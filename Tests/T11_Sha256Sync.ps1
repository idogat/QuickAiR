#Requires -Version 5.1
# ╔══════════════════════════════════════╗
# ║  QuickAiR — T11_Sha256Sync.ps1      ║
# ║  Verify _sha256 function bodies     ║
# ║  are identical across all copies    ║
# ╠══════════════════════════════════════╣
# ║  Inputs    : none (reads source)    ║
# ║  Output    : @{ Passed=@();         ║
# ║               Failed=@(); Info=@() }║
# ║  PS compat : 5.1                    ║
# ║  Version   : 1.0                    ║
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

# ── T11: _sha256 function body sync ──────────────────────
$srcPath = Join-Path $PSScriptRoot '..\Modules\Collectors\Processes.psm1'
if (-not (Test-Path $srcPath)) {
    Add-R 'T11' $false 'Processes.psm1 not found'
} else {
    $src = Get-Content $srcPath -Raw

    # Extract all _sha256 function bodies by finding balanced braces
    # Split source on the function signature, then extract body from each occurrence
    $parts = $src -split 'function _sha256\(\$p\)\s*\{'
    # First element is before any _sha256, remaining are bodies + trailing code
    $bodies = @()
    for ($j = 1; $j -lt $parts.Count; $j++) {
        # Find the matching closing brace by counting brace depth
        $depth = 1; $pos = 0
        while ($depth -gt 0 -and $pos -lt $parts[$j].Length) {
            if ($parts[$j][$pos] -eq '{') { $depth++ }
            elseif ($parts[$j][$pos] -eq '}') { $depth-- }
            $pos++
        }
        $body = $parts[$j].Substring(0, $pos - 1).Trim() -replace '\s+', ' '
        $bodies += $body
    }

    if ($bodies.Count -lt 3) {
        Add-R 'T11' $false "_sha256 found $($bodies.Count) copies, expected 3" @("Found copies: $($bodies.Count)")
    } else {

        $allMatch = $true
        $diffs = @()
        for ($i = 1; $i -lt $bodies.Count; $i++) {
            if ($bodies[$i] -ne $bodies[0]) {
                $allMatch = $false
                $diffs += "Copy $($i+1) differs from copy 1"
            }
        }

        if ($allMatch) {
            Add-R 'T11' $true "_sha256 function: all $($bodies.Count) copies are identical"
        } else {
            Add-R 'T11' $false "_sha256 function bodies have diverged" $diffs
        }
    }
}

return @{ Passed=$script:passResults; Failed=$script:failResults; Info=$script:infoResults }
