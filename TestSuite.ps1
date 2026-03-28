#Requires -Version 5.1
# ╔══════════════════════════════════════╗
# ║  QuickAiR — TestSuite.ps1            ║
# ║  Test runner. Auto-discovers and    ║
# ║  runs Tests\T*.ps1. Prints summary. ║
# ╠══════════════════════════════════════╣
# ║  Exports   : n/a (entry point)      ║
# ║  Inputs    : -JsonPath -HtmlPath    ║
# ║              -T3Threshold -DcMode   ║
# ║  Output    : console pass/fail      ║
# ║  Depends   : Tests\T*.ps1           ║
# ║  PS compat : 5.1                    ║
# ║  Version   : 2.0                    ║
# ╚══════════════════════════════════════╝
<#
.SYNOPSIS
    QuickAiR Test Suite - validates collected JSON output and Report.html
.DESCRIPTION
    Runs automated checks against the most recent collected JSON and Report.html.
    Auto-discovers test files in Tests\ directory.
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
    [string]$JsonPath    = "",
    [string]$HtmlPath    = "",
    [float]$T3Threshold  = 0.0,
    [switch]$DcMode
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

$SUITE_VERSION = "2.0"

Write-Host "================================" -ForegroundColor Cyan
Write-Host "QuickAiR Test Suite v$SUITE_VERSION" -ForegroundColor Cyan
Write-Host "================================" -ForegroundColor Cyan

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

$allResults = @()
$tests = Get-ChildItem "$scriptDir\Tests\T*.ps1" | Sort-Object Name

foreach ($t in $tests) {
    $tArgs = @{ JsonPath = $JsonPath; HtmlPath = $HtmlPath }
    if ($t.BaseName -eq 'T02_Network') { $tArgs['T3Threshold'] = $T3Threshold }
    try {
        $result = & $t.FullName @tArgs
        foreach ($r in $result.Passed) { $allResults += $r }
        foreach ($r in $result.Failed) { $allResults += $r }
        foreach ($r in $result.Info)   { $allResults += $r }
    } catch {
        $allResults += [PSCustomObject]@{Id=$t.BaseName;Pass=$false;InfoOnly=$false;Summary="Test file error: $($_.Exception.Message)";Details=@()}
    }
}

# DcMode inline
if ($DcMode) {
    $jsonRaw2 = [System.IO.File]::ReadAllText($JsonPath, [System.Text.Encoding]::UTF8)
    $data2    = $jsonRaw2 | ConvertFrom-Json
    $procs2   = @($data2.Processes)
    $netTcp2  = @($data2.Network.tcp)

    $dcFails = @()
    $dcWarn  = @()

    $dcPorts  = @(53, 88, 135, 389, 445, 636, 3268, 3269)
    $jsonPorts2 = @($netTcp2 | ForEach-Object { [int]$_.LocalPort }) | Sort-Object -Unique
    foreach ($port in $dcPorts) {
        if ($jsonPorts2 -notcontains $port) { $dcWarn += "WARN: DC port $port not found in network tcp" }
    }
    foreach ($port in @(53, 88, 389)) {
        if ($jsonPorts2 -notcontains $port) { $dcFails += "FAIL: Required DC port $port absent from network tcp" }
    }
    $hasLsass = $procs2 | Where-Object { $_.Name -match '^lsass\.exe$' }
    if (-not $hasLsass) { $dcFails += "FAIL: lsass.exe not in processes" }
    $hasDnsOrNtds = $procs2 | Where-Object { $_.Name -match '^(dns\.exe|ntds\.exe)$' }
    if (-not $hasDnsOrNtds) { $dcFails += "FAIL: dns.exe or ntds.exe not in processes" }

    if ($dcWarn.Count -gt 0) {
        Write-Host ""
        Write-Host "DC-SPECIFIC WARNINGS:" -ForegroundColor Yellow
        $dcWarn | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    }

    $dcPass = $dcFails.Count -eq 0
    $allResults += [PSCustomObject]@{Id="DC";Pass=$dcPass;InfoOnly=$false;Summary="DC sanity checks";Details=$dcFails}
}

# Print results
Write-Host ""
$passCount    = 0
$nonInfoCount = 0
foreach ($r in $allResults) {
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

    Write-Host ("{0} {1,-5} - {2}" -f $tag, $r.Id, $r.Summary) -ForegroundColor $color

    if (-not $r.Pass -and -not $r.InfoOnly -and $r.Details.Count -gt 0) {
        $show = $r.Details | Select-Object -First 25
        foreach ($d in $show) { Write-Host "        $d" -ForegroundColor DarkGray }
        if ($r.Details.Count -gt 25) {
            Write-Host "        ... ($($r.Details.Count - 25) more)" -ForegroundColor DarkGray
        }
    }
    if ($r.InfoOnly -and $r.Details.Count -gt 0) {
        foreach ($d in $r.Details) { Write-Host "        $d" -ForegroundColor DarkGray }
    }
}

Write-Host ""
Write-Host ("SUMMARY: {0}/{1} passed" -f $passCount, $nonInfoCount) -ForegroundColor White
Write-Host ""
$hasFails = $allResults | Where-Object { -not $_.Pass -and -not $_.InfoOnly }
if ($hasFails.Count -eq 0) {
    Write-Host "ALL TESTS PASSED" -ForegroundColor Green
} else {
    Write-Host "TESTS FAILED" -ForegroundColor Red
}
