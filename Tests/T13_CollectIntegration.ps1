#Requires -Version 5.1
# =============================================
#   QuickAiR -- T13_CollectIntegration.ps1
#   T92 Localhost all-plugins collection
#   T93 Remote target .106 collection
#   T94 Multiple targets collection
#   T95 Bridge file injection (second batch)
#   T96 Output JSON Report.html contract
# =============================================
#   Inputs    : -JsonPath -HtmlPath (unused, for suite compat)
#   Output    : @{ Passed=@();
#                Failed=@(); Info=@() }
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
    if ($IsInfo)   { $script:infoResults += $obj }
    elseif ($Pass) { $script:passResults += $obj }
    else           { $script:failResults += $obj }
}

$scriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoDir      = Split-Path -Parent $scriptDir
$collectorPs1 = Join-Path $repoDir 'Collector.ps1'
$launcherDir  = Join-Path $repoDir 'Modules\Launcher'
$pipeListMod  = Join-Path $launcherDir 'PipeListener.psm1'

# Admin check -- integration tests require admin
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Temp output directory for collections
$tempOutput = Join-Path $env:TEMP "QuickAiRCollectTest_$([guid]::NewGuid().ToString('N').Substring(0,8))"

# Track T92 output for T96
$script:t92JsonPath = ''

# Helper: find newest JSON in output directory
function Find-NewestJson {
    param([string]$Dir)
    Get-ChildItem -Path $Dir -Recurse -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

# Helper: validate JSON has all required plugin sections
function Test-JsonSections {
    param($Data, [string]$Label)
    $fails = @()

    if ($null -eq $Data.manifest) { $fails += "${Label}: manifest missing" }
    else {
        if ([string]::IsNullOrEmpty($Data.manifest.hostname))           { $fails += "${Label}: manifest.hostname empty" }
        if ([string]::IsNullOrEmpty($Data.manifest.collection_time_utc)) { $fails += "${Label}: manifest.collection_time_utc empty" }
        if ([string]::IsNullOrEmpty($Data.manifest.sha256))             { $fails += "${Label}: manifest.sha256 empty" }
    }

    if ($null -eq $Data.Processes) { $fails += "${Label}: Processes section missing" }
    elseif (@($Data.Processes).Count -eq 0) { $fails += "${Label}: Processes section empty" }

    if ($null -eq $Data.Network) { $fails += "${Label}: Network section missing" }
    else {
        if ($null -eq $Data.Network.tcp -or @($Data.Network.tcp).Count -eq 0) { $fails += "${Label}: Network.tcp empty" }
        if ($null -eq $Data.Network.dns)  { $fails += "${Label}: Network.dns missing" }
    }

    if ($null -eq $Data.DLLs) { $fails += "${Label}: DLLs section missing" }
    elseif (@($Data.DLLs).Count -eq 0) { $fails += "${Label}: DLLs section empty" }

    if ($null -eq $Data.Users) { $fails += "${Label}: Users section missing" }

    return $fails
}

# ---------------------------------------------------------------
# T92 -- Localhost all-plugins collection (T-C7)
# Run Collector.ps1 -Targets @('localhost') -Quiet
# Verify: JSON exists, valid, all sections populated
# ---------------------------------------------------------------
if (-not $isAdmin) {
    Add-R "T92" $true "Localhost collection (SKIP - not admin)" @() $true
} else {
    try {
        New-Item -ItemType Directory -Path $tempOutput -Force | Out-Null
        $t92d = @()

        # Run collector against localhost
        & $collectorPs1 -Targets @('localhost') -OutputPath $tempOutput -Quiet -ErrorAction Stop

        # Find output JSON
        $jsonFile = Find-NewestJson -Dir $tempOutput
        if ($null -eq $jsonFile) {
            $t92d += "No JSON output found in $tempOutput"
        } else {
            $script:t92JsonPath = $jsonFile.FullName

            # Parse and validate
            $rawJson = [System.IO.File]::ReadAllText($jsonFile.FullName, [System.Text.Encoding]::UTF8)
            $data92  = $rawJson | ConvertFrom-Json

            $sectionFails = Test-JsonSections -Data $data92 -Label 'localhost'
            $t92d += $sectionFails

            # Verify hostname resolves to local machine
            $localNames = @($env:COMPUTERNAME, 'localhost', '127.0.0.1')
            if ($localNames -inotcontains $data92.manifest.hostname) {
                $t92d += "manifest.hostname '$($data92.manifest.hostname)' not in local names"
            }
        }

        if ($t92d.Count -eq 0) {
            Add-R "T92" $true "Localhost collection: JSON valid, all plugin sections populated"
        } else {
            Add-R "T92" $false "Localhost collection failures" $t92d
        }
    } catch {
        Add-R "T92" $false "T92 threw exception" @($_.Exception.Message)
    }
}

# ---------------------------------------------------------------
# T93 -- Remote target .106 collection (T-C8)
# Uses 192.168.1.106 (Server 2022) instead of .250 (not in lab)
# Skip if unreachable
# ---------------------------------------------------------------
$remote106 = '192.168.1.106'
$remote106Reachable = $false
try {
    $wsmanTest = Test-WSMan $remote106 -ErrorAction Stop
    if ($null -ne $wsmanTest) { $remote106Reachable = $true }
} catch { }

if (-not $isAdmin) {
    Add-R "T93" $true "Remote .106 collection (SKIP - not admin)" @() $true
} elseif (-not $remote106Reachable) {
    Add-R "T93" $true "Remote .106 collection (SKIP - $remote106 unreachable via WinRM)" @() $true
} else {
    try {
        $t93d = @()
        $out93 = Join-Path $tempOutput 'T93'
        New-Item -ItemType Directory -Path $out93 -Force | Out-Null

        # Use stored credentials for .106 (Server 2022: administrator / Aa123456)
        $secPass = ConvertTo-SecureString 'Aa123456' -AsPlainText -Force
        $cred106 = New-Object System.Management.Automation.PSCredential('administrator', $secPass)

        & $collectorPs1 -Targets @($remote106) -Credential $cred106 -OutputPath $out93 -Quiet -ErrorAction Stop

        $jsonFile93 = Find-NewestJson -Dir $out93
        if ($null -eq $jsonFile93) {
            $t93d += "No JSON output found for $remote106"
        } else {
            $rawJson93 = [System.IO.File]::ReadAllText($jsonFile93.FullName, [System.Text.Encoding]::UTF8)
            $data93    = $rawJson93 | ConvertFrom-Json

            $sectionFails = Test-JsonSections -Data $data93 -Label $remote106
            $t93d += $sectionFails
        }

        if ($t93d.Count -eq 0) {
            Add-R "T93" $true "Remote .106 collection: JSON valid, all plugin sections present"
        } else {
            Add-R "T93" $false "Remote .106 collection failures" $t93d
        }
    } catch {
        Add-R "T93" $false "T93 threw exception" @($_.Exception.Message)
    }
}

# ---------------------------------------------------------------
# T94 -- Multiple targets collection (T-C9)
# localhost + .106 + .100
# Verify: separate JSON per target
# ---------------------------------------------------------------
$remote100 = '192.168.1.100'
$remote100Reachable = $false
try {
    $wsmanTest100 = Test-WSMan $remote100 -ErrorAction Stop
    if ($null -ne $wsmanTest100) { $remote100Reachable = $true }
} catch { }

if (-not $isAdmin) {
    Add-R "T94" $true "Multi-target collection (SKIP - not admin)" @() $true
} elseif (-not $remote106Reachable -or -not $remote100Reachable) {
    $skip94 = @()
    if (-not $remote106Reachable) { $skip94 += $remote106 }
    if (-not $remote100Reachable) { $skip94 += $remote100 }
    Add-R "T94" $true "Multi-target collection (SKIP - unreachable: $($skip94 -join ', '))" @() $true
} else {
    try {
        $t94d = @()
        $out94 = Join-Path $tempOutput 'T94'
        New-Item -ItemType Directory -Path $out94 -Force | Out-Null

        $secPass = ConvertTo-SecureString 'Aa123456' -AsPlainText -Force
        $cred94  = New-Object System.Management.Automation.PSCredential('administrator', $secPass)

        & $collectorPs1 -Targets @('localhost', $remote106, $remote100) -Credential $cred94 -OutputPath $out94 -Quiet -ErrorAction Stop

        # Count distinct hostname subdirectories with JSON
        $jsonFiles94 = @(Get-ChildItem -Path $out94 -Recurse -Filter '*.json' -File -ErrorAction SilentlyContinue)
        $hostDirs94  = @($jsonFiles94 | ForEach-Object { Split-Path -Parent $_.FullName } | Sort-Object -Unique)

        if ($jsonFiles94.Count -lt 3) {
            $t94d += "Expected at least 3 JSON files, got $($jsonFiles94.Count)"
        }
        if ($hostDirs94.Count -lt 3) {
            $t94d += "Expected 3 hostname subdirectories, got $($hostDirs94.Count)"
        }

        # Validate each JSON
        foreach ($jf in $jsonFiles94) {
            $rawJ   = [System.IO.File]::ReadAllText($jf.FullName, [System.Text.Encoding]::UTF8)
            $dataJ  = $rawJ | ConvertFrom-Json
            $label  = if ($dataJ.manifest) { $dataJ.manifest.hostname } else { $jf.Name }
            $t94d  += Test-JsonSections -Data $dataJ -Label $label
        }

        if ($t94d.Count -eq 0) {
            Add-R "T94" $true "Multi-target collection: 3 targets collected, 3 JSONs valid"
        } else {
            Add-R "T94" $false "Multi-target collection failures" $t94d
        }
    } catch {
        Add-R "T94" $false "T94 threw exception" @($_.Exception.Message)
    }
}

# ---------------------------------------------------------------
# T95 -- Bridge file injection / second batch (T-C10)
# Tests PipeListener mid-flight injection mechanism:
# Send batch 1, wait, read; send batch 2, wait, read.
# ---------------------------------------------------------------
try {
    if (-not (Test-Path $pipeListMod)) { throw "PipeListener.psm1 not found: $pipeListMod" }
    Import-Module $pipeListMod -Force -ErrorAction Stop

    $bridgeTemp = Join-Path $env:TEMP "QuickAiRBridgeTest_$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $bridgeTemp -Force | Out-Null

    $listener = Start-BridgeListener -BridgeDir $bridgeTemp -IntervalMs 300
    $t95d = @()

    try {
        # First batch: 2 targets (simulates initial collection)
        $batch1 = @(
            [PSCustomObject]@{ hostname = 'host-batch1-a'; outputPath = '.\DFIROutput\'; plugins = @('Processes','Network') },
            [PSCustomObject]@{ hostname = 'host-batch1-b'; outputPath = '.\DFIROutput\'; plugins = @('Processes','Network') }
        )
        Send-JobBatch -BridgeDir $bridgeTemp -Jobs $batch1

        Start-Sleep -Milliseconds 1500
        $pending1 = @(Read-PendingJobs -Listener $listener)

        if ($pending1.Count -ne 2) {
            $t95d += "Batch 1: expected 2 pending jobs, got $($pending1.Count)"
        }

        # Second batch while "running": 1 more target
        $batch2 = @(
            [PSCustomObject]@{ hostname = 'host-batch2-a'; outputPath = '.\DFIROutput\'; plugins = @('Processes') }
        )
        Send-JobBatch -BridgeDir $bridgeTemp -Jobs $batch2

        Start-Sleep -Milliseconds 1500
        $pending2 = @(Read-PendingJobs -Listener $listener)

        if ($pending2.Count -ne 1) {
            $t95d += "Batch 2: expected 1 pending job, got $($pending2.Count)"
        }

        # No more pending
        $pending3 = @(Read-PendingJobs -Listener $listener)
        if ($pending3.Count -ne 0) {
            $t95d += "After both batches: expected 0 remaining, got $($pending3.Count)"
        }
    } finally {
        Stop-BridgeListener -Listener $listener
        Remove-Item $bridgeTemp -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($t95d.Count -eq 0) {
        Add-R "T95" $true "Bridge injection: batch 1 (2 jobs) picked up, batch 2 (1 job) picked up mid-flight, queue drained"
    } else {
        Add-R "T95" $false "Bridge injection failures" $t95d
    }
} catch {
    Add-R "T95" $false "T95 threw exception" @($_.Exception.Message)
}

# ---------------------------------------------------------------
# T96 -- Output JSON loads in Report.html contract (T-C11)
# Validates that collection output matches what Report.html expects:
# Processes array, Network.tcp, Network.dns, manifest fields
# ---------------------------------------------------------------
$jsonForT96 = $script:t92JsonPath
if ([string]::IsNullOrEmpty($jsonForT96)) {
    # Fallback: try latest JSON in DFIROutput
    $fallback = Find-NewestJson -Dir (Join-Path $repoDir 'DFIROutput')
    if ($null -ne $fallback) { $jsonForT96 = $fallback.FullName }
}

if ([string]::IsNullOrEmpty($jsonForT96) -or -not (Test-Path $jsonForT96)) {
    Add-R "T96" $true "Report.html contract (SKIP - no JSON available from T92 or DFIROutput)" @() $true
} else {
    try {
        $rawJson96 = [System.IO.File]::ReadAllText($jsonForT96, [System.Text.Encoding]::UTF8)
        $data96    = $rawJson96 | ConvertFrom-Json
        $t96d      = @()

        # Basic structure
        $t96d += Test-JsonSections -Data $data96 -Label 'Report contract'

        # Report.html-specific fields the JS expects
        # Processes: each must have ProcessId, Name, ParentProcessId
        $procs = @($data96.Processes)
        if ($procs.Count -gt 0) {
            $sample = $procs[0]
            $reqFields = @('ProcessId','Name','ParentProcessId','CreationDateUTC','ExecutablePath')
            foreach ($f in $reqFields) {
                if (-not $sample.PSObject.Properties[$f]) {
                    $t96d += "Process record missing required field: $f"
                }
            }
        }

        # Network.tcp: each must have OwningProcess, LocalAddress, LocalPort, State
        $tcp = @($data96.Network.tcp)
        if ($tcp.Count -gt 0) {
            $sampleTcp = $tcp[0]
            $reqTcp = @('OwningProcess','LocalAddress','LocalPort','State')
            foreach ($f in $reqTcp) {
                if (-not $sampleTcp.PSObject.Properties[$f]) {
                    $t96d += "TCP record missing required field: $f"
                }
            }
        }

        # Network.dns: each must have hostname (varies by source)
        $dns = @($data96.Network.dns)
        if ($dns.Count -gt 0) {
            $sampleDns = $dns[0]
            # DNS records have varying schemas depending on source; check at least one identifying field
            $hasDnsKey = $sampleDns.PSObject.Properties['Name'] -or $sampleDns.PSObject.Properties['hostname'] -or $sampleDns.PSObject.Properties['Entry']
            if (-not $hasDnsKey) {
                $t96d += "DNS record missing identifying field (Name, hostname, or Entry)"
            }
        }

        # Manifest: Report.html reads these specifically
        $reqManifest = @('hostname','collection_time_utc','collector_version','sha256',
                         'target_ps_version','target_os_caption','winrm_reachable')
        foreach ($f in $reqManifest) {
            if (-not $data96.manifest.PSObject.Properties[$f]) {
                $t96d += "manifest missing Report.html field: $f"
            }
        }

        # Valid UTF-8: if we got here without error, encoding is fine
        # JSON parse: if ConvertFrom-Json succeeded, it's valid

        if ($t96d.Count -eq 0) {
            Add-R "T96" $true "Report.html contract: JSON structure matches expected schema (Processes, Network.tcp, Network.dns, manifest fields)"
        } else {
            Add-R "T96" $false "Report.html contract failures" $t96d
        }
    } catch {
        Add-R "T96" $false "T96 threw exception" @($_.Exception.Message)
    }
}

# ---------------------------------------------------------------
# Cleanup temp directory
# ---------------------------------------------------------------
if (Test-Path $tempOutput) {
    Remove-Item $tempOutput -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------
return @{
    Passed = $script:passResults
    Failed = $script:failResults
    Info   = $script:infoResults
}
