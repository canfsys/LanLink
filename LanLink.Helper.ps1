[CmdletBinding()]
param(
    [int]$Port = 0,
    [string]$Token = '',
    [int]$ParentPid = 0,
    [switch]$SelfTest,
    [switch]$DebugNonAdmin
)

$ErrorActionPreference = 'Stop'
$script:AppName = 'LanLink'
$script:ProgramDataDir = if ($env:LANLINK_STATE_DIR) { $env:LANLINK_STATE_DIR } else { Join-Path $env:ProgramData 'LanLink' }
$script:StatePath = Join-Path $script:ProgramDataDir 'state.json'
$script:LogDir = Join-Path $script:ProgramDataDir 'logs'
$script:HelperLog = Join-Path $script:LogDir ("helper-{0:yyyyMMdd}.log" -f (Get-Date))
$script:FirewallGroup = 'LanLink'
$script:AccountName = 'LanLink'
$script:AccountDescription = 'LanLink temporary file sharing account'
$script:DirectSubnets = @('192.168.77', '192.168.78', '192.168.79')

function Write-HelperLog {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )
    try {
        if (-not (Test-Path -LiteralPath $script:LogDir)) {
            New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
        }
        $line = '[{0:yyyy-MM-dd HH:mm:ss}] [{1}] {2}' -f (Get-Date), $Level, $Message
        Add-Content -LiteralPath $script:HelperLog -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {
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

function Read-State {
    if (-not (Test-Path -LiteralPath $script:StatePath)) {
        return $null
    }
    try {
        $raw = [System.IO.File]::ReadAllText($script:StatePath, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $null
        }
        return ($raw | ConvertFrom-Json)
    } catch {
        Write-HelperLog "读取状态失败: $($_.Exception.Message)" 'WARN'
        return $null
    }
}

function Write-State {
    param($Value)
    if (-not (Test-Path -LiteralPath $script:ProgramDataDir)) {
        New-Item -ItemType Directory -Path $script:ProgramDataDir -Force | Out-Null
    }
    $json = $Value | ConvertTo-Json -Depth 12
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($script:StatePath, $json, $utf8)
}

function Remove-State {
    if (Test-Path -LiteralPath $script:StatePath) {
        Remove-Item -LiteralPath $script:StatePath -Force -ErrorAction SilentlyContinue
    }
}

function New-RandomPassword {
    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower = 'abcdefghijkmnopqrstuvwxyz'
    $digit = '23456789'
    $symbol = '!@#$%^&*'
    $all = $upper + $lower + $digit + $symbol
    $chars = New-Object System.Collections.ArrayList
    [void]$chars.Add($upper[(Get-Random -Maximum $upper.Length)])
    [void]$chars.Add($lower[(Get-Random -Maximum $lower.Length)])
    [void]$chars.Add($digit[(Get-Random -Maximum $digit.Length)])
    [void]$chars.Add($symbol[(Get-Random -Maximum $symbol.Length)])
    for ($i = 0; $i -lt 20; $i++) {
        [void]$chars.Add($all[(Get-Random -Maximum $all.Length)])
    }
    $shuffled = @($chars | Sort-Object { Get-Random })
    return (-join $shuffled)
}

function Get-Adapter {
    param(
        [string]$Name,
        [int]$Index = 0
    )
    if ($Name) {
        return (Get-NetAdapter -Name $Name -ErrorAction Stop)
    }
    if ($Index -gt 0) {
        return (Get-NetAdapter -InterfaceIndex $Index -ErrorAction Stop)
    }
    throw '未指定网卡'
}

function Get-OriginalNetwork {
    param($Adapter)
    $index = $Adapter.ifIndex
    $ipIf = $null
    try {
        $ipIf = Get-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction Stop
    } catch {
    }

    $ips = @()
    try {
        $ips = @(Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction Stop |
            ForEach-Object {
                [pscustomobject]@{
                    ip     = [string]$_.IPAddress
                    prefix = [int]$_.PrefixLength
                }
            })
    } catch {
    }

    $gateways = @()
    try {
        $gateways = @(Get-NetRoute -InterfaceIndex $index -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' } |
            ForEach-Object { [string]$_.NextHop })
    } catch {
    }

    $dns = @()
    try {
        $dnsInfo = Get-DnsClientServerAddress -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction Stop
        if ($dnsInfo) {
            $dns = @($dnsInfo.ServerAddresses | Where-Object { $_ })
        }
    } catch {
    }

    $profile = $null
    try {
        $profile = Get-NetConnectionProfile -InterfaceIndex $index -ErrorAction Stop
    } catch {
    }

    return [pscustomobject]@{
        adapterName     = [string]$Adapter.Name
        interfaceIndex  = [int]$index
        description     = [string]$Adapter.InterfaceDescription
        mediaType       = [string]$Adapter.MediaType
        dhcpEnabled     = $(if ($ipIf) { [string]$ipIf.Dhcp -eq 'Enabled' } else { $false })
        ipAddresses     = $ips
        gateways        = $gateways
        dnsServers      = $dns
        profileName     = $(if ($profile) { [string]$profile.Name } else { '' })
        networkCategory = $(if ($profile) { [string]$profile.NetworkCategory } else { '' })
        appliedIp       = $null
        appliedPrefix   = 0
        mode            = $null
    }
}

function Test-SubnetConflict {
    param(
        [string]$Prefix,
        [int]$IgnoreIndex
    )
    $like = "$Prefix.*"
    try {
        $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceIndex -ne $IgnoreIndex -and $_.IPAddress -like $like })
        if ($ips.Count -gt 0) {
            return $true
        }
    } catch {
    }
    try {
        $routes = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceIndex -ne $IgnoreIndex -and $_.DestinationPrefix -like "$Prefix.0/24" })
        if ($routes.Count -gt 0) {
            return $true
        }
    } catch {
    }
    return $false
}

function Set-StaticAddress {
    param(
        $Adapter,
        [string]$IpAddress,
        [int]$PrefixLength = 24
    )
    $index = [int]$Adapter.ifIndex
    Write-HelperLog "设置静态地址 $IpAddress/$PrefixLength 到 $($Adapter.Name)"

    Set-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -Dhcp Disabled -ErrorAction Stop

    try {
        $existing = @(Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction SilentlyContinue)
        foreach ($item in $existing) {
            Remove-NetIPAddress -IPAddress $item.IPAddress -InterfaceIndex $index -Confirm:$false -ErrorAction SilentlyContinue
        }
    } catch {
    }

    New-NetIPAddress -InterfaceIndex $index -IPAddress $IpAddress -PrefixLength $PrefixLength -ErrorAction Stop | Out-Null
    try {
        Set-DnsClientServerAddress -InterfaceIndex $index -ResetServerAddresses -ErrorAction SilentlyContinue
    } catch {
    }

    # 新配置的 IPv4 会先处于 Tentative（DAD 检测中），此时 Get-NetIPAddress 能查到，
    # 但 UdpClient.Bind 会报“请求的地址无效”。必须等到 Preferred 再返回。
    $found = $null
    $duplicate = $false
    $lastState = ''
    for ($i = 0; $i -lt 40; $i++) {
        $candidate = Get-NetIPAddress -InterfaceIndex $index -IPAddress $IpAddress -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($candidate) {
            $lastState = [string]$candidate.AddressState
            if ($lastState -eq 'Duplicate') {
                $duplicate = $true
                break
            }
            if (-not $lastState -or $lastState -eq 'Preferred') {
                $found = $candidate
                break
            }
        }
        Start-Sleep -Milliseconds 250
    }
    if ($duplicate) {
        throw "静态 IP $IpAddress 与网络中的其他设备冲突，请更换直连网段"
    }
    if (-not $found) {
        throw "静态 IP $IpAddress 未进入可用状态（当前 $lastState），可能仍在检测地址冲突"
    }
    Write-HelperLog "静态 IP $IpAddress 已生效（$lastState）"

    try {
        Set-NetConnectionProfile -InterfaceIndex $index -NetworkCategory Private -ErrorAction Stop
        Write-HelperLog "网络位置已设为专用"
    } catch {
        Write-HelperLog "网络位置设置失败（可忽略，防火墙规则覆盖所有配置文件）: $($_.Exception.Message)" 'WARN'
    }
}

function Restore-NetworkConfig {
    param($State)
    if (-not $State -or -not $State.network) {
        return
    }
    $net = $State.network
    $adapter = Get-NetAdapter -Name $net.adapterName -ErrorAction SilentlyContinue
    if (-not $adapter) {
        throw "找不到原网卡 $($net.adapterName)，无法还原 IP 配置"
    }
    $index = [int]$adapter.ifIndex
    Write-HelperLog "还原网卡 $($net.adapterName)（原 DHCP=$($net.dhcpEnabled)）"

    if ($net.appliedIp) {
        Remove-NetIPAddress -IPAddress $net.appliedIp -InterfaceIndex $index -Confirm:$false -ErrorAction SilentlyContinue
    }

    $originalIps = @($net.ipAddresses | Where-Object { $_ -and $_.ip })
    $gateways = @($net.gateways | Where-Object { $_ })
    $dns = @($net.dnsServers | Where-Object { $_ })
    if (-not [bool]$net.dhcpEnabled -and $originalIps.Count -eq 0) {
        throw '原始网络配置没有记录到可用 IP，无法自动还原，请手动配置'
    }

    if ([bool]$net.dhcpEnabled) {
        Set-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -Dhcp Enabled -ErrorAction Stop
        try {
            Set-DnsClientServerAddress -InterfaceIndex $index -ResetServerAddresses -ErrorAction SilentlyContinue
        } catch {
        }
        try {
            Start-Process -FilePath 'ipconfig.exe' -ArgumentList '/renew' -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
        } catch {
        }
    } else {
        $first = $true
        foreach ($ipItem in $originalIps) {
            $gw = $null
            if ($first -and $gateways.Count -gt 0) {
                $gw = $gateways[0]
            }
            try {
                if ($gw) {
                    New-NetIPAddress -InterfaceIndex $index -IPAddress $ipItem.ip -PrefixLength ([int]$ipItem.prefix) -DefaultGateway $gw -ErrorAction Stop | Out-Null
                } else {
                    New-NetIPAddress -InterfaceIndex $index -IPAddress $ipItem.ip -PrefixLength ([int]$ipItem.prefix) -ErrorAction Stop | Out-Null
                }
            } catch {
                Write-HelperLog "恢复 IP $($ipItem.ip) 失败: $($_.Exception.Message)" 'WARN'
            }
            $first = $false
        }
        try {
            if ($dns.Count -gt 0) {
                Set-DnsClientServerAddress -InterfaceIndex $index -ServerAddresses $dns -ErrorAction Stop
            } else {
                Set-DnsClientServerAddress -InterfaceIndex $index -ResetServerAddresses -ErrorAction SilentlyContinue
            }
        } catch {
            Write-HelperLog "恢复 DNS 失败: $($_.Exception.Message)" 'WARN'
        }
    }

    $State.network.appliedIp = $null
    $State.network.appliedPrefix = 0
    $State.network.mode = $null
    Write-State $State
    Start-Sleep -Milliseconds 500
}

function Configure-DirectAddress {
    param($Payload)
    $adapterName = [string]$Payload.adapterName
    $role = [string]$Payload.role
    $subnets = @($Payload.subnets | Where-Object { $_ })
    if ($subnets.Count -eq 0) {
        $subnets = $script:DirectSubnets
    }
    if (-not $adapterName) {
        throw '未指定网卡'
    }
    $adapter = Get-Adapter -Name $adapterName
    if ([string]$adapter.MediaType -match '802\.11' -or [string]$adapter.InterfaceDescription -match 'Wireless|Wi-Fi|WLAN') {
        throw '网线直连需要选择以太网卡，不能使用无线网卡'
    }

    $state = Read-State
    if ($state -and $state.dirty -and $state.network -and [string]$state.network.adapterName -ne $adapterName) {
        Write-HelperLog "发现其他网卡的未还原配置，先还原 $($state.network.adapterName)"
        Restore-NetworkConfig -State $state
        $state = Read-State
    }
    if (-not $state -or -not $state.network -or [string]$state.network.adapterName -ne $adapterName) {
        $original = Get-OriginalNetwork -Adapter $adapter
        $state = [pscustomobject]@{
            version   = 1
            dirty     = $true
            createdAt = (Get-Date).ToString('o')
            network   = $original
            share     = $null
            firewall  = @()
        }
        Write-State $state
    }

    $state.dirty = $true
    foreach ($prefix in $subnets) {
        $prefix = ([string]$prefix).Trim().TrimEnd('.')
        if ($prefix -match '\.0$') {
            $prefix = $prefix.Substring(0, $prefix.Length - 2)
        }
        if ($prefix -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}$') {
            continue
        }
        $ip = if ($role -eq 'Host') { "$prefix.1" } else { "$prefix.2" }
        if (Test-SubnetConflict -Prefix $prefix -IgnoreIndex ([int]$adapter.ifIndex)) {
            Write-HelperLog "网段 $prefix.0/24 已被占用，尝试下一个"
            continue
        }
        if ([bool]$Payload.dryRun) {
            return [pscustomobject]@{ dryRun = $true; ip = $ip; prefixLength = 24; subnet = "$prefix.0/24"; adapter = $adapterName; role = $role }
        }
        try {
            Set-StaticAddress -Adapter $adapter -IpAddress $ip -PrefixLength 24
        } catch {
            Write-HelperLog "配置 $ip/24 失败：$($_.Exception.Message)" 'WARN'
            if ($_.Exception.Message -match '冲突|未进入可用状态|未能生效') {
                continue
            }
            throw
        }
        $state.network.appliedIp = $ip
        $state.network.appliedPrefix = 24
        $state.network.mode = 'Direct'
        Write-State $state
        return [pscustomobject]@{ dryRun = $false; ip = $ip; prefixLength = 24; subnet = "$prefix.0/24"; adapter = $adapterName; role = $role }
    }
    throw '没有可用的直连网段（192.168.77/78/79 均被占用）'
}

function Get-ShareIp {
    param([string]$AdapterName)
    $state = Read-State
    if ($state -and $state.network -and $state.network.appliedIp) {
        $live = Get-NetIPAddress -IPAddress $state.network.appliedIp -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if ($live) {
            return [string]$state.network.appliedIp
        }
    }
    if ($AdapterName) {
        $adapter = Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue
        if ($adapter) {
            $ip = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -notlike '169.254.*' } |
                Select-Object -First 1
            if (-not $ip) {
                $ip = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
            }
            if ($ip) {
                return [string]$ip.IPAddress
            }
        }
    }
    try {
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' } |
            Select-Object -First 1
        if ($route) {
            $ip = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -notlike '169.254.*' } |
                Select-Object -First 1
            if ($ip) {
                return [string]$ip.IPAddress
            }
        }
    } catch {
    }
    try {
        $dnsIp = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
            Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
            Select-Object -First 1
        if ($dnsIp) {
            return $dnsIp.ToString()
        }
    } catch {
    }
    throw '无法确定本机共享 IP 地址'
}

function Ensure-LocalAccount {
    param([string]$Name = $script:AccountName)
    $password = New-RandomPassword
    $secure = ConvertTo-SecureString -String $password -AsPlainText -Force
    $user = Get-LocalUser -Name $Name -ErrorAction SilentlyContinue
    if (-not $user) {
        New-LocalUser -Name $Name -Password $secure -PasswordNeverExpires -UserMayNotChangePassword -Description $script:AccountDescription -ErrorAction Stop | Out-Null
        Write-HelperLog "已创建本地账户 $Name"
    } else {
        Set-LocalUser -Name $Name -Password $secure -ErrorAction Stop
        Enable-LocalUser -Name $Name -ErrorAction SilentlyContinue
        Write-HelperLog "已重置本地账户 $Name 的密码"
    }

    try {
        $sid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')
        $group = Get-LocalGroup -SID $sid -ErrorAction Stop
        Add-LocalGroupMember -Group $group -Member $Name -ErrorAction Stop
    } catch {
        # 已经在 Users 组，或系统不支持按 SID 查询，忽略。
    }
    return [pscustomobject]@{ name = $Name; password = $password }
}

function Ensure-Firewall {
    # UDP 发现使用 Any：部分 Windows/第三方防火墙不会把广播包匹配到 LocalSubnet，
    # 会导致直连时主机收不到发现请求。SMB 仍然只允许本地子网。
    $rules = @(
        @{ Name = 'LanLink-SMB-In'; Protocol = 'TCP'; Port = 445; Remote = 'LocalSubnet' },
        @{ Name = 'LanLink-Discovery-In'; Protocol = 'UDP'; Port = 51234; Remote = 'Any' }
    )
    foreach ($rule in $rules) {
        Remove-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue
        New-NetFirewallRule -DisplayName $rule.Name -Group $script:FirewallGroup `
            -Description 'LanLink temporary rule' -Direction Inbound -Action Allow `
            -Protocol $rule.Protocol -LocalPort $rule.Port -Profile Any -RemoteAddress $rule.Remote `
            -ErrorAction Stop | Out-Null
    }
    Write-HelperLog '防火墙规则已放行 TCP 445（本地子网）/ UDP 51234（任意地址，用于发现）'
}

function Remove-LanLinkFirewall {
    Remove-NetFirewallRule -Group $script:FirewallGroup -ErrorAction SilentlyContinue
    Remove-NetFirewallRule -DisplayName 'LanLink-SMB-In' -ErrorAction SilentlyContinue
    Remove-NetFirewallRule -DisplayName 'LanLink-Discovery-In' -ErrorAction SilentlyContinue
}

function Remove-LanLinkAccount {
    $user = Get-LocalUser -Name $script:AccountName -ErrorAction SilentlyContinue
    if ($user -and [string]$user.Description -like '*LanLink*') {
        try {
            Remove-LocalUser -Name $script:AccountName -ErrorAction Stop
            Write-HelperLog "已删除本地账户 $($script:AccountName)"
        } catch {
            Write-HelperLog "删除本地账户失败（可能仍被会话占用）: $($_.Exception.Message)" 'WARN'
        }
    }
}

function Ensure-Share {
    param($Payload)
    $path = [string]$Payload.path
    $shareName = [string]$Payload.shareName
    $readOnly = [bool]$Payload.readOnly
    $adapterName = [string]$Payload.adapterName
    if (-not $shareName) {
        $shareName = 'LanLink'
    }
    if (-not $path) {
        throw '未指定共享文件夹'
    }
    if ($path -match '^\\\\') {
        throw '共享目录不能是网络路径'
    }
    if ($path -match '^[A-Za-z]:\\?$') {
        throw '请不要直接共享整个磁盘根目录，请选择子文件夹'
    }
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -ItemType Directory -Path $path -Force -ErrorAction Stop | Out-Null
    }
    $item = Get-Item -LiteralPath $path -ErrorAction Stop
    if (-not $item.PSIsContainer) {
        throw '共享路径必须是文件夹'
    }

    $account = Ensure-LocalAccount
    $sid = (New-Object System.Security.Principal.NTAccount($env:COMPUTERNAME, $account.name)).Translate([System.Security.Principal.SecurityIdentifier]).Value
    $rights = if ($readOnly) { 'RX' } else { 'M' }
    $icaclsOutput = & icacls.exe $path /grant "*${sid}:(OI)(CI)${rights}" /C /Q 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "设置 NTFS 权限失败（icacls 退出码 $LASTEXITCODE）：$($icaclsOutput -join ' ')"
    }

    $share = Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue
    if ($share -and [string]$share.Path -ne $path) {
        $base = $shareName
        $i = 2
        while (Get-SmbShare -Name "$base$i" -ErrorAction SilentlyContinue) {
            $i++
        }
        $shareName = "$base$i"
        $share = $null
    }
    if (-not $share) {
        if ($readOnly) {
            New-SmbShare -Name $shareName -Path $path -ReadAccess "$env:COMPUTERNAME\$($account.name)" -Description 'LanLink temporary share' -ErrorAction Stop | Out-Null
        } else {
            New-SmbShare -Name $shareName -Path $path -ChangeAccess "$env:COMPUTERNAME\$($account.name)" -Description 'LanLink temporary share' -ErrorAction Stop | Out-Null
        }
        Write-HelperLog "已创建共享 $shareName -> $path"
    } else {
        $access = if ($readOnly) { 'Read' } else { 'Change' }
        Grant-SmbShareAccess -Name $shareName -AccountName "$env:COMPUTERNAME\$($account.name)" -AccessRight $access -Force -ErrorAction Stop | Out-Null
        Write-HelperLog "已更新共享 $shareName 权限"
    }

    $service = Get-Service -Name LanmanServer -ErrorAction SilentlyContinue
    if ($service -and $service.Status -ne 'Running') {
        Start-Service -Name LanmanServer -ErrorAction Stop
    }

    Ensure-Firewall
    $ip = Get-ShareIp -AdapterName $adapterName

    $state = Read-State
    if (-not $state) {
        $state = [pscustomobject]@{
            version   = 1
            dirty     = $true
            createdAt = (Get-Date).ToString('o')
            network   = $null
            share     = $null
            firewall  = @()
        }
    }
    $state.dirty = $true
    $state.share = [pscustomobject]@{
        name        = $shareName
        path        = $path
        accountName = $account.name
        readOnly    = $readOnly
    }
    $state.firewall = @('LanLink-SMB-In', 'LanLink-Discovery-In')
    Write-State $state

    return [pscustomobject]@{
        shareName = $shareName
        path      = $path
        user      = "$env:COMPUTERNAME\$($account.name)"
        accountName = $account.name
        password  = $account.password
        readOnly  = $readOnly
        ip        = $ip
    }
}

function Remove-ShareOnly {
    $state = Read-State
    if (-not $state -or -not $state.share) {
        Remove-LanLinkFirewall
        return [pscustomobject]@{ removed = $false }
    }
    try {
        if (Get-SmbShare -Name $state.share.name -ErrorAction SilentlyContinue) {
            Remove-SmbShare -Name $state.share.name -Force -ErrorAction Stop
        }
        Write-HelperLog "已删除共享 $($state.share.name)"
    } catch {
        Write-HelperLog "删除共享失败: $($_.Exception.Message)" 'WARN'
        return [pscustomobject]@{ removed = $false; error = $_.Exception.Message }
    }
    Remove-LanLinkFirewall
    $state.share = $null
    $state.firewall = @()
    Write-State $state
    return [pscustomobject]@{ removed = $true }
}

function Invoke-RestoreAll {
    $state = Read-State
    $warnings = New-Object System.Collections.ArrayList
    $stateKept = $false
    if ($state) {
        if ($state.share) {
            try {
                if (Get-SmbShare -Name $state.share.name -ErrorAction SilentlyContinue) {
                    Remove-SmbShare -Name $state.share.name -Force -ErrorAction Stop
                }
                Write-HelperLog "已删除共享 $($state.share.name)"
            } catch {
                $stateKept = $true
                [void]$warnings.Add("删除共享失败：$($_.Exception.Message)")
            }
        }
        try {
            Remove-LanLinkFirewall
        } catch {
            [void]$warnings.Add("删除防火墙规则失败：$($_.Exception.Message)")
        }
        if ($state.network) {
            try {
                Restore-NetworkConfig -State $state
            } catch {
                $stateKept = $true
                [void]$warnings.Add("还原网络失败：$($_.Exception.Message)")
            }
        }
        if ($state.share -and $state.share.accountName) {
            Remove-LanLinkAccount
        }
    } else {
        Remove-LanLinkFirewall
    }

    if (-not $stateKept) {
        Remove-State
    } else {
        if ($state) {
            $state.dirty = $true
            Write-State $state
        }
    }
    return [pscustomobject]@{
        warnings = @($warnings)
        stateKept = $stateKept
    }
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

function Get-NetworkInfo {
    $result = New-Object System.Collections.ArrayList
    $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue)
    foreach ($adapter in $adapters) {
        $index = [int]$adapter.ifIndex
        $ips = @()
        try {
            $ips = @(Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                ForEach-Object {
                    [pscustomobject]@{
                        ipAddress    = [string]$_.IPAddress
                        prefixLength = [int]$_.PrefixLength
                        prefixOrigin = [string]$_.PrefixOrigin
                    }
                })
        } catch {
        }
        $gateways = @()
        try {
            $gateways = @(Get-NetRoute -InterfaceIndex $index -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' } |
                ForEach-Object { [string]$_.NextHop })
        } catch {
        }
        $dns = @()
        try {
            $dnsInfo = Get-DnsClientServerAddress -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction SilentlyContinue
            if ($dnsInfo) {
                $dns = @($dnsInfo.ServerAddresses | Where-Object { $_ })
            }
        } catch {
        }
        $profile = $null
        try {
            $profile = Get-NetConnectionProfile -InterfaceIndex $index -ErrorAction SilentlyContinue
        } catch {
        }
        $dhcp = $null
        try {
            $ipIf = Get-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction SilentlyContinue
            if ($ipIf) {
                $dhcp = [string]$ipIf.Dhcp -eq 'Enabled'
            }
        } catch {
        }
        [void]$result.Add([pscustomobject]@{
            name            = [string]$adapter.Name
            description     = [string]$adapter.InterfaceDescription
            interfaceIndex  = $index
            status          = [string]$adapter.Status
            linkSpeed       = [string]$adapter.LinkSpeed
            macAddress      = [string]$adapter.MacAddress
            mediaType       = [string]$adapter.MediaType
            dhcpEnabled     = $dhcp
            ipv4            = $ips
            gateways        = $gateways
            dnsServers      = $dns
            profileName     = $(if ($profile) { [string]$profile.Name } else { '' })
            networkCategory = $(if ($profile) { [string]$profile.NetworkCategory } else { '' })
        })
    }
    return @($result)
}

function Get-LanLinkSessions {
    $supported = $true
    $sessions = @()
    try {
        $null = Get-Command Get-SmbSession -ErrorAction Stop
        $sessions = @(Get-SmbSession -ErrorAction Stop | Where-Object {
                [string]$_.ClientUserName -like "*\$($script:AccountName)" -and [int]$_.NumOpens -gt 0
            } | ForEach-Object {
                [pscustomobject]@{
                    clientComputerName = [string]$_.ClientComputerName
                    clientUserName     = [string]$_.ClientUserName
                    numOpens           = [int]$_.NumOpens
                    secondsExists       = [int]$_.SecondsExists
                }
            })
    } catch {
        $supported = $false
        Write-HelperLog "查询 SMB 会话失败：$($_.Exception.Message)" 'WARN'
    }
    return [pscustomobject]@{
        supported = $supported
        sessions  = @($sessions)
    }
}

function Invoke-HelperCommand {
    param(
        [string]$Command,
        $Payload
    )
    if ($null -eq $Payload) {
        $Payload = [pscustomobject]@{}
    }
    switch ($Command) {
        'ping' {
            return [pscustomobject]@{ pong = $true; time = (Get-Date).ToString('o'); admin = (Test-Admin) }
        }
        'getNetworkInfo' {
            return @(Get-NetworkInfo)
        }
        'getState' {
            return (Read-State)
        }
        'getSessions' {
            return (Get-LanLinkSessions)
        }
        'configureDirect' {
            return (Configure-DirectAddress -Payload $Payload)
        }
        'restoreNetwork' {
            $state = Read-State
            if (-not $state -or -not $state.network) {
                return [pscustomobject]@{ restored = $false }
            }
            Restore-NetworkConfig -State $state
            return [pscustomobject]@{ restored = $true }
        }
        'ensureShare' {
            if ([bool]$Payload.dryRun) {
                return [pscustomobject]@{
                    dryRun    = $true
                    shareName = $(if ($Payload.shareName) { [string]$Payload.shareName } else { 'LanLink' })
                    path      = [string]$Payload.path
                    readOnly  = [bool]$Payload.readOnly
                }
            }
            return (Ensure-Share -Payload $Payload)
        }
        'removeShare' {
            return (Remove-ShareOnly)
        }
        'restoreAll' {
            return (Invoke-RestoreAll)
        }
        'testTcp' {
            return [pscustomobject]@{
                open = (Test-TcpPort -Address ([string]$Payload.address) -PortNumber ([int]$Payload.port) -TimeoutMs ([int]$Payload.timeoutMs))
            }
        }
        'getLogPath' {
            return [pscustomobject]@{ path = $script:HelperLog }
        }
        default {
            throw "未知命令: $Command"
        }
    }
}

function Invoke-SelfTest {
    $failures = New-Object System.Collections.ArrayList

    $pwd = New-RandomPassword
    if ($pwd.Length -ne 24) {
        [void]$failures.Add("密码长度错误: $($pwd.Length)")
    }
    if ($pwd -notmatch '[A-Z]' -or $pwd -notmatch '[a-z]' -or $pwd -notmatch '[0-9]' -or $pwd -notmatch '[!@#$%^&*]') {
        [void]$failures.Add('密码复杂度不足')
    }

    $json = @{ a = 1; b = @(1, 2, 3) } | ConvertTo-Json -Depth 5 -Compress
    $back = $json | ConvertFrom-Json
    if ($back.a -ne 1 -or @($back.b).Count -ne 3) {
        [void]$failures.Add('JSON 往返失败')
    }

    foreach ($prefix in $script:DirectSubnets) {
        if ($prefix -notmatch '^192\.168\.\d{2}$') {
            [void]$failures.Add("直连网段格式错误: $prefix")
        }
    }

    if ($failures.Count -gt 0) {
        $failures | ForEach-Object { Write-Host "FAIL: $_" }
        exit 1
    }
    Write-Host 'SELFTEST OK'
    exit 0
}

function Start-HelperServer {
    if (-not (Test-Admin) -and -not $DebugNonAdmin) {
        Write-HelperLog 'Helper 未以管理员权限启动' 'ERROR'
        exit 5
    }
    if ($Port -le 0 -or [string]::IsNullOrWhiteSpace($Token)) {
        Write-HelperLog '缺少 Port 或 Token' 'ERROR'
        exit 4
    }

    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
    $listener.Start()
    Write-HelperLog "Helper 已启动，监听 127.0.0.1:$Port，父进程 $ParentPid"
    $stop = $false

    try {
        while (-not $stop) {
            if (-not $listener.Pending()) {
                if ($ParentPid -gt 0) {
                    $parent = Get-Process -Id $ParentPid -ErrorAction SilentlyContinue
                    if (-not $parent) {
                        Write-HelperLog '父进程已退出，Helper 结束'
                        break
                    }
                }
                Start-Sleep -Milliseconds 200
                continue
            }

            $client = $listener.AcceptTcpClient()
            $client.NoDelay = $true
            $client.ReceiveTimeout = 0
            $stream = $client.GetStream()
            $stream.ReadTimeout = [System.Threading.Timeout]::Infinite
            $stream.WriteTimeout = [System.Threading.Timeout]::Infinite
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
            $writer = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding($false)))
            $writer.AutoFlush = $true

            try {
                while (-not $stop) {
                    $line = $reader.ReadLine()
                    if ($null -eq $line) {
                        break
                    }
                    if ([string]::IsNullOrWhiteSpace($line)) {
                        continue
                    }
                    $request = $null
                    try {
                        $request = $line | ConvertFrom-Json
                    } catch {
                        $writer.WriteLine((@{ ok = $false; error = '请求不是合法 JSON' } | ConvertTo-Json -Compress))
                        continue
                    }
                    if ([string]$request.token -ne $Token) {
                        $writer.WriteLine((@{ ok = $false; error = 'Token 无效' } | ConvertTo-Json -Compress))
                        continue
                    }
                    if ([string]$request.cmd -eq 'exit') {
                        $writer.WriteLine((@{ ok = $true; data = 'bye' } | ConvertTo-Json -Compress))
                        $stop = $true
                        break
                    }
                    try {
                        $data = Invoke-HelperCommand -Command ([string]$request.cmd) -Payload $request.args
                        $response = @{ ok = $true; data = $data }
                    } catch {
                        Write-HelperLog "命令 $($request.cmd) 失败: $($_.Exception.Message)" 'ERROR'
                        $response = @{ ok = $false; error = $_.Exception.Message; detail = $_.ScriptStackTrace }
                    }
                    $writer.WriteLine(($response | ConvertTo-Json -Depth 12 -Compress))
                }
            } catch {
                Write-HelperLog "连接异常: $($_.Exception.Message)" 'WARN'
            } finally {
                try { $reader.Close() } catch { }
                try { $writer.Close() } catch { }
                try { $client.Close() } catch { }
            }
        }
    } finally {
        try { $listener.Stop() } catch { }
        Write-HelperLog 'Helper 已退出'
    }
}

if ($SelfTest) {
    Invoke-SelfTest
}

Start-HelperServer
