[CmdletBinding()]
param(
    [ValidateSet('Gui', 'Host', 'Client', 'Restore', 'Status')]
    [string]$Role = 'Gui',
    [string]$SharePath = '',
    [ValidateSet('Auto', 'Lan', 'Direct')]
    [string]$Mode = 'Auto',
    [string]$AdapterName = '',
    [switch]$ReadOnly,
    [switch]$RememberClients,
    [string]$HostAddress = '',
    [string]$Drive = '',
    [int]$Port = 51234,
    [switch]$NoGui,
    [switch]$AutoApprove,
    [switch]$DryRun,
    [switch]$Json,
    [string]$ClientName = '',
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$script:AppName = 'LanLink'
$script:AppVersion = '1.1.0'
$script:AppRoot = $PSScriptRoot
if (-not $script:AppRoot) {
    $script:AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$script:HelperPath = Join-Path $script:AppRoot 'LanLink.Helper.ps1'
$script:AppDataDir = if ($env:LANLINK_DATA_DIR) { $env:LANLINK_DATA_DIR } else { Join-Path $env:LOCALAPPDATA 'LanLink' }
$script:LogDir = Join-Path $script:AppDataDir 'logs'
$script:SettingsPath = Join-Path $script:AppDataDir 'settings.json'
$script:ClientIdPath = Join-Path $script:AppDataDir 'client-id.txt'
$script:AllowedPath = Join-Path $script:AppDataDir 'allowed-clients.json'
$script:StatePath = if ($env:LANLINK_STATE_DIR) { Join-Path $env:LANLINK_STATE_DIR 'state.json' } else { Join-Path $env:ProgramData 'LanLink\state.json' }
$script:ListenPort = $Port
$script:DirectCandidates = @('192.168.77', '192.168.78', '192.168.79')
$script:DefaultSharePath = Join-Path $env:PUBLIC 'LanLinkShare'
$script:SuppressSaveSettings = $false
$script:DefaultRememberClients = [bool]$RememberClients
$script:Adapters = @()
$script:PendingHostRequests = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
if (-not $ClientName) {
    $ClientName = $env:COMPUTERNAME
}

foreach ($dir in @($script:AppDataDir, $script:LogDir)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

# ---------------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------------

function Write-AppLog {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )
    try {
        $file = Join-Path $script:LogDir ("lanlink-{0:yyyyMMdd}.log" -f (Get-Date))
        $line = '[{0:yyyy-MM-dd HH:mm:ss}] [{1}] {2}' -f (Get-Date), $Level, $Message
        Add-Content -LiteralPath $file -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {
    }
}

function Add-UiLog {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )
    Write-AppLog -Message $Message -Level $Level
    if ($script:LogBox) {
        $line = '[{0:HH:mm:ss}] {1}' -f (Get-Date), $Message
        try {
            $script:LogBox.AppendText($line + "`r`n")
            $script:LogBox.SelectionStart = $script:LogBox.TextLength
            $script:LogBox.ScrollToCaret()
        } catch {
        }
    }
}

function Show-UiError {
    param([string]$Message)
    Add-UiLog -Message $Message -Level 'ERROR'
    if ($script:Form) {
        [System.Windows.Forms.MessageBox]::Show(
            $Message,
            '双机快传 LanLink',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    } else {
        Write-Host "错误: $Message" -ForegroundColor Red
    }
}

function Test-Admin {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Test-DirtyState {
    if (-not (Test-Path -LiteralPath $script:StatePath)) {
        return $false
    }
    try {
        $raw = [System.IO.File]::ReadAllText($script:StatePath, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $false
        }
        $state = $raw | ConvertFrom-Json
        return [bool]$state.dirty
    } catch {
        return $false
    }
}

function Get-ClientId {
    if (Test-Path -LiteralPath $script:ClientIdPath) {
        try {
            $id = ([System.IO.File]::ReadAllText($script:ClientIdPath, [System.Text.Encoding]::UTF8)).Trim()
            if ($id) {
                return $id
            }
        } catch {
        }
    }
    $id = [guid]::NewGuid().ToString('N')
    Set-Content -LiteralPath $script:ClientIdPath -Value $id -Encoding ASCII
    return $id
}

function Get-ClientHistory {
    if (-not (Test-Path -LiteralPath $script:AllowedPath)) {
        return @()
    }
    try {
        $raw = [System.IO.File]::ReadAllText($script:AllowedPath, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return @()
        }
        $parsed = $raw | ConvertFrom-Json
        $records = @($parsed | ForEach-Object { $_ })
        $history = New-Object System.Collections.ArrayList
        foreach ($record in $records) {
            $id = [string]$record.id
            if ([string]::IsNullOrWhiteSpace($id)) {
                continue
            }
            $lastSeen = ''
            if ($record.PSObject.Properties['lastSeen']) {
                $lastSeen = [string]$record.lastSeen
            }
            $firstSeen = $lastSeen
            if ($record.PSObject.Properties['firstSeen'] -and $record.firstSeen) {
                $firstSeen = [string]$record.firstSeen
            }
            $lastIp = ''
            if ($record.PSObject.Properties['lastIp']) {
                $lastIp = [string]$record.lastIp
            }
            $remembered = $true
            if ($record.PSObject.Properties['remembered']) {
                $remembered = [bool]$record.remembered
            }
            $rememberedManual = $false
            if ($record.PSObject.Properties['rememberedManual']) {
                $rememberedManual = [bool]$record.rememberedManual
            }
            $connectCount = 1
            if ($record.PSObject.Properties['connectCount']) {
                $connectCount = [int]$record.connectCount
            }
            if ($connectCount -lt 1) {
                $connectCount = 1
            }
            [void]$history.Add([pscustomobject]@{
                id               = $id
                name             = [string]$record.name
                lastIp           = $lastIp
                firstSeen        = $firstSeen
                lastSeen         = $lastSeen
                connectCount     = $connectCount
                remembered       = $remembered
                rememberedManual = $rememberedManual
            })
        }
        $sorted = @($history | Sort-Object lastSeen -Descending)
        $unique = New-Object System.Collections.ArrayList
        $seen = @{}
        foreach ($item in $sorted) {
            if ($seen.ContainsKey($item.id)) {
                continue
            }
            $seen[$item.id] = $true
            [void]$unique.Add($item)
            if ($unique.Count -ge 200) {
                break
            }
        }
        return @($unique | ForEach-Object { $_ })
    } catch {
        Write-AppLog "读取历史电脑失败：$($_.Exception.Message)" 'WARN'
        return @()
    }
}

function Save-ClientHistory {
    param($History)
    $list = @($History | Sort-Object lastSeen -Descending)
    if ($list.Count -gt 200) {
        $list = @($list[0..199])
    }
    try {
        if ($list.Count -eq 0) {
            $json = '[]'
        } else {
            $json = ConvertTo-Json -InputObject @($list) -Depth 6
        }
        Set-Content -LiteralPath $script:AllowedPath -Value $json -Encoding UTF8
        return $true
    } catch {
        Write-AppLog "保存历史电脑失败：$($_.Exception.Message)" 'ERROR'
        return $false
    }
}

function Test-AllowedClient {
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) {
        return $false
    }
    $record = @(Get-ClientHistory | Where-Object { [string]$_.id -eq $Id }) | Select-Object -First 1
    if (-not $record) {
        return $false
    }
    return [bool]$record.remembered
}

function Update-ClientHistory {
    param(
        [string]$Id,
        [string]$Name,
        [string]$Ip
    )
    if ([string]::IsNullOrWhiteSpace($Id)) {
        return $null
    }
    $history = @(Get-ClientHistory)
    $existing = @($history | Where-Object { [string]$_.id -eq $Id }) | Select-Object -First 1
    $now = (Get-Date).ToString('o')
    if ($existing) {
        if ($Name) {
            $existing.name = $Name
        }
        $existing.lastIp = $Ip
        $existing.lastSeen = $now
        $existing.connectCount = [int]$existing.connectCount + 1
        $record = $existing
    } else {
        $record = [pscustomobject]@{
            id               = $Id
            name             = $Name
            lastIp           = $Ip
            firstSeen        = $now
            lastSeen         = $now
            connectCount     = 1
            remembered       = [bool]$script:DefaultRememberClients
            rememberedManual = $false
        }
        $history += $record
    }
    Save-ClientHistory -History $history | Out-Null
    return $record
}

function Set-ClientRemembered {
    param(
        [string]$Id,
        [bool]$Remembered,
        [switch]$Manual
    )
    if ([string]::IsNullOrWhiteSpace($Id)) {
        return $false
    }
    $history = @(Get-ClientHistory)
    $record = @($history | Where-Object { [string]$_.id -eq $Id }) | Select-Object -First 1
    if (-not $record) {
        return $false
    }
    $record.remembered = $Remembered
    if ($Manual) {
        $record.rememberedManual = $true
    }
    return (Save-ClientHistory -History $history)
}

function Apply-ClientDefaultRemember {
    param([string]$Id)
    if (-not $script:DefaultRememberClients) {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($Id)) {
        return $false
    }
    $history = @(Get-ClientHistory)
    $record = @($history | Where-Object { [string]$_.id -eq $Id }) | Select-Object -First 1
    if (-not $record -or [bool]$record.rememberedManual -or [bool]$record.remembered) {
        return $false
    }
    $record.remembered = $true
    return (Save-ClientHistory -History $history)
}

function Remove-ClientHistory {
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) {
        return $false
    }
    $history = @(Get-ClientHistory | Where-Object { [string]$_.id -ne $Id })
    Save-ClientHistory -History $history | Out-Null
    return $true
}

function Load-Settings {
    if (-not (Test-Path -LiteralPath $script:SettingsPath)) {
        return $null
    }
    try {
        $raw = [System.IO.File]::ReadAllText($script:SettingsPath, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $null
        }
        return ($raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Save-Settings {
    if ($script:SuppressSaveSettings) {
        return
    }
    if (-not $script:TxtSharePath) {
        return
    }
    $mode = @('Auto', 'Lan', 'Direct')[$script:ModeCombo.SelectedIndex]
    $adapter = ''
    if ($script:AdapterCombo.SelectedIndex -gt 0 -and ($script:AdapterCombo.SelectedIndex - 1) -lt $script:Adapters.Count) {
        $adapter = $script:Adapters[$script:AdapterCombo.SelectedIndex - 1].Name
    }
    $settings = [pscustomobject]@{
        sharePath       = $script:TxtSharePath.Text.Trim()
        mode            = $mode
        adapterName     = $adapter
        readOnly        = [bool]$script:ChkReadOnly.Checked
        defaultRemember = $(if ($script:ChkDefaultRemember) { [bool]$script:ChkDefaultRemember.Checked } else { [bool]$script:DefaultRememberClients })
    }
    try {
        $settings | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
    } catch {
        Write-AppLog "保存设置失败: $($_.Exception.Message)" 'WARN'
    }
}

# ---------------------------------------------------------------------------
# Helper 进程通信
# ---------------------------------------------------------------------------

function Start-Helper {
    if ($script:HelperClient -and $script:HelperClient.Connected) {
        return
    }
    if (-not (Test-Path -LiteralPath $script:HelperPath)) {
        throw "找不到提权组件：$($script:HelperPath)"
    }

    $port = Get-Random -Minimum 20000 -Maximum 60000
    $token = [guid]::NewGuid().ToString('N')
    $argLine = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Port {1} -Token {2} -ParentPid {3}' -f $script:HelperPath, $port, $token, $PID

    Add-UiLog '正在请求管理员权限（UAC），请点“是”...'
    try {
        $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argLine -PassThru -ErrorAction Stop
    } catch {
        throw "需要管理员权限才能配置网络和共享。UAC 被取消或无法提权：$($_.Exception.Message)"
    }

    $deadline = (Get-Date).AddSeconds(60)
    $client = $null
    while ((Get-Date) -lt $deadline) {
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $client.Connect('127.0.0.1', $port)
            break
        } catch {
            if ($client) {
                $client.Close()
                $client = $null
            }
            if ($process.HasExited) {
                throw "提权组件启动失败（退出码 $($process.ExitCode)）。请检查杀毒软件是否拦截。"
            }
            Start-Sleep -Milliseconds 250
        }
    }
    if (-not $client -or -not $client.Connected) {
        throw '等待提权组件超时。请重试，或检查 UAC/杀毒软件。'
    }

    $client.NoDelay = $true
    $stream = $client.GetStream()
    $stream.ReadTimeout = 15000
    $stream.WriteTimeout = 15000
    $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
    $writer = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding($false)))
    $writer.AutoFlush = $true

    $script:HelperProcess = $process
    $script:HelperClient = $client
    $script:HelperStream = $stream
    $script:HelperReader = $reader
    $script:HelperWriter = $writer
    $script:HelperToken = $token
    $script:HelperPort = $port

    try {
        $ping = Invoke-Helper -Command 'ping' -Payload @{} -TimeoutSec 10
        if (-not $ping.pong) {
            throw '提权组件未响应'
        }
        Add-UiLog '提权组件已就绪'
    } catch {
        Stop-Helper
        throw "提权组件握手失败：$($_.Exception.Message)"
    }
}

function Invoke-Helper {
    param(
        [string]$Command,
        [hashtable]$Payload = @{},
        [int]$TimeoutSec = 120
    )
    if (-not $script:HelperClient -or -not $script:HelperClient.Connected) {
        throw '提权组件未连接'
    }
    $request = @{
        token = $script:HelperToken
        cmd   = $Command
        args  = $Payload
    } | ConvertTo-Json -Depth 12 -Compress
    try {
        $script:HelperStream.ReadTimeout = $TimeoutSec * 1000
        $script:HelperWriter.WriteLine($request)
        $script:HelperWriter.Flush()
        $line = $script:HelperReader.ReadLine()
    } catch {
        $message = $_.Exception.Message
        Stop-Helper
        throw "提权组件通信失败：$message"
    }
    if ([string]::IsNullOrWhiteSpace($line)) {
        Stop-Helper
        throw '提权组件连接已断开'
    }
    $response = $line | ConvertFrom-Json
    if (-not $response.ok) {
        throw [string]$response.error
    }
    return $response.data
}

function Stop-Helper {
    try {
        if ($script:HelperClient -and $script:HelperClient.Connected) {
            $script:HelperStream.ReadTimeout = 2000
            $script:HelperWriter.WriteLine((@{ token = $script:HelperToken; cmd = 'exit'; args = @{} } | ConvertTo-Json -Compress))
            $script:HelperWriter.Flush()
            Start-Sleep -Milliseconds 100
        }
    } catch {
    }
    foreach ($obj in @($script:HelperReader, $script:HelperWriter, $script:HelperStream, $script:HelperClient)) {
        if ($obj) {
            try { $obj.Close() } catch { }
            try { $obj.Dispose() } catch { }
        }
    }
    $script:HelperReader = $null
    $script:HelperWriter = $null
    $script:HelperStream = $null
    $script:HelperClient = $null
    $script:HelperToken = $null
    $script:HelperProcess = $null
}

function Ensure-Helper {
    if (-not $script:HelperClient -or -not $script:HelperClient.Connected) {
        Start-Helper
    }
}

# ---------------------------------------------------------------------------
# 网卡与网络信息
# ---------------------------------------------------------------------------

function Get-LocalAdapters {
    $result = New-Object System.Collections.ArrayList
    try {
        $interfaces = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()
    } catch {
        return @()
    }
    foreach ($ni in $interfaces) {
        try {
            if ($ni.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback) {
                continue
            }
            if ($ni.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Tunnel) {
                continue
            }
            if ($ni.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) {
                continue
            }
            $props = $ni.GetIPProperties()
            $ipv4 = @()
            foreach ($ua in $props.UnicastAddresses) {
                if ($ua.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                    $ipv4 += [pscustomobject]@{
                        ip     = $ua.Address.ToString()
                        prefix = [int]$ua.PrefixLength
                    }
                }
            }
            $gateways = @()
            foreach ($gw in $props.GatewayAddresses) {
                if ($gw.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                    $gateways += $gw.Address.ToString()
                }
            }
            $dns = @()
            foreach ($d in $props.DnsAddresses) {
                if ($d.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                    $dns += $d.ToString()
                }
            }
            $description = [string]$ni.Description
            $isVirtual = $description -match 'Virtual|VMware|Hyper-V|VirtualBox|TAP|VPN|WAN Miniport|Loopback'
            [void]$result.Add([pscustomobject]@{
                Name        = [string]$ni.Name
                Description = $description
                Type        = [string]$ni.NetworkInterfaceType
                Status      = [string]$ni.OperationalStatus
                Speed       = [long]$ni.Speed
                Mac         = [string]$ni.GetPhysicalAddress().ToString()
                IPv4        = @($ipv4)
                Gateways    = @($gateways)
                Dns         = @($dns)
                IsVirtual   = [bool]$isVirtual
            })
        } catch {
            continue
        }
    }
    $ordered = @($result | Sort-Object `
        @{ Expression = { if ($_.Type -match 'Ethernet') { 0 } elseif ($_.Type -match 'Wireless') { 1 } else { 2 } } }, `
        @{ Expression = { $_.Name } })
    return $ordered
}

function Get-AdapterDisplay {
    param($Adapter)
    $ip = '无 IP'
    if (@($Adapter.IPv4).Count -gt 0) {
        $ip = $Adapter.IPv4[0].ip
    }
    $speed = ''
    if ($Adapter.Speed -gt 0) {
        $speed = '{0:N0} Mbps' -f ($Adapter.Speed / 1000000)
    }
    return ('{0}  |  {1}  |  {2}' -f $Adapter.Name, $ip, $speed).TrimEnd(' ', '|')
}

function Select-BestAdapter {
    param([string]$SelectedMode = 'Auto')
    if ($null -eq $script:Adapters) {
        return $null
    }
    $list = @($script:Adapters | Where-Object { $_ })
    if ($list.Count -eq 0) {
        return $null
    }
    $physical = @($list | Where-Object { -not $_.IsVirtual })
    if ($physical.Count -eq 0) {
        $physical = $list
    }
    if ($SelectedMode -eq 'Direct') {
        $eth = @($physical | Where-Object { $_.Type -match 'Ethernet' })
        if ($eth.Count -gt 0) {
            return $eth[0]
        }
    }
    $withGateway = @($physical | Where-Object {
            $_.IPv4 -and @($_.IPv4).Count -gt 0 -and @($_.Gateways).Count -gt 0 -and $_.IPv4[0].ip -notlike '169.254.*'
        })
    if ($withGateway.Count -gt 0) {
        return $withGateway[0]
    }
    $withIp = @($physical | Where-Object {
            $_.IPv4 -and @($_.IPv4).Count -gt 0 -and $_.IPv4[0].ip -notlike '169.254.*'
        })
    if ($withIp.Count -gt 0) {
        return $withIp[0]
    }
    return $physical[0]
}

function Get-EffectiveModeForAdapter {
    param(
        $Adapter,
        [string]$SelectedMode = 'Auto'
    )
    if ($SelectedMode -eq 'Lan') {
        return 'Lan'
    }
    if ($SelectedMode -eq 'Direct') {
        return 'Direct'
    }
    if ($Adapter -and @($Adapter.IPv4).Count -gt 0 -and @($Adapter.Gateways).Count -gt 0 -and $Adapter.IPv4[0].ip -notlike '169.254.*') {
        return 'Lan'
    }
    return 'Direct'
}

function Test-TcpPort {
    param(
        [string]$Address,
        [int]$PortNumber,
        [int]$TimeoutMs = 3000
    )
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($Address, $PortNumber, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            return $false
        }
        $client.EndConnect($iar)
        return $true
    } catch {
        return $false
    } finally {
        if ($client) {
            $client.Close()
        }
    }
}

# ---------------------------------------------------------------------------
# UDP 发现与连接（后台 Runspace）
# ---------------------------------------------------------------------------

$script:HostListenerScript = @'
param($Port, $Inbox, $Outbox, $Cts, $HostInfo)
$ErrorActionPreference = 'SilentlyContinue'
try {
    $udp = New-Object System.Net.Sockets.UdpClient
    $udp.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
    $udp.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, $Port)))
    $udp.EnableBroadcast = $true
    $udp.Client.ReceiveTimeout = 200
    $Inbox.Enqueue(@{ kind = 'ready'; port = $Port })
    while (-not $Cts.IsCancellationRequested) {
        $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $data = $null
        try {
            $data = $udp.Receive([ref]$remote)
        } catch {
            $data = $null
        }
        if ($data -and $data.Length -gt 0) {
            $msg = $null
            try {
                $msg = [System.Text.Encoding]::UTF8.GetString($data) | ConvertFrom-Json
            } catch {
                $msg = $null
            }
            if ($msg -and $msg.magic -eq 'LANLINK') {
                if ($msg.type -eq 'discover') {
                    $Inbox.Enqueue(@{ kind = 'debug'; message = "收到发现请求：$($remote.Address)" })
                    $offer = @{
                        magic = 'LANLINK'
                        v     = 1
                        type  = 'offer'
                        host  = $HostInfo.name
                        ip    = $HostInfo.ip
                        share = $HostInfo.share
                        mode  = $HostInfo.mode
                        port  = $HostInfo.port
                        nonce = $msg.nonce
                    }
                    $json = $offer | ConvertTo-Json -Compress
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $udp.Send($bytes, $bytes.Length, $remote) | Out-Null
                } elseif ($msg.type -eq 'request') {
                    $Inbox.Enqueue(@{ kind = 'debug'; message = "收到连接请求：$($remote.Address)" })
                    $Inbox.Enqueue(@{ kind = 'request'; msg = $msg; remote = $remote; received = (Get-Date) })
                } elseif ($msg.type -eq 'disconnect') {
                    $Inbox.Enqueue(@{ kind = 'disconnect'; msg = $msg; remote = $remote })
                }
            }
        }
        $out = $null
        while ($Outbox.TryDequeue([ref]$out)) {
            try {
                $json = $out.payload | ConvertTo-Json -Depth 8 -Compress
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                $udp.Send($bytes, $bytes.Length, $out.remote) | Out-Null
            } catch {
            }
        }
    }
    $udp.Close()
} catch {
    $Inbox.Enqueue(@{ kind = 'error'; error = $_.Exception.Message })
}
'@

$script:ClientDiscoveryScript = @'
param($Port, $Events, $Cts, $AdapterIp, $PrefixLength, $Nonce, $DirectHostIp)
$ErrorActionPreference = 'SilentlyContinue'
try {
    $targets = New-Object System.Collections.ArrayList
    if ($DirectHostIp) {
        try {
            [void]$targets.Add([System.Net.IPAddress]::Parse($DirectHostIp))
        } catch {
        }
    }
    [void]$targets.Add([System.Net.IPAddress]::Broadcast)
    if ($AdapterIp) {
        try {
            $ip = [System.Net.IPAddress]::Parse($AdapterIp)
            $ipBytes = $ip.GetAddressBytes()
            $maskBytes = New-Object byte[] 4
            for ($i = 0; $i -lt $PrefixLength; $i++) {
                $idx = [math]::Floor($i / 8)
                $maskBytes[$idx] = $maskBytes[$idx] -bor (1 -shl (7 - ($i % 8)))
            }
            $bcBytes = New-Object byte[] 4
            for ($i = 0; $i -lt 4; $i++) {
                $bcBytes[$i] = $ipBytes[$i] -bor (255 - $maskBytes[$i])
            }
            $subnetBroadcast = [System.Net.IPAddress]::new($bcBytes)
            if (-not (@($targets | Where-Object { $_.Equals($subnetBroadcast) }).Count -gt 0)) {
                [void]$targets.Add($subnetBroadcast)
            }
        } catch {
        }
    }

    $udp = New-Object System.Net.Sockets.UdpClient
    $udp.EnableBroadcast = $true
    $boundTo = '0.0.0.0'
    $bindError = ''
    if ($AdapterIp) {
        for ($attempt = 0; $attempt -lt 10; $attempt++) {
            try {
                $udp.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($AdapterIp), 0)))
                $boundTo = $AdapterIp
                $bindError = ''
                break
            } catch {
                $bindError = $_.Exception.Message
                try { $udp.Close() } catch { }
                Start-Sleep -Milliseconds 300
                $udp = New-Object System.Net.Sockets.UdpClient
                $udp.EnableBroadcast = $true
            }
        }
    }
    if (-not $AdapterIp -or $boundTo -ne $AdapterIp) {
        try {
            $udp.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)))
            $boundTo = '0.0.0.0（回退）'
        } catch {
            $boundTo = '绑定失败'
        }
        if ($bindError) {
            $Events.Enqueue(@{ kind = 'debug'; message = "绑定 $AdapterIp 失败：$bindError；当前 $boundTo" })
        }
    }
    $udp.Client.ReceiveTimeout = 250

    $payload = @{
        magic  = 'LANLINK'
        v      = 1
        type   = 'discover'
        nonce  = $Nonce
        client = $env:COMPUTERNAME
    } | ConvertTo-Json -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $Events.Enqueue(@{ kind = 'debug'; message = "本机绑定 $boundTo，发现目标：$($targets -join ', ')" })

    $sendError = ''
    for ($round = 0; $round -lt 3; $round++) {
        foreach ($target in $targets) {
            try {
                $udp.Send($bytes, $bytes.Length, (New-Object System.Net.IPEndPoint($target, $Port))) | Out-Null
            } catch {
                if (-not $sendError) {
                    $sendError = $_.Exception.Message
                }
            }
        }
        Start-Sleep -Milliseconds 150
    }
    if ($sendError) {
        $Events.Enqueue(@{ kind = 'debug'; message = "部分发现包发送失败：$sendError" })
    }

    $deadline = (Get-Date).AddSeconds(2.5)
    $seen = @{}
    while ((Get-Date) -lt $deadline -and -not $Cts.IsCancellationRequested) {
        $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $data = $null
        try {
            $data = $udp.Receive([ref]$remote)
        } catch {
            $data = $null
        }
        if ($data -and $data.Length -gt 0) {
            $msg = $null
            try {
                $msg = [System.Text.Encoding]::UTF8.GetString($data) | ConvertFrom-Json
            } catch {
                $msg = $null
            }
            if ($msg -and $msg.magic -eq 'LANLINK' -and $msg.type -eq 'offer' -and $msg.ip) {
                $seen[[string]$msg.ip] = $msg
            }
        }
    }
    $udp.Close()
    $Events.Enqueue(@{ kind = 'debug'; message = "发现结束，收到 $($seen.Count) 个主机响应" })
    $Events.Enqueue(@{ kind = 'hosts'; hosts = @($seen.Values); nonce = $Nonce })
} catch {
    $Events.Enqueue(@{ kind = 'error'; error = $_.Exception.Message })
}
'@

$script:ClientRequestScript = @'
param($Port, $HostIp, $Events, $Cts, $Nonce, $ClientId, $ClientName, $BindIp)
$ErrorActionPreference = 'SilentlyContinue'
try {
    $udp = New-Object System.Net.Sockets.UdpClient
    try {
        if ($BindIp) {
            $udp.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($BindIp), 0)))
        }
    } catch {
    }
    $udp.Client.ReceiveTimeout = 300
    $payload = @{
        magic    = 'LANLINK'
        v        = 1
        type     = 'request'
        nonce    = $Nonce
        clientId = $ClientId
        client   = $ClientName
    } | ConvertTo-Json -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $udp.Send($bytes, $bytes.Length, (New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($HostIp), $Port))) | Out-Null
    $deadline = (Get-Date).AddSeconds(45)
    $done = $false
    while ((Get-Date) -lt $deadline -and -not $Cts.IsCancellationRequested) {
        $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $data = $null
        try {
            $data = $udp.Receive([ref]$remote)
        } catch {
            $data = $null
        }
        if ($data -and $data.Length -gt 0) {
            $msg = $null
            try {
                $msg = [System.Text.Encoding]::UTF8.GetString($data) | ConvertFrom-Json
            } catch {
                $msg = $null
            }
            if ($msg -and $msg.magic -eq 'LANLINK' -and $msg.nonce -eq $Nonce -and ($msg.type -eq 'grant' -or $msg.type -eq 'deny')) {
                $Events.Enqueue(@{ kind = $msg.type; msg = $msg })
                $done = $true
                break
            }
        }
    }
    $udp.Close()
    if (-not $done -and -not $Cts.IsCancellationRequested) {
        $Events.Enqueue(@{ kind = 'timeout' })
    }
} catch {
    $Events.Enqueue(@{ kind = 'error'; error = $_.Exception.Message })
}
'@

function Start-HostDiscovery {
    Stop-HostDiscovery
    if (-not $script:ShareInfo) {
        throw '共享信息未初始化'
    }
    $script:HostInbox = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $script:HostOutbox = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $script:HostCts = New-Object System.Threading.CancellationTokenSource
    $info = @{
        name  = $env:COMPUTERNAME
        ip    = $script:ShareInfo.ip
        share = $script:ShareInfo.share
        mode  = $script:ShareInfo.mode
        port  = $script:ListenPort
    }
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script:HostListenerScript).
        AddArgument($script:ListenPort).
        AddArgument($script:HostInbox).
        AddArgument($script:HostOutbox).
        AddArgument($script:HostCts).
        AddArgument($info)
    $script:HostDiscoveryRS = $rs
    $script:HostDiscoveryPS = $ps
    $script:HostDiscoveryHandle = $ps.BeginInvoke()
    Add-UiLog "正在启动 UDP 发现服务（端口 $($script:ListenPort)）..."
}

function Stop-HostDiscovery {
    if ($script:HostCts) {
        try { $script:HostCts.Cancel() } catch { }
    }
    if ($script:HostDiscoveryPS) {
        try { $script:HostDiscoveryPS.Stop() } catch { }
        try { $script:HostDiscoveryPS.Dispose() } catch { }
    }
    if ($script:HostDiscoveryRS) {
        try { $script:HostDiscoveryRS.Close() } catch { }
        try { $script:HostDiscoveryRS.Dispose() } catch { }
    }
    $script:HostDiscoveryPS = $null
    $script:HostDiscoveryRS = $null
    $script:HostDiscoveryHandle = $null
    $script:HostCts = $null
}

function Start-ClientDiscovery {
    param(
        [string]$AdapterIp,
        [int]$PrefixLength = 24,
        [string]$DirectHostIp = ''
    )
    Stop-ClientDiscovery
    $script:ClientEvents = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $script:ClientCts = New-Object System.Threading.CancellationTokenSource
    $nonce = [guid]::NewGuid().ToString('N')
    $script:ClientNonce = $nonce
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script:ClientDiscoveryScript).
        AddArgument($script:ListenPort).
        AddArgument($script:ClientEvents).
        AddArgument($script:ClientCts).
        AddArgument($AdapterIp).
        AddArgument($PrefixLength).
        AddArgument($nonce).
        AddArgument($DirectHostIp)
    $script:ClientDiscoveryRS = $rs
    $script:ClientDiscoveryPS = $ps
    $script:ClientDiscoveryHandle = $ps.BeginInvoke()
}

function Stop-ClientDiscovery {
    if ($script:ClientCts) {
        try { $script:ClientCts.Cancel() } catch { }
    }
    if ($script:ClientDiscoveryPS) {
        try { $script:ClientDiscoveryPS.Stop() } catch { }
        try { $script:ClientDiscoveryPS.Dispose() } catch { }
    }
    if ($script:ClientDiscoveryRS) {
        try { $script:ClientDiscoveryRS.Close() } catch { }
        try { $script:ClientDiscoveryRS.Dispose() } catch { }
    }
    $script:ClientDiscoveryPS = $null
    $script:ClientDiscoveryRS = $null
    $script:ClientDiscoveryHandle = $null
    $script:ClientCts = $null
}

function Start-ClientConnect {
    param($HostInfo)
    Stop-ClientConnect
    $script:ClientEvents = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $script:ClientCts = New-Object System.Threading.CancellationTokenSource
    $nonce = [guid]::NewGuid().ToString('N')
    $script:ClientNonce = $nonce
    $bindIp = $null
    if ($script:ClientSearchMode -eq 'Direct') {
        $bindIp = $script:ClientAdapterIp
    }
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script:ClientRequestScript).
        AddArgument($script:ListenPort).
        AddArgument([string]$HostInfo.ip).
        AddArgument($script:ClientEvents).
        AddArgument($script:ClientCts).
        AddArgument($nonce).
        AddArgument((Get-ClientId)).
        AddArgument($ClientName).
        AddArgument($bindIp)
    $script:ClientConnectRS = $rs
    $script:ClientConnectPS = $ps
    $script:ClientConnectHandle = $ps.BeginInvoke()
}

function Stop-ClientConnect {
    if ($script:ClientCts) {
        try { $script:ClientCts.Cancel() } catch { }
    }
    if ($script:ClientConnectPS) {
        try { $script:ClientConnectPS.Stop() } catch { }
        try { $script:ClientConnectPS.Dispose() } catch { }
    }
    if ($script:ClientConnectRS) {
        try { $script:ClientConnectRS.Close() } catch { }
        try { $script:ClientConnectRS.Dispose() } catch { }
    }
    $script:ClientConnectPS = $null
    $script:ClientConnectRS = $null
    $script:ClientConnectHandle = $null
    $script:ClientCts = $null
}

# ---------------------------------------------------------------------------
# 客户端映射
# ---------------------------------------------------------------------------

function Get-FreeDriveLetter {
    $used = New-Object System.Collections.ArrayList
    try {
        foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
            [void]$used.Add($d.Name.Substring(0, 1).ToUpper())
        }
    } catch {
    }
    try {
        foreach ($m in @(Get-SmbMapping -ErrorAction SilentlyContinue)) {
            if ($m.LocalPath -match '^([A-Za-z]):') {
                [void]$used.Add($Matches[1].ToUpper())
            }
        }
    } catch {
    }
    foreach ($letter in @('Z', 'Y', 'X', 'W', 'V', 'U', 'T', 'S', 'R', 'Q', 'P', 'O', 'N', 'M', 'L', 'K', 'J', 'I', 'H', 'G', 'F', 'E')) {
        if (-not $used.Contains($letter)) {
            return $letter
        }
    }
    throw '没有可用的盘符（E-Z 均被占用）'
}

function Connect-LanLinkShare {
    param($Grant)
    $ip = [string]$Grant.ip
    $share = [string]$Grant.share
    if (-not $ip -or -not $share) {
        throw '主机返回的共享信息不完整'
    }
    $remote = "\\$ip\$share"
    Add-UiLog "正在连接 $remote ..."
    if (-not (Test-TcpPort -Address $ip -PortNumber 445 -TimeoutMs 4000)) {
        throw "无法连接 $ip 的 445 端口。请确认主机共享已启动、防火墙已放行，且两台电脑在同一网段。"
    }

    try {
        $existing = @(Get-SmbMapping -ErrorAction SilentlyContinue | Where-Object { $_.RemotePath -like "\\$ip\*" })
        foreach ($map in $existing) {
            Remove-SmbMapping -LocalPath $map.LocalPath -Force -ErrorAction SilentlyContinue
        }
    } catch {
    }

    $drive = $Drive
    if (-not $drive) {
        $drive = Get-FreeDriveLetter
    } else {
        $drive = $drive.TrimEnd(':').ToUpper()
    }

    $mapped = $false
    try {
        New-SmbMapping -LocalPath "${drive}:" -RemotePath $remote -UserName ([string]$Grant.user) -Password ([string]$Grant.pass) -Persistent $false -ErrorAction Stop | Out-Null
        $mapped = $true
    } catch {
        $userArg = '/user:' + [string]$Grant.user
        $netOut = & net.exe use "${drive}:" $remote ([string]$Grant.pass) $userArg /persistent:no 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "映射共享失败：$($netOut -join ' ')"
        }
        $mapped = $true
    }
    if (-not $mapped) {
        throw '映射共享失败'
    }

    $script:ClientConnected = $true
    $script:ConnectedDrive = $drive
    $script:ConnectedRemote = $remote
    $script:ConnectedHostIp = $ip
    $script:ConnectedHostPort = $script:ListenPort
    if ($Grant.port) {
        $script:ConnectedHostPort = [int]$Grant.port
    }
    Add-UiLog "已映射 ${drive}: -> $remote"
    if ($script:BtnDisconnect) {
        $script:BtnDisconnect.Enabled = $true
    }
    if ($script:LblClientStatus) {
        $script:LblClientStatus.Text = "已连接：$remote（${drive}:）"
    }
    if ($script:LblHeaderStatus) {
        $script:LblHeaderStatus.Text = "客户端已连接"
    }
    try {
        Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$remote`"" | Out-Null
    } catch {
    }
    return [pscustomobject]@{ drive = $drive; remote = $remote }
}

function Disconnect-LanLinkShare {
    if (-not $script:ClientConnected) {
        return
    }
    $drive = $script:ConnectedDrive
    if ($script:ConnectedHostIp) {
        try {
            $udp = New-Object System.Net.Sockets.UdpClient
            $payload = @{
                magic    = 'LANLINK'
                v        = 1
                type     = 'disconnect'
                clientId = (Get-ClientId)
                client   = $ClientName
            } | ConvertTo-Json -Compress
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
            $target = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($script:ConnectedHostIp), [int]$script:ConnectedHostPort)
            for ($i = 0; $i -lt 3; $i++) {
                $udp.Send($bytes, $bytes.Length, $target) | Out-Null
                Start-Sleep -Milliseconds 30
            }
            $udp.Close()
        } catch {
        }
    }
    try {
        if ($drive) {
            Remove-SmbMapping -LocalPath "${drive}:" -Force -ErrorAction SilentlyContinue
        }
    } catch {
    }
    try {
        if ($drive) {
            & net.exe use "${drive}:" /delete /y 2>&1 | Out-Null
        }
    } catch {
    }
    Add-UiLog "已断开映射 ${drive}:"
    $script:ClientConnected = $false
    $script:ConnectedDrive = $null
    $script:ConnectedRemote = $null
    $script:ConnectedHostIp = $null
    $script:ConnectedHostPort = 0
    if ($script:BtnDisconnect) {
        $script:BtnDisconnect.Enabled = $false
    }
    if ($script:LblClientStatus) {
        $script:LblClientStatus.Text = '未连接'
    }
    if ($script:LblHeaderStatus) {
        $script:LblHeaderStatus.Text = '就绪'
    }
}

# ---------------------------------------------------------------------------
# GUI
# ---------------------------------------------------------------------------

function New-UiFont {
    param(
        [double]$Size = 9,
        [bool]$Bold = $false
    )
    $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    try {
        return (New-Object System.Drawing.Font('Microsoft YaHei UI', $Size, $style, [System.Drawing.GraphicsUnit]::Point))
    } catch {
        return (New-Object System.Drawing.Font('Segoe UI', $Size, $style, [System.Drawing.GraphicsUnit]::Point))
    }
}

function New-UiLabel {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$W,
        [int]$H,
        [double]$Size = 9,
        [bool]$Bold = $false,
        [string]$Color = '#0F172A',
        [string]$Align = 'MiddleLeft'
    )
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($W, $H)
    $label.Font = New-UiFont -Size $Size -Bold $Bold
    $label.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Color)
    $label.TextAlign = $Align
    $label.AutoSize = $false
    return $label
}

function New-UiButton {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$W,
        [int]$H,
        [string]$BackColor = '#2563EB',
        [string]$ForeColor = '#FFFFFF',
        [double]$Size = 10,
        [bool]$Bold = $true
    )
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Object System.Drawing.Point($X, $Y)
    $button.Size = New-Object System.Drawing.Size($W, $H)
    $button.Font = New-UiFont -Size $Size -Bold $Bold
    $button.BackColor = [System.Drawing.ColorTranslator]::FromHtml($BackColor)
    $button.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($ForeColor)
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize = 0
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $button.UseVisualStyleBackColor = $false
    return $button
}

function Scale-ControlFonts {
    param(
        $Control,
        [double]$Factor
    )
    foreach ($child in $Control.Controls) {
        try {
            $font = $child.Font
            if ($font) {
                $child.Font = New-Object System.Drawing.Font($font.FontFamily, [float]($font.Size * $Factor), $font.Style, $font.Unit)
            }
        } catch {
        }
        Scale-ControlFonts -Control $child -Factor $Factor
    }
}

function Set-Role {
    param([string]$SelectedRole)
    $script:Role = $SelectedRole
    if ($script:HostPanel) {
        $script:HostPanel.Visible = ($SelectedRole -eq 'Host')
    }
    if ($script:ClientPanel) {
        $script:ClientPanel.Visible = ($SelectedRole -eq 'Client')
    }
    if ($SelectedRole -eq 'Host') {
        $script:BtnRoleHost.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#2563EB')
        $script:BtnRoleHost.ForeColor = [System.Drawing.Color]::White
        $script:BtnRoleClient.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#DCFCE7')
        $script:BtnRoleClient.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#166534')
        $script:LblHeaderStatus.Text = if ($script:HostRunning) { '主机共享中' } else { '主机模式' }
    } else {
        $script:BtnRoleClient.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#16A34A')
        $script:BtnRoleClient.ForeColor = [System.Drawing.Color]::White
        $script:BtnRoleHost.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#E0E7FF')
        $script:BtnRoleHost.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#1E3A8A')
        $script:LblHeaderStatus.Text = if ($script:ClientConnected) { '客户端已连接' } else { '客户端模式' }
    }
    Update-AdapterSummary
    if ($SelectedRole -eq 'Host') {
        Refresh-HistoryGrid
    }
}

function Set-UiBusy {
    param(
        [bool]$Busy,
        [string]$Text = ''
    )
    try {
        if ($script:Form) {
            $script:Form.Cursor = if ($Busy) { [System.Windows.Forms.Cursors]::WaitCursor } else { [System.Windows.Forms.Cursors]::Default }
        }
        if ($script:StatusLabel) {
            $script:StatusLabel.Text = if ($Text) { $Text } else { '就绪' }
        }
        [System.Windows.Forms.Application]::DoEvents()
    } catch {
    }
}

function Populate-Adapters {
    if (-not $script:AdapterCombo) {
        return
    }
    $previous = ''
    if ($script:AdapterCombo.SelectedIndex -gt 0 -and ($script:AdapterCombo.SelectedIndex - 1) -lt $script:Adapters.Count) {
        $previous = $script:Adapters[$script:AdapterCombo.SelectedIndex - 1].Name
    }
    $script:Adapters = @(Get-LocalAdapters)
    $script:AdapterCombo.Items.Clear()
    [void]$script:AdapterCombo.Items.Add('自动选择')
    foreach ($adapter in $script:Adapters) {
        [void]$script:AdapterCombo.Items.Add((Get-AdapterDisplay -Adapter $adapter))
    }
    $script:AdapterCombo.SelectedIndex = 0
    if ($previous) {
        for ($i = 0; $i -lt $script:Adapters.Count; $i++) {
            if ($script:Adapters[$i].Name -eq $previous) {
                $script:AdapterCombo.SelectedIndex = $i + 1
                break
            }
        }
    }
    Update-AdapterSummary
}

function Get-UiMode {
    if (-not $script:ModeCombo) {
        return 'Auto'
    }
    return @('Auto', 'Lan', 'Direct')[$script:ModeCombo.SelectedIndex]
}

function Get-SelectedAdapter {
    if (-not $script:AdapterCombo) {
        return $null
    }
    $index = $script:AdapterCombo.SelectedIndex
    if ($index -gt 0 -and ($index - 1) -lt $script:Adapters.Count) {
        return $script:Adapters[$index - 1]
    }
    return (Select-BestAdapter -SelectedMode (Get-UiMode))
}

function Format-HistoryTime {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }
    try {
        return ([datetime]$Value).ToString('yyyy-MM-dd HH:mm')
    } catch {
        return $Value
    }
}

function Update-AdapterSummary {
    if (-not $script:LblClientAdapter) {
        return
    }
    $adapter = Get-SelectedAdapter
    if ($adapter) {
        $script:LblClientAdapter.Text = "网卡：$($adapter.Name)"
    } else {
        $script:LblClientAdapter.Text = '网卡：未检测到'
    }
}

function Refresh-Adapters {
    if ($script:HostRunning) {
        Show-UiError '共享进行中，停止共享后才能刷新网卡。'
        return
    }
    if ($script:ClientSearching -or $script:ClientConnecting) {
        Show-UiError '搜索或连接进行中，请稍后再刷新网卡。'
        return
    }
    $before = Get-SelectedAdapter
    $beforeName = ''
    if ($before) {
        $beforeName = [string]$before.Name
    }
    Populate-Adapters
    $after = Get-SelectedAdapter
    Update-AdapterSummary
    if (-not $after) {
        Show-UiError '未检测到可用网卡。请检查网线、Wi-Fi 或虚拟网卡状态。'
        return
    }
    if ($beforeName -and $after.Name -ne $beforeName) {
        Add-UiLog "原网卡 $beforeName 已不可用，已切换到 $($after.Name)" 'WARN'
    }
    $ip = '无 IP'
    if (@($after.IPv4).Count -gt 0) {
        $ip = [string]$after.IPv4[0].ip
    }
    Add-UiLog "已刷新网卡列表：$($script:Adapters.Count) 个；当前 $($after.Name) / $ip"
    Save-Settings
}

function Refresh-HistoryGrid {
    if (-not $script:HistoryGrid) {
        return
    }
    $script:RefreshingHistory = $true
    try {
        $history = @(Get-ClientHistory)
        $script:HistoryGrid.Rows.Clear()
        foreach ($record in $history) {
            $lastSeen = Format-HistoryTime -Value ([string]$record.lastSeen)
            $rowIndex = $script:HistoryGrid.Rows.Add(
                [bool]$record.remembered,
                [string]$record.name,
                [string]$record.lastIp,
                $lastSeen,
                [int]$record.connectCount,
                '🗑'
            )
            $script:HistoryGrid.Rows[$rowIndex].Tag = [string]$record.id
        }
        if ($script:HistoryTab) {
            $script:HistoryTab.Text = "历史电脑 ($($history.Count))"
        }
        if ($script:LblHistoryEmpty) {
            $script:LblHistoryEmpty.Visible = ($history.Count -eq 0)
        }
    } finally {
        $script:RefreshingHistory = $false
    }
}

function Show-ApprovalDialog {
    param($Request)
    $clientName = [string]$Request.msg.client
    if (-not $clientName) {
        $clientName = '未知电脑'
    }
    $clientIp = $Request.remote.Address.ToString()
    $script:ApprovalSeconds = 30

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = '连接请求'
    $dlg.ClientSize = New-Object System.Drawing.Size(460, 230)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.TopMost = $true
    $dlg.ShowInTaskbar = $true
    $dlg.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#F8FAFC')
    $dlg.Font = New-UiFont -Size 9

    $title = New-UiLabel -Text '有电脑请求连接' -X 24 -Y 20 -W 412 -H 32 -Size 14 -Bold $true -Color '#0F172A'
    $dlg.Controls.Add($title)
    $info = New-UiLabel -Text ("{0}（{1}）请求访问你的共享文件夹。" -f $clientName, $clientIp) -X 24 -Y 62 -W 412 -H 48 -Size 10 -Color '#334155'
    $dlg.Controls.Add($info)
    $hint = New-UiLabel -Text '允许后，对方将获得本次共享的访问权限。' -X 24 -Y 112 -W 412 -H 26 -Size 9 -Color '#64748B'
    $dlg.Controls.Add($hint)
    $countdownLabel = New-UiLabel -Text '30 秒后自动拒绝' -X 24 -Y 146 -W 200 -H 24 -Size 9 -Color '#DC2626'
    $dlg.Controls.Add($countdownLabel)
    $script:ApprovalDialog = $dlg
    $script:ApprovalCountdownLabel = $countdownLabel

    $btnAllow = New-UiButton -Text '允许' -X 250 -Y 176 -W 90 -H 36 -BackColor '#16A34A' -ForeColor '#FFFFFF' -Size 10
    $btnDeny = New-UiButton -Text '拒绝' -X 350 -Y 176 -W 90 -H 36 -BackColor '#E2E8F0' -ForeColor '#334155' -Size 10
    $btnAllow.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $btnDeny.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($btnAllow)
    $dlg.Controls.Add($btnDeny)
    $dlg.AcceptButton = $btnAllow
    $dlg.CancelButton = $btnDeny

    $script:ApprovalTimer = New-Object System.Windows.Forms.Timer
    $script:ApprovalTimer.Interval = 1000
    $script:ApprovalTimer.Add_Tick({
            $script:ApprovalSeconds--
            if ($script:ApprovalSeconds -le 0) {
                $script:ApprovalTimer.Stop()
                $script:ApprovalDialog.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
                $script:ApprovalDialog.Close()
                return
            }
            $script:ApprovalCountdownLabel.Text = "$($script:ApprovalSeconds) 秒后自动拒绝"
        })
    $dlg.Add_Shown({
            $script:ApprovalTimer.Start()
            $script:ApprovalDialog.Activate()
            $script:ApprovalDialog.BringToFront()
        })
    $dlg.Add_FormClosed({
            $script:ApprovalTimer.Stop()
            $script:ApprovalTimer.Dispose()
            $script:ApprovalDialog = $null
            $script:ApprovalCountdownLabel = $null
            $script:ApprovalTimer = $null
        })

    $result = $dlg.ShowDialog($script:Form)
    return ($result -eq [System.Windows.Forms.DialogResult]::OK)
}

function Send-HostGrant {
    param($Item)
    if (-not $script:ShareInfo) {
        return
    }
    $payload = @{
        magic    = 'LANLINK'
        v        = 1
        type     = 'grant'
        nonce    = $Item.msg.nonce
        ip       = $script:ShareInfo.ip
        share    = $script:ShareInfo.share
        user     = $script:ShareInfo.user
        pass     = $script:ShareInfo.pass
        host     = $env:COMPUTERNAME
        port     = $script:ListenPort
        readOnly = [bool]$script:ShareInfo.readOnly
    }
    $script:HostOutbox.Enqueue(@{ remote = $Item.remote; payload = $payload })
    $clientId = [string]$Item.msg.clientId
    if ($clientId -and -not $script:ConnectedClients.ContainsKey($clientId)) {
        $script:ConnectedClients[$clientId] = $true
        if ($script:ClientList) {
            $row = New-Object System.Windows.Forms.ListViewItem([string]$Item.msg.client)
            [void]$row.SubItems.Add($Item.remote.Address.ToString())
            [void]$row.SubItems.Add((Get-Date).ToString('HH:mm:ss'))
            $row.Tag = $clientId
            [void]$script:ClientList.Items.Add($row)
        }
    }
    if ($clientId) {
        $historyRecord = Update-ClientHistory -Id $clientId -Name ([string]$Item.msg.client) -Ip ($Item.remote.Address.ToString())
        if (Apply-ClientDefaultRemember -Id $clientId) {
            Add-UiLog "已按默认设置记住 $($Item.msg.client)，下次免确认"
        }
        Refresh-HistoryGrid
    }
    Add-UiLog "已允许 $($Item.msg.client)（$($Item.remote.Address)）访问共享"
    if ($script:LblHostStatus) {
        $script:LblHostStatus.Text = "共享中：$($script:ShareInfo.share)  |  $($script:ShareInfo.ip)  |  已连接 $($script:ConnectedClients.Count) 台"
    }
}

function Send-HostDeny {
    param(
        $Item,
        [string]$Reason = '主机拒绝'
    )
    $payload = @{
        magic  = 'LANLINK'
        v      = 1
        type   = 'deny'
        nonce  = $Item.msg.nonce
        reason = $Reason
    }
    $script:HostOutbox.Enqueue(@{ remote = $Item.remote; payload = $payload })
    Add-UiLog "已拒绝 $($Item.msg.client)（$($Item.remote.Address)）：$Reason"
}

function Handle-HostRequest {
    param($Item)
    if ($script:InRequestDialog) {
        $script:PendingHostRequests.Enqueue($Item)
        return
    }
    $script:InRequestDialog = $true
    try {
        $clientId = [string]$Item.msg.clientId
        if (Test-AllowedClient -Id $clientId) {
            Add-UiLog "已授权电脑 $($Item.msg.client) 自动连接"
            Send-HostGrant -Item $Item
            return
        }
        $allowed = Show-ApprovalDialog -Request $Item
        if ($allowed) {
            Send-HostGrant -Item $Item
        } else {
            Send-HostDeny -Item $Item -Reason '主机用户拒绝或超时'
        }
    } finally {
        $script:InRequestDialog = $false
    }
    $next = $null
    if ($script:PendingHostRequests.TryDequeue([ref]$next)) {
        Handle-HostRequest -Item $next
    }
}

function Remove-HostClient {
    param($Item)
    $clientId = [string]$Item.msg.clientId
    $clientName = [string]$Item.msg.client
    if (-not $clientName) {
        $clientName = '未知客户端'
    }
    if ($clientId -and $script:ConnectedClients -and $script:ConnectedClients.ContainsKey($clientId)) {
        [void]$script:ConnectedClients.Remove($clientId)
        if ($script:ClientList) {
            for ($i = $script:ClientList.Items.Count - 1; $i -ge 0; $i--) {
                if ([string]$script:ClientList.Items[$i].Tag -eq $clientId) {
                    $script:ClientList.Items.RemoveAt($i)
                }
            }
        }
    }
    Add-UiLog "客户端 $clientName 已断开"
    if ($script:LblHostStatus -and $script:ShareInfo) {
        $script:LblHostStatus.Text = "共享中：$($script:ShareInfo.share)  |  $($script:ShareInfo.ip)  |  已连接 $($script:ConnectedClients.Count) 台"
    }
}

function Update-UiQueues {
    if ($script:HostInbox -and -not $script:InRequestDialog) {
        $item = $null
        if ($script:HostInbox.TryDequeue([ref]$item)) {
            if ($item.kind -eq 'error') {
                Show-UiError "发现服务错误：$($item.error)"
            } elseif ($item.kind -eq 'ready') {
                Add-UiLog "UDP 发现服务已就绪（端口 $($item.port)）"
            } elseif ($item.kind -eq 'debug') {
                Add-UiLog ([string]$item.message)
            } elseif ($item.kind -eq 'request') {
                Handle-HostRequest -Item $item
            } elseif ($item.kind -eq 'disconnect') {
                Remove-HostClient -Item $item
            }
        }
    }
    if ($script:ClientEvents) {
        $event = $null
        while ($script:ClientEvents.TryDequeue([ref]$event)) {
            Handle-ClientEvent -Event $event
        }
    }
}

function Handle-ClientEvent {
    param($Event)
    switch ($Event.kind) {
        'hosts' {
            $script:ClientSearching = $false
            Stop-ClientDiscovery
            $hosts = @($Event.hosts)
            if ($hosts.Count -eq 0 -and $script:ClientSearchMode -eq 'Direct' -and $script:DirectCandidateIndex -lt ($script:DirectCandidates.Count - 1)) {
                $script:DirectCandidateIndex++
                Add-UiLog '当前网段未发现主机，尝试下一个直连网段...'
                Start-DirectCandidate
                return
            }
            $script:DiscoveredHosts = $hosts
            if ($script:HostList) {
                $script:HostList.Items.Clear()
                foreach ($hostInfo in $hosts) {
                    $row = New-Object System.Windows.Forms.ListViewItem([string]$hostInfo.host)
                    [void]$row.SubItems.Add([string]$hostInfo.ip)
                    [void]$row.SubItems.Add([string]$hostInfo.mode)
                    $row.Tag = $hostInfo
                    [void]$script:HostList.Items.Add($row)
                }
            }
            if ($hosts.Count -gt 0) {
                if ($script:LblClientStatus) {
                    $script:LblClientStatus.Text = "发现 $($hosts.Count) 台主机，选中后点【连接】"
                }
                Add-UiLog "发现 $($hosts.Count) 台主机"
            } else {
                if ($script:LblClientStatus) {
                    $script:LblClientStatus.Text = '未发现主机。请确认另一台电脑已点【启动共享】且窗口未关闭。'
                }
                Add-UiLog '未发现主机：请确认主机端共享仍在运行（不要点停止/关闭窗口），再重试。'
            }
            Set-UiBusy $false '就绪'
        }
        'debug' {
            if ($Event.message) {
                Add-UiLog ([string]$Event.message)
            }
        }
        'grant' {
            $script:ClientConnecting = $false
            Stop-ClientConnect
            try {
                Set-UiBusy $true '正在映射共享...'
                $result = Connect-LanLinkShare -Grant $Event.msg
                Set-UiBusy $false "已连接 $($result.drive):"
            } catch {
                Set-UiBusy $false '连接失败'
                Show-UiError $_.Exception.Message
            }
        }
        'deny' {
            $script:ClientConnecting = $false
            Stop-ClientConnect
            Set-UiBusy $false '已拒绝'
            Show-UiError "主机拒绝了连接：$($Event.msg.reason)"
        }
        'timeout' {
            $script:ClientConnecting = $false
            Stop-ClientConnect
            Set-UiBusy $false '等待超时'
            Show-UiError '等待主机确认超时。请确认主机端弹出了确认窗口并点了“允许”。'
        }
        'error' {
            $script:ClientConnecting = $false
            $script:ClientSearching = $false
            Stop-ClientConnect
            Set-UiBusy $false '出错'
            Show-UiError "发现/连接失败：$($Event.error)"
        }
    }
}

function Start-DirectCandidate {
    $candidate = $script:DirectCandidates[$script:DirectCandidateIndex]
    $script:ClientSearching = $true
    try {
        Set-UiBusy $true "正在配置直连地址（$candidate.0/24）..."
        $result = Invoke-Helper -Command 'configureDirect' -Payload @{
            adapterName = $script:ClientAdapter.Name
            role        = 'Client'
            subnets     = @($candidate)
            dryRun      = [bool]$DryRun
        }
        $script:ClientAdapterIp = $result.ip
        Add-UiLog "本机直连地址：$($result.ip)/24，搜索 $candidate.0/24 ..."
        Start-Sleep -Milliseconds 300
        Start-ClientDiscovery -AdapterIp $result.ip -PrefixLength 24 -DirectHostIp "$candidate.1"
        Set-UiBusy $false '正在搜索主机...'
    } catch {
        $script:ClientSearching = $false
        Set-UiBusy $false '配置失败'
        Show-UiError $_.Exception.Message
    }
}

function Start-HostAction {
    if ($script:HostRunning) {
        return
    }
    $path = $script:TxtSharePath.Text.Trim()
    if (-not $path) {
        Show-UiError '请先选择共享文件夹'
        return
    }
    $adapter = Get-SelectedAdapter
    if (-not $adapter) {
        Show-UiError '未找到可用网卡'
        return
    }
    $selectedMode = Get-UiMode
    $effectiveMode = Get-EffectiveModeForAdapter -Adapter $adapter -SelectedMode $selectedMode
    if ($effectiveMode -eq 'Direct' -and $adapter.Type -notmatch 'Ethernet') {
        Show-UiError '网线直连需要选择以太网卡。请插好网线，或在“网卡”下拉框中手动选择以太网卡。'
        return
    }

    if ($script:BtnStartHost) {
        $script:BtnStartHost.Enabled = $false
    }
    try {
        Set-UiBusy $true '正在请求管理员权限...'
        Ensure-Helper
        $ip = $null
        if ($effectiveMode -eq 'Direct') {
            Add-UiLog "配置网线直连：$($adapter.Name)"
            $result = Invoke-Helper -Command 'configureDirect' -Payload @{
                adapterName = $adapter.Name
                role        = 'Host'
                subnets     = $script:DirectCandidates
                dryRun      = [bool]$DryRun
            }
            $ip = $result.ip
            Add-UiLog "主机直连地址：$ip/24"
        } else {
            Add-UiLog "使用局域网模式：$($adapter.Name)"
            $info = @(Invoke-Helper -Command 'getNetworkInfo' -Payload @{})
            $adapterInfo = @($info | Where-Object { $_.name -eq $adapter.Name }) | Select-Object -First 1
            $addresses = @()
            if ($adapterInfo) {
                $addresses = @($adapterInfo.ipv4 | Where-Object { $_.ipAddress })
            }
            $validAddresses = @($addresses | Where-Object { $_.ipAddress -notlike '169.254.*' })
            if ($validAddresses.Count -gt 0) {
                $ip = [string]$validAddresses[0].ipAddress
            } elseif ($addresses.Count -gt 0) {
                $ip = [string]$addresses[0].ipAddress
            }
            if (-not $ip) {
                throw "网卡 $($adapter.Name) 没有可用的 IPv4 地址"
            }
            if ($ip -like '169.254.*') {
                throw "网卡 $($adapter.Name) 只有 169.254 自动地址，说明没有拿到 DHCP。请检查网线/路由器，或把连接方式改为【仅网线直连】。"
            }
        }

        Set-UiBusy $true '正在创建共享和防火墙规则...'
        $share = Invoke-Helper -Command 'ensureShare' -Payload @{
            path        = $path
            shareName   = 'LanLink'
            readOnly    = [bool]$script:ChkReadOnly.Checked
            adapterName = $adapter.Name
            dryRun      = [bool]$DryRun
        }
        if ($DryRun) {
            Add-UiLog "[DryRun] 将共享 $($share.path) 为 \\$ip\$($share.shareName)（只读=$($share.readOnly)）"
            Set-UiBusy $false 'DryRun 完成'
            return
        }
        $script:ShareInfo = @{
            ip      = [string]$share.ip
            share   = [string]$share.shareName
            user    = [string]$share.user
            pass    = [string]$share.password
            path    = [string]$share.path
            readOnly = [bool]$share.readOnly
            mode    = $effectiveMode
        }
        $script:ConnectedClients = @{}
        Start-HostDiscovery
        $script:HostRunning = $true
        $script:BtnStartHost.Enabled = $false
        $script:BtnStopHost.Enabled = $true
        $script:TxtSharePath.Enabled = $false
        $script:ModeCombo.Enabled = $false
        $script:AdapterCombo.Enabled = $false
        $script:BtnBrowse.Enabled = $false
        if ($script:BtnRefreshAdapters) {
            $script:BtnRefreshAdapters.Enabled = $false
        }
        if ($script:BtnRefreshClientAdapters) {
            $script:BtnRefreshClientAdapters.Enabled = $false
        }
        $script:LblHostStatus.Text = "共享中：$($share.shareName)  |  $($share.ip)  |  等待客户端..."
        $script:LblHeaderStatus.Text = '主机共享中'
        Add-UiLog "共享已启动：\\$($share.ip)\$($share.shareName)"
        Add-UiLog "账户：$($share.user)（密码仅本次会话有效，不会保存）"
        Save-Settings
        Set-UiBusy $false '等待客户端连接'
    } catch {
        Set-UiBusy $false '启动失败'
        Show-UiError $_.Exception.Message
        if ($script:ShareInfo) {
            if ($script:BtnStopHost) {
                $script:BtnStopHost.Enabled = $true
            }
        } elseif ($script:BtnStartHost) {
            $script:BtnStartHost.Enabled = $true
            if ($script:BtnRefreshAdapters) {
                $script:BtnRefreshAdapters.Enabled = $true
            }
            if ($script:BtnRefreshClientAdapters) {
                $script:BtnRefreshClientAdapters.Enabled = $true
            }
        }
    }
}

function Stop-HostAction {
    if (-not $script:HostRunning -and -not $script:ShareInfo) {
        return
    }
    $uiCount = 0
    if ($script:ConnectedClients) {
        $uiCount = $script:ConnectedClients.Count
    }
    $activeCount = $uiCount
    try {
        $sessionInfo = Invoke-Helper -Command 'getSessions' -Payload @{}
        if ($sessionInfo -and $sessionInfo.supported) {
            $sessionCount = @($sessionInfo.sessions).Count
            if ($uiCount -eq 0) {
                # 客户端已通过 UDP 断开通知清理了界面列表，不再因为 SMB 会话延迟而误报。
                $activeCount = 0
            } elseif ($sessionCount -eq 0) {
                Add-UiLog '检测到客户端已断开，清理主机端连接列表'
                $script:ConnectedClients = @{}
                if ($script:ClientList) {
                    $script:ClientList.Items.Clear()
                }
                if ($script:LblHostStatus -and $script:ShareInfo) {
                    $script:LblHostStatus.Text = "共享中：$($script:ShareInfo.share)  |  $($script:ShareInfo.ip)  |  已连接 0 台"
                }
                $activeCount = 0
            } else {
                $activeCount = $sessionCount
            }
        }
    } catch {
        Add-UiLog "查询客户端会话失败，按界面列表判断：$($_.Exception.Message)" 'WARN'
    }
    $message = '停止共享并还原网络配置？'
    if ($activeCount -gt 0) {
        $message = "当前有 $activeCount 台客户端连接。停止共享并还原网络配置？"
    }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        $message,
        '停止共享',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }
    $restored = $false
    try {
        Set-UiBusy $true '正在停止并还原...'
        Stop-HostDiscovery
        $result = Invoke-Helper -Command 'restoreAll' -Payload @{}
        if ($result -and @($result.warnings).Count -gt 0) {
            foreach ($warning in @($result.warnings)) {
                Add-UiLog "还原警告：$warning" 'WARN'
            }
        }
        if ($result -and $result.stateKept) {
            Show-UiError '部分配置未能还原，状态已保留。请检查日志后重试。'
        } else {
            Add-UiLog '已停止共享并还原网络配置'
            $restored = $true
        }
    } catch {
        Show-UiError "停止/还原失败：$($_.Exception.Message)"
    } finally {
        $script:HostRunning = $false
        if ($restored) {
            $script:ShareInfo = $null
            $script:ConnectedClients = @{}
            if ($script:ClientList) {
                $script:ClientList.Items.Clear()
            }
            if ($script:BtnStartHost) {
                $script:BtnStartHost.Enabled = $true
                $script:BtnStopHost.Enabled = $false
                $script:TxtSharePath.Enabled = $true
                $script:ModeCombo.Enabled = $true
                $script:AdapterCombo.Enabled = $true
                $script:BtnBrowse.Enabled = $true
                if ($script:BtnRefreshAdapters) {
                    $script:BtnRefreshAdapters.Enabled = $true
                }
                if ($script:BtnRefreshClientAdapters) {
                    $script:BtnRefreshClientAdapters.Enabled = $true
                }
                $script:LblHostStatus.Text = '未启动'
            }
            $script:LblHeaderStatus.Text = '就绪'
            Set-UiBusy $false '就绪'
        } else {
            if ($script:BtnStopHost) {
                $script:BtnStopHost.Enabled = $true
            }
            if ($script:LblHostStatus) {
                $script:LblHostStatus.Text = '还原失败，请重试'
            }
            $script:LblHeaderStatus.Text = '还原失败'
            Set-UiBusy $false '还原失败'
        }
    }
}

function Start-ClientSearchAction {
    if ($script:ClientSearching -or $script:ClientConnecting) {
        return
    }
    $adapter = Get-SelectedAdapter
    if (-not $adapter) {
        Show-UiError '未找到可用网卡'
        return
    }
    $effectiveMode = Get-EffectiveModeForAdapter -Adapter $adapter -SelectedMode (Get-UiMode)
    if ($effectiveMode -eq 'Direct' -and $adapter.Type -notmatch 'Ethernet') {
        Show-UiError '网线直连需要选择以太网卡。请插好网线，或手动选择以太网卡。'
        return
    }
    $script:ClientSearchMode = $effectiveMode
    $script:ClientAdapter = $adapter
    $script:ClientSearching = $true
    $script:DiscoveredHosts = @()
    if ($script:HostList) {
        $script:HostList.Items.Clear()
    }
    if ($script:LblClientStatus) {
        $script:LblClientStatus.Text = '正在搜索主机...'
    }

    try {
        if ($effectiveMode -eq 'Direct') {
            Set-UiBusy $true '正在请求管理员权限...'
            Ensure-Helper
            $script:DirectCandidateIndex = 0
            Start-DirectCandidate
        } else {
            if (@($adapter.IPv4).Count -eq 0) {
                throw "网卡 $($adapter.Name) 没有 IPv4 地址，无法搜索局域网主机"
            }
            Add-UiLog "在局域网中搜索主机（$($adapter.Name)）..."
            Start-ClientDiscovery -AdapterIp $adapter.IPv4[0].ip -PrefixLength $adapter.IPv4[0].prefix
            Set-UiBusy $false '正在搜索主机...'
        }
    } catch {
        $script:ClientSearching = $false
        Set-UiBusy $false '搜索失败'
        Show-UiError $_.Exception.Message
    }
}

function Connect-SelectedHostAction {
    if ($script:ClientConnecting) {
        return
    }
    $hostInfo = $null
    if ($script:HostList -and $script:HostList.SelectedItems.Count -gt 0) {
        $hostInfo = $script:HostList.SelectedItems[0].Tag
    }
    if (-not $hostInfo) {
        $manual = $script:TxtManualIp.Text.Trim()
        if ($manual) {
            $parsed = $null
            if (-not [System.Net.IPAddress]::TryParse($manual, [ref]$parsed)) {
                Show-UiError "手动输入的 IP 不合法：$manual"
                return
            }
            $hostInfo = [pscustomobject]@{ host = '手动主机'; ip = $manual; mode = 'Manual' }
        }
    }
    if (-not $hostInfo) {
        Show-UiError '请先在列表中选择一台主机，或手动输入主机 IP'
        return
    }
    $script:ClientConnecting = $true
    try {
        Stop-ClientDiscovery
        Set-UiBusy $true '等待主机确认...'
        Add-UiLog "正在请求连接 $($hostInfo.ip) ..."
        Start-ClientConnect -HostInfo $hostInfo
        if ($script:LblClientStatus) {
            $script:LblClientStatus.Text = "等待 $($hostInfo.ip) 确认..."
        }
    } catch {
        $script:ClientConnecting = $false
        Set-UiBusy $false '连接失败'
        Show-UiError $_.Exception.Message
    }
}

function Disconnect-ClientAction {
    if (-not $script:ClientConnected) {
        return
    }
    Disconnect-LanLinkShare
    Set-UiBusy $false '已断开'
}

function Restore-ClientAction {
    if ($script:ClientConnected) {
        Disconnect-LanLinkShare
    }
    try {
        Set-UiBusy $true '正在还原本机网络配置...'
        Ensure-Helper
        $result = Invoke-Helper -Command 'restoreAll' -Payload @{}
        if ($result -and @($result.warnings).Count -gt 0) {
            foreach ($warning in @($result.warnings)) {
                Add-UiLog "还原警告：$warning" 'WARN'
            }
        }
        Add-UiLog '本机网络配置已还原'
        Set-UiBusy $false '已还原'
    } catch {
        Set-UiBusy $false '还原失败'
        Show-UiError $_.Exception.Message
    }
}

function Initialize-Ui {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    [System.Windows.Forms.Application]::EnableVisualStyles()
    [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = '双机快传 LanLink'
    $form.ClientSize = New-Object System.Drawing.Size(880, 640)
    $form.MinimumSize = New-Object System.Drawing.Size(800, 590)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.Location = New-Object System.Drawing.Point(20, 20)
    $form.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#F1F5F9')
    $form.Font = New-UiFont -Size 9
    $script:Form = $form

    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = [System.Windows.Forms.DockStyle]::Top
    $header.Height = 84
    $header.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#0F172A')

    $title = New-UiLabel -Text '双机快传 LanLink' -X 20 -Y 12 -W 420 -H 38 -Size 19 -Bold $true -Color '#FFFFFF'
    $header.Controls.Add($title)
    $subtitle = New-UiLabel -Text '局域网 / 网线直连 · 一键共享与传输' -X 22 -Y 50 -W 460 -H 24 -Size 9 -Color '#93C5FD'
    $header.Controls.Add($subtitle)
    $script:LblHeaderStatus = New-UiLabel -Text '就绪' -X 600 -Y 22 -W 250 -H 32 -Size 10 -Bold $true -Color '#93C5FD' -Align 'MiddleRight'
    $header.Controls.Add($script:LblHeaderStatus)

    $rolePanel = New-Object System.Windows.Forms.Panel
    $rolePanel.Dock = [System.Windows.Forms.DockStyle]::Top
    $rolePanel.Height = 82
    $rolePanel.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#F8FAFC')

    $script:BtnRoleHost = New-UiButton -Text '① 作为主机：共享文件夹' -X 16 -Y 12 -W 416 -H 58 -BackColor '#2563EB' -ForeColor '#FFFFFF' -Size 12
    $script:BtnRoleClient = New-UiButton -Text '② 作为客户端：连接主机' -X 448 -Y 12 -W 416 -H 58 -BackColor '#DCFCE7' -ForeColor '#166534' -Size 12
    $rolePanel.Controls.Add($script:BtnRoleHost)
    $rolePanel.Controls.Add($script:BtnRoleClient)

    $content = New-Object System.Windows.Forms.Panel
    $content.Dock = [System.Windows.Forms.DockStyle]::Fill
    $content.AutoScroll = $true
    $content.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#F1F5F9')

    # 主机面板
    $hostPanel = New-Object System.Windows.Forms.GroupBox
    $hostPanel.Text = '主机 · 共享文件夹'
    $hostPanel.Location = New-Object System.Drawing.Point(16, 10)
    $hostPanel.Size = New-Object System.Drawing.Size(832, 318)
    $hostPanel.Font = New-UiFont -Size 10 -Bold $true
    $hostPanel.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#1E293B')
    $hostPanel.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#FFFFFF')
    $content.Controls.Add($hostPanel)
    $script:HostPanel = $hostPanel

    $hostPanel.Controls.Add((New-UiLabel -Text '共享文件夹' -X 18 -Y 32 -W 88 -H 28 -Size 9 -Color '#334155'))
    $script:TxtSharePath = New-Object System.Windows.Forms.TextBox
    $script:TxtSharePath.Location = New-Object System.Drawing.Point(110, 28)
    $script:TxtSharePath.Size = New-Object System.Drawing.Size(560, 30)
    $script:TxtSharePath.Font = New-UiFont -Size 9
    $script:TxtSharePath.Text = $script:DefaultSharePath
    $hostPanel.Controls.Add($script:TxtSharePath)

    $script:BtnBrowse = New-UiButton -Text '浏览...' -X 682 -Y 26 -W 130 -H 32 -BackColor '#E2E8F0' -ForeColor '#334155' -Size 9 -Bold $false
    $hostPanel.Controls.Add($script:BtnBrowse)

    $hostPanel.Controls.Add((New-UiLabel -Text '连接方式' -X 18 -Y 76 -W 88 -H 28 -Size 9 -Color '#334155'))
    $script:ModeCombo = New-Object System.Windows.Forms.ComboBox
    $script:ModeCombo.Location = New-Object System.Drawing.Point(110, 72)
    $script:ModeCombo.Size = New-Object System.Drawing.Size(170, 30)
    $script:ModeCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $script:ModeCombo.Font = New-UiFont -Size 9
    [void]$script:ModeCombo.Items.Add('自动识别')
    [void]$script:ModeCombo.Items.Add('仅局域网（路由器/交换机）')
    [void]$script:ModeCombo.Items.Add('仅网线直连')
    $script:ModeCombo.SelectedIndex = 0
    $hostPanel.Controls.Add($script:ModeCombo)

    $hostPanel.Controls.Add((New-UiLabel -Text '网卡' -X 300 -Y 76 -W 48 -H 28 -Size 9 -Color '#334155'))
    $script:AdapterCombo = New-Object System.Windows.Forms.ComboBox
    $script:AdapterCombo.Location = New-Object System.Drawing.Point(355, 72)
    $script:AdapterCombo.Size = New-Object System.Drawing.Size(355, 30)
    $script:AdapterCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $script:AdapterCombo.Font = New-UiFont -Size 9
    $hostPanel.Controls.Add($script:AdapterCombo)

    $script:BtnRefreshAdapters = New-UiButton -Text '刷新网卡' -X 720 -Y 72 -W 90 -H 30 -BackColor '#E2E8F0' -ForeColor '#334155' -Size 8 -Bold $false
    $hostPanel.Controls.Add($script:BtnRefreshAdapters)

    $script:ChkReadOnly = New-Object System.Windows.Forms.CheckBox
    $script:ChkReadOnly.Text = '只读共享（对方不能修改文件）'
    $script:ChkReadOnly.Location = New-Object System.Drawing.Point(110, 110)
    $script:ChkReadOnly.Size = New-Object System.Drawing.Size(240, 26)
    $script:ChkReadOnly.Font = New-UiFont -Size 9
    $script:ChkReadOnly.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#334155')
    $hostPanel.Controls.Add($script:ChkReadOnly)

    $script:ChkDefaultRemember = New-Object System.Windows.Forms.CheckBox
    $script:ChkDefaultRemember.Text = '默认记住已连接电脑'
    $script:ChkDefaultRemember.Location = New-Object System.Drawing.Point(360, 110)
    $script:ChkDefaultRemember.Size = New-Object System.Drawing.Size(250, 26)
    $script:ChkDefaultRemember.Font = New-UiFont -Size 9
    $script:ChkDefaultRemember.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#334155')
    $script:ChkDefaultRemember.Checked = [bool]$script:DefaultRememberClients
    $hostPanel.Controls.Add($script:ChkDefaultRemember)

    $script:LblDefaultRememberHint = New-UiLabel -Text '仅影响之后连接' -X 615 -Y 112 -W 190 -H 22 -Size 8 -Color '#94A3B8'
    $hostPanel.Controls.Add($script:LblDefaultRememberHint)

    $script:DefaultRememberTip = New-Object System.Windows.Forms.ToolTip
    $script:DefaultRememberTip.AutoPopDelay = 12000
    $script:DefaultRememberTip.InitialDelay = 400
    $script:DefaultRememberTip.ReshowDelay = 200
    $script:DefaultRememberTip.SetToolTip($script:ChkDefaultRemember, '开启后，之后连接的新电脑或历史电脑会自动勾选“记住”；不会立即修改已有列表；手动勾选/取消过的电脑优先。')

    $script:BtnStartHost = New-UiButton -Text '启动共享' -X 110 -Y 146 -W 190 -H 42 -BackColor '#2563EB' -ForeColor '#FFFFFF' -Size 10
    $script:BtnStopHost = New-UiButton -Text '停止共享并还原' -X 318 -Y 146 -W 190 -H 42 -BackColor '#FEE2E2' -ForeColor '#B91C1C' -Size 10
    $script:BtnStopHost.Enabled = $false
    $hostPanel.Controls.Add($script:BtnStartHost)
    $hostPanel.Controls.Add($script:BtnStopHost)

    $script:LblHostStatus = New-UiLabel -Text '未启动' -X 525 -Y 152 -W 285 -H 30 -Size 9 -Color '#64748B'
    $hostPanel.Controls.Add($script:LblHostStatus)

    $script:ClientTabs = New-Object System.Windows.Forms.TabControl
    $script:ClientTabs.Location = New-Object System.Drawing.Point(18, 192)
    $script:ClientTabs.Size = New-Object System.Drawing.Size(787, 116)
    $script:ClientTabs.Font = New-UiFont -Size 9

    $connectedTab = New-Object System.Windows.Forms.TabPage
    $connectedTab.Text = '已连接'
    $connectedTab.BackColor = [System.Drawing.Color]::White
    $connectedTab.Padding = New-Object System.Windows.Forms.Padding(4)
    $script:ClientList = New-Object System.Windows.Forms.ListView
    $script:ClientList.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:ClientList.View = [System.Windows.Forms.View]::Details
    $script:ClientList.FullRowSelect = $true
    $script:ClientList.GridLines = $false
    $script:ClientList.Font = New-UiFont -Size 9
    [void]$script:ClientList.Columns.Add('电脑', 220)
    [void]$script:ClientList.Columns.Add('IP', 260)
    [void]$script:ClientList.Columns.Add('连接时间', 160)
    $connectedTab.Controls.Add($script:ClientList)
    [void]$script:ClientTabs.TabPages.Add($connectedTab)

    $script:HistoryTab = New-Object System.Windows.Forms.TabPage
    $script:HistoryTab.Text = '历史电脑 (0)'
    $script:HistoryTab.BackColor = [System.Drawing.Color]::White
    $script:HistoryTab.Padding = New-Object System.Windows.Forms.Padding(4)

    $script:HistoryGrid = New-Object System.Windows.Forms.DataGridView
    $script:HistoryGrid.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:HistoryGrid.AllowUserToAddRows = $false
    $script:HistoryGrid.AllowUserToDeleteRows = $false
    $script:HistoryGrid.AllowUserToResizeRows = $false
    $script:HistoryGrid.RowHeadersVisible = $false
    $script:HistoryGrid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $script:HistoryGrid.MultiSelect = $false
    $script:HistoryGrid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
    $script:HistoryGrid.BackgroundColor = [System.Drawing.Color]::White
    $script:HistoryGrid.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $script:HistoryGrid.CellBorderStyle = [System.Windows.Forms.DataGridViewCellBorderStyle]::SingleHorizontal
    $script:HistoryGrid.GridColor = [System.Drawing.ColorTranslator]::FromHtml('#E2E8F0')
    $script:HistoryGrid.ColumnHeadersHeight = 26
    $script:HistoryGrid.RowTemplate.Height = 24
    $script:HistoryGrid.EditMode = [System.Windows.Forms.DataGridViewEditMode]::EditOnEnter
    $script:HistoryGrid.Font = New-UiFont -Size 9

    $rememberColumn = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $rememberColumn.HeaderText = '记住'
    $rememberColumn.Width = 55
    $rememberColumn.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::None
    $rememberColumn.ReadOnly = $true
    $rememberColumn.ThreeState = $false
    $rememberColumn.TrueValue = $true
    $rememberColumn.FalseValue = $false
    [void]$script:HistoryGrid.Columns.Add($rememberColumn)

    $nameColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $nameColumn.HeaderText = '电脑名'
    $nameColumn.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
    $nameColumn.FillWeight = 35
    $nameColumn.MinimumWidth = 150
    $nameColumn.ReadOnly = $true
    [void]$script:HistoryGrid.Columns.Add($nameColumn)

    $ipColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $ipColumn.HeaderText = 'IP'
    $ipColumn.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
    $ipColumn.FillWeight = 25
    $ipColumn.MinimumWidth = 120
    $ipColumn.ReadOnly = $true
    [void]$script:HistoryGrid.Columns.Add($ipColumn)

    $lastColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $lastColumn.HeaderText = '最后连接'
    $lastColumn.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
    $lastColumn.FillWeight = 28
    $lastColumn.MinimumWidth = 140
    $lastColumn.ReadOnly = $true
    [void]$script:HistoryGrid.Columns.Add($lastColumn)

    $countColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $countColumn.HeaderText = '次数'
    $countColumn.Width = 55
    $countColumn.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::None
    $countColumn.ReadOnly = $true
    [void]$script:HistoryGrid.Columns.Add($countColumn)

    $deleteColumn = New-Object System.Windows.Forms.DataGridViewButtonColumn
    $deleteColumn.HeaderText = '删除'
    $deleteColumn.Width = 60
    $deleteColumn.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::None
    $deleteColumn.Text = '🗑'
    $deleteColumn.UseColumnTextForButtonValue = $true
    $deleteColumn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    [void]$script:HistoryGrid.Columns.Add($deleteColumn)

    $script:HistoryRememberColumn = 0
    $script:HistoryDeleteColumn = 5
    $script:HistoryTab.Controls.Add($script:HistoryGrid)

    $script:LblHistoryEmpty = New-UiLabel -Text '暂无历史电脑，连接一次后会自动出现' -X 140 -Y 40 -W 470 -H 26 -Size 9 -Color '#94A3B8' -Align 'MiddleCenter'
    $script:LblHistoryEmpty.BackColor = [System.Drawing.Color]::White
    $script:HistoryTab.Controls.Add($script:LblHistoryEmpty)
    $script:LblHistoryEmpty.BringToFront()

    [void]$script:ClientTabs.TabPages.Add($script:HistoryTab)
    $hostPanel.Controls.Add($script:ClientTabs)

    # 客户端面板
    $clientPanel = New-Object System.Windows.Forms.GroupBox
    $clientPanel.Text = '客户端 · 连接主机'
    $clientPanel.Location = New-Object System.Drawing.Point(16, 10)
    $clientPanel.Size = New-Object System.Drawing.Size(832, 318)
    $clientPanel.Font = New-UiFont -Size 10 -Bold $true
    $clientPanel.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#1E293B')
    $clientPanel.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#FFFFFF')
    $clientPanel.Visible = $false
    $content.Controls.Add($clientPanel)
    $script:ClientPanel = $clientPanel

    $script:BtnSearch = New-UiButton -Text '搜索主机' -X 18 -Y 28 -W 140 -H 36 -BackColor '#16A34A' -ForeColor '#FFFFFF' -Size 10
    $clientPanel.Controls.Add($script:BtnSearch)

    $clientPanel.Controls.Add((New-UiLabel -Text '手动 IP' -X 180 -Y 34 -W 64 -H 26 -Size 9 -Color '#334155'))
    $script:TxtManualIp = New-Object System.Windows.Forms.TextBox
    $script:TxtManualIp.Location = New-Object System.Drawing.Point(250, 32)
    $script:TxtManualIp.Size = New-Object System.Drawing.Size(170, 30)
    $script:TxtManualIp.Font = New-UiFont -Size 9
    $clientPanel.Controls.Add($script:TxtManualIp)
    $script:BtnManualConnect = New-UiButton -Text '连接此 IP' -X 430 -Y 30 -W 120 -H 34 -BackColor '#E2E8F0' -ForeColor '#334155' -Size 9 -Bold $false
    $clientPanel.Controls.Add($script:BtnManualConnect)

    $script:LblClientAdapter = New-UiLabel -Text '网卡：未检测到' -X 560 -Y 34 -W 130 -H 26 -Size 8 -Color '#64748B'
    $script:LblClientAdapter.AutoEllipsis = $true
    $clientPanel.Controls.Add($script:LblClientAdapter)
    $script:BtnRefreshClientAdapters = New-UiButton -Text '刷新网卡' -X 700 -Y 30 -W 110 -H 34 -BackColor '#E2E8F0' -ForeColor '#334155' -Size 9 -Bold $false
    $clientPanel.Controls.Add($script:BtnRefreshClientAdapters)

    $script:HostList = New-Object System.Windows.Forms.ListView
    $script:HostList.Location = New-Object System.Drawing.Point(18, 78)
    $script:HostList.Size = New-Object System.Drawing.Size(795, 150)
    $script:HostList.View = [System.Windows.Forms.View]::Details
    $script:HostList.FullRowSelect = $true
    $script:HostList.GridLines = $false
    $script:HostList.Font = New-UiFont -Size 9
    [void]$script:HostList.Columns.Add('电脑名', 280)
    [void]$script:HostList.Columns.Add('IP 地址', 280)
    [void]$script:HostList.Columns.Add('连接方式', 200)
    $clientPanel.Controls.Add($script:HostList)

    $script:BtnConnect = New-UiButton -Text '连接选中主机' -X 18 -Y 242 -W 170 -H 40 -BackColor '#16A34A' -ForeColor '#FFFFFF' -Size 10
    $script:BtnDisconnect = New-UiButton -Text '断开连接' -X 200 -Y 242 -W 170 -H 40 -BackColor '#FEE2E2' -ForeColor '#B91C1C' -Size 10
    $script:BtnDisconnect.Enabled = $false
    $script:BtnRestoreClient = New-UiButton -Text '还原网络配置' -X 382 -Y 242 -W 170 -H 40 -BackColor '#E2E8F0' -ForeColor '#334155' -Size 10
    $clientPanel.Controls.Add($script:BtnConnect)
    $clientPanel.Controls.Add($script:BtnDisconnect)
    $clientPanel.Controls.Add($script:BtnRestoreClient)

    $script:LblClientStatus = New-UiLabel -Text '未连接' -X 570 -Y 248 -W 240 -H 30 -Size 9 -Color '#64748B'
    $clientPanel.Controls.Add($script:LblClientStatus)

    # 日志
    $logGroup = New-Object System.Windows.Forms.GroupBox
    $logGroup.Text = '运行日志'
    $logGroup.Location = New-Object System.Drawing.Point(16, 338)
    $logGroup.Size = New-Object System.Drawing.Size(832, 110)
    $logGroup.Font = New-UiFont -Size 10 -Bold $true
    $logGroup.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#1E293B')
    $logGroup.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#FFFFFF')
    $content.Controls.Add($logGroup)

    $script:LogBox = New-Object System.Windows.Forms.TextBox
    $script:LogBox.Location = New-Object System.Drawing.Point(12, 24)
    $script:LogBox.Size = New-Object System.Drawing.Size(808, 74)
    $script:LogBox.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $script:LogBox.Multiline = $true
    $script:LogBox.ReadOnly = $true
    $script:LogBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $script:LogBox.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#0B1220')
    $script:LogBox.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#E2E8F0')
    $script:LogBox.Font = New-Object System.Drawing.Font('Consolas', 8.5)
    $logGroup.Controls.Add($script:LogBox)

    $statusStrip = New-Object System.Windows.Forms.StatusStrip
    $statusStrip.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#E2E8F0')
    $script:StatusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $script:StatusLabel.Text = '就绪'
    $versionLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $versionLabel.Text = "v$($script:AppVersion)"
    $versionLabel.Spring = $true
    $versionLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    [void]$statusStrip.Items.Add($script:StatusLabel)
    [void]$statusStrip.Items.Add($versionLabel)
    # 先加 Fill，再加 Bottom/Top；这样 Docking 顺序为 顶部标题、角色栏、底部状态栏、中间内容
    $form.Controls.Add($content)
    $form.Controls.Add($statusStrip)
    $form.Controls.Add($rolePanel)
    $form.Controls.Add($header)

    # 事件
    $script:BtnRoleHost.Add_Click({ Set-Role -SelectedRole 'Host' })
    $script:BtnRoleClient.Add_Click({ Set-Role -SelectedRole 'Client' })
    $script:BtnBrowse.Add_Click({
            $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
            $dialog.Description = '选择共享文件夹'
            $dialog.SelectedPath = $script:TxtSharePath.Text
            if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $script:TxtSharePath.Text = $dialog.SelectedPath
            }
        })
    $script:BtnStartHost.Add_Click({ Start-HostAction })
    $script:BtnStopHost.Add_Click({ Stop-HostAction })
    $script:BtnSearch.Add_Click({ Start-ClientSearchAction })
    $script:BtnConnect.Add_Click({ Connect-SelectedHostAction })
    $script:BtnManualConnect.Add_Click({ Connect-SelectedHostAction })
    $script:BtnDisconnect.Add_Click({ Disconnect-ClientAction })
    $script:BtnRestoreClient.Add_Click({ Restore-ClientAction })
    $script:BtnRefreshAdapters.Add_Click({ Refresh-Adapters })
    $script:BtnRefreshClientAdapters.Add_Click({ Refresh-Adapters })

    $script:HistoryGrid.Add_CellClick({
            param($sender, $eventArgs)
            if ($eventArgs.RowIndex -lt 0) {
                return
            }
            $row = $script:HistoryGrid.Rows[$eventArgs.RowIndex]
            $id = [string]$row.Tag
            $name = [string]$row.Cells[1].Value
            if (-not $name) {
                $name = '该电脑'
            }

            if ($eventArgs.ColumnIndex -eq $script:HistoryRememberColumn) {
                $checked = -not [bool]$row.Cells[$script:HistoryRememberColumn].Value
                $row.Cells[$script:HistoryRememberColumn].Value = $checked
                if (Set-ClientRemembered -Id $id -Remembered $checked -Manual) {
                    if ($checked) {
                        Add-UiLog "已记住电脑 $name，下次免确认"
                    } else {
                        Add-UiLog "已取消记住电脑 $name"
                    }
                } else {
                    Add-UiLog "保存历史电脑设置失败" 'ERROR'
                    Refresh-HistoryGrid
                }
                return
            }

            if ($eventArgs.ColumnIndex -eq $script:HistoryDeleteColumn) {
                $connected = $script:ConnectedClients -and $script:ConnectedClients.ContainsKey($id)
                $message = "删除 $name 的历史记录？删除后下次连接需要重新确认。"
                if ($connected) {
                    $message = "$name 当前仍在连接。删除历史记录不会断开当前连接，下次连接需要重新确认。"
                }
                $answer = [System.Windows.Forms.MessageBox]::Show(
                    $message,
                    '删除历史电脑',
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Question
                )
                if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
                    Remove-ClientHistory -Id $id | Out-Null
                    Refresh-HistoryGrid
                    Add-UiLog "已删除历史电脑 $name"
                }
            }
        })

    $script:ModeCombo.Add_SelectedIndexChanged({ Save-Settings })
    $script:AdapterCombo.Add_SelectedIndexChanged({
            Update-AdapterSummary
            Save-Settings
        })
    $script:ChkReadOnly.Add_CheckedChanged({ Save-Settings })
    $script:ChkDefaultRemember.Add_CheckedChanged({
            $script:DefaultRememberClients = [bool]$script:ChkDefaultRemember.Checked
            Save-Settings
            if (-not $script:SuppressSaveSettings) {
                if ($script:DefaultRememberClients) {
                    Add-UiLog '已开启“默认记住已连接电脑”（仅影响之后连接）'
                } else {
                    Add-UiLog '已关闭“默认记住已连接电脑”（不会清除已有记住状态）'
                }
            }
        })

    $form.Add_Shown({
            $script:SuppressSaveSettings = $true
            Populate-Adapters
            $settings = Load-Settings
            if ($settings) {
                if ($settings.sharePath) {
                    $script:TxtSharePath.Text = [string]$settings.sharePath
                }
                if ($settings.mode) {
                    $modeIndex = @('Auto', 'Lan', 'Direct').IndexOf([string]$settings.mode)
                    if ($modeIndex -ge 0) {
                        $script:ModeCombo.SelectedIndex = $modeIndex
                    }
                }
                if ($settings.adapterName) {
                    for ($i = 0; $i -lt $script:Adapters.Count; $i++) {
                        if ($script:Adapters[$i].Name -eq [string]$settings.adapterName) {
                            $script:AdapterCombo.SelectedIndex = $i + 1
                            break
                        }
                    }
                }
                $script:ChkReadOnly.Checked = [bool]$settings.readOnly
                $defaultRemember = [bool]$RememberClients
                if ($settings.PSObject.Properties['defaultRemember']) {
                    $defaultRemember = [bool]$settings.defaultRemember
                } elseif ($settings.PSObject.Properties['remember']) {
                    $defaultRemember = [bool]$settings.remember
                }
                $script:ChkDefaultRemember.Checked = $defaultRemember
                $script:DefaultRememberClients = $defaultRemember
            } else {
                $script:ChkDefaultRemember.Checked = [bool]$RememberClients
                $script:DefaultRememberClients = [bool]$RememberClients
            }
            $script:SuppressSaveSettings = $false
            Save-Settings
            Update-AdapterSummary
            Refresh-HistoryGrid

            Add-UiLog "双机快传 LanLink v$($script:AppVersion) 已启动"
            Add-UiLog "本机：$env:COMPUTERNAME  |  共享目录默认：$($script:DefaultSharePath)"
            if (Test-Admin) {
                Add-UiLog '提示：当前以管理员身份运行，资源管理器可能看不到映射盘。建议普通权限双击 LanLink.cmd。' 'WARN'
            }
            if (Test-DirtyState) {
                $answer = [System.Windows.Forms.MessageBox]::Show(
                    '检测到上次共享未正常还原（可能修改了 IP、共享或防火墙）。是否现在还原？',
                    '恢复上次配置',
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                )
                if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
                    try {
                        Set-UiBusy $true '正在还原上次配置...'
                        Ensure-Helper
                        $result = Invoke-Helper -Command 'restoreAll' -Payload @{}
                        Add-UiLog '上次配置已还原'
                        Set-UiBusy $false '就绪'
                    } catch {
                        Set-UiBusy $false '还原失败'
                        Show-UiError $_.Exception.Message
                    }
                }
            }
        })

    $form.Add_FormClosing({
            param($sender, $eventArgs)
            if ($script:HostRunning) {
                $answer = [System.Windows.Forms.MessageBox]::Show(
                    '共享仍在进行。关闭窗口前是否停止共享并还原网络配置？',
                    '退出',
                    [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
                    [System.Windows.Forms.MessageBoxIcon]::Question
                )
                if ($answer -eq [System.Windows.Forms.DialogResult]::Cancel) {
                    $eventArgs.Cancel = $true
                    return
                }
                if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
                    try {
                        Stop-HostDiscovery
                        Invoke-Helper -Command 'restoreAll' -Payload @{} | Out-Null
                    } catch {
                        Write-AppLog "退出时还原失败: $($_.Exception.Message)" 'ERROR'
                    }
                }
            }
            Stop-ClientDiscovery
            Stop-ClientConnect
            Stop-HostDiscovery
            Stop-Helper
        })

    $script:UiTimer = New-Object System.Windows.Forms.Timer
    $script:UiTimer.Interval = 250
    $script:UiTimer.Add_Tick({
            try {
                Update-UiQueues
            } catch {
                Write-AppLog "UI 队列处理失败: $($_.Exception.Message)" 'ERROR'
            }
        })
    $script:UiTimer.Start()

    $form.Add_Load({
            try {
                $working = [System.Windows.Forms.Screen]::FromControl($script:Form).WorkingArea
                $maxWidth = $working.Width - 40
                $maxHeight = $working.Height - 80
                if ($script:Form.Width -gt $maxWidth -or $script:Form.Height -gt $maxHeight) {
                    $ratio = [math]::Min($maxWidth / $script:Form.Width, $maxHeight / $script:Form.Height)
                    if ($ratio -lt 0.75) {
                        $ratio = 0.75
                    }
                    $script:Form.Scale((New-Object System.Drawing.SizeF($ratio, $ratio)))
                    Scale-ControlFonts -Control $script:Form -Factor $ratio
                    $script:Form.Location = New-Object System.Drawing.Point(20, 20)
                }
            } catch {
            }
        })

    $startRole = if ($env:LANLINK_START_ROLE -eq 'Client') { 'Client' } else { 'Host' }
    Set-Role -SelectedRole $startRole
    [void]$form.ShowDialog()
    if ($script:UiTimer) {
        $script:UiTimer.Stop()
        $script:UiTimer.Dispose()
    }
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

function Find-HostsSync {
    param(
        [string]$AdapterIp,
        [int]$PrefixLength = 24,
        [int]$TimeoutSec = 2,
        [string]$DirectHostIp = ''
    )
    $targets = New-Object System.Collections.ArrayList
    if ($DirectHostIp) {
        try {
            [void]$targets.Add([System.Net.IPAddress]::Parse($DirectHostIp))
        } catch {
        }
    }
    [void]$targets.Add([System.Net.IPAddress]::Broadcast)
    if ($AdapterIp) {
        try {
            $ip = [System.Net.IPAddress]::Parse($AdapterIp)
            $ipBytes = $ip.GetAddressBytes()
            $maskBytes = New-Object byte[] 4
            for ($i = 0; $i -lt $PrefixLength; $i++) {
                $idx = [math]::Floor($i / 8)
                $maskBytes[$idx] = $maskBytes[$idx] -bor (1 -shl (7 - ($i % 8)))
            }
            $bcBytes = New-Object byte[] 4
            for ($i = 0; $i -lt 4; $i++) {
                $bcBytes[$i] = $ipBytes[$i] -bor (255 - $maskBytes[$i])
            }
            $subnetBroadcast = [System.Net.IPAddress]::new($bcBytes)
            if (-not (@($targets | Where-Object { $_.Equals($subnetBroadcast) }).Count -gt 0)) {
                [void]$targets.Add($subnetBroadcast)
            }
        } catch {
        }
    }
    $udp = New-Object System.Net.Sockets.UdpClient
    $udp.EnableBroadcast = $true
    try {
        if ($AdapterIp) {
            $udp.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($AdapterIp), 0)))
        }
    } catch {
        try {
            $udp.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)))
        } catch {
        }
    }
    $udp.Client.ReceiveTimeout = 300
    $nonce = [guid]::NewGuid().ToString('N')
    $payload = @{ magic = 'LANLINK'; v = 1; type = 'discover'; nonce = $nonce; client = $env:COMPUTERNAME } | ConvertTo-Json -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    for ($round = 0; $round -lt 3; $round++) {
        foreach ($target in $targets) {
            try {
                $udp.Send($bytes, $bytes.Length, (New-Object System.Net.IPEndPoint($target, $script:ListenPort))) | Out-Null
            } catch {
            }
        }
        Start-Sleep -Milliseconds 150
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $seen = @{}
    while ((Get-Date) -lt $deadline) {
        $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        try {
            $data = $udp.Receive([ref]$remote)
        } catch {
            continue
        }
        try {
            $msg = [System.Text.Encoding]::UTF8.GetString($data) | ConvertFrom-Json
            if ($msg.magic -eq 'LANLINK' -and $msg.type -eq 'offer' -and $msg.ip) {
                $seen[[string]$msg.ip] = $msg
            }
        } catch {
        }
    }
    $udp.Close()
    return @($seen.Values)
}

function Request-GrantSync {
    param(
        [string]$HostIp,
        [string]$BindIp
    )
    $udp = New-Object System.Net.Sockets.UdpClient
    try {
        if ($BindIp) {
            $udp.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($BindIp), 0)))
        }
    } catch {
    }
    $udp.Client.ReceiveTimeout = 300
    $nonce = [guid]::NewGuid().ToString('N')
    $payload = @{
        magic    = 'LANLINK'
        v        = 1
        type     = 'request'
        nonce    = $nonce
        clientId = (Get-ClientId)
        client   = $ClientName
    } | ConvertTo-Json -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $udp.Send($bytes, $bytes.Length, (New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($HostIp), $script:ListenPort))) | Out-Null
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        try {
            $data = $udp.Receive([ref]$remote)
        } catch {
            continue
        }
        try {
            $msg = [System.Text.Encoding]::UTF8.GetString($data) | ConvertFrom-Json
        } catch {
            continue
        }
        if ($msg.magic -eq 'LANLINK' -and $msg.nonce -eq $nonce) {
            if ($msg.type -eq 'grant') {
                $udp.Close()
                return $msg
            }
            if ($msg.type -eq 'deny') {
                $udp.Close()
                throw "主机拒绝连接：$($msg.reason)"
            }
        }
    }
    $udp.Close()
    throw '等待主机确认超时'
}

function Run-Cli {
    switch ($Role) {
        'Status' {
            Ensure-Helper
            $state = Invoke-Helper -Command 'getState' -Payload @{}
            $network = @(Invoke-Helper -Command 'getNetworkInfo' -Payload @{})
            if ($Json) {
                [pscustomobject]@{ state = $state; network = $network } | ConvertTo-Json -Depth 12
            } else {
                Write-Host "LanLink v$($script:AppVersion)"
                if ($state) {
                    Write-Host "dirty: $($state.dirty)"
                    if ($state.share) {
                        Write-Host "share: $($state.share.name) -> $($state.share.path)"
                    }
                    if ($state.network) {
                        Write-Host "adapter: $($state.network.adapterName)  appliedIp: $($state.network.appliedIp)"
                    }
                } else {
                    Write-Host '没有保存的状态'
                }
                Write-Host '--- network ---'
                $network | Format-Table name, status, dhcpEnabled, @{ n = 'ipv4'; e = { (@($_.ipv4) | ForEach-Object { $_.ipAddress }) -join ',' } }, @{ n = 'gateway'; e = { @($_.gateways) -join ',' } } -AutoSize
            }
        }
        'Restore' {
            Ensure-Helper
            $result = Invoke-Helper -Command 'restoreAll' -Payload @{}
            if ($Json) {
                $result | ConvertTo-Json -Depth 8
            } else {
                Write-Host '还原完成'
                foreach ($warning in @($result.warnings)) {
                    Write-Host "警告: $warning" -ForegroundColor Yellow
                }
            }
            if ($result.stateKept) {
                exit 1
            }
        }
        'Host' {
            if (-not $AutoApprove) {
                throw 'CLI 主机模式会无人值守地允许连接，必须显式加 -AutoApprove 才能启动'
            }
            $adapter = $null
            if ($AdapterName) {
                $adapter = @(Get-LocalAdapters | Where-Object { $_.Name -eq $AdapterName }) | Select-Object -First 1
            }
            if (-not $adapter) {
                $adapter = Select-BestAdapter -SelectedMode $Mode
            }
            if (-not $adapter) {
                throw '未找到可用网卡'
            }
            $effectiveMode = Get-EffectiveModeForAdapter -Adapter $adapter -SelectedMode $Mode
            if ($effectiveMode -eq 'Direct' -and $adapter.Type -notmatch 'Ethernet') {
                throw '网线直连需要以太网卡'
            }
            $targetPath = if ($SharePath) { $SharePath } else { $script:DefaultSharePath }
            Ensure-Helper
            if ($effectiveMode -eq 'Direct') {
                $direct = Invoke-Helper -Command 'configureDirect' -Payload @{
                    adapterName = $adapter.Name
                    role        = 'Host'
                    subnets     = $script:DirectCandidates
                    dryRun      = [bool]$DryRun
                }
                $ip = $direct.ip
            } else {
                $info = @(Invoke-Helper -Command 'getNetworkInfo' -Payload @{})
                $adapterInfo = @($info | Where-Object { $_.name -eq $adapter.Name }) | Select-Object -First 1
                $addresses = @()
                if ($adapterInfo) {
                    $addresses = @($adapterInfo.ipv4 | Where-Object { $_.ipAddress })
                }
                $validAddresses = @($addresses | Where-Object { $_.ipAddress -notlike '169.254.*' })
                if ($validAddresses.Count -gt 0) {
                    $ip = [string]$validAddresses[0].ipAddress
                } elseif ($addresses.Count -gt 0) {
                    $ip = [string]$addresses[0].ipAddress
                } else {
                    $ip = $null
                }
                if (-not $ip) {
                    throw '网卡没有 IPv4 地址'
                }
                if ($ip -like '169.254.*') {
                    throw '网卡只有 169.254 自动地址，请检查 DHCP 或改用 -Mode Direct'
                }
            }
            $share = Invoke-Helper -Command 'ensureShare' -Payload @{
                path        = $targetPath
                shareName   = 'LanLink'
                readOnly    = [bool]$ReadOnly
                adapterName = $adapter.Name
                dryRun      = [bool]$DryRun
            }
            if ($DryRun) {
                Write-Host "[DryRun] \\$ip\$($share.shareName) -> $($share.path)"
                return
            }
            $script:ShareInfo = @{
                ip       = [string]$share.ip
                share    = [string]$share.shareName
                user     = [string]$share.user
                pass     = [string]$share.password
                path     = [string]$share.path
                readOnly = [bool]$share.readOnly
                mode     = $effectiveMode
            }
            $script:ConnectedClients = @{}
            Start-HostDiscovery
            Write-Host ''
            Write-Host "共享已启动: \\$($share.ip)\$($share.shareName)" -ForegroundColor Green
            Write-Host "账户: $($share.user)"
            Write-Host "本机 IP: $($share.ip)"
            Write-Host 'CLI 模式已自动允许连接。按 Ctrl+C 停止并还原。'
            try {
                while ($true) {
                    $item = $null
                    while ($script:HostInbox.TryDequeue([ref]$item)) {
                        if ($item.kind -eq 'request') {
                            Send-HostGrant -Item $item
                        } elseif ($item.kind -eq 'error') {
                            Write-Host "发现服务错误: $($item.error)" -ForegroundColor Red
                        }
                    }
                    Start-Sleep -Milliseconds 200
                }
            } finally {
                Stop-HostDiscovery
                try {
                    Invoke-Helper -Command 'restoreAll' -Payload @{} | Out-Null
                    Write-Host '已停止并还原'
                } catch {
                    Write-Host "还原失败: $($_.Exception.Message)" -ForegroundColor Red
                }
                Stop-Helper
            }
        }
        'Client' {
            $adapter = $null
            if ($AdapterName) {
                $adapter = @(Get-LocalAdapters | Where-Object { $_.Name -eq $AdapterName }) | Select-Object -First 1
            }
            if (-not $adapter) {
                $adapter = Select-BestAdapter -SelectedMode $Mode
            }
            if (-not $adapter) {
                throw '未找到可用网卡'
            }
            $effectiveMode = Get-EffectiveModeForAdapter -Adapter $adapter -SelectedMode $Mode
            $targetHost = $HostAddress
            $bindIp = $null
            if (-not $targetHost) {
                if ($effectiveMode -eq 'Direct') {
                    Ensure-Helper
                    for ($i = 0; $i -lt $script:DirectCandidates.Count; $i++) {
                        $direct = Invoke-Helper -Command 'configureDirect' -Payload @{
                            adapterName = $adapter.Name
                            role        = 'Client'
                            subnets     = @($script:DirectCandidates[$i])
                            dryRun      = [bool]$DryRun
                        }
                        $bindIp = $direct.ip
                        Write-Host "搜索 $($script:DirectCandidates[$i]).0/24 ..."
                        $hosts = @(Find-HostsSync -AdapterIp $bindIp -PrefixLength 24 -TimeoutSec 2 -DirectHostIp "$($script:DirectCandidates[$i]).1")
                        if ($hosts.Count -gt 0) {
                            $targetHost = [string]$hosts[0].ip
                            break
                        }
                    }
                    if (-not $targetHost) {
                        throw '未发现主机。请确认主机已启动共享，或使用 -HostAddress 指定 IP。'
                    }
                } else {
                    if (@($adapter.IPv4).Count -eq 0) {
                        throw '网卡没有 IPv4 地址'
                    }
                    Write-Host "在局域网中搜索主机..."
                    $hosts = @(Find-HostsSync -AdapterIp $adapter.IPv4[0].ip -PrefixLength $adapter.IPv4[0].prefix -TimeoutSec 2)
                    if ($hosts.Count -eq 0) {
                        throw '未发现主机。请使用 -HostAddress 指定主机 IP。'
                    }
                    $targetHost = [string]$hosts[0].ip
                }
            }
            Write-Host "请求连接 $targetHost ..."
            $grant = Request-GrantSync -HostIp $targetHost -BindIp $bindIp
            $result = Connect-LanLinkShare -Grant $grant
            Write-Host "已连接: $($result.remote)  ->  $($result.drive):" -ForegroundColor Green
        }
        default {
            throw "未知角色: $Role"
        }
    }
}

# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------

function Invoke-AppSelfTest {
    $failures = New-Object System.Collections.ArrayList

    try {
        $id1 = Get-ClientId
        $id2 = Get-ClientId
        if (-not $id1 -or $id1 -ne $id2) {
            [void]$failures.Add('客户端 ID 读写不一致')
        }
    } catch {
        [void]$failures.Add("客户端 ID 测试失败：$($_.Exception.Message)")
    }

    try {
        $adapters = @(Get-LocalAdapters)
        if ($null -eq $adapters) {
            [void]$failures.Add('网卡枚举返回 null')
        }
    } catch {
        [void]$failures.Add("网卡枚举失败：$($_.Exception.Message)")
    }

    try {
        $driveLetter = Get-FreeDriveLetter
        if ($driveLetter -notmatch '^[A-Z]$') {
            [void]$failures.Add("盘符选择异常：$driveLetter")
        }
    } catch {
        [void]$failures.Add("盘符选择失败：$($_.Exception.Message)")
    }

    try {
        $json = @{ a = 1; b = @(1, 2, 3) } | ConvertTo-Json -Depth 5 -Compress
        $back = $json | ConvertFrom-Json
        if ($back.a -ne 1 -or @($back.b).Count -ne 3) {
            [void]$failures.Add('JSON 往返失败')
        }
    } catch {
        [void]$failures.Add("JSON 测试失败：$($_.Exception.Message)")
    }

    $originalAllowedPath = $script:AllowedPath
    $originalDefaultRemember = $script:DefaultRememberClients
    $historyTestPath = Join-Path ([System.IO.Path]::GetTempPath()) ("lanlink-history-test-{0}.json" -f [guid]::NewGuid().ToString('N'))
    $script:AllowedPath = $historyTestPath
    try {
        $oldJson = '[{"id":"old-client","name":"OLD-PC","lastSeen":"2026-01-01T00:00:00"}]'
        [System.IO.File]::WriteAllText($historyTestPath, $oldJson, (New-Object System.Text.UTF8Encoding($false)))
        $migrated = @(Get-ClientHistory)
        $oldRecord = @($migrated | Where-Object { $_.id -eq 'old-client' }) | Select-Object -First 1
        if (-not $oldRecord -or -not [bool]$oldRecord.remembered -or [bool]$oldRecord.rememberedManual -or [int]$oldRecord.connectCount -ne 1) {
            [void]$failures.Add('旧历史记录迁移失败')
        }

        $script:DefaultRememberClients = $false
        $null = Update-ClientHistory -Id 'new-client' -Name 'NEW-PC' -Ip '192.168.77.2'
        $null = Update-ClientHistory -Id 'new-client' -Name 'NEW-PC' -Ip '192.168.77.2'
        $newRecord = @(Get-ClientHistory | Where-Object { $_.id -eq 'new-client' }) | Select-Object -First 1
        if (-not $newRecord -or [int]$newRecord.connectCount -ne 2 -or [bool]$newRecord.remembered -or [bool]$newRecord.rememberedManual) {
            [void]$failures.Add('历史记录新增/计数失败')
        }

        $script:DefaultRememberClients = $true
        $null = Update-ClientHistory -Id 'default-on-client' -Name 'DEFAULT-ON' -Ip '192.168.77.4'
        $defaultOnRecord = @(Get-ClientHistory | Where-Object { $_.id -eq 'default-on-client' }) | Select-Object -First 1
        if (-not $defaultOnRecord -or -not [bool]$defaultOnRecord.remembered -or [bool]$defaultOnRecord.rememberedManual) {
            [void]$failures.Add('默认开关对新记录未生效')
        }

        if (-not (Apply-ClientDefaultRemember -Id 'new-client')) {
            [void]$failures.Add('默认记住未应用')
        }
        $newRecord = @(Get-ClientHistory | Where-Object { $_.id -eq 'new-client' }) | Select-Object -First 1
        if (-not $newRecord -or -not [bool]$newRecord.remembered -or [bool]$newRecord.rememberedManual) {
            [void]$failures.Add('默认记住结果错误')
        }

        $null = Set-ClientRemembered -Id 'new-client' -Remembered $false -Manual
        if (Apply-ClientDefaultRemember -Id 'new-client') {
            [void]$failures.Add('手动取消后仍被默认记住覆盖')
        }
        $newRecord = @(Get-ClientHistory | Where-Object { $_.id -eq 'new-client' }) | Select-Object -First 1
        if (-not $newRecord -or [bool]$newRecord.remembered -or -not [bool]$newRecord.rememberedManual) {
            [void]$failures.Add('手动记住标记错误')
        }

        $null = Remove-ClientHistory -Id 'new-client'
        if (@(Get-ClientHistory | Where-Object { $_.id -eq 'new-client' }).Count -ne 0) {
            [void]$failures.Add('历史记录删除失败')
        }
    } catch {
        [void]$failures.Add("历史记录测试失败：$($_.Exception.Message)")
    } finally {
        $script:AllowedPath = $originalAllowedPath
        $script:DefaultRememberClients = $originalDefaultRemember
        if (Test-Path -LiteralPath $historyTestPath) {
            Remove-Item -LiteralPath $historyTestPath -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not (Test-Path -LiteralPath $script:HelperPath)) {
        [void]$failures.Add("找不到提权组件：$($script:HelperPath)")
    }

    if ($failures.Count -gt 0) {
        $failures | ForEach-Object { Write-Host "FAIL: $_" -ForegroundColor Red }
        exit 1
    }
    Write-Host "SELFTEST OK (adapters=$(@($adapters).Count), drive=$driveLetter, admin=$(Test-Admin))"
}

if ($SelfTest) {
    Invoke-AppSelfTest
    return
}

try {
    if ($NoGui -or $Role -ne 'Gui') {
        Run-Cli
    } else {
        Initialize-Ui
    }
} catch {
    Write-AppLog "未处理异常: $($_.Exception.Message) $($_.ScriptStackTrace)" 'ERROR'
    if ($script:Form) {
        Show-UiError $_.Exception.Message
    } else {
        Write-Host "错误: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}
