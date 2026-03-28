#
# QuickAiR -- Register-QuickAiRProtocol.ps1
# Registers (or removes) the quickair:// URI scheme in HKCU
# so browsers can invoke QuickAiRLaunch.ps1.
#
# Parameters : -Unregister switch (default: register)
# Run once   : as Administrator on the analyst machine
# Version    : 1.0
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

$ROOT    = 'HKCU:\SOFTWARE\Classes\quickair'
$CMD_KEY = "$ROOT\shell\open\command"

if ($Unregister) {
    if (Test-Path $ROOT) {
        Remove-Item -Path $ROOT -Recurse -Force
        Write-Host "quickair:// protocol unregistered"
    }
    else {
        Write-Host "quickair:// was not registered -- nothing to remove"
    }
}
else {
    $launchScript = Join-Path $PSScriptRoot 'QuickAiRLaunch.ps1'
    $cmd = 'powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $launchScript + '" -URI "%1"'

    if (-not (Test-Path $ROOT)) {
        New-Item -Path $ROOT -Force | Out-Null
    }
    Set-ItemProperty -Path $ROOT -Name '(Default)'    -Value 'URL:QuickAiR DFIR Launcher'
    New-ItemProperty -Path $ROOT -Name 'URL Protocol'  -Value '' -PropertyType String -Force | Out-Null

    if (-not (Test-Path $CMD_KEY)) {
        New-Item -Path $CMD_KEY -Force | Out-Null
    }
    Set-ItemProperty -Path $CMD_KEY -Name '(Default)' -Value $cmd

    # Verify
    $ok = (Test-Path $ROOT) -and (Test-Path $CMD_KEY)
    if (-not $ok) {
        Write-Error "Registry verification failed -- keys not found after write."
        exit 1
    }

    $storedCmd = (Get-ItemProperty -Path $CMD_KEY -Name '(Default)').'(Default)'
    if ($storedCmd -notlike "*QuickAiRLaunch.ps1*") {
        Write-Error "Registry verification failed -- command value unexpected: $storedCmd"
        exit 1
    }

    Write-Host "quickair:// protocol registered"
    Write-Host "Test with: Start-Process quickair://test"
}
