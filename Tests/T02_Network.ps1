#Requires -Version 5.1
# ╔══════════════════════════════════════╗
# ║  QuickAiR — T02_Network.ps1          ║
# ║  T3 network completeness, T4 proc   ║
# ║  assign, T5 DNS, T6 correl, T7 rDNS ║
# ╠══════════════════════════════════════╣
# ║  Inputs    : -JsonPath -HtmlPath    ║
# ║              -T3Threshold           ║
# ║  Output    : @{ Passed=@();         ║
# ║               Failed=@(); Info=@() }║
# ║  PS compat : 5.1                    ║
# ╚══════════════════════════════════════╝
[CmdletBinding()]
param(
    [string]$JsonPath     = "",
    [string]$HtmlPath     = "",
    [float]$T3Threshold   = 0.0
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

$script:passResults = @()
$script:failResults = @()
$script:infoResults = @()

function Add-R {
    param([string]$Id, [bool]$Pass, [string]$Summary, [string[]]$Details=@(), [bool]$IsInfo=$false)
    $obj = [PSCustomObject]@{Id=$Id;Pass=$Pass;InfoOnly=$IsInfo;Summary=$Summary;Details=$Details}
    if ($IsInfo)       { $script:infoResults  += $obj }
    elseif ($Pass)     { $script:passResults  += $obj }
    else               { $script:failResults  += $obj }
}

# Load JSON
$jsonRaw  = [System.IO.File]::ReadAllText($JsonPath, [System.Text.Encoding]::UTF8)
$data     = $jsonRaw | ConvertFrom-Json
$manifest = $data.manifest
$procs    = @($data.Processes)
$netTcp   = @($data.Network.tcp)
$dnsCach  = @($data.Network.dns)

$jsonHostname   = $manifest.hostname
$localHostnames = @($env:COMPUTERNAME, 'localhost', '127.0.0.1')
$isLocalJson    = ($localHostnames -icontains $jsonHostname)

# ---------------------------------------------------------------
# T3 - Network connection completeness
# ---------------------------------------------------------------
if (-not $isLocalJson) {
    Add-R "T3" $true "Network completeness (SKIP - remote host $jsonHostname, localhost-only test)" @() $true
} else {
    $netstatLines = & netstat -ano 2>&1
    $netstatConns = @()
    foreach ($line in $netstatLines) {
        $ln = $line.ToString().Trim()
        if ($ln -match '^TCP\s+(\[?[\d.:a-fA-F]+\]?):(\d+)\s+(\[?[\d.:a-fA-F*]+\]?):(\d+|\*)\s+(\S+)\s+(\d+)\s*$') {
            $rawState = $Matches[5]
            $normState = switch ($rawState) {
                'LISTENING'    { 'LISTEN' }
                'SYN_SENT'     { 'SYN_SENT' }
                'SYN_RECEIVED' { 'SYN_RECEIVED' }
                default        { $rawState }
            }
            $netstatConns += [PSCustomObject]@{
                LocalPort     = [int]$Matches[2]
                RemoteAddress = ($Matches[3] -replace '[\[\]]','')
                RemotePort    = if ($Matches[4] -eq '*') { 0 } else { [int]$Matches[4] }
                State         = $normState
            }
        }
    }

    $jsonNetSet = @{}
    foreach ($c in $netTcp) {
        $key = "$($c.LocalPort)|$($c.RemoteAddress)|$($c.RemotePort)|$($c.State)"
        $jsonNetSet[$key] = $true
    }

    $t3Missing = @()
    foreach ($c in $netstatConns) {
        $key = "$($c.LocalPort)|$($c.RemoteAddress)|$($c.RemotePort)|$($c.State)"
        if ($jsonNetSet.ContainsKey($key)) { continue }

        if ($c.State -eq 'LISTEN' -and $c.RemotePort -eq 0) {
            $altRA  = if ($c.RemoteAddress -eq '0.0.0.0') { '::' } else { '0.0.0.0' }
            $altKey = "$($c.LocalPort)|$altRA|0|LISTEN"
            if ($jsonNetSet.ContainsKey($altKey)) { continue }
        }

        $t3Missing += "$($c.State) LocalPort=$($c.LocalPort) Remote=$($c.RemoteAddress):$($c.RemotePort)"
    }

    $total3   = $netstatConns.Count
    $missRate = if ($total3 -gt 0) { $t3Missing.Count / $total3 } else { 0 }
    $t3Pass   = ($t3Missing.Count -eq 0) -or ($T3Threshold -gt 0 -and $missRate -le $T3Threshold)

    if ($t3Pass) {
        $label = if ($T3Threshold -gt 0 -and $t3Missing.Count -gt 0) { " (within $T3Threshold threshold)" } else { "" }
        Add-R "T3" $true "Network completeness ($($total3 - $t3Missing.Count)/$total3)$label"
    } else {
        Add-R "T3" $false "Network completeness ($($t3Missing.Count) missing of $total3)" $t3Missing
    }
}

# ---------------------------------------------------------------
# T4 - Network-process assignment
# ---------------------------------------------------------------
$pidSet      = @{}
foreach ($p in $procs) { $pidSet[[int]$p.ProcessId] = $true }
$t4Unassigned = @()
foreach ($c in $netTcp) {
    $pid_ = [int]$c.OwningProcess
    if (-not $pidSet.ContainsKey($pid_)) {
        $t4Unassigned += "Local=$($c.LocalAddress):$($c.LocalPort) Remote=$($c.RemoteAddress):$($c.RemotePort) State=$($c.State) OwningProcess=$pid_"
    }
}

if ($t4Unassigned.Count -eq 0) {
    Add-R "T4" $true "Network-process assignment ($($netTcp.Count)/$($netTcp.Count) assigned)"
} else {
    Add-R "T4" $false "Network-process assignment ($($t4Unassigned.Count) unassigned)" $t4Unassigned
}

# ---------------------------------------------------------------
# T5 - DNS cache completeness
# ---------------------------------------------------------------
if (-not $isLocalJson) {
    Add-R "T5" $true "DNS cache completeness (SKIP - remote host $jsonHostname, localhost-only test)" @() $true
} else {
    $ipconfigLines = & ipconfig /displaydns 2>&1
    $ipconfigHosts = @()
    foreach ($line in $ipconfigLines) {
        if ($line.ToString().Trim() -match 'Record Name[\s.]*:[\s]*(.+)') {
            $h = $Matches[1].Trim().ToLower()
            if ($h -match '\.(in-addr|ip6)\.arpa$') { continue }
            if ($h -match '\.(1e100\.net|bc\.googleusercontent\.com|amazonaws\.com|azure\.com|azurewebsites\.net|cloudfront\.net)$') { continue }
            $ipconfigHosts += $h
        }
    }
    $ipconfigHosts = @($ipconfigHosts | Sort-Object -Unique)

    $jsonDnsSet = @{}
    foreach ($e in $dnsCach) { if ($e.Entry) { $jsonDnsSet[$e.Entry.ToLower()] = $true } }

    $t5Missing = @()
    foreach ($h in $ipconfigHosts) {
        if (-not $jsonDnsSet.ContainsKey($h)) { $t5Missing += $h }
    }

    if ($t5Missing.Count -eq 0) {
        Add-R "T5" $true "DNS cache completeness ($($ipconfigHosts.Count)/$($ipconfigHosts.Count))"
    } else {
        Add-R "T5" $false "DNS cache completeness ($($t5Missing.Count) missing of $($ipconfigHosts.Count))" $t5Missing
    }
}

# ---------------------------------------------------------------
# T6 - DNS correlation
# ---------------------------------------------------------------
$dnsDataSet = @{}
foreach ($e in $dnsCach) { if ($e.Data) { $dnsDataSet[$e.Data] = $true } }

$t6Missing = @()
foreach ($c in $netTcp) {
    if ($c.RemoteAddress -and $dnsDataSet.ContainsKey($c.RemoteAddress) -and (-not $c.DnsMatch)) {
        $t6Missing += "Local=$($c.LocalAddress):$($c.LocalPort) Remote=$($c.RemoteAddress):$($c.RemotePort) State=$($c.State)"
    }
}

if ($t6Missing.Count -eq 0) {
    Add-R "T6" $true "DNS correlation (all matched)"
} else {
    Add-R "T6" $false "DNS correlation ($($t6Missing.Count) missing DnsMatch where match exists)" $t6Missing
}

# ---------------------------------------------------------------
# T7 - ReverseDns for public IPs
# ---------------------------------------------------------------
$privatePattern = '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.|0\.0\.0\.0$|::1$|fe80:|::$)'
$uniquePublic   = @($netTcp |
    Where-Object { $_.RemoteAddress -and
                   $_.RemoteAddress -ne '0.0.0.0' -and
                   $_.RemoteAddress -ne '::' -and
                   $_.RemoteAddress -notmatch $privatePattern } |
    ForEach-Object { $_.RemoteAddress } | Sort-Object -Unique)

$t7Missing = @()
foreach ($ip in $uniquePublic) {
    $hasRev = $netTcp | Where-Object { $_.RemoteAddress -eq $ip -and $_.ReverseDns } | Select-Object -First 1
    if (-not $hasRev) { $t7Missing += $ip }
}

if ($t7Missing.Count -eq 0) {
    Add-R "T7" $true "ReverseDns ($($uniquePublic.Count) public IPs, all populated)"
} else {
    Add-R "T7" $false "ReverseDns ($($t7Missing.Count)/$($uniquePublic.Count) public IPs missing ReverseDns)" $t7Missing
}

return @{ Passed=$script:passResults; Failed=$script:failResults; Info=$script:infoResults }
