# 双机快传 LanLink — 自检脚本
# 只做语法、自检和本地 IPC 测试，不修改网卡/共享/防火墙。

[CmdletBinding()]
param(
    [switch]$SkipIpc
)

$ErrorActionPreference = 'Stop'
$script:Failures = 0
$script:Root = Split-Path -Parent $PSScriptRoot
$script:Main = Join-Path $script:Root 'LanLink.ps1'
$script:Helper = Join-Path $script:Root 'LanLink.Helper.ps1'
# 可在只读环境中用环境变量把测试数据放到临时目录，默认放在仓库根目录（已被 .gitignore 忽略）。
$script:DataDir = if ($env:LANLINK_TEST_DATA_DIR) { $env:LANLINK_TEST_DATA_DIR } else { Join-Path $script:Root '.testdata' }
$script:StateDir = if ($env:LANLINK_TEST_STATE_DIR) { $env:LANLINK_TEST_STATE_DIR } else { Join-Path $script:Root '.teststate' }
$script:Token = [guid]::NewGuid().ToString('N')
$script:Port = Get-Random -Minimum 30000 -Maximum 50000

function Write-Pass {
    param([string]$Name)
    Write-Host "PASS  $Name" -ForegroundColor Green
}

function Write-Fail {
    param([string]$Name, [string]$Detail = '')
    $script:Failures++
    Write-Host "FAIL  $Name  $Detail" -ForegroundColor Red
}

function Test-ScriptSyntax {
    param([string]$Path)
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        $message = ($errors | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; '
        Write-Fail "语法 $(Split-Path $Path -Leaf)" $message
    } else {
        Write-Pass "语法 $(Split-Path $Path -Leaf)"
    }
}

function Invoke-Checked {
    param(
        [string]$Name,
        [string]$FilePath,
        [string[]]$Arguments
    )
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FilePath @Arguments 2>&1
    $code = $LASTEXITCODE
    if ($code -eq 0) {
        Write-Pass $Name
    } else {
        Write-Fail $Name ("exit=$code output=" + ($output -join ' | '))
    }
    return $output
}

function Send-HelperRequest {
    param(
        [string]$Command,
        [hashtable]$Arguments = @{},
        [string]$TokenOverride = ''
    )
    $token = if ($TokenOverride) { $TokenOverride } else { $script:Token }
    $request = @{
        token = $token
        cmd   = $Command
        args  = $Arguments
    } | ConvertTo-Json -Depth 10 -Compress
    $script:Writer.WriteLine($request)
    $script:Writer.Flush()
    $line = $script:Reader.ReadLine()
    if ([string]::IsNullOrWhiteSpace($line)) {
        throw 'Helper 无响应'
    }
    return ($line | ConvertFrom-Json)
}

# ---------------------------------------------------------------------------
# 准备
# ---------------------------------------------------------------------------

foreach ($dir in @($script:DataDir, $script:StateDir)) {
    if (Test-Path -LiteralPath $dir) {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}
$env:LANLINK_DATA_DIR = $script:DataDir
$env:LANLINK_STATE_DIR = $script:StateDir

Write-Host '=== LanLink 自检 ===' -ForegroundColor Cyan
Test-ScriptSyntax -Path $script:Main
Test-ScriptSyntax -Path $script:Helper

Invoke-Checked -Name 'Helper 自检' -FilePath $script:Helper -Arguments @('-SelfTest') | Out-Null
Invoke-Checked -Name '主程序自检' -FilePath $script:Main -Arguments @('-SelfTest') | Out-Null
Invoke-Checked -Name '发现协议测试' -FilePath (Join-Path $PSScriptRoot 'Test-Discovery.ps1') -Arguments @() | Out-Null

# ---------------------------------------------------------------------------
# Helper IPC
# ---------------------------------------------------------------------------

if (-not $SkipIpc) {
    $helperProcess = $null
    try {
        $helperProcess = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:Helper, '-DebugNonAdmin', '-Port', $script:Port, '-Token', $script:Token, '-ParentPid', $PID) `
            -PassThru -WindowStyle Hidden

        $client = $null
        $deadline = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $deadline) {
            try {
                $client = New-Object System.Net.Sockets.TcpClient
                $client.Connect('127.0.0.1', $script:Port)
                break
            } catch {
                if ($client) {
                    $client.Close()
                    $client = $null
                }
                Start-Sleep -Milliseconds 200
            }
        }
        if (-not $client -or -not $client.Connected) {
            throw '无法连接 Helper'
        }

        $stream = $client.GetStream()
        $stream.ReadTimeout = 15000
        $script:Reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
        $script:Writer = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding($false)))
        $script:Writer.AutoFlush = $true

        $ping = Send-HelperRequest -Command 'ping'
        if ($ping.ok -and $ping.data.pong -eq $true) {
            Write-Pass 'Helper IPC ping'
        } else {
            Write-Fail 'Helper IPC ping' ($ping | ConvertTo-Json -Compress)
        }

        $state = Send-HelperRequest -Command 'getState'
        if ($state.ok) {
            Write-Pass 'Helper getState'
        } else {
            Write-Fail 'Helper getState' ($state | ConvertTo-Json -Compress)
        }

        $sessions = Send-HelperRequest -Command 'getSessions'
        if ($sessions.ok -and $null -ne $sessions.data.supported) {
            Write-Pass 'Helper getSessions'
        } else {
            Write-Fail 'Helper getSessions' ($sessions | ConvertTo-Json -Compress)
        }

        $dry = Send-HelperRequest -Command 'ensureShare' -Arguments @{
            path      = (Join-Path $script:Root '.testshare')
            shareName = 'LanLink'
            readOnly  = $false
            dryRun    = $true
        }
        if ($dry.ok -and $dry.data.dryRun -eq $true) {
            Write-Pass 'Helper ensureShare DryRun'
        } else {
            Write-Fail 'Helper ensureShare DryRun' ($dry | ConvertTo-Json -Compress)
        }

        $tcp = Send-HelperRequest -Command 'testTcp' -Arguments @{
            address   = '127.0.0.1'
            port      = 445
            timeoutMs = 800
        }
        if ($tcp.ok -and $null -ne $tcp.data.open) {
            Write-Pass 'Helper testTcp'
        } else {
            Write-Fail 'Helper testTcp' ($tcp | ConvertTo-Json -Compress)
        }

        $bad = Send-HelperRequest -Command 'ping' -TokenOverride 'wrong-token'
        if ($bad.ok -eq $false) {
            Write-Pass 'Helper 拒绝错误 Token'
        } else {
            Write-Fail 'Helper 拒绝错误 Token' ($bad | ConvertTo-Json -Compress)
        }

        $null = Send-HelperRequest -Command 'exit'
        $client.Close()
    } catch {
        Write-Fail 'Helper IPC' $_.Exception.Message
    } finally {
        if ($helperProcess) {
            Start-Sleep -Milliseconds 300
            $helperProcess.Refresh()
            if (-not $helperProcess.HasExited) {
                Stop-Process -Id $helperProcess.Id -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 结果
# ---------------------------------------------------------------------------

Write-Host ''
if ($script:Failures -gt 0) {
    Write-Host "自检失败：$($script:Failures) 项" -ForegroundColor Red
    exit 1
}
Write-Host '全部自检通过' -ForegroundColor Green
exit 0
