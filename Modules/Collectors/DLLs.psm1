#Requires -Version 5.1
# ╔══════════════════════════════════════╗
# ║  QuickAiR — DLLs.psm1                ║
# ║  Loaded modules per process via     ║
# ║  .NET Process.Modules + SHA256.     ║
# ╠══════════════════════════════════════╣
# ║  Exports   : Invoke-Collector       ║
# ║  Inputs    : -Session               ║
# ║              -TargetPSVersion       ║
# ║              -TargetCapabilities    ║
# ║  Output    : @{ data=dlls[];        ║
# ║               source='dotnet';      ║
# ║               errors=[] }          ║
# ║  Depends   : Core\DateTime.psm1     ║
# ║  PS compat : 2.0+ (target-side)     ║
# ║  Version   : 3.3                    ║
# ╚══════════════════════════════════════╝

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# ── Unified scriptblock (PS 2.0+) ────────────────────────────────────────────
# Uses .NET Process.Modules for enumeration on all PS versions.
# Signature: Get-AuthenticodeSignature on PS 3+, X509Certificate on PS 2.0.
$script:DLL_SB = {
    function _sha256($p) {
        if (-not $p) { return @($null, 'PATH_NULL') }
        try {
            if (-not [System.IO.File]::Exists($p)) { return @($null, 'FILE_NOT_FOUND') }
            $fs = New-Object System.IO.FileStream($p, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $s  = [Security.Cryptography.SHA256]::Create()
            $h  = $s.ComputeHash($fs); $fs.Close(); $s.Clear()
            return @(([BitConverter]::ToString($h) -replace '-','').ToLower(), $null)
        } catch {
            $m = $_.Exception.Message
            if ($m -match 'Access') { return @($null, 'ACCESS_DENIED') }
            elseif ($m -match 'not find|not exist|cannot find') { return @($null, 'FILE_NOT_FOUND') }
            else { return @($null, "COMPUTE_ERROR: $m") }
        }
    }
    $PROTECTED_PROCS  = @('lsass','csrss','smss','wininit','System','Idle')
    $PRIVATE_MARKERS  = @('\Temp\','\AppData\','\ProgramData\','\Users\Public\','\Downloads\')

    # Detect PS version once (runs on target)
    $psMajor = 2
    if ($PSVersionTable -and $PSVersionTable.PSVersion) {
        $psMajor = $PSVersionTable.PSVersion.Major
    }

    # Catalog signature check P/Invoke for PS 2.0
    # Uses CryptCATAdmin APIs to check if file hash is in Windows catalog DB.
    # Falls back to CreateFromSignedFile for embedded sig details.
    $_catAvailable = $false
    if ($psMajor -lt 3) {
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

    // Returns catalog file path if file hash is in catalog DB, null otherwise
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
                        // CATALOG_INFO: cbStruct(4) + wszCatalogFile(260 wchars = 520 bytes)
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
'@
            }
            $_catAvailable = $true
        } catch {
            $_catAvailable = $false
        }
    }

    $sigCache = @{}
    $catSignerCache = @{}

    $out = @()
    $skippedProcs = @()
    $MAX_MODULE_COUNT = 50000
    $totalModuleCount = 0
    $allProcs = $null
    try { $allProcs = [System.Diagnostics.Process]::GetProcesses() } catch { $allProcs = @() }

    foreach ($p in $allProcs) {
        if ($totalModuleCount -gt $MAX_MODULE_COUNT) {
            $skippedProcs += New-Object PSObject -Property @{ ProcessId=$null; ProcessName='MODULE_LIMIT_REACHED' }
            break
        }
        $pName = $null
        try { $pName = $p.ProcessName } catch {}
        if (-not $pName) { continue }

        $skip = $false
        foreach ($pp in $PROTECTED_PROCS) { if ($pName -ieq $pp) { $skip = $true; break } }
        if ($skip) {
            $spId = $null; try { $spId = [int]$p.Id } catch {}
            $skippedProcs += New-Object PSObject -Property @{ ProcessId=$spId; ProcessName=$pName }
            continue
        }

        $procId = $null
        try { $procId = [int]$p.Id } catch {}
        if ($procId -eq $null) { continue }

        $mods = $null
        try {
            $mods = $p.Modules
        } catch {
            $reason = $_.Exception.Message
            if ($_.Exception.Message -match 'Access') { $reason = 'ACCESS_DENIED' }
            $out += New-Object PSObject -Property @{
                ProcessId     = $procId
                ProcessName   = $pName
                ModuleName    = $null
                ModulePath    = $null
                FileVersion   = $null
                Company       = $null
                FileHash      = $null
                SHA256Error   = $null
                IsPrivatePath = $null
                Signature     = $null

                reason        = $reason
                source        = 'dotnet'
            }
            continue
        }

        foreach ($m in $mods) {
            $totalModuleCount++
            if ($totalModuleCount -gt $MAX_MODULE_COUNT) { break }
            $mPath = $null
            $mName = $null
            try { $mPath = $m.FileName  } catch {}
            try { $mName = $m.ModuleName } catch {}

            $isPrivate = $false
            if ($mPath) {
                foreach ($marker in $PRIVATE_MARKERS) {
                    if ($mPath -like "*$marker*") { $isPrivate = $true; break }
                }
            }

            $r = _sha256 $mPath; $fileHash = $r[0]; $sha256Err = $r[1]

            $ver     = $null
            $company = $null
            if ($mPath) {
                try {
                    $fvi     = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($mPath)
                    $ver     = $fvi.FileVersion
                    $company = $fvi.CompanyName
                } catch {}
            }

            # Signature: branch by PS version
            $sigD = $null
            if ($mPath) {
                if ($psMajor -ge 3) {
                    # PS 3+ — Get-AuthenticodeSignature
                    try {
                        $sigD3 = Get-AuthenticodeSignature -FilePath $mPath -ErrorAction Stop
                        $cnD3 = $null
                        if ($sigD3.SignerCertificate) {
                            $subjD3 = $sigD3.SignerCertificate.Subject
                            if ($subjD3 -match 'CN=([^,]+)') { $cnD3 = $Matches[1].Trim() }
                        }
                        $isOSBinD = $null; try { $isOSBinD = $sigD3.IsOSBinary } catch {}
                        $sigTypeD = $null; try { $sigTypeD = $sigD3.SignatureType.ToString() } catch {}
                        $sigSubject    = $null; $sigIssuer  = $null
                        $sigThumb      = $null; $sigNotAfter = $null
                        $sigTimestamper = $null
                        if ($sigD3.SignerCertificate) {
                            $sigSubject  = $sigD3.SignerCertificate.Subject
                            $sigIssuer   = $sigD3.SignerCertificate.Issuer
                            $sigThumb    = $sigD3.SignerCertificate.Thumbprint
                            $sigNotAfter = $sigD3.SignerCertificate.NotAfter.ToUniversalTime().ToString('o')
                        }
                        if ($sigD3.TimeStamperCertificate) {
                            $sigTimestamper = $sigD3.TimeStamperCertificate.Subject
                        }
                        $sigD = New-Object PSObject -Property @{
                            IsSigned      = ($sigD3.Status -ne 'NotSigned')
                            IsValid       = ($sigD3.Status -eq 'Valid')
                            Status        = $sigD3.Status.ToString()
                            SignerSubject = $sigSubject
                            SignerCompany = $cnD3
                            Issuer        = $sigIssuer
                            Thumbprint    = $sigThumb
                            NotAfter      = $sigNotAfter
                            TimeStamper   = $sigTimestamper
                            IsOSBinary    = $isOSBinD
                            SignatureType = $sigTypeD
                        }
                    } catch {
                        $sigD = New-Object PSObject -Property @{
                            IsSigned=$null; IsValid=$null; Status="ERROR: $($_.Exception.Message)"
                            SignerSubject=$null; SignerCompany=$null; Issuer=$null
                            Thumbprint=$null; NotAfter=$null; TimeStamper=$null
                            IsOSBinary=$null; SignatureType=$null
                        }
                    }
                } else {
                    # PS 2.0 — Catalog DB + CreateFromSignedFile for cert details
                    if ($sigCache.ContainsKey($mPath)) {
                        $sigD = $sigCache[$mPath]
                    } else {
                        $catPath = $null
                        if ($_catAvailable) {
                            try { $catPath = [CatalogChecker]::FindCatalog($mPath) } catch {}
                        }
                        # Try embedded sig for cert details
                        $sigSubj = $null; $sigIss = $null; $cnW = $null; $hasEmbedded = $false
                        try {
                            $certW = [System.Security.Cryptography.X509Certificates.X509Certificate]::CreateFromSignedFile($mPath)
                            $sigSubj = $certW.Subject
                            $sigIss  = $certW.Issuer
                            if ($sigSubj -match 'CN=([^,]+)') { $cnW = $Matches[1].Trim() }
                            $hasEmbedded = $true
                        } catch {}
                        if ($hasEmbedded) {
                            $sigD = New-Object PSObject -Property @{
                                IsSigned=$true; IsValid=$null; Status='Valid'
                                SignerSubject=$sigSubj; SignerCompany=$cnW; Issuer=$sigIss
                                Thumbprint=$null; NotAfter=$null; TimeStamper=$null
                                IsOSBinary=$null; SignatureType='Embedded'; CatalogFile=$null
                            }
                        } elseif ($catPath) {
                            # Extract signer from catalog file (cached per .cat path)
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
                            $sigD = New-Object PSObject -Property @{
                                IsSigned=$true; IsValid=$null; Status='CatalogPresent'
                                SignerSubject=$cSigSubj; SignerCompany=$cCn; Issuer=$cSigIss
                                Thumbprint=$null; NotAfter=$null; TimeStamper=$null
                                IsOSBinary=$null; SignatureType='Catalog'; CatalogFile=$catPath
                            }
                        } else {
                            $sigD = New-Object PSObject -Property @{
                                IsSigned=$false; IsValid=$false; Status='NotSigned'
                                SignerSubject=$null; SignerCompany=$null; Issuer=$null
                                Thumbprint=$null; NotAfter=$null; TimeStamper=$null
                                IsOSBinary=$null; SignatureType=$null; CatalogFile=$null
                            }
                        }
                        $sigCache[$mPath] = $sigD
                    }
                }
            }

            $out += New-Object PSObject -Property @{
                ProcessId     = $procId
                ProcessName   = $pName
                ModuleName    = $mName
                ModulePath    = $mPath
                FileVersion   = $ver
                Company       = $company
                FileHash      = $fileHash
                SHA256Error   = $sha256Err
                IsPrivatePath = $isPrivate
                Signature     = $sigD

                reason        = $null
                source        = 'dotnet'
            }
        }
    }
    New-Object PSObject -Property @{ _dlls = $out; _skipped = $skippedProcs }
}

# ── Invoke-Collector ──────────────────────────────────────────────────────────
function Invoke-Collector {
    param(
        $Session,
        $TargetPSVersion,
        $TargetCapabilities
    )

    $errors = @()
    $dlls   = @()

    $sb = $script:DLL_SB

    $skippedProcs = @()

    try {
        if ($Session -ne $null -and $Session -is [hashtable] -and $Session.Method -eq 'WMI') {
            # DLL collection requires .NET Process.Modules — no WMI equivalent
            $errors += @{ artifact = 'DLLs'; severity = 'warning'; degraded = $true; message = 'DLL/module collection unavailable via WMI remote. This target requires WinRM for DLL enumeration.' }
            Write-Log 'WARN' 'DLL collection skipped: WMI fallback does not support .NET Process.Modules'
            return @{
                data   = @()
                source = 'wmi_unsupported'
                errors = $errors
            }
        } elseif ($Session -ne $null) {
            $raw = Invoke-Command -Session $Session -ScriptBlock $sb
        } else {
            $raw = & $sb
        }

        # Unwrap wrapper object from scriptblock
        $rawDlls = @()
        if ($raw._dlls -ne $null) {
            $rawDlls      = @($raw._dlls)
            $skippedProcs = @($raw._skipped)
        } else {
            $rawDlls = @($raw)
        }

        foreach ($entry in $rawDlls) {
            # Extract Signature as hashtable
            $sigOut2 = $null
            if ($entry.Signature -ne $null) {
                try {
                    $sigOut2 = @{
                        IsSigned      = $entry.Signature.IsSigned
                        IsValid       = $entry.Signature.IsValid
                        Status        = $entry.Signature.Status
                        SignerSubject = $entry.Signature.SignerSubject
                        SignerCompany = $entry.Signature.SignerCompany
                        Issuer        = $entry.Signature.Issuer
                        Thumbprint    = $entry.Signature.Thumbprint
                        NotAfter      = $entry.Signature.NotAfter
                        TimeStamper   = $entry.Signature.TimeStamper
                        IsOSBinary    = $entry.Signature.IsOSBinary
                        SignatureType = $entry.Signature.SignatureType
                        CatalogFile   = $entry.Signature.CatalogFile
                    }
                } catch {}
            }
            $dlls += @{
                ProcessId     = $entry.ProcessId
                ProcessName   = $entry.ProcessName
                ModuleName    = $entry.ModuleName
                ModulePath    = $entry.ModulePath
                FileVersion   = $entry.FileVersion
                Company       = $entry.Company
                FileHash      = $entry.FileHash
                SHA256Error   = $entry.SHA256Error
                IsPrivatePath = $entry.IsPrivatePath
                Signature     = $sigOut2
                reason        = $entry.reason
                source        = $entry.source
            }
        }
    } catch {
        $errors += @{ artifact = 'DLLs'; message = $_.Exception.Message }
        Write-Log 'ERROR' "DLL collection failed: $($_.Exception.Message)"
    }

    # Log skipped protected processes
    if ($skippedProcs.Count -gt 0) {
        $skippedNames = @()
        foreach ($sp in $skippedProcs) { $skippedNames += "$($sp.ProcessName)(PID:$($sp.ProcessId))" }
        $errors += @{ artifact = 'DLLs'; severity = 'warning'; message = "Protected processes skipped for DLL enumeration: $($skippedNames -join ', ')" }
    }

    $src = 'dotnet'

    return @{ data = @($dlls); source = $src; errors = $errors }
}

Export-ModuleMember -Function Invoke-Collector
