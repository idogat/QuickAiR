#Requires -Version 5.1
# =============================================
#   QuickAiR -- T12_CollectUnit.ps1
#   T86 Parse-CollectURI empty array
#   T87 Parse-CollectURI single localhost target
#   T88 Parse-CollectURI malformed base64
#   T89 CSV contract: 3 valid hostnames
#   T90 CSV contract: 2 valid + 1 invalid
#   T91 Plugin subset encoding
# =============================================
#   Inputs    : -JsonPath -HtmlPath (unused, for suite compat)
#   Output    : @{ Passed=@();
#                Failed=@(); Info=@() }
#   PS compat : 5.1
# =============================================
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
    if ($IsInfo)   { $script:infoResults += $obj }
    elseif ($Pass) { $script:passResults += $obj }
    else           { $script:failResults += $obj }
}

$scriptDir       = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoDir         = Split-Path -Parent $scriptDir
$quickairCollect = Join-Path $repoDir 'QuickAiRCollect.ps1'

# ---------------------------------------------------------------
# Helper: encode targets array to quickair-collect:// URI
# Mirrors 09c_collect.js colCollect() -- btoa(JSON.stringify(targets))
# ---------------------------------------------------------------
function Build-CollectURI {
    param([array]$Targets)
    $json      = $Targets | ConvertTo-Json -Compress
    if ($Targets.Count -eq 1) { $json = "[$json]" }
    $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $b64       = [System.Convert]::ToBase64String($jsonBytes)
    $encoded   = [System.Uri]::EscapeDataString($b64)
    return "quickair-collect://collect?targets=$encoded"
}

# ---------------------------------------------------------------
# Extract Parse-CollectURI from QuickAiRCollect.ps1
# Strategy: same brace-depth technique as T10_Launcher.ps1
# ---------------------------------------------------------------
$parseLoaded = $false
$script:funcSrc86 = ''
try {
    if (-not (Test-Path $quickairCollect)) { throw "QuickAiRCollect.ps1 not found: $quickairCollect" }

    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop

    $rawBytes   = [System.IO.File]::ReadAllBytes($quickairCollect)
    $rawContent = [System.Text.Encoding]::UTF8.GetString($rawBytes)
    $allLines   = $rawContent -split '\r?\n'

    # Locate Parse-CollectURI
    $startIdx = -1
    for ($i = 0; $i -lt $allLines.Count; $i++) {
        if ($allLines[$i] -match '^\s*function\s+Parse-CollectURI\s*\{') {
            $startIdx = $i; break
        }
    }
    if ($startIdx -lt 0) { throw "function Parse-CollectURI not found in $quickairCollect" }

    $depth = 0; $endIdx = $startIdx
    for ($i = $startIdx; $i -lt $allLines.Count; $i++) {
        $line = $allLines[$i]
        if ($line -match '^([^#"'']*)(#.*)?$') { $bare = $Matches[1] } else { $bare = $line }
        foreach ($ch in $bare.ToCharArray()) {
            if ($ch -eq '{') { $depth++ }
            if ($ch -eq '}') { $depth--; if ($depth -eq 0) { $endIdx = $i; break } }
        }
        if ($depth -eq 0 -and $i -gt $startIdx) { $endIdx = $i; break }
    }

    $funcLines = $allLines[$startIdx..$endIdx]
    $funcText  = $funcLines -join "`n"
    $script:funcSrc86 = $funcText

    $sb = [scriptblock]::Create($funcText)
    . $sb
    $parseLoaded = $true
} catch {
    Add-R "T86" $false "Could not load Parse-CollectURI for testing" @($_.Exception.Message)
    Add-R "T87" $false "Could not load Parse-CollectURI for testing" @($_.Exception.Message)
    Add-R "T88" $false "Could not load Parse-CollectURI for testing" @($_.Exception.Message)
    Add-R "T89" $false "Could not load Parse-CollectURI for testing" @($_.Exception.Message)
    Add-R "T90" $false "Could not load Parse-CollectURI for testing" @($_.Exception.Message)
    Add-R "T91" $false "Could not load Parse-CollectURI for testing" @($_.Exception.Message)
}

if ($parseLoaded) {

    # ---------------------------------------------------------------
    # T86 -- Parse-CollectURI with empty array (T-C1)
    # URI: quickair-collect://collect?targets=<base64 of "[]">
    # Expect: returns @(), no exception, no crash
    # ---------------------------------------------------------------
    try {
        $emptyJson  = '[]'
        $emptyBytes = [System.Text.Encoding]::UTF8.GetBytes($emptyJson)
        $emptyB64   = [System.Convert]::ToBase64String($emptyBytes)
        $uri86      = "quickair-collect://collect?targets=$emptyB64"

        $result86 = @(Parse-CollectURI -URI $uri86)
        $t86d = @()

        if ($result86.Count -ne 0) {
            $t86d += "Expected 0 targets from empty array, got $($result86.Count)"
        }

        if ($t86d.Count -eq 0) {
            Add-R "T86" $true "Parse-CollectURI empty array: returns 0 targets, no crash"
        } else {
            Add-R "T86" $false "Parse-CollectURI empty array failures" $t86d
        }
    } catch {
        Add-R "T86" $false "T86 threw exception" @($_.Exception.Message)
    }

    # ---------------------------------------------------------------
    # T87 -- Parse-CollectURI single localhost target (T-C2)
    # Build URI with localhost + all 4 plugins
    # Expect: 1 target returned, hostname=localhost
    # ---------------------------------------------------------------
    try {
        $targets87 = @(
            [ordered]@{
                hostname   = 'localhost'
                outputPath = '.\DFIROutput\'
                plugins    = @('Processes','Network','DLLs','Users')
            }
        )
        $uri87 = Build-CollectURI -Targets $targets87

        $result87 = @(Parse-CollectURI -URI $uri87)
        $t87d = @()

        if ($result87.Count -ne 1) {
            $t87d += "Expected 1 target, got $($result87.Count)"
        } else {
            if ($result87[0].hostname -ne 'localhost') {
                $t87d += "hostname mismatch: expected 'localhost', got '$($result87[0].hostname)'"
            }
        }

        if ($t87d.Count -eq 0) {
            Add-R "T87" $true "Parse-CollectURI single target: localhost returned correctly"
        } else {
            Add-R "T87" $false "Parse-CollectURI single target failures" $t87d
        }
    } catch {
        Add-R "T87" $false "T87 threw exception" @($_.Exception.Message)
    }

    # ---------------------------------------------------------------
    # T88 -- Parse-CollectURI malformed base64 (T-C3)
    # Parse-CollectURI calls MessageBox + exit 1 on bad input.
    # Cannot call directly -- verify catch structure + .NET throw.
    # ---------------------------------------------------------------
    try {
        $t88d = @()
        $funcSrc = $script:funcSrc86

        if ($funcSrc -notmatch '(?s)try\s*\{') {
            $t88d += "Parse-CollectURI does not contain a try block"
        }
        if ($funcSrc -notmatch '(?s)catch\s*\{') {
            $t88d += "Parse-CollectURI does not contain a catch block"
        }
        if ($funcSrc -notmatch 'Write-Warning') {
            $t88d += "Catch block does not call Write-Warning"
        }
        if ($funcSrc -notmatch 'MessageBox') {
            $t88d += "Catch block does not show MessageBox error dialog"
        }
        if ($funcSrc -notmatch 'exit\s+1') {
            $t88d += "Catch block does not call exit 1"
        }

        # Verify malformed base64 throws at .NET level
        $b64Threw = $false
        try {
            [System.Convert]::FromBase64String('NOT!VALID==BASE64!!') | Out-Null
        } catch {
            $b64Threw = $true
        }
        if (-not $b64Threw) { $t88d += "Invalid base64 did not throw (unexpected)" }

        if ($t88d.Count -eq 0) {
            Add-R "T88" $true "Parse-CollectURI malformed: catch block has MessageBox+exit, malformed base64 throws .NET exception"
        } else {
            Add-R "T88" $false "Parse-CollectURI malformed input check failures" $t88d
        }
    } catch {
        Add-R "T88" $false "T88 threw exception" @($_.Exception.Message)
    }

    # ---------------------------------------------------------------
    # T89 -- CSV contract: 3 valid hostnames (T-C4)
    # Mirrors the encoding that 09c_collect.js produces from a 3-line CSV.
    # Parse-CollectURI should return all 3.
    # ---------------------------------------------------------------
    try {
        $targets89 = @(
            [ordered]@{ hostname = 'host-alpha';   outputPath = '.\DFIROutput\' },
            [ordered]@{ hostname = 'host-bravo';   outputPath = '.\DFIROutput\' },
            [ordered]@{ hostname = 'host-charlie'; outputPath = '.\DFIROutput\' }
        )
        $uri89 = Build-CollectURI -Targets $targets89

        $result89 = @(Parse-CollectURI -URI $uri89)
        $t89d = @()

        if ($result89.Count -ne 3) {
            $t89d += "Expected 3 targets, got $($result89.Count)"
        } else {
            $expected = @('host-alpha','host-bravo','host-charlie')
            for ($i = 0; $i -lt 3; $i++) {
                if ($result89[$i].hostname -ne $expected[$i]) {
                    $t89d += "Target $i hostname mismatch: expected '$($expected[$i])', got '$($result89[$i].hostname)'"
                }
            }
        }

        if ($t89d.Count -eq 0) {
            Add-R "T89" $true "CSV contract valid: 3 hostnames encoded and parsed correctly"
        } else {
            Add-R "T89" $false "CSV contract valid failures" $t89d
        }
    } catch {
        Add-R "T89" $false "T89 threw exception" @($_.Exception.Message)
    }

    # ---------------------------------------------------------------
    # T90 -- CSV contract: 2 valid + 1 invalid hostname (T-C5)
    # Invalid hostname has space -- rejected by regex '^[\w][\w\.\-]{0,253}$'
    # Expect: 2 returned, 1 skipped
    # ---------------------------------------------------------------
    try {
        $targets90 = @(
            [ordered]@{ hostname = 'host-valid-1';     outputPath = '.\DFIROutput\' },
            [ordered]@{ hostname = 'host with space';  outputPath = '.\DFIROutput\' },
            [ordered]@{ hostname = 'host-valid-2';     outputPath = '.\DFIROutput\' }
        )
        $uri90 = Build-CollectURI -Targets $targets90

        $result90 = @(Parse-CollectURI -URI $uri90)
        $t90d = @()

        if ($result90.Count -ne 2) {
            $t90d += "Expected 2 valid targets (1 invalid skipped), got $($result90.Count)"
        } else {
            if ($result90[0].hostname -ne 'host-valid-1') {
                $t90d += "First valid target mismatch: expected 'host-valid-1', got '$($result90[0].hostname)'"
            }
            if ($result90[1].hostname -ne 'host-valid-2') {
                $t90d += "Second valid target mismatch: expected 'host-valid-2', got '$($result90[1].hostname)'"
            }
        }

        if ($t90d.Count -eq 0) {
            Add-R "T90" $true "CSV contract mixed: 2 valid imported, 1 invalid (space in hostname) skipped"
        } else {
            Add-R "T90" $false "CSV contract mixed failures" $t90d
        }
    } catch {
        Add-R "T90" $false "T90 threw exception" @($_.Exception.Message)
    }

    # ---------------------------------------------------------------
    # T91 -- Plugin subset: encode only Processes+Network (T-C6)
    # Uncheck DLLs and Users → plugins array excludes them.
    # Parse-CollectURI returns raw targets; Add-Targets filters
    # plugins against $ALL_PLUGINS. Test both: raw parse preserves
    # the plugins array, and filtering logic works.
    # ---------------------------------------------------------------
    try {
        $targets91 = @(
            [ordered]@{
                hostname   = 'localhost'
                outputPath = '.\DFIROutput\'
                plugins    = @('Processes','Network')
            }
        )
        $uri91 = Build-CollectURI -Targets $targets91

        $result91 = @(Parse-CollectURI -URI $uri91)
        $t91d = @()

        if ($result91.Count -ne 1) {
            $t91d += "Expected 1 target, got $($result91.Count)"
        } else {
            $raw = $result91[0]

            # Check raw plugins array preserved from URI
            $rawPlugins = @($raw.plugins)
            if ($rawPlugins.Count -ne 2) {
                $t91d += "Expected 2 plugins in raw parse, got $($rawPlugins.Count)"
            }
            if ('Processes' -notin $rawPlugins) { $t91d += "Processes missing from raw plugins" }
            if ('Network'   -notin $rawPlugins) { $t91d += "Network missing from raw plugins" }
            if ('DLLs'      -in    $rawPlugins) { $t91d += "DLLs should NOT be in plugins" }
            if ('Users'     -in    $rawPlugins) { $t91d += "Users should NOT be in plugins" }

            # Simulate Add-Targets plugin filtering (line 184-186 of QuickAiRCollect.ps1)
            $ALL_PLUGINS = @('DLLs','Network','Processes','Users')
            $filtered = @($raw.plugins | ForEach-Object { [string]$_ }) | Where-Object { $_ -in $ALL_PLUGINS }
            if ($filtered.Count -ne 2) {
                $t91d += "Plugin filter should yield 2, got $($filtered.Count)"
            }
            if ('DLLs'  -in $filtered) { $t91d += "DLLs should not survive filter" }
            if ('Users' -in $filtered) { $t91d += "Users should not survive filter" }
        }

        if ($t91d.Count -eq 0) {
            Add-R "T91" $true "Plugin subset: Processes+Network encoded, DLLs+Users excluded, filter correct"
        } else {
            Add-R "T91" $false "Plugin subset failures" $t91d
        }
    } catch {
        Add-R "T91" $false "T91 threw exception" @($_.Exception.Message)
    }
}

# ---------------------------------------------------------------
return @{
    Passed = $script:passResults
    Failed = $script:failResults
    Info   = $script:infoResults
}
