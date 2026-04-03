#
# QuickAiR -- Register-QuickAiRProtocol.ps1
# Registers (or removes) two URI schemes in HKCU:
#   quickair://          -> QuickAiRLaunch.ps1   (tool execution)
#   quickair-collect://  -> QuickAiRCollect.ps1  (artifact collection)
#
# Parameters : -Unregister switch (default: register)
# Run once   : as Administrator on the analyst machine
# Version    : 1.1
#

[CmdletBinding()]
param(
    [switch]$Unregister
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# Admin check
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator."
    exit 1
}

$ROOT            = 'HKCU:\SOFTWARE\Classes\quickair'
$CMD_KEY         = "$ROOT\shell\open\command"
$ROOT_COLLECT    = 'HKCU:\SOFTWARE\Classes\quickair-collect'
$CMD_KEY_COLLECT = "$ROOT_COLLECT\shell\open\command"

if ($Unregister) {
    $removed = 0
    if (Test-Path $ROOT) {
        Remove-Item -Path $ROOT -Recurse -Force
        Write-Host "quickair:// protocol unregistered"
        $removed++
    }
    if (Test-Path $ROOT_COLLECT) {
        Remove-Item -Path $ROOT_COLLECT -Recurse -Force
        Write-Host "quickair-collect:// protocol unregistered"
        $removed++
    }
    if ($removed -eq 0) {
        Write-Host "No QuickAiR protocols were registered -- nothing to remove"
    }
}
else {
    $registeredKeys = @()
    try {
    # ── quickair:// → QuickAiRLaunch.ps1 ─────────────────────
    $launchScript = Join-Path $PSScriptRoot 'QuickAiRLaunch.ps1'
    $cmd = 'powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $launchScript + '" -URI "%1"'

    if (-not (Test-Path $ROOT)) {
        New-Item -Path $ROOT -Force -ErrorAction Stop | Out-Null
    }
    $registeredKeys += $ROOT
    Set-ItemProperty -Path $ROOT -Name '(Default)'    -Value 'URL:QuickAiR DFIR Launcher' -ErrorAction Stop
    New-ItemProperty -Path $ROOT -Name 'URL Protocol'  -Value '' -PropertyType String -Force -ErrorAction Stop | Out-Null

    if (-not (Test-Path $CMD_KEY)) {
        New-Item -Path $CMD_KEY -Force -ErrorAction Stop | Out-Null
    }
    $registeredKeys += $CMD_KEY
    Set-ItemProperty -Path $CMD_KEY -Name '(Default)' -Value $cmd -ErrorAction Stop

    # ── quickair-collect:// → QuickAiRCollect.ps1 ────────────
    $collectScript = Join-Path $PSScriptRoot 'QuickAiRCollect.ps1'
    $cmdCollect = 'powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $collectScript + '" -URI "%1"'

    if (-not (Test-Path $ROOT_COLLECT)) {
        New-Item -Path $ROOT_COLLECT -Force -ErrorAction Stop | Out-Null
    }
    $registeredKeys += $ROOT_COLLECT
    Set-ItemProperty -Path $ROOT_COLLECT -Name '(Default)'    -Value 'URL:QuickAiR DFIR Collector' -ErrorAction Stop
    New-ItemProperty -Path $ROOT_COLLECT -Name 'URL Protocol'  -Value '' -PropertyType String -Force -ErrorAction Stop | Out-Null

    if (-not (Test-Path $CMD_KEY_COLLECT)) {
        New-Item -Path $CMD_KEY_COLLECT -Force -ErrorAction Stop | Out-Null
    }
    $registeredKeys += $CMD_KEY_COLLECT
    Set-ItemProperty -Path $CMD_KEY_COLLECT -Name '(Default)' -Value $cmdCollect -ErrorAction Stop

    } catch {
        Write-Error "Protocol registration failed: $($_.Exception.Message). Rolling back..."
        foreach ($key in $registeredKeys) {
            Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue
        }
        exit 1
    }

    # ── Verify both ──────────────────────────────────────────
    $ok = (Test-Path $ROOT) -and (Test-Path $CMD_KEY) -and
          (Test-Path $ROOT_COLLECT) -and (Test-Path $CMD_KEY_COLLECT)
    if (-not $ok) {
        Write-Error "Registry verification failed -- keys not found after write."
        exit 1
    }

    $storedCmd = (Get-ItemProperty -Path $CMD_KEY -Name '(Default)').'(Default)'
    if ($storedCmd -notlike "*QuickAiRLaunch.ps1*") {
        Write-Error "Registry verification failed -- launch command unexpected: $storedCmd"
        exit 1
    }

    $storedCmdCollect = (Get-ItemProperty -Path $CMD_KEY_COLLECT -Name '(Default)').'(Default)'
    if ($storedCmdCollect -notlike "*QuickAiRCollect.ps1*") {
        Write-Error "Registry verification failed -- collect command unexpected: $storedCmdCollect"
        exit 1
    }

    Write-Host "quickair:// protocol registered         -> QuickAiRLaunch.ps1"
    Write-Host "quickair-collect:// protocol registered  -> QuickAiRCollect.ps1"
    Write-Host "Test with: Start-Process quickair://test"
    Write-Host "Test with: Start-Process 'quickair-collect://collect?targets=dGVzdA=='"
}
