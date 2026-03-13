#Requires -Version 5.1
# Quicker Test Suite
<#
.SYNOPSIS
    Quicker Test Suite - validates collected JSON output and Report.html
.DESCRIPTION
    Runs 11 automated checks against the most recent collected JSON and Report.html.
    All decisions made autonomously. No prompts.
.PARAMETER JsonPath
    Path to collected JSON file. If omitted, uses most recent file in DFIROutput\.
.PARAMETER HtmlPath
    Path to Report.html. Defaults to Report.html in script directory.
.PARAMETER T3Threshold
    Fractional miss rate allowed for T3 (e.g. 0.05 = 5%). Default 0 (exact match).
.PARAMETER DcMode
    When set, enables DC-specific sanity checks.
#>
[CmdletBinding()]
param(
    [string]$JsonPath     = "",
    [string]$HtmlPath     = "",
    [float] $T3Threshold  = 0.0,
    [switch]$DcMode
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

$SUITE_VERSION = "1.0"

# ── Banner ────────────────────────────────────────────────────────────────────
Write-Host "================================" -ForegroundColor Cyan
Write-Host "Quicker Test Suite v$SUITE_VERSION"  -ForegroundColor Cyan
Write-Host "================================" -ForegroundColor Cyan

# ── Locate files ──────────────────────────────────────────────────────────────
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $JsonPath) {
    $outputDir = Join-Path $scriptDir "DFIROutput"
    if (-not (Test-Path $outputDir)) {
        Write-Host "No DFIROutput directory found. Run Collector.ps1 first." -ForegroundColor Red
        exit 1
    }
    $latest = Get-ChildItem -Path $outputDir -Recurse -Filter "*.json" |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) {
        Write-Host "No JSON files found in DFIROutput." -ForegroundColor Red
        exit 1
    }
    $JsonPath = $latest.FullName
}

if (-not $HtmlPath) {
    $HtmlPath = Join-Path $scriptDir "Report.html"
}

Write-Host "JSON : $JsonPath"
Write-Host "HTML : $HtmlPath"
Write-Host ""

# ── Load JSON ─────────────────────────────────────────────────────────────────
$jsonRaw  = [System.IO.File]::ReadAllText($JsonPath, [System.Text.Encoding]::UTF8)
$data     = $jsonRaw | ConvertFrom-Json
$manifest = $data.manifest
$procs    = @($data.processes)
$netTcp   = @($data.network_tcp)
$dnsCach  = @($data.dns_cache)

# ── Result accumulator ────────────────────────────────────────────────────────
$results = @()
$allPass = $true

function Add-Result {
    param([string]$Id, [bool]$Pass, [string]$Summary, [string[]]$Details = @(), [bool]$InfoOnly = $false)
    $script:results += [PSCustomObject]@{
        Id       = $Id
        Pass     = $Pass
        InfoOnly = $InfoOnly
        Summary  = $Summary
        Details  = $Details
    }
    if (-not $Pass -and -not $InfoOnly) { $script:allPass = $false }
}

# ── Detect if JSON is from local machine (T1/T3/T5 only valid for localhost) ───
$jsonHostname   = $manifest.hostname
$localHostnames = @($env:COMPUTERNAME, 'localhost', '127.0.0.1')
$isLocalJson    = ($localHostnames -icontains $jsonHostname)

# ═══════════════════════════════════════════════════════════════════════════════
# T1 — Process completeness
# ═══════════════════════════════════════════════════════════════════════════════
if (-not $isLocalJson) {
    Add-Result "T1" $true "Process completeness (SKIP - remote host $jsonHostname, localhost-only test)" @() $true
} else {

# Parse collection time so we only check processes that existed at collection time
$collectionTimeParsed = $null
try {
    $collectionTimeParsed = [datetime]::ParseExact(
        $manifest.collection_time_utc,
        'yyyy-MM-ddTHH:mm:ssZ',
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime()
} catch {}

$dotnetProcs  = [System.Diagnostics.Process]::GetProcesses()

# Filter to processes that were running at collection time (exclude those that
# started after the snapshot — they would not be in the collected JSON)
$expectedProcs = @()
foreach ($dp in $dotnetProcs) {
    if ($collectionTimeParsed) {
        try {
            $startUtc = $dp.StartTime.ToUniversalTime()
            # collection_time_utc is set after all data is collected, so any
            # process alive during collection started strictly before it
            if ($startUtc -lt $collectionTimeParsed) {
                $expectedProcs += $dp
            }
            continue
        } catch {}
    }
    $expectedProcs += $dp  # include if start time unavailable
}

$collectedPidSet = @{}
foreach ($p in $procs) { $collectedPidSet[[int]$p.ProcessId] = $true }

$t1Missing = @()
foreach ($dp in $expectedProcs) {
    if (-not $collectedPidSet.ContainsKey([int]$dp.Id)) {
        $t1Missing += "PID=$($dp.Id) Name=$($dp.ProcessName)"
    }
}

$t1ExpectedCount = $expectedProcs.Count
if ($t1Missing.Count -eq 0) {
    Add-Result "T1" $true "Process completeness ($t1ExpectedCount/$t1ExpectedCount processes verified)"
} else {
    Add-Result "T1" $false "Process completeness ($($t1Missing.Count) missing of $t1ExpectedCount)" $t1Missing
}
} # end isLocalJson for T1

# ═══════════════════════════════════════════════════════════════════════════════
# T2 — Process fields
# ═══════════════════════════════════════════════════════════════════════════════
$t2Violations = @()
foreach ($p in $procs) {
    $pid_  = $p.ProcessId
    $name_ = $p.Name
    if ($pid_ -eq $null)  { $t2Violations += "PID=null  Name=$name_" }
    if ($name_ -eq $null) { $t2Violations += "PID=$pid_ Name=null" }
    if ($p.source -ne 'dotnet_fallback') {
        $cd = $p.CreationDateUTC
        if ($cd -ne $null -and $cd -ne '') {
            if ($cd -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') {
                $t2Violations += "PID=$pid_ CreationDateUTC not valid ISO 8601: $cd"
            }
        }
    }
}

if ($t2Violations.Count -eq 0) {
    Add-Result "T2" $true "Process fields ($($procs.Count) processes OK)"
} else {
    Add-Result "T2" $false "Process fields ($($t2Violations.Count) violations)" $t2Violations
}

# ═══════════════════════════════════════════════════════════════════════════════
# T3 — Network connection completeness
# ═══════════════════════════════════════════════════════════════════════════════
if (-not $isLocalJson) {
    Add-Result "T3" $true "Network completeness (SKIP - remote host $jsonHostname, localhost-only test)" @() $true
} else {
$netstatLines = & netstat -ano 2>&1
$netstatConns = @()
foreach ($line in $netstatLines) {
    $ln = $line.ToString().Trim()
    if ($ln -match '^TCP\s+(\[?[\d.:a-fA-F]+\]?):(\d+)\s+(\[?[\d.:a-fA-F*]+\]?):(\d+|\*)\s+(\S+)\s+(\d+)\s*$') {
        # Normalize netstat state names to match CIM/Collector convention
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

    # IPv4/IPv6 equivalence for LISTEN connections:
    # netstat shows 0.0.0.0:port LISTEN; CIM may only return :::port LISTEN (IPv6-mapped)
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
    Add-Result "T3" $true "Network completeness ($($total3 - $t3Missing.Count)/$total3)$label"
} else {
    Add-Result "T3" $false "Network completeness ($($t3Missing.Count) missing of $total3)" $t3Missing
}
} # end isLocalJson for T3

# ═══════════════════════════════════════════════════════════════════════════════
# T4 — Network-process assignment
# ═══════════════════════════════════════════════════════════════════════════════
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
    Add-Result "T4" $true "Network-process assignment ($($netTcp.Count)/$($netTcp.Count) assigned)"
} else {
    Add-Result "T4" $false "Network-process assignment ($($t4Unassigned.Count) unassigned)" $t4Unassigned
}

# ═══════════════════════════════════════════════════════════════════════════════
# T5 — DNS cache completeness
# ═══════════════════════════════════════════════════════════════════════════════
if (-not $isLocalJson) {
    Add-Result "T5" $true "DNS cache completeness (SKIP - remote host $jsonHostname, localhost-only test)" @() $true
} else {
$ipconfigLines = & ipconfig /displaydns 2>&1
$ipconfigHosts = @()
foreach ($line in $ipconfigLines) {
    if ($line.ToString().Trim() -match 'Record Name[\s.]*:[\s]*(.+)') {
        $h = $Matches[1].Trim().ToLower()
        # Skip reverse-DNS PTR entries — these may be added to the DNS cache by
        # the collector's own reverse DNS enrichment step (GetHostEntry calls)
        # which runs AFTER dns_cache is collected, causing false T5 failures
        # Patterns: *.in-addr.arpa, *.ip6.arpa, *.bc.googleusercontent.com (PTR),
        #           *.1e100.net (Google PTR), *.compute-*.amazonaws.com etc.
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
    Add-Result "T5" $true "DNS cache completeness ($($ipconfigHosts.Count)/$($ipconfigHosts.Count))"
} else {
    Add-Result "T5" $false "DNS cache completeness ($($t5Missing.Count) missing of $($ipconfigHosts.Count))" $t5Missing
}
} # end isLocalJson for T5

# ═══════════════════════════════════════════════════════════════════════════════
# T6 — DNS correlation
# ═══════════════════════════════════════════════════════════════════════════════
$dnsDataSet = @{}
foreach ($e in $dnsCach) { if ($e.Data) { $dnsDataSet[$e.Data] = $true } }

$t6Missing = @()
foreach ($c in $netTcp) {
    if ($c.RemoteAddress -and $dnsDataSet.ContainsKey($c.RemoteAddress) -and (-not $c.DnsMatch)) {
        $t6Missing += "Local=$($c.LocalAddress):$($c.LocalPort) Remote=$($c.RemoteAddress):$($c.RemotePort) State=$($c.State)"
    }
}

if ($t6Missing.Count -eq 0) {
    Add-Result "T6" $true "DNS correlation (all matched)"
} else {
    Add-Result "T6" $false "DNS correlation ($($t6Missing.Count) missing DnsMatch where match exists)" $t6Missing
}

# ═══════════════════════════════════════════════════════════════════════════════
# T7 — ReverseDns for public IPs
# ═══════════════════════════════════════════════════════════════════════════════
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
    Add-Result "T7" $true "ReverseDns ($($uniquePublic.Count) public IPs, all populated)"
} else {
    Add-Result "T7" $false "ReverseDns ($($t7Missing.Count)/$($uniquePublic.Count) public IPs missing ReverseDns)" $t7Missing
}

# ═══════════════════════════════════════════════════════════════════════════════
# T8 — Manifest integrity
# ═══════════════════════════════════════════════════════════════════════════════
$t8Fails = @()

# SHA256 verification — reconstruct pre-hash JSON by replacing stored hash with null
$storedHash = $manifest.sha256
if ($storedHash) {
    $hashVerified = $false
    foreach ($nullFmt in @('  null', ' null', 'null')) {
        $reconstructed = $jsonRaw -replace ('"sha256":\s*"[^"]*"'), ('"sha256":' + $nullFmt)
        $bytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($reconstructed))
        $computed = ($bytes | ForEach-Object { $_.ToString('X2') }) -join ''
        if ($computed -ieq $storedHash) { $hashVerified = $true; break }
    }
    if (-not $hashVerified) { $t8Fails += "sha256 mismatch: stored=$storedHash" }
} else {
    $t8Fails += "sha256 field is null or missing"
}

# collection_time_utc
if ($manifest.collection_time_utc -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') {
    $t8Fails += "collection_time_utc not valid ISO 8601: $($manifest.collection_time_utc)"
}

# target_ps_version numeric
if ($manifest.target_ps_version -notmatch '^\d') {
    $t8Fails += "target_ps_version not numeric: $($manifest.target_ps_version)"
}

# network_source
$validNetSrc = @('cim','netstat_fallback','netstat_legacy')
if ($validNetSrc -notcontains $manifest.network_source) {
    $t8Fails += "network_source invalid: '$($manifest.network_source)' - expected one of: $($validNetSrc -join '|')"
}

# dns_source
$validDnsSrc = @('cim','ipconfig_fallback','ipconfig_legacy')
if ($validDnsSrc -notcontains $manifest.dns_source) {
    $t8Fails += "dns_source invalid: '$($manifest.dns_source)' - expected one of: $($validDnsSrc -join '|')"
}

if ($t8Fails.Count -eq 0) {
    Add-Result "T8" $true "Manifest integrity (SHA256 OK, all fields valid)"
} else {
    Add-Result "T8" $false "Manifest integrity ($($t8Fails.Count) failures)" $t8Fails
}

# ═══════════════════════════════════════════════════════════════════════════════
# T9 — No silent drops
# ═══════════════════════════════════════════════════════════════════════════════
$collErrs  = @($manifest.collection_errors)
$errCount  = $collErrs.Count
$t9Malform = @()
foreach ($e in $collErrs) {
    if ($e -eq $null)          { $t9Malform += "null entry in collection_errors"; continue }
    if (-not $e.artifact)      { $t9Malform += "entry missing 'artifact' field: $($e | ConvertTo-Json -Compress)" }
    if (-not $e.message)       { $t9Malform += "entry missing 'message' field: $($e | ConvertTo-Json -Compress)" }
}

if ($t9Malform.Count -eq 0) {
    Add-Result "T9" $true "collection_errors: $errCount entries" @() $true
} else {
    Add-Result "T9" $false "collection_errors: $($t9Malform.Count) malformed entries" $t9Malform
}

# ═══════════════════════════════════════════════════════════════════════════════
# T10 — HTML sanity
# ═══════════════════════════════════════════════════════════════════════════════
if (-not (Test-Path $HtmlPath)) {
    Add-Result "T10" $false "Report.html not found" @("Missing: $HtmlPath")
} else {
    $htmlInfo    = Get-Item $HtmlPath
    $htmlSize    = $htmlInfo.Length
    $htmlContent = [System.IO.File]::ReadAllText($HtmlPath, [System.Text.Encoding]::UTF8)
    $t10Fails    = @()

    if ($htmlSize -le (50 * 1024)) {
        $t10Fails += "File size $([int]($htmlSize/1024))KB - expected >50KB"
    }

    # External URLs (http/https, not localhost)
    $urlRx = [regex]::Matches($htmlContent, 'https?://[^\s"<>]+')
    foreach ($m in $urlRx) {
        if ($m.Value -notmatch 'localhost|127\.0\.0\.1') {
            $t10Fails += "External URL: $($m.Value)"
        }
    }

    # External <script src=
    $scrPattern = '<script[^>]+src\s*=\s*"([^"]+)"'
    $scrRx = [regex]::Matches($htmlContent, $scrPattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    foreach ($m in $scrRx) {
        $src = $m.Groups[1].Value
        if ($src -notmatch '^[#/]{1,2}' -and $src -match '://') {
            $t10Fails += "<script src=$src> - external"
        }
    }

    # External <link href=
    $lnkPattern = '<link[^>]+href\s*=\s*"([^"]+)"'
    $lnkRx = [regex]::Matches($htmlContent, $lnkPattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    foreach ($m in $lnkRx) {
        if ($m.Groups[1].Value -match 'https?://') {
            $t10Fails += "<link href=$($m.Groups[1].Value)> - external"
        }
    }

    if ($t10Fails.Count -eq 0) {
        Add-Result "T10" $true "HTML sanity (size=$([int]($htmlSize/1024))KB, no external resources)"
    } else {
        Add-Result "T10" $false "HTML sanity ($($t10Fails.Count) violations)" $t10Fails
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# T11 — HTML field verification
# ═══════════════════════════════════════════════════════════════════════════════
$htmlContent11 = if (Test-Path $HtmlPath) {
    [System.IO.File]::ReadAllText($HtmlPath, [System.Text.Encoding]::UTF8)
} else { "" }

# Each entry: Field = string to search for, Tab = which section it belongs to
$requiredFields = @(
    # ── PROCESSES
    [PSCustomObject]@{ Field='ProcessId';                    Tab='PROCESSES' },
    [PSCustomObject]@{ Field='ParentProcessId';              Tab='PROCESSES' },
    [PSCustomObject]@{ Field='CommandLine';                  Tab='PROCESSES' },
    [PSCustomObject]@{ Field='ExecutablePath';               Tab='PROCESSES' },
    [PSCustomObject]@{ Field='CreationDateUTC';              Tab='PROCESSES' },
    [PSCustomObject]@{ Field='CreationDateLocal';            Tab='PROCESSES' },
    [PSCustomObject]@{ Field='WorkingSetSize';               Tab='PROCESSES' },
    [PSCustomObject]@{ Field='VirtualSize';                  Tab='PROCESSES' },
    [PSCustomObject]@{ Field='SessionId';                    Tab='PROCESSES' },
    [PSCustomObject]@{ Field='HandleCount';                  Tab='PROCESSES' },
    [PSCustomObject]@{ Field='dotnet_fallback';              Tab='PROCESSES' },  # source visual flag
    # ── NETWORK
    [PSCustomObject]@{ Field='LocalAddress';                 Tab='NETWORK' },
    [PSCustomObject]@{ Field='LocalPort';                    Tab='NETWORK' },
    [PSCustomObject]@{ Field='RemoteAddress';                Tab='NETWORK' },
    [PSCustomObject]@{ Field='RemotePort';                   Tab='NETWORK' },
    [PSCustomObject]@{ Field='OwningProcess';                Tab='NETWORK' },
    [PSCustomObject]@{ Field='InterfaceAlias';               Tab='NETWORK' },
    [PSCustomObject]@{ Field='IsPrivateIP';                  Tab='NETWORK' },
    [PSCustomObject]@{ Field='ReverseDns';                   Tab='NETWORK' },
    [PSCustomObject]@{ Field='DnsMatch';                     Tab='NETWORK' },
    # ── DNS
    [PSCustomObject]@{ Field='Entry';                        Tab='DNS' },
    [PSCustomObject]@{ Field='_matchedProcess';              Tab='DNS' },       # DnsMatch linked process
    [PSCustomObject]@{ Field='_matchedPid';                  Tab='DNS' },       # DnsMatch linked PID
    # ── FLEET
    [PSCustomObject]@{ Field='hostname';                     Tab='FLEET' },
    [PSCustomObject]@{ Field='target_os_caption';            Tab='FLEET' },
    [PSCustomObject]@{ Field='target_ps_version';            Tab='FLEET' },
    [PSCustomObject]@{ Field='collection_time_utc';          Tab='FLEET' },
    [PSCustomObject]@{ Field='network_source';               Tab='FLEET' },
    [PSCustomObject]@{ Field='dns_source';                   Tab='FLEET' },
    [PSCustomObject]@{ Field='proc_count';                   Tab='FLEET' },
    [PSCustomObject]@{ Field='dns_count';                    Tab='FLEET' },
    [PSCustomObject]@{ Field='active_count';                 Tab='FLEET' },
    [PSCustomObject]@{ Field='unique_ips';                   Tab='FLEET' },
    [PSCustomObject]@{ Field='collection_errors';            Tab='FLEET' },
    # ── MANIFEST
    [PSCustomObject]@{ Field='collector_version';            Tab='MANIFEST' },
    [PSCustomObject]@{ Field='analyzer_version';             Tab='MANIFEST' },
    [PSCustomObject]@{ Field='target_os_version';            Tab='MANIFEST' },
    [PSCustomObject]@{ Field='target_timezone_offset_minutes'; Tab='MANIFEST' },
    [PSCustomObject]@{ Field='collection_errors';            Tab='MANIFEST' }
)

$t11Missing = @()
$seen = @{}
foreach ($req in $requiredFields) {
    $key = "$($req.Tab):$($req.Field)"
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    if ($htmlContent11.IndexOf($req.Field) -lt 0) {
        $t11Missing += "$($req.Tab): $($req.Field)"
    }
}

if ($t11Missing.Count -eq 0) {
    Add-Result "T11" $true "HTML fields (all present in render logic)"
} else {
    Add-Result "T11" $false "HTML fields ($($t11Missing.Count) missing: $($t11Missing -join '; '))" $t11Missing
}

# ═══════════════════════════════════════════════════════════════════════════════
# DC-specific sanity checks (only when -DcMode)
# ═══════════════════════════════════════════════════════════════════════════════
if ($DcMode) {
    $dcFails = @()
    $dcWarn  = @()

    # Required DC ports in network_tcp
    $dcPorts = @(53, 88, 135, 389, 445, 636, 3268, 3269)
    $jsonPorts = @($netTcp | ForEach-Object { [int]$_.LocalPort }) | Sort-Object -Unique
    foreach ($port in $dcPorts) {
        if ($jsonPorts -notcontains $port) { $dcWarn += "WARN: DC port $port not found in network_tcp" }
    }

    # Sanity: Port 53, 389, 88 must be present
    foreach ($port in @(53, 88, 389)) {
        if ($jsonPorts -notcontains $port) { $dcFails += "FAIL: Required DC port $port absent from network_tcp" }
    }

    # lsass.exe
    $hasLsass = $procs | Where-Object { $_.Name -match '^lsass\.exe$' }
    if (-not $hasLsass) { $dcFails += "FAIL: lsass.exe not in processes" }

    # dns.exe or ntds.exe
    $hasDnsOrNtds = $procs | Where-Object { $_.Name -match '^(dns\.exe|ntds\.exe)$' }
    if (-not $hasDnsOrNtds) { $dcFails += "FAIL: dns.exe or ntds.exe not in processes" }

    if ($dcWarn.Count -gt 0) {
        Write-Host ""
        Write-Host "DC-SPECIFIC WARNINGS:" -ForegroundColor Yellow
        $dcWarn | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    }

    $dcPass = $dcFails.Count -eq 0
    Add-Result "DC" $dcPass "DC sanity checks" $dcFails
}

# ═══════════════════════════════════════════════════════════════════════════════
# Output
# ═══════════════════════════════════════════════════════════════════════════════
Write-Host ""
$passCount    = 0
$nonInfoCount = 0
foreach ($r in $results) {
    if ($r.InfoOnly) {
        $tag   = "[INFO]"
        $color = 'Cyan'
    } elseif ($r.Pass) {
        $tag   = "[PASS]"
        $color = 'Green'
        $passCount++
        $nonInfoCount++
    } else {
        $tag   = "[FAIL]"
        $color = 'Red'
        $nonInfoCount++
    }

    $line = "{0} {1,-5} - {2}" -f $tag, $r.Id, $r.Summary
    Write-Host $line -ForegroundColor $color

    if (-not $r.Pass -and -not $r.InfoOnly -and $r.Details.Count -gt 0) {
        $show = $r.Details | Select-Object -First 25
        foreach ($d in $show) { Write-Host "        $d" -ForegroundColor DarkGray }
        if ($r.Details.Count -gt 25) {
            $extra = $r.Details.Count - 25
            Write-Host "        ... ($extra more)" -ForegroundColor DarkGray
        }
    }
    if ($r.InfoOnly -and $r.Details.Count -gt 0) {
        foreach ($d in $r.Details) { Write-Host "        $d" -ForegroundColor DarkGray }
    }
}

Write-Host ""
Write-Host ("SUMMARY: {0}/{1} passed" -f $passCount, $nonInfoCount) -ForegroundColor White
Write-Host ""
if ($allPass) {
    Write-Host "ALL TESTS PASSED" -ForegroundColor Green
} else {
    Write-Host "TESTS FAILED" -ForegroundColor Red
}
