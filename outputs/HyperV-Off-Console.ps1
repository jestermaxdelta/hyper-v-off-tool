#requires -version 5.1
[CmdletBinding()]
param([switch] $Resume)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

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

$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-IsAdministrator)) {
    $arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}"{1}' -f $PSCommandPath, $(if ($Resume) { ' -Resume' } else { '' })
    try { Start-Process -FilePath $windowsPowerShell -ArgumentList $arguments -Verb RunAs } catch { }
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$enginePath = Join-Path $PSScriptRoot 'Disable-HyperV-Fully.ps1'
$workRoot = Join-Path $env:ProgramData 'Disable-HyperV-Fully'
$eventLogPath = Join-Path $workRoot 'Operational-Events.jsonl'
$statePath = Join-Path $workRoot 'state.json'
$reportPath = Join-Path $workRoot 'Final-Status.txt'
$defenderBackupPath = Join-Path $workRoot 'SecurityToggle-Backup.json'
$runOncePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
$runOnceName = 'HyperVOffConsole'
$continuationTaskName = 'Disable-HyperV-Fully-Continue'

# Create the data folder up front: the Testing page writes here even if the
# engine has never run, and Set-Content cannot create intermediate directories.
try { New-Item -ItemType Directory -Path $workRoot -Force -ErrorAction Stop | Out-Null } catch { }

if (-not (Test-Path -LiteralPath $enginePath)) {
    [System.Windows.MessageBox]::Show(
        "One of the PowerShell files is missing:`n$enginePath`n`nKeep both PowerShell files together in the same folder.",
        'Hyper-V Off Tool',
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error
    ) | Out-Null
    return
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Hyper-V Off Tool" Width="1200" Height="820"
        MinWidth="1080" MinHeight="740" WindowStartupLocation="CenterScreen"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="CanMinimize"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13" Foreground="#F4EEF8"
        TextOptions.TextFormattingMode="Display" UseLayoutRounding="True">
  <Window.Resources>
    <!-- Palette: aubergine-black canvas, fuchsia to violet accent. -->
    <SolidColorBrush x:Key="AccentBrush" Color="#E063E8"/>
    <SolidColorBrush x:Key="AccentSoft" Color="#C58BE8"/>
    <SolidColorBrush x:Key="TextPrimary" Color="#F4EEF8"/>
    <SolidColorBrush x:Key="TextSecondary" Color="#B8ACC4"/>
    <SolidColorBrush x:Key="TextMuted" Color="#85798F"/>
    <SolidColorBrush x:Key="TextFaint" Color="#5E5468"/>
    <SolidColorBrush x:Key="CardBg" Color="#120D17"/>
    <SolidColorBrush x:Key="CardBgAlt" Color="#0E0A12"/>
    <SolidColorBrush x:Key="CardStroke" Color="#221A2A"/>
    <SolidColorBrush x:Key="Divider" Color="#1D1624"/>
    <SolidColorBrush x:Key="GoodBrush" Color="#4ADE9B"/>
    <SolidColorBrush x:Key="WarnBrush" Color="#F5B94F"/>
    <SolidColorBrush x:Key="BadBrush" Color="#FF6B81"/>
    <FontFamily x:Key="DisplayFont">Segoe UI Variable Display, Segoe UI</FontFamily>
    <FontFamily x:Key="IconFont">Segoe Fluent Icons, Segoe MDL2 Assets</FontFamily>
    <FontFamily x:Key="MonoFont">Cascadia Mono, Consolas</FontFamily>

    <DropShadowEffect x:Key="WindowShadow" BlurRadius="48" ShadowDepth="0" Opacity="0.7" Color="#000000"/>
    <DropShadowEffect x:Key="PrimaryGlow" BlurRadius="26" ShadowDepth="0" Opacity="0.55" Color="#C23FD6"/>
    <DropShadowEffect x:Key="SoftGlow" BlurRadius="14" ShadowDepth="0" Opacity="0.6" Color="#C23FD6"/>

    <LinearGradientBrush x:Key="PrimaryFill" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#E35BD9" Offset="0"/>
      <GradientStop Color="#9D4BEA" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="PrimaryFillHover" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#EE74E4" Offset="0"/>
      <GradientStop Color="#AE61F2" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="WindowFill" StartPoint="0,0" EndPoint="0,1">
      <GradientStop Color="#0D0911" Offset="0"/>
      <GradientStop Color="#09070C" Offset="0.6"/>
      <GradientStop Color="#08060A" Offset="1"/>
    </LinearGradientBrush>
    <RadialGradientBrush x:Key="TopGlow" Center="0.5,0" GradientOrigin="0.5,0" RadiusX="0.6" RadiusY="0.9">
      <GradientStop Color="#40A2349C" Offset="0"/>
      <GradientStop Color="#185E2A8C" Offset="0.45"/>
      <GradientStop Color="#00000000" Offset="1"/>
    </RadialGradientBrush>
    <LinearGradientBrush x:Key="HeroFill" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#1A1120" Offset="0"/>
      <GradientStop Color="#120C17" Offset="0.55"/>
      <GradientStop Color="#0F0A13" Offset="1"/>
    </LinearGradientBrush>
    <RadialGradientBrush x:Key="HeroGlow" Center="1,0" GradientOrigin="1,0" RadiusX="0.8" RadiusY="0.9">
      <GradientStop Color="#3DC43FC0" Offset="0"/>
      <GradientStop Color="#00000000" Offset="1"/>
    </RadialGradientBrush>
    <LinearGradientBrush x:Key="HeroStroke" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#4A2E57" Offset="0"/>
      <GradientStop Color="#231A2B" Offset="0.5"/>
      <GradientStop Color="#1E1725" Offset="1"/>
    </LinearGradientBrush>
    <DrawingBrush x:Key="DotGrid" TileMode="Tile" Viewport="0,0,18,18" ViewportUnits="Absolute" Opacity="0.07">
      <DrawingBrush.Drawing>
        <GeometryDrawing Brush="#FFFFFF">
          <GeometryDrawing.Geometry><EllipseGeometry Center="1,1" RadiusX="0.9" RadiusY="0.9"/></GeometryDrawing.Geometry>
        </GeometryDrawing>
      </DrawingBrush.Drawing>
    </DrawingBrush>

    <!-- Headings -->
    <Style x:Key="PageTitle" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="{StaticResource DisplayFont}"/>
      <Setter Property="FontSize" Value="30"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
      <Setter Property="TextOptions.TextFormattingMode" Value="Ideal"/>
    </Style>
    <Style x:Key="Kicker" TargetType="TextBlock">
      <Setter Property="FontSize" Value="10.5"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Foreground" Value="{StaticResource AccentBrush}"/>
    </Style>
    <Style x:Key="CardTitle" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="{StaticResource DisplayFont}"/>
      <Setter Property="FontSize" Value="16"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
    </Style>
    <Style x:Key="Body" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource TextMuted}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="LineHeight" Value="18"/>
    </Style>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="CornerRadius" Value="16"/>
      <Setter Property="Background" Value="{StaticResource CardBg}"/>
      <Setter Property="BorderBrush" Value="{StaticResource CardStroke}"/>
      <Setter Property="BorderThickness" Value="1"/>
    </Style>

    <Style x:Key="GhostButton" TargetType="Button">
      <Setter Property="Foreground" Value="#DCD2E6"/>
      <Setter Property="Background" Value="#16101C"/>
      <Setter Property="BorderBrush" Value="#2C2236"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="16,9"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Chrome" CornerRadius="10" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="#1F1627"/>
                <Setter TargetName="Chrome" Property="BorderBrush" Value="#4A3358"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Chrome" Property="BorderBrush" Value="#B055D6"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="#140E19"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Chrome" Property="Opacity" Value="0.38"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="WindowButton" TargetType="Button" BasedOn="{StaticResource GhostButton}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="Foreground" Value="#9C90A8"/>
      <Setter Property="FontFamily" Value="{StaticResource IconFont}"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="Width" Value="40"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="Padding" Value="0"/>
    </Style>
    <Style x:Key="CloseButtonStyle" TargetType="Button" BasedOn="{StaticResource WindowButton}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Chrome" CornerRadius="9" Background="Transparent">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="#C42B4A"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="PrimaryButton" TargetType="Button">
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="Background" Value="{StaticResource PrimaryFill}"/>
      <Setter Property="Padding" Value="26,12"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border x:Name="Glow" CornerRadius="11" Background="{StaticResource PrimaryFill}" Effect="{StaticResource PrimaryGlow}" Opacity="0.75"/>
              <Border x:Name="Chrome" CornerRadius="11" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}"
                      BorderThickness="1" BorderBrush="#40FFFFFF">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="{StaticResource PrimaryFillHover}"/>
                <Setter TargetName="Glow" Property="Opacity" Value="1"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Chrome" Property="BorderBrush" Value="#FFFFFF"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Chrome" Property="Opacity" Value="0.86"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Chrome" Property="Background" Value="#231A2B"/>
                <Setter TargetName="Chrome" Property="BorderBrush" Value="#30253A"/>
                <Setter TargetName="Glow" Property="Visibility" Value="Collapsed"/>
                <Setter Property="Foreground" Value="#7D7189"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="DangerButton" TargetType="Button" BasedOn="{StaticResource GhostButton}">
      <Setter Property="Foreground" Value="#FFB3C0"/>
      <Setter Property="Background" Value="#1E0F15"/>
      <Setter Property="BorderBrush" Value="#4E2230"/>
      <Setter Property="Padding" Value="18,9"/>
    </Style>

    <Style x:Key="NavRadio" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#8E829A"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Padding" Value="14,11"/>
      <Setter Property="Margin" Value="0,2"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Grid>
              <Border x:Name="NavChrome" CornerRadius="10" Background="{TemplateBinding Background}"
                      BorderBrush="Transparent" BorderThickness="1" Padding="{TemplateBinding Padding}">
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="{TemplateBinding Tag}" FontFamily="{StaticResource IconFont}" FontSize="14"
                             VerticalAlignment="Center" x:Name="Glyph"/>
                  <ContentPresenter Margin="12,0,0,0" VerticalAlignment="Center"/>
                </StackPanel>
              </Border>
              <Border x:Name="Indicator" Width="3" CornerRadius="1.5" Background="{StaticResource PrimaryFill}"
                      HorizontalAlignment="Left" Margin="-17,10,0,10" Opacity="0" Effect="{StaticResource SoftGlow}"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="NavChrome" Property="Background" Value="#150F1A"/>
                <Setter Property="Foreground" Value="#D8CEE2"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="NavChrome" Property="BorderBrush" Value="#4A3358"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="NavChrome" Property="Background" Value="#1C1323"/>
                <Setter TargetName="NavChrome" Property="BorderBrush" Value="#2E2038"/>
                <Setter Property="Foreground" Value="#F4EEF8"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
                <Setter TargetName="Indicator" Property="Opacity" Value="1"/>
                <Setter TargetName="Glyph" Property="Foreground" Value="{StaticResource AccentBrush}"/>
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
            <Border x:Name="FilterChrome" CornerRadius="8" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter Property="Foreground" Value="#D8CEE2"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="FilterChrome" Property="Background" Value="#261932"/>
                <Setter Property="Foreground" Value="#F4EEF8"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

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
                <Ellipse.Effect><DropShadowEffect BlurRadius="8" ShadowDepth="1" Opacity="0.5"/></Ellipse.Effect>
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
                <Setter TargetName="Track" Property="BorderBrush" Value="#B055D6"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.42"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Chip" TargetType="Border">
      <Setter Property="CornerRadius" Value="999"/>
      <Setter Property="Padding" Value="11,4"/>
      <Setter Property="BorderThickness" Value="1"/>
    </Style>

    <Style x:Key="RowLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource TextMuted}"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="RowValue" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#DCD2E6"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="HorizontalAlignment" Value="Right"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
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
      <Setter Property="Margin" Value="6,4,0,4"/>
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
          <Setter Property="Margin" Value="4,6,4,0"/>
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
            <Border Background="#1A1220" BorderBrush="#3A2B47" BorderThickness="1" CornerRadius="8" Padding="10,6">
              <ContentPresenter/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid Margin="18">
    <Border CornerRadius="20" Background="#09070C" Effect="{StaticResource WindowShadow}"/>
    <Border x:Name="RootChrome" CornerRadius="20" BorderBrush="#241B2C" BorderThickness="1" Background="{StaticResource WindowFill}" ClipToBounds="True">
    <Grid>
      <!-- Hero glow behind the title bar, echoing the website header. -->
      <Border Background="{StaticResource TopGlow}" Height="360" VerticalAlignment="Top" IsHitTestVisible="False" CornerRadius="20,20,0,0"/>
      <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="60"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="92"/>
      </Grid.RowDefinitions>

      <Grid x:Name="TitleBar" Grid.Row="0" Margin="24,0,12,0" Background="Transparent">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Grid Width="32" Height="32">
            <Border CornerRadius="10" Background="{StaticResource PrimaryFill}" Effect="{StaticResource SoftGlow}" Opacity="0.7"/>
            <Border CornerRadius="10" Background="{StaticResource PrimaryFill}" BorderBrush="#50FFFFFF" BorderThickness="1">
              <TextBlock Text="&#xE7E8;" FontFamily="{StaticResource IconFont}" FontSize="14" Foreground="#FFFFFF"
                         HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
          </Grid>
          <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
            <TextBlock FontFamily="{StaticResource DisplayFont}" FontWeight="Bold" FontSize="14.5">
              <Run Text="Hyper-V Off"/><Run Text="." Foreground="{StaticResource AccentBrush}"/>
            </TextBlock>
            <TextBlock x:Name="MachineSubTitle" Text="" Foreground="{StaticResource TextFaint}" FontSize="11" Margin="0,1,0,0"/>
          </StackPanel>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="MinimizeButton" Content="&#xE921;" Style="{StaticResource WindowButton}" Margin="0,0,4,0" ToolTip="Minimize"/>
          <Button x:Name="CloseButton" Content="&#xE8BB;" Style="{StaticResource CloseButtonStyle}" ToolTip="Close. Any work in progress keeps going."/>
        </StackPanel>
      </Grid>

      <Grid Grid.Row="1" Margin="22,2,22,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="232"/>
          <ColumnDefinition Width="20"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <!-- Sidebar -->
        <Border Grid.Column="0" Style="{StaticResource Card}" Background="#CC0E0A12" Padding="17,20">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <StackPanel Margin="3,0,3,22">
              <TextBlock Text="SYSTEM TOOL" Style="{StaticResource Kicker}"/>
              <TextBlock Style="{StaticResource PageTitle}" FontSize="22" Margin="0,8,0,0" TextWrapping="Wrap" LineHeight="26">
                <Run Text="Turn off Hyper-V"/><Run Text="." Foreground="{StaticResource AccentBrush}"/>
              </TextBlock>
            </StackPanel>
            <StackPanel Grid.Row="1">
              <TextBlock Text="WORKFLOW" Foreground="{StaticResource TextFaint}" FontSize="10" FontWeight="Bold" Margin="4,0,0,6"/>
              <RadioButton x:Name="OverviewNav" Content="Overview" Tag="&#xE80F;" GroupName="Navigation" IsChecked="True" Style="{StaticResource NavRadio}"/>
              <RadioButton x:Name="ControlsNav" Content="Options" Tag="&#xE713;" GroupName="Navigation" Style="{StaticResource NavRadio}"/>
              <RadioButton x:Name="ActivityNav" GroupName="Navigation" Tag="&#xE9D9;" Style="{StaticResource NavRadio}">
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="Log"/>
                  <Border x:Name="LogBadge" Visibility="Collapsed" CornerRadius="999" Background="#3A1420" BorderBrush="#6B2438" BorderThickness="1" Padding="7,0" Margin="9,0,0,0" VerticalAlignment="Center">
                    <TextBlock x:Name="LogBadgeText" Text="0" Foreground="#FF8FA2" FontSize="10.5" FontWeight="Bold"/>
                  </Border>
                </StackPanel>
              </RadioButton>
              <TextBlock Text="TOOLS" Foreground="{StaticResource TextFaint}" FontSize="10" FontWeight="Bold" Margin="4,18,0,6"/>
              <RadioButton x:Name="TestingNav" GroupName="Navigation" Tag="&#xE90F;" Style="{StaticResource NavRadio}">
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="Testing"/>
                  <Border CornerRadius="5" Background="#1D1524" BorderBrush="#34283F" BorderThickness="1" Padding="5,0" Margin="9,0,0,0" VerticalAlignment="Center">
                    <TextBlock Text="DEV" Foreground="{StaticResource TextMuted}" FontSize="9" FontWeight="Bold"/>
                  </Border>
                </StackPanel>
              </RadioButton>
            </StackPanel>
            <Border Grid.Row="3" CornerRadius="12" Background="#140E19" BorderBrush="#2A1F33" BorderThickness="1" Padding="15,14">
              <StackPanel>
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="&#xEA18;" FontFamily="{StaticResource IconFont}" FontSize="13" Foreground="{StaticResource AccentBrush}" VerticalAlignment="Center"/>
                  <TextBlock Text="Safety checks" Foreground="#E8DFF0" FontWeight="SemiBold" Margin="9,0,0,0" VerticalAlignment="Center"/>
                </StackPanel>
                <TextBlock Text="Restore point, settings backup and BitLocker protection always run first." Style="{StaticResource Body}" FontSize="11" LineHeight="16" Margin="0,7,0,0"/>
              </StackPanel>
            </Border>
          </Grid>
        </Border>

        <Grid Grid.Column="2" x:Name="PanelHost">
          <Grid.RenderTransform><TranslateTransform Y="0"/></Grid.RenderTransform>

          <!-- Overview -->
          <Grid x:Name="OverviewPanel">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <Grid Margin="4,4,4,18">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <StackPanel>
                <TextBlock Text="OVERVIEW" Style="{StaticResource Kicker}"/>
                <TextBlock Style="{StaticResource PageTitle}" Margin="0,6,0,0"><Run Text="This PC"/><Run Text="." Foreground="{StaticResource AccentBrush}"/></TextBlock>
                <TextBlock Text="See what is running before anything gets changed." Foreground="{StaticResource TextMuted}" Margin="0,4,0,0"/>
              </StackPanel>
              <Border x:Name="HeaderPill" Grid.Column="1" Style="{StaticResource Chip}" Background="#221430" BorderBrush="#4A2E62" VerticalAlignment="Bottom" Margin="0,0,0,4">
                <StackPanel Orientation="Horizontal">
                  <Ellipse x:Name="HeaderDot" Width="7" Height="7" Fill="#E063E8" VerticalAlignment="Center"/>
                  <TextBlock x:Name="HeaderStatus" Text="READY" Foreground="#E7B8F2" FontSize="10.5" FontWeight="Bold" Margin="7,0,0,0" VerticalAlignment="Center"/>
                </StackPanel>
              </Border>
            </Grid>

            <Grid Grid.Row="1">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="1.5*"/>
                <ColumnDefinition Width="16"/>
                <ColumnDefinition Width="1*"/>
              </Grid.ColumnDefinitions>

              <Border Grid.Column="0" CornerRadius="16" Background="{StaticResource HeroFill}" BorderBrush="{StaticResource HeroStroke}" BorderThickness="1" ClipToBounds="True">
                <Grid>
                  <Border Background="{StaticResource HeroGlow}" CornerRadius="16" IsHitTestVisible="False"/>
                  <Border Background="{StaticResource DotGrid}" CornerRadius="16" IsHitTestVisible="False">
                    <Border.OpacityMask>
                      <RadialGradientBrush Center="1,0" GradientOrigin="1,0" RadiusX="0.9" RadiusY="1">
                        <GradientStop Color="#FF000000" Offset="0"/>
                        <GradientStop Color="#00000000" Offset="1"/>
                      </RadialGradientBrush>
                    </Border.OpacityMask>
                  </Border>
                  <Grid Margin="30,28,30,26">
                    <Grid.RowDefinitions>
                      <RowDefinition Height="Auto"/>
                      <RowDefinition Height="*"/>
                      <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <StackPanel>
                      <TextBlock x:Name="StatusKicker" Text="BEFORE YOU START" Style="{StaticResource Kicker}"/>
                      <TextBlock x:Name="StatusTitle" Text="Ready to check this PC." Style="{StaticResource PageTitle}" FontSize="32" Margin="0,10,0,0" TextWrapping="Wrap" LineHeight="38"/>
                      <TextBlock x:Name="StatusSubtitle" Text="First we check what is running. Nothing changes until you start." Foreground="{StaticResource TextSecondary}" FontSize="13" TextWrapping="Wrap" Margin="0,10,0,0" MaxWidth="520" HorizontalAlignment="Left" LineHeight="20"/>
                    </StackPanel>

                    <!-- Stepper -->
                    <Grid Grid.Row="1" Margin="0,24,0,22" VerticalAlignment="Center">
                      <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                      </Grid.RowDefinitions>
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="46"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                      </Grid.ColumnDefinitions>
                      <Rectangle Grid.RowSpan="4" Width="1" Fill="#2E2238" HorizontalAlignment="Left" Margin="15,22,0,22"/>

                      <Border x:Name="Step1Dot" Grid.Row="0" Width="31" Height="31" CornerRadius="16" BorderThickness="1.5" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="0,4,0,0" Background="#140E19" BorderBrush="#34283F">
                        <TextBlock x:Name="Step1Mark" Text="1" FontWeight="Bold" FontSize="12" Foreground="#85798F" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                      </Border>
                      <StackPanel Grid.Row="0" Grid.Column="1" Margin="0,4,12,14"><TextBlock Text="Back up" FontWeight="SemiBold" Foreground="#EDE5F4"/><TextBlock Text="Make a restore point and save the current settings." Style="{StaticResource Body}" Margin="0,3,0,0"/></StackPanel>
                      <TextBlock x:Name="Step1State" Grid.Row="0" Grid.Column="2" Text="" FontSize="11" FontWeight="SemiBold" Margin="0,10,0,0" Foreground="#85798F"/>

                      <Border x:Name="Step2Dot" Grid.Row="1" Width="31" Height="31" CornerRadius="16" BorderThickness="1.5" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="0,4,0,0" Background="#140E19" BorderBrush="#34283F">
                        <TextBlock x:Name="Step2Mark" Text="2" FontWeight="Bold" FontSize="12" Foreground="#85798F" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                      </Border>
                      <StackPanel Grid.Row="1" Grid.Column="1" Margin="0,4,12,14"><TextBlock Text="Turn off" FontWeight="SemiBold" Foreground="#EDE5F4"/><TextBlock Text="Disable Hyper-V, VBS, Windows Hello PIN and related Windows features." Style="{StaticResource Body}" Margin="0,3,0,0"/></StackPanel>
                      <TextBlock x:Name="Step2State" Grid.Row="1" Grid.Column="2" Text="" FontSize="11" FontWeight="SemiBold" Margin="0,10,0,0" Foreground="#85798F"/>

                      <Border x:Name="Step3Dot" Grid.Row="2" Width="31" Height="31" CornerRadius="16" BorderThickness="1.5" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="0,4,0,0" Background="#140E19" BorderBrush="#34283F">
                        <TextBlock x:Name="Step3Mark" Text="3" FontWeight="Bold" FontSize="12" Foreground="#85798F" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                      </Border>
                      <StackPanel Grid.Row="2" Grid.Column="1" Margin="0,4,12,14"><TextBlock Text="Restart" FontWeight="SemiBold" Foreground="#EDE5F4"/><TextBlock Text="Restart when Windows needs it. The tool carries on by itself." Style="{StaticResource Body}" Margin="0,3,0,0"/></StackPanel>
                      <TextBlock x:Name="Step3State" Grid.Row="2" Grid.Column="2" Text="" FontSize="11" FontWeight="SemiBold" Margin="0,10,0,0" Foreground="#85798F"/>

                      <Border x:Name="Step4Dot" Grid.Row="3" Width="31" Height="31" CornerRadius="16" BorderThickness="1.5" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="0,4,0,0" Background="#140E19" BorderBrush="#34283F">
                        <TextBlock x:Name="Step4Mark" Text="4" FontWeight="Bold" FontSize="12" Foreground="#85798F" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                      </Border>
                      <StackPanel Grid.Row="3" Grid.Column="1" Margin="0,4,12,0"><TextBlock Text="Verify" FontWeight="SemiBold" Foreground="#EDE5F4"/><TextBlock Text="Confirm every Hyper-V part is actually off." Style="{StaticResource Body}" Margin="0,3,0,0"/></StackPanel>
                      <TextBlock x:Name="Step4State" Grid.Row="3" Grid.Column="2" Text="" FontSize="11" FontWeight="SemiBold" Margin="0,10,0,0" Foreground="#85798F"/>
                    </Grid>

                    <StackPanel Grid.Row="2" Orientation="Horizontal">
                      <Button x:Name="VerifyButton" Style="{StaticResource GhostButton}" ToolTip="Read-only check. Nothing on the PC is changed.">
                        <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE721;" FontFamily="{StaticResource IconFont}" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"/><TextBlock Text="Check this PC"/></StackPanel>
                      </Button>
                      <Button x:Name="OpenFilesButton" Style="{StaticResource GhostButton}" Margin="10,0,0,0">
                        <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE838;" FontFamily="{StaticResource IconFont}" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"/><TextBlock Text="Open log folder"/></StackPanel>
                      </Button>
                      <Button x:Name="OpenReportButton" Style="{StaticResource GhostButton}" Margin="10,0,0,0" Visibility="Collapsed">
                        <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE8A5;" FontFamily="{StaticResource IconFont}" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"/><TextBlock Text="Final report"/></StackPanel>
                      </Button>
                    </StackPanel>
                  </Grid>
                </Grid>
              </Border>

              <Border Grid.Column="2" Style="{StaticResource Card}" Padding="24,22">
                <Grid>
                  <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                  </Grid.RowDefinitions>
                  <Grid Margin="0,0,0,10">
                    <TextBlock Text="Quick check" Style="{StaticResource CardTitle}"/>
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" ToolTip="Refreshes every few seconds">
                      <Ellipse Width="6" Height="6" Fill="{StaticResource GoodBrush}" VerticalAlignment="Center">
                        <Ellipse.Triggers>
                          <EventTrigger RoutedEvent="Loaded">
                            <BeginStoryboard>
                              <Storyboard RepeatBehavior="Forever" AutoReverse="True">
                                <DoubleAnimation Storyboard.TargetProperty="Opacity" From="1" To="0.25" Duration="0:0:1.1"/>
                              </Storyboard>
                            </BeginStoryboard>
                          </EventTrigger>
                        </Ellipse.Triggers>
                      </Ellipse>
                      <TextBlock Text="LIVE" Foreground="{StaticResource TextMuted}" FontSize="10" FontWeight="Bold" Margin="6,0,0,0"/>
                    </StackPanel>
                  </Grid>
                  <StackPanel Grid.Row="1">
                    <Border BorderBrush="{StaticResource Divider}" BorderThickness="0,0,0,1" Padding="0,12">
                      <Grid><TextBlock Text="Administrator" Style="{StaticResource RowLabel}"/><TextBlock x:Name="AdminCheck" Text="Yes" Style="{StaticResource RowValue}" Foreground="{StaticResource GoodBrush}"/></Grid>
                    </Border>
                    <Border BorderBrush="{StaticResource Divider}" BorderThickness="0,0,0,1" Padding="0,12">
                      <Grid><TextBlock Text="Hypervisor" Style="{StaticResource RowLabel}"/><TextBlock x:Name="HypervisorCheck" Text="Checking" Style="{StaticResource RowValue}"/></Grid>
                    </Border>
                    <Border BorderBrush="{StaticResource Divider}" BorderThickness="0,0,0,1" Padding="0,12">
                      <Grid><TextBlock Text="VBS" Style="{StaticResource RowLabel}"/><TextBlock x:Name="VbsCheck" Text="Checking" Style="{StaticResource RowValue}"/></Grid>
                    </Border>
                    <Border BorderBrush="{StaticResource Divider}" BorderThickness="0,0,0,1" Padding="0,12">
                      <Grid><TextBlock Text="Managed by" Style="{StaticResource RowLabel}"/><TextBlock x:Name="ManagedCheck" Text="Checking" Style="{StaticResource RowValue}"/></Grid>
                    </Border>
                    <Border Padding="0,12">
                      <Grid><TextBlock Text="Last run" Style="{StaticResource RowLabel}"/><TextBlock x:Name="LastRunCheck" Text="Never" Style="{StaticResource RowValue}"/></Grid>
                    </Border>
                  </StackPanel>
                  <Border Grid.Row="3" x:Name="ManagedNote" Visibility="Collapsed" CornerRadius="10" Background="#1D1710" BorderBrush="#4A3A1E" BorderThickness="1" Padding="12,10">
                    <TextBlock Text="This PC is managed by work or school. Their policy can switch VBS back on later." Foreground="#E9C27A" FontSize="11.5" TextWrapping="Wrap" LineHeight="17"/>
                  </Border>
                </Grid>
              </Border>
            </Grid>
          </Grid>

          <!-- Options -->
          <Grid x:Name="ControlsPanel" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <StackPanel Margin="4,4,4,18">
              <TextBlock Text="OPTIONS" Style="{StaticResource Kicker}"/>
              <TextBlock Style="{StaticResource PageTitle}" Margin="0,6,0,0"><Run Text="How it runs"/><Run Text="." Foreground="{StaticResource AccentBrush}"/></TextBlock>
              <TextBlock Text="Choose how restarts work. The safety checks always stay on." Foreground="{StaticResource TextMuted}" Margin="0,4,0,0"/>
            </StackPanel>
            <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
              <StackPanel>
                <Border x:Name="ConfirmBanner" Visibility="Collapsed" CornerRadius="16" BorderThickness="1" Padding="24,20" Margin="0,0,0,14" BorderBrush="#7A3A8E">
                  <Border.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                      <GradientStop Color="#2A1433" Offset="0"/>
                      <GradientStop Color="#160E1C" Offset="1"/>
                    </LinearGradientBrush>
                  </Border.Background>
                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Border Width="36" Height="36" CornerRadius="18" Background="#3A1A48" VerticalAlignment="Top">
                      <TextBlock Text="&#xE7BA;" FontFamily="{StaticResource IconFont}" FontSize="15" Foreground="{StaticResource AccentBrush}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <StackPanel Grid.Column="1" Margin="16,0,0,0">
                      <TextBlock Text="Confirm to continue" Style="{StaticResource CardTitle}"/>
                      <TextBlock Style="{StaticResource Body}" Foreground="#CDBFD9" Margin="0,6,0,0" FontSize="12.5" LineHeight="20">
                        This turns off Credential Guard, Memory Integrity, Windows Sandbox, WSL 2 and Hyper-V, and removes Windows Hello PIN sign-in. You will sign in with your account password instead.
                      </TextBlock>
                      <TextBlock x:Name="ConfirmCountdown" Text="" Foreground="{StaticResource AccentSoft}" FontSize="11.5" FontWeight="SemiBold" Margin="0,10,0,0"/>
                    </StackPanel>
                  </Grid>
                </Border>

                <Border Style="{StaticResource Card}" Padding="26,22" Margin="0,0,0,14">
                  <StackPanel>
                    <TextBlock Text="Restart settings" Style="{StaticResource CardTitle}" Margin="0,0,0,8"/>
                    <Grid Margin="0,10"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel Margin="0,0,20,0"><TextBlock Text="Restart automatically" FontWeight="SemiBold"/><TextBlock Text="Gives you 30 seconds to save, then restarts. Turn off to restart yourself later." Style="{StaticResource Body}" Margin="0,3,0,0"/></StackPanel><CheckBox x:Name="AutoRestartToggle" Grid.Column="1" Style="{StaticResource Toggle}" IsChecked="True" VerticalAlignment="Center"/></Grid>
                    <Border BorderBrush="{StaticResource Divider}" BorderThickness="0,1,0,0" Margin="0,8,0,0" Padding="0,18,0,0">
                      <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel Margin="0,0,20,0"><TextBlock Text="Remove the firmware lock" FontWeight="SemiBold"/><TextBlock Text="Prepares the Microsoft confirmation screen at boot if Windows needs it (press the key shown, commonly F3)." Style="{StaticResource Body}" Margin="0,3,0,0"/></StackPanel><CheckBox x:Name="FirmwareToggle" Grid.Column="1" Style="{StaticResource Toggle}" IsChecked="True" VerticalAlignment="Center"/></Grid>
                    </Border>
                    <Border BorderBrush="{StaticResource Divider}" BorderThickness="0,1,0,0" Margin="0,18,0,0" Padding="0,18,0,0">
                      <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel Margin="0,0,20,0"><TextBlock Text="Open again after restart" FontWeight="SemiBold"/><TextBlock Text="Brings this window back after you sign in. It stops opening on its own once Hyper-V is off." Style="{StaticResource Body}" Margin="0,3,0,0"/></StackPanel><CheckBox x:Name="ReopenToggle" Grid.Column="1" Style="{StaticResource Toggle}" IsChecked="True" VerticalAlignment="Center"/></Grid>
                    </Border>
                  </StackPanel>
                </Border>

                <Border Style="{StaticResource Card}" Background="{StaticResource CardBgAlt}" Padding="26,22">
                  <StackPanel>
                    <TextBlock Text="Safety checks" Style="{StaticResource CardTitle}" Margin="0,0,0,8"/>
                    <Grid Margin="0,10"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="Restore point" FontWeight="SemiBold"/><TextBlock Text="Stops if Windows cannot create and confirm one." Style="{StaticResource Body}" Margin="0,3,0,0"/></StackPanel><Border Grid.Column="1" Style="{StaticResource Chip}" Background="#0F2119" BorderBrush="#1F4434" VerticalAlignment="Center"><TextBlock Text="ALWAYS ON" Foreground="{StaticResource GoodBrush}" FontSize="10" FontWeight="Bold"/></Border></Grid>
                    <Border BorderBrush="{StaticResource Divider}" BorderThickness="0,1,0,0" Margin="0,8,0,0" Padding="0,8,0,0">
                      <Grid Margin="0,10"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="BitLocker protection" FontWeight="SemiBold"/><TextBlock Text="Paused only while the PC restarts. The disk stays encrypted." Style="{StaticResource Body}" Margin="0,3,0,0"/></StackPanel><Border Grid.Column="1" Style="{StaticResource Chip}" Background="#0F2119" BorderBrush="#1F4434" VerticalAlignment="Center"><TextBlock Text="ALWAYS ON" Foreground="{StaticResource GoodBrush}" FontSize="10" FontWeight="Bold"/></Border></Grid>
                    </Border>
                    <Border BorderBrush="{StaticResource Divider}" BorderThickness="0,1,0,0" Margin="0,8,0,0" Padding="0,8,0,0">
                      <Grid Margin="0,10"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="Settings backup" FontWeight="SemiBold"/><TextBlock Text="Saves the current boot and security settings first." Style="{StaticResource Body}" Margin="0,3,0,0"/></StackPanel><Border Grid.Column="1" Style="{StaticResource Chip}" Background="#0F2119" BorderBrush="#1F4434" VerticalAlignment="Center"><TextBlock Text="ALWAYS ON" Foreground="{StaticResource GoodBrush}" FontSize="10" FontWeight="Bold"/></Border></Grid>
                    </Border>
                  </StackPanel>
                </Border>
              </StackPanel>
            </ScrollViewer>
          </Grid>

          <!-- Testing -->
          <Grid x:Name="TestingPanel" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <StackPanel Margin="4,4,4,18">
              <TextBlock Text="TESTING" Style="{StaticResource Kicker}"/>
              <TextBlock Style="{StaticResource PageTitle}" Margin="0,6,0,0"><Run Text="Test helpers"/><Run Text="." Foreground="{StaticResource AccentBrush}"/></TextBlock>
              <TextBlock Text="Local helpers for testing. Not part of the normal workflow." Foreground="{StaticResource TextMuted}" Margin="0,4,0,0"/>
            </StackPanel>
            <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="1.5*"/>
                  <ColumnDefinition Width="16"/>
                  <ColumnDefinition Width="1*"/>
                </Grid.ColumnDefinitions>
                <Border CornerRadius="16" Background="#160C12" BorderBrush="#40202C" BorderThickness="1" Padding="26,22" VerticalAlignment="Top">
                  <StackPanel>
                    <StackPanel Orientation="Horizontal">
                      <TextBlock Text="&#xEA18;" FontFamily="{StaticResource IconFont}" FontSize="15" Foreground="{StaticResource BadBrush}" VerticalAlignment="Center"/>
                      <TextBlock Text="Windows Security control" Style="{StaticResource CardTitle}" Margin="10,0,0,0" VerticalAlignment="Center"/>
                    </StackPanel>
                    <TextBlock Text="Replaces third-party tools such as Sordum Defender Control with the same native changes: it sets the Defender policy keys, stops the WinDefend / WdNisSvc / WdFilter services and hides the Security Health tray icon. Restore reverses everything using the saved original values."
                               Style="{StaticResource Body}" Foreground="#A8929D" Margin="0,10,0,0"/>
                    <Border CornerRadius="10" Background="#1D1710" BorderBrush="#4A3A1E" BorderThickness="1" Padding="14,11" Margin="0,16,0,0">
                      <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <TextBlock Text="&#xE7BA;" FontFamily="{StaticResource IconFont}" FontSize="12" Foreground="{StaticResource WarnBrush}" VerticalAlignment="Top" Margin="0,2,0,0"/>
                        <TextBlock Grid.Column="1" Text="If Tamper Protection is ON, Windows blocks or reverts these changes. Turn it off first in Windows Security &#x2192; Virus &amp; threat protection settings."
                                   Foreground="#E9C27A" FontSize="11.5" TextWrapping="Wrap" Margin="10,0,0,0" LineHeight="17"/>
                      </Grid>
                    </Border>
                    <StackPanel Orientation="Horizontal" Margin="0,18,0,0">
                      <Button x:Name="DefenderDisableButton" Content="Disable Windows Security" Style="{StaticResource DangerButton}"/>
                      <Button x:Name="DefenderEnableButton" Content="Restore Windows Security" Style="{StaticResource GhostButton}" Margin="10,0,0,0"/>
                    </StackPanel>
                    <TextBlock x:Name="DefenderNote" Text="" Foreground="{StaticResource TextMuted}" FontSize="11.5" TextWrapping="Wrap" Margin="0,12,0,0" LineHeight="17"/>
                  </StackPanel>
                </Border>

                <Border Grid.Column="2" Style="{StaticResource Card}" Padding="24,22" VerticalAlignment="Top">
                  <StackPanel>
                    <TextBlock Text="Current state" Style="{StaticResource CardTitle}" Margin="0,0,0,10"/>
                    <Border BorderBrush="{StaticResource Divider}" BorderThickness="0,0,0,1" Padding="0,12">
                      <Grid><TextBlock Text="Tamper Protection" Style="{StaticResource RowLabel}"/><TextBlock x:Name="DefTamperValue" Text="Checking" Style="{StaticResource RowValue}"/></Grid>
                    </Border>
                    <Border BorderBrush="{StaticResource Divider}" BorderThickness="0,0,0,1" Padding="0,12">
                      <Grid><TextBlock Text="Real-time protection" Style="{StaticResource RowLabel}"/><TextBlock x:Name="DefRtValue" Text="Checking" Style="{StaticResource RowValue}"/></Grid>
                    </Border>
                    <Border Padding="0,12">
                      <Grid><TextBlock Text="WinDefend service" Style="{StaticResource RowLabel}"/><TextBlock x:Name="DefSvcValue" Text="Checking" Style="{StaticResource RowValue}"/></Grid>
                    </Border>
                  </StackPanel>
                </Border>
              </Grid>
            </ScrollViewer>
          </Grid>

          <!-- Log -->
          <Grid x:Name="ActivityPanel" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <Grid Margin="4,4,4,18">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <StackPanel>
                <TextBlock Text="LOG" Style="{StaticResource Kicker}"/>
                <TextBlock Style="{StaticResource PageTitle}" Margin="0,6,0,0"><Run Text="What happened"/><Run Text="." Foreground="{StaticResource AccentBrush}"/></TextBlock>
                <TextBlock x:Name="ActivityCaption" Text="Newest first. Only important results and anything you need to fix." Foreground="{StaticResource TextMuted}" Margin="0,4,0,0"/>
              </StackPanel>
              <Border Grid.Column="1" CornerRadius="11" Background="#120D17" BorderBrush="#241B2C" BorderThickness="1" Padding="3" VerticalAlignment="Bottom" Margin="0,0,0,2">
                <StackPanel Orientation="Horizontal">
                  <RadioButton x:Name="AllFilter" Content="All" GroupName="LogFilter" IsChecked="True" Style="{StaticResource FilterRadio}"/>
                  <RadioButton x:Name="ActionFilter" Content="Needs attention" GroupName="LogFilter" Style="{StaticResource FilterRadio}"/>
                  <RadioButton x:Name="FailureFilter" Content="Failed" GroupName="LogFilter" Style="{StaticResource FilterRadio}"/>
                </StackPanel>
              </Border>
            </Grid>
            <Border Grid.Row="1" Style="{StaticResource Card}" Background="{StaticResource CardBgAlt}" Padding="10,10,6,10">
              <Grid>
                <StackPanel x:Name="ActivityEmpty" HorizontalAlignment="Center" VerticalAlignment="Center" MaxWidth="340">
                  <Border Width="56" Height="56" CornerRadius="28" Background="#160F1C" BorderBrush="#2A1F33" BorderThickness="1" HorizontalAlignment="Center">
                    <TextBlock Text="&#xE9D9;" FontFamily="{StaticResource IconFont}" FontSize="20" Foreground="#6B4C80" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  </Border>
                  <TextBlock x:Name="ActivityEmptyTitle" Text="Nothing here yet" HorizontalAlignment="Center" Style="{StaticResource CardTitle}" Margin="0,14,0,0"/>
                  <TextBlock x:Name="ActivityEmptyBody" Text="Check the PC or start the process. Important results show up here." Style="{StaticResource Body}" TextAlignment="Center" Margin="0,6,0,0"/>
                </StackPanel>
                <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                  <ItemsControl x:Name="ActivityList">
                    <ItemsControl.ItemTemplate>
                      <DataTemplate>
                        <Border CornerRadius="12" Background="{Binding Background}" BorderBrush="{Binding Stroke}" BorderThickness="1" Margin="4,4,8,6" Padding="16,14">
                          <Grid>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                            <Border Width="28" Height="28" CornerRadius="14" Background="{Binding IconBackground}" VerticalAlignment="Top">
                              <TextBlock Text="{Binding Glyph}" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="12" Foreground="{Binding Accent}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <StackPanel Grid.Column="1" Margin="14,0,14,0">
                              <TextBlock Text="{Binding Level}" Foreground="{Binding Accent}" FontWeight="Bold" FontSize="10"/>
                              <TextBlock Text="{Binding Message}" Foreground="#EDE5F4" TextWrapping="Wrap" FontWeight="SemiBold" Margin="0,3,0,0" LineHeight="19"/>
                              <Border Visibility="{Binding ActionVisibility}" CornerRadius="9" Background="#0C090F" BorderBrush="#221A2A" BorderThickness="1" Margin="0,10,0,0" Padding="12,9">
                                <StackPanel>
                                  <TextBlock Text="WHAT TO DO" Foreground="{Binding Accent}" FontSize="10" FontWeight="Bold"/>
                                  <TextBlock Text="{Binding Action}" Foreground="#B8ACC4" TextWrapping="Wrap" Margin="0,4,0,0" LineHeight="18"/>
                                </StackPanel>
                              </Border>
                            </StackPanel>
                            <TextBlock Grid.Column="2" Text="{Binding Time}" Foreground="#6E6379" FontFamily="Cascadia Mono, Consolas" FontSize="11" VerticalAlignment="Top" Margin="0,1,0,0"/>
                          </Grid>
                        </Border>
                      </DataTemplate>
                    </ItemsControl.ItemTemplate>
                  </ItemsControl>
                </ScrollViewer>
              </Grid>
            </Border>
          </Grid>
        </Grid>
      </Grid>

      <!-- Footer / action bar -->
      <Grid Grid.Row="2" Margin="22,14,22,18">
        <Border CornerRadius="16" Background="#CC110C15" BorderBrush="{StaticResource CardStroke}" BorderThickness="1" ClipToBounds="True">
          <Grid>
            <Border x:Name="BusyTrack" Height="2" VerticalAlignment="Top" ClipToBounds="True" Visibility="Collapsed" Margin="16,0">
              <Rectangle x:Name="BusyBar" Width="220" HorizontalAlignment="Left">
                <Rectangle.Fill>
                  <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                    <GradientStop Color="#00E35BD9" Offset="0"/>
                    <GradientStop Color="#FFE35BD9" Offset="0.5"/>
                    <GradientStop Color="#009D4BEA" Offset="1"/>
                  </LinearGradientBrush>
                </Rectangle.Fill>
                <Rectangle.RenderTransform><TranslateTransform X="-220"/></Rectangle.RenderTransform>
              </Rectangle>
            </Border>
            <Grid Margin="22,0,12,0">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <StackPanel VerticalAlignment="Center" Margin="0,0,16,0">
                <TextBlock x:Name="FooterTitle" Text="Nothing has been changed yet." FontWeight="SemiBold" FontSize="13.5" TextTrimming="CharacterEllipsis"/>
                <TextBlock x:Name="FooterSubtitle" Text="Check the options and save your work before starting." Foreground="{StaticResource TextMuted}" FontSize="11.5" Margin="0,3,0,0" TextTrimming="CharacterEllipsis"/>
              </StackPanel>
              <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                <Button x:Name="CancelRestartButton" Content="Cancel restart" Style="{StaticResource GhostButton}" Margin="0,0,10,0" Visibility="Collapsed" ToolTip="Stops the pending restart. Restart yourself later; the tool carries on after that."/>
                <Button x:Name="CancelConfirmButton" Content="Cancel" Style="{StaticResource GhostButton}" Margin="0,0,10,0" Visibility="Collapsed"/>
                <Button x:Name="ActivityShortcut" Content="See log" Style="{StaticResource GhostButton}" Margin="0,0,10,0"/>
                <Button x:Name="RunButton" Content="Turn off Hyper-V" Style="{StaticResource PrimaryButton}" MinWidth="184"/>
              </StackPanel>
            </Grid>
          </Grid>
        </Border>
      </Grid>
      </Grid>
    </Grid>
    </Border>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader($xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

$names = @(
    'TitleBar','MinimizeButton','CloseButton','MachineSubTitle','OverviewNav','ControlsNav','TestingNav','ActivityNav',
    'LogBadge','LogBadgeText','PanelHost',
    'OverviewPanel','ControlsPanel','TestingPanel','ActivityPanel','HeaderPill','HeaderDot','HeaderStatus','StatusKicker','StatusTitle',
    'StatusSubtitle','AdminCheck','HypervisorCheck','VbsCheck','ManagedCheck','LastRunCheck','ManagedNote',
    'Step1Dot','Step1Mark','Step1State','Step2Dot','Step2Mark','Step2State','Step3Dot','Step3Mark','Step3State','Step4Dot','Step4Mark','Step4State',
    'VerifyButton','OpenFilesButton','OpenReportButton','AutoRestartToggle','FirmwareToggle','ReopenToggle','ConfirmBanner','ConfirmCountdown',
    'DefenderDisableButton','DefenderEnableButton','DefenderNote','DefTamperValue','DefRtValue','DefSvcValue',
    'AllFilter','ActionFilter','FailureFilter','ActivityCaption','ActivityEmpty','ActivityEmptyTitle','ActivityEmptyBody','ActivityList',
    'BusyTrack','BusyBar','FooterTitle','FooterSubtitle','CancelRestartButton','CancelConfirmButton','ActivityShortcut','RunButton'
)
foreach ($name in $names) { Set-Variable -Name $name -Value $window.FindName($name) -Scope Script }

$script:confirmationArmed = $false
$script:confirmDeadline = [datetime]::MinValue
$script:defenderArmed = $false
$script:defenderDeadline = [datetime]::MinValue
$script:lastEventSignature = ''
$script:engineProcess = $null
$script:engineMode = ''
$script:defenderTickCounter = 0
$script:restartPendingUntil = [datetime]::MinValue
$script:busyAnimating = $false
$script:brushCache = @{}

$confirmWindowSeconds = 12

# ---------------------------------------------------------------- helpers

function Get-Brush {
    param([string] $Hex)
    if (-not $script:brushCache.ContainsKey($Hex)) {
        $brush = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($Hex))
        $brush.Freeze()
        $script:brushCache[$Hex] = $brush
    }
    return $script:brushCache[$Hex]
}

$toneColors = @{
    Good    = '#4ADE9B'
    Warn    = '#F5B94F'
    Bad     = '#FF6B81'
    Accent  = '#E063E8'
    Neutral = '#DCD2E6'
    Muted   = '#85798F'
}

function Set-Value {
    param($Control, [string] $Text, [ValidateSet('Good','Warn','Bad','Accent','Neutral','Muted')][string] $Tone = 'Neutral')
    $Control.Text = $Text
    $Control.Foreground = Get-Brush $toneColors[$Tone]
}

function Set-HeaderPill {
    param([string] $Text, [ValidateSet('Accent','Good','Warn','Bad')][string] $Tone)
    $palette = switch ($Tone) {
        'Good' { @('#0F2119','#1F4434','#4ADE9B','#8CEBC0') }
        'Warn' { @('#221A0E','#4A3A1E','#F5B94F','#F2D08F') }
        'Bad'  { @('#26101A','#5A2233','#FF6B81','#FFA3B2') }
        default { @('#221430','#4A2E62','#E063E8','#E7B8F2') }
    }
    $HeaderPill.Background = Get-Brush $palette[0]
    $HeaderPill.BorderBrush = Get-Brush $palette[1]
    $HeaderDot.Fill = Get-Brush $palette[2]
    $HeaderStatus.Foreground = Get-Brush $palette[3]
    $HeaderStatus.Text = $Text
}

function Set-Step {
    param([int] $Index, [ValidateSet('Pending','Active','Done','Failed')][string] $State, [string] $Caption = '')
    $dot = Get-Variable -Name "Step${Index}Dot" -ValueOnly -Scope Script
    $mark = Get-Variable -Name "Step${Index}Mark" -ValueOnly -Scope Script
    $label = Get-Variable -Name "Step${Index}State" -ValueOnly -Scope Script
    switch ($State) {
        'Done' {
            $dot.Background = $window.FindResource('PrimaryFill')
            $dot.BorderBrush = Get-Brush '#E88BEA'
            $mark.Text = [string][char]0xE73E
            $mark.FontFamily = $window.FindResource('IconFont')
            $mark.Foreground = Get-Brush '#FFFFFF'
            $label.Foreground = Get-Brush '#C58BE8'
            if (-not $Caption) { $Caption = 'Done' }
        }
        'Active' {
            $dot.Background = Get-Brush '#2A1435'
            $dot.BorderBrush = Get-Brush '#E063E8'
            $mark.Text = "$Index"
            $mark.FontFamily = $window.FindResource('DisplayFont')
            $mark.Foreground = Get-Brush '#F4C6F6'
            $label.Foreground = Get-Brush '#E063E8'
            if (-not $Caption) { $Caption = 'In progress' }
        }
        'Failed' {
            $dot.Background = Get-Brush '#26101A'
            $dot.BorderBrush = Get-Brush '#FF6B81'
            $mark.Text = [string][char]0xE711
            $mark.FontFamily = $window.FindResource('IconFont')
            $mark.Foreground = Get-Brush '#FF6B81'
            $label.Foreground = Get-Brush '#FF6B81'
            if (-not $Caption) { $Caption = 'Stopped' }
        }
        default {
            $dot.Background = Get-Brush '#140E19'
            $dot.BorderBrush = Get-Brush '#34283F'
            $mark.Text = "$Index"
            $mark.FontFamily = $window.FindResource('DisplayFont')
            $mark.Foreground = Get-Brush '#85798F'
            $label.Foreground = Get-Brush '#85798F'
        }
    }
    $label.Text = $Caption
}

function Set-Steps {
    param([string[]] $States, [string[]] $Captions = @('','','',''))
    for ($i = 0; $i -lt 4; $i++) { Set-Step -Index ($i + 1) -State $States[$i] -Caption $Captions[$i] }
}

function Set-Busy {
    param([bool] $On)
    if ($On -eq $script:busyAnimating) { return }
    $script:busyAnimating = $On
    $transform = $BusyBar.RenderTransform
    if ($On) {
        $BusyTrack.Visibility = 'Visible'
        $width = [Math]::Max(1400, $BusyTrack.ActualWidth)
        $animation = New-Object Windows.Media.Animation.DoubleAnimation(-220, $width, [Windows.Duration]::new([TimeSpan]::FromSeconds(1.6)))
        $animation.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
        $ease = New-Object Windows.Media.Animation.SineEase
        $ease.EasingMode = 'EaseInOut'
        $animation.EasingFunction = $ease
        $transform.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, $animation)
    }
    else {
        $transform.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, $null)
        $BusyTrack.Visibility = 'Collapsed'
    }
}

function Show-Panel {
    param([ValidateSet('Overview','Controls','Testing','Activity')][string] $Name)
    $target = $null
    foreach ($pair in @(@('Overview',$OverviewPanel),@('Controls',$ControlsPanel),@('Testing',$TestingPanel),@('Activity',$ActivityPanel))) {
        if ($pair[0] -eq $Name) { $target = $pair[1]; $pair[1].Visibility = 'Visible' } else { $pair[1].Visibility = 'Collapsed' }
    }
    switch ($Name) {
        'Overview' { if (-not $OverviewNav.IsChecked) { $OverviewNav.IsChecked = $true } }
        'Controls' { if (-not $ControlsNav.IsChecked) { $ControlsNav.IsChecked = $true } }
        'Testing'  { if (-not $TestingNav.IsChecked) { $TestingNav.IsChecked = $true } }
        'Activity' { if (-not $ActivityNav.IsChecked) { $ActivityNav.IsChecked = $true } }
    }
    # Short fade/slide so page changes feel intentional rather than abrupt.
    $duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds(220))
    $fade = New-Object Windows.Media.Animation.DoubleAnimation(0, 1, $duration)
    $slide = New-Object Windows.Media.Animation.DoubleAnimation(8, 0, $duration)
    $ease = New-Object Windows.Media.Animation.CubicEase
    $ease.EasingMode = 'EaseOut'
    $slide.EasingFunction = $ease
    $target.BeginAnimation([Windows.UIElement]::OpacityProperty, $fade)
    $PanelHost.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $slide)
}

function Get-CurrentState {
    if (-not (Test-Path -LiteralPath $statePath)) { return $null }
    try { return (Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json) } catch { return $null }
}

function Get-OperationalEvents {
    if (-not (Test-Path -LiteralPath $eventLogPath)) { return @() }
    $events = New-Object System.Collections.ArrayList
    foreach ($line in @(Get-Content -LiteralPath $eventLogPath -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $parsed = $line | ConvertFrom-Json
            if (Test-HasProperty $parsed 'Message') { [void]$events.Add($parsed) }
        } catch { }
    }
    return @($events)
}

function Add-UiEvent {
    param(
        [ValidateSet('Info','Success','Action','Warning','Error')][string] $Level,
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
        $script:lastEventSignature = ''
        Refresh-Activity
    } catch { }
}

function Get-EventTime {
    param($Item)
    if (Test-HasProperty $Item 'Timestamp') {
        try { return ([datetime]"$($Item.Timestamp)").ToLocalTime() } catch { }
    }
    return $null
}

function Test-EventNeedsAction {
    param($Item)
    return ((Test-HasProperty $Item 'ActionRequired') -and -not [string]::IsNullOrWhiteSpace("$($Item.ActionRequired)"))
}

function Convert-ToActivityItem {
    param($Item)
    $level = if (Test-HasProperty $Item 'Level') { "$($Item.Level)" } else { 'Info' }
    # accent, card background, card stroke, icon background, glyph
    $palette = switch ($level) {
        'Success' { @('#4ADE9B','#0E1512','#1C3328','#123023',[char]0xE73E) }
        'Action'  { @('#E063E8','#150E19','#3A2448','#2A1435',[char]0xE72A) }
        'Warning' { @('#F5B94F','#16120C','#3B2F1A','#2A2112',[char]0xE7BA) }
        'Error'   { @('#FF6B81','#170C11','#44202B','#2E121B',[char]0xE711) }
        default   { @('#B8ACC4','#110D15','#231A2B','#1D1524',[char]0xE946) }
    }
    $hasAction = Test-EventNeedsAction $Item
    $parsedTime = Get-EventTime $Item
    $timeText = if ($null -eq $parsedTime) { '' }
        elseif ($parsedTime.Date -eq (Get-Date).Date) { $parsedTime.ToString('HH:mm:ss') }
        else { $parsedTime.ToString('d MMM HH:mm') }
    $levelLabel = switch ($level) { 'Action' { 'ACTION NEEDED' } 'Error' { 'FAILED' } default { $level.ToUpperInvariant() } }
    [pscustomobject]@{
        Time             = $timeText
        Level            = $levelLabel
        Message          = "$($Item.Message)"
        Action           = if ($hasAction) { "$($Item.ActionRequired)" } else { '' }
        ActionVisibility = if ($hasAction) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
        Accent           = Get-Brush $palette[0]
        Background       = Get-Brush $palette[1]
        Stroke           = Get-Brush $palette[2]
        IconBackground   = Get-Brush $palette[3]
        Glyph            = [string]$palette[4]
    }
}

function Refresh-Activity {
    $all = @(Get-OperationalEvents)

    # Remember when a restart was last scheduled so the footer can offer a cancel.
    $script:restartPendingUntil = [datetime]::MinValue
    for ($i = $all.Count - 1; $i -ge 0; $i--) {
        if ((Test-HasProperty $all[$i] 'Code') -and $all[$i].Code -eq 'RESTART_SCHEDULED') {
            $at = Get-EventTime $all[$i]
            if ($null -ne $at) { $script:restartPendingUntil = $at.AddSeconds(32) }
            break
        }
        if ((Test-HasProperty $all[$i] 'Code') -and $all[$i].Code -eq 'RESTART_CANCELLED') { break }
    }

    # Badge: failures in the current run (since the last start/verify).
    $recentFailures = 0
    for ($i = $all.Count - 1; $i -ge 0; $i--) {
        $code = if (Test-HasProperty $all[$i] 'Code') { "$($all[$i].Code)" } else { '' }
        if ($code -in @('WORKFLOW_STARTED','CONTINUATION_STARTED','VERIFICATION_PASSED','VERIFY_ONLY_PASSED','ALREADY_DISABLED','SKIP_ALREADY_OFF')) { break }
        if ((Test-HasProperty $all[$i] 'Level') -and $all[$i].Level -eq 'Error') { $recentFailures++ }
    }
    $LogBadge.Visibility = if ($recentFailures -gt 0) { 'Visible' } else { 'Collapsed' }
    $LogBadgeText.Text = "$recentFailures"

    $filter = if ($ActionFilter.IsChecked) { 1 } elseif ($FailureFilter.IsChecked) { 2 } else { 0 }
    $events = $all
    if ($filter -eq 1) { $events = @($events | Where-Object { Test-EventNeedsAction $_ }) }
    if ($filter -eq 2) { $events = @($events | Where-Object { (Test-HasProperty $_ 'Level') -and $_.Level -eq 'Error' }) }
    $events = @($events | Select-Object -Last 150)
    $lastStamp = if ($events.Count -and (Test-HasProperty $events[-1] 'Timestamp')) { "$($events[-1].Timestamp)" } else { '' }
    $signature = "$($events.Count)|$lastStamp|$filter|$((Get-Date).Date.Ticks)"
    if ($signature -eq $script:lastEventSignature) { return }
    $script:lastEventSignature = $signature

    $items = New-Object System.Collections.ArrayList
    for ($i = $events.Count - 1; $i -ge 0; $i--) { [void]$items.Add((Convert-ToActivityItem $events[$i])) }
    $ActivityList.ItemsSource = $items
    $ActivityCaption.Text = if ($all.Count) { "Newest first  ·  $($all.Count) entries. Only important results and anything you need to fix." } else { 'Only important results and anything you need to fix are shown here.' }

    if ($events.Count -eq 0) {
        $ActivityEmpty.Visibility = 'Visible'
        if ($filter -eq 0) {
            $ActivityEmptyTitle.Text = 'Nothing here yet'
            $ActivityEmptyBody.Text = 'Check the PC or start the process. Important results show up here.'
        } else {
            $ActivityEmptyTitle.Text = 'All clear'
            $ActivityEmptyBody.Text = if ($filter -eq 1) { 'Nothing needs your attention right now.' } else { 'No failures have been logged.' }
        }
    }
    else { $ActivityEmpty.Visibility = 'Collapsed' }
}

function Get-SystemSnapshot {
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
    # True only when we can positively confirm: no hypervisor running AND VBS off.
    $snapshot.AlreadyOff = ($snapshot.Hypervisor -eq $false) -and ($snapshot.VbsStatus -eq 0)
    return [pscustomobject]$snapshot
}

function Test-HypervisorAlreadyOff {
    return (Get-SystemSnapshot).AlreadyOff
}

function Remove-StartupReopen {
    Remove-ItemProperty -LiteralPath $runOncePath -Name $runOnceName -ErrorAction SilentlyContinue
}

function Test-EngineBusy {
    return ($null -ne $script:engineProcess -and -not $script:engineProcess.HasExited)
}

function Read-LiveStatus {
    param($Snapshot = (Get-SystemSnapshot))

    if ($null -eq $Snapshot.Hypervisor) { Set-Value $HypervisorCheck 'Unavailable' 'Muted' }
    elseif ($Snapshot.Hypervisor) { Set-Value $HypervisorCheck 'Running' 'Bad' }
    else { Set-Value $HypervisorCheck 'Stopped' 'Good' }

    switch ($Snapshot.VbsStatus) {
        $null { Set-Value $VbsCheck 'Unavailable' 'Muted' }
        0 { Set-Value $VbsCheck 'Off' 'Good' }
        1 { Set-Value $VbsCheck 'Configured' 'Warn' }
        2 { Set-Value $VbsCheck 'Running' 'Bad' }
        default { Set-Value $VbsCheck 'Unknown' 'Muted' }
    }

    if ($null -eq $Snapshot.Domain) { Set-Value $ManagedCheck 'Unavailable' 'Muted' }
    elseif ($Snapshot.Domain) { Set-Value $ManagedCheck 'Work or school' 'Warn' }
    else { Set-Value $ManagedCheck 'This PC' 'Neutral' }
    $ManagedNote.Visibility = if ($Snapshot.Domain) { 'Visible' } else { 'Collapsed' }

    $alreadyOff = [bool]$Snapshot.AlreadyOff
    $liveUnknown = ($null -eq $Snapshot.Hypervisor) -or ($null -eq $Snapshot.VbsStatus)
    $state = Get-CurrentState
    $taskExists = $null -ne (Get-ScheduledTask -TaskName $continuationTaskName -ErrorAction SilentlyContinue)
    $engineBusy = Test-EngineBusy
    $VerifyButton.IsEnabled = -not ($engineBusy -or $taskExists)
    $OpenFilesButton.IsEnabled = Test-Path -LiteralPath $workRoot
    $OpenReportButton.Visibility = if (Test-Path -LiteralPath $reportPath) { 'Visible' } else { 'Collapsed' }

    $restartPending = (Get-Date) -lt $script:restartPendingUntil
    $CancelRestartButton.Visibility = if ($restartPending) { 'Visible' } else { 'Collapsed' }

    if ($alreadyOff) {
        # Smart stop: Hyper-V is already off, so never re-open the tool at sign-in.
        Remove-StartupReopen
    }

    $stateCompleted = (Test-HasProperty $state 'Completed') -and [bool]$state.Completed
    $stateHasBackup = Test-HasProperty $state 'RestorePointDescription'
    $attempt = if (Test-HasProperty $state 'Attempt') { "$($state.Attempt)" } else { '1' }

    Set-Busy ($engineBusy -or $restartPending)

    if ($engineBusy) {
        Disarm-Confirmation
        Set-HeaderPill 'WORKING' 'Accent'
        $LastRunCheck.Text = 'In progress'
        $LastRunCheck.Foreground = Get-Brush $toneColors.Accent
        if ($script:engineMode -eq 'Verify') {
            $StatusKicker.Text = 'CHECKING'
            $StatusTitle.Text = 'Checking this PC.'
            $StatusSubtitle.Text = 'Reading boot, feature and security settings. Nothing is being changed.'
            Set-Steps @('Pending','Pending','Pending','Active') @('','','','Checking')
            $FooterTitle.Text = 'Checking this PC...'
        } else {
            $StatusKicker.Text = 'IN PROGRESS'
            $StatusTitle.Text = 'Turning off Hyper-V.'
            $StatusSubtitle.Text = 'Creating the restore point can take a minute or two. You can keep this window open or close it; the work carries on either way.'
            if ($stateHasBackup) { Set-Steps @('Done','Active','Pending','Pending') } else { Set-Steps @('Active','Pending','Pending','Pending') }
            $FooterTitle.Text = 'Turning off Hyper-V...'
        }
        $FooterSubtitle.Text = 'The log updates live as each step finishes.'
        $RunButton.Content = 'Working...'
        $RunButton.IsEnabled = $false
        return
    }

    if ($alreadyOff -or $stateCompleted) {
        Disarm-Confirmation
        $LastRunCheck.Text = if ($stateCompleted) { 'Finished' } elseif ($null -ne $state) { 'Earlier run' } else { 'Never' }
        $LastRunCheck.Foreground = Get-Brush $(if ($stateCompleted) { $toneColors.Good } else { $toneColors.Neutral })
        if ($alreadyOff) {
            Set-HeaderPill 'OFF' 'Good'
            $StatusKicker.Text = 'ALL CLEAR'
            $StatusTitle.Text = 'Hyper-V is off.'
            $StatusSubtitle.Text = 'No hypervisor is running and VBS is off, so there is nothing to change. The tool will not open by itself any more.'
            Set-Steps @('Done','Done','Done','Done')
            $FooterTitle.Text = 'Nothing left to do.'
            $FooterSubtitle.Text = 'You can run a check at any time.'
            $RunButton.Content = 'Already off'
            $RunButton.IsEnabled = $false
        }
        elseif ($liveUnknown) {
            # Finished, but Windows will not report live status right now: do not guess.
            Set-HeaderPill 'DONE' 'Good'
            $StatusKicker.Text = 'FINISHED'
            $StatusTitle.Text = 'The run has finished.'
            $StatusSubtitle.Text = 'Windows is not reporting live hypervisor status right now. Final-Status.txt and the Log have the verified result.'
            Set-Steps @('Done','Done','Done','Done')
            $FooterTitle.Text = 'Nothing left to do.'
            $FooterSubtitle.Text = 'Review the Log for anything that still needs attention.'
            $RunButton.Content = 'Finished'
            $RunButton.IsEnabled = $false
        }
        else {
            # The run finished, but the live readings say something is still on.
            Set-HeaderPill 'ATTENTION' 'Warn'
            $StatusKicker.Text = 'NEEDS ATTENTION'
            $StatusTitle.Text = 'Finished, but not everything is off.'
            $StatusSubtitle.Text = 'The run completed, yet this PC still reports Hyper-V or VBS as active. The Log names what is left and how to fix it.'
            Set-Steps @('Done','Done','Done','Failed') @('','','','Check the log')
            $FooterTitle.Text = 'Something is still switched on.'
            $FooterSubtitle.Text = 'Fix the item named in the Log, then run it again.'
            $RunButton.Content = 'Run again'
            $RunButton.IsEnabled = $true
        }
        return
    }

    if ($taskExists) {
        Disarm-Confirmation
        $LastRunCheck.Text = "Restart $attempt of 2"
        $LastRunCheck.Foreground = Get-Brush $toneColors.Accent
        Set-HeaderPill 'RESTARTING' 'Accent'
        $StatusKicker.Text = 'IN PROGRESS'
        if ($restartPending) {
            $seconds = [int][Math]::Ceiling(($script:restartPendingUntil - (Get-Date)).TotalSeconds)
            $StatusTitle.Text = "Restarting in about $seconds s."
            $StatusSubtitle.Text = 'Save any open work now. If a Microsoft confirmation screen appears at boot, approve it with the key shown (commonly F3).'
        } else {
            $StatusTitle.Text = 'Waiting for the restart.'
            $StatusSubtitle.Text = 'Restart Windows when ready. The tool carries on automatically after sign-in and keeps using the same log.'
        }
        Set-Steps @('Done','Done','Active','Pending') @('','',"Restart $attempt of 2",'')
        $FooterTitle.Text = if ($restartPending) { 'Restart scheduled. Save your work.' } else { 'Everything is staged for the restart.' }
        $FooterSubtitle.Text = 'The log stays available through every restart.'
        $RunButton.Content = 'Already running'
        $RunButton.IsEnabled = $false
        return
    }

    if ($null -ne $state -and (Test-HasProperty $state 'Attempt')) {
        # A previous run ended without completing: surface it instead of looking fresh.
        $LastRunCheck.Text = 'Incomplete'
        $LastRunCheck.Foreground = Get-Brush $toneColors.Warn
        Set-HeaderPill 'ATTENTION' 'Warn'
        $StatusKicker.Text = 'NEEDS ATTENTION'
        $StatusTitle.Text = 'The last run did not finish.'
        $StatusSubtitle.Text = 'Open the Log to see exactly what stopped it and what to do next.'
        if ($stateHasBackup) { Set-Steps @('Done','Failed','Pending','Pending') } else { Set-Steps @('Failed','Pending','Pending','Pending') }
        if (-not $script:confirmationArmed) {
            $FooterTitle.Text = 'The last attempt stopped early.'
            $FooterSubtitle.Text = 'Fix the item named in the Log, then try again.'
            $RunButton.Content = 'Try again'
        }
        $RunButton.IsEnabled = $true
        return
    }

    Set-HeaderPill 'READY' 'Accent'
    $LastRunCheck.Text = if ($null -ne $state) { 'Earlier run' } else { 'Never' }
    $LastRunCheck.Foreground = Get-Brush $toneColors.Neutral
    $StatusKicker.Text = 'BEFORE YOU START'
    $StatusTitle.Text = 'Ready to turn off Hyper-V.'
    $StatusSubtitle.Text = 'Nothing changes until you start. Save your work and make sure you know your account password; the PIN will be turned off.'
    Set-Steps @('Pending','Pending','Pending','Pending')
    if (-not $script:confirmationArmed) {
        $FooterTitle.Text = 'Nothing has been changed yet.'
        $FooterSubtitle.Text = 'Check the options and save your work before starting.'
        $RunButton.Content = 'Turn off Hyper-V'
    }
    $RunButton.IsEnabled = $true
}

function Disarm-Confirmation {
    if (-not $script:confirmationArmed) { return }
    $script:confirmationArmed = $false
    $ConfirmBanner.Visibility = 'Collapsed'
    $CancelConfirmButton.Visibility = 'Collapsed'
    $RunButton.Content = 'Turn off Hyper-V'
}

function Arm-Confirmation {
    $script:confirmationArmed = $true
    $script:confirmDeadline = (Get-Date).AddSeconds($confirmWindowSeconds)
    $RunButton.Content = 'Yes, turn it off'
    $FooterTitle.Text = 'Please confirm before continuing.'
    $FooterSubtitle.Text = 'Review the options, then click again. Press Esc or Cancel to back out.'
    $ConfirmBanner.Visibility = 'Visible'
    $CancelConfirmButton.Visibility = 'Visible'
    Update-ConfirmCountdown
    Show-Panel -Name 'Controls'
    $RunButton.Focus() | Out-Null
}

function Update-ConfirmCountdown {
    if (-not $script:confirmationArmed) { return }
    $remaining = [int][Math]::Ceiling(($script:confirmDeadline - (Get-Date)).TotalSeconds)
    if ($remaining -le 0) {
        Disarm-Confirmation
        Read-LiveStatus
        return
    }
    $ConfirmCountdown.Text = "Confirm within $remaining s, or this resets."
}

function Set-ReopenAfterSignIn {
    # Never arm the sign-in reopen when Hyper-V is already confirmed off.
    if (-not $ReopenToggle.IsChecked) { Remove-StartupReopen; return }
    if (Test-HypervisorAlreadyOff) { Remove-StartupReopen; return }
    $command = '"{0}" -NoProfile -STA -ExecutionPolicy Bypass -File "{1}" -Resume' -f $windowsPowerShell, $PSCommandPath
    try {
        New-Item -Path $runOncePath -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -Path $runOncePath -Name $runOnceName -PropertyType String -Value $command -Force -ErrorAction Stop | Out-Null
    }
    catch {
        Add-UiEvent -Level Warning -Code 'REOPEN_ARM_FAILED' `
            -Message "Could not schedule the app to reopen after sign-in: $($_.Exception.Message)" `
            -ActionRequired 'After the restart, open this tool manually from the same folder. The disablement itself continues automatically.'
    }
}

function Start-Engine {
    param([switch] $Verify)
    if (Test-EngineBusy) { return }
    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $enginePath))
    if ($Verify) {
        $arguments += '-VerifyOnly'
    }
    else {
        if (Test-HypervisorAlreadyOff) {
            Add-UiEvent -Level Success -Code 'SKIP_ALREADY_OFF' `
                -Message 'Hyper-V was already off, so the operation was skipped.'
            Read-LiveStatus
            return
        }
        if (-not $AutoRestartToggle.IsChecked) { $arguments += '-NoRestart' }
        if (-not $FirmwareToggle.IsChecked) { $arguments += '-SkipFirmwareOptOut' }
        Set-ReopenAfterSignIn
    }
    try {
        $script:engineProcess = Start-Process -FilePath $windowsPowerShell -ArgumentList ($arguments -join ' ') -WindowStyle Hidden -PassThru -ErrorAction Stop
        $script:engineMode = if ($Verify) { 'Verify' } else { 'Run' }
    }
    catch {
        Add-UiEvent -Level Error -Code 'ENGINE_START_FAILED' `
            -Message "Could not start the engine: $($_.Exception.Message)" `
            -ActionRequired 'Keep both PowerShell files in the same folder, then try again.'
        Read-LiveStatus
        return
    }
    Show-Panel -Name 'Activity'
    Read-LiveStatus
}

function Get-DefenderStatusInfo {
    $info = @{ TamperProtection = 'Unavailable'; RealTimeProtection = 'Unavailable'; Service = 'Unavailable'; TamperOn = $false }
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        $info.TamperProtection = if ([bool]$mp.IsTamperProtected) { 'On' } else { 'Off' }
        $info.TamperOn = [bool]$mp.IsTamperProtected
        $info.RealTimeProtection = if ([bool]$mp.RealTimeProtectionEnabled) { 'On' } else { 'Off' }
    } catch { }
    try {
        $svc = Get-Service -Name WinDefend -ErrorAction Stop
        $info.Service = "$($svc.Status)"
    } catch { }
    return $info
}

function Update-DefenderStatusUI {
    $d = Get-DefenderStatusInfo
    Set-Value $DefTamperValue "$($d.TamperProtection)" $(if ($d.TamperOn) { 'Warn' } elseif ($d.TamperProtection -eq 'Off') { 'Good' } else { 'Muted' })
    Set-Value $DefRtValue "$($d.RealTimeProtection)" $(if ($d.RealTimeProtection -eq 'On') { 'Good' } elseif ($d.RealTimeProtection -eq 'Off') { 'Bad' } else { 'Muted' })
    Set-Value $DefSvcValue "$($d.Service)" $(if ($d.Service -eq 'Running') { 'Good' } elseif ($d.Service -eq 'Stopped') { 'Bad' } else { 'Muted' })
    $DefenderNote.Text = if ($d.TamperOn) { 'Tamper Protection is on right now, so most changes will be blocked.' } else { '' }
    $DefenderNote.Foreground = Get-Brush $toneColors.Warn
    return $d
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
        } catch { }
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
    param([ValidateSet('Disable','Enable')][string] $Mode)

    $defenderServices = @('WinDefend','WdNisSvc','WdFilter','WdBoot')
    $disabling = ($Mode -eq 'Disable')

    if ($disabling) {
        Save-ServiceStartBackup -ServiceNames @('WinDefend','WdNisSvc','WdFilter','WdBoot','SecurityHealthService')

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

        foreach ($service in @('WinDefend','WdNisSvc')) {
            try { Stop-Service -Name $service -Force -ErrorAction SilentlyContinue } catch { }
        }
        foreach ($driver in @('WdFilter','WdBoot')) {
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
            New-ItemProperty -Path $startupKey -Name 'SecurityHealth' -PropertyType Binary -Value ([byte[]]@(3,0,0,0,0,0,0,0,0,0,0,0)) -Force -ErrorAction SilentlyContinue | Out-Null
        } catch { }

        Add-UiEvent -Level Success -Code 'DEFENDER_DISABLED' `
            -Message 'Applied the Windows Security off state for testing.'
    }
    else {
        $originalStarts = @{}
        if (Test-Path -LiteralPath $defenderBackupPath) {
            try {
                foreach ($property in (Get-Content -LiteralPath $defenderBackupPath -Raw | ConvertFrom-Json).PSObject.Properties) {
                    $originalStarts[$property.Name] = [int]$property.Value
                }
            } catch { }
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

        foreach ($service in @('WinDefend','WdNisSvc','SecurityHealthService')) {
            try { Start-Service -Name $service -ErrorAction SilentlyContinue } catch { }
        }

        try {
            $startupKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
            if (-not (Test-Path -LiteralPath $startupKey)) { New-Item -Path $startupKey -Force | Out-Null }
            New-ItemProperty -Path $startupKey -Name 'SecurityHealth' -PropertyType Binary -Value ([byte[]]@(2,0,0,0,0,0,0,0,0,0,0,0)) -Force -ErrorAction SilentlyContinue | Out-Null
            $tray = Join-Path $env:SystemRoot 'System32\SecurityHealthSystray.exe'
            if ((Get-Service -Name SecurityHealthService -ErrorAction SilentlyContinue).Status -eq 'Running' -and
                -not (Get-Process -Name SecurityHealthSystray -ErrorAction SilentlyContinue) -and
                (Test-Path -LiteralPath $tray)) {
                Start-Process -FilePath $tray -WindowStyle Hidden
            }
        } catch { }

        # The backup has served its purpose; the next Disable should capture fresh originals.
        Remove-Item -LiteralPath $defenderBackupPath -Force -ErrorAction SilentlyContinue

        Add-UiEvent -Level Success -Code 'DEFENDER_ENABLED' `
            -Message 'Restored Windows Security settings. If Defender does not start, restart the PC.'
    }

    Update-DefenderStatusUI | Out-Null
}

function Reset-DefenderArm {
    $script:defenderArmed = $false
    $DefenderDisableButton.Content = 'Disable Windows Security'
}

function Invoke-DefenderAction {
    param([ValidateSet('Disable','Enable')][string] $Mode)
    $DefenderDisableButton.IsEnabled = $false
    $DefenderEnableButton.IsEnabled = $false
    $window.Cursor = [Windows.Input.Cursors]::Wait
    try { Invoke-WindowsSecurityChange -Mode $Mode }
    catch {
        if ($Mode -eq 'Disable') {
            Add-UiEvent -Level Error -Code 'DEFENDER_DISABLE_FAILED' `
                -Message "Windows Security could not be fully disabled: $($_.Exception.Message)" `
                -ActionRequired 'Turn off Tamper Protection in Windows Security first, then try again.'
        } else {
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

# ---------------------------------------------------------------- events

$TitleBar.Add_MouseLeftButtonDown({
    if ($_.ButtonState -eq [Windows.Input.MouseButtonState]::Pressed) {
        try { $window.DragMove() } catch { }
    }
})
$MinimizeButton.Add_Click({ $window.WindowState = [Windows.WindowState]::Minimized })
$CloseButton.Add_Click({ $window.Close() })
$OverviewNav.Add_Checked({ Show-Panel -Name 'Overview' })
$ControlsNav.Add_Checked({ Show-Panel -Name 'Controls' })
$TestingNav.Add_Checked({ Show-Panel -Name 'Testing'; Update-DefenderStatusUI | Out-Null })
$ActivityNav.Add_Checked({ Show-Panel -Name 'Activity' })
$ActivityShortcut.Add_Click({ Show-Panel -Name 'Activity' })
$OpenFilesButton.Add_Click({ if (Test-Path -LiteralPath $workRoot) { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $workRoot) } })
$OpenReportButton.Add_Click({ if (Test-Path -LiteralPath $reportPath) { Start-Process notepad.exe -ArgumentList ('"{0}"' -f $reportPath) } })
$VerifyButton.Add_Click({ Start-Engine -Verify })

$CancelConfirmButton.Add_Click({ Disarm-Confirmation; Read-LiveStatus; Show-Panel -Name 'Overview' })

$CancelRestartButton.Add_Click({
    & shutdown.exe /a 2>&1 | Out-Null
    $script:restartPendingUntil = [datetime]::MinValue
    Add-UiEvent -Level Action -Code 'RESTART_CANCELLED' `
        -Message 'The automatic restart was cancelled.' `
        -ActionRequired 'Restart Windows when you are ready. The tool carries on automatically after the restart.'
    Read-LiveStatus
})

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

$AllFilter.Add_Checked({ $script:lastEventSignature = ''; Refresh-Activity })
$ActionFilter.Add_Checked({ $script:lastEventSignature = ''; Refresh-Activity })
$FailureFilter.Add_Checked({ $script:lastEventSignature = ''; Refresh-Activity })

$RunButton.Add_Click({
    if (-not $RunButton.IsEnabled -or (Test-EngineBusy)) { return }
    if (-not $script:confirmationArmed) {
        if (Test-HypervisorAlreadyOff) {
            Add-UiEvent -Level Success -Code 'SKIP_ALREADY_OFF' `
                -Message 'Hyper-V was already off, so the operation was skipped.'
            Read-LiveStatus
            return
        }
        Arm-Confirmation
        return
    }
    Disarm-Confirmation
    $RunButton.Content = 'Working...'
    $RunButton.IsEnabled = $false
    Start-Engine
})

$window.Add_PreviewKeyDown({
    if ($_.Key -eq [Windows.Input.Key]::Escape -and $script:confirmationArmed) {
        Disarm-Confirmation
        Read-LiveStatus
        $_.Handled = $true
    }
})

# A fast one-second clock drives countdowns; the heavier status read runs every other tick.
$script:tick = 0
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.Add_Tick({
    try {
        $script:tick++
        Update-ConfirmCountdown
        if ($script:defenderArmed -and (Get-Date) -gt $script:defenderDeadline) { Reset-DefenderArm }
        $restartPending = (Get-Date) -lt $script:restartPendingUntil
        if (($script:tick % 2) -ne 0 -and -not $restartPending) { return }

        Refresh-Activity
        $snapshot = Get-SystemSnapshot
        Read-LiveStatus -Snapshot $snapshot
        $script:defenderTickCounter++
        if ($TestingPanel.Visibility -eq 'Visible' -and ($script:defenderTickCounter % 5) -eq 0) { Update-DefenderStatusUI | Out-Null }
        if ($Resume) {
            $state = Get-CurrentState
            $stillWorking = $null -ne $state -and -not ((Test-HasProperty $state 'Completed') -and [bool]$state.Completed)
            if ($stillWorking -and -not $snapshot.AlreadyOff) { Set-ReopenAfterSignIn }
            else { Remove-StartupReopen }
        }
    }
    catch {
        # A transient read failure must never take the window down.
    }
})
$window.Add_Closed({ $timer.Stop() })

$MachineSubTitle.Text = "$env:COMPUTERNAME  ·  $env:PROCESSOR_ARCHITECTURE  ·  Administrator"

# Gentle entrance.
$window.Opacity = 0
$window.Add_ContentRendered({
    $fadeIn = New-Object Windows.Media.Animation.DoubleAnimation(0, 1, [Windows.Duration]::new([TimeSpan]::FromMilliseconds(260)))
    $window.BeginAnimation([Windows.Window]::OpacityProperty, $fadeIn)
})

Refresh-Activity
Read-LiveStatus
if ($Resume) { Show-Panel -Name 'Activity' }
$timer.Start()
[void]$window.ShowDialog()
