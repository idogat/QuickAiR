# ╔══════════════════════════════════════════╗
# ║  QuickAiR — Network.psm1                ║
# ║  TCP+UDP connections (3 tiers), DNS    ║
# ║  cache (3 tiers), multi-NIC mapping    ║
# ╠══════════════════════════════════════════╣
# ║  Exports   : Invoke-Collector          ║
# ║  Inputs    : -Session                  ║
# ║              -TargetPSVersion          ║
# ║              -TargetCapabilities       ║
# ║  Output    : @{ data=@{tcp=[];udp=[]; ║
# ║               dns=[];adapters=[]};     ║
# ║               source=@{network=;      ║
# ║               udp=;dns=};             ║
# ║               errors=[] }             ║
# ║  Helpers   : ConvertFrom-NetstatOutput ║
# ║              Resolve-InterfaceAlias    ║
# ║              Add-DnsEnrichment         ║
# ║              ConvertTo-DnsTypeName     ║
# ║  Depends   : Core\Connection.psm1     ║
# ║  PS compat : 2.0+ (target-side)       ║
# ║  Version   : 2.2                      ║
# ╚══════════════════════════════════════════╝

$ErrorActionPreference = 'Continue'

# PS 2.0-compatible netstat scriptblock
$script:NET_SB_LEGACY = {
    $lines = cmd /c "netstat -ano" 2>&1
    New-Object PSObject -Property @{ Source = 'netstat_legacy'; Lines = $lines }
}
$script:NET_SB_FALLBACK = {
    $lines = & netstat -ano 2>&1
    New-Object PSObject -Property @{ Source = 'netstat_fallback'; Lines = $lines }
}
$script:NET_SB_CIM = {
    $out = @(); $udpOut = @()
    try {
        $raw = Get-CimInstance -Namespace ROOT/StandardCimv2 -ClassName MSFT_NetTCPConnection
        foreach ($c in $raw) {
            $ct = $null
            if ($c.CreationTime) { $ct = $c.CreationTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
            $out += New-Object PSObject -Property @{
                LocalAddress   = $c.LocalAddress
                LocalPort      = [int]$c.LocalPort
                RemoteAddress  = $c.RemoteAddress
                RemotePort     = [int]$c.RemotePort
                OwningProcess  = [int]$c.OwningProcess
                StateInt       = [int]$c.State
                InterfaceAlias = $c.InterfaceAlias
                CreationTime   = $ct
            }
        }
        try {
            $rawU = Get-CimInstance -Namespace ROOT/StandardCimv2 -ClassName MSFT_NetUDPEndpoint
            foreach ($u in $rawU) {
                $udpOut += New-Object PSObject -Property @{
                    LocalAddress  = $u.LocalAddress
                    LocalPort     = [int]$u.LocalPort
                    OwningProcess = [int]$u.OwningProcess
                }
            }
        } catch {}
        New-Object PSObject -Property @{ Source = 'cim'; Connections = $out; UdpEndpoints = $udpOut }
    } catch {
        $lines = & netstat -ano 2>&1
        New-Object PSObject -Property @{ Source = 'netstat_fallback'; Lines = $lines }
    }
}

# DNS cache scriptblocks
$script:DNS_PARSE_SB = {
    param([string[]]$Lines)
    $out     = @()
    $entry   = ''; $data = ''; $recType = ''; $ttl = 0
    foreach ($line in $Lines) {
        $line = $line.Trim()
        if ($line -match 'Record Name[\s.]*:[\s]*(.+)') {
            # flush previous
            if ($entry -and $data) {
                $out += New-Object PSObject -Property @{ Entry=$entry; Name=$entry; Data=$data; Type=$recType; TTL=$ttl }
            }
            $entry=''; $data=''; $recType=''; $ttl=0
            $entry = $Matches[1].Trim()
        } elseif ($line -match 'Record Type[\s.]*:[\s]*(.+)') {
            $recType = $Matches[1].Trim()
        } elseif ($line -match 'Time To Live[\s.]*:[\s]*(\d+)') {
            $ttl = [int]$Matches[1]
        } elseif ($line -match '(A|AAAA)\s+\(Host\) Record[\s.]*:[\s]*(.+)') {
            $data = $Matches[2].Trim()
        } elseif ($line -match 'Host Record[\s.]*:[\s]*(.+)') {
            $data = $Matches[1].Trim()
        } elseif (-not $data -and $line -match '^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$') {
            $data = $line
        }
    }
    if ($entry -and $data) {
        $out += New-Object PSObject -Property @{ Entry=$entry; Name=$entry; Data=$data; Type=$recType; TTL=$ttl }
    }
    $out
}

$script:DNS_SB_CIM = {
    try {
        $out = @()
        $raw = Get-CimInstance -Namespace ROOT/StandardCimv2 -ClassName MSFT_DNSClientCache
        foreach ($d in $raw) {
            $out += New-Object PSObject -Property @{ Entry=$d.Entry; Name=$d.Name; Data=$d.Data; Type=[int]$d.Type; TTL=[int]$d.TimeToLive }
        }
        New-Object PSObject -Property @{ Source='cim'; Entries=$out }
    } catch {
        $lines = & ipconfig /displaydns 2>&1
        New-Object PSObject -Property @{ Source='ipconfig_fallback'; Lines=$lines }
    }
}

# PS 2.0-compatible WMI adapter scriptblock
$script:ADAPTER_SB_WMI = {
    $out = @()
    $ncidMap = @{}
    try {
        $netAdapters = Get-WmiObject Win32_NetworkAdapter
        foreach ($a in $netAdapters) {
            if ($a.InterfaceIndex -ne $null -and $a.NetConnectionID) {
                $ncidMap[[int]$a.InterfaceIndex] = $a.NetConnectionID
            }
        }
    } catch {}
    $cfgs = Get-WmiObject Win32_NetworkAdapterConfiguration -Filter "IPEnabled=true"
    foreach ($cfg in $cfgs) {
        $ips = @()
        if ($cfg.IPAddress) { foreach ($ip in $cfg.IPAddress) { if ($ip) { $ips += $ip } } }
        $gw  = $null
        if ($cfg.DefaultIPGateway) { $gw = @($cfg.DefaultIPGateway)[0] }
        $dns = @()
        if ($cfg.DNSServerSearchOrder) { foreach ($d in $cfg.DNSServerSearchOrder) { if ($d) { $dns += $d } } }
        $alias = if ($ncidMap.ContainsKey([int]$cfg.InterfaceIndex)) { $ncidMap[[int]$cfg.InterfaceIndex] } else { $cfg.Description }
        $out += New-Object PSObject -Property @{
            AdapterName    = $cfg.Description
            InterfaceAlias = $alias
            IPAddresses    = $ips
            MACAddress     = $cfg.MACAddress
            DefaultGateway = $gw
            DNSServers     = $dns
            DHCPEnabled    = [bool]$cfg.DHCPEnabled
        }
    }
    $out
}

# PS 3+ CIM adapter scriptblock
$script:ADAPTER_SB_CIM = {
    $out = @()
    $ncidMap = @{}
    try {
        $netAdapters = Get-CimInstance Win32_NetworkAdapter
        foreach ($a in $netAdapters) {
            if ($a.InterfaceIndex -ne $null -and $a.NetConnectionID) {
                $ncidMap[[int]$a.InterfaceIndex] = $a.NetConnectionID
            }
        }
    } catch {}
    $cfgs = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=true"
    foreach ($cfg in $cfgs) {
        $ips = @()
        if ($cfg.IPAddress) { $ips = @($cfg.IPAddress | Where-Object { $_ }) }
        $gw  = $null
        if ($cfg.DefaultIPGateway) { $gw = @($cfg.DefaultIPGateway)[0] }
        $dns = @()
        if ($cfg.DNSServerSearchOrder) { $dns = @($cfg.DNSServerSearchOrder | Where-Object { $_ }) }
        $alias = if ($ncidMap.ContainsKey([int]$cfg.InterfaceIndex)) { $ncidMap[[int]$cfg.InterfaceIndex] } else { $cfg.Description }
        $out += New-Object PSObject -Property @{
            AdapterName    = $cfg.Description
            InterfaceAlias = $alias
            IPAddresses    = $ips
            MACAddress     = $cfg.MACAddress
            DefaultGateway = $gw
            DNSServers     = $dns
            DHCPEnabled    = [bool]$cfg.DHCPEnabled
        }
    }
    $out
}

# Internal helper: parse netstat output lines (TCP + UDP)
function ConvertFrom-NetstatOutput {
    param([string[]]$Lines)
    $tcp = @(); $udp = @()
    foreach ($line in $Lines) {
        $line = $line.Trim()
        # TCP: has state column
        if ($line -match '^TCP\s+(\[?[\d.:a-fA-F]+\]?):(\d+)\s+(\[?[\d.:a-fA-F*]+\]?):(\d+|\*)\s+(\S+)\s+(\d+)\s*$') {
            $la = $Matches[1] -replace '[\[\]]',''
            $ra = $Matches[3] -replace '[\[\]]',''
            $st = $Matches[5]
            $tcp += @{
                Protocol       = 'TCP'
                LocalAddress   = $la
                LocalPort      = [int]$Matches[2]
                RemoteAddress  = $ra
                RemotePort     = if ($Matches[4] -eq '*') { 0 } else { [int]$Matches[4] }
                State          = $st
                OwningProcess  = [int]$Matches[6]
                InterfaceAlias = if ($la -eq '0.0.0.0' -or $la -eq '::') { 'ALL_INTERFACES' } else { $la }
                CreationTime   = $null
                IsListener     = ($st -eq 'LISTENING')
                ReverseDns     = $null
                DnsMatch       = $null
                IsPrivateIP    = $false
            }
        }
        # UDP: no state column, remote is *:*
        elseif ($line -match '^UDP\s+(\[?[\d.:a-fA-F]+\]?):(\d+)\s+\S+\s+(\d+)\s*$') {
            $la = $Matches[1] -replace '[\[\]]',''
            $udp += @{
                Protocol       = 'UDP'
                LocalAddress   = $la
                LocalPort      = [int]$Matches[2]
                RemoteAddress  = $null
                RemotePort     = $null
                State          = 'LISTENING'
                OwningProcess  = [int]$Matches[3]
                InterfaceAlias = if ($la -eq '0.0.0.0' -or $la -eq '::') { 'ALL_INTERFACES' } else { $la }
                CreationTime   = $null
                IsListener     = $true
                ReverseDns     = $null
                DnsMatch       = $null
                IsPrivateIP    = $false
            }
        }
    }
    return @{ Tcp = $tcp; Udp = $udp }
}

# Internal helper: resolve interface alias per connection using adapter list
function Resolve-InterfaceAlias {
    param([array]$Connections, [array]$Adapters)

    $ipToAlias = @{}
    foreach ($adapter in $Adapters) {
        $alias = if ($adapter.InterfaceAlias) { $adapter.InterfaceAlias } else { $adapter.AdapterName }
        foreach ($ip in @($adapter.IPAddresses)) {
            if ($ip) {
                $ipKey = ($ip.ToString()) -replace '%.*$', ''
                if (-not $ipToAlias.ContainsKey($ipKey)) { $ipToAlias[$ipKey] = $alias }
            }
        }
    }

    $unknownCount = 0
    $out = @()
    foreach ($c in $Connections) {
        $la = if ($c.LocalAddress) { ($c.LocalAddress.ToString()) -replace '%.*$', '' } else { '' }

        $alias = if (-not $la -or $la -eq '0.0.0.0' -or $la -eq '::') {
            'ALL_INTERFACES'
        } elseif ($la -eq '127.0.0.1' -or $la -eq '::1') {
            'LOOPBACK'
        } elseif ($ipToAlias.ContainsKey($la)) {
            $ipToAlias[$la]
        } else {
            $unknownCount++
            'UNKNOWN'
        }

        $e = $c.Clone()
        $e.InterfaceAlias = $alias
        $out += $e
    }

    if ($unknownCount -gt 0) {
        Write-Log 'WARN' "InterfaceAlias: $unknownCount connection(s) unmatched to any adapter IP -> UNKNOWN"
    }
    return $out
}

# Internal helper: DNS enrichment (cache-only reverse DNS + DnsMatch)
function Add-DnsEnrichment {
    param([array]$Connections, [array]$DnsCache)

    $dnsMap = @{}
    foreach ($d in $DnsCache) {
        if ($d.Data -and -not $dnsMap.ContainsKey($d.Data)) { $dnsMap[$d.Data] = $d.Entry }
    }

    $out = @()
    foreach ($c in $Connections) {
        $e = $c.Clone()
        $ip = $c.RemoteAddress
        if ($ip) {
            if ($dnsMap.ContainsKey($ip)) {
                $e.ReverseDns = $dnsMap[$ip]
                $e.DnsMatch   = $dnsMap[$ip]
            }
            $e.IsPrivateIP = Test-PrivateIP $ip
        }
        $out += $e
    }
    return $out
}

# DNS record type lookup (F-08)
$script:DNS_TYPE_MAP = @{ 1='A'; 2='NS'; 5='CNAME'; 6='SOA'; 12='PTR'; 15='MX'; 28='AAAA'; 33='SRV' }

function ConvertTo-DnsTypeName {
    param($Type)
    if ($Type -is [int] -and $script:DNS_TYPE_MAP.ContainsKey($Type)) { return $script:DNS_TYPE_MAP[$Type] }
    return "$Type"
}

# Internal helper: resolve PID to process name
$script:PROC_SB_PS2 = {
    $out = @{}
    $procs = Get-WmiObject Win32_Process | Select-Object ProcessId, Name
    foreach ($p in $procs) { $out[[int]$p.ProcessId] = $p.Name }
    $out
}
$script:PROC_SB_PS3 = {
    $out = @{}
    foreach ($p in (Get-Process)) { $out[[int]$p.Id] = $p.ProcessName }
    $out
}

function Invoke-Collector {
    param(
        $Session,
        $TargetPSVersion,
        $TargetCapabilities
    )

    $errors        = @()
    $conns         = @()
    $udpConns      = @()
    $dnsEntries    = @()
    $adapters      = @()
    $networkSource = 'unknown'
    $udpSource     = 'unknown'
    $dnsSource     = 'unknown'

    $OP_TIMEOUT_SEC = 60

    # --- Network TCP + UDP collection ---
    try {
        if ($Session -ne $null -and $Session -is [hashtable] -and $Session.Method -eq 'WMI') {
            # WMI remote: try MSFT_NetTCPConnection if StandardCimv2 is available
            if ($Session.HasStandardCimv2 -eq $false) {
                $networkSource = 'wmi_remote_unavailable'
                $udpSource     = 'wmi_remote_unavailable'
                $errors += @{ artifact = 'network_tcp'; message = "WMI fallback on pre-2012 OS: TCP/UDP collection unavailable. MSFT_NetTCPConnection requires Windows 8/Server 2012+. Use netstat on target manually." }
            } else {
            try {
                $scope = New-Object System.Management.ManagementScope("\\$($Session.ComputerName)\ROOT\StandardCimv2")
                if ($Session.Credential) {
                    $scope.Options.Username = $Session.Credential.UserName
                    $scope.Options.Password = $Session.Credential.GetNetworkCredential().Password
                }
                $scope.Connect()

                # TCP connections
                $tcpQuery = New-Object System.Management.ObjectQuery("SELECT * FROM MSFT_NetTCPConnection")
                $tcpSearcher = New-Object System.Management.ManagementObjectSearcher($scope, $tcpQuery)
                $tcpResults = $tcpSearcher.Get()
                $networkSource = 'wmi_remote_cimv2'
                foreach ($c in $tcpResults) {
                    $la = [string]$c['LocalAddress']; $ra = [string]$c['RemoteAddress']
                    $stateStr = ConvertFrom-TcpStateInt ([int]$c['State'])
                    $ct = $null
                    try {
                        if ($c['CreationTime']) {
                            $ct = [System.Management.ManagementDateTimeConverter]::ToDateTime([string]$c['CreationTime']).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                        }
                    } catch {}
                    $conns += @{
                        Protocol       = 'TCP'
                        LocalAddress   = $la
                        LocalPort      = [int]$c['LocalPort']
                        RemoteAddress  = $ra
                        RemotePort     = [int]$c['RemotePort']
                        OwningProcess  = [int]$c['OwningProcess']
                        State          = $stateStr
                        InterfaceAlias = if ($la -eq '0.0.0.0' -or $la -eq '::') { 'ALL_INTERFACES' } else { $la }
                        CreationTime   = $ct
                        IsListener     = ($stateStr -eq 'LISTEN')
                        ReverseDns     = $null
                        DnsMatch       = $null
                        IsPrivateIP    = Test-PrivateIP $ra
                    }
                }

                # UDP endpoints
                try {
                    $udpQuery = New-Object System.Management.ObjectQuery("SELECT * FROM MSFT_NetUDPEndpoint")
                    $udpSearcher = New-Object System.Management.ManagementObjectSearcher($scope, $udpQuery)
                    $udpResults = $udpSearcher.Get()
                    $udpSource = 'wmi_remote_cimv2'
                    foreach ($u in $udpResults) {
                        $la = [string]$u['LocalAddress']
                        $udpConns += @{
                            Protocol       = 'UDP'
                            LocalAddress   = $la
                            LocalPort      = [int]$u['LocalPort']
                            RemoteAddress  = $null
                            RemotePort     = $null
                            State          = 'LISTENING'
                            OwningProcess  = [int]$u['OwningProcess']
                            InterfaceAlias = if ($la -eq '0.0.0.0' -or $la -eq '::') { 'ALL_INTERFACES' } else { $la }
                            CreationTime   = $null
                            IsListener     = $true
                            ReverseDns     = $null
                            DnsMatch       = $null
                            IsPrivateIP    = $false
                        }
                    }
                } catch {
                    $udpSource = 'wmi_remote_unavailable'
                    $errors += @{ artifact = 'network_udp'; message = "UDP unavailable via WMI remote: $($_.Exception.Message)" }
                }
            } catch {
                $networkSource = 'wmi_remote_unavailable'
                $udpSource     = 'wmi_remote_unavailable'
                $errors += @{ artifact = 'network_tcp'; message = "WMI fallback on pre-2012 OS: TCP/UDP collection unavailable. MSFT_NetTCPConnection requires Windows 8/Server 2012+. Use netstat on target manually." }
            }
            } # end HasStandardCimv2 else
        } elseif ($Session -ne $null) {
            # Remote (WinRM)
            if ($TargetCapabilities.HasNetTCPIP) { $sb = $script:NET_SB_CIM }
            elseif ($TargetPSVersion -ge 3)      { $sb = $script:NET_SB_FALLBACK }
            else                                 { $sb = $script:NET_SB_LEGACY }

            $r = Invoke-Command -Session $Session -ScriptBlock $sb
            $networkSource = $r.Source

            if ($r.Source -eq 'cim' -and $r.Connections) {
                foreach ($c in $r.Connections) {
                    $la = $c.LocalAddress; $ra = $c.RemoteAddress
                    $stateStr = ConvertFrom-TcpStateInt $c.StateInt
                    $conns += @{
                        Protocol       = 'TCP'
                        LocalAddress   = $la
                        LocalPort      = [int]$c.LocalPort
                        RemoteAddress  = $ra
                        RemotePort     = [int]$c.RemotePort
                        OwningProcess  = [int]$c.OwningProcess
                        State          = $stateStr
                        InterfaceAlias = if ($la -eq '0.0.0.0' -or $la -eq '::') { 'ALL_INTERFACES' } else { if ($c.InterfaceAlias) { $c.InterfaceAlias } else { $la } }
                        CreationTime   = $c.CreationTime
                        IsListener     = ($stateStr -eq 'LISTEN')
                        ReverseDns     = $null
                        DnsMatch       = $null
                        IsPrivateIP    = Test-PrivateIP $ra
                    }
                }
                # UDP from CIM remote
                $udpSource = 'cim'
                foreach ($u in @($r.UdpEndpoints)) {
                    if (-not $u) { continue }
                    $la = $u.LocalAddress
                    $udpConns += @{
                        Protocol       = 'UDP'
                        LocalAddress   = $la
                        LocalPort      = [int]$u.LocalPort
                        RemoteAddress  = $null
                        RemotePort     = $null
                        State          = 'LISTENING'
                        OwningProcess  = [int]$u.OwningProcess
                        InterfaceAlias = if ($la -eq '0.0.0.0' -or $la -eq '::') { 'ALL_INTERFACES' } else { $la }
                        CreationTime   = $null
                        IsListener     = $true
                        ReverseDns     = $null
                        DnsMatch       = $null
                        IsPrivateIP    = $false
                    }
                }
            } elseif ($r.Lines) {
                $parsed = ConvertFrom-NetstatOutput -Lines $r.Lines
                $conns    = $parsed.Tcp
                $udpConns = $parsed.Udp
                $udpSource = $r.Source
            }
        } else {
            # Local
            if ($TargetCapabilities.HasNetTCPIP) {
                $networkSource = 'cim'
                $raw = Get-CimInstance -Namespace ROOT/StandardCimv2 -ClassName MSFT_NetTCPConnection -OperationTimeoutSec $OP_TIMEOUT_SEC
                foreach ($c in $raw) {
                    $la = $c.LocalAddress; $ra = $c.RemoteAddress
                    $stateStr = ConvertFrom-TcpStateInt ([int]$c.State)
                    $ct = $null
                    if ($c.CreationTime) { $ct = $c.CreationTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
                    $conns += @{
                        Protocol       = 'TCP'
                        LocalAddress   = $la
                        LocalPort      = [int]$c.LocalPort
                        RemoteAddress  = $ra
                        RemotePort     = [int]$c.RemotePort
                        OwningProcess  = [int]$c.OwningProcess
                        State          = $stateStr
                        InterfaceAlias = if ($la -eq '0.0.0.0' -or $la -eq '::') { 'ALL_INTERFACES' } else { if ($c.InterfaceAlias) { $c.InterfaceAlias } else { $la } }
                        CreationTime   = $ct
                        IsListener     = ($stateStr -eq 'LISTEN')
                        ReverseDns     = $null
                        DnsMatch       = $null
                        IsPrivateIP    = Test-PrivateIP $ra
                    }
                }
                # UDP local CIM
                $udpSource = 'cim'
                try {
                    $rawU = Get-CimInstance -Namespace ROOT/StandardCimv2 -ClassName MSFT_NetUDPEndpoint -OperationTimeoutSec $OP_TIMEOUT_SEC
                    foreach ($u in $rawU) {
                        $la = $u.LocalAddress
                        $udpConns += @{
                            Protocol       = 'UDP'
                            LocalAddress   = $la
                            LocalPort      = [int]$u.LocalPort
                            RemoteAddress  = $null
                            RemotePort     = $null
                            State          = 'LISTENING'
                            OwningProcess  = [int]$u.OwningProcess
                            InterfaceAlias = if ($la -eq '0.0.0.0' -or $la -eq '::') { 'ALL_INTERFACES' } else { $la }
                            CreationTime   = $null
                            IsListener     = $true
                            ReverseDns     = $null
                            DnsMatch       = $null
                            IsPrivateIP    = $false
                        }
                    }
                } catch {
                    $errors += @{ artifact = 'network_udp'; message = $_.Exception.Message }
                }
            } elseif ($TargetPSVersion -ge 3) {
                $networkSource = 'netstat_fallback'
                $lines  = & netstat -ano 2>&1
                $parsed = ConvertFrom-NetstatOutput -Lines $lines
                $conns    = $parsed.Tcp
                $udpConns = $parsed.Udp
                $udpSource = $networkSource
            } else {
                $networkSource = 'netstat_legacy'
                $lines  = cmd /c "netstat -ano" 2>&1
                $parsed = ConvertFrom-NetstatOutput -Lines $lines
                $conns    = $parsed.Tcp
                $udpConns = $parsed.Udp
                $udpSource = $networkSource
            }
        }
    } catch {
        $errors += @{ artifact = 'network_tcp'; message = $_.Exception.Message }
        Write-Log 'ERROR' "Network collection failed: $($_.Exception.Message)"
    }

    # --- DNS cache collection ---
    try {
        if ($Session -ne $null -and $Session -is [hashtable] -and $Session.Method -eq 'WMI') {
            # WMI remote: no WMI equivalent for DNS client cache
            $dnsSource = 'wmi_remote_unavailable'
            $errors += @{ artifact = 'dns_cache'; severity = 'warning'; message = 'DNS cache collection unavailable via WMI remote' }
        } elseif ($Session -ne $null) {
            # Remote (WinRM)
            if ($TargetCapabilities.HasDNSClient) { $sb = $script:DNS_SB_CIM }
            elseif ($TargetPSVersion -ge 3) {
                $sb = { $lines = & ipconfig /displaydns 2>&1; New-Object PSObject -Property @{ Source='ipconfig_fallback'; Lines=$lines } }
            } else {
                $sb = { $lines = cmd /c "ipconfig /displaydns" 2>&1; New-Object PSObject -Property @{ Source='ipconfig_legacy'; Lines=$lines } }
            }

            $r = Invoke-Command -Session $Session -ScriptBlock $sb
            $dnsSource = $r.Source

            if ($r.Source -eq 'cim' -and $r.Entries) {
                foreach ($d in $r.Entries) {
                    $dnsEntries += @{ Entry=$d.Entry; Name=$d.Name; Data=$d.Data; Type=(ConvertTo-DnsTypeName $d.Type); TTL=[int]$d.TTL }
                }
            } elseif ($r.Lines) {
                $parsed = & $script:DNS_PARSE_SB -Lines $r.Lines
                foreach ($d in $parsed) { $dnsEntries += @{ Entry=$d.Entry; Name=$d.Name; Data=$d.Data; Type=$d.Type; TTL=$d.TTL } }
            }
        } else {
            # Local
            if ($TargetCapabilities.HasDNSClient) {
                $dnsSource = 'cim'
                $raw = Get-CimInstance -Namespace ROOT/StandardCimv2 -ClassName MSFT_DNSClientCache -OperationTimeoutSec $OP_TIMEOUT_SEC
                foreach ($d in $raw) {
                    $dnsEntries += @{ Entry=$d.Entry; Name=$d.Name; Data=$d.Data; Type=(ConvertTo-DnsTypeName ([int]$d.Type)); TTL=[int]$d.TimeToLive }
                }
            } elseif ($TargetPSVersion -ge 3) {
                $dnsSource = 'ipconfig_fallback'
                $lines  = & ipconfig /displaydns 2>&1
                $parsed = & $script:DNS_PARSE_SB -Lines $lines
                foreach ($d in $parsed) { $dnsEntries += @{ Entry=$d.Entry; Name=$d.Name; Data=$d.Data; Type=$d.Type; TTL=$d.TTL } }
            } else {
                $dnsSource = 'ipconfig_legacy'
                $lines  = cmd /c "ipconfig /displaydns" 2>&1
                $parsed = & $script:DNS_PARSE_SB -Lines $lines
                foreach ($d in $parsed) { $dnsEntries += @{ Entry=$d.Entry; Name=$d.Name; Data=$d.Data; Type=$d.Type; TTL=$d.TTL } }
            }
        }
    } catch {
        $errors += @{ artifact = 'dns_cache'; message = $_.Exception.Message }
        Write-Log 'ERROR' "DNS collection failed: $($_.Exception.Message)"
    }

    # --- Adapter enumeration ---
    try {
        if ($Session -ne $null -and $Session -is [hashtable] -and $Session.Method -eq 'WMI') {
            # WMI remote: adapter collection works well
            $wmiP = @{ ComputerName = $Session.ComputerName; ErrorAction = 'Stop' }
            if ($Session.Credential) { $wmiP.Credential = $Session.Credential }
            $ncidMap = @{}
            try {
                $netAdapters = Get-WmiObject Win32_NetworkAdapter @wmiP
                foreach ($a in $netAdapters) {
                    if ($a.InterfaceIndex -ne $null -and $a.NetConnectionID) {
                        $ncidMap[[int]$a.InterfaceIndex] = $a.NetConnectionID
                    }
                }
            } catch {}
            $cfgs = Get-WmiObject Win32_NetworkAdapterConfiguration -Filter "IPEnabled=true" @wmiP
            $raw = @()
            foreach ($cfg in $cfgs) {
                $ips = @()
                if ($cfg.IPAddress) { foreach ($ip in $cfg.IPAddress) { if ($ip) { $ips += $ip } } }
                $gw  = $null
                if ($cfg.DefaultIPGateway) { $gw = @($cfg.DefaultIPGateway)[0] }
                $dns = @()
                if ($cfg.DNSServerSearchOrder) { foreach ($d in $cfg.DNSServerSearchOrder) { if ($d) { $dns += $d } } }
                $alias = if ($ncidMap.ContainsKey([int]$cfg.InterfaceIndex)) { $ncidMap[[int]$cfg.InterfaceIndex] } else { $cfg.Description }
                $raw += New-Object PSObject -Property @{
                    AdapterName    = $cfg.Description
                    InterfaceAlias = $alias
                    IPAddresses    = $ips
                    MACAddress     = $cfg.MACAddress
                    DefaultGateway = $gw
                    DNSServers     = $dns
                    DHCPEnabled    = [bool]$cfg.DHCPEnabled
                }
            }
        } elseif ($Session -ne $null) {
            $sb = if ($TargetPSVersion -ge 3) { $script:ADAPTER_SB_CIM } else { $script:ADAPTER_SB_WMI }
            $raw = Invoke-Command -Session $Session -ScriptBlock $sb
        } else {
            $sb = if ($TargetPSVersion -ge 3) { $script:ADAPTER_SB_CIM } else { $script:ADAPTER_SB_WMI }
            $raw = & $sb
        }
        foreach ($a in @($raw)) {
            $ips = @(); if ($a.IPAddresses) { foreach ($ip in @($a.IPAddresses)) { if ($ip) { $ips += $ip.ToString() } } }
            $dns = @(); if ($a.DNSServers)  { foreach ($d  in @($a.DNSServers))  { if ($d)  { $dns += $d.ToString()  } } }
            $adapters += @{
                AdapterName    = $a.AdapterName
                InterfaceAlias = $a.InterfaceAlias
                IPAddresses    = $ips
                MACAddress     = $a.MACAddress
                DefaultGateway = $a.DefaultGateway
                DNSServers     = $dns
                DHCPEnabled    = $a.DHCPEnabled
            }
        }
    } catch {
        $errors += @{ artifact = 'network_adapters'; message = $_.Exception.Message }
        Write-Log 'ERROR' "Adapter enumeration failed: $($_.Exception.Message)"
    }

    # --- Process name resolution (F-04) ---
    $pidMap = @{}
    try {
        if ($Session -ne $null -and $Session -is [hashtable] -and $Session.Method -eq 'WMI') {
            $wmiProcP = @{ Class = 'Win32_Process'; ComputerName = $Session.ComputerName; ErrorAction = 'Stop' }
            if ($Session.Credential) { $wmiProcP.Credential = $Session.Credential }
            $wmiProcs = Get-WmiObject @wmiProcP
            foreach ($p in $wmiProcs) { $pidMap[[int]$p.ProcessId] = $p.Name }
        } elseif ($Session -ne $null) {
            $sb = if ($TargetPSVersion -ge 3) { $script:PROC_SB_PS3 } else { $script:PROC_SB_PS2 }
            $pidMap = Invoke-Command -Session $Session -ScriptBlock $sb
        } else {
            $sb = if ($TargetPSVersion -ge 3) { $script:PROC_SB_PS3 } else { $script:PROC_SB_PS2 }
            $pidMap = & $sb
        }
        if (-not $pidMap) { $pidMap = @{} }
    } catch {
        $errors += @{ artifact = 'process_names'; message = $_.Exception.Message }
    }

    foreach ($c in @($conns) + @($udpConns)) {
        $pid_ = $c.OwningProcess
        $c.OwningProcessName = if ($pidMap.ContainsKey([int]$pid_)) { $pidMap[[int]$pid_] } else { $null }
    }

    # --- Resolve interface aliases ---
    $resolvedTcp = Resolve-InterfaceAlias -Connections $conns -Adapters $adapters
    $resolvedUdp = Resolve-InterfaceAlias -Connections $udpConns -Adapters $adapters

    # --- DNS enrichment ---
    $enrichedTcp = Add-DnsEnrichment -Connections $resolvedTcp -DnsCache $dnsEntries
    $enrichedUdp = Add-DnsEnrichment -Connections $resolvedUdp -DnsCache $dnsEntries

    return @{
        data = @{
            tcp      = $enrichedTcp
            udp      = $enrichedUdp
            dns      = $dnsEntries
            adapters = $adapters
        }
        source = @{
            network = $networkSource
            udp     = $udpSource
            dns     = $dnsSource
        }
        errors = $errors
    }
}

Export-ModuleMember -Function Invoke-Collector
