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

$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-IsAdministrator)) {
    $arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}"{1}' -f $PSCommandPath, $(if ($Resume) { ' -Resume' } else { '' })
    Start-Process -FilePath $windowsPowerShell -ArgumentList $arguments -Verb RunAs
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
        Title="Hyper-V Off Tool" Width="1200" Height="810"
        MinWidth="1080" MinHeight="720" WindowStartupLocation="CenterScreen"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        FontFamily="Segoe UI Variable Display, Segoe UI" Foreground="#EDF1F6">
  <Window.Resources>
    <SolidColorBrush x:Key="AccentBrush" Color="#6C9EFF"/>
    <SolidColorBrush x:Key="TextPrimary" Color="#EDF1F6"/>
    <SolidColorBrush x:Key="TextMuted" Color="#7E8894"/>
    <SolidColorBrush x:Key="CardBg" Color="#10151C"/>
    <SolidColorBrush x:Key="CardBgAlt" Color="#0D1218"/>
    <SolidColorBrush x:Key="CardStroke" Color="#1D2530"/>
    <SolidColorBrush x:Key="GoodBrush" Color="#43D9A3"/>
    <SolidColorBrush x:Key="WarnBrush" Color="#F2B84B"/>
    <SolidColorBrush x:Key="BadBrush" Color="#FF7A6E"/>

    <DropShadowEffect x:Key="WindowShadow" BlurRadius="46" ShadowDepth="0" Opacity="0.55" Color="#000000"/>
    <DropShadowEffect x:Key="PrimaryGlow" BlurRadius="22" ShadowDepth="0" Opacity="0.45" Color="#4D7FE8"/>

    <LinearGradientBrush x:Key="PrimaryFill" StartPoint="0,0" EndPoint="0,1">
      <GradientStop Color="#7FA8FF" Offset="0"/>
      <GradientStop Color="#5B84EE" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="DangerFill" StartPoint="0,0" EndPoint="0,1">
      <GradientStop Color="#FF8A80" Offset="0"/>
      <GradientStop Color="#E85D51" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="WindowFill" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#0A0E14" Offset="0"/>
      <GradientStop Color="#07090D" Offset="0.55"/>
      <GradientStop Color="#0A0D13" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="HeroGlow" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#131C2B" Offset="0"/>
      <GradientStop Color="#0F141C" Offset="1"/>
    </LinearGradientBrush>

    <Style x:Key="GhostButton" TargetType="Button">
      <Setter Property="Foreground" Value="#C7CED6"/>
      <Setter Property="Background" Value="#141A22"/>
      <Setter Property="BorderBrush" Value="#27303C"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="16,9"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Cursor" Value="Hand"/>
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
                <Setter TargetName="Chrome" Property="Background" Value="#1B2330"/>
                <Setter TargetName="Chrome" Property="BorderBrush" Value="#38445A"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Chrome" Property="Background" Value="#161D27"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Chrome" Property="Opacity" Value="0.38"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="PrimaryButton" TargetType="Button">
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="Background" Value="{StaticResource PrimaryFill}"/>
      <Setter Property="Padding" Value="24,11"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Effect" Value="{StaticResource PrimaryGlow}"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Chrome" CornerRadius="10" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Chrome" Property="Background">
                  <Setter.Value>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                      <GradientStop Color="#93B6FF" Offset="0"/>
                      <GradientStop Color="#6E94F5" Offset="1"/>
                    </LinearGradientBrush>
                  </Setter.Value>
                </Setter>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Chrome" Property="Opacity" Value="0.85"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Chrome" Property="Opacity" Value="0.35"/>
                <Setter Property="Effect" Value="{x:Null}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="DangerButton" TargetType="Button" BasedOn="{StaticResource GhostButton}">
      <Setter Property="Foreground" Value="#FFB4AD"/>
      <Setter Property="BorderBrush" Value="#4A2A28"/>
      <Setter Property="Padding" Value="18,9"/>
    </Style>

    <Style x:Key="NavRadio" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#828D99"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Padding" Value="14,11"/>
      <Setter Property="Margin" Value="0,2"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Grid>
              <Border x:Name="NavChrome" CornerRadius="10" Background="{TemplateBinding Background}"
                      Padding="{TemplateBinding Padding}">
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="{TemplateBinding Tag}" FontFamily="Segoe MDL2 Assets" FontSize="14"
                             VerticalAlignment="Center" x:Name="Glyph"/>
                  <ContentPresenter Margin="12,0,0,0" VerticalAlignment="Center"/>
                </StackPanel>
              </Border>
              <Rectangle x:Name="Indicator" Width="3" RadiusX="1.5" RadiusY="1.5"
                         Fill="Transparent" HorizontalAlignment="Left" VerticalAlignment="Stretch" Margin="-20,9"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="NavChrome" Property="Background" Value="#131923"/>
                <Setter Property="Foreground" Value="#C9D2DC"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="NavChrome" Property="Background" Value="#151D29"/>
                <Setter Property="Foreground" Value="#DCE6F5"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
                <Setter TargetName="Indicator" Property="Fill" Value="{StaticResource AccentBrush}"/>
                <Setter TargetName="Glyph" Property="Foreground" Value="{StaticResource AccentBrush}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="FilterRadio" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#8892A0"/>
      <Setter Property="Background" Value="#11161E"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Margin" Value="4,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="FilterChrome" CornerRadius="8" Background="{TemplateBinding Background}"
                    BorderBrush="#232C38" BorderThickness="1" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="FilterChrome" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="FilterChrome" Property="Background" Value="#182338"/>
                <Setter TargetName="FilterChrome" Property="BorderBrush" Value="#33507E"/>
                <Setter Property="Foreground" Value="#BCCEF0"/>
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
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid>
              <Border x:Name="Track" CornerRadius="14" Background="#222A35" BorderBrush="#303B49" BorderThickness="1"/>
              <Ellipse x:Name="Thumb" Width="20" Height="20" Fill="#98A2AE" HorizontalAlignment="Left" Margin="4,0">
                <Ellipse.Effect><DropShadowEffect BlurRadius="8" ShadowDepth="1" Opacity="0.5"/></Ellipse.Effect>
              </Ellipse>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="{StaticResource PrimaryFill}"/>
                <Setter TargetName="Track" Property="BorderBrush" Value="#7FA8FF"/>
                <Setter TargetName="Thumb" Property="Fill" Value="#FFFFFF"/>
                <Setter TargetName="Thumb" Property="HorizontalAlignment" Value="Right"/>
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
      <Setter Property="CornerRadius" Value="7"/>
      <Setter Property="Padding" Value="11,5"/>
    </Style>
  </Window.Resources>

  <Grid Margin="16">
    <Border Effect="{StaticResource WindowShadow}"/>
    <Border CornerRadius="18" BorderBrush="#212A36" BorderThickness="1" Background="{StaticResource WindowFill}">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="56"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="86"/>
      </Grid.RowDefinitions>

      <Grid x:Name="TitleBar" Grid.Row="0" Margin="22,0,14,0" Background="Transparent">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Border Width="32" Height="32" CornerRadius="9">
            <Border.Background>
              <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                <GradientStop Color="#7FA8FF" Offset="0"/>
                <GradientStop Color="#5B84EE" Offset="1"/>
              </LinearGradientBrush>
            </Border.Background>
            <TextBlock Text="&#xE72E;" FontFamily="Segoe MDL2 Assets" FontSize="15" Foreground="#FFFFFF"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
            <TextBlock Text="Hyper-V Off Tool" FontWeight="SemiBold" FontSize="14"/>
            <TextBlock x:Name="MachineSubTitle" Text="" Foreground="#6C7683" FontSize="11" Margin="0,1,0,0"/>
          </StackPanel>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="MinimizeButton" Content="&#xE921;" FontFamily="Segoe MDL2 Assets" FontSize="11"
                  Width="38" Height="30" Style="{StaticResource GhostButton}" Padding="0" Margin="0,0,6,0"/>
          <Button x:Name="CloseButton" Content="&#xE8BB;" FontFamily="Segoe MDL2 Assets" FontSize="11"
                  Width="38" Height="30" Style="{StaticResource GhostButton}" Padding="0"/>
        </StackPanel>
      </Grid>

      <Grid Grid.Row="1" Margin="20,4,20,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="228"/>
          <ColumnDefinition Width="18"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <Border Grid.Column="0" CornerRadius="14" Background="{StaticResource CardBgAlt}" BorderBrush="{StaticResource CardStroke}" BorderThickness="1" Padding="16,18">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <StackPanel Margin="4,2,4,22">
              <TextBlock Text="SYSTEM TOOL" Foreground="#5E6976" FontSize="10" FontWeight="Bold"/>
              <TextBlock Text="Turn off Hyper-V" FontSize="22" FontWeight="SemiBold" Margin="0,8,0,0" Foreground="{StaticResource TextPrimary}"/>
            </StackPanel>
            <StackPanel Grid.Row="1">
              <RadioButton x:Name="OverviewNav" Content="Overview" Tag="&#xE80F;" GroupName="Navigation" IsChecked="True" Style="{StaticResource NavRadio}"/>
              <RadioButton x:Name="ControlsNav" Content="Options" Tag="&#xE713;" GroupName="Navigation" Style="{StaticResource NavRadio}"/>
              <RadioButton x:Name="TestingNav" Content="Testing" Tag="&#xE90F;" GroupName="Navigation" Style="{StaticResource NavRadio}"/>
              <RadioButton x:Name="ActivityNav" Content="Log" Tag="&#xE9D9;" GroupName="Navigation" Style="{StaticResource NavRadio}"/>
            </StackPanel>
            <Border Grid.Row="3" CornerRadius="11" Background="#0F1620" BorderBrush="#1B2735" BorderThickness="1" Padding="15,14">
              <StackPanel>
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="&#xE72E;" FontFamily="Segoe MDL2 Assets" FontSize="13" Foreground="{StaticResource GoodBrush}" VerticalAlignment="Center"/>
                  <TextBlock Text="Safety checks" Foreground="#D4DBE3" FontWeight="SemiBold" Margin="9,0,0,0" VerticalAlignment="Center"/>
                </StackPanel>
                <TextBlock Text="Restore point, settings backup, and BitLocker protection always run first." Foreground="#66717F" FontSize="11" TextWrapping="Wrap" Margin="0,7,0,0" LineHeight="16"/>
              </StackPanel>
            </Border>
          </Grid>
        </Border>

        <Grid Grid.Column="2">
          <Grid x:Name="OverviewPanel">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <Grid Margin="6,12,6,20">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <StackPanel>
                <TextBlock Text="This PC" FontSize="28" FontWeight="SemiBold"/>
                <TextBlock Text="Check what is running before anything gets changed." Foreground="{StaticResource TextMuted}" Margin="0,6,0,0"/>
              </StackPanel>
              <Border Grid.Column="1" Style="{StaticResource Chip}" Background="#152036" BorderBrush="#2C4470" BorderThickness="1" VerticalAlignment="Top">
                <TextBlock x:Name="HeaderStatus" Text="READY" Foreground="#A9C4F5" FontSize="10" FontWeight="Bold"/>
              </Border>
            </Grid>

            <Grid Grid.Row="1">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="1.45*"/>
                <ColumnDefinition Width="16"/>
                <ColumnDefinition Width="1*"/>
              </Grid.ColumnDefinitions>
              <Border Grid.Column="0" CornerRadius="14" Background="{StaticResource HeroGlow}" BorderBrush="#263349" BorderThickness="1" Padding="30">
                <Grid>
                  <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="24"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="22"/>
                    <RowDefinition Height="Auto"/>
                  </Grid.RowDefinitions>
                  <StackPanel>
                    <TextBlock x:Name="StatusKicker" Text="BEFORE YOU START" Foreground="{StaticResource AccentBrush}" FontSize="10" FontWeight="Bold"/>
                    <TextBlock x:Name="StatusTitle" Text="Ready to check this PC" FontSize="32" FontWeight="SemiBold" Margin="0,12,0,0" TextWrapping="Wrap"/>
                    <TextBlock x:Name="StatusSubtitle" Text="First we will check what is running. Nothing changes until you start the process." Foreground="#96A0AC" FontSize="13" TextWrapping="Wrap" Margin="0,10,0,0" MaxWidth="520" HorizontalAlignment="Left" LineHeight="20"/>
                  </StackPanel>
                  <Border Grid.Row="2" CornerRadius="11" Background="#0B1016" BorderBrush="#1B2530" BorderThickness="1" Padding="19,4">
                    <Grid>
                      <Grid.RowDefinitions>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="*"/>
                      </Grid.RowDefinitions>
                      <Grid Margin="0,10"><Grid.ColumnDefinitions><ColumnDefinition Width="30"/><ColumnDefinition Width="92"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><TextBlock Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" Foreground="#3E5A78" VerticalAlignment="Center"/><TextBlock Grid.Column="1" Text="Back up" Foreground="#CBD4DE" FontWeight="SemiBold"/><TextBlock Grid.Column="2" Text="Make a restore point and save the current settings" Foreground="#75808C"/></Grid>
                      <Border Grid.Row="1" BorderBrush="#182130" BorderThickness="0,1,0,0"><Grid Margin="0,10"><Grid.ColumnDefinitions><ColumnDefinition Width="30"/><ColumnDefinition Width="92"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><TextBlock Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" Foreground="#3E5A78" VerticalAlignment="Center"/><TextBlock Grid.Column="1" Text="Turn off" Foreground="#CBD4DE" FontWeight="SemiBold"/><TextBlock Grid.Column="2" Text="Disable Hyper-V, VBS, Windows Hello PIN, and related Windows features" Foreground="#75808C"/></Grid></Border>
                      <Border Grid.Row="2" BorderBrush="#182130" BorderThickness="0,1,0,0"><Grid Margin="0,10"><Grid.ColumnDefinitions><ColumnDefinition Width="30"/><ColumnDefinition Width="92"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><TextBlock Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" Foreground="#3E5A78" VerticalAlignment="Center"/><TextBlock Grid.Column="1" Text="Restart" Foreground="#CBD4DE" FontWeight="SemiBold"/><TextBlock Grid.Column="2" Text="Restart automatically if Windows needs it" Foreground="#75808C"/></Grid></Border>
                      <Border Grid.Row="3" BorderBrush="#182130" BorderThickness="0,1,0,0"><Grid Margin="0,10"><Grid.ColumnDefinitions><ColumnDefinition Width="30"/><ColumnDefinition Width="92"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><TextBlock Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" Foreground="#3E5A78" VerticalAlignment="Center"/><TextBlock Grid.Column="1" Text="Check again" Foreground="#CBD4DE" FontWeight="SemiBold"/><TextBlock Grid.Column="2" Text="Make sure the Hyper-V parts are actually off" Foreground="#75808C"/></Grid></Border>
                    </Grid>
                  </Border>
                  <StackPanel Grid.Row="4" Orientation="Horizontal">
                    <Button x:Name="VerifyButton" Content="Check this PC" Style="{StaticResource GhostButton}"/>
                    <Button x:Name="OpenFilesButton" Content="Open log folder" Style="{StaticResource GhostButton}" Margin="10,0,0,0"/>
                  </StackPanel>
                </Grid>
              </Border>

              <Border Grid.Column="2" CornerRadius="14" Background="{StaticResource CardBg}" BorderBrush="{StaticResource CardStroke}" BorderThickness="1" Padding="24">
                <StackPanel>
                  <TextBlock Text="Quick check" FontSize="15" FontWeight="SemiBold" Margin="0,0,0,14"/>
                  <Border BorderBrush="#1C2531" BorderThickness="0,0,0,1" Padding="0,11">
                    <Grid><TextBlock Text="Administrator" Foreground="#7E8894"/><TextBlock x:Name="AdminCheck" Text="Yes" HorizontalAlignment="Right" Foreground="#C4D2E4" FontWeight="SemiBold"/></Grid>
                  </Border>
                  <Border BorderBrush="#1C2531" BorderThickness="0,0,0,1" Padding="0,11">
                    <Grid><TextBlock Text="Hypervisor" Foreground="#7E8894"/><TextBlock x:Name="HypervisorCheck" Text="Checking" HorizontalAlignment="Right" Foreground="#C4D2E4" FontWeight="SemiBold"/></Grid>
                  </Border>
                  <Border BorderBrush="#1C2531" BorderThickness="0,0,0,1" Padding="0,11">
                    <Grid><TextBlock Text="VBS" Foreground="#7E8894"/><TextBlock x:Name="VbsCheck" Text="Checking" HorizontalAlignment="Right" Foreground="#C4D2E4" FontWeight="SemiBold"/></Grid>
                  </Border>
                  <Border BorderBrush="#1C2531" BorderThickness="0,0,0,1" Padding="0,11">
                    <Grid><TextBlock Text="Managed by" Foreground="#7E8894"/><TextBlock x:Name="ManagedCheck" Text="Checking" HorizontalAlignment="Right" Foreground="#C4D2E4" FontWeight="SemiBold"/></Grid>
                  </Border>
                  <Border Padding="0,11">
                    <Grid><TextBlock Text="Last run" Foreground="#7E8894"/><TextBlock x:Name="LastRunCheck" Text="Never" HorizontalAlignment="Right" Foreground="#C4D2E4" FontWeight="SemiBold"/></Grid>
                  </Border>
                </StackPanel>
              </Border>
            </Grid>
          </Grid>

          <Grid x:Name="ControlsPanel" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <StackPanel Margin="6,12,6,20">
              <TextBlock Text="Options" FontSize="28" FontWeight="SemiBold"/>
              <TextBlock Text="Choose how restarts should work. The safety checks always stay on." Foreground="{StaticResource TextMuted}" Margin="0,6,0,0"/>
            </StackPanel>
            <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
              <StackPanel>
                <Border CornerRadius="14" Background="{StaticResource CardBg}" BorderBrush="{StaticResource CardStroke}" BorderThickness="1" Padding="26" Margin="0,0,0,14">
                  <StackPanel>
                    <TextBlock Text="Restart settings" FontSize="15" FontWeight="SemiBold" Margin="0,0,0,10"/>
                    <Grid Margin="0,9"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="Restart automatically" FontWeight="SemiBold"/><TextBlock Text="Give you 30 seconds to save, then restart." Foreground="#79848F" FontSize="12" Margin="0,4,0,0"/></StackPanel><CheckBox x:Name="AutoRestartToggle" Grid.Column="1" Style="{StaticResource Toggle}" IsChecked="True" VerticalAlignment="Center"/></Grid>
                    <Border BorderBrush="#1C2531" BorderThickness="0,1,0,0" Margin="0,10,0,0" Padding="0,18,0,0">
                      <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="Remove the firmware lock" FontWeight="SemiBold"/><TextBlock Text="Prepare the Microsoft confirmation screen if Windows needs it." Foreground="#79848F" FontSize="12" Margin="0,4,0,0"/></StackPanel><CheckBox x:Name="FirmwareToggle" Grid.Column="1" Style="{StaticResource Toggle}" IsChecked="True" VerticalAlignment="Center"/></Grid>
                    </Border>
                    <Border BorderBrush="#1C2531" BorderThickness="0,1,0,0" Margin="0,18,0,0" Padding="0,18,0,0">
                      <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="Open again after restart" FontWeight="SemiBold"/><TextBlock Text="Bring this window back after you sign in. It stops opening on its own once Hyper-V is off." Foreground="#79848F" FontSize="12" Margin="0,4,0,0"/></StackPanel><CheckBox x:Name="ReopenToggle" Grid.Column="1" Style="{StaticResource Toggle}" IsChecked="True" VerticalAlignment="Center"/></Grid>
                    </Border>
                  </StackPanel>
                </Border>

                <Border CornerRadius="14" Background="{StaticResource CardBgAlt}" BorderBrush="{StaticResource CardStroke}" BorderThickness="1" Padding="26">
                  <StackPanel>
                    <TextBlock Text="Safety checks" FontSize="15" FontWeight="SemiBold" Margin="0,0,0,14"/>
                    <Grid Margin="0,8"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="Restore point" FontWeight="SemiBold"/><TextBlock Text="Stop if Windows cannot create and confirm one." Foreground="#79848F" FontSize="12" Margin="0,4,0,0"/></StackPanel><Border Grid.Column="1" Style="{StaticResource Chip}" Background="#12241F" BorderBrush="#1F4438" BorderThickness="1" VerticalAlignment="Center"><TextBlock Text="ALWAYS ON" Foreground="#43D9A3" FontSize="10" FontWeight="Bold"/></Border></Grid>
                    <Grid Margin="0,16,0,8"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="BitLocker protection" FontWeight="SemiBold"/><TextBlock Text="Pause it only while the PC restarts." Foreground="#79848F" FontSize="12" Margin="0,4,0,0"/></StackPanel><Border Grid.Column="1" Style="{StaticResource Chip}" Background="#12241F" BorderBrush="#1F4438" BorderThickness="1" VerticalAlignment="Center"><TextBlock Text="ALWAYS ON" Foreground="#43D9A3" FontSize="10" FontWeight="Bold"/></Border></Grid>
                    <Grid Margin="0,16,0,8"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="Settings backup" FontWeight="SemiBold"/><TextBlock Text="Save the current boot and security settings first." Foreground="#79848F" FontSize="12" Margin="0,4,0,0"/></StackPanel><Border Grid.Column="1" Style="{StaticResource Chip}" Background="#12241F" BorderBrush="#1F4438" BorderThickness="1" VerticalAlignment="Center"><TextBlock Text="ALWAYS ON" Foreground="#43D9A3" FontSize="10" FontWeight="Bold"/></Border></Grid>
                  </StackPanel>
                </Border>
              </StackPanel>
            </ScrollViewer>
          </Grid>

          <Grid x:Name="TestingPanel" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <StackPanel Margin="6,12,6,20">
              <TextBlock Text="Testing" FontSize="28" FontWeight="SemiBold"/>
              <TextBlock Text="Local test helpers. These are not part of the normal workflow." Foreground="{StaticResource TextMuted}" Margin="0,6,0,0"/>
            </StackPanel>
            <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
              <StackPanel>
                <Border CornerRadius="14" Background="#1A1214" BorderBrush="#43282B" BorderThickness="1" Padding="26" Margin="0,0,0,14">
                  <StackPanel>
                    <StackPanel Orientation="Horizontal">
                      <TextBlock Text="&#xE7BA;" FontFamily="Segoe MDL2 Assets" FontSize="15" Foreground="{StaticResource BadBrush}" VerticalAlignment="Center"/>
                      <TextBlock Text="Windows Security control" FontSize="15" FontWeight="SemiBold" Margin="10,0,0,0" VerticalAlignment="Center"/>
                    </StackPanel>
                    <TextBlock Text="For local testing only. This replaces third-party tools such as Sordum Defender Control with the same native changes: it flips the Defender policy keys, stops the WinDefend / WdNisSvc / WdFilter services, and hides the Security Health tray icon. Enable reverses everything using saved original values."
                               Foreground="#A98F91" FontSize="12" TextWrapping="Wrap" Margin="0,10,0,0" LineHeight="18"/>
                    <Border CornerRadius="10" Background="#211619" BorderBrush="#43282B" BorderThickness="1" Padding="14,11" Margin="0,14,0,0">
                      <StackPanel Orientation="Horizontal">
                        <TextBlock Text="&#xE7BA;" FontFamily="Segoe MDL2 Assets" FontSize="12" Foreground="{StaticResource WarnBrush}" VerticalAlignment="Center"/>
                        <TextBlock Text="If Tamper Protection is ON, Windows will block or revert these changes. Turn it off in Windows Security &#x2192; Virus &amp; threat protection settings first."
                                   Foreground="#D9B67A" FontSize="11.5" TextWrapping="Wrap" Margin="9,0,0,0" VerticalAlignment="Center" MaxWidth="620" LineHeight="17"/>
                      </StackPanel>
                    </Border>
                    <StackPanel Orientation="Horizontal" Margin="0,18,0,0">
                      <Button x:Name="DefenderDisableButton" Content="Disable Windows Security" Style="{StaticResource DangerButton}"/>
                      <Button x:Name="DefenderEnableButton" Content="Restore Windows Security" Style="{StaticResource GhostButton}" Margin="10,0,0,0"/>
                    </StackPanel>
                    <TextBlock x:Name="DefenderNote" Text="" Foreground="#8892A0" FontSize="11.5" TextWrapping="Wrap" Margin="0,12,0,0" LineHeight="17"/>
                  </StackPanel>
                </Border>

                <Border CornerRadius="14" Background="{StaticResource CardBg}" BorderBrush="{StaticResource CardStroke}" BorderThickness="1" Padding="26">
                  <StackPanel>
                    <TextBlock Text="Current state" FontSize="15" FontWeight="SemiBold" Margin="0,0,0,12"/>
                    <Border BorderBrush="#1C2531" BorderThickness="0,0,0,1" Padding="0,11">
                      <Grid><TextBlock Text="Tamper Protection" Foreground="#7E8894"/><TextBlock x:Name="DefTamperValue" Text="Checking" HorizontalAlignment="Right" Foreground="#C4D2E4" FontWeight="SemiBold"/></Grid>
                    </Border>
                    <Border BorderBrush="#1C2531" BorderThickness="0,0,0,1" Padding="0,11">
                      <Grid><TextBlock Text="Real-time protection" Foreground="#7E8894"/><TextBlock x:Name="DefRtValue" Text="Checking" HorizontalAlignment="Right" Foreground="#C4D2E4" FontWeight="SemiBold"/></Grid>
                    </Border>
                    <Border Padding="0,11">
                      <Grid><TextBlock Text="WinDefend service" Foreground="#7E8894"/><TextBlock x:Name="DefSvcValue" Text="Checking" HorizontalAlignment="Right" Foreground="#C4D2E4" FontWeight="SemiBold"/></Grid>
                    </Border>
                  </StackPanel>
                </Border>
              </StackPanel>
            </ScrollViewer>
          </Grid>

          <Grid x:Name="ActivityPanel" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <Grid Margin="6,12,6,20">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <StackPanel><TextBlock Text="Log" FontSize="28" FontWeight="SemiBold"/><TextBlock Text="Only important results and anything you need to fix are shown here." Foreground="{StaticResource TextMuted}" Margin="0,6,0,0"/></StackPanel>
              <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                <RadioButton x:Name="AllFilter" Content="All" GroupName="LogFilter" IsChecked="True" Style="{StaticResource FilterRadio}"/>
                <RadioButton x:Name="ActionFilter" Content="Needs attention" GroupName="LogFilter" Style="{StaticResource FilterRadio}"/>
                <RadioButton x:Name="FailureFilter" Content="Failed" GroupName="LogFilter" Style="{StaticResource FilterRadio}"/>
              </StackPanel>
            </Grid>
            <Border Grid.Row="1" CornerRadius="14" Background="{StaticResource CardBgAlt}" BorderBrush="{StaticResource CardStroke}" BorderThickness="1" Padding="10">
              <Grid>
                <StackPanel x:Name="ActivityEmpty" HorizontalAlignment="Center" VerticalAlignment="Center" MaxWidth="340">
                  <TextBlock Text="&#xE9D9;" FontFamily="Segoe MDL2 Assets" FontSize="26" Foreground="#333E4C" HorizontalAlignment="Center"/>
                  <TextBlock Text="Nothing here yet" HorizontalAlignment="Center" FontSize="16" FontWeight="SemiBold" Margin="0,10,0,0"/>
                  <TextBlock Text="Check the PC or start the process. Important results will show up here." Foreground="#75808C" TextAlignment="Center" TextWrapping="Wrap" Margin="0,8,0,0" LineHeight="18"/>
                </StackPanel>
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                  <ItemsControl x:Name="ActivityList">
                    <ItemsControl.ItemTemplate>
                      <DataTemplate>
                        <Border CornerRadius="10" Background="{Binding Background}" BorderBrush="{Binding Stroke}" BorderThickness="1" Margin="4,4,4,7" Padding="16">
                          <Grid>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="80"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                            <StackPanel><TextBlock Text="{Binding Time}" Foreground="#67717E" FontFamily="Cascadia Mono, Consolas" FontSize="11"/><TextBlock Text="{Binding Level}" Foreground="{Binding Accent}" FontWeight="Bold" FontSize="10" Margin="0,7,0,0"/></StackPanel>
                            <StackPanel Grid.Column="1"><TextBlock Text="{Binding Message}" Foreground="#E7ECF2" TextWrapping="Wrap" FontWeight="SemiBold"/><Border Visibility="{Binding ActionVisibility}" CornerRadius="8" Background="#141A22" Margin="0,10,0,0" Padding="12,9"><StackPanel><TextBlock Text="WHAT TO DO" Foreground="{Binding Accent}" FontSize="10" FontWeight="Bold"/><TextBlock Text="{Binding Action}" Foreground="#AEB8C3" TextWrapping="Wrap" Margin="0,5,0,0" LineHeight="18"/></StackPanel></Border></StackPanel>
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

      <Grid Grid.Row="2" Margin="28,0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <StackPanel VerticalAlignment="Center">
          <TextBlock x:Name="FooterTitle" Text="Nothing has been changed yet." FontWeight="SemiBold"/>
          <TextBlock x:Name="FooterSubtitle" Text="Check the options and save your work before starting." Foreground="#6C7683" FontSize="11" Margin="0,4,0,0"/>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="ActivityShortcut" Content="See log" Style="{StaticResource GhostButton}" Margin="0,0,10,0"/>
          <Button x:Name="RunButton" Content="Turn off Hyper-V" Style="{StaticResource PrimaryButton}" MinWidth="176"/>
        </StackPanel>
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
    'OverviewPanel','ControlsPanel','TestingPanel','ActivityPanel','HeaderStatus','StatusKicker','StatusTitle',
    'StatusSubtitle','AdminCheck','HypervisorCheck','VbsCheck','ManagedCheck','LastRunCheck',
    'VerifyButton','OpenFilesButton','AutoRestartToggle','FirmwareToggle','ReopenToggle',
    'DefenderDisableButton','DefenderEnableButton','DefenderNote','DefTamperValue','DefRtValue','DefSvcValue',
    'AllFilter','ActionFilter','FailureFilter','ActivityEmpty','ActivityList','FooterTitle','FooterSubtitle','ActivityShortcut','RunButton'
)
foreach ($name in $names) { Set-Variable -Name $name -Value $window.FindName($name) -Scope Script }

$script:confirmationArmed = $false
$script:lastEventSignature = ''
$script:engineProcess = $null
$script:defenderTickCounter = 0

function Show-Panel {
    param([ValidateSet('Overview','Controls','Testing','Activity')][string] $Name)
    foreach ($pair in @(@('Overview',$OverviewPanel),@('Controls',$ControlsPanel),@('Testing',$TestingPanel),@('Activity',$ActivityPanel))) {
        $pair[1].Visibility = if ($pair[0] -eq $Name) { 'Visible' } else { 'Collapsed' }
    }
    if ($Name -eq 'Overview') { $OverviewNav.IsChecked = $true }
    if ($Name -eq 'Controls') { $ControlsNav.IsChecked = $true }
    if ($Name -eq 'Testing') { $TestingNav.IsChecked = $true }
    if ($Name -eq 'Activity') { $ActivityNav.IsChecked = $true }
}

function Get-CurrentState {
    if (-not (Test-Path -LiteralPath $statePath)) { return $null }
    try { return (Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json) } catch { return $null }
}

function Get-OperationalEvents {
    if (-not (Test-Path -LiteralPath $eventLogPath)) { return @() }
    $events = New-Object System.Collections.ArrayList
    foreach ($line in @(Get-Content -LiteralPath $eventLogPath -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { [void]$events.Add(($line | ConvertFrom-Json)) } catch { }
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
    } catch { }
}

function Convert-ToActivityItem {
    param($Event)
    $palette = switch ($Event.Level) {
        'Success' { @('#43D9A3','#0F1D18','#1D3A30') }
        'Action'  { @('#F2B84B','#201B10','#463A1E') }
        'Warning' { @('#F2B84B','#201B10','#463A1E') }
        'Error'   { @('#FF7A6E','#231312','#4C2622') }
        default   { @('#9AA5B1','#12171E','#27303B') }
    }
    $hasAction = $false
    if ($null -ne $Event -and $Event.PSObject.Properties.Match('ActionRequired').Count -gt 0) {
        $hasAction = -not [string]::IsNullOrWhiteSpace("$($Event.ActionRequired)")
    }
    $parsedTime = Get-Date
    if ($null -ne $Event -and $Event.PSObject.Properties.Match('Timestamp').Count -gt 0) {
        try { $parsedTime = [datetime]$Event.Timestamp } catch { }
    }
    $messageText = if ($null -ne $Event -and $Event.PSObject.Properties.Match('Message').Count -gt 0) { "$($Event.Message)" } else { "$($Event)" }
    $levelText = if ($null -ne $Event -and $Event.PSObject.Properties.Match('Level').Count -gt 0) { "$($Event.Level)" } else { 'Info' }
    $actionText = if ($hasAction) { "$($Event.ActionRequired)" } else { '' }
    [pscustomobject]@{
        Time             = $parsedTime.ToLocalTime().ToString('HH:mm:ss')
        Level            = $levelText.ToUpperInvariant()
        Message          = $messageText
        Action           = $actionText
        ActionVisibility = if ($hasAction) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
        Accent           = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString($palette[0]))
        Background       = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString($palette[1]))
        Stroke           = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString($palette[2]))
    }
}

function Refresh-Activity {
    $events = @(Get-OperationalEvents)
    $filter = if ($ActionFilter.IsChecked) { 1 } elseif ($FailureFilter.IsChecked) { 2 } else { 0 }
    if ($filter -eq 1) { $events = @($events | Where-Object { $_.PSObject.Properties.Match('ActionRequired').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace("$($_.ActionRequired)") }) }
    if ($filter -eq 2) { $events = @($events | Where-Object Level -eq 'Error') }
    $events = @($events | Select-Object -Last 120)
    $lastEvent = if ($events.Count) { $events[-1] } else { $null }
    $lastStamp = if ($null -ne $lastEvent -and $lastEvent.PSObject.Properties.Match('Timestamp').Count -gt 0) { "$($lastEvent.Timestamp)" } else { '' }
    $signature = if ($events.Count) { "$($events.Count)|$lastStamp|$filter" } else { "0||$filter" }
    if ($signature -eq $script:lastEventSignature) { return }
    $script:lastEventSignature = $signature
    $ActivityList.ItemsSource = @($events | ForEach-Object { Convert-ToActivityItem $_ })
    $ActivityEmpty.Visibility = if ($events.Count -eq 0) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
}

function Test-HypervisorAlreadyOff {
    # True only when we can positively confirm: no hypervisor running AND VBS off.
    try {
        $system = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if ($system.PSObject.Properties.Match('HypervisorPresent').Count -gt 0) {
            if ([bool]$system.HypervisorPresent) { return $false }
        }
        else { return $false }
        $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
        return ([int]$dg.VirtualizationBasedSecurityStatus -eq 0)
    }
    catch { return $false }
}

function Remove-StartupReopen {
    Remove-ItemProperty -LiteralPath $runOncePath -Name $runOnceName -ErrorAction SilentlyContinue
}

function Read-LiveStatus {
    $vbsStatusKnown = $false
    $vbsOff = $false
    try {
        $system = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $hypervisor = if ($system.PSObject.Properties.Match('HypervisorPresent').Count -gt 0) { [bool]$system.HypervisorPresent } else { $null }
        $HypervisorCheck.Text = if ($null -eq $hypervisor) { 'Unknown' } elseif ($hypervisor) { 'Running' } else { 'Stopped' }
        $HypervisorCheck.Foreground = if ($hypervisor) { '#FF7A6E' } elseif ($null -ne $hypervisor) { '#43D9A3' } else { '#C4D2E4' }
        $ManagedCheck.Text = if ($system.PartOfDomain) { 'Work or school' } else { 'This PC' }

        try {
            $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
            $status = [int]$dg.VirtualizationBasedSecurityStatus
            $vbsStatusKnown = $true
            $vbsOff = ($status -eq 0)
            $VbsCheck.Text = switch ($status) { 0 {'Off'} 1 {'Configured'} 2 {'Running'} default {'Unknown'} }
            $VbsCheck.Foreground = if ($vbsOff) { '#43D9A3' } else { '#F2B84B' }
        }
        catch { $VbsCheck.Text = 'Unavailable'; $VbsCheck.Foreground = '#C4D2E4' }
    }
    catch {
        $HypervisorCheck.Text = 'Unavailable'
        $VbsCheck.Text = 'Unavailable'
        $ManagedCheck.Text = 'Unavailable'
    }

    $alreadyOff = (Test-HypervisorAlreadyOff) -and ($HypervisorCheck.Text -eq 'Stopped')
    $state = Get-CurrentState
    $taskExists = $null -ne (Get-ScheduledTask -TaskName 'Disable-HyperV-Fully-Continue' -ErrorAction SilentlyContinue)
    $engineBusy = $null -ne $script:engineProcess -and -not $script:engineProcess.HasExited
    $VerifyButton.IsEnabled = -not ($engineBusy -or $taskExists)

    if ($alreadyOff) {
        # Smart stop: Hyper-V is already off, so never re-open the tool at sign-in.
        Remove-StartupReopen
    }

    $OpenFilesButton.IsEnabled = (Test-Path -LiteralPath $workRoot) -or (Test-Path -LiteralPath $reportPath)
    $stateCompleted = $null -ne $state -and ($state.PSObject.Properties.Match('Completed').Count -gt 0) -and [bool]$state.Completed

    if ($engineBusy) {
        $HeaderStatus.Text = 'WORKING'
        $LastRunCheck.Text = 'In progress'
        $FooterTitle.Text = 'Working on this PC...'
        $FooterSubtitle.Text = 'The log updates live. Keep this window open or close it; the work continues either way.'
        $RunButton.Content = 'Working...'
        $RunButton.IsEnabled = $false
        return
    }

    if ($alreadyOff -or $stateCompleted) {
        $LastRunCheck.Text = 'Finished'
        $HeaderStatus.Text = if ($alreadyOff) { 'OFF' } else { 'DONE' }
        $StatusKicker.Text = 'FINISHED'
        $StatusTitle.Text = if ($alreadyOff) { 'Hyper-V is already off' } else { 'Hyper-V is off' }
        $StatusSubtitle.Text = if ($alreadyOff) {
            'This PC has no hypervisor running, so there is nothing to change. The tool will not open by itself any more.'
        } else {
            'The restart and final checks are finished. See the Log if anything still needs attention.'
        }
        $FooterTitle.Text = 'Nothing left to do.'
        $FooterSubtitle.Text = if ($stateCompleted -and -not $alreadyOff) { 'Review the Log for anything that still needs attention.' } else { 'You can run a check at any time.' }
        $RunButton.Content = 'Already off'
        $RunButton.IsEnabled = $false
        return
    }

    if ($taskExists) {
        $attemptText = if ($null -ne $state -and ($state.PSObject.Properties.Match('Attempt').Count -gt 0)) { "$($state.Attempt)" } else { '?' }
        $LastRunCheck.Text = "Restart $attemptText of 2"
        $HeaderStatus.Text = 'RUNNING'
        $StatusKicker.Text = 'IN PROGRESS'
        $StatusTitle.Text = 'Waiting for the restart'
        $StatusSubtitle.Text = 'Windows will carry on automatically after the restart and keep using the same log.'
        $FooterTitle.Text = 'The tool is already running.'
        $FooterSubtitle.Text = 'The log will stay available through every restart.'
        $RunButton.Content = 'Already running'
        $RunButton.IsEnabled = $false
        return
    }

    if ($null -ne $state -and $stateCompleted -eq $false -and ($state.PSObject.Properties.Match('Started').Count -gt 0)) {
        # A previous run ended without completing: surface it instead of looking fresh.
        $LastRunCheck.Text = 'Incomplete'
        $HeaderStatus.Text = 'ATTENTION'
        $StatusKicker.Text = 'NEEDS ATTENTION'
        $StatusTitle.Text = 'The last run did not finish'
        $StatusSubtitle.Text = 'Open the Log to see exactly what failed and what to do next.'
        $FooterTitle.Text = 'The last attempt stopped early.'
        $FooterSubtitle.Text = 'Fix the item named in the Log, then try again.'
        $RunButton.Content = 'Try again'
        $RunButton.IsEnabled = $true
        return
    }

    $HeaderStatus.Text = 'READY'
    $LastRunCheck.Text = if ($null -ne $state) { 'Earlier run' } else { 'Never' }
    $StatusKicker.Text = 'BEFORE YOU START'
    $StatusTitle.Text = 'Ready to check this PC'
    $StatusSubtitle.Text = 'First we will check what is running. Nothing changes until you start the process.'
    $FooterTitle.Text = 'Nothing has been changed yet.'
    $FooterSubtitle.Text = 'Check the options and save your work before starting.'
    $RunButton.Content = 'Turn off Hyper-V'
    $RunButton.IsEnabled = $true
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
    $script:engineProcess = Start-Process -FilePath $windowsPowerShell -ArgumentList ($arguments -join ' ') -WindowStyle Hidden -PassThru
    $VerifyButton.IsEnabled = $false
    Show-Panel -Name 'Activity'
    $FooterTitle.Text = if ($Verify) { 'Checking this PC...' } else { 'Turning off Hyper-V...' }
    $FooterSubtitle.Text = 'Only useful results and anything that needs your attention are shown in the Log.'
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
        $info.Service = switch ("$($svc.Status)") { 'Running' {'Running'} 'Stopped' {'Stopped'} default { "$($svc.Status)" } }
    } catch { }
    return $info
}

function Update-DefenderStatusUI {
    $d = Get-DefenderStatusInfo
    $DefTamperValue.Text = "$($d.TamperProtection)"
    $DefTamperValue.Foreground = if ($d.TamperOn) { '#F2B84B' } elseif ($d.TamperProtection -eq 'Off') { '#43D9A3' } else { '#C4D2E4' }
    $DefRtValue.Text = "$($d.RealTimeProtection)"
    $DefRtValue.Foreground = if ($d.RealTimeProtection -eq 'On') { '#43D9A3' } elseif ($d.RealTimeProtection -eq 'Off') { '#FF7A6E' } else { '#C4D2E4' }
    $DefSvcValue.Text = "$($d.Service)"
    $DefSvcValue.Foreground = if ($d.Service -eq 'Running') { '#43D9A3' } elseif ($d.Service -eq 'Stopped') { '#FF7A6E' } else { '#C4D2E4' }
    return $d
}

function Save-ServiceStartBackup {
    param([string[]] $ServiceNames)
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
            -ActionRequired 'Turn off Tamper Protection in Windows Security, then use Restore Windows Security.'
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
            & sc.exe stop $driver 2>&1 | Out-Null
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
            [void](Restore-TamperSafeRegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$name" -Name 'Start' -Value $startValue)
        }

        try { Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop } catch { }

        foreach ($service in @('WinDefend','WdNisSvc','SecurityHealthService')) {
            try { Start-Service -Name $service -ErrorAction SilentlyContinue } catch { }
        }

        try {
            $startupKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
            New-ItemProperty -Path $startupKey -Name 'SecurityHealth' -PropertyType Binary -Value ([byte[]]@(2,0,0,0,0,0,0,0,0,0,0,0)) -Force -ErrorAction SilentlyContinue | Out-Null
            $tray = Join-Path $env:SystemRoot 'System32\SecurityHealthSystray.exe'
            if ((Get-Service -Name SecurityHealthService -ErrorAction SilentlyContinue).Status -eq 'Running' -and
                -not (Get-Process -Name SecurityHealthSystray -ErrorAction SilentlyContinue)) {
                Start-Process -FilePath $tray -WindowStyle Hidden
            }
        } catch { }

        Add-UiEvent -Level Success -Code 'DEFENDER_ENABLED' `
            -Message 'Restored Windows Security settings. If Defender does not start, restart the PC.'
    }

    Update-DefenderStatusUI | Out-Null
}

$TitleBar.Add_MouseLeftButtonDown({
    if ($_.ButtonState -eq [Windows.Input.MouseButtonState]::Pressed) {
        try { $window.DragMove() } catch { }
    }
})
$MinimizeButton.Add_Click({ $window.WindowState = [Windows.WindowState]::Minimized })
$CloseButton.Add_Click({ $window.Close() })
$OverviewNav.Add_Checked({ Show-Panel -Name 'Overview' })
$ControlsNav.Add_Checked({ Show-Panel -Name 'Controls' })
$TestingNav.Add_Checked({ Show-Panel -Name 'Testing' })
$ActivityNav.Add_Checked({ Show-Panel -Name 'Activity' })
$ActivityShortcut.Add_Click({ Show-Panel -Name 'Activity' })
$OpenFilesButton.Add_Click({ if (Test-Path -LiteralPath $workRoot) { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $workRoot) } })
$VerifyButton.Add_Click({ Start-Engine -Verify })

$DefenderDisableButton.Add_Click({
    $DefenderDisableButton.IsEnabled = $false
    $DefenderEnableButton.IsEnabled = $false
    $window.Cursor = [Windows.Input.Cursors]::Wait
    try { Invoke-WindowsSecurityChange -Mode 'Disable' } catch {
        Add-UiEvent -Level Error -Code 'DEFENDER_DISABLE_FAILED' `
            -Message "Windows Security could not be fully disabled: $($_.Exception.Message)" `
            -ActionRequired 'Turn off Tamper Protection in Windows Security first, then try again. The Log has the technical detail.'
    } finally {
        $window.Cursor = $null
        $DefenderDisableButton.IsEnabled = $true
        $DefenderEnableButton.IsEnabled = $true
    }
})

$DefenderEnableButton.Add_Click({
    $DefenderDisableButton.IsEnabled = $false
    $DefenderEnableButton.IsEnabled = $false
    $window.Cursor = [Windows.Input.Cursors]::Wait
    try { Invoke-WindowsSecurityChange -Mode 'Enable' } catch {
        Add-UiEvent -Level Error -Code 'DEFENDER_ENABLE_FAILED' `
            -Message "Windows Security could not be fully restored: $($_.Exception.Message)" `
            -ActionRequired 'Restart the PC and use Restore Windows Security again. The Log has the technical detail.'
    } finally {
        $window.Cursor = $null
        $DefenderDisableButton.IsEnabled = $true
        $DefenderEnableButton.IsEnabled = $true
    }
})

$AllFilter.Add_Checked({ $script:lastEventSignature = ''; Refresh-Activity })
$ActionFilter.Add_Checked({ $script:lastEventSignature = ''; Refresh-Activity })
$FailureFilter.Add_Checked({ $script:lastEventSignature = ''; Refresh-Activity })

$RunButton.Add_Click({
    if (-not $RunButton.IsEnabled) { return }
    if (Test-HypervisorAlreadyOff) {
        Add-UiEvent -Level Success -Code 'SKIP_ALREADY_OFF' `
            -Message 'Hyper-V was already off, so the operation was skipped.'
        Read-LiveStatus
        return
    }
    if (-not $script:confirmationArmed) {
        $script:confirmationArmed = $true
        $RunButton.Content = 'Yes, turn it off'
        $FooterTitle.Text = 'Please confirm before continuing.'
        $FooterSubtitle.Text = 'This turns off Credential Guard, Memory Integrity, Sandbox, WSL 2, and Hyper-V, and disables Windows Hello PIN sign-in (use the account password instead).'
        Show-Panel -Name 'Controls'
        return
    }
    $script:confirmationArmed = $false
    $RunButton.Content = 'Working...'
    $RunButton.IsEnabled = $false
    Start-Engine
})

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(2)
$timer.Add_Tick({
    Refresh-Activity
    Read-LiveStatus
    $script:defenderTickCounter++
    if (($script:defenderTickCounter % 5) -eq 0) { Update-DefenderStatusUI | Out-Null }
    if ($Resume) {
        $state = Get-CurrentState
        $stillWorking = $null -ne $state -and -not ($state.PSObject.Properties.Match('Completed').Count -gt 0)
        if ($stillWorking -and -not (Test-HypervisorAlreadyOff)) {
            Set-ReopenAfterSignIn
        }
        elseif (-not $stillWorking) {
            Remove-StartupReopen
        }
    }
})
$window.Add_Closed({ $timer.Stop() })

$MachineSubTitle.Text = "$env:COMPUTERNAME  |  $env:PROCESSOR_ARCHITECTURE"

if ($Resume) { Show-Panel -Name 'Activity' }
Refresh-Activity
Read-LiveStatus
Update-DefenderStatusUI | Out-Null
$timer.Start()
[void]$window.ShowDialog()


