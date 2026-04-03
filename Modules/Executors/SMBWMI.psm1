#Requires -Version 2.0
# ╔══════════════════════════════════════╗
# ║  QuickAiR — SMBWMI.psm1             ║
# ║  Remote executor via SMB transfer   ║
# ║  + WMI execution.                  ║
# ║  Fallback when WinRM unavailable.  ║
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
# ║  PS compat : 2.0+ (analyst machine) ║
# ║  Version   : 1.6                    ║
# ╚══════════════════════════════════════╝

Set-StrictMode -Off
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
        [Parameter(Mandatory=$false)] [string]$SmbShare = "",
        [Parameter(Mandatory=$false)] $BinaryTypeOverride = $null,
        [Parameter(Mandatory=$false)] [int]$SfxTimeoutSeconds = 300
    )

    $startTime = [System.DateTime]::UtcNow
    $result = [ordered]@{
        ExecutionId   = [System.Guid]::NewGuid().ToString()
        ComputerName  = $ComputerName
        Method        = "SMB+WMI"
        LocalBinary   = $LocalBinaryPath
        RemoteDest    = $RemoteDestPath
        Arguments     = $Arguments
        StartTimeUTC  = $startTime.ToString("o")
        EndTimeUTC    = $null
        States        = @()
        FinalState    = $null
        PID           = $null
        SmbShare      = $null
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

    # Convert local path to UNC: C:\Windows\Temp\x.exe → \\host\C$\Windows\Temp\x.exe
    function ConvertTo-UNCPath {
        param([string]$Host_, [string]$LocalPath)
        if ($LocalPath -match '^([A-Za-z]):\\(.*)$') {
            $drive = $Matches[1]
            $rest  = $Matches[2]
            if ($rest -match '[\[\]`]') {
                Add-State "WARN" "UNC path contains special characters that may cause SMB issues: $LocalPath"
            }
            return "\\$Host_\$drive`$\$rest"
        }
        return $null
    }

    # Enumerate admin shares on target via WMI; find one matching the drive letter
    function Find-AdminShare {
        param([string]$Host_, [System.Management.Automation.PSCredential]$Cred, [string]$DriveLetter)
        $wmiScope = $null; $searcher = $null
        try {
            $wmiScope = New-Object System.Management.ManagementScope("\\$Host_\root\cimv2")
            if ($Cred) {
                $wmiScope.Options.Username = $Cred.UserName
                $wmiScope.Options.Password = $Cred.GetNetworkCredential().Password
            }
            $wmiScope.Connect()
            $q = New-Object System.Management.ObjectQuery("SELECT Name, Path FROM Win32_Share WHERE Type = 2147483648")
            $searcher = New-Object System.Management.ManagementObjectSearcher($wmiScope, $q)
            $shares = @($searcher.Get())
            $allNames = @()
            foreach ($s in $shares) {
                $allNames += [string]$s['Name']
                $sp = [string]$s['Path']
                $driveRoot = $DriveLetter + ':\'
                if ($sp -and $sp -ieq $driveRoot) {
                    return @{ Name = [string]$s['Name']; Path = $sp; AllShares = $allNames }
                }
            }
            return @{ Name = $null; Path = $null; AllShares = $allNames }
        } catch {
            return @{ Name = $null; Path = $null; AllShares = @(); Error = $_.Exception.Message }
        } finally {
            if ($searcher) { try { $searcher.Dispose() } catch {} }
            if ($wmiScope) { try { $wmiScope.Dispose() } catch {} }
        }
    }

    $smbDriveName = $null

    try {
        # Step 1 — Verify local binary exists on analyst machine
        $LocalBinaryPath = $LocalBinaryPath.Trim().Trim('"').Trim("'").Trim()
        $LocalBinaryPath = $LocalBinaryPath -replace '/', '\'
        if (-not (Test-Path -LiteralPath $LocalBinaryPath)) {
            Add-State "CONNECTION_FAILED" "Local binary not found: $LocalBinaryPath"
            $result.Error = "Local binary not found: $LocalBinaryPath"
            $result.EndTimeUTC = [System.DateTime]::UtcNow.ToString("o")
            return [PSCustomObject]$result
        }

        # Step 2 — Test SMB connectivity: map PSDrive to share
        if ($SmbShare) {
            # Custom share provided (e.g. \\host\CustomShare or just CustomShare)
            $shareRoot = $SmbShare.TrimEnd('\')
            if ($shareRoot -notmatch '^\\\\') {
                $shareRoot = "\\$ComputerName\$shareRoot"
            }
            # For custom share: UNC path = shareRoot + relative portion of RemoteDestPath
            # User must ensure RemoteDestPath maps correctly under the share
            $uncPath = ConvertTo-UNCPath -Host_ $ComputerName -LocalPath $RemoteDestPath
            if (-not $uncPath) {
                Add-State "CONNECTION_FAILED" "Cannot convert path to UNC: $RemoteDestPath"
                $result.Error = "Cannot convert path to UNC: $RemoteDestPath"
                $result.EndTimeUTC = [System.DateTime]::UtcNow.ToString("o")
                return [PSCustomObject]$result
            }
        } else {
            # Dynamic share enumeration via Win32_Share
            if ($RemoteDestPath -notmatch '^([A-Za-z]):\\(.*)$') {
                Add-State "CONNECTION_FAILED" "Cannot parse drive letter from path: $RemoteDestPath"
                $result.Error = "Cannot parse drive letter from path: $RemoteDestPath"
                $result.EndTimeUTC = [System.DateTime]::UtcNow.ToString("o")
                return [PSCustomObject]$result
            }
            $driveLetter = $Matches[1]
            $pathRemainder = $Matches[2]

            $shareResult = Find-AdminShare -Host_ $ComputerName -Cred $Credential -DriveLetter $driveLetter

            if ($shareResult.Name) {
                # Found matching admin share
                $shareRoot = "\\$ComputerName\" + $shareResult.Name
                $uncPath   = "\\$ComputerName\" + $shareResult.Name + "\" + $pathRemainder
            } else {
                # No matching admin share found and -SmbShare not provided.
                # Per autonomy rule: never prompt the user. Return CONNECTION_FAILED.
                # Analyst can retry with -SmbShare to specify a share manually.
                $detail = "No admin share found for drive $($driveLetter): on $ComputerName"
                if ($shareResult.AllShares -and $shareResult.AllShares.Count -gt 0) {
                    $nameList = $shareResult.AllShares -join ', '
                    $detail += ". Available shares: $nameList"
                }
                if ($shareResult.Error) {
                    $detail += ". Enumeration error: $($shareResult.Error)"
                }
                $detail += ". Retry with -SmbShare to specify a share manually."
                Add-State "CONNECTION_FAILED" $detail
                $result.Error = $detail
                $result.EndTimeUTC = [System.DateTime]::UtcNow.ToString("o")
                return [PSCustomObject]$result
            }
        }
        $result.SmbShare = $shareRoot
        $smbDriveName = "QuickAiRSMB_$(Get-Random)"

        try {
            $driveParams = @{
                Name        = $smbDriveName
                PSProvider  = 'FileSystem'
                Root        = $shareRoot
                ErrorAction = 'Stop'
            }
            if ($Credential) { $driveParams['Credential'] = $Credential }
            New-PSDrive @driveParams | Out-Null

            # Verify SMB is actually reachable (New-PSDrive can succeed lazily)
            if (-not (Test-Path "${smbDriveName}:\")) {
                throw "SMB share not accessible after mapping"
            }
        } catch {
            Add-State "CONNECTION_FAILED" "SMB share inaccessible: $($_.Exception.Message)"
            $result.Error = "SMB share inaccessible: $($_.Exception.Message)"
            try { Remove-PSDrive -Name $smbDriveName -Force -ErrorAction SilentlyContinue } catch { }
            $smbDriveName = $null
            $result.EndTimeUTC = [System.DateTime]::UtcNow.ToString("o")
            return [PSCustomObject]$result
        }

        # Step 3 — Compute SHA256 of local binary (PS 2.0 compatible — no Get-FileHash)
        $localSha = [System.Security.Cryptography.SHA256]::Create()
        $localBytes = [System.IO.File]::ReadAllBytes($LocalBinaryPath)
        $localHashBytes = $localSha.ComputeHash($localBytes)
        try { $localSha.Dispose() } catch { }
        $localHash = ([System.BitConverter]::ToString($localHashBytes) -replace '-','')
        $localSize = $localBytes.Length

        # Step 4 — Transfer binary via SMB (use UNC path — PSDrive caches credentials)
        try {
            $uncDir = Split-Path -Parent $uncPath
            if ($uncDir -and -not (Test-Path $uncDir)) {
                New-Item -ItemType Directory -Path $uncDir -Force | Out-Null
            }
            Copy-Item -LiteralPath $LocalBinaryPath -Destination $uncPath -Force -ErrorAction Stop

            # Verify 1: file exists on target
            if (-not (Test-Path -LiteralPath $uncPath)) {
                throw "Post-copy verification failed: file not found at UNC path $uncPath"
            }
            # Verify 2: file size matches source
            $remoteSize = (Get-Item -LiteralPath $uncPath -ErrorAction Stop).Length
            if ($remoteSize -ne $localSize) {
                throw "Post-copy verification failed: size mismatch (local=${localSize} remote=${remoteSize}) UNC=$uncPath"
            }

            # Verify 3: SHA256 by reading back through UNC
            $sha   = [System.Security.Cryptography.SHA256]::Create()
            $bytes = [System.IO.File]::ReadAllBytes($uncPath)
            $hash  = $sha.ComputeHash($bytes)
            try { $sha.Dispose() } catch { }
            $remoteHash = ([System.BitConverter]::ToString($hash) -replace '-','')
            if ($remoteHash -ne $localHash) {
                throw "SHA256 mismatch: local=$localHash remote=$remoteHash"
            }
            Add-State "TRANSFERRED" "via $shareRoot SHA256=$localHash"
        } catch {
            Add-State "TRANSFER_FAILED" $_.Exception.Message
            $result.Error = $_.Exception.Message
            $result.EndTimeUTC = [System.DateTime]::UtcNow.ToString("o")
            return [PSCustomObject]$result
        }

        # Step 4a — BinaryType detection
        if ($BinaryTypeOverride -ne $null) {
            $result.BinaryType = $BinaryTypeOverride
        } elseif (Get-Command Get-BinaryType -ErrorAction SilentlyContinue) {
            $result.BinaryType = Get-BinaryType -Path $LocalBinaryPath
        }

        $isSFX = $result.BinaryType -and $result.BinaryType.IsSFX

        # Step 5 — Launch via WMI Win32_Process::Create
        $commandLine = if ($Arguments) { "`"$RemoteDestPath`" $Arguments" } else { "`"$RemoteDestPath`"" }

        $launchPID = $null
        $launchScope = $null; $classObj = $null
        try {
            $launchScope = New-Object System.Management.ManagementScope("\\$ComputerName\root\cimv2")
            if ($Credential) {
                $launchScope.Options.Username = $Credential.UserName
                $launchScope.Options.Password = $Credential.GetNetworkCredential().Password
            }
            $launchScope.Connect()

            $classObj = New-Object System.Management.ManagementClass($launchScope, "Win32_Process", $null)
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
        } finally {
            if ($classObj)    { try { $classObj.Dispose() }    catch {} }
            if ($launchScope) { try { $launchScope.Dispose() } catch {} }
        }

        $result.PID = $launchPID

        if ($isSFX) {
            # SFX flow: poll for process exit via WMI
            $sfxType = $result.BinaryType.SFXType
            Add-State "LAUNCHED" "SFX type=$sfxType detected; using exit code check"

            $sfxExited   = $false
            $wmiErrors   = 0
            $sfxTimer    = [System.Diagnostics.Stopwatch]::StartNew()
            while (-not $sfxExited) {
                Start-Sleep -Seconds 2
                if ($sfxTimer.Elapsed.TotalSeconds -ge $SfxTimeoutSeconds) {
                    Add-State "LAUNCH_FAILED" "SFX timed out after ${SfxTimeoutSeconds}s"
                    $result.Error = "SFX timed out after ${SfxTimeoutSeconds}s"
                    $result.EndTimeUTC = [System.DateTime]::UtcNow.ToString("o")
                    return [PSCustomObject]$result
                }
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

            # Step 6 — Alive check via WMI
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
                # WMI query failed — cannot confirm process is running.
                # Report ALIVE_ASSUMED so consumers know the check was inconclusive.
                $aliveResult = 'ALIVE_ASSUMED'
                Add-State "ALIVE_ASSUMED" "PID=$launchPID assumed alive (WMI check error: $($_.Exception.Message))"
                $result.Error = "WMI alive-check failed: $($_.Exception.Message)"
            }

            if ($aliveResult -eq 'ALIVE' -or $aliveResult -eq 'ALIVE_ASSUMED') {
                if ($result.States[$result.States.Count - 1].State -ne 'ALIVE' -and
                    $result.States[$result.States.Count - 1].State -ne 'ALIVE_ASSUMED') {
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
        # Always clean up PSDrive mapping
        if ($smbDriveName) {
            try { Remove-PSDrive -Name $smbDriveName -Force -ErrorAction SilentlyContinue } catch { }
        }
        $result.EndTimeUTC = [System.DateTime]::UtcNow.ToString("o")
    }

    return [PSCustomObject]$result
}

Export-ModuleMember -Function Invoke-Executor
