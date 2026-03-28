#Requires -Version 5.1
# QuickAiR -- T04_Network.ps1
#
# T57  - Network key presence (data.Network exists with tcp/udp/dns/adapters sub-keys)
# T58  - TCP schema: all required fields present on every record
# T59  - UDP schema: all required fields present, Protocol=UDP, IsListener=true, no State drift
# T60  - DNS schema: all required fields present on every cache entry
# T61  - Adapter schema: all required fields present on every adapter
# T62  - TCP numeric field types (LocalPort, RemotePort, OwningProcess castable to int)
# T63  - UDP numeric field types (LocalPort, OwningProcess castable to int)
# T64  - TCP IsListener is Boolean, matches State (LISTEN <-> IsListener=true)
# T65  - TCP CreationTime UTC format (ends with Z when non-null)
# T66  - TCP IsPrivateIP is Boolean on all records
# T67  - DNS Type field is a string (not int) on all records
# T68  - DNS TTL is numeric on all records
# T69  - Source fields valid values (source.network, source.udp, source.dns)
# T70  - TCP OwningProcess PIDs exist in Processes (cross-reference)
# T71  - DnsMatch populated from DNS cache: TCP records whose RemoteAddress is in dns.Data must have DnsMatch set
# T72  - collection_errors for Network artifact have artifact+message fields
# T73  - No GetHostEntry call in module source (cache-only reverse DNS enforcement)
# T74  - No #Requires line in module source (PS 2.0 target-side compat)
# T75  - No Set-StrictMode -Off in module source (module must not suppress strict mode globally)
#
# Inputs  : -JsonPath -HtmlPath
# Output  : @{ Passed=@(); Failed=@(); Info=@() }
# PS compat: 5.1
# Version : 1.0

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

$jsonHostname   = $manifest.hostname
$localHostnames = @($env:COMPUTERNAME, 'localhost', '127.0.0.1')
$isLocalJson    = ($localHostnames -icontains $jsonHostname)

# ---------------------------------------------------------------
# T57 - Network key presence (data.Network with required sub-keys)
# ---------------------------------------------------------------
$netNode = $data.Network
if ($netNode -eq $null) {
    Add-R "T57" $true "Network key absent in JSON (SKIP - module may not have been enabled)" @() $true
    # Emit INFO skips for all remaining network tests and return early
    $skipIds = @('T58','T59','T60','T61','T62','T63','T64','T65','T66','T67','T68','T69','T70','T71','T72')
    foreach ($sid in $skipIds) {
        Add-R $sid $true "Network data absent (SKIP)" @() $true
    }
    # Static source checks still run below
} else {
    $netSubKeys = @('tcp','udp','dns','adapters')
    $missingSubKeys = @()
    foreach ($sk in $netSubKeys) {
        $val = $netNode.PSObject.Properties[$sk]
        if ($val -eq $null) { $missingSubKeys += $sk }
    }
    if ($missingSubKeys.Count -eq 0) {
        Add-R "T57" $true "Network key present with all sub-keys (tcp, udp, dns, adapters)"
    } else {
        Add-R "T57" $false "Network key present but missing sub-keys: $($missingSubKeys -join ', ')" $missingSubKeys
    }

    $tcpRecords  = @(if ($netNode.tcp)      { $netNode.tcp      } else { @() })
    $udpRecords  = @(if ($netNode.udp)      { $netNode.udp      } else { @() })
    $dnsRecords  = @(if ($netNode.dns)      { $netNode.dns      } else { @() })
    $adpRecords  = @(if ($netNode.adapters) { $netNode.adapters } else { @() })

    # ---------------------------------------------------------------
    # T58 - TCP schema: required fields present on every record
    # ---------------------------------------------------------------
    $tcpRequiredFields = @(
        'Protocol','LocalAddress','LocalPort','RemoteAddress','RemotePort',
        'OwningProcess','State','InterfaceAlias','CreationTime',
        'IsListener','ReverseDns','DnsMatch','IsPrivateIP','OwningProcessName'
    )
    $t58Violations = @()
    foreach ($c in $tcpRecords) {
        if ($c -eq $null) { continue }
        $props = $c.PSObject.Properties.Name
        foreach ($f in $tcpRequiredFields) {
            if ($props -notcontains $f) {
                $t58Violations += "TCP Local=$($c.LocalAddress):$($c.LocalPort) missing field '$f'"
                if ($t58Violations.Count -ge 25) { break }
            }
        }
        if ($t58Violations.Count -ge 25) { break }
    }
    if ($t58Violations.Count -eq 0) {
        Add-R "T58" $true "TCP schema: all required fields present ($($tcpRecords.Count) records checked)"
    } else {
        Add-R "T58" $false "TCP schema: $($t58Violations.Count) field violations" $t58Violations
    }

    # ---------------------------------------------------------------
    # T59 - UDP schema: required fields present, Protocol=UDP, IsListener=true
    # ---------------------------------------------------------------
    $udpRequiredFields = @(
        'Protocol','LocalAddress','LocalPort','OwningProcess',
        'InterfaceAlias','IsListener','OwningProcessName'
    )
    $t59Violations = @()
    foreach ($u in $udpRecords) {
        if ($u -eq $null) { continue }
        $props = $u.PSObject.Properties.Name
        foreach ($f in $udpRequiredFields) {
            if ($props -notcontains $f) {
                $t59Violations += "UDP Local=$($u.LocalAddress):$($u.LocalPort) missing field '$f'"
                if ($t59Violations.Count -ge 25) { break }
            }
        }
        if ($u.Protocol -ne $null -and $u.Protocol -ne 'UDP') {
            $t59Violations += "UDP record has Protocol='$($u.Protocol)' (expected UDP) at $($u.LocalAddress):$($u.LocalPort)"
        }
        if ($u.IsListener -ne $null -and $u.IsListener -ne $true) {
            $t59Violations += "UDP record has IsListener=$($u.IsListener) (expected true) at $($u.LocalAddress):$($u.LocalPort)"
        }
        if ($t59Violations.Count -ge 25) { break }
    }
    if ($t59Violations.Count -eq 0) {
        Add-R "T59" $true "UDP schema: all required fields present, Protocol=UDP, IsListener=true ($($udpRecords.Count) records)"
    } else {
        Add-R "T59" $false "UDP schema: $($t59Violations.Count) violations" $t59Violations
    }

    # ---------------------------------------------------------------
    # T60 - DNS schema: required fields on every cache entry
    # ---------------------------------------------------------------
    $dnsRequiredFields = @('Entry','Name','Data','Type','TTL')
    $t60Violations = @()
    foreach ($d in $dnsRecords) {
        if ($d -eq $null) { continue }
        $props = $d.PSObject.Properties.Name
        foreach ($f in $dnsRequiredFields) {
            if ($props -notcontains $f) {
                $t60Violations += "DNS Entry='$($d.Entry)' missing field '$f'"
                if ($t60Violations.Count -ge 25) { break }
            }
        }
        if ($t60Violations.Count -ge 25) { break }
    }
    if ($t60Violations.Count -eq 0) {
        Add-R "T60" $true "DNS schema: all required fields present ($($dnsRecords.Count) cache entries checked)"
    } else {
        Add-R "T60" $false "DNS schema: $($t60Violations.Count) field violations" $t60Violations
    }

    # ---------------------------------------------------------------
    # T61 - Adapter schema: required fields on every adapter
    # ---------------------------------------------------------------
    $adpRequiredFields = @('AdapterName','InterfaceAlias','IPAddresses','MACAddress','DefaultGateway','DNSServers','DHCPEnabled')
    $t61Violations = @()
    foreach ($a in $adpRecords) {
        if ($a -eq $null) { continue }
        $props = $a.PSObject.Properties.Name
        foreach ($f in $adpRequiredFields) {
            if ($props -notcontains $f) {
                $t61Violations += "Adapter '$($a.AdapterName)' missing field '$f'"
                if ($t61Violations.Count -ge 25) { break }
            }
        }
        if ($t61Violations.Count -ge 25) { break }
    }
    if ($t61Violations.Count -eq 0) {
        Add-R "T61" $true "Adapter schema: all required fields present ($($adpRecords.Count) adapters checked)"
    } else {
        Add-R "T61" $false "Adapter schema: $($t61Violations.Count) field violations" $t61Violations
    }

    # ---------------------------------------------------------------
    # T62 - TCP numeric field types (LocalPort, RemotePort, OwningProcess)
    # ---------------------------------------------------------------
    $t62Violations = @()
    foreach ($c in $tcpRecords) {
        if ($c -eq $null) { continue }
        foreach ($numField in @('LocalPort','RemotePort','OwningProcess')) {
            $val = $c.$numField
            if ($val -ne $null) {
                try { $null = [int]$val }
                catch { $t62Violations += "TCP Local=$($c.LocalAddress):$($c.LocalPort) $numField='$val' not castable to int" }
            } else {
                $t62Violations += "TCP Local=$($c.LocalAddress):$($c.LocalPort) $numField is null"
            }
        }
        if ($t62Violations.Count -ge 25) { break }
    }
    if ($t62Violations.Count -eq 0) {
        Add-R "T62" $true "TCP numeric fields valid ($($tcpRecords.Count) records, LocalPort/RemotePort/OwningProcess all int-castable)"
    } else {
        Add-R "T62" $false "TCP numeric fields: $($t62Violations.Count) violations" $t62Violations
    }

    # ---------------------------------------------------------------
    # T63 - UDP numeric field types (LocalPort, OwningProcess)
    # ---------------------------------------------------------------
    $t63Violations = @()
    foreach ($u in $udpRecords) {
        if ($u -eq $null) { continue }
        foreach ($numField in @('LocalPort','OwningProcess')) {
            $val = $u.$numField
            if ($val -ne $null) {
                try { $null = [int]$val }
                catch { $t63Violations += "UDP Local=$($u.LocalAddress):$($u.LocalPort) $numField='$val' not castable to int" }
            } else {
                $t63Violations += "UDP Local=$($u.LocalAddress):$($u.LocalPort) $numField is null"
            }
        }
        if ($t63Violations.Count -ge 25) { break }
    }
    if ($t63Violations.Count -eq 0) {
        Add-R "T63" $true "UDP numeric fields valid ($($udpRecords.Count) records, LocalPort/OwningProcess all int-castable)"
    } else {
        Add-R "T63" $false "UDP numeric fields: $($t63Violations.Count) violations" $t63Violations
    }

    # ---------------------------------------------------------------
    # T64 - TCP IsListener is Boolean, coherent with State=LISTEN
    # ---------------------------------------------------------------
    $t64Violations = @()
    foreach ($c in $tcpRecords) {
        if ($c -eq $null) { continue }
        $il = $c.IsListener
        # Must be boolean type
        if ($il -ne $null) {
            $t = $il.GetType().Name
            if ($t -ne 'Boolean') {
                $t64Violations += "TCP Local=$($c.LocalAddress):$($c.LocalPort) IsListener type='$t' (expected Boolean)"
            }
        }
        # IsListener=true must correlate with State containing LISTEN
        $st = "$($c.State)"
        if ($il -eq $true -and $st -notmatch 'LISTEN') {
            $t64Violations += "TCP Local=$($c.LocalAddress):$($c.LocalPort) IsListener=true but State='$st' (expected LISTEN)"
        }
        if ($il -eq $false -and $st -match '^LISTEN(ING)?$') {
            $t64Violations += "TCP Local=$($c.LocalAddress):$($c.LocalPort) IsListener=false but State='$st'"
        }
        if ($t64Violations.Count -ge 25) { break }
    }
    if ($t64Violations.Count -eq 0) {
        Add-R "T64" $true "TCP IsListener is Boolean and coherent with State on all $($tcpRecords.Count) records"
    } else {
        Add-R "T64" $false "TCP IsListener/State coherence: $($t64Violations.Count) violations" $t64Violations
    }

    # ---------------------------------------------------------------
    # T65 - TCP CreationTime UTC format (ends with Z when non-null)
    # ---------------------------------------------------------------
    $t65Violations = @()
    foreach ($c in $tcpRecords) {
        if ($c -eq $null) { continue }
        $ct = $c.CreationTime
        if ($ct -ne $null -and $ct -ne '') {
            if ($ct -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') {
                $t65Violations += "TCP Local=$($c.LocalAddress):$($c.LocalPort) CreationTime='$ct' not UTC ISO 8601"
            }
        }
        if ($t65Violations.Count -ge 25) { break }
    }
    if ($t65Violations.Count -eq 0) {
        Add-R "T65" $true "TCP CreationTime UTC format valid on all non-null values ($($tcpRecords.Count) records checked)"
    } else {
        Add-R "T65" $false "TCP CreationTime format: $($t65Violations.Count) violations" $t65Violations
    }

    # ---------------------------------------------------------------
    # T66 - TCP IsPrivateIP is Boolean on all records
    # ---------------------------------------------------------------
    $t66Violations = @()
    foreach ($c in $tcpRecords) {
        if ($c -eq $null) { continue }
        $ip = $c.IsPrivateIP
        if ($ip -eq $null) {
            $t66Violations += "TCP Local=$($c.LocalAddress):$($c.LocalPort) IsPrivateIP is null"
        } else {
            $t = $ip.GetType().Name
            if ($t -ne 'Boolean') {
                $t66Violations += "TCP Local=$($c.LocalAddress):$($c.LocalPort) IsPrivateIP type='$t' (expected Boolean)"
            }
        }
        if ($t66Violations.Count -ge 25) { break }
    }
    if ($t66Violations.Count -eq 0) {
        Add-R "T66" $true "TCP IsPrivateIP is Boolean on all $($tcpRecords.Count) records"
    } else {
        Add-R "T66" $false "TCP IsPrivateIP type: $($t66Violations.Count) violations" $t66Violations
    }

    # ---------------------------------------------------------------
    # T67 - DNS Type field is a string (not int) on all records
    # ---------------------------------------------------------------
    $t67Violations = @()
    foreach ($d in $dnsRecords) {
        if ($d -eq $null) { continue }
        $typeVal = $d.Type
        if ($typeVal -ne $null) {
            $t = $typeVal.GetType().Name
            if ($t -ne 'String') {
                $t67Violations += "DNS Entry='$($d.Entry)' Type='$typeVal' has type '$t' (expected String)"
                if ($t67Violations.Count -ge 25) { break }
            }
        }
    }
    if ($t67Violations.Count -eq 0) {
        Add-R "T67" $true "DNS Type field is String on all $($dnsRecords.Count) cache entries (ConvertTo-DnsTypeName applied)"
    } else {
        Add-R "T67" $false "DNS Type field not String: $($t67Violations.Count) violations" $t67Violations
    }

    # ---------------------------------------------------------------
    # T68 - DNS TTL is numeric on all records
    # ---------------------------------------------------------------
    $t68Violations = @()
    foreach ($d in $dnsRecords) {
        if ($d -eq $null) { continue }
        $ttl = $d.TTL
        if ($ttl -ne $null) {
            try { $null = [int]$ttl }
            catch { $t68Violations += "DNS Entry='$($d.Entry)' TTL='$ttl' not castable to int" }
        }
        if ($t68Violations.Count -ge 25) { break }
    }
    if ($t68Violations.Count -eq 0) {
        Add-R "T68" $true "DNS TTL is numeric on all $($dnsRecords.Count) cache entries"
    } else {
        Add-R "T68" $false "DNS TTL non-numeric: $($t68Violations.Count) violations" $t68Violations
    }

    # ---------------------------------------------------------------
    # T69 - Source fields valid values
    # ---------------------------------------------------------------
    $validNetSources = @('cim','netstat_fallback','netstat_legacy','unknown')
    $validDnsSources = @('cim','ipconfig_fallback','ipconfig_legacy','unknown')

    $t69Violations = @()
    $srcNode = $data.manifest.PSObject.Properties['network_source']
    # Source lives in the result's source property; access via manifest or check raw JSON
    # The collector stores source in the top-level return; TestSuite merges it into manifest
    # Try both locations: manifest.network_source and data.Network_source
    $netSrc = $null; $udpSrc = $null; $dnsSrc = $null
    if ($manifest.PSObject.Properties['network_source']) { $netSrc = $manifest.network_source }
    if ($manifest.PSObject.Properties['udp_source'])     { $udpSrc = $manifest.udp_source }
    if ($manifest.PSObject.Properties['dns_source'])     { $dnsSrc = $manifest.dns_source }

    if ($netSrc -ne $null) {
        if ($validNetSources -notcontains $netSrc) {
            $t69Violations += "source.network='$netSrc' not a valid value (expected: $($validNetSources -join ', '))"
        }
    }
    if ($udpSrc -ne $null) {
        if ($validNetSources -notcontains $udpSrc) {
            $t69Violations += "source.udp='$udpSrc' not a valid value"
        }
    }
    if ($dnsSrc -ne $null) {
        if ($validDnsSources -notcontains $dnsSrc) {
            $t69Violations += "source.dns='$dnsSrc' not a valid value (expected: $($validDnsSources -join ', '))"
        }
    }

    if ($netSrc -eq $null -and $udpSrc -eq $null -and $dnsSrc -eq $null) {
        Add-R "T69" $true "Network source fields not present in manifest (collector may store separately - SKIP)" @() $true
    } elseif ($t69Violations.Count -eq 0) {
        Add-R "T69" $true "Network source fields valid (network=$netSrc udp=$udpSrc dns=$dnsSrc)"
    } else {
        Add-R "T69" $false "Network source fields: $($t69Violations.Count) invalid values" $t69Violations
    }

    # ---------------------------------------------------------------
    # T70 - TCP OwningProcess PIDs exist in Processes (cross-reference)
    # ---------------------------------------------------------------
    if (-not $isLocalJson) {
        Add-R "T70" $true "TCP/Process cross-reference (SKIP - remote host $jsonHostname)" @() $true
    } else {
        $procArr = @($data.Processes)
        $pidSet = @{}
        foreach ($p in $procArr) {
            if ($p -ne $null -and $p.ProcessId -ne $null) { $pidSet[[int]$p.ProcessId] = $true }
        }

        $t70Missing = @()
        foreach ($c in $tcpRecords) {
            if ($c -eq $null) { continue }
            $pid_ = $c.OwningProcess
            if ($pid_ -ne $null) {
                $pidInt = [int]$pid_
                # PID 0 and PID 4 (Idle/System) are valid but may not appear in Processes
                if ($pidInt -gt 4 -and -not $pidSet.ContainsKey($pidInt)) {
                    $t70Missing += "PID=$pidInt Local=$($c.LocalAddress):$($c.LocalPort)"
                }
            }
            if ($t70Missing.Count -ge 25) { break }
        }
        if ($t70Missing.Count -eq 0) {
            Add-R "T70" $true "TCP/Process cross-reference OK ($($tcpRecords.Count) TCP records, all PIDs>4 found in Processes)"
        } else {
            Add-R "T70" $false "TCP/Process cross-reference: $($t70Missing.Count) PIDs missing from Processes" $t70Missing
        }
    }

    # ---------------------------------------------------------------
    # T71 - DnsMatch: TCP records whose RemoteAddress appears in dns.Data must have DnsMatch set
    # ---------------------------------------------------------------
    $dnsDataSet = @{}
    foreach ($d in $dnsRecords) {
        if ($d.Data) { $dnsDataSet[$d.Data] = $true }
    }

    $t71Missing = @()
    foreach ($c in $tcpRecords) {
        if ($c -eq $null) { continue }
        $ra = $c.RemoteAddress
        if ($ra -and $dnsDataSet.ContainsKey($ra)) {
            if (-not $c.DnsMatch) {
                $t71Missing += "Local=$($c.LocalAddress):$($c.LocalPort) Remote=$ra has DNS entry but DnsMatch is null"
            }
        }
        if ($t71Missing.Count -ge 25) { break }
    }
    if ($t71Missing.Count -eq 0) {
        Add-R "T71" $true "DNS enrichment: all TCP records with RemoteAddress in dns.Data have DnsMatch set ($($dnsDataSet.Count) DNS IPs checked)"
    } else {
        Add-R "T71" $false "DNS enrichment: $($t71Missing.Count) TCP records missing DnsMatch where DNS entry exists" $t71Missing
    }

    # ---------------------------------------------------------------
    # T72 - collection_errors for Network artifact have artifact+message
    # ---------------------------------------------------------------
    $collErrors = @()
    if ($manifest.collection_errors) { $collErrors = @($manifest.collection_errors) }
    $netErrors = @($collErrors | Where-Object { $_.artifact -match '^network|^dns_cache|^process_names' })
    $t72Violations = @()
    foreach ($ce in $netErrors) {
        if ($ce.artifact -eq $null -or $ce.artifact -eq '') {
            $t72Violations += "collection_error entry missing artifact field"
        }
        if ($ce.message -eq $null -or $ce.message -eq '') {
            $t72Violations += "collection_error missing message field; artifact=$($ce.artifact)"
        }
        if ($t72Violations.Count -ge 25) { break }
    }
    if ($t72Violations.Count -eq 0) {
        $isInfo = ($netErrors.Count -eq 0)
        Add-R "T72" $true "Network collection_errors ($($netErrors.Count) entries) - all have artifact+message" @() $isInfo
    } else {
        Add-R "T72" $false "Network collection_errors malformed: $($t72Violations.Count) violations" $t72Violations
    }
}

# ---------------------------------------------------------------
# T73 - No GetHostEntry call in module source (cache-only reverse DNS)
# ---------------------------------------------------------------
$modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Modules\Collectors\Network.psm1'
if (-not (Test-Path $modulePath)) {
    Add-R "T73" $true "Network.psm1 not found at expected path - cannot check for GetHostEntry (SKIP)" @() $true
} else {
    $moduleSource = [System.IO.File]::ReadAllText($modulePath, [System.Text.Encoding]::UTF8)
    if ($moduleSource -match 'GetHostEntry') {
        Add-R "T73" $false "Network.psm1 contains GetHostEntry - live DNS lookup detected (must be cache-only)" @("Found: GetHostEntry in $modulePath")
    } else {
        Add-R "T73" $true "Network.psm1 has no GetHostEntry call - reverse DNS is cache-only as required"
    }
}

# ---------------------------------------------------------------
# T74 - No #Requires line in module source (PS 2.0 target-side compat)
# ---------------------------------------------------------------
if (-not (Test-Path $modulePath)) {
    Add-R "T74" $true "Network.psm1 not found - cannot check for #Requires (SKIP)" @() $true
} else {
    if (-not $moduleSource) {
        $moduleSource = [System.IO.File]::ReadAllText($modulePath, [System.Text.Encoding]::UTF8)
    }
    if ($moduleSource -match '(?m)^\s*#Requires') {
        Add-R "T74" $false "Network.psm1 contains a #Requires directive - breaks PS 2.0 target-side compatibility" @("Found: #Requires in $modulePath")
    } else {
        Add-R "T74" $true "Network.psm1 has no #Requires directive - PS 2.0 target-side compatible"
    }
}

# ---------------------------------------------------------------
# T75 - No Set-StrictMode -Off in module source
# ---------------------------------------------------------------
if (-not (Test-Path $modulePath)) {
    Add-R "T75" $true "Network.psm1 not found - cannot check for Set-StrictMode (SKIP)" @() $true
} else {
    if (-not $moduleSource) {
        $moduleSource = [System.IO.File]::ReadAllText($modulePath, [System.Text.Encoding]::UTF8)
    }
    if ($moduleSource -match '(?i)Set-StrictMode\s+-Off') {
        Add-R "T75" $false "Network.psm1 contains Set-StrictMode -Off - module must not suppress strict mode globally" @("Found: Set-StrictMode -Off in $modulePath")
    } else {
        Add-R "T75" $true "Network.psm1 has no Set-StrictMode -Off"
    }
}

return @{ Passed=$script:passResults; Failed=$script:failResults; Info=$script:infoResults }
