#Requires -Version 5.1
# ╔══════════════════════════════════════╗
# ║  Quicker — DLLs.psm1                ║
# ║  Loaded modules per process.        ║
# ║  SHA256 for non-system DLLs.        ║
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
# ║  Version   : 2.0                    ║
# ╚══════════════════════════════════════╝

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# ── .NET scriptblock (PS 3+) ─────────────────────────────────────────────────
$script:DLL_SB_DOTNET = {
    $PROTECTED_PROCS  = @('lsass','csrss','smss','wininit','System','Idle')
    $SYS32_PATH       = 'C:\Windows\System32\'
    $SYSWOW_PATH      = 'C:\Windows\SysWOW64\'
    $PRIVATE_MARKERS  = @('\Temp\','\AppData\','\ProgramData\','\Users\Public\','\Downloads\')

    $out = @()
    $allProcs = $null
    try { $allProcs = [System.Diagnostics.Process]::GetProcesses() } catch { $allProcs = @() }

    foreach ($p in $allProcs) {
        $pName = $null
        try { $pName = $p.ProcessName } catch {}
        if (-not $pName) { continue }

        $skip = $false
        foreach ($pp in $PROTECTED_PROCS) { if ($pName -ieq $pp) { $skip = $true; break } }
        if ($skip) { continue }

        $pId = $null
        try { $pId = [int]$p.Id } catch {}
        if ($pId -eq $null) { continue }

        $mods = $null
        try {
            $mods = $p.Modules
        } catch {
            $reason = if ($_.Exception.Message -match 'Access') { 'ACCESS_DENIED' } else { $_.Exception.Message }
            $out += New-Object PSObject -Property @{
                ProcessId     = $pId
                ProcessName   = $pName
                ModuleName    = $null
                ModulePath    = $null
                FileVersion   = $null
                Company       = $null
                FileHash      = $null
                IsPrivatePath = $null
                IsSigned      = $null
                LoadedAt      = $null
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

            $isSystem = $false
            if ($mPath) {
                if ($mPath -like "$SYS32_PATH*" -or $mPath -like "$SYSWOW_PATH*") { $isSystem = $true }
            }

            $isPrivate = $false
            if ($mPath) {
                foreach ($marker in $PRIVATE_MARKERS) {
                    if ($mPath -like "*$marker*") { $isPrivate = $true; break }
                }
            }

            $fileHash = $null
            if ($mPath -and -not $isSystem) {
                try {
                    $bytes  = [System.IO.File]::ReadAllBytes($mPath)
                    $hasher = [Security.Cryptography.SHA256]::Create()
                    $hashBytes = $hasher.ComputeHash($bytes)
                    $fileHash = ([BitConverter]::ToString($hashBytes) -replace '-','').ToLower()
                    $hasher.Dispose()
                } catch {}
            }

            $ver     = $null
            $company = $null
            if ($mPath) {
                try {
                    $fvi     = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($mPath)
                    $ver     = $fvi.FileVersion
                    $company = $fvi.CompanyName
                } catch {}
            }

            $signed = $null
            if ($mPath) {
                try {
                    $sig    = Get-AuthenticodeSignature -FilePath $mPath -ErrorAction Stop
                    $signed = ($sig.Status -eq 'Valid')
                } catch {}
            }

            $out += New-Object PSObject -Property @{
                ProcessId     = $pId
                ProcessName   = $pName
                ModuleName    = $mName
                ModulePath    = $mPath
                FileVersion   = $ver
                Company       = $company
                FileHash      = $fileHash
                IsPrivatePath = $isPrivate
                IsSigned      = $signed
                LoadedAt      = $null
                reason        = $null
                source        = 'dotnet'
            }
        }
    }
    $out
}

# ── WMI scriptblock (PS 2.0) ─────────────────────────────────────────────────
$script:DLL_SB_WMI = {
    $PROTECTED_PROCS  = @('lsass','csrss','smss','wininit','System','Idle')
    $SYS32_PATH       = 'C:\Windows\System32\'
    $SYSWOW_PATH      = 'C:\Windows\SysWOW64\'
    $PRIVATE_MARKERS  = @('\Temp\','\AppData\','\ProgramData\','\Users\Public\','\Downloads\')

    $out = @()
    $procs = $null
    try { $procs = Get-WmiObject Win32_Process } catch { $procs = @() }

    foreach ($p in $procs) {
        $pName = $null
        $pId   = $null
        try { $pName = $p.Name }      catch {}
        try { $pId   = [int]$p.ProcessId } catch {}
        if (-not $pId -and $pId -ne 0) { continue }
        if (-not $pName) { continue }

        $pNameNoExt = $pName -replace '\.exe$',''
        $skip = $false
        foreach ($pp in $PROTECTED_PROCS) {
            if ($pNameNoExt -ieq $pp -or $pName -ieq $pp) { $skip = $true; break }
        }
        if ($skip) { continue }

        # Try Win32_ProcessVMMapsFiles first, then CIM_ProcessExecutable
        $assocObjs = $null
        $useDependent = $false

        try {
            $assocObjs   = Get-WmiObject Win32_ProcessVMMapsFiles -Filter "Antecedent like '%Handle=""$pId""%'" -ErrorAction Stop
            $useDependent = $false
        } catch {
            try {
                $assocObjs   = Get-WmiObject CIM_ProcessExecutable -Filter "Dependent like '%Handle=""$pId""%'" -ErrorAction Stop
                $useDependent = $true
            } catch {
                $out += New-Object PSObject -Property @{
                    ProcessId     = $pId
                    ProcessName   = $pName
                    ModuleName    = $null
                    ModulePath    = $null
                    FileVersion   = $null
                    Company       = $null
                    FileHash      = $null
                    IsPrivatePath = $null
                    IsSigned      = $null
                    LoadedAt      = $null
                    reason        = 'WMI_UNAVAILABLE'
                    source        = 'wmi'
                }
                continue
            }
        }

        if (-not $assocObjs) {
            $out += New-Object PSObject -Property @{
                ProcessId     = $pId
                ProcessName   = $pName
                ModuleName    = $null
                ModulePath    = $null
                FileVersion   = $null
                Company       = $null
                FileHash      = $null
                IsPrivatePath = $null
                IsSigned      = $null
                LoadedAt      = $null
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

            $isSystem = $false
            if ($mPath -like "$SYS32_PATH*" -or $mPath -like "$SYSWOW_PATH*") { $isSystem = $true }

            $isPrivate = $false
            foreach ($marker in $PRIVATE_MARKERS) {
                if ($mPath -like "*$marker*") { $isPrivate = $true; break }
            }

            $fileHash = $null
            if (-not $isSystem) {
                try {
                    $bytes     = [System.IO.File]::ReadAllBytes($mPath)
                    $hasher    = [Security.Cryptography.SHA256]::Create()
                    $hashBytes = $hasher.ComputeHash($bytes)
                    $fileHash  = ([BitConverter]::ToString($hashBytes) -replace '-','').ToLower()
                    $hasher.Dispose()
                } catch {}
            }

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

            $signed = $null
            try {
                $sig    = Get-AuthenticodeSignature -FilePath $mPath -ErrorAction Stop
                $signed = ($sig.Status -eq 'Valid')
            } catch {}

            $out += New-Object PSObject -Property @{
                ProcessId     = $pId
                ProcessName   = $pName
                ModuleName    = $mName
                ModulePath    = $mPath
                FileVersion   = $ver
                Company       = $company
                FileHash      = $fileHash
                IsPrivatePath = $isPrivate
                IsSigned      = $signed
                LoadedAt      = $null
                reason        = $null
                source        = 'wmi'
            }
        }
    }
    $out
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

    try {
        if ($Session -ne $null) {
            $raw = Invoke-Command -Session $Session -ScriptBlock $sb
        } else {
            $raw = & $sb
        }

        foreach ($entry in @($raw)) {
            $dlls += @{
                ProcessId     = $entry.ProcessId
                ProcessName   = $entry.ProcessName
                ModuleName    = $entry.ModuleName
                ModulePath    = $entry.ModulePath
                FileVersion   = $entry.FileVersion
                Company       = $entry.Company
                FileHash      = $entry.FileHash
                IsPrivatePath = $entry.IsPrivatePath
                IsSigned      = $entry.IsSigned
                LoadedAt      = $entry.LoadedAt
                reason        = $entry.reason
                source        = $entry.source
            }
        }
    } catch {
        $errors += @{ artifact = 'DLLs'; message = $_.Exception.Message }
        Write-Log 'ERROR' "DLL collection failed: $($_.Exception.Message)"
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
