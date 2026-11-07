# =====================================================================
#  Antigravity 启动器 v3.0  (launcher-core.ps1)
#  由同目录 “启动 Antigravity.bat” 调用；也可手动：
#      powershell -NoProfile -ExecutionPolicy Bypass -File launcher-core.ps1
#  参数：
#      -Restart    强制结束已在运行的 Antigravity 后重新启动
#      -Diagnose   只做环境诊断，不启动
#      -NoProxy    本次不使用代理（直接启动）
#      -Help       显示帮助
# =====================================================================
[CmdletBinding()]
param(
    [switch]$Restart,
    [switch]$Diagnose,
    [switch]$NoProxy,
    [switch]$RestoreOfficial,
    [switch]$Help
)

$script:LauncherVersion = '3.0'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }
try { $Host.UI.RawUI.WindowTitle = 'Antigravity 启动器 v3.0' } catch { }

if (-not $PSScriptRoot) { $script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path } else { $script:Root = $PSScriptRoot }
$script:ConfigFile   = Join-Path $script:Root 'config.json'
$script:LogDir       = Join-Path $env:LOCALAPPDATA 'AntigravityLauncher'
$script:LauncherLog  = Join-Path $script:LogDir 'launcher.log'
$script:CurlPath     = $null
$script:MainLogOffset = 0

# ---------------------------------------------------------------------
# 基础输出 / 日志
# ---------------------------------------------------------------------
function Initialize-Console {
    try {
        if ([Console]::WindowWidth -lt 70) { [Console]::BufferWidth = 90 }
    } catch { }
}

function Initialize-Log {
    if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
    try {
        if ((Test-Path $script:LauncherLog) -and ((Get-Item $script:LauncherLog).Length -gt 512KB)) {
            Move-Item $script:LauncherLog ($script:LauncherLog + '.1') -Force
        }
    } catch { }
}

function Write-Log {
    param([string]$Message)
    try {
        Add-Content -Path $script:LauncherLog -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message) -Encoding UTF8
    } catch { }
}

function Write-Sep {
    Write-Host ('  ' + ('-' * 64)) -ForegroundColor DarkGray
}

function Write-Step {
    param([string]$Message)
    Write-Host ''
    Write-Host ('  >> ' + $Message) -ForegroundColor Cyan
    Write-Log ('STEP ' + $Message)
}

function Write-Ok {
    param([string]$Message)
    Write-Host ('  [通过] ' + $Message) -ForegroundColor Green
    Write-Log ('OK   ' + $Message)
}

function Write-Warn {
    param([string]$Message)
    Write-Host ('  [注意] ' + $Message) -ForegroundColor Yellow
    Write-Log ('WARN ' + $Message)
}

function Write-Fail {
    param([string]$Message)
    Write-Host ('  [失败] ' + $Message) -ForegroundColor Red
    Write-Log ('FAIL ' + $Message)
}

function Write-Info {
    param([string]$Message)
    Write-Host ('         ' + $Message) -ForegroundColor Gray
    Write-Log ('INFO ' + $Message)
}

function Write-Banner {
    Write-Host ''
    Write-Host '  ================================================================' -ForegroundColor DarkCyan
    Write-Host ('                 Antigravity 启动器  v' + $script:LauncherVersion) -ForegroundColor Cyan
    Write-Host '        自动检测安装位置 / 代理 / 连通性，并验证界面加载' -ForegroundColor DarkGray
    Write-Host '  ================================================================' -ForegroundColor DarkCyan
}

# ---------------------------------------------------------------------
# 交互（带超时；不可交互时自动使用默认值）
# ---------------------------------------------------------------------
function Test-KeyAvailable {
    try {
        if ([Console]::IsInputRedirected) { return $false }
        return [Console]::KeyAvailable
    } catch { return $false }
}

function Read-KeyChoice {
    param(
        [string]$Prompt,
        [string[]]$Keys,
        [string]$DefaultKey,
        [int]$TimeoutSec = 15
    )
    $keysUpper = @($Keys | ForEach-Object { $_.ToUpperInvariant() })
    $Def = $DefaultKey.ToUpperInvariant()
    if ([Console]::IsInputRedirected) {
        Write-Host ('  ' + $Prompt + ' -> 默认 ' + $Def) -ForegroundColor Yellow
        return $Def
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $lastShown = -1
    while ((Get-Date) -lt $deadline) {
        if (Test-KeyAvailable) {
            $k = [Console]::ReadKey($true).KeyChar
            $s = ([string]$k).ToUpperInvariant()
            if ($keysUpper -contains $s) {
                Write-Host ($Prompt + ' -> ' + $s) -ForegroundColor Yellow
                return $s
            }
        }
        $rem = [int][Math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)
        if ($rem -ne $lastShown) {
            Write-Host ("`r  $Prompt (剩余 $rem 秒，默认 $Def)      ") -ForegroundColor Yellow -NoNewline
            $lastShown = $rem
        }
        Start-Sleep -Milliseconds 120
    }
    Write-Host ("`r  $Prompt -> 默认 $Def (超时)          ") -ForegroundColor Yellow
    return $Def
}

# ---------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------
function Normalize-Config {
    param($Raw)
    $cfg = [ordered]@{
        AppPath              = 'auto'
        ProxyUrl             = 'auto'
        ExtraArgs            = @()
        CleanStaleProcesses  = $true
        CheckConnectivity    = $true
        VerifyUi             = 'auto'
        UiRetries            = 1
        UiVerifyTimeoutSec   = 40
        KeepWindowOpen       = $false
    }
    if ($null -eq $Raw) { return $cfg }
    foreach ($p in $Raw.PSObject.Properties) {
        if ($cfg.Contains($p.Name)) { $cfg[$p.Name] = $p.Value }
    }
    if ($cfg.ExtraArgs -isnot [array]) {
        if ([string]::IsNullOrWhiteSpace([string]$cfg.ExtraArgs)) { $cfg.ExtraArgs = @() }
        else { $cfg.ExtraArgs = @([string]$cfg.ExtraArgs) }
    }
    return $cfg
}

function Read-LauncherConfig {
    if (-not (Test-Path $script:ConfigFile)) {
        $default = @'
{
  "AppPath": "auto",
  "ProxyUrl": "auto",
  "ExtraArgs": [],
  "CleanStaleProcesses": true,
  "CheckConnectivity": true,
  "VerifyUi": "auto",
  "UiRetries": 1,
  "UiVerifyTimeoutSec": 40,
  "KeepWindowOpen": false
}
'@
        try {
            [System.IO.File]::WriteAllText($script:ConfigFile, $default, (New-Object System.Text.UTF8Encoding $false))
            Write-Info ('已生成默认配置文件: ' + $script:ConfigFile)
        } catch { Write-Warn ('无法写入配置文件: ' + $_.Exception.Message) }
    }
    try {
        $raw = Get-Content $script:ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
        return (Normalize-Config $raw)
    } catch {
        Write-Warn ('配置文件格式有误，使用默认配置: ' + $_.Exception.Message)
        return (Normalize-Config $null)
    }
}

function Save-Config {
    param($Cfg)
    try {
        $obj = [ordered]@{}
        foreach ($k in $Cfg.Keys) { $obj[$k] = $Cfg[$k] }
        $json = ConvertTo-Json $obj -Depth 5
        [System.IO.File]::WriteAllText($script:ConfigFile, $json, (New-Object System.Text.UTF8Encoding $false))
    } catch { }
}

# ---------------------------------------------------------------------
# 安装位置检测
# ---------------------------------------------------------------------
function Get-ShortcutTargets {
    $result = @()
    $ws = $null
    try { $ws = New-Object -ComObject WScript.Shell } catch { return $result }
    $dirs = @(
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('CommonDesktopDirectory'),
        [Environment]::GetFolderPath('StartMenu'),
        [Environment]::GetFolderPath('CommonStartMenu')
    ) | Where-Object { $_ -and (Test-Path $_) }
    foreach ($d in $dirs) {
        Get-ChildItem -Path $d -Filter '*.lnk' -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'Antigravity' } |
            ForEach-Object {
                try {
                    $sc = $ws.CreateShortcut($_.FullName)
                    if ($sc.TargetPath -and $sc.TargetPath -match '(?i)antigravity.*\.exe$') {
                        $result += [pscustomobject]@{ Path = $sc.TargetPath; Source = ('快捷方式 ' + $_.Name) }
                    }
                } catch { }
            }
    }
    return $result
}

function Get-RegistryInstallPaths {
    $result = @()
    $keys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($k in $keys) {
        Get-ItemProperty -Path $k -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match '(?i)antigravity' } |
            ForEach-Object {
                $cand = @()
                if ($_.DisplayIcon) {
                    $icon = ([string]$_.DisplayIcon).Trim('"')
                    $icon = ($icon -split ',')[0].Trim('"')
                    if ($icon -match '(?i)\.exe$') { $cand += $icon }
                }
                if ($_.InstallLocation) {
                    $loc = ([string]$_.InstallLocation).Trim('"')
                    $cand += (Join-Path $loc 'Antigravity.exe')
                    $cand += (Join-Path $loc 'Antigravity IDE.exe')
                }
                foreach ($c in $cand) {
                    if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) {
                        $result += [pscustomobject]@{ Path = $c; Source = ('注册表 ' + $_.DisplayName) }
                    }
                }
            }
    }
    return $result
}

function Get-StandardInstallPaths {
    $names = @('Antigravity.exe', 'Antigravity IDE.exe')
    $dirs = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Antigravity'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Antigravity IDE'),
        (Join-Path $env:LOCALAPPDATA 'Antigravity'),
        (Join-Path $env:ProgramFiles 'Antigravity'),
        (Join-Path ${env:ProgramFiles(x86)} 'Antigravity')
    )
    $result = @()
    foreach ($d in $dirs) {
        if (-not $d) { continue }
        foreach ($n in $names) {
            $p = Join-Path $d $n
            if (Test-Path -LiteralPath $p -PathType Leaf) {
                $result += [pscustomobject]@{ Path = $p; Source = '常见安装目录' }
            }
        }
    }
    return $result
}

function Resolve-AppPath {
    param($Cfg)
    # 1) 配置指定
    if ($Cfg.AppPath -and $Cfg.AppPath -ne 'auto') {
        if (Test-Path -LiteralPath $Cfg.AppPath -PathType Leaf) {
            return [pscustomobject]@{ Path = $Cfg.AppPath; Source = 'config.json 指定' }
        }
        Write-Warn ('config.json 中指定的 AppPath 不存在: ' + $Cfg.AppPath)
    }
    # 2) 启停快捷方式 -> 常见目录 -> 注册表
    $all = @()
    $all += @(Get-ShortcutTargets)
    $all += @(Get-StandardInstallPaths)
    $all += @(Get-RegistryInstallPaths)
    foreach ($c in $all) {
        if ($c -and $c.Path -and (Test-Path -LiteralPath $c.Path -PathType Leaf)) { return $c }
    }
    return $null
}

# ---------------------------------------------------------------------
# 代理检测
# ---------------------------------------------------------------------
function Get-SystemProxyInfo {
    $info = [pscustomobject]@{
        Enabled     = $false
        Server      = ''
        Override    = ''
        AutoConfig  = ''
        Url         = ''
    }
    try {
        $reg = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
        if ($reg) {
            $info.Enabled  = ([int]$reg.ProxyEnable -eq 1)
            $info.Server   = [string]$reg.ProxyServer
            $info.Override = [string]$reg.ProxyOverride
            $info.AutoConfig = [string]$reg.AutoConfigURL
            $info.Url = ConvertTo-ProxyUrl $info.Server
        }
    } catch { }
    return $info
}

function ConvertTo-ProxyUrl {
    param([string]$Server)
    if ([string]::IsNullOrWhiteSpace($Server)) { return '' }
    $s = $Server.Trim()
    if ($s -match '=') {
        $parts = @($s -split ';' | Where-Object { $_ -match '=' })
        $pick = $parts | Where-Object { $_ -match '^(?i)https?=' } | Select-Object -First 1
        if (-not $pick) { $pick = $parts | Where-Object { $_ -match '^(?i)socks=' } | Select-Object -First 1 }
        if (-not $pick) { return '' }
        $s = ($pick -split '=', 2)[1].Trim()
    }
    $s = $s.Trim().TrimEnd('/')
    if ($s -match '^(?i)(https?|socks5h?)://') { return $s }
    if ($s -match '^[^:\s]+:\d{2,5}$') { return ('http://' + $s) }
    return ''
}

function Test-TcpEndpoint {
    param([string]$ComputerName, [int]$Port, [int]$TimeoutMs = 900)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch { return $false } finally { try { $client.Close() } catch { } }
}

function Get-ProxyHostPort {
    param([string]$ProxyUrl)
    $uri = $null
    try { $uri = [Uri]$ProxyUrl } catch { return $null }
    if (-not $uri -or -not $uri.Host) { return $null }
    return [pscustomobject]@{ Host = $uri.Host; Port = $uri.Port; Scheme = $uri.Scheme }
}

function Resolve-Proxy {
    param($Cfg)
    $result = [pscustomobject]@{
        Url        = ''
        Source     = '未使用代理'
        IsSystem   = $false
        System     = (Get-SystemProxyInfo)
        Candidates = @()
    }
    if ($NoProxy -or ([string]$Cfg.ProxyUrl) -eq 'off') {
        $result.Source = '按设置不使用代理'
        return $result
    }
    $pref = [string]$Cfg.ProxyUrl
    # 1) 配置显式指定
    if ($pref -and $pref -ne 'auto') {
        $u = ConvertTo-ProxyUrl $pref
        if ($u) {
            $hp = Get-ProxyHostPort $u
            if ($hp -and (Test-TcpEndpoint -ComputerName $hp.Host -Port $hp.Port)) {
                $result.Url = $u; $result.Source = 'config.json 指定'; return $result
            }
            Write-Warn ('config.json 指定的代理当前无法连接: ' + $u)
        } else {
            Write-Warn ('config.json 中 ProxyUrl 格式无法识别: ' + $pref)
        }
    }
    # 2) Windows 系统代理
    $sys = $result.System
    if ($sys.Enabled -and $sys.Url) {
        $hp = Get-ProxyHostPort $sys.Url
        if ($hp -and (Test-TcpEndpoint -ComputerName $hp.Host -Port $hp.Port)) {
            $result.Url = $sys.Url; $result.Source = 'Windows 系统代理'; $result.IsSystem = $true
            return $result
        }
        Write-Warn ('系统代理已开启但无法连接: ' + $sys.Url)
        $result.Candidates += $sys.Url
    } elseif ($sys.Enabled -and $sys.AutoConfig) {
        Write-Warn ('系统使用 PAC 自动配置: ' + $sys.AutoConfig)
    }
    # 3) 常见本地代理端口探测
    $commonPorts = @(10808, 10809, 7890, 7897, 1080, 2080, 8889, 8118, 3128)
    foreach ($port in $commonPorts) {
        if (Test-TcpEndpoint -ComputerName '127.0.0.1' -Port $port) {
            $u = ('http://127.0.0.1:' + $port)
            if ($result.Candidates -notcontains $u) { $result.Candidates += $u }
            $result.Url = $u; $result.Source = ('端口探测 127.0.0.1:' + $port)
            return $result
        }
    }
    return $result
}

# ---------------------------------------------------------------------
# 连通性检测（curl）
# ---------------------------------------------------------------------
function Initialize-Curl {
    $cmd = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($cmd) { $script:CurlPath = $cmd.Source; return $true }
    foreach ($p in @("$env:SystemRoot\System32\curl.exe", "$env:SystemRoot\Sysnative\curl.exe")) {
        if (Test-Path $p) { $script:CurlPath = $p; return $true }
    }
    return $false
}

function ConvertTo-WinArgString {
    param([string[]]$Items)
    $out = @()
    foreach ($a in $Items) {
        $s = [string]$a
        if ($s -match '[\s"]') {
            $s = '"' + ($s -replace '"', '\"') + '"'
        }
        $out += $s
    }
    return ($out -join ' ')
}

function Invoke-CurlProbe {
    param([string]$Url, [string]$ProxyUrl, [int]$TimeoutSec = 15)
    $res = [pscustomobject]@{ ExitCode = -1; HttpCode = ''; Seconds = 0; Error = ''; Url = $Url; Proxy = $ProxyUrl }
    if (-not $script:CurlPath) { $res.Error = '未找到 curl.exe'; return $res }
    $curlArgs = @('-sS', '-o', 'NUL', '-w', '%{http_code}|%{time_total}', '--connect-timeout', '8', '--max-time', ([string]$TimeoutSec))
    if ($ProxyUrl) { $curlArgs += @('--proxy', $ProxyUrl) } else { $curlArgs += @('--noproxy', '*') }
    $curlArgs += $Url
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:CurlPath
        $psi.Arguments = ConvertTo-WinArgString $curlArgs
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $stdout = $p.StandardOutput.ReadToEnd()
        $stderr = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        $res.ExitCode = $p.ExitCode
        if ($stdout -match '(\d+)\|([\d\.]+)') {
            $res.HttpCode = $matches[1]
            $res.Seconds = [double]$matches[2]
        }
        $res.Error = (($stderr -replace '\s+', ' ').Trim())
        return $res
    } catch {
        $res.Error = $_.Exception.Message
        return $res
    }
}

function Test-ConnectivityTarget {
    param([string]$Name, [string]$Url, [string]$ProxyUrl, [int]$Attempts = 2)
    $last = $null
    for ($i = 1; $i -le $Attempts; $i++) {
        $r = Invoke-CurlProbe -Url $Url -ProxyUrl $ProxyUrl -TimeoutSec 12
        $last = $r
        if ($r.ExitCode -eq 0) { return [pscustomobject]@{ Name = $Name; Ok = $true; Result = $r; Attempts = $i } }
        if ($i -lt $Attempts) { Start-Sleep -Seconds 2 }
    }
    return [pscustomobject]@{ Name = $Name; Ok = $false; Result = $last; Attempts = $Attempts }
}

function Invoke-ConnectivityChecks {
    param([string]$ProxyUrl)
    $targets = @(
        @{ Name = 'Google 账号服务 (oauth2.googleapis.com)'; Url = 'https://oauth2.googleapis.com/token' },
        @{ Name = 'Code Assist 服务 (daily-cloudcode-pa)'; Url = 'https://daily-cloudcode-pa.googleapis.com/' }
    )
    $results = @()
    foreach ($t in $targets) {
        $r = Test-ConnectivityTarget -Name $t.Name -Url $t.Url -ProxyUrl $ProxyUrl
        $results += $r
        if ($r.Ok) {
            $sec = [Math]::Round($r.Result.Seconds, 2)
            $note = ''
            if ($sec -ge 3) { $note = ' (较慢)' }
            Write-Ok ('{0} 可用{1}  耗时 {2}s' -f $r.Name, $note, $sec)
        } else {
            $msg = $r.Result.Error
            if ([string]::IsNullOrWhiteSpace($msg)) { $msg = ('curl 退出码 ' + $r.Result.ExitCode) }
            if ($msg.Length -gt 160) { $msg = $msg.Substring(0, 160) + '...' }
            Write-Fail ('{0} 不可用: {1}' -f $r.Name, $msg)
        }
    }
    return $results
}

# ---------------------------------------------------------------------
# 进程 / 窗口
# ---------------------------------------------------------------------
function Get-AppProcessState {
    param([string]$ImageName)
    $escaped = $ImageName -replace "'", "''"
    $all = @(Get-CimInstance Win32_Process -Filter ("Name='{0}'" -f $escaped) -ErrorAction SilentlyContinue)
    $main = @()
    $helpers = @()
    foreach ($p in $all) {
        $cmd = [string]$p.CommandLine
        if ($cmd -match '--type=') { $helpers += $p } else { $main += $p }
    }
    $windows = @()
    foreach ($m in $main) {
        $wp = Get-Process -Id $m.ProcessId -ErrorAction SilentlyContinue
        if ($wp -and ($wp.MainWindowHandle -ne 0)) { $windows += $wp }
    }
    return [pscustomobject]@{
        All     = $all
        Main    = $main
        Helpers = $helpers
        Windows = $windows
    }
}

function Get-InstallDirProcesses {
    param([string]$InstallDir)
    if (-not $InstallDir) { return @() }
    $prefix = $InstallDir.TrimEnd('\').ToLowerInvariant() + '\'
    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $ep = [string]$_.ExecutablePath
            if ([string]::IsNullOrWhiteSpace($ep)) { return $false }
            return $ep.ToLowerInvariant().StartsWith($prefix)
        })
}

function Stop-AntigravityProcesses {
    param([string]$InstallDir)
    $killed = 0
    $targets = @(Get-InstallDirProcesses -InstallDir $InstallDir)
    if ($targets.Count -eq 0) { return 0 }
    foreach ($t in $targets) {
        try {
            Stop-Process -Id $t.ProcessId -Force -ErrorAction Stop
            $killed++
        } catch { }
    }
    # 等待退出
    $deadline = (Get-Date).AddSeconds(12)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 300
        $left = @(Get-InstallDirProcesses -InstallDir $InstallDir)
        if ($left.Count -eq 0) { break }
        foreach ($t in $left) { try { Stop-Process -Id $t.ProcessId -Force -ErrorAction Stop } catch { } }
    }
    return $killed
}

function Activate-AppWindow {
    param([int]$ProcessId)
    try {
        $ws = New-Object -ComObject WScript.Shell
        return [bool]$ws.AppActivate($ProcessId)
    } catch { return $false }
}

# ---------------------------------------------------------------------
# app.asar 备份检测（用于白屏提示）
# ---------------------------------------------------------------------
function Test-AsarBackupPresent {
    param([string]$InstallDir)
    if (-not $InstallDir) { return $false }
    return (Test-Path (Join-Path $InstallDir 'resources\app.asar.bak'))
}

# ---------------------------------------------------------------------
# 启动 & 校验
# ---------------------------------------------------------------------
function Build-ChromiumBypassList {
    param([string]$SystemOverride)
    $defaults = @('localhost', '127.0.0.1', '[::1]', '*.local')
    $extra = @()
    if (-not [string]::IsNullOrWhiteSpace($SystemOverride)) {
        foreach ($item in ($SystemOverride -split ';')) {
            $t = $item.Trim()
            if ([string]::IsNullOrWhiteSpace($t)) { continue }
            if ($t -match '^<[^>]+>$') { continue }
            $extra += $t
        }
    }
    $merged = @($defaults) + $extra | Select-Object -Unique
    return ($merged -join ';')
}

function Set-ProxyEnvironment {
    param([string]$ProxyUrl)
    $pairs = @()
    if ($ProxyUrl) {
        $pairs = @(
            @('HTTP_PROXY', $ProxyUrl), @('HTTPS_PROXY', $ProxyUrl), @('ALL_PROXY', $ProxyUrl),
            @('http_proxy', $ProxyUrl), @('https_proxy', $ProxyUrl), @('all_proxy', $ProxyUrl),
            @('NO_PROXY', 'localhost,127.0.0.1,::1,.local'), @('no_proxy', 'localhost,127.0.0.1,::1,.local')
        )
    } else {
        foreach ($n in 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy', 'NO_PROXY', 'no_proxy') {
            Remove-Item ('env:' + $n) -ErrorAction SilentlyContinue
        }
        return
    }
    foreach ($pair in $pairs) { Set-Item ('env:' + $pair[0]) $pair[1] }
}

function Start-AntigravityApp {
    param([string]$AppPath, [string[]]$AppArgs)
    $appDir = Split-Path -Parent $AppPath
    $argString = ConvertTo-WinArgString $AppArgs
    Write-Log ('LAUNCH ' + $AppPath + ' ' + $argString)
    if ([string]::IsNullOrWhiteSpace($argString)) {
        return (Start-Process -FilePath $AppPath -WorkingDirectory $appDir -PassThru)
    }
    return (Start-Process -FilePath $AppPath -WorkingDirectory $appDir -ArgumentList $argString -PassThru)
}

function Wait-AppWindow {
    param([System.Diagnostics.Process]$Process, [int]$TimeoutSec = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ($Process.HasExited) {
            return [pscustomobject]@{ Ok = $false; Exited = $true; ExitCode = $Process.ExitCode }
        }
        $p = Get-Process -Id $Process.Id -ErrorAction SilentlyContinue
        if ($p -and ($p.MainWindowHandle -ne 0)) {
            return [pscustomobject]@{ Ok = $true; Exited = $false; Window = $p }
        }
        Start-Sleep -Milliseconds 350
    }
    return [pscustomobject]@{ Ok = $false; Exited = $false; ExitCode = $null }
}

function Get-MainLogLength {
    try {
        if (Test-Path $script:MainLog) { return (Get-Content $script:MainLog -Raw -ErrorAction SilentlyContinue).Length }
    } catch { }
    return 0
}

function Read-MainLogSince {
    param([int]$Offset)
    try {
        if (-not (Test-Path $script:MainLog)) { return '' }
        $text = Get-Content $script:MainLog -Raw -ErrorAction SilentlyContinue
        if ($null -eq $text) { return '' }
        if ($Offset -lt 0 -or $Offset -gt $text.Length) { return $text }
        return $text.Substring($Offset)
    } catch { return '' }
}

function Test-LastSessionFailed {
    $text = ''
    try {
        if (Test-Path $script:MainLog) {
            $raw = Get-Content $script:MainLog -Raw -ErrorAction SilentlyContinue
            if ($raw) {
                $idx = $raw.LastIndexOf('Starting app')
                if ($idx -ge 0) { $text = $raw.Substring($idx) }
            }
        }
    } catch { }
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    return ($text -match 'Failed to load URL')
}

function Wait-UiHealthy {
    param([int]$Offset, [int]$TimeoutSec = 40)
    $start = Get-Date
    $deadline = $start.AddSeconds($TimeoutSec)
    $lastShown = -1
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 800
        $new = Read-MainLogSince -Offset $Offset
        $m = [regex]::Match($new, 'Failed to load URL:\s+(\S+)\s+with error:\s+(ERR_\w+)')
        if ($m.Success) {
            return [pscustomobject]@{ Status = 'Failed'; Url = $m.Groups[1].Value; Code = $m.Groups[2].Value; Elapsed = ((Get-Date) - $start).TotalSeconds }
        }
        if (Test-KeyAvailable) {
            $null = [Console]::ReadKey($true)
            Write-Host ''
            return [pscustomobject]@{ Status = 'Skipped'; Url = ''; Code = ''; Elapsed = ((Get-Date) - $start).TotalSeconds }
        }
        $elapsed = [int]((Get-Date) - $start).TotalSeconds
        if ($elapsed -ne $lastShown) {
            Write-Host ("`r  正在验证界面加载 ... {0}s / {1}s  (按任意键跳过)   " -f $elapsed, $TimeoutSec) -ForegroundColor DarkGray -NoNewline
            $lastShown = $elapsed
        }
    }
    Write-Host ''
    return [pscustomobject]@{ Status = 'Ok'; Url = ''; Code = ''; Elapsed = ((Get-Date) - $start).TotalSeconds }
}

# ---------------------------------------------------------------------
# 诊断
# ---------------------------------------------------------------------
function Show-Diagnose {
    param($Cfg, $App, $ProxyInfo)
    Write-Sep
    Write-Host '  [环境诊断]' -ForegroundColor Cyan
    Write-Info ('启动器版本      : ' + $script:LauncherVersion)
    Write-Info ('PowerShell 版本 : ' + $PSVersionTable.PSVersion.ToString())
    Write-Info ('配置文件        : ' + $script:ConfigFile)
    Write-Info ('启动器日志      : ' + $script:LauncherLog)
    if ($App) {
        Write-Info ('Antigravity     : ' + $App.Path)
        Write-Info ('来源            : ' + $App.Source)
        Write-Info ('安装目录        : ' + (Split-Path -Parent $App.Path))
        Write-Info ('app.asar.bak    : ' + (Test-AsarBackupPresent (Split-Path -Parent $App.Path)))
    } else {
        Write-Fail '未检测到 Antigravity 安装位置'
    }
    $sys = Get-SystemProxyInfo
    $sysProxyText = '未开启'
    if ($sys.Enabled) { $sysProxyText = '已开启 ' + $sys.Server }
    $pacText = '无'
    if ($sys.AutoConfig) { $pacText = $sys.AutoConfig }
    $proxyText = '无'
    if ($ProxyInfo -and $ProxyInfo.Url) { $proxyText = $ProxyInfo.Url + ' (' + $ProxyInfo.Source + ')' }
    $curlText = '未找到'
    if ($script:CurlPath) { $curlText = $script:CurlPath }
    Write-Info ('Windows 系统代理: ' + $sysProxyText)
    Write-Info ('PAC 自动配置    : ' + $pacText)
    Write-Info ('使用代理        : ' + $proxyText)
    Write-Info ('curl.exe        : ' + $curlText)
    Write-Info ('main.log        : ' + $script:MainLog)
    Write-Info ('language_server : ' + (Join-Path (Split-Path -Parent $script:MainLog) 'language_server.log'))
    Write-Info ('上次界面加载失败: ' + (Test-LastSessionFailed))
    if ($App) {
        $image = [System.IO.Path]::GetFileName($App.Path)
        $state = Get-AppProcessState -ImageName $image
        Write-Info ('当前进程        : 共 ' + $state.All.Count + ' 个 (主进程 ' + $state.Main.Count + ', 辅助 ' + $state.Helpers.Count + ', 窗口 ' + $state.Windows.Count + ')')
        $installDir = Split-Path -Parent $App.Path
        if ($state.All.Count -gt 0) {
            foreach ($p in (Get-InstallDirProcesses -InstallDir $installDir)) {
                Write-Info ('    PID ' + $p.ProcessId + '  ' + $p.Name)
            }
        }
    }
    if ($script:CurlPath) {
        Write-Sep
        Write-Host '  [Google 连通性]' -ForegroundColor Cyan
        $useProxy = $null
        if ($ProxyInfo -and $ProxyInfo.Url) { $useProxy = $ProxyInfo.Url }
        if (-not $NoProxy -and $useProxy) {
            Write-Info ('经代理 ' + $useProxy + ' 检测:')
            $null = Invoke-ConnectivityChecks -ProxyUrl $useProxy
        } else {
            Write-Info '直连检测:'
            $null = Invoke-ConnectivityChecks -ProxyUrl ''
        }

        # ---- 断链/稳定性检测 ----
        Write-Sep
        Write-Host '  [网络稳定性 / 断链检测]' -ForegroundColor Cyan
        $testProxy = ''
        if (-not $NoProxy -and $useProxy) { $testProxy = $useProxy }
        $probeUrls = @(
            @{ n = 'gstatic 204'; u = 'https://www.gstatic.com/generate_204' },
            @{ n = 'Code Assist 首页'; u = 'https://daily-cloudcode-pa.googleapis.com/' },
            @{ n = 'Code Assist 接口'; u = 'https://daily-cloudcode-pa.googleapis.com/v1internal:listExperiments' }
        )
        $okCount = 0
        $failCount = 0
        $failDetail = @()
        foreach ($pu in $probeUrls) {
            for ($pi = 1; $pi -le 5; $pi++) {
                $pr = Invoke-CurlProbe -Url $pu.u -ProxyUrl $testProxy -TimeoutSec 10
                if ($pr.ExitCode -eq 0) {
                    $okCount++
                } else {
                    $failCount++
                    $errText = $pr.Error
                    if ([string]::IsNullOrWhiteSpace($errText)) { $errText = ('curl 退出码 ' + $pr.ExitCode) }
                    if ($errText.Length -gt 60) { $errText = $errText.Substring(0, 60) + '...' }
                    $failDetail += ($pu.n + ' -> ' + $errText)
                }
                Start-Sleep -Milliseconds 120
            }
        }
        $totalProbe = $okCount + $failCount
        $failRate = 0
        if ($totalProbe -gt 0) { $failRate = [int][Math]::Round(100.0 * $failCount / $totalProbe) }
        Write-Info ('探测 ' + $totalProbe + ' 次: 成功 ' + $okCount + '，失败 ' + $failCount + '（失败率 ' + $failRate + '%）')
        if ($failCount -eq 0) {
            Write-Ok '链路稳定，未发现断链'
        } elseif ($failRate -le 10) {
            Write-Warn '存在偶发断链（多由代理节点/线路波动引起，客户端通常会自动重试）'
            Write-Info ('失败样例: ' + (($failDetail | Select-Object -First 3) -join ' ; '))
        } else {
            Write-Warn '断链较频繁，建议更换代理节点后重新检测'
            Write-Info ('失败样例: ' + (($failDetail | Select-Object -First 3) -join ' ; '))
        }
        Write-Info ('客户端侧网络错误可查看: ' + (Join-Path (Split-Path -Parent $script:MainLog) 'language_server.log'))
        Write-Info '  （搜索 EOF / deadline exceeded / connection reset 等关键词）'
    }
    Write-Sep
}

function Show-Help {
    Write-Host ''
    Write-Host '  用法：' -ForegroundColor Cyan
    Write-Host '    双击 “Antigravity-Launcher.bat”             正常启动'
    Write-Host '    Antigravity-Launcher.bat -Restart          强制重启（先结束后台残留再启动）'
    Write-Host '    Antigravity-Launcher.bat -Diagnose         只诊断，不启动'
    Write-Host '    Antigravity-Launcher.bat -NoProxy          本次不使用代理'
    Write-Host '    双击 “恢复官方客户端.bat”                   撤销汉化补丁，恢复官方 app.asar / language_server.exe'
    Write-Host ''
    Write-Host '  配置文件：config.json（与启动器同目录），常用项：' -ForegroundColor Cyan
    Write-Host '    AppPath    : "auto" 或 exe 完整路径'
    Write-Host '    ProxyUrl   : "auto" / "off" / "http://127.0.0.1:10808"'
    Write-Host '    ExtraArgs  : 额外命令行参数数组'
    Write-Host '    VerifyUi   : "auto" / true / false    启动后是否验证界面加载'
    Write-Host '    UiRetries  : 界面加载失败自动重试次数（默认 1）'
    Write-Host ''
}

# ---------------------------------------------------------------------
# 恢复官方客户端文件（撤销汉化补丁）
# ---------------------------------------------------------------------
function Invoke-RestoreOfficial {
    param([string]$InstallDir)
    Write-Step '恢复官方客户端文件（撤销汉化补丁）'
    $res = Join-Path $InstallDir 'resources'
    $asar = Join-Path $res 'app.asar'
    $asarBak = Join-Path $res 'app.asar.bak'
    $ls = Join-Path $res 'bin\language_server.exe'
    $lsBak = Join-Path $res 'bin\language_server.exe.agybak'
    $hasAsar = Test-Path $asarBak
    $hasLs = Test-Path $lsBak
    if (-not $hasAsar -and -not $hasLs) {
        Write-Warn '未找到官方原版备份（app.asar.bak / language_server.exe.agybak），无法自动恢复。'
        Write-Info ('请检查目录: ' + $res)
        return 7
    }
    Write-Info ('app.asar.bak                : ' + $hasAsar)
    Write-Info ('language_server.exe.agybak  : ' + $hasLs)
    $choice = Read-KeyChoice -Prompt '确认恢复官方版本吗? [Y]恢复 / [N]取消' -Keys @('Y', 'N') -DefaultKey 'N' -TimeoutSec 20
    if ($choice -ne 'Y') { Write-Info '已取消，未做任何更改。'; return 0 }

    $killed = Stop-AntigravityProcesses -InstallDir $InstallDir
    Write-Info ('已结束 ' + $killed + ' 个客户端进程')
    Start-Sleep -Seconds 2
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'

    if ($hasAsar) {
        try {
            if (Test-Path $asar) { Copy-Item $asar (Join-Path $res ('app.asar.hanbak.' + $stamp)) -Force -ErrorAction Stop }
            Copy-Item $asarBak $asar -Force -ErrorAction Stop
            Write-Ok 'app.asar 已恢复为官方版本'
        } catch {
            Write-Fail ('恢复 app.asar 失败: ' + $_.Exception.Message)
            return 7
        }
    }
    if ($hasLs) {
        try {
            if (Test-Path $ls) { Copy-Item $ls (Join-Path (Split-Path -Parent $ls) ('language_server.exe.hanbak.' + $stamp)) -Force -ErrorAction Stop }
            Copy-Item $lsBak $ls -Force -ErrorAction Stop
            Write-Ok 'language_server.exe 已恢复为官方版本'
        } catch {
            Write-Fail ('恢复 language_server.exe 失败: ' + $_.Exception.Message)
            return 7
        }
    }
    Write-Host ''
    Write-Ok '恢复完成（汉化会失效）。原来的汉化文件已备份为 *.hanbak.<时间戳>，需要时可再换回。'
    Write-Info '现在可以运行 Antigravity-Launcher.bat 正常启动。'
    return 0
}

# ---------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------
function Main {
    Initialize-Console
    Initialize-Log
    $switchText = @()
    if ($Restart) { $switchText += '-Restart' }
    if ($Diagnose) { $switchText += '-Diagnose' }
    if ($NoProxy) { $switchText += '-NoProxy' }
    if ($RestoreOfficial) { $switchText += '-RestoreOfficial' }
    if ($Help) { $switchText += '-Help' }
    Write-Log ('===== 启动器 v' + $script:LauncherVersion + ' 开始 (' + ($switchText -join ' ') + ') =====')
    Write-Banner

    if ($Help) { Show-Help; return 0 }

    $cfg = Read-LauncherConfig
    if (-not (Initialize-Curl)) {
        Write-Warn '未找到 curl.exe（Windows 10 1803+ 自带），将跳过连通性检测'
    }

    # ---- 1. 安装位置 ----
    Write-Step '1/5  检测 Antigravity 安装位置'
    $app = Resolve-AppPath -Cfg $cfg
    if (-not $app) {
        Write-Fail '未检测到 Antigravity 安装位置。'
        Write-Info '请确认已安装 Antigravity，或在 config.json 中把 AppPath 设为 Antigravity.exe 的完整路径。'
        Write-Info '已搜索：桌面/开始菜单快捷方式、注册表卸载项、常见安装目录。'
        return 2
    }
    $installDir = Split-Path -Parent $app.Path
    $imageName = [System.IO.Path]::GetFileName($app.Path)
    Write-Ok ('Antigravity 已找到 (' + $app.Source + ')')
    Write-Info $app.Path

    # ---- 恢复官方客户端（撤销汉化）----
    if ($RestoreOfficial) {
        return (Invoke-RestoreOfficial -InstallDir $installDir)
    }

    # ---- 2. 代理 ----
    Write-Step '2/5  检测可用代理'
    $proxy = Resolve-Proxy -Cfg $cfg
    if ($proxy.Url) {
        $mode = '系统代理'
        if (-not $proxy.IsSystem) { $mode = '启动参数注入' }
        Write-Ok ('代理可用: ' + $proxy.Url + '  (' + $proxy.Source + '，' + $mode + '方式生效)')
    } else {
        if ($NoProxy -or ([string]$cfg.ProxyUrl) -eq 'off') {
            Write-Info '本次不使用代理。'
        } else {
            Write-Warn '未检测到可用代理。'
            Write-Info '请确认 v2rayN 等代理软件已启动，端口通常为 10808 / 10809 / 7890 / 7897。'
            $choice = Read-KeyChoice -Prompt '仍要继续启动吗? [Y]继续 / [N]退出' -Keys @('Y', 'N') -DefaultKey 'Y' -TimeoutSec 12
            if ($choice -eq 'N') { return 3 }
        }
    }

    # ---- 诊断模式：在检测完代理后直接输出诊断信息 ----
    if ($Diagnose) {
        Show-Diagnose -Cfg $cfg -App $app -ProxyInfo $proxy
        return 0
    }

    # ---- 3. 连通性 ----
    $connectivityOk = $true
    if ($cfg.CheckConnectivity -and $script:CurlPath) {
        Write-Step '3/5  检测 Google 连通性'
        $results = @()
        if ($NoProxy -or -not $proxy.Url) {
            Write-Info '未使用代理，检测直连情况（中国大陆网络通常需要代理）...'
            $results = @(Invoke-ConnectivityChecks -ProxyUrl '')
        } else {
            $results = @(Invoke-ConnectivityChecks -ProxyUrl $proxy.Url)
        }
        $failed = @($results | Where-Object { -not $_.Ok }).Count
        if ($failed -gt 0) {
            $connectivityOk = $false
            Write-Warn ('有 ' + $failed + ' 项 Google 服务不可达，Antigravity 可能无法登录或使用 AI 功能。')
            $choice = Read-KeyChoice -Prompt '[R]重试检测 / [C]仍然启动 / [Q]退出' -Keys @('R', 'C', 'Q') -DefaultKey 'C' -TimeoutSec 20
            if ($choice -eq 'Q') { return 4 }
            if ($choice -eq 'R') {
                Write-Info '重新检测...'
                Start-Sleep -Seconds 1
                $retryProxy = ''
                if ($proxy.Url) { $retryProxy = $proxy.Url }
                $results = @(Invoke-ConnectivityChecks -ProxyUrl $retryProxy)
                $connectivityOk = (@($results | Where-Object { -not $_.Ok }).Count -eq 0)
            }
        }
    } else {
        Write-Step '3/5  连通性检测已跳过'
    }

    # ---- 4. 处理已在运行的实例 ----
    Write-Step '4/5  检查是否已有 Antigravity 在运行'
    $state = Get-AppProcessState -ImageName $imageName
    if ($state.All.Count -gt 0) {
        if ($state.Windows.Count -gt 0 -and -not $Restart) {
            $w = $state.Windows[0]
            Write-Warn ('Antigravity 已在运行 (PID ' + $w.Id + ', 标题: ' + $w.MainWindowTitle + ')')
            $null = Activate-AppWindow -ProcessId $w.Id
            Write-Info '已尝试把窗口切换到前台。'
            $choice = Read-KeyChoice -Prompt '[R]强制重启 / [其他]直接退出' -Keys @('R') -DefaultKey 'X' -TimeoutSec 10
            if ($choice -ne 'R') {
                Write-Info '未做任何更改。'
                return 0
            }
            $Restart = $true
        }
        if ($Restart -or $state.Windows.Count -eq 0) {
            if ($state.Windows.Count -eq 0) {
                Write-Warn ('检测到 ' + $state.All.Count + ' 个残留 Antigravity 进程（没有可见窗口），可能是上次异常退出留下的。')
            } else {
                Write-Warn '按 -Restart 执行强制重启，正在结束现有进程...'
            }
            if ($cfg.CleanStaleProcesses) {
                $killed = Stop-AntigravityProcesses -InstallDir $installDir
                Write-Ok ('已清理 ' + $killed + ' 个进程')
                $state = Get-AppProcessState -ImageName $imageName
                if ($state.All.Count -gt 0) {
                    Write-Warn ('仍有 ' + $state.All.Count + ' 个进程无法结束（可能权限较高），继续尝试启动。')
                }
            } else {
                Write-Warn 'config.json 中 CleanStaleProcesses 为 false，未清理残留进程。'
            }
        }
    } else {
        Write-Ok '没有正在运行的实例'
    }

    # ---- 5. 启动 ----
    Write-Step '5/5  启动 Antigravity'
    # 决定代理生效方式
    $launchArgs = @()
    $proxyMode = '不使用代理'
    if ($NoProxy -or ([string]$cfg.ProxyUrl) -eq 'off') {
        $proxyForLaunch = ''
    } else {
        $proxyForLaunch = $proxy.Url
    }
    if ($proxyForLaunch) {
        $sys = Get-SystemProxyInfo
        $sameAsSystem = ($sys.Enabled -and $sys.Url -and ($sys.Url -eq $proxyForLaunch))
        if ($sameAsSystem) {
            $proxyMode = '系统代理（不动启动参数）'
        } else {
            $bypass = Build-ChromiumBypassList -SystemOverride $sys.Override
            $launchArgs += ('--proxy-server=' + $proxyForLaunch)
            $launchArgs += ('--proxy-bypass-list=' + $bypass)
            $proxyMode = '启动参数注入'
        }
    }
    if ($cfg.ExtraArgs -and @($cfg.ExtraArgs).Count -gt 0) {
        $launchArgs += @($cfg.ExtraArgs)
    }
    Write-Info ('代理生效方式: ' + $proxyMode)
    if ($proxyMode -eq '启动参数注入') {
        Write-Info '（系统代理未启用或与检测到的代理不一致，已通过 --proxy-server 显式指定）'
    }
    if ($launchArgs.Count -gt 0) { Write-Info ('启动参数: ' + (ConvertTo-WinArgString $launchArgs)) }

    # 界面验证策略
    $verify = $cfg.VerifyUi
    if ($verify -is [string] -and $verify -eq 'auto') { $verify = Test-LastSessionFailed }
    $verify = [bool]$verify
    $uiTimeout = 40
    try { $uiTimeout = [int]$cfg.UiVerifyTimeoutSec } catch { }
    if ($uiTimeout -lt 10) { $uiTimeout = 10 }
    $retries = 0
    try { $retries = [int]$cfg.UiRetries } catch { }
    if ($retries -lt 0) { $retries = 0 }
    $maxAttempts = 1
    if ($verify) { $maxAttempts = 1 + $retries }
    if ($verify) {
        Write-Info ('已启用界面验证（最多 ' + $maxAttempts + ' 次尝试，单次最长 ' + $uiTimeout + ' 秒）')
    } else {
        Write-Info '界面验证未启用（如需检测白屏，可在 config.json 里把 VerifyUi 设为 true）'
    }

    # 环境变量：代理 + 清理可能干扰 Electron 的变量
    Set-ProxyEnvironment -ProxyUrl $proxyForLaunch
    $hadRunAsNode = $false
    if ($env:ELECTRON_RUN_AS_NODE) { $hadRunAsNode = $true; Remove-Item env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue }
    if ($hadRunAsNode) { Write-Warn '已清除环境变量 ELECTRON_RUN_AS_NODE（否则 Antigravity 可能只启动成 Node 进程后立刻退出）' }

    $attempt = 0
    $appProcess = $null
    while ($true) {
        $attempt++
        Write-Host ''
        Write-Host ('  -- 第 ' + $attempt + '/' + $maxAttempts + ' 次启动 --') -ForegroundColor DarkCyan
        $script:MainLogOffset = Get-MainLogLength
        try {
            $appProcess = Start-AntigravityApp -AppPath $app.Path -AppArgs $launchArgs
        } catch {
            Write-Fail ('启动失败: ' + $_.Exception.Message)
            return 5
        }
        Write-Info ('进程 PID: ' + $appProcess.Id)
        Write-Info '等待主窗口出现 ...'
        $w = Wait-AppWindow -Process $appProcess -TimeoutSec 35
        if ($w.Exited) {
            Write-Fail ('Antigravity 启动后立即退出 (退出码 ' + $w.ExitCode + ')')
            Write-Info '常见原因：'
            Write-Info '  1) 环境变量 ELECTRON_RUN_AS_NODE=1（本启动器已自动清除）'
            Write-Info '  2) 安装文件损坏：可尝试重新安装 Antigravity'
            Write-Info ('  3) 详情见日志: ' + $script:MainLog)
            return 5
        }
        if (-not $w.Ok) {
            Write-Warn '30 秒内没有检测到主窗口，但进程仍在运行。'
            Write-Info ('可查看日志: ' + $script:MainLog)
        } else {
            Write-Ok ('主窗口已出现: ' + $w.Window.MainWindowTitle)
        }

        if (-not $verify) { break }

        $ui = Wait-UiHealthy -Offset $script:MainLogOffset -TimeoutSec $uiTimeout
        if ($ui.Status -eq 'Ok') {
            Write-Ok ('界面加载验证通过（' + [Math]::Round($ui.Elapsed, 1) + ' 秒内无加载错误）')
            break
        }
        if ($ui.Status -eq 'Skipped') {
            Write-Info '已跳过界面验证。'
            break
        }
        # Failed
        Write-Fail ('界面加载失败: ' + $ui.Url + '  ' + $ui.Code)
        if ($attempt -lt $maxAttempts) {
            Write-Warn ('正在自动重试（第 ' + ($attempt + 1) + '/' + $maxAttempts + ' 次）...')
            Stop-AntigravityProcesses -InstallDir $installDir | Out-Null
            Start-Sleep -Seconds 2
            continue
        }
        # 最终失败
        Write-Host ''
        Write-Host '  界面无法加载（表现为白屏/空白窗口）。' -ForegroundColor Red
        Write-Info '该问题通常来自客户端自身（而非本启动器）：窗口加载的本地地址由语言服务进程提供。'
        Write-Info '可尝试：'
        Write-Info '  1) 再运行一次（选择 -Restart）——同类问题有时重试一次即可恢复'
        Write-Info '  2) 关闭 Antigravity 后重启电脑，或重新安装/更新客户端'
        if (Test-AsarBackupPresent -InstallDir $installDir) {
            Write-Info '  3) 检测到汉化补丁备份 resources\app.asar.bak：可运行同目录 “恢复官方客户端.bat” 还原官方文件'
        }
        Write-Info '  4) 如装有 Kaspersky / 360 / 火绒等安全软件：把 Antigravity.exe 与 resources\bin\language_server.exe'
        Write-Info '     加入受信任程序或排除项（或临时退出安全软件）后重试——安全软件的加密连接扫描可能干扰本地界面服务'
        Write-Info ('  5) 日志: ' + $script:MainLog)
        Write-Info ('     日志: ' + (Join-Path (Split-Path -Parent $script:MainLog) 'language_server.log'))
        $choice = Read-KeyChoice -Prompt '[R]再试一次 / [O]打开日志目录 / [其他]退出' -Keys @('R', 'O') -DefaultKey 'X' -TimeoutSec 25
        if ($choice -eq 'O') {
            try { Start-Process explorer.exe (Join-Path (Split-Path -Parent $script:MainLog)) } catch { }
            return 6
        }
        if ($choice -eq 'R' -and $attempt -lt ($maxAttempts + 2)) {
            $maxAttempts = $attempt + 1
            Stop-AntigravityProcesses -InstallDir $installDir | Out-Null
            Start-Sleep -Seconds 2
            continue
        }
        return 6
    }

    Write-Host ''
    Write-Sep
    Write-Host '  Antigravity 已启动' -ForegroundColor Green
    Write-Info ('安装位置 : ' + $app.Path)
    Write-Info ('进程 PID : ' + $appProcess.Id)
    Write-Info ('代理方式 : ' + $proxyMode)
    if ($connectivityOk -eq $false) { Write-Info '连通性   : 有服务不可达（可能影响登录/AI 功能）' }
    Write-Info ('客户端日志: ' + $script:MainLog)
    Write-Info ('启动器日志: ' + $script:LauncherLog)
    Write-Sep
    Write-Host ''
    if (-not $cfg.KeepWindowOpen) {
        Start-Sleep -Seconds 1
    } else {
        $null = Read-KeyChoice -Prompt '按任意键关闭此窗口' -Keys @() -DefaultKey 'X' -TimeoutSec 8
    }
    return 0
}

# ---------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------
$script:MainLog = Join-Path $env:APPDATA 'Antigravity\logs\main.log'
$exitCode = 1
try {
    $exitCode = Main
} catch {
    Write-Host ''
    Write-Fail ('启动器发生异常: ' + $_.Exception.Message)
    Write-Info ('详细信息: ' + ($_.ScriptStackTrace -replace "`r?`n", ' | '))
    Write-Log ('EXCEPTION ' + $_.Exception.ToString() + ' ' + $_.ScriptStackTrace)
    $exitCode = 9
}
Write-Log ('===== 结束，退出码 ' + $exitCode + ' =====')
exit $exitCode
