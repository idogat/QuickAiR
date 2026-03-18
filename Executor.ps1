#Requires -Version 5.1
# ╔══════════════════════════════════════╗
# ║  Quicker — Executor.ps1             ║
# ║  Thin orchestrator. Transfers and   ║
# ║  launches a tool on a remote target ║
# ║  via WinRM or WMI.                  ║
# ╠══════════════════════════════════════╣
# ║  Exports   : n/a (entry point)      ║
# ║  Inputs    : -Target                ║
# ║              -LocalBinaryPath       ║
# ║              -RemoteDestPath        ║
# ║              -Arguments             ║
# ║              -Credential            ║
# ║              -Method                ║
# ║              -AliveCheck            ║
# ║              -OutputPath            ║
# ║              -Help                  ║
# ║  Output    : <hostname>_execution_  ║
# ║              <ts>.json              ║
# ║  Depends   : Executors\WinRM.psm1  ║
# ║              Executors\WMI.psm1    ║
# ║  PS compat : 5.1 (analyst machine)  ║
# ║  Version   : 1.0                    ║
# ╚══════════════════════════════════════╝

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)] [string]$Target          = "",
    [Parameter(Mandatory=$false)] [string]$LocalBinaryPath = "",
    [Parameter(Mandatory=$false)] [string]$RemoteDestPath  = "",
    [Parameter(Mandatory=$false)] [string]$Arguments       = "",
    [Parameter(Mandatory=$false)] [System.Management.Automation.PSCredential]$Credential,
    [Parameter(Mandatory=$false)] [ValidateSet("Auto","WinRM","WMI")] [string]$Method = "Auto",
    [Parameter(Mandatory=$false)] [int]$AliveCheck         = 10,
    [Parameter(Mandatory=$false)] [string]$OutputPath      = "",
    [Parameter(Mandatory=$false)] [switch]$Help
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

$EXECUTOR_VERSION = "1.0"

#region --- Help ---
if ($Help) {
    Write-Host ""
    Write-Host "════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Quicker — Executor.ps1 v$EXECUTOR_VERSION" -ForegroundColor Cyan
    Write-Host "  Remote Tool Launcher" -ForegroundColor Cyan
    Write-Host "════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "DESCRIPTION" -ForegroundColor Yellow
    Write-Host "  Transfers a binary to a remote Windows target and launches"
    Write-Host "  it, then confirms execution started. One target at a time."
    Write-Host "  Writes a JSON result to OutputPath."
    Write-Host ""
    Write-Host "PARAMETERS" -ForegroundColor Yellow
    Write-Host "  -Target           Hostname or IP address of remote target (required)"
    Write-Host "  -LocalBinaryPath  Path to tool on analyst machine (required)"
    Write-Host "  -RemoteDestPath   Destination path on target"
    Write-Host "                    Default: C:\Windows\Temp\<binary filename>"
    Write-Host "  -Arguments        Arguments to pass to the tool"
    Write-Host "  -Credential       PSCredential for remote auth"
    Write-Host "                    Prompted if not supplied and target is not localhost"
    Write-Host "  -Method           Auto | WinRM | WMI  (default: Auto)"
    Write-Host "                    Auto tries WinRM first, falls back to WMI"
    Write-Host "  -AliveCheck       Seconds to wait before alive check (default: 10)"
    Write-Host "  -OutputPath       Folder for result JSON (default: .\ExecutionResults\)"
    Write-Host "  -Help             Show this help"
    Write-Host ""
    Write-Host "EXAMPLES" -ForegroundColor Yellow
    Write-Host "  .\Executor.ps1 -Target 192.168.1.250 -LocalBinaryPath C:\Tools\tool.exe"
    Write-Host "  .\Executor.ps1 -Target 192.168.1.100 -LocalBinaryPath C:\Tools\tool.exe \"
    Write-Host "    -Method WinRM -AliveCheck 15 -Arguments '-scan'"
    Write-Host "  .\Executor.ps1 -Target localhost -LocalBinaryPath C:\Windows\System32\notepad.exe"
    Write-Host ""
    Write-Host "STATES" -ForegroundColor Yellow
    Write-Host "  State               Meaning"
    Write-Host "  ─────────────────   ──────────────────────────────────────────────"
    Write-Host "  CONNECTION_FAILED   Could not reach target or binary not found locally"
    Write-Host "  TRANSFERRED         Binary copied to target and SHA256 verified"
    Write-Host "  TRANSFER_FAILED     Binary copy or SHA256 check failed"
    Write-Host "  LAUNCHED            Process started; PID captured"
    Write-Host "  LAUNCH_FAILED       Process did not start or exited before alive check"
    Write-Host "  ALIVE               Process still running after AliveCheck seconds"
    Write-Host ""
    exit 0
}
#endregion

#region --- Resolve OutputPath ---
if (-not $OutputPath) {
    $OutputPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "ExecutionResults"
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
#endregion

#region --- Helper: UTC timestamp prefix ---
function Write-Ts {
    param([string]$Message, [string]$Color = "White")
    $ts = [System.DateTime]::UtcNow.ToString("yyyy-MM-dd HH:mm:ss")
    Write-Host "[$ts UTC] $Message" -ForegroundColor $Color
}
#endregion

#region --- Admin check ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Executor.ps1 requires Administrator. Please restart as Administrator." -ForegroundColor Red
    exit 1
}
#endregion

Write-Ts "Quicker Executor v$EXECUTOR_VERSION starting" "Cyan"

#region --- Interactive prompts for required params ---
if (-not $Target) {
    $Target = Read-Host "Enter target hostname or IP (e.g. 192.168.1.250)"
}
$Target = $Target.Trim()

if (-not $LocalBinaryPath) {
    do {
        $LocalBinaryPath = (Read-Host "Enter full path to local binary (e.g. C:\Tools\tool.exe)").Trim()
        if (-not (Test-Path -LiteralPath $LocalBinaryPath)) {
            Write-Host "  File not found: $LocalBinaryPath" -ForegroundColor Red
            $LocalBinaryPath = ""
        }
    } while (-not $LocalBinaryPath)
}

$isLocal = ($Target -eq 'localhost' -or $Target -eq '127.0.0.1' -or
            $Target -ieq $env:COMPUTERNAME)

if (-not $isLocal -and -not $Credential) {
    Write-Host "Enter credentials for $Target" -ForegroundColor Cyan
    try { $Credential = Get-Credential -Message "Credentials for $Target" -ErrorAction Stop }
    catch { $Credential = $null }
}
#endregion

#region --- Default RemoteDestPath ---
if (-not $RemoteDestPath) {
    $binaryName    = [System.IO.Path]::GetFileName($LocalBinaryPath)
    $RemoteDestPath = "C:\Windows\Temp\$binaryName"
}
#endregion

#region --- Resolve hostname for output filename ---
$outHost = $Target
try {
    if ($Target -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
        $resolved = [System.Net.Dns]::GetHostEntry($Target).HostName
        if ($resolved) { $outHost = $resolved }
    }
} catch { }
$outHost = $outHost -replace '[\\/:*?"<>|]', '_'
#endregion

#region --- Ensure OutputPath exists ---
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}
#endregion

Write-Ts "Target        : $Target" "Cyan"
Write-Ts "LocalBinary   : $LocalBinaryPath" "Cyan"
Write-Ts "RemoteDest    : $RemoteDestPath" "Cyan"
Write-Ts "Method        : $Method" "Cyan"
Write-Ts "AliveCheck    : ${AliveCheck}s" "Cyan"

#region --- Execute ---
$executorDir = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "Modules\Executors"

$execParams = @{
    ComputerName       = $Target
    Credential         = $Credential
    LocalBinaryPath    = $LocalBinaryPath
    RemoteDestPath     = $RemoteDestPath
    Arguments          = $Arguments
    AliveCheckSeconds  = $AliveCheck
}

$result = $null

if ($Method -eq "WinRM" -or $Method -eq "Auto") {
    Write-Ts "Trying WinRM..." "Cyan"
    Import-Module "$executorDir\WinRM.psm1" -Force
    $result = Invoke-Executor @execParams

    foreach ($s in $result.States) {
        $icon = if ($s.State -match 'FAILED') { "[x]" } else { "[v]" }
        $col  = if ($s.State -match 'FAILED') { "Red" } else { "Green" }
        Write-Ts "$icon $($s.State)  $($s.Detail)" $col
    }

    if ($Method -eq "Auto" -and $result.FinalState -eq "CONNECTION_FAILED") {
        Write-Ts "WinRM CONNECTION_FAILED — falling back to WMI" "Yellow"
        Import-Module "$executorDir\WMI.psm1" -Force
        $result = Invoke-Executor @execParams

        foreach ($s in $result.States) {
            $icon = if ($s.State -match 'FAILED') { "[x]" } else { "[v]" }
            $col  = if ($s.State -match 'FAILED') { "Red" } else { "Green" }
            Write-Ts "$icon $($s.State)  $($s.Detail)" $col
        }
    }
}
elseif ($Method -eq "WMI") {
    Write-Ts "Using WMI..." "Cyan"
    Import-Module "$executorDir\WMI.psm1" -Force
    $result = Invoke-Executor @execParams

    foreach ($s in $result.States) {
        $icon = if ($s.State -match 'FAILED') { "[x]" } else { "[v]" }
        $col  = if ($s.State -match 'FAILED') { "Red" } else { "Green" }
        Write-Ts "$icon $($s.State)  $($s.Detail)" $col
    }
}
#endregion

#region --- Build and write result JSON ---
$ts        = [System.DateTime]::UtcNow.ToString("yyyyMMdd_HHmmss")
$jsonFile  = Join-Path $OutputPath "${outHost}_execution_${ts}.json"

$fullResult = [ordered]@{
    ExecutorVersion = $EXECUTOR_VERSION
    AnalystMachine  = $env:COMPUTERNAME
}
# Merge result fields
foreach ($k in $result.PSObject.Properties.Name) {
    $fullResult[$k] = $result.$k
}

$jsonText = $fullResult | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($jsonFile, $jsonText, [System.Text.Encoding]::UTF8)

$finalIcon = if ($result.FinalState -match 'FAILED') { "[x]" } else { "[v]" }
$finalCol  = if ($result.FinalState -match 'FAILED') { "Red" } else { "Green" }
Write-Ts "$finalIcon Final state: $($result.FinalState)" $finalCol
Write-Ts "Result JSON: $jsonFile" "White"
#endregion
