#Requires -Version 5.1
# ╔══════════════════════════════════════╗
# ║  QuickAiR -- WinRM.psm1               ║
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
# ║              SfxTimeoutSeconds      ║
# ║  Output    : result object          ║
# ║  Depends   : none                   ║
# ║  PS compat : 5.1 (analyst machine)  ║
# ║  Version   : 3.0                    ║
# ╚══════════════════════════════════════╝

Set-StrictMode -Version 2
# ErrorActionPreference=Continue at module scope: prevents one failing cmdlet
# from aborting the entire module load or function. Individual cmdlets that
# MUST NOT silently fail use -ErrorAction Stop explicitly. Any NEW cmdlet
# added to this module MUST use -ErrorAction Stop where failure matters.
$ErrorActionPreference = 'Continue'

# Load Output.psm1 for Get-BinaryType / Write-Log
$_outputMod = Join-Path (Split-Path -Parent $PSScriptRoot) "Core\Output.psm1"
if (-not $PSScriptRoot) {
    $_outputMod = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "..\Core\Output.psm1"
}
if (Test-Path $_outputMod) {
    Import-Module $_outputMod -Force -ErrorAction SilentlyContinue
}

# WMI Win32_Process.Create return code mapping (used in remote launch path)
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
        [Parameter(Mandatory=$false)] $BinaryTypeOverride = $null,
        [Parameter(Mandatory=$false)] [int]$SfxTimeoutSeconds = 300
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

    $session = $null
    $originalTrustedHosts = $null
    $trustedHostsModified = $false
    $isLocal = ($ComputerName -eq 'localhost' -or $ComputerName -eq '127.0.0.1' -or
                $ComputerName -eq '::1' -or $ComputerName -eq '[::1]' -or
                $ComputerName -ieq $env:COMPUTERNAME)
    if (-not $isLocal) {
        try {
            $resolvedHost = [System.Net.Dns]::GetHostEntry($ComputerName).HostName
            $localFqdn    = [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName
            if ($resolvedHost -ieq $localFqdn) { $isLocal = $true }
        } catch { }
    }

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
        # Step 1 -- Clean and verify local binary exists
        $LocalBinaryPath = $LocalBinaryPath.Trim().Trim('"').Trim("'").Trim()
        $LocalBinaryPath = $LocalBinaryPath -replace '/', '\'
        if (-not (Test-Path -LiteralPath $LocalBinaryPath)) {
            Add-State "CONNECTION_FAILED" "Local binary not found: $LocalBinaryPath"
            $result.Error = "Local binary not found: $LocalBinaryPath"
            return [PSCustomObject]$result
        }

        # Step 2 -- Establish WinRM PSSession (remote only)
        if ($isLocal) {
            Add-State "CONNECTED" "Local execution (no PSSession needed)"
        } else {
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
                # Save original so we can restore in finally block (B1 fix)
                # Use named mutex to prevent race with parallel executor instances
                $thMutex = $null
                try {
                    $thMutex = [System.Threading.Mutex]::new($false, 'QuickAiR_TrustedHosts')
                    $gotMutex = $thMutex.WaitOne(10000)
                    if (-not $gotMutex) {
                        Add-State "WARNING" "TrustedHosts mutex timeout - skipping TH modification"
                    }
                    $cur = if ($gotMutex) { (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction Stop).Value } else { '*' }
                    if ($cur -ne '*' -and $cur -notmatch [regex]::Escape($ComputerName)) {
                        $originalTrustedHosts = $cur
                        $newList = if ($cur) { "$cur,$ComputerName" } else { $ComputerName }
                        Set-Item WSMan:\localhost\Client\TrustedHosts -Value $newList -Force -ErrorAction Stop
                        $trustedHostsModified = $true
                    }
                } catch { } finally {
                    if ($thMutex) { try { $thMutex.ReleaseMutex() } catch {} }
                }

                $session = New-PSSession @sessParams
                Add-State "CONNECTED" "PSSession established to $ComputerName"
            } catch {
                Add-State "CONNECTION_FAILED" $_.Exception.Message
                $result.Error = $_.Exception.Message
                return [PSCustomObject]$result
            }
        }

        # Step 3 -- Transfer binary
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
                # Copy companion .mui resource files if present (e.g. notepad.exe.mui)
                $srcDir  = Split-Path -Parent $LocalBinaryPath
                $srcName = Split-Path -Leaf  $LocalBinaryPath
                $dstDir  = Split-Path -Parent $RemoteDestPath
                $dstName = Split-Path -Leaf  $RemoteDestPath
                try {
                    Get-ChildItem $srcDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                        $muiSrc = Join-Path $_.FullName "$srcName.mui"
                        if (Test-Path $muiSrc) {
                            $muiDestDir = Join-Path $dstDir $_.Name
                            $muiDest    = Join-Path $muiDestDir "$dstName.mui"
                            if (-not (Test-Path $muiDestDir)) {
                                New-Item -ItemType Directory -Path $muiDestDir -Force | Out-Null
                            }
                            Copy-Item -LiteralPath $muiSrc -Destination $muiDest -Force -ErrorAction Stop
                        }
                    }
                } catch { }
            } catch {
                Add-State "TRANSFER_FAILED" $_.Exception.Message
                $result.Error = $_.Exception.Message
                return [PSCustomObject]$result
            }
        } else {
            # Remote: chunked base64 transfer (PS 2.0 compat, avoids WinRM envelope size limit)
            try {
                # Check file size before loading into memory
                $fileInfo = New-Object System.IO.FileInfo($LocalBinaryPath)
                $MAX_BINARY_SIZE = 500MB
                if ($fileInfo.Length -gt $MAX_BINARY_SIZE) {
                    $sizeMB = [math]::Round($fileInfo.Length / 1MB, 1)
                    $limitMB = [math]::Round($MAX_BINARY_SIZE / 1MB, 0)
                    Add-State "TRANSFER_FAILED" "Binary too large: ${sizeMB}MB exceeds ${limitMB}MB limit"
                    $result.Error = "Binary exceeds size limit (${sizeMB}MB)"
                    return [PSCustomObject]$result
                }
                $fileBytes = [System.IO.File]::ReadAllBytes($LocalBinaryPath)
                $dest      = $RemoteDestPath
                # 96 KB binary chunks → ~128 KB base64, well under WinRM 2.0 500 KB envelope limit
                $chunkSize = 98304
                $offset    = 0
                $isFirst   = $true

                while ($offset -lt $fileBytes.Length) {
                    $len = [Math]::Min($chunkSize, $fileBytes.Length - $offset)
                    $chunk = [byte[]]::new($len)
                    [Array]::Copy($fileBytes, $offset, $chunk, 0, $len)
                    $b64Chunk = [System.Convert]::ToBase64String($chunk)
                    $isFirstChunk = $isFirst

                    Invoke-Command -Session $session -ScriptBlock {
                        param($b64Data, $destPath, $firstChunk)
                        $decoded = [System.Convert]::FromBase64String($b64Data)
                        if ($firstChunk) {
                            $dir = Split-Path -Parent $destPath
                            if ($dir -and -not (Test-Path $dir)) {
                                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                            }
                            [System.IO.File]::WriteAllBytes($destPath, $decoded)
                        } else {
                            $stream = [System.IO.File]::OpenWrite($destPath)
                            try {
                                [void]$stream.Seek(0, [System.IO.SeekOrigin]::End)
                                $stream.Write($decoded, 0, $decoded.Length)
                            } finally {
                                $stream.Close()
                            }
                        }
                    } -ArgumentList $b64Chunk, $dest, $isFirstChunk -ErrorAction Stop

                    $offset  += $len
                    $isFirst  = $false
                }

                $remoteHash = Invoke-Command -Session $session -ScriptBlock {
                    param($path)
                    $sha  = [System.Security.Cryptography.SHA256]::Create()
                    $data = [System.IO.File]::ReadAllBytes($path)
                    $h    = $sha.ComputeHash($data)
                    try { $sha.Dispose() } catch { }
                    return ([BitConverter]::ToString($h) -replace '-','')
                } -ArgumentList $dest -ErrorAction Stop

                if ($remoteHash -ne $localHash) {
                    throw "SHA256 mismatch: local=$localHash remote=$remoteHash"
                }
                $transferred   = $true
                $transferDetail = "SHA256=$localHash"
                # Transfer companion .mui resource files if present
                $srcDir2  = Split-Path -Parent $LocalBinaryPath
                $srcName2 = Split-Path -Leaf  $LocalBinaryPath
                $dstDir2  = Split-Path -Parent $dest
                $dstName2 = Split-Path -Leaf  $dest
                try {
                    Get-ChildItem $srcDir2 -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                        $muiSrc2 = Join-Path $_.FullName "$srcName2.mui"
                        if (Test-Path $muiSrc2) {
                            $muiB64 = [System.Convert]::ToBase64String(
                                [System.IO.File]::ReadAllBytes($muiSrc2))
                            $muiDestDir2 = Join-Path $dstDir2 $_.Name
                            $muiDest2    = Join-Path $muiDestDir2 "$dstName2.mui"
                            Invoke-Command -Session $session -ScriptBlock {
                                param($b64Data, $destPath)
                                $d = Split-Path -Parent $destPath
                                if ($d -and -not (Test-Path $d)) {
                                    New-Item -ItemType Directory -Path $d -Force | Out-Null
                                }
                                [System.IO.File]::WriteAllBytes($destPath,
                                    [System.Convert]::FromBase64String($b64Data))
                            } -ArgumentList $muiB64, $muiDest2 -ErrorAction Stop
                        }
                    }
                } catch { }
            } catch {
                # Fallback: SMB Copy-Item via PSDrive (passes credential properly -- EX2)
                $smbFallbackDrive = $null
                try {
                    $uncPath = "\\$ComputerName\" + ($RemoteDestPath -replace '^([A-Za-z]):\\', '$1$\')
                    $uncRoot = "\\$ComputerName\" + ($RemoteDestPath -replace '^([A-Za-z]):\\.*', '$1$')
                    $smbFallbackDrive = "QuickAiRFB_$(Get-Random)"
                    $fbDriveParams = @{
                        Name        = $smbFallbackDrive
                        PSProvider  = 'FileSystem'
                        Root        = $uncRoot
                        ErrorAction = 'Stop'
                    }
                    if ($Credential) { $fbDriveParams['Credential'] = $Credential }
                    New-PSDrive @fbDriveParams | Out-Null
                    Copy-Item -LiteralPath $LocalBinaryPath -Destination $uncPath -Force -ErrorAction Stop

                    $remoteHash2 = Invoke-Command -Session $session -ScriptBlock {
                        param($path)
                        $sha  = [System.Security.Cryptography.SHA256]::Create()
                        $data = [System.IO.File]::ReadAllBytes($path)
                        $h    = $sha.ComputeHash($data); $sha.Dispose()
                        return ([BitConverter]::ToString($h) -replace '-','')
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
                } finally {
                    if ($smbFallbackDrive) {
                        try { Remove-PSDrive -Name $smbFallbackDrive -Force -ErrorAction SilentlyContinue } catch { }
                    }
                }
            }
        }

        if ($transferred) {
            Add-State "TRANSFERRED" $transferDetail
        }

        # Step 4a -- BinaryType detection
        if ($BinaryTypeOverride -ne $null) {
            $result.BinaryType = $BinaryTypeOverride
        } else {
            $result.BinaryType = Get-BinaryType -Path $LocalBinaryPath
        }

        $isSFX = $result.BinaryType -and $result.BinaryType.IsSFX

        if ($isSFX) {
            # SFX flow: launch and wait for exit, check exit code
            $sfxType = $result.BinaryType.SFXType
            Add-State "LAUNCHED" "SFX type=$sfxType detected; using exit code check"

            try {
                $sfxTimeoutMs = $SfxTimeoutSeconds * 1000
                $sfxResult = Invoke-OnTarget -ScriptBlock {
                    param($exePath, $exeArgs, $timeoutMs)
                    $psi = New-Object System.Diagnostics.ProcessStartInfo
                    $psi.FileName               = $exePath
                    $psi.Arguments              = $exeArgs
                    $psi.UseShellExecute        = $false
                    $psi.RedirectStandardOutput = $false
                    $psi.RedirectStandardError  = $false
                    $proc = [System.Diagnostics.Process]::Start($psi)
                    if (-not $proc) { throw "Process.Start returned null" }
                    $pid_ = $proc.Id
                    $exited = $proc.WaitForExit($timeoutMs)
                    if (-not $exited) {
                        try { $proc.Kill() } catch { }
                        return [PSCustomObject]@{ ExitCode=-1; PID=$pid_; TimedOut=$true }
                    }
                    return [PSCustomObject]@{ ExitCode=$proc.ExitCode; PID=$pid_; TimedOut=$false }
                } -ArgumentList @($RemoteDestPath, $Arguments, $sfxTimeoutMs)
            } catch {
                Add-State "LAUNCH_FAILED" $_.Exception.Message
                $result.Error = $_.Exception.Message
                return [PSCustomObject]$result
            }

            $result.PID = [int]$sfxResult.PID

            if ($sfxResult.TimedOut) {
                Add-State "LAUNCH_FAILED" "SFX timed out after ${SfxTimeoutSeconds}s"
                $result.Error = "SFX timed out after ${SfxTimeoutSeconds}s"
                return [PSCustomObject]$result
            }

            if ([int]$sfxResult.ExitCode -eq 0) {
                Add-State "SFX_LAUNCHED" "SFX exited with code 0"
            } else {
                $ec = $sfxResult.ExitCode
                Add-State "LAUNCH_FAILED" "SFX exited with code $ec"
                $result.Error = "SFX exit code $ec"
            }

        } else {
            # Step 4b -- Normal launch
            $launchPID     = $null
            $earlyExitCode = $null
            try {
                if ($isLocal) {
                    # Local: Process.Start with UseShellExecute creates a detached process
                    $launchResult = Invoke-OnTarget -ScriptBlock {
                        param($exePath, $exeArgs)
                        $psi = New-Object System.Diagnostics.ProcessStartInfo
                        $psi.FileName        = $exePath
                        $psi.Arguments       = $exeArgs
                        $psi.UseShellExecute = $true
                        $proc = [System.Diagnostics.Process]::Start($psi)
                        if (-not $proc) { throw "Process.Start returned null" }
                        $pid_ = $proc.Id
                        $exited = $proc.WaitForExit(1000)
                        if ($exited) {
                            return [PSCustomObject]@{ PID = $pid_; ExitCode = $proc.ExitCode }
                        }
                        return [PSCustomObject]@{ PID = $pid_; ExitCode = $null }
                    } -ArgumentList @($RemoteDestPath, $Arguments)
                } else {
                    # Remote: call Win32_Process::Create locally on the target via WinRM.
                    # Launching via Invoke-Command ScriptBlock creates a child of wsmprovhost.exe;
                    # that child is killed when the PSSession closes.
                    # Win32_Process::Create (called locally on target) spawns under the WMI
                    # service, which is independent of the WinRM session -- process survives close.
                    # NOTE: $Arguments passed raw to command line. Win32_Process::Create
                    # uses CreateProcess directly -- shell metacharacters (&, |, >) are NOT
                    # interpreted. This is safe by design. (EX8)
                    $wmiCodes = $script:WMI_RETURN_CODES
                    $launchResult = Invoke-Command -Session $session -ScriptBlock {
                        param($exePath, $exeArgs, $returnCodes)
                        $cmdLine = if ($exeArgs) { "`"$exePath`" $exeArgs" } else { "`"$exePath`"" }
                        $wmiResult = Invoke-WmiMethod -Class Win32_Process -Name Create -ArgumentList $cmdLine -ErrorAction Stop
                        if ($wmiResult.ReturnValue -ne 0) {
                            $rc = [int]$wmiResult.ReturnValue
                            $msg = if ($returnCodes -and $returnCodes.ContainsKey($rc)) {
                                $returnCodes[$rc]
                            } else {
                                "WMI return code $rc"
                            }
                            throw "Win32_Process::Create failed: $msg (code=$rc)"
                        }
                        return [PSCustomObject]@{ PID = [int]$wmiResult.ProcessId; ExitCode = $null }
                    } -ArgumentList @($RemoteDestPath, $Arguments, $wmiCodes) -ErrorAction Stop
                }

                if ($launchResult -is [int] -or $launchResult -is [long]) {
                    $launchPID     = [int]$launchResult
                    $earlyExitCode = $null
                } elseif ($null -ne $launchResult.PID) {
                    $launchPID     = [int]$launchResult.PID
                    $earlyExitCode = $launchResult.ExitCode
                } else {
                    throw "Remote execution returned null PID"
                }
            } catch {
                Add-State "LAUNCH_FAILED" $_.Exception.Message
                $result.Error = $_.Exception.Message
                return [PSCustomObject]$result
            }

            $result.PID = $launchPID
            Add-State "LAUNCHED" "PID=$launchPID"

            # Step 5 -- Alive check
            Start-Sleep -Seconds $AliveCheckSeconds

            # EX4: verify PID AND process name to guard against PID reuse
            $expectedName = [System.IO.Path]::GetFileNameWithoutExtension($RemoteDestPath)
            $stillAlive = $false
            try {
                $stillAlive = Invoke-OnTarget -ScriptBlock {
                    param($checkPid, $expectedProcessName)
                    $p = Get-Process -Id $checkPid -ErrorAction SilentlyContinue
                    if ($null -eq $p) { return $false }
                    if ($expectedProcessName -and $p.ProcessName -ine $expectedProcessName) {
                        return $false  # PID reused by different process
                    }
                    return $true
                } -ArgumentList @($launchPID, $expectedName)
            } catch { $stillAlive = $false }
            $stillAlive = [bool]$stillAlive

            if ($stillAlive) {
                Add-State "ALIVE" "PID=$launchPID still running after ${AliveCheckSeconds}s"
            } else {
                $failDetail = if ($null -ne $earlyExitCode) {
                    "Exited early, code: $earlyExitCode"
                } else {
                    "PID=$launchPID not found after ${AliveCheckSeconds}s alive check"
                }
                Add-State "LAUNCH_FAILED" $failDetail
                $result.Error = "Process not found after alive check"
            }
        }

    } finally {
        # EX1: Clean up transferred binary on failure (before closing session)
        if ($result.FinalState -match 'FAILED' -and $RemoteDestPath) {
            try {
                if ($isLocal) {
                    if (Test-Path -LiteralPath $RemoteDestPath) {
                        Remove-Item -LiteralPath $RemoteDestPath -Force -ErrorAction Stop
                        Add-State "CLEANUP" "Removed transferred binary from target"
                    }
                } elseif ($session -and $session.State -eq 'Opened') {
                    Invoke-Command -Session $session -ScriptBlock {
                        param($p)
                        if (Test-Path -LiteralPath $p) {
                            Remove-Item -LiteralPath $p -Force -ErrorAction Stop
                        }
                    } -ArgumentList $RemoteDestPath -ErrorAction Stop
                    Add-State "CLEANUP" "Removed transferred binary from target"
                }
            } catch {
                Add-State "CLEANUP_FAILED" "Could not remove transferred binary: $($_.Exception.Message)"
            }
        }
        # B1: Restore TrustedHosts to original value if we modified it
        if ($trustedHostsModified) {
            $thMutex = $null
            try {
                $thMutex = [System.Threading.Mutex]::new($false, 'QuickAiR_TrustedHosts')
                $thMutex.WaitOne(10000) | Out-Null
                Set-Item WSMan:\localhost\Client\TrustedHosts -Value $originalTrustedHosts -Force -ErrorAction Stop
            } catch {
                # EX5: Log warning instead of silently swallowing
                Add-State "WARNING" "TrustedHosts restore failed: $($_.Exception.Message). Verify WSMan:\localhost\Client\TrustedHosts manually."
            } finally {
                if ($thMutex) { try { $thMutex.ReleaseMutex() } catch {} }
            }
        }
        if ($session) {
            Remove-PSSession $session -ErrorAction SilentlyContinue
        }
        $result.EndTimeUTC = [System.DateTime]::UtcNow.ToString("o")
    }

    return [PSCustomObject]$result
}

Export-ModuleMember -Function Invoke-Executor
