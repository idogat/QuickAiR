#Requires -Version 5.1
# ╔══════════════════════════════════════╗
# ║  Quicker — T03_Manifest.ps1         ║
# ║  T8 manifest integrity + SHA256,    ║
# ║  T9 collection error log audit      ║
# ╠══════════════════════════════════════╣
# ║  Inputs    : -JsonPath -HtmlPath    ║
# ║  Output    : @{ Passed=@();         ║
# ║               Failed=@(); Info=@() }║
# ║  PS compat : 5.1                    ║
# ╚══════════════════════════════════════╝
[CmdletBinding()]
param(
    [string]$JsonPath = "",
    [string]$HtmlPath = ""
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

$script:passResults = @()
$script:failResults = @()
$script:infoResults = @()

function Add-R {
    param([string]$Id, [bool]$Pass, [string]$Summary, [string[]]$Details=@(), [bool]$IsInfo=$false)
    $obj = [PSCustomObject]@{Id=$Id;Pass=$Pass;InfoOnly=$IsInfo;Summary=$Summary;Details=$Details}
    if ($IsInfo)       { $script:infoResults  += $obj }
    elseif ($Pass)     { $script:passResults  += $obj }
    else               { $script:failResults  += $obj }
}

# Load JSON
$jsonRaw  = [System.IO.File]::ReadAllText($JsonPath, [System.Text.Encoding]::UTF8)
$data     = $jsonRaw | ConvertFrom-Json
$manifest = $data.manifest

# ---------------------------------------------------------------
# T8 - Manifest integrity
# ---------------------------------------------------------------
$t8Fails = @()

# SHA256 verification - reconstruct pre-hash JSON by replacing stored hash with null
$storedHash = $manifest.sha256
if ($storedHash) {
    $hashVerified = $false
    foreach ($nullFmt in @('  null', ' null', 'null')) {
        $reconstructed = $jsonRaw -replace ('"sha256":\s*"[^"]*"'), ('"sha256":' + $nullFmt)
        $bytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($reconstructed))
        $computed = ($bytes | ForEach-Object { $_.ToString('X2') }) -join ''
        if ($computed -ieq $storedHash) { $hashVerified = $true; break }
    }
    if (-not $hashVerified) { $t8Fails += "sha256 mismatch: stored=$storedHash" }
} else {
    $t8Fails += "sha256 field is null or missing"
}

# collection_time_utc
if ($manifest.collection_time_utc -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') {
    $t8Fails += "collection_time_utc not valid ISO 8601: $($manifest.collection_time_utc)"
}

# target_ps_version numeric
if ($manifest.target_ps_version -notmatch '^\d') {
    $t8Fails += "target_ps_version not numeric: $($manifest.target_ps_version)"
}

# Network_source.network validation
# Sources are stored as <CollectorBaseName>_source in manifest
# Network collector stores source as @{ network = ...; dns = ... }
$networkSourceObj = $manifest.Network_source
if ($networkSourceObj) {
    $netSrcVal = $networkSourceObj.network
    $validNetSrc = @('cim','netstat_fallback','netstat_legacy')
    if ($validNetSrc -notcontains $netSrcVal) {
        $t8Fails += "Network_source.network invalid: '$netSrcVal' - expected one of: $($validNetSrc -join '|')"
    }
    $dnsSrcVal = $networkSourceObj.dns
    $validDnsSrc = @('cim','ipconfig_fallback','ipconfig_legacy')
    if ($validDnsSrc -notcontains $dnsSrcVal) {
        $t8Fails += "Network_source.dns invalid: '$dnsSrcVal' - expected one of: $($validDnsSrc -join '|')"
    }
} else {
    # Backwards compat: try flat fields
    $validNetSrc = @('cim','netstat_fallback','netstat_legacy')
    if ($manifest.network_source -and $validNetSrc -notcontains $manifest.network_source) {
        $t8Fails += "network_source invalid: '$($manifest.network_source)' - expected one of: $($validNetSrc -join '|')"
    } elseif (-not $manifest.network_source -and -not $networkSourceObj) {
        $t8Fails += "Network_source (or network_source) field missing from manifest"
    }
    $validDnsSrc = @('cim','ipconfig_fallback','ipconfig_legacy')
    if ($manifest.dns_source -and $validDnsSrc -notcontains $manifest.dns_source) {
        $t8Fails += "dns_source invalid: '$($manifest.dns_source)' - expected one of: $($validDnsSrc -join '|')"
    } elseif (-not $manifest.dns_source -and -not $networkSourceObj) {
        $t8Fails += "dns_source (or Network_source.dns) field missing from manifest"
    }
}

if ($t8Fails.Count -eq 0) {
    Add-R "T8" $true "Manifest integrity (SHA256 OK, all fields valid)"
} else {
    Add-R "T8" $false "Manifest integrity ($($t8Fails.Count) failures)" $t8Fails
}

# ---------------------------------------------------------------
# T9 - No silent drops (collection_errors)
# ---------------------------------------------------------------
$collErrs  = @($manifest.collection_errors)
$errCount  = $collErrs.Count
$t9Malform = @()
foreach ($e in $collErrs) {
    if ($e -eq $null)          { $t9Malform += "null entry in collection_errors"; continue }
    if (-not $e.artifact)      { $t9Malform += "entry missing 'artifact' field: $($e | ConvertTo-Json -Compress)" }
    if (-not $e.message)       { $t9Malform += "entry missing 'message' field: $($e | ConvertTo-Json -Compress)" }
}

if ($t9Malform.Count -eq 0) {
    Add-R "T9" $true "collection_errors: $errCount entries" @() $true
} else {
    Add-R "T9" $false "collection_errors: $($t9Malform.Count) malformed entries" $t9Malform
}

return @{ Passed=$script:passResults; Failed=$script:failResults; Info=$script:infoResults }
