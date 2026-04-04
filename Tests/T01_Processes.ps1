#Requires -Version 5.1
# QuickAiR -- T01_Processes.ps1 (v2.7 coverage)
#
# T1  - Process completeness (ground-truth vs .NET)
# T2  - Schema: all required fields present on every process
# T44 - Process count > 0
# T45 - Known system processes exist (System, svchost, etc.)
# T46 - Source field valid values
# T47 - CreationDateUTC format (ends with Z, when present)
# T48 - Numeric field types (WorkingSetSize, VirtualSize, ProcessId)
# T49 - IntegrityLevel: field present, valid values when non-null
# T50 - IntegrityLevel: at least one non-null value (own process readable)
# T51 - SHA256 consistency (hash xor error reason when path present)
# T52 - Signature structure when non-null (all 11 sub-fields present)
# T53 - Signature.NotAfter UTC format (ends with Z when non-null)
# T54 - Signature.IsSigned and IsValid are Boolean or null (not strings)
# T55 - collection_errors for Processes have artifact+message
# T56 - dotnet_crosscheck anomaly errors have artifact+message
#
# Inputs  : -JsonPath -HtmlPath
# Output  : @{ Passed=@(); Failed=@(); Info=@() }
# PS compat: 5.1
# Version : 2.0

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
$procs    = @($data.Processes)

$jsonHostname   = $manifest.hostname
$localHostnames = @($env:COMPUTERNAME, 'localhost', '127.0.0.1')
$isLocalJson    = ($localHostnames -icontains $jsonHostname)

# ---------------------------------------------------------------
# T1 - Process completeness (ground-truth vs .NET)
# ---------------------------------------------------------------
if (-not $isLocalJson) {
    Add-R "T1" $true "Process completeness (SKIP - remote host $jsonHostname)" @() $true
} else {
    $collectionTimeParsed = $null
    try {
        $collectionTimeParsed = [datetime]::ParseExact(
            $manifest.collection_time_utc,
            'yyyy-MM-ddTHH:mm:ssZ',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime()
    } catch {}

    $dotnetProcs   = [System.Diagnostics.Process]::GetProcesses()
    $expectedProcs = @()
    foreach ($dp in $dotnetProcs) {
        if ($collectionTimeParsed) {
            try {
                $startUtc = $dp.StartTime.ToUniversalTime()
                if ($startUtc -lt $collectionTimeParsed) { $expectedProcs += $dp }
                continue
            } catch {}
        }
        $expectedProcs += $dp
    }

    $collectedPidSet = @{}
    foreach ($p in $procs) { $collectedPidSet[[int]$p.ProcessId] = $true }

    $t1Missing = @()
    foreach ($dp in $expectedProcs) {
        if (-not $collectedPidSet.ContainsKey([int]$dp.Id)) {
            $t1Missing += "PID=$($dp.Id) Name=$($dp.ProcessName)"
        }
    }
    if ($t1Missing.Count -gt 25) { $t1Missing = $t1Missing[0..24] + "...and $($t1Missing.Count - 25) more" }

    $t1ExpectedCount = $expectedProcs.Count
    if ($t1Missing.Count -eq 0) {
        Add-R "T1" $true "Process completeness ($t1ExpectedCount/$t1ExpectedCount processes verified)"
    } else {
        Add-R "T1" $false "Process completeness ($($t1Missing.Count) missing of $t1ExpectedCount)" $t1Missing
    }
}

# ---------------------------------------------------------------
# T2 - Schema: all required fields present on every process
# ---------------------------------------------------------------
$requiredFields = @(
    'ProcessId','ParentProcessId','Name','CommandLine','ExecutablePath',
    'CreationDateUTC','CreationDateLocal','WorkingSetSize','VirtualSize',
    'SessionId','HandleCount','Owner','IntegrityLevel','IntegrityLevelError',
    'SHA256','SHA256Error','Signature','source'
)
$t2Violations = @()
foreach ($p in $procs) {
    if ($p -eq $null) { continue }
    $pid_ = $p.ProcessId
    $props = $p.PSObject.Properties.Name
    foreach ($f in $requiredFields) {
        if ($props -notcontains $f) {
            $t2Violations += "PID=$pid_ missing field '$f'"
            if ($t2Violations.Count -ge 25) { break }
        }
    }
    if ($t2Violations.Count -ge 25) { break }
}
if ($t2Violations.Count -eq 0) {
    Add-R "T2" $true "Schema completeness ($($procs.Count) processes - all required fields present)"
} else {
    Add-R "T2" $false "Schema completeness ($($t2Violations.Count) violations)" $t2Violations
}

# ---------------------------------------------------------------
# T44 - Process count > 0
# ---------------------------------------------------------------
if ($procs.Count -gt 0) {
    Add-R "T44" $true "Process count > 0 ($($procs.Count) processes collected)"
} else {
    Add-R "T44" $false "Process count is 0 - collection produced no records"
}

# ---------------------------------------------------------------
# T45 - Known system processes exist
# ---------------------------------------------------------------
$knownNames = @('System','svchost.exe','lsass.exe','services.exe','wininit.exe')
$collectedNames = @{}
foreach ($p in $procs) {
    if ($p.Name) { $collectedNames[$p.Name.ToLower()] = $true }
}
$t45Missing = @()
foreach ($kn in $knownNames) {
    if (-not $collectedNames.ContainsKey($kn.ToLower())) {
        $t45Missing += $kn
    }
}
if ($t45Missing.Count -eq 0) {
    Add-R "T45" $true "Known system processes present (System, svchost.exe, lsass.exe, services.exe, wininit.exe)"
} else {
    Add-R "T45" $false "Known system processes missing ($($t45Missing.Count))" $t45Missing
}

# ---------------------------------------------------------------
# T46 - Source field valid values
# ---------------------------------------------------------------
$validSources = @('cim','wmi','dotnet_fallback','cim+dotnet_fallback','wmi+dotnet_fallback','wmi_remote')
$t46Violations = @()
foreach ($p in $procs) {
    $src = $p.source
    if ($src -eq $null -or $src -eq '') {
        $t46Violations += "PID=$($p.ProcessId) source is null/empty"
    } elseif ($validSources -notcontains $src) {
        $t46Violations += "PID=$($p.ProcessId) invalid source='$src'"
    }
    if ($t46Violations.Count -ge 25) { break }
}
if ($t46Violations.Count -eq 0) {
    Add-R "T46" $true "Source field valid values ($($procs.Count) processes checked)"
} else {
    Add-R "T46" $false "Source field invalid ($($t46Violations.Count) violations)" $t46Violations
}

# ---------------------------------------------------------------
# T47 - CreationDateUTC format (ends with Z when present)
# ---------------------------------------------------------------
$t47Violations = @()
foreach ($p in $procs) {
    $cd = $p.CreationDateUTC
    if ($cd -ne $null -and $cd -ne '') {
        if ($cd -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') {
            $t47Violations += "PID=$($p.ProcessId) CreationDateUTC='$cd'"
        }
    }
    if ($t47Violations.Count -ge 25) { break }
}
if ($t47Violations.Count -eq 0) {
    Add-R "T47" $true "CreationDateUTC format valid (ends with Z where present)"
} else {
    Add-R "T47" $false "CreationDateUTC format invalid ($($t47Violations.Count) violations)" $t47Violations
}

# ---------------------------------------------------------------
# T48 - Numeric field types (WorkingSetSize, VirtualSize, ProcessId)
# ---------------------------------------------------------------
$t48Violations = @()
foreach ($p in $procs) {
    $pid_ = $p.ProcessId
    if ($pid_ -eq $null) {
        $t48Violations += "ProcessId is null"
    } else {
        try { $null = [int]$pid_ } catch { $t48Violations += "ProcessId='$pid_' not castable to int" }
    }
    $ws = $p.WorkingSetSize
    if ($ws -ne $null) {
        try { $null = [long]$ws } catch { $t48Violations += "PID=$pid_ WorkingSetSize='$ws' not castable to long" }
    }
    $vs = $p.VirtualSize
    if ($vs -ne $null) {
        try { $null = [long]$vs } catch { $t48Violations += "PID=$pid_ VirtualSize='$vs' not castable to long" }
    }
    if ($t48Violations.Count -ge 25) { break }
}
if ($t48Violations.Count -eq 0) {
    Add-R "T48" $true "Numeric field types valid ($($procs.Count) processes checked)"
} else {
    Add-R "T48" $false "Numeric field types invalid ($($t48Violations.Count) violations)" $t48Violations
}

# ---------------------------------------------------------------
# T49 - IntegrityLevel field present and valid values when non-null
# Valid: Untrusted, Low, Medium, MediumPlus, High, System, ProtectedProcess, RID_<n>
# null is allowed (ACCESS_DENIED when not running as admin)
# ---------------------------------------------------------------
$validILNames = @('Untrusted','Low','Medium','MediumPlus','High','System','ProtectedProcess')
$t49Violations = @()
foreach ($p in $procs) {
    $il = $p.IntegrityLevel
    if ($il -ne $null -and $il -ne '') {
        if ($validILNames -notcontains $il -and $il -notmatch '^RID_\d+$') {
            $t49Violations += "PID=$($p.ProcessId) IntegrityLevel='$il' not a valid value"
        }
    }
    if ($t49Violations.Count -ge 25) { break }
}
if ($t49Violations.Count -eq 0) {
    Add-R "T49" $true "IntegrityLevel values valid on all processes (null allowed for inaccessible)"
} else {
    Add-R "T49" $false "IntegrityLevel has invalid values ($($t49Violations.Count) violations)" $t49Violations
}

# ---------------------------------------------------------------
# T50 - At least one process has non-null IntegrityLevel
# The collector can always read its own process token even without admin.
# If every value is null the P/Invoke helper is broken.
# WMI remote collections cannot retrieve integrity levels (requires local P/Invoke).
# ---------------------------------------------------------------
$isWmiRemote = ($procs | Where-Object { $_.source -eq 'wmi_remote' } | Select-Object -First 1) -ne $null
$nonNullIL = @($procs | Where-Object { $_.IntegrityLevel -ne $null -and $_.IntegrityLevel -ne '' })
if ($isWmiRemote) {
    Add-R "T50" $true "IntegrityLevel (SKIP - WMI remote collection, P/Invoke unavailable)" @() $true
} elseif ($nonNullIL.Count -gt 0) {
    Add-R "T50" $true "IntegrityLevel populated on $($nonNullIL.Count)/$($procs.Count) processes (at least one non-null)"
} else {
    Add-R "T50" $false "IntegrityLevel is null on ALL $($procs.Count) processes - P/Invoke integrity helper may be broken"
}

# ---------------------------------------------------------------
# T51 - SHA256 consistency: hash xor error reason when path present
# If ExecutablePath is present: must have hash or error, not both null
# If both hash and error are set simultaneously that is also wrong
# ---------------------------------------------------------------
$t51Violations = @()
foreach ($p in $procs) {
    $h   = $p.SHA256
    $err = $p.SHA256Error
    $exe = $p.ExecutablePath
    if ($exe -ne $null -and $exe -ne '') {
        if (($h -eq $null -or $h -eq '') -and ($err -eq $null -or $err -eq '')) {
            $t51Violations += "PID=$($p.ProcessId) has ExecutablePath but SHA256 and SHA256Error both null"
        }
        if (($h -ne $null -and $h -ne '') -and ($err -ne $null -and $err -ne '')) {
            $t51Violations += "PID=$($p.ProcessId) has both SHA256 hash AND SHA256Error set simultaneously"
        }
    }
    if ($t51Violations.Count -ge 25) { break }
}
if ($t51Violations.Count -eq 0) {
    Add-R "T51" $true "SHA256 consistency valid (hash xor error; never both null when path present)"
} else {
    Add-R "T51" $false "SHA256 consistency ($($t51Violations.Count) violations)" $t51Violations
}

# ---------------------------------------------------------------
# T52 - Signature structure when non-null (all 11 sub-fields present)
# ---------------------------------------------------------------
$sigFields = @('IsSigned','IsValid','Status','SignerSubject','SignerCompany','Issuer',
               'Thumbprint','NotAfter','TimeStamper','IsOSBinary','SignatureType')
$t52Violations = @()
foreach ($p in $procs) {
    if ($p -eq $null) { continue }
    $sig = $p.Signature
    if ($sig -eq $null) { continue }
    $sigProps = $sig.PSObject.Properties.Name
    foreach ($sf in $sigFields) {
        if ($sigProps -notcontains $sf) {
            $t52Violations += "PID=$($p.ProcessId) Signature missing field '$sf'"
            if ($t52Violations.Count -ge 25) { break }
        }
    }
    if ($sig.Status -eq $null) {
        $t52Violations += "PID=$($p.ProcessId) Signature.Status is null"
    }
    if ($t52Violations.Count -ge 25) { break }
}
if ($t52Violations.Count -eq 0) {
    Add-R "T52" $true "Signature structure valid on all processes with non-null Signature block"
} else {
    Add-R "T52" $false "Signature structure ($($t52Violations.Count) violations)" $t52Violations
}

# ---------------------------------------------------------------
# T53 - Signature.NotAfter UTC format (ends with Z when non-null)
# ---------------------------------------------------------------
$t53Violations = @()
foreach ($p in $procs) {
    $sig = $p.Signature
    if ($sig -eq $null) { continue }
    $na = $sig.NotAfter
    if ($na -ne $null -and $na -ne '') {
        if ($na -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') {
            $t53Violations += "PID=$($p.ProcessId) Signature.NotAfter='$na' not UTC ISO 8601"
        }
    }
    if ($t53Violations.Count -ge 25) { break }
}
if ($t53Violations.Count -eq 0) {
    Add-R "T53" $true "Signature.NotAfter UTC format valid (ends with Z where present)"
} else {
    Add-R "T53" $false "Signature.NotAfter format invalid ($($t53Violations.Count) violations)" $t53Violations
}

# ---------------------------------------------------------------
# T54 - Signature.IsSigned and IsValid are Boolean or null
# ---------------------------------------------------------------
$t54Violations = @()
foreach ($p in $procs) {
    $sig = $p.Signature
    if ($sig -eq $null) { continue }
    foreach ($boolField in @('IsSigned','IsValid')) {
        $val = $sig.$boolField
        if ($val -ne $null) {
            $t = $val.GetType().Name
            if ($t -ne 'Boolean') {
                $t54Violations += "PID=$($p.ProcessId) Signature.$boolField type='$t' value='$val' (expected Boolean or null)"
            }
        }
    }
    if ($t54Violations.Count -ge 25) { break }
}
if ($t54Violations.Count -eq 0) {
    Add-R "T54" $true "Signature.IsSigned/IsValid are Boolean or null on all processes"
} else {
    Add-R "T54" $false "Signature boolean types invalid ($($t54Violations.Count) violations)" $t54Violations
}

# ---------------------------------------------------------------
# T55 - collection_errors entries related to Processes have artifact+message
# ---------------------------------------------------------------
$collErrors = @()
if ($manifest.collection_errors) { $collErrors = @($manifest.collection_errors) }
$procErrors = @($collErrors | Where-Object { $_.artifact -match 'process|dotnet' })
$t55Violations = @()
foreach ($ce in $procErrors) {
    if ($ce.artifact -eq $null) { $t55Violations += "collection_error missing artifact field" }
    if ($ce.message  -eq $null) { $t55Violations += "collection_error missing message field; artifact=$($ce.artifact)" }
    if ($t55Violations.Count -ge 25) { break }
}
if ($t55Violations.Count -eq 0) {
    $isInfo = ($procErrors.Count -eq 0)
    Add-R "T55" $true "collection_errors for Processes ($($procErrors.Count) entries) - all have artifact+message" @() $isInfo
} else {
    Add-R "T55" $false "collection_errors malformed ($($t55Violations.Count) violations)" $t55Violations
}

# ---------------------------------------------------------------
# T56 - dotnet_crosscheck anomaly errors have artifact and message
# ---------------------------------------------------------------
$dcErrors = @($collErrors | Where-Object { $_.artifact -eq 'dotnet_crosscheck' })
$t56Violations = @()
foreach ($dce in $dcErrors) {
    if ($dce.artifact -eq $null -or $dce.artifact -eq '') {
        $t56Violations += "dotnet_crosscheck entry missing artifact field"
    }
    if ($dce.message -eq $null -or $dce.message -eq '') {
        $t56Violations += "dotnet_crosscheck entry missing message field"
    }
    if ($t56Violations.Count -ge 25) { break }
}
if ($dcErrors.Count -eq 0) {
    Add-R "T56" $true "dotnet_crosscheck errors: 0 anomaly entries (no DKOM artifacts detected)" @() $true
} elseif ($t56Violations.Count -eq 0) {
    Add-R "T56" $true "dotnet_crosscheck errors: $($dcErrors.Count) anomaly entries - all have artifact+message"
} else {
    Add-R "T56" $false "dotnet_crosscheck errors malformed ($($t56Violations.Count) violations)" $t56Violations
}

return @{ Passed=$script:passResults; Failed=$script:failResults; Info=$script:infoResults }
