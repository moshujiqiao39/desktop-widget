#requires -version 5.1
<#
    桌面小组件 · 天气 / 时间 / CPU / 内存
    ------------------------------------------------------
    · 天气：wttr.in 为主，Open-Meteo 兜底（都免费、无需 Key）
    · 定位：IP 定位（ip-api / ipinfo）为主，设备实时定位做精修，最后 config 城市兜底
    · 时间：按本机时区；与天气所在地时区不同时，额外显示当地时间
    · 交互：左键拖动 / 右键菜单 / 托盘图标
    · 诊断：powershell -NoProfile -STA -ExecutionPolicy Bypass -File Widget.ps1 -Test
    · 出图：powershell -NoProfile -STA -ExecutionPolicy Bypass -File Widget.ps1 -Preview
#>

param(
    [switch]$Test,
    [switch]$Preview,
    [string]$PreviewPath = '',
    [switch]$MakeShortcut
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 必须在任何 WPF 类型加载前声明 DPI 感知：否则系统会把整个窗口再缩放一次，
# 「贴右下角」算出来的坐标会被乘上缩放比，窗口直接跑到屏幕外。
try {
    if (-not ('DesktopWidget.Dpi' -as [type])) {
        Add-Type -Namespace DesktopWidget -Name Dpi -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shcore.dll")]
public static extern int SetProcessDpiAwareness(int value);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetProcessDPIAware();
'@
    }
    $dpiResult = [DesktopWidget.Dpi]::SetProcessDpiAwareness(1)   # 1 = 系统 DPI 感知
    if ($dpiResult -ne 0) { $null = [DesktopWidget.Dpi]::SetProcessDPIAware() }
} catch {
    try { $null = [DesktopWidget.Dpi]::SetProcessDPIAware() } catch { }
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ============================================================ 基础路径 =====
$script:Root = $PSScriptRoot
if (-not $script:Root) { $script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path }

$script:CacheDir = Join-Path $script:Root 'cache'
$script:LogDir = Join-Path $script:Root 'logs'
foreach ($dir in @($script:CacheDir, $script:LogDir)) {
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
}
$script:ConfigPath = Join-Path $script:Root 'config.json'
$script:CachePath = Join-Path $script:CacheDir 'weather.json'
$script:TasksPath = Join-Path $script:Root 'tasks.json'
$script:LogPath = Join-Path $script:LogDir 'widget.log'

# ============================================================ 小工具 =======
function Write-Log {
    param([string]$Message)
    try {
        $line = '{0}  {1}' -f (Get-Date).ToString('MM-dd HH:mm:ss'), $Message
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    } catch { }
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return $text | ConvertFrom-Json
    } catch {
        Write-Log "读取 $Path 失败：$($_.Exception.Message)"
        return $null
    }
}

function Write-JsonFile {
    param([string]$Path, $Object)
    $json = $Object | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
}

function Get-Brush {
    param([string]$Hex)
    $color = [System.Windows.Media.ColorConverter]::ConvertFromString($Hex)
    return [System.Windows.Media.SolidColorBrush]::new($color)
}

function Format-TzLabel {
    param([TimeSpan]$Offset)
    $sign = '+'
    if ($Offset.TotalMinutes -lt 0) { $sign = '-'; $Offset = $Offset.Negate() }
    if ($Offset.Minutes -eq 0) { return ('UTC{0}{1}' -f $sign, [int]$Offset.Hours) }
    return ('UTC{0}{1}:{2:00}' -f $sign, [int]$Offset.Hours, $Offset.Minutes)
}

function Format-Invariant {
    param([double]$Value)
    return $Value.ToString('0.####', [Globalization.CultureInfo]::InvariantCulture)
}

# ============================================================ 配置 =========
function Get-DefaultConfig {
    [ordered]@{
        city                  = ''
        latitude              = $null
        longitude             = $null
        locatedBy             = ''
        locatedAt             = $null
        weatherProvider       = ''
        opacity               = 0.96
        alwaysOnTop           = $true
        left                  = $null
        top                   = $null
        weatherRefreshMinutes = 10
        showSeconds           = $true
        showTime              = $true
        showWeather           = $true
        showCpu               = $true
        showMem               = $true
        showTasks             = $true
        showAi                = $true
        deepseekKey           = ''
        aiRefreshMinutes      = 5
        priceHit              = 0.04
        priceMiss             = 2.0
        priceOut              = 8.0
        background            = '#1B2130'
        cornerRadius          = 14
    }
}

# 主题里的默认值兜底：config.json 没写的项用 theme.json
function Apply-ThemeDefaults {
    if (-not $script:Theme) { Read-Theme }
    if (-not $script:Config) { return }
    if (-not $script:Config['background']) { $script:Config['background'] = $script:Theme.background }
    if ($null -eq $script:Config['opacity']) { $script:Config['opacity'] = $script:Theme.opacity }
    if ($null -eq $script:Config['cornerRadius']) { $script:Config['cornerRadius'] = $script:Theme.cornerRadius }
}

function Read-Config {
    $cfg = Get-DefaultConfig
    $saved = Read-JsonFile $script:ConfigPath
    if ($saved) {
        foreach ($prop in $saved.PSObject.Properties) {
            if ($cfg.Contains($prop.Name)) { $cfg[$prop.Name] = $prop.Value }
        }
    }
    return $cfg
}

function Save-Config {
    try { Write-JsonFile $script:ConfigPath $script:Config }
    catch { Write-Log "保存配置失败：$($_.Exception.Message)" }
}

$script:Config = Read-Config

# ============================================================ 运行状态 =====
$script:UI = $null
$script:Window = $null
$script:Menu = $null
$script:Tray = $null
$script:Exiting = $false
$script:Ready = $false
$script:LastConfigSave = [datetime]::MinValue

$script:Location = @{ Lat = $null; Lon = $null; City = ''; Source = ''; TimeZone = ''; UtcOffsetSeconds = $null }
if ($script:Config['latitude'] -and $script:Config['longitude']) {
    $script:Location.Lat = [double]$script:Config['latitude']
    $script:Location.Lon = [double]$script:Config['longitude']
    $script:Location.City = [string]$script:Config['city']
    $script:Location.Source = 'config'
}

$script:Weather = $null
$script:WeatherState = 'idle'       # idle | locating | fetching | ok | error
$script:WeatherError = ''
$script:NextWeatherAt = [datetime]::MinValue
$script:LastIconKey = ''
$script:CompactMode = $false
$script:Tasks = @()
$script:TasksOpen = $false
$script:EditingTaskId = ''
$script:ReminderActive = $false
$script:AiAdapters = @()
$script:AiState = @{}
$script:BgRequests = @{}
$script:UiOpen = $false
$script:PreTasksPos = $null
$script:LastCpu = 0
$script:LastMem = 0

$script:Queue = New-Object System.Collections.Queue
$script:Net = $null
$script:GeoStage = ''               # '' | position | done | failed
$script:GeoTask = $null
$script:GeoDeadline = [datetime]::MinValue
$script:GeoLocator = $null
$script:AsTaskMethod = $null

# 天气源顺序：wttr.in 在国内可直连，Open-Meteo 作兜底
$script:Providers = @('wttr.in', 'open-meteo')
$script:ProviderIndex = 0
if ($script:Config['weatherProvider'] -and ($script:Providers -contains $script:Config['weatherProvider'])) {
    $script:ProviderIndex = [array]::IndexOf($script:Providers, [string]$script:Config['weatherProvider'])
}

$script:IpEndpoints = @(
    @{ Name = 'ip-api'; Url = 'http://ip-api.com/json/?lang=zh-CN&fields=status,message,country,regionName,city,lat,lon,timezone' },
    @{ Name = 'ipinfo'; Url = 'https://ipinfo.io/json' }
)
$script:IpIndex = 0

$script:Http = [System.Net.Http.HttpClient]::new()
$script:Http.Timeout = [TimeSpan]::FromSeconds(15)
$null = $script:Http.DefaultRequestHeaders.UserAgent.ParseAdd('DesktopWidget/1.0 (Windows NT; PowerShell)')

# ============================================================ 天气码表 =====
# WMO（Open-Meteo）
$script:WmoMap = @{
    0  = @('晴',           'sun',      '#FFC65C')
    1  = @('晴间多云',     'suncloud', '#FFD27A')
    2  = @('多云',         'cloud',    '#A9BCCF')
    3  = @('阴',           'cloud',    '#8E9EAE')
    45 = @('雾',           'fog',      '#B9C6D2')
    48 = @('雾凇',         'fog',      '#C7D5E1')
    51 = @('毛毛雨',       'rain',     '#7FBDE8')
    53 = @('毛毛雨',       'rain',     '#7FBDE8')
    55 = @('强毛毛雨',     'rain',     '#6FB1E2')
    56 = @('冻毛毛雨',     'rain',     '#8CC8F0')
    57 = @('冻毛毛雨',     'rain',     '#8CC8F0')
    61 = @('小雨',         'rain',     '#6FB1E2')
    63 = @('中雨',         'rain',     '#5FA6DE')
    65 = @('大雨',         'rain',     '#4F9BD8')
    66 = @('冻雨',         'rain',     '#8CC8F0')
    67 = @('冻雨',         'rain',     '#8CC8F0')
    71 = @('小雪',         'snow',     '#D6E9FF')
    73 = @('中雪',         'snow',     '#C9E1FB')
    75 = @('大雪',         'snow',     '#BEDAF9')
    77 = @('米雪',         'snow',     '#D6E9FF')
    80 = @('阵雨',         'rain',     '#6FB1E2')
    81 = @('强阵雨',       'rain',     '#5FA6DE')
    82 = @('暴阵雨',       'rain',     '#4F9BD8')
    85 = @('阵雪',         'snow',     '#C9E1FB')
    86 = @('强阵雪',       'snow',     '#BEDAF9')
    95 = @('雷阵雨',       'storm',    '#B79CF2')
    96 = @('雷阵雨伴冰雹', 'storm',    '#B79CF2')
    99 = @('雷暴冰雹',     'storm',    '#B79CF2')
}

# WWO（wttr.in）
$script:WwoMap = @{
    113 = @('晴',         'sun',      '#FFC65C')
    116 = @('晴间多云',   'suncloud', '#FFD27A')
    119 = @('多云',       'cloud',    '#A9BCCF')
    122 = @('阴',         'cloud',    '#8E9EAE')
    143 = @('薄雾',       'fog',      '#B9C6D2')
    248 = @('雾',         'fog',      '#B9C6D2')
    260 = @('冻雾',       'fog',      '#C7D5E1')
    176 = @('局部小雨',   'rain',     '#6FB1E2')
    263 = @('小毛雨',     'rain',     '#7FBDE8')
    266 = @('毛雨',       'rain',     '#7FBDE8')
    281 = @('冻毛雨',     'rain',     '#8CC8F0')
    284 = @('强冻毛雨',   'rain',     '#8CC8F0')
    293 = @('小雨',       'rain',     '#6FB1E2')
    296 = @('小雨',       'rain',     '#6FB1E2')
    299 = @('间断中雨',   'rain',     '#5FA6DE')
    302 = @('中雨',       'rain',     '#5FA6DE')
    305 = @('间断大雨',   'rain',     '#4F9BD8')
    308 = @('大雨',       'rain',     '#4F9BD8')
    311 = @('小冻雨',     'rain',     '#8CC8F0')
    314 = @('冻雨',       'rain',     '#8CC8F0')
    353 = @('小阵雨',     'rain',     '#6FB1E2')
    356 = @('强阵雨',     'rain',     '#5FA6DE')
    359 = @('暴雨',       'rain',     '#4F9BD8')
    179 = @('局部小雪',   'snow',     '#D6E9FF')
    182 = @('局地雨夹雪', 'snow',     '#C9E1FB')
    185 = @('局部冻雨',   'rain',     '#8CC8F0')
    227 = @('吹雪',       'snow',     '#C9E1FB')
    230 = @('暴风雪',     'snow',     '#BEDAF9')
    317 = @('小雨夹雪',   'snow',     '#D6E9FF')
    320 = @('雨夹雪',     'snow',     '#C9E1FB')
    323 = @('局部小雪',   'snow',     '#D6E9FF')
    326 = @('小雪',       'snow',     '#D6E9FF')
    329 = @('局部中雪',   'snow',     '#C9E1FB')
    332 = @('中雪',       'snow',     '#C9E1FB')
    335 = @('局部大雪',   'snow',     '#BEDAF9')
    338 = @('大雪',       'snow',     '#BEDAF9')
    350 = @('冰粒',       'snow',     '#DCEBFF')
    362 = @('阵雪夹雨',   'snow',     '#C9E1FB')
    365 = @('强阵雪夹雨', 'snow',     '#BEDAF9')
    368 = @('小阵雪',     'snow',     '#D6E9FF')
    371 = @('强阵雪',     'snow',     '#BEDAF9')
    374 = @('小冰粒',     'snow',     '#DCEBFF')
    377 = @('强冰粒',     'snow',     '#BEDAF9')
    200 = @('雷阵雨',     'storm',    '#B79CF2')
    386 = @('局部雷雨',   'storm',    '#B79CF2')
    389 = @('强雷阵雨',   'storm',    '#B79CF2')
    392 = @('局部雷雪',   'storm',    '#B79CF2')
    395 = @('强雷雪',     'storm',    '#B79CF2')
}

function Get-Condition {
    param([int]$Code, [ValidateSet('wmo', 'wwo')][string]$Scale = 'wmo')
    if ($Scale -eq 'wwo' -and $script:WwoMap.ContainsKey($Code)) {
        $row = $script:WwoMap[$Code]
        return @{ Text = $row[0]; Kind = $row[1]; Color = $row[2] }
    }
    if ($script:WmoMap.ContainsKey($Code)) {
        $row = $script:WmoMap[$Code]
        return @{ Text = $row[0]; Kind = $row[1]; Color = $row[2] }
    }
    return @{ Text = '未知'; Kind = 'cloud'; Color = '#A9BCCF' }
}

# ============================================================ 界面 XAML ====
$script:Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="桌面小组件" Width="332" SizeToContent="Height"
        WindowStyle="None" ResizeMode="NoResize" AllowsTransparency="True"
        Background="Transparent" ShowInTaskbar="False" Topmost="True"
        ShowActivated="False" UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display"
        FontFamily="Segoe UI, Microsoft YaHei UI, Microsoft YaHei">

  <Window.Resources>
    <SolidColorBrush x:Key="TextPrimary" Color="#F7FFFFFF"/>
    <SolidColorBrush x:Key="TextSecondary" Color="#B4FFFFFF"/>
    <SolidColorBrush x:Key="TextTertiary" Color="#7AFFFFFF"/>
    <SolidColorBrush x:Key="TextFaint" Color="#5CFFFFFF"/>
    <SolidColorBrush x:Key="TextMuted" Color="#59FFFFFF"/>
    <SolidColorBrush x:Key="TextIcon" Color="#73FFFFFF"/>
    <SolidColorBrush x:Key="TrackBrush" Color="#1FFFFFFF"/>
    <SolidColorBrush x:Key="DividerBrush" Color="#1AFFFFFF"/>
    <SolidColorBrush x:Key="SwitchTrackBrush" Color="#26FFFFFF"/>
    <SolidColorBrush x:Key="SwitchThumb" Color="#A6FFFFFF"/>

    <Style x:Key="IconButton" TargetType="Button">
      <Setter Property="Width" Value="22"/>
      <Setter Property="Height" Value="22"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bg" CornerRadius="11" Background="Transparent">
              <TextBlock x:Name="Glyph" Text="{TemplateBinding Content}" FontSize="{TemplateBinding FontSize}"
                         FontFamily="{TemplateBinding FontFamily}" Foreground="{DynamicResource TextIcon}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bg" Property="Background" Value="#33FFFFFF"/>
                <Setter TargetName="Glyph" Property="Foreground" Value="#FFFFFFFF"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bg" Property="Background" Value="#4DFFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Toggle" TargetType="CheckBox">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="Track" Width="36" Height="20" CornerRadius="10" Background="{DynamicResource SwitchTrackBrush}">
              <Ellipse x:Name="Thumb" Width="16" Height="16" Fill="{DynamicResource SwitchThumb}"
                       HorizontalAlignment="Left" Margin="2,0,0,0"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="#5EA6E8"/>
                <Setter TargetName="Thumb" Property="Fill" Value="#FFFFFF"/>
                <Setter TargetName="Thumb" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="Thumb" Property="Margin" Value="0,0,2,0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="FlatButton" TargetType="Button">
      <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
      <Setter Property="Background" Value="#1FFFFFFF"/>
      <Setter Property="FontSize" Value="10.5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" CornerRadius="9" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="Background" Value="#33FFFFFF"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="B" Property="Background" Value="#4DFFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="DarkBox" TargetType="TextBox">
      <Setter Property="Background" Value="#1FFFFFFF"/>
      <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource TrackBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="7,5"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="CaretBrush" Value="{DynamicResource TextPrimary}"/>
      <Setter Property="SelectionBrush" Value="#665EA6E8"/>
    </Style>

  </Window.Resources>

  <Border x:Name="Card" Width="304" Margin="14" CornerRadius="20"
          BorderThickness="1" BorderBrush="{DynamicResource TrackBrush}">
    <Border.Background>
      <LinearGradientBrush StartPoint="0,0" EndPoint="0.7,1">
        <GradientStop Color="#F2181E2B" Offset="0"/>
        <GradientStop Color="#F20C1017" Offset="1"/>
      </LinearGradientBrush>
    </Border.Background>
    <Border.Effect>
      <DropShadowEffect BlurRadius="18" ShadowDepth="4" Direction="90" Opacity="0.5" Color="#000000"/>
    </Border.Effect>

    <Grid>
      <StackPanel x:Name="MainPanel" Margin="20,15,20,13">


        <Grid x:Name="TimeRow">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <StackPanel Orientation="Horizontal" VerticalAlignment="Bottom">
            <TextBlock x:Name="ClockText" Text="00:00" FontSize="38" FontWeight="Light" Foreground="{DynamicResource TextPrimary}"/>
            <TextBlock x:Name="SecText" Text="00" FontSize="14" Margin="4,0,0,5" VerticalAlignment="Bottom" Foreground="{DynamicResource TextTertiary}"/>
          </StackPanel>
          <StackPanel Grid.Column="1" VerticalAlignment="Bottom" HorizontalAlignment="Right" Margin="0,0,0,4">
            <TextBlock x:Name="DateText" Text="—" FontSize="12" Foreground="{DynamicResource TextSecondary}" HorizontalAlignment="Right"/>
            <TextBlock x:Name="WeekText" Text="—" FontSize="10.5" Foreground="{DynamicResource TextTertiary}" HorizontalAlignment="Right" Margin="0,2,0,0"/>
          </StackPanel>
        </Grid>

        <Border x:Name="ReminderBanner" Visibility="Collapsed" CornerRadius="10" Background="#3DF2B461"
                BorderThickness="1" BorderBrush="#66F2B461" Padding="9,7" Margin="0,12,0,0">
          <Grid>
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
              <TextBlock Text="⏰" FontSize="12" VerticalAlignment="Center" Foreground="#FFF2C27A"/>
              <TextBlock x:Name="ReminderText" Text="" FontSize="10.5" Margin="6,0,0,0" VerticalAlignment="Center"
                         Foreground="{DynamicResource TextPrimary}" TextTrimming="CharacterEllipsis" MaxWidth="150"/>
            </StackPanel>
            <Button x:Name="ReminderOk" Content="知道了" FontSize="9" FontFamily="Microsoft YaHei UI"
                    HorizontalAlignment="Right" VerticalAlignment="Center" Cursor="Hand"
                    Foreground="#FFF2C27A" Background="Transparent" BorderThickness="0" Padding="6,2"/>
          </Grid>
        </Border>

        <Grid x:Name="WeatherRow" Margin="0,12,0,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Canvas x:Name="WeatherIcon" Width="56" Height="56" VerticalAlignment="Top"/>
          <StackPanel Grid.Column="1" Margin="11,0,0,0">
            <StackPanel Orientation="Horizontal">
              <TextBlock x:Name="TempText" Text="--°" FontSize="32" FontWeight="Light" Foreground="{DynamicResource TextPrimary}"/>
              <TextBlock x:Name="CondText" Text="定位中" FontSize="12" Margin="7,0,0,7" VerticalAlignment="Bottom" Foreground="{DynamicResource TextSecondary}"/>
            </StackPanel>
            <TextBlock x:Name="RangeText" Text="—" FontSize="10.5" Foreground="{DynamicResource TextTertiary}" Margin="1,2,0,0"/>
            <StackPanel Orientation="Horizontal" Margin="1,4,0,0">
              <TextBlock x:Name="CityLabel" Text="—" FontSize="10.5" Foreground="{DynamicResource TextSecondary}"/>
              <TextBlock x:Name="DetailLabel" Text="" FontSize="10.5" Foreground="{DynamicResource TextTertiary}"/>
            </StackPanel>
          </StackPanel>
        </Grid>

        <Border x:Name="DividerBorder" Height="1" Background="{DynamicResource DividerBrush}" Margin="0,13,0,0"/>

        <Grid x:Name="CpuRow" Margin="0,11,0,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="34"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="58"/>
          </Grid.ColumnDefinitions>
          <TextBlock Text="CPU" FontSize="10" Foreground="{DynamicResource TextTertiary}" VerticalAlignment="Center"/>
          <Border x:Name="CpuTrack" Grid.Column="1" Height="4" CornerRadius="2"
                  Background="{DynamicResource TrackBrush}" Margin="4,0,8,0" VerticalAlignment="Center">
            <Border x:Name="CpuBar" Width="0" HorizontalAlignment="Left" CornerRadius="2" Background="#5EA6E8"/>
          </Border>
          <TextBlock x:Name="CpuText" Grid.Column="2" Text="--%" FontSize="11.5"
                     Foreground="{DynamicResource TextPrimary}" TextAlignment="Right" VerticalAlignment="Center"/>
        </Grid>

        <Grid x:Name="MemRow" Margin="0,10,0,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="34"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="58"/>
          </Grid.ColumnDefinitions>
          <TextBlock Text="内存" FontSize="10" Foreground="{DynamicResource TextTertiary}" VerticalAlignment="Center"/>
          <Border x:Name="MemTrack" Grid.Column="1" Height="4" CornerRadius="2"
                  Background="{DynamicResource TrackBrush}" Margin="4,0,8,0" VerticalAlignment="Center">
            <Border x:Name="MemBar" Width="0" HorizontalAlignment="Left" CornerRadius="2" Background="#A78BFA"/>
          </Border>
          <StackPanel Grid.Column="2" VerticalAlignment="Center">
            <TextBlock x:Name="MemText" Text="--%" FontSize="11.5" Foreground="{DynamicResource TextPrimary}" TextAlignment="Right"/>
            <TextBlock x:Name="MemGbText" Text="--" FontSize="8.5" Foreground="{DynamicResource TextFaint}" TextAlignment="Right" Margin="0,1,0,0"/>
          </StackPanel>
        </Grid>

        <Grid x:Name="AiRow" Margin="0,8,0,0" Cursor="Hand" Background="Transparent">
          <TextBlock x:Name="AiSummary" Text="AI" FontSize="10.5" Foreground="{DynamicResource TextSecondary}"
                     TextTrimming="CharacterEllipsis" Margin="0,0,10,0"/>
        </Grid>

        <Grid x:Name="TasksRow" Margin="0,10,0,0" Cursor="Hand" Background="Transparent">
          <TextBlock x:Name="TasksSummary" Text="待办" FontSize="10.5" Foreground="{DynamicResource TextSecondary}"
                     TextTrimming="CharacterEllipsis" Margin="0,0,34,0"/>
          <TextBlock x:Name="TasksCount" Text="" FontSize="9" Foreground="{DynamicResource TextMuted}"
                     HorizontalAlignment="Right" VerticalAlignment="Center"/>
        </Grid>

        <Grid x:Name="FooterRow" Margin="0,11,0,0">
          <TextBlock x:Name="TzText" Text="" FontSize="8.5" Foreground="{DynamicResource TextFaint}"/>
          <TextBlock x:Name="SourceText" Text="" FontSize="8.5" Foreground="{DynamicResource TextFaint}" HorizontalAlignment="Right"/>
        </Grid>

        <TextBlock x:Name="EmptyHint" Text="模块都关掉了 · 点右上角 ⚙ 打开" Visibility="Collapsed"
                   FontSize="11" Foreground="{DynamicResource TextTertiary}" TextAlignment="Center" Margin="0,30,0,30"/>
      </StackPanel>

      <StackPanel x:Name="SettingsPanel" Visibility="Collapsed" Margin="20,16,20,14">
        <TextBlock Text="设置" FontSize="14.5" FontWeight="SemiBold" Foreground="{DynamicResource TextPrimary}"/>

        <Border x:Name="FirstRunHint" Visibility="Collapsed" Background="#22FFC857" CornerRadius="8" Padding="10,8" Margin="0,10,0,0">
          <TextBlock Text="第一次运行：勾上你想看的模块，然后点右上角 ✕ 收起即可。天气和定位会自动处理。" FontSize="9.5" Foreground="{DynamicResource TextPrimary}" TextWrapping="Wrap"/>
        </Border>

        <TextBlock Text="显示内容" FontSize="9.5" Foreground="{DynamicResource TextMuted}" Margin="0,13,0,0"/>

        <Grid Margin="0,7,0,0">
          <TextBlock Text="天气" FontSize="11.5" Foreground="{DynamicResource TextPrimary}" VerticalAlignment="Center"/>
          <CheckBox x:Name="SwWeather" Style="{StaticResource Toggle}" HorizontalAlignment="Right" VerticalAlignment="Center"/>
        </Grid>
        <Grid Margin="0,9,0,0">
          <TextBlock Text="时间" FontSize="11.5" Foreground="{DynamicResource TextPrimary}" VerticalAlignment="Center"/>
          <CheckBox x:Name="SwTime" Style="{StaticResource Toggle}" HorizontalAlignment="Right" VerticalAlignment="Center"/>
        </Grid>
        <Grid Margin="0,9,0,0">
          <TextBlock Text="CPU" FontSize="11.5" Foreground="{DynamicResource TextPrimary}" VerticalAlignment="Center"/>
          <CheckBox x:Name="SwCpu" Style="{StaticResource Toggle}" HorizontalAlignment="Right" VerticalAlignment="Center"/>
        </Grid>
        <Grid Margin="0,9,0,0">
          <TextBlock Text="内存" FontSize="11.5" Foreground="{DynamicResource TextPrimary}" VerticalAlignment="Center"/>
          <CheckBox x:Name="SwMem" Style="{StaticResource Toggle}" HorizontalAlignment="Right" VerticalAlignment="Center"/>
        </Grid>
        <Grid Margin="0,9,0,0">
          <TextBlock Text="待办" FontSize="11.5" Foreground="{DynamicResource TextPrimary}" VerticalAlignment="Center"/>
          <CheckBox x:Name="SwTasks" Style="{StaticResource Toggle}" HorizontalAlignment="Right" VerticalAlignment="Center" AutomationProperties.Name="显示待办"/>
        </Grid>
        <Grid Margin="0,9,0,0">
          <TextBlock Text="AI 用量" FontSize="11.5" Foreground="{DynamicResource TextPrimary}" VerticalAlignment="Center"/>
          <CheckBox x:Name="SwAi" Style="{StaticResource Toggle}" HorizontalAlignment="Right" VerticalAlignment="Center" AutomationProperties.Name="显示AI用量"/>
        </Grid>

        <Border Height="1" Background="{DynamicResource DividerBrush}" Margin="0,13,0,0"/>

        <TextBlock Text="窗口" FontSize="9.5" Foreground="{DynamicResource TextMuted}" Margin="0,11,0,0"/>
        <Grid Margin="0,7,0,0">
          <TextBlock Text="置顶显示" FontSize="11.5" Foreground="{DynamicResource TextPrimary}" VerticalAlignment="Center"/>
          <CheckBox x:Name="SwTopmost" Style="{StaticResource Toggle}" HorizontalAlignment="Right" VerticalAlignment="Center"/>
        </Grid>

        <Border Height="1" Background="{DynamicResource DividerBrush}" Margin="0,13,0,0"/>

        <TextBlock Text="背景颜色" FontSize="9.5" Foreground="{DynamicResource TextMuted}" Margin="0,11,0,0"/>

        <Grid Margin="0,9,0,0" Height="22">
          <Border x:Name="ColorPreview" Width="22" Height="22" CornerRadius="11" HorizontalAlignment="Left"
                  Background="#1B2130" BorderThickness="1" BorderBrush="{DynamicResource TrackBrush}"/>
          <TextBlock x:Name="ColorHexText" Text="#1B2130" FontSize="10" Foreground="{DynamicResource TextTertiary}"
                     VerticalAlignment="Center" Margin="31,0,0,0"/>
        </Grid>

        <Border x:Name="HueBar" Height="12" CornerRadius="6" Margin="0,9,0,0" Cursor="Hand">
          <Border.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
              <GradientStop Color="#FF0000" Offset="0"/>
              <GradientStop Color="#FFFF00" Offset="0.1667"/>
              <GradientStop Color="#00FF00" Offset="0.3333"/>
              <GradientStop Color="#00FFFF" Offset="0.5"/>
              <GradientStop Color="#0000FF" Offset="0.6667"/>
              <GradientStop Color="#FF00FF" Offset="0.8333"/>
              <GradientStop Color="#FF0000" Offset="1"/>
            </LinearGradientBrush>
          </Border.Background>
        </Border>

        <Grid x:Name="SvHost" Height="70" Margin="0,8,0,0">
          <Border x:Name="SatValPad" Cursor="Hand" CornerRadius="8">
            <Border.Clip>
              <RectangleGeometry RadiusX="8" RadiusY="8" Rect="0,0,264,70"/>
            </Border.Clip>
            <Grid>
              <Border x:Name="SvHueLayer" Background="#1B2130"/>
              <Border>
                <Border.Background>
                  <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                    <GradientStop Color="#FFFFFFFF" Offset="0"/>
                    <GradientStop Color="#00FFFFFF" Offset="1"/>
                  </LinearGradientBrush>
                </Border.Background>
              </Border>
              <Border>
                <Border.Background>
                  <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                    <GradientStop Color="#00000000" Offset="0"/>
                    <GradientStop Color="#FF000000" Offset="1"/>
                  </LinearGradientBrush>
                </Border.Background>
              </Border>
            </Grid>
          </Border>
          <Ellipse x:Name="SvKnob" Width="12" Height="12" Stroke="{DynamicResource TextPrimary}" StrokeThickness="2"
                   Fill="#33FFFFFF" IsHitTestVisible="False" HorizontalAlignment="Left" VerticalAlignment="Top"/>
        </Grid>

        <Grid Margin="0,12,0,0">
          <TextBlock Text="不透明度" FontSize="11.5" Foreground="{DynamicResource TextPrimary}" VerticalAlignment="Center"/>
          <TextBlock x:Name="OpacityText" Text="96%" FontSize="10.5" Foreground="{DynamicResource TextTertiary}"
                     HorizontalAlignment="Right" VerticalAlignment="Center"/>
        </Grid>
        <Border x:Name="OpacityBar" Height="14" CornerRadius="7" Margin="0,8,0,0"
                Background="{DynamicResource TrackBrush}" Cursor="Hand">
          <Border x:Name="OpacityFill" Width="0" HorizontalAlignment="Left" CornerRadius="7" Background="#5EA6E8"/>
        </Border>

        <Grid Margin="0,14,0,0">
          <TextBlock x:Name="ResetButton" Text="恢复默认设置" FontSize="10" Foreground="{DynamicResource TextTertiary}" Cursor="Hand"/>
          <TextBlock x:Name="HintText" Text="点 ⚙ 或右上角 ✕ 收起" FontSize="9" Foreground="{DynamicResource TextMuted}"
                     HorizontalAlignment="Right" VerticalAlignment="Center"/>
        </Grid>
      </StackPanel>

      <StackPanel x:Name="TasksPanel" Visibility="Collapsed" Margin="20,16,20,14">
        <Grid>
          <TextBlock Text="待办" FontSize="14.5" FontWeight="SemiBold" Foreground="{DynamicResource TextPrimary}"/>
          <TextBlock x:Name="TasksHint" Text="点条目编辑" FontSize="9" Foreground="{DynamicResource TextMuted}"
                     HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,22,0"/>
        </Grid>

        <ScrollViewer x:Name="TasksScroll" MaxHeight="200" VerticalScrollBarVisibility="Auto" Margin="0,10,0,0">
          <StackPanel x:Name="TasksList"/>
        </ScrollViewer>
        <TextBlock x:Name="TasksEmpty" Text="还没有待办，下面新建一条" FontSize="10.5"
                   Foreground="{DynamicResource TextMuted}" Margin="0,16,0,16" HorizontalAlignment="Center"/>

        <Button x:Name="TaskNewButton" Content="＋ 新建待办" Style="{StaticResource FlatButton}"
                Padding="0,8" Margin="0,10,0,0" HorizontalAlignment="Stretch"/>

        <StackPanel x:Name="TaskEditView" Visibility="Collapsed" Margin="0,10,0,0">
          <TextBlock Text="事情" FontSize="9" Foreground="{DynamicResource TextMuted}"/>
          <TextBox x:Name="EditorTitle" Style="{StaticResource DarkBox}" Margin="0,5,0,0" AutomationProperties.Name="事情"/>

          <Grid Margin="0,9,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <StackPanel>
              <TextBlock Text="时间" FontSize="9" Foreground="{DynamicResource TextMuted}"/>
              <TextBox x:Name="EditorDue" Style="{StaticResource DarkBox}" Margin="0,5,0,0" AutomationProperties.Name="时间"/>
            </StackPanel>
            <StackPanel Grid.Column="1" Margin="8,0,0,0">
              <TextBlock Text="提醒时间" FontSize="9" Foreground="{DynamicResource TextMuted}"/>
              <TextBox x:Name="EditorRemindAt" Style="{StaticResource DarkBox}" Margin="0,5,0,0" AutomationProperties.Name="提醒时间"/>
            </StackPanel>
          </Grid>

          <Grid Margin="0,9,0,0">
            <TextBlock Text="到点提醒" FontSize="10.5" Foreground="{DynamicResource TextPrimary}" VerticalAlignment="Center"/>
            <CheckBox x:Name="EditorRemind" Style="{StaticResource Toggle}" HorizontalAlignment="Right" VerticalAlignment="Center" AutomationProperties.Name="到点提醒"/>
          </Grid>

          <TextBlock x:Name="EditorError" Text="" FontSize="9" Foreground="#FFF0706A" Margin="0,6,0,0" TextWrapping="Wrap"/>

          <Grid Margin="0,10,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Button x:Name="TaskSaveButton" Content="保存" Style="{StaticResource FlatButton}" Padding="0,7" Margin="0,0,4,0"/>
            <Button x:Name="TaskDeleteButton" Content="删除" Style="{StaticResource FlatButton}" Padding="0,7" Margin="4,0" Grid.Column="1"/>
            <Button x:Name="TaskCancelButton" Content="取消" Style="{StaticResource FlatButton}" Padding="0,7" Margin="4,0,0,0" Grid.Column="2"/>
          </Grid>
        </StackPanel>
      </StackPanel>

      <StackPanel x:Name="AiPanel" Visibility="Collapsed" Margin="20,16,20,14">
        <Grid>
          <TextBlock Text="AI 用量" FontSize="14.5" FontWeight="SemiBold" Foreground="{DynamicResource TextPrimary}"/>
          <TextBlock Text="今日" FontSize="9" Foreground="{DynamicResource TextMuted}" HorizontalAlignment="Right"
                     VerticalAlignment="Center" Margin="0,0,22,0"/>
        </Grid>

        <StackPanel x:Name="AiList" Margin="0,10,0,0"/>

        <TextBlock x:Name="AiKeyLabel" Text="DeepSeek API key（只存本机 config.json，用来查账户余额）" FontSize="8.5"
                   Foreground="{DynamicResource TextMuted}" Margin="0,8,0,0"/>
        <TextBox x:Name="AiKeyBox" Style="{StaticResource DarkBox}" Margin="0,5,0,0" AutomationProperties.Name="DeepSeek key"/>
        <Grid Margin="0,8,0,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Button x:Name="AiKeySave" Content="保存并查询" Style="{StaticResource FlatButton}" Padding="0,7" Margin="0,0,4,0"/>
          <Button x:Name="AiRefresh" Content="刷新" Style="{StaticResource FlatButton}" Padding="0,7" Margin="4,0,0,0" Grid.Column="1"/>
        </Grid>
      </StackPanel>

      <Grid x:Name="CompactPanel" Visibility="Collapsed" Height="44" Margin="14,0,8,0">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock x:Name="CompactClock" Text="00:00" FontSize="19" FontWeight="Light"
                     Foreground="{DynamicResource TextPrimary}"/>
          <TextBlock x:Name="CompactTemp" Text="--°" FontSize="13" VerticalAlignment="Center" Margin="9,0,0,1"
                     Foreground="{DynamicResource TextSecondary}"/>
        </StackPanel>
        <Button x:Name="ExpandButton" Style="{StaticResource IconButton}" Content="▢" FontSize="14"
                HorizontalAlignment="Right" VerticalAlignment="Center" ToolTip="展开"
                AutomationProperties.Name="展开"/>
      </Grid>

      <Button x:Name="MinimizeButton" Style="{StaticResource IconButton}" Content="—" FontSize="12"
              HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,9,84,0" ToolTip="收起成小条"
              AutomationProperties.Name="最小化"/>
      <Button x:Name="PinButton" Width="22" Height="22" Focusable="False" Cursor="Hand"
              HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,9,59,0" ToolTip="置顶显示"
              AutomationProperties.Name="置顶">
        <Button.Template>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bg" CornerRadius="11" Background="Transparent">
              <TextBlock x:Name="Glyph" Text="顶" FontSize="11"
                         Foreground="{DynamicResource TextIcon}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bg" Property="Background" Value="#33FFFFFF"/>
                <Setter TargetName="Glyph" Property="Foreground" Value="#FFFFFFFF"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bg" Property="Background" Value="#4DFFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Button.Template>
      </Button>
      <Button x:Name="SettingsButton" Style="{StaticResource IconButton}" Content="⚙"
              HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,9,34,0" ToolTip="设置"/>
      <Button x:Name="CloseButton" Style="{StaticResource IconButton}" Content="✕"
              HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,9,9,0"
              ToolTip="隐藏（任务栏快捷方式或托盘图标可再打开）"/>
    </Grid>
  </Border>
</Window>
'@

# ============================================================ 构建窗口 =====
function New-Widget {
    $window = [Windows.Markup.XamlReader]::Parse($script:Xaml)

    $script:Window = $window
    $script:UI = @{}
    foreach ($name in 'Card', 'ClockText', 'SecText', 'DateText', 'WeekText', 'WeatherIcon', 'TempText',
        'CondText', 'RangeText', 'CityLabel', 'DetailLabel', 'CpuTrack', 'CpuBar', 'CpuText',
        'MemTrack', 'MemBar', 'MemText', 'MemGbText', 'TzText', 'SourceText', 'CloseButton',
        'SettingsButton', 'MainPanel', 'SettingsPanel', 'TimeRow', 'WeatherRow', 'DividerBorder',
        'CpuRow', 'MemRow', 'FooterRow', 'EmptyHint', 'SwWeather', 'SwTime', 'SwCpu', 'SwMem',
        'SwTopmost', 'ResetButton', 'ColorPreview', 'ColorHexText', 'HueBar', 'SatValPad',
        'SvHueLayer', 'SvKnob', 'OpacityBar', 'OpacityFill', 'OpacityText', 'PinButton',
        'MinimizeButton', 'ExpandButton', 'CompactPanel', 'CompactClock', 'CompactTemp',
        'TasksRow', 'TasksSummary', 'TasksCount', 'TasksPanel', 'TasksScroll', 'TasksList', 'TasksEmpty',
        'TaskNewButton', 'TaskEditView', 'TaskSaveButton', 'TaskDeleteButton', 'TaskCancelButton',
        'EditorTitle', 'EditorDue', 'EditorRemind', 'EditorRemindAt', 'EditorError',
        'ReminderBanner', 'ReminderText', 'ReminderOk', 'SwTasks', 'SwAi',
        'AiRow', 'AiSummary', 'AiPanel', 'AiList', 'AiKeyBox', 'AiKeySave', 'AiRefresh', 'AiKeyLabel',
        'FirstRunHint') {
        $script:UI[$name] = $window.FindName($name)
    }

    # 主题画笔：换背景时改这些资源的颜色，界面上的 DynamicResource 会一起跟着变
    $script:ThemeBrushes = @{}
    foreach ($key in 'TextPrimary', 'TextSecondary', 'TextTertiary', 'TextFaint', 'TextMuted', 'TextIcon',
        'TrackBrush', 'DividerBrush', 'SwitchTrackBrush', 'SwitchThumb') {
        $brush = $window.FindResource($key)
        if ($brush) { $script:ThemeBrushes[$key] = $brush }
    }
    $script:Hsv = @{ H = 210.0; S = 0.35; V = 0.15 }

    # 透明度只作用在卡片背景上，窗口本身保持不透明（否则文字会一起变淡）
    $window.Opacity = 1.0
    $window.Topmost = [bool]$script:Config['alwaysOnTop']
    Set-AppIcon

    $script:UI['CloseButton'].Add_Click({ On-CloseClicked })
    $script:UI['SettingsButton'].Add_Click({ Toggle-Settings })
    $script:UI['PinButton'].Add_Click({ Toggle-Topmost })
    $script:UI['MinimizeButton'].Add_Click({ Collapse-Widget })
    $script:UI['ExpandButton'].Add_Click({ Expand-Widget })
    $script:UI['TasksRow'].Add_MouseLeftButtonUp({ Open-Tasks })
    $script:UI['TaskNewButton'].Add_Click({ Show-TaskEditor $null })
    $script:UI['TaskSaveButton'].Add_Click({ Save-TaskFromEditor })
    $script:UI['TaskDeleteButton'].Add_Click({ Delete-Task })
    $script:UI['TaskCancelButton'].Add_Click({ Close-TaskEditor })
    $script:UI['ReminderOk'].Add_Click({ Dismiss-Reminder })
    $script:UI['AiRow'].Add_MouseLeftButtonUp({ Open-AiPanel })
    $script:UI['AiKeySave'].Add_Click({ Save-AiKey })
    $script:UI['AiRefresh'].Add_Click({
            Update-AiAdapters -Force
            Render-AiList
        })
    $script:UI['ResetButton'].Add_MouseLeftButtonUp({ Reset-Settings })

    foreach ($switchName in 'SwWeather', 'SwTime', 'SwCpu', 'SwMem', 'SwTasks', 'SwAi', 'SwTopmost') {
        $toggle = $script:UI[$switchName]
        if (-not $toggle) { continue }
        $toggle.Add_Checked({ On-SettingToggled })
        $toggle.Add_Unchecked({ On-SettingToggled })
    }

    # 调色盘：色相条 + 饱和度/明度方块 + 不透明度条，按住拖动连续取值
    $hueBar = $script:UI['HueBar']
    $hueBar.Add_MouseLeftButtonDown({
            param($s, $e)
            $null = $s.CaptureMouse()
            Set-HueFromPoint $s ($e.GetPosition($s))
        })
    $hueBar.Add_MouseMove({
            param($s, $e)
            if ($s.IsMouseCaptured) { Set-HueFromPoint $s ($e.GetPosition($s)) }
        })
    $hueBar.Add_MouseLeftButtonUp({
            param($s, $e)
            if ($s.IsMouseCaptured) { $null = $s.ReleaseMouseCapture(); Save-Config }
        })

    $pad = $script:UI['SatValPad']
    $pad.Add_MouseLeftButtonDown({
            param($s, $e)
            $null = $s.CaptureMouse()
            Set-SvFromPoint $s ($e.GetPosition($s))
        })
    $pad.Add_MouseMove({
            param($s, $e)
            if ($s.IsMouseCaptured) { Set-SvFromPoint $s ($e.GetPosition($s)) }
        })
    $pad.Add_MouseLeftButtonUp({
            param($s, $e)
            if ($s.IsMouseCaptured) { $null = $s.ReleaseMouseCapture(); Save-Config }
        })

    $opacityBar = $script:UI['OpacityBar']
    $opacityBar.Add_MouseLeftButtonDown({
            param($s, $e)
            $null = $s.CaptureMouse()
            Set-OpacityFromPoint $s ($e.GetPosition($s))
        })
    $opacityBar.Add_MouseMove({
            param($s, $e)
            if ($s.IsMouseCaptured) { Set-OpacityFromPoint $s ($e.GetPosition($s)) }
        })
    $opacityBar.Add_MouseLeftButtonUp({
            param($s, $e)
            if ($s.IsMouseCaptured) { $null = $s.ReleaseMouseCapture(); Save-Config }
        })

    Initialize-SettingsUI

    $window.Add_Closing({
            param($s, $e)
            if (-not $script:Exiting) { $e.Cancel = $true; Hide-Widget }
        })
    $window.Add_LocationChanged({
            if ($script:Ready -and -not $script:SettingsOpen -and -not $script:CompactMode) {
                $script:Config['left'] = [int][math]::Round($script:Window.Left)
                $script:Config['top'] = [int][math]::Round($script:Window.Top)
                if (((Get-Date) - $script:LastConfigSave).TotalSeconds -gt 3) {
                    $script:LastConfigSave = Get-Date
                    Save-Config
                }
            }
        })
    # 拖动窗口：按下时只记位置，移动超过 4px 才真正拖动，
    # 否则 DragMove 会吞掉鼠标抬起事件，卡片里的可点区域（待办行等）就点不动了
    $window.Add_MouseLeftButtonDown({
            param($s, $e)
            if (-not $script:UI) { return }
            if ($script:UI['SettingsPanel'].Visibility -eq [System.Windows.Visibility]::Visible) { return }
            if ($script:UI['TasksPanel'].Visibility -eq [System.Windows.Visibility]::Visible) { return }
            $script:DragStart = $e.GetPosition($script:Window)
        })
    $window.Add_MouseMove({
            param($s, $e)
            if (-not $script:DragStart) { return }
            if ($e.LeftButton -ne [System.Windows.Input.MouseButtonState]::Pressed) { $script:DragStart = $null; return }
            $pos = $e.GetPosition($script:Window)
            $dx = [math]::Abs($pos.X - $script:DragStart.X)
            $dy = [math]::Abs($pos.Y - $script:DragStart.Y)
            if ($dx -gt 4 -or $dy -gt 4) {
                $script:DragStart = $null
                try { $script:Window.DragMove() } catch { }
            }
        })
    $window.Add_MouseLeftButtonUp({
            $script:DragStart = $null
        })
    $window.Add_MouseRightButtonUp({
            param($s, $e)
            Open-WidgetMenu
        })

    $script:Menu = New-WidgetMenu
    return $window
}

function Open-WidgetMenu {
    if (-not $script:Menu) { return }
    try {
        $script:Menu.PlacementTarget = $script:Window
        $script:Menu.Placement = [System.Windows.Controls.Primitives.PlacementMode]::MousePoint
        $script:Menu.IsOpen = $true
    } catch { Write-Log "菜单打开失败：$($_.Exception.Message)" }
}

function New-WidgetMenu {
    $menu = [System.Windows.Controls.ContextMenu]::new()
    $menu.Background = Get-Brush '#F21B2130'
    $menu.Foreground = Get-Brush '#E8EEF7'
    $menu.BorderBrush = Get-Brush '#33FFFFFF'
    $menu.FontSize = 12
    $menu.FontFamily = 'Microsoft YaHei UI'

    $addItem = {
        param([string]$Text, [scriptblock]$Action, [bool]$Checkable = $false)
        $item = [System.Windows.Controls.MenuItem]::new()
        $item.Header = $Text
        $item.FontSize = 12
        $item.IsCheckable = $Checkable
        if ($Action) { $item.Add_Click($Action) }
        $null = $menu.Items.Add($item)
        return $item
    }
    $addSeparator = { $null = $menu.Items.Add([System.Windows.Controls.Separator]::new()) }

    $null = & $addItem '刷新天气' { Invalidate-Weather }
    $null = & $addItem '重新定位' { Relocate }
    $script:TopMostItem = & $addItem '置顶显示' { Toggle-Topmost } $true
    $script:TopMostItem.IsChecked = [bool]$script:Config['alwaysOnTop']
    $null = & $addSeparator
    $null = & $addItem '调试信息' { Show-DebugInfo }
    $null = & $addItem '打开程序文件夹' { Start-Process explorer.exe $script:Root }
    $null = & $addSeparator
    $null = & $addItem '退出' { Exit-Widget }

    $menu.Add_Opened({ if ($script:TopMostItem) { $script:TopMostItem.IsChecked = $script:Window.Topmost } })
    return $menu
}

# ============================================================ 天气图标 =====
function Add-IconEllipse {
    param([double]$X, [double]$Y, [double]$W, [double]$H, $Brush)
    $e = [System.Windows.Shapes.Ellipse]::new()
    $e.Width = $W; $e.Height = $H; $e.Fill = $Brush
    [System.Windows.Controls.Canvas]::SetLeft($e, $X)
    [System.Windows.Controls.Canvas]::SetTop($e, $Y)
    $null = $script:UI['WeatherIcon'].Children.Add($e)
}

function Add-IconRect {
    param([double]$X, [double]$Y, [double]$W, [double]$H, [double]$Radius, $Brush)
    $r = [System.Windows.Shapes.Rectangle]::new()
    $r.Width = $W; $r.Height = $H; $r.Fill = $Brush
    $r.RadiusX = $Radius; $r.RadiusY = $Radius
    [System.Windows.Controls.Canvas]::SetLeft($r, $X)
    [System.Windows.Controls.Canvas]::SetTop($r, $Y)
    $null = $script:UI['WeatherIcon'].Children.Add($r)
}

function Add-IconLine {
    param([double]$X1, [double]$Y1, [double]$X2, [double]$Y2, [double]$Thickness, $Brush)
    $l = [System.Windows.Shapes.Line]::new()
    $l.X1 = $X1; $l.Y1 = $Y1; $l.X2 = $X2; $l.Y2 = $Y2
    $l.Stroke = $Brush; $l.StrokeThickness = $Thickness
    $l.StrokeStartLineCap = [System.Windows.Media.PenLineCap]::Round
    $l.StrokeEndLineCap = [System.Windows.Media.PenLineCap]::Round
    $null = $script:UI['WeatherIcon'].Children.Add($l)
}

function Draw-SunParts {
    param([double]$Cx, [double]$Cy, [double]$Radius, [double]$Thickness, $Brush, [double]$RayLength = 10.0)
    Add-IconEllipse ($Cx - $Radius) ($Cy - $Radius) ($Radius * 2) ($Radius * 2) $Brush
    $inner = $Radius + 4.5
    $outer = $Radius + $RayLength
    for ($i = 0; $i -lt 8; $i++) {
        $a = [math]::PI / 4 * $i
        Add-IconLine ($Cx + [math]::Cos($a) * $inner) ($Cy + [math]::Sin($a) * $inner) `
            ($Cx + [math]::Cos($a) * $outer) ($Cy + [math]::Sin($a) * $outer) $Thickness $Brush
    }
}

function Draw-CloudParts {
    param([double]$Dx, [double]$Dy, [double]$Scale, $Brush)
    Add-IconEllipse (5 * $Scale + $Dx) (21 * $Scale + $Dy) (21 * $Scale) (21 * $Scale) $Brush
    Add-IconEllipse (15 * $Scale + $Dx) (12 * $Scale + $Dy) (29 * $Scale) (29 * $Scale) $Brush
    Add-IconEllipse (33 * $Scale + $Dx) (22 * $Scale + $Dy) (20 * $Scale) (20 * $Scale) $Brush
    Add-IconRect (11 * $Scale + $Dx) (30 * $Scale + $Dy) (36 * $Scale) (12 * $Scale) (6 * $Scale) $Brush
}

function Draw-WeatherIcon {
    param([string]$Kind, [string]$ColorHex)

    if (-not $script:UI) { return }
    $key = "$Kind|$ColorHex"
    if ($key -eq $script:LastIconKey) { return }
    $script:LastIconKey = $key

    $canvas = $script:UI['WeatherIcon']
    $canvas.Children.Clear()
    $brush = Get-Brush $ColorHex

    switch ($Kind) {
        'sun' { Draw-SunParts 28 28 8.5 2.8 $brush 10.5 }
        'suncloud' {
            Draw-SunParts 40 16 5.0 2.0 $brush 7.5
            Draw-CloudParts 0 9 0.80 $brush
        }
        'cloud' { Draw-CloudParts 1 5 1.0 $brush }
        'fog' {
            Add-IconLine 8 22 50 22 4 $brush
            Add-IconLine 14 31 46 31 4 $brush
            Add-IconLine 20 40 40 40 4 $brush
        }
        'rain' {
            Draw-CloudParts 1 3 1.0 $brush
            $drop = Get-Brush '#6FB1E2'
            Add-IconLine 20 45 18.5 53 2.6 $drop
            Add-IconLine 30 46 28.5 54 2.6 $drop
            Add-IconLine 40 45 38.5 53 2.6 $drop
        }
        'snow' {
            Draw-CloudParts 1 3 1.0 $brush
            $flake = Get-Brush '#DCEBFF'
            Add-IconEllipse 16.5 43.5 4.6 4.6 $flake
            Add-IconEllipse 27.5 47.0 4.6 4.6 $flake
            Add-IconEllipse 38.5 43.5 4.6 4.6 $flake
        }
        'storm' {
            Draw-CloudParts 1 1 1.0 $brush
            $bolt = [System.Windows.Shapes.Polyline]::new()
            $bolt.Stroke = Get-Brush '#FFD166'
            $bolt.StrokeThickness = 2.8
            $bolt.StrokeLineJoin = [System.Windows.Media.PenLineJoin]::Round
            $points = [System.Windows.Media.PointCollection]::new()
            foreach ($pair in @(@(32, 40), @(23, 51), @(29, 51), @(25, 57))) {
                $points.Add([System.Windows.Point]::new([double]$pair[0], [double]$pair[1]))
            }
            $bolt.Points = $points
            $null = $canvas.Children.Add($bolt)
        }
        default { Draw-CloudParts 1 5 1.0 $brush }
    }
}

# ============================================================ 界面刷新 =====
function Update-Clock {
    if (-not $script:UI) { return }
    $now = Get-Date
    $script:UI['ClockText'].Text = $now.ToString('HH:mm')
    $script:UI['SecText'].Text = $now.ToString('ss')
    $script:UI['DateText'].Text = '{0}月{1}日' -f $now.Month, $now.Day
    $script:UI['WeekText'].Text = '周' + @('日', '一', '二', '三', '四', '五', '六')[[int]$now.DayOfWeek]
    if (-not $script:Weather) {
        $script:UI['TzText'].Text = Format-TzLabel ([TimeZoneInfo]::Local.BaseUtcOffset)
    }
}

function Set-BarWidth {
    param([string]$TrackName, [string]$BarName, [double]$Percent)
    if (-not $script:UI) { return }
    $track = $script:UI[$TrackName]
    $bar = $script:UI[$BarName]
    $width = $track.ActualWidth
    if ($width -le 0) { return }
    $pct = [math]::Max(0.0, [math]::Min(100.0, $Percent))
    $bar.Width = [math]::Round($width * $pct / 100.0, 1)
}

function Initialize-Counters {
    $script:UseCounters = $false
    try {
        $script:CpuCounter = New-Object System.Diagnostics.PerformanceCounter -ArgumentList 'Processor', '% Processor Time', '_Total'
        $script:MemCounter = New-Object System.Diagnostics.PerformanceCounter -ArgumentList 'Memory', 'Available MBytes'
        $null = $script:CpuCounter.NextValue()
        $null = $script:MemCounter.NextValue()
        $script:UseCounters = $true
    } catch {
        Write-Log "性能计数器不可用，改用 WMI：$($_.Exception.Message)"
        $script:CpuCounter = $null
        $script:MemCounter = $null
    }

    try {
        $totalBytes = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory
        $script:MemTotalKb = [double]$totalBytes / 1024.0
    } catch {
        $script:MemTotalKb = 0
        Write-Log "读取内存总量失败：$($_.Exception.Message)"
    }
    $script:LastWmiAt = [datetime]::MinValue
    $script:LastWmiCpu = 0
}

function Get-CpuPercent {
    if ($script:UseCounters -and $script:CpuCounter) {
        try { return [double]$script:CpuCounter.NextValue() } catch { }
    }
    if (((Get-Date) - $script:LastWmiAt).TotalMilliseconds -gt 1500) {
        $script:LastWmiAt = Get-Date
        try {
            $row = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop
            if ($row) { $script:LastWmiCpu = [double]$row.PercentProcessorTime }
        } catch { }
    }
    return [double]$script:LastWmiCpu
}

function Get-MemoryInfo {
    $availKb = $null
    if ($script:UseCounters -and $script:MemCounter) {
        try { $availKb = [double]$script:MemCounter.NextValue() * 1024.0 } catch { }
    }
    if ($null -eq $availKb) {
        try {
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            $availKb = [double]$os.FreePhysicalMemory
        } catch { return $null }
    }
    if ($script:MemTotalKb -le 0) { return $null }
    $usedKb = $script:MemTotalKb - $availKb
    return @{
        Percent = [math]::Round(100.0 * $usedKb / $script:MemTotalKb, 0)
        UsedGb  = $usedKb / 1048576.0
        TotalGb = $script:MemTotalKb / 1048576.0
    }
}

function Update-Stats {
    if (-not $script:UI) { return }

    $cpu = [math]::Round([math]::Max(0.0, [math]::Min(100.0, (Get-CpuPercent))), 0)
    $script:LastCpu = $cpu
    $script:UI['CpuText'].Text = '{0:0}%' -f $cpu
    Set-BarWidth 'CpuTrack' 'CpuBar' $cpu
    if ($cpu -ge 90) { $cpuColor = '#F0706A' } elseif ($cpu -ge 75) { $cpuColor = '#F2B461' } else { $cpuColor = '#5EA6E8' }
    $script:UI['CpuBar'].Background = Get-Brush $cpuColor

    $mem = Get-MemoryInfo
    if ($mem) {
        $script:LastMem = [double]$mem.Percent
        $script:UI['MemText'].Text = '{0:0}%' -f $mem.Percent
        $script:UI['MemGbText'].Text = '{0:0.0} / {1:0} GB' -f $mem.UsedGb, $mem.TotalGb
        Set-BarWidth 'MemTrack' 'MemBar' $mem.Percent
        if ($mem.Percent -ge 90) { $memColor = '#F0706A' } elseif ($mem.Percent -ge 80) { $memColor = '#F2B461' } else { $memColor = '#A78BFA' }
        $script:UI['MemBar'].Background = Get-Brush $memColor
    }
}

function Update-WeatherUI {
    if (-not $script:UI) { return }
    $w = $script:Weather

    if (-not $w) {
        $script:UI['TempText'].Text = '--°'
        $script:UI['RangeText'].Text = '—'
        $script:UI['CityLabel'].Text = '—'
        $script:UI['DetailLabel'].Text = ''
        switch ($script:WeatherState) {
            'locating' { $script:UI['CondText'].Text = '定位中' }
            'fetching' { $script:UI['CondText'].Text = '获取中' }
            'error' { $script:UI['CondText'].Text = '获取失败' }
            default { $script:UI['CondText'].Text = '待启动' }
        }
        $script:UI['SourceText'].Text = if ($script:WeatherError) { '稍后重试' } else { '' }
        Draw-WeatherIcon 'cloud' '#8E9EAE'
        return
    }

    $script:UI['TempText'].Text = '{0:0}°' -f $w.Temp
    $script:UI['CondText'].Text = $w.Cond.Text
    $script:UI['RangeText'].Text = '最高 {0:0}°　最低 {1:0}°' -f $w.Hi, $w.Lo
    $script:UI['CityLabel'].Text = $w.City

    $detail = ''
    if ($null -ne $w.Feels) { $detail += (' · 体感 {0:0}°' -f [double]$w.Feels) }
    if ($null -ne $w.Hum) { $detail += (' · 湿度 {0:0}%' -f [double]$w.Hum) }
    $script:UI['DetailLabel'].Text = $detail

    $stamp = $w.UpdatedAt.ToString('HH:mm')
    if ($w.FromCache) { $script:UI['SourceText'].Text = "缓存 · $stamp" }
    else { $script:UI['SourceText'].Text = "$($w.Source) · $stamp" }

    $localOffset = [TimeZoneInfo]::Local.BaseUtcOffset
    if ($null -ne $w.UtcOffsetSeconds) {
        $diff = [math]::Abs([double]$w.UtcOffsetSeconds - $localOffset.TotalSeconds)
        if ($diff -gt 60) {
            $placeTime = [datetime]::UtcNow.AddSeconds([double]$w.UtcOffsetSeconds).ToString('HH:mm')
            $zone = Format-TzLabel ([TimeSpan]::FromSeconds([double]$w.UtcOffsetSeconds))
            $script:UI['TzText'].Text = "当地 $placeTime · $zone"
        } else {
            $script:UI['TzText'].Text = Format-TzLabel $localOffset
        }
    } else {
        $script:UI['TzText'].Text = Format-TzLabel $localOffset
    }

    Draw-WeatherIcon $w.Cond.Kind $w.Cond.Color
}

# ============================================================ 网络请求 =====
function Start-HttpRequest {
    param([string]$Kind, [string]$Url, [string]$Provider = '')
    foreach ($queued in $script:Queue) { if ($queued.Url -eq $Url) { return } }
    if ($script:Net -and $script:Net.Url -eq $Url) { return }
    $script:Queue.Enqueue(@{ Kind = $Kind; Url = $Url; Provider = $Provider })
    Start-NextHttpRequest
}

function Start-NextHttpRequest {
    if ($script:Net -or $script:Queue.Count -eq 0) { return }
    $item = $script:Queue.Dequeue()
    try {
        $task = $script:Http.GetStringAsync($item.Url)
    } catch {
        Write-Log "发起请求失败($($item.Kind))：$($_.Exception.Message)"
        Set-WeatherError '网络请求失败'
        return
    }
    $script:Net = @{ Kind = $item.Kind; Url = $item.Url; Provider = $item.Provider; Task = $task; Deadline = (Get-Date).AddSeconds(20) }
}

function Set-WeatherError {
    param([string]$Message)
    $script:WeatherError = $Message
    if (-not $script:Weather) { $script:WeatherState = 'error' }
    Write-Log "天气异常：$Message"
}

function Receive-HttpResponse {
    $net = $script:Net
    if (-not $net) { return }

    if ($net.Task.IsCompleted) {
        $script:Net = $null
        try {
            $body = $net.Task.Result
            Handle-HttpResult -Kind $net.Kind -Body $body -Provider $net.Provider
            $script:WeatherError = ''
        } catch {
            $msg = $_.Exception.GetBaseException().Message
            Write-Log "请求出错($($net.Kind))：$msg"
            Set-WeatherError $msg
            if ($net.Kind -eq 'forecast') {
                Advance-WeatherProvider
            } elseif ($net.Kind -eq 'ip') {
                Advance-IpProvider
            } else {
                $script:NextWeatherAt = (Get-Date).AddSeconds(60)
            }
        }
        Start-NextHttpRequest
        return
    }

    if ((Get-Date) -gt $net.Deadline) {
        $script:Net = $null
        try { $net.Task.Dispose() } catch { }
        Write-Log "请求超时($($net.Kind)) $($net.Url)"
        Set-WeatherError '网络超时'
        if ($net.Kind -eq 'forecast') {
            Advance-WeatherProvider
        } elseif ($net.Kind -eq 'ip') {
            Advance-IpProvider
        } else {
            $script:NextWeatherAt = (Get-Date).AddSeconds(60)
        }
        Start-NextHttpRequest
    }
}

function Handle-HttpResult {
    param([string]$Kind, [string]$Body, [string]$Provider = '')

    switch ($Kind) {
        'forecast' {
            if ($Provider -eq 'wttr.in') { Parse-WttrForecast -Body $Body }
            else { Parse-OpenMeteoForecast -Body $Body }
        }
        'ip' {
            $j = $Body | ConvertFrom-Json
            $lat = $null; $lon = $null; $city = ''; $tz = ''
            if ($j.status -eq 'success' -and $null -ne $j.lat) {
                $lat = [double]$j.lat; $lon = [double]$j.lon; $city = [string]$j.city; $tz = [string]$j.timezone
            } elseif ($j.loc -match '^(-?[\d.]+),(-?[\d.]+)$') {
                $lat = [double]$matches[1]; $lon = [double]$matches[2]; $city = [string]$j.city; $tz = [string]$j.timezone
            } elseif ($j.success -and $null -ne $j.latitude) {
                $lat = [double]$j.latitude; $lon = [double]$j.longitude; $city = [string]$j.city; $tz = [string]$j.timezone.id
            }
            if ($null -eq $lat) { throw 'IP 定位没有返回坐标' }
            Apply-Location -Lat $lat -Lon $lon -City ($city -replace '\s+', ' ').Trim() -Source 'ip'
            Set-LocationTimeZone $tz
        }
        'geo-city' {
            $j = $Body | ConvertFrom-Json
            if (-not $j.results -or $j.results.Count -eq 0) { throw ('找不到城市：' + $script:Config['city']) }
            $r = $j.results[0]
            Apply-Location -Lat ([double]$r.latitude) -Lon ([double]$r.longitude) -City ([string]$r.name) -Source 'config'
            Set-LocationTimeZone ([string]$r.timezone)
        }
        'reverse' {
            $j = $Body | ConvertFrom-Json
            $city = [string]$j.city
            if (-not $city) { $city = [string]$j.locality }
            if (-not $city) { $city = [string]$j.principalSubdivision }
            if ($city) {
                $script:Location.City = $city
                $script:Config['city'] = $city
                Save-Config
                Update-WeatherUI
            }
        }
    }
}

function Set-WeatherModel {
    param(
        [double]$Temp, $Feels, $Hum, [double]$Hi, [double]$Lo,
        [int]$Code, [string]$Scale, [string]$Source, $UtcOffsetSeconds
    )
    $cond = Get-Condition -Code $Code -Scale $Scale
    $cityName = $script:Location.City
    if (-not $cityName) { $cityName = '本地' }

    if ($null -eq $UtcOffsetSeconds) { $UtcOffsetSeconds = $script:Location.UtcOffsetSeconds }

    $script:Weather = @{
        Temp             = $Temp
        Feels            = $Feels
        Hum              = $Hum
        Hi               = $Hi
        Lo               = $Lo
        Cond             = $cond
        City             = $cityName
        Source           = $Source
        UtcOffsetSeconds = $UtcOffsetSeconds
        UpdatedAt        = Get-Date
        FromCache        = $false
    }
    $script:WeatherState = 'ok'
    $script:WeatherError = ''

    $script:Config['weatherProvider'] = $Source
    $minutes = [int]$script:Config['weatherRefreshMinutes']
    if ($minutes -lt 1) { $minutes = 10 }
    $script:NextWeatherAt = (Get-Date).AddMinutes($minutes)

    $cache = @{
        savedAt          = (Get-Date).ToString('o')
        temp             = $script:Weather.Temp
        feels            = $script:Weather.Feels
        hum              = $script:Weather.Hum
        hi               = $script:Weather.Hi
        lo               = $script:Weather.Lo
        condText         = $cond.Text
        condKind         = $cond.Kind
        condColor        = $cond.Color
        city             = $script:Weather.City
        source           = $Source
        utcOffsetSeconds = $UtcOffsetSeconds
    }
    Write-JsonFile $script:CachePath $cache
    Save-Config
    Write-Log ("天气更新[{0}]：{1}° {2} {3}" -f $Source, $Temp, $cond.Text, $cityName)
    Update-WeatherUI
}

function Parse-WttrForecast {
    param([string]$Body)
    $j = $Body | ConvertFrom-Json
    $cc = $j.current_condition[0]
    if (-not $cc) { throw 'wttr 响应缺少 current_condition' }
    $day = $j.weather[0]

    $temp = [double]$cc.temp_C
    $feels = $null
    if ($null -ne $cc.FeelsLikeC) { $feels = [double]$cc.FeelsLikeC }
    $hum = $null
    if ($null -ne $cc.humidity) { $hum = [double]$cc.humidity }
    $hi = $temp; $lo = $temp
    if ($day) {
        if ($null -ne $day.maxtempC) { $hi = [double]$day.maxtempC }
        if ($null -ne $day.mintempC) { $lo = [double]$day.mintempC }
    }
    if (-not $script:Location.City -and $j.nearest_area) {
        $area = [string]$j.nearest_area[0].areaName[0].value
        if ($area) { $script:Location.City = $area }
    }
    Set-WeatherModel -Temp $temp -Feels $feels -Hum $hum -Hi $hi -Lo $lo `
        -Code ([int]$cc.weatherCode) -Scale 'wwo' -Source 'wttr.in'
}

function Parse-OpenMeteoForecast {
    param([string]$Body)
    $j = $Body | ConvertFrom-Json
    if (-not $j.current) { throw 'Open-Meteo 响应缺少 current' }
    $cur = $j.current
    $daily = $j.daily

    $temp = [double]$cur.temperature_2m
    $feels = $null
    if ($null -ne $cur.apparent_temperature) { $feels = [double]$cur.apparent_temperature }
    $hum = $null
    if ($null -ne $cur.relative_humidity_2m) { $hum = [double]$cur.relative_humidity_2m }
    $hi = $temp; $lo = $temp
    if ($daily -and $daily.temperature_2m_max) { $hi = [double]$daily.temperature_2m_max[0] }
    if ($daily -and $daily.temperature_2m_min) { $lo = [double]$daily.temperature_2m_min[0] }

    $offset = $null
    if ($null -ne $j.utc_offset_seconds) { $offset = [double]$j.utc_offset_seconds }

    Set-WeatherModel -Temp $temp -Feels $feels -Hum $hum -Hi $hi -Lo $lo `
        -Code ([int]$cur.weather_code) -Scale 'wmo' -Source 'open-meteo' -UtcOffsetSeconds $offset
}

function Start-ForecastRequest {
    if ($null -eq $script:Location.Lat) { return }
    if ($script:Net) { return }

    $provider = $script:Providers[$script:ProviderIndex]
    $lat = Format-Invariant ([double]$script:Location.Lat)
    $lon = Format-Invariant ([double]$script:Location.Lon)

    if ($provider -eq 'wttr.in') {
        $url = "https://wttr.in/$lat,$lon`?format=j1&lang=zh"
    } else {
        $url = "https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon" +
        '&current=temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m' +
        '&daily=weather_code,temperature_2m_max,temperature_2m_min&timezone=auto&forecast_days=3'
    }
    $script:WeatherState = 'fetching'
    Start-HttpRequest -Kind 'forecast' -Url $url -Provider $provider
}

function Advance-WeatherProvider {
    if ($script:ProviderIndex -lt ($script:Providers.Count - 1)) {
        $script:ProviderIndex++
        Write-Log ('天气源切换到 ' + $script:Providers[$script:ProviderIndex])
        $script:WeatherError = ''
        $script:NextWeatherAt = (Get-Date).AddSeconds(-1)
        Start-ForecastRequest
        return
    }
    $script:ProviderIndex = 0
    $script:NextWeatherAt = (Get-Date).AddSeconds(60)
}

function Advance-IpProvider {
    if ($script:IpIndex -lt ($script:IpEndpoints.Count - 1)) {
        $script:IpIndex++
        Write-Log ('IP 定位切换到 ' + $script:IpEndpoints[$script:IpIndex].Name)
        Start-IpLocation
        return
    }
    Start-NextLocationStep
}

# ============================================================ 定位 =========
# .NET Framework 只认 Windows 时区 ID，IANA 名字（Asia/Shanghai）要先翻译
$script:TzAliases = @{
    'Asia/Shanghai'              = 'China Standard Time'
    'Asia/Chongqing'             = 'China Standard Time'
    'Asia/Harbin'                = 'China Standard Time'
    'Asia/Urumqi'                = 'Central Asia Standard Time'
    'Asia/Hong_Kong'             = 'China Standard Time'
    'Asia/Macau'                 = 'China Standard Time'
    'Asia/Taipei'                = 'Taipei Standard Time'
    'Asia/Tokyo'                 = 'Tokyo Standard Time'
    'Asia/Seoul'                 = 'Korea Standard Time'
    'Asia/Singapore'             = 'Singapore Standard Time'
    'Asia/Kuala_Lumpur'          = 'Singapore Standard Time'
    'Asia/Manila'                = 'Singapore Standard Time'
    'Asia/Bangkok'               = 'SE Asia Standard Time'
    'Asia/Ho_Chi_Minh'           = 'SE Asia Standard Time'
    'Asia/Jakarta'               = 'SE Asia Standard Time'
    'Asia/Kolkata'               = 'India Standard Time'
    'Asia/Calcutta'              = 'India Standard Time'
    'Asia/Karachi'               = 'Pakistan Standard Time'
    'Asia/Dhaka'                 = 'Bangladesh Standard Time'
    'Asia/Kathmandu'             = 'Nepal Standard Time'
    'Asia/Dubai'                 = 'Arabian Standard Time'
    'Asia/Riyadh'                = 'Arab Standard Time'
    'Asia/Tehran'                = 'Iran Standard Time'
    'Asia/Vladivostok'           = 'Vladivostok Standard Time'
    'Asia/Yekaterinburg'         = 'Ekaterinburg Standard Time'
    'Asia/Novosibirsk'           = 'N. Central Asia Standard Time'
    'Europe/London'              = 'GMT Standard Time'
    'Europe/Dublin'              = 'GMT Standard Time'
    'Europe/Lisbon'              = 'GMT Standard Time'
    'Europe/Paris'               = 'Romance Standard Time'
    'Europe/Brussels'            = 'Romance Standard Time'
    'Europe/Madrid'              = 'Romance Standard Time'
    'Europe/Berlin'              = 'W. Europe Standard Time'
    'Europe/Amsterdam'           = 'W. Europe Standard Time'
    'Europe/Rome'                = 'W. Europe Standard Time'
    'Europe/Zurich'              = 'W. Europe Standard Time'
    'Europe/Vienna'              = 'W. Europe Standard Time'
    'Europe/Stockholm'           = 'W. Europe Standard Time'
    'Europe/Oslo'                = 'W. Europe Standard Time'
    'Europe/Copenhagen'          = 'W. Europe Standard Time'
    'Europe/Prague'              = 'Central Europe Standard Time'
    'Europe/Warsaw'              = 'Central European Standard Time'
    'Europe/Budapest'            = 'Central Europe Standard Time'
    'Europe/Athens'              = 'GTB Standard Time'
    'Europe/Bucharest'           = 'GTB Standard Time'
    'Europe/Helsinki'            = 'FLE Standard Time'
    'Europe/Kiev'                = 'FLE Standard Time'
    'Europe/Istanbul'            = 'Turkey Standard Time'
    'Europe/Moscow'              = 'Russian Standard Time'
    'America/New_York'           = 'Eastern Standard Time'
    'America/Toronto'            = 'Eastern Standard Time'
    'America/Chicago'            = 'Central Standard Time'
    'America/Denver'             = 'Mountain Standard Time'
    'America/Phoenix'            = 'US Mountain Standard Time'
    'America/Los_Angeles'        = 'Pacific Standard Time'
    'America/Vancouver'          = 'Pacific Standard Time'
    'America/Anchorage'          = 'Alaskan Standard Time'
    'America/Mexico_City'        = 'Central Standard Time (Mexico)'
    'America/Sao_Paulo'          = 'E. South America Standard Time'
    'America/Argentina/Buenos_Aires' = 'Argentina Standard Time'
    'America/Bogota'             = 'SA Pacific Standard Time'
    'America/Lima'               = 'SA Pacific Standard Time'
    'America/Santiago'           = 'Pacific SA Standard Time'
    'Australia/Sydney'           = 'AUS Eastern Standard Time'
    'Australia/Melbourne'        = 'AUS Eastern Standard Time'
    'Australia/Brisbane'         = 'E. Australia Standard Time'
    'Australia/Adelaide'         = 'Cen. Australia Standard Time'
    'Australia/Perth'            = 'W. Australia Standard Time'
    'Pacific/Auckland'           = 'New Zealand Standard Time'
    'Pacific/Honolulu'           = 'Hawaiian Standard Time'
    'Africa/Cairo'               = 'Egypt Standard Time'
    'Africa/Johannesburg'        = 'South Africa Standard Time'
    'Africa/Lagos'               = 'W. Central Africa Standard Time'
    'Africa/Nairobi'             = 'E. Africa Standard Time'
    'Atlantic/Reykjavik'         = 'Greenwich Standard Time'
    'Etc/UTC'                    = 'UTC'
    'Etc/GMT'                    = 'UTC'
    'UTC'                        = 'UTC'
}

function Set-LocationTimeZone {
    param([string]$TimeZoneId)

    if ($TimeZoneId) {
        $windowsId = $TimeZoneId
        if ($script:TzAliases.ContainsKey($TimeZoneId)) { $windowsId = $script:TzAliases[$TimeZoneId] }
        try {
            $tz = [TimeZoneInfo]::FindSystemTimeZoneById($windowsId)
            $script:Location.TimeZone = $TimeZoneId
            $script:Location.UtcOffsetSeconds = $tz.GetUtcOffset([datetime]::UtcNow).TotalSeconds
            return
        } catch {
            $script:Location.TimeZone = $TimeZoneId
        }
    }

    # 认不出来的时区：按经度粗估（每 15 度一个小时），总比不显示好
    if ($null -ne $script:Location.Lon) {
        $hours = [math]::Round([double]$script:Location.Lon / 15.0, 0, [MidpointRounding]::AwayFromZero)
        $script:Location.UtcOffsetSeconds = $hours * 3600
    }
}

function Get-DistanceKm {
    param([double]$Lat1, [double]$Lon1, [double]$Lat2, [double]$Lon2)
    $dLat = ($Lat1 - $Lat2) * 111.0
    $dLon = ($Lon1 - $Lon2) * 111.0 * [math]::Cos($Lat1 * [math]::PI / 180)
    return [math]::Sqrt($dLat * $dLat + $dLon * $dLon)
}

function Get-SourcePriority {
    param([string]$Source)
    switch ($Source) {
        'device' { return 3 }
        'ip' { return 2 }
        'config' { return 1 }
        default { return 0 }
    }
}

function Apply-Location {
    param([double]$Lat, [double]$Lon, [string]$City, [string]$Source)

    # 精度高的来源优先：已经拿到设备坐标，就别被 IP 定位覆盖回去
    if ($null -ne $script:Location.Lat -and
        (Get-SourcePriority $Source) -lt (Get-SourcePriority $script:Location.Source)) {
        if ($City -and (-not $script:Location.City -or $script:Location.City -eq '本地')) {
            $script:Location.City = $City
            $script:Config['city'] = $City
            Save-Config
            Write-Log ("补充城市名：$City")
            Update-WeatherUI
        }
        return
    }

    $moved = $true
    if ($null -ne $script:Location.Lat -and $null -ne $script:Location.Lon) {
        if ((Get-DistanceKm $script:Location.Lat $script:Location.Lon $Lat $Lon) -lt 2.0) { $moved = $false }
    }

    $script:Location.Lat = $Lat
    $script:Location.Lon = $Lon
    $script:Location.Source = $Source
    if ($City) { $script:Location.City = $City }
    if (-not $script:Location.City) { $script:Location.City = '本地' }

    Write-Log ("定位成功[{0}]：{1}, {2} {3}" -f $Source, $Lat, $Lon, $script:Location.City)

    $script:Config['latitude'] = [math]::Round($Lat, 5)
    $script:Config['longitude'] = [math]::Round($Lon, 5)
    $script:Config['city'] = $script:Location.City
    $script:Config['locatedBy'] = $Source
    $script:Config['locatedAt'] = (Get-Date).ToString('o')
    Save-Config

    if ($moved -or -not $script:Weather) {
        $script:WeatherState = 'fetching'
        $script:NextWeatherAt = (Get-Date).AddSeconds(-1)
        Start-ForecastRequest
    }
    Update-WeatherUI
}

function Start-IpLocation {
    $endpoint = $script:IpEndpoints[$script:IpIndex]
    Write-Log ('IP 定位：' + $endpoint.Name)
    Start-HttpRequest -Kind 'ip' -Url $endpoint.Url
}

function Start-NextLocationStep {
    if ($script:Config['city']) {
        $name = [uri]::EscapeDataString([string]$script:Config['city'])
        $url = "https://geocoding-api.open-meteo.com/v1/search?name=$name&count=1&language=zh&format=json"
        Start-HttpRequest -Kind 'geo-city' -Url $url
        return
    }
    Write-Log '定位全部失败：没有可用坐标'
    Set-WeatherError '定位失败'
    $script:WeatherState = 'error'
    $script:NextWeatherAt = (Get-Date).AddMinutes(5)
}

function Convert-ToTask {
    param($Operation, [Type]$ResultType)
    if (-not $script:AsTaskMethod) {
        $script:AsTaskMethod = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
                $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
                $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
            })[0]
    }
    return $script:AsTaskMethod.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
}

function Start-DeviceLocation {
    if ($script:GeoStage -eq 'position' -or $script:GeoStage -eq 'done') { return }
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
        $null = [Windows.Devices.Geolocation.Geolocator, Windows.Devices.Geolocation, ContentType = WindowsRuntime]
        $script:GeoLocator = New-Object Windows.Devices.Geolocation.Geolocator
        $script:GeoLocator.DesiredAccuracyInMeters = 1000

        $posType = [Windows.Devices.Geolocation.Geoposition, Windows.Devices.Geolocation, ContentType = WindowsRuntime]
        try {
            $operation = $script:GeoLocator.GetGeopositionAsync([TimeSpan]::FromMinutes(5), [TimeSpan]::FromSeconds(8))
        } catch {
            $operation = $script:GeoLocator.GetGeopositionAsync()
        }
        $script:GeoTask = Convert-ToTask -Operation $operation -ResultType $posType
        $script:GeoStage = 'position'
        $script:GeoDeadline = (Get-Date).AddSeconds(10)
        Write-Log '设备定位：请求坐标'
    } catch {
        $script:GeoStage = 'failed'
        Write-Log "设备定位不可用：$($_.Exception.Message)"
    }
}

function Poll-Location {
    if ($script:GeoStage -ne 'position') { return }

    if ($script:GeoTask.IsCompleted) {
        $script:GeoStage = 'done'
        try {
            $coordinate = $script:GeoTask.Result.Coordinate
            $lat = [double]$coordinate.Point.Position.Latitude
            $lon = [double]$coordinate.Point.Position.Longitude
            Write-Log ("设备定位成功：{0}, {1}" -f $lat, $lon)
            Apply-Location -Lat $lat -Lon $lon -City '' -Source 'device'
            # 设备定位拿不到时区，按经度估一个，用于判断「当地时间和本机不一样」
            if ($null -eq $script:Location.UtcOffsetSeconds) { Set-LocationTimeZone '' }
            if (-not $script:Location.City -or $script:Location.City -eq '本地') {
                $revUrl = 'https://api.bigdatacloud.net/data/reverse-geocode-client?latitude=' +
                (Format-Invariant $lat) + '&longitude=' + (Format-Invariant $lon) + '&localityLanguage=zh'
                Start-HttpRequest -Kind 'reverse' -Url $revUrl
            }
        } catch {
            Write-Log "设备定位取坐标失败：$($_.Exception.Message)"
        }
        return
    }

    if ((Get-Date) -gt $script:GeoDeadline) {
        $script:GeoStage = 'failed'
        Write-Log '设备定位超时，沿用 IP 定位'
    }
}

function Start-Location {
    $script:GeoStage = ''
    $script:GeoTask = $null
    $script:IpIndex = 0
    if ($script:Location.Lat) {
        Start-ForecastRequest
    } else {
        $script:WeatherState = 'locating'
        Start-IpLocation
    }
    Start-DeviceLocation
}

# ============================================================ 主循环 =======
function Update-Tick {
    Update-Clock
    Update-Stats
    if ($script:CompactMode) { Update-CompactPanel }
    Update-TasksUI
    Update-AiAdapters
    Check-Reminders
    Poll-Location
    Receive-HttpResponse

    # 第二个实例（例如任务栏上固定的快捷方式）请求把窗口叫出来
    if ($script:ShowEvent) {
        try {
            if ($script:ShowEvent.WaitOne(0)) { Show-Widget }
        } catch { $script:ShowEvent = $null }
    }

    if (-not $script:Net -and $script:Location.Lat -and (Get-Date) -ge $script:NextWeatherAt) {
        Start-ForecastRequest
    }
    Update-WeatherUI
}

# ============================================================ 调试/退出 ====
function Show-DebugInfo {
    $lines = @()
    $lines += "位置来源：$($script:Location.Source)"
    $lines += "坐标：$($script:Location.Lat), $($script:Location.Lon)"
    $lines += "城市：$($script:Location.City)"
    if ($null -ne $script:Location.UtcOffsetSeconds) {
        $lines += "位置时区：$($script:Location.TimeZone) $(Format-TzLabel ([TimeSpan]::FromSeconds($script:Location.UtcOffsetSeconds)))"
    }
    $lines += "天气状态：$($script:WeatherState)   数据源：$($script:Providers[$script:ProviderIndex])"
    if ($script:Weather) {
        $lines += "天气：$($script:Weather.Temp)° $($script:Weather.Cond.Text)  更新：$($script:Weather.UpdatedAt.ToString('HH:mm:ss'))"
    }
    if ($script:WeatherError) { $lines += "最近错误：$($script:WeatherError)" }
    $lines += "CPU：$($script:LastCpu)%   内存：$($script:LastMem)%"
    $lines += "本机时区：$(Format-TzLabel ([TimeZoneInfo]::Local.BaseUtcOffset))"
    $lines += "日志：$($script:LogPath)"
    [System.Windows.MessageBox]::Show(($lines -join "`r`n"), '桌面小组件 · 调试信息') | Out-Null
}

function Exit-Widget {
    $script:Exiting = $true
    try {
        $script:Config['left'] = [int][math]::Round($script:Window.Left)
        $script:Config['top'] = [int][math]::Round($script:Window.Top)
        Save-Config
    } catch { }
    try {
        if ($script:Tray) { $script:Tray.Visible = $false; $script:Tray.Dispose() }
    } catch { }
    try { [System.Windows.Application]::Current.Shutdown() } catch { }
}

function Invalidate-Weather {
    $script:NextWeatherAt = (Get-Date).AddSeconds(-1)
    $script:WeatherError = ''
    $script:ProviderIndex = 0
    if ($script:Location.Lat) {
        Start-ForecastRequest
    } else {
        Start-Location
    }
    Write-Log '手动刷新天气'
}

function Relocate {
    $script:Location.Lat = $null
    $script:Location.Lon = $null
    $script:Location.City = ''
    $script:Location.Source = ''
    $script:WeatherState = 'locating'
    Start-Location
    Write-Log '手动重新定位'
}

# ============================================================ 托盘/显示 =====
function New-AppIconBitmap {
    param([int]$Size = 32)
    $bitmap = [System.Drawing.Bitmap]::new($Size, $Size)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.Color]::Transparent)

    $k = $Size / 32.0
    $sunBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 255, 198, 92))
    $cloudBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 214, 226, 240))
    $graphics.FillEllipse($sunBrush, [single](17 * $k), [single](3 * $k), [single](11 * $k), [single](11 * $k))
    $graphics.FillEllipse($cloudBrush, [single](4 * $k), [single](12 * $k), [single](11 * $k), [single](11 * $k))
    $graphics.FillEllipse($cloudBrush, [single](9 * $k), [single](8 * $k), [single](16 * $k), [single](16 * $k))
    $graphics.FillEllipse($cloudBrush, [single](18 * $k), [single](12 * $k), [single](10 * $k), [single](10 * $k))
    $graphics.FillRectangle($cloudBrush, [single](8 * $k), [single](16 * $k), [single](20 * $k), [single](8 * $k))
    $graphics.Dispose()

    $script:AppIconBitmap = $bitmap
    return $bitmap
}

function Set-AppIcon {
    try {
        $bitmap = New-AppIconBitmap
        $script:AppIconHIcon = $bitmap.GetHicon()
        $source = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
            $script:AppIconHIcon,
            [System.Windows.Int32Rect]::new(0, 0, 32, 32),
            [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
        $source.Freeze()
        $script:Window.Icon = $source
    } catch {
        Write-Log "设置窗口图标失败：$($_.Exception.Message)"
    }
}

function New-TrayIcon {
    $bitmap = New-AppIconBitmap
    $script:TrayHIcon = $bitmap.GetHicon()
    return [System.Drawing.Icon]::FromHandle($script:TrayHIcon)
}

function Initialize-Tray {
    try {
        $script:Tray = [System.Windows.Forms.NotifyIcon]::new()
        $script:Tray.Icon = New-TrayIcon
        $script:Tray.Text = '桌面小组件 · 天气/时间/CPU/内存'

        $trayMenu = [System.Windows.Forms.ContextMenuStrip]::new()
        $showItem = $trayMenu.Items.Add('显示 / 隐藏')
        $showItem.Add_Click({ Toggle-Visibility })
        $refreshItem = $trayMenu.Items.Add('刷新天气')
        $refreshItem.Add_Click({ Invalidate-Weather })
        $null = $trayMenu.Items.Add('-')
        $exitItem = $trayMenu.Items.Add('退出')
        $exitItem.Add_Click({ Exit-Widget })

        $script:Tray.ContextMenuStrip = $trayMenu
        $script:Tray.Add_MouseDoubleClick({ Toggle-Visibility })
        $script:Tray.Visible = $true
    } catch {
        Write-Log "托盘初始化失败：$($_.Exception.Message)"
    }
}

# 生成 .ico（任务栏快捷方式用）：手写 32 位 BGRA，保住透明通道
function New-IconImageData {
    param($Bitmap)
    $w = $Bitmap.Width
    $h = $Bitmap.Height
    $maskStride = [int]([math]::Floor(($w + 31) / 32) * 4)
    $maskBytes = $maskStride * $h
    $imageSize = $w * $h * 4 + $maskBytes

    $stream = [IO.MemoryStream]::new()
    $writer = [IO.BinaryWriter]::new($stream)
    $writer.Write([int]40)          # biSize
    $writer.Write([int]$w)          # biWidth
    $writer.Write([int]($h * 2))    # biHeight（XOR + AND）
    $writer.Write([int16]1)         # biPlanes
    $writer.Write([int16]32)        # biBitCount
    $writer.Write([int]0)           # biCompression
    $writer.Write([int]$imageSize)  # biSizeImage
    $writer.Write([int]0)
    $writer.Write([int]0)
    $writer.Write([int]0)
    $writer.Write([int]0)

    # 像素：自下而上、BGRA
    for ($y = $h - 1; $y -ge 0; $y--) {
        for ($x = 0; $x -lt $w; $x++) {
            $c = $Bitmap.GetPixel($x, $y)
            $writer.Write([byte]$c.B)
            $writer.Write([byte]$c.G)
            $writer.Write([byte]$c.R)
            $writer.Write([byte]$c.A)
        }
    }
    $writer.Write([byte[]]::new($maskBytes))   # AND 掩码全 0，透明交给 alpha
    $writer.Flush()
    $bytes = [byte[]]$stream.ToArray()
    $writer.Dispose()
    $stream.Dispose()
    return , $bytes
}

function Save-AppIcon {
    param([string]$Path)

    $sizes = @(32, 64)
    $items = @()
    foreach ($s in $sizes) {
        $bitmap = New-AppIconBitmap -Size $s
        $items += , [pscustomobject]@{ Size = $s; Bytes = (New-IconImageData -Bitmap $bitmap) }
        $bitmap.Dispose()
    }

    $out = New-Object 'System.Collections.Generic.List[byte]'
    $out.AddRange([byte[]]@(0, 0, 1, 0, [byte]$sizes.Count, 0))

    $offset = 6 + 16 * $sizes.Count
    foreach ($item in $items) {
        $len = $item.Bytes.Length
        $out.AddRange([byte[]]@(
                [byte]$item.Size, [byte]$item.Size, 0, 0,
                1, 0, 32, 0,
                [byte]($len -band 0xFF), [byte](($len -shr 8) -band 0xFF),
                [byte](($len -shr 16) -band 0xFF), [byte](($len -shr 24) -band 0xFF),
                [byte]($offset -band 0xFF), [byte](($offset -shr 8) -band 0xFF),
                [byte](($offset -shr 16) -band 0xFF), [byte](($offset -shr 24) -band 0xFF)
            ))
        $offset += $len
    }
    foreach ($item in $items) { $out.AddRange($item.Bytes) }

    [IO.File]::WriteAllBytes($Path, $out.ToArray())
}

# 在桌面生成「桌面小组件」快捷方式，拖到任务栏即可固定
function New-TaskbarShortcut {
    $iconPath = Join-Path $script:Root 'widget.ico'
    Save-AppIcon -Path $iconPath

    $launcher = Join-Path $script:Root '启动小组件.vbs'
    $desktop = [Environment]::GetFolderPath('Desktop')
    $shortcutPath = Join-Path $desktop '桌面小组件.lnk'

    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($shortcutPath)
    $link.TargetPath = "$env:WINDIR\System32\wscript.exe"
    $link.Arguments = '"' + $launcher + '"'
    $link.WorkingDirectory = $script:Root
    $link.IconLocation = "$iconPath,0"
    $link.Description = '桌面小组件 · 天气/时间/CPU/内存'
    $link.Save()

    Write-Host ''
    Write-Host '已在桌面生成：桌面小组件.lnk'
    Write-Host ('图标：' + $iconPath)
    Write-Host ''
    Write-Host '固定到任务栏（任选一种）：'
    Write-Host '  1) 把桌面上的「桌面小组件」快捷方式直接拖到任务栏上；'
    Write-Host '  2) 右键它 → 显示更多选项 → 固定到任务栏。'
    Write-Host ''
    Write-Host '固定好以后：点这个图标会唤醒已经在跑的小组件；没在跑就启动它。'
}

# ============================================================ 设置页 =======
function Set-ElementVisible {
    param([string]$Name, [bool]$Visible)
    $element = $script:UI[$Name]
    if (-not $element) { return }
    if ($Visible) { $element.Visibility = [System.Windows.Visibility]::Visible }
    else { $element.Visibility = [System.Windows.Visibility]::Collapsed }
}

function Apply-ModuleVisibility {
    if (-not $script:UI) { return }
    $showTime = [bool]$script:Config['showTime']
    $showWeather = [bool]$script:Config['showWeather']
    $showCpu = [bool]$script:Config['showCpu']
    $showMem = [bool]$script:Config['showMem']

    Set-ElementVisible 'TimeRow' $showTime
    Set-ElementVisible 'WeatherRow' $showWeather
    Set-ElementVisible 'CpuRow' $showCpu
    Set-ElementVisible 'MemRow' $showMem
    Set-ElementVisible 'DividerBorder' ($showCpu -or $showMem)
    Set-ElementVisible 'FooterRow' ($showWeather -or $showTime)
    Set-ElementVisible 'TasksRow' ([bool]$script:Config['showTasks'])
    Set-ElementVisible 'AiRow' ([bool]$script:Config['showAi'])
    Set-ElementVisible 'EmptyHint' (-not ($showTime -or $showWeather -or $showCpu -or $showMem -or $script:Config['showTasks']))
}

function Get-ShadeColor {
    param([string]$Hex, [double]$Factor, [byte]$Alpha)
    $color = [System.Windows.Media.ColorConverter]::ConvertFromString($Hex)
    $r = [byte][math]::Max(0, [math]::Min(255, [math]::Round($color.R * $Factor)))
    $g = [byte][math]::Max(0, [math]::Min(255, [math]::Round($color.G * $Factor)))
    $b = [byte][math]::Max(0, [math]::Min(255, [math]::Round($color.B * $Factor)))
    return [System.Windows.Media.Color]::FromArgb($Alpha, $r, $g, $b)
}

function Get-ColorLuminance {
    param($Color)
    return 0.2126 * ($Color.R / 255.0) + 0.7152 * ($Color.G / 255.0) + 0.0722 * ($Color.B / 255.0)
}

function Convert-HexToHsv {
    param([string]$Hex)
    $c = [System.Windows.Media.ColorConverter]::ConvertFromString($Hex)
    $r = $c.R / 255.0; $g = $c.G / 255.0; $b = $c.B / 255.0
    $max = [math]::Max($r, [math]::Max($g, $b))
    $min = [math]::Min($r, [math]::Min($g, $b))
    $d = $max - $min

    $h = 0.0
    if ($d -gt 0.0001) {
        if ($max -eq $r) { $h = 60.0 * ((($g - $b) / $d) % 6) }
        elseif ($max -eq $g) { $h = 60.0 * ((($b - $r) / $d) + 2) }
        else { $h = 60.0 * ((($r - $g) / $d) + 4) }
    }
    if ($h -lt 0) { $h += 360 }
    $s = 0.0
    if ($max -gt 0.0001) { $s = $d / $max }
    return @{ H = $h; S = $s; V = $max }
}

function Convert-HsvToHex {
    param([double]$H, [double]$S, [double]$V)
    $h = $H % 360
    if ($h -lt 0) { $h += 360 }
    $c = $V * $S
    $x = $c * (1 - [math]::Abs((($h / 60.0) % 2) - 1))
    $m = $V - $c
    $seg = [int][math]::Floor($h / 60.0) % 6
    switch ($seg) {
        0 { $r = $c; $g = $x; $b = 0 }
        1 { $r = $x; $g = $c; $b = 0 }
        2 { $r = 0; $g = $c; $b = $x }
        3 { $r = 0; $g = $x; $b = $c }
        4 { $r = $x; $g = 0; $b = $c }
        default { $r = $c; $g = 0; $b = $x }
    }
    $ri = [int][math]::Max(0, [math]::Min(255, [math]::Round(($r + $m) * 255)))
    $gi = [int][math]::Max(0, [math]::Min(255, [math]::Round(($g + $m) * 255)))
    $bi = [int][math]::Max(0, [math]::Min(255, [math]::Round(($b + $m) * 255)))
    return ('#{0:X2}{1:X2}{2:X2}' -f $ri, $gi, $bi)
}

# 背景亮就用深色字，背景暗就用浅色字
function Update-TextTheme {
    param([bool]$Light)
    if ($Light) {
        $map = @{
            TextPrimary      = '#F00F141B'
            TextSecondary    = '#C60F141B'
            TextTertiary     = '#990F141B'
            TextFaint        = '#7A0F141B'
            TextMuted        = '#660F141B'
            TextIcon         = '#800F141B'
            TrackBrush       = '#1F000000'
            DividerBrush     = '#1F000000'
            SwitchTrackBrush = '#24000000'
            SwitchThumb      = '#8C0F141B'
        }
    } else {
        $map = @{
            TextPrimary      = '#F7FFFFFF'
            TextSecondary    = '#B4FFFFFF'
            TextTertiary     = '#7AFFFFFF'
            TextFaint        = '#5CFFFFFF'
            TextMuted        = '#59FFFFFF'
            TextIcon         = '#73FFFFFF'
            TrackBrush       = '#1FFFFFFF'
            DividerBrush     = '#1AFFFFFF'
            SwitchTrackBrush = '#26FFFFFF'
            SwitchThumb      = '#A6FFFFFF'
        }
    }
    foreach ($key in $map.Keys) {
        try {
            $color = [System.Windows.Media.ColorConverter]::ConvertFromString($map[$key])
            $script:Window.Resources[$key] = [System.Windows.Media.SolidColorBrush]::new($color)
        } catch { Write-Log "更新主题色 $key 失败：$($_.Exception.Message)" }
    }
}

function Apply-Background {
    param([string]$Hex)
    if (-not $script:UI) { return }
    if (-not $Hex) { $Hex = '#1B2130' }

    $color = [System.Windows.Media.ColorConverter]::ConvertFromString($Hex)
    $light = (Get-ColorLuminance $color) -gt 0.55
    $bottomFactor = 0.5
    if ($light) { $bottomFactor = 0.86 }

    # 透明度只改背景 alpha；文字始终满不透明
    $alpha = [byte][math]::Round(255 * [double]$script:Config['opacity'])
    $alpha = [byte][math]::Max(0, [math]::Min(255, $alpha))

    $brush = [System.Windows.Media.LinearGradientBrush]::new()
    $brush.StartPoint = [System.Windows.Point]::new(0, 0)
    $brush.EndPoint = [System.Windows.Point]::new(0.7, 1)
    $top = [System.Windows.Media.Color]::FromArgb($alpha, $color.R, $color.G, $color.B)
    $bottom = Get-ShadeColor -Hex $Hex -Factor $bottomFactor -Alpha $alpha
    $brush.GradientStops.Add([System.Windows.Media.GradientStop]::new($top, 0.0))
    $brush.GradientStops.Add([System.Windows.Media.GradientStop]::new($bottom, 1.0))
    $script:UI['Card'].Background = $brush

    # 阴影跟着一起淡，不然透明卡片配重阴影很怪
    try { $script:UI['Card'].Effect.Opacity = 0.5 * [double]$script:Config['opacity'] } catch { }

    Update-TextTheme -Light $light
    if ($script:UI['TasksPanel'] -and $script:UI['TasksPanel'].Visibility -eq [System.Windows.Visibility]::Visible) { Render-TaskList }
    $script:UI['ColorPreview'].Background = Get-Brush $Hex
    $script:UI['ColorHexText'].Text = $Hex.ToUpper()
}

# 调色盘状态 -> 界面
function Refresh-Picker {
    if (-not $script:UI) { return }
    $hex = Convert-HsvToHex -H $script:Hsv.H -S $script:Hsv.S -V $script:Hsv.V
    $script:UI['SvHueLayer'].Background = Get-Brush (Convert-HsvToHex -H $script:Hsv.H -S 1.0 -V 1.0)

    $pad = $script:UI['SatValPad']
    $w = $pad.ActualWidth
    $h = $pad.ActualHeight
    if ($w -gt 0 -and $h -gt 0) {
        $x = [math]::Round($script:Hsv.S * $w) - 6
        $y = [math]::Round((1.0 - $script:Hsv.V) * $h) - 6
        $script:UI['SvKnob'].Margin = [System.Windows.Thickness]::new($x, $y, 0, 0)
    }

    $script:Config['background'] = $hex
    Apply-Background -Hex $hex
}

function Set-HueFromPoint {
    param($Element, $Point)
    $w = $Element.ActualWidth
    if ($w -le 0) { return }
    $f = [math]::Max(0.0, [math]::Min(1.0, $Point.X / $w))
    $script:Hsv.H = $f * 360.0
    Refresh-Picker
}

function Set-SvFromPoint {
    param($Element, $Point)
    $w = $Element.ActualWidth
    $h = $Element.ActualHeight
    if ($w -le 0 -or $h -le 0) { return }
    $script:Hsv.S = [math]::Max(0.0, [math]::Min(1.0, $Point.X / $w))
    $script:Hsv.V = 1.0 - [math]::Max(0.0, [math]::Min(1.0, $Point.Y / $h))
    Refresh-Picker
}

function Set-OpacityFromPoint {
    param($Element, $Point)
    $w = $Element.ActualWidth
    if ($w -le 0) { return }
    Set-OpacityFraction ([math]::Max(0.0, [math]::Min(1.0, $Point.X / $w)))
}

function Update-OpacityBar {
    $bar = $script:UI['OpacityBar']
    if (-not $bar) { return }
    $opacity = [double]$script:Config['opacity']
    $f = ($opacity - 0.35) / 0.65
    $f = [math]::Max(0.0, [math]::Min(1.0, $f))
    $w = $bar.ActualWidth
    if ($w -gt 0) { $script:UI['OpacityFill'].Width = [math]::Round([math]::Max(2, $w * $f)) }
    $script:UI['OpacityText'].Text = ('{0:0}%' -f ($opacity * 100))
}

function Set-OpacityFraction {
    param([double]$Fraction)
    $opacity = 0.35 + ([math]::Max(0.0, [math]::Min(1.0, $Fraction)) * 0.65)
    $script:Config['opacity'] = [math]::Round($opacity, 2)
    Apply-Background -Hex ([string]$script:Config['background'])
    Update-OpacityBar
}

function Set-Topmost {
    param([bool]$On)
    $script:Config['alwaysOnTop'] = $On
    if ($script:Window) { $script:Window.Topmost = $On }
    if ($script:UI -and $script:UI['SwTopmost']) { $script:UI['SwTopmost'].IsChecked = $On }
    Update-PinButton
}

function Toggle-Topmost {
    Set-Topmost (-not [bool]$script:Config['alwaysOnTop'])
    Save-Config
    Write-Log ('置顶：' + $script:Config['alwaysOnTop'])
}

function Update-PinButton {
    $btn = $script:UI['PinButton']
    if (-not $btn) { return }
    $on = [bool]$script:Config['alwaysOnTop']
    $btn.Opacity = 1.0
    if (-not $on) { $btn.Opacity = 0.42 }
    $btn.ToolTip = '已置顶（点一下取消）'
    if (-not $on) { $btn.ToolTip = '点一下置顶' }
}

function On-SettingToggled {
    if (-not $script:UI -or -not $script:SettingsReady) { return }
    $script:Config['showWeather'] = [bool]$script:UI['SwWeather'].IsChecked
    $script:Config['showTime'] = [bool]$script:UI['SwTime'].IsChecked
    $script:Config['showCpu'] = [bool]$script:UI['SwCpu'].IsChecked
    $script:Config['showMem'] = [bool]$script:UI['SwMem'].IsChecked
    $script:Config['showTasks'] = [bool]$script:UI['SwTasks'].IsChecked
    $script:Config['showAi'] = [bool]$script:UI['SwAi'].IsChecked

    Set-Topmost ([bool]$script:UI['SwTopmost'].IsChecked)
    Apply-ModuleVisibility
    Save-Config
    Ensure-WindowOnScreen
}

function Initialize-SettingsUI {
    $script:SettingsReady = $false
    $script:UI['SwWeather'].IsChecked = [bool]$script:Config['showWeather']
    $script:UI['SwTime'].IsChecked = [bool]$script:Config['showTime']
    $script:UI['SwCpu'].IsChecked = [bool]$script:Config['showCpu']
    $script:UI['SwMem'].IsChecked = [bool]$script:Config['showMem']
    $script:UI['SwTasks'].IsChecked = [bool]$script:Config['showTasks']
    $script:UI['SwAi'].IsChecked = [bool]$script:Config['showAi']
    $script:UI['SwTopmost'].IsChecked = [bool]$script:Config['alwaysOnTop']
    Apply-ModuleVisibility

    $hsv = Convert-HexToHsv ([string]$script:Config['background'])
    $script:Hsv.H = $hsv.H
    $script:Hsv.S = $hsv.S
    $script:Hsv.V = $hsv.V
    Refresh-Picker
    Update-OpacityBar
    Update-PinButton

    $script:SettingsReady = $true
}

function Open-Settings {
    $script:PreSettingsPos = @{
        Left   = $script:Window.Left
        Top    = $script:Window.Top
        Height = $script:Window.ActualHeight
    }
    $script:SettingsOpen = $true
    $script:UI['MainPanel'].Visibility = [System.Windows.Visibility]::Collapsed
    $script:UI['TasksPanel'].Visibility = [System.Windows.Visibility]::Collapsed
    $script:UI['AiPanel'].Visibility = [System.Windows.Visibility]::Collapsed
    $script:TasksOpen = $false
    $script:UiOpen = $false
    $script:UI['SettingsPanel'].Visibility = [System.Windows.Visibility]::Visible
    $script:UI['SettingsButton'].Visibility = [System.Windows.Visibility]::Collapsed
    $script:UI['PinButton'].Visibility = [System.Windows.Visibility]::Collapsed
    $script:Window.UpdateLayout()
    # 布局出来后才知道滑杆多宽，补一次定位
    Refresh-Picker
    Update-OpacityBar
    Ensure-WindowOnScreen
    Write-Log '打开设置页'
}

function Close-Settings {
    $script:SettingsOpen = $false
    $script:UI['SettingsPanel'].Visibility = [System.Windows.Visibility]::Collapsed
    $script:UI['MainPanel'].Visibility = [System.Windows.Visibility]::Visible
    $script:UI['SettingsButton'].Visibility = [System.Windows.Visibility]::Visible
    $script:UI['PinButton'].Visibility = [System.Windows.Visibility]::Visible
    $script:Window.UpdateLayout()

    # 回到打开设置前的位置；如果原本贴着屏幕底边，就保持底边不动（卡片变矮不该悬空）
    if ($script:PreSettingsPos) {
        $wa = [System.Windows.SystemParameters]::WorkArea
        $newHeight = $script:Window.ActualHeight
        $top = $script:PreSettingsPos.Top
        $oldBottom = $script:PreSettingsPos.Top + $script:PreSettingsPos.Height
        if ($oldBottom -ge ($wa.Bottom - 26)) {
            $top = $oldBottom - $newHeight
        }
        $script:Window.Left = $script:PreSettingsPos.Left
        $script:Window.Top = $top
    }
    Ensure-WindowOnScreen
}

function Toggle-Settings {
    if ($script:UI['SettingsPanel'].Visibility -eq [System.Windows.Visibility]::Visible) {
        Close-Settings
    } else {
        Open-Settings
    }
}

function On-CloseClicked {
    if (-not $script:UI) { return }
    if ($script:UI['SettingsPanel'].Visibility -eq [System.Windows.Visibility]::Visible) {
        Close-Settings
    } elseif ($script:UI['TasksPanel'].Visibility -eq [System.Windows.Visibility]::Visible) {
        Close-Tasks
    } elseif ($script:UI['AiPanel'].Visibility -eq [System.Windows.Visibility]::Visible) {
        Close-AiPanel
    } else {
        Close-Widget
    }
}

function Reset-Settings {
    $script:Config['showTime'] = $true
    $script:Config['showWeather'] = $true
    $script:Config['showCpu'] = $true
    $script:Config['showMem'] = $true
    $script:Config['background'] = '#1B2130'
    $script:Config['opacity'] = 0.96

    $script:UI['SwWeather'].IsChecked = $true
    $script:UI['SwTime'].IsChecked = $true
    $script:UI['SwCpu'].IsChecked = $true
    $script:UI['SwMem'].IsChecked = $true
    $script:UI['SwTopmost'].IsChecked = $true

    Set-Topmost $true
    Apply-ModuleVisibility

    $hsv = Convert-HexToHsv '#1B2130'
    $script:Hsv.H = $hsv.H
    $script:Hsv.S = $hsv.S
    $script:Hsv.V = $hsv.V
    Refresh-Picker
    Update-OpacityBar

    Save-Config
    Ensure-WindowOnScreen
    Write-Log '设置已恢复默认'
}

# 面板开关后窗口高度会变，别让它掉出屏幕
function Ensure-WindowOnScreen {
    if (-not $script:Window) { return }
    try {
        $script:Window.UpdateLayout()
        $wa = [System.Windows.SystemParameters]::WorkArea
        $w = $script:Window.ActualWidth
        $h = $script:Window.ActualHeight
        if ($w -le 0 -or $h -le 0) { return }

        $left = $script:Window.Left
        $top = $script:Window.Top
        if ($left + $w -gt $wa.Right) { $left = $wa.Right - $w - 8 }
        if ($top + $h -gt $wa.Bottom) { $top = $wa.Bottom - $h - 8 }
        if ($left -lt $wa.Left) { $left = $wa.Left + 8 }
        if ($top -lt $wa.Top) { $top = $wa.Top + 8 }

        $script:Window.Left = [math]::Round($left)
        $script:Window.Top = [math]::Round($top)
    } catch { }
}

function Close-Widget {
    if (-not $script:Window) { return }
    Hide-Widget
    try { if ($script:Tray) { $script:Tray.ShowBalloonTip(2500, '桌面小组件', '已隐藏。点任务栏的小组件图标或托盘图标可以再打开。', 'None') } } catch { }
    Write-Log '关闭按钮：隐藏到托盘'
}

# 最小化：收起成只显示时间/温度的小条（窗口不在任务栏，收进任务栏就没地方点了）
function Collapse-Widget {
    if (-not $script:Window -or $script:CompactMode) { return }
    if ($script:UI['SettingsPanel'].Visibility -eq [System.Windows.Visibility]::Visible) { Close-Settings }

    $script:CompactMode = $true   # 先置位，避免下面移动窗口时把临时坐标写进配置
    $right = $script:Window.Left + $script:Window.ActualWidth
    $bottom = $script:Window.Top + $script:Window.ActualHeight

    $script:UI['MainPanel'].Visibility = [System.Windows.Visibility]::Collapsed
    $script:UI['CompactPanel'].Visibility = [System.Windows.Visibility]::Visible
    foreach ($n in 'MinimizeButton', 'PinButton', 'SettingsButton', 'CloseButton') {
        $script:UI[$n].Visibility = [System.Windows.Visibility]::Collapsed
    }
    $script:UI['Card'].Width = 146
    $script:Window.Width = 146 + 28

    $script:Window.UpdateLayout()
    $script:Window.Left = [math]::Round($right - $script:Window.ActualWidth)
    $script:Window.Top = [math]::Round($bottom - $script:Window.ActualHeight)
    Update-CompactPanel
    Ensure-WindowOnScreen
    Write-Log '最小化：收起成小条'
}

function Expand-Widget {
    if (-not $script:Window -or -not $script:CompactMode) { return }
    $script:CompactMode = $false

    $right = $script:Window.Left + $script:Window.ActualWidth
    $bottom = $script:Window.Top + $script:Window.ActualHeight

    $script:UI['CompactPanel'].Visibility = [System.Windows.Visibility]::Collapsed
    $script:UI['MainPanel'].Visibility = [System.Windows.Visibility]::Visible
    foreach ($n in 'MinimizeButton', 'PinButton', 'SettingsButton', 'CloseButton') {
        $script:UI[$n].Visibility = [System.Windows.Visibility]::Visible
    }
    $script:UI['Card'].Width = 304
    $script:Window.Width = 304 + 28

    $script:Window.UpdateLayout()
    $script:Window.Left = [math]::Round($right - $script:Window.ActualWidth)
    $script:Window.Top = [math]::Round($bottom - $script:Window.ActualHeight)
    Ensure-WindowOnScreen
    # 展开后的位置显式存一次（收起期间是不记录的）
    $script:Config['left'] = [int][math]::Round($script:Window.Left)
    $script:Config['top'] = [int][math]::Round($script:Window.Top)
    Save-Config
    Write-Log '展开'
}

function Update-CompactPanel {
    if (-not $script:UI) { return }
    $script:UI['CompactClock'].Text = (Get-Date).ToString('HH:mm')
    $temp = '--°'
    if ($script:Weather) { $temp = '{0:0}°' -f $script:Weather.Temp }
    $script:UI['CompactTemp'].Text = $temp
}

function Hide-Widget {
    if (-not $script:Window) { return }
    $script:Window.Hide()
}

function Show-Widget {
    if (-not $script:Window) { return }
    if (-not $script:Window.IsVisible) { $script:Window.Show() }
    if ($script:Window.WindowState -eq [System.Windows.WindowState]::Minimized) {
        $script:Window.WindowState = [System.Windows.WindowState]::Normal
    }
    if ($script:Config['alwaysOnTop']) { $script:Window.Topmost = $true }
    $script:Window.Activate()
}

function Toggle-Visibility {
    if (-not $script:Window) { return }
    if ($script:Window.IsVisible) {
        Hide-Widget
    } else {
        Show-Widget
    }
}

# ============================================================ AI 用量 =====
# 适配器机制：adapters/*.ps1 每个文件返回一个 hashtable，声明 Id/Name/Order/Interval/Collect
# 这样加一个新工具 = 往 adapters 里丢一个文件，不用改主程序

function Get-WidgetRoot { return $script:Root }
function Get-WidgetCacheDir { return $script:CacheDir }

function Get-WidgetSetting {
    param([string]$Name, $Default = $null)
    if ($script:Config -and $script:Config.Contains($Name) -and $null -ne $script:Config[$Name]) {
        return $script:Config[$Name]
    }
    return $Default
}

# --- 主题：theme.json 提供默认背景/透明度/圆角，config.json 里的用户选择优先 ---
function Read-Theme {
    $path = Join-Path $script:Root 'theme.json'
    $data = Read-JsonFile $path
    if (-not $data) { $data = [pscustomobject]@{} }
    $theme = @{
        background   = [string]$data.background
        opacity      = $null
        cornerRadius = 14
        accent       = [string]$data.accent
    }
    if ($null -ne $data.opacity) { $theme.opacity = [double]$data.opacity }
    if ($null -ne $data.cornerRadius) { $theme.cornerRadius = [double]$data.cornerRadius }
    if (-not $theme.background) { $theme.background = '#1B2130' }
    $script:Theme = $theme
}

function Apply-ThemeRadius {
    if (-not $script:UI -or -not $script:UI['Card']) { return }
    $card = $script:UI['Card']
    if ($card -is [System.Windows.Controls.Border] -and $script:Theme) {
        $card.CornerRadius = [System.Windows.CornerRadius]::new([double]$script:Theme.cornerRadius)
    }
}

function Get-NodeRuntime {
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $bundled = Join-Path $env:USERPROFILE '.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe'
    if (Test-Path -LiteralPath $bundled) { return $bundled }
    return $null
}

function Format-TokenCount {
    param([double]$Value)
    if ($Value -ge 1000000) { return ('{0:0.0}M' -f ($Value / 1000000)) }
    if ($Value -ge 1000) { return ('{0:0.0}k' -f ($Value / 1000)) }
    return ('{0:0}' -f $Value)
}

function Get-CurrencySymbol {
    param([string]$Currency)
    switch (($Currency + '').ToUpperInvariant()) {
        'CNY' { return [char]0x00A5 }
        'USD' { return '$' }
        default { return '' }
    }
}

# --- 异步 HTTP：适配器可以发起请求，主循环轮询结果，不阻塞界面 ---
function Start-BgRequest {
    param([string]$Id, [string]$Url, [hashtable]$Headers = @{})
    try {
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Url)
        foreach ($k in $Headers.Keys) {
            if ($k -eq 'Authorization') {
                $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::Parse([string]$Headers[$k])
            } else {
                $null = $request.Headers.TryAddWithoutValidation($k, [string]$Headers[$k])
            }
        }
        $script:BgRequests[$Id] = @{
            Task     = $script:Http.SendAsync($request)
            Deadline = (Get-Date).AddSeconds(12)
        }
    } catch {
        $script:BgRequests[$Id] = @{ Error = $_.Exception.Message; Done = $true }
    }
}

function Poll-BgRequest {
    param([string]$Id)
    $entry = $script:BgRequests[$Id]
    if (-not $entry) { return @{ Running = $false; Done = $false; Failed = $false } }
    if ($entry.Error) {
        $script:BgRequests.Remove($Id)
        return @{ Running = $false; Done = $false; Failed = $true; Error = [string]$entry.Error }
    }
    if (-not $entry.Task.IsCompleted) {
        if ((Get-Date) -gt $entry.Deadline) {
            $script:BgRequests.Remove($Id)
            return @{ Running = $false; Done = $false; Failed = $true; Error = '请求超时' }
        }
        return @{ Running = $true; Done = $false; Failed = $false }
    }

    $script:BgRequests.Remove($Id)
    try {
        $response = $entry.Task.Result
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            $msg = 'HTTP ' + [int]$response.StatusCode
            if ([int]$response.StatusCode -eq 401) { $msg = 'API key 无效' }
            return @{ Running = $false; Done = $false; Failed = $true; Error = $msg }
        }
        return @{ Running = $false; Done = $true; Failed = $false; Json = ($body | ConvertFrom-Json) }
    } catch {
        return @{ Running = $false; Done = $false; Failed = $true; Error = $_.Exception.Message }
    }
}

# --- 适配器加载与刷新 ---
function Import-AiAdapters {
    $script:AiAdapters = @()
    $dir = Join-Path $script:Root 'adapters'
    if (-not (Test-Path -LiteralPath $dir)) { return }
    foreach ($file in (Get-ChildItem -LiteralPath $dir -File -Filter *.ps1 | Sort-Object Name)) {
        try {
            # 读文本再执行，避开执行策略对 .ps1 的拦截
            $adapter = & ([scriptblock]::Create([IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8)))
            if ($adapter -and $adapter.Id -and $adapter.Collect) {
                if (-not $adapter.ContainsKey('Order')) { $adapter.Order = 100 }
                if (-not $adapter.ContainsKey('Interval')) { $adapter.Interval = 300 }
                if (-not $adapter.ContainsKey('Summary')) { $adapter.Summary = $true }
                if (-not $adapter.ContainsKey('ShortName')) { $adapter.ShortName = $adapter.Name }
                if (-not $adapter.ContainsKey('KeyName')) { $adapter.KeyName = '' }
                $script:AiAdapters += [pscustomobject]$adapter
                Write-Log ("载入适配器：{0}" -f $adapter.Id)
            }
        } catch {
            Write-Log ("适配器载入失败 {0}：{1}" -f $file.Name, $_.Exception.Message)
        }
    }
    $script:AiAdapters = @($script:AiAdapters | Sort-Object Order)
    foreach ($a in $script:AiAdapters) {
        if (-not $script:AiState.ContainsKey($a.Id)) {
            $script:AiState[$a.Id] = @{ Ok = $false; Value = '…'; Note = ''; NextRun = [datetime]::MinValue }
        }
    }
}

function Update-AiAdapters {
    param([switch]$Force)
    if (-not $script:AiAdapters) { return }
    $now = Get-Date
    $changed = $false
    foreach ($adapter in $script:AiAdapters) {
        $state = $script:AiState[$adapter.Id]
        if (-not $state) { continue }
        if (-not $Force -and $now -lt $state.NextRun) { continue }
        try {
            $result = & $adapter.Collect
        } catch {
            $result = @{ Ok = $false; Value = '出错'; Note = $_.Exception.Message }
        }
        if ($result) {
            $state.Ok = [bool]$result.Ok
            $state.Value = [string]$result.Value
            $state.Note = [string]$result.Note
            $state.Data = $result.Data
        }
        $state.NextRun = $now.AddSeconds([int]$adapter.Interval)
        $changed = $true
    }
    if ($changed -and $script:UI) { Update-AiUI }
}

function Get-AiSummaryText {
    if (-not $script:AiAdapters) { return 'AI · 未载入适配器' }
    $parts = @()
    foreach ($adapter in $script:AiAdapters) {
        if (-not $adapter.Summary) { continue }
        $state = $script:AiState[$adapter.Id]
        if ($state -and $state.Ok) { $parts += ('{0} {1}' -f $adapter.ShortName, $state.Value) }
    }
    if ($parts.Count -eq 0) { return 'AI · 暂无数据' }
    return ('AI 今日 · ' + ($parts -join ' · '))
}

function Update-AiUI {
    if (-not $script:UI) { return }
    Set-ElementVisible 'AiRow' ([bool]$script:Config['showAi'])
    if ($script:UI['AiSummary']) { $script:UI['AiSummary'].Text = (Get-AiSummaryText) }
    if ($script:UI['AiList'] -and $script:UI['AiPanel'].Visibility -eq [System.Windows.Visibility]::Visible) {
        Render-AiList
    }
}

function New-AiRow {
    param([string]$Name, [string]$Value, [string]$Note, [bool]$Ok)
    $row = [System.Windows.Controls.Border]::new()
    $row.CornerRadius = [System.Windows.CornerRadius]::new(8)
    $row.Background = Get-Brush '#12FFFFFF'
    $row.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
    $row.Padding = [System.Windows.Thickness]::new(9, 7, 9, 7)

    $grid = [System.Windows.Controls.Grid]::new()
    $c1 = [System.Windows.Controls.ColumnDefinition]::new()
    $c1.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $c2 = [System.Windows.Controls.ColumnDefinition]::new()
    $c2.Width = [System.Windows.GridLength]::Auto
    $grid.ColumnDefinitions.Add($c1)
    $grid.ColumnDefinitions.Add($c2)

    $left = [System.Windows.Controls.StackPanel]::new()
    $title = [System.Windows.Controls.TextBlock]::new()
    $title.Text = $Name
    $title.FontSize = 10.5
    $title.Foreground = Get-ThemeBrush 'TextPrimary'
    $left.Children.Add($title) | Out-Null
    if ($Note) {
        $noteBlock = [System.Windows.Controls.TextBlock]::new()
        $noteBlock.Text = $Note
        $noteBlock.FontSize = 8.5
        $noteBlock.Margin = [System.Windows.Thickness]::new(0, 2, 0, 0)
        $noteBlock.Foreground = Get-ThemeBrush 'TextMuted'
        $noteBlock.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
        $left.Children.Add($noteBlock) | Out-Null
    }
    $grid.Children.Add($left) | Out-Null

    $valueText = [System.Windows.Controls.TextBlock]::new()
    $valueText.Text = $Value
    $valueText.FontSize = 11
    $valueText.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    if ($Ok) { $valueText.Foreground = Get-ThemeBrush 'TextPrimary' }
    else { $valueText.Foreground = Get-ThemeBrush 'TextMuted' }
    [System.Windows.Controls.Grid]::SetColumn($valueText, 1)
    $grid.Children.Add($valueText) | Out-Null

    $row.Child = $grid
    return $row
}

function Render-AiList {
    if (-not $script:UI) { return }
    $list = $script:UI['AiList']
    $list.Children.Clear()

    if (-not $script:AiAdapters -or $script:AiAdapters.Count -eq 0) {
        $hint = [System.Windows.Controls.TextBlock]::new()
        $hint.Text = '没有找到适配器（adapters/ 目录为空）'
        $hint.FontSize = 9.5
        $hint.Foreground = Get-ThemeBrush 'TextMuted'
        $list.Children.Add($hint) | Out-Null
        return
    }

    foreach ($adapter in $script:AiAdapters) {
        $state = $script:AiState[$adapter.Id]
        $value = '…'
        $note = $adapter.Note
        $ok = $false
        if ($state) {
            $value = $state.Value
            if ($state.Note) { $note = $state.Note }
            $ok = [bool]$state.Ok
        }
        $list.Children.Add((New-AiRow -Name $adapter.Name -Value $value -Note $note -Ok $ok)) | Out-Null
    }

    # key 输入框：只有声明了 KeyName 的适配器才显示
    $keyAdapter = $script:AiAdapters | Where-Object { $_.KeyName } | Select-Object -First 1
    $showKey = $null -ne $keyAdapter
    if ($script:UI['AiKeyBox']) {
        $script:UI['AiKeyBox'].Visibility = $(if ($showKey) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed })
        $script:UI['AiKeySave'].Visibility = $(if ($showKey) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed })
        $script:UI['AiKeyBox'].Text = ''
    }
    if ($showKey -and $script:UI['AiKeyLabel']) {
        $saved = [string](Get-WidgetSetting $keyAdapter.KeyName '')
        if ($saved.Length -gt 10) {
            $script:UI['AiKeyLabel'].Text = ('{0}（已保存 …{1}，留空则沿用）' -f $keyAdapter.Hint, $saved.Substring($saved.Length - 4))
        } else {
            $script:UI['AiKeyLabel'].Text = ('{0}（只存本机 config.json，用来查账户余额）' -f $keyAdapter.Hint)
        }
    }
}

function Open-AiPanel {
    if (-not $script:Window) { return }
    if ($script:CompactMode) { Expand-Widget }
    if ($script:UI['SettingsPanel'].Visibility -eq [System.Windows.Visibility]::Visible) { Close-Settings }
    if ($script:UI['TasksPanel'].Visibility -eq [System.Windows.Visibility]::Visible) { Close-Tasks }

    $script:PreAiPos = @{ Left = $script:Window.Left; Top = $script:Window.Top; Height = $script:Window.ActualHeight }
    $script:UiOpen = $true

    $script:UI['MainPanel'].Visibility = [System.Windows.Visibility]::Collapsed
    $script:UI['AiPanel'].Visibility = [System.Windows.Visibility]::Visible
    foreach ($n in 'MinimizeButton', 'PinButton', 'SettingsButton') {
        $script:UI[$n].Visibility = [System.Windows.Visibility]::Collapsed
    }

    Render-AiList
    Update-AiAdapters -Force
    $script:Window.UpdateLayout()
    Ensure-WindowOnScreen
    $null = $script:Window.Activate()
    Write-Log '打开 AI 用量'
}

function Close-AiPanel {
    if (-not $script:UI) { return }
    $script:UI['AiPanel'].Visibility = [System.Windows.Visibility]::Collapsed
    $script:UI['MainPanel'].Visibility = [System.Windows.Visibility]::Visible
    foreach ($n in 'MinimizeButton', 'PinButton', 'SettingsButton') {
        $script:UI[$n].Visibility = [System.Windows.Visibility]::Visible
    }
    $script:UiOpen = $false
    if ($script:PreAiPos) {
        $wa = [System.Windows.SystemParameters]::WorkArea
        $newHeight = $script:Window.ActualHeight
        $top = $script:PreAiPos.Top
        if (($script:PreAiPos.Top + $script:PreAiPos.Height) -ge ($wa.Bottom - 26)) {
            $top = $script:PreAiPos.Top + $script:PreAiPos.Height - $newHeight
        }
        $script:Window.Left = $script:PreAiPos.Left
        $script:Window.Top = $top
    }
    Ensure-WindowOnScreen
}

function Save-AiKey {
    $keyAdapter = $script:AiAdapters | Where-Object { $_.KeyName } | Select-Object -First 1
    if (-not $keyAdapter) { return }
    $typed = ([string]$script:UI['AiKeyBox'].Text).Trim()
    if (-not $typed) { $typed = [string](Get-WidgetSetting $keyAdapter.KeyName '') }
    $script:Config[$keyAdapter.KeyName] = $typed
    Save-Config
    $script:UI['AiKeyBox'].Text = ''
    # 让这个适配器下次立刻重查
    $state = $script:AiState[$keyAdapter.Id]
    if ($state) { $state.NextRun = [datetime]::MinValue }
    $script:BgRequests.Remove($keyAdapter.Id)
    Update-AiAdapters -Force
    Render-AiList
    Write-Log ('更新适配器密钥：{0}' -f $keyAdapter.Id)
}

# ============================================================ 待办 =========
function Read-Tasks {
    $data = Read-JsonFile $script:TasksPath
    $list = @()
    foreach ($item in @($data)) {
        if (-not $item) { continue }
        $list += @{
            Id       = [string]$item.id
            Title    = [string]$item.title
            Due      = [string]$item.due
            Remind   = [bool]$item.remind
            RemindAt = [string]$item.remindAt
            Done     = [bool]$item.done
            Reminded = [bool]$item.reminded
        }
    }
    return , $list
}

function Save-Tasks {
    $out = @()
    foreach ($task in $script:Tasks) {
        $out += [ordered]@{
            id       = $task.Id
            title    = $task.Title
            due      = $task.Due
            remind   = $task.Remind
            remindAt = $task.RemindAt
            done     = $task.Done
            reminded = $task.Reminded
        }
    }
    Write-JsonFile $script:TasksPath ([object[]]$out)
}

function Get-ThemeBrush {
    param([string]$Key)
    $brush = $null
    if ($script:Window) { $brush = $script:Window.Resources[$Key] }
    if ($brush) { return $brush }
    return Get-Brush '#B4FFFFFF'
}

function ConvertTo-TaskTime {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $s = $Text.Trim()
    $now = Get-Date

    $timeOnly = [regex]::Match($s, '^(\d{1,2}):(\d{2})$')
    if ($timeOnly.Success) {
        $hh = [int]$timeOnly.Groups[1].Value
        $mm = [int]$timeOnly.Groups[2].Value
        if ($hh -gt 23 -or $mm -gt 59) { return $null }
        return [datetime]::new($now.Year, $now.Month, $now.Day, $hh, $mm, 0)
    }

    foreach ($fmt in @('yyyy-MM-dd HH:mm', 'yyyy/M/d HH:mm', 'yyyy/M/d H:mm', 'MM-dd HH:mm', 'M-d HH:mm', 'M-d H:mm')) {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact($s, $fmt, [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::None, [ref]$parsed)) { return $parsed }
    }
    return $null
}

function ConvertFrom-TaskTime {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParseExact($Text, 'yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref]$parsed)) { return $parsed }
    return $null
}

function Format-TaskTime {
    param([datetime]$Time)
    return $Time.ToString('yyyy-MM-dd HH:mm')
}

function Update-TasksEmpty {
    if (-not $script:UI) { return }
    $hasAny = @($script:Tasks).Count -gt 0
    if ($hasAny) { $script:UI['TasksEmpty'].Visibility = [System.Windows.Visibility]::Collapsed }
    else { $script:UI['TasksEmpty'].Visibility = [System.Windows.Visibility]::Visible }
}

function Render-TaskList {
    if (-not $script:UI) { return }
    $list = $script:UI['TasksList']
    $list.Children.Clear()

    $sorted = @($script:Tasks | Sort-Object @{ Expression = { if ($_.Done) { 1 } else { 0 } } }, @{ Expression = { $_.Due } })
    if ($sorted.Count -gt 0) { $script:UI['TasksEmpty'].Visibility = [System.Windows.Visibility]::Collapsed }
    else { $script:UI['TasksEmpty'].Visibility = [System.Windows.Visibility]::Visible }

    foreach ($task in $sorted) {
        $row = [System.Windows.Controls.Border]::new()
        $row.CornerRadius = [System.Windows.CornerRadius]::new(8)
        $row.Background = Get-Brush '#12FFFFFF'
        $row.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
        $row.Padding = [System.Windows.Thickness]::new(9, 7, 8, 7)
        $row.Cursor = [System.Windows.Input.Cursors]::Hand
        $row.Tag = $task
        $row.ToolTip = '点击编辑'

        $grid = [System.Windows.Controls.Grid]::new()
        foreach ($width in @(14, 0, 1, 0)) {
            $col = [System.Windows.Controls.ColumnDefinition]::new()
            if ($width -eq 0) { $col.Width = [System.Windows.GridLength]::Auto }
            elseif ($width -eq 1) { $col.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) }
            else { $col.Width = [System.Windows.GridLength]::new([double]$width) }
            $grid.ColumnDefinitions.Add($col)
        }

        $dot = [System.Windows.Controls.TextBlock]::new()
        if ($task.Done) { $dot.Text = '●' } else { $dot.Text = '○' }
        $dot.FontSize = 9
        $dot.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $dot.Cursor = [System.Windows.Input.Cursors]::Hand
        $dot.Tag = $task
        if ($task.Done) { $dot.Foreground = Get-Brush '#FF5EA6E8' } else { $dot.Foreground = Get-ThemeBrush 'TextTertiary' }
        $dot.Add_MouseLeftButtonUp({
                param($s, $e)
                $e.Handled = $true
                Toggle-TaskDone $s.Tag
            })
        $grid.Children.Add($dot) | Out-Null

        $when = ConvertFrom-TaskTime $task.Due
        $time = [System.Windows.Controls.TextBlock]::new()
        if ($when) { $time.Text = $when.ToString('MM-dd HH:mm') } else { $time.Text = '—' }
        $time.FontSize = 9
        $time.Margin = [System.Windows.Thickness]::new(6, 0, 8, 0)
        $time.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $time.Foreground = Get-ThemeBrush 'TextTertiary'
        [System.Windows.Controls.Grid]::SetColumn($time, 1)
        $grid.Children.Add($time) | Out-Null

        $title = [System.Windows.Controls.TextBlock]::new()
        $title.Text = $task.Title
        $title.FontSize = 10.5
        $title.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $title.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
        if ($task.Done) {
            $title.Foreground = Get-ThemeBrush 'TextTertiary'
            $title.TextDecorations = [System.Windows.TextDecorations]::Strikethrough
        } else {
            $title.Foreground = Get-ThemeBrush 'TextPrimary'
        }
        [System.Windows.Controls.Grid]::SetColumn($title, 2)
        $grid.Children.Add($title) | Out-Null

        if ($task.Remind) {
            $bell = [System.Windows.Controls.TextBlock]::new()
            $bell.Text = '⏰'
            $bell.FontSize = 9
            $bell.Margin = [System.Windows.Thickness]::new(6, 0, 0, 0)
            $bell.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
            [System.Windows.Controls.Grid]::SetColumn($bell, 3)
            $grid.Children.Add($bell) | Out-Null
        }

        $row.Child = $grid
        $row.Add_MouseLeftButtonUp({ param($s, $e) Show-TaskEditor $s.Tag })
        $null = $list.Children.Add($row)
    }
}

function Update-TasksUI {
    if (-not $script:UI) { return }
    Set-ElementVisible 'TasksRow' ([bool]$script:Config['showTasks'])
    Set-ElementVisible 'AiRow' ([bool]$script:Config['showAi'])

    $pending = @($script:Tasks | Where-Object { -not $_.Done } | Sort-Object { $_.Due })
    if ($pending.Count -eq 0) {
        $script:UI['TasksSummary'].Text = '待办 · 暂无'
        $script:UI['TasksCount'].Text = ''
        return
    }
    $next = $pending[0]
    $when = ConvertFrom-TaskTime $next.Due
    $stamp = '—'
    if ($when) { $stamp = $when.ToString('MM-dd HH:mm') }
    $script:UI['TasksSummary'].Text = ('待办 · {0}  {1}' -f $stamp, $next.Title)
    if ($pending.Count -gt 1) { $script:UI['TasksCount'].Text = ('+{0}' -f ($pending.Count - 1)) }
    else { $script:UI['TasksCount'].Text = '' }
}

function Open-Tasks {
    if (-not $script:Window) { return }
    if ($script:CompactMode) { Expand-Widget }
    if ($script:UI['SettingsPanel'].Visibility -eq [System.Windows.Visibility]::Visible) { Close-Settings }

    $script:PreTasksPos = @{ Left = $script:Window.Left; Top = $script:Window.Top; Height = $script:Window.ActualHeight }
    $script:TasksOpen = $true

    $script:UI['MainPanel'].Visibility = [System.Windows.Visibility]::Collapsed
    $script:UI['SettingsPanel'].Visibility = [System.Windows.Visibility]::Collapsed
    $script:UI['AiPanel'].Visibility = [System.Windows.Visibility]::Collapsed
    $script:UiOpen = $false
    $script:UI['TasksPanel'].Visibility = [System.Windows.Visibility]::Visible
    foreach ($n in 'MinimizeButton', 'PinButton', 'SettingsButton') {
        $script:UI[$n].Visibility = [System.Windows.Visibility]::Collapsed
    }
    Close-TaskEditor
    Render-TaskList
    $script:Window.UpdateLayout()
    Ensure-WindowOnScreen
    $script:Window.Activate()
    Write-Log '打开待办'
}

function Close-Tasks {
    if (-not $script:UI) { return }
    $script:UI['TasksPanel'].Visibility = [System.Windows.Visibility]::Collapsed
    $script:UI['MainPanel'].Visibility = [System.Windows.Visibility]::Visible
    foreach ($n in 'MinimizeButton', 'PinButton', 'SettingsButton') {
        $script:UI[$n].Visibility = [System.Windows.Visibility]::Visible
    }
    $script:TasksOpen = $false
    if ($script:PreTasksPos) {
        $wa = [System.Windows.SystemParameters]::WorkArea
        $newHeight = $script:Window.ActualHeight
        $top = $script:PreTasksPos.Top
        if (($script:PreTasksPos.Top + $script:PreTasksPos.Height) -ge ($wa.Bottom - 26)) {
            $top = $script:PreTasksPos.Top + $script:PreTasksPos.Height - $newHeight
        }
        $script:Window.Left = $script:PreTasksPos.Left
        $script:Window.Top = $top
    }
    Ensure-WindowOnScreen
}

function Close-TaskEditor {
    if (-not $script:UI) { return }
    $script:UI['TaskEditView'].Visibility = [System.Windows.Visibility]::Collapsed
    $script:UI['TasksScroll'].Visibility = [System.Windows.Visibility]::Visible
    $script:UI['TaskNewButton'].Visibility = [System.Windows.Visibility]::Visible
    $script:UI['EditorError'].Text = ''
    Update-TasksEmpty
}

function Show-TaskEditor {
    param($Task)
    if (-not $script:UI) { return }
    $script:EditingTaskId = ''
    if ($Task) { $script:EditingTaskId = [string]$Task.Id }

    $script:UI['TasksScroll'].Visibility = [System.Windows.Visibility]::Collapsed
    $script:UI['TasksEmpty'].Visibility = [System.Windows.Visibility]::Collapsed
    $script:UI['TaskNewButton'].Visibility = [System.Windows.Visibility]::Collapsed
    $script:UI['TaskEditView'].Visibility = [System.Windows.Visibility]::Visible
    $script:UI['EditorError'].Text = ''

    if ($Task) {
        $script:UI['EditorTitle'].Text = [string]$Task.Title
        $due = ConvertFrom-TaskTime ([string]$Task.Due)
        if ($due) { $script:UI['EditorDue'].Text = $due.ToString('MM-dd HH:mm') } else { $script:UI['EditorDue'].Text = '' }
        $script:UI['EditorRemind'].IsChecked = [bool]$Task.Remind
        $remindAt = ConvertFrom-TaskTime ([string]$Task.RemindAt)
        if ($remindAt) { $script:UI['EditorRemindAt'].Text = $remindAt.ToString('MM-dd HH:mm') } else { $script:UI['EditorRemindAt'].Text = '' }
        $script:UI['TaskDeleteButton'].Visibility = [System.Windows.Visibility]::Visible
    } else {
        $due = (Get-Date).AddHours(1)
        $due = [datetime]::new($due.Year, $due.Month, $due.Day, $due.Hour, [int]([math]::Floor($due.Minute / 5) * 5), 0)
        $script:UI['EditorTitle'].Text = ''
        $script:UI['EditorDue'].Text = $due.ToString('MM-dd HH:mm')
        $script:UI['EditorRemind'].IsChecked = $false
        $script:UI['EditorRemindAt'].Text = $due.AddMinutes(-10).ToString('MM-dd HH:mm')
        $script:UI['TaskDeleteButton'].Visibility = [System.Windows.Visibility]::Collapsed
    }

    $script:Window.UpdateLayout()
    Ensure-WindowOnScreen
    $script:Window.Activate()
    $null = $script:UI['EditorTitle'].Focus()
}

function Save-TaskFromEditor {
    $title = ([string]$script:UI['EditorTitle'].Text).Trim()
    if (-not $title) { $script:UI['EditorError'].Text = '事情不能为空'; return }
    if ($title.Length -gt 60) { $title = $title.Substring(0, 60) }

    $due = ConvertTo-TaskTime ([string]$script:UI['EditorDue'].Text)
    if (-not $due) { $script:UI['EditorError'].Text = '时间看不懂：试试「11-18 18:00」或「18:00」'; return }

    $remind = [bool]$script:UI['EditorRemind'].IsChecked
    $remindAt = $null
    if ($remind) {
        $remindAt = ConvertTo-TaskTime ([string]$script:UI['EditorRemindAt'].Text)
        if (-not $remindAt) { $script:UI['EditorError'].Text = '提醒时间看不懂：试试「11-18 17:50」'; return }
        if ($remindAt -gt $due) { $script:UI['EditorError'].Text = '提醒时间不能晚于事情时间'; return }
    }

    $task = $null
    if ($script:EditingTaskId) {
        $task = $script:Tasks | Where-Object { $_.Id -eq $script:EditingTaskId } | Select-Object -First 1
    }
    if (-not $task) {
        $task = @{ Id = [guid]::NewGuid().ToString('N'); Done = $false; Reminded = $false }
        $script:Tasks = @($script:Tasks) + $task
    }

    $task.Title = $title
    $task.Due = (Format-TaskTime $due)
    $task.Remind = $remind
    if ($remindAt) { $task.RemindAt = (Format-TaskTime $remindAt) } else { $task.RemindAt = '' }
    $task.Reminded = $false

    Save-Tasks
    Close-TaskEditor
    Render-TaskList
    Update-TasksUI
    Write-Log ("保存待办：{0} @ {1}" -f $title, $task.Due)
}

function Delete-Task {
    if (-not $script:EditingTaskId) { return }
    $script:Tasks = @($script:Tasks | Where-Object { $_.Id -ne $script:EditingTaskId })
    Save-Tasks
    Close-TaskEditor
    Render-TaskList
    Update-TasksUI
    Write-Log '删除待办'
}

function Toggle-TaskDone {
    param($Task)
    if (-not $Task) { return }
    $Task.Done = -not $Task.Done
    if ($Task.Done) { $Task.Reminded = $true }
    Save-Tasks
    Render-TaskList
    Update-TasksUI
}

function Check-Reminders {
    if (-not $script:Tasks) { return }
    $now = Get-Date
    foreach ($task in @($script:Tasks)) {
        if ($task.Done -or -not $task.Remind -or $task.Reminded) { continue }
        if (-not $task.RemindAt) { continue }
        $at = ConvertFrom-TaskTime ([string]$task.RemindAt)
        if (-not $at) { continue }
        if ($now -lt $at) { continue }

        # 超过 12 小时的旧提醒不打扰，直接标掉
        if (($now - $at).TotalHours -gt 12) {
            $task.Reminded = $true
            Save-Tasks
            continue
        }
        Show-Reminder $task
        return
    }
}

function Show-Reminder {
    param($Task)
    $Task.Reminded = $true
    Save-Tasks

    if ($script:CompactMode) { Expand-Widget }
    if ($script:UI['TasksPanel'].Visibility -eq [System.Windows.Visibility]::Visible) { Close-Tasks }
    if ($script:UI['SettingsPanel'].Visibility -eq [System.Windows.Visibility]::Visible) { Close-Settings }
    if (-not $script:Window.IsVisible) { $script:Window.Show() }

    $script:ReminderActive = $true
    $script:Window.Topmost = $true

    $due = ConvertFrom-TaskTime ([string]$Task.Due)
    $stamp = ''
    if ($due) { $stamp = $due.ToString('HH:mm') + ' ' }
    $script:UI['ReminderText'].Text = ($stamp + [string]$Task.Title)
    $script:UI['ReminderBanner'].Visibility = [System.Windows.Visibility]::Visible
    try { [System.Media.SystemSounds]::Exclamation.Play() } catch { }
    $null = $script:Window.Activate()
    Write-Log ("到点提醒：{0}" -f $Task.Title)
}

function Dismiss-Reminder {
    $script:ReminderActive = $false
    if ($script:UI) { $script:UI['ReminderBanner'].Visibility = [System.Windows.Visibility]::Collapsed }
    if ($script:Window) { $script:Window.Topmost = [bool]$script:Config['alwaysOnTop'] }
    Write-Log '关闭提醒'
}

# ============================================================ 缓存 =========
function Restore-CachedWeather {
    $cache = Read-JsonFile $script:CachePath
    if (-not $cache) { return $false }
    try {
        $savedAt = [datetime]::Parse([string]$cache.savedAt, [Globalization.CultureInfo]::InvariantCulture)
        if (((Get-Date) - $savedAt).TotalHours -gt 6) { return $false }
        $city = $script:Location.City
        if (-not $city) { $city = [string]$cache.city }
        $script:Weather = @{
            Temp             = [double]$cache.temp
            Feels            = $cache.feels
            Hum              = $cache.hum
            Hi               = [double]$cache.hi
            Lo               = [double]$cache.lo
            Cond             = @{ Text = [string]$cache.condText; Kind = [string]$cache.condKind; Color = [string]$cache.condColor }
            City             = $city
            Source           = [string]$cache.source
            UtcOffsetSeconds = $cache.utcOffsetSeconds
            UpdatedAt        = $savedAt
            FromCache        = $true
        }
        return $true
    } catch {
        Write-Log "缓存读取失败：$($_.Exception.Message)"
        return $false
    }
}

# ============================================================ 预览 =========
function Fill-PreviewSample {
    $now = Get-Date
    $script:UI['ClockText'].Text = $now.ToString('HH:mm')
    $script:UI['SecText'].Text = $now.ToString('ss')
    $script:UI['DateText'].Text = '{0}月{1}日' -f $now.Month, $now.Day
    $script:UI['WeekText'].Text = '周' + @('日', '一', '二', '三', '四', '五', '六')[[int]$now.DayOfWeek]
    $script:UI['TempText'].Text = '13°'
    $script:UI['CondText'].Text = '晴间多云'
    $script:UI['RangeText'].Text = '最高 16°　最低 9°'
    $script:UI['CityLabel'].Text = '上海'
    $script:UI['DetailLabel'].Text = ' · 体感 10° · 湿度 75%'
    $script:UI['CpuText'].Text = '23%'
    $script:UI['MemText'].Text = '61%'
    $script:UI['MemGbText'].Text = '9.8 / 16.0 GB'
    $script:UI['TzText'].Text = 'UTC+8'
    $script:UI['SourceText'].Text = 'wttr.in · 10:41'
    $script:UI['AiSummary'].Text = 'AI 今日 · DSH ¥16.20 · Claude 0'
    $script:UI['TasksSummary'].Text = '待办 · 18:00  交季度报告'
    $script:UI['TasksCount'].Text = '+1'
    $script:UI['CompactClock'].Text = $now.ToString('HH:mm')
    $script:UI['CompactTemp'].Text = '13°'

    $icon = 'suncloud'
    $iconColor = '#FFD27A'
    if ($env:WIDGET_PREVIEW_ICON) {
        $icon = $env:WIDGET_PREVIEW_ICON
        $iconColor = '#B9C6D2'
    }
    Draw-WeatherIcon $icon $iconColor
}

function Invoke-Preview {
    param([string]$Path)
    if (-not $Path) { $Path = Join-Path $script:Root 'preview.png' }

    $null = New-Widget
    Fill-PreviewSample
    if ($env:WIDGET_PREVIEW_SETTINGS) {
        $script:UI['MainPanel'].Visibility = [System.Windows.Visibility]::Collapsed
        $script:UI['SettingsPanel'].Visibility = [System.Windows.Visibility]::Visible
        $script:UI['SettingsButton'].Visibility = [System.Windows.Visibility]::Collapsed
        $script:UI['PinButton'].Visibility = [System.Windows.Visibility]::Collapsed
    }
    if ($env:WIDGET_PREVIEW_TASKS) {
        $script:Tasks = @(
            @{ Id = '1'; Title = '交季度报告'; Due = '2026-11-18 18:00'; Remind = $true; RemindAt = '2026-11-18 17:30'; Done = $false; Reminded = $false },
            @{ Id = '2'; Title = '买猫粮'; Due = '2026-11-18 20:00'; Remind = $false; RemindAt = ''; Done = $false; Reminded = $false },
            @{ Id = '3'; Title = '给路由器换个位置'; Due = '2026-11-18 09:00'; Remind = $false; RemindAt = ''; Done = $true; Reminded = $true }
        )
        $script:UI['MainPanel'].Visibility = [System.Windows.Visibility]::Collapsed
        $script:UI['TasksPanel'].Visibility = [System.Windows.Visibility]::Visible
        foreach ($n in 'MinimizeButton', 'PinButton', 'SettingsButton') { $script:UI[$n].Visibility = [System.Windows.Visibility]::Collapsed }
        Render-TaskList
    }
    if ($env:WIDGET_PREVIEW_REMINDER) {
        $script:UI['ReminderBanner'].Visibility = [System.Windows.Visibility]::Visible
        $script:UI['ReminderText'].Text = '18:00 交季度报告'
    }
    if ($env:WIDGET_PREVIEW_AI) {
        Read-Theme
    Import-AiAdapters
        $script:AiState['claude'] = @{ Ok = $true; Value = '12.3k'; Note = '今日已用 · 3 个会话文件'; NextRun = (Get-Date).AddHours(1) }
        $script:AiState['codex'] = @{ Ok = $true; Value = '8.2k'; Note = '今日已用 · 累计 1.6M'; NextRun = (Get-Date).AddHours(1) }
        $script:AiState['dsh'] = @{ Ok = $true; Value = '¥16.20'; Note = '650 次 · deepseek-flash · 高峰时段'; NextRun = (Get-Date).AddHours(1) }
        $script:AiState['deepseek-balance'] = @{ Ok = $true; Value = '¥9.47'; Note = '充值 9.47 / 赠送 0.00'; NextRun = (Get-Date).AddHours(1) }
        $script:UI['MainPanel'].Visibility = [System.Windows.Visibility]::Collapsed
        $script:UI['AiPanel'].Visibility = [System.Windows.Visibility]::Visible
        foreach ($n in 'MinimizeButton', 'PinButton', 'SettingsButton') { $script:UI[$n].Visibility = [System.Windows.Visibility]::Collapsed }
        Render-AiList
        if ($script:UI['AiKeyLabel']) { $script:UI['AiKeyLabel'].Text = 'DeepSeek API key（只存本机，用来查账户余额）' }
        if ($script:UI['AiKeyBox']) { $script:UI['AiKeyBox'].Text = '' }
    }
    if ($env:WIDGET_PREVIEW_COMPACT) {
        $script:UI['MainPanel'].Visibility = [System.Windows.Visibility]::Collapsed
        $script:UI['CompactPanel'].Visibility = [System.Windows.Visibility]::Visible
        foreach ($n in 'MinimizeButton', 'PinButton', 'SettingsButton', 'CloseButton') {
            $script:UI[$n].Visibility = [System.Windows.Visibility]::Collapsed
        }
        $script:UI['Card'].Width = 146
    }

    $card = $script:UI['Card']
    $inf = [double]::PositiveInfinity
    $card.Measure([System.Windows.Size]::new($inf, $inf))
    $width = [int][math]::Ceiling($card.DesiredSize.Width)
    $height = [int][math]::Ceiling($card.DesiredSize.Height)
    $card.Arrange([System.Windows.Rect]::new(0, 0, [double]$width, [double]$height))
    $card.UpdateLayout()

    Set-BarWidth 'CpuTrack' 'CpuBar' 23
    Set-BarWidth 'MemTrack' 'MemBar' 61
    $card.UpdateLayout()
    Refresh-Picker
    Update-OpacityBar
    $card.UpdateLayout()

    $scale = 2.0
    $bitmap = [System.Windows.Media.Imaging.RenderTargetBitmap]::new(
        [int]($width * $scale), [int]($height * $scale),
        (96.0 * $scale), (96.0 * $scale), [System.Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($card)

    $encoder = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [IO.File]::Create($Path)
    try { $encoder.Save($stream) } finally { $stream.Close() }

    Write-Host "预览已生成：$Path  (${width}x${height})"
}

# ============================================================ 自检 =========
function Invoke-SelfTest {
    Write-Host '=== 桌面小组件自检 ==='
    $null = New-Widget
    Initialize-Counters
    Write-Host ('内存总量：{0:0.0} GB' -f ($script:MemTotalKb / 1048576.0))
    Write-Host ('时区：{0} {1}' -f [TimeZoneInfo]::Local.DisplayName, (Format-TzLabel ([TimeZoneInfo]::Local.BaseUtcOffset)))

    Start-Location

    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt 35) {
        Update-Tick
        if ($script:WeatherState -eq 'ok') { break }
        if ($script:WeatherState -eq 'error' -and $watch.Elapsed.TotalSeconds -gt 15) { break }
        Start-Sleep -Milliseconds 120
    }

    Write-Host ''
    Write-Host '--- 定位 ---'
    Write-Host ('来源：{0}  坐标：{1}, {2}  城市：{3}  时区：{4}' -f $script:Location.Source, $script:Location.Lat, $script:Location.Lon, $script:Location.City, $script:Location.TimeZone)
    Write-Host '--- 天气 ---'
    Write-Host ('状态：{0}   数据源：{1}   错误：{2}' -f $script:WeatherState, $script:Providers[$script:ProviderIndex], $script:WeatherError)
    if ($script:Weather) {
        Write-Host ('温度：{0}°  {1}   最高 {2}° 最低 {3}°   体感 {4}°   湿度 {5}%   更新 {6}' -f `
                $script:Weather.Temp, $script:Weather.Cond.Text, $script:Weather.Hi, $script:Weather.Lo, $script:Weather.Feels, $script:Weather.Hum, $script:Weather.UpdatedAt.ToString('HH:mm:ss'))
    }
    Write-Host '--- 系统 ---'
    Write-Host ('CPU：{0}%   内存：{1}%' -f $script:LastCpu, $script:LastMem)
    Write-Host ''

    if ($script:WeatherState -eq 'ok') {
        Write-Host '结论：正常。'
        return 0
    }
    Write-Host '结论：天气未取到，详见 logs\widget.log'
    return 1
}

# ============================================================ 启动 =========
$script:MutexName = 'Local\DesktopWidget_WeatherClock_1'
$script:ShowEventName = 'Local\DesktopWidget_Show_1'

function Invoke-Run {
    $mutex = [System.Threading.Mutex]::new($false, $script:MutexName)
    if (-not $mutex.WaitOne(0)) {
        # 已经有实例在跑：让它显示出来（任务栏固定了快捷方式的场景）
        try {
            $existing = [System.Threading.EventWaitHandle]::OpenExisting($script:ShowEventName)
            $null = $existing.Set()
            $existing.Dispose()
            Write-Log '已有实例在运行，已请求它显示窗口'
        } catch {
            Write-Log '已有实例在运行，本次启动退出'
        }
        return
    }

    try {
        $script:ShowEvent = [System.Threading.EventWaitHandle]::new(
            $false, [System.Threading.EventResetMode]::AutoReset, $script:ShowEventName)
    } catch {
        Write-Log "创建显示事件失败：$($_.Exception.Message)"
        $script:ShowEvent = $null
    }

    $app = [System.Windows.Application]::new()
    $app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown

    $null = New-Widget
    Initialize-Counters
    Initialize-Tray

    Read-Theme
    Apply-ThemeDefaults
    Apply-ThemeRadius
    $firstRun = -not (Test-Path -LiteralPath (Join-Path $script:Root 'config.json'))
    if ($firstRun) {
        Save-Config
        Write-Log '首次运行：已生成默认 config.json'
    }
    $script:Tasks = Read-Tasks
    Import-AiAdapters

    if (Restore-CachedWeather) {
        Update-WeatherUI
    }

    $script:Window.Show()
    $script:Window.UpdateLayout()
    $script:Window.UpdateLayout()

    $workArea = [System.Windows.SystemParameters]::WorkArea
    $placed = $false
    $savedLeft = $script:Config['left']
    $savedTop = $script:Config['top']
    if ($null -ne $savedLeft -and $null -ne $savedTop) {
        $l = [double]$savedLeft
        $t = [double]$savedTop
        if ($l -ge ($workArea.Left - 120) -and $l -le ($workArea.Right - 80) -and
            $t -ge ($workArea.Top - 120) -and $t -le ($workArea.Bottom - 80)) {
            $script:Window.Left = $l
            $script:Window.Top = $t
            $placed = $true
        }
    }
    if (-not $placed) {
        $script:Window.Left = [math]::Round($workArea.Right - $script:Window.ActualWidth - 18)
        $script:Window.Top = [math]::Round($workArea.Bottom - $script:Window.ActualHeight - 18)
    }
    # SizeToContent 的首帧高度可能还没算准，兜底再钳一次，别让卡片掉出屏幕
    Ensure-WindowOnScreen

    # 个别机器上分层窗口的首帧会丢，主动让系统重绘一次（不抢焦点、不改位置）
    try {
        if (-not ('DesktopWidget.Native' -as [type])) {
            Add-Type -Namespace DesktopWidget -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
'@
        }
        $hwnd = ([System.Windows.Interop.WindowInteropHelper]::new($script:Window)).Handle
        if ($hwnd -ne [IntPtr]::Zero) {
            # 尊重「置顶」开关：关了置顶就只提到普通层顶部
            if ($script:Window.Topmost) { $insertAfter = [IntPtr](-1) } else { $insertAfter = [IntPtr]::Zero }
            $null = [DesktopWidget.Native]::SetWindowPos($hwnd, $insertAfter, 0, 0, 0, 0, 0x0040 -bor 0x0010 -bor 0x0002 -bor 0x0001)
        }
        Write-Log ('窗口位置：{0},{1}  尺寸 {2}x{3}' -f [math]::Round($script:Window.Left), [math]::Round($script:Window.Top),
            [math]::Round($script:Window.ActualWidth), [math]::Round($script:Window.ActualHeight))
    } catch {
        Write-Log "窗口重绘失败：$($_.Exception.Message)"
    }

if ($firstRun -and $script:UI['FirstRunHint']) {
        $script:UI['FirstRunHint'].Visibility = [System.Windows.Visibility]::Visible
        Open-Settings
    }

    $script:Ready = $true

    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromSeconds(1)
    $timer.Add_Tick({
            try { Update-Tick } catch { Write-Log "主循环异常：$($_.Exception.Message)" }
        })
    $timer.Start()

    Update-Tick
    Update-TasksUI
    Ensure-WindowOnScreen
    Start-Location
    Write-Log '小组件已启动'

    $app.Run()
    $timer.Stop()
    Save-Config
}

# ============================================================ 入口 =========
$exitCode = 0
try {
    if ($Test) {
        $exitCode = Invoke-SelfTest
    } elseif ($Preview) {
        Invoke-Preview -Path $PreviewPath
    } elseif ($MakeShortcut) {
        New-TaskbarShortcut
    } else {
        Invoke-Run
    }
} catch {
    Write-Log "致命错误：$($_.Exception.Message)`r`n$($_.ScriptStackTrace)"
    if ($Test -or $Preview -or $MakeShortcut) {
        Write-Host "失败：$($_.Exception.Message)"
        Write-Host $_.ScriptStackTrace
        $exitCode = 1
    } else {
        [System.Windows.MessageBox]::Show("小组件启动失败：`r`n$($_.Exception.Message)`r`n`r`n日志：$($script:LogPath)", '桌面小组件') | Out-Null
        $exitCode = 1
    }
}
exit $exitCode
