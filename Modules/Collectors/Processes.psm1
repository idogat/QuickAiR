#Requires -Version 5.1
# ╔══════════════════════════════════════╗
# ║  Quicker — Processes.psm1           ║
# ║  Process list via CIM (PS3+) or WMI ║
# ║  (PS2). Includes .NET fallback.     ║
# ╠══════════════════════════════════════╣
# ║  Exports   : Invoke-Collector       ║
# ║  Helpers   : _sha256, _getSigPS3    ║
# ║  SB helpers: _sha256, _getSigPS2    ║
# ║              (WMI), _getSigPS3 (CIM)║
# ║  Inputs    : -Session               ║
# ║              -TargetPSVersion       ║
# ║              -TargetCapabilities    ║
# ║  Output    : @{ data=processes[];   ║
# ║               source=string;        ║
# ║               errors=[] }           ║
# ║  Fields    : ProcessId, PPID, Name, ║
# ║    CommandLine, ExecutablePath,      ║
# ║    CreationDateUTC, WorkingSetSize,  ║
# ║    VirtualSize, SessionId,           ║
# ║    HandleCount, Owner, SHA256,       ║
# ║    SHA256Error, Signature, source    ║
# ║  Depends   : Core\DateTime.psm1     ║
# ║  PS compat : 2.0+ (target-side)     ║
# ║  Version   : 2.5                    ║
# ╚══════════════════════════════════════╝

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# PS 2.0-compatible WMI process enumeration scriptblock
$script:PROC_SB_WMI = {
    function _sha256($p) {
        if (-not $p) { return @($null, 'PATH_NULL') }
        try {
            if (-not [System.IO.File]::Exists($p)) { return @($null, 'FILE_NOT_FOUND') }
            $b = [System.IO.File]::ReadAllBytes($p)
            $s = [Security.Cryptography.SHA256]::Create()
            $h = $s.ComputeHash($b); $s.Dispose()
            return @(([BitConverter]::ToString($h) -replace '-','').ToLower(), $null)
        } catch {
            $m = $_.Exception.Message
            if ($m -match 'Access') { return @($null, 'ACCESS_DENIED') }
            elseif ($m -match 'not find|not exist|cannot find') { return @($null, 'FILE_NOT_FOUND') }
            else { return @($null, "COMPUTE_ERROR: $m") }
        }
    }
    function _getSigPS2($path) {
        if (-not $path) { return $null }
        try {
            $cert = [System.Security.Cryptography.X509Certificates.X509Certificate]::CreateFromSignedFile($path)
            return New-Object PSObject -Property @{
                IsSigned=$true; IsValid=$null; Status='PS2_CERT_PRESENT'
                SignerSubject=$cert.Subject; SignerCompany=$null; Issuer=$cert.Issuer
                Thumbprint=$null; NotAfter=$null; TimeStamper=$null
                IsOSBinary=$null; SignatureType=$null
            }
        } catch {
            return New-Object PSObject -Property @{
                IsSigned=$null; IsValid=$null; Status='PS2_UNSUPPORTED'
                SignerSubject=$null; SignerCompany=$null; Issuer=$null
                Thumbprint=$null; NotAfter=$null; TimeStamper=$null
                IsOSBinary=$null; SignatureType=$null
            }
        }
    }
    $out = @()
    $outerErrors = @()
    $sha256Cache = @{}
    $searcher = New-Object System.Management.ManagementObjectSearcher("root\cimv2", "SELECT * FROM Win32_Process")
    $searcher.Options.ReturnImmediately = $false
    $searcher.Options.Rewindable = $false
    $procs = $searcher.Get()
    foreach ($p in $procs) {
        try {
        $pid_ = $null; $ppid = $null; $name_ = $null; $cmdLine = $null; $exePath = $null; $cdate = $null; $ws = [long]0; $vs = [long]0; $sid = $null; $hc = $null
        try { $pid_   = [int]$p.ProcessId }       catch {}
        try { $ppid   = [int]$p.ParentProcessId } catch {}
        try { $name_  = $p.Name }                 catch {}
        try { $cmdLine = $p.CommandLine }          catch {}
        try { $exePath = $p.ExecutablePath }       catch {}
        try { $cdate  = $p.CreationDate }          catch {}
        try { $ws     = [long]$p.WorkingSetSize }  catch {}
        try { $vs     = [long]$p.VirtualSize }     catch {}
        try { $sid    = [int]$p.SessionId }        catch {}
        try { $hc     = [int]$p.HandleCount }      catch {}

        # Owner via GetOwner()
        $owner = $null
        try {
            $ownerInfo = $p.InvokeMethod('GetOwner', $null)
            if ($ownerInfo -and $ownerInfo['ReturnValue'] -eq 0) {
                $d = $ownerInfo['Domain']; $u = $ownerInfo['User']
                $owner = if ($d) { "$d\$u" } else { $u }
            }
        } catch {}

        # SHA256 with cache
        $sha256Val = $null; $sha256Err = $null
        if ($exePath -and $sha256Cache.ContainsKey($exePath)) {
            $sha256Val = $sha256Cache[$exePath][0]; $sha256Err = $sha256Cache[$exePath][1]
        } else {
            $r = _sha256 $exePath; $sha256Val = $r[0]; $sha256Err = $r[1]
            if ($exePath) { $sha256Cache[$exePath] = @($sha256Val, $sha256Err) }
        }

        # Signature (PS 2.0 compatible)
        $sigObj = _getSigPS2 $exePath

        if ($pid_ -ne $null) {
            $out += New-Object PSObject -Property @{
                ProcessId       = $pid_
                ParentProcessId = $ppid
                Name            = $name_
                CommandLine     = $cmdLine
                ExecutablePath  = $exePath
                CreationDate    = $cdate
                WorkingSetSize  = $ws
                VirtualSize     = $vs
                SessionId       = $sid
                HandleCount     = $hc
                Owner           = $owner
                SHA256          = $sha256Val
                SHA256Error     = $sha256Err
                Signature       = $sigObj
                source          = 'wmi'
            }
        }
        } catch {
            $outerErrors += "WMI process loop error: $($_.Exception.Message)"
            continue
        }
    }
    # .NET cross-check
    $dotnet = @()
    try {
        $dnProcs = [System.Diagnostics.Process]::GetProcesses()
        $wmiPids = @{}; foreach ($x in $out) { $wmiPids[$x.ProcessId] = $true }
        foreach ($dp in $dnProcs) {
            if (-not $wmiPids.ContainsKey([int]$dp.Id)) {
                $exeFn = $null; $startT = $null; $ws2 = [long]0; $vs2 = [long]0; $sid2 = $null; $hc2 = $null
                try { $exeFn  = $dp.MainModule.FileName }                                          catch {}
                try { $startT = $dp.StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } catch {}
                try { $ws2    = [long]$dp.WorkingSet64 }                                           catch {}
                try { $vs2    = [long]$dp.VirtualMemorySize64 }                                    catch {}
                try { $sid2   = [int]$dp.SessionId }                                               catch {}
                try { $hc2    = [int]$dp.HandleCount }                                             catch {}
                # SHA256 with cache
                $sha256Fb = $null; $sha256ErrFb = $null
                if ($exeFn -and $sha256Cache.ContainsKey($exeFn)) {
                    $sha256Fb = $sha256Cache[$exeFn][0]; $sha256ErrFb = $sha256Cache[$exeFn][1]
                } else {
                    $r = _sha256 $exeFn; $sha256Fb = $r[0]; $sha256ErrFb = $r[1]
                    if ($exeFn) { $sha256Cache[$exeFn] = @($sha256Fb, $sha256ErrFb) }
                }
                $sigFb = _getSigPS2 $exeFn
                $dotnet += New-Object PSObject -Property @{
                    ProcessId = [int]$dp.Id; ParentProcessId = $null
                    Name = $dp.ProcessName; CommandLine = $null; ExecutablePath = $exeFn
                    CreationDate = $startT; WorkingSetSize = $ws2; VirtualSize = $vs2
                    SessionId = $sid2; HandleCount = $hc2; Owner = $null
                    SHA256 = $sha256Fb; SHA256Error = $sha256ErrFb; Signature = $sigFb
                    source = 'dotnet_fallback'
                }
            }
        }
    } catch {
        $outerErrors += ".NET cross-check failed: $($_.Exception.Message)"
    }
    $out += $dotnet
    New-Object PSObject -Property @{ Procs = $out; FallbackCount = $dotnet.Count; OuterErrors = $outerErrors }
}

# CIM scriptblock for PS 3+ path
$script:PROC_SB_CIM = {
    function _sha256($p) {
        if (-not $p) { return @($null, 'PATH_NULL') }
        try {
            if (-not [System.IO.File]::Exists($p)) { return @($null, 'FILE_NOT_FOUND') }
            $b = [System.IO.File]::ReadAllBytes($p)
            $s = [Security.Cryptography.SHA256]::Create()
            $h = $s.ComputeHash($b); $s.Dispose()
            return @(([BitConverter]::ToString($h) -replace '-','').ToLower(), $null)
        } catch {
            $m = $_.Exception.Message
            if ($m -match 'Access') { return @($null, 'ACCESS_DENIED') }
            elseif ($m -match 'not find|not exist|cannot find') { return @($null, 'FILE_NOT_FOUND') }
            else { return @($null, "COMPUTE_ERROR: $m") }
        }
    }
    function _getSigPS3($path) {
        if (-not $path) { return $null }
        try {
            $sig = Get-AuthenticodeSignature -FilePath $path -ErrorAction Stop
            $cn = $null
            if ($sig.SignerCertificate -and $sig.SignerCertificate.Subject -match 'CN=([^,]+)') {
                $cn = $Matches[1].Trim()
            }
            $isOSBin = $null; try { $isOSBin = $sig.IsOSBinary } catch {}
            $sigType = $null; try { $sigType = $sig.SignatureType.ToString() } catch {}
            return New-Object PSObject -Property @{
                IsSigned      = ($sig.Status -ne 'NotSigned')
                IsValid       = ($sig.Status -eq 'Valid')
                Status        = $sig.Status.ToString()
                SignerSubject = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { $null }
                SignerCompany = $cn
                Issuer        = if ($sig.SignerCertificate) { $sig.SignerCertificate.Issuer } else { $null }
                Thumbprint    = if ($sig.SignerCertificate) { $sig.SignerCertificate.Thumbprint } else { $null }
                NotAfter      = if ($sig.SignerCertificate) { $sig.SignerCertificate.NotAfter.ToString('o') } else { $null }
                TimeStamper   = if ($sig.TimeStamperCertificate) { $sig.TimeStamperCertificate.Subject } else { $null }
                IsOSBinary    = $isOSBin
                SignatureType = $sigType
            }
        } catch {
            return New-Object PSObject -Property @{
                IsSigned=$null; IsValid=$null; Status="ERROR: $($_.Exception.Message)"
                SignerSubject=$null; SignerCompany=$null; Issuer=$null
                Thumbprint=$null; NotAfter=$null; TimeStamper=$null
                IsOSBinary=$null; SignatureType=$null
            }
        }
    }
    $out = @()
    $outerErrors = @()
    $sha256Cache = @{}
    $raw = Get-CimInstance Win32_Process -OperationTimeoutSec 60
    foreach ($p in $raw) {
        try {
        $pid_ = $null; $ppid = $null; $name_ = $null
        try { $pid_  = [int]$p.ProcessId }       catch {}
        try { $ppid  = [int]$p.ParentProcessId } catch {}
        try { $name_ = $p.Name }                 catch {}
        if ($pid_ -eq $null) { continue }
        $entry = New-Object PSObject -Property @{
            ProcessId = $pid_; ParentProcessId = $ppid; Name = $name_
            CommandLine = $null; ExecutablePath = $null
            CreationDateUtc = $null; CreationDate = $null
            WorkingSetSize = [long]0; VirtualSize = [long]0
            SessionId = $null; HandleCount = $null; Owner = $null
            SHA256 = $null; SHA256Error = $null; Signature = $null
            source = 'cim'
        }
        try { $entry.CommandLine     = $p.CommandLine } catch {}
        try { $entry.ExecutablePath  = $p.ExecutablePath } catch {}
        try { $entry.CreationDateUtc = if ($p.CreationDate) { $p.CreationDate.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $null } } catch {}
        try { $entry.CreationDate    = $null } catch {}
        try { $entry.WorkingSetSize  = [long]$p.WorkingSetSize } catch {}
        try { $entry.VirtualSize     = [long]$p.VirtualSize }    catch {}
        try { $entry.SessionId       = [int]$p.SessionId }       catch {}
        try { $entry.HandleCount     = [int]$p.HandleCount }     catch {}

        # Owner via Invoke-CimMethod
        try {
            $ownerResult = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction Stop
            if ($ownerResult.ReturnValue -eq 0) {
                $d = $ownerResult.Domain; $u = $ownerResult.User
                $entry.Owner = if ($d) { "$d\$u" } else { $u }
            }
        } catch {}

        # SHA256 with cache
        if ($entry.ExecutablePath -and $sha256Cache.ContainsKey($entry.ExecutablePath)) {
            $entry.SHA256 = $sha256Cache[$entry.ExecutablePath][0]; $entry.SHA256Error = $sha256Cache[$entry.ExecutablePath][1]
        } else {
            $r = _sha256 $entry.ExecutablePath; $entry.SHA256 = $r[0]; $entry.SHA256Error = $r[1]
            if ($entry.ExecutablePath) { $sha256Cache[$entry.ExecutablePath] = @($entry.SHA256, $entry.SHA256Error) }
        }

        # Signature (PS 3+)
        $entry.Signature = _getSigPS3 $entry.ExecutablePath

        $out += $entry
        } catch {
            $outerErrors += "CIM process loop error PID=$($p.ProcessId): $($_.Exception.Message)"
            continue
        }
    }
    # .NET cross-check
    $dotnet = @()
    try {
        $dnProcs = [System.Diagnostics.Process]::GetProcesses()
        $cimPids = @{}; foreach ($x in $out) { $cimPids[$x.ProcessId] = $true }
        foreach ($dp in $dnProcs) {
            if (-not $cimPids.ContainsKey([int]$dp.Id)) {
                $exeFn = $null; $startT = $null; $ws2 = [long]0; $vs2 = [long]0; $sid2 = $null; $hc2 = $null
                try { $exeFn  = $dp.MainModule.FileName }                                          catch {}
                try { $startT = $dp.StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } catch {}
                try { $ws2    = [long]$dp.WorkingSet64 }                                           catch {}
                try { $vs2    = [long]$dp.VirtualMemorySize64 }                                    catch {}
                try { $sid2   = [int]$dp.SessionId }                                               catch {}
                try { $hc2    = [int]$dp.HandleCount }                                             catch {}
                # SHA256 with cache
                $sha256Fb2 = $null; $sha256ErrFb2 = $null
                if ($exeFn -and $sha256Cache.ContainsKey($exeFn)) {
                    $sha256Fb2 = $sha256Cache[$exeFn][0]; $sha256ErrFb2 = $sha256Cache[$exeFn][1]
                } else {
                    $r = _sha256 $exeFn; $sha256Fb2 = $r[0]; $sha256ErrFb2 = $r[1]
                    if ($exeFn) { $sha256Cache[$exeFn] = @($sha256Fb2, $sha256ErrFb2) }
                }
                $sigFb2 = _getSigPS3 $exeFn
                $dotnet += New-Object PSObject -Property @{
                    ProcessId = [int]$dp.Id; ParentProcessId = $null
                    Name = $dp.ProcessName; CommandLine = $null; ExecutablePath = $exeFn
                    CreationDateUtc = $startT; CreationDate = $null
                    WorkingSetSize = $ws2; VirtualSize = $vs2
                    SessionId = $sid2; HandleCount = $hc2; Owner = $null
                    SHA256 = $sha256Fb2; SHA256Error = $sha256ErrFb2; Signature = $sigFb2
                    source = 'dotnet_fallback'
                }
            }
        }
    } catch {
        $outerErrors += ".NET cross-check failed: $($_.Exception.Message)"
    }
    $out += $dotnet
    New-Object PSObject -Property @{ Procs = $out; FallbackCount = $dotnet.Count; OuterErrors = $outerErrors }
}

function _sha256($p) {
    if (-not $p) { return @($null, 'PATH_NULL') }
    try {
        if (-not [System.IO.File]::Exists($p)) { return @($null, 'FILE_NOT_FOUND') }
        $b = [System.IO.File]::ReadAllBytes($p)
        $s = [Security.Cryptography.SHA256]::Create()
        $h = $s.ComputeHash($b); $s.Dispose()
        return @(([BitConverter]::ToString($h) -replace '-','').ToLower(), $null)
    } catch {
        $m = $_.Exception.Message
        if ($m -match 'Access') { return @($null, 'ACCESS_DENIED') }
        elseif ($m -match 'not find|not exist|cannot find') { return @($null, 'FILE_NOT_FOUND') }
        else { return @($null, "COMPUTE_ERROR: $m") }
    }
}

function _getSigPS3($path) {
    if (-not $path) { return $null }
    try {
        $sig = Get-AuthenticodeSignature -FilePath $path -ErrorAction Stop
        $cn = $null
        if ($sig.SignerCertificate -and $sig.SignerCertificate.Subject -match 'CN=([^,]+)') {
            $cn = $Matches[1].Trim()
        }
        $isOSBin = $null; try { $isOSBin = $sig.IsOSBinary } catch {}
        $sigType = $null; try { $sigType = $sig.SignatureType.ToString() } catch {}
        return @{
            IsSigned      = ($sig.Status -ne 'NotSigned')
            IsValid       = ($sig.Status -eq 'Valid')
            Status        = $sig.Status.ToString()
            SignerSubject = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { $null }
            SignerCompany = $cn
            Issuer        = if ($sig.SignerCertificate) { $sig.SignerCertificate.Issuer } else { $null }
            Thumbprint    = if ($sig.SignerCertificate) { $sig.SignerCertificate.Thumbprint } else { $null }
            NotAfter      = if ($sig.SignerCertificate) { $sig.SignerCertificate.NotAfter.ToString('o') } else { $null }
            TimeStamper   = if ($sig.TimeStamperCertificate) { $sig.TimeStamperCertificate.Subject } else { $null }
            IsOSBinary    = $isOSBin
            SignatureType = $sigType
        }
    } catch {
        return @{
            IsSigned=$null; IsValid=$null; Status="ERROR: $($_.Exception.Message)"
            SignerSubject=$null; SignerCompany=$null; Issuer=$null
            Thumbprint=$null; NotAfter=$null; TimeStamper=$null
            IsOSBinary=$null; SignatureType=$null
        }
    }
}

function Invoke-Collector {
    param(
        $Session,
        $TargetPSVersion,
        $TargetCapabilities
    )

    $errors       = @()
    $procs        = @()
    $fallbackNote = $null
    $sourceStr    = 'unknown'

    try {
        if ($Session -ne $null) {
            # Remote path
            $sb = if ($TargetPSVersion -ge 3) { $script:PROC_SB_CIM } else { $script:PROC_SB_WMI }
            $r   = Invoke-Command -Session $Session -ScriptBlock $sb
            $raw = $r.Procs
            if ($r.FallbackCount -gt 0) {
                $fallbackNote = "$($r.FallbackCount) process(es) added via .NET fallback on remote (absent from WMI/CIM)"
                Write-Log 'WARN' "Remote: $fallbackNote"
            }
            $baseSource = if ($TargetPSVersion -ge 3) { 'cim' } else { 'wmi' }
            $sourceStr  = if ($r.FallbackCount -gt 0) { "$baseSource+dotnet_fallback" } else { $baseSource }

            foreach ($p in $raw) {
                try {
                $utcVal = if ($p.CreationDateUtc)  { $p.CreationDateUtc }
                          elseif ($p.CreationDate) { ConvertTo-UtcIso -Value $p.CreationDate -FallbackOffsetMin $TargetCapabilities.TimezoneOffsetMinutes }
                          else                     { $null }
                $locVal = $null
                $pid_   = $null; try { $pid_ = [int]$p.ProcessId } catch {}
                if ($pid_ -eq $null) { continue }
                $ppid2 = $null; try { if ($p.ParentProcessId -ne $null) { $ppid2 = [int]$p.ParentProcessId } } catch {}
                $ws2   = [long]0; try { $ws2 = [long]$p.WorkingSetSize } catch {}
                $vs2   = [long]0; try { $vs2 = [long]$p.VirtualSize }    catch {}
                # Extract Signature hashtable from PSObject
                $sigOut = $null
                if ($p.Signature -ne $null) {
                    try {
                        $sigOut = @{
                            IsSigned      = $p.Signature.IsSigned
                            IsValid       = $p.Signature.IsValid
                            Status        = $p.Signature.Status
                            SignerSubject = $p.Signature.SignerSubject
                            SignerCompany = $p.Signature.SignerCompany
                            Issuer        = $p.Signature.Issuer
                            Thumbprint    = $p.Signature.Thumbprint
                            NotAfter      = $p.Signature.NotAfter
                            TimeStamper   = $p.Signature.TimeStamper
                            IsOSBinary    = $p.Signature.IsOSBinary
                            SignatureType = $p.Signature.SignatureType
                        }
                    } catch {}
                }
                $procs += @{
                    ProcessId        = $pid_
                    ParentProcessId  = $ppid2
                    Name             = $p.Name
                    CommandLine      = $p.CommandLine
                    ExecutablePath   = $p.ExecutablePath
                    CreationDateUTC  = $utcVal
                    CreationDateLocal = $locVal
                    WorkingSetSize   = $ws2
                    VirtualSize      = $vs2
                    SessionId        = $p.SessionId
                    HandleCount      = $p.HandleCount
                    Owner            = $p.Owner
                    SHA256           = $p.SHA256
                    SHA256Error      = $p.SHA256Error
                    Signature        = $sigOut
                    source           = $p.source
                }
                } catch {
                    $errors += @{ artifact='process_loop'; message=$_.Exception.Message }
                    Write-Log 'WARN' "Remote process loop error: $($_.Exception.Message)"
                    continue
                }
            }
        } else {
            # Local path
            $sha256Cache = @{}
            if ($TargetCapabilities.PSVersion -ge 3) {
                # CIM path - per-process try/catch to never silently drop
                $raw = Get-CimInstance Win32_Process -OperationTimeoutSec 60
                $sourceStr = 'cim'
                $fallbackCount = 0
                foreach ($p in $raw) {
                    try {
                    $pid_ = $null; $ppid = $null; $name_ = $null
                    try { $pid_  = [int]$p.ProcessId }       catch {}
                    try { $ppid  = [int]$p.ParentProcessId } catch {}
                    try { $name_ = $p.Name }                 catch {}
                    if ($pid_ -eq $null) { continue }
                    $entry = @{
                        ProcessId        = $pid_
                        ParentProcessId  = $ppid
                        Name             = $name_
                        CommandLine      = $null
                        ExecutablePath   = $null
                        CreationDateUTC  = $null
                        CreationDateLocal = $null
                        WorkingSetSize   = [long]0
                        VirtualSize      = [long]0
                        SessionId        = $null
                        HandleCount      = $null
                        Owner            = $null
                        SHA256           = $null
                        SHA256Error      = $null
                        Signature        = $null
                        source           = 'cim'
                    }
                    try { $entry.CommandLine      = $p.CommandLine } catch { $errors += @{ artifact='process_detail'; ProcessId=$pid_; Name=$name_; message=$_.Exception.Message } }
                    try { $entry.ExecutablePath   = $p.ExecutablePath } catch {}
                    try { $entry.CreationDateUTC  = if ($p.CreationDate) { $p.CreationDate.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $null } } catch {}
                    try { $entry.CreationDateLocal = $null } catch {}
                    try { $entry.WorkingSetSize   = [long]$p.WorkingSetSize } catch {}
                    try { $entry.VirtualSize      = [long]$p.VirtualSize }   catch {}
                    try { $entry.SessionId        = [int]$p.SessionId }      catch {}
                    try { $entry.HandleCount      = [int]$p.HandleCount }    catch {}

                    # Owner via Invoke-CimMethod
                    try {
                        $ownerResult = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction Stop
                        if ($ownerResult.ReturnValue -eq 0) {
                            $d = $ownerResult.Domain; $u = $ownerResult.User
                            $entry.Owner = if ($d) { "$d\$u" } else { $u }
                        }
                    } catch {}

                    # SHA256 with cache
                    if ($entry.ExecutablePath -and $sha256Cache.ContainsKey($entry.ExecutablePath)) {
                        $entry.SHA256 = $sha256Cache[$entry.ExecutablePath][0]; $entry.SHA256Error = $sha256Cache[$entry.ExecutablePath][1]
                    } else {
                        $r = _sha256 $entry.ExecutablePath; $entry.SHA256 = $r[0]; $entry.SHA256Error = $r[1]
                        if ($entry.ExecutablePath) { $sha256Cache[$entry.ExecutablePath] = @($entry.SHA256, $entry.SHA256Error) }
                    }

                    # Signature (local CIM path, PS 3+)
                    $entry.Signature = _getSigPS3 $entry.ExecutablePath

                    $procs += $entry
                    } catch {
                        $errors += @{ artifact='process_loop'; message=$_.Exception.Message }
                        Write-Log 'WARN' "Process loop error: $($_.Exception.Message)"
                        continue
                    }
                }

                # .NET cross-check
                try {
                    $dnProcs       = [System.Diagnostics.Process]::GetProcesses()
                    $collectedPIDs = @{}
                    foreach ($x in $procs) { $collectedPIDs[[int]$x.ProcessId] = $true }
                    foreach ($dp in $dnProcs) {
                        if (-not $collectedPIDs.ContainsKey([int]$dp.Id)) {
                            $exeFn = $null; $startT = $null; $ws2 = [long]0; $vs2 = [long]0; $sid2 = $null; $hc2 = $null
                            try { $exeFn  = $dp.MainModule.FileName }                                          catch {}
                            try { $startT = $dp.StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } catch {}
                            try { $ws2    = [long]$dp.WorkingSet64 }                                           catch {}
                            try { $vs2    = [long]$dp.VirtualMemorySize64 }                                    catch {}
                            try { $sid2   = [int]$dp.SessionId }                                               catch {}
                            try { $hc2    = [int]$dp.HandleCount }                                             catch {}
                            # SHA256 with cache
                            $sha256Fb3 = $null; $sha256ErrFb3 = $null
                            if ($exeFn -and $sha256Cache.ContainsKey($exeFn)) {
                                $sha256Fb3 = $sha256Cache[$exeFn][0]; $sha256ErrFb3 = $sha256Cache[$exeFn][1]
                            } else {
                                $r = _sha256 $exeFn; $sha256Fb3 = $r[0]; $sha256ErrFb3 = $r[1]
                                if ($exeFn) { $sha256Cache[$exeFn] = @($sha256Fb3, $sha256ErrFb3) }
                            }
                            if (-not $exeFn) { $sha256ErrFb3 = 'PATH_NULL' }
                            $procs += @{
                                ProcessId        = [int]$dp.Id
                                ParentProcessId  = $null
                                Name             = $dp.ProcessName
                                CommandLine      = $null
                                ExecutablePath   = $exeFn
                                CreationDateUTC  = $startT
                                CreationDateLocal = $null
                                WorkingSetSize   = $ws2
                                VirtualSize      = $vs2
                                SessionId        = $sid2
                                HandleCount      = $hc2
                                Owner            = $null
                                SHA256           = $sha256Fb3
                                SHA256Error      = $sha256ErrFb3
                                Signature        = _getSigPS3 $exeFn
                                source           = 'dotnet_fallback'
                            }
                            $fallbackCount++
                            Write-Log 'WARN' "PID=$($dp.Id) Name=$($dp.ProcessName) absent from WMI/CIM - added via .NET fallback"
                        }
                    }
                    if ($fallbackCount -gt 0) {
                        $fallbackNote = "$fallbackCount process(es) added via .NET fallback (absent from WMI/CIM)"
                        $sourceStr = 'cim+dotnet_fallback'
                    }
                } catch {
                    $errors += @{ artifact='dotnet_crosscheck'; message=$_.Exception.Message }
                    Write-Log 'WARN' ".NET cross-check failed: $($_.Exception.Message)"
                }

            } else {
                # WMI path — local collection runs on analyst machine (PS 5.1+)
                $sourceStr = 'wmi'
                $fallbackCount = 0
                $searcher = New-Object System.Management.ManagementObjectSearcher("root\cimv2", "SELECT * FROM Win32_Process")
                $searcher.Options.ReturnImmediately = $false
                $searcher.Options.Rewindable = $false
                $raw2 = $searcher.Get()
                foreach ($p in $raw2) {
                    try {
                    $pid_ = $null; $ppid = $null; $name_ = $null
                    try { $pid_  = [int]$p.ProcessId }       catch {}
                    try { $ppid  = [int]$p.ParentProcessId } catch {}
                    try { $name_ = $p.Name }                 catch {}
                    if ($pid_ -eq $null) { continue }
                    $utc = $null; $cd = $null; $cmdLine = $null; $exePath = $null; $ws = [long]0; $vs = [long]0; $sid = $null; $hc = $null
                    try { $cd      = $p.CreationDate; $utc = ConvertTo-UtcIso -Value $cd -FallbackOffsetMin $TargetCapabilities.TimezoneOffsetMinutes } catch {}
                    try { $cmdLine = $p.CommandLine }         catch { $errors += @{ artifact='process_detail'; ProcessId=$pid_; Name=$name_; message=$_.Exception.Message } }
                    try { $exePath = $p.ExecutablePath }      catch {}
                    try { $ws      = [long]$p.WorkingSetSize } catch {}
                    try { $vs      = [long]$p.VirtualSize }   catch {}
                    try { $sid     = [int]$p.SessionId }      catch {}
                    try { $hc      = [int]$p.HandleCount }    catch {}

                    # Owner via GetOwner()
                    $ownerW = $null
                    try {
                        $ownerInfoW = $p.InvokeMethod('GetOwner', $null)
                        if ($ownerInfoW -and $ownerInfoW['ReturnValue'] -eq 0) {
                            $dW = $ownerInfoW['Domain']; $uW = $ownerInfoW['User']
                            $ownerW = if ($dW) { "$dW\$uW" } else { $uW }
                        }
                    } catch {}

                    # SHA256 with cache
                    $sha256W = $null; $sha256ErrW = $null
                    if ($exePath -and $sha256Cache.ContainsKey($exePath)) {
                        $sha256W = $sha256Cache[$exePath][0]; $sha256ErrW = $sha256Cache[$exePath][1]
                    } else {
                        $r = _sha256 $exePath; $sha256W = $r[0]; $sha256ErrW = $r[1]
                        if ($exePath) { $sha256Cache[$exePath] = @($sha256W, $sha256ErrW) }
                    }

                    # Signature (analyst machine is PS 5.1+, Get-AuthenticodeSignature available)
                    $sigW = _getSigPS3 $exePath

                    $procs += @{
                        ProcessId        = $pid_
                        ParentProcessId  = $ppid
                        Name             = $name_
                        CommandLine      = $cmdLine
                        ExecutablePath   = $exePath
                        CreationDateUTC  = $utc
                        CreationDateLocal = $null
                        WorkingSetSize   = $ws
                        VirtualSize      = $vs
                        SessionId        = $sid
                        HandleCount      = $hc
                        Owner            = $ownerW
                        SHA256           = $sha256W
                        SHA256Error      = $sha256ErrW
                        Signature        = $sigW
                        source           = 'wmi'
                    }
                    } catch {
                        $errors += @{ artifact='process_loop'; message=$_.Exception.Message }
                        Write-Log 'WARN' "WMI Process loop error: $($_.Exception.Message)"
                        continue
                    }
                }

                # .NET cross-check
                try {
                    $dnProcs       = [System.Diagnostics.Process]::GetProcesses()
                    $collectedPIDs = @{}
                    foreach ($x in $procs) { $collectedPIDs[[int]$x.ProcessId] = $true }
                    foreach ($dp in $dnProcs) {
                        if (-not $collectedPIDs.ContainsKey([int]$dp.Id)) {
                            $exeFn = $null; $startT = $null; $ws2 = [long]0; $vs2 = [long]0; $sid2 = $null; $hc2 = $null
                            try { $exeFn  = $dp.MainModule.FileName }                                          catch {}
                            try { $startT = $dp.StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } catch {}
                            try { $ws2    = [long]$dp.WorkingSet64 }                                           catch {}
                            try { $vs2    = [long]$dp.VirtualMemorySize64 }                                    catch {}
                            try { $sid2   = [int]$dp.SessionId }                                               catch {}
                            try { $hc2    = [int]$dp.HandleCount }                                             catch {}
                            # SHA256 with cache
                            $sha256WFb = $null; $sha256ErrWFb = $null
                            if ($exeFn -and $sha256Cache.ContainsKey($exeFn)) {
                                $sha256WFb = $sha256Cache[$exeFn][0]; $sha256ErrWFb = $sha256Cache[$exeFn][1]
                            } else {
                                $r = _sha256 $exeFn; $sha256WFb = $r[0]; $sha256ErrWFb = $r[1]
                                if ($exeFn) { $sha256Cache[$exeFn] = @($sha256WFb, $sha256ErrWFb) }
                            }
                            if (-not $exeFn) { $sha256ErrWFb = 'PATH_NULL' }
                            $procs += @{
                                ProcessId        = [int]$dp.Id
                                ParentProcessId  = $null
                                Name             = $dp.ProcessName
                                CommandLine      = $null
                                ExecutablePath   = $exeFn
                                CreationDateUTC  = $startT
                                CreationDateLocal = $null
                                WorkingSetSize   = $ws2
                                VirtualSize      = $vs2
                                SessionId        = $sid2
                                HandleCount      = $hc2
                                Owner            = $null
                                SHA256           = $sha256WFb
                                SHA256Error      = $sha256ErrWFb
                                Signature        = _getSigPS3 $exeFn
                                source           = 'dotnet_fallback'
                            }
                            $fallbackCount++
                            Write-Log 'WARN' "PID=$($dp.Id) Name=$($dp.ProcessName) absent from WMI/CIM - added via .NET fallback"
                        }
                    }
                    if ($fallbackCount -gt 0) {
                        $fallbackNote = "$fallbackCount process(es) added via .NET fallback (absent from WMI/CIM)"
                        $sourceStr = 'wmi+dotnet_fallback'
                    }
                } catch {
                    $errors += @{ artifact='dotnet_crosscheck'; message=$_.Exception.Message }
                    Write-Log 'WARN' ".NET cross-check failed: $($_.Exception.Message)"
                }
            }
        }
    } catch {
        $errors += @{ artifact = 'processes'; message = $_.Exception.Message }
        Write-Log 'ERROR' "Process collection failed: $($_.Exception.Message)"
    }

    return @{ data = $procs; source = $sourceStr; errors = $errors }
}

Export-ModuleMember -Function Invoke-Collector
