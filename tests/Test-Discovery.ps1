# 发现协议回归测试：在 127.0.0.1 上跑真实的 HostListenerScript / ClientDiscoveryScript。
# 不修改系统网络，只验证 UDP 发现包和 offer 解析。

[CmdletBinding()]
param(
    [string]$Address = '127.0.0.1',
    [int]$PrefixLength = 8
)

$ErrorActionPreference = 'Stop'
$script:Failures = 0

function Write-Pass([string]$Message) {
    Write-Host "PASS  $Message" -ForegroundColor Green
}

function Write-Fail([string]$Message, [string]$Detail = '') {
    $script:Failures++
    Write-Host "FAIL  $Message  $Detail" -ForegroundColor Red
}

$main = Join-Path (Split-Path -Parent $PSScriptRoot) 'LanLink.ps1'
if (-not (Test-Path -LiteralPath $main)) {
    throw "找不到 $main"
}

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($main, [ref]$tokens, [ref]$errors)
$assignments = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)
$hostScript = $null
$clientScript = $null
foreach ($assignment in $assignments) {
    $left = $assignment.Left.Extent.Text
    $value = $null
    if ($assignment.Right -is [System.Management.Automation.Language.CommandExpressionAst]) {
        $expression = $assignment.Right.Expression
        if ($expression -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            $value = $expression.Value
        }
    }
    if ($left -match 'HostListenerScript') {
        $hostScript = $value
    }
    if ($left -match 'ClientDiscoveryScript') {
        $clientScript = $value
    }
}
if (-not $hostScript -or -not $clientScript) {
    throw '未能从主程序提取发现脚本'
}
Write-Host "已提取：host=$($hostScript.Length) 字节，client=$($clientScript.Length) 字节"

$port = Get-Random -Minimum 40000 -Maximum 50000
$inbox = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$outbox = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$events = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$hostCts = New-Object System.Threading.CancellationTokenSource
$clientCts = New-Object System.Threading.CancellationTokenSource
$hostInfo = @{ name = 'TESTHOST'; ip = $Address; share = 'LanLink'; mode = 'Direct'; port = $port }

$hostRs = [runspacefactory]::CreateRunspace()
$hostRs.Open()
$hostPs = [powershell]::Create()
$hostPs.Runspace = $hostRs
[void]$hostPs.AddScript($hostScript).AddArgument($port).AddArgument($inbox).AddArgument($outbox).AddArgument($hostCts).AddArgument($hostInfo)
$hostHandle = $hostPs.BeginInvoke()
Start-Sleep -Milliseconds 500

$clientRs = [runspacefactory]::CreateRunspace()
$clientRs.Open()
$clientPs = [powershell]::Create()
$clientPs.Runspace = $clientRs
[void]$clientPs.AddScript($clientScript).
    AddArgument($port).
    AddArgument($events).
    AddArgument($clientCts).
    AddArgument($Address).
    AddArgument($PrefixLength).
    AddArgument('test-nonce').
    AddArgument($Address)
$clientHandle = $clientPs.BeginInvoke()

$deadline = (Get-Date).AddSeconds(8)
$hosts = @()
$hostReady = $false
while ((Get-Date) -lt $deadline -and $hosts.Count -eq 0) {
    $event = $null
    while ($events.TryDequeue([ref]$event)) {
        if ($event.kind -eq 'debug') {
            Write-Host "  client: $($event.message)"
        } elseif ($event.kind -eq 'hosts') {
            $hosts = @($event.hosts)
        } elseif ($event.kind -eq 'error') {
            Write-Fail '客户端发现' ([string]$event.error)
        }
    }
    $hostEvent = $null
    while ($inbox.TryDequeue([ref]$hostEvent)) {
        if ($hostEvent.kind -eq 'ready') {
            $hostReady = $true
            Write-Host "  host: UDP 已就绪，端口 $($hostEvent.port)"
        } elseif ($hostEvent.kind -eq 'debug') {
            Write-Host "  host: $($hostEvent.message)"
        } elseif ($hostEvent.kind -eq 'error') {
            Write-Fail '主机监听' ([string]$hostEvent.error)
        }
    }
    Start-Sleep -Milliseconds 150
}

$disconnectSeen = $false
try {
    $disconnectUdp = New-Object System.Net.Sockets.UdpClient
    $disconnectPayload = @{
        magic    = 'LANLINK'
        v        = 1
        type     = 'disconnect'
        clientId = 'test-client'
        client   = 'TESTCLIENT'
    } | ConvertTo-Json -Compress
    $disconnectBytes = [System.Text.Encoding]::UTF8.GetBytes($disconnectPayload)
    $disconnectUdp.Send($disconnectBytes, $disconnectBytes.Length, (New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($Address), $port))) | Out-Null
    $disconnectUdp.Close()
    Start-Sleep -Milliseconds 300
    $hostEvent = $null
    while ($inbox.TryDequeue([ref]$hostEvent)) {
        if ($hostEvent.kind -eq 'disconnect') {
            $disconnectSeen = $true
        }
    }
} catch {
    Write-Fail '主机断开通知' $_.Exception.Message
}

try {
    $hostCts.Cancel()
    $clientCts.Cancel()
    try { $hostPs.Stop() } catch { }
    try { $clientPs.Stop() } catch { }
    try { $hostRs.Close() } catch { }
    try { $clientRs.Close() } catch { }
} catch {
}

if ($hostReady) {
    Write-Pass '主机 UDP 监听就绪'
} else {
    Write-Fail '主机 UDP 监听就绪' '未收到 ready 事件'
}

if ($disconnectSeen) {
    Write-Pass '主机收到断开通知'
} else {
    Write-Fail '主机收到断开通知' '未收到 disconnect 事件'
}

if ($hosts.Count -gt 0 -and [string]$hosts[0].ip -eq $Address) {
    Write-Pass '客户端通过单播发现主机'
    Write-Host "  offer: host=$($hosts[0].host) ip=$($hosts[0].ip) share=$($hosts[0].share)"
} else {
    Write-Fail '客户端通过单播发现主机' ("收到 $($hosts.Count) 个响应")
}

Write-Host ''
if ($script:Failures -gt 0) {
    Write-Host "发现协议测试失败：$($script:Failures) 项" -ForegroundColor Red
    exit 1
}
Write-Host '发现协议测试通过' -ForegroundColor Green
exit 0
