#Requires -Version 5.1
# ╔══════════════════════════════════════╗
# ║  Quicker — WinRM.psm1               ║
# ║  Remote executor via WinRM/PSSession║
# ║  Transfers binary + launches it.   ║
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
# ║  PS compat : 5.1 (analyst machine)  ║
# ║  Version   : 1.1                    ║
# ╚══════════════════════════════════════╝

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

function Invoke-Executor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]  [string]$ComputerName,
        [Parameter(Mandatory=$false)] [System.Management.Automation.PSCredential]$Credential,
        [Parameter(Mandatory=$true)]  [string]$LocalBinaryPath,
        [Parameter(Mandatory=$true)]  [string]$RemoteDestPath,
        [Parameter(Mandatory=$false)] [string]$Arguments = "",
        [Parameter(Mandatory=$false)] [int]$AliveCheckSeconds = 10
    )

    $startTime = [System.DateTime]::UtcNow
    $result = [ordered]@{
        ExecutionId   = [System.Guid]::NewGuid().ToString()
        ComputerName  = $ComputerName
        Method        = "WinRM"
        LocalBinary   = $LocalBinaryPath
        RemoteDest    = $RemoteDestPath
        Arguments     = $Arguments
        StartTimeUTC  = $startTime.ToString("o")
        EndTimeUTC    = $null
        States        = @()
        FinalState    = $null
        PID           = $null
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

    $session = $null
    $isLocal = ($ComputerName -eq 'localhost' -or $ComputerName -eq '127.0.0.1' -or
                $ComputerName -ieq $env:COMPUTERNAME)

    # Helper: run a scriptblock either via session (remote) or locally
    function Invoke-OnTarget {
        param([scriptblock]$ScriptBlock, [object[]]$ArgumentList = @())
        if ($isLocal) {
            return & $ScriptBlock @ArgumentList
        } else {
            return Invoke-Command -Session $session -ScriptBlock $ScriptBlock `
                                  -ArgumentList $ArgumentList -ErrorAction Stop
        }
    }

    try {
        # Step 1 — Verify local binary exists
        if (-not (Test-Path -LiteralPath $LocalBinaryPath)) {
            Add-State "CONNECTION_FAILED" "Local binary not found: $LocalBinaryPath"
            $result.Error = "Local binary not found: $LocalBinaryPath"
            return [PSCustomObject]$result
        }

        # Step 2 — Establish WinRM PSSession (remote only)
        if (-not $isLocal) {
            try {
                $soParams = @{
                    SkipCACheck      = $true
                    SkipCNCheck      = $true
                    OpenTimeout      = 30000
                    OperationTimeout = 30000
                }
                $sessionOpt = New-PSSessionOption @soParams

                $sessParams = @{
                    ComputerName  = $ComputerName
                    SessionOption = $sessionOpt
                    ErrorAction   = 'Stop'
                }
                if ($Credential) { $sessParams['Credential'] = $Credential }

                # Ensure target is in TrustedHosts for non-domain / HTTP WinRM
                try {
                    $cur = (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction Stop).Value
                    if ($cur -ne '*' -and $cur -notmatch [regex]::Escape($ComputerName)) {
                        $newList = if ($cur) { "$cur,$ComputerName" } else { $ComputerName }
                        Set-Item WSMan:\localhost\Client\TrustedHosts -Value $newList -Force -ErrorAction Stop
                    }
                } catch { }

                $session = New-PSSession @sessParams
            } catch {
                Add-State "CONNECTION_FAILED" $_.Exception.Message
                $result.Error = $_.Exception.Message
                return [PSCustomObject]$result
            }
        }

        # Step 3 — Transfer binary
        $transferred    = $false
        $transferDetail = ""
        $localHash      = (Get-FileHash -LiteralPath $LocalBinaryPath -Algorithm SHA256).Hash

        if ($isLocal) {
            # Local: direct file copy
            try {
                $dir = Split-Path -Parent $RemoteDestPath
                if ($dir -and -not (Test-Path $dir)) {
                    New-Item -ItemType Directory -Path $dir -Force | Out-Null
                }
                Copy-Item -LiteralPath $LocalBinaryPath -Destination $RemoteDestPath -Force -ErrorAction Stop
                $destHash = (Get-FileHash -LiteralPath $RemoteDestPath -Algorithm SHA256).Hash
                if ($destHash -ne $localHash) {
                    throw "SHA256 mismatch: src=$localHash dest=$destHash"
                }
                $transferred   = $true
                $transferDetail = "SHA256=$localHash"
            } catch {
                Add-State "TRANSFER_FAILED" $_.Exception.Message
                $result.Error = $_.Exception.Message
                return [PSCustomObject]$result
            }
        } else {
            # Remote: primary base64, fallback SMB
            try {
                $bytes    = [System.IO.File]::ReadAllBytes($LocalBinaryPath)
                $b64      = [System.Convert]::ToBase64String($bytes)
                $dest     = $RemoteDestPath

                Invoke-Command -Session $session -ScriptBlock {
                    param($b64Data, $destPath)
                    $dir = Split-Path -Parent $destPath
                    if ($dir -and -not (Test-Path $dir)) {
                        New-Item -ItemType Directory -Path $dir -Force | Out-Null
                    }
                    $decoded = [System.Convert]::FromBase64String($b64Data)
                    [System.IO.File]::WriteAllBytes($destPath, $decoded)
                } -ArgumentList $b64, $dest -ErrorAction Stop

                $remoteHash = Invoke-Command -Session $session -ScriptBlock {
                    param($path)
                    (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
                } -ArgumentList $dest -ErrorAction Stop

                if ($remoteHash -ne $localHash) {
                    throw "SHA256 mismatch: local=$localHash remote=$remoteHash"
                }
                $transferred   = $true
                $transferDetail = "SHA256=$localHash"
            } catch {
                # Fallback: SMB Copy-Item
                try {
                    $uncPath = "\\$ComputerName\" + ($RemoteDestPath -replace '^([A-Za-z]):\\', '$1$\')
                    Copy-Item -LiteralPath $LocalBinaryPath -Destination $uncPath -Force -ErrorAction Stop

                    $remoteHash2 = Invoke-Command -Session $session -ScriptBlock {
                        param($path)
                        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
                    } -ArgumentList $RemoteDestPath -ErrorAction Stop

                    if ($remoteHash2 -ne $localHash) {
                        throw "SHA256 mismatch after SMB fallback: local=$localHash remote=$remoteHash2"
                    }
                    $transferred   = $true
                    $transferDetail = "SMB fallback. SHA256=$localHash"
                } catch {
                    Add-State "TRANSFER_FAILED" $_.Exception.Message
                    $result.Error = $_.Exception.Message
                    return [PSCustomObject]$result
                }
            }
        }

        if ($transferred) {
            Add-State "TRANSFERRED" $transferDetail
        }

        # Step 4 — Launch binary on target
        $launchPID = $null
        try {
            $launchResult = Invoke-OnTarget -ScriptBlock {
                param($exePath, $exeArgs)
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName        = $exePath
                $psi.Arguments       = $exeArgs
                $psi.UseShellExecute = $true
                $proc = [System.Diagnostics.Process]::Start($psi)
                if (-not $proc) { throw "Process.Start returned null" }
                return $proc.Id
            } -ArgumentList @($RemoteDestPath, $Arguments)

            $launchPID = $launchResult
        } catch {
            Add-State "LAUNCH_FAILED" $_.Exception.Message
            $result.Error = $_.Exception.Message
            return [PSCustomObject]$result
        }

        $result.PID = $launchPID
        Add-State "LAUNCHED" "PID=$launchPID"

        # Step 5 — Alive check
        Start-Sleep -Seconds $AliveCheckSeconds

        $stillAlive = $false
        try {
            $stillAlive = Invoke-OnTarget -ScriptBlock {
                param($checkPid)
                $p = Get-Process -Id $checkPid -ErrorAction SilentlyContinue
                return ($null -ne $p)
            } -ArgumentList @($launchPID)
        } catch { $stillAlive = $false }

        if ($stillAlive) {
            Add-State "ALIVE" "PID=$launchPID still running after ${AliveCheckSeconds}s"
        } else {
            Add-State "LAUNCH_FAILED" "PID=$launchPID not found after ${AliveCheckSeconds}s alive check"
            $result.Error = "Process not found after alive check"
        }

    } finally {
        if ($session) {
            Remove-PSSession $session -ErrorAction SilentlyContinue
        }
        $result.EndTimeUTC = [System.DateTime]::UtcNow.ToString("o")
    }

    return [PSCustomObject]$result
}

Export-ModuleMember -Function Invoke-Executor
