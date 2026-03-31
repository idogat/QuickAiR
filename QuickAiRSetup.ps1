#
# QuickAiR — QuickAiRSetup.ps1
# One-time protocol registration. Double-click to run.
# Registers quickair:// and quickair-collect:// URI handlers.
# Ships with the tool — no download needed. Re-runnable.
# Version : 1.0
#

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms

# Verify scripts exist in same folder
$launch  = Join-Path $PSScriptRoot 'QuickAiRLaunch.ps1'
$collect = Join-Path $PSScriptRoot 'QuickAiRCollect.ps1'

if (-not (Test-Path $launch) -or -not (Test-Path $collect)) {
    [System.Windows.Forms.MessageBox]::Show(
        "QuickAiRSetup.ps1 must be in the same folder as QuickAiRLaunch.ps1 and QuickAiRCollect.ps1.`n`nMove it to the QuickAiR folder and try again.",
        'QuickAiR Setup', 'OK', 'Error') | Out-Null
    exit 1
}

# Register protocols
$entries = @(
    @{ Root = 'HKCU:\SOFTWARE\Classes\quickair';         Label = 'URL:QuickAiR DFIR Launcher';  Script = $launch  },
    @{ Root = 'HKCU:\SOFTWARE\Classes\quickair-collect';  Label = 'URL:QuickAiR DFIR Collector'; Script = $collect }
)
foreach ($e in $entries) {
    $cmdKey = "$($e.Root)\shell\open\command"
    if (-not (Test-Path $e.Root))  { New-Item -Path $e.Root  -Force | Out-Null }
    if (-not (Test-Path $cmdKey))  { New-Item -Path $cmdKey  -Force | Out-Null }
    Set-ItemProperty  -Path $e.Root -Name '(Default)'    -Value $e.Label
    New-ItemProperty  -Path $e.Root -Name 'URL Protocol' -Value '' -PropertyType String -Force | Out-Null
    $cmd = 'powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $e.Script + '" -URI "%1"'
    Set-ItemProperty  -Path $cmdKey -Name '(Default)' -Value $cmd
}

# Verify
$ok = (Test-Path 'HKCU:\SOFTWARE\Classes\quickair\shell\open\command') -and
      (Test-Path 'HKCU:\SOFTWARE\Classes\quickair-collect\shell\open\command')
if ($ok) {
    [System.Windows.Forms.MessageBox]::Show(
        "QuickAiR setup complete.`n`nOpen Report.html to begin.",
        'QuickAiR Setup', 'OK', 'Information') | Out-Null
} else {
    [System.Windows.Forms.MessageBox]::Show(
        "Setup failed — registry keys not created.`nTry right-clicking and selecting Run as Administrator.",
        'QuickAiR Setup', 'OK', 'Error') | Out-Null
}
