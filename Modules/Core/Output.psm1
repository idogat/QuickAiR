#Requires -Version 5.1
# ╔══════════════════════════════════════╗
# ║  QuickAiR — Output.psm1              ║
# ║  Logging, JSON write, SHA256,       ║
# ║  manifest building                  ║
# ╠══════════════════════════════════════╣
# ║  Exports   : Initialize-Log         ║
# ║              Write-Log              ║
# ║              Get-FileSha256         ║
# ║              Write-JsonOutput       ║
# ║              Build-Manifest         ║
# ║              Get-BinaryType         ║
# ║  Inputs    : path, data, hostname,  ║
# ║              caps, sources          ║
# ║  Output    : @{Path; Hash} (JSON)   ║
# ║              manifest ordered hash  ║
# ║  Depends   : none                   ║
# ║  PS compat : 5.1 (analyst machine)  ║
# ║  Version   : 2.3                    ║
# ╚══════════════════════════════════════╝

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

$script:LogFile  = $null
$script:IsQuiet  = $false

function Initialize-Log {
    param([string]$Path, [bool]$Quiet = $false)
    $script:LogFile  = $Path
    $script:IsQuiet  = $Quiet
}

function Write-Log {
    param([string]$Level, [string]$Message)
    $ts   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $line = "$ts $Level $Message"
    if ($script:LogFile) {
        Add-Content -Path $script:LogFile -Value $line -ErrorAction SilentlyContinue
    }
    if (-not $script:IsQuiet) {
        switch ($Level) {
            'ERROR' { Write-Host $line -ForegroundColor Red    }
            'WARN'  { Write-Host $line -ForegroundColor Yellow }
            default { Write-Host $line }
        }
    }
}

function Get-FileSha256 {
    param([string]$Path)
    try { return (Get-FileHash -Path $Path -Algorithm SHA256 -ErrorAction Stop).Hash }
    catch { return $null }
}

function Write-JsonOutput {
    param(
        $Data,
        [string]$HostDir,
        [string]$Hostname
    )

    if (-not (Test-Path $HostDir)) {
        New-Item -ItemType Directory -Path $HostDir -Force | Out-Null
    }

    $ts      = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
    $outFile = Join-Path $HostDir "$Hostname`_$ts.json"

    # Phase 1: serialize with sha256=null, compute hash
    $json = $Data | ConvertTo-Json -Depth 10 -Compress:$false
    $sha256bytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
        [System.Text.Encoding]::UTF8.GetBytes($json))
    $sha256 = ($sha256bytes | ForEach-Object { $_.ToString('X2') }) -join ''

    # Embed SHA256 — case-sensitive replace to only match manifest's lowercase "sha256",
    # not collector fields like "SHA256" which would get corrupted
    $json2 = $json -creplace '"sha256":\s+null', ('"sha256": "' + $sha256 + '"')
    if ($json2 -eq $json) { $json2 = $json -creplace '"sha256":\s*null', ('"sha256": "' + $sha256 + '"') }

    [System.IO.File]::WriteAllText($outFile, $json2, [System.Text.Encoding]::UTF8)

    return @{ Path = $outFile; Hash = $sha256 }
}

function Build-Manifest {
    param(
        $Hostname,
        $CollectorVersion,
        $AnalystOS,
        $Caps,
        [hashtable]$Sources,
        $NetworkAdapters,
        $CollectionErrors,
        $WinRMReachable = $null,
        $WmiReachable = $null,
        $SmbReachable = $null,
        $SmbShareName = $null,
        $ConnectionMethod = $null,
        $WmiFallbackUsed = $false,
        $DegradedArtifacts = @()
    )

    $manifest = [ordered]@{
        hostname                       = $Hostname
        collection_time_utc            = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        collector_version              = $CollectorVersion
        analyst_machine_hostname       = $env:COMPUTERNAME
        analyst_machine_os             = $AnalystOS
        analyst_ps_version             = $PSVersionTable.PSVersion.ToString()
        target_ps_version              = $Caps.PSVersion.ToString()
        target_os_version              = $Caps.OSVersion
        target_os_build                = $Caps.OSBuild
        target_os_caption              = $Caps.OSCaption
        target_is_server_core          = $Caps.IsServerCore
        target_timezone_offset_minutes = $Caps.TimezoneOffsetMinutes
        network_adapters               = $NetworkAdapters
    }

    # Add source entries: foreach key in Sources: manifest[$key+"_source"]=$Sources[$key]
    foreach ($key in $Sources.Keys) {
        $manifest[$key + '_source'] = $Sources[$key]
    }

    $manifest['winrm_reachable']   = $WinRMReachable
    $manifest['wmi_reachable']     = $WmiReachable
    $manifest['smb_reachable']     = $SmbReachable
    $manifest['smb_share_name']    = $SmbShareName
    $manifest['connection_method']  = $ConnectionMethod
    $manifest['wmi_fallback_used']  = $WmiFallbackUsed
    $manifest['degraded_artifacts'] = $DegradedArtifacts
    $manifest['sha256']            = $null
    $manifest['collection_errors'] = $CollectionErrors

    return $manifest
}

function Get-QuickAiRSha256 {
    param([string]$Path)
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $sha = [Security.Cryptography.SHA256]::Create()
        $hash = $sha.ComputeHash($bytes)
        $sha.Dispose()
        return ([BitConverter]::ToString($hash) -replace '-','').ToLower()
    } catch {
        return $null
    }
}

function Get-QuickAiRSignature {
    param([string]$Path)
    try {
        if ($PSVersionTable.PSVersion.Major -ge 3) {
            $sig = Get-AuthenticodeSignature -FilePath $Path -ErrorAction Stop
            $cert = $null
            if ($sig.SignerCertificate) {
                $subj = $sig.SignerCertificate.Subject
                $cn = if ($subj -match 'CN=([^,]+)') { $Matches[1].Trim() } else { $null }
                $cert = @{
                    Subject    = $subj
                    Issuer     = $sig.SignerCertificate.Issuer
                    Thumbprint = $sig.SignerCertificate.Thumbprint
                    NotAfter   = $sig.SignerCertificate.NotAfter.ToString('o')
                    CN         = $cn
                }
            }
            return @{
                IsSigned         = ($sig.Status -ne 'NotSigned')
                IsValid          = ($sig.Status -eq 'Valid')
                Status           = $sig.Status.ToString()
                SignerCertificate = $cert
                TimeStamper      = if ($sig.TimeStamperCertificate) { $sig.TimeStamperCertificate.Subject } else { $null }
            }
        } else {
            # PS 2.0 fallback
            try {
                $cert = [System.Security.Cryptography.X509Certificates.X509Certificate]::CreateFromSignedFile($Path)
                return @{ IsSigned=$true; IsValid=$null; Status='PS2_SIGNED'; SignerCertificate=@{Subject=$cert.Subject;Issuer=$cert.Issuer;Thumbprint=$null;NotAfter=$null;CN=$null}; TimeStamper=$null }
            } catch {
                return @{ IsSigned=$null; IsValid=$null; Status='PS2_UNSUPPORTED'; SignerCertificate=$null; TimeStamper=$null }
            }
        }
    } catch {
        return @{ IsSigned=$null; IsValid=$null; Status="ERROR: $($_.Exception.Message)"; SignerCertificate=$null; TimeStamper=$null }
    }
}

function Get-SidMetadata {
    param([string]$SID, [string]$MachineSIDPrefix = '')
    if (-not $SID) { return @{ SID=$null; AccountType='Unknown'; IsLocal=$false; IsDomain=$false; IsSystem=$false; IsAdmin=$false } }
    $acctType = switch -Regex ($SID) {
        '^S-1-5-18$' { 'SYSTEM'; break }
        '^S-1-5-19$' { 'LocalService'; break }
        '^S-1-5-20$' { 'NetworkService'; break }
        '^S-1-5-32-' { 'BuiltInGroup'; break }
        '^S-1-5-21-\d+-\d+-\d+-\d+$' {
            $rid = $SID.Split('-')[-1]
            switch ($rid) {
                '500' { 'LocalAdministrator' }
                '501' { 'LocalGuest' }
                '512' { 'DomainAdmins' }
                '513' { 'DomainUsers' }
                '514' { 'DomainGuests' }
                '515' { 'DomainComputers' }
                '516' { 'DomainControllers' }
                '519' { 'EnterpriseAdmins' }
                '520' { 'GroupPolicyCreators' }
                default { if ([int]$rid -ge 1000) { 'DomainUser' } else { 'BuiltIn' } }
            }
            break
        }
        default { 'Unknown' }
    }
    $isLocal  = ($MachineSIDPrefix -and $SID -match ('^' + [regex]::Escape($MachineSIDPrefix) + '-\d+$'))
    $isDomain = ($SID -match '^S-1-5-21-') -and (-not $isLocal)
    $isSystem = ($SID -match '^S-1-5-(18|19|20)$')
    $isAdmin  = ($SID -match '-500$') -or ($SID -eq 'S-1-5-32-544')
    return @{ SID=$SID; AccountType=$acctType; IsLocal=[bool]$isLocal; IsDomain=[bool]$isDomain; IsSystem=[bool]$isSystem; IsAdmin=[bool]$isAdmin }
}

function Get-BinaryType {
    param([string]$Path)
    $empty = [PSCustomObject]@{
        IsSFX            = $false
        SFXType          = $null
        DetectionMethod  = $null
        FileSizeBytes    = $null
        PESizeBytes      = $null
        AppendedBytes    = $null
    }
    try {
        if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            Write-Log "WARN" "Get-BinaryType: path not found or empty: $Path"
            return $empty
        }

        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $fileSize = $bytes.Length
        $empty.FileSizeBytes = $fileSize

        # Locate PE header
        if ($fileSize -lt 64) { return $empty }
        # e_lfanew at offset 0x3C (4 bytes LE)
        $peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
        if ($peOffset -lt 0 -or ($peOffset + 24) -ge $fileSize) { return $empty }
        # PE signature: "PE\0\0"
        if ($bytes[$peOffset] -ne 0x50 -or $bytes[$peOffset+1] -ne 0x45 -or
            $bytes[$peOffset+2] -ne 0x00 -or $bytes[$peOffset+3] -ne 0x00) {
            return $empty
        }

        # COFF header: Machine(2) Sections(2) TimeDateStamp(4) SymTablePtr(4) SymCount(4) OptHdrSize(2) Chars(2)
        $coffOffset      = $peOffset + 4
        if (($coffOffset + 20) -ge $fileSize) { return $empty }
        $numSections     = [BitConverter]::ToUInt16($bytes, $coffOffset + 2)
        $optHdrSize      = [BitConverter]::ToUInt16($bytes, $coffOffset + 16)

        # Optional header starts at coffOffset+20
        $optOffset = $coffOffset + 20
        if ($optOffset -ge $fileSize) { return $empty }

        # Section table starts after optional header
        $sectionTableOffset = $optOffset + $optHdrSize
        if ($sectionTableOffset -ge $fileSize) { return $empty }

        # Each section header: 40 bytes. Find the highest (rawOffset + rawSize).
        $peEnd = 0
        for ($i = 0; $i -lt $numSections; $i++) {
            $secOff = $sectionTableOffset + ($i * 40)
            if (($secOff + 40) -gt $fileSize) { break }
            $rawOffset = [BitConverter]::ToUInt32($bytes, $secOff + 20)
            $rawSize   = [BitConverter]::ToUInt32($bytes, $secOff + 16)
            $secEnd    = [int]$rawOffset + [int]$rawSize
            if ($secEnd -gt $peEnd) { $peEnd = $secEnd }
        }

        if ($peEnd -le 0 -or $peEnd -ge $fileSize) {
            # No appended data detectable via sections; still check version info
            $peEnd = $fileSize
        }

        $appendedBytes = $fileSize - $peEnd
        $empty.PESizeBytes    = $peEnd
        $empty.AppendedBytes  = $appendedBytes

        # --- Magic byte detection on appended data ---
        $sfxType   = $null
        $sfxMethod = $null

        if ($appendedBytes -ge 4) {
            $a = $peEnd  # start of appended region
            # Scan for magic bytes within appended region (up to first 256 bytes offset)
            $scanEnd = [Math]::Min($a + 256, $fileSize - 4)
            for ($j = $a; $j -le $scanEnd; $j++) {
                if ($j + 3 -ge $fileSize) { break }
                $b0 = $bytes[$j]; $b1 = $bytes[$j+1]; $b2 = $bytes[$j+2]; $b3 = $bytes[$j+3]
                # ZIP: 50 4B 03 04
                if ($b0 -eq 0x50 -and $b1 -eq 0x4B -and $b2 -eq 0x03 -and $b3 -eq 0x04) {
                    $sfxType = "ZIP"; $sfxMethod = "AppendedMagic:ZIP"; break
                }
                # RAR: 52 61 72 21
                if ($b0 -eq 0x52 -and $b1 -eq 0x61 -and $b2 -eq 0x72 -and $b3 -eq 0x21) {
                    $sfxType = "RAR"; $sfxMethod = "AppendedMagic:RAR"; break
                }
                # 7-zip: 37 7A BC AF 27 1C
                if ($b0 -eq 0x37 -and $b1 -eq 0x7A -and $b2 -eq 0xBC -and $b3 -eq 0xAF) {
                    $sfxType = "7zip"; $sfxMethod = "AppendedMagic:7zip"; break
                }
                # GZIP: 1F 8B
                if ($b0 -eq 0x1F -and $b1 -eq 0x8B) {
                    $sfxType = "GZIP"; $sfxMethod = "AppendedMagic:GZIP"; break
                }
                # Appended PE: 4D 5A
                if ($b0 -eq 0x4D -and $b1 -eq 0x5A) {
                    $sfxType = "PE"; $sfxMethod = "AppendedMagic:PE"; break
                }
            }
        }

        # Also scan full file bytes for magic if not found yet (handles embedded archives)
        if (-not $sfxType -and $fileSize -ge 4) {
            $scanEnd2 = [Math]::Min($fileSize - 4, $peEnd)
            for ($j = 0; $j -le $scanEnd2; $j++) {
                $b0 = $bytes[$j]; $b1 = $bytes[$j+1]
                if ($j + 3 -ge $fileSize) { break }
                $b2 = $bytes[$j+2]; $b3 = $bytes[$j+3]
                if ($b0 -eq 0x50 -and $b1 -eq 0x4B -and $b2 -eq 0x03 -and $b3 -eq 0x04) {
                    $sfxType = "ZIP"; $sfxMethod = "EmbeddedMagic:ZIP"; break
                }
                if ($b0 -eq 0x52 -and $b1 -eq 0x61 -and $b2 -eq 0x72 -and $b3 -eq 0x21) {
                    $sfxType = "RAR"; $sfxMethod = "EmbeddedMagic:RAR"; break
                }
                if ($b0 -eq 0x37 -and $b1 -eq 0x7A -and $b2 -eq 0xBC -and $b3 -eq 0xAF) {
                    $sfxType = "7zip"; $sfxMethod = "EmbeddedMagic:7zip"; break
                }
            }
        }

        # --- NSIS marker: "Nullsoft" string in PE ---
        if (-not $sfxType) {
            $nsisSig = [System.Text.Encoding]::ASCII.GetBytes("Nullsoft")
            $found = $false
            for ($j = 0; $j -le ($fileSize - $nsisSig.Length); $j++) {
                $match = $true
                for ($k = 0; $k -lt $nsisSig.Length; $k++) {
                    if ($bytes[$j+$k] -ne $nsisSig[$k]) { $match = $false; break }
                }
                if ($match) { $found = $true; break }
            }
            if ($found) { $sfxType = "NSIS"; $sfxMethod = "NSISMarker" }
        }

        # --- PE version info keywords (ASCII scan) ---
        if (-not $sfxType) {
            $keywords = @("Self-Extractor","SFX","NSIS","Inno Setup")
            $peBytes  = if ($peEnd -lt $fileSize) { $bytes[0..($peEnd-1)] } else { $bytes }
            $peText   = [System.Text.Encoding]::ASCII.GetString($peBytes)
            foreach ($kw in $keywords) {
                if ($peText.IndexOf($kw, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $sfxType = switch -Regex ($kw) {
                        'NSIS|Nullsoft' { "NSIS" }
                        'Inno'          { "ZIP"  }
                        default         { "Unknown" }
                    }
                    $sfxMethod = "VersionInfoKeyword:$kw"
                    break
                }
            }
        }

        if ($sfxType) {
            return [PSCustomObject]@{
                IsSFX           = $true
                SFXType         = $sfxType
                DetectionMethod = $sfxMethod
                FileSizeBytes   = $fileSize
                PESizeBytes     = $peEnd
                AppendedBytes   = $appendedBytes
            }
        }
        return $empty
    } catch {
        Write-Log "WARN" "Get-BinaryType error on '$Path': $($_.Exception.Message)"
        return $empty
    }
}

Export-ModuleMember -Function Write-Log, Get-FileSha256, Initialize-Log, Write-JsonOutput, Build-Manifest, Get-QuickAiRSha256, Get-QuickAiRSignature, Get-SidMetadata, Get-BinaryType
