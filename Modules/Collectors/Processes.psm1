#Requires -Version 5.1
# ╔══════════════════════════════════════════╗
# ║  QuickAiR -- Processes.psm1               ║
# ║  Process list via CIM (PS3+), WMI       ║
# ║  (PS2), or WMI remote. .NET fallback.  ║
# ╠══════════════════════════════════════════╣
# ║  Exports   : Invoke-Collector            ║
# ║  Helpers   : _sha256, _getSigPS3,       ║
# ║              _getIntegrityLevel          ║
# ║  SB helpers: _sha256, _getSigPS2 (WMI), ║
# ║    _getSigPS3 (CIM), _getIntegrityLevel ║
# ║  Inputs    : -Session                    ║
# ║              -TargetPSVersion            ║
# ║              -TargetCapabilities         ║
# ║  Output    : @{ data=processes[];        ║
# ║               source=string;             ║
# ║               errors=[] }                ║
# ║  Fields    : ProcessId, PPID, Name,      ║
# ║    CommandLine, ExecutablePath,           ║
# ║    CreationDateUTC, WorkingSetSize,       ║
# ║    VirtualSize, SessionId, HandleCount,   ║
# ║    Owner, IntegrityLevel,                 ║
# ║    IntegrityLevelError, SHA256,           ║
# ║    SHA256Error, Signature, source         ║
# ║  Depends   : Core\DateTime.psm1          ║
# ║  PS compat : 2.0+ (target-side)          ║
# ║  Version   : 3.8                         ║
# ╚══════════════════════════════════════════╝

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# PS 2.0-compatible WMI process enumeration scriptblock
$script:PROC_SB_WMI = {
    # SYNC: _sha256 and _getSigPS2 are duplicated here because scriptblocks
    # sent via Invoke-Command cannot reference module-scope functions.
    # Any changes must be mirrored in all copies (WMI SB, CIM SB, module scope).
    function _sha256($p) {
        if (-not $p) { return @($null, 'PATH_NULL') }
        try {
            if (-not [System.IO.File]::Exists($p)) { return @($null, 'FILE_NOT_FOUND') }
            $s = [Security.Cryptography.SHA256]::Create()
            $st = [System.IO.File]::OpenRead($p)
            try { $h = $s.ComputeHash($st) } finally { $st.Close(); $s.Dispose() }
            return @(([BitConverter]::ToString($h) -replace '-','').ToLower(), $null)
        } catch {
            $m = $_.Exception.Message
            if ($m -match 'Access') { return @($null, 'ACCESS_DENIED') }
            elseif ($m -match 'not find|not exist|cannot find') { return @($null, 'FILE_NOT_FOUND') }
            else { return @($null, "COMPUTE_ERROR: $m") }
        }
    }
    # Catalog signature check P/Invoke for PS 2.0
    $_catAvailable = $false
    try {
        if (-not ('CatalogChecker' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public class CatalogChecker
{
    [DllImport("wintrust.dll")]
    static extern bool CryptCATAdminCalcHashFromFileHandle(
        IntPtr hFile, ref int pcbHash, IntPtr pbHash, int dwFlags);
    [DllImport("wintrust.dll")]
    static extern bool CryptCATAdminAcquireContext(
        out IntPtr phCatAdmin, ref Guid pgSubsystem, int dwFlags);
    [DllImport("wintrust.dll")]
    static extern IntPtr CryptCATAdminEnumCatalogFromHash(
        IntPtr hCatAdmin, IntPtr pbHash, int cbHash, int dwFlags, ref IntPtr phPrevCatInfo);
    [DllImport("wintrust.dll", CharSet = CharSet.Unicode)]
    static extern bool CryptCATCatalogInfoFromContext(
        IntPtr hCatInfo, IntPtr psCatInfo, int dwFlags);
    [DllImport("wintrust.dll")]
    static extern bool CryptCATAdminReleaseCatalogContext(
        IntPtr hCatAdmin, IntPtr hCatInfo, int dwFlags);
    [DllImport("wintrust.dll")]
    static extern bool CryptCATAdminReleaseContext(
        IntPtr hCatAdmin, int dwFlags);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateFile(string fn, uint access, uint share,
        IntPtr sa, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr h);

    public static string FindCatalog(string filePath)
    {
        IntPtr hFile = CreateFile(filePath, 0x80000000, 1,
            IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (hFile == new IntPtr(-1)) return null;
        try
        {
            int hashSize = 0;
            CryptCATAdminCalcHashFromFileHandle(hFile, ref hashSize, IntPtr.Zero, 0);
            if (hashSize == 0) return null;
            IntPtr hashBuf = Marshal.AllocHGlobal(hashSize);
            try
            {
                if (!CryptCATAdminCalcHashFromFileHandle(hFile, ref hashSize, hashBuf, 0))
                    return null;
                Guid subsystem = new Guid("F750E6C3-38EE-11D1-85E5-00C04FC295EE");
                IntPtr hCatAdmin;
                if (!CryptCATAdminAcquireContext(out hCatAdmin, ref subsystem, 0))
                    return null;
                try
                {
                    IntPtr hCatInfo = IntPtr.Zero;
                    hCatInfo = CryptCATAdminEnumCatalogFromHash(
                        hCatAdmin, hashBuf, hashSize, 0, ref hCatInfo);
                    if (hCatInfo == IntPtr.Zero) return null;
                    try
                    {
                        int ciSize = 4 + 520;
                        IntPtr pCI = Marshal.AllocHGlobal(ciSize);
                        try
                        {
                            for (int i = 0; i < ciSize; i++) Marshal.WriteByte(pCI, i, 0);
                            Marshal.WriteInt32(pCI, 0, ciSize);
                            if (CryptCATCatalogInfoFromContext(hCatInfo, pCI, 0))
                                return Marshal.PtrToStringUni(new IntPtr(pCI.ToInt64() + 4));
                            return null;
                        }
                        finally { Marshal.FreeHGlobal(pCI); }
                    }
                    finally
                    {
                        CryptCATAdminReleaseCatalogContext(hCatAdmin, hCatInfo, 0);
                    }
                }
                finally { CryptCATAdminReleaseContext(hCatAdmin, 0); }
            }
            finally { Marshal.FreeHGlobal(hashBuf); }
        }
        finally { CloseHandle(hFile); }
    }
}
'@ -ErrorAction Stop
        }
        $_catAvailable = $true
    } catch {
        $_catAvailable = $false
    }

    $sigCache = @{}
    $catSignerCache = @{}
    function _getSigPS2($path) {
        if (-not $path) { return $null }
        if ($sigCache.ContainsKey($path)) { return $sigCache[$path] }
        $catPath = $null
        if ($_catAvailable) {
            try { $catPath = [CatalogChecker]::FindCatalog($path) } catch {}
        }
        $sigSubj = $null; $sigIss = $null; $cnW = $null; $hasEmbedded = $false
        try {
            $cert = [System.Security.Cryptography.X509Certificates.X509Certificate]::CreateFromSignedFile($path)
            $sigSubj = $cert.Subject
            $sigIss  = $cert.Issuer
            if ($sigSubj -match 'CN=([^,]+)') { $cnW = $Matches[1].Trim() }
            $hasEmbedded = $true
        } catch {}
        $result = $null
        if ($hasEmbedded) {
            $result = New-Object PSObject -Property @{
                IsSigned=$true; IsValid=$null; Status='EmbeddedCertPresent'
                SignerSubject=$sigSubj; SignerCompany=$cnW; Issuer=$sigIss
                Thumbprint=$null; NotAfter=$null; TimeStamper=$null
                IsOSBinary=$null; SignatureType='Embedded'; CatalogFile=$null
            }
        } elseif ($catPath) {
            $cSigSubj = $null; $cSigIss = $null; $cCn = $null
            if ($catSignerCache.ContainsKey($catPath)) {
                $cached = $catSignerCache[$catPath]
                $cSigSubj = $cached.Subject; $cSigIss = $cached.Issuer; $cCn = $cached.CN
            } else {
                try {
                    $catCert = [System.Security.Cryptography.X509Certificates.X509Certificate]::CreateFromSignedFile($catPath)
                    $cSigSubj = $catCert.Subject
                    $cSigIss  = $catCert.Issuer
                    if ($cSigSubj -match 'CN=([^,]+)') { $cCn = $Matches[1].Trim() }
                } catch {}
                $catSignerCache[$catPath] = New-Object PSObject -Property @{
                    Subject=$cSigSubj; Issuer=$cSigIss; CN=$cCn
                }
            }
            $result = New-Object PSObject -Property @{
                IsSigned=$true; IsValid=$null; Status='CatalogPresent'
                SignerSubject=$cSigSubj; SignerCompany=$cCn; Issuer=$cSigIss
                Thumbprint=$null; NotAfter=$null; TimeStamper=$null
                IsOSBinary=$null; SignatureType='Catalog'; CatalogFile=$catPath
            }
        } else {
            $result = New-Object PSObject -Property @{
                IsSigned=$false; IsValid=$false; Status='NotSigned'
                SignerSubject=$null; SignerCompany=$null; Issuer=$null
                Thumbprint=$null; NotAfter=$null; TimeStamper=$null
                IsOSBinary=$null; SignatureType=$null; CatalogFile=$null
            }
        }
        $sigCache[$path] = $result
        return $result
    }
    function _getIntegrityLevel($pid_) {
        if ($null -eq $pid_ -or $pid_ -eq 0) { return @($null, 'PID_ZERO_OR_NULL') }
        try {
            if (-not ('IntegrityHelper' -as [type])) {
                Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class IntegrityHelper {
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool GetTokenInformation(IntPtr TokenHandle, int TokenInformationClass, IntPtr TokenInformation, int TokenInformationLength, out int ReturnLength);
    [DllImport("advapi32.dll", CharSet=CharSet.Auto)]
    static extern bool ConvertSidToStringSid(IntPtr pSid, out string strSid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr hObject);
    public static int GetIntegrityRidByPid(int pid) {
        IntPtr hProc = OpenProcess(0x0400, false, pid);
        if (hProc == IntPtr.Zero) hProc = OpenProcess(0x1000, false, pid);
        if (hProc == IntPtr.Zero) return -5;
        try {
            IntPtr hToken;
            if (!OpenProcessToken(hProc, 0x0008, out hToken)) return -1;
            try {
                int len;
                GetTokenInformation(hToken, 25, IntPtr.Zero, 0, out len);
                if (len == 0) return -2;
                IntPtr buf = Marshal.AllocHGlobal(len);
                try {
                    if (!GetTokenInformation(hToken, 25, buf, len, out len)) return -3;
                    IntPtr pSid = Marshal.ReadIntPtr(buf);
                    string sidStr;
                    if (!ConvertSidToStringSid(pSid, out sidStr)) return -4;
                    string[] parts = sidStr.Split(new char[]{'-'});
                    return int.Parse(parts[parts.Length - 1]);
                } finally { Marshal.FreeHGlobal(buf); }
            } finally { CloseHandle(hToken); }
        } finally { CloseHandle(hProc); }
    }
}
'@ -ErrorAction Stop
            }
            $rid = [IntegrityHelper]::GetIntegrityRidByPid($pid_)
            if ($rid -lt 0) { return @($null, "TOKEN_ERROR_$rid") }
            $label = switch ($rid) {
                0x0000 { 'Untrusted' }
                0x1000 { 'Low' }
                0x2000 { 'Medium' }
                0x2100 { 'MediumPlus' }
                0x3000 { 'High' }
                0x4000 { 'System' }
                0x5000 { 'ProtectedProcess' }
                default { "RID_$rid" }
            }
            return @($label, $null)
        } catch {
            $m = $_.Exception.Message
            if ($m -match 'Access') { return @($null, 'ACCESS_DENIED') }
            return @($null, "IL_ERROR: $m")
        }
    }
    $out = New-Object System.Collections.ArrayList
    $outerErrors = @()
    $sha256Cache = @{}
    $MAX_PROCESS_COUNT = 5000
    $processCount = 0
    $searcher = New-Object System.Management.ManagementObjectSearcher("root\cimv2", "SELECT * FROM Win32_Process")
    $searcher.Options.ReturnImmediately = $false
    $searcher.Options.Rewindable = $false
    $searcher.Options.Timeout = [TimeSpan]::FromSeconds(60)
    $procs = $searcher.Get()
    foreach ($p in $procs) {
        $processCount++
        if ($processCount -gt $MAX_PROCESS_COUNT) {
            $outerErrors += "LIMIT: Process count exceeded $MAX_PROCESS_COUNT - truncated to prevent OOM"
            break
        }
        try {
        $pid_ = $null; $ppid = $null; $name_ = $null; $cmdLine = $null; $exePath = $null; $cdate = $null; $ws = [long]0; $vs = [long]0; $sid = $null; $hc = $null
        try { $pid_   = [int]$p.ProcessId }       catch {}
        try { $ppid   = [int]$p.ParentProcessId } catch {}
        try { $name_  = $p.Name }                 catch {}
        try { $cmdLine = $p.CommandLine }          catch {}
        try { $exePath = $p.ExecutablePath }       catch {}
        try { $cdate  = $p.CreationDate }          catch {}
        # Normalize CreationDate (DMTF) to UTC ISO within scriptblock -- same field name as CIM path
        $cdateUtc = $null
        try {
            if ($cdate) { $cdateUtc = [System.Management.ManagementDateTimeConverter]::ToDateTime($cdate).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
        } catch { $outerErrors += "CreationDate parse failed for PID ${pid_}: $($_.Exception.Message)" }
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
        } catch {
            $outerErrors += "GetOwner failed for PID ${pid_}: $($_.Exception.Message)"
        }

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

        # IntegrityLevel
        $ilResult = _getIntegrityLevel $pid_

        if ($pid_ -ne $null) {
            [void]$out.Add((New-Object PSObject -Property @{
                ProcessId       = $pid_
                ParentProcessId = $ppid
                Name            = $name_
                CommandLine     = $cmdLine
                ExecutablePath  = $exePath
                CreationDateUtc = $cdateUtc
                WorkingSetSize  = $ws
                VirtualSize     = $vs
                SessionId       = $sid
                HandleCount     = $hc
                Owner           = $owner
                IntegrityLevel  = $ilResult[0]
                IntegrityLevelError = $ilResult[1]
                SHA256          = $sha256Val
                SHA256Error     = $sha256Err
                Signature       = $sigObj
                source          = 'wmi'
            }))
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
                try { if ($dp.Id -gt 4) { $exeFn = $dp.MainModule.FileName } }                         catch {}
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
                $ilFb = _getIntegrityLevel ([int]$dp.Id)
                $dotnet += New-Object PSObject -Property @{
                    ProcessId = [int]$dp.Id; ParentProcessId = $null
                    Name = $dp.ProcessName; CommandLine = $null; ExecutablePath = $exeFn
                    CreationDateUtc = $startT; WorkingSetSize = $ws2; VirtualSize = $vs2
                    SessionId = $sid2; HandleCount = $hc2; Owner = $null
                    IntegrityLevel = $ilFb[0]; IntegrityLevelError = $ilFb[1]
                    SHA256 = $sha256Fb; SHA256Error = $sha256ErrFb; Signature = $sigFb
                    source = 'dotnet_fallback'
                }
                $outerErrors += "ANOMALY: PID $([int]$dp.Id) ($($dp.ProcessName)) present in .NET but absent from WMI - possible DKOM or short-lived process started after WMI snapshot"
            }
        }
    } catch {
        $outerErrors += ".NET cross-check failed: $($_.Exception.Message)"
    }
    if ($dotnet.Count -gt 0) { $out.AddRange($dotnet) }
    New-Object PSObject -Property @{ Procs = @($out); FallbackCount = $dotnet.Count; OuterErrors = $outerErrors }
}

# CIM scriptblock for PS 3+ path
$script:PROC_SB_CIM = {
    # SYNC: _sha256 and _getSigPS3 are duplicated here because scriptblocks
    # sent via Invoke-Command cannot reference module-scope functions.
    # Any changes must be mirrored in all copies (WMI SB, CIM SB, module scope).
    function _sha256($p) {
        if (-not $p) { return @($null, 'PATH_NULL') }
        try {
            if (-not [System.IO.File]::Exists($p)) { return @($null, 'FILE_NOT_FOUND') }
            $s = [Security.Cryptography.SHA256]::Create()
            $st = [System.IO.File]::OpenRead($p)
            try { $h = $s.ComputeHash($st) } finally { $st.Close(); $s.Dispose() }
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
                NotAfter      = if ($sig.SignerCertificate) { $sig.SignerCertificate.NotAfter.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $null }
                TimeStamper   = if ($sig.TimeStamperCertificate) { $sig.TimeStamperCertificate.Subject } else { $null }
                IsOSBinary    = $isOSBin
                SignatureType = $sigType
                CatalogFile   = $null
            }
        } catch {
            return New-Object PSObject -Property @{
                IsSigned=$null; IsValid=$null; Status="ERROR: $($_.Exception.Message)"
                SignerSubject=$null; SignerCompany=$null; Issuer=$null
                Thumbprint=$null; NotAfter=$null; TimeStamper=$null
                IsOSBinary=$null; SignatureType=$null; CatalogFile=$null
            }
        }
    }
    function _getIntegrityLevel($pid_) {
        if ($null -eq $pid_ -or $pid_ -eq 0) { return @($null, 'PID_ZERO_OR_NULL') }
        try {
            if (-not ('IntegrityHelper' -as [type])) {
                Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class IntegrityHelper {
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool GetTokenInformation(IntPtr TokenHandle, int TokenInformationClass, IntPtr TokenInformation, int TokenInformationLength, out int ReturnLength);
    [DllImport("advapi32.dll", CharSet=CharSet.Auto)]
    static extern bool ConvertSidToStringSid(IntPtr pSid, out string strSid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr hObject);
    public static int GetIntegrityRidByPid(int pid) {
        IntPtr hProc = OpenProcess(0x0400, false, pid);
        if (hProc == IntPtr.Zero) hProc = OpenProcess(0x1000, false, pid);
        if (hProc == IntPtr.Zero) return -5;
        try {
            IntPtr hToken;
            if (!OpenProcessToken(hProc, 0x0008, out hToken)) return -1;
            try {
                int len;
                GetTokenInformation(hToken, 25, IntPtr.Zero, 0, out len);
                if (len == 0) return -2;
                IntPtr buf = Marshal.AllocHGlobal(len);
                try {
                    if (!GetTokenInformation(hToken, 25, buf, len, out len)) return -3;
                    IntPtr pSid = Marshal.ReadIntPtr(buf);
                    string sidStr;
                    if (!ConvertSidToStringSid(pSid, out sidStr)) return -4;
                    string[] parts = sidStr.Split(new char[]{'-'});
                    return int.Parse(parts[parts.Length - 1]);
                } finally { Marshal.FreeHGlobal(buf); }
            } finally { CloseHandle(hToken); }
        } finally { CloseHandle(hProc); }
    }
}
'@ -ErrorAction Stop
            }
            $rid = [IntegrityHelper]::GetIntegrityRidByPid($pid_)
            if ($rid -lt 0) { return @($null, "TOKEN_ERROR_$rid") }
            $label = switch ($rid) {
                0x0000 { 'Untrusted' }
                0x1000 { 'Low' }
                0x2000 { 'Medium' }
                0x2100 { 'MediumPlus' }
                0x3000 { 'High' }
                0x4000 { 'System' }
                0x5000 { 'ProtectedProcess' }
                default { "RID_$rid" }
            }
            return @($label, $null)
        } catch {
            $m = $_.Exception.Message
            if ($m -match 'Access') { return @($null, 'ACCESS_DENIED') }
            return @($null, "IL_ERROR: $m")
        }
    }
    $out = New-Object System.Collections.ArrayList
    $outerErrors = @()
    $sha256Cache = @{}
    $MAX_PROCESS_COUNT = 5000
    $processCount = 0
    $raw = Get-CimInstance Win32_Process -OperationTimeoutSec 60
    foreach ($p in $raw) {
        $processCount++
        if ($processCount -gt $MAX_PROCESS_COUNT) {
            $outerErrors += "LIMIT: Process count exceeded $MAX_PROCESS_COUNT - truncated to prevent OOM"
            break
        }
        try {
        $pid_ = $null; $ppid = $null; $name_ = $null
        try { $pid_  = [int]$p.ProcessId }       catch {}
        try { $ppid  = [int]$p.ParentProcessId } catch {}
        try { $name_ = $p.Name }                 catch {}
        if ($pid_ -eq $null) { continue }
        $ilResult = _getIntegrityLevel $pid_
        $entry = New-Object PSObject -Property @{
            ProcessId = $pid_; ParentProcessId = $ppid; Name = $name_
            CommandLine = $null; ExecutablePath = $null
            CreationDateUtc = $null; CreationDate = $null
            WorkingSetSize = [long]0; VirtualSize = [long]0
            SessionId = $null; HandleCount = $null; Owner = $null
            IntegrityLevel = $ilResult[0]; IntegrityLevelError = $ilResult[1]
            SHA256 = $null; SHA256Error = $null; Signature = $null
            source = 'cim'
        }
        try { $entry.CommandLine     = $p.CommandLine } catch {}
        try { $entry.ExecutablePath  = $p.ExecutablePath } catch {}
        try { $entry.CreationDateUtc = if ($p.CreationDate) { $p.CreationDate.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $null } } catch { $outerErrors += "CreationDate conversion failed for PID ${pid_}: $($_.Exception.Message)" }
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
        } catch {
            $outerErrors += "GetOwner failed for PID ${pid_}: $($_.Exception.Message)"
        }

        # SHA256 with cache
        if ($entry.ExecutablePath -and $sha256Cache.ContainsKey($entry.ExecutablePath)) {
            $entry.SHA256 = $sha256Cache[$entry.ExecutablePath][0]; $entry.SHA256Error = $sha256Cache[$entry.ExecutablePath][1]
        } else {
            $r = _sha256 $entry.ExecutablePath; $entry.SHA256 = $r[0]; $entry.SHA256Error = $r[1]
            if ($entry.ExecutablePath) { $sha256Cache[$entry.ExecutablePath] = @($entry.SHA256, $entry.SHA256Error) }
        }

        # Signature (PS 3+)
        $entry.Signature = _getSigPS3 $entry.ExecutablePath

        [void]$out.Add($entry)
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
                try { if ($dp.Id -gt 4) { $exeFn = $dp.MainModule.FileName } }                         catch {}
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
                $ilFb2 = _getIntegrityLevel ([int]$dp.Id)
                $dotnet += New-Object PSObject -Property @{
                    ProcessId = [int]$dp.Id; ParentProcessId = $null
                    Name = $dp.ProcessName; CommandLine = $null; ExecutablePath = $exeFn
                    CreationDateUtc = $startT; CreationDate = $null
                    WorkingSetSize = $ws2; VirtualSize = $vs2
                    SessionId = $sid2; HandleCount = $hc2; Owner = $null
                    IntegrityLevel = $ilFb2[0]; IntegrityLevelError = $ilFb2[1]
                    SHA256 = $sha256Fb2; SHA256Error = $sha256ErrFb2; Signature = $sigFb2
                    source = 'dotnet_fallback'
                }
                $outerErrors += "ANOMALY: PID $([int]$dp.Id) ($($dp.ProcessName)) present in .NET but absent from CIM - possible DKOM or short-lived process started after CIM snapshot"
            }
        }
    } catch {
        $outerErrors += ".NET cross-check failed: $($_.Exception.Message)"
    }
    if ($dotnet.Count -gt 0) { $out.AddRange($dotnet) }
    New-Object PSObject -Property @{ Procs = @($out); FallbackCount = $dotnet.Count; OuterErrors = $outerErrors }
}

function _sha256($p) {
    if (-not $p) { return @($null, 'PATH_NULL') }
    try {
        if (-not [System.IO.File]::Exists($p)) { return @($null, 'FILE_NOT_FOUND') }
        $s = [Security.Cryptography.SHA256]::Create()
        $st = [System.IO.File]::OpenRead($p)
        try { $h = $s.ComputeHash($st) } finally { $st.Close(); $s.Dispose() }
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
            NotAfter      = if ($sig.SignerCertificate) { $sig.SignerCertificate.NotAfter.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $null }
            TimeStamper   = if ($sig.TimeStamperCertificate) { $sig.TimeStamperCertificate.Subject } else { $null }
            IsOSBinary    = $isOSBin
            SignatureType = $sigType
            CatalogFile   = $null
        }
    } catch {
        return New-Object PSObject -Property @{
            IsSigned=$null; IsValid=$null; Status="ERROR: $($_.Exception.Message)"
            SignerSubject=$null; SignerCompany=$null; Issuer=$null
            Thumbprint=$null; NotAfter=$null; TimeStamper=$null
            IsOSBinary=$null; SignatureType=$null; CatalogFile=$null
        }
    }
}

# IntegrityLevel helper -- uses P/Invoke to read process token integrity RID
# Returns @(levelString, errorString). levelString is one of:
#   Untrusted, Low, Medium, MediumPlus, High, System, ProtectedProcess, or the raw RID
$script:_integrityTypeAdded = $false
$script:_integrityTypeAvailable = $false
function _getIntegrityLevel($pid_) {
    if ($null -eq $pid_ -or $pid_ -eq 0) { return @($null, 'PID_ZERO_OR_NULL') }
    if (-not $script:_integrityTypeAdded) {
        $script:_integrityTypeAdded = $true  # Mark attempted so we don't retry on failure
        try {
            Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class IntegrityHelper {
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool GetTokenInformation(IntPtr TokenHandle, int TokenInformationClass, IntPtr TokenInformation, int TokenInformationLength, out int ReturnLength);
    [DllImport("advapi32.dll", CharSet=CharSet.Auto)]
    static extern bool ConvertSidToStringSid(IntPtr pSid, out string strSid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr hObject);
    public static int GetIntegrityRidByPid(int pid) {
        IntPtr hProc = OpenProcess(0x0400, false, pid);
        if (hProc == IntPtr.Zero) hProc = OpenProcess(0x1000, false, pid);
        if (hProc == IntPtr.Zero) return -5;
        try {
            IntPtr hToken;
            if (!OpenProcessToken(hProc, 0x0008, out hToken)) return -1;
            try {
                int len;
                GetTokenInformation(hToken, 25, IntPtr.Zero, 0, out len);
                if (len == 0) return -2;
                IntPtr buf = Marshal.AllocHGlobal(len);
                try {
                    if (!GetTokenInformation(hToken, 25, buf, len, out len)) return -3;
                    IntPtr pSid = Marshal.ReadIntPtr(buf);
                    string sidStr;
                    if (!ConvertSidToStringSid(pSid, out sidStr)) return -4;
                    string[] parts = sidStr.Split(new char[]{'-'});
                    return int.Parse(parts[parts.Length - 1]);
                } finally { Marshal.FreeHGlobal(buf); }
            } finally { CloseHandle(hToken); }
        } finally { CloseHandle(hProc); }
    }
}
'@ -ErrorAction Stop
            $script:_integrityTypeAvailable = $true
        } catch {
            return @($null, 'PINVOKE_COMPILE_FAILED')
        }
    }
    if (-not $script:_integrityTypeAvailable) { return @($null, 'PINVOKE_UNAVAILABLE') }
    try {
        $rid = [IntegrityHelper]::GetIntegrityRidByPid($pid_)
        if ($rid -lt 0) { return @($null, "TOKEN_ERROR_$rid") }
        $label = switch ($rid) {
            0x0000 { 'Untrusted' }
            0x1000 { 'Low' }
            0x2000 { 'Medium' }
            0x2100 { 'MediumPlus' }
            0x3000 { 'High' }
            0x4000 { 'System' }
            0x5000 { 'ProtectedProcess' }
            default { "RID_$rid" }
        }
        return @($label, $null)
    } catch {
        $m = $_.Exception.Message
        if ($m -match 'Access') { return @($null, 'ACCESS_DENIED') }
        return @($null, "IL_ERROR: $m")
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
        if ($Session -ne $null -and $Session -is [hashtable] -and $Session.Method -eq 'WMI') {
            # WMI remote path: query from analyst machine
            if (-not $Session.ComputerName) {
                throw "WMI session has no ComputerName - cannot query remote processes"
            }
            $wmiP = @{ Class = 'Win32_Process'; ComputerName = $Session.ComputerName; ErrorAction = 'Stop' }
            if ($Session.Credential) { $wmiP.Credential = $Session.Credential }
            $wmiProcs = Get-WmiObject @wmiP
            $sourceStr = 'wmi_remote'

            foreach ($wp in $wmiProcs) {
                try {
                    $pid_ = $null; $ppid = $null; $name_ = $null; $cmdLine = $null; $exePath = $null
                    $ws = [long]0; $vs = [long]0; $sid = $null; $hc = $null
                    try { $pid_    = [int]$wp.ProcessId }       catch {}
                    try { $ppid    = [int]$wp.ParentProcessId } catch {}
                    try { $name_   = $wp.Name }                 catch {}
                    try { $cmdLine = $wp.CommandLine }           catch {}
                    try { $exePath = $wp.ExecutablePath }        catch {}
                    try { $ws      = [long]$wp.WorkingSetSize }  catch {}
                    try { $vs      = [long]$wp.VirtualSize }     catch {}
                    try { $sid     = [int]$wp.SessionId }        catch {}
                    try { $hc      = [int]$wp.HandleCount }      catch {}
                    if ($pid_ -eq $null) { continue }

                    # CreationDate -- WMI datetime format
                    $utcVal = $null
                    try {
                        if ($wp.CreationDate) {
                            $utcVal = [System.Management.ManagementDateTimeConverter]::ToDateTime($wp.CreationDate).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                        }
                    } catch { $errors += @{ artifact='process_detail'; ProcessId=$pid_; message="CreationDate parse failed: $($_.Exception.Message)" } }

                    # Owner via GetOwner() -- WMI ManagementObject method
                    $owner = $null
                    try {
                        $ownerInfo = $wp.InvokeMethod('GetOwner', $null)
                        if ($ownerInfo -and $ownerInfo['ReturnValue'] -eq 0) {
                            $d = $ownerInfo['Domain']; $u = $ownerInfo['User']
                            $owner = if ($d) { "$d\$u" } else { $u }
                        }
                    } catch {
                        $errors += @{ artifact='process_owner'; ProcessId=$pid_; message="GetOwner failed: $($_.Exception.Message)" }
                    }

                    $procs += @{
                        ProcessId           = $pid_
                        ParentProcessId     = $ppid
                        Name                = $name_
                        CommandLine         = $cmdLine
                        ExecutablePath      = $exePath
                        CreationDateUTC     = $utcVal
                        CreationDateLocal   = $null
                        WorkingSetSize      = $ws
                        VirtualSize         = $vs
                        SessionId           = $sid
                        HandleCount         = $hc
                        Owner               = $owner
                        IntegrityLevel      = $null
                        IntegrityLevelError = 'WMI_REMOTE_UNSUPPORTED'
                        SHA256              = $null
                        SHA256Error         = 'WMI_REMOTE_UNSUPPORTED'
                        Signature           = @{
                            IsSigned      = $null
                            IsValid       = $null
                            Status        = 'WMI_REMOTE_UNSUPPORTED'
                            SignerSubject = $null
                            SignerCompany = $null
                            Issuer        = $null
                            Thumbprint    = $null
                            NotAfter      = $null
                            TimeStamper   = $null
                            IsOSBinary    = $null
                            SignatureType = $null
                            CatalogFile   = $null
                        }
                        source              = 'wmi_remote'
                    }
                } catch {
                    $errors += @{ artifact = 'process_loop'; message = $_.Exception.Message }
                    continue
                }
            }
            $errors += @{ artifact = 'processes'; severity = 'warning'; message = 'WMI fallback: SHA256, signatures, integrity levels unavailable' }
            $errors += @{ artifact = 'dotnet_crosscheck'; severity = 'warning'; message = 'DKOM_CHECK_UNAVAILABLE: .NET cross-check skipped on WMI remote -- DKOM-hidden processes will not be detected' }

        } elseif ($Session -ne $null) {
            # Remote path (WinRM)
            $sb = if ($TargetPSVersion -ge 3) { $script:PROC_SB_CIM } else { $script:PROC_SB_WMI }
            $r   = Invoke-Command -Session $Session -ScriptBlock $sb
            $raw = $r.Procs
            if ($r.FallbackCount -gt 0) {
                $fallbackNote = "$($r.FallbackCount) process(es) added via .NET fallback on remote (absent from WMI/CIM)"
                Write-Log 'WARN' "Remote: $fallbackNote"
            }
            $baseSource = if ($TargetPSVersion -ge 3) { 'cim' } else { 'wmi' }
            $sourceStr  = if ($r.FallbackCount -gt 0) { "$baseSource+dotnet_fallback" } else { $baseSource }

            # Merge remote errors/anomalies into local errors array
            if ($r.OuterErrors) {
                foreach ($oe in $r.OuterErrors) {
                    $errors += @{ artifact = 'dotnet_crosscheck'; message = $oe }
                }
            }

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
                # Extract Signature hashtable from PSObject -- defensive access for
                # properties that may be absent after WinRM deserialization on older PS
                $sigOut = $null
                if ($p.Signature -ne $null) {
                    try {
                        $s_ = $p.Signature
                        $sigOut = @{
                            IsSigned      = $(if ($s_.PSObject.Properties['IsSigned'])      { $s_.IsSigned }      else { $null })
                            IsValid       = $(if ($s_.PSObject.Properties['IsValid'])       { $s_.IsValid }       else { $null })
                            Status        = $(if ($s_.PSObject.Properties['Status'])        { $s_.Status }        else { $null })
                            SignerSubject = $(if ($s_.PSObject.Properties['SignerSubject']) { $s_.SignerSubject } else { $null })
                            SignerCompany = $(if ($s_.PSObject.Properties['SignerCompany']) { $s_.SignerCompany } else { $null })
                            Issuer        = $(if ($s_.PSObject.Properties['Issuer'])        { $s_.Issuer }        else { $null })
                            Thumbprint    = $(if ($s_.PSObject.Properties['Thumbprint'])    { $s_.Thumbprint }    else { $null })
                            NotAfter      = $(if ($s_.PSObject.Properties['NotAfter'] -and $s_.NotAfter) {
                                                    # Normalize to UTC Z -- remoting may return local time with offset
                                                    $naVal = $s_.NotAfter
                                                    if ($naVal -is [datetime]) {
                                                        $naVal.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                                                    } elseif ($naVal -is [string] -and $naVal -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') {
                                                        $naVal  # Already correct UTC Z format
                                                    } elseif ($naVal -is [string]) {
                                                        try { ([datetime]::Parse($naVal)).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
                                                        catch { $naVal }
                                                    } else { $naVal }
                                                } else { $null })
                            TimeStamper   = $(if ($s_.PSObject.Properties['TimeStamper'])   { $s_.TimeStamper }   else { $null })
                            IsOSBinary    = $(if ($s_.PSObject.Properties['IsOSBinary'])    { $s_.IsOSBinary }    else { $null })
                            SignatureType = $(if ($s_.PSObject.Properties['SignatureType']) { $s_.SignatureType } else { $null })
                            CatalogFile   = $(if ($s_.PSObject.Properties['CatalogFile'])   { $s_.CatalogFile }   else { $null })
                        }
                    } catch {
                        $errors += @{ artifact='signature_deser'; ProcessId=$pid_; message="Signature deserialization failed: $($_.Exception.Message)" }
                    }
                }
                # Enforce SHA256 XOR contract: hash or error, never both
                $sha256Out = $(if ($p.PSObject.Properties['SHA256'])      { $p.SHA256 }      else { $null })
                $sha256ErrOut = $(if ($p.PSObject.Properties['SHA256Error']) { $p.SHA256Error } else { $null })
                if ($sha256Out -and $sha256ErrOut) { $sha256ErrOut = $null }
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
                    Owner            = $(if ($p.PSObject.Properties['Owner'])            { $p.Owner }            else { $null })
                    IntegrityLevel   = $(if ($p.PSObject.Properties['IntegrityLevel']) { $p.IntegrityLevel } else { $null })
                    IntegrityLevelError = $(if ($p.PSObject.Properties['IntegrityLevelError']) { $p.IntegrityLevelError } else { $null })
                    SHA256           = $sha256Out
                    SHA256Error      = $sha256ErrOut
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
                    $ilLocal = _getIntegrityLevel $pid_
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
                        IntegrityLevel   = $ilLocal[0]
                        IntegrityLevelError = $ilLocal[1]
                        SHA256           = $null
                        SHA256Error      = $null
                        Signature        = $null
                        source           = 'cim'
                    }
                    try { $entry.CommandLine      = $p.CommandLine } catch { $errors += @{ artifact='process_detail'; ProcessId=$pid_; Name=$name_; message=$_.Exception.Message } }
                    try { $entry.ExecutablePath   = $p.ExecutablePath } catch {}
                    try {
                        $entry.CreationDateUTC = if ($p.CreationDate) { $p.CreationDate.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $null }
                    } catch {
                        $entry.CreationDateUTC = $null
                        $errors += @{ artifact='process_detail'; ProcessId=$pid_; Name=$name_; field='CreationDateUTC'; message="CreationDate access failed: $($_.Exception.Message)" }
                    }
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
                    } catch {
                        $errors += @{ artifact='process_owner'; ProcessId=$pid_; Name=$name_; message="GetOwner failed: $($_.Exception.Message)" }
                    }

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
                            try { if ($dp.Id -gt 4) { $exeFn = $dp.MainModule.FileName } }                         catch {}
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
                            $ilFb3 = _getIntegrityLevel ([int]$dp.Id)
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
                                IntegrityLevel   = $ilFb3[0]
                                IntegrityLevelError = $ilFb3[1]
                                SHA256           = $sha256Fb3
                                SHA256Error      = $sha256ErrFb3
                                Signature        = _getSigPS3 $exeFn
                                source           = 'dotnet_fallback'
                            }
                            $fallbackCount++
                            $errors += @{ artifact = 'dotnet_crosscheck'; message = "PID $([int]$dp.Id) ($($dp.ProcessName)) present in .NET but absent from CIM - possible DKOM or race condition"; severity = 'HIGH' }
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
                # WMI path -- local collection runs on analyst machine (PS 5.1+)
                $sourceStr = 'wmi'
                $fallbackCount = 0
                $searcher = New-Object System.Management.ManagementObjectSearcher("root\cimv2", "SELECT * FROM Win32_Process")
                $searcher.Options.ReturnImmediately = $false
                $searcher.Options.Rewindable = $false
                $searcher.Options.Timeout = [TimeSpan]::FromSeconds(60)
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
                    } catch {
                        $errors += @{ artifact='process_owner'; ProcessId=$pid_; message="GetOwner failed: $($_.Exception.Message)" }
                    }

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

                    # IntegrityLevel
                    $ilW = _getIntegrityLevel $pid_

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
                        IntegrityLevel   = $ilW[0]
                        IntegrityLevelError = $ilW[1]
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
                            try { if ($dp.Id -gt 4) { $exeFn = $dp.MainModule.FileName } }                         catch {}
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
                            $ilWFb = _getIntegrityLevel ([int]$dp.Id)
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
                                IntegrityLevel   = $ilWFb[0]
                                IntegrityLevelError = $ilWFb[1]
                                SHA256           = $sha256WFb
                                SHA256Error      = $sha256ErrWFb
                                Signature        = _getSigPS3 $exeFn
                                source           = 'dotnet_fallback'
                            }
                            $fallbackCount++
                            $errors += @{ artifact = 'dotnet_crosscheck'; message = "PID $([int]$dp.Id) ($($dp.ProcessName)) present in .NET but absent from WMI - possible DKOM or short-lived process started after WMI snapshot"; severity = 'HIGH' }
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
