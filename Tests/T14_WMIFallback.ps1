#Requires -Version 5.1
# =============================================
#   QuickAiR -- T14_WMIFallback.ps1
#   T97  Manifest: connection_method=WMI, wmi_fallback_used=true
#   T98  Manifest: degraded_artifacts list completeness
#   T99  Manifest: source fields correct for WMI fallback
#   T100 Manifest: network_adapters present and non-empty
#   T101 collection_errors: required artifact entries present
#   T102 collection_errors: all entries have artifact+message fields
#   T103 Processes: source='wmi_remote' on all records
#   T104 Processes: SHA256Error='WMI_REMOTE_UNSUPPORTED' on all records
#   T105 Processes: IntegrityLevelError='WMI_REMOTE_UNSUPPORTED' on all records
#   T106 Processes: Signature.Status='WMI_REMOTE_UNSUPPORTED' on all records
#   T107 Processes: SHA256 and IntegrityLevel are null (not populated)
#   T108 Processes: required fields present on all records
#   T109 Processes: count > 0 (WMI process enumeration produced data)
#   T110 DLLs: present as empty array (not null)
#   T111 DLLs: DLLs_source='wmi_unsupported'
#   T112 Network: tcp sub-key present (Win8+/2012+ WMI path)
#   T113 Network: dns is empty array
#   T114 Network: dns source='wmi_remote_unavailable'
#   T115 Network: tcp records have required fields
#   T116 Users: present and non-empty
#   T117 Users: source starts with 'wmi_remote'
#   T118 Users: required top-level fields present
#   T119 Users: each user record has required fields
#   T120 Cross-check: network tcp OwningProcess PIDs exist in Processes
# =============================================
#   Inputs    : -JsonPath (WMI-fallback JSON file)
#               -HtmlPath (unused, for suite compat)
#   Output    : @{ Passed=@(); Failed=@(); Info=@() }
#   PS compat : 5.1
# =============================================
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

# ---------------------------------------------------------------
# Load JSON — prefer the supplied JsonPath, fall back to the
# known WMI-fallback fixture in the repo.
# ---------------------------------------------------------------
$scriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoDir     = Split-Path -Parent $scriptDir
$fixturePath = Join-Path $repoDir 'DFIROutput\DESKTOP-3JH57JT.local\DESKTOP-3JH57JT.local_20260403003337.json'

$resolvedPath = $JsonPath
if ([string]::IsNullOrEmpty($resolvedPath) -or -not (Test-Path $resolvedPath)) {
    $resolvedPath = $fixturePath
}

if (-not (Test-Path $resolvedPath)) {
    Add-R "T97"  $true  "WMI fallback JSON not found — all WMI fallback tests skipped (path: $resolvedPath)" @() $true
    Add-R "T98"  $true  "WMI fallback JSON not found — skipped" @() $true
    Add-R "T99"  $true  "WMI fallback JSON not found — skipped" @() $true
    Add-R "T100" $true  "WMI fallback JSON not found — skipped" @() $true
    Add-R "T101" $true  "WMI fallback JSON not found — skipped" @() $true
    Add-R "T102" $true  "WMI fallback JSON not found — skipped" @() $true
    Add-R "T103" $true  "WMI fallback JSON not found — skipped" @() $true
    Add-R "T104" $true  "WMI fallback JSON not found — skipped" @() $true
    Add-R "T105" $true  "WMI fallback JSON not found — skipped" @() $true
    Add-R "T106" $true  "WMI fallback JSON not found — skipped" @() $true
    Add-R "T107" $true  "WMI fallback JSON not found — skipped" @() $true
    Add-R "T108" $true  "WMI fallback JSON not found — skipped" @() $true
    Add-R "T109" $true  "WMI fallback JSON not found — skipped" @() $true
    Add-R "T110" $true  "WMI fallback JSON not found — skipped" @() $true
    Add-R "T111" $true  "WMI fallback JSON not found — skipped" @() $true
    Add-R "T112" $true  "WMI fallback JSON not found — skipped" @() $true
    Add-R "T113" $true  "WMI fallback JSON not found — skipped" @() $true
    Add-R "T114" $true  "WMI fallback JSON not found — skipped" @() $true
    Add-R "T115" $true  "WMI fallback JSON not found — skipped" @() $true
    Add-R "T116" $true  "WMI fallback JSON not found — skipped" @() $true
    Add-R "T117" $true  "WMI fallback JSON not found — skipped" @() $true
    Add-R "T118" $true  "WMI fallback JSON not found — skipped" @() $true
    Add-R "T119" $true  "WMI fallback JSON not found — skipped" @() $true
    Add-R "T120" $true  "WMI fallback JSON not found — skipped" @() $true
    return @{ Passed=$script:passResults; Failed=$script:failResults; Info=$script:infoResults }
}

$jsonRaw = [System.IO.File]::ReadAllText($resolvedPath, [System.Text.Encoding]::UTF8)
$data    = $jsonRaw | ConvertFrom-Json

# Guard: if manifest is absent the JSON is completely invalid
if ($null -eq $data -or $null -eq $data.manifest) {
    Add-R "T97" $false "manifest object missing — JSON may be corrupt or wrong file" @("Path: $resolvedPath")
    return @{ Passed=$script:passResults; Failed=$script:failResults; Info=$script:infoResults }
}

$mf = $data.manifest

# Gate: skip all WMI-specific tests if this is not a WMI-fallback JSON
$isWmiFallback = ($mf.connection_method -eq 'WMI') -and ($mf.wmi_fallback_used -eq $true)
if (-not $isWmiFallback) {
    $note = "connection_method=$($mf.connection_method) wmi_fallback_used=$($mf.wmi_fallback_used)"
    Add-R "T97"  $true "Not a WMI-fallback JSON ($note) — all WMI fallback tests skipped" @() $true
    Add-R "T98"  $true "Not a WMI-fallback JSON — skipped" @() $true
    Add-R "T99"  $true "Not a WMI-fallback JSON — skipped" @() $true
    Add-R "T100" $true "Not a WMI-fallback JSON — skipped" @() $true
    Add-R "T101" $true "Not a WMI-fallback JSON — skipped" @() $true
    Add-R "T102" $true "Not a WMI-fallback JSON — skipped" @() $true
    Add-R "T103" $true "Not a WMI-fallback JSON — skipped" @() $true
    Add-R "T104" $true "Not a WMI-fallback JSON — skipped" @() $true
    Add-R "T105" $true "Not a WMI-fallback JSON — skipped" @() $true
    Add-R "T106" $true "Not a WMI-fallback JSON — skipped" @() $true
    Add-R "T107" $true "Not a WMI-fallback JSON — skipped" @() $true
    Add-R "T108" $true "Not a WMI-fallback JSON — skipped" @() $true
    Add-R "T109" $true "Not a WMI-fallback JSON — skipped" @() $true
    Add-R "T110" $true "Not a WMI-fallback JSON — skipped" @() $true
    Add-R "T111" $true "Not a WMI-fallback JSON — skipped" @() $true
    Add-R "T112" $true "Not a WMI-fallback JSON — skipped" @() $true
    Add-R "T113" $true "Not a WMI-fallback JSON — skipped" @() $true
    Add-R "T114" $true "Not a WMI-fallback JSON — skipped" @() $true
    Add-R "T115" $true "Not a WMI-fallback JSON — skipped" @() $true
    Add-R "T116" $true "Not a WMI-fallback JSON — skipped" @() $true
    Add-R "T117" $true "Not a WMI-fallback JSON — skipped" @() $true
    Add-R "T118" $true "Not a WMI-fallback JSON — skipped" @() $true
    Add-R "T119" $true "Not a WMI-fallback JSON — skipped" @() $true
    Add-R "T120" $true "Not a WMI-fallback JSON — skipped" @() $true
    return @{ Passed=$script:passResults; Failed=$script:failResults; Info=$script:infoResults }
}

# ---------------------------------------------------------------
# T97 — Manifest: connection_method=WMI and wmi_fallback_used=true
# ---------------------------------------------------------------
$t97d = @()
if ($mf.connection_method -ne 'WMI') {
    $t97d += "connection_method='$($mf.connection_method)' expected 'WMI'"
}
if ($mf.wmi_fallback_used -ne $true) {
    $t97d += "wmi_fallback_used=$($mf.wmi_fallback_used) expected true"
}
if ($null -eq $mf.PSObject.Properties['winrm_reachable']) {
    $t97d += "manifest.winrm_reachable field missing"
} elseif ($mf.winrm_reachable -ne $false) {
    $t97d += "winrm_reachable=$($mf.winrm_reachable) — WMI fallback implies WinRM was not available"
}
if ($null -eq $mf.PSObject.Properties['wmi_reachable']) {
    $t97d += "manifest.wmi_reachable field missing"
} elseif ($mf.wmi_reachable -ne $true) {
    $t97d += "wmi_reachable=$($mf.wmi_reachable) — WMI fallback requires wmi_reachable=true"
}
if ($t97d.Count -eq 0) {
    Add-R "T97" $true "Manifest: connection_method=WMI, wmi_fallback_used=true, winrm_reachable=false, wmi_reachable=true"
} else {
    Add-R "T97" $false "Manifest WMI fallback flags incorrect ($($t97d.Count) issues)" $t97d
}

# ---------------------------------------------------------------
# T98 — Manifest: degraded_artifacts list completeness
# ---------------------------------------------------------------
$expectedDegraded = @('DLLs','DNS_cache','process_hashes','process_signatures','integrity_levels','dotnet_crosscheck','user_firstlogon_timestamps')
$actualDegraded   = @()
if ($mf.PSObject.Properties['degraded_artifacts'] -and $null -ne $mf.degraded_artifacts) {
    $actualDegraded = @($mf.degraded_artifacts)
}
$t98d = @()
foreach ($expected in $expectedDegraded) {
    if ($actualDegraded -notcontains $expected) {
        $t98d += "Missing degraded_artifact: '$expected'"
    }
}
if ($actualDegraded.Count -eq 0) {
    $t98d += "degraded_artifacts is absent or empty"
}
if ($t98d.Count -eq 0) {
    Add-R "T98" $true "manifest.degraded_artifacts contains all 7 expected entries: $($expectedDegraded -join ', ')"
} else {
    Add-R "T98" $false "manifest.degraded_artifacts incomplete ($($t98d.Count) missing)" $t98d
}

# ---------------------------------------------------------------
# T99 — Manifest: source fields correct for WMI fallback
# ---------------------------------------------------------------
$t99d = @()

# Processes_source
if ($null -eq $mf.PSObject.Properties['Processes_source']) {
    $t99d += "manifest.Processes_source field missing"
} elseif ($mf.Processes_source -ne 'wmi_remote') {
    $t99d += "Processes_source='$($mf.Processes_source)' expected 'wmi_remote'"
}

# DLLs_source
if ($null -eq $mf.PSObject.Properties['DLLs_source']) {
    $t99d += "manifest.DLLs_source field missing"
} elseif ($mf.DLLs_source -ne 'wmi_unsupported') {
    $t99d += "DLLs_source='$($mf.DLLs_source)' expected 'wmi_unsupported'"
}

# Users_source
if ($null -eq $mf.PSObject.Properties['Users_source']) {
    $t99d += "manifest.Users_source field missing"
} elseif ($mf.Users_source -notlike 'wmi_remote*') {
    $t99d += "Users_source='$($mf.Users_source)' expected to start with 'wmi_remote'"
}

# Network_source sub-object
if ($null -eq $mf.PSObject.Properties['Network_source'] -or $null -eq $mf.Network_source) {
    $t99d += "manifest.Network_source object missing"
} else {
    $ns = $mf.Network_source
    if ($null -eq $ns.PSObject.Properties['dns']) {
        $t99d += "manifest.Network_source.dns missing"
    } elseif ($ns.dns -ne 'wmi_remote_unavailable') {
        $t99d += "Network_source.dns='$($ns.dns)' expected 'wmi_remote_unavailable'"
    }
}

if ($t99d.Count -eq 0) {
    Add-R "T99" $true "Manifest source fields correct: Processes_source=wmi_remote, DLLs_source=wmi_unsupported, Users_source=wmi_remote*, Network_source.dns=wmi_remote_unavailable"
} else {
    Add-R "T99" $false "Manifest source fields incorrect ($($t99d.Count) issues)" $t99d
}

# ---------------------------------------------------------------
# T100 — Manifest: network_adapters present and non-empty
# Adapters are in manifest.network_adapters for WMI collections.
# ---------------------------------------------------------------
$t100d = @()
if ($null -eq $mf.PSObject.Properties['network_adapters'] -or $null -eq $mf.network_adapters) {
    $t100d += "manifest.network_adapters missing"
} else {
    $adapters = @($mf.network_adapters)
    if ($adapters.Count -eq 0) {
        $t100d += "manifest.network_adapters is empty — expected at least one adapter"
    } else {
        # Each adapter should have basic fields
        $reqAdapterFields = @('IPAddresses','MACAddress','InterfaceAlias')
        $adpViolations = @()
        foreach ($adp in $adapters) {
            foreach ($f in $reqAdapterFields) {
                if ($null -eq $adp.PSObject.Properties[$f]) {
                    $adpViolations += "Adapter missing field: $f"
                }
            }
        }
        if ($adpViolations.Count -gt 0) {
            $t100d += $adpViolations | Select-Object -First 25
        }
    }
}
if ($t100d.Count -eq 0) {
    $adpCount = @($mf.network_adapters).Count
    Add-R "T100" $true "manifest.network_adapters present with $adpCount adapter(s), required fields present"
} else {
    Add-R "T100" $false "manifest.network_adapters issues ($($t100d.Count))" $t100d
}

# ---------------------------------------------------------------
# T101 — collection_errors: required artifact entries present
# Expected artifact values: DLLs, dns_cache, processes, dotnet_crosscheck
# ---------------------------------------------------------------
$errors = @()
if ($mf.PSObject.Properties['collection_errors'] -and $null -ne $mf.collection_errors) {
    $errors = @($mf.collection_errors)
}

$requiredErrorArtifacts = @('DLLs','dns_cache','processes','dotnet_crosscheck')
$t101d = @()
$actualArtifacts = @($errors | Where-Object { $null -ne $_.PSObject.Properties['artifact'] } | ForEach-Object { $_.artifact })

foreach ($req in $requiredErrorArtifacts) {
    if ($actualArtifacts -notcontains $req) {
        $t101d += "collection_errors missing entry for artifact: '$req'"
    }
}

if ($t101d.Count -eq 0) {
    Add-R "T101" $true "collection_errors contains all 4 required artifact entries: $($requiredErrorArtifacts -join ', ')"
} else {
    Add-R "T101" $false "collection_errors missing required artifact entries ($($t101d.Count) missing)" $t101d
}

# ---------------------------------------------------------------
# T102 — collection_errors: all entries have artifact and message
# ---------------------------------------------------------------
$t102d = @()
foreach ($err in $errors) {
    $id = if ($null -ne $err.PSObject.Properties['artifact']) { $err.artifact } else { '(no artifact)' }
    if ($null -eq $err.PSObject.Properties['artifact'] -or [string]::IsNullOrEmpty($err.artifact)) {
        $t102d += "Error entry missing 'artifact' field"
    }
    if ($null -eq $err.PSObject.Properties['message'] -or [string]::IsNullOrEmpty($err.message)) {
        $t102d += "Error entry for '$id' missing 'message' field"
    }
}
if ($t102d.Count -eq 0) {
    Add-R "T102" $true "collection_errors structure valid: $($errors.Count) entries, all have artifact+message"
} else {
    Add-R "T102" $false "collection_errors structure invalid ($($t102d.Count) issues)" ($t102d | Select-Object -First 25)
}

# ---------------------------------------------------------------
# Processes section — gate on presence
# ---------------------------------------------------------------
if ($null -eq $data.PSObject.Properties['Processes'] -or $null -eq $data.Processes) {
    Add-R "T103" $true "Processes key absent in JSON — WMI Processes tests skipped" @() $true
    Add-R "T104" $true "Processes key absent — skipped" @() $true
    Add-R "T105" $true "Processes key absent — skipped" @() $true
    Add-R "T106" $true "Processes key absent — skipped" @() $true
    Add-R "T107" $true "Processes key absent — skipped" @() $true
    Add-R "T108" $true "Processes key absent — skipped" @() $true
    Add-R "T109" $true "Processes key absent — skipped" @() $true
} else {
    $procs = @($data.Processes)

    # T103 — source='wmi_remote' on all records
    $t103d = @()
    foreach ($p in $procs) {
        if ($p.source -ne 'wmi_remote') {
            $t103d += "PID $($p.ProcessId) '$($p.Name)' has source='$($p.source)'"
        }
    }
    if ($t103d.Count -eq 0) {
        Add-R "T103" $true "Processes source: all $($procs.Count) records have source='wmi_remote'"
    } else {
        Add-R "T103" $false "Processes source: $($t103d.Count) records with wrong source" ($t103d | Select-Object -First 25)
    }

    # T104 — SHA256Error='WMI_REMOTE_UNSUPPORTED' on all records
    $t104d = @()
    foreach ($p in $procs) {
        if ($p.SHA256Error -ne 'WMI_REMOTE_UNSUPPORTED') {
            $t104d += "PID $($p.ProcessId) '$($p.Name)' SHA256Error='$($p.SHA256Error)'"
        }
    }
    if ($t104d.Count -eq 0) {
        Add-R "T104" $true "Processes SHA256Error: all $($procs.Count) records have SHA256Error='WMI_REMOTE_UNSUPPORTED'"
    } else {
        Add-R "T104" $false "Processes SHA256Error: $($t104d.Count) records with wrong value" ($t104d | Select-Object -First 25)
    }

    # T105 — IntegrityLevelError='WMI_REMOTE_UNSUPPORTED' on all records
    $t105d = @()
    foreach ($p in $procs) {
        if ($p.IntegrityLevelError -ne 'WMI_REMOTE_UNSUPPORTED') {
            $t105d += "PID $($p.ProcessId) '$($p.Name)' IntegrityLevelError='$($p.IntegrityLevelError)'"
        }
    }
    if ($t105d.Count -eq 0) {
        Add-R "T105" $true "Processes IntegrityLevelError: all $($procs.Count) records have IntegrityLevelError='WMI_REMOTE_UNSUPPORTED'"
    } else {
        Add-R "T105" $false "Processes IntegrityLevelError: $($t105d.Count) records with wrong value" ($t105d | Select-Object -First 25)
    }

    # T106 — Signature.Status='WMI_REMOTE_UNSUPPORTED' on all records
    $t106d = @()
    foreach ($p in $procs) {
        if ($null -eq $p.PSObject.Properties['Signature'] -or $null -eq $p.Signature) {
            $t106d += "PID $($p.ProcessId) '$($p.Name)' Signature block missing"
        } elseif ($p.Signature.Status -ne 'WMI_REMOTE_UNSUPPORTED') {
            $t106d += "PID $($p.ProcessId) '$($p.Name)' Signature.Status='$($p.Signature.Status)'"
        }
    }
    if ($t106d.Count -eq 0) {
        Add-R "T106" $true "Processes Signature.Status: all $($procs.Count) records have Signature.Status='WMI_REMOTE_UNSUPPORTED'"
    } else {
        Add-R "T106" $false "Processes Signature.Status: $($t106d.Count) records with wrong value" ($t106d | Select-Object -First 25)
    }

    # T107 — SHA256 and IntegrityLevel are null (hashes/IL not collected via WMI)
    $t107d = @()
    foreach ($p in $procs) {
        if ($null -ne $p.SHA256) {
            $t107d += "PID $($p.ProcessId) '$($p.Name)' SHA256='$($p.SHA256)' expected null for WMI collection"
        }
        if ($null -ne $p.IntegrityLevel) {
            $t107d += "PID $($p.ProcessId) '$($p.Name)' IntegrityLevel='$($p.IntegrityLevel)' expected null for WMI collection"
        }
    }
    if ($t107d.Count -eq 0) {
        Add-R "T107" $true "Processes SHA256+IntegrityLevel: all $($procs.Count) records have null values (correct for WMI path)"
    } else {
        Add-R "T107" $false "Processes SHA256/IntegrityLevel: $($t107d.Count) records with unexpected non-null values" ($t107d | Select-Object -First 25)
    }

    # T108 — Required fields present on all records
    $t108d = @()
    $reqProcFields = @('ProcessId','Name','ParentProcessId','CreationDateUTC','source','SHA256Error','IntegrityLevelError','Signature')
    foreach ($p in $procs) {
        foreach ($f in $reqProcFields) {
            if ($null -eq $p.PSObject.Properties[$f]) {
                $t108d += "PID $($p.ProcessId) '$($p.Name)' missing field: $f"
            }
        }
    }
    if ($t108d.Count -eq 0) {
        Add-R "T108" $true "Processes required fields: all $($procs.Count) records have required fields present"
    } else {
        Add-R "T108" $false "Processes required fields: $($t108d.Count) violations" ($t108d | Select-Object -First 25)
    }

    # T109 — Process count > 0
    if ($procs.Count -gt 0) {
        Add-R "T109" $true "Processes count: $($procs.Count) records collected via WMI (count > 0)"
    } else {
        Add-R "T109" $false "Processes count is 0 — WMI process enumeration produced no records"
    }
}

# ---------------------------------------------------------------
# DLLs section
# ---------------------------------------------------------------
if ($null -eq $data.PSObject.Properties['DLLs']) {
    Add-R "T110" $false "DLLs key absent from JSON — expected empty array for WMI fallback"
    Add-R "T111" $true  "DLLs key absent — T111 skipped" @() $true
} else {
    # T110 — DLLs is an empty array (not null)
    $dlls = @($data.DLLs)
    if ($null -eq $data.DLLs) {
        Add-R "T110" $false "DLLs is null — expected empty array [] for WMI fallback"
    } elseif ($dlls.Count -gt 0) {
        Add-R "T110" $false "DLLs has $($dlls.Count) records — expected empty array for WMI fallback (DLL collection requires WinRM)"
    } else {
        Add-R "T110" $true  "DLLs: empty array [] as expected for WMI fallback (DLL collection requires WinRM)"
    }

    # T111 — DLLs_source='wmi_unsupported'
    if ($null -eq $mf.PSObject.Properties['DLLs_source']) {
        Add-R "T111" $false "manifest.DLLs_source field missing — expected 'wmi_unsupported'"
    } elseif ($mf.DLLs_source -ne 'wmi_unsupported') {
        Add-R "T111" $false "manifest.DLLs_source='$($mf.DLLs_source)' expected 'wmi_unsupported'" @("Actual: $($mf.DLLs_source)")
    } else {
        Add-R "T111" $true  "manifest.DLLs_source='wmi_unsupported' (correct)"
    }
}

# ---------------------------------------------------------------
# Network section
# ---------------------------------------------------------------
if ($null -eq $data.PSObject.Properties['Network'] -or $null -eq $data.Network) {
    Add-R "T112" $true "Network key absent in JSON — Network tests skipped" @() $true
    Add-R "T113" $true "Network key absent — skipped" @() $true
    Add-R "T114" $true "Network key absent — skipped" @() $true
    Add-R "T115" $true "Network key absent — skipped" @() $true
} else {
    $net = $data.Network

    # T112 — tcp sub-key present (Win8+/2012+ WMI code path may populate it)
    # On WMI fallback, tcp may or may not be present depending on OS version.
    # We verify: if tcp is present it is an array (not null). Missing is also acceptable.
    if ($null -eq $net.PSObject.Properties['tcp']) {
        Add-R "T112" $true "Network.tcp sub-key absent (acceptable on pre-Win8/2012 targets via WMI)" @() $true
    } elseif ($null -eq $net.tcp) {
        Add-R "T112" $false "Network.tcp is null — expected either an array or absent for WMI fallback"
    } else {
        $tcpCount = @($net.tcp).Count
        Add-R "T112" $true "Network.tcp present with $tcpCount records (WMI network collection succeeded)"
    }

    # T113 — dns is empty array (DNS cache unavailable via WMI remote)
    if ($null -eq $net.PSObject.Properties['dns']) {
        Add-R "T113" $false "Network.dns sub-key absent — expected empty array [] for WMI fallback"
    } elseif ($null -eq $net.dns) {
        Add-R "T113" $false "Network.dns is null — expected empty array [] for WMI fallback"
    } else {
        $dnsRecords = @($net.dns)
        if ($dnsRecords.Count -gt 0) {
            Add-R "T113" $false "Network.dns has $($dnsRecords.Count) records — expected empty array (DNS cache unavailable via WMI remote)"
        } else {
            Add-R "T113" $true  "Network.dns is empty array [] as expected (DNS cache unavailable via WMI remote)"
        }
    }

    # T114 — Network_source.dns='wmi_remote_unavailable'
    if ($null -eq $mf.PSObject.Properties['Network_source'] -or $null -eq $mf.Network_source) {
        Add-R "T114" $false "manifest.Network_source object missing — cannot verify dns source"
    } elseif ($null -eq $mf.Network_source.PSObject.Properties['dns']) {
        Add-R "T114" $false "manifest.Network_source.dns field missing — expected 'wmi_remote_unavailable'"
    } elseif ($mf.Network_source.dns -ne 'wmi_remote_unavailable') {
        Add-R "T114" $false "manifest.Network_source.dns='$($mf.Network_source.dns)' expected 'wmi_remote_unavailable'" @("Actual: $($mf.Network_source.dns)")
    } else {
        Add-R "T114" $true  "manifest.Network_source.dns='wmi_remote_unavailable' (correct)"
    }

    # T115 — tcp records have required fields (only if tcp is present and non-empty)
    if ($null -ne $net.PSObject.Properties['tcp'] -and $null -ne $net.tcp) {
        $tcpRecs = @($net.tcp)
        if ($tcpRecs.Count -eq 0) {
            Add-R "T115" $true "Network.tcp schema: empty array — no records to validate" @() $true
        } else {
            $t115d = @()
            $reqTcpFields = @('OwningProcess','LocalAddress','LocalPort','RemoteAddress','RemotePort','State','Protocol')
            foreach ($rec in $tcpRecs) {
                foreach ($f in $reqTcpFields) {
                    if ($null -eq $rec.PSObject.Properties[$f]) {
                        $t115d += "TCP record PID=$($rec.OwningProcess) LocalPort=$($rec.LocalPort) missing field: $f"
                    }
                }
            }
            if ($t115d.Count -eq 0) {
                Add-R "T115" $true "Network.tcp schema: all $($tcpRecs.Count) records have required fields"
            } else {
                Add-R "T115" $false "Network.tcp schema: $($t115d.Count) field violations" ($t115d | Select-Object -First 25)
            }
        }
    } else {
        Add-R "T115" $true "Network.tcp absent — schema validation skipped" @() $true
    }
}

# ---------------------------------------------------------------
# Users section
# ---------------------------------------------------------------
if ($null -eq $data.PSObject.Properties['Users'] -or $null -eq $data.Users) {
    Add-R "T116" $true "Users key absent in JSON — Users tests skipped" @() $true
    Add-R "T117" $true "Users key absent — skipped" @() $true
    Add-R "T118" $true "Users key absent — skipped" @() $true
    Add-R "T119" $true "Users key absent — skipped" @() $true
} else {
    $usersSection = $data.Users

    # T116 — Users present and non-empty
    if ($usersSection -isnot [System.Management.Automation.PSCustomObject] -and
        $usersSection -isnot [hashtable]) {
        Add-R "T116" $false "Users section is not an object (type: $($usersSection.GetType().Name))"
    } else {
        $userArr = @()
        if ($null -ne $usersSection.PSObject.Properties['users'] -and $null -ne $usersSection.users) {
            $userArr = @($usersSection.users)
        }
        if ($userArr.Count -eq 0) {
            Add-R "T116" $false "Users.users array is empty — WMI should enumerate at least local accounts"
        } else {
            Add-R "T116" $true "Users present: $($userArr.Count) user record(s) collected via WMI"
        }
    }

    # T117 — Users_source starts with 'wmi_remote'
    if ($null -eq $mf.PSObject.Properties['Users_source']) {
        Add-R "T117" $false "manifest.Users_source field missing"
    } elseif ($mf.Users_source -notlike 'wmi_remote*') {
        Add-R "T117" $false "manifest.Users_source='$($mf.Users_source)' expected to start with 'wmi_remote'" @("Actual: $($mf.Users_source)")
    } else {
        Add-R "T117" $true "manifest.Users_source='$($mf.Users_source)' (starts with 'wmi_remote' — correct)"
    }

    # T118 — Required top-level fields on Users section
    $t118d = @()
    $reqUsersTopFields = @('users','domain_accounts','is_domain_controller','machine_name','machine_sid')
    foreach ($f in $reqUsersTopFields) {
        if ($null -eq $usersSection.PSObject.Properties[$f]) {
            $t118d += "Users missing top-level field: $f"
        }
    }
    if ($t118d.Count -eq 0) {
        Add-R "T118" $true "Users top-level fields present: $($reqUsersTopFields -join ', ')"
    } else {
        Add-R "T118" $false "Users top-level fields missing ($($t118d.Count))" $t118d
    }

    # T119 — Each user record has required fields
    $userArr119 = @()
    if ($null -ne $usersSection.PSObject.Properties['users'] -and $null -ne $usersSection.users) {
        $userArr119 = @($usersSection.users)
    }
    if ($userArr119.Count -eq 0) {
        Add-R "T119" $true "Users.users empty — per-record field validation skipped" @() $true
    } else {
        $t119d = @()
        $reqUserFields = @('SID','Username','AccountType','ProfilePath','GroupMemberships','LastLogonUTC','HasLocalAccount')
        foreach ($u in $userArr119) {
            $uname = if ($null -ne $u.PSObject.Properties['Username']) { $u.Username } else { '(unknown)' }
            foreach ($f in $reqUserFields) {
                if ($null -eq $u.PSObject.Properties[$f]) {
                    $t119d += "User '$uname' missing field: $f"
                }
            }
            # SID format sanity
            if ($null -ne $u.PSObject.Properties['SID'] -and
                -not [string]::IsNullOrEmpty($u.SID) -and
                $u.SID -notmatch '^S-1-') {
                $t119d += "User '$uname' SID='$($u.SID)' does not match S-1- prefix"
            }
        }
        if ($t119d.Count -eq 0) {
            Add-R "T119" $true "Users per-record fields: all $($userArr119.Count) records have required fields and valid SIDs"
        } else {
            Add-R "T119" $false "Users per-record fields: $($t119d.Count) violations" ($t119d | Select-Object -First 25)
        }
    }
}

# ---------------------------------------------------------------
# T120 — Cross-check: Network.tcp OwningProcess PIDs exist in Processes
# Only run if both sections are present and non-empty.
# ---------------------------------------------------------------
$canCrossCheck = $true
if ($null -eq $data.PSObject.Properties['Network'] -or $null -eq $data.Network) { $canCrossCheck = $false }
if ($null -eq $data.PSObject.Properties['Processes'] -or $null -eq $data.Processes) { $canCrossCheck = $false }

if (-not $canCrossCheck) {
    Add-R "T120" $true "Cross-check Network/Processes skipped (one or both sections absent)" @() $true
} else {
    $procPids = @{}
    foreach ($p in @($data.Processes)) {
        if ($null -ne $p.PSObject.Properties['ProcessId']) {
            $procPids[[string]$p.ProcessId] = $p.Name
        }
    }

    $t120d = @()
    if ($null -ne $data.Network.PSObject.Properties['tcp'] -and $null -ne $data.Network.tcp) {
        $seenMissing = @{}
        foreach ($rec in @($data.Network.tcp)) {
            $oPid = [string]$rec.OwningProcess
            # PID 0 (System Idle) is always valid; skip it
            if ($oPid -eq '0') { continue }
            # All other PIDs must appear in the Processes array
            if (-not $procPids.ContainsKey($oPid) -and -not $seenMissing.ContainsKey($oPid)) {
                $seenMissing[$oPid] = $true
                $pname = if ($null -ne $rec.PSObject.Properties['OwningProcessName']) { $rec.OwningProcessName } else { '?' }
                $t120d += "TCP OwningProcess PID=$oPid ('$pname') not found in Processes array"
            }
        }
    }

    if ($t120d.Count -eq 0) {
        Add-R "T120" $true "Cross-check: all Network.tcp OwningProcess PIDs (excluding PID 0) found in Processes array"
    } else {
        Add-R "T120" $false "Cross-check: $($t120d.Count) TCP OwningProcess PIDs missing from Processes" ($t120d | Select-Object -First 25)
    }
}

# ---------------------------------------------------------------
return @{
    Passed = $script:passResults
    Failed = $script:failResults
    Info   = $script:infoResults
}
