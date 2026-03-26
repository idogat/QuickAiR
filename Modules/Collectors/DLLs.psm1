#Requires -Version 5.1
# ╔══════════════════════════════════════╗
# ║  Quicker — DLLs.psm1                ║
# ║  Loaded modules per process.        ║
# ║  SHA256 for all DLLs.              ║
# ╠══════════════════════════════════════╣
# ║  Exports   : Invoke-Collector       ║
# ║  Inputs    : -Session               ║
# ║              -TargetPSVersion       ║
# ║              -TargetCapabilities    ║
# ║  Output    : @{ data=dlls[];        ║
# ║               source=string;        ║
# ║               errors=[] }          ║
# ║  Depends   : Core\DateTime.psm1     ║
# ║  PS compat : 2.0+ (target-side)     ║
# ║  Version   : 2.5                    ║
# ╚══════════════════════════════════════╝

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# ── .NET scriptblock (PS 3+) ─────────────────────────────────────────────────
$script:DLL_SB_DOTNET = {
    function _sha256($p) {
        if (-not $p) { return @($null, 'PATH_NULL') }
        try {
            if (-not [System.IO.File]::Exists($p)) { return @($null, 'FILE_NOT_FOUND') }
            $fs = New-Object System.IO.FileStream($p, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $s  = [Security.Cryptography.SHA256]::Create()
            $h  = $s.ComputeHash($fs); $fs.Dispose(); $s.Dispose()
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

    $out = @()
    $skippedProcs = @()
    $allProcs = $null
    try { $allProcs = [System.Diagnostics.Process]::GetProcesses() } catch { $allProcs = @() }

    foreach ($p in $allProcs) {
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
            $reason = if ($_.Exception.Message -match 'Access') { 'ACCESS_DENIED' } else { $_.Exception.Message }
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

            # Signature inline (PS 3+)
            $sigD = $null
            if ($mPath) {
                try {
                    $sigD3 = Get-AuthenticodeSignature -FilePath $mPath -ErrorAction Stop
                    $certD3 = $null; $cnD3 = $null
                    if ($sigD3.SignerCertificate) {
                        $subjD3 = $sigD3.SignerCertificate.Subject
                        $cnD3 = if ($subjD3 -match 'CN=([^,]+)') { $Matches[1].Trim() } else { $null }
                    }
                    $isOSBinD = $null; try { $isOSBinD = $sigD3.IsOSBinary } catch {}
                    $sigTypeD = $null; try { $sigTypeD = $sigD3.SignatureType.ToString() } catch {}
                    $sigD = New-Object PSObject -Property @{
                        IsSigned     = ($sigD3.Status -ne 'NotSigned')
                        IsValid      = ($sigD3.Status -eq 'Valid')
                        Status       = $sigD3.Status.ToString()
                        SignerSubject = if ($sigD3.SignerCertificate) { $sigD3.SignerCertificate.Subject } else { $null }
                        SignerCompany = $cnD3
                        Issuer       = if ($sigD3.SignerCertificate) { $sigD3.SignerCertificate.Issuer } else { $null }
                        Thumbprint   = if ($sigD3.SignerCertificate) { $sigD3.SignerCertificate.Thumbprint } else { $null }
                        NotAfter     = if ($sigD3.SignerCertificate) { $sigD3.SignerCertificate.NotAfter.ToUniversalTime().ToString('o') } else { $null }
                        TimeStamper  = if ($sigD3.TimeStamperCertificate) { $sigD3.TimeStamperCertificate.Subject } else { $null }
                        IsOSBinary   = $isOSBinD
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

# ── WMI scriptblock (PS 2.0) ─────────────────────────────────────────────────
$script:DLL_SB_WMI = {
    function _sha256($p) {
        if (-not $p) { return @($null, 'PATH_NULL') }
        try {
            if (-not [System.IO.File]::Exists($p)) { return @($null, 'FILE_NOT_FOUND') }
            $fs = New-Object System.IO.FileStream($p, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $s  = [Security.Cryptography.SHA256]::Create()
            $h  = $s.ComputeHash($fs); $fs.Dispose(); $s.Dispose()
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

    $out = @()
    $skippedProcs = @()
    $procs = $null
    try { $procs = Get-WmiObject Win32_Process } catch { $procs = @() }

    foreach ($p in $procs) {
        $pName = $null
        $procId   = $null
        try { $pName = $p.Name }      catch {}
        try { $procId   = [int]$p.ProcessId } catch {}
        if ($null -eq $procId) { continue }
        if (-not $pName) { continue }

        $pNameNoExt = $pName -replace '\.exe$',''
        $skip = $false
        foreach ($pp in $PROTECTED_PROCS) {
            if ($pNameNoExt -ieq $pp -or $pName -ieq $pp) { $skip = $true; break }
        }
        if ($skip) {
            $skippedProcs += New-Object PSObject -Property @{ ProcessId=$procId; ProcessName=$pName }
            continue
        }

        # Try Win32_ProcessVMMapsFiles first, then CIM_ProcessExecutable
        $assocObjs = $null
        $useDependent = $false

        try {
            $assocObjs   = Get-WmiObject Win32_ProcessVMMapsFiles -Filter "Antecedent like '%Handle=""$procId""%'" -ErrorAction Stop
            $useDependent = $false
        } catch {
            try {
                $assocObjs   = Get-WmiObject CIM_ProcessExecutable -Filter "Dependent like '%Handle=""$procId""%'" -ErrorAction Stop
                $useDependent = $true
            } catch {
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
    
                    reason        = 'WMI_UNAVAILABLE'
                    source        = 'wmi'
                }
                continue
            }
        }

        if (-not $assocObjs) {
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

                reason        = 'WMI_UNAVAILABLE'
                source        = 'wmi'
            }
            continue
        }

        foreach ($assoc in $assocObjs) {
            $mPath = $null
            try {
                if (-not $useDependent) {
                    # Win32_ProcessVMMapsFiles: file ref is Dependent
                    $fileRef = $assoc.Dependent
                    $mPath   = ([wmi]$fileRef).Name
                } else {
                    # CIM_ProcessExecutable: file ref is Antecedent
                    $fileRef = $assoc.Antecedent
                    $mPath   = ([wmi]$fileRef).Name
                }
            } catch {}
            if (-not $mPath) { continue }

            $mName = [System.IO.Path]::GetFileName($mPath)

            # Filter non-module files (WMI returns all memory-mapped files)
            $ext = [System.IO.Path]::GetExtension($mPath).ToLower()
            if ($ext -and $ext -ne '.dll' -and $ext -ne '.exe' -and $ext -ne '.sys' -and $ext -ne '.drv' -and $ext -ne '.ocx' -and $ext -ne '.cpl') { continue }

            $isPrivate = $false
            foreach ($marker in $PRIVATE_MARKERS) {
                if ($mPath -like "*$marker*") { $isPrivate = $true; break }
            }

            $r = _sha256 $mPath; $fileHash = $r[0]; $sha256ErrW = $r[1]

            $ver     = $null
            $company = $null
            try {
                $escapedPath = $mPath -replace "\\","\\\\"
                $wmiFile = Get-WmiObject CIM_DataFile -Filter "Name='$escapedPath'" -ErrorAction Stop
                if ($wmiFile) {
                    $ver     = $wmiFile.Version
                    $company = $wmiFile.Manufacturer
                }
            } catch {}

            # Signature inline (PS 2.0 compatible)
            $sigW = $null
            try {
                $certW = [System.Security.Cryptography.X509Certificates.X509Certificate]::CreateFromSignedFile($mPath)
                $sigW = New-Object PSObject -Property @{
                    IsSigned=$true; IsValid=$null; Status='PS2_CERT_PRESENT'
                    SignerSubject=$certW.Subject; SignerCompany=$null; Issuer=$certW.Issuer
                    Thumbprint=$null; NotAfter=$null; TimeStamper=$null
                    IsOSBinary=$null; SignatureType=$null
                }
            } catch {
                $sigW = New-Object PSObject -Property @{
                    IsSigned=$null; IsValid=$null; Status='PS2_UNSUPPORTED'
                    SignerSubject=$null; SignerCompany=$null; Issuer=$null
                    Thumbprint=$null; NotAfter=$null; TimeStamper=$null
                    IsOSBinary=$null; SignatureType=$null
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
                SHA256Error   = $sha256ErrW
                IsPrivatePath = $isPrivate
                Signature     = $sigW

                reason        = $null
                source        = 'wmi'
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

    $useDotNet = ([int]$TargetPSVersion -ge 3)
    $sb        = if ($useDotNet) { $script:DLL_SB_DOTNET } else { $script:DLL_SB_WMI }

    $skippedProcs = @()

    try {
        if ($Session -ne $null) {
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
        $errors += @{ artifact = 'DLLs'; message = "Protected processes skipped for DLL enumeration: $($skippedNames -join ', ')" }
    }

    # Determine source string
    $hasDotnet = $false
    $hasWmi    = $false
    foreach ($d in $dlls) {
        if ($d.source -eq 'dotnet') { $hasDotnet = $true }
        if ($d.source -eq 'wmi')    { $hasWmi    = $true }
    }
    $src = if ($hasDotnet -and $hasWmi) { 'mixed' }
           elseif ($hasDotnet)          { 'dotnet' }
           elseif ($hasWmi)             { 'wmi' }
           else                         { if ($useDotNet) { 'dotnet' } else { 'wmi' } }

    return @{ data = @($dlls); source = $src; errors = $errors }
}

Export-ModuleMember -Function Invoke-Collector
