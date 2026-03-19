#
# Quicker -- Register-QuickerProtocol.ps1
# Registers (or removes) the quicker:// URI scheme in HKCU
# so browsers can invoke QuickerLaunch.ps1.
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

$ROOT    = 'HKCU:\SOFTWARE\Classes\quicker'
$CMD_KEY = "$ROOT\shell\open\command"

if ($Unregister) {
    if (Test-Path $ROOT) {
        Remove-Item -Path $ROOT -Recurse -Force
        Write-Host "quicker:// protocol unregistered"
    }
    else {
        Write-Host "quicker:// was not registered -- nothing to remove"
    }
}
else {
    $launchScript = Join-Path $PSScriptRoot 'QuickerLaunch.ps1'
    $cmd = 'powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $launchScript + '" -URI "%1"'

    if (-not (Test-Path $ROOT)) {
        New-Item -Path $ROOT -Force | Out-Null
    }
    Set-ItemProperty -Path $ROOT -Name '(Default)'    -Value 'URL:Quicker DFIR Launcher'
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
    if ($storedCmd -notlike "*QuickerLaunch.ps1*") {
        Write-Error "Registry verification failed -- command value unexpected: $storedCmd"
        exit 1
    }

    Write-Host "quicker:// protocol registered"
    Write-Host "Test with: Start-Process quicker://test"
}
