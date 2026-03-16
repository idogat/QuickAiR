#Requires -Version 5.1
# ╔══════════════════════════════════════╗
# ║  Quicker — T01_Processes.ps1        ║
# ║  T1 process completeness,           ║
# ║  T2 process field validation        ║
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

# Load JSON
$jsonRaw  = [System.IO.File]::ReadAllText($JsonPath, [System.Text.Encoding]::UTF8)
$data     = $jsonRaw | ConvertFrom-Json
$manifest = $data.manifest
$procs    = @($data.Processes)

$jsonHostname   = $manifest.hostname
$localHostnames = @($env:COMPUTERNAME, 'localhost', '127.0.0.1')
$isLocalJson    = ($localHostnames -icontains $jsonHostname)

# ---------------------------------------------------------------
# T1 - Process completeness
# ---------------------------------------------------------------
if (-not $isLocalJson) {
    Add-R "T1" $true "Process completeness (SKIP - remote host $jsonHostname, localhost-only test)" @() $true
} else {
    $collectionTimeParsed = $null
    try {
        $collectionTimeParsed = [datetime]::ParseExact(
            $manifest.collection_time_utc,
            'yyyy-MM-ddTHH:mm:ssZ',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime()
    } catch {}

    $dotnetProcs  = [System.Diagnostics.Process]::GetProcesses()
    $expectedProcs = @()
    foreach ($dp in $dotnetProcs) {
        if ($collectionTimeParsed) {
            try {
                $startUtc = $dp.StartTime.ToUniversalTime()
                if ($startUtc -lt $collectionTimeParsed) { $expectedProcs += $dp }
                continue
            } catch {}
        }
        $expectedProcs += $dp
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
        Add-R "T1" $true "Process completeness ($t1ExpectedCount/$t1ExpectedCount processes verified)"
    } else {
        Add-R "T1" $false "Process completeness ($($t1Missing.Count) missing of $t1ExpectedCount)" $t1Missing
    }
}

# ---------------------------------------------------------------
# T2 - Process fields
# ---------------------------------------------------------------
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
    Add-R "T2" $true "Process fields ($($procs.Count) processes OK)"
} else {
    Add-R "T2" $false "Process fields ($($t2Violations.Count) violations)" $t2Violations
}

return @{ Passed=$script:passResults; Failed=$script:failResults; Info=$script:infoResults }
