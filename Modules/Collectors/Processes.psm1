#Requires -Version 5.1
# ╔══════════════════════════════════════╗
# ║  Quicker — Processes.psm1           ║
# ║  Process list via CIM (PS3+) or WMI ║
# ║  (PS2). Includes .NET fallback.     ║
# ╠══════════════════════════════════════╣
# ║  Exports   : Invoke-Collector       ║
# ║  Inputs    : -Session               ║
# ║              -TargetPSVersion       ║
# ║              -TargetCapabilities    ║
# ║  Output    : @{ data=processes[];   ║
# ║               source=string;        ║
# ║               errors=[] }           ║
# ║  Depends   : Core\DateTime.psm1     ║
# ║  PS compat : 2.0+ (target-side)     ║
# ║  Version   : 2.3                    ║
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
    $out = @()
    $outerErrors = @()
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

        # SHA256
        $r = _sha256 $exePath; $sha256Val = $r[0]; $sha256Err = $r[1]

        # Signature inline (PS 2.0 compatible)
        $sigObj = $null
        if ($exePath) {
            try {
                $cert2 = [System.Security.Cryptography.X509Certificates.X509Certificate]::CreateFromSignedFile($exePath)
                $sigObj = New-Object PSObject -Property @{
                    IsSigned = $true; IsValid = $null; Status = 'PS2_SIGNED'
                    SignerSubject = $cert2.Subject; SignerCompany = $null
                    Thumbprint = $null; NotAfter = $null; TimeStamper = $null
                }
            } catch {
                $sigObj = New-Object PSObject -Property @{
                    IsSigned = $null; IsValid = $null; Status = 'PS2_UNSUPPORTED'
                    SignerSubject = $null; SignerCompany = $null
                    Thumbprint = $null; NotAfter = $null; TimeStamper = $null
                }
            }
        }

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
                $exeFn = $null; $startT = $null; $ws2 = [long]0; $vs2 = [long]0
                try { $exeFn  = $dp.MainModule.FileName }                                          catch {}
                try { $startT = $dp.StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } catch {}
                try { $ws2    = [long]$dp.WorkingSet64 }                                           catch {}
                try { $vs2    = [long]$dp.VirtualMemorySize64 }                                    catch {}
                $r = _sha256 $exeFn; $sha256Fb = $r[0]; $sha256ErrFb = $r[1]
                $dotnet += New-Object PSObject -Property @{
                    ProcessId = [int]$dp.Id; ParentProcessId = $null
                    Name = $dp.ProcessName; CommandLine = $null; ExecutablePath = $exeFn
                    CreationDate = $startT; WorkingSetSize = $ws2; VirtualSize = $vs2
                    SessionId = $null; HandleCount = $null; SHA256 = $sha256Fb; SHA256Error = $sha256ErrFb; Signature = $null
                    source = 'dotnet_fallback'
                }
            }
        }
    } catch {}
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
    $out = @()
    $outerErrors = @()
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
            SessionId = $null; HandleCount = $null
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

        # SHA256
        $r = _sha256 $entry.ExecutablePath; $entry.SHA256 = $r[0]; $entry.SHA256Error = $r[1]

        # Signature inline (PS 3+)
        if ($entry.ExecutablePath) {
            try {
                $sig3 = Get-AuthenticodeSignature -FilePath $entry.ExecutablePath -ErrorAction Stop
                $cert3 = $null; $cn3 = $null
                if ($sig3.SignerCertificate) {
                    $subj3 = $sig3.SignerCertificate.Subject
                    $cn3 = if ($subj3 -match 'CN=([^,]+)') { $Matches[1].Trim() } else { $null }
                    $cert3 = New-Object PSObject -Property @{
                        Subject=$subj3; Issuer=$sig3.SignerCertificate.Issuer
                        Thumbprint=$sig3.SignerCertificate.Thumbprint
                        NotAfter=$sig3.SignerCertificate.NotAfter.ToString('o'); CN=$cn3
                    }
                }
                $entry.Signature = New-Object PSObject -Property @{
                    IsSigned  = ($sig3.Status -ne 'NotSigned')
                    IsValid   = ($sig3.Status -eq 'Valid')
                    Status    = $sig3.Status.ToString()
                    SignerSubject = if ($cert3) { $cert3.Subject } else { $null }
                    SignerCompany = if ($cert3) { $cert3.CN } else { $null }
                    Thumbprint    = if ($cert3) { $cert3.Thumbprint } else { $null }
                    NotAfter      = if ($cert3) { $cert3.NotAfter } else { $null }
                    TimeStamper   = if ($sig3.TimeStamperCertificate) { $sig3.TimeStamperCertificate.Subject } else { $null }
                }
            } catch {
                $entry.Signature = New-Object PSObject -Property @{
                    IsSigned=$null; IsValid=$null; Status="ERROR: $($_.Exception.Message)"
                    SignerSubject=$null; SignerCompany=$null; Thumbprint=$null; NotAfter=$null; TimeStamper=$null
                }
            }
        }

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
                $exeFn = $null; $startT = $null; $ws2 = [long]0; $vs2 = [long]0
                try { $exeFn  = $dp.MainModule.FileName }                                          catch {}
                try { $startT = $dp.StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } catch {}
                try { $ws2    = [long]$dp.WorkingSet64 }                                           catch {}
                try { $vs2    = [long]$dp.VirtualMemorySize64 }                                    catch {}
                $r = _sha256 $exeFn; $sha256Fb2 = $r[0]; $sha256ErrFb2 = $r[1]
                $sigFb2 = $null
                if ($exeFn) {
                    try {
                        $sigX = Get-AuthenticodeSignature -FilePath $exeFn -ErrorAction Stop
                        $certX = $null; $cnX = $null
                        if ($sigX.SignerCertificate) {
                            $subjX = $sigX.SignerCertificate.Subject
                            $cnX = if ($subjX -match 'CN=([^,]+)') { $Matches[1].Trim() } else { $null }
                        }
                        $sigFb2 = New-Object PSObject -Property @{
                            IsSigned=($sigX.Status -ne 'NotSigned'); IsValid=($sigX.Status -eq 'Valid')
                            Status=$sigX.Status.ToString()
                            SignerSubject=if ($sigX.SignerCertificate){$sigX.SignerCertificate.Subject}else{$null}
                            SignerCompany=$cnX; Thumbprint=if($sigX.SignerCertificate){$sigX.SignerCertificate.Thumbprint}else{$null}
                            NotAfter=if($sigX.SignerCertificate){$sigX.SignerCertificate.NotAfter.ToString('o')}else{$null}
                            TimeStamper=if($sigX.TimeStamperCertificate){$sigX.TimeStamperCertificate.Subject}else{$null}
                        }
                    } catch {}
                }
                $dotnet += New-Object PSObject -Property @{
                    ProcessId = [int]$dp.Id; ParentProcessId = $null
                    Name = $dp.ProcessName; CommandLine = $null; ExecutablePath = $exeFn
                    CreationDateUtc = $startT; CreationDate = $null
                    WorkingSetSize = $ws2; VirtualSize = $vs2
                    SessionId = $null; HandleCount = $null
                    SHA256 = $sha256Fb2; SHA256Error = $sha256ErrFb2; Signature = $sigFb2
                    source = 'dotnet_fallback'
                }
            }
        }
    } catch {}
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
                            IsSigned     = $p.Signature.IsSigned
                            IsValid      = $p.Signature.IsValid
                            Status       = $p.Signature.Status
                            SignerSubject = $p.Signature.SignerSubject
                            SignerCompany = $p.Signature.SignerCompany
                            Thumbprint   = $p.Signature.Thumbprint
                            NotAfter     = $p.Signature.NotAfter
                            TimeStamper  = $p.Signature.TimeStamper
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

                    # SHA256
                    $r = _sha256 $entry.ExecutablePath; $entry.SHA256 = $r[0]; $entry.SHA256Error = $r[1]

                    # Signature inline (local CIM path, PS 3+)
                    if ($entry.ExecutablePath) {
                        try {
                            $sigL = Get-AuthenticodeSignature -FilePath $entry.ExecutablePath -ErrorAction Stop
                            $certL = $null; $cnL = $null
                            if ($sigL.SignerCertificate) {
                                $subjL = $sigL.SignerCertificate.Subject
                                $cnL = if ($subjL -match 'CN=([^,]+)') { $Matches[1].Trim() } else { $null }
                            }
                            $entry.Signature = @{
                                IsSigned     = ($sigL.Status -ne 'NotSigned')
                                IsValid      = ($sigL.Status -eq 'Valid')
                                Status       = $sigL.Status.ToString()
                                SignerSubject = if ($sigL.SignerCertificate) { $sigL.SignerCertificate.Subject } else { $null }
                                SignerCompany = $cnL
                                Thumbprint   = if ($sigL.SignerCertificate) { $sigL.SignerCertificate.Thumbprint } else { $null }
                                NotAfter     = if ($sigL.SignerCertificate) { $sigL.SignerCertificate.NotAfter.ToString('o') } else { $null }
                                TimeStamper  = if ($sigL.TimeStamperCertificate) { $sigL.TimeStamperCertificate.Subject } else { $null }
                            }
                        } catch {
                            $entry.Signature = @{
                                IsSigned=$null; IsValid=$null; Status="ERROR: $($_.Exception.Message)"
                                SignerSubject=$null; SignerCompany=$null; Thumbprint=$null; NotAfter=$null; TimeStamper=$null
                            }
                        }
                    }

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
                            $exeFn = $null; $startT = $null; $ws2 = [long]0; $vs2 = [long]0
                            try { $exeFn  = $dp.MainModule.FileName }                                          catch {}
                            try { $startT = $dp.StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } catch {}
                            try { $ws2    = [long]$dp.WorkingSet64 }                                           catch {}
                            try { $vs2    = [long]$dp.VirtualMemorySize64 }                                    catch {}
                            $r = _sha256 $exeFn; $sha256Fb3 = $r[0]; $sha256ErrFb3 = $r[1]; $sigFb3 = $null
                            if ($exeFn) {
                                try {
                                    $sigFb3x = Get-AuthenticodeSignature -FilePath $exeFn -ErrorAction Stop
                                    $cnFb3 = $null
                                    if ($sigFb3x.SignerCertificate -and $sigFb3x.SignerCertificate.Subject -match 'CN=([^,]+)') { $cnFb3 = $Matches[1].Trim() }
                                    $sigFb3 = @{
                                        IsSigned=($sigFb3x.Status -ne 'NotSigned'); IsValid=($sigFb3x.Status -eq 'Valid')
                                        Status=$sigFb3x.Status.ToString()
                                        SignerSubject=if($sigFb3x.SignerCertificate){$sigFb3x.SignerCertificate.Subject}else{$null}
                                        SignerCompany=$cnFb3
                                        Thumbprint=if($sigFb3x.SignerCertificate){$sigFb3x.SignerCertificate.Thumbprint}else{$null}
                                        NotAfter=if($sigFb3x.SignerCertificate){$sigFb3x.SignerCertificate.NotAfter.ToString('o')}else{$null}
                                        TimeStamper=if($sigFb3x.TimeStamperCertificate){$sigFb3x.TimeStamperCertificate.Subject}else{$null}
                                    }
                                } catch {}
                            } else { $sha256ErrFb3 = 'PATH_NULL' }
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
                                SessionId        = $null
                                HandleCount      = $null
                                SHA256           = $sha256Fb3
                                SHA256Error      = $sha256ErrFb3
                                Signature        = $sigFb3
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
                    Write-Log 'WARN' ".NET cross-check failed: $($_.Exception.Message)"
                }

            } else {
                # WMI path
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

                    # SHA256
                    $r = _sha256 $exePath; $sha256W = $r[0]; $sha256ErrW = $r[1]

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
                        SHA256           = $sha256W
                        SHA256Error      = $sha256ErrW
                        Signature        = $null
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
                            $exeFn = $null; $startT = $null; $ws2 = [long]0; $vs2 = [long]0
                            try { $exeFn  = $dp.MainModule.FileName }                                          catch {}
                            try { $startT = $dp.StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } catch {}
                            try { $ws2    = [long]$dp.WorkingSet64 }                                           catch {}
                            try { $vs2    = [long]$dp.VirtualMemorySize64 }                                    catch {}
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
                                SessionId        = $null
                                HandleCount      = $null
                                SHA256           = $null
                                SHA256Error      = if ($exeFn) { $null } else { 'PATH_NULL' }
                                Signature        = $null
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
