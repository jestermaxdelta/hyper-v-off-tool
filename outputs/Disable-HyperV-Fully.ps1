#requires -version 5.1
<#
.SYNOPSIS
Disables the Microsoft hypervisor, Hyper-V/VBS consumers, Credential Guard,
Memory Integrity (HVCI), Windows Hello PIN sign-in, and related Windows
optional features.

.DESCRIPTION
The script is restart-resilient. Before changing Hyper-V/VBS, it creates and
verifies a System Restore point plus focused BCD/registry/feature backups. It
then installs a protected continuation copy and SYSTEM startup task, suspends
BitLocker protection for at most two restarts, applies supported Windows
settings, optionally stages Microsoft's SecConfig.efi UEFI opt-out flow,
restarts, verifies the result, and writes a report.

If a blue/black firmware confirmation screen appears, physical presence is
required. Read the prompt and press the requested key (commonly F3) to accept.

This cannot generically turn off Intel VT-x/AMD-V in BIOS/UEFI firmware. That
setting is vendor-specific. It is not necessary for the Windows hypervisor to
be fully stopped, but some third-party diagnostics may insist on it.

.PARAMETER NoRestart
Apply and stage everything but leave the restart to the operator.

.PARAMETER SkipFirmwareOptOut
Do not stage SecConfig.efi. Use only when Credential Guard/VBS was never locked
in UEFI, or when firmware interaction is prohibited.

.PARAMETER VerifyOnly
Make no changes; write and display the current status report.

.NOTES
Run from elevated Windows PowerShell 5.1. If not elevated, the script asks for
UAC elevation automatically. Logs and the final report are written under:
C:\ProgramData\Disable-HyperV-Fully
#>

[CmdletBinding()]
param(
    [switch] $NoRestart,
    [switch] $SkipFirmwareOptOut,
    [switch] $VerifyOnly,
    [switch] $ContinueAfterRestart
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:WorkRoot = Join-Path $env:ProgramData 'Disable-HyperV-Fully'
$script:InstalledScript = Join-Path $script:WorkRoot 'Disable-HyperV-Fully.ps1'
$script:StateFile = Join-Path $script:WorkRoot 'state.json'
$script:LogFile = Join-Path $script:WorkRoot 'Disable-HyperV-Fully.log'
$script:EventLogFile = Join-Path $script:WorkRoot 'Operational-Events.jsonl'
$script:ReportFile = Join-Path $script:WorkRoot 'Final-Status.txt'
$script:TaskName = 'Disable-HyperV-Fully-Continue'
$script:DgOptOutGuid = '{0cb3b571-2f2e-4343-a879-d86a476d7215}'
$script:RunId = [guid]::NewGuid().ToString('N')

$script:FeatureNames = @(
    'Containers-DisposableClientVM',
    'Windows-Defender-ApplicationGuard',
    'Microsoft-Defender-ApplicationGuard',
    'VirtualMachinePlatform',
    'HypervisorPlatform',
    'IsolatedUserMode',
    'Microsoft-Hyper-V-Management-PowerShell',
    'Microsoft-Hyper-V-Management-Clients',
    'Microsoft-Hyper-V-Tools-All',
    'Microsoft-Hyper-V-Services',
    'Microsoft-Hyper-V-Hypervisor',
    'Microsoft-Hyper-V',
    'Microsoft-Hyper-V-All'
)

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-Elevation {
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    if ($NoRestart) { $arguments += '-NoRestart' }
    if ($SkipFirmwareOptOut) { $arguments += '-SkipFirmwareOptOut' }
    if ($VerifyOnly) { $arguments += '-VerifyOnly' }
    Start-Process -FilePath $windowsPowerShell -Verb RunAs -ArgumentList ($arguments -join ' ')
}

if (-not (Test-IsAdministrator)) {
    if ($ContinueAfterRestart) { throw 'The continuation must run as SYSTEM or Administrator.' }
    Request-Elevation
    return
}

New-Item -ItemType Directory -Path $script:WorkRoot -Force | Out-Null

function Protect-WorkRoot {
    # The scheduled task runs as SYSTEM, so prevent standard users from replacing
    # the continuation script or its state before the next boot.
    $acl = Get-Acl -LiteralPath $script:WorkRoot
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) {
        [void]$acl.RemoveAccessRuleSpecific($rule)
    }

    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    foreach ($sidText in @('S-1-5-18', 'S-1-5-32-544')) {
        $sid = New-Object Security.Principal.SecurityIdentifier($sidText)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            $sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            $propagation,
            $allow
        )
        [void]$acl.AddAccessRule($rule)
    }
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    Set-Acl -LiteralPath $script:WorkRoot -AclObject $acl
}

Protect-WorkRoot

function Write-Log {
    param([Parameter(Mandatory = $true)][string] $Message)
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
}

function Add-OperationalEvent {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Info', 'Success', 'Action', 'Warning', 'Error')][string] $Level,
        [Parameter(Mandatory = $true)][string] $Code,
        [Parameter(Mandatory = $true)][string] $Message,
        [string] $ActionRequired = ''
    )
    [pscustomobject]@{
        Timestamp      = (Get-Date).ToString('o')
        RunId          = $script:RunId
        Level          = $Level
        Code           = $Code
        Message        = $Message
        ActionRequired = $ActionRequired
    } | ConvertTo-Json -Compress | Add-Content -LiteralPath $script:EventLogFile -Encoding UTF8
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string] $FilePath,
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [switch] $IgnoreExitCode
    )
    $output = & $FilePath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $IgnoreExitCode) {
        Write-Log ("FAILED: {0} {1}" -f $FilePath, ($Arguments -join ' '))
        foreach ($line in @($output)) {
            if ($null -ne $line -and "$line".Length -gt 0) { Write-Log "$line" }
        }
        throw "$FilePath exited with code $exitCode."
    }
    return $exitCode
}

function Get-RestorePointsSafely {
    try {
        return @(Get-ComputerRestorePoint -ErrorAction Stop)
    }
    catch {
        return @()
    }
}

function New-VerifiedSystemRestorePoint {
    $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem
    if ([int]$operatingSystem.ProductType -ne 1) {
        throw 'System Restore points are supported only on Windows client editions. No Hyper-V/VBS changes were made.'
    }
    if (-not (Get-Command Enable-ComputerRestore -ErrorAction SilentlyContinue) -or
        -not (Get-Command Checkpoint-Computer -ErrorAction SilentlyContinue)) {
        throw 'The Windows System Restore PowerShell commands are unavailable. No Hyper-V/VBS changes were made.'
    }

    $drive = "$($env:SystemDrive)\"
    $description = 'Before disabling Hyper-V and VBS {0}' -f (Get-Date -Format 'yyyy-MM-dd HHmmss')
    $beforeSequenceNumbers = @(Get-RestorePointsSafely | ForEach-Object { [int]$_.SequenceNumber })
    $frequencyPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $frequencyName = 'SystemRestorePointCreationFrequency'
    $frequencyProperty = Get-ItemProperty -LiteralPath $frequencyPath -Name $frequencyName -ErrorAction SilentlyContinue
    $frequencyExisted = $null -ne $frequencyProperty
    $originalFrequency = if ($frequencyExisted) { [int]$frequencyProperty.$frequencyName } else { $null }

    Write-Log "Enabling System Restore on $drive if necessary."
    Enable-ComputerRestore -Drive $drive -ErrorAction Stop

    # Microsoft documents value 0 as forcing creation instead of silently
    # skipping when another restore point is less than 24 hours old. Restore the
    # operator's original setting immediately after the checkpoint call.
    New-ItemProperty -Path $frequencyPath -Name $frequencyName -PropertyType DWord -Value 0 -Force | Out-Null
    try {
        Write-Log "Creating mandatory System Restore point: $description"
        Checkpoint-Computer -Description $description -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
    }
    finally {
        if ($frequencyExisted) {
            New-ItemProperty -Path $frequencyPath -Name $frequencyName -PropertyType DWord -Value $originalFrequency -Force | Out-Null
        }
        else {
            Remove-ItemProperty -LiteralPath $frequencyPath -Name $frequencyName -ErrorAction SilentlyContinue
        }
    }

    $newPoint = $null
    for ($verificationAttempt = 1; $verificationAttempt -le 10 -and $null -eq $newPoint; $verificationAttempt++) {
        $newPoint = Get-RestorePointsSafely | Where-Object {
            $_.Description -eq $description -and [int]$_.SequenceNumber -notin $beforeSequenceNumbers
        } | Sort-Object SequenceNumber -Descending | Select-Object -First 1
        if ($null -eq $newPoint) { Start-Sleep -Seconds 2 }
    }

    if ($null -eq $newPoint) {
        throw 'Windows did not verify creation of a new System Restore point. No Hyper-V/VBS changes were made.'
    }

    Write-Log "Verified System Restore point sequence $($newPoint.SequenceNumber)."
    Add-OperationalEvent -Level Success -Code 'RESTORE_POINT_CREATED' `
        -Message "Created and verified restore point '$description'."
    return [pscustomobject]@{
        Description    = $description
        SequenceNumber = [int]$newPoint.SequenceNumber
        CreationTime   = "$($newPoint.CreationTime)"
    }
}

function New-PreChangeBackup {
    $backupDirectory = Join-Path $script:WorkRoot ('Backup-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    Write-Log "Creating focused pre-change backup in $backupDirectory"

    Invoke-Native -FilePath 'bcdedit.exe' -Arguments @('/export', (Join-Path $backupDirectory 'BCD-Backup.bcd')) | Out-Null
    (& bcdedit.exe /enum all /v 2>&1 | Out-String) |
        Set-Content -LiteralPath (Join-Path $backupDirectory 'BCD-Inventory.txt') -Encoding Unicode

    foreach ($registryBackup in @(
        @('HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard', 'DeviceGuard-System.reg'),
        @('HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard', 'DeviceGuard-Policy.reg')
    )) {
        $providerPath = $registryBackup[0] -replace '^HKLM\\', 'HKLM:\'
        if (Test-Path -LiteralPath $providerPath) {
            Invoke-Native -FilePath 'reg.exe' -Arguments @('export', $registryBackup[0], (Join-Path $backupDirectory $registryBackup[1]), '/y') | Out-Null
        }
    }

    $lsaPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
    $lsaProperty = Get-ItemProperty -LiteralPath $lsaPath -Name LsaCfgFlags -ErrorAction SilentlyContinue
    [pscustomobject]@{
        Path   = $lsaPath
        Name   = 'LsaCfgFlags'
        Exists = ($null -ne $lsaProperty)
        Value  = if ($null -ne $lsaProperty) { $lsaProperty.LsaCfgFlags } else { $null }
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backupDirectory 'LsaCfgFlags.json') -Encoding UTF8

    try {
        Get-WindowsOptionalFeature -Online | Select-Object FeatureName, @{
            Name = 'State'; Expression = { "$($_.State)" }
        } | ConvertTo-Json -Depth 3 |
            Set-Content -LiteralPath (Join-Path $backupDirectory 'Windows-Features.json') -Encoding UTF8
    }
    catch {
        Write-Log "WARNING: Windows feature inventory backup failed: $($_.Exception.Message)"
        Add-OperationalEvent -Level Warning -Code 'FEATURE_BASELINE_PARTIAL' `
            -Message 'The safety backup could not capture the Windows feature inventory.' `
            -ActionRequired 'Run Get-WindowsOptionalFeature -Online from an elevated PowerShell window. Resolve its error before relying on feature-by-feature rollback.'
    }

    try {
        Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard |
            Select-Object * | ConvertTo-Json -Depth 4 |
            Set-Content -LiteralPath (Join-Path $backupDirectory 'DeviceGuard-Status.json') -Encoding UTF8
    }
    catch {
        Write-Log "WARNING: Device Guard status backup failed: $($_.Exception.Message)"
        Add-OperationalEvent -Level Warning -Code 'DEVICE_GUARD_BASELINE_PARTIAL' `
            -Message 'The safety backup could not capture the pre-change Device Guard status.' `
            -ActionRequired 'Run Get-CimInstance Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard from an elevated PowerShell window and resolve its WMI error.'
    }

    Write-Log 'Pre-change BCD and configuration backup completed.'
    Add-OperationalEvent -Level Success -Code 'SAFETY_BACKUP_CREATED' `
        -Message "Saved the BCD and targeted configuration baseline to $backupDirectory."
    return $backupDirectory
}

function Set-RegistryDword {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][int] $Value
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -Path $Path -Name $Name -PropertyType DWord -Value $Value -Force | Out-Null
}

function Set-VbsRegistryOff {
    Write-Log 'Explicitly disabling VBS, Credential Guard, HVCI, and System Guard policy/configuration.'

    $values = @(
        @('HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard', 'EnableVirtualizationBasedSecurity', 0),
        @('HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard', 'RequirePlatformSecurityFeatures', 0),
        @('HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard', 'Locked', 0),
        @('HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard', 'Mandatory', 0),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard', 'EnableVirtualizationBasedSecurity', 0),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard', 'RequirePlatformSecurityFeatures', 0),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard', 'LsaCfgFlags', 0),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard', 'HypervisorEnforcedCodeIntegrity', 0),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard', 'ConfigureSystemGuardLaunch', 0),
        @('HKLM:\SYSTEM\CurrentControlSet\Control\Lsa', 'LsaCfgFlags', 0),
        @('HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\CredentialGuard', 'Enabled', 0),
        @('HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity', 'Enabled', 0),
        @('HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity', 'Locked', 0),
        @('HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\SystemGuard', 'Enabled', 0),
        @('HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\KernelShadowStacks', 'Enabled', 0)
    )

    foreach ($value in $values) {
        Set-RegistryDword -Path $value[0] -Name $value[1] -Value $value[2]
    }
    Add-OperationalEvent -Level Success -Code 'VBS_POLICY_DISABLED' `
        -Message 'Applied explicit off settings for VBS, Credential Guard, Memory Integrity, Secure Launch, and kernel shadow stacks.'
}

function Disable-WindowsHelloPin {
    Write-Log 'Disabling Windows Hello PIN sign-in (prevents the TPM "PIN is no longer available" lockout).'

    # Block PIN logon through policy so Windows falls back to the account password.
    Set-RegistryDword -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name 'AllowPINLogon' -Value 0
    Set-RegistryDword -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name 'AllowDomainPINLogon' -Value 0

    # Stop and disable the NGC container service so Windows cannot re-provision
    # Hello credentials behind our back.
    foreach ($serviceName in @('NgcCtnrSvc')) {
        try {
            Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
            Set-Service -Name $serviceName -StartupType Disabled -ErrorAction SilentlyContinue
        }
        catch {
            Write-Log "WARNING: Could not stop/disable service ${serviceName}: $($_.Exception.Message)"
        }
    }

    # Existing PIN/Hello containers are TPM-sealed. The boot-measurement change
    # made by disabling VBS/Secure Launch invalidates them, which is exactly
    # what produces the "Something happened and your PIN isn't available"
    # sign-in screen. Remove the stale containers entirely.
    $ngcPath = Join-Path $env:SystemRoot 'ServiceProfiles\LocalService\AppData\Local\Microsoft\Ngc'
    if (Test-Path -LiteralPath $ngcPath) {
        Invoke-Native -FilePath 'takeown.exe' -Arguments @('/f', $ngcPath, '/r', '/d', 'y') -IgnoreExitCode | Out-Null
        Invoke-Native -FilePath 'icacls.exe' -Arguments @($ngcPath, '/grant', '*S-1-5-32-544:(OI)(CI)F', '/t', '/c', '/q') -IgnoreExitCode | Out-Null
        try {
            Get-ChildItem -LiteralPath $ngcPath -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Cleared existing Windows Hello containers under $ngcPath."
        }
        catch {
            Write-Log "WARNING: Could not fully clear ${ngcPath}: $($_.Exception.Message)"
        }
    }

    Add-OperationalEvent -Level Success -Code 'PIN_DISABLED' `
        -Message 'Windows Hello PIN sign-in is fully disabled. Sign in with the account password instead.' `
        -ActionRequired 'Sign in with the account password (Microsoft account or local password). The PIN option will no longer be offered at sign-in.'
}

function Disable-HyperVFeatures {
    Write-Log 'Disabling Windows features that install or consume the Microsoft hypervisor.'
    $disabledFeatures = @()
    try {
        $features = @(Get-WindowsOptionalFeature -Online)
        foreach ($name in $script:FeatureNames) {
            $feature = $features | Where-Object FeatureName -eq $name | Select-Object -First 1
            if ($null -ne $feature -and $feature.State -in @('Enabled', 'EnablePending')) {
                Write-Log "Disabling optional feature: $name"
                try {
                    Disable-WindowsOptionalFeature -Online -FeatureName $name -NoRestart -ErrorAction Stop | Out-Null
                    $disabledFeatures += $name
                }
                catch {
                    Write-Log "WARNING: Could not disable $name directly: $($_.Exception.Message)"
                    Add-OperationalEvent -Level Error -Code 'FEATURE_DISABLE_FAILED' `
                        -Message "Windows could not disable the '$name' feature." `
                        -ActionRequired "Restart Windows, reopen this app, and retry. If it still fails, run DISM /Online /Disable-Feature /FeatureName:$name /NoRestart from an elevated terminal."
                }
            }
        }
    }
    catch {
        Write-Log "WARNING: Optional-feature inventory failed: $($_.Exception.Message)"
        Add-OperationalEvent -Level Error -Code 'FEATURE_INVENTORY_FAILED' `
            -Message 'Windows did not return its optional-feature inventory.' `
            -ActionRequired 'Restart Windows, then run the operation again. If it repeats, run DISM /Online /Cleanup-Image /RestoreHealth first.'
    }

    if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
        try {
            $serverHyperV = Get-WindowsFeature -Name Hyper-V -ErrorAction Stop
            if ($serverHyperV.Installed) {
                Write-Log 'Removing the Hyper-V role on Windows Server.'
                Uninstall-WindowsFeature -Name Hyper-V -IncludeManagementTools -Restart:$false | Out-Null
                $disabledFeatures += 'Hyper-V server role'
            }
        }
        catch {
            Write-Log "WARNING: Windows Server Hyper-V role check/removal failed: $($_.Exception.Message)"
            Add-OperationalEvent -Level Error -Code 'SERVER_ROLE_DISABLE_FAILED' `
                -Message 'Windows could not remove the Hyper-V server role.' `
                -ActionRequired 'Run Uninstall-WindowsFeature Hyper-V -IncludeManagementTools from an elevated PowerShell window, then restart.'
        }
    }
    if ($disabledFeatures.Count -gt 0) {
        Add-OperationalEvent -Level Success -Code 'FEATURES_DISABLED' `
            -Message ('Disabled: {0}.' -f ($disabledFeatures -join ', '))
    }
}

function Set-BootConfigurationOff {
    Write-Log 'Setting Windows boot entries not to launch the hypervisor or Virtual Secure Mode.'
    $activeBootConfigured = $false
    foreach ($entry in @('{current}', '{default}')) {
        $hypervisorExit = Invoke-Native -FilePath 'bcdedit.exe' -Arguments @('/set', $entry, 'hypervisorlaunchtype', 'off') -IgnoreExitCode
        $vsmExit = Invoke-Native -FilePath 'bcdedit.exe' -Arguments @('/set', $entry, 'vsmlaunchtype', 'off') -IgnoreExitCode
        if ($entry -eq '{current}' -and ($hypervisorExit -ne 0 -or $vsmExit -ne 0)) {
            Add-OperationalEvent -Level Error -Code 'BOOT_CONFIGURATION_FAILED' `
                -Message 'Windows could not persist both hypervisor boot-off settings on the active boot entry.' `
                -ActionRequired 'Open an elevated terminal, run bcdedit /set {current} hypervisorlaunchtype off and bcdedit /set {current} vsmlaunchtype off, then restart.'
        }
        elseif ($entry -eq '{current}') {
            $activeBootConfigured = $true
        }
    }
    if ($activeBootConfigured) {
        Add-OperationalEvent -Level Success -Code 'BOOT_CONFIGURATION_APPLIED' `
            -Message 'Configured the active Windows boot entry not to launch Hyper-V or Virtual Secure Mode.'
    }
}

function Invoke-DisablementPass {
    Set-VbsRegistryOff
    Disable-WindowsHelloPin
    Disable-HyperVFeatures
    Set-BootConfigurationOff
}

function Get-BitLockerProtectionStatus {
    if (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) {
        try {
            $bitLockerVolume = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
            switch ("$($bitLockerVolume.ProtectionStatus)") {
                'On'  { return 1 }
                'Off' { return 0 }
            }
        }
        catch {
            # Fall through to the independent WMI query. Do not surface a
            # failure unless both supported query paths fail.
        }
    }

    try {
        $escapedDrive = $env:SystemDrive.Replace('\', '\\')
        $volume = Get-CimInstance -Namespace 'root\CIMV2\Security\MicrosoftVolumeEncryption' `
            -ClassName Win32_EncryptableVolume -Filter "DriveLetter='$escapedDrive'" -ErrorAction Stop
        if ($null -eq $volume) { return 0 }
        $result = Invoke-CimMethod -InputObject $volume -MethodName GetProtectionStatus -ErrorAction Stop
        return [int]$result.ProtectionStatus
    }
    catch {
        Write-Log "WARNING: Could not query BitLocker through WMI: $($_.Exception.Message)"
        return 2
    }
}

function Suspend-SystemDriveBitLocker {
    $status = Get-BitLockerProtectionStatus
    if ($status -eq 0) {
        Write-Log 'BitLocker/device-encryption protection is not active on the OS drive.'
        Add-OperationalEvent -Level Info -Code 'BITLOCKER_NOT_ACTIVE' `
            -Message 'OS-drive BitLocker protection is not active, so no suspension was needed.'
        return $false
    }
    if ($status -eq 2) {
        throw 'BitLocker state is unknown. Refusing boot changes to avoid a recovery-key lockout. Confirm the OS-drive recovery key is available, then retry.'
    }

    Write-Log 'Suspending OS-drive BitLocker protection for two restarts (the disk remains encrypted).'
    if (Get-Command Suspend-BitLocker -ErrorAction SilentlyContinue) {
        Suspend-BitLocker -MountPoint $env:SystemDrive -RebootCount 2 -ErrorAction Stop | Out-Null
    }
    else {
        Invoke-Native -FilePath 'manage-bde.exe' -Arguments @('-protectors', '-disable', $env:SystemDrive, '-RebootCount', '2') | Out-Null
    }
    Add-OperationalEvent -Level Success -Code 'BITLOCKER_SUSPENDED' `
        -Message 'Temporarily suspended OS-drive BitLocker protection for at most two restarts.'
    return $true
}

function Resume-SystemDriveBitLocker {
    try {
        if ((Get-BitLockerProtectionStatus) -ne 1) {
            Write-Log 'Re-enabling OS-drive BitLocker protection.'
            if (Get-Command Resume-BitLocker -ErrorAction SilentlyContinue) {
                Resume-BitLocker -MountPoint $env:SystemDrive -ErrorAction Stop | Out-Null
            }
            else {
                Invoke-Native -FilePath 'manage-bde.exe' -Arguments @('-protectors', '-enable', $env:SystemDrive) | Out-Null
            }
            Add-OperationalEvent -Level Success -Code 'BITLOCKER_RESUMED' `
                -Message 'Re-enabled OS-drive BitLocker protection.'
        }
    }
    catch {
        Write-Log "WARNING: BitLocker protection could not be resumed automatically: $($_.Exception.Message)"
        Add-OperationalEvent -Level Error -Code 'BITLOCKER_RESUME_FAILED' `
            -Message 'Windows could not automatically re-enable OS-drive BitLocker protection.' `
            -ActionRequired "Open an elevated PowerShell window and run Resume-BitLocker -MountPoint '$env:SystemDrive'."
    }
}

function Install-ContinuationTask {
    Copy-Item -LiteralPath $PSCommandPath -Destination $script:InstalledScript -Force
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $actionArguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ContinueAfterRestart' -f $script:InstalledScript
    $action = New-ScheduledTaskAction -Execute $windowsPowerShell -Argument $actionArguments
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 45)
    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
    Write-Log "Installed restart continuation task: $($script:TaskName)"
    Add-OperationalEvent -Level Success -Code 'CONTINUATION_ARMED' `
        -Message 'Installed the protected SYSTEM continuation task for restart recovery.'
}

function Remove-ContinuationTask {
    Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
}

function Save-State {
    param([Parameter(Mandatory = $true)] $State)
    $State | ConvertTo-Json | Set-Content -LiteralPath $script:StateFile -Encoding UTF8
}

function Load-State {
    if (-not (Test-Path -LiteralPath $script:StateFile)) {
        throw "Continuation state file is missing: $($script:StateFile)"
    }
    return (Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json)
}

function Stage-UefiOptOut {
    Write-Log 'Staging Microsoft SecConfig.efi to remove Credential Guard/VBS UEFI locks.'
    $secConfig = Join-Path $env:SystemRoot 'System32\SecConfig.efi'
    if (-not (Test-Path -LiteralPath $secConfig)) {
        Write-Log 'WARNING: SecConfig.efi is absent; the UEFI opt-out cannot be staged on this Windows installation.'
        Add-OperationalEvent -Level Error -Code 'SECCONFIG_MISSING' `
            -Message 'Microsoft SecConfig.efi is missing, so a firmware-locked VBS policy cannot be removed automatically.' `
            -ActionRequired 'Run DISM /Online /Cleanup-Image /RestoreHealth, restart Windows, then retry.'
        return $false
    }

    $usedLetters = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Name.ToUpperInvariant() })
    $driveLetter = [char[]](83..90) | ForEach-Object { "$_" } | Where-Object { $_ -notin $usedLetters } | Select-Object -First 1
    if (-not $driveLetter) { throw 'No free drive letter from S: through Z: is available for the EFI System Partition.' }
    $drive = "$driveLetter`:"
    $mounted = $false

    try {
        $mountExit = Invoke-Native -FilePath 'mountvol.exe' -Arguments @($drive, '/s') -IgnoreExitCode
        if ($mountExit -ne 0) {
            Write-Log 'No mountable EFI System Partition was found. This is expected on legacy-BIOS systems; skipping the firmware opt-out.'
            Add-OperationalEvent -Level Info -Code 'UEFI_FLOW_NOT_APPLICABLE' `
                -Message 'No mountable EFI System Partition was found. The firmware opt-out step was skipped.'
            return $false
        }
        $mounted = $true
        $efiDestination = Join-Path $drive 'EFI\Microsoft\Boot\SecConfig.efi'
        Copy-Item -LiteralPath $secConfig -Destination $efiDestination -Force

        # This fixed GUID and load option are from Microsoft's DG Readiness tool.
        Invoke-Native -FilePath 'bcdedit.exe' -Arguments @('/delete', $script:DgOptOutGuid, '/cleanup') -IgnoreExitCode | Out-Null
        Invoke-Native -FilePath 'bcdedit.exe' -Arguments @('/create', $script:DgOptOutGuid, '/d', 'DG/VBS Opt-Out', '/application', 'osloader') | Out-Null
        Invoke-Native -FilePath 'bcdedit.exe' -Arguments @('/set', $script:DgOptOutGuid, 'path', '\EFI\Microsoft\Boot\SecConfig.efi') | Out-Null
        Invoke-Native -FilePath 'bcdedit.exe' -Arguments @('/set', '{bootmgr}', 'bootsequence', $script:DgOptOutGuid) | Out-Null
        Invoke-Native -FilePath 'bcdedit.exe' -Arguments @('/set', $script:DgOptOutGuid, 'loadoptions', 'DISABLE-LSA-ISO,DISABLE-VBS') | Out-Null
        Invoke-Native -FilePath 'bcdedit.exe' -Arguments @('/set', $script:DgOptOutGuid, 'device', "partition=$drive") | Out-Null
        Write-Log 'UEFI opt-out staged. The next boot may require physical confirmation (commonly the F3 key).'
        Add-OperationalEvent -Level Action -Code 'UEFI_CONFIRMATION_REQUIRED' `
            -Message 'Staged Microsoft SecConfig.efi to remove any firmware-locked VBS configuration.' `
            -ActionRequired 'At the next boot, approve the firmware prompt using the key shown on screen, commonly F3.'
        return $true
    }
    finally {
        if ($mounted) {
            Invoke-Native -FilePath 'mountvol.exe' -Arguments @($drive, '/d') -IgnoreExitCode | Out-Null
        }
    }
}

function Get-DisablementStatus {
    $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
    $processors = @(Get-CimInstance -ClassName Win32_Processor)
    $deviceGuard = $null
    try {
        $deviceGuard = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
    }
    catch {
        Write-Log "WARNING: Win32_DeviceGuard status is unavailable: $($_.Exception.Message)"
        Add-OperationalEvent -Level Error -Code 'DEVICE_GUARD_STATUS_UNAVAILABLE' `
            -Message 'Windows could not return the Device Guard verification status.' `
            -ActionRequired 'Run winmgmt /verifyrepository from an elevated terminal. Repair the WMI repository only if Windows reports it inconsistent, then verify again.'
    }

    $enabledFeatures = @()
    try {
        $allFeatures = @(Get-WindowsOptionalFeature -Online)
        $enabledFeatures = @($allFeatures | Where-Object {
            $_.FeatureName -in $script:FeatureNames -and $_.State -in @('Enabled', 'EnablePending')
        } | ForEach-Object { '{0} [{1}]' -f $_.FeatureName, $_.State })
    }
    catch {
        $enabledFeatures = @("STATUS QUERY FAILED: $($_.Exception.Message)")
    }

    $bcdText = (& bcdedit.exe /enum '{current}' 2>&1 | Out-String)
    $incorrectRegistrySettings = @()
    foreach ($requiredValue in @(
        @('HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard', 'EnableVirtualizationBasedSecurity'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard', 'EnableVirtualizationBasedSecurity'),
        @('HKLM:\SYSTEM\CurrentControlSet\Control\Lsa', 'LsaCfgFlags'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard', 'LsaCfgFlags'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard', 'HypervisorEnforcedCodeIntegrity'),
        @('HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\CredentialGuard', 'Enabled'),
        @('HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity', 'Enabled'),
        @('HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\SystemGuard', 'Enabled'),
        @('HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\KernelShadowStacks', 'Enabled')
    )) {
        try {
            $actualValue = (Get-ItemProperty -LiteralPath $requiredValue[0] -Name $requiredValue[1] -ErrorAction Stop).($requiredValue[1])
            if ([int]$actualValue -ne 0) {
                $incorrectRegistrySettings += '{0}\{1}={2}' -f $requiredValue[0], $requiredValue[1], $actualValue
            }
        }
        catch {
            $incorrectRegistrySettings += '{0}\{1}=missing/unreadable' -f $requiredValue[0], $requiredValue[1]
        }
    }
    $pinLogonPolicy = $null
    try {
        $pinLogonPolicy = [int](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name AllowPINLogon -ErrorAction Stop).AllowPINLogon
    }
    catch { }

    $hypervisorPresent = $false
    if ($computerSystem.PSObject.Properties.Name -contains 'HypervisorPresent') {
        $hypervisorPresent = [bool]$computerSystem.HypervisorPresent
    }

    $vbsStatus = $null
    $servicesRunning = @()
    if ($null -ne $deviceGuard) {
        $vbsStatus = [int]$deviceGuard.VirtualizationBasedSecurityStatus
        $servicesRunning = @($deviceGuard.SecurityServicesRunning | Where-Object { [int]$_ -ne 0 })
    }

    $firmwareVirtualization = @($processors | ForEach-Object {
        if ($_.PSObject.Properties.Name -contains 'VirtualizationFirmwareEnabled') {
            $_.VirtualizationFirmwareEnabled
        }
    } | Select-Object -Unique)

    $status = [pscustomobject]@{
        Timestamp                         = Get-Date
        ComputerName                      = $env:COMPUTERNAME
        DomainJoined                      = [bool]$computerSystem.PartOfDomain
        Domain                            = $computerSystem.Domain
        HypervisorPresent                 = $hypervisorPresent
        VirtualizationBasedSecurityStatus = $vbsStatus
        DeviceGuardStatusAvailable         = [bool]($null -ne $deviceGuard)
        SecurityServicesRunning           = $servicesRunning
        EnabledHypervisorFeatures          = $enabledFeatures
        BcdHypervisorLaunchOff             = [bool]($bcdText -match '(?im)^hypervisorlaunchtype\s+Off\s*$')
        BcdVsmLaunchOff                    = [bool]($bcdText -match '(?im)^vsmlaunchtype\s+Off\s*$')
        RegistryDisableSettingsCorrect     = [bool]($incorrectRegistrySettings.Count -eq 0)
        RegistrySettingsNotDisabled        = $incorrectRegistrySettings
        PinLogonDisabledByPolicy           = ($pinLogonPolicy -eq 0)
        FirmwareVirtualizationEnabled      = $firmwareVirtualization
        BcdCurrentEntry                    = $bcdText.Trim()
    }

    $status | Add-Member -NotePropertyName WindowsHypervisorFullyDisabled -NotePropertyValue ([bool](
        -not $status.HypervisorPresent -and
        $status.DeviceGuardStatusAvailable -and
        $status.VirtualizationBasedSecurityStatus -eq 0 -and
        @($status.SecurityServicesRunning).Count -eq 0 -and
        @($status.EnabledHypervisorFeatures).Count -eq 0 -and
        $status.BcdHypervisorLaunchOff -and
        $status.BcdVsmLaunchOff -and
        $status.RegistryDisableSettingsCorrect
    ))
    return $status
}

function Write-StatusReport {
    param(
        [Parameter(Mandatory = $true)] $Status,
        [AllowNull()] $State = $null
    )

    $serviceText = if (@($Status.SecurityServicesRunning).Count) { @($Status.SecurityServicesRunning) -join ', ' } else { 'None' }
    $featureText = if (@($Status.EnabledHypervisorFeatures).Count) { @($Status.EnabledHypervisorFeatures) -join [Environment]::NewLine } else { 'None' }
    $firmwareText = if (@($Status.FirmwareVirtualizationEnabled).Count) { @($Status.FirmwareVirtualizationEnabled) -join ', ' } else { 'Unknown' }
    $registryProblemText = if (@($Status.RegistrySettingsNotDisabled).Count) { @($Status.RegistrySettingsNotDisabled) -join [Environment]::NewLine } else { 'None' }
    $restorePointText = 'Not created (verification-only run)'
    $backupText = 'Not created (verification-only run)'
    if ($null -ne $State) {
        if ($State.PSObject.Properties.Name -contains 'RestorePointDescription') {
            $restorePointText = '{0} (sequence {1})' -f $State.RestorePointDescription, $State.RestorePointSequenceNumber
        }
        if ($State.PSObject.Properties.Name -contains 'BackupDirectory') {
            $backupText = "$($State.BackupDirectory)"
        }
    }
    $vbsMeaning = switch ($Status.VirtualizationBasedSecurityStatus) {
        0 { '0 (not enabled)' }
        1 { '1 (enabled but not running)' }
        2 { '2 (enabled and running)' }
        default { 'Unavailable' }
    }

    $report = @"
Hyper-V / VBS disablement report
Generated: $($Status.Timestamp.ToString('yyyy-MM-dd HH:mm:ss zzz'))
Computer:  $($Status.ComputerName)

RESULT: Windows hypervisor fully disabled = $($Status.WindowsHypervisorFullyDisabled)

Pre-change restore point:           $restorePointText
Focused safety backup:              $backupText

HypervisorPresent:                 $($Status.HypervisorPresent)
Device Guard status available:     $($Status.DeviceGuardStatusAvailable)
VirtualizationBasedSecurityStatus: $vbsMeaning
SecurityServicesRunning:           $serviceText
BCD hypervisorlaunchtype Off:      $($Status.BcdHypervisorLaunchOff)
BCD vsmlaunchtype Off:             $($Status.BcdVsmLaunchOff)
Registry disable settings correct: $($Status.RegistryDisableSettingsCorrect)
Registry settings not disabled:    $registryProblemText
Windows Hello PIN disabled:        $($Status.PinLogonDisabledByPolicy)
Enabled related Windows features:  $featureText

Firmware virtualization enabled:   $firmwareText
Domain joined:                      $($Status.DomainJoined) ($($Status.Domain))

Interpretation:
- RESULT=True means the Microsoft hypervisor and VBS are stopped in Windows.
- Firmware virtualization can remain True; Intel VT-x/AMD-V is a separate,
  vendor-specific BIOS/UEFI setting and does not mean Hyper-V is running.
- On a managed PC, domain Group Policy or MDM can re-enable these settings.
- Windows Hello PIN sign-in is disabled by this workflow. Sign in with the
  account password instead.
- Security impact: Credential Guard, Memory Integrity/HVCI, Application Guard,
  Sandbox, WSL 2, Hyper-V, Windows Hello PIN, and hypervisor-based containers
  are disabled.

Current BCD entry:
$($Status.BcdCurrentEntry)
"@
    $report | Set-Content -LiteralPath $script:ReportFile -Encoding UTF8
    Write-Host ''
    Write-Host $report
    Write-Log "Status report written to $($script:ReportFile)"
}

function Complete-Workflow {
    param(
        [Parameter(Mandatory = $true)] $State,
        [Parameter(Mandatory = $true)] $Status
    )
    Remove-ContinuationTask
    Invoke-Native -FilePath 'bcdedit.exe' -Arguments @('/delete', $script:DgOptOutGuid, '/cleanup') -IgnoreExitCode | Out-Null
    if ([bool]$State.BitLockerSuspendedByScript) { Resume-SystemDriveBitLocker }
    $State | Add-Member -NotePropertyName Completed -NotePropertyValue $true -Force
    $State | Add-Member -NotePropertyName CompletedAt -NotePropertyValue ((Get-Date).ToString('o')) -Force
    Save-State -State $State
    Write-StatusReport -Status $Status -State $State
    if ($Status.WindowsHypervisorFullyDisabled) {
        Write-Log 'SUCCESS: The Windows hypervisor and VBS are fully disabled.'
        Add-OperationalEvent -Level Success -Code 'VERIFICATION_PASSED' `
            -Message 'Verification passed. Hyper-V and VBS are fully disabled in Windows.'
    }
    else {
        Write-Log 'INCOMPLETE: Review Final-Status.txt. A firmware confirmation may have been declined, or central policy may be re-enabling VBS.'
        $failedChecks = @()
        if ($Status.HypervisorPresent) { $failedChecks += 'the hypervisor is still present' }
        if ($Status.VirtualizationBasedSecurityStatus -ne 0) { $failedChecks += 'VBS is still enabled or running' }
        if (@($Status.EnabledHypervisorFeatures).Count) { $failedChecks += 'virtualization features remain enabled' }
        if (-not $Status.BcdHypervisorLaunchOff -or -not $Status.BcdVsmLaunchOff) { $failedChecks += 'boot-off settings are incomplete' }
        if (-not $Status.RegistryDisableSettingsCorrect) { $failedChecks += 'disable policies were overwritten' }
        $action = if ($Status.DomainJoined -and -not $Status.RegistryDisableSettingsCorrect) {
            'Change the domain Group Policy or MDM policy that enables VBS, then run Verify again.'
        }
        elseif ($Status.VirtualizationBasedSecurityStatus -ne 0 -or $Status.HypervisorPresent) {
            'Run the operation again and approve the pre-boot firmware prompt. If it persists, disable Intel VT-x or AMD SVM in the vendor BIOS.'
        }
        else {
            'Open Final-Status.txt, correct the named failed check, then run Verify again.'
        }
        Add-OperationalEvent -Level Error -Code 'VERIFICATION_FAILED' `
            -Message ('Verification failed: {0}.' -f ($failedChecks -join '; ')) `
            -ActionRequired $action
    }
}

function Request-Restart {
    param([int] $Attempt)
    Write-Host ''
    Write-Warning 'The PC will restart in 30 seconds. Save any open work. Run "shutdown.exe /a" to cancel.'
    Write-Warning 'If a firmware confirmation screen appears, accept the DG/VBS opt-out (commonly by pressing F3).'
    Write-Log "Scheduling restart for verification attempt $Attempt."
    Add-OperationalEvent -Level Action -Code 'RESTART_SCHEDULED' `
        -Message "Scheduled restart for verification attempt $Attempt of 2." `
        -ActionRequired 'Save open work. At boot, approve the firmware prompt if Windows displays one.'
    Invoke-Native -FilePath 'shutdown.exe' -Arguments @('/r', '/t', '30', '/c', 'Finishing Hyper-V and VBS disablement') | Out-Null
}

$bitLockerSuspended = $false

try {
    if ($VerifyOnly) {
        $verifyStatus = Get-DisablementStatus
        Write-StatusReport -Status $verifyStatus
        if ($verifyStatus.WindowsHypervisorFullyDisabled) {
            Add-OperationalEvent -Level Success -Code 'VERIFY_ONLY_PASSED' `
                -Message 'Verification passed. Hyper-V and VBS are fully disabled in Windows.'
        }
        else {
            Add-OperationalEvent -Level Error -Code 'VERIFY_ONLY_FAILED' `
                -Message 'Verification found one or more active or persistent virtualization settings.' `
                -ActionRequired 'Run the full disablement operation, complete its restart flow, then verify again.'
        }
        return
    }

    if ($ContinueAfterRestart) {
        Start-Sleep -Seconds 15
        $state = Load-State
        if ($state.PSObject.Properties.Name -contains 'RunId') { $script:RunId = "$($state.RunId)" }
        Write-Log "Continuation started after restart; attempt $($state.Attempt) of 2."
        Add-OperationalEvent -Level Info -Code 'CONTINUATION_STARTED' `
            -Message "Resumed automatically after restart for verification attempt $($state.Attempt) of 2."
        Invoke-DisablementPass
        $status = Get-DisablementStatus

        if (-not $status.WindowsHypervisorFullyDisabled -and [int]$state.Attempt -lt 2) {
            $state.Attempt = 2
            if (-not [bool]$state.SkipFirmwareOptOut) {
                $state.UefiOptOutStaged = Stage-UefiOptOut
            }
            Save-State -State $state
            Request-Restart -Attempt 2
            return
        }

        Complete-Workflow -State $state -Status $status
        return
    }

    # Smart short-circuit: if the hypervisor and VBS are already fully off,
    # change nothing, mark the run complete, and let the UI stop re-opening.
    Write-Log 'Checking whether Hyper-V/VBS are already disabled.'
    $preChangeStatus = Get-DisablementStatus
    if ($preChangeStatus.WindowsHypervisorFullyDisabled) {
        Write-Log 'Hyper-V and VBS are already fully disabled. No changes were made.'
        Add-OperationalEvent -Level Success -Code 'ALREADY_DISABLED' `
            -Message 'Hyper-V and VBS were already fully disabled. Nothing needed to change.'
        $existingState = $null
        if (Test-Path -LiteralPath $script:StateFile) {
            try { $existingState = Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json } catch { }
        }
        if ($null -eq $existingState) {
            $existingState = [pscustomobject]@{
                Attempt = 1
                RunId   = $script:RunId
                Started = (Get-Date).ToString('o')
            }
        }
        $existingState | Add-Member -NotePropertyName SkipFirmwareOptOut -NotePropertyValue ([bool]$SkipFirmwareOptOut) -Force
        $existingState | Add-Member -NotePropertyName BitLockerSuspendedByScript -NotePropertyValue $false -Force
        $existingState | Add-Member -NotePropertyName Completed -NotePropertyValue $true -Force
        $existingState | Add-Member -NotePropertyName CompletedAt -NotePropertyValue ((Get-Date).ToString('o')) -Force
        Save-State -State $existingState
        Write-StatusReport -Status $preChangeStatus -State $existingState
        return
    }

    Write-Log 'Starting complete Hyper-V/VBS disablement.'
    Add-OperationalEvent -Level Info -Code 'WORKFLOW_STARTED' `
        -Message 'Started the guarded Hyper-V and VBS disablement workflow.'
    Write-Warning 'This intentionally reduces Windows security and removes Hyper-V, Sandbox, WSL 2 support, Application Guard, Windows Hello PIN sign-in, and hypervisor-based containers.'
    $restorePoint = New-VerifiedSystemRestorePoint
    $backupDirectory = New-PreChangeBackup
    $bitLockerSuspended = Suspend-SystemDriveBitLocker
    Install-ContinuationTask
    $state = [pscustomobject]@{
        Attempt                     = 1
        RunId                       = $script:RunId
        Started                     = (Get-Date).ToString('o')
        SkipFirmwareOptOut          = [bool]$SkipFirmwareOptOut
        UefiOptOutStaged            = $false
        BitLockerSuspendedByScript  = [bool]$bitLockerSuspended
        RestorePointDescription     = $restorePoint.Description
        RestorePointSequenceNumber  = [int]$restorePoint.SequenceNumber
        RestorePointCreationTime    = $restorePoint.CreationTime
        BackupDirectory             = $backupDirectory
    }
    Save-State -State $state
    Invoke-DisablementPass

    $uefiStaged = $false
    if (-not $SkipFirmwareOptOut) {
        $uefiStaged = Stage-UefiOptOut
    }

    $state.UefiOptOutStaged = [bool]$uefiStaged
    Save-State -State $state

    if ($NoRestart) {
        Write-Log 'Changes are staged. Restart manually when ready; the startup task will continue and verify automatically.'
        Write-Warning 'On the next boot, accept the DG/VBS firmware opt-out prompt if one appears (commonly F3).'
        Add-OperationalEvent -Level Action -Code 'MANUAL_RESTART_REQUIRED' `
            -Message 'All changes are staged and the continuation task is armed.' `
            -ActionRequired 'Restart Windows when ready. Approve the firmware prompt if one appears.'
    }
    else {
        Request-Restart -Attempt 1
    }
}
catch {
    Write-Log "FATAL: $($_.Exception.Message)"
    Write-Log $_.ScriptStackTrace
    $failureMessage = $_.Exception.Message
    $failureAction = if ($failureMessage -like '*Restore point*' -or $failureMessage -like '*System Restore*') {
        'Open System Protection, enable protection for the OS drive, ensure at least 2 GB is available, then retry.'
    }
    elseif ($failureMessage -like '*BitLocker*') {
        'Confirm the OS-drive BitLocker recovery key is available, then retry.'
    }
    elseif ($failureMessage -like '*bcdedit*' -or $failureMessage -like '*boot*') {
        'Run bcdedit /enum from an elevated terminal. Repair BCD access errors before retrying.'
    }
    else {
        'Restart Windows and retry once. If it repeats, use the failure text shown here when escalating to support.'
    }
    Add-OperationalEvent -Level Error -Code 'WORKFLOW_FAILED' `
        -Message $failureMessage -ActionRequired $failureAction
    Remove-ContinuationTask
    # Remove only the fixed temporary Microsoft DG opt-out entry. This also
    # clears any one-time bootsequence reference if staging failed midway.
    Invoke-Native -FilePath 'bcdedit.exe' -Arguments @('/delete', $script:DgOptOutGuid, '/cleanup') -IgnoreExitCode | Out-Null
    if ($ContinueAfterRestart) {
        try {
            if (Test-Path -LiteralPath $script:StateFile) {
                $failedState = Load-State
                if ([bool]$failedState.BitLockerSuspendedByScript) { Resume-SystemDriveBitLocker }
            }
        }
        catch {
            Write-Log "WARNING: Failure cleanup could not restore BitLocker automatically: $($_.Exception.Message)"
        }
    }
    elseif ($bitLockerSuspended) {
        Resume-SystemDriveBitLocker
    }
    throw
}
