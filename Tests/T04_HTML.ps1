#Requires -Version 5.1
# ╔══════════════════════════════════════╗
# ║  Quicker — T04_HTML.ps1             ║
# ║  T10 HTML sanity (size, no CDN),    ║
# ║  T11 HTML field coverage check      ║
# ╠══════════════════════════════════════╣
# ║  Inputs    : -JsonPath -HtmlPath    ║
# ║  Output    : @{ Passed=@();         ║
# ║               Failed=@(); Info=@() }║
# ║  PS compat : 5.1                    ║
# ╚══════════════════════════════════════╝
[CmdletBinding()]
param(
    [string]$JsonPath = "",
    [string]$HtmlPath = ""
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

# ---------------------------------------------------------------
# T10 - HTML sanity
# ---------------------------------------------------------------
if (-not (Test-Path $HtmlPath)) {
    Add-R "T10" $false "Report.html not found" @("Missing: $HtmlPath")
} else {
    $htmlInfo    = Get-Item $HtmlPath
    $htmlSize    = $htmlInfo.Length
    $htmlContent = [System.IO.File]::ReadAllText($HtmlPath, [System.Text.Encoding]::UTF8)
    $t10Fails    = @()

    # Must be non-trivial size
    if ($htmlSize -lt 10000) { $t10Fails += "HTML file too small ($htmlSize bytes, expected >= 10KB)" }

    # Must not have external resource references
    $extPatterns = @('http://','https://','cdn.','googleapis.com','cloudflare.com','bootstrapcdn','jsdelivr')
    foreach ($pat in $extPatterns) {
        if ($htmlContent -match [regex]::Escape($pat)) {
            $t10Fails += "External resource reference found: $pat"
        }
    }

    # Must contain expected structural markers
    $markers = @('<script', 'function renderFleet', 'function renderProcesses', 'function renderNetwork')
    foreach ($m in $markers) {
        if ($htmlContent.IndexOf($m) -lt 0) { $t10Fails += "Missing structural marker: $m" }
    }

    if ($t10Fails.Count -eq 0) {
        Add-R "T10" $true "HTML sanity (size=$([int]($htmlSize/1024))KB, no external resources)"
    } else {
        Add-R "T10" $false "HTML sanity ($($t10Fails.Count) violations)" $t10Fails
    }
}

# ---------------------------------------------------------------
# T11 - HTML field verification
# ---------------------------------------------------------------
$htmlContent11 = if (Test-Path $HtmlPath) {
    [System.IO.File]::ReadAllText($HtmlPath, [System.Text.Encoding]::UTF8)
} else { "" }

$requiredFields = @(
    # PROCESSES
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
    [PSCustomObject]@{ Field='dotnet_fallback';              Tab='PROCESSES' },
    # NETWORK
    [PSCustomObject]@{ Field='LocalAddress';                 Tab='NETWORK' },
    [PSCustomObject]@{ Field='LocalPort';                    Tab='NETWORK' },
    [PSCustomObject]@{ Field='RemoteAddress';                Tab='NETWORK' },
    [PSCustomObject]@{ Field='RemotePort';                   Tab='NETWORK' },
    [PSCustomObject]@{ Field='OwningProcess';                Tab='NETWORK' },
    [PSCustomObject]@{ Field='InterfaceAlias';               Tab='NETWORK' },
    [PSCustomObject]@{ Field='IsPrivateIP';                  Tab='NETWORK' },
    [PSCustomObject]@{ Field='ReverseDns';                   Tab='NETWORK' },
    [PSCustomObject]@{ Field='DnsMatch';                     Tab='NETWORK' },
    # DNS
    [PSCustomObject]@{ Field='Entry';                        Tab='DNS' },
    [PSCustomObject]@{ Field='_matchedProcess';              Tab='DNS' },
    [PSCustomObject]@{ Field='_matchedPid';                  Tab='DNS' },
    # FLEET
    [PSCustomObject]@{ Field='hostname';                     Tab='FLEET' },
    [PSCustomObject]@{ Field='target_os_caption';            Tab='FLEET' },
    [PSCustomObject]@{ Field='target_ps_version';            Tab='FLEET' },
    [PSCustomObject]@{ Field='collection_time_utc';          Tab='FLEET' },
    [PSCustomObject]@{ Field='Network_source';               Tab='FLEET' },
    [PSCustomObject]@{ Field='proc_count';                   Tab='FLEET' },
    [PSCustomObject]@{ Field='dns_count';                    Tab='FLEET' },
    [PSCustomObject]@{ Field='active_count';                 Tab='FLEET' },
    [PSCustomObject]@{ Field='unique_ips';                   Tab='FLEET' },
    [PSCustomObject]@{ Field='collection_errors';            Tab='FLEET' },
    # MANIFEST
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
    Add-R "T11" $true "HTML fields (all present in render logic)"
} else {
    Add-R "T11" $false "HTML fields ($($t11Missing.Count) missing: $($t11Missing -join '; '))" $t11Missing
}

return @{ Passed=$script:passResults; Failed=$script:failResults; Info=$script:infoResults }
