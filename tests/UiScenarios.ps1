# Dot-sourced at the end of the console script by Invoke-UiTests.ps1, in place
# of ShowDialog(). Everything here runs in the console's script scope, so it
# drives the real window, real handlers and real functions.
$ErrorActionPreference = 'Stop'
$timer.Stop()

$shotDir = if ($env:GITHUB_WORKSPACE) { Join-Path $env:GITHUB_WORKSPACE 'ui-screens' } else { Join-Path $env:TEMP 'ui-screens' }
New-Item -ItemType Directory -Path $shotDir -Force | Out-Null
$script:failures = New-Object System.Collections.ArrayList

function Assert-That {
    param([bool] $Condition, [string] $Message)
    if ($Condition) { Write-Host "ok: $Message" }
    else { Write-Host "FAIL: $Message"; [void]$script:failures.Add($Message) }
}

function Wait-Ui {
    param([int] $Ms = 300)
    $frame = New-Object Windows.Threading.DispatcherFrame
    $pump = New-Object Windows.Threading.DispatcherTimer
    $pump.Interval = [TimeSpan]::FromMilliseconds($Ms)
    $pump.Add_Tick({ $pump.Stop(); $frame.Continue = $false }.GetNewClosure())
    $pump.Start()
    [Windows.Threading.Dispatcher]::PushFrame($frame)
}

function Save-Shot {
    param([string] $Name)
    Wait-Ui 450
    foreach ($panel in @($OverviewPanel, $ControlsPanel, $TestingPanel, $ActivityPanel)) {
        $panel.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
        $panel.Opacity = 1
    }
    $PanelHost.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $null)
    $window.BeginAnimation([Windows.Window]::OpacityProperty, $null)
    $window.Opacity = 1
    $content = $window.Content
    if ($content.ActualWidth -eq 0) {
        # Window could not be shown (no desktop): lay the content out by hand.
        $content.Measure((New-Object Windows.Size 1200, 820))
        $content.Arrange((New-Object Windows.Rect 0, 0, 1200, 820))
    }
    $content.UpdateLayout()
    $bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap ([int]$content.ActualWidth), ([int]$content.ActualHeight), 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($content)
    $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [IO.File]::Create((Join-Path $shotDir "$Name.png"))
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
    Write-Host "shot: $Name.png"
}

function Invoke-Click {
    param($Button)
    $Button.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
}

# ------------------------------------------------------------------ mocks

$realGetCurrentState = ${function:Get-CurrentState}
$realStartEngine = ${function:Start-Engine}
$script:mockSnapshot = $null
$script:mockState = $null
$script:useMockState = $true
$script:mockTask = $false
$script:mockBusy = $false
$script:startCalls = 0

function New-Snap {
    param($Hypervisor, $Vbs, $Domain = $false)
    [pscustomobject]@{ Hypervisor = $Hypervisor; VbsStatus = $Vbs; Domain = $Domain; AlreadyOff = (($Hypervisor -eq $false) -and ($Vbs -eq 0)) }
}

function Get-SystemSnapshot {
    if ($null -ne $script:mockSnapshot) { return $script:mockSnapshot }
    $snapshot = [ordered]@{ Hypervisor = $null; VbsStatus = $null; Domain = $null; AlreadyOff = $false }
    try {
        $system = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if (Test-HasProperty $system 'HypervisorPresent') { $snapshot.Hypervisor = [bool]$system.HypervisorPresent }
        if (Test-HasProperty $system 'PartOfDomain') { $snapshot.Domain = [bool]$system.PartOfDomain }
    } catch { }
    try {
        $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
        if (Test-HasProperty $dg 'VirtualizationBasedSecurityStatus') { $snapshot.VbsStatus = [int]$dg.VirtualizationBasedSecurityStatus }
    } catch { }
    $snapshot.AlreadyOff = ($snapshot.Hypervisor -eq $false) -and ($snapshot.VbsStatus -eq 0)
    return [pscustomobject]$snapshot
}
function Get-CurrentState { if ($script:useMockState) { return $script:mockState } ; & $realGetCurrentState }
function Test-EngineBusy {
    if ($script:mockBusy) { return $true }
    return ($null -ne $script:engineProcess -and -not $script:engineProcess.HasExited)
}
function Get-ScheduledTask {
    param([string] $TaskName)
    if ($null -ne $script:mockTask) { if ($script:mockTask) { return [pscustomobject]@{ TaskName = $TaskName } } else { return $null } }
    ScheduledTasks\Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
}
function Start-Engine { param([switch] $Verify) $script:startCalls++ }

$realEventLog = $eventLogPath
$eventLogPath = Join-Path $env:TEMP 'ui-test-events.jsonl'

function Write-TestEvents {
    param([object[]] $Events)
    Remove-Item -LiteralPath $eventLogPath -Force -ErrorAction SilentlyContinue
    foreach ($e in $Events) { $e | ConvertTo-Json -Compress | Add-Content -LiteralPath $eventLogPath -Encoding UTF8 }
    $script:lastEventSignature = ''
}
function New-TestEvent {
    param([string] $Level, [string] $Code, [string] $Message, [string] $Action = '', [datetime] $At = (Get-Date))
    [pscustomobject]@{ Timestamp = $At.ToString('o'); RunId = 't'; Level = $Level; Code = $Code; Message = $Message; ActionRequired = $Action }
}
function Set-Scenario {
    param($Snap, $State = $null, [bool] $Task = $false, [bool] $Busy = $false, [string] $Mode = 'Run')
    $script:mockSnapshot = $Snap
    $script:mockState = $State
    $script:mockTask = $Task
    $script:mockBusy = $Busy
    $script:engineMode = $Mode
    Refresh-Activity
    Read-LiveStatus
}

# ------------------------------------------------------------------ show window

try {
    $window.Show()
    Wait-Ui 600
    Assert-That $window.IsVisible 'window shows'
} catch {
    Assert-That $false "window shows: $($_.Exception.Message)"
}

try {
    # 1. Ready
    Write-TestEvents @()
    Set-Scenario (New-Snap $true 2)
    Show-Panel -Name 'Overview'
    Assert-That ($StatusTitle.Text -eq 'Ready to turn off Hyper-V.') 'ready: title'
    Assert-That ($RunButton.IsEnabled -and "$($RunButton.Content)" -eq 'Turn off Hyper-V') 'ready: run button enabled'
    Assert-That ($HypervisorCheck.Text -eq 'Running' -and $VbsCheck.Text -eq 'Running') 'ready: live values'
    Assert-That ($HeaderStatus.Text -eq 'READY') 'ready: pill'
    Assert-That ($ActivityEmpty.Visibility -eq 'Visible') 'ready: empty log state'
    Save-Shot '01-overview-ready'

    # 2. Confirm flow (regression: refresh must not revert the armed button)
    Invoke-Click $RunButton
    Assert-That $script:confirmationArmed 'confirm: first click arms'
    Assert-That ($ControlsPanel.Visibility -eq 'Visible') 'confirm: jumps to Options'
    Assert-That ($ConfirmBanner.Visibility -eq 'Visible') 'confirm: banner shown'
    Read-LiveStatus
    Assert-That ("$($RunButton.Content)" -eq 'Yes, turn it off') 'confirm: refresh keeps "Yes, turn it off"'
    Assert-That ($script:startCalls -eq 0) 'confirm: nothing started yet'
    Save-Shot '02-options-confirm'
    Invoke-Click $CancelConfirmButton
    Assert-That (-not $script:confirmationArmed) 'confirm: Cancel disarms'
    Assert-That ("$($RunButton.Content)" -eq 'Turn off Hyper-V') 'confirm: label restored after cancel'
    Invoke-Click $RunButton
    $script:confirmDeadline = (Get-Date).AddSeconds(-1)
    Update-ConfirmCountdown
    Assert-That (-not $script:confirmationArmed) 'confirm: times out'
    Invoke-Click $RunButton
    Invoke-Click $RunButton
    Assert-That ($script:startCalls -eq 1) 'confirm: second click starts the engine once'

    # 3. Working
    Set-Scenario (New-Snap $true 2) -Busy $true
    Show-Panel -Name 'Overview'
    Assert-That ($StatusTitle.Text -eq 'Turning off Hyper-V.') 'working: title'
    Assert-That (-not $RunButton.IsEnabled) 'working: run button locked'
    Assert-That (-not $VerifyButton.IsEnabled) 'working: check button locked'
    Assert-That ($BusyTrack.Visibility -eq 'Visible') 'working: busy bar'
    Assert-That ($Step1State.Text -eq 'In progress') 'working: step 1 active'
    Save-Shot '03-overview-working'

    Set-Scenario (New-Snap $true 2) -Busy $true -Mode 'Verify'
    Assert-That ($StatusTitle.Text -eq 'Checking this PC.') 'verify: title'
    $script:mockBusy = $false

    # 4. Restart pending
    Write-TestEvents @(
        (New-TestEvent Info WORKFLOW_STARTED 'Started the guarded Hyper-V and VBS disablement workflow.' '' (Get-Date).AddMinutes(-2)),
        (New-TestEvent Action RESTART_SCHEDULED 'Scheduled restart for verification attempt 1 of 2.' 'Save open work. At boot, approve the firmware prompt if Windows displays one.')
    )
    Set-Scenario (New-Snap $true 2) ([pscustomobject]@{ Attempt = 1; RestorePointDescription = 'rp' }) -Task $true
    Assert-That ($StatusTitle.Text -like 'Restarting in about*') 'restart: countdown title'
    Assert-That ($CancelRestartButton.Visibility -eq 'Visible') 'restart: cancel restart button'
    Assert-That ($Step3State.Text -eq 'Restart 1 of 2') 'restart: step 3 caption'
    Save-Shot '04-overview-restarting'

    # 5. Incomplete + failure badge
    Write-TestEvents @(
        (New-TestEvent Info WORKFLOW_STARTED 'Started the guarded Hyper-V and VBS disablement workflow.' '' (Get-Date).AddMinutes(-3)),
        (New-TestEvent Error WORKFLOW_FAILED 'System Restore is disabled on the OS drive.' 'Open System Protection, enable protection for the OS drive, ensure at least 2 GB is available, then retry.')
    )
    Set-Scenario (New-Snap $true 2) ([pscustomobject]@{ Attempt = 1 })
    Assert-That ($StatusTitle.Text -eq 'The last run did not finish.') 'incomplete: title'
    Assert-That ("$($RunButton.Content)" -eq 'Try again' -and $RunButton.IsEnabled) 'incomplete: try again'
    Assert-That ($LogBadge.Visibility -eq 'Visible' -and $LogBadgeText.Text -eq '1') 'incomplete: failure badge'
    Assert-That ($Step1State.Text -eq 'Stopped') 'incomplete: step 1 failed'
    Show-Panel -Name 'Overview'
    Save-Shot '05-overview-incomplete'
    Invoke-Click $RunButton
    Read-LiveStatus
    Assert-That ($script:confirmationArmed -and "$($RunButton.Content)" -eq 'Yes, turn it off') 'incomplete: confirm survives refresh'
    Invoke-Click $CancelConfirmButton

    # 6. Log page and filters
    Write-TestEvents @(
        (New-TestEvent Info WORKFLOW_STARTED 'Started the guarded Hyper-V and VBS disablement workflow.' '' (Get-Date).AddDays(-1)),
        (New-TestEvent Success RESTORE_POINT_VERIFIED 'Created and verified restore point "Before Hyper-V off".'),
        (New-TestEvent Warning DEFENDER_TAMPER_ON 'Tamper Protection is ON. Windows will block most of these changes.' 'Turn off Tamper Protection in Windows Security first, then disable again.'),
        (New-TestEvent Action RESTART_SCHEDULED 'Scheduled restart for verification attempt 1 of 2.' 'Save open work.' (Get-Date).AddMinutes(-10)),
        (New-TestEvent Error VERIFICATION_FAILED 'Verification failed: VBS is still enabled or running.' 'Run the operation again and approve the pre-boot firmware prompt.')
    )
    Set-Scenario (New-Snap $true 2) ([pscustomobject]@{ Attempt = 2; RestorePointDescription = 'rp' })
    Show-Panel -Name 'Activity'
    Assert-That (@($ActivityList.ItemsSource).Count -eq 5) 'log: all 5 entries'
    Assert-That ("$(@($ActivityList.ItemsSource)[0].Message)" -like 'Verification failed*') 'log: newest first'
    Save-Shot '06-log-all'
    $ActionFilter.IsChecked = $true
    Assert-That (@($ActivityList.ItemsSource).Count -eq 3) 'log: needs-attention filter'
    $FailureFilter.IsChecked = $true
    Assert-That (@($ActivityList.ItemsSource).Count -eq 1) 'log: failed filter'
    Write-TestEvents @((New-TestEvent Success VERIFY_ONLY_PASSED 'Verification passed.'))
    Refresh-Activity
    Assert-That ($ActivityEmpty.Visibility -eq 'Visible' -and $ActivityEmptyTitle.Text -eq 'All clear') 'log: filtered empty state'
    $AllFilter.IsChecked = $true

    # Malformed lines never break the log
    Remove-Item -LiteralPath $eventLogPath -Force
    Add-Content -LiteralPath $eventLogPath -Value 'not json' -Encoding UTF8
    Add-Content -LiteralPath $eventLogPath -Value '{}' -Encoding UTF8
    Add-Content -LiteralPath $eventLogPath -Value '{"Timestamp":"bad","Level":"Mystery","Message":"odd one"}' -Encoding UTF8
    $script:lastEventSignature = ''
    Refresh-Activity
    Assert-That (@($ActivityList.ItemsSource).Count -eq 1) 'log: malformed lines skipped, odd level rendered'

    # 7. Finished states
    Write-TestEvents @()
    Set-Scenario (New-Snap $false 0)
    Show-Panel -Name 'Overview'
    Assert-That ($StatusTitle.Text -eq 'Hyper-V is off.' -and -not $RunButton.IsEnabled) 'off: title and locked button'
    Assert-That ($HeaderStatus.Text -eq 'OFF') 'off: pill'
    Save-Shot '07-overview-off'

    Set-Scenario (New-Snap $true 2) ([pscustomobject]@{ Attempt = 2; Completed = $true })
    Assert-That ($StatusTitle.Text -eq 'Finished, but not everything is off.') 'completed-but-on: title'
    Set-Scenario (New-Snap $null $null) ([pscustomobject]@{ Attempt = 2; Completed = $true })
    Assert-That ($StatusTitle.Text -eq 'The run has finished.') 'completed-unknown: title'
    Assert-That ($HypervisorCheck.Text -eq 'Unavailable') 'completed-unknown: unavailable value'

    # 8. Managed PC
    Set-Scenario (New-Snap $true 2 $true)
    Assert-That ($ManagedCheck.Text -eq 'Work or school' -and $ManagedNote.Visibility -eq 'Visible') 'managed: note shown'
    Save-Shot '08-overview-managed'

    # 9. Options (no confirm) and Testing
    Show-Panel -Name 'Controls'
    Save-Shot '09-options'
    $TestingNav.IsChecked = $true
    Assert-That ($TestingPanel.Visibility -eq 'Visible') 'testing: nav works'
    Assert-That ($DefTamperValue.Text -ne 'Checking') 'testing: defender status read'
    Invoke-Click $DefenderDisableButton
    Assert-That ("$($DefenderDisableButton.Content)" -eq 'Click again to disable') 'testing: disable needs a second click'
    Save-Shot '10-testing'
    Reset-DefenderArm

    # 10. Registry helper: deleting an absent value is not a "blocked" warning
    Write-TestEvents @()
    $testKey = 'HKCU:\Software\HyperVOffUiTest'
    Assert-That (Restore-TamperSafeRegistryValue -Path $testKey -Name 'Probe' -Value 1) 'registry: set'
    Assert-That ((Get-ItemProperty -LiteralPath $testKey -Name Probe).Probe -eq 1) 'registry: value written'
    Assert-That (Restore-TamperSafeRegistryValue -Path $testKey -Name 'Probe' -Delete) 'registry: delete'
    Assert-That (Restore-TamperSafeRegistryValue -Path $testKey -Name 'Probe' -Delete) 'registry: delete missing'
    Assert-That (Restore-TamperSafeRegistryValue -Path "$testKey\Nope" -Name 'Probe' -Delete) 'registry: delete missing key'
    Assert-That (-not (@(Get-OperationalEvents) | Where-Object { $_.Code -eq 'DEFENDER_CHANGE_BLOCKED' })) 'registry: no false blocked warnings'
    Remove-Item -LiteralPath $testKey -Recurse -Force -ErrorAction SilentlyContinue

    # 11. Real system: live status, then real engine runs
    $script:mockSnapshot = $null
    $script:mockTask = $null
    $script:mockBusy = $false
    $script:useMockState = $false
    $eventLogPath = $realEventLog
    Set-Item -Path function:script:Start-Engine -Value $realStartEngine
    $script:lastEventSignature = ''
    Refresh-Activity
    Read-LiveStatus
    Write-Host "real: hypervisor=$($HypervisorCheck.Text) vbs=$($VbsCheck.Text) managed=$($ManagedCheck.Text) title=$($StatusTitle.Text)"
    Assert-That ($HypervisorCheck.Text -in @('Running','Stopped')) 'real: hypervisor status read'

    function Wait-Engine {
        param([int] $Seconds = 240)
        $deadline = (Get-Date).AddSeconds($Seconds)
        while (-not $script:engineProcess.HasExited -and (Get-Date) -lt $deadline) { Wait-Ui 500 }
        return $script:engineProcess.HasExited
    }

    $before = @(Get-OperationalEvents).Count
    Invoke-Click $VerifyButton
    Assert-That ($null -ne $script:engineProcess) 'real verify: engine started'
    Assert-That ($ActivityPanel.Visibility -eq 'Visible') 'real verify: jumps to log'
    Assert-That (Wait-Engine) 'real verify: engine finished'
    $newEvents = @(Get-OperationalEvents | Select-Object -Skip $before)
    $newEvents | ForEach-Object { Write-Host "  event: [$($_.Level)] $($_.Code) - $($_.Message)" }
    Assert-That (@($newEvents | Where-Object { $_.Code -in @('VERIFY_ONLY_PASSED','VERIFY_ONLY_FAILED') }).Count -eq 1) 'real verify: produced a verification result'
    Assert-That (-not ($newEvents | Where-Object { $_.Code -eq 'WORKFLOW_FAILED' })) 'real verify: no engine crash'
    Assert-That (Test-Path -LiteralPath $reportPath) 'real verify: Final-Status.txt written'
    $script:lastEventSignature = ''
    Refresh-Activity
    Read-LiveStatus
    Assert-That ($VerifyButton.IsEnabled) 'real verify: check button unlocks afterwards'
    Save-Shot '11-log-real-verify'

    # Full run with no restart. On this server it must stop safely at the
    # restore-point gate (no System Restore) and report why.
    $AutoRestartToggle.IsChecked = $false
    $ReopenToggle.IsChecked = $false
    $before = @(Get-OperationalEvents).Count
    Invoke-Click $RunButton
    Invoke-Click $RunButton
    Assert-That ($null -ne $script:engineProcess -and $script:engineMode -eq 'Run') 'real run: engine started'
    Assert-That (Wait-Engine 600) 'real run: engine finished'
    $newEvents = @(Get-OperationalEvents | Select-Object -Skip $before)
    $newEvents | ForEach-Object { Write-Host "  event: [$($_.Level)] $($_.Code) - $($_.Message) | $($_.ActionRequired)" }
    Assert-That ($newEvents.Count -gt 0) 'real run: produced events'
    Assert-That (-not (Get-ItemProperty -LiteralPath $runOncePath -Name $runOnceName -ErrorAction SilentlyContinue)) 'real run: no sign-in reopen when the toggle is off'
    Assert-That ($null -eq (ScheduledTasks\Get-ScheduledTask -TaskName $continuationTaskName -ErrorAction SilentlyContinue) -or ($newEvents | Where-Object { $_.Code -eq 'MANUAL_RESTART_REQUIRED' })) 'real run: no stray continuation task after a failure'
    $script:lastEventSignature = ''
    Refresh-Activity
    Read-LiveStatus
    Show-Panel -Name 'Overview'
    Save-Shot '12-overview-after-real-run'
    Show-Panel -Name 'Activity'
    Save-Shot '13-log-after-real-run'
    $logFile = Join-Path $workRoot 'Disable-HyperV-Fully.log'
    if (Test-Path -LiteralPath $logFile) { Write-Host '--- engine log tail ---'; Get-Content -LiteralPath $logFile -Tail 25 | ForEach-Object { Write-Host "  $_" } }
}
catch {
    Assert-That $false "unexpected error: $($_.Exception.Message) at $($_.InvocationInfo.PositionMessage)"
}

try { $window.Close() } catch { }
Write-Host ''
if ($script:failures.Count) {
    Write-Host "$($script:failures.Count) check(s) failed:"
    $script:failures | ForEach-Object { Write-Host "  - $_" }
    exit 1
}
Write-Host 'All UI checks passed.'
exit 0
