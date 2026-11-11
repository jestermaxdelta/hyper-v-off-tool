# TEMPORARY review harness (removed before merge). Dot-sourced in place of
# ShowDialog(), so it runs in the console's script scope against the real
# window, real handlers and real functions.
$ErrorActionPreference = 'Stop'

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
    param([string] $Name, [double] $Scale = 1)
    Wait-Ui 450
    foreach ($element in @($HomePanel, $ActivityPanel, $TestingPanel, $ConfirmOverlay, $HelpOverlay)) {
        $element.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
        $element.Opacity = 1
    }
    foreach ($card in @($ConfirmCard, $HelpCard)) {
        $card.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $null)
    }
    $PageHost.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $null)
    $window.BeginAnimation([Windows.Window]::OpacityProperty, $null)
    $window.Opacity = 1
    $content = $window.Content
    if ($content.ActualWidth -eq 0) {
        $content.Measure((New-Object Windows.Size $window.Width, $window.Height))
        $content.Arrange((New-Object Windows.Rect 0, 0, $window.Width, $window.Height))
    }
    $content.UpdateLayout()
    $width = [int][Math]::Ceiling($content.ActualWidth * $Scale)
    $height = [int][Math]::Ceiling($content.ActualHeight * $Scale)
    $bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap $width, $height, (96 * $Scale), (96 * $Scale), ([Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($content)
    $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [IO.File]::Create((Join-Path $shotDir "$Name.png"))
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
    Write-Host "shot: $Name.png ($width x $height)"
}

function Test-FullyInside {
    param($Element, $Ancestor)
    if (-not $Element.IsVisible) { return $true }
    $origin = $Element.TransformToAncestor($Ancestor).Transform((New-Object Windows.Point 0, 0))
    return ($origin.X -ge -0.5 -and $origin.Y -ge -0.5 -and
            ($origin.X + $Element.ActualWidth) -le ($Ancestor.ActualWidth + 0.5) -and
            ($origin.Y + $Element.ActualHeight) -le ($Ancestor.ActualHeight + 0.5))
}

function Invoke-Ticks {
    param([int] $Seconds, [scriptblock] $Until)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        Invoke-Tick
        if ($Until -and (& $Until)) { return $true }
        Wait-Ui 250
    }
    return $false
}

try {
    Write-Host "reduceMotion=$script:reduceMotion renderTier=$([Windows.Media.RenderCapability]::Tier -shr 16)"
    $timer.Stop()
    $window.Show()
    Wait-Ui 800
    Assert-That $window.IsVisible 'window shows'

    # ------------------------------------------------------------ real machine
    $gotSnapshot = Invoke-Ticks 45 { $null -ne $script:snapshot }
    Assert-That $gotSnapshot 'background poller delivers a snapshot'
    if ($gotSnapshot) { Write-Host ($script:snapshot | ConvertTo-Json -Compress) }
    Save-Shot '00-real-initial'

    Start-Engine -Verify
    Assert-That (Test-EngineBusy) 'real verify: engine reports busy'
    [void](Invoke-Ticks 5)
    Save-Shot '00-real-verifying'
    $finished = Invoke-Ticks 180 { -not (Test-EngineBusy) }
    Assert-That $finished 'real verify: engine finished'
    [void](Invoke-Ticks 3)
    Assert-That ($script:events.Count -gt 0) 'real verify: events were read from the live log'
    $script:events | Select-Object -Last 4 | ForEach-Object { Write-Host ("event: {0} {1} {2}" -f $_.Level, $_.Code, $_.Message) }
    Save-Shot '00-real-after-verify'

    Stop-StatusPoller
    Wait-Ui 300

    # ------------------------------------------------------------ mocks
    $eventLogPath = Join-Path $env:TEMP 'ui-preview-events.jsonl'

    function New-TestEvent {
        param([string] $Level, [string] $Code, [string] $Message, [string] $Action = '', [int] $SecondsAgo = 60)
        [pscustomobject]@{ Timestamp = (Get-Date).AddSeconds(-$SecondsAgo).ToString('o'); RunId = 't'; Level = $Level; Code = $Code; Message = $Message; ActionRequired = $Action }
    }
    function New-Snap {
        param($Hypervisor = $true, $Vbs = 2, $Cg = $true, $Hvci = $true, $Domain = $false, [switch] $Task, [switch] $Engine,
              [switch] $Verify, [switch] $Continuation, [switch] $Battery, $BitLocker = $true, $Product = 1, $FreeGB = 118.4, $BootMinutesAgo = 300)
        [pscustomobject]@{
            Taken = Get-Date; Hypervisor = $Hypervisor; VbsStatus = $Vbs; Domain = $Domain
            AlreadyOff = (($Hypervisor -eq $false) -and ($Vbs -eq 0))
            CredentialGuard = $Cg; MemoryIntegrity = $Hvci
            TaskExists = [bool]$Task; EngineRunning = [bool]$Engine; EngineVerify = [bool]$Verify; EngineContinuation = [bool]$Continuation
            OnBattery = [bool]$Battery; FreeGB = $FreeGB; BitLockerOn = $BitLocker
            ProductType = $Product; OsCaption = 'Windows 11 Pro'; BootTime = (Get-Date).AddMinutes(-$BootMinutesAgo)
        }
    }
    function Set-Scenario {
        param($Snap, $State = $null, [object[]] $Events = @())
        Remove-Item -LiteralPath $eventLogPath -Force -ErrorAction SilentlyContinue
        foreach ($e in $Events) { $e | ConvertTo-Json -Compress | Add-Content -LiteralPath $eventLogPath -Encoding UTF8 }
        $script:events = New-Object System.Collections.ArrayList
        $script:eventOffset = [long]0
        $script:activitySignature = ''
        [void](Read-NewEvents)
        Update-EventInsights
        Update-ActivityList
        $script:engineProcess = $null
        $script:engineMode = ''
        $script:engineStartedAt = $null
        $script:restartArmedUntil = [datetime]::MinValue
        $script:snapshot = $Snap
        $script:state = $State
        Update-View
    }

    $runEvents = @(
        (New-TestEvent Info 'WORKFLOW_STARTED' 'Started the guarded Hyper-V and VBS disablement workflow.' '' 300),
        (New-TestEvent Success 'RESTORE_POINT_CREATED' "Created and verified restore point 'Before disabling Hyper-V and VBS 2026-11-11 101500'." '' 240),
        (New-TestEvent Success 'SAFETY_BACKUP_CREATED' 'Saved the BCD and targeted configuration baseline to C:\ProgramData\Disable-HyperV-Fully\Backup-20261111-101700.' '' 230),
        (New-TestEvent Success 'BITLOCKER_SUSPENDED' 'Temporarily suspended OS-drive BitLocker protection for at most two restarts.' '' 225),
        (New-TestEvent Success 'CONTINUATION_ARMED' 'Installed the protected SYSTEM continuation task for restart recovery.' '' 220),
        (New-TestEvent Success 'VBS_POLICY_DISABLED' 'Applied explicit off settings for VBS, Credential Guard, Memory Integrity, Secure Launch, and kernel shadow stacks.' '' 215),
        (New-TestEvent Success 'PIN_DISABLED' 'Windows Hello PIN sign-in is fully disabled. Sign in with the account password instead.' 'Sign in with the account password (Microsoft account or local password). The PIN option will no longer be offered at sign-in.' 210)
    )
    $restartEvents = $runEvents + @(
        (New-TestEvent Success 'FEATURES_DISABLED' 'Disabled: Microsoft-Hyper-V-All, VirtualMachinePlatform, Containers-DisposableClientVM.' '' 60),
        (New-TestEvent Success 'BOOT_CONFIGURATION_APPLIED' 'Configured the active Windows boot entry not to launch Hyper-V or Virtual Secure Mode.' '' 40),
        (New-TestEvent Action 'UEFI_CONFIRMATION_REQUIRED' 'Staged Microsoft SecConfig.efi to remove any firmware-locked VBS configuration.' 'At the next boot, approve the firmware prompt using the key shown on screen, commonly F3.' 30)
    )
    $state1 = [pscustomobject]@{ Attempt = 1; RunId = 't'; UefiOptOutStaged = $true; RestorePointDescription = 'Before disabling Hyper-V and VBS'; BitLockerSuspendedByScript = $true }

    # 1. Checking
    Set-Scenario $null
    Show-Page -Name 'Home'
    Assert-That ($StatusTitle.Text -eq 'Checking this PC...') 'checking: title'
    Assert-That (-not $PrimaryButton.IsEnabled) 'checking: primary disabled'
    Save-Shot '01-checking'

    # 2. Ready
    Set-Scenario (New-Snap)
    Assert-That ($StatusTitle.Text -eq 'Ready to turn off Hyper-V.') 'ready: title'
    Assert-That ($PrimaryButton.IsEnabled -and $PrimaryText.Text -eq 'Turn off Hyper-V') 'ready: primary'
    Assert-That ($SecondaryButton.IsVisible -and $SecondaryButton.IsEnabled) 'ready: check button available'
    Assert-That (@($GuideList.ItemsSource).Count -eq 3) 'ready: three guidance steps'
    Assert-That ($HvValue.Text -eq 'Running' -and $CgValue.Text -eq 'On') 'ready: live readings'
    Write-Host "window size: $($window.ActualWidth) x $($window.ActualHeight) (work area $([Windows.SystemParameters]::WorkArea))"
    Assert-That (Test-FullyInside $PrimaryButton $window) 'layout: primary button fully visible'
    Assert-That (Test-FullyInside $SecondaryButton $window) 'layout: check button fully visible'
    Save-Shot '02-ready'
    Save-Shot '02-ready@2x' 2

    # 3. Confirm sheet with every pre-flight warning
    Set-Scenario (New-Snap -Battery -Domain $true -FreeGB 1.4)
    Assert-That (@($GuideList.ItemsSource).Count -eq 6) 'ready+warnings: extra guidance steps'
    Save-Shot '02b-ready-warnings'
    Invoke-Primary
    Assert-That ($ConfirmOverlay.Visibility -eq 'Visible') 'confirm: sheet opens'
    Assert-That (-not $ConfirmStart.IsEnabled) 'confirm: start disabled until both boxes ticked'
    Assert-That (@($PreflightList.ItemsSource).Count -eq 5) 'confirm: pre-flight items'
    Save-Shot '03-confirm'
    $AckSaved.IsChecked = $true
    Assert-That (-not $ConfirmStart.IsEnabled) 'confirm: one box is not enough'
    $AckPassword.IsChecked = $true
    Assert-That $ConfirmStart.IsEnabled 'confirm: both boxes enable start'
    Save-Shot '03b-confirm-ready'
    Save-Shot '03b-confirm-ready@2x' 2
    try {
        $escape = New-Object Windows.Input.KeyEventArgs([Windows.Input.Keyboard]::PrimaryDevice, [Windows.PresentationSource]::FromVisual($window), 0, [Windows.Input.Key]::Escape)
        $escape.RoutedEvent = [Windows.Input.Keyboard]::PreviewKeyDownEvent
        $window.RaiseEvent($escape)
        Assert-That ($ConfirmOverlay.Visibility -ne 'Visible') 'confirm: Esc closes the sheet'
    }
    catch { Write-Host "note: could not simulate Esc ($($_.Exception.Message))"; Close-Sheet }

    # 4. Working
    Set-Scenario (New-Snap -Engine) $state1 $runEvents
    Assert-That ($StatusKicker.Text -eq 'STEP 2 OF 4') 'working: step 2'
    Assert-That ($StatusSubtitle.Text -like '*features*') 'working: features detail'
    Assert-That (-not $PrimaryButton.IsEnabled) 'working: primary disabled'
    Save-Shot '04-working'
    Save-Shot '04-working@2x' 2

    # 5. Restart countdown
    $countdownEvents = $restartEvents + @((New-TestEvent Action 'RESTART_SCHEDULED' 'Scheduled restart for verification attempt 1 of 2.' 'Save open work. At boot, approve the firmware prompt if Windows displays one.' 8))
    Set-Scenario (New-Snap -Task) $state1 $countdownEvents
    Assert-That ($StatusTitle.Text -like 'Restarting in * seconds.') "countdown: title ($($StatusTitle.Text))"
    Assert-That ($CancelRestartButton.IsVisible) 'countdown: cancel visible'
    Assert-That (@($GuideList.ItemsSource | Where-Object { $_.Text -like '*F3*' }).Count -eq 1) 'countdown: F3 guidance when firmware step staged'
    Save-Shot '05-restart-countdown'

    # 6. Waiting for a manual restart
    $manualEvents = $restartEvents + @((New-TestEvent Action 'MANUAL_RESTART_REQUIRED' 'All changes are staged and the continuation task is armed.' 'Restart Windows when ready. Approve the firmware prompt if one appears.' 20))
    Set-Scenario (New-Snap -Task -BootMinutesAgo 600) $state1 $manualEvents
    Assert-That ($StatusTitle.Text -eq 'Restart to continue.') 'waiting: title'
    Invoke-Primary
    Assert-That ($PrimaryText.Text -eq 'Click again to restart') 'waiting: restart needs a second click'
    Save-Shot '06-waiting-restart'
    $script:restartArmedUntil = [datetime]::MinValue

    # 7. Finishing after the restart
    Set-Scenario (New-Snap -Task -Engine -Continuation -Hypervisor $false -Vbs 0 -Cg $false -Hvci $false -BootMinutesAgo 2) $state1 ($manualEvents + @((New-TestEvent Info 'CONTINUATION_STARTED' 'Resumed automatically after restart for verification attempt 1 of 2.' '' 5)))
    Assert-That ($StatusTitle.Text -eq 'Finishing up...') 'finishing: title'
    Save-Shot '07-finishing'

    # 8. Done
    $doneState = [pscustomobject]@{ Attempt = 1; Completed = $true; UefiOptOutStaged = $true; RestorePointDescription = 'x' }
    $doneEvents = $manualEvents + @(
        (New-TestEvent Info 'CONTINUATION_STARTED' 'Resumed automatically after restart for verification attempt 1 of 2.' '' 50),
        (New-TestEvent Success 'BITLOCKER_RESUMED' 'Re-enabled OS-drive BitLocker protection.' '' 20),
        (New-TestEvent Success 'VERIFICATION_PASSED' 'Verification passed. Hyper-V and VBS are fully disabled in Windows.' '' 10)
    )
    Set-Scenario (New-Snap -Hypervisor $false -Vbs 0 -Cg $false -Hvci $false) $doneState $doneEvents
    Assert-That ($StatusTitle.Text -eq 'Hyper-V is off.' -and $PrimaryText.Text -eq 'Close') 'done: title and close'
    Save-Shot '08-done'
    Save-Shot '08-done@2x' 2

    Set-Scenario (New-Snap -Hypervisor $false -Vbs 0 -Cg $false -Hvci $false)
    Assert-That ($StatusKicker.Text -eq 'NOTHING TO DO') 'already off: kicker'
    Save-Shot '08b-already-off'

    # 9. Stopped early
    $failEvents = @(
        (New-TestEvent Info 'WORKFLOW_STARTED' 'Started the guarded Hyper-V and VBS disablement workflow.' '' 120),
        (New-TestEvent Error 'WORKFLOW_FAILED' 'Windows did not verify creation of a new System Restore point. No Hyper-V/VBS changes were made.' 'Open System Protection, enable protection for the OS drive, ensure at least 2 GB is available, then retry.' 90)
    )
    Set-Scenario (New-Snap) ([pscustomobject]@{ Attempt = 1; RunId = 't' }) $failEvents
    Assert-That ($StatusTitle.Text -eq 'The last run did not finish.') 'incomplete: title'
    Assert-That (@($GuideList.ItemsSource)[0].Detail -like 'Open System Protection*') 'incomplete: names the fix'
    Assert-That ($ActivityBadge.Visibility -eq 'Visible' -and $ActivityBadgeText.Text -eq '1') 'incomplete: failure badge'
    Save-Shot '09-incomplete'
    Save-Shot '09-incomplete@2x' 2

    # 10. Finished but still on
    $stillOnEvents = $doneEvents[0..($doneEvents.Count - 2)] + @((New-TestEvent Error 'VERIFICATION_FAILED' 'Verification failed: VBS is still enabled or running.' 'Run the operation again and approve the pre-boot firmware prompt. If it persists, disable Intel VT-x or AMD SVM in the vendor BIOS.' 10))
    Set-Scenario (New-Snap -Hypervisor $true -Vbs 2) $doneState $stillOnEvents
    Assert-That ($PrimaryText.Text -eq 'Run again') 'still on: run again'
    Save-Shot '10-finished-but-on'

    # 11. Windows Server
    Set-Scenario (New-Snap -Product 3)
    Assert-That (-not $PrimaryButton.IsEnabled) 'server: blocked'
    Save-Shot '11-unsupported'

    # 12. Activity
    Set-Scenario (New-Snap) ([pscustomobject]@{ Attempt = 1 }) ($restartEvents + $failEvents)
    Show-Page -Name 'Activity'
    Save-Shot '12-activity'
    $FailureFilter.IsChecked = $true
    Save-Shot '12b-activity-failed'
    $ActionFilter.IsChecked = $true
    $AllFilter.IsChecked = $true
    Set-Scenario (New-Snap)
    Save-Shot '12c-activity-empty'
    $support = Get-SupportText
    Assert-That ($support -like '*support details*') 'support text builds'

    # 13. Help
    Show-Page -Name 'Home'
    Set-Scenario (New-Snap)
    Open-Sheet -Name 'Help'
    Save-Shot '13-help'
    Close-Sheet

    # 14. Testing
    Set-TestingVisible $true
    Show-Page -Name 'Testing'
    $script:sync.Defender = @{ TamperProtection = 'On'; RealTimeProtection = 'On'; Service = 'Running'; TamperOn = $true }
    Update-DefenderStatusUI
    Save-Shot '14-testing'
    Set-TestingVisible $false
    Assert-That ($HomePanel.Visibility -eq 'Visible') 'testing: hiding returns to Home'

    # 15. Small window
    $window.Width = 980
    $window.Height = 660
    Wait-Ui 500
    Set-Scenario (New-Snap)
    Show-Toast 'Copied. Paste it into your support message.' 'Good'
    Save-Shot '15-small-ready'
    Assert-That (Test-FullyInside $PrimaryButton $window) 'small: primary button fully visible'
    Set-Scenario (New-Snap -Engine) $state1 $runEvents
    Save-Shot '15b-small-working'
    Set-Scenario (New-Snap -Battery -Domain $true)
    Invoke-Primary
    Save-Shot '15c-small-confirm'
    Assert-That (Test-FullyInside $ConfirmStart $window) 'small: confirm button fully visible'
    Close-Sheet

    # 16. Default size. The runner's screen is smaller than the window, so the
    # content is detached and laid out at 1180 x 780 on its own.
    $content = $window.Content
    $content.Resources = $window.Resources
    $window.Content = $null
    function Save-Detached {
        param([string] $Name)
        $content.Measure((New-Object Windows.Size 1180, 780))
        $content.Arrange((New-Object Windows.Rect 0, 0, 1180, 780))
        $content.UpdateLayout()
        $bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap 2360, 1560, 192, 192, ([Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($content)
        $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $stream = [IO.File]::Create((Join-Path $shotDir "$Name.png"))
        try { $encoder.Save($stream) } finally { $stream.Dispose() }
        Write-Host "shot: $Name.png (detached 1180 x 780 @2x)"
    }
    Show-Page -Name 'Home'
    Set-Scenario (New-Snap)
    Wait-Ui 300
    Save-Detached '16-large-ready@2x'
    Set-Scenario (New-Snap -Engine) $state1 $runEvents
    Wait-Ui 300
    Save-Detached '16b-large-working@2x'
    Set-Scenario (New-Snap -Hypervisor $false -Vbs 0 -Cg $false -Hvci $false) $doneState $doneEvents
    Wait-Ui 300
    Save-Detached '16c-large-done@2x'
}
catch {
    Assert-That $false ("scenario crashed: {0} at {1}" -f $_.Exception.Message, $_.InvocationInfo.PositionMessage)
}

$timer.Stop()
Stop-StatusPoller
try { $window.Close() } catch { }
if ($script:failures.Count) {
    Write-Host "$($script:failures.Count) check(s) failed:"
    $script:failures | ForEach-Object { Write-Host " - $_" }
    exit 1
}
Write-Host 'All UI checks passed.'
exit 0
