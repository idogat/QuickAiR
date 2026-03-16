#Requires -Version 5.1
# Modules\Collectors\Network.psm1
# Network TCP connections, DNS cache, and adapter enumeration plugin

Set-StrictMode -Off
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
    $out = @()
    try {
        $raw = Get-CimInstance -Namespace ROOT/StandardCimv2 -ClassName MSFT_NetTCPConnection
        foreach ($c in $raw) {
            $out += New-Object PSObject -Property @{
                LocalAddress   = $c.LocalAddress
                LocalPort      = [int]$c.LocalPort
                RemoteAddress  = $c.RemoteAddress
                RemotePort     = [int]$c.RemotePort
                OwningProcess  = [int]$c.OwningProcess
                StateInt       = [int]$c.State
                InterfaceAlias = $c.InterfaceAlias
            }
        }
        New-Object PSObject -Property @{ Source = 'cim'; Connections = $out }
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

# Internal helper: parse netstat output lines
function ConvertFrom-NetstatOutput {
    param([string[]]$Lines)
    $out = @()
    foreach ($line in $Lines) {
        $line = $line.Trim()
        if ($line -match '^TCP\s+(\[?[\d.:a-fA-F]+\]?):(\d+)\s+(\[?[\d.:a-fA-F*]+\]?):(\d+|\*)\s+(\S+)\s+(\d+)\s*$') {
            $la = $Matches[1] -replace '[\[\]]',''
            $ra = $Matches[3] -replace '[\[\]]',''
            $out += @{
                LocalAddress   = $la
                LocalPort      = [int]$Matches[2]
                RemoteAddress  = $ra
                RemotePort     = if ($Matches[4] -eq '*') { 0 } else { [int]$Matches[4] }
                State          = $Matches[5]
                OwningProcess  = [int]$Matches[6]
                InterfaceAlias = if ($la -eq '0.0.0.0' -or $la -eq '::') { 'ALL_INTERFACES' } else { $la }
                CreationTime   = $null
                ReverseDns     = $null
                DnsMatch       = $null
                IsPrivateIP    = $false
            }
        }
    }
    return $out
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

# Internal helper: DNS enrichment (reverse DNS + DnsMatch)
function Add-DnsEnrichment {
    param([array]$Connections, [array]$DnsCache)

    $dnsMap = @{}
    foreach ($d in $DnsCache) {
        if ($d.Data -and -not $dnsMap.ContainsKey($d.Data)) { $dnsMap[$d.Data] = $d.Entry }
    }

    $uniqueIPs = @($Connections | Where-Object { $_.RemoteAddress -and $_.RemoteAddress -ne '0.0.0.0' -and $_.RemoteAddress -ne '::' -and $_.RemoteAddress -ne '*' } | ForEach-Object { $_.RemoteAddress } | Sort-Object -Unique)

    $revMap = @{}
    foreach ($ip in $uniqueIPs) {
        try {
            $h = [System.Net.Dns]::GetHostEntry($ip)
            $revMap[$ip] = $h.HostName
        } catch {
            $revMap[$ip] = $ip
        }
    }

    $out = @()
    foreach ($c in $Connections) {
        $e = $c.Clone()
        $ip = $c.RemoteAddress
        if ($ip) {
            if ($revMap.ContainsKey($ip)) { $e.ReverseDns  = $revMap[$ip] }
            if ($dnsMap.ContainsKey($ip)) { $e.DnsMatch    = $dnsMap[$ip] }
            $e.IsPrivateIP = Test-PrivateIP $ip
        }
        $out += $e
    }
    return $out
}

function Invoke-Collector {
    param(
        $Session,
        $TargetPSVersion,
        $TargetCapabilities
    )

    $errors        = @()
    $conns         = @()
    $dnsEntries    = @()
    $adapters      = @()
    $networkSource = 'unknown'
    $dnsSource     = 'unknown'

    $OP_TIMEOUT_SEC = 60

    # --- Network TCP collection ---
    try {
        if ($Session -ne $null) {
            # Remote
            if ($TargetCapabilities.HasNetTCPIP) { $sb = $script:NET_SB_CIM }
            elseif ($TargetPSVersion -ge 3)      { $sb = $script:NET_SB_FALLBACK }
            else                                 { $sb = $script:NET_SB_LEGACY }

            $r = Invoke-Command -Session $Session -ScriptBlock $sb
            $networkSource = $r.Source

            if ($r.Source -eq 'cim' -and $r.Connections) {
                foreach ($c in $r.Connections) {
                    $la = $c.LocalAddress; $ra = $c.RemoteAddress
                    $conns += @{
                        LocalAddress   = $la
                        LocalPort      = [int]$c.LocalPort
                        RemoteAddress  = $ra
                        RemotePort     = [int]$c.RemotePort
                        OwningProcess  = [int]$c.OwningProcess
                        State          = ConvertFrom-TcpStateInt $c.StateInt
                        InterfaceAlias = if ($la -eq '0.0.0.0' -or $la -eq '::') { 'ALL_INTERFACES' } else { if ($c.InterfaceAlias) { $c.InterfaceAlias } else { $la } }
                        CreationTime   = $null
                        ReverseDns     = $null
                        DnsMatch       = $null
                        IsPrivateIP    = Test-PrivateIP $ra
                    }
                }
            } elseif ($r.Lines) {
                $conns = ConvertFrom-NetstatOutput -Lines $r.Lines
            }
        } else {
            # Local
            if ($TargetCapabilities.HasNetTCPIP) {
                $networkSource = 'cim'
                $raw = Get-CimInstance -Namespace ROOT/StandardCimv2 -ClassName MSFT_NetTCPConnection -OperationTimeoutSec $OP_TIMEOUT_SEC
                foreach ($c in $raw) {
                    $la = $c.LocalAddress; $ra = $c.RemoteAddress
                    $conns += @{
                        LocalAddress   = $la
                        LocalPort      = [int]$c.LocalPort
                        RemoteAddress  = $ra
                        RemotePort     = [int]$c.RemotePort
                        OwningProcess  = [int]$c.OwningProcess
                        State          = ConvertFrom-TcpStateInt ([int]$c.State)
                        InterfaceAlias = if ($la -eq '0.0.0.0' -or $la -eq '::') { 'ALL_INTERFACES' } else { if ($c.InterfaceAlias) { $c.InterfaceAlias } else { $la } }
                        CreationTime   = $null
                        ReverseDns     = $null
                        DnsMatch       = $null
                        IsPrivateIP    = Test-PrivateIP $ra
                    }
                }
            } elseif ($TargetPSVersion -ge 3) {
                $networkSource = 'netstat_fallback'
                $lines  = & netstat -ano 2>&1
                $conns  = ConvertFrom-NetstatOutput -Lines $lines
            } else {
                $networkSource = 'netstat_legacy'
                $lines  = cmd /c "netstat -ano" 2>&1
                $conns  = ConvertFrom-NetstatOutput -Lines $lines
            }
        }
    } catch {
        $errors += @{ artifact = 'network_tcp'; message = $_.Exception.Message }
        Write-Log 'ERROR' "Network collection failed: $($_.Exception.Message)"
    }

    # --- DNS cache collection ---
    try {
        if ($Session -ne $null) {
            # Remote
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
                    $dnsEntries += @{ Entry=$d.Entry; Name=$d.Name; Data=$d.Data; Type=[int]$d.Type; TTL=[int]$d.TTL }
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
                    $dnsEntries += @{ Entry=$d.Entry; Name=$d.Name; Data=$d.Data; Type=[int]$d.Type; TTL=[int]$d.TimeToLive }
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
        $sb = if ($TargetPSVersion -ge 3) { $script:ADAPTER_SB_CIM } else { $script:ADAPTER_SB_WMI }
        if ($Session -ne $null) {
            $raw = Invoke-Command -Session $Session -ScriptBlock $sb
        } else {
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

    # --- Resolve interface aliases ---
    $resolvedNet = Resolve-InterfaceAlias -Connections $conns -Adapters $adapters

    # --- DNS enrichment ---
    $enrichedNet = Add-DnsEnrichment -Connections $resolvedNet -DnsCache $dnsEntries

    return @{
        data = @{
            tcp      = $enrichedNet
            dns      = $dnsEntries
            adapters = $adapters
        }
        source = @{
            network = $networkSource
            dns     = $dnsSource
        }
        errors = $errors
    }
}

Export-ModuleMember -Function Invoke-Collector
