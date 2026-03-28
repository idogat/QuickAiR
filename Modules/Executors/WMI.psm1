#Requires -Version 2.0
# ╔══════════════════════════════════════╗
# ║  QuickAiR — WMI.psm1                 ║
# ║  Remote executor via WMI only.      ║
# ║  No file transfer — binary must     ║
# ║  already exist on target.           ║
# ╠══════════════════════════════════════╣
# ║  Exports   : Invoke-Executor        ║
# ║  Inputs    : ComputerName           ║
# ║              Credential             ║
# ║              LocalBinaryPath        ║
# ║              RemoteDestPath         ║
# ║              Arguments              ║
# ║              AliveCheckSeconds      ║
# ║  Output    : result object          ║
# ║  Depends   : none                   ║
# ║  PS compat : 2.0+ (analyst machine) ║
# ║  Version   : 1.1                    ║
# ╚══════════════════════════════════════╝

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# Load Output.psm1 for Get-BinaryType / Write-Log
$_outputMod = Join-Path (Split-Path -Parent $PSScriptRoot) "Core\Output.psm1"
if (-not $PSScriptRoot) {
    $_outputMod = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "..\Core\Output.psm1"
}
if (Test-Path $_outputMod) {
    Import-Module $_outputMod -Force -ErrorAction SilentlyContinue
}

# WMI Win32_Process.Create return code mapping
$script:WMI_RETURN_CODES = @{
    0  = "Success"
    2  = "Access denied"
    3  = "Insufficient privilege"
    8  = "Unknown failure"
    9  = "Path not found"
    21 = "Invalid parameter"
}

function Invoke-Executor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]  [string]$ComputerName,
        [Parameter(Mandatory=$false)] [System.Management.Automation.PSCredential]$Credential,
        [Parameter(Mandatory=$true)]  [string]$LocalBinaryPath,
        [Parameter(Mandatory=$true)]  [string]$RemoteDestPath,
        [Parameter(Mandatory=$false)] [string]$Arguments = "",
        [Parameter(Mandatory=$false)] [int]$AliveCheckSeconds = 10,
        [Parameter(Mandatory=$false)] $BinaryTypeOverride = $null
    )

    $startTime = [System.DateTime]::UtcNow
    $result = [ordered]@{
        ExecutionId   = [System.Guid]::NewGuid().ToString()
        ComputerName  = $ComputerName
        Method        = "WMI"
        LocalBinary   = $LocalBinaryPath
        RemoteDest    = $RemoteDestPath
        Arguments     = $Arguments
        StartTimeUTC  = $startTime.ToString("o")
        EndTimeUTC    = $null
        States        = @()
        FinalState    = $null
        PID           = $null
        BinaryType    = $null
        Error         = $null
    }

    function Add-State {
        param([string]$State, [string]$Detail = "")
        $result.States += [ordered]@{
            State   = $State
            TimeUTC = [System.DateTime]::UtcNow.ToString("o")
            Detail  = $Detail
        }
        $result.FinalState = $State
    }

    try {
        # Step 1 — Verify local binary path provided (WMI skips transfer; note it)
        # We still validate that LocalBinaryPath is non-empty; actual existence is on target.
        if (-not $LocalBinaryPath) {
            Add-State "CONNECTION_FAILED" "LocalBinaryPath not specified"
            $result.Error = "LocalBinaryPath not specified"
            $result.EndTimeUTC = [System.DateTime]::UtcNow.ToString("o")
            return [PSCustomObject]$result
        }

        # Step 2 — Verify WMI connectivity to target
        try {
            $wmiParams = @{
                Class       = 'Win32_OperatingSystem'
                ComputerName = $ComputerName
                ErrorAction = 'Stop'
            }
            if ($Credential) { $wmiParams['Credential'] = $Credential }
            Get-WmiObject @wmiParams | Out-Null
        } catch {
            Add-State "CONNECTION_FAILED" $_.Exception.Message
            $result.Error = $_.Exception.Message
            $result.EndTimeUTC = [System.DateTime]::UtcNow.ToString("o")
            return [PSCustomObject]$result
        }

        # Step 3 — Transfer skipped (WMI cannot transfer files)
        Add-State "TRANSFERRED" "Skipped -- binary must exist on target"

        # Step 3a — BinaryType detection (on LocalBinaryPath if accessible locally)
        if ($BinaryTypeOverride -ne $null) {
            $result.BinaryType = $BinaryTypeOverride
        } elseif (Get-Command Get-BinaryType -ErrorAction SilentlyContinue) {
            $result.BinaryType = Get-BinaryType -Path $LocalBinaryPath
        }

        $isSFX = $result.BinaryType -and $result.BinaryType.IsSFX

        # Step 4 — Launch via Win32_Process.Create
        $commandLine = if ($Arguments) { "`"$RemoteDestPath`" $Arguments" } else { "`"$RemoteDestPath`"" }

        $launchPID = $null
        try {
            $wmiScopeParams = @{ ComputerName = $ComputerName }
            if ($Credential) { $wmiScopeParams['Credential'] = $Credential }

            $scope = New-Object System.Management.ManagementScope("\\$ComputerName\root\cimv2")
            if ($Credential) {
                $scope.Options.Username = $Credential.UserName
                $scope.Options.Password = $Credential.GetNetworkCredential().Password
            }
            $scope.Connect()

            $classObj = New-Object System.Management.ManagementClass($scope, "Win32_Process", $null)
            $inParams  = $classObj.GetMethodParameters("Create")
            $inParams["CommandLine"] = $commandLine

            $outParams = $classObj.InvokeMethod("Create", $inParams, $null)
            $rc        = [int]$outParams["ReturnValue"]

            if ($rc -ne 0) {
                $msg = if ($script:WMI_RETURN_CODES.ContainsKey($rc)) {
                    $script:WMI_RETURN_CODES[$rc]
                } else {
                    "WMI return code $rc"
                }
                throw "Win32_Process.Create failed: $msg (code=$rc)"
            }

            $launchPID = [int]$outParams["ProcessId"]
        } catch {
            Add-State "LAUNCH_FAILED" $_.Exception.Message
            $result.Error = $_.Exception.Message
            $result.EndTimeUTC = [System.DateTime]::UtcNow.ToString("o")
            return [PSCustomObject]$result
        }

        $result.PID = $launchPID

        if ($isSFX) {
            # SFX flow: poll for process exit (WMI cannot retrieve exit code)
            $sfxType = $result.BinaryType.SFXType
            Add-State "LAUNCHED" "SFX type=$sfxType detected; using exit code check"

            $sfxExited   = $false
            $wmiErrors   = 0
            while (-not $sfxExited) {
                Start-Sleep -Seconds 2
                $checkParams = @{
                    Class        = 'Win32_Process'
                    ComputerName = $ComputerName
                    Filter       = "ProcessId=$launchPID"
                    ErrorAction  = 'Stop'
                }
                if ($Credential) { $checkParams['Credential'] = $Credential }
                try {
                    $p = Get-WmiObject @checkParams
                    if ($null -eq $p) { $sfxExited = $true }
                    $wmiErrors = 0
                } catch {
                    $wmiErrors++
                    if ($wmiErrors -ge 3) {
                        # WMI permanently inaccessible — assume SFX launched
                        Add-State "SFX_LAUNCHED" "SFX assumed launched (WMI poll error: $($_.Exception.Message))"
                        break
                    }
                }
            }

            if ($sfxExited) {
                Add-State "SFX_LAUNCHED" "SFX exited (exit code unavailable via WMI)"
            }

        } else {
            Add-State "LAUNCHED" "PID=$launchPID"

            # Step 5 — Alive check
            Start-Sleep -Seconds $AliveCheckSeconds

            $aliveResult = 'UNKNOWN'
            try {
                $aliveParams = @{
                    Class        = 'Win32_Process'
                    ComputerName = $ComputerName
                    Filter       = "ProcessId=$launchPID"
                    ErrorAction  = 'Stop'
                }
                if ($Credential) { $aliveParams['Credential'] = $Credential }
                $proc = Get-WmiObject @aliveParams
                $aliveResult = if ($null -ne $proc) { 'ALIVE' } else { 'EXITED' }
            } catch {
                # WMI query failed (e.g. Access Denied) — process was already
                # launched successfully, so assume alive rather than marking failed.
                $aliveResult = 'ALIVE'
                Add-State "ALIVE" "PID=$launchPID assumed alive (WMI check error: $($_.Exception.Message))"
            }

            if ($aliveResult -eq 'ALIVE') {
                if ($result.States[$result.States.Count - 1].State -ne 'ALIVE') {
                    Add-State "ALIVE" "PID=$launchPID still running after ${AliveCheckSeconds}s"
                }
            } else {
                Add-State "LAUNCH_FAILED" "PID=$launchPID not found after ${AliveCheckSeconds}s alive check"
                $result.Error = "Process not found after alive check"
            }
        }

    } catch {
        if (-not $result.FinalState) {
            Add-State "CONNECTION_FAILED" $_.Exception.Message
            $result.Error = $_.Exception.Message
        }
    } finally {
        $result.EndTimeUTC = [System.DateTime]::UtcNow.ToString("o")
    }

    return [PSCustomObject]$result
}

Export-ModuleMember -Function Invoke-Executor
