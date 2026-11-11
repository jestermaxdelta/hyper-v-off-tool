#requires -version 5.1
<#
.SYNOPSIS
Hyper-V Off Tool: the guided window that drives Disable-HyperV-Fully.ps1.

.DESCRIPTION
Shows what is running, tells the user exactly what to do next, collects an
explicit confirmation, then starts the engine. Live system checks run on a
background runspace so the window never stalls while Windows is queried.

.PARAMETER Resume
Used when the window reopens by itself after a restart.

.PARAMETER Testing
Shows the internal Testing page. Ctrl+Shift+T toggles it at any time.
#>
[CmdletBinding()]
param(
    [switch] $Resume,
    [switch] $Testing
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# The release workflow replaces 'dev' with the published version tag.
$script:AppVersion = 'dev'
$script:AppName = 'Hyper-V Off Tool'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-HasProperty {
    # StrictMode-safe property probe; works on objects with zero properties.
    param($InputObject, [Parameter(Mandatory = $true)][string] $Name)
    return ($null -ne $InputObject -and $null -ne $InputObject.PSObject.Properties[$Name])
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

function Show-Notice {
    param([string] $Text, [ValidateSet('Info', 'Warning', 'Error')][string] $Kind = 'Info')
    $image = switch ($Kind) {
        'Error' { [System.Windows.MessageBoxImage]::Error }
        'Warning' { [System.Windows.MessageBoxImage]::Warning }
        default { [System.Windows.MessageBoxImage]::Information }
    }
    [void][System.Windows.MessageBox]::Show($Text, $script:AppName, [System.Windows.MessageBoxButton]::OK, $image)
}

$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

if (-not (Test-IsAdministrator)) {
    $switches = ''
    if ($Resume) { $switches += ' -Resume' }
    if ($Testing) { $switches += ' -Testing' }
    $arguments = '-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"{1}' -f $PSCommandPath, $switches
    try {
        Start-Process -FilePath $windowsPowerShell -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -ErrorAction Stop | Out-Null
    }
    catch {
        Show-Notice ("Administrator approval is needed to turn off Hyper-V.`n`n" +
            'Open Start-HyperV-Off-Console.cmd again and choose Yes when Windows asks for permission.') 'Warning'
    }
    return
}

# One window at a time: a second copy could start a second engine run.
$script:instanceMutex = $null
try {
    $script:instanceMutex = New-Object System.Threading.Mutex($false, 'Global\HyperVOffConsole')
    $owned = $false
    try { $owned = $script:instanceMutex.WaitOne(0) }
    catch {
        # An abandoned mutex (previous window crashed) is ours to take over.
        $owned = ($_.Exception -is [System.Threading.AbandonedMutexException]) -or
                 ($_.Exception.InnerException -is [System.Threading.AbandonedMutexException])
    }
    if (-not $owned) {
        if (-not $Resume) { Show-Notice 'The Hyper-V Off Tool is already open. Look for it on the taskbar.' }
        return
    }
}
catch { $script:instanceMutex = $null }

$enginePath = Join-Path $PSScriptRoot 'Disable-HyperV-Fully.ps1'
$workRoot = Join-Path $env:ProgramData 'Disable-HyperV-Fully'
$eventLogPath = Join-Path $workRoot 'Operational-Events.jsonl'
$statePath = Join-Path $workRoot 'state.json'
$reportPath = Join-Path $workRoot 'Final-Status.txt'
$uiTracePath = Join-Path $workRoot 'Console-UI.log'
$defenderBackupPath = Join-Path $workRoot 'SecurityToggle-Backup.json'
$runOncePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
$runOnceName = 'HyperVOffConsole'
$continuationTaskName = 'Disable-HyperV-Fully-Continue'
$continuationTaskFile = Join-Path $env:SystemRoot "System32\Tasks\$continuationTaskName"

# The Testing page writes here even if the engine has never run, and
# Set-Content cannot create intermediate directories.
try { New-Item -ItemType Directory -Path $workRoot -Force -ErrorAction Stop | Out-Null } catch { }

if (-not (Test-Path -LiteralPath $enginePath)) {
    Show-Notice ("A required file is missing:`n$enginePath`n`n" +
        'Extract everything from the ZIP into one folder, then open Start-HyperV-Off-Console.cmd again.') 'Error'
    return
}

$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Hyper-V Off Tool" Width="1180" Height="780" MinWidth="960" MinHeight="640"
        WindowStartupLocation="CenterScreen" ResizeMode="CanResize" Background="#0A070E"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13" Foreground="#F4EEF8"
        TextOptions.TextFormattingMode="Display" UseLayoutRounding="True" SnapsToDevicePixels="True">
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="58" ResizeBorderThickness="6" CornerRadius="0" GlassFrameThickness="0,0,0,1" UseAeroCaptionButtons="False"/>
  </WindowChrome.WindowChrome>

  <Window.Resources>
    <!-- Palette: aubergine-black canvas, fuchsia to violet accent. -->
    <SolidColorBrush x:Key="AccentBrush" Color="#E063E8"/>
    <SolidColorBrush x:Key="AccentSoft" Color="#C58BE8"/>
    <SolidColorBrush x:Key="TextPrimary" Color="#F4EEF8"/>
    <SolidColorBrush x:Key="TextSecondary" Color="#B8ACC4"/>
    <SolidColorBrush x:Key="TextMuted" Color="#8C8097"/>
    <SolidColorBrush x:Key="TextFaint" Color="#655B70"/>
    <SolidColorBrush x:Key="CardBg" Color="#120D17"/>
    <SolidColorBrush x:Key="CardBgAlt" Color="#0E0A12"/>
    <SolidColorBrush x:Key="CardStroke" Color="#231A2B"/>
    <SolidColorBrush x:Key="Divider" Color="#1D1624"/>
    <SolidColorBrush x:Key="GoodBrush" Color="#4ADE9B"/>
    <SolidColorBrush x:Key="WarnBrush" Color="#F5B94F"/>
    <SolidColorBrush x:Key="BadBrush" Color="#FF6B81"/>
    <!-- State tone. Replaced at startup with animatable brushes; always referenced dynamically. -->
    <SolidColorBrush x:Key="HeroTone" Color="#E063E8"/>
    <SolidColorBrush x:Key="HeroToneDim" Color="#6EE063E8"/>
    <SolidColorBrush x:Key="HeroToneFaint" Color="#22E063E8"/>

    <FontFamily x:Key="DisplayFont">Segoe UI Variable Display, Segoe UI</FontFamily>
    <FontFamily x:Key="IconFont">Segoe Fluent Icons, Segoe MDL2 Assets</FontFamily>
    <FontFamily x:Key="MonoFont">Cascadia Mono, Consolas</FontFamily>

    <DropShadowEffect x:Key="PrimaryGlow" BlurRadius="24" ShadowDepth="0" Opacity="0.55" Color="#C23FD6"/>
    <DropShadowEffect x:Key="SoftGlow" BlurRadius="14" ShadowDepth="0" Opacity="0.6" Color="#C23FD6"/>
    <DropShadowEffect x:Key="CardShadow" BlurRadius="44" ShadowDepth="12" Opacity="0.6" Color="#000000"/>

    <LinearGradientBrush x:Key="PrimaryFill" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#E35BD9" Offset="0"/>
      <GradientStop Color="#9D4BEA" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="PrimaryFillHover" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#EE74E4" Offset="0"/>
      <GradientStop Color="#AE61F2" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="StepLineLit" StartPoint="0,0" EndPoint="1,0">
      <GradientStop Color="#E35BD9" Offset="0"/>
      <GradientStop Color="#9D4BEA" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="WindowFill" StartPoint="0,0" EndPoint="0,1">
      <GradientStop Color="#0D0911" Offset="0"/>
      <GradientStop Color="#09070C" Offset="0.6"/>
      <GradientStop Color="#08060A" Offset="1"/>
    </LinearGradientBrush>
    <RadialGradientBrush x:Key="TopGlow" Center="0.5,0" GradientOrigin="0.5,0" RadiusX="0.6" RadiusY="0.9">
      <GradientStop Color="#3AA2349C" Offset="0"/>
      <GradientStop Color="#145E2A8C" Offset="0.45"/>
      <GradientStop Color="#00000000" Offset="1"/>
    </RadialGradientBrush>
    <RadialGradientBrush x:Key="AuroraLow" Center="0.08,1" GradientOrigin="0.08,1" RadiusX="0.55" RadiusY="0.7">
      <GradientStop Color="#1C5B2AA0" Offset="0"/>
      <GradientStop Color="#00000000" Offset="1"/>
    </RadialGradientBrush>
    <LinearGradientBrush x:Key="HeroFill" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#191020" Offset="0"/>
      <GradientStop Color="#120C17" Offset="0.55"/>
      <GradientStop Color="#0F0A13" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="HeroStroke" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#4A2E57" Offset="0"/>
      <GradientStop Color="#231A2B" Offset="0.5"/>
      <GradientStop Color="#1E1725" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="CardStrokeLit" StartPoint="0,0" EndPoint="0,1">
      <GradientStop Color="#2F2439" Offset="0"/>
      <GradientStop Color="#1C1523" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="SheetFill" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#1B1222" Offset="0"/>
      <GradientStop Color="#120C17" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="NavActiveFill" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#2A1736" Offset="0"/>
      <GradientStop Color="#1C1225" Offset="1"/>
    </LinearGradientBrush>
    <RadialGradientBrush x:Key="OrbCoreFill" Center="0.4,0.35" GradientOrigin="0.4,0.35" RadiusX="0.7" RadiusY="0.7">
      <GradientStop Color="#261A30" Offset="0"/>
      <GradientStop Color="#110B16" Offset="1"/>
    </RadialGradientBrush>
    <DrawingBrush x:Key="DotGrid" TileMode="Tile" Viewport="0,0,18,18" ViewportUnits="Absolute" Opacity="0.07">
      <DrawingBrush.Drawing>
        <GeometryDrawing Brush="#FFFFFF">
          <GeometryDrawing.Geometry><EllipseGeometry Center="1,1" RadiusX="0.9" RadiusY="0.9"/></GeometryDrawing.Geometry>
        </GeometryDrawing>
      </DrawingBrush.Drawing>
    </DrawingBrush>

    <!-- Text -->
    <Style x:Key="PageTitle" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="{StaticResource DisplayFont}"/>
      <Setter Property="FontSize" Value="28"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
      <Setter Property="TextOptions.TextFormattingMode" Value="Ideal"/>
    </Style>
    <Style x:Key="Kicker" TargetType="TextBlock">
      <Setter Property="FontSize" Value="10.5"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Foreground" Value="{StaticResource AccentBrush}"/>
    </Style>
    <Style x:Key="Section" TargetType="TextBlock">
      <Setter Property="FontSize" Value="10.5"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Foreground" Value="{StaticResource TextFaint}"/>
    </Style>
    <Style x:Key="CardTitle" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="{StaticResource DisplayFont}"/>
      <Setter Property="FontSize" Value="15.5"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
      <Setter Property="TextOptions.TextFormattingMode" Value="Ideal"/>
    </Style>
    <Style x:Key="Body" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource TextMuted}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="LineHeight" Value="18"/>
    </Style>
    <Style x:Key="RowLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource TextMuted}"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="RowValue" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#DCD2E6"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="CornerRadius" Value="18"/>
      <Setter Property="Background" Value="{StaticResource CardBg}"/>
      <Setter Property="BorderBrush" Value="{StaticResource CardStrokeLit}"/>
      <Setter Property="BorderThickness" Value="1"/>
    </Style>
    <Style x:Key="Chip" TargetType="Border">
      <Setter Property="CornerRadius" Value="999"/>
      <Setter Property="Padding" Value="11,4"/>
      <Setter Property="BorderThickness" Value="1"/>
    </Style>
    <Style x:Key="OffChip" TargetType="Border">
      <Setter Property="CornerRadius" Value="999"/>
      <Setter Property="Padding" Value="11,5"/>
      <Setter Property="Margin" Value="0,0,6,6"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Background" Value="#1C1323"/>
      <Setter Property="BorderBrush" Value="#35263F"/>
    </Style>

    <!-- Buttons -->
    <Style x:Key="GhostButton" TargetType="Button">
      <Setter Property="Foreground" Value="#DCD2E6"/>
      <Setter Property="Background" Value="#16101C"/>
      <Setter Property="BorderBrush" Value="#2C2236"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="16,10"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Chrome" CornerRadius="11" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="#20172A"/>
                <Setter TargetName="Chrome" Property="BorderBrush" Value="#4A3358"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="#140E19"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Chrome" Property="BorderBrush" Value="#C46BE6"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Chrome" Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SmallGhost" TargetType="Button" BasedOn="{StaticResource GhostButton}">
      <Setter Property="Padding" Value="12,7"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>
    <Style x:Key="DangerButton" TargetType="Button" BasedOn="{StaticResource GhostButton}">
      <Setter Property="Foreground" Value="#FFB3C0"/>
      <Setter Property="Background" Value="#1E0F15"/>
      <Setter Property="BorderBrush" Value="#4E2230"/>
    </Style>

    <Style x:Key="ChromeButton" TargetType="Button">
      <Setter Property="Foreground" Value="#9C90A8"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="FontFamily" Value="{StaticResource IconFont}"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="Width" Value="42"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Chrome" CornerRadius="9" Background="{TemplateBinding Background}" BorderThickness="1" BorderBrush="Transparent">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="#1C1424"/>
                <Setter Property="Foreground" Value="#F4EEF8"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Chrome" Property="BorderBrush" Value="#C46BE6"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="CloseChromeButton" TargetType="Button" BasedOn="{StaticResource ChromeButton}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Chrome" CornerRadius="9" Background="Transparent" BorderThickness="1" BorderBrush="Transparent">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="#C42B4A"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Chrome" Property="BorderBrush" Value="#C46BE6"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="PrimaryButton" TargetType="Button">
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="Background" Value="{StaticResource PrimaryFill}"/>
      <Setter Property="Padding" Value="24,12"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border x:Name="Glow" CornerRadius="12" Background="{StaticResource PrimaryFill}" Effect="{StaticResource PrimaryGlow}" Opacity="0.7"/>
              <Border x:Name="Chrome" CornerRadius="12" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}"
                      BorderThickness="1" BorderBrush="#40FFFFFF">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="{StaticResource PrimaryFillHover}"/>
                <Setter TargetName="Glow" Property="Opacity" Value="1"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Chrome" Property="Opacity" Value="0.86"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Chrome" Property="BorderBrush" Value="#FFFFFF"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Chrome" Property="Background" Value="#211829"/>
                <Setter TargetName="Chrome" Property="BorderBrush" Value="#30253A"/>
                <Setter TargetName="Glow" Property="Visibility" Value="Collapsed"/>
                <Setter Property="Foreground" Value="#85798F"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="LinkButton" TargetType="Button">
      <Setter Property="Foreground" Value="#C58BE8"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="LinkChrome" Background="{TemplateBinding Background}" CornerRadius="10" Padding="10,7" BorderThickness="1" BorderBrush="Transparent">
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="LinkChrome" Property="Background" Value="#14FFFFFF"/>
                <Setter Property="Foreground" Value="#F0B8F5"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="LinkChrome" Property="BorderBrush" Value="#C46BE6"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Navigation and filters -->
    <Style x:Key="NavTab" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#9C90A8"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="NavChrome" CornerRadius="9" Background="{TemplateBinding Background}" BorderBrush="Transparent" BorderThickness="1" Padding="{TemplateBinding Padding}">
              <StackPanel Orientation="Horizontal">
                <TextBlock x:Name="NavGlyph" Text="{TemplateBinding Tag}" FontFamily="{StaticResource IconFont}" FontSize="13" VerticalAlignment="Center"/>
                <ContentPresenter Margin="9,0,0,0" VerticalAlignment="Center"/>
              </StackPanel>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="NavChrome" Property="Background" Value="#170F1C"/>
                <Setter Property="Foreground" Value="#DCD2E6"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="NavChrome" Property="Background" Value="{StaticResource NavActiveFill}"/>
                <Setter TargetName="NavChrome" Property="BorderBrush" Value="#3A2848"/>
                <Setter Property="Foreground" Value="#F4EEF8"/>
                <Setter TargetName="NavGlyph" Property="Foreground" Value="{StaticResource AccentBrush}"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="NavChrome" Property="BorderBrush" Value="#C46BE6"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="FilterRadio" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#8E829A"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="FilterChrome" CornerRadius="8" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}" BorderThickness="1" BorderBrush="Transparent">
              <ContentPresenter HorizontalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter Property="Foreground" Value="#D8CEE2"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="FilterChrome" Property="Background" Value="#261932"/>
                <Setter Property="Foreground" Value="#F4EEF8"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="FilterChrome" Property="BorderBrush" Value="#C46BE6"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Inputs -->
    <Style x:Key="Toggle" TargetType="CheckBox">
      <Setter Property="Width" Value="50"/>
      <Setter Property="Height" Value="28"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid>
              <Border x:Name="Track" CornerRadius="14" Background="#1D1524" BorderBrush="#34283F" BorderThickness="1"/>
              <Border x:Name="TrackOn" CornerRadius="14" Background="{StaticResource PrimaryFill}" Opacity="0"/>
              <Ellipse x:Name="Thumb" Width="20" Height="20" Fill="#8E829A" HorizontalAlignment="Left" Margin="4,0,0,0">
                <Ellipse.RenderTransform><TranslateTransform X="0"/></Ellipse.RenderTransform>
              </Ellipse>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Thumb" Property="Fill" Value="#FFFFFF"/>
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="Thumb" Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" To="22" Duration="0:0:0.18">
                        <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                      </DoubleAnimation>
                      <DoubleAnimation Storyboard.TargetName="TrackOn" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.18"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="Thumb" Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" To="0" Duration="0:0:0.18">
                        <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                      </DoubleAnimation>
                      <DoubleAnimation Storyboard.TargetName="TrackOn" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.18"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Track" Property="BorderBrush" Value="#C46BE6"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.42"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="CheckRow" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#EDE5F4"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="Row" CornerRadius="13" Background="#100B14" BorderBrush="#251C2D" BorderThickness="1" Padding="15,13">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Grid Width="22" Height="22" VerticalAlignment="Top" Margin="0,1,0,0">
                  <Border x:Name="Box" CornerRadius="7" Background="#1A1220" BorderBrush="#4A3A58" BorderThickness="1.5"/>
                  <Border x:Name="BoxOn" CornerRadius="7" Background="{StaticResource PrimaryFill}" Opacity="0"/>
                  <TextBlock x:Name="Tick" Text="&#xE73E;" FontFamily="{StaticResource IconFont}" FontSize="12" Foreground="#FFFFFF"
                             HorizontalAlignment="Center" VerticalAlignment="Center" Opacity="0"/>
                </Grid>
                <ContentPresenter Grid.Column="1" Margin="14,0,0,0" VerticalAlignment="Center"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Row" Property="BorderBrush" Value="#3A2B47"/>
                <Setter TargetName="Box" Property="BorderBrush" Value="#7A5A92"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="BoxOn" Property="Opacity" Value="1"/>
                <Setter TargetName="Tick" Property="Opacity" Value="1"/>
                <Setter TargetName="Row" Property="Background" Value="#170F1D"/>
                <Setter TargetName="Row" Property="BorderBrush" Value="#5A3470"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Row" Property="BorderBrush" Value="#C46BE6"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Thin dark scrollbars so nothing flashes Windows-grey. -->
    <Style TargetType="Thumb" x:Key="ScrollThumb">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border x:Name="ThumbChrome" CornerRadius="3" Background="#33263E"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ThumbChrome" Property="Background" Value="#5A3F6E"/></Trigger>
              <Trigger Property="IsDragging" Value="True"><Setter TargetName="ThumbChrome" Property="Background" Value="#8B55B0"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="6"/>
      <Setter Property="MinWidth" Value="6"/>
      <Setter Property="Margin" Value="4,4,0,4"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.Thumb><Thumb Style="{StaticResource ScrollThumb}"/></Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="6"/>
          <Setter Property="Margin" Value="4,4,4,0"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ScrollBar">
                <Track x:Name="PART_Track">
                  <Track.Thumb><Thumb Style="{StaticResource ScrollThumb}"/></Track.Thumb>
                </Track>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style TargetType="ToolTip">
      <Setter Property="Foreground" Value="#E8DFF0"/>
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToolTip">
            <Border Background="#1A1220" BorderBrush="#3A2B47" BorderThickness="1" CornerRadius="8" Padding="10,7">
              <ContentPresenter/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border x:Name="RootBorder" Background="{StaticResource WindowFill}" BorderBrush="#251C2D" BorderThickness="1">
    <Grid>
      <Border Background="{StaticResource TopGlow}" Height="420" VerticalAlignment="Top" IsHitTestVisible="False"/>
      <Border Background="{StaticResource AuroraLow}" IsHitTestVisible="False"/>

      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="58"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Title bar: brand, navigation, window buttons. Dragging is handled by WindowChrome. -->
        <Grid Grid.Row="0" Margin="20,0,10,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <Grid Width="32" Height="32">
              <Border CornerRadius="10" Background="{StaticResource PrimaryFill}" Effect="{StaticResource SoftGlow}" Opacity="0.65"/>
              <Border CornerRadius="10" Background="{StaticResource PrimaryFill}" BorderBrush="#50FFFFFF" BorderThickness="1">
                <TextBlock Text="&#xE7E8;" FontFamily="{StaticResource IconFont}" FontSize="14" Foreground="#FFFFFF"
                           HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
            </Grid>
            <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
              <TextBlock FontFamily="{StaticResource DisplayFont}" FontWeight="Bold" FontSize="14.5">
                <Run Text="Hyper-V Off"/><Run Text="." Foreground="{StaticResource AccentBrush}"/>
              </TextBlock>
              <TextBlock x:Name="BrandSubtitle" Text="Administrator" Foreground="{StaticResource TextFaint}" FontSize="11" Margin="0,1,0,0" TextTrimming="CharacterEllipsis"/>
            </StackPanel>
          </StackPanel>

          <Border Grid.Column="1" CornerRadius="12" Background="#B3120D17" BorderBrush="#241B2C" BorderThickness="1" Padding="3"
                  VerticalAlignment="Center" WindowChrome.IsHitTestVisibleInChrome="True">
            <StackPanel Orientation="Horizontal">
              <RadioButton x:Name="NavHome" Content="Home" Tag="&#xE80F;" GroupName="Navigation" IsChecked="True" Style="{StaticResource NavTab}"
                           ToolTip="Status and next steps (Ctrl+1)"/>
              <RadioButton x:Name="NavActivity" GroupName="Navigation" Tag="&#xE9D9;" Style="{StaticResource NavTab}" ToolTip="Everything the tool did (Ctrl+2)">
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="Activity"/>
                  <Border x:Name="ActivityBadge" Visibility="Collapsed" CornerRadius="999" Background="#3A1420" BorderBrush="#6B2438" BorderThickness="1" Padding="6,0" Margin="8,0,0,0" VerticalAlignment="Center">
                    <TextBlock x:Name="ActivityBadgeText" Text="0" Foreground="#FF8FA2" FontSize="10.5" FontWeight="Bold"/>
                  </Border>
                </StackPanel>
              </RadioButton>
              <RadioButton x:Name="NavTesting" GroupName="Navigation" Tag="&#xE90F;" Style="{StaticResource NavTab}" Visibility="Collapsed" ToolTip="Internal test helpers (Ctrl+Shift+T)">
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="Testing"/>
                  <Border CornerRadius="5" Background="#1D1524" BorderBrush="#34283F" BorderThickness="1" Padding="5,0" Margin="8,0,0,0" VerticalAlignment="Center">
                    <TextBlock Text="DEV" Foreground="{StaticResource TextMuted}" FontSize="9" FontWeight="Bold"/>
                  </Border>
                </StackPanel>
              </RadioButton>
            </StackPanel>
          </Border>

          <StackPanel Grid.Column="2" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" WindowChrome.IsHitTestVisibleInChrome="True">
            <Button x:Name="HelpButton" Style="{StaticResource LinkButton}" Margin="0,0,8,0" ToolTip="How it works, and how to undo it (F1)" AutomationProperties.Name="Help">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#xE897;" FontFamily="{StaticResource IconFont}" FontSize="13" VerticalAlignment="Center"/>
                <TextBlock Text="Help" Margin="7,0,0,0" FontWeight="SemiBold" FontSize="12.5" VerticalAlignment="Center"/>
              </StackPanel>
            </Button>
            <Button x:Name="MinimizeButton" Content="&#xE921;" Style="{StaticResource ChromeButton}" Margin="0,0,2,0" ToolTip="Minimize" AutomationProperties.Name="Minimize"/>
            <Button x:Name="MaximizeButton" Content="&#xE922;" Style="{StaticResource ChromeButton}" Margin="0,0,2,0" ToolTip="Maximize" AutomationProperties.Name="Maximize"/>
            <Button x:Name="CloseButton" Content="&#xE8BB;" Style="{StaticResource CloseChromeButton}" ToolTip="Close. Work that has started keeps going." AutomationProperties.Name="Close"/>
          </StackPanel>
        </Grid>

        <!-- Pages -->
        <Grid x:Name="PageHost" Grid.Row="1" Margin="20,4,20,0">
          <Grid.RenderTransform><TranslateTransform Y="0"/></Grid.RenderTransform>

          <!-- Home -->
          <Grid x:Name="HomePanel">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="16"/>
              <ColumnDefinition Width="320"/>
            </Grid.ColumnDefinitions>

            <Border Grid.Column="0" CornerRadius="20" Background="{StaticResource HeroFill}" BorderBrush="{StaticResource HeroStroke}" BorderThickness="1" ClipToBounds="True">
              <Grid>
                <Grid.RowDefinitions>
                  <RowDefinition Height="*"/>
                  <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <Border x:Name="HeroAmbient" Grid.RowSpan="2" CornerRadius="20" IsHitTestVisible="False"/>
                <Border Grid.RowSpan="2" Background="{StaticResource DotGrid}" CornerRadius="20" IsHitTestVisible="False">
                  <Border.OpacityMask>
                    <RadialGradientBrush Center="1,0" GradientOrigin="1,0" RadiusX="0.9" RadiusY="1">
                      <GradientStop Color="#FF000000" Offset="0"/>
                      <GradientStop Color="#00000000" Offset="1"/>
                    </RadialGradientBrush>
                  </Border.OpacityMask>
                </Border>

                <ScrollViewer Grid.Row="0" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="0,0,4,0">
                  <Grid Margin="30,28,26,20">
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="Auto"/>
                      <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>

                    <!-- Status orb: glows while Hyper-V is on, spins while working, settles green when off. -->
                    <Grid Width="184" Height="184" VerticalAlignment="Top" Margin="0,2,30,0" IsHitTestVisible="False">
                      <Ellipse x:Name="OrbGlow" Width="184" Height="184" Opacity="0.9"/>
                      <Ellipse Width="176" Height="176" Stroke="#24FFFFFF" StrokeThickness="1" StrokeDashArray="1 5"/>
                      <Ellipse Width="148" Height="148" Stroke="#2A2032" StrokeThickness="3"/>
                      <Ellipse x:Name="OrbRingFull" Width="148" Height="148" Stroke="{DynamicResource HeroToneDim}" StrokeThickness="3"/>
                      <Path x:Name="OrbArc" Width="148" Height="148" Stretch="None" Stroke="{DynamicResource HeroTone}" StrokeThickness="3"
                            StrokeStartLineCap="Round" StrokeEndLineCap="Round" Data="M 74,1.5 A 72.5,72.5 0 0 1 146.5,74"
                            RenderTransformOrigin="0.5,0.5" Visibility="Collapsed">
                        <Path.RenderTransform><RotateTransform Angle="0"/></Path.RenderTransform>
                      </Path>
                      <Ellipse Width="112" Height="112" Fill="{StaticResource OrbCoreFill}" Stroke="{DynamicResource HeroToneDim}" StrokeThickness="1"/>
                      <TextBlock x:Name="OrbGlyph" Text="&#xE721;" FontFamily="{StaticResource IconFont}" FontSize="38" Foreground="{DynamicResource HeroTone}"
                                 HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Grid>

                    <StackPanel Grid.Column="1">
                      <Grid>
                        <TextBlock x:Name="StatusKicker" Text="ONE MOMENT" Style="{StaticResource Kicker}" Foreground="{DynamicResource HeroTone}" VerticalAlignment="Center"/>
                        <Border x:Name="StatusPill" Style="{StaticResource Chip}" Background="{DynamicResource HeroToneFaint}" BorderBrush="{DynamicResource HeroToneDim}" HorizontalAlignment="Right">
                          <StackPanel Orientation="Horizontal">
                            <Ellipse Width="7" Height="7" Fill="{DynamicResource HeroTone}" VerticalAlignment="Center"/>
                            <TextBlock x:Name="StatusPillText" Text="CHECKING" Foreground="#F4EEF8" FontSize="10.5" FontWeight="Bold" Margin="7,0,0,0" VerticalAlignment="Center"/>
                          </StackPanel>
                        </Border>
                      </Grid>
                      <TextBlock x:Name="StatusTitle" Text="Checking this PC..." Style="{StaticResource PageTitle}" FontSize="34" Margin="0,10,0,0" TextWrapping="Wrap" LineHeight="40"/>
                      <TextBlock x:Name="StatusSubtitle" Text="Reading the current Hyper-V and security settings. Nothing is changed."
                                 Foreground="{StaticResource TextSecondary}" FontSize="13.5" TextWrapping="Wrap" Margin="0,8,0,0" MaxWidth="600" HorizontalAlignment="Left" LineHeight="21"/>

                      <Border x:Name="GuideCard" CornerRadius="16" Background="#A60C0910" BorderBrush="#2A1F33" BorderThickness="1" Padding="20,16,20,8" Margin="0,22,0,0">
                        <StackPanel>
                          <StackPanel Orientation="Horizontal">
                            <TextBlock Text="&#xE8FB;" FontFamily="{StaticResource IconFont}" FontSize="11" Foreground="{DynamicResource HeroTone}" VerticalAlignment="Center"/>
                            <TextBlock x:Name="GuideHeader" Text="WHAT TO DO NOW" Style="{StaticResource Section}" Foreground="#B8ACC4" Margin="8,0,0,0" VerticalAlignment="Center"/>
                          </StackPanel>
                          <ItemsControl x:Name="GuideList" Margin="0,14,0,0" Focusable="False">
                            <ItemsControl.ItemTemplate>
                              <DataTemplate>
                                <Grid Margin="0,0,0,12">
                                  <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                  </Grid.ColumnDefinitions>
                                  <Border Width="24" Height="24" CornerRadius="12" Background="{Binding BadgeBackground}" BorderBrush="{Binding BadgeStroke}" BorderThickness="1" VerticalAlignment="Top">
                                    <TextBlock Text="{Binding Index}" FontSize="11" FontWeight="Bold" Foreground="{Binding Accent}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                  </Border>
                                  <StackPanel Grid.Column="1" Margin="13,2,0,0">
                                    <TextBlock Text="{Binding Text}" Foreground="#F1EAF6" FontWeight="SemiBold" TextWrapping="Wrap" LineHeight="19"/>
                                    <TextBlock Text="{Binding Detail}" Visibility="{Binding DetailVisibility}" Foreground="#9A8EA6" FontSize="12" TextWrapping="Wrap" LineHeight="18" Margin="0,2,0,0"/>
                                  </StackPanel>
                                </Grid>
                              </DataTemplate>
                            </ItemsControl.ItemTemplate>
                          </ItemsControl>
                        </StackPanel>
                      </Border>
                    </StackPanel>
                  </Grid>
                </ScrollViewer>

                <!-- Journey -->
                <Border Grid.Row="1" BorderBrush="#1F1726" BorderThickness="0,1,0,0" Background="#4D07050A" Padding="22,18,22,12">
                  <StackPanel>
                    <Grid>
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="*"/>
                      </Grid.ColumnDefinitions>

                      <Grid Grid.Column="0">
                        <Grid.RowDefinitions><RowDefinition Height="36"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <Rectangle x:Name="Step1LineL" Grid.Column="0" Height="2" VerticalAlignment="Center" Fill="#2A2032" Visibility="Hidden"/>
                        <Rectangle x:Name="Step1LineR" Grid.Column="1" Height="2" VerticalAlignment="Center" Fill="#2A2032"/>
                        <Ellipse x:Name="Step1Pulse" Grid.ColumnSpan="2" Width="34" Height="34" Stroke="{DynamicResource HeroTone}" StrokeThickness="1.5" Opacity="0" RenderTransformOrigin="0.5,0.5">
                          <Ellipse.RenderTransform><ScaleTransform ScaleX="1" ScaleY="1"/></Ellipse.RenderTransform>
                        </Ellipse>
                        <Border x:Name="Step1Dot" Grid.ColumnSpan="2" Width="34" Height="34" CornerRadius="17" BorderThickness="1.5" Background="#140E19" BorderBrush="#34283F">
                          <TextBlock x:Name="Step1Mark" Text="1" FontWeight="Bold" FontSize="12.5" Foreground="#85798F" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <TextBlock Grid.Row="1" Grid.ColumnSpan="2" Text="Back up" FontWeight="SemiBold" Foreground="#EDE5F4" HorizontalAlignment="Center" Margin="0,9,0,0"/>
                        <TextBlock x:Name="Step1Caption" Grid.Row="2" Grid.ColumnSpan="2" Text="Restore point" FontSize="11.5" Foreground="#85798F" HorizontalAlignment="Center" TextTrimming="CharacterEllipsis" Margin="4,2,4,0"/>
                      </Grid>

                      <Grid Grid.Column="1">
                        <Grid.RowDefinitions><RowDefinition Height="36"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <Rectangle x:Name="Step2LineL" Grid.Column="0" Height="2" VerticalAlignment="Center" Fill="#2A2032"/>
                        <Rectangle x:Name="Step2LineR" Grid.Column="1" Height="2" VerticalAlignment="Center" Fill="#2A2032"/>
                        <Ellipse x:Name="Step2Pulse" Grid.ColumnSpan="2" Width="34" Height="34" Stroke="{DynamicResource HeroTone}" StrokeThickness="1.5" Opacity="0" RenderTransformOrigin="0.5,0.5">
                          <Ellipse.RenderTransform><ScaleTransform ScaleX="1" ScaleY="1"/></Ellipse.RenderTransform>
                        </Ellipse>
                        <Border x:Name="Step2Dot" Grid.ColumnSpan="2" Width="34" Height="34" CornerRadius="17" BorderThickness="1.5" Background="#140E19" BorderBrush="#34283F">
                          <TextBlock x:Name="Step2Mark" Text="2" FontWeight="Bold" FontSize="12.5" Foreground="#85798F" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <TextBlock Grid.Row="1" Grid.ColumnSpan="2" Text="Turn off" FontWeight="SemiBold" Foreground="#EDE5F4" HorizontalAlignment="Center" Margin="0,9,0,0"/>
                        <TextBlock x:Name="Step2Caption" Grid.Row="2" Grid.ColumnSpan="2" Text="Hyper-V, VBS, PIN" FontSize="11.5" Foreground="#85798F" HorizontalAlignment="Center" TextTrimming="CharacterEllipsis" Margin="4,2,4,0"/>
                      </Grid>

                      <Grid Grid.Column="2">
                        <Grid.RowDefinitions><RowDefinition Height="36"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <Rectangle x:Name="Step3LineL" Grid.Column="0" Height="2" VerticalAlignment="Center" Fill="#2A2032"/>
                        <Rectangle x:Name="Step3LineR" Grid.Column="1" Height="2" VerticalAlignment="Center" Fill="#2A2032"/>
                        <Ellipse x:Name="Step3Pulse" Grid.ColumnSpan="2" Width="34" Height="34" Stroke="{DynamicResource HeroTone}" StrokeThickness="1.5" Opacity="0" RenderTransformOrigin="0.5,0.5">
                          <Ellipse.RenderTransform><ScaleTransform ScaleX="1" ScaleY="1"/></Ellipse.RenderTransform>
                        </Ellipse>
                        <Border x:Name="Step3Dot" Grid.ColumnSpan="2" Width="34" Height="34" CornerRadius="17" BorderThickness="1.5" Background="#140E19" BorderBrush="#34283F">
                          <TextBlock x:Name="Step3Mark" Text="3" FontWeight="Bold" FontSize="12.5" Foreground="#85798F" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <TextBlock Grid.Row="1" Grid.ColumnSpan="2" Text="Restart" FontWeight="SemiBold" Foreground="#EDE5F4" HorizontalAlignment="Center" Margin="0,9,0,0"/>
                        <TextBlock x:Name="Step3Caption" Grid.Row="2" Grid.ColumnSpan="2" Text="Up to two" FontSize="11.5" Foreground="#85798F" HorizontalAlignment="Center" TextTrimming="CharacterEllipsis" Margin="4,2,4,0"/>
                      </Grid>

                      <Grid Grid.Column="3">
                        <Grid.RowDefinitions><RowDefinition Height="36"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <Rectangle x:Name="Step4LineL" Grid.Column="0" Height="2" VerticalAlignment="Center" Fill="#2A2032"/>
                        <Rectangle x:Name="Step4LineR" Grid.Column="1" Height="2" VerticalAlignment="Center" Fill="#2A2032" Visibility="Hidden"/>
                        <Ellipse x:Name="Step4Pulse" Grid.ColumnSpan="2" Width="34" Height="34" Stroke="{DynamicResource HeroTone}" StrokeThickness="1.5" Opacity="0" RenderTransformOrigin="0.5,0.5">
                          <Ellipse.RenderTransform><ScaleTransform ScaleX="1" ScaleY="1"/></Ellipse.RenderTransform>
                        </Ellipse>
                        <Border x:Name="Step4Dot" Grid.ColumnSpan="2" Width="34" Height="34" CornerRadius="17" BorderThickness="1.5" Background="#140E19" BorderBrush="#34283F">
                          <TextBlock x:Name="Step4Mark" Text="4" FontWeight="Bold" FontSize="12.5" Foreground="#85798F" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <TextBlock Grid.Row="1" Grid.ColumnSpan="2" Text="Verify" FontWeight="SemiBold" Foreground="#EDE5F4" HorizontalAlignment="Center" Margin="0,9,0,0"/>
                        <TextBlock x:Name="Step4Caption" Grid.Row="2" Grid.ColumnSpan="2" Text="Confirm all off" FontSize="11.5" Foreground="#85798F" HorizontalAlignment="Center" TextTrimming="CharacterEllipsis" Margin="4,2,4,0"/>
                      </Grid>
                    </Grid>

                    <Button x:Name="LatestButton" Style="{StaticResource LinkButton}" HorizontalContentAlignment="Stretch" Margin="-2,12,-2,0" Visibility="Collapsed" ToolTip="Open the Activity page">
                      <Grid>
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="Auto"/>
                          <ColumnDefinition Width="*"/>
                          <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <Border CornerRadius="6" Background="#1C1424" BorderBrush="#2E2238" BorderThickness="1" Padding="7,1" VerticalAlignment="Center">
                          <TextBlock Text="LATEST" FontSize="9.5" FontWeight="Bold" Foreground="#9C90A8"/>
                        </Border>
                        <TextBlock x:Name="LatestText" Grid.Column="1" Margin="10,0,10,0" Foreground="#B8ACC4" FontSize="12" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
                        <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                          <TextBlock x:Name="LatestTime" FontFamily="{StaticResource MonoFont}" FontSize="11" Foreground="#6E6379" VerticalAlignment="Center"/>
                          <TextBlock Text="&#xE76C;" FontFamily="{StaticResource IconFont}" FontSize="10" Margin="10,0,0,0" VerticalAlignment="Center"/>
                        </StackPanel>
                      </Grid>
                    </Button>
                  </StackPanel>
                </Border>
              </Grid>
            </Border>

            <ScrollViewer Grid.Column="2" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
              <StackPanel>
                <Border Style="{StaticResource Card}" Padding="22,18,22,10">
                  <StackPanel>
                    <Grid Margin="0,0,0,8">
                      <TextBlock Text="Live check" Style="{StaticResource CardTitle}"/>
                      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" ToolTip="Refreshes every few seconds in the background">
                        <Ellipse x:Name="LiveDot" Width="6" Height="6" Fill="{StaticResource GoodBrush}" VerticalAlignment="Center"/>
                        <TextBlock Text="LIVE" Foreground="{StaticResource TextMuted}" FontSize="10" FontWeight="Bold" Margin="6,0,0,0"/>
                      </StackPanel>
                    </Grid>

                    <Grid Height="40" ToolTip="The Microsoft virtualization layer that Hyper-V, VBS and WSL 2 run on.">
                      <TextBlock Text="Hypervisor" Style="{StaticResource RowLabel}"/>
                      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                        <Ellipse x:Name="HvDot" Width="7" Height="7" Fill="#62586C" VerticalAlignment="Center"/>
                        <TextBlock x:Name="HvValue" Text="Checking" Style="{StaticResource RowValue}" Margin="8,0,0,0"/>
                      </StackPanel>
                    </Grid>
                    <Rectangle Height="1" Fill="{StaticResource Divider}"/>
                    <Grid Height="40" ToolTip="Virtualization-based security: runs parts of Windows inside the hypervisor.">
                      <TextBlock Text="VBS" Style="{StaticResource RowLabel}"/>
                      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                        <Ellipse x:Name="VbsDot" Width="7" Height="7" Fill="#62586C" VerticalAlignment="Center"/>
                        <TextBlock x:Name="VbsValue" Text="Checking" Style="{StaticResource RowValue}" Margin="8,0,0,0"/>
                      </StackPanel>
                    </Grid>
                    <Rectangle Height="1" Fill="{StaticResource Divider}"/>
                    <Grid Height="40" ToolTip="Protects sign-in secrets using VBS.">
                      <TextBlock Text="Credential Guard" Style="{StaticResource RowLabel}"/>
                      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                        <Ellipse x:Name="CgDot" Width="7" Height="7" Fill="#62586C" VerticalAlignment="Center"/>
                        <TextBlock x:Name="CgValue" Text="Checking" Style="{StaticResource RowValue}" Margin="8,0,0,0"/>
                      </StackPanel>
                    </Grid>
                    <Rectangle Height="1" Fill="{StaticResource Divider}"/>
                    <Grid Height="40" ToolTip="Also called HVCI or Core isolation. Uses VBS to check drivers.">
                      <TextBlock Text="Memory Integrity" Style="{StaticResource RowLabel}"/>
                      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                        <Ellipse x:Name="HvciDot" Width="7" Height="7" Fill="#62586C" VerticalAlignment="Center"/>
                        <TextBlock x:Name="HvciValue" Text="Checking" Style="{StaticResource RowValue}" Margin="8,0,0,0"/>
                      </StackPanel>
                    </Grid>
                    <Rectangle Height="1" Fill="{StaticResource Divider}"/>
                    <Grid Height="40" ToolTip="If BitLocker is on, it is paused for at most two restarts and then turned back on automatically.">
                      <TextBlock Text="BitLocker" Style="{StaticResource RowLabel}"/>
                      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                        <Ellipse x:Name="BitLockerDot" Width="7" Height="7" Fill="#62586C" VerticalAlignment="Center"/>
                        <TextBlock x:Name="BitLockerValue" Text="Checking" Style="{StaticResource RowValue}" Margin="8,0,0,0"/>
                      </StackPanel>
                    </Grid>
                    <Rectangle Height="1" Fill="{StaticResource Divider}"/>
                    <Grid Height="40" ToolTip="Work or school PCs can have policies that turn VBS back on.">
                      <TextBlock Text="Managed by" Style="{StaticResource RowLabel}"/>
                      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                        <Ellipse x:Name="ManagedDot" Width="7" Height="7" Fill="#62586C" VerticalAlignment="Center"/>
                        <TextBlock x:Name="ManagedValue" Text="Checking" Style="{StaticResource RowValue}" Margin="8,0,0,0"/>
                      </StackPanel>
                    </Grid>
                    <Rectangle Height="1" Fill="{StaticResource Divider}"/>
                    <Grid Height="40">
                      <TextBlock Text="Last run" Style="{StaticResource RowLabel}"/>
                      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                        <Ellipse x:Name="LastRunDot" Width="7" Height="7" Fill="#62586C" VerticalAlignment="Center"/>
                        <TextBlock x:Name="LastRunValue" Text="Never" Style="{StaticResource RowValue}" Margin="8,0,0,0"/>
                      </StackPanel>
                    </Grid>
                  </StackPanel>
                </Border>

                <Border Style="{StaticResource Card}" Background="{StaticResource CardBgAlt}" Padding="22,18" Margin="0,14,0,0">
                  <StackPanel>
                    <Grid Margin="0,0,0,12">
                      <TextBlock Text="Safety net" Style="{StaticResource CardTitle}"/>
                      <Border Style="{StaticResource Chip}" Background="#0F2119" BorderBrush="#1F4434" HorizontalAlignment="Right" VerticalAlignment="Center">
                        <TextBlock Text="ALWAYS ON" Foreground="{StaticResource GoodBrush}" FontSize="9.5" FontWeight="Bold"/>
                      </Border>
                    </Grid>
                    <Grid Margin="0,0,0,10">
                      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="&#xE73E;" FontFamily="{StaticResource IconFont}" FontSize="11" Foreground="{StaticResource GoodBrush}" Margin="0,3,0,0"/>
                      <TextBlock Grid.Column="1" Text="A restore point is created and checked before anything changes." Style="{StaticResource Body}" Foreground="#B8ACC4" Margin="11,0,0,0"/>
                    </Grid>
                    <Grid Margin="0,0,0,10">
                      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="&#xE73E;" FontFamily="{StaticResource IconFont}" FontSize="11" Foreground="{StaticResource GoodBrush}" Margin="0,3,0,0"/>
                      <TextBlock Grid.Column="1" Text="Boot and security settings are backed up first." Style="{StaticResource Body}" Foreground="#B8ACC4" Margin="11,0,0,0"/>
                    </Grid>
                    <Grid Margin="0,0,0,10">
                      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="&#xE73E;" FontFamily="{StaticResource IconFont}" FontSize="11" Foreground="{StaticResource GoodBrush}" Margin="0,3,0,0"/>
                      <TextBlock Grid.Column="1" Text="BitLocker is paused for two restarts at most. The disk stays encrypted." Style="{StaticResource Body}" Foreground="#B8ACC4" Margin="11,0,0,0"/>
                    </Grid>
                    <Grid>
                      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="&#xE73E;" FontFamily="{StaticResource IconFont}" FontSize="11" Foreground="{StaticResource GoodBrush}" Margin="0,3,0,0"/>
                      <TextBlock Grid.Column="1" Text="Stops after two restarts, so it can never loop." Style="{StaticResource Body}" Foreground="#B8ACC4" Margin="11,0,0,0"/>
                    </Grid>
                  </StackPanel>
                </Border>
              </StackPanel>
            </ScrollViewer>
          </Grid>

          <!-- Activity -->
          <Grid x:Name="ActivityPanel" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <Grid Margin="4,6,4,16">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <StackPanel>
                <TextBlock Text="ACTIVITY" Style="{StaticResource Kicker}"/>
                <TextBlock Style="{StaticResource PageTitle}" Margin="0,6,0,0"><Run Text="What happened"/><Run Text="." Foreground="{StaticResource AccentBrush}"/></TextBlock>
                <TextBlock x:Name="ActivityCaption" Text="Newest first. Only results that matter and anything you need to fix." Foreground="{StaticResource TextMuted}" Margin="0,4,0,0"/>
                <Border CornerRadius="11" Background="#120D17" BorderBrush="#241B2C" BorderThickness="1" Padding="3" HorizontalAlignment="Left" Margin="0,14,0,0">
                  <StackPanel Orientation="Horizontal">
                    <RadioButton x:Name="AllFilter" Content="All" GroupName="LogFilter" IsChecked="True" Style="{StaticResource FilterRadio}"/>
                    <RadioButton x:Name="ActionFilter" Content="Needs attention" GroupName="LogFilter" Style="{StaticResource FilterRadio}"/>
                    <RadioButton x:Name="FailureFilter" Content="Failed" GroupName="LogFilter" Style="{StaticResource FilterRadio}"/>
                  </StackPanel>
                </Border>
              </StackPanel>
              <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Bottom">
                <Button x:Name="CopySupportButton" Style="{StaticResource SmallGhost}" Margin="0,0,8,0" ToolTip="Copies the status and recent activity, ready to paste into a support message.">
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE8C8;" FontFamily="{StaticResource IconFont}" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"/><TextBlock Text="Copy for support"/></StackPanel>
                </Button>
                <Button x:Name="OpenFilesButton" Style="{StaticResource SmallGhost}" Margin="0,0,8,0" ToolTip="C:\ProgramData\Disable-HyperV-Fully">
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE838;" FontFamily="{StaticResource IconFont}" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"/><TextBlock Text="Log folder"/></StackPanel>
                </Button>
                <Button x:Name="OpenReportButton" Style="{StaticResource SmallGhost}" Visibility="Collapsed" ToolTip="Opens Final-Status.txt">
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE8A5;" FontFamily="{StaticResource IconFont}" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"/><TextBlock Text="Final report"/></StackPanel>
                </Button>
              </StackPanel>
            </Grid>
            <Border Grid.Row="1" Style="{StaticResource Card}" Background="{StaticResource CardBgAlt}" Padding="6,8,4,8">
              <Grid>
                <StackPanel x:Name="ActivityEmpty" HorizontalAlignment="Center" VerticalAlignment="Center" MaxWidth="360">
                  <Border Width="58" Height="58" CornerRadius="29" Background="#160F1C" BorderBrush="#2A1F33" BorderThickness="1" HorizontalAlignment="Center">
                    <TextBlock Text="&#xE9D9;" FontFamily="{StaticResource IconFont}" FontSize="20" Foreground="#7A5590" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  </Border>
                  <TextBlock x:Name="ActivityEmptyTitle" Text="Nothing here yet" HorizontalAlignment="Center" Style="{StaticResource CardTitle}" Margin="0,14,0,0"/>
                  <TextBlock x:Name="ActivityEmptyBody" Text="Check the PC or start the process. Results show up here as they happen." Style="{StaticResource Body}" TextAlignment="Center" Margin="0,6,0,0"/>
                </StackPanel>
                <ScrollViewer x:Name="ActivityScroll" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                  <ItemsControl x:Name="ActivityList" Focusable="False">
                    <ItemsControl.ItemTemplate>
                      <DataTemplate>
                        <Grid>
                          <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="84"/>
                            <ColumnDefinition Width="36"/>
                            <ColumnDefinition Width="*"/>
                          </Grid.ColumnDefinitions>
                          <StackPanel Margin="0,16,8,0" HorizontalAlignment="Right">
                            <TextBlock Text="{Binding Time}" FontFamily="Cascadia Mono, Consolas" FontSize="11.5" Foreground="#A094AC" HorizontalAlignment="Right"/>
                            <TextBlock Text="{Binding Day}" FontSize="10.5" Foreground="#62586C" HorizontalAlignment="Right" Margin="0,2,0,0"/>
                          </StackPanel>
                          <Rectangle Grid.Column="1" Width="1" Fill="#241B2C" HorizontalAlignment="Center"/>
                          <Border Grid.Column="1" Width="26" Height="26" CornerRadius="13" Background="{Binding IconBackground}" BorderBrush="{Binding Stroke}" BorderThickness="1" VerticalAlignment="Top" Margin="0,14,0,0">
                            <TextBlock Text="{Binding Glyph}" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="11" Foreground="{Binding Accent}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                          </Border>
                          <Border Grid.Column="2" CornerRadius="12" Background="{Binding Background}" BorderBrush="{Binding Stroke}" BorderThickness="1" Margin="6,6,12,6" Padding="16,12">
                            <StackPanel>
                              <TextBlock Text="{Binding Level}" Foreground="{Binding Accent}" FontWeight="Bold" FontSize="10"/>
                              <TextBlock Text="{Binding Message}" Foreground="#EDE5F4" TextWrapping="Wrap" FontWeight="SemiBold" Margin="0,3,0,0" LineHeight="19"/>
                              <Border Visibility="{Binding ActionVisibility}" CornerRadius="9" Background="#0C090F" BorderBrush="#221A2A" BorderThickness="1" Margin="0,10,0,0" Padding="12,9">
                                <StackPanel>
                                  <TextBlock Text="WHAT TO DO" Foreground="{Binding Accent}" FontSize="10" FontWeight="Bold"/>
                                  <TextBlock Text="{Binding Action}" Foreground="#B8ACC4" TextWrapping="Wrap" Margin="0,4,0,0" LineHeight="18"/>
                                </StackPanel>
                              </Border>
                            </StackPanel>
                          </Border>
                        </Grid>
                      </DataTemplate>
                    </ItemsControl.ItemTemplate>
                  </ItemsControl>
                </ScrollViewer>
              </Grid>
            </Border>
          </Grid>

          <!-- Testing (internal) -->
          <Grid x:Name="TestingPanel" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <StackPanel Margin="4,6,4,16">
              <TextBlock Text="TESTING" Style="{StaticResource Kicker}"/>
              <TextBlock Style="{StaticResource PageTitle}" Margin="0,6,0,0"><Run Text="Test helpers"/><Run Text="." Foreground="{StaticResource AccentBrush}"/></TextBlock>
              <TextBlock Text="Internal helpers for test machines. Not part of the normal workflow." Foreground="{StaticResource TextMuted}" Margin="0,4,0,0"/>
            </StackPanel>
            <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="1.5*"/>
                  <ColumnDefinition Width="16"/>
                  <ColumnDefinition Width="1*"/>
                </Grid.ColumnDefinitions>
                <Border CornerRadius="18" Background="#160C12" BorderBrush="#40202C" BorderThickness="1" Padding="26,22" VerticalAlignment="Top">
                  <StackPanel>
                    <StackPanel Orientation="Horizontal">
                      <TextBlock Text="&#xEA18;" FontFamily="{StaticResource IconFont}" FontSize="15" Foreground="{StaticResource BadBrush}" VerticalAlignment="Center"/>
                      <TextBlock Text="Windows Security control" Style="{StaticResource CardTitle}" Margin="10,0,0,0" VerticalAlignment="Center"/>
                    </StackPanel>
                    <TextBlock Text="Applies the same native changes as third-party Defender toggles: Defender policy keys, the WinDefend, WdNisSvc and WdFilter services, and the Security Health tray icon. Restore reverses everything using the saved original values."
                               Style="{StaticResource Body}" Foreground="#A8929D" Margin="0,10,0,0"/>
                    <Border CornerRadius="10" Background="#1D1710" BorderBrush="#4A3A1E" BorderThickness="1" Padding="14,11" Margin="0,16,0,0">
                      <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <TextBlock Text="&#xE7BA;" FontFamily="{StaticResource IconFont}" FontSize="12" Foreground="{StaticResource WarnBrush}" VerticalAlignment="Top" Margin="0,2,0,0"/>
                        <TextBlock Grid.Column="1" Text="If Tamper Protection is on, Windows blocks or reverts these changes. Turn it off first in Windows Security, Virus &amp; threat protection settings."
                                   Foreground="#E9C27A" FontSize="11.5" TextWrapping="Wrap" Margin="10,0,0,0" LineHeight="17"/>
                      </Grid>
                    </Border>
                    <StackPanel Orientation="Horizontal" Margin="0,18,0,0">
                      <Button x:Name="DefenderDisableButton" Content="Disable Windows Security" Style="{StaticResource DangerButton}"/>
                      <Button x:Name="DefenderEnableButton" Content="Restore Windows Security" Style="{StaticResource GhostButton}" Margin="10,0,0,0"/>
                    </StackPanel>
                    <TextBlock x:Name="DefenderNote" Text="" Foreground="{StaticResource WarnBrush}" FontSize="11.5" TextWrapping="Wrap" Margin="0,12,0,0" LineHeight="17"/>
                  </StackPanel>
                </Border>
                <Border Grid.Column="2" Style="{StaticResource Card}" Padding="22,18,22,8" VerticalAlignment="Top">
                  <StackPanel>
                    <TextBlock Text="Current state" Style="{StaticResource CardTitle}" Margin="0,0,0,8"/>
                    <Grid Height="40"><TextBlock Text="Tamper Protection" Style="{StaticResource RowLabel}"/><TextBlock x:Name="DefTamperValue" Text="Checking" Style="{StaticResource RowValue}" HorizontalAlignment="Right"/></Grid>
                    <Rectangle Height="1" Fill="{StaticResource Divider}"/>
                    <Grid Height="40"><TextBlock Text="Real-time protection" Style="{StaticResource RowLabel}"/><TextBlock x:Name="DefRtValue" Text="Checking" Style="{StaticResource RowValue}" HorizontalAlignment="Right"/></Grid>
                    <Rectangle Height="1" Fill="{StaticResource Divider}"/>
                    <Grid Height="40"><TextBlock Text="WinDefend service" Style="{StaticResource RowLabel}"/><TextBlock x:Name="DefSvcValue" Text="Checking" Style="{StaticResource RowValue}" HorizontalAlignment="Right"/></Grid>
                  </StackPanel>
                </Border>
              </Grid>
            </ScrollViewer>
          </Grid>
        </Grid>

        <!-- Action bar: one place for the next step, on every page. -->
        <Border Grid.Row="2" Margin="20,14,20,18" CornerRadius="18" Background="#E6110C15" BorderBrush="{StaticResource CardStrokeLit}" BorderThickness="1" ClipToBounds="True">
          <Grid>
            <Border x:Name="BusyTrack" Height="2" VerticalAlignment="Top" ClipToBounds="True" Visibility="Collapsed" Margin="18,0">
              <Rectangle x:Name="BusyBar" Width="240" HorizontalAlignment="Left">
                <Rectangle.Fill>
                  <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                    <GradientStop Color="#00E35BD9" Offset="0"/>
                    <GradientStop Color="#FFE35BD9" Offset="0.5"/>
                    <GradientStop Color="#009D4BEA" Offset="1"/>
                  </LinearGradientBrush>
                </Rectangle.Fill>
                <Rectangle.RenderTransform><TranslateTransform X="-240"/></Rectangle.RenderTransform>
              </Rectangle>
            </Border>
            <Grid Margin="14,12,12,12">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <Border Width="40" Height="40" CornerRadius="12" Background="{DynamicResource HeroToneFaint}" BorderBrush="{DynamicResource HeroToneDim}" BorderThickness="1" VerticalAlignment="Center">
                <TextBlock x:Name="FooterGlyph" Text="&#xE721;" FontFamily="{StaticResource IconFont}" FontSize="16" Foreground="{DynamicResource HeroTone}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="14,0,16,0">
                <TextBlock x:Name="FooterTitle" Text="Checking this PC..." FontWeight="SemiBold" FontSize="13.5" TextTrimming="CharacterEllipsis"/>
                <TextBlock x:Name="FooterSubtitle" Text="This takes a second." Foreground="{StaticResource TextMuted}" FontSize="12" Margin="0,3,0,0" TextTrimming="CharacterEllipsis"/>
              </StackPanel>
              <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                <Button x:Name="CancelRestartButton" Content="Cancel restart" Style="{StaticResource GhostButton}" Margin="0,0,10,0" Visibility="Collapsed"
                        ToolTip="Stops the pending restart. Restart yourself later; the tool carries on after that."/>
                <Button x:Name="SecondaryButton" Style="{StaticResource GhostButton}" Margin="0,0,10,0" Visibility="Collapsed" ToolTip="Read-only check. Nothing on the PC is changed. (F5)">
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE721;" FontFamily="{StaticResource IconFont}" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"/><TextBlock Text="Check this PC"/></StackPanel>
                </Button>
                <Button x:Name="PrimaryButton" Style="{StaticResource PrimaryButton}" MinWidth="196" IsEnabled="False">
                  <StackPanel Orientation="Horizontal">
                    <TextBlock x:Name="PrimaryText" Text="Turn off Hyper-V" VerticalAlignment="Center"/>
                    <TextBlock x:Name="PrimaryGlyph" Text="&#xE72A;" FontFamily="{StaticResource IconFont}" FontSize="12" Margin="10,0,0,0" VerticalAlignment="Center"/>
                  </StackPanel>
                </Button>
              </StackPanel>
            </Grid>
          </Grid>
        </Border>

        <!-- Toast -->
        <Border x:Name="Toast" Grid.Row="1" HorizontalAlignment="Center" VerticalAlignment="Bottom" Margin="0,0,0,2" Visibility="Collapsed" IsHitTestVisible="False"
                CornerRadius="12" Background="#F21A1220" BorderBrush="#3A2B47" BorderThickness="1" Padding="16,10" Effect="{StaticResource CardShadow}">
          <StackPanel Orientation="Horizontal">
            <TextBlock x:Name="ToastGlyph" Text="&#xE73E;" FontFamily="{StaticResource IconFont}" FontSize="13" Foreground="{StaticResource GoodBrush}" VerticalAlignment="Center"/>
            <TextBlock x:Name="ToastText" Text="" Foreground="#F1EAF6" FontWeight="SemiBold" Margin="10,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
        </Border>

        <!-- Confirm sheet -->
        <Grid x:Name="ConfirmOverlay" Grid.Row="1" Grid.RowSpan="2" Visibility="Collapsed" Background="#C8060409">
          <Border x:Name="ConfirmCard" Width="660" Margin="24,6,24,24" VerticalAlignment="Center" CornerRadius="22" BorderThickness="1" BorderBrush="#4A2E57"
                  Background="{StaticResource SheetFill}" Effect="{StaticResource CardShadow}">
            <Border.RenderTransform><TranslateTransform Y="0"/></Border.RenderTransform>
            <Grid>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
              </Grid.RowDefinitions>
              <StackPanel Margin="30,24,24,0">
                <Grid>
                  <TextBlock Text="CONFIRM" Style="{StaticResource Kicker}" VerticalAlignment="Center"/>
                  <Button x:Name="ConfirmCloseX" Content="&#xE8BB;" Style="{StaticResource ChromeButton}" HorizontalAlignment="Right" ToolTip="Cancel (Esc)" AutomationProperties.Name="Cancel"/>
                </Grid>
                <TextBlock x:Name="ConfirmTitle" Text="Turn off Hyper-V on this PC?" Style="{StaticResource PageTitle}" FontSize="24" TextWrapping="Wrap" Margin="0,2,6,0"/>
                <TextBlock Text="These stop working until you turn them back on:" Style="{StaticResource Body}" FontSize="12.5" Margin="0,8,0,0"/>
                <WrapPanel Margin="0,10,0,0">
                  <Border Style="{StaticResource OffChip}"><TextBlock Text="Hyper-V" Foreground="#E7D9F0" FontSize="11.5"/></Border>
                  <Border Style="{StaticResource OffChip}"><TextBlock Text="VBS" Foreground="#E7D9F0" FontSize="11.5"/></Border>
                  <Border Style="{StaticResource OffChip}"><TextBlock Text="Credential Guard" Foreground="#E7D9F0" FontSize="11.5"/></Border>
                  <Border Style="{StaticResource OffChip}"><TextBlock Text="Memory Integrity" Foreground="#E7D9F0" FontSize="11.5"/></Border>
                  <Border Style="{StaticResource OffChip}"><TextBlock Text="Windows Sandbox" Foreground="#E7D9F0" FontSize="11.5"/></Border>
                  <Border Style="{StaticResource OffChip}"><TextBlock Text="WSL 2" Foreground="#E7D9F0" FontSize="11.5"/></Border>
                  <Border Style="{StaticResource OffChip}"><TextBlock Text="Application Guard" Foreground="#E7D9F0" FontSize="11.5"/></Border>
                  <Border Style="{StaticResource OffChip}"><TextBlock Text="Windows Hello PIN" Foreground="#E7D9F0" FontSize="11.5"/></Border>
                </WrapPanel>
              </StackPanel>

              <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="0,14,4,0">
                <StackPanel Margin="30,0,24,10">
                  <TextBlock Text="BEFORE YOU START" Style="{StaticResource Section}"/>
                  <CheckBox x:Name="AckSaved" Style="{StaticResource CheckRow}" Margin="0,10,0,0">
                    <StackPanel>
                      <TextBlock Text="I have saved my work and closed other apps." FontWeight="SemiBold"/>
                      <TextBlock Text="The PC restarts up to twice. Anything unsaved is lost." Style="{StaticResource Body}" Margin="0,2,0,0"/>
                    </StackPanel>
                  </CheckBox>
                  <CheckBox x:Name="AckPassword" Style="{StaticResource CheckRow}" Margin="0,8,0,0">
                    <StackPanel>
                      <TextBlock Text="I know the password for this Windows account." FontWeight="SemiBold"/>
                      <TextBlock Text="PIN sign-in is removed. From now on you sign in with your Microsoft account or local password." Style="{StaticResource Body}" Margin="0,2,0,0"/>
                    </StackPanel>
                  </CheckBox>
                  <ItemsControl x:Name="PreflightList" Margin="0,10,0,0" Focusable="False">
                    <ItemsControl.ItemTemplate>
                      <DataTemplate>
                        <Border CornerRadius="11" Background="{Binding Background}" BorderBrush="{Binding Stroke}" BorderThickness="1" Padding="13,10" Margin="0,0,0,7">
                          <Grid>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                            <TextBlock Text="{Binding Glyph}" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="13" Foreground="{Binding Accent}" VerticalAlignment="Top" Margin="0,2,0,0"/>
                            <TextBlock Grid.Column="1" Text="{Binding Text}" Foreground="{Binding TextBrush}" TextWrapping="Wrap" Margin="11,0,0,0" LineHeight="18" FontSize="12.5"/>
                          </Grid>
                        </Border>
                      </DataTemplate>
                    </ItemsControl.ItemTemplate>
                  </ItemsControl>

                  <TextBlock Text="OPTIONS" Style="{StaticResource Section}" Margin="0,14,0,0"/>
                  <Border CornerRadius="13" Background="#100B14" BorderBrush="#251C2D" BorderThickness="1" Padding="16,6" Margin="0,10,0,0">
                    <StackPanel>
                      <Grid Margin="0,10">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <StackPanel Margin="0,0,20,0">
                          <TextBlock Text="Restart automatically" FontWeight="SemiBold"/>
                          <TextBlock Text="Restarts 30 seconds after the changes, so you can save. Turn off to restart yourself later." Style="{StaticResource Body}" Margin="0,2,0,0"/>
                        </StackPanel>
                        <CheckBox x:Name="AutoRestartToggle" Grid.Column="1" Style="{StaticResource Toggle}" IsChecked="True" VerticalAlignment="Center" AutomationProperties.Name="Restart automatically"/>
                      </Grid>
                      <Rectangle Height="1" Fill="{StaticResource Divider}"/>
                      <Grid Margin="0,10">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <StackPanel Margin="0,0,20,0">
                          <TextBlock Text="Remove the firmware lock" FontWeight="SemiBold"/>
                          <TextBlock Text="Needed when VBS is locked in UEFI. A Microsoft screen may ask you to press a key (usually F3) at startup." Style="{StaticResource Body}" Margin="0,2,0,0"/>
                        </StackPanel>
                        <CheckBox x:Name="FirmwareToggle" Grid.Column="1" Style="{StaticResource Toggle}" IsChecked="True" VerticalAlignment="Center" AutomationProperties.Name="Remove the firmware lock"/>
                      </Grid>
                      <Rectangle Height="1" Fill="{StaticResource Divider}"/>
                      <Grid Margin="0,10">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <StackPanel Margin="0,0,20,0">
                          <TextBlock Text="Open this window after restarting" FontWeight="SemiBold"/>
                          <TextBlock Text="Shows the progress after you sign in. Stops opening by itself once Hyper-V is off." Style="{StaticResource Body}" Margin="0,2,0,0"/>
                        </StackPanel>
                        <CheckBox x:Name="ReopenToggle" Grid.Column="1" Style="{StaticResource Toggle}" IsChecked="True" VerticalAlignment="Center" AutomationProperties.Name="Open this window after restarting"/>
                      </Grid>
                    </StackPanel>
                  </Border>
                </StackPanel>
              </ScrollViewer>

              <Border Grid.Row="2" BorderBrush="#251C2D" BorderThickness="0,1,0,0" Background="#59000000" CornerRadius="0,0,22,22" Padding="30,16,24,18">
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,14,0">
                    <TextBlock x:Name="ConfirmHintGlyph" Text="&#xE946;" FontFamily="{StaticResource IconFont}" FontSize="12" Foreground="{StaticResource TextMuted}" VerticalAlignment="Center"/>
                    <TextBlock x:Name="ConfirmHint" Text="Tick both boxes to continue." Foreground="{StaticResource TextMuted}" FontSize="12" Margin="8,0,0,0" VerticalAlignment="Center" TextWrapping="Wrap"/>
                  </StackPanel>
                  <StackPanel Grid.Column="1" Orientation="Horizontal">
                    <Button x:Name="ConfirmCancel" Content="Cancel" Style="{StaticResource GhostButton}" Margin="0,0,10,0"/>
                    <Button x:Name="ConfirmStart" Style="{StaticResource PrimaryButton}" IsEnabled="False">
                      <StackPanel Orientation="Horizontal">
                        <TextBlock Text="Turn off Hyper-V" VerticalAlignment="Center"/>
                        <TextBlock Text="&#xE72A;" FontFamily="{StaticResource IconFont}" FontSize="12" Margin="10,0,0,0" VerticalAlignment="Center"/>
                      </StackPanel>
                    </Button>
                  </StackPanel>
                </Grid>
              </Border>
            </Grid>
          </Border>
        </Grid>

        <!-- Help sheet -->
        <Grid x:Name="HelpOverlay" Grid.Row="1" Grid.RowSpan="2" Visibility="Collapsed" Background="#C8060409">
          <Border x:Name="HelpCard" Width="680" Margin="24,6,24,24" VerticalAlignment="Center" CornerRadius="22" BorderThickness="1" BorderBrush="#3A2848"
                  Background="{StaticResource SheetFill}" Effect="{StaticResource CardShadow}">
            <Border.RenderTransform><TranslateTransform Y="0"/></Border.RenderTransform>
            <Grid>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
              </Grid.RowDefinitions>
              <StackPanel Margin="30,24,24,0">
                <Grid>
                  <TextBlock Text="HELP" Style="{StaticResource Kicker}" VerticalAlignment="Center"/>
                  <Button x:Name="HelpCloseX" Content="&#xE8BB;" Style="{StaticResource ChromeButton}" HorizontalAlignment="Right" ToolTip="Close (Esc)" AutomationProperties.Name="Close help"/>
                </Grid>
                <TextBlock Style="{StaticResource PageTitle}" FontSize="24" Margin="0,2,0,0"><Run Text="How it works"/><Run Text="." Foreground="{StaticResource AccentBrush}"/></TextBlock>
              </StackPanel>
              <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="0,16,4,0">
                <StackPanel Margin="30,0,24,10">
                  <Grid Margin="0,0,0,16">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Border Width="32" Height="32" CornerRadius="16" Background="#241530" VerticalAlignment="Top"><TextBlock Text="&#xE7E8;" FontFamily="{StaticResource IconFont}" FontSize="13" Foreground="{StaticResource AccentBrush}" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
                    <StackPanel Grid.Column="1" Margin="14,0,0,0">
                      <TextBlock Text="What does it change?" FontWeight="SemiBold" FontSize="13.5"/>
                      <TextBlock Style="{StaticResource Body}" FontSize="12.5" Foreground="#B0A4BC" Margin="0,4,0,0" Text="It turns off the Windows hypervisor and everything that runs on it: Hyper-V, Virtual Machine Platform, VBS, Credential Guard, Memory Integrity, Windows Sandbox, WSL 2, Application Guard and Windows Hello PIN sign-in. Apps that need these will not start until they are turned back on."/>
                    </StackPanel>
                  </Grid>
                  <Grid Margin="0,0,0,16">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Border Width="32" Height="32" CornerRadius="16" Background="#241530" VerticalAlignment="Top"><TextBlock Text="&#xE765;" FontFamily="{StaticResource IconFont}" FontSize="13" Foreground="{StaticResource AccentBrush}" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
                    <StackPanel Grid.Column="1" Margin="14,0,0,0">
                      <TextBlock Text="A blue screen asks me to press F3 while the PC starts" FontWeight="SemiBold" FontSize="13.5"/>
                      <TextBlock Style="{StaticResource Body}" FontSize="12.5" Foreground="#B0A4BC" Margin="0,4,0,0" Text="That is a Microsoft confirmation screen. It appears when VBS was locked in the firmware. Press the key it shows (usually F3) to approve. If you miss it, Windows starts normally; run the tool again and approve it next time."/>
                    </StackPanel>
                  </Grid>
                  <Grid Margin="0,0,0,16">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Border Width="32" Height="32" CornerRadius="16" Background="#241530" VerticalAlignment="Top"><TextBlock Text="&#xE72E;" FontFamily="{StaticResource IconFont}" FontSize="13" Foreground="{StaticResource AccentBrush}" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
                    <StackPanel Grid.Column="1" Margin="14,0,0,0">
                      <TextBlock Text="Why is my PIN gone?" FontWeight="SemiBold" FontSize="13.5"/>
                      <TextBlock Style="{StaticResource Body}" FontSize="12.5" Foreground="#B0A4BC" Margin="0,4,0,0" Text="Windows Hello PINs are sealed to the security settings this tool turns off. Removing the PIN first avoids the 'Your PIN isn't available' lockout. Sign in with your Microsoft account password or local password instead."/>
                    </StackPanel>
                  </Grid>
                  <Grid Margin="0,0,0,16">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Border Width="32" Height="32" CornerRadius="16" Background="#241530" VerticalAlignment="Top"><TextBlock Text="&#xE7A7;" FontFamily="{StaticResource IconFont}" FontSize="13" Foreground="{StaticResource AccentBrush}" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
                    <StackPanel Grid.Column="1" Margin="14,0,0,0">
                      <TextBlock Text="How do I undo it?" FontWeight="SemiBold" FontSize="13.5"/>
                      <TextBlock Style="{StaticResource Body}" FontSize="12.5" Foreground="#B0A4BC" Margin="0,4,0,0" Text="Open System Restore and choose the restore point named 'Before disabling Hyper-V and VBS'. The tool created and checked it before changing anything. Your personal files are not affected by a restore."/>
                    </StackPanel>
                  </Grid>
                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Border Width="32" Height="32" CornerRadius="16" Background="#241530" VerticalAlignment="Top"><TextBlock Text="&#xE9D9;" FontFamily="{StaticResource IconFont}" FontSize="13" Foreground="{StaticResource AccentBrush}" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
                    <StackPanel Grid.Column="1" Margin="14,0,0,0">
                      <TextBlock Text="Something went wrong. What now?" FontWeight="SemiBold" FontSize="13.5"/>
                      <TextBlock Style="{StaticResource Body}" FontSize="12.5" Foreground="#B0A4BC" Margin="0,4,0,0" Text="The Home page names the fix, and every failure on the Activity page says what to do. If you need help, use Copy for support on the Activity page and paste it into your message. Logs are in C:\ProgramData\Disable-HyperV-Fully."/>
                    </StackPanel>
                  </Grid>
                </StackPanel>
              </ScrollViewer>
              <Border Grid.Row="2" BorderBrush="#251C2D" BorderThickness="0,1,0,0" Background="#59000000" CornerRadius="0,0,22,22" Padding="30,14,24,16">
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBlock x:Name="VersionText" Text="Version dev" Foreground="{StaticResource TextFaint}" FontSize="11.5" VerticalAlignment="Center"/>
                  <StackPanel Grid.Column="1" Orientation="Horizontal">
                    <Button x:Name="OpenRestoreButton" Style="{StaticResource SmallGhost}" Margin="0,0,8,0" ToolTip="Opens Windows System Restore (rstrui.exe)">
                      <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE7A7;" FontFamily="{StaticResource IconFont}" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"/><TextBlock Text="Open System Restore"/></StackPanel>
                    </Button>
                    <Button x:Name="HelpDone" Content="Got it" Style="{StaticResource PrimaryButton}" Padding="22,9" MinWidth="110"/>
                  </StackPanel>
                </Grid>
              </Border>
            </Grid>
          </Border>
        </Grid>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

try {
    [xml]$xaml = $xamlText
    $window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
}
catch {
    Show-Notice ("The window could not be opened.`n`n{0}" -f $_.Exception.Message) 'Error'
    return
}

# Expose every named element as a script variable (template parts resolve to
# nothing at window scope and are skipped).
$xamlNamespace = 'http://schemas.microsoft.com/winfx/2006/xaml'
foreach ($node in $xaml.SelectNodes('//*')) {
    $nameAttribute = $node.GetAttributeNode('Name', $xamlNamespace)
    if ($null -eq $nameAttribute) { continue }
    $element = $window.FindName($nameAttribute.Value)
    if ($null -ne $element) { Set-Variable -Name $nameAttribute.Value -Value $element -Scope Script }
}

# ---------------------------------------------------------------- state

$script:snapshot = $null
$script:snapshotVersion = -1
$script:events = New-Object System.Collections.ArrayList
$script:eventOffset = [long]0
$script:state = $null
$script:stateStamp = ''
$script:insight = @{
    RestartPendingUntil = [datetime]::MinValue
    RestartRequestAt    = $null
    FailureCount        = 0
    RunCodes            = @{}
    RunStartAt          = $null
    HasRunStart         = $false
    Fix                 = $null
    Latest              = $null
}
$script:engineProcess = $null
$script:engineMode = ''
$script:engineStartedAt = $null
$script:engineExitedAt = [datetime]::MinValue
$script:restartArmedUntil = [datetime]::MinValue
$script:defenderArmed = $false
$script:defenderDeadline = [datetime]::MinValue
$script:defenderVersion = -1
$script:activitySignature = ''
$script:guideSignature = ''
$script:heroTone = ''
$script:orbSpinning = $false
$script:orbBreathing = $false
$script:busyAnimating = $false
$script:stepStates = @('', '', '', '', '')
$script:overlay = ''
$script:primaryAction = 'None'
$script:reopenArmedThisSession = $false
$script:reopenCleared = $false
$script:toastTimer = $null
$script:brushCache = @{}

# Respect "Show animations in Windows" and skip continuous motion when WPF is
# rendering in software (remote desktop, basic display drivers).
$script:reduceMotion = (-not [Windows.SystemParameters]::ClientAreaAnimation) -or
                       (([Windows.Media.RenderCapability]::Tier -shr 16) -eq 0)

$glyph = @{
    Power   = [string][char]0xE7E8
    Sync    = [string][char]0xE895
    Check   = [string][char]0xE73E
    Warning = [string][char]0xE7BA
    Cancel  = [string][char]0xE711
    Search  = [string][char]0xE721
    Restart = [string][char]0xE72C
    Info    = [string][char]0xE946
    Forward = [string][char]0xE72A
    Close   = [string][char]0xE8BB
    Battery = [string][char]0xE83F
    Lock    = [string][char]0xE72E
    Work    = [string][char]0xE821
    Disk    = [string][char]0xEDA2
    History = [string][char]0xE81C
    Report  = [string][char]0xE8A5
    Max     = [string][char]0xE922
    Restore = [string][char]0xE923
}

$toneColors = @{
    Good    = '#4ADE9B'
    Warn    = '#F5B94F'
    Bad     = '#FF6B81'
    Accent  = '#E063E8'
    Neutral = '#DCD2E6'
    Muted   = '#85798F'
}
$heroToneColors = @{
    Accent  = '#E063E8'
    Good    = '#4ADE9B'
    Warn    = '#F5B94F'
    Bad     = '#FF6B81'
    Neutral = '#A99DB5'
}
# badge fill, badge stroke for numbered guidance
$guideBadge = @{
    Accent  = @('#241530', '#4A2E62')
    Good    = @('#0F2119', '#1F4434')
    Warn    = @('#221A0E', '#4A3A1E')
    Bad     = @('#26101A', '#5A2233')
    Neutral = @('#1D1524', '#34283F')
}

# ---------------------------------------------------------------- helpers

function Write-UiTrace {
    param($ErrorRecord)
    try {
        $text = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
            '{0} at {1}' -f $ErrorRecord.Exception.Message, $ErrorRecord.InvocationInfo.PositionMessage
        }
        else { "$ErrorRecord" }
        Add-Content -LiteralPath $uiTracePath -Value ('{0}  {1}' -f (Get-Date).ToString('o'), $text) -Encoding UTF8
    }
    catch { }
}

function Invoke-Guarded {
    # Runs a UI action; a failure is logged and shown instead of closing the window.
    param([scriptblock] $Action)
    try { & $Action }
    catch {
        Write-UiTrace $_
        Show-Toast 'That did not work. Details were saved to Console-UI.log in the log folder.' 'Bad'
    }
}

function Get-Color {
    param([string] $Hex, [int] $Alpha = -1)
    $color = [Windows.Media.Color][Windows.Media.ColorConverter]::ConvertFromString($Hex)
    if ($Alpha -ge 0) { $color = [Windows.Media.Color]::FromArgb([byte]$Alpha, $color.R, $color.G, $color.B) }
    return $color
}

function Get-Brush {
    param([string] $Hex)
    if (-not $script:brushCache.ContainsKey($Hex)) {
        $brush = New-Object Windows.Media.SolidColorBrush (Get-Color $Hex)
        $brush.Freeze()
        $script:brushCache[$Hex] = $brush
    }
    return $script:brushCache[$Hex]
}

function New-Duration {
    param([int] $Milliseconds)
    if ($script:reduceMotion) { $Milliseconds = 1 }
    return [Windows.Duration]::new([TimeSpan]::FromMilliseconds($Milliseconds))
}

function New-EaseOut {
    $ease = New-Object Windows.Media.Animation.CubicEase
    $ease.EasingMode = [Windows.Media.Animation.EasingMode]::EaseOut
    return $ease
}

function Start-ColorTransition {
    param($Target, $Property, [Windows.Media.Color] $To, [int] $Milliseconds = 450)
    $animation = New-Object Windows.Media.Animation.ColorAnimation
    $animation.To = $To
    $animation.Duration = New-Duration $Milliseconds
    $animation.EasingFunction = New-EaseOut
    $Target.BeginAnimation($Property, $animation)
}

# Animatable tone brushes shared by the hero, stepper and action bar.
$script:toneBrush = New-Object Windows.Media.SolidColorBrush (Get-Color $heroToneColors.Neutral)
$script:toneDimBrush = New-Object Windows.Media.SolidColorBrush (Get-Color $heroToneColors.Neutral 110)
$script:toneFaintBrush = New-Object Windows.Media.SolidColorBrush (Get-Color $heroToneColors.Neutral 34)
# The indexer takes [object], so pass the raw brush rather than PowerShell's wrapper.
$window.Resources['HeroTone'] = $script:toneBrush.PSObject.BaseObject
$window.Resources['HeroToneDim'] = $script:toneDimBrush.PSObject.BaseObject
$window.Resources['HeroToneFaint'] = $script:toneFaintBrush.PSObject.BaseObject

# Soft radial glows (cheaper than blur effects) that follow the same tone.
$script:orbGlowStop = New-Object Windows.Media.GradientStop((Get-Color $heroToneColors.Neutral 70), 0.0)
$script:orbGlowEdge = New-Object Windows.Media.GradientStop((Get-Color $heroToneColors.Neutral 0), 1.0)
$orbGlowBrush = New-Object Windows.Media.RadialGradientBrush
$orbGlowBrush.GradientStops.Add($script:orbGlowStop)
$orbGlowBrush.GradientStops.Add((New-Object Windows.Media.GradientStop((Get-Color $heroToneColors.Neutral 26), 0.55)))
$orbGlowBrush.GradientStops.Add($script:orbGlowEdge)
$script:orbGlowMid = $orbGlowBrush.GradientStops[1]
$OrbGlow.Fill = $orbGlowBrush

$script:ambientStop = New-Object Windows.Media.GradientStop((Get-Color $heroToneColors.Neutral 40), 0.0)
$ambientBrush = New-Object Windows.Media.RadialGradientBrush
$ambientBrush.Center = New-Object Windows.Point(0.12, 0.18)
$ambientBrush.GradientOrigin = New-Object Windows.Point(0.12, 0.18)
$ambientBrush.RadiusX = 0.55
$ambientBrush.RadiusY = 0.85
$ambientBrush.GradientStops.Add($script:ambientStop)
$ambientBrush.GradientStops.Add((New-Object Windows.Media.GradientStop((Get-Color '#000000' 0), 1.0)))
$HeroAmbient.Background = $ambientBrush

function Set-HeroTone {
    param([ValidateSet('Accent', 'Good', 'Warn', 'Bad', 'Neutral')][string] $Tone)
    if ($script:heroTone -eq $Tone) { return }
    $script:heroTone = $Tone
    $hex = $heroToneColors[$Tone]
    $colorProperty = [Windows.Media.SolidColorBrush]::ColorProperty
    $stopProperty = [Windows.Media.GradientStop]::ColorProperty
    Start-ColorTransition $script:toneBrush $colorProperty (Get-Color $hex)
    Start-ColorTransition $script:toneDimBrush $colorProperty (Get-Color $hex 110)
    Start-ColorTransition $script:toneFaintBrush $colorProperty (Get-Color $hex 34)
    Start-ColorTransition $script:orbGlowStop $stopProperty (Get-Color $hex 78) 700
    Start-ColorTransition $script:orbGlowMid $stopProperty (Get-Color $hex 26) 700
    Start-ColorTransition $script:orbGlowEdge $stopProperty (Get-Color $hex 0) 700
    Start-ColorTransition $script:ambientStop $stopProperty (Get-Color $hex 34) 900
}

function Set-OrbMotion {
    param([bool] $Spin, [bool] $Breathe)
    if ($Spin -ne $script:orbSpinning) {
        $script:orbSpinning = $Spin
        $rotate = $OrbArc.RenderTransform
        if ($Spin) {
            $OrbArc.Visibility = 'Visible'
            $OrbRingFull.Opacity = 0.35
            if (-not $script:reduceMotion) {
                $spinAnimation = New-Object Windows.Media.Animation.DoubleAnimation(0, 360, [Windows.Duration]::new([TimeSpan]::FromSeconds(1.4)))
                $spinAnimation.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
                $rotate.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $spinAnimation)
            }
        }
        else {
            $rotate.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $null)
            $OrbArc.Visibility = 'Collapsed'
            $OrbRingFull.Opacity = 1
        }
    }
    if ($Breathe -ne $script:orbBreathing) {
        $script:orbBreathing = $Breathe
        if ($Breathe -and -not $script:reduceMotion) {
            $breath = New-Object Windows.Media.Animation.DoubleAnimation(0.55, 1.0, [Windows.Duration]::new([TimeSpan]::FromSeconds(2.2)))
            $breath.AutoReverse = $true
            $breath.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
            $breath.EasingFunction = New-Object Windows.Media.Animation.SineEase
            $OrbGlow.BeginAnimation([Windows.UIElement]::OpacityProperty, $breath)
        }
        else {
            $OrbGlow.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
            $OrbGlow.Opacity = 0.9
        }
    }
}

function Set-Busy {
    param([bool] $On)
    if ($On -eq $script:busyAnimating) { return }
    $script:busyAnimating = $On
    $transform = $BusyBar.RenderTransform
    if ($On) {
        $BusyTrack.Visibility = 'Visible'
        if ($script:reduceMotion) { $transform.X = 0; return }
        $width = [Math]::Max(1400, $BusyTrack.ActualWidth)
        $animation = New-Object Windows.Media.Animation.DoubleAnimation(-240, $width, [Windows.Duration]::new([TimeSpan]::FromSeconds(1.7)))
        $animation.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
        $ease = New-Object Windows.Media.Animation.SineEase
        $ease.EasingMode = [Windows.Media.Animation.EasingMode]::EaseInOut
        $animation.EasingFunction = $ease
        $transform.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, $animation)
    }
    else {
        $transform.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, $null)
        $BusyTrack.Visibility = 'Collapsed'
    }
}

function Set-Reading {
    param($Value, $Dot, [string] $Text, [ValidateSet('Good', 'Warn', 'Bad', 'Accent', 'Neutral', 'Muted')][string] $Tone)
    $Value.Text = $Text
    $Value.Foreground = Get-Brush $(if ($Tone -eq 'Neutral') { '#DCD2E6' } else { $toneColors[$Tone] })
    $Dot.Fill = Get-Brush $(if ($Tone -eq 'Neutral') { '#85798F' } elseif ($Tone -eq 'Muted') { '#4A4054' } else { $toneColors[$Tone] })
}

function Set-Value {
    param($Control, [string] $Text, [ValidateSet('Good', 'Warn', 'Bad', 'Accent', 'Neutral', 'Muted')][string] $Tone = 'Neutral')
    $Control.Text = $Text
    $Control.Foreground = Get-Brush $toneColors[$Tone]
}

function Show-Toast {
    param([string] $Text, [ValidateSet('Good', 'Warn', 'Bad', 'Accent')][string] $Tone = 'Good')
    $ToastText.Text = $Text
    $ToastGlyph.Text = switch ($Tone) { 'Good' { $glyph.Check } 'Accent' { $glyph.Info } default { $glyph.Warning } }
    $ToastGlyph.Foreground = Get-Brush $toneColors[$Tone]
    $Toast.Visibility = 'Visible'
    $Toast.BeginAnimation([Windows.UIElement]::OpacityProperty, (New-Object Windows.Media.Animation.DoubleAnimation(0, 1, (New-Duration 180))))
    if ($null -ne $script:toastTimer) { $script:toastTimer.Stop() }
    $script:toastTimer = New-Object Windows.Threading.DispatcherTimer
    $script:toastTimer.Interval = [TimeSpan]::FromSeconds($(if ($Tone -eq 'Good') { 3.5 } else { 6 }))
    $script:toastTimer.Add_Tick({
        $script:toastTimer.Stop()
        $Toast.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
        $Toast.Visibility = 'Collapsed'
    })
    $script:toastTimer.Start()
}

# ---------------------------------------------------------------- pages and sheets

function Show-Page {
    param([ValidateSet('Home', 'Activity', 'Testing')][string] $Name)
    $pages = @{ Home = $HomePanel; Activity = $ActivityPanel; Testing = $TestingPanel }
    $navs = @{ Home = $NavHome; Activity = $NavActivity; Testing = $NavTesting }
    foreach ($key in $pages.Keys) { $pages[$key].Visibility = if ($key -eq $Name) { 'Visible' } else { 'Collapsed' } }
    if (-not $navs[$Name].IsChecked) { $navs[$Name].IsChecked = $true }
    $script:sync.WantDefender = ($Name -eq 'Testing')
    if ($Name -eq 'Testing') { $script:sync.Poke = $true }
    if (-not $script:reduceMotion) {
        $pages[$Name].BeginAnimation([Windows.UIElement]::OpacityProperty, (New-Object Windows.Media.Animation.DoubleAnimation(0, 1, (New-Duration 220))))
        $slide = New-Object Windows.Media.Animation.DoubleAnimation(8, 0, (New-Duration 220))
        $slide.EasingFunction = New-EaseOut
        $PageHost.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $slide)
    }
}

function Set-TestingVisible {
    param([bool] $On)
    $NavTesting.Visibility = if ($On) { 'Visible' } else { 'Collapsed' }
    if (-not $On -and $TestingPanel.Visibility -eq 'Visible') { Show-Page -Name 'Home' }
}

function Open-Sheet {
    param([ValidateSet('Confirm', 'Help')][string] $Name)
    $overlay = if ($Name -eq 'Confirm') { $ConfirmOverlay } else { $HelpOverlay }
    $card = if ($Name -eq 'Confirm') { $ConfirmCard } else { $HelpCard }
    if ($script:overlay -and $script:overlay -ne $Name) { Close-Sheet }
    $script:overlay = $Name
    $overlay.Visibility = 'Visible'
    $overlay.BeginAnimation([Windows.UIElement]::OpacityProperty, (New-Object Windows.Media.Animation.DoubleAnimation(0, 1, (New-Duration 180))))
    $rise = New-Object Windows.Media.Animation.DoubleAnimation(16, 0, (New-Duration 260))
    $rise.EasingFunction = New-EaseOut
    $card.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $rise)
}

function Close-Sheet {
    if (-not $script:overlay) { return }
    $ConfirmOverlay.Visibility = 'Collapsed'
    $HelpOverlay.Visibility = 'Collapsed'
    $script:overlay = ''
    $PrimaryButton.Focus() | Out-Null
}

function New-PreflightItem {
    param([string] $Glyph, [string] $Text, [ValidateSet('Good', 'Warn', 'Bad', 'Accent')][string] $Tone)
    # accent, background, stroke, text
    $palette = switch ($Tone) {
        'Good' { @('#4ADE9B', '#0D1712', '#1C3328', '#BFE9D3') }
        'Warn' { @('#F5B94F', '#17120B', '#3B2F1A', '#EBD3A4') }
        'Bad' { @('#FF6B81', '#180C11', '#44202B', '#F2B8C2') }
        default { @('#C58BE8', '#150F1B', '#2F2339', '#D9CCE4') }
    }
    [pscustomobject]@{
        Glyph      = $Glyph
        Text       = $Text
        Accent     = [Windows.Media.Brush](Get-Brush $palette[0])
        Background = [Windows.Media.Brush](Get-Brush $palette[1])
        Stroke     = [Windows.Media.Brush](Get-Brush $palette[2])
        TextBrush  = [Windows.Media.Brush](Get-Brush $palette[3])
    }
    # Brushes are cast: function output arrives wrapped in PSObject, which
    # WPF data binding cannot convert to a Brush.
}

function Update-Preflight {
    $snap = $script:snapshot
    $items = New-Object System.Collections.ArrayList
    if ($null -ne $snap) {
        if ($null -ne $snap.FreeGB -and $snap.FreeGB -lt 2) {
            [void]$items.Add((New-PreflightItem $glyph.Disk ('Only {0:N1} GB is free on {1}. Free up at least 2 GB first, or Windows cannot create the restore point.' -f $snap.FreeGB, $env:SystemDrive) 'Bad'))
        }
        if ($snap.OnBattery) {
            [void]$items.Add((New-PreflightItem $glyph.Battery 'This PC is on battery. Plug it in: it restarts up to twice and must not run out of power.' 'Warn'))
        }
        if ($snap.Domain) {
            [void]$items.Add((New-PreflightItem $glyph.Work 'This PC is managed by work or school. Their policy can turn VBS back on later.' 'Warn'))
        }
        if ($snap.BitLockerOn -eq $true) {
            [void]$items.Add((New-PreflightItem $glyph.Lock 'BitLocker is on. It is paused for up to two restarts and turned back on by itself. Keep your recovery key handy just in case.' 'Accent'))
        }
    }
    [void]$items.Add((New-PreflightItem $glyph.History 'A restore point is created and checked before anything changes. If that fails, nothing is changed.' 'Good'))
    $PreflightList.ItemsSource = $items
}

function Update-ConfirmButton {
    $ready = [bool]$AckSaved.IsChecked -and [bool]$AckPassword.IsChecked
    $ConfirmStart.IsEnabled = $ready
    if ($ready) {
        $ConfirmHint.Text = 'Ready. The safety checks run first, then the changes.'
        $ConfirmHintGlyph.Text = $glyph.Check
        $ConfirmHintGlyph.Foreground = Get-Brush $toneColors.Good
    }
    else {
        $ConfirmHint.Text = 'Tick both boxes to continue.'
        $ConfirmHintGlyph.Text = $glyph.Info
        $ConfirmHintGlyph.Foreground = Get-Brush $toneColors.Muted
    }
}

function Open-Confirm {
    if (Test-EngineBusy) { return }
    $AckSaved.IsChecked = $false
    $AckPassword.IsChecked = $false
    $ConfirmTitle.Text = "Turn off Hyper-V on $env:COMPUTERNAME?"
    Update-Preflight
    Update-ConfirmButton
    Open-Sheet -Name 'Confirm'
    $AckSaved.Focus() | Out-Null
}

# ---------------------------------------------------------------- data

function Update-StateCache {
    # Re-reads state.json only when it changed. Returns $true on change.
    $stamp = ''
    try {
        $info = New-Object IO.FileInfo $statePath
        if ($info.Exists) { $stamp = '{0}|{1}' -f $info.Length, $info.LastWriteTimeUtc.Ticks }
    }
    catch { }
    if ($stamp -eq $script:stateStamp) { return $false }
    $script:stateStamp = $stamp
    $script:state = $null
    if ($stamp) {
        try { $script:state = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json } catch { $script:stateStamp = '' }
    }
    return $true
}

function Get-CurrentState { return $script:state }

function ConvertTo-UiEvent {
    param([string] $Line)
    $trimmed = $Line.Trim([char[]]@([char]0xFEFF, [char]13, [char]10, [char]32, [char]9))
    if (-not $trimmed) { return $null }
    try { $parsed = $trimmed | ConvertFrom-Json } catch { return $null }
    if (-not (Test-HasProperty $parsed 'Message')) { return $null }
    foreach ($name in 'Timestamp', 'Level', 'Code', 'ActionRequired') {
        if (-not (Test-HasProperty $parsed $name)) { $parsed | Add-Member -NotePropertyName $name -NotePropertyValue '' }
    }
    if (-not $parsed.Level) { $parsed.Level = 'Info' }
    $at = $null
    if ($parsed.Timestamp) { try { $at = ([datetime]"$($parsed.Timestamp)").ToLocalTime() } catch { } }
    $parsed | Add-Member -NotePropertyName At -NotePropertyValue $at -Force
    return $parsed
}

function Read-NewEvents {
    # Incrementally reads only the bytes appended since the last call, sharing
    # the file so the engine can keep writing. Returns $true when new events arrived.
    $info = New-Object IO.FileInfo $eventLogPath
    if (-not $info.Exists) {
        if ($script:events.Count -gt 0 -or $script:eventOffset -ne 0) {
            $script:events = New-Object System.Collections.ArrayList
            $script:eventOffset = [long]0
            return $true
        }
        return $false
    }
    if ($info.Length -eq $script:eventOffset) { return $false }
    $reset = $false
    if ($info.Length -lt $script:eventOffset) {
        $script:events = New-Object System.Collections.ArrayList
        $script:eventOffset = [long]0
        $reset = $true
    }
    $skipPartialLine = $false
    if ($script:eventOffset -eq 0 -and $info.Length -gt 512KB) {
        $script:eventOffset = $info.Length - 512KB
        $skipPartialLine = $true
    }
    $buffer = $null
    $read = 0
    $stream = $null
    try {
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = New-Object IO.FileStream($eventLogPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        [void]$stream.Seek($script:eventOffset, [IO.SeekOrigin]::Begin)
        $length = [int][Math]::Min($stream.Length - $script:eventOffset, 16MB)
        if ($length -le 0) { return $reset }
        $buffer = New-Object byte[] $length
        while ($read -lt $length) {
            $count = $stream.Read($buffer, $read, $length - $read)
            if ($count -le 0) { break }
            $read += $count
        }
    }
    catch { return $reset }
    finally { if ($null -ne $stream) { $stream.Dispose() } }
    if ($read -le 0) { return $reset }

    # Consume complete lines only; a line still being written is picked up next time.
    $lastNewline = [Array]::LastIndexOf($buffer, [byte]10, $read - 1)
    if ($lastNewline -lt 0) { return $reset }
    $start = 0
    if ($skipPartialLine) { $start = [Array]::IndexOf($buffer, [byte]10) + 1 }
    $text = [Text.Encoding]::UTF8.GetString($buffer, $start, $lastNewline + 1 - $start)
    $script:eventOffset += ($lastNewline + 1)
    foreach ($line in $text.Split([char]10)) {
        $item = ConvertTo-UiEvent $line
        if ($null -ne $item) { [void]$script:events.Add($item) }
    }
    if ($script:events.Count -gt 1500) { $script:events.RemoveRange(0, $script:events.Count - 1000) }
    return $true
}

function Update-EventInsights {
    $all = $script:events
    $restartUntil = [datetime]::MinValue
    $restartAt = $null
    $restartFound = $false
    $failures = 0
    $failuresDone = $false
    $runStart = -1
    for ($i = $all.Count - 1; $i -ge 0; $i--) {
        $item = $all[$i]
        $code = "$($item.Code)"
        if (-not $restartFound -and $code -in @('RESTART_SCHEDULED', 'RESTART_CANCELLED', 'MANUAL_RESTART_REQUIRED', 'RESTART_NOW')) {
            $restartFound = $true
            $restartAt = $item.At
            if ($null -ne $item.At) {
                if ($code -eq 'RESTART_SCHEDULED') { $restartUntil = $item.At.AddSeconds(32) }
                elseif ($code -eq 'RESTART_NOW') { $restartUntil = $item.At.AddSeconds(6) }
            }
        }
        if (-not $failuresDone) {
            if ($code -in @('WORKFLOW_STARTED', 'CONTINUATION_STARTED', 'VERIFICATION_PASSED', 'VERIFY_ONLY_PASSED', 'ALREADY_DISABLED', 'SKIP_ALREADY_OFF')) { $failuresDone = $true }
            elseif ("$($item.Level)" -eq 'Error') { $failures++ }
        }
        if ($runStart -lt 0 -and $code -eq 'WORKFLOW_STARTED') { $runStart = $i }
    }

    $codes = @{}
    $fix = $null
    $fixFallback = $null
    $from = [Math]::Max(0, $runStart)
    for ($i = $all.Count - 1; $i -ge $from; $i--) {
        $item = $all[$i]
        if ($runStart -ge 0) { $codes["$($item.Code)"] = $true }
        if ($null -eq $fix -and "$($item.Level)" -eq 'Error') { $fix = $item }
        if ($null -eq $fixFallback -and "$($item.Level)" -eq 'Warning' -and "$($item.ActionRequired)") { $fixFallback = $item }
    }
    if ($null -eq $fix) { $fix = $fixFallback }

    $script:insight.RestartPendingUntil = $restartUntil
    $script:insight.RestartRequestAt = $restartAt
    $script:insight.FailureCount = $failures
    $script:insight.RunCodes = $codes
    $script:insight.HasRunStart = ($runStart -ge 0)
    $script:insight.RunStartAt = if ($runStart -ge 0) { $all[$runStart].At } else { $null }
    $script:insight.Fix = $fix
    $script:insight.Latest = if ($all.Count) { $all[$all.Count - 1] } else { $null }

    $ActivityBadge.Visibility = if ($failures -gt 0) { 'Visible' } else { 'Collapsed' }
    $ActivityBadgeText.Text = "$failures"
}

function Add-UiEvent {
    param(
        [ValidateSet('Info', 'Success', 'Action', 'Warning', 'Error')][string] $Level,
        [string] $Code,
        [string] $Message,
        [string] $ActionRequired = ''
    )
    try {
        [pscustomobject]@{
            Timestamp      = (Get-Date).ToString('o')
            RunId          = 'console-ui'
            Level          = $Level
            Code           = $Code
            Message        = $Message
            ActionRequired = $ActionRequired
        } | ConvertTo-Json -Compress | Add-Content -LiteralPath $eventLogPath -Encoding UTF8
    }
    catch { Write-UiTrace $_ }
    if (Read-NewEvents) {
        Update-EventInsights
        Update-ActivityList
    }
}

function Format-EventTime {
    param($At)
    if ($null -eq $At) { return @('', '') }
    $today = (Get-Date).Date
    $day = if ($At.Date -eq $today) { 'Today' } elseif ($At.Date -eq $today.AddDays(-1)) { 'Yesterday' } else { $At.ToString('d MMM') }
    return @($At.ToString('HH:mm:ss'), $day)
}

function Convert-ToActivityItem {
    param($Item)
    $level = "$($Item.Level)"
    # accent, card background, card stroke, icon background, glyph
    $palette = switch ($level) {
        'Success' { @('#4ADE9B', '#0E1512', '#1C3328', '#123023', $glyph.Check) }
        'Action' { @('#E063E8', '#150E19', '#3A2448', '#2A1435', $glyph.Forward) }
        'Warning' { @('#F5B94F', '#16120C', '#3B2F1A', '#2A2112', $glyph.Warning) }
        'Error' { @('#FF6B81', '#170C11', '#44202B', '#2E121B', $glyph.Cancel) }
        default { @('#B8ACC4', '#110D15', '#231A2B', '#1D1524', $glyph.Info) }
    }
    $action = "$($Item.ActionRequired)"
    $time = Format-EventTime $Item.At
    $levelLabel = switch ($level) { 'Action' { 'ACTION NEEDED' } 'Error' { 'FAILED' } 'Success' { 'DONE' } default { $level.ToUpperInvariant() } }
    [pscustomobject]@{
        Time             = $time[0]
        Day              = $time[1]
        Level            = $levelLabel
        Message          = "$($Item.Message)"
        Action           = $action
        ActionVisibility = if ($action) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
        Accent           = [Windows.Media.Brush](Get-Brush $palette[0])
        Background       = [Windows.Media.Brush](Get-Brush $palette[1])
        Stroke           = [Windows.Media.Brush](Get-Brush $palette[2])
        IconBackground   = [Windows.Media.Brush](Get-Brush $palette[3])
        Glyph            = [string]$palette[4]
    }
}

function Update-ActivityList {
    $filter = if ($ActionFilter.IsChecked) { 1 } elseif ($FailureFilter.IsChecked) { 2 } else { 0 }
    $all = $script:events
    $signature = '{0}|{1}|{2}|{3}' -f $all.Count, $script:eventOffset, $filter, (Get-Date).Date.Ticks
    if ($signature -eq $script:activitySignature) { return }
    $script:activitySignature = $signature

    $items = New-Object System.Collections.ArrayList
    for ($i = $all.Count - 1; $i -ge 0 -and $items.Count -lt 150; $i--) {
        $item = $all[$i]
        if ($filter -eq 1 -and -not "$($item.ActionRequired)") { continue }
        if ($filter -eq 2 -and "$($item.Level)" -ne 'Error') { continue }
        [void]$items.Add((Convert-ToActivityItem $item))
    }
    $ActivityList.ItemsSource = $items
    $ActivityScroll.ScrollToTop()
    $middot = [char]0x00B7
    $ActivityCaption.Text = if ($all.Count) { "Newest first  $middot  $($all.Count) entries. Only results that matter and anything you need to fix." }
                            else { 'Only results that matter and anything you need to fix are shown here.' }
    $OpenReportButton.Visibility = if (Test-Path -LiteralPath $reportPath) { 'Visible' } else { 'Collapsed' }

    if ($items.Count -eq 0) {
        $ActivityEmpty.Visibility = 'Visible'
        if ($filter -eq 0) {
            $ActivityEmptyTitle.Text = 'Nothing here yet'
            $ActivityEmptyBody.Text = 'Check the PC or start the process. Results show up here as they happen.'
        }
        else {
            $ActivityEmptyTitle.Text = 'All clear'
            $ActivityEmptyBody.Text = if ($filter -eq 1) { 'Nothing needs your attention right now.' } else { 'No failures have been logged.' }
        }
    }
    else { $ActivityEmpty.Visibility = 'Collapsed' }
}

# ---------------------------------------------------------------- live status (background)

$script:sync = [hashtable]::Synchronized(@{
    Snapshot        = $null
    Version         = 0
    Stop            = $false
    Poke            = $false
    IntervalMs      = 3000
    WantDefender    = $false
    Defender        = $null
    DefenderVersion = 0
})

$pollerScript = {
    param($sync, $taskName, $taskFile)
    Set-StrictMode -Off
    $ErrorActionPreference = 'Continue'
    function Has($o, $n) { return ($null -ne $o -and $null -ne $o.PSObject.Properties[$n]) }

    $productType = $null
    $caption = ''
    $bootTime = $null
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        if (Has $os 'ProductType') { $productType = [int]$os.ProductType }
        if (Has $os 'Caption') { $caption = ("$($os.Caption)" -replace '^Microsoft\s+', '').Trim() }
        if (Has $os 'LastBootUpTime') { $bootTime = [datetime]$os.LastBootUpTime }
    }
    catch { }

    $loop = 0
    $onBattery = $false
    $bitLocker = $null
    while (-not $sync.Stop) {
        $snap = [ordered]@{
            Taken = Get-Date; Hypervisor = $null; VbsStatus = $null; Domain = $null; AlreadyOff = $false
            CredentialGuard = $null; MemoryIntegrity = $null
            TaskExists = $false; EngineRunning = $false; EngineVerify = $false; EngineContinuation = $false
            OnBattery = $false; FreeGB = $null; BitLockerOn = $null
            ProductType = $productType; OsCaption = $caption; BootTime = $bootTime
        }
        try {
            $system = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
            if (Has $system 'HypervisorPresent') { $snap.Hypervisor = [bool]$system.HypervisorPresent }
            if (Has $system 'PartOfDomain') { $snap.Domain = [bool]$system.PartOfDomain }
        }
        catch { }
        try {
            $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
            if (Has $dg 'VirtualizationBasedSecurityStatus') { $snap.VbsStatus = [int]$dg.VirtualizationBasedSecurityStatus }
            if (Has $dg 'SecurityServicesRunning') {
                $running = @($dg.SecurityServicesRunning | ForEach-Object { [int]$_ })
                $snap.CredentialGuard = ($running -contains 1)
                $snap.MemoryIntegrity = ($running -contains 2)
            }
        }
        catch { }
        $snap.AlreadyOff = ($snap.Hypervisor -eq $false) -and ($snap.VbsStatus -eq 0)

        $taskFound = $false
        try { $taskFound = $null -ne (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) } catch { }
        if (-not $taskFound) { try { $taskFound = Test-Path -LiteralPath $taskFile } catch { } }
        $snap.TaskExists = $taskFound

        try {
            $engines = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop |
                Where-Object { "$($_.CommandLine)" -match 'Disable-HyperV-Fully\.ps1' })
            $snap.EngineRunning = ($engines.Count -gt 0)
            $snap.EngineVerify = (@($engines | Where-Object { "$($_.CommandLine)" -match '-VerifyOnly' }).Count -gt 0)
            $snap.EngineContinuation = (@($engines | Where-Object { "$($_.CommandLine)" -match '-ContinueAfterRestart' }).Count -gt 0)
        }
        catch { }

        try {
            $drive = New-Object IO.DriveInfo ($env:SystemDrive)
            $snap.FreeGB = [Math]::Round($drive.AvailableFreeSpace / 1GB, 1)
        }
        catch { }

        if (($loop % 5) -eq 0) {
            try {
                $batteries = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop)
                $onBattery = (@($batteries | Where-Object { [int]$_.BatteryStatus -in 1, 4, 5 }).Count -gt 0)
            }
            catch { $onBattery = $false }
        }
        if (($loop % 10) -eq 0) {
            try {
                $volume = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume `
                    -Filter ("DriveLetter='{0}'" -f $env:SystemDrive) -ErrorAction Stop | Select-Object -First 1
                $bitLocker = if ($null -ne $volume -and (Has $volume 'ProtectionStatus')) { [int]$volume.ProtectionStatus -eq 1 } else { $null }
            }
            catch { $bitLocker = $null }
        }
        $snap.OnBattery = $onBattery
        $snap.BitLockerOn = $bitLocker

        if ($sync.WantDefender) {
            $defender = @{ TamperProtection = 'Unavailable'; RealTimeProtection = 'Unavailable'; Service = 'Unavailable'; TamperOn = $false }
            try {
                $mp = Get-MpComputerStatus -ErrorAction Stop
                $defender.TamperOn = [bool]$mp.IsTamperProtected
                $defender.TamperProtection = if ($defender.TamperOn) { 'On' } else { 'Off' }
                $defender.RealTimeProtection = if ([bool]$mp.RealTimeProtectionEnabled) { 'On' } else { 'Off' }
            }
            catch { }
            try { $defender.Service = "$((Get-Service -Name WinDefend -ErrorAction Stop).Status)" } catch { }
            $sync.Defender = $defender
            $sync.DefenderVersion = $sync.DefenderVersion + 1
        }

        $sync.Snapshot = [pscustomobject]$snap
        $sync.Version = $sync.Version + 1
        $loop++

        $waited = 0
        while (-not $sync.Stop -and -not $sync.Poke -and $waited -lt $sync.IntervalMs) {
            Start-Sleep -Milliseconds 100
            $waited += 100
        }
        $sync.Poke = $false
    }
}

$script:poller = $null
function Start-StatusPoller {
    try {
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.ApartmentState = [System.Threading.ApartmentState]::MTA
        $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $runspace.Open()
        $shell = [powershell]::Create()
        $shell.Runspace = $runspace
        [void]$shell.AddScript($pollerScript.ToString()).AddArgument($script:sync).AddArgument($continuationTaskName).AddArgument($continuationTaskFile)
        $script:poller = @{ Shell = $shell; Runspace = $runspace; Handle = $shell.BeginInvoke() }
    }
    catch {
        Write-UiTrace $_
        Show-Toast 'Live status is unavailable. The tool still works; status may be out of date.' 'Warn'
    }
}

function Stop-StatusPoller {
    $script:sync.Stop = $true
    if ($null -eq $script:poller) { return }
    try { [void]$script:poller.Shell.BeginStop($null, $null) } catch { }
    $script:poller = $null
}

function Test-EngineBusy {
    if ($null -ne $script:engineProcess) {
        try { if (-not $script:engineProcess.HasExited) { return $true } } catch { }
    }
    $snap = $script:snapshot
    return ($null -ne $snap -and $snap.EngineRunning -and $snap.Taken -gt $script:engineExitedAt)
}

function Get-EngineMode {
    if ($null -ne $script:engineProcess -and $script:engineMode) { return $script:engineMode }
    $snap = $script:snapshot
    if ($null -ne $snap) {
        if ($snap.EngineVerify) { return 'Verify' }
        if ($snap.EngineContinuation) { return 'Continue' }
    }
    return 'Run'
}

# ---------------------------------------------------------------- view

function New-Guide {
    param([string] $Text, [string] $Detail = '', [ValidateSet('Accent', 'Good', 'Warn', 'Bad', 'Neutral')][string] $Tone = 'Accent')
    return @{ Text = $Text; Detail = $Detail; Tone = $Tone }
}

function Get-RunProgress {
    $codes = $script:insight.RunCodes
    $runStartAt = $script:insight.RunStartAt
    # A run this window just started has not logged yet: do not show the previous run's progress.
    if ($null -ne $script:engineStartedAt -and ($null -eq $runStartAt -or $runStartAt -lt $script:engineStartedAt.AddSeconds(-5))) { $codes = @{} }
    $hasBackup = (-not $script:insight.HasRunStart) -and (Test-HasProperty $script:state 'RestorePointDescription')
    if (-not $hasBackup -and -not $codes.ContainsKey('RESTORE_POINT_CREATED')) {
        return @{ Step = 1; Caption = 'Restore point'; Detail = 'Creating and checking a restore point. This usually takes one to three minutes.' }
    }
    if (-not $hasBackup -and -not $codes.ContainsKey('SAFETY_BACKUP_CREATED')) {
        return @{ Step = 1; Caption = 'Saving settings'; Detail = 'Saving the current boot and security settings.' }
    }
    if (-not $codes.ContainsKey('VBS_POLICY_DISABLED')) {
        return @{ Step = 2; Caption = 'Preparing'; Detail = 'Pausing BitLocker and setting up the restart helper.' }
    }
    if (-not ($codes.ContainsKey('FEATURES_DISABLED') -or $codes.ContainsKey('FEATURE_DISABLE_FAILED') -or $codes.ContainsKey('FEATURE_INVENTORY_FAILED'))) {
        return @{ Step = 2; Caption = 'Windows features'; Detail = 'Removing the Hyper-V, Windows Sandbox and WSL 2 features. This is the longest part.' }
    }
    if (-not ($codes.ContainsKey('BOOT_CONFIGURATION_APPLIED') -or $codes.ContainsKey('BOOT_CONFIGURATION_FAILED'))) {
        return @{ Step = 2; Caption = 'Boot settings'; Detail = 'Telling Windows not to start the hypervisor at boot.' }
    }
    return @{ Step = 2; Caption = 'Finishing'; Detail = 'Getting everything ready for the restart.' }
}

function Get-ViewModel {
    $snap = $script:snapshot
    $state = $script:state
    $now = Get-Date
    $vm = @{
        Name = 'Ready'; Tone = 'Accent'; Glyph = $glyph.Power; Spin = $false; Breathe = $false
        Pill = 'READY'; Kicker = ''; Title = ''; Subtitle = ''
        Steps = @('Pending', 'Pending', 'Pending', 'Pending'); Captions = @('', '', '', '')
        Guide = @(); GuideTitle = 'WHAT TO DO NOW'
        FooterTitle = ''; FooterSubtitle = ''
        PrimaryText = 'Turn off Hyper-V'; PrimaryGlyph = $glyph.Forward; PrimaryEnabled = $false; PrimaryAction = 'None'
        ShowVerify = $false; VerifyEnabled = $false; ShowCancelRestart = $false; Busy = $false; ShowLatest = $true
    }

    $stateCompleted = (Test-HasProperty $state 'Completed') -and [bool]$state.Completed
    $attempt = if (Test-HasProperty $state 'Attempt') { [int]$state.Attempt } else { 1 }
    $uefiStaged = (Test-HasProperty $state 'UefiOptOutStaged') -and [bool]$state.UefiOptOutStaged
    $restartPending = $now -lt $script:insight.RestartPendingUntil
    $restartArmed = $now -lt $script:restartArmedUntil
    $firmwareGuide = New-Guide 'If a blue Microsoft screen appears while the PC starts, press the key it shows (usually F3).' 'This approves removing the firmware lock. If you miss it, Windows still starts; run the tool again afterwards.' 'Warn'
    $passwordGuide = New-Guide 'Sign in with your password.' 'The PIN option is gone on purpose. This window reopens and finishes by itself.' 'Accent'

    if ($null -eq $snap) {
        $vm.Name = 'Checking'; $vm.Tone = 'Neutral'; $vm.Glyph = $glyph.Search; $vm.Spin = $true
        $vm.Pill = 'CHECKING'; $vm.Kicker = 'ONE MOMENT'
        $vm.Title = 'Checking this PC...'
        $vm.Subtitle = 'Reading the current Hyper-V and security settings. Nothing is changed.'
        $vm.Guide = @(New-Guide 'Nothing to do yet.' 'The status appears in a second or two.' 'Neutral')
        $vm.FooterTitle = 'Checking this PC...'
        $vm.FooterSubtitle = 'This only reads settings.'
        $vm.ShowLatest = $false
        return $vm
    }

    $busy = Test-EngineBusy
    $mode = Get-EngineMode
    $verifyAllowed = -not $busy -and -not $snap.TaskExists
    $vm.ShowVerify = $true
    $vm.VerifyEnabled = $verifyAllowed

    if ($busy -and $mode -eq 'Verify') {
        $vm.Name = 'Verifying'; $vm.Tone = 'Accent'; $vm.Glyph = $glyph.Search; $vm.Spin = $true; $vm.Busy = $true
        $vm.Pill = 'CHECKING'; $vm.Kicker = 'READ-ONLY CHECK'
        $vm.Title = 'Checking this PC...'
        $vm.Subtitle = 'Reading boot, feature and security settings. Nothing is being changed.'
        $vm.Steps = @('Pending', 'Pending', 'Pending', 'Active'); $vm.Captions = @('', '', '', 'Checking')
        $vm.Guide = @(New-Guide 'Nothing to do. This takes under a minute.' 'The result appears here and on the Activity page.' 'Neutral')
        $vm.FooterTitle = 'Checking this PC...'
        $vm.FooterSubtitle = 'Read-only. Nothing is changed.'
        $vm.PrimaryText = 'Checking...'; $vm.PrimaryGlyph = ''
        $vm.ShowVerify = $false
        return $vm
    }

    if ($busy -and $mode -eq 'Continue') {
        $vm.Name = 'Finishing'; $vm.Tone = 'Accent'; $vm.Glyph = $glyph.Sync; $vm.Spin = $true; $vm.Busy = $true
        $vm.Pill = 'FINISHING'; $vm.Kicker = 'STEP 4 OF 4'
        $vm.Title = 'Finishing up...'
        $vm.Subtitle = 'The tool picked up where it left off after the restart and is confirming every part is off.'
        $vm.Steps = @('Done', 'Done', 'Done', 'Active'); $vm.Captions = @('', '', '', 'Verifying')
        $vm.Guide = @(
            (New-Guide 'Leave the PC on for a minute or two.' 'You do not need to do anything else.' 'Accent'),
            (New-Guide 'If it needs one more restart, you get a 30-second warning.' 'Save anything you open in the meantime.' 'Neutral')
        )
        $vm.FooterTitle = 'Finishing after the restart...'
        $vm.FooterSubtitle = 'Checking that Hyper-V, VBS and their features are all off.'
        $vm.PrimaryText = 'Finishing...'; $vm.PrimaryGlyph = ''
        $vm.ShowVerify = $false
        return $vm
    }

    if ($busy) {
        $progress = Get-RunProgress
        $vm.Name = 'Working'; $vm.Tone = 'Accent'; $vm.Glyph = $glyph.Sync; $vm.Spin = $true; $vm.Busy = $true
        $vm.Pill = 'WORKING'; $vm.Kicker = ('STEP {0} OF 4' -f $progress.Step)
        $vm.Title = 'Turning off Hyper-V...'
        $vm.Subtitle = $progress.Detail
        if ($progress.Step -eq 1) { $vm.Steps = @('Active', 'Pending', 'Pending', 'Pending'); $vm.Captions = @($progress.Caption, '', '', '') }
        else { $vm.Steps = @('Done', 'Active', 'Pending', 'Pending'); $vm.Captions = @('', $progress.Caption, '', '') }
        $reopenText = if ($ReopenToggle.IsChecked) { 'It carries on in the background, and this window reopens after the restart.' }
                      else { 'It carries on in the background. Open the tool again after the restart to see the result.' }
        $restartText = if ($AutoRestartToggle.IsChecked) { New-Guide 'Save your work now.' 'Windows restarts by itself when this part finishes, after a 30-second warning.' 'Warn' }
                       else { New-Guide 'Save your work.' 'You will be asked to restart when this part finishes.' 'Neutral' }
        $vm.Guide = @(
            (New-Guide 'Keep the PC on and plugged in.' 'Do not turn it off while this runs.' 'Accent'),
            $restartText,
            (New-Guide 'You can close this window.' $reopenText 'Neutral')
        )
        $vm.FooterTitle = 'Working on it...'
        $vm.FooterSubtitle = ('Step {0} of 4: {1}' -f $progress.Step, $progress.Caption)
        $vm.PrimaryText = 'Working...'; $vm.PrimaryGlyph = ''
        $vm.ShowVerify = $false
        return $vm
    }

    if ($snap.TaskExists) {
        $restartedSince = ($null -ne $script:insight.RestartRequestAt) -and ($null -ne $snap.BootTime) -and
                          ($script:insight.RestartRequestAt -lt $snap.BootTime)
        if ($restartPending) {
            $seconds = [int][Math]::Max(0, [Math]::Ceiling(($script:insight.RestartPendingUntil - $now).TotalSeconds))
            $vm.Name = 'RestartCountdown'; $vm.Tone = 'Warn'; $vm.Glyph = $glyph.Restart; $vm.Breathe = $true; $vm.Busy = $true
            $vm.Pill = 'RESTARTING'; $vm.Kicker = ('STEP 3 OF 4' + $(if ($attempt -gt 1) { '  /  RESTART 2 OF 2' } else { '' }))
            $vm.Title = if ($seconds -gt 0) { "Restarting in $seconds seconds." } else { 'Restarting now.' }
            $vm.Subtitle = 'Save anything you have open. The tool continues by itself after you sign in.'
            $vm.Steps = @('Done', 'Done', 'Active', 'Pending'); $vm.Captions = @('', '', "Restart $attempt of 2", '')
            $guide = New-Object System.Collections.ArrayList
            [void]$guide.Add((New-Guide 'Save your work now.' 'Windows closes all apps when it restarts.' 'Warn'))
            if ($uefiStaged) { [void]$guide.Add($firmwareGuide) }
            [void]$guide.Add($passwordGuide)
            $vm.Guide = @($guide)
            $vm.FooterTitle = if ($seconds -gt 0) { "Restarting in $seconds s. Save your work." } else { 'Restarting now...' }
            $vm.FooterSubtitle = 'Cancel restart if you need more time; then restart yourself later.'
            $vm.PrimaryText = if ($restartArmed) { 'Click again to restart' } else { 'Restart now' }
            $vm.PrimaryGlyph = $glyph.Restart; $vm.PrimaryEnabled = $true; $vm.PrimaryAction = 'Restart'
            $vm.ShowCancelRestart = $true
            $vm.ShowVerify = $false
            return $vm
        }
        if ($restartedSince) {
            $minutes = ($now - $snap.BootTime).TotalMinutes
            $vm.Name = 'FinishingPending'; $vm.Tone = 'Accent'; $vm.Glyph = $glyph.Sync; $vm.Spin = $true; $vm.Busy = $true
            $vm.Pill = 'FINISHING'; $vm.Kicker = 'STEP 4 OF 4'
            $vm.Title = 'Finishing up...'
            $vm.Subtitle = 'Windows has restarted. The final checks start by themselves in the background.'
            $vm.Steps = @('Done', 'Done', 'Done', 'Active'); $vm.Captions = @('', '', '', 'Starting')
            if ($minutes -lt 10) {
                $vm.Guide = @(New-Guide 'Leave the PC on for a few minutes.' 'You do not need to do anything else.' 'Accent')
            }
            else {
                $vm.Guide = @(
                    (New-Guide 'This is taking longer than expected.' 'The final checks should have started by now.' 'Warn'),
                    (New-Guide 'Restart the PC once more.' 'The checks run automatically when Windows starts.' 'Accent')
                )
            }
            $vm.FooterTitle = 'Finishing after the restart...'
            $vm.FooterSubtitle = 'Nothing for you to do.'
            $vm.PrimaryText = 'Finishing...'; $vm.PrimaryGlyph = ''
            $vm.ShowVerify = $false
            return $vm
        }
        $vm.Name = 'WaitingRestart'; $vm.Tone = 'Warn'; $vm.Glyph = $glyph.Restart; $vm.Breathe = $true
        $vm.Pill = 'RESTART NEEDED'; $vm.Kicker = 'STEP 3 OF 4'
        $vm.Title = 'Restart to continue.'
        $vm.Subtitle = 'Everything is ready. Restart when it suits you; the tool finishes by itself after you sign in.'
        $vm.Steps = @('Done', 'Done', 'Active', 'Pending'); $vm.Captions = @('', '', "Restart $attempt of 2", '')
        $guide = New-Object System.Collections.ArrayList
        [void]$guide.Add((New-Guide 'Save your work, then click Restart now.' 'Or restart from the Start menu whenever you are ready.' 'Warn'))
        if ($uefiStaged) { [void]$guide.Add($firmwareGuide) }
        [void]$guide.Add($passwordGuide)
        $vm.Guide = @($guide)
        $vm.FooterTitle = 'Waiting for a restart.'
        $vm.FooterSubtitle = 'Nothing else happens until Windows restarts.'
        $vm.PrimaryText = if ($restartArmed) { 'Click again to restart' } else { 'Restart now' }
        $vm.PrimaryGlyph = $glyph.Restart; $vm.PrimaryEnabled = $true; $vm.PrimaryAction = 'Restart'
        $vm.ShowVerify = $false
        return $vm
    }

    if ($snap.AlreadyOff) {
        $vm.Name = 'Off'; $vm.Tone = 'Good'; $vm.Glyph = $glyph.Check
        $vm.Pill = 'HYPER-V IS OFF'
        $vm.Title = 'Hyper-V is off.'
        $vm.Steps = @('Done', 'Done', 'Done', 'Done')
        if ($stateCompleted) {
            $vm.Kicker = 'ALL DONE'
            $vm.Subtitle = 'The hypervisor and VBS are no longer running. You do not need to run this tool again.'
            $vm.Guide = @(
                (New-Guide 'Sign in with your password from now on.' 'Windows Hello PIN sign-in stays off.' 'Good'),
                (New-Guide 'Apps that need Hyper-V will not start.' 'For example WSL 2, Windows Sandbox and Hyper-V virtual machines.' 'Neutral'),
                (New-Guide 'Changed your mind? Use System Restore.' 'Open Help for the steps.' 'Neutral')
            )
            $vm.FooterTitle = 'Finished. Nothing left to do.'
        }
        else {
            $vm.Kicker = 'NOTHING TO DO'
            $vm.Subtitle = 'No hypervisor is running and VBS is off, so there is nothing to change on this PC.'
            $vm.Guide = @(
                (New-Guide 'You do not need to run this tool.' 'Nothing was changed.' 'Good'),
                (New-Guide 'Close this window when you are done.' '' 'Neutral')
            )
            $vm.FooterTitle = 'Hyper-V is already off.'
        }
        $vm.FooterSubtitle = 'You can close this window. It will not open by itself again.'
        $vm.PrimaryText = 'Close'; $vm.PrimaryGlyph = ''; $vm.PrimaryEnabled = $true; $vm.PrimaryAction = 'Close'
        return $vm
    }

    $liveUnknown = ($null -eq $snap.Hypervisor) -or ($null -eq $snap.VbsStatus)
    $fix = $script:insight.Fix
    $fixAction = if ($null -ne $fix -and "$($fix.ActionRequired)") { "$($fix.ActionRequired)" } else { '' }

    if ($stateCompleted -and $liveUnknown) {
        $vm.Name = 'FinishedUnknown'; $vm.Tone = 'Good'; $vm.Glyph = $glyph.Check
        $vm.Pill = 'FINISHED'; $vm.Kicker = 'FINISHED'
        $vm.Title = 'The run has finished.'
        $vm.Subtitle = 'Windows is not reporting live status right now, so the final report has the verified result.'
        $vm.Steps = @('Done', 'Done', 'Done', 'Done')
        $vm.Guide = @(
            (New-Guide 'Open the final report to see the result.' 'It lists anything that is still on.' 'Accent'),
            (New-Guide 'Sign in with your password from now on.' 'Windows Hello PIN sign-in stays off.' 'Neutral')
        )
        $vm.FooterTitle = 'The run has finished.'
        $vm.FooterSubtitle = 'The final report has the verified result.'
        if (Test-Path -LiteralPath $reportPath) {
            $vm.PrimaryText = 'Open final report'; $vm.PrimaryGlyph = $glyph.Report; $vm.PrimaryEnabled = $true; $vm.PrimaryAction = 'Report'
        }
        else {
            $vm.PrimaryText = 'Close'; $vm.PrimaryGlyph = ''; $vm.PrimaryEnabled = $true; $vm.PrimaryAction = 'Close'
        }
        return $vm
    }

    if ($stateCompleted) {
        $vm.Name = 'FinishedButOn'; $vm.Tone = 'Warn'; $vm.Glyph = $glyph.Warning
        $vm.Pill = 'NEEDS ATTENTION'; $vm.Kicker = 'NEEDS ATTENTION'
        $vm.Title = 'Not everything is off yet.'
        $vm.Subtitle = if ($null -ne $fix) { "$($fix.Message)" } else { 'The run finished, but this PC still reports Hyper-V or VBS as active.' }
        $vm.Steps = @('Done', 'Done', 'Done', 'Failed'); $vm.Captions = @('', '', '', 'Still on')
        $vm.Guide = @(
            (New-Guide 'Fix this first:' $(if ($fixAction) { $fixAction } else { 'Open the Activity page to see what is still on.' }) 'Warn'),
            (New-Guide 'Then click Run again.' 'The safety checks run again before anything changes.' 'Accent')
        )
        $vm.FooterTitle = 'Something is still switched on.'
        $vm.FooterSubtitle = 'Fix the item on the left, then run it again.'
        $vm.PrimaryText = 'Run again'; $vm.PrimaryEnabled = $true; $vm.PrimaryAction = 'Confirm'
        return $vm
    }

    if (Test-HasProperty $state 'Attempt') {
        $hasBackup = Test-HasProperty $state 'RestorePointDescription'
        $vm.Name = 'Incomplete'; $vm.Tone = 'Warn'; $vm.Glyph = $glyph.Warning
        $vm.Pill = 'NEEDS ATTENTION'; $vm.Kicker = 'STOPPED EARLY'
        $vm.Title = 'The last run did not finish.'
        $vm.Subtitle = if ($null -ne $fix) { "$($fix.Message)" } else { 'It stopped before everything was turned off. Partly prepared restart steps were cleaned up.' }
        if ($hasBackup) { $vm.Steps = @('Done', 'Failed', 'Pending', 'Pending'); $vm.Captions = @('', 'Stopped', '', '') }
        else { $vm.Steps = @('Failed', 'Pending', 'Pending', 'Pending'); $vm.Captions = @('Stopped', '', '', '') }
        $vm.Guide = @(
            (New-Guide 'Fix this first:' $(if ($fixAction) { $fixAction } else { 'Open the Activity page to see what stopped it.' }) 'Warn'),
            (New-Guide 'Then click Try again.' 'The safety checks run again before anything changes.' 'Accent')
        )
        $vm.FooterTitle = 'The last attempt stopped early.'
        $vm.FooterSubtitle = 'Fix the item on the left, then try again.'
        $vm.PrimaryText = 'Try again'; $vm.PrimaryEnabled = $true; $vm.PrimaryAction = 'Confirm'
        return $vm
    }

    if ($null -ne $snap.ProductType -and $snap.ProductType -ne 1) {
        $vm.Name = 'Unsupported'; $vm.Tone = 'Bad'; $vm.Glyph = $glyph.Cancel
        $vm.Pill = 'NOT SUPPORTED'; $vm.Kicker = 'WINDOWS SERVER'
        $vm.Title = 'This edition is not supported.'
        $vm.Subtitle = 'Windows Server has no System Restore, so the tool cannot create the restore point it needs before changing anything. Nothing has been changed.'
        $vm.Guide = @(
            (New-Guide 'Use this tool on Windows 10 or Windows 11.' '' 'Bad'),
            (New-Guide 'Want to see the current state anyway?' 'Click Check this PC. It only reads settings.' 'Neutral')
        )
        $vm.FooterTitle = 'Windows Server is not supported.'
        $vm.FooterSubtitle = 'Nothing has been changed.'
        $vm.PrimaryText = 'Not supported'; $vm.PrimaryGlyph = ''
        return $vm
    }

    # Ready
    $vm.Name = 'Ready'; $vm.Tone = 'Accent'; $vm.Glyph = $glyph.Power; $vm.Breathe = $true
    $vm.Pill = if ($snap.Hypervisor) { 'HYPER-V IS ON' } else { 'READY' }
    $vm.Kicker = 'BEFORE YOU START'
    $vm.Title = 'Ready to turn off Hyper-V.'
    $vm.Subtitle = 'Nothing changes until you confirm. It takes a few minutes and up to two restarts, and the tool carries on by itself.'
    $guide = New-Object System.Collections.ArrayList
    [void]$guide.Add((New-Guide 'Save your work and close other apps.' 'The PC restarts up to twice.' 'Accent'))
    [void]$guide.Add((New-Guide 'Make sure you know your Windows password.' 'PIN sign-in is removed. You will sign in with your Microsoft account or local password.' 'Accent'))
    if ($snap.OnBattery) { [void]$guide.Add((New-Guide 'Plug in your PC.' 'It is on battery right now and must not run out of power during the restarts.' 'Warn')) }
    if ($null -ne $snap.FreeGB -and $snap.FreeGB -lt 2) { [void]$guide.Add((New-Guide ('Free up disk space on {0}.' -f $env:SystemDrive) ('Only {0:N1} GB is free; the restore point needs at least 2 GB.' -f $snap.FreeGB) 'Bad')) }
    if ($snap.Domain) { [void]$guide.Add((New-Guide 'Note: this PC is managed by work or school.' 'Their policy can turn VBS back on later.' 'Warn')) }
    [void]$guide.Add((New-Guide 'Click Turn off Hyper-V.' 'You confirm on the next screen before anything changes.' 'Accent'))
    $vm.Guide = @($guide)
    $vm.FooterTitle = 'Nothing has been changed yet.'
    $vm.FooterSubtitle = 'Follow the steps above, then click Turn off Hyper-V.'
    $vm.PrimaryEnabled = $true; $vm.PrimaryAction = 'Confirm'
    return $vm
}

function Set-Step {
    param([int] $Index, [ValidateSet('Pending', 'Active', 'Done', 'Failed')][string] $State, [string] $Caption = '')
    $defaults = @('', 'Restore point', 'Hyper-V, VBS, PIN', 'Up to two', 'Confirm all off')
    if (-not $Caption) {
        $Caption = switch ($State) { 'Done' { 'Done' } 'Active' { 'In progress' } 'Failed' { 'Stopped' } default { $defaults[$Index] } }
    }
    $key = "$State|$Caption"
    if ($script:stepStates[$Index] -eq $key) { return }
    $script:stepStates[$Index] = $key

    $dot = Get-Variable -Name "Step${Index}Dot" -ValueOnly -Scope Script
    $mark = Get-Variable -Name "Step${Index}Mark" -ValueOnly -Scope Script
    $label = Get-Variable -Name "Step${Index}Caption" -ValueOnly -Scope Script
    $pulse = Get-Variable -Name "Step${Index}Pulse" -ValueOnly -Scope Script
    $lineOut = Get-Variable -Name "Step${Index}LineR" -ValueOnly -Scope Script
    $iconFont = $window.FindResource('IconFont')
    $displayFont = $window.FindResource('DisplayFont')

    switch ($State) {
        'Done' {
            $dot.Background = $window.FindResource('PrimaryFill')
            $dot.BorderBrush = Get-Brush '#E88BEA'
            $mark.Text = $glyph.Check; $mark.FontFamily = $iconFont; $mark.Foreground = Get-Brush '#FFFFFF'
            $label.Foreground = Get-Brush '#C58BE8'
        }
        'Active' {
            $dot.Background = Get-Brush '#22122C'
            $dot.BorderBrush = $script:toneBrush
            $mark.Text = "$Index"; $mark.FontFamily = $displayFont; $mark.Foreground = $script:toneBrush
            $label.Foreground = $script:toneBrush
        }
        'Failed' {
            $dot.Background = Get-Brush '#26101A'
            $dot.BorderBrush = Get-Brush '#FF6B81'
            $mark.Text = $glyph.Cancel; $mark.FontFamily = $iconFont; $mark.Foreground = Get-Brush '#FF6B81'
            $label.Foreground = Get-Brush '#FF6B81'
        }
        default {
            $dot.Background = Get-Brush '#140E19'
            $dot.BorderBrush = Get-Brush '#34283F'
            $mark.Text = "$Index"; $mark.FontFamily = $displayFont; $mark.Foreground = Get-Brush '#85798F'
            $label.Foreground = Get-Brush '#85798F'
        }
    }
    $label.Text = $Caption
    $lineOut.Fill = if ($State -eq 'Done') { $window.FindResource('StepLineLit') } else { Get-Brush '#2A2032' }
    if ($Index -lt 4) {
        $nextLine = Get-Variable -Name ("Step{0}LineL" -f ($Index + 1)) -ValueOnly -Scope Script
        $nextLine.Fill = $lineOut.Fill
    }

    $scale = $pulse.RenderTransform
    if ($State -eq 'Active' -and -not $script:reduceMotion) {
        $grow = New-Object Windows.Media.Animation.DoubleAnimation(1, 1.7, [Windows.Duration]::new([TimeSpan]::FromSeconds(1.6)))
        $grow.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
        $grow.EasingFunction = New-EaseOut
        $fade = New-Object Windows.Media.Animation.DoubleAnimation(0.7, 0, [Windows.Duration]::new([TimeSpan]::FromSeconds(1.6)))
        $fade.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
        $scale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, $grow)
        $scale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, $grow)
        $pulse.BeginAnimation([Windows.UIElement]::OpacityProperty, $fade)
    }
    else {
        $scale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, $null)
        $scale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, $null)
        $pulse.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
        $pulse.Opacity = 0
    }
}

function Set-Guide {
    param([object[]] $Items)
    $signature = (@($Items | ForEach-Object { '{0}~{1}~{2}' -f $_.Text, $_.Detail, $_.Tone }) -join '|')
    if ($signature -eq $script:guideSignature) { return }
    $script:guideSignature = $signature
    $list = New-Object System.Collections.ArrayList
    $index = 0
    foreach ($item in $Items) {
        $index++
        $badge = $guideBadge[$item.Tone]
        $accentHex = if ($item.Tone -eq 'Neutral') { '#B8ACC4' } else { $toneColors[$item.Tone] }
        [void]$list.Add([pscustomobject]@{
            Index            = "$index"
            Text             = $item.Text
            Detail           = $item.Detail
            DetailVisibility = if ($item.Detail) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
            Accent           = [Windows.Media.Brush](Get-Brush $accentHex)
            BadgeBackground  = [Windows.Media.Brush](Get-Brush $badge[0])
            BadgeStroke      = [Windows.Media.Brush](Get-Brush $badge[1])
        })
    }
    $GuideList.ItemsSource = $list
    $GuideCard.Visibility = if ($list.Count) { 'Visible' } else { 'Collapsed' }
}

function Update-Readings {
    $snap = $script:snapshot
    if ($null -eq $snap) { return }
    if ($null -eq $snap.Hypervisor) { Set-Reading $HvValue $HvDot 'Unavailable' 'Muted' }
    elseif ($snap.Hypervisor) { Set-Reading $HvValue $HvDot 'Running' 'Accent' }
    else { Set-Reading $HvValue $HvDot 'Off' 'Good' }

    switch ($snap.VbsStatus) {
        $null { Set-Reading $VbsValue $VbsDot 'Unavailable' 'Muted' }
        0 { Set-Reading $VbsValue $VbsDot 'Off' 'Good' }
        1 { Set-Reading $VbsValue $VbsDot 'Set up, not running' 'Warn' }
        2 { Set-Reading $VbsValue $VbsDot 'Running' 'Accent' }
        default { Set-Reading $VbsValue $VbsDot 'Unknown' 'Muted' }
    }
    foreach ($pair in @(@($snap.CredentialGuard, $CgValue, $CgDot), @($snap.MemoryIntegrity, $HvciValue, $HvciDot))) {
        if ($null -eq $pair[0]) { Set-Reading $pair[1] $pair[2] 'Unavailable' 'Muted' }
        elseif ($pair[0]) { Set-Reading $pair[1] $pair[2] 'On' 'Accent' }
        else { Set-Reading $pair[1] $pair[2] 'Off' 'Good' }
    }
    if ($null -eq $snap.BitLockerOn) { Set-Reading $BitLockerValue $BitLockerDot 'Unknown' 'Muted' }
    elseif ($snap.BitLockerOn) { Set-Reading $BitLockerValue $BitLockerDot 'On' 'Good' }
    else { Set-Reading $BitLockerValue $BitLockerDot 'Off' 'Neutral' }

    if ($null -eq $snap.Domain) { Set-Reading $ManagedValue $ManagedDot 'Unavailable' 'Muted' }
    elseif ($snap.Domain) { Set-Reading $ManagedValue $ManagedDot 'Work or school' 'Warn' }
    else { Set-Reading $ManagedValue $ManagedDot 'This PC' 'Neutral' }

    $state = $script:state
    $attempt = if (Test-HasProperty $state 'Attempt') { [int]$state.Attempt } else { 1 }
    if (Test-EngineBusy) { Set-Reading $LastRunValue $LastRunDot 'In progress' 'Accent' }
    elseif ($snap.TaskExists) { Set-Reading $LastRunValue $LastRunDot "Restart $attempt of 2" 'Accent' }
    elseif ((Test-HasProperty $state 'Completed') -and [bool]$state.Completed) { Set-Reading $LastRunValue $LastRunDot 'Finished' 'Good' }
    elseif (Test-HasProperty $state 'Attempt') { Set-Reading $LastRunValue $LastRunDot 'Stopped early' 'Warn' }
    else { Set-Reading $LastRunValue $LastRunDot 'Never' 'Neutral' }

    $middot = [char]0x00B7
    $BrandSubtitle.Text = if ($snap.OsCaption) { "$env:COMPUTERNAME  $middot  $($snap.OsCaption)" } else { "$env:COMPUTERNAME  $middot  Administrator" }
}

function Update-View {
    $vm = Get-ViewModel
    Set-HeroTone $vm.Tone
    Set-OrbMotion -Spin $vm.Spin -Breathe $vm.Breathe
    Set-Busy $vm.Busy
    $OrbGlyph.Text = $vm.Glyph
    $FooterGlyph.Text = $vm.Glyph
    $StatusPillText.Text = $vm.Pill
    $StatusKicker.Text = $vm.Kicker
    $StatusTitle.Text = $vm.Title
    $StatusSubtitle.Text = $vm.Subtitle
    $GuideHeader.Text = $vm.GuideTitle
    Set-Guide $vm.Guide
    for ($i = 0; $i -lt 4; $i++) { Set-Step -Index ($i + 1) -State $vm.Steps[$i] -Caption $vm.Captions[$i] }

    $FooterTitle.Text = $vm.FooterTitle
    $FooterSubtitle.Text = $vm.FooterSubtitle
    $PrimaryText.Text = $vm.PrimaryText
    $PrimaryGlyph.Text = $vm.PrimaryGlyph
    $PrimaryGlyph.Visibility = if ($vm.PrimaryGlyph) { 'Visible' } else { 'Collapsed' }
    $PrimaryButton.IsEnabled = [bool]$vm.PrimaryEnabled
    $script:primaryAction = $vm.PrimaryAction
    $SecondaryButton.Visibility = if ($vm.ShowVerify) { 'Visible' } else { 'Collapsed' }
    $SecondaryButton.IsEnabled = [bool]$vm.VerifyEnabled
    $CancelRestartButton.Visibility = if ($vm.ShowCancelRestart) { 'Visible' } else { 'Collapsed' }

    $latest = $script:insight.Latest
    if ($vm.ShowLatest -and $null -ne $latest) {
        $LatestButton.Visibility = 'Visible'
        $LatestText.Text = "$($latest.Message)"
        $when = Format-EventTime $latest.At
        $LatestTime.Text = if ($when[1] -eq 'Today') { $when[0] } else { ('{0} {1}' -f $when[1], $when[0]).Trim() }
    }
    else { $LatestButton.Visibility = 'Collapsed' }

    Update-Readings

    # Smart stop: once Hyper-V is confirmed off, never reopen at sign-in.
    if (-not $script:reopenCleared -and $null -ne $script:snapshot -and $script:snapshot.AlreadyOff -and -not $script:snapshot.TaskExists) {
        Remove-StartupReopen
        $script:reopenCleared = $true
    }
}

# ---------------------------------------------------------------- actions

function Remove-StartupReopen {
    Remove-ItemProperty -LiteralPath $runOncePath -Name $runOnceName -ErrorAction SilentlyContinue
}

function Set-ReopenAfterSignIn {
    # Never arm the sign-in reopen when Hyper-V is already confirmed off.
    if (-not $ReopenToggle.IsChecked) { Remove-StartupReopen; return }
    if ($null -ne $script:snapshot -and $script:snapshot.AlreadyOff -and -not $script:snapshot.TaskExists) { Remove-StartupReopen; return }
    $command = '"{0}" -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" -Resume' -f $windowsPowerShell, $PSCommandPath
    try {
        New-Item -Path $runOncePath -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -Path $runOncePath -Name $runOnceName -PropertyType String -Value $command -Force -ErrorAction Stop | Out-Null
    }
    catch {
        Add-UiEvent -Level Warning -Code 'REOPEN_ARM_FAILED' `
            -Message "Could not set the window to reopen after sign-in: $($_.Exception.Message)" `
            -ActionRequired 'After the restart, open the tool again from the same folder. The work itself continues automatically.'
    }
}

function Update-ResumeReopen {
    # After a restart (RunOnce has already fired), re-arm once so a second
    # restart also brings the window back; disarm once the work is done.
    if (-not $Resume -or $null -eq $script:snapshot) { return }
    $state = $script:state
    $stillWorking = ($null -ne $state) -and -not ((Test-HasProperty $state 'Completed') -and [bool]$state.Completed)
    if ($stillWorking -and $script:snapshot.TaskExists) {
        if (-not $script:reopenArmedThisSession) { Set-ReopenAfterSignIn; $script:reopenArmedThisSession = $true }
    }
    elseif ($script:reopenArmedThisSession -or -not $stillWorking) {
        Remove-StartupReopen
        $script:reopenArmedThisSession = $false
    }
}

function Start-Engine {
    param([switch] $Verify)
    if (Test-EngineBusy) { return }
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $enginePath))
    if ($Verify) {
        $arguments += '-VerifyOnly'
    }
    else {
        if ($null -ne $script:snapshot -and $script:snapshot.AlreadyOff) {
            Add-UiEvent -Level Success -Code 'SKIP_ALREADY_OFF' -Message 'Hyper-V was already off, so nothing was changed.'
            Show-Toast 'Hyper-V is already off. Nothing was changed.' 'Good'
            Update-View
            return
        }
        if (-not $AutoRestartToggle.IsChecked) { $arguments += '-NoRestart' }
        if (-not $FirmwareToggle.IsChecked) { $arguments += '-SkipFirmwareOptOut' }
        Set-ReopenAfterSignIn
    }
    try {
        $script:engineProcess = Start-Process -FilePath $windowsPowerShell -ArgumentList ($arguments -join ' ') -WindowStyle Hidden -PassThru -ErrorAction Stop
        $script:engineMode = if ($Verify) { 'Verify' } else { 'Run' }
        $script:engineStartedAt = Get-Date
    }
    catch {
        Add-UiEvent -Level Error -Code 'ENGINE_START_FAILED' `
            -Message "Could not start the engine: $($_.Exception.Message)" `
            -ActionRequired 'Keep both PowerShell files in the same folder, then try again.'
        Show-Toast 'Could not start. See the Activity page for what to do.' 'Bad'
    }
    $script:sync.IntervalMs = 1500
    $script:sync.Poke = $true
    Show-Page -Name 'Home'
    Update-View
}

function Complete-EngineRun {
    $mode = $script:engineMode
    $script:engineProcess = $null
    $script:engineMode = ''
    $script:engineExitedAt = Get-Date
    $script:sync.Poke = $true
    if (Read-NewEvents) { Update-EventInsights; Update-ActivityList }
    if ($mode -ne 'Verify') { return }
    for ($i = $script:events.Count - 1; $i -ge 0; $i--) {
        $code = "$($script:events[$i].Code)"
        if ($code -eq 'VERIFY_ONLY_PASSED') { Show-Toast 'Check passed: Hyper-V and VBS are off.' 'Good'; return }
        if ($code -eq 'VERIFY_ONLY_FAILED') { Show-Toast 'Check finished: some parts are still on. Details are on the Activity page.' 'Warn'; return }
        if ($code -eq 'WORKFLOW_FAILED') { break }
    }
    Show-Toast 'Check finished. Details are on the Activity page.' 'Accent'
}

function Invoke-RestartNow {
    $now = Get-Date
    if ($now -ge $script:restartArmedUntil) {
        $script:restartArmedUntil = $now.AddSeconds(5)
        Update-View
        return
    }
    $script:restartArmedUntil = [datetime]::MinValue
    & shutdown.exe /a 2>&1 | Out-Null
    & shutdown.exe /r /t 3 /c 'Hyper-V Off Tool: restarting to finish turning off Hyper-V.' 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Show-Toast 'Windows did not accept the restart. Restart from the Start menu instead.' 'Warn'
        Update-View
        return
    }
    Add-UiEvent -Level Info -Code 'RESTART_NOW' -Message 'Restarting now at your request.'
    Show-Toast 'Restarting...' 'Accent'
    Update-View
}

function Invoke-CancelRestart {
    & shutdown.exe /a 2>&1 | Out-Null
    Add-UiEvent -Level Action -Code 'RESTART_CANCELLED' `
        -Message 'The automatic restart was cancelled.' `
        -ActionRequired 'Restart Windows when you are ready. The tool carries on automatically after the restart.'
    Show-Toast 'Restart cancelled. Restart whenever you are ready.' 'Accent'
    Update-View
}

function Invoke-Primary {
    switch ($script:primaryAction) {
        'Confirm' {
            if ($null -ne $script:snapshot -and $script:snapshot.AlreadyOff) { Start-Engine; return }
            Open-Confirm
        }
        'Restart' { Invoke-RestartNow }
        'Close' { $window.Close() }
        'Report' { if (Test-Path -LiteralPath $reportPath) { Start-Process notepad.exe -ArgumentList ('"{0}"' -f $reportPath) } }
    }
}

function Get-SupportText {
    $snap = $script:snapshot
    $state = $script:state
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Hyper-V Off Tool $script:AppVersion - support details")
    $lines.Add(('Created:   {0}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')))
    $lines.Add(('Computer:  {0}' -f $env:COMPUTERNAME))
    if ($null -ne $snap) {
        $lines.Add(('Windows:   {0} (product type {1})' -f $snap.OsCaption, $snap.ProductType))
        $lines.Add(('Status:    hypervisor={0}; VBS={1}; CredentialGuard={2}; MemoryIntegrity={3}' -f $snap.Hypervisor, $snap.VbsStatus, $snap.CredentialGuard, $snap.MemoryIntegrity))
        $lines.Add(('Device:    managed={0}; BitLocker={1}; onBattery={2}; freeGB={3}' -f $snap.Domain, $snap.BitLockerOn, $snap.OnBattery, $snap.FreeGB))
        $lines.Add(('Engine:    running={0}; continuationTask={1}' -f $snap.EngineRunning, $snap.TaskExists))
    }
    if ($null -ne $state) {
        $fields = foreach ($name in 'Attempt', 'Completed', 'CompletedAt', 'UefiOptOutStaged', 'BitLockerSuspendedByScript', 'SkipFirmwareOptOut', 'RestorePointDescription') {
            if (Test-HasProperty $state $name) { '{0}={1}' -f $name, $state.$name }
        }
        $lines.Add(('Run state: {0}' -f (@($fields) -join '; ')))
    }
    $lines.Add('')
    $lines.Add('Recent activity (newest first):')
    $count = 0
    for ($i = $script:events.Count - 1; $i -ge 0 -and $count -lt 60; $i--) {
        $item = $script:events[$i]
        $when = if ($null -ne $item.At) { $item.At.ToString('yyyy-MM-dd HH:mm:ss') } else { '' }
        $lines.Add(('{0}  {1,-7} {2}: {3}' -f $when, $item.Level, $item.Code, $item.Message))
        if ("$($item.ActionRequired)") { $lines.Add(('                     What to do: {0}' -f $item.ActionRequired)) }
        $count++
    }
    if ($count -eq 0) { $lines.Add('(none)') }
    return ($lines -join "`r`n")
}

function Copy-SupportDetails {
    $text = Get-SupportText
    for ($try = 0; $try -lt 4; $try++) {
        try {
            [Windows.Clipboard]::SetText($text)
            Show-Toast 'Copied. Paste it into your support message.' 'Good'
            return
        }
        catch { Start-Sleep -Milliseconds 120 }
    }
    Show-Toast 'The clipboard is busy. Try again in a moment.' 'Warn'
}

# ---------------------------------------------------------------- Testing page (Windows Security)

function Update-DefenderStatusUI {
    $d = $script:sync.Defender
    if ($null -eq $d) { return }
    Set-Value $DefTamperValue "$($d.TamperProtection)" $(if ($d.TamperOn) { 'Warn' } elseif ($d.TamperProtection -eq 'Off') { 'Good' } else { 'Muted' })
    Set-Value $DefRtValue "$($d.RealTimeProtection)" $(if ($d.RealTimeProtection -eq 'On') { 'Good' } elseif ($d.RealTimeProtection -eq 'Off') { 'Bad' } else { 'Muted' })
    Set-Value $DefSvcValue "$($d.Service)" $(if ($d.Service -eq 'Running') { 'Good' } elseif ($d.Service -eq 'Stopped') { 'Bad' } else { 'Muted' })
    $DefenderNote.Text = if ($d.TamperOn) { 'Tamper Protection is on right now, so most changes will be blocked.' } else { '' }
}

function Save-ServiceStartBackup {
    param([string[]] $ServiceNames)
    # Keep the first backup: a second Disable must not overwrite the true originals with 4s.
    if (Test-Path -LiteralPath $defenderBackupPath) { return }
    $backup = @{}
    foreach ($name in $ServiceNames) {
        try {
            $value = (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$name" -Name Start -ErrorAction Stop).Start
            $backup[$name] = [int]$value
        }
        catch { }
    }
    if ($backup.Count) {
        try {
            New-Item -ItemType Directory -Path $workRoot -Force -ErrorAction Stop | Out-Null
            $backup | ConvertTo-Json | Set-Content -LiteralPath $defenderBackupPath -Encoding UTF8
        }
        catch {
            Add-UiEvent -Level Warning -Code 'DEFENDER_BACKUP_SAVE_FAILED' `
                -Message "Could not save the Defender service start-value backup: $($_.Exception.Message)" `
                -ActionRequired 'Restore Windows Security will fall back to default start values. Check permissions on C:\ProgramData\Disable-HyperV-Fully.'
        }
    }
}

function Restore-TamperSafeRegistryValue {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Name,
        [AllowNull()][object] $Value,
        [switch] $Delete
    )
    try {
        if ($Delete) {
            if (-not (Test-Path -LiteralPath $Path)) { return $true }
            if ($null -eq (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue)) { return $true }
            Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        }
        else {
            if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
            New-ItemProperty -Path $Path -Name $Name -PropertyType DWord -Value ([int]$Value) -Force -ErrorAction Stop | Out-Null
        }
        return $true
    }
    catch {
        Add-UiEvent -Level Warning -Code 'DEFENDER_CHANGE_BLOCKED' `
            -Message "Windows blocked a security setting change: $Path\$Name." `
            -ActionRequired 'Turn off Tamper Protection in Windows Security, then try again.'
        return $false
    }
}

function Invoke-WindowsSecurityChange {
    param([ValidateSet('Disable', 'Enable')][string] $Mode)

    $defenderServices = @('WinDefend', 'WdNisSvc', 'WdFilter', 'WdBoot')

    if ($Mode -eq 'Disable') {
        Save-ServiceStartBackup -ServiceNames @('WinDefend', 'WdNisSvc', 'WdFilter', 'WdBoot', 'SecurityHealthService')

        $tamper = $null
        try { $tamper = [bool](Get-MpComputerStatus -ErrorAction Stop).IsTamperProtected } catch { }
        if ($tamper) {
            Add-UiEvent -Level Warning -Code 'DEFENDER_TAMPER_ON' `
                -Message 'Tamper Protection is ON. Windows will block most of these changes.' `
                -ActionRequired 'Turn off Tamper Protection in Windows Security first, then disable again.'
        }

        try { Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop } catch { }
        [void](Restore-TamperSafeRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -Name 'DisableAntiSpyware' -Value 1)
        [void](Restore-TamperSafeRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -Name 'DisableAntiVirus' -Value 1)
        [void](Restore-TamperSafeRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows Defender' -Name 'DisableAntiSpyware' -Value 1)
        [void](Restore-TamperSafeRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' -Name 'DisableRealtimeMonitoring' -Value 1)
        [void](Restore-TamperSafeRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Real-Time Protection' -Name 'DisableRealtimeMonitoring' -Value 1)

        foreach ($service in @('WinDefend', 'WdNisSvc')) {
            try { Stop-Service -Name $service -Force -ErrorAction SilentlyContinue } catch { }
        }
        foreach ($driver in @('WdFilter', 'WdBoot')) {
            try { & sc.exe stop $driver 2>&1 | Out-Null } catch { }
        }
        foreach ($name in $defenderServices) {
            [void](Restore-TamperSafeRegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$name" -Name 'Start' -Value 4)
        }
        [void](Restore-TamperSafeRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\SecurityHealthService' -Name 'Start' -Value 4)

        try {
            Get-Process -Name SecurityHealthSystray -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            $startupKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
            if (-not (Test-Path -LiteralPath $startupKey)) { New-Item -Path $startupKey -Force | Out-Null }
            New-ItemProperty -Path $startupKey -Name 'SecurityHealth' -PropertyType Binary -Value ([byte[]]@(3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) -Force -ErrorAction SilentlyContinue | Out-Null
        }
        catch { }

        Add-UiEvent -Level Success -Code 'DEFENDER_DISABLED' -Message 'Applied the Windows Security off state for testing.'
    }
    else {
        $originalStarts = @{}
        if (Test-Path -LiteralPath $defenderBackupPath) {
            try {
                foreach ($property in (Get-Content -LiteralPath $defenderBackupPath -Raw | ConvertFrom-Json).PSObject.Properties) {
                    $originalStarts[$property.Name] = [int]$property.Value
                }
            }
            catch { }
        }
        $defaults = @{ WinDefend = 2; WdNisSvc = 3; WdFilter = 0; WdBoot = 0; SecurityHealthService = 3 }

        [void](Restore-TamperSafeRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -Name 'DisableAntiSpyware' -Delete)
        [void](Restore-TamperSafeRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -Name 'DisableAntiVirus' -Delete)
        [void](Restore-TamperSafeRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows Defender' -Name 'DisableAntiSpyware' -Delete)
        [void](Restore-TamperSafeRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' -Name 'DisableRealtimeMonitoring' -Delete)
        [void](Restore-TamperSafeRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Real-Time Protection' -Name 'DisableRealtimeMonitoring' -Delete)

        foreach ($name in @($defenderServices + 'SecurityHealthService')) {
            $startValue = if ($originalStarts.ContainsKey($name)) { $originalStarts[$name] } else { $defaults[$name] }
            # Never "restore" a disabled value that a stale backup may hold.
            if ([int]$startValue -eq 4) { $startValue = $defaults[$name] }
            [void](Restore-TamperSafeRegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$name" -Name 'Start' -Value $startValue)
        }

        try { Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop } catch { }

        foreach ($service in @('WinDefend', 'WdNisSvc', 'SecurityHealthService')) {
            try { Start-Service -Name $service -ErrorAction SilentlyContinue } catch { }
        }

        try {
            $startupKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
            if (-not (Test-Path -LiteralPath $startupKey)) { New-Item -Path $startupKey -Force | Out-Null }
            New-ItemProperty -Path $startupKey -Name 'SecurityHealth' -PropertyType Binary -Value ([byte[]]@(2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) -Force -ErrorAction SilentlyContinue | Out-Null
            $tray = Join-Path $env:SystemRoot 'System32\SecurityHealthSystray.exe'
            if ((Get-Service -Name SecurityHealthService -ErrorAction SilentlyContinue).Status -eq 'Running' -and
                -not (Get-Process -Name SecurityHealthSystray -ErrorAction SilentlyContinue) -and
                (Test-Path -LiteralPath $tray)) {
                Start-Process -FilePath $tray -WindowStyle Hidden
            }
        }
        catch { }

        # The backup has served its purpose; the next Disable should capture fresh originals.
        Remove-Item -LiteralPath $defenderBackupPath -Force -ErrorAction SilentlyContinue

        Add-UiEvent -Level Success -Code 'DEFENDER_ENABLED' `
            -Message 'Restored Windows Security settings. If Defender does not start, restart the PC.'
    }
    $script:sync.Poke = $true
}

function Reset-DefenderArm {
    $script:defenderArmed = $false
    $DefenderDisableButton.Content = 'Disable Windows Security'
}

function Invoke-DefenderAction {
    param([ValidateSet('Disable', 'Enable')][string] $Mode)
    $DefenderDisableButton.IsEnabled = $false
    $DefenderEnableButton.IsEnabled = $false
    $window.Cursor = [Windows.Input.Cursors]::Wait
    try { Invoke-WindowsSecurityChange -Mode $Mode }
    catch {
        if ($Mode -eq 'Disable') {
            Add-UiEvent -Level Error -Code 'DEFENDER_DISABLE_FAILED' `
                -Message "Windows Security could not be fully disabled: $($_.Exception.Message)" `
                -ActionRequired 'Turn off Tamper Protection in Windows Security first, then try again.'
        }
        else {
            Add-UiEvent -Level Error -Code 'DEFENDER_ENABLE_FAILED' `
                -Message "Windows Security could not be fully restored: $($_.Exception.Message)" `
                -ActionRequired 'Restart the PC and use Restore Windows Security again.'
        }
    }
    finally {
        $window.Cursor = $null
        Reset-DefenderArm
        $DefenderDisableButton.IsEnabled = $true
        $DefenderEnableButton.IsEnabled = $true
    }
}

# ---------------------------------------------------------------- clock

function Invoke-Tick {
    $changed = $false
    $now = Get-Date

    if ($null -ne $script:engineProcess) {
        $exited = $true
        try { $exited = $script:engineProcess.HasExited } catch { }
        if ($exited) { Complete-EngineRun; $changed = $true }
    }

    if ($script:sync.Version -ne $script:snapshotVersion) {
        $script:snapshotVersion = $script:sync.Version
        $script:snapshot = $script:sync.Snapshot
        $changed = $true
    }
    if ($script:sync.DefenderVersion -ne $script:defenderVersion) {
        $script:defenderVersion = $script:sync.DefenderVersion
        Update-DefenderStatusUI
    }
    if (Read-NewEvents) { Update-EventInsights; Update-ActivityList; $changed = $true }
    if (Update-StateCache) { $changed = $true }

    # Countdowns and two-step buttons need a fresh label every tick.
    if ($now -lt $script:insight.RestartPendingUntil.AddSeconds(1)) { $changed = $true }
    if ($script:restartArmedUntil -ne [datetime]::MinValue -and $now -ge $script:restartArmedUntil) {
        $script:restartArmedUntil = [datetime]::MinValue
        $changed = $true
    }
    if ($script:defenderArmed -and $now -gt $script:defenderDeadline) { Reset-DefenderArm }

    if ($changed) { Update-View }

    $active = (Test-EngineBusy) -or ($null -ne $script:snapshot -and $script:snapshot.TaskExists) -or ($now -lt $script:insight.RestartPendingUntil)
    $script:sync.IntervalMs = if ($active) { 2000 } else { 4000 }
    Update-ResumeReopen
}

# ---------------------------------------------------------------- window icon

function Set-WindowIcon {
    try {
        $visual = New-Object Windows.Media.DrawingVisual
        $context = $visual.RenderOpen()
        $context.DrawRoundedRectangle($window.FindResource('PrimaryFill'), $null, (New-Object Windows.Rect(0, 0, 64, 64)), 16, 16)
        $family = New-Object Windows.Media.FontFamily 'Segoe Fluent Icons, Segoe MDL2 Assets'
        $typeface = New-Object Windows.Media.Typeface($family, [Windows.FontStyles]::Normal, [Windows.FontWeights]::Normal, [Windows.FontStretches]::Normal)
        $text = $null
        try {
            $text = New-Object Windows.Media.FormattedText($glyph.Power, [Globalization.CultureInfo]::InvariantCulture,
                [Windows.FlowDirection]::LeftToRight, $typeface, 32, [Windows.Media.Brushes]::White, 1.0)
        }
        catch {
            $text = New-Object Windows.Media.FormattedText($glyph.Power, [Globalization.CultureInfo]::InvariantCulture,
                [Windows.FlowDirection]::LeftToRight, $typeface, 32, [Windows.Media.Brushes]::White)
        }
        $context.DrawText($text, (New-Object Windows.Point(((64 - $text.Width) / 2), ((64 - $text.Height) / 2))))
        $context.Close()
        $bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap(64, 64, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($visual)
        $bitmap.Freeze()
        $window.Icon = $bitmap
    }
    catch { Write-UiTrace $_ }
}

# ---------------------------------------------------------------- events

$MinimizeButton.Add_Click({ $window.WindowState = [Windows.WindowState]::Minimized })
$MaximizeButton.Add_Click({
    $window.WindowState = if ($window.WindowState -eq [Windows.WindowState]::Maximized) { [Windows.WindowState]::Normal } else { [Windows.WindowState]::Maximized }
})
$CloseButton.Add_Click({ $window.Close() })
$window.Add_StateChanged({
    $maximized = ($window.WindowState -eq [Windows.WindowState]::Maximized)
    # A maximized WindowChrome window overhangs the screen by the frame width.
    $RootBorder.Margin = if ($maximized) { New-Object Windows.Thickness 7 } else { New-Object Windows.Thickness 0 }
    $MaximizeButton.Content = [string]$(if ($maximized) { $glyph.Restore } else { $glyph.Max })
    $MaximizeButton.ToolTip = if ($maximized) { 'Restore' } else { 'Maximize' }
})

$NavHome.Add_Checked({ Invoke-Guarded { Show-Page -Name 'Home' } })
$NavActivity.Add_Checked({ Invoke-Guarded { Show-Page -Name 'Activity' } })
$NavTesting.Add_Checked({ Invoke-Guarded { Show-Page -Name 'Testing'; Update-DefenderStatusUI } })
$LatestButton.Add_Click({ Invoke-Guarded { Show-Page -Name 'Activity' } })
$HelpButton.Add_Click({ Invoke-Guarded { Open-Sheet -Name 'Help'; $HelpDone.Focus() | Out-Null } })
$HelpCloseX.Add_Click({ Close-Sheet })
$HelpDone.Add_Click({ Close-Sheet })
$OpenRestoreButton.Add_Click({ Invoke-Guarded { Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\rstrui.exe') } })

$OpenFilesButton.Add_Click({ Invoke-Guarded { if (Test-Path -LiteralPath $workRoot) { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $workRoot) } } })
$OpenReportButton.Add_Click({ Invoke-Guarded { if (Test-Path -LiteralPath $reportPath) { Start-Process notepad.exe -ArgumentList ('"{0}"' -f $reportPath) } } })
$CopySupportButton.Add_Click({ Invoke-Guarded { Copy-SupportDetails } })
$AllFilter.Add_Checked({ Invoke-Guarded { $script:activitySignature = ''; Update-ActivityList } })
$ActionFilter.Add_Checked({ Invoke-Guarded { $script:activitySignature = ''; Update-ActivityList } })
$FailureFilter.Add_Checked({ Invoke-Guarded { $script:activitySignature = ''; Update-ActivityList } })

$PrimaryButton.Add_Click({ Invoke-Guarded { Invoke-Primary } })
$SecondaryButton.Add_Click({ Invoke-Guarded { Start-Engine -Verify } })
$CancelRestartButton.Add_Click({ Invoke-Guarded { Invoke-CancelRestart } })

$AckSaved.Add_Checked({ Update-ConfirmButton })
$AckSaved.Add_Unchecked({ Update-ConfirmButton })
$AckPassword.Add_Checked({ Update-ConfirmButton })
$AckPassword.Add_Unchecked({ Update-ConfirmButton })
$ConfirmCancel.Add_Click({ Close-Sheet })
$ConfirmCloseX.Add_Click({ Close-Sheet })
$ConfirmStart.Add_Click({
    Invoke-Guarded {
        if (-not ([bool]$AckSaved.IsChecked -and [bool]$AckPassword.IsChecked)) { return }
        Close-Sheet
        Start-Engine
    }
})
foreach ($sheet in @($ConfirmOverlay, $HelpOverlay)) {
    # Clicking the dimmed backdrop (not the card) closes the sheet.
    $sheet.Add_MouseLeftButtonDown({
        param($sender, $e)
        if ($e.OriginalSource -eq $sender) { Close-Sheet }
    })
}

$DefenderDisableButton.Add_Click({
    if (-not $script:defenderArmed) {
        $script:defenderArmed = $true
        $script:defenderDeadline = (Get-Date).AddSeconds(6)
        $DefenderDisableButton.Content = 'Click again to disable'
        return
    }
    Invoke-DefenderAction -Mode 'Disable'
})
$DefenderEnableButton.Add_Click({ Invoke-DefenderAction -Mode 'Enable' })

$window.Add_PreviewKeyDown({
    param($sender, $e)
    $modifiers = [Windows.Input.Keyboard]::Modifiers
    $ctrl = ($modifiers -band [Windows.Input.ModifierKeys]::Control) -ne 0
    $shift = ($modifiers -band [Windows.Input.ModifierKeys]::Shift) -ne 0
    if ($e.Key -eq [Windows.Input.Key]::Escape -and $script:overlay) { Close-Sheet; $e.Handled = $true }
    elseif ($e.Key -eq [Windows.Input.Key]::F1) { Open-Sheet -Name 'Help'; $e.Handled = $true }
    elseif ($e.Key -eq [Windows.Input.Key]::F5 -and -not $script:overlay -and $SecondaryButton.IsVisible -and $SecondaryButton.IsEnabled) { Invoke-Guarded { Start-Engine -Verify }; $e.Handled = $true }
    elseif ($ctrl -and $shift -and $e.Key -eq [Windows.Input.Key]::T) { Set-TestingVisible ($NavTesting.Visibility -ne 'Visible'); $e.Handled = $true }
    elseif ($ctrl -and -not $script:overlay -and $e.Key -eq [Windows.Input.Key]::D1) { Show-Page -Name 'Home'; $e.Handled = $true }
    elseif ($ctrl -and -not $script:overlay -and $e.Key -eq [Windows.Input.Key]::D2) { Show-Page -Name 'Activity'; $e.Handled = $true }
})

# A failure inside any handler is logged instead of closing the window.
$window.Dispatcher.Add_UnhandledException({
    param($sender, $e)
    Write-UiTrace $e.Exception
    $e.Handled = $true
})

# Fast UI clock: cheap checks only. Windows is queried by the background poller.
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(500)
$timer.Add_Tick({
    try { Invoke-Tick }
    catch { Write-UiTrace $_ }
})

$window.Add_Closing({
    $timer.Stop()
    Stop-StatusPoller
})

# ---------------------------------------------------------------- start

$VersionText.Text = "Version $script:AppVersion"
$window.Title = "$script:AppName"
Set-WindowIcon
Set-HeroTone 'Neutral'
if (-not $script:reduceMotion) {
    $livePulse = New-Object Windows.Media.Animation.DoubleAnimation(1, 0.25, [Windows.Duration]::new([TimeSpan]::FromSeconds(1.1)))
    $livePulse.AutoReverse = $true
    $livePulse.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
    $LiveDot.BeginAnimation([Windows.UIElement]::OpacityProperty, $livePulse)
}
Set-TestingVisible ([bool]$Testing)

# Fit the window to small or scaled screens instead of letting Windows clip it.
$workArea = [Windows.SystemParameters]::WorkArea
$window.Width = [Math]::Max(720, [Math]::Min($window.Width, $workArea.Width - 16))
$window.Height = [Math]::Max(520, [Math]::Min($window.Height, $workArea.Height - 16))
$window.MinWidth = [Math]::Min($window.MinWidth, $window.Width)
$window.MinHeight = [Math]::Min($window.MinHeight, $window.Height)

if (-not $script:reduceMotion) {
    $window.Opacity = 0
    $window.Add_ContentRendered({
        $window.BeginAnimation([Windows.Window]::OpacityProperty, (New-Object Windows.Media.Animation.DoubleAnimation(0, 1, (New-Duration 240))))
    })
}

[void](Update-StateCache)
[void](Read-NewEvents)
Update-EventInsights
Update-ActivityList
Update-View
Start-StatusPoller
$timer.Start()

[void]$window.ShowDialog()

Stop-StatusPoller
if ($null -ne $script:instanceMutex) {
    try { $script:instanceMutex.ReleaseMutex() } catch { }
    $script:instanceMutex.Dispose()
}
