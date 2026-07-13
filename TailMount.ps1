[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml

if (-not ('TailMount.NativeMethods' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;

namespace TailMount
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public class NETRESOURCE
    {
        public int dwScope = 0;
        public int dwType = 1;
        public int dwDisplayType = 0;
        public int dwUsage = 0;
        public string lpLocalName = null;
        public string lpRemoteName = null;
        public string lpComment = null;
        public string lpProvider = null;
    }

    public static class NativeMethods
    {
        public const int CONNECT_UPDATE_PROFILE = 0x00000001;
        public const int CONNECT_INTERACTIVE = 0x00000008;
        public const int CONNECT_PROMPT = 0x00000010;
        public const int CONNECT_SAVE_CREDENTIALS = 0x00001000;

        [DllImport("mpr.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern int WNetAddConnection2(
            NETRESOURCE netResource,
            string password,
            string username,
            int flags);

        [DllImport("mpr.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern int WNetCancelConnection2(
            string name,
            int flags,
            bool force);

        [DllImport("mpr.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern int WNetGetConnection(
            string localName,
            StringBuilder remoteName,
            ref int length);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        public static extern uint GetDriveType(string rootPathName);

        public static Task<int> WNetAddConnection2Async(
            NETRESOURCE netResource,
            string password,
            string username,
            int flags)
        {
            return Task.Run(() =>
                WNetAddConnection2(netResource, password, username, flags));
        }
    }

    public sealed class NetworkProbeResult
    {
        public bool Reachable { get; set; }
        public long LatencyMs { get; set; }
        public long TcpLatencyMs { get; set; }
        public bool UsedIcmp { get; set; }
        public string ErrorMessage { get; set; }
        public DateTime CheckedAt { get; set; }
    }

    public sealed class DriveProbeResult
    {
        public bool Success { get; set; }
        public long DurationMs { get; set; }
        public string ErrorMessage { get; set; }
    }

    public static class HealthProbe
    {
        public static Task<NetworkProbeResult> ProbeNetworkAsync(
            string host,
            int port,
            int timeoutMs)
        {
            return Task.Run(() => ProbeNetwork(host, port, timeoutMs));
        }

        public static Task<NetworkProbeResult> ProbeSshAsync(
            string host,
            int port,
            int timeoutMs)
        {
            return Task.Run(() => ProbeTcp(host, port, timeoutMs));
        }

        private static NetworkProbeResult ProbeNetwork(string host, int port, int timeoutMs)
        {
            try
            {
                using (Ping ping = new Ping())
                {
                    PingReply reply = ping.Send(host, timeoutMs);
                    if (reply != null && reply.Status == IPStatus.Success)
                    {
                        return new NetworkProbeResult
                        {
                            Reachable = true,
                            LatencyMs = reply.RoundtripTime,
                            TcpLatencyMs = -1,
                            UsedIcmp = true,
                            ErrorMessage = null,
                            CheckedAt = DateTime.Now
                        };
                    }
                }
            }
            catch
            {
                // ICMP may be blocked by the host or an ACL. In that case use
                // the configured SSH port as a compatibility fallback.
            }

            return ProbeTcp(host, port, timeoutMs);
        }

        private static NetworkProbeResult ProbeTcp(string host, int port, int timeoutMs)
        {
            NetworkProbeResult result = new NetworkProbeResult
            {
                Reachable = false,
                LatencyMs = -1,
                TcpLatencyMs = -1,
                UsedIcmp = false,
                ErrorMessage = null,
                CheckedAt = DateTime.Now
            };

            Stopwatch watch = Stopwatch.StartNew();
            try
            {
                using (TcpClient client = new TcpClient())
                {
                    IAsyncResult pending = client.BeginConnect(host, port, null, null);
                    bool connected = pending.AsyncWaitHandle.WaitOne(timeoutMs);
                    pending.AsyncWaitHandle.Close();
                    if (!connected)
                    {
                        throw new TimeoutException("SSH 连接超时");
                    }
                    client.EndConnect(pending);
                    watch.Stop();
                    result.TcpLatencyMs = watch.ElapsedMilliseconds;
                    result.Reachable = client.Connected;
                    result.LatencyMs = result.TcpLatencyMs;
                }
            }
            catch (Exception exception)
            {
                watch.Stop();
                result.ErrorMessage = exception.Message;
            }

            return result;
        }

        public static Task<DriveProbeResult> ProbeDriveAsync(string rootPath)
        {
            return Task.Run(() =>
            {
                DriveProbeResult result = new DriveProbeResult();
                Stopwatch watch = Stopwatch.StartNew();
                try
                {
                    using (IEnumerator<string> entries = Directory.EnumerateFileSystemEntries(rootPath).GetEnumerator())
                    {
                        entries.MoveNext();
                    }
                    watch.Stop();
                    result.Success = true;
                    result.DurationMs = watch.ElapsedMilliseconds;
                }
                catch (Exception exception)
                {
                    watch.Stop();
                    result.Success = false;
                    result.DurationMs = watch.ElapsedMilliseconds;
                    result.ErrorMessage = exception.Message;
                }
                return result;
            });
        }
    }
}
"@
}

$script:AppRoot = if ($env:TAILMOUNT_APPROOT) { $env:TAILMOUNT_APPROOT } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:DataRoot = if ($env:TAILMOUNT_DATAROOT) { $env:TAILMOUNT_DATAROOT } else { Join-Path $script:AppRoot 'data' }
$script:ConfigPath = Join-Path $script:DataRoot 'profiles.json'
$script:BackupConfigPath = "$($script:ConfigPath).bak"
$script:LogPath = Join-Path $script:DataRoot 'TailMount.log'
$script:Profiles = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$script:StartupWarnings = New-Object 'System.Collections.Generic.List[string]'
$script:ConfigLoadedFromBackup = $false
$script:LastConfigSaveSucceeded = $true
$script:LastConfigError = ''
$script:IsLoadingProfile = $false
$script:NetworkHistory = New-Object 'System.Collections.Generic.Queue[object]'
$script:NetworkProbeTask = $null
$script:NetworkProbeKey = ''
$script:NetworkProbeStartedAt = [datetime]::MinValue
$script:NextNetworkProbeAt = [datetime]::MinValue
$script:LastNetworkResult = $null
$script:LastNetworkState = 'Idle'
$script:ConsecutiveNetworkFailures = 0
$script:NetworkAlertMessage = ''
$script:NetworkAlertSeverity = 'None'
$script:DriveProbeTask = $null
$script:DriveProbeKey = ''
$script:DriveProbeStartedAt = [datetime]::MinValue
$script:NextDriveProbeAt = [datetime]::MinValue
$script:LastDriveState = 'Idle'
$script:DriveAlertMessage = ''
$script:DriveAlertSeverity = 'None'
$script:ActiveMountTask = $null
$script:ActiveMountLocalName = ''
$script:ActiveMountStartedAt = [datetime]::MinValue
$script:MountSlowNoticeShown = $false
$script:MountVerySlowNoticeShown = $false
$script:LastMonitorError = ''

if (-not (Test-Path -LiteralPath $script:DataRoot)) {
    New-Item -ItemType Directory -Path $script:DataRoot -Force | Out-Null
}

function New-TailMountProfile {
    param(
        [string]$Name = '我的服务器'
    )

    [pscustomobject]@{
        Id          = [guid]::NewGuid().ToString('N')
        Name        = $Name
        Host        = ''
        Port        = 22
        UserName    = ''
        RemotePath  = '/home'
        DriveLetter = 'S'
        AuthMode    = 'Password'
        Persist     = $true
        Notes       = ''
    }
}

function Import-TailMountProfiles {
    foreach ($candidate in @($script:ConfigPath, $script:BackupConfigPath)) {
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        try {
            # Windows PowerShell 5 can return a JSON array as one non-enumerated
            # pipeline object. Assign it directly and let foreach enumerate it;
            # wrapping the pipeline in @() makes two profiles appear as one item.
            $items = Get-Content -LiteralPath $candidate -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -eq $items) { throw '配置内容为空' }
            foreach ($item in $items) {
                if (-not $item.Id) { $item | Add-Member -NotePropertyName Id -NotePropertyValue ([guid]::NewGuid().ToString('N')) }
                if ($null -eq $item.Persist) { $item | Add-Member -NotePropertyName Persist -NotePropertyValue $true -Force }
                if (-not $item.AuthMode) { $item | Add-Member -NotePropertyName AuthMode -NotePropertyValue 'Password' -Force }
                $script:Profiles.Add($item)
            }
            if ($script:Profiles.Count -eq 0) { throw '配置中没有可用项目' }
            if ($candidate -eq $script:BackupConfigPath) {
                $script:ConfigLoadedFromBackup = $true
                $script:StartupWarnings.Add('主配置损坏，已从 profiles.json.bak 自动恢复。')
            }
            break
        }
        catch {
            $script:Profiles.Clear()
            $script:StartupWarnings.Add("无法读取 $(Split-Path -Leaf $candidate)：$($_.Exception.Message)")
        }
    }

    if ($script:Profiles.Count -eq 0) {
        $script:Profiles.Add((New-TailMountProfile))
    }
}

function Export-TailMountProfiles {
    $temporaryPath = "$($script:ConfigPath).tmp"
    try {
        $snapshot = @($script:Profiles)
        $json = ConvertTo-Json -InputObject $snapshot -Depth 5
        [System.IO.File]::WriteAllText($temporaryPath, $json, [System.Text.UTF8Encoding]::new($false))

        # Atomic replacement prevents a crash or power loss from leaving a
        # half-written JSON file. Preserve the previous known-good file too.
        if (Test-Path -LiteralPath $script:ConfigPath) {
            $backupPath = if ($script:ConfigLoadedFromBackup) { $null } else { $script:BackupConfigPath }
            [System.IO.File]::Replace($temporaryPath, $script:ConfigPath, $backupPath, $true)
        }
        else {
            [System.IO.File]::Move($temporaryPath, $script:ConfigPath)
        }
        $script:ConfigLoadedFromBackup = $false
        $script:LastConfigSaveSucceeded = $true
        $script:LastConfigError = ''
    }
    catch {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
        $script:LastConfigSaveSucceeded = $false
        $script:LastConfigError = $_.Exception.Message
    }
}

Import-TailMountProfiles

$xaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    xmlns:shell="clr-namespace:System.Windows.Shell;assembly=PresentationFramework"
    x:Name="MainWindow"
    Title="TailMount"
    Width="1180"
    Height="790"
    MinWidth="1020"
    MinHeight="700"
    WindowStartupLocation="CenterScreen"
    WindowStyle="None"
    ResizeMode="CanResize"
    Background="#F4F7FB"
    FontFamily="Segoe UI Variable Text, Segoe UI"
    TextOptions.TextFormattingMode="Display"
    SnapsToDevicePixels="True">

    <shell:WindowChrome.WindowChrome>
        <shell:WindowChrome CaptionHeight="0" ResizeBorderThickness="7" CornerRadius="12" GlassFrameThickness="0" />
    </shell:WindowChrome.WindowChrome>

    <Window.Resources>
        <SolidColorBrush x:Key="Ink" Color="#142033" />
        <SolidColorBrush x:Key="Muted" Color="#718096" />
        <SolidColorBrush x:Key="Accent" Color="#5B61F4" />
        <SolidColorBrush x:Key="AccentHover" Color="#4B50DA" />
        <SolidColorBrush x:Key="Line" Color="#E3E8F1" />

        <Style x:Key="Card" TargetType="Border">
            <Setter Property="Background" Value="White" />
            <Setter Property="CornerRadius" Value="18" />
            <Setter Property="BorderBrush" Value="#E8ECF3" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="Padding" Value="24" />
            <Setter Property="Effect">
                <Setter.Value>
                    <DropShadowEffect BlurRadius="18" ShadowDepth="2" Opacity="0.07" Color="#20304A" />
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="FieldLabel" TargetType="TextBlock">
            <Setter Property="Foreground" Value="#4A586E" />
            <Setter Property="FontSize" Value="12" />
            <Setter Property="FontWeight" Value="SemiBold" />
            <Setter Property="Margin" Value="2,0,0,7" />
        </Style>

        <Style x:Key="ModernTextBox" TargetType="TextBox">
            <Setter Property="Height" Value="43" />
            <Setter Property="Background" Value="#FBFCFE" />
            <Setter Property="BorderBrush" Value="#DDE3ED" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="Foreground" Value="#172238" />
            <Setter Property="FontSize" Value="14" />
            <Setter Property="Padding" Value="12,0" />
            <Setter Property="VerticalContentAlignment" Value="Center" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="10">
                            <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center" />
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsKeyboardFocused" Value="True">
                                <Setter TargetName="Bd" Property="BorderBrush" Value="#696EF6" />
                                <Setter TargetName="Bd" Property="BorderThickness" Value="1.5" />
                                <Setter TargetName="Bd" Property="Background" Value="White" />
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="Bd" Property="Background" Value="#F0F2F6" />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ModernPasswordBox" TargetType="PasswordBox">
            <Setter Property="Height" Value="43" />
            <Setter Property="Background" Value="#FBFCFE" />
            <Setter Property="BorderBrush" Value="#DDE3ED" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="Foreground" Value="#172238" />
            <Setter Property="FontSize" Value="14" />
            <Setter Property="Padding" Value="12,0" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="PasswordBox">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="10">
                            <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center" />
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsKeyboardFocused" Value="True">
                                <Setter TargetName="Bd" Property="BorderBrush" Value="#696EF6" />
                                <Setter TargetName="Bd" Property="BorderThickness" Value="1.5" />
                                <Setter TargetName="Bd" Property="Background" Value="White" />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ModernCombo" TargetType="ComboBox">
            <Setter Property="Height" Value="43" />
            <Setter Property="Background" Value="#FBFCFE" />
            <Setter Property="BorderBrush" Value="#DDE3ED" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="Foreground" Value="#172238" />
            <Setter Property="FontSize" Value="14" />
            <Setter Property="Padding" Value="9,0" />
            <Setter Property="VerticalContentAlignment" Value="Center" />
        </Style>

        <Style x:Key="PrimaryButton" TargetType="Button">
            <Setter Property="Height" Value="43" />
            <Setter Property="Padding" Value="18,0" />
            <Setter Property="Background" Value="{StaticResource Accent}" />
            <Setter Property="Foreground" Value="White" />
            <Setter Property="BorderThickness" Value="0" />
            <Setter Property="FontSize" Value="13" />
            <Setter Property="FontWeight" Value="SemiBold" />
            <Setter Property="Cursor" Value="Hand" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="ButtonBorder" Background="{TemplateBinding Background}" CornerRadius="11" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" />
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ButtonBorder" Property="Background" Value="{StaticResource AccentHover}" />
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="ButtonBorder" Property="Opacity" Value="0.84" />
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="ButtonBorder" Property="Opacity" Value="0.45" />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="SecondaryButton" TargetType="Button" BasedOn="{StaticResource PrimaryButton}">
            <Setter Property="Background" Value="#EEF0FF" />
            <Setter Property="Foreground" Value="#4E54DB" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="ButtonBorder" Background="{TemplateBinding Background}" BorderBrush="#DDE0FF" BorderThickness="1" CornerRadius="11" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" />
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ButtonBorder" Property="Background" Value="#E2E5FF" /></Trigger>
                            <Trigger Property="IsPressed" Value="True"><Setter TargetName="ButtonBorder" Property="Opacity" Value="0.78" /></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="OutlineButton" TargetType="Button" BasedOn="{StaticResource PrimaryButton}">
            <Setter Property="Background" Value="White" />
            <Setter Property="Foreground" Value="#3D4A5F" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="ButtonBorder" Background="{TemplateBinding Background}" BorderBrush="#DEE4EE" BorderThickness="1" CornerRadius="11" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" />
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ButtonBorder" Property="Background" Value="#F6F8FB" /></Trigger>
                            <Trigger Property="IsPressed" Value="True"><Setter TargetName="ButtonBorder" Property="Opacity" Value="0.78" /></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="TitleButton" TargetType="Button">
            <Setter Property="Width" Value="46" />
            <Setter Property="Height" Value="46" />
            <Setter Property="Background" Value="Transparent" />
            <Setter Property="Foreground" Value="#AEB8CA" />
            <Setter Property="BorderThickness" Value="0" />
            <Setter Property="FontFamily" Value="Segoe MDL2 Assets" />
            <Setter Property="FontSize" Value="11" />
            <Setter Property="Cursor" Value="Hand" />
            <Setter Property="shell:WindowChrome.IsHitTestVisibleInChrome" Value="True" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bg" Background="{TemplateBinding Background}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" />
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bg" Property="Background" Value="#263247" /><Setter Property="Foreground" Value="White" /></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ProfileItem" TargetType="ListBoxItem">
            <Setter Property="Padding" Value="0" />
            <Setter Property="Margin" Value="0,0,0,8" />
            <Setter Property="Background" Value="Transparent" />
            <Setter Property="BorderThickness" Value="0" />
            <Setter Property="HorizontalContentAlignment" Value="Stretch" />
            <Setter Property="Cursor" Value="Hand" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ListBoxItem">
                        <Border x:Name="ItemBorder" Background="{TemplateBinding Background}" CornerRadius="12" Padding="13,11">
                            <ContentPresenter />
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ItemBorder" Property="Background" Value="#202D42" /></Trigger>
                            <Trigger Property="IsSelected" Value="True"><Setter TargetName="ItemBorder" Property="Background" Value="#5A60EC" /></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Border Background="#F4F7FB" BorderBrush="#CED5E1" BorderThickness="1" CornerRadius="12">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="48" />
                <RowDefinition Height="*" />
            </Grid.RowDefinitions>

            <Border x:Name="TitleBar" Grid.Row="0" Background="#111A2B" CornerRadius="11,11,0,0">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="280" />
                        <ColumnDefinition Width="*" />
                        <ColumnDefinition Width="Auto" />
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center" Margin="22,0,0,0">
                        <Border Width="27" Height="27" CornerRadius="8" Background="#686DF5">
                            <TextBlock Text="T" Foreground="White" FontSize="15" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center" />
                        </Border>
                        <TextBlock Text="TailMount" Foreground="White" FontSize="14" FontWeight="SemiBold" VerticalAlignment="Center" Margin="10,0,0,0" />
                        <Border Background="#243149" CornerRadius="7" Margin="9,0,0,0" Padding="7,3">
                            <TextBlock Text="WINDOWS" Foreground="#8CD8CB" FontSize="9" FontWeight="Bold" />
                        </Border>
                    </StackPanel>
                    <TextBlock Grid.Column="1" Text="Tailscale SFTP Drive Manager" Foreground="#7F8CA2" FontSize="12" VerticalAlignment="Center" />
                    <StackPanel Grid.Column="2" Orientation="Horizontal">
                        <Button x:Name="MinimizeButton" Style="{StaticResource TitleButton}" Content="&#xE921;" ToolTip="最小化" />
                        <Button x:Name="MaximizeButton" Style="{StaticResource TitleButton}" Content="&#xE922;" ToolTip="最大化" />
                        <Button x:Name="CloseButton" Content="&#xE8BB;" ToolTip="关闭">
                            <Button.Style>
                                <Style TargetType="Button" BasedOn="{StaticResource TitleButton}">
                                    <Style.Triggers>
                                        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#E5484D" /><Setter Property="Foreground" Value="White" /></Trigger>
                                    </Style.Triggers>
                                </Style>
                            </Button.Style>
                        </Button>
                    </StackPanel>
                </Grid>
            </Border>

            <Grid Grid.Row="1">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="280" />
                    <ColumnDefinition Width="*" />
                </Grid.ColumnDefinitions>

                <Border Grid.Column="0" Background="#111A2B" CornerRadius="0,0,0,11">
                    <Grid Margin="18,22,18,18">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto" />
                            <RowDefinition Height="*" />
                            <RowDefinition Height="Auto" />
                        </Grid.RowDefinitions>

                        <Grid Grid.Row="0" Margin="4,0,4,14">
                            <TextBlock Text="连接配置" Foreground="#8290A7" FontSize="11" FontWeight="Bold" VerticalAlignment="Center" />
                            <Button x:Name="AddProfileButton" Content="＋  新建" HorizontalAlignment="Right" Padding="10,5" Background="#202D42" Foreground="#C8D1E0" BorderThickness="0" Cursor="Hand" FontSize="11" />
                        </Grid>

                        <ListBox x:Name="ProfileList" Grid.Row="1" Background="Transparent" BorderThickness="0" ItemContainerStyle="{StaticResource ProfileItem}" ScrollViewer.HorizontalScrollBarVisibility="Disabled">
                            <ListBox.ItemTemplate>
                                <DataTemplate>
                                    <Grid>
                                        <Grid.ColumnDefinitions><ColumnDefinition Width="36" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions>
                                        <Border Width="30" Height="30" CornerRadius="9" Background="#2C3950" VerticalAlignment="Center">
                                            <TextBlock Text="&#xE968;" FontFamily="Segoe MDL2 Assets" Foreground="#8CD8CB" FontSize="13" HorizontalAlignment="Center" VerticalAlignment="Center" />
                                        </Border>
                                        <StackPanel Grid.Column="1" Margin="8,0,0,0">
                                            <TextBlock Text="{Binding Name}" Foreground="White" FontSize="13" FontWeight="SemiBold" TextTrimming="CharacterEllipsis" />
                                            <TextBlock Text="{Binding Host}" Foreground="#93A0B5" FontSize="10.5" Margin="0,3,0,0" TextTrimming="CharacterEllipsis" />
                                        </StackPanel>
                                    </Grid>
                                </DataTemplate>
                            </ListBox.ItemTemplate>
                        </ListBox>

                        <Border Grid.Row="2" Background="#172338" BorderBrush="#26344B" BorderThickness="1" CornerRadius="14" Padding="14" Margin="0,14,0,0">
                            <StackPanel>
                                <TextBlock Text="运行环境" Foreground="#DCE3EE" FontSize="11" FontWeight="SemiBold" Margin="0,0,0,11" />
                                <Grid Margin="0,0,0,7"><Grid.ColumnDefinitions><ColumnDefinition Width="14" /><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions><Ellipse x:Name="TailscaleDot" Width="7" Height="7" Fill="#6B778C" /><TextBlock Grid.Column="1" Text="Tailscale" Foreground="#95A1B5" FontSize="10.5" /><TextBlock x:Name="TailscaleState" Grid.Column="2" Text="检测中" Foreground="#718098" FontSize="10" /></Grid>
                                <Grid Margin="0,0,0,7"><Grid.ColumnDefinitions><ColumnDefinition Width="14" /><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions><Ellipse x:Name="WinFspDot" Width="7" Height="7" Fill="#6B778C" /><TextBlock Grid.Column="1" Text="WinFsp" Foreground="#95A1B5" FontSize="10.5" /><TextBlock x:Name="WinFspState" Grid.Column="2" Text="检测中" Foreground="#718098" FontSize="10" /></Grid>
                                <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="14" /><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions><Ellipse x:Name="SshfsDot" Width="7" Height="7" Fill="#6B778C" /><TextBlock Grid.Column="1" Text="SSHFS-Win" Foreground="#95A1B5" FontSize="10.5" /><TextBlock x:Name="SshfsState" Grid.Column="2" Text="检测中" Foreground="#718098" FontSize="10" /></Grid>
                                <Button x:Name="InstallDependenciesButton" Content="安装缺少的组件" Height="34" Margin="0,12,0,0" Background="#22314A" Foreground="#BFC9D8" BorderBrush="#30405A" BorderThickness="1" Cursor="Hand" FontSize="10.5" />
                            </StackPanel>
                        </Border>
                    </Grid>
                </Border>

                <Grid Grid.Column="1" Margin="28,22,28,24">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto" />
                        <RowDefinition Height="*" />
                    </Grid.RowDefinitions>

                    <Grid Grid.Row="0" Margin="0,0,0,18">
                        <StackPanel>
                            <TextBlock Text="远程磁盘" Foreground="{StaticResource Ink}" FontSize="25" FontWeight="SemiBold" />
                            <TextBlock Text="通过 Tailscale 安全地把服务器目录装进文件资源管理器" Foreground="{StaticResource Muted}" FontSize="12.5" Margin="0,5,0,0" />
                        </StackPanel>
                        <Border x:Name="GlobalStatusBadge" HorizontalAlignment="Right" VerticalAlignment="Top" Background="#EDF1F7" CornerRadius="16" Padding="12,7">
                            <StackPanel Orientation="Horizontal">
                                <Ellipse x:Name="GlobalStatusDot" Width="7" Height="7" Fill="#98A3B4" Margin="0,0,7,0" />
                                <TextBlock x:Name="GlobalStatusText" Text="等待连接" Foreground="#667489" FontSize="11" FontWeight="SemiBold" />
                            </StackPanel>
                        </Border>
                    </Grid>

                    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="0,0,8,0">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*" />
                                <ColumnDefinition Width="310" />
                            </Grid.ColumnDefinitions>

                            <StackPanel Grid.Column="0" Margin="0,0,18,0">
                                <Border Style="{StaticResource Card}">
                                    <StackPanel>
                                        <Grid Margin="0,0,0,20">
                                            <StackPanel>
                                                <TextBlock Text="服务器连接" Foreground="{StaticResource Ink}" FontSize="16" FontWeight="SemiBold" />
                                                <TextBlock Text="填写 MagicDNS 名称或 Tailscale IP" Foreground="{StaticResource Muted}" FontSize="11.5" Margin="0,4,0,0" />
                                            </StackPanel>
                                            <Button x:Name="DeleteProfileButton" HorizontalAlignment="Right" VerticalAlignment="Top" Content="删除配置" Background="Transparent" Foreground="#D45B67" BorderThickness="0" Cursor="Hand" FontSize="11" Padding="8,4" />
                                        </Grid>

                                        <Grid>
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="14" /><ColumnDefinition Width="150" /></Grid.ColumnDefinitions>
                                            <StackPanel Grid.Column="0"><TextBlock Text="配置名称" Style="{StaticResource FieldLabel}" /><TextBox x:Name="ProfileNameBox" Style="{StaticResource ModernTextBox}" /></StackPanel>
                                            <StackPanel Grid.Column="2"><TextBlock Text="盘符" Style="{StaticResource FieldLabel}" /><ComboBox x:Name="DriveLetterBox" Style="{StaticResource ModernCombo}" /></StackPanel>
                                        </Grid>

                                        <Grid Margin="0,15,0,0">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="14" /><ColumnDefinition Width="150" /></Grid.ColumnDefinitions>
                                            <StackPanel Grid.Column="0"><TextBlock Text="服务器地址" Style="{StaticResource FieldLabel}" /><TextBox x:Name="HostBox" Style="{StaticResource ModernTextBox}" ToolTip="例如：server-name、server-name.tailnet.ts.net 或 100.x.x.x" /></StackPanel>
                                            <StackPanel Grid.Column="2"><TextBlock Text="SSH 端口" Style="{StaticResource FieldLabel}" /><TextBox x:Name="PortBox" Style="{StaticResource ModernTextBox}" Text="22" /></StackPanel>
                                        </Grid>

                                        <Grid Margin="0,15,0,0">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="14" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions>
                                            <StackPanel Grid.Column="0"><TextBlock Text="服务器用户名" Style="{StaticResource FieldLabel}" /><TextBox x:Name="UserNameBox" Style="{StaticResource ModernTextBox}" /></StackPanel>
                                            <StackPanel Grid.Column="2"><TextBlock Text="远程目录" Style="{StaticResource FieldLabel}" /><TextBox x:Name="RemotePathBox" Style="{StaticResource ModernTextBox}" ToolTip="绝对路径示例：/srv/data；主目录相对路径示例：documents" /></StackPanel>
                                        </Grid>

                                        <Grid Margin="0,15,0,0">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="14" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions>
                                            <StackPanel Grid.Column="0"><TextBlock Text="认证方式" Style="{StaticResource FieldLabel}" /><ComboBox x:Name="AuthModeBox" Style="{StaticResource ModernCombo}"><ComboBoxItem Tag="Password">SSH 密码</ComboBoxItem><ComboBoxItem Tag="Key">默认 SSH 密钥</ComboBoxItem></ComboBox></StackPanel>
                                            <StackPanel Grid.Column="2" x:Name="PasswordPanel"><TextBlock Text="密码（不会保存）" Style="{StaticResource FieldLabel}" /><PasswordBox x:Name="PasswordBox" Style="{StaticResource ModernPasswordBox}" ToolTip="留空时由 Windows 弹出凭据窗口" /></StackPanel>
                                        </Grid>

                                        <Grid Margin="0,18,0,0">
                                            <CheckBox x:Name="PersistCheckBox" Content="记住此映射并在登录后恢复" Foreground="#536075" FontSize="12" VerticalAlignment="Center" />
                                            <Button x:Name="SaveProfileButton" Content="保存配置" Style="{StaticResource SecondaryButton}" HorizontalAlignment="Right" Width="118" />
                                        </Grid>
                                    </StackPanel>
                                </Border>

                                <Border Style="{StaticResource Card}" Margin="0,16,0,0" Padding="20,17">
                                    <Grid>
                                        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions>
                                        <Border Width="36" Height="36" CornerRadius="10" Background="#EAF8F4">
                                            <TextBlock Text="&#xE72E;" FontFamily="Segoe MDL2 Assets" Foreground="#2E9D81" FontSize="15" HorizontalAlignment="Center" VerticalAlignment="Center" />
                                        </Border>
                                        <StackPanel Grid.Column="1" Margin="12,0,0,0">
                                            <TextBlock Text="安全提示" Foreground="#344258" FontSize="12.5" FontWeight="SemiBold" />
                                            <TextBlock Text="连接只通过你的 Tailnet；建议服务器关闭公网 22 端口，并优先使用无口令的专用 SSH 密钥。" Foreground="#7A8799" FontSize="11" Margin="0,3,0,0" TextWrapping="Wrap" />
                                        </StackPanel>
                                    </Grid>
                                </Border>
                            </StackPanel>

                            <StackPanel Grid.Column="1">
                                <Border Style="{StaticResource Card}" Padding="22">
                                    <StackPanel>
                                        <Border x:Name="ConnectionIconBorder" Width="56" Height="56" CornerRadius="18" Background="#EEF0FF" HorizontalAlignment="Left">
                                            <TextBlock x:Name="ConnectionIcon" Text="&#xE968;" FontFamily="Segoe MDL2 Assets" Foreground="#5B61F4" FontSize="22" HorizontalAlignment="Center" VerticalAlignment="Center" />
                                        </Border>
                                        <TextBlock x:Name="ConnectionTitle" Text="尚未挂载" Foreground="{StaticResource Ink}" FontSize="18" FontWeight="SemiBold" Margin="0,17,0,0" />
                                        <TextBlock x:Name="ConnectionDescription" Text="保存配置后测试连接，然后挂载为 Windows 磁盘。" Foreground="{StaticResource Muted}" FontSize="11.5" TextWrapping="Wrap" Margin="0,6,0,0" />

                                        <Border Background="#F6F8FC" BorderBrush="#E7EBF2" BorderThickness="1" CornerRadius="11" Padding="12" Margin="0,17,0,0">
                                            <StackPanel>
                                                <TextBlock Text="映射预览" Foreground="#8A96A8" FontSize="9.5" FontWeight="Bold" />
                                                <TextBlock x:Name="UncPreviewText" Text="等待填写连接信息" Foreground="#445168" FontFamily="Cascadia Mono, Consolas" FontSize="10.5" TextWrapping="Wrap" Margin="0,5,0,0" />
                                            </StackPanel>
                                        </Border>

                                        <Border Background="#F8FAFD" BorderBrush="#E4E9F1" BorderThickness="1" CornerRadius="12" Padding="12" Margin="0,11,0,0">
                                            <StackPanel>
                                                <Grid Margin="0,0,0,10">
                                                    <StackPanel Orientation="Horizontal">
                                                        <Ellipse x:Name="NetworkQualityDot" Width="7" Height="7" Fill="#98A3B4" VerticalAlignment="Center" Margin="0,0,7,0" />
                                                        <TextBlock x:Name="NetworkQualityText" Text="正在检测网络质量" Foreground="#536075" FontSize="11" FontWeight="SemiBold" />
                                                    </StackPanel>
                                                    <TextBlock x:Name="NetworkLastCheckText" Text="每 5 秒" Foreground="#98A3B4" FontSize="9.5" HorizontalAlignment="Right" />
                                                </Grid>
                                                <UniformGrid Columns="3">
                                                    <StackPanel><TextBlock Text="延时" Foreground="#8A96A8" FontSize="9.5" /><TextBlock x:Name="NetworkLatencyText" Text="-- ms" Foreground="#344258" FontSize="13" FontWeight="SemiBold" Margin="0,3,0,0" /></StackPanel>
                                                    <StackPanel><TextBlock Text="稳定性" Foreground="#8A96A8" FontSize="9.5" /><TextBlock x:Name="NetworkStabilityText" Text="--%" Foreground="#344258" FontSize="13" FontWeight="SemiBold" Margin="0,3,0,0" /></StackPanel>
                                                    <StackPanel><TextBlock Text="磁盘响应" Foreground="#8A96A8" FontSize="9.5" /><TextBlock x:Name="DriveResponseText" Text="未挂载" Foreground="#344258" FontSize="13" FontWeight="SemiBold" Margin="0,3,0,0" /></StackPanel>
                                                </UniformGrid>
                                            </StackPanel>
                                        </Border>

                                        <Border x:Name="NetworkAlertBorder" Background="#FFF4DD" BorderBrush="#F2D398" BorderThickness="1" CornerRadius="10" Padding="10,8" Margin="0,8,0,0" Visibility="Collapsed">
                                            <TextBlock x:Name="NetworkAlertText" Text="网络连接不稳定" Foreground="#996414" FontSize="10.5" TextWrapping="Wrap" />
                                        </Border>

                                        <Button x:Name="MountButton" Content="挂载远程磁盘" Style="{StaticResource PrimaryButton}" Margin="0,12,0,0" />
                                        <Grid Margin="0,9,0,0">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="8" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions>
                                            <Button x:Name="TestButton" Grid.Column="0" Content="测试连接" Style="{StaticResource OutlineButton}" Padding="10,0" />
                                            <Button x:Name="UnmountButton" Grid.Column="2" Content="卸载" Style="{StaticResource OutlineButton}" Padding="10,0" />
                                        </Grid>
                                        <Button x:Name="OpenDriveButton" Content="在资源管理器中打开" Style="{StaticResource SecondaryButton}" Margin="0,9,0,0" />
                                    </StackPanel>
                                </Border>

                                <Border Style="{StaticResource Card}" Margin="0,16,0,0" Padding="18">
                                    <StackPanel>
                                        <Grid Margin="0,0,0,10">
                                            <TextBlock Text="活动记录" Foreground="#344258" FontSize="12" FontWeight="SemiBold" />
                                            <Button x:Name="ClearLogButton" Content="清空" HorizontalAlignment="Right" Background="Transparent" BorderThickness="0" Foreground="#8995A7" FontSize="10" Cursor="Hand" />
                                        </Grid>
                                        <TextBox x:Name="LogBox" Height="112" Background="#111A2B" Foreground="#B8C4D7" BorderThickness="0" FontFamily="Cascadia Mono, Consolas" FontSize="10" Padding="11" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" />
                                    </StackPanel>
                                </Border>
                            </StackPanel>
                        </Grid>
                    </ScrollViewer>
                </Grid>
            </Grid>
        </Grid>
    </Border>
</Window>
'@

$xmlReader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($xmlReader)

$controlNames = @(
    'TitleBar', 'MinimizeButton', 'MaximizeButton', 'CloseButton',
    'ProfileList', 'AddProfileButton', 'DeleteProfileButton', 'SaveProfileButton',
    'ProfileNameBox', 'HostBox', 'PortBox', 'UserNameBox', 'RemotePathBox',
    'DriveLetterBox', 'AuthModeBox', 'PasswordBox', 'PasswordPanel', 'PersistCheckBox',
    'TestButton', 'MountButton', 'UnmountButton', 'OpenDriveButton',
    'InstallDependenciesButton', 'ClearLogButton', 'LogBox', 'UncPreviewText',
    'GlobalStatusBadge', 'GlobalStatusDot', 'GlobalStatusText', 'ConnectionIconBorder',
    'ConnectionIcon', 'ConnectionTitle', 'ConnectionDescription',
    'NetworkQualityDot', 'NetworkQualityText', 'NetworkLastCheckText',
    'NetworkLatencyText', 'NetworkStabilityText', 'DriveResponseText',
    'NetworkAlertBorder', 'NetworkAlertText',
    'TailscaleDot', 'TailscaleState', 'WinFspDot', 'WinFspState', 'SshfsDot', 'SshfsState'
)

foreach ($name in $controlNames) {
    Set-Variable -Name $name -Value $window.FindName($name) -Scope Script
}

foreach ($letter in [char[]](67..90)) {
    $DriveLetterBox.Items.Add("$letter`:") | Out-Null
}

function Add-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )

    $now = Get-Date
    $time = $now.ToString('HH:mm:ss')
    $symbol = switch ($Level) {
        'Success' { '+' }
        'Warning' { '!' }
        'Error'   { 'x' }
        default   { 'i' }
    }
    $displayLine = "[$time] [$symbol] $Message`r`n"
    $LogBox.AppendText($displayLine)
    $LogBox.ScrollToEnd()

    # Keep a small persistent diagnostic log for failures that are difficult
    # to reproduce. Rotation prevents an always-running monitor growing it
    # without bound. Passwords are never included in application messages.
    try {
        if ((Test-Path -LiteralPath $script:LogPath) -and
            (Get-Item -LiteralPath $script:LogPath).Length -ge 1MB) {
            $rotatedPath = "$($script:LogPath).1"
            if (Test-Path -LiteralPath $rotatedPath) { Remove-Item -LiteralPath $rotatedPath -Force }
            Move-Item -LiteralPath $script:LogPath -Destination $rotatedPath
        }
        $fileLine = "[$($now.ToString('yyyy-MM-dd HH:mm:ss'))] [$symbol] $Message`r`n"
        [System.IO.File]::AppendAllText($script:LogPath, $fileLine, [System.Text.UTF8Encoding]::new($false))
    }
    catch {
        # Logging must never interrupt mounting or health monitoring.
    }
}

function Set-GlobalStatus {
    param(
        [string]$Text,
        [ValidateSet('Idle', 'Busy', 'Success', 'Error')]
        [string]$State = 'Idle'
    )

    $colors = switch ($State) {
        'Busy'    { @('#FFF4DD', '#E49B25', '#A66A0A') }
        'Success' { @('#E9F8F2', '#35A982', '#23775F') }
        'Error'   { @('#FDEDEF', '#DF6673', '#A73E4A') }
        default   { @('#EDF1F7', '#98A3B4', '#667489') }
    }
    $GlobalStatusBadge.Background = $colors[0]
    $GlobalStatusDot.Fill = $colors[1]
    $GlobalStatusText.Foreground = $colors[2]
    $GlobalStatusText.Text = $Text
}

function Get-HealthSeverityRank {
    param([string]$Severity)
    switch ($Severity) {
        'Error' { return 2 }
        'Warning' { return 1 }
        default { return 0 }
    }
}

function Render-HealthAlert {
    $message = ''
    $severity = 'None'
    if ((Get-HealthSeverityRank $script:NetworkAlertSeverity) -ge (Get-HealthSeverityRank $script:DriveAlertSeverity)) {
        $message = $script:NetworkAlertMessage
        $severity = $script:NetworkAlertSeverity
    }
    else {
        $message = $script:DriveAlertMessage
        $severity = $script:DriveAlertSeverity
    }

    if (-not $message -or $severity -eq 'None') {
        $NetworkAlertBorder.Visibility = 'Collapsed'
        return
    }

    $NetworkAlertBorder.Visibility = 'Visible'
    $NetworkAlertText.Text = $message
    if ($severity -eq 'Error') {
        $NetworkAlertBorder.Background = '#FDEDEF'
        $NetworkAlertBorder.BorderBrush = '#F1B7BD'
        $NetworkAlertText.Foreground = '#A73E4A'
    }
    else {
        $NetworkAlertBorder.Background = '#FFF4DD'
        $NetworkAlertBorder.BorderBrush = '#F2D398'
        $NetworkAlertText.Foreground = '#996414'
    }
}

function Set-HealthAlert {
    param(
        [ValidateSet('Network', 'Drive')]
        [string]$Source,
        [string]$Message,
        [ValidateSet('None', 'Warning', 'Error')]
        [string]$Severity = 'None'
    )
    if ($Source -eq 'Network') {
        $script:NetworkAlertMessage = $Message
        $script:NetworkAlertSeverity = $Severity
    }
    else {
        $script:DriveAlertMessage = $Message
        $script:DriveAlertSeverity = $Severity
    }
    Render-HealthAlert
}

function Reset-NetworkMonitor {
    $script:NetworkHistory.Clear()
    $script:NetworkProbeTask = $null
    $script:NetworkProbeKey = ''
    $script:NetworkProbeStartedAt = [datetime]::MinValue
    $script:NextNetworkProbeAt = [datetime]::MinValue
    $script:LastNetworkResult = $null
    $script:LastNetworkState = 'Idle'
    $script:ConsecutiveNetworkFailures = 0
    $NetworkQualityDot.Fill = '#98A3B4'
    $NetworkQualityText.Text = '正在检测网络质量'
    $NetworkLatencyText.Text = '-- ms'
    $NetworkStabilityText.Text = '--%'
    $NetworkLastCheckText.Text = '等待检测'
    Set-HealthAlert 'Network' '' 'None'
}

function Get-CurrentNetworkKey {
    $hostName = $HostBox.Text.Trim()
    $portValue = 0
    if (-not [int]::TryParse($PortBox.Text.Trim(), [ref]$portValue)) { return '' }
    if (-not $hostName -or $portValue -lt 1 -or $portValue -gt 65535) { return '' }
    return "$hostName|$portValue"
}

function Update-NetworkHealth {
    param($Result, [string]$ProbeKey)
    if ($null -eq $Result -or $ProbeKey -ne (Get-CurrentNetworkKey)) { return }

    $script:LastNetworkResult = $Result
    $entry = [pscustomobject]@{ Success = [bool]$Result.Reachable; Latency = [long]$Result.LatencyMs }
    $script:NetworkHistory.Enqueue($entry)
    while ($script:NetworkHistory.Count -gt 12) { $script:NetworkHistory.Dequeue() | Out-Null }

    $history = @($script:NetworkHistory.ToArray())
    $successful = @($history | Where-Object { $_.Success }).Count
    $stability = if ($history.Count -gt 0) { [int][math]::Round(($successful * 100.0) / $history.Count) } else { 0 }
    $NetworkStabilityText.Text = "$stability%"
    $probeType = if ($Result.UsedIcmp) { 'Ping' } else { 'TCP' }
    $NetworkLastCheckText.Text = "$($Result.CheckedAt.ToString('HH:mm:ss')) · $probeType"

    $state = 'Good'
    $stateLabel = '连接良好'
    $dotColor = '#35A982'
    $latency = [long]$Result.LatencyMs

    if (-not $Result.Reachable) {
        $script:ConsecutiveNetworkFailures++
        $NetworkLatencyText.Text = '-- ms'
        if ($script:ConsecutiveNetworkFailures -lt 2) {
            $state = 'Transient'
            $stateLabel = '瞬时波动，正在复查'
            $dotColor = '#E49B25'
            Set-HealthAlert 'Network' '刚刚出现一次网络超时，TailMount 将在 1 秒后复查；可能只是瞬时抖动。' 'Warning'
        }
        else {
            $state = 'Offline'
            $stateLabel = '网络不可达'
            $dotColor = '#DF6673'
            Set-HealthAlert 'Network' '服务器持续不可达。请检查 Tailscale 在线状态、ACL 或本地网络。' 'Error'
        }
    }
    else {
        $script:ConsecutiveNetworkFailures = 0
    }

    if ($Result.Reachable -and $history.Count -ge 5 -and $stability -lt 80) {
        $state = 'Unstable'
        $stateLabel = '连接不稳定'
        $dotColor = '#E49B25'
        $NetworkLatencyText.Text = "$latency ms"
        Set-HealthAlert 'Network' "最近连接成功率只有 $stability%，建议等待网络稳定后再传输重要文件。" 'Warning'
    }
    elseif ($Result.Reachable -and $latency -ge 400) {
        $state = 'VerySlow'
        $stateLabel = '响应非常慢'
        $dotColor = '#DF6673'
        $NetworkLatencyText.Text = "$latency ms"
        Set-HealthAlert 'Network' "当前延时 $latency ms，打开目录和保存文件可能明显变慢。" 'Error'
    }
    elseif ($Result.Reachable -and $latency -ge 180) {
        $state = 'Slow'
        $stateLabel = '网络偏慢'
        $dotColor = '#E49B25'
        $NetworkLatencyText.Text = "$latency ms"
        Set-HealthAlert 'Network' "当前延时 $latency ms，批量小文件操作可能较慢。" 'Warning'
    }
    elseif ($Result.Reachable) {
        if ($latency -lt 70) { $stateLabel = '连接优秀' }
        $NetworkLatencyText.Text = "$latency ms"
        Set-HealthAlert 'Network' '' 'None'
    }

    $NetworkQualityDot.Fill = $dotColor
    $NetworkQualityText.Text = $stateLabel
    if ($state -ne $script:LastNetworkState) {
        if ($state -eq 'Transient') { Add-Log '健康监测：检测到一次瞬时网络中断，正在快速复查。' 'Warning' }
        elseif ($state -eq 'Offline') { Add-Log '健康监测：服务器网络持续不可达。' 'Error' }
        elseif ($state -eq 'Unstable') { Add-Log "健康监测：近期连接稳定性为 $stability%。" 'Warning' }
        elseif ($state -eq 'Slow' -or $state -eq 'VerySlow') { Add-Log "健康监测：当前网络延时为 $latency ms。" 'Warning' }
        elseif ($script:LastNetworkState -notin @('Idle', 'Good')) { Add-Log '健康监测：网络连接已恢复正常。' 'Success' }
        $script:LastNetworkState = $state
    }
}

function Update-DriveHealth {
    param($Result, [string]$ProbeKey)
    if ($null -eq $Result -or $ProbeKey -ne $script:DriveProbeKey -or -not (Test-DriveMounted)) { return }

    $duration = [long]$Result.DurationMs
    $state = 'Good'
    if (-not $Result.Success) {
        $state = 'Offline'
        $DriveResponseText.Text = '无法访问'
        $DriveResponseText.Foreground = '#A73E4A'
        Set-HealthAlert 'Drive' '远程磁盘无法打开。网络可能已断开，建议先卸载再重新连接。' 'Error'
    }
    elseif ($duration -ge 5000) {
        $state = 'VerySlow'
        $DriveResponseText.Text = ('{0:N1} s' -f ($duration / 1000.0))
        $DriveResponseText.Foreground = '#A73E4A'
        Set-HealthAlert 'Drive' '远程目录响应超过 5 秒，文件操作可能卡住；请暂缓大量读写。' 'Error'
    }
    elseif ($duration -ge 1500) {
        $state = 'Slow'
        $DriveResponseText.Text = ('{0:N1} s' -f ($duration / 1000.0))
        $DriveResponseText.Foreground = '#A66A0A'
        Set-HealthAlert 'Drive' '远程目录响应偏慢，打开文件或保存修改可能需要等待。' 'Warning'
    }
    else {
        $DriveResponseText.Text = "$duration ms"
        $DriveResponseText.Foreground = '#344258'
        Set-HealthAlert 'Drive' '' 'None'
    }

    if ($state -ne $script:LastDriveState) {
        if ($state -eq 'Offline') { Add-Log '磁盘监测：远程目录当前无法访问。' 'Error' }
        elseif ($state -eq 'Slow' -or $state -eq 'VerySlow') { Add-Log "磁盘监测：目录响应耗时 $duration ms。" 'Warning' }
        elseif ($script:LastDriveState -notin @('Idle', 'Good')) { Add-Log '磁盘监测：远程目录响应已恢复正常。' 'Success' }
        $script:LastDriveState = $state
    }
}

function Get-SelectedAuthMode {
    $selectedItem = $AuthModeBox.SelectedItem
    if ($null -ne $selectedItem -and $selectedItem.Tag) {
        return [string]$selectedItem.Tag
    }
    return 'Password'
}

function Select-AuthMode {
    param([string]$Mode)
    for ($i = 0; $i -lt $AuthModeBox.Items.Count; $i++) {
        if ([string]$AuthModeBox.Items[$i].Tag -eq $Mode) {
            $AuthModeBox.SelectedIndex = $i
            return
        }
    }
    $AuthModeBox.SelectedIndex = 0
}

function Update-AuthPresentation {
    $mode = Get-SelectedAuthMode
    if ($mode -eq 'Key') {
        $PasswordPanel.Opacity = 0.48
        $PasswordBox.IsEnabled = $false
        $PasswordBox.Password = ''
    }
    else {
        $PasswordPanel.Opacity = 1
        $PasswordBox.IsEnabled = $true
    }
    Update-UncPreview
}

function Get-CurrentUncPath {
    $hostName = $HostBox.Text.Trim()
    $userName = $UserNameBox.Text.Trim()
    $remotePath = $RemotePathBox.Text.Trim()
    $portText = $PortBox.Text.Trim()
    $authMode = Get-SelectedAuthMode

    if (-not $hostName -or -not $userName) { return $null }

    $isAbsolute = $remotePath.StartsWith('/') -or $remotePath.StartsWith('\')
    if ($isAbsolute) {
        $prefix = if ($authMode -eq 'Key') { 'sshfs.kr' } else { 'sshfs.r' }
    }
    else {
        $prefix = if ($authMode -eq 'Key') { 'sshfs.k' } else { 'sshfs' }
    }

    $portSegment = ''
    if ($portText -and $portText -ne '22') { $portSegment = "!$portText" }
    $pathSegment = $remotePath.TrimStart('/', '\').Replace('/', '\')
    if ($pathSegment) { $pathSegment = "\$pathSegment" }

    return "\\$prefix\$userName@$hostName$portSegment$pathSegment"
}

function Update-UncPreview {
    if ($null -eq $UncPreviewText) { return }
    $unc = Get-CurrentUncPath
    if ($unc) { $UncPreviewText.Text = $unc }
    else { $UncPreviewText.Text = '等待填写服务器地址和用户名' }
}

function Capture-SelectedProfile {
    $profile = $ProfileList.SelectedItem
    if ($null -eq $profile) { return $null }

    $profile.Name = $ProfileNameBox.Text.Trim()
    if (-not $profile.Name) { $profile.Name = '未命名服务器' }
    $profile.Host = $HostBox.Text.Trim()
    $portValue = 22
    [int]::TryParse($PortBox.Text.Trim(), [ref]$portValue) | Out-Null
    $profile.Port = $portValue
    $profile.UserName = $UserNameBox.Text.Trim()
    $profile.RemotePath = $RemotePathBox.Text.Trim()
    $profile.DriveLetter = ([string]$DriveLetterBox.SelectedItem).TrimEnd(':')
    $profile.AuthMode = Get-SelectedAuthMode
    $profile.Persist = [bool]$PersistCheckBox.IsChecked
    $ProfileList.Items.Refresh()
    return $profile
}

function Show-SelectedProfile {
    $profile = $ProfileList.SelectedItem
    if ($null -eq $profile) { return }
    $script:IsLoadingProfile = $true
    try {
        $ProfileNameBox.Text = [string]$profile.Name
        $HostBox.Text = [string]$profile.Host
        $PortBox.Text = [string]$profile.Port
        $UserNameBox.Text = [string]$profile.UserName
        $RemotePathBox.Text = [string]$profile.RemotePath
        $driveValue = "{0}:" -f [string]$profile.DriveLetter
        $DriveLetterBox.SelectedItem = $driveValue
        if ($DriveLetterBox.SelectedIndex -lt 0) { $DriveLetterBox.SelectedItem = 'S:' }
        Select-AuthMode ([string]$profile.AuthMode)
        $PersistCheckBox.IsChecked = [bool]$profile.Persist
        $PasswordBox.Password = ''
        Update-AuthPresentation
        Update-UncPreview
        Update-DriveState
    }
    finally {
        $script:IsLoadingProfile = $false
    }
}

function Test-ProfileFields {
    $errors = New-Object System.Collections.Generic.List[string]
    $hostName = $HostBox.Text.Trim()
    $userName = $UserNameBox.Text.Trim()
    $remotePath = $RemotePathBox.Text.Trim()
    if (-not $hostName) { $errors.Add('请填写服务器地址') }
    elseif ($hostName -match '[\s\\/@!:]') { $errors.Add('服务器地址不能包含空格、端口或 \\ / @ !；端口请单独填写') }
    if (-not $userName) { $errors.Add('请填写服务器用户名') }
    elseif ($userName -match '[\s\\/@]') { $errors.Add('服务器用户名不能包含空格、\\、/ 或 @') }
    if (-not $remotePath) { $errors.Add('请填写远程目录') }
    elseif ($remotePath -match '[\x00-\x1F]') { $errors.Add('远程目录不能包含控制字符') }

    $port = 0
    if (-not [int]::TryParse($PortBox.Text.Trim(), [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        $errors.Add('SSH 端口必须是 1–65535')
    }
    if ($DriveLetterBox.SelectedIndex -lt 0) { $errors.Add('请选择盘符') }

    if ($errors.Count -gt 0) {
        [System.Windows.MessageBox]::Show(($errors -join "`r`n"), '请完善连接信息', 'OK', 'Warning') | Out-Null
        return $false
    }
    return $true
}

function Get-DependencyState {
    $tailscaleCandidates = @(
        (Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Tailscale\tailscale.exe')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

    $sshfsCandidates = @(
        (Join-Path $env:ProgramFiles 'SSHFS-Win\bin\sshfs-win.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'SSHFS-Win\bin\sshfs-win.exe')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

    $winFspInstalled = $false
    try {
        $service = Get-Service -Name 'WinFsp.Launcher' -ErrorAction Stop
        $winFspInstalled = $null -ne $service
    }
    catch {
        $winFspInstalled = (Test-Path -LiteralPath (Join-Path ${env:ProgramFiles(x86)} 'WinFsp'))
    }

    [pscustomobject]@{
        Tailscale = $tailscaleCandidates.Count -gt 0
        WinFsp    = $winFspInstalled
        Sshfs     = $sshfsCandidates.Count -gt 0
        TailscalePath = if ($tailscaleCandidates.Count -gt 0) { $tailscaleCandidates[0] } else { $null }
        SshfsPath = if ($sshfsCandidates.Count -gt 0) { $sshfsCandidates[0] } else { $null }
    }
}

function Set-DependencyBadge {
    param($Dot, $Text, [bool]$Installed)
    if ($Installed) {
        $Dot.Fill = '#42C79A'
        $Text.Text = '已安装'
        $Text.Foreground = '#6CCFB0'
    }
    else {
        $Dot.Fill = '#EF8A92'
        $Text.Text = '缺少'
        $Text.Foreground = '#D9828B'
    }
}

function Update-Dependencies {
    $state = Get-DependencyState
    Set-DependencyBadge $TailscaleDot $TailscaleState $state.Tailscale
    Set-DependencyBadge $WinFspDot $WinFspState $state.WinFsp
    Set-DependencyBadge $SshfsDot $SshfsState $state.Sshfs
    if ($state.WinFsp -and $state.Sshfs) {
        $InstallDependenciesButton.Visibility = 'Collapsed'
    }
    else {
        $InstallDependenciesButton.Visibility = 'Visible'
        if (-not $state.WinFsp -and $state.Sshfs) {
            $InstallDependenciesButton.Content = '安装 WinFsp'
        }
        elseif ($state.WinFsp -and -not $state.Sshfs) {
            $InstallDependenciesButton.Content = '安装 SSHFS-Win'
        }
        else {
            $InstallDependenciesButton.Content = '安装缺少的组件'
        }
    }
    return $state
}

function Get-DriveLetter {
    $value = [string]$DriveLetterBox.SelectedItem
    if (-not $value) { return $null }
    return $value.TrimEnd(':').ToUpperInvariant()
}

function Get-MappedRemotePath {
    param([string]$LocalName)
    if (-not $LocalName) { return $null }
    $capacity = 2048
    $builder = New-Object System.Text.StringBuilder $capacity
    $result = [TailMount.NativeMethods]::WNetGetConnection($LocalName, $builder, [ref]$capacity)
    if ($result -eq 0) { return $builder.ToString() }
    return $null
}

function Test-DriveMounted {
    $letter = Get-DriveLetter
    if (-not $letter) { return $false }
    $remotePath = Get-MappedRemotePath "$letter`:"
    return $remotePath -and $remotePath.StartsWith('\\sshfs', [System.StringComparison]::OrdinalIgnoreCase)
}

function Update-DriveState {
    $letter = Get-DriveLetter
    $currentDriveKey = if ($letter) { "$letter`:" } else { '' }
    if ($script:DriveProbeKey -and $script:DriveProbeKey -ne $currentDriveKey) {
        # A probe for the previously selected drive may still be blocked in the
        # filesystem provider. Detach it so it cannot block monitoring the new
        # profile or overwrite the new profile's status when it eventually ends.
        $script:DriveProbeTask = $null
        $script:DriveProbeKey = ''
        $script:DriveProbeStartedAt = [datetime]::MinValue
        $script:NextDriveProbeAt = [datetime]::MinValue
        $script:LastDriveState = 'Idle'
    }
    $mounted = Test-DriveMounted
    if ($mounted) {
        Set-GlobalStatus "$letter`: 已挂载" 'Success'
        $ConnectionIconBorder.Background = '#E9F8F2'
        $ConnectionIcon.Foreground = '#32A27E'
        $ConnectionTitle.Text = '远程磁盘已就绪'
        $ConnectionDescription.Text = "$letter`: 已连接，可以在文件资源管理器中直接访问。"
        $MountButton.Content = '重新挂载'
        $OpenDriveButton.IsEnabled = $true
        $UnmountButton.IsEnabled = $true
        if ($script:NextDriveProbeAt -eq [datetime]::MinValue) { $script:NextDriveProbeAt = [datetime]::Now }
    }
    else {
        Set-GlobalStatus '等待连接' 'Idle'
        $ConnectionIconBorder.Background = '#EEF0FF'
        $ConnectionIcon.Foreground = '#5B61F4'
        $ConnectionTitle.Text = '尚未挂载'
        $ConnectionDescription.Text = '保存配置后测试连接，然后挂载为 Windows 磁盘。'
        $MountButton.Content = '挂载远程磁盘'
        $OpenDriveButton.IsEnabled = $false
        $UnmountButton.IsEnabled = $false
        $DriveResponseText.Text = '未挂载'
        $DriveResponseText.Foreground = '#344258'
        $script:LastDriveState = 'Idle'
        $script:DriveProbeTask = $null
        $script:DriveProbeKey = ''
        $script:DriveProbeStartedAt = [datetime]::MinValue
        $script:NextDriveProbeAt = [datetime]::MinValue
        Set-HealthAlert 'Drive' '' 'None'
    }
}

function Get-Win32Message {
    param([int]$Code)
    try {
        return (New-Object ComponentModel.Win32Exception($Code)).Message
    }
    catch {
        return "Windows 错误 $Code"
    }
}

function Get-MountErrorAdvice {
    param([int]$Code)
    switch ($Code) {
        { $_ -in @(53, 67) } { return 'Windows 找不到 SSHFS 网络路径。请确认 SSHFS-Win 已安装，并检查地址、用户名和远程目录。' }
        86 { return '密码为空、错误或已保存凭据失效。请重新输入 SSH 密码后挂载。' }
        1204 { return 'SSHFS 网络提供程序未正确注册。请重新安装 SSHFS-Win，并重启 Windows。' }
        1219 { return 'Windows 已用另一组凭据连接同一服务器。请先卸载相关映射，再重新挂载。' }
        1326 { return '用户名或密码验证失败。请检查 SSH 用户名并重新输入密码。' }
        default { return '请先测试 SSH 连接；若网络正常，请检查认证方式、远程目录和 SSHFS-Win 服务。' }
    }
}

function Get-FreshNetworkProbe {
    $key = Get-CurrentNetworkKey
    if (-not $key) { return $null }
    $parts = $key.Split('|')
    # A successful Ping proves network reachability but not that SSH is
    # listening. Mount preflight therefore always performs a real TCP check.
    $task = [TailMount.HealthProbe]::ProbeSshAsync($parts[0], [int]$parts[1], 1400)
    if (-not $task.Wait(3200)) { return $null }
    return $task.Result
}

function Complete-MountOperation {
    if ($null -eq $script:ActiveMountTask) { return }
    $localName = $script:ActiveMountLocalName
    try {
        if ($script:ActiveMountTask.IsFaulted) {
            throw $script:ActiveMountTask.Exception.GetBaseException()
        }
        $result = [int]$script:ActiveMountTask.Result
        if ($result -eq 0) {
            $PasswordBox.Password = ''
            Set-GlobalStatus "$localName 已挂载" 'Success'
            Add-Log "$localName 挂载成功。" 'Success'
            Set-HealthAlert 'Drive' '' 'None'
            $script:NextDriveProbeAt = [datetime]::Now
        }
        else {
            $message = Get-Win32Message $result
            $advice = Get-MountErrorAdvice $result
            Set-GlobalStatus '挂载失败' 'Error'
            Add-Log "挂载失败：$message（$result）。$advice" 'Error'
            [System.Windows.MessageBox]::Show("无法挂载远程目录。`r`n`r`n$message`r`n错误代码：$result`r`n`r`n建议：$advice", 'TailMount', 'OK', 'Error') | Out-Null
        }
    }
    catch {
        Set-GlobalStatus '挂载失败' 'Error'
        Add-Log "挂载失败：$($_.Exception.Message)" 'Error'
    }
    finally {
        $script:ActiveMountTask = $null
        $script:ActiveMountLocalName = ''
        $script:MountSlowNoticeShown = $false
        $script:MountVerySlowNoticeShown = $false
        $MountOperationTimer.Stop()
        $MountButton.IsEnabled = $true
        $TestButton.IsEnabled = $true
        Update-DriveState
    }
}

function Mount-SelectedProfile {
    if ($null -ne $script:ActiveMountTask) { return }
    if (-not (Test-ProfileFields)) { return }
    $profile = Capture-SelectedProfile
    Export-TailMountProfiles
    $deps = Update-Dependencies
    if (-not $deps.WinFsp -or -not $deps.Sshfs) {
        Set-GlobalStatus '缺少 SSHFS 组件' 'Error'
        Add-Log '缺少 WinFsp 或 SSHFS-Win，请先点击左下角安装。' 'Error'
        return
    }

    Set-GlobalStatus '正在检查网络…' 'Busy'
    $window.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Background)
    $preflight = Get-FreshNetworkProbe
    if ($null -eq $preflight -or -not $preflight.Reachable) {
        Set-GlobalStatus '服务器不可达' 'Error'
        Add-Log '挂载已取消：预检查发现 SSH 端口不可达。' 'Error'
        Set-HealthAlert 'Network' '服务器当前不可达，已避免启动可能长时间无响应的挂载操作。' 'Error'
        return
    }
    if ([long]$preflight.LatencyMs -ge 400) {
        Add-Log "网络延时为 $($preflight.LatencyMs) ms，挂载和文件访问可能较慢。" 'Warning'
    }

    $unc = Get-CurrentUncPath
    $letter = Get-DriveLetter
    $localName = "$letter`:"
    Set-GlobalStatus '正在挂载…' 'Busy'
    Add-Log "正在挂载 $localName → $unc"
    $window.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Background)

    $existingRemote = Get-MappedRemotePath $localName
    $driveType = [TailMount.NativeMethods]::GetDriveType("$localName\")
    if ($driveType -ne 1 -and -not $existingRemote) {
        Set-GlobalStatus '盘符已被占用' 'Error'
        Add-Log "$localName 是本地磁盘或不可替换设备，请选择其他盘符。" 'Error'
        [System.Windows.MessageBox]::Show("盘符 $localName 已被本地磁盘或其他设备占用，请选择其他盘符。", 'TailMount', 'OK', 'Warning') | Out-Null
        Update-DriveState
        return
    }
    if ($existingRemote -and -not $existingRemote.StartsWith('\\sshfs', [System.StringComparison]::OrdinalIgnoreCase)) {
        Set-GlobalStatus '盘符已被占用' 'Error'
        Add-Log "$localName 已映射到其他网络位置，TailMount 不会自动断开它。" 'Error'
        [System.Windows.MessageBox]::Show("盘符 $localName 已映射到：`r`n$existingRemote`r`n`r`n请选择其他盘符。", 'TailMount', 'OK', 'Warning') | Out-Null
        Update-DriveState
        return
    }
    if ($existingRemote) {
        [TailMount.NativeMethods]::WNetCancelConnection2($localName, 0, $true) | Out-Null
    }

    $resource = New-Object TailMount.NETRESOURCE
    $resource.lpLocalName = $localName
    $resource.lpRemoteName = $unc
    # Leave the provider unset so Windows selects the registered provider from
    # the \\sshfs / \\sshfs.r UNC prefix. Passing WinFsp's registry service name
    # here causes WNetAddConnection2 to return ERROR_BAD_PROVIDER (1204) on
    # current WinFsp releases.
    $resource.lpProvider = $null

    $flags = 0
    if ($profile.Persist) {
        $flags = $flags -bor [TailMount.NativeMethods]::CONNECT_UPDATE_PROFILE
        $flags = $flags -bor [TailMount.NativeMethods]::CONNECT_SAVE_CREDENTIALS
    }

    $password = $null
    $userName = $null
    if ($profile.AuthMode -eq 'Password') {
        $userName = $profile.UserName
        if ($PasswordBox.Password) {
            $password = $PasswordBox.Password
        }
        # With an empty field, let Windows try an already saved credential.
        # Do not request an interactive prompt from the worker thread because
        # that prompt can be hidden behind the WPF window and appear hung.
    }

    try {
        $script:ActiveMountTask = [TailMount.NativeMethods]::WNetAddConnection2Async($resource, $password, $userName, $flags)
        $script:ActiveMountLocalName = $localName
        $script:ActiveMountStartedAt = [datetime]::Now
        $script:MountSlowNoticeShown = $false
        $script:MountVerySlowNoticeShown = $false
        $MountButton.IsEnabled = $false
        $TestButton.IsEnabled = $false
        $ConnectionTitle.Text = '正在挂载远程磁盘'
        $ConnectionDescription.Text = '挂载在后台进行；网络较慢时界面仍可正常操作。'
        $MountOperationTimer.Start()
    }
    catch {
        $script:ActiveMountTask = $null
        $MountButton.IsEnabled = $true
        $TestButton.IsEnabled = $true
        Set-GlobalStatus '挂载失败' 'Error'
        Add-Log "无法启动挂载任务：$($_.Exception.Message)" 'Error'
    }
}

function Unmount-SelectedProfile {
    $letter = Get-DriveLetter
    if (-not $letter) { return }
    $localName = "$letter`:"
    $existingRemote = Get-MappedRemotePath $localName
    if (-not $existingRemote -or -not $existingRemote.StartsWith('\\sshfs', [System.StringComparison]::OrdinalIgnoreCase)) {
        Add-Log "$localName 不是 TailMount/SSHFS 映射，未执行卸载。" 'Warning'
        Update-DriveState
        return
    }
    Set-GlobalStatus '正在卸载…' 'Busy'
    $window.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Background)
    $result = [TailMount.NativeMethods]::WNetCancelConnection2($localName, [TailMount.NativeMethods]::CONNECT_UPDATE_PROFILE, $true)
    if ($result -eq 0 -or $result -eq 2250) {
        Add-Log "$localName 已卸载。" 'Success'
    }
    else {
        Add-Log "卸载失败：$(Get-Win32Message $result)（$result）" 'Error'
    }
    Update-DriveState
}

function Test-SelectedProfileConnection {
    if (-not (Test-ProfileFields)) { return }
    Capture-SelectedProfile | Out-Null
    Export-TailMountProfiles
    $hostName = $HostBox.Text.Trim()
    $port = [int]$PortBox.Text.Trim()
    Set-GlobalStatus '正在测试…' 'Busy'
    $ConnectionTitle.Text = '正在检查连接'
    $ConnectionDescription.Text = "解析 $hostName 并检查 SSH 端口 $port…"
    Add-Log "正在测试 $hostName`:$port"
    $window.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Background)

    try {
        $key = "$hostName|$port"
        $task = [TailMount.HealthProbe]::ProbeSshAsync($hostName, $port, 1800)
        if (-not $task.Wait(4200)) { throw '连接检测超时' }
        $result = $task.Result
        $script:NetworkProbeKey = $key
        Update-NetworkHealth $result $key
        if (-not $result.Reachable) { throw $(if ($result.ErrorMessage) { $result.ErrorMessage } else { '目标未接受连接' }) }
        Set-GlobalStatus 'SSH 可达' 'Success'
        $ConnectionIconBorder.Background = '#E9F8F2'
        $ConnectionIcon.Foreground = '#32A27E'
        $ConnectionTitle.Text = '服务器连接正常'
        $ConnectionDescription.Text = "$hostName 的 SSH 端口 $port 可以访问，延时 $($result.LatencyMs) ms。"
        Add-Log "SSH 端口连接成功，延时 $($result.LatencyMs) ms。" 'Success'
    }
    catch {
        Set-GlobalStatus '服务器不可达' 'Error'
        $ConnectionIconBorder.Background = '#FDEDEF'
        $ConnectionIcon.Foreground = '#D95B68'
        $ConnectionTitle.Text = '无法连接服务器'
        $ConnectionDescription.Text = '请检查 Tailscale 在线状态、服务器地址、ACL 和 SSH 端口。'
        Add-Log "连接测试失败：$($_.Exception.Message)" 'Error'
    }
    finally {
        # A connection test describes reachability, but an existing mapped
        # drive remains the primary application state.
        if (Test-DriveMounted) { Update-DriveState }
    }
}

$MountOperationTimer = New-Object Windows.Threading.DispatcherTimer
$MountOperationTimer.Interval = [timespan]::FromMilliseconds(250)
$MountOperationTimer.Add_Tick({
    if ($null -eq $script:ActiveMountTask) {
        $MountOperationTimer.Stop()
        return
    }

    if ($script:ActiveMountTask.IsCompleted) {
        Complete-MountOperation
        return
    }

    $elapsed = ([datetime]::Now - $script:ActiveMountStartedAt).TotalSeconds
    if ($elapsed -ge 30 -and -not $script:MountVerySlowNoticeShown) {
        $script:MountVerySlowNoticeShown = $true
        Set-GlobalStatus '挂载仍在等待' 'Error'
        Set-HealthAlert 'Drive' '挂载已等待超过 30 秒。网络或 SSHFS 服务可能无响应；可关闭程序后重试。' 'Error'
        Add-Log '挂载等待超过 30 秒，可能发生网络或 SSHFS 卡顿。' 'Error'
    }
    elseif ($elapsed -ge 10 -and -not $script:MountSlowNoticeShown) {
        $script:MountSlowNoticeShown = $true
        Set-GlobalStatus '挂载速度较慢' 'Busy'
        Set-HealthAlert 'Drive' '挂载耗时超过 10 秒，正在继续等待服务器响应。' 'Warning'
        Add-Log '挂载耗时超过 10 秒，仍在后台等待。' 'Warning'
    }
})

$HealthMonitorTimer = New-Object Windows.Threading.DispatcherTimer
$HealthMonitorTimer.Interval = [timespan]::FromSeconds(1)
$HealthMonitorTimer.Add_Tick({
    try {
    $now = [datetime]::Now
    $networkKey = Get-CurrentNetworkKey

    if ($script:NetworkProbeTask -and $script:NetworkProbeTask.IsCompleted) {
        try {
            if ($script:NetworkProbeTask.IsFaulted) {
                throw $script:NetworkProbeTask.Exception.GetBaseException()
            }
            Update-NetworkHealth $script:NetworkProbeTask.Result $script:NetworkProbeKey
        }
        catch {
            $failedResult = [TailMount.NetworkProbeResult]::new()
            $failedResult.Reachable = $false
            $failedResult.LatencyMs = -1
            $failedResult.CheckedAt = [datetime]::Now
            $failedResult.ErrorMessage = $_.Exception.Message
            Update-NetworkHealth $failedResult $script:NetworkProbeKey
        }
        finally {
            $script:NetworkProbeTask = $null
            $retrySeconds = if ($script:ConsecutiveNetworkFailures -eq 1) { 1 } else { 5 }
            $script:NextNetworkProbeAt = [datetime]::Now.AddSeconds($retrySeconds)
        }
    }
    elseif ($script:NetworkProbeTask -and ($now - $script:NetworkProbeStartedAt).TotalSeconds -ge 5) {
        $timeoutResult = [TailMount.NetworkProbeResult]::new()
        $timeoutResult.Reachable = $false
        $timeoutResult.LatencyMs = -1
        $timeoutResult.CheckedAt = $now
        $timeoutResult.ErrorMessage = '健康监测超时'
        Update-NetworkHealth $timeoutResult $script:NetworkProbeKey
        $script:NetworkProbeTask = $null
        $retrySeconds = if ($script:ConsecutiveNetworkFailures -eq 1) { 1 } else { 5 }
        $script:NextNetworkProbeAt = $now.AddSeconds($retrySeconds)
    }
    elseif (-not $script:NetworkProbeTask -and $networkKey -and $now -ge $script:NextNetworkProbeAt) {
        if ($script:NetworkProbeKey -and $script:NetworkProbeKey -ne $networkKey) { Reset-NetworkMonitor }
        $parts = $networkKey.Split('|')
        $script:NetworkProbeKey = $networkKey
        $script:NetworkProbeStartedAt = $now
        $script:NetworkProbeTask = [TailMount.HealthProbe]::ProbeNetworkAsync($parts[0], [int]$parts[1], 1400)
        $NetworkLastCheckText.Text = '检测中…'
    }

    $mounted = Test-DriveMounted
    if ($mounted) {
        if ($script:DriveProbeTask -and $script:DriveProbeTask.IsCompleted) {
            try {
                if ($script:DriveProbeTask.IsFaulted) { throw $script:DriveProbeTask.Exception.GetBaseException() }
                Update-DriveHealth $script:DriveProbeTask.Result $script:DriveProbeKey
            }
            catch {
                $DriveResponseText.Text = '检测失败'
                $DriveResponseText.Foreground = '#A73E4A'
                Set-HealthAlert 'Drive' '无法读取远程磁盘状态，连接可能已经失效。' 'Error'
            }
            finally {
                $script:DriveProbeTask = $null
                $script:NextDriveProbeAt = [datetime]::Now.AddSeconds(12)
            }
        }
        elseif ($script:DriveProbeTask) {
            $driveElapsed = ($now - $script:DriveProbeStartedAt).TotalSeconds
            if ($driveElapsed -ge 8 -and $script:LastDriveState -ne 'PendingVerySlow') {
                $script:LastDriveState = 'PendingVerySlow'
                $DriveResponseText.Text = '> 8 s'
                $DriveResponseText.Foreground = '#A73E4A'
                Set-HealthAlert 'Drive' '远程目录超过 8 秒没有响应。请避免重复打开窗口或强制写入文件。' 'Error'
                Add-Log '磁盘监测：远程目录超过 8 秒无响应。' 'Error'
            }
            elseif ($driveElapsed -ge 3 -and $script:LastDriveState -notin @('PendingSlow', 'PendingVerySlow')) {
                $script:LastDriveState = 'PendingSlow'
                $DriveResponseText.Text = '> 3 s'
                $DriveResponseText.Foreground = '#A66A0A'
                Set-HealthAlert 'Drive' '远程目录响应超过 3 秒，文件管理器可能暂时卡顿。' 'Warning'
                Add-Log '磁盘监测：远程目录响应超过 3 秒。' 'Warning'
            }
        }
        elseif ($now -ge $script:NextDriveProbeAt) {
            $letter = Get-DriveLetter
            if ($letter) {
                $script:DriveProbeKey = "$letter`:"
                $script:DriveProbeStartedAt = $now
                $script:DriveProbeTask = [TailMount.HealthProbe]::ProbeDriveAsync("$letter`:\")
                $DriveResponseText.Text = '检测中…'
            }
        }
    }
    else {
        if ($script:LastDriveState -ne 'Idle') {
            $script:LastDriveState = 'Idle'
            $DriveResponseText.Text = '未挂载'
            $DriveResponseText.Foreground = '#344258'
            Set-HealthAlert 'Drive' '' 'None'
        }
        $script:DriveProbeTask = $null
        $script:DriveProbeKey = ''
        $script:DriveProbeStartedAt = [datetime]::MinValue
        $script:NextDriveProbeAt = [datetime]::MinValue
    }
    $script:LastMonitorError = ''
    }
    catch {
        $monitorError = $_.Exception.Message
        if ($monitorError -ne $script:LastMonitorError) {
            $script:LastMonitorError = $monitorError
            try { Add-Log "健康监测内部错误：$monitorError" 'Error' } catch { }
        }
    }
})

$ProfileList.ItemsSource = $script:Profiles
$ProfileList.SelectedIndex = 0

$TitleBar.Add_MouseLeftButtonDown({
    param($sender, $eventArgs)
    if ($eventArgs.ClickCount -eq 2) {
        if ($window.WindowState -eq 'Maximized') { $window.WindowState = 'Normal' } else { $window.WindowState = 'Maximized' }
    }
    else {
        try { $window.DragMove() } catch { }
    }
})
$MinimizeButton.Add_Click({ $window.WindowState = 'Minimized' })
$MaximizeButton.Add_Click({ if ($window.WindowState -eq 'Maximized') { $window.WindowState = 'Normal' } else { $window.WindowState = 'Maximized' } })
$CloseButton.Add_Click({ $window.Close() })

$ProfileList.Add_SelectionChanged({
    if (-not $script:IsLoadingProfile) { Show-SelectedProfile; Reset-NetworkMonitor }
})

$AddProfileButton.Add_Click({
    if ($ProfileList.SelectedItem) { Capture-SelectedProfile | Out-Null }
    $newProfile = New-TailMountProfile -Name ("服务器 {0}" -f ($script:Profiles.Count + 1))
    $script:Profiles.Add($newProfile)
    Export-TailMountProfiles
    $ProfileList.SelectedItem = $newProfile
    Add-Log '已创建新的服务器配置。'
})

$DeleteProfileButton.Add_Click({
    $profile = $ProfileList.SelectedItem
    if ($null -eq $profile) { return }
    $answer = [System.Windows.MessageBox]::Show("确定删除配置「$($profile.Name)」吗？", '删除配置', 'YesNo', 'Question')
    if ($answer -eq 'Yes') {
        $index = $ProfileList.SelectedIndex
        $script:Profiles.Remove($profile)
        if ($script:Profiles.Count -eq 0) { $script:Profiles.Add((New-TailMountProfile)) }
        Export-TailMountProfiles
        $ProfileList.SelectedIndex = [Math]::Max(0, [Math]::Min($index, $script:Profiles.Count - 1))
        Add-Log '配置已删除。' 'Warning'
    }
})

$SaveProfileButton.Add_Click({
    Capture-SelectedProfile | Out-Null
    Export-TailMountProfiles
    if ($script:LastConfigSaveSucceeded) {
        Add-Log '配置已保存（密码未写入磁盘）。' 'Success'
    }
    else {
        Add-Log "配置保存失败：$($script:LastConfigError)" 'Error'
        [System.Windows.MessageBox]::Show("无法保存配置。`r`n`r`n$($script:LastConfigError)", 'TailMount', 'OK', 'Error') | Out-Null
    }
    Update-UncPreview
})

$AuthModeBox.Add_SelectionChanged({ if (-not $script:IsLoadingProfile) { Update-AuthPresentation } })
$DriveLetterBox.Add_SelectionChanged({ if (-not $script:IsLoadingProfile) { Update-DriveState; Update-UncPreview } })
foreach ($box in @($HostBox, $PortBox, $UserNameBox, $RemotePathBox)) {
    $box.Add_TextChanged({ if (-not $script:IsLoadingProfile) { Update-UncPreview } })
}
$HostBox.Add_TextChanged({ if (-not $script:IsLoadingProfile) { Reset-NetworkMonitor } })
$PortBox.Add_TextChanged({ if (-not $script:IsLoadingProfile) { Reset-NetworkMonitor } })

$TestButton.Add_Click({ Test-SelectedProfileConnection })
$MountButton.Add_Click({ Mount-SelectedProfile })
$UnmountButton.Add_Click({ Unmount-SelectedProfile })
$OpenDriveButton.Add_Click({
    $letter = Get-DriveLetter
    if ($letter -and (Test-DriveMounted)) {
        Start-Process explorer.exe -ArgumentList "$letter`:\"
        Add-Log "已在文件资源管理器中打开 $letter`:。"
    }
    else {
        Update-DriveState
        Add-Log '远程磁盘当前未挂载，无法打开。' 'Warning'
    }
})

$ClearLogButton.Add_Click({ $LogBox.Clear() })

$InstallDependenciesButton.Add_Click({
    $deps = Get-DependencyState
    $missingNames = New-Object System.Collections.Generic.List[string]
    if (-not $deps.WinFsp) { $missingNames.Add('WinFsp') }
    if (-not $deps.Sshfs) { $missingNames.Add('SSHFS-Win') }
    if ($missingNames.Count -eq 0) {
        Update-Dependencies | Out-Null
        Add-Log '所需组件均已安装。' 'Success'
        return
    }

    $missingText = $missingNames -join '、'
    $answer = [System.Windows.MessageBox]::Show("将使用 WinGet 安装：$missingText。安装过程中会出现系统授权窗口。是否继续？", '安装依赖', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }
    try {
        $installerScript = Join-Path $script:AppRoot 'Install-Dependencies.ps1'
        if (-not (Test-Path -LiteralPath $installerScript)) { throw '找不到组件安装脚本。' }
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$installerScript`"")
        Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments
        Add-Log "已启动组件安装程序：$missingText。安装完成后请重新启动 TailMount。" 'Info'
    }
    catch {
        Add-Log "无法启动安装：$($_.Exception.Message)" 'Error'
    }
})

$window.Add_Closing({
    try {
        $HealthMonitorTimer.Stop()
        $MountOperationTimer.Stop()
        Capture-SelectedProfile | Out-Null
        Export-TailMountProfiles
    }
    catch { }
})

$window.Add_ContentRendered({
    Show-SelectedProfile
    $deps = Update-Dependencies
    Add-Log 'TailMount 已启动。'
    foreach ($warning in $script:StartupWarnings) { Add-Log $warning 'Warning' }
    if (-not $script:LastConfigSaveSucceeded -and $script:LastConfigError) {
        Add-Log "配置自动保存失败：$($script:LastConfigError)" 'Error'
    }
    if (-not $deps.Tailscale) { Add-Log '未检测到 Tailscale 桌面客户端。' 'Warning' }
    if (-not $deps.WinFsp -or -not $deps.Sshfs) { Add-Log '首次挂载前需要安装 WinFsp 与 SSHFS-Win。' 'Warning' }
    Reset-NetworkMonitor
    $HealthMonitorTimer.Start()
})

[void]$window.ShowDialog()















