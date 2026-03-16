#Requires -Version 5.1
# ╔══════════════════════════════════════╗
# ║  Quicker — T07_Signatures.ps1        ║
# ║  T16 SHA256 consistency,            ║
# ║  T17 Signature fields,              ║
# ║  T18 Process completeness 2008R2    ║
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
$jsonRaw = [System.IO.File]::ReadAllText($JsonPath, [System.Text.Encoding]::UTF8)
$data    = $jsonRaw | ConvertFrom-Json

# ---------------------------------------------------------------
# T16 - SHA256 consistency
# Every process/DLL with non-null path must have SHA256 or SHA256Error
# ---------------------------------------------------------------
$t16Violations = @()

foreach ($p in @($data.Processes)) {
    if ($p.ExecutablePath -ne $null -and $p.ExecutablePath -ne '') {
        if ($p.SHA256 -eq $null -and $p.SHA256Error -eq $null) {
            $t16Violations += "PROC PID=$($p.ProcessId) Name=$($p.Name): both SHA256 and SHA256Error are null"
        }
    }
}

foreach ($d in @($data.DLLs)) {
    if ($d.ModulePath -ne $null -and $d.ModulePath -ne '') {
        if ($d.FileHash -eq $null -and $d.SHA256Error -eq $null) {
            $t16Violations += "DLL PID=$($d.ProcessId) Module=$($d.ModuleName): both FileHash and SHA256Error are null"
        }
    }
}

if ($t16Violations.Count -eq 0) {
    Add-R "T16" $true "SHA256 consistency (all paths have hash or error reason)"
} else {
    $t16Count = $t16Violations.Count
    Add-R "T16" $false "SHA256 consistency - $t16Count violations" $t16Violations
}

# ---------------------------------------------------------------
# T17 - Signature fields
# Every process/DLL with non-null path must have Signature block
# IsSigned must be bool or null (not missing)
# If IsSigned=true: SignerCertificate/SignerSubject present
# ---------------------------------------------------------------
$t17Violations = @()

foreach ($p in @($data.Processes)) {
    if ($p.ExecutablePath -ne $null -and $p.ExecutablePath -ne '') {
        if ($p.Signature -eq $null) {
            $t17Violations += "PROC PID=$($p.ProcessId) Name=$($p.Name): Signature block missing"
            continue
        }
        $isSigned = $p.Signature.IsSigned
        if ($isSigned -ne $null -and $isSigned -isnot [bool]) {
            $t17Violations += "PROC PID=$($p.ProcessId) Name=$($p.Name): IsSigned is '$isSigned' (not bool or null)"
        }
        if ($isSigned -eq $true -and ($p.Signature.SignerSubject -eq $null -and $p.Signature.SignerCompany -eq $null)) {
            # Allow null SignerSubject if Status is an error
            if ($p.Signature.Status -notmatch '^ERROR|PS2_') {
                $t17Violations += "PROC PID=$($p.ProcessId) Name=$($p.Name): IsSigned=true but SignerSubject/Company both null"
            }
        }
    }
}

foreach ($d in @($data.DLLs)) {
    if ($d.ModulePath -ne $null -and $d.ModulePath -ne '') {
        if ($d.Signature -eq $null) {
            $t17Violations += "DLL PID=$($d.ProcessId) Module=$($d.ModuleName): Signature block missing"
            continue
        }
        $isSigned = $d.Signature.IsSigned
        if ($isSigned -ne $null -and $isSigned -isnot [bool]) {
            $t17Violations += "DLL PID=$($d.ProcessId) Module=$($d.ModuleName): IsSigned is '$isSigned' (not bool or null)"
        }
    }
}

if ($t17Violations.Count -eq 0) {
    Add-R "T17" $true "Signature fields (all entries with paths have valid Signature block)"
} else {
    $t17Count = $t17Violations.Count
    Add-R "T17" $false "Signature fields - $t17Count violations" $t17Violations
}

# ---------------------------------------------------------------
# T18 - Process completeness re-check on 2008R2
# Skip if target OS is not Server 2008 R2 (version 6.1.x)
# ---------------------------------------------------------------
$targetOsVersion = if ($data.manifest) { $data.manifest.target_os_version } else { '' }
$targetOsCaption = if ($data.manifest) { $data.manifest.target_os_caption } else { '' }
$is2008R2 = ($targetOsVersion -match '^6\.1\.' -or $targetOsCaption -match '2008 R2|Windows 7')

if (-not $is2008R2) {
    Add-R "T18" $true "Process completeness 2008R2 (SKIP - not Server 2008 R2, OS=$targetOsCaption v$targetOsVersion)" @() $true
} else {
    $procList   = @($data.Processes)
    $t18Failures = @()

    # Mandatory: powershell.exe must appear
    $hasPsh = @($procList | Where-Object { $_.Name -match '^powershell(\.exe)?$' })
    if ($hasPsh.Count -eq 0) {
        $t18Failures += "powershell.exe not found in process list (mandatory)"
    }

    # Sanity: System process must appear
    $hasSys = @($procList | Where-Object { $_.Name -match '^System$' })
    if ($hasSys.Count -eq 0) {
        $t18Failures += "System process not found in process list"
    }

    # Count sanity
    if ($procList.Count -lt 10) {
        $t18Failures += "Only $($procList.Count) processes collected - suspiciously low, likely truncated"
    }

    # Compare with GetProcesses() if running on the same machine
    $targetHostname = if ($data.manifest) { $data.manifest.hostname } else { '' }
    $isLocalCollection = ($targetHostname -ieq 'localhost' -or $targetHostname -ieq $env:COMPUTERNAME -or $targetHostname -ieq '127.0.0.1')
    if ($isLocalCollection) {
        $liveProcs  = [System.Diagnostics.Process]::GetProcesses()
        $jsonPids   = @{}
        foreach ($p in $procList) { if ($p.ProcessId -ne $null) { $jsonPids[[int]$p.ProcessId] = $p.Name } }
        foreach ($lp in $liveProcs) {
            if (-not $jsonPids.ContainsKey([int]$lp.Id)) {
                $t18Failures += "PID=$($lp.Id) Name=$($lp.ProcessName) present in GetProcesses but missing from JSON"
            }
        }
    }

    $t18ProcCount = $procList.Count
    $t18IssueCount = $t18Failures.Count
    if ($t18IssueCount -eq 0) {
        Add-R "T18" $true "Process completeness 2008R2 - $t18ProcCount processes, powershell.exe present"
    } else {
        Add-R "T18" $false "Process completeness 2008R2 - $t18IssueCount issues" $t18Failures
    }
}

return @{ Passed=$script:passResults; Failed=$script:failResults; Info=$script:infoResults }
