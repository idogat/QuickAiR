#Requires -Version 5.1
# ╔══════════════════════════════════════╗
# ║  Quicker — Output.psm1              ║
# ║  Logging, JSON write, SHA256,       ║
# ║  manifest building                  ║
# ╠══════════════════════════════════════╣
# ║  Exports   : Initialize-Log         ║
# ║              Write-Log              ║
# ║              Get-FileSha256         ║
# ║              Write-JsonOutput       ║
# ║              Build-Manifest         ║
# ║  Inputs    : path, data, hostname,  ║
# ║              caps, sources          ║
# ║  Output    : @{Path; Hash} (JSON)   ║
# ║              manifest ordered hash  ║
# ║  Depends   : none                   ║
# ║  PS compat : 5.1 (analyst machine)  ║
# ║  Version   : 2.0                    ║
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

    # Embed SHA256
    $json2 = $json -replace '"sha256":\s+null', ('"sha256": "' + $sha256 + '"')
    if ($json2 -eq $json) { $json2 = $json -replace '"sha256":\s*null', ('"sha256": "' + $sha256 + '"') }

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
        $CollectionErrors
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

    $manifest['sha256']            = $null
    $manifest['collection_errors'] = $CollectionErrors

    return $manifest
}

function Get-QuickerSha256 {
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

function Get-QuickerSignature {
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

Export-ModuleMember -Function Write-Log, Get-FileSha256, Initialize-Log, Write-JsonOutput, Build-Manifest, Get-QuickerSha256, Get-QuickerSignature
