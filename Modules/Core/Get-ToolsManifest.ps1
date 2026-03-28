#Requires -Version 5.1
# ===========================================
# QuickAiR - Get-ToolsManifest.ps1
# Scans C:\DFIRLab\tools\ for executables,
# categorizes each, writes tools.json
# manifest for the HTML UI.
# -------------------------------------------
# Exports   : n/a (standalone script)
# Inputs    : none
# Output    : <repo-root>\tools.json + C:\DFIRLab\tools\tools.json
# Depends   : none
# PS compat : 5.1 (analyst machine)
# Version   : 1.1
# ===========================================

$toolsDir = 'C:\DFIRLab\tools'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$outFile  = Join-Path $repoRoot 'tools.json'

if (-not (Test-Path $toolsDir -PathType Container)) {
    Write-Verbose "Get-ToolsManifest: tools folder not found ($toolsDir) - skipping"
    return
}

function Get-ToolCategory {
    param([string]$filename)
    $name = [System.IO.Path]::GetFileNameWithoutExtension($filename).ToLower()

    # DumpIt handles both memory and disk acquisition
    if ($name -match 'dumpit') { return 'memory+disk' }

    # Memory-only tools
    if ($name -match 'winpmem|magnet|rammap|belkasoft') { return 'memory' }

    # Disk-only tools
    if ($name -eq 'dd' -or $name -eq 'dcfldd') { return 'disk' }
    if ($name -match 'ftk|guymager|paladin') { return 'disk' }

    return 'custom'
}

$exes = Get-ChildItem -Path $toolsDir -File |
    Where-Object { $_.Extension -match '^\.(exe|ps1|bat|cmd)$' } |
    Sort-Object Name

$tools = @(
    $exes | ForEach-Object {
        $cat = Get-ToolCategory $_.Name
        [ordered]@{
            filename    = $_.Name
            path        = $_.FullName
            category    = $cat
            displayName = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
        }
    }
)

$manifest = [ordered]@{
    generated = (Get-Date).ToUniversalTime().ToString("o")
    tools     = $tools
}

$json = $manifest | ConvertTo-Json -Depth 4
[System.IO.File]::WriteAllText($outFile, $json, [System.Text.Encoding]::UTF8)
# Also write to tools dir for backward compat
$toolsCopy = Join-Path $toolsDir 'tools.json'
[System.IO.File]::WriteAllText($toolsCopy, $json, [System.Text.Encoding]::UTF8)
Write-Host "Get-ToolsManifest: wrote $($tools.Count) tool(s) to $outFile"
