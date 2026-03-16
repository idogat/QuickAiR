#Requires -Version 5.1
# ╔══════════════════════════════════════╗
# ║  Quicker — T06_DLLs.ps1             ║
# ║  T13 DLL collection completeness,   ║
# ║  T14 DLL field validation,          ║
# ║  T15 private path detection         ║
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
# T13 - DLL collection completeness
# ---------------------------------------------------------------
if (-not $data.DLLs) {
    Add-R "T13" $true "DLL collection completeness (SKIP - no DLLs key in JSON)" @() $true
} else {
    $dlls = @($data.DLLs)

    # Group by ProcessId
    $byPid = @{}
    foreach ($d in $dlls) {
        $pid_ = $d.ProcessId
        if ($pid_ -eq $null) { $pid_ = '__null__' }
        if (-not $byPid.ContainsKey($pid_)) { $byPid[$pid_] = @() }
        $byPid[$pid_] += $d
    }

    $t13Failures = @()
    foreach ($pid_ in $byPid.Keys) {
        $entries = $byPid[$pid_]
        # Check: at least one entry with (ModuleName AND ModulePath not null)
        # OR at least one entry with reason not null/empty
        $hasModule = $false
        $hasReason = $false
        foreach ($e in $entries) {
            if ($e.ModuleName -ne $null -and $e.ModulePath -ne $null) { $hasModule = $true; break }
        }
        if (-not $hasModule) {
            foreach ($e in $entries) {
                if ($e.reason -ne $null -and $e.reason -ne '') { $hasReason = $true; break }
            }
        }
        if (-not $hasModule -and -not $hasReason) {
            $sample = $entries[0]
            $t13Failures += "ProcessId=$pid_ ProcessName=$($sample.ProcessName)"
        }
    }

    if ($t13Failures.Count -eq 0) {
        Add-R "T13" $true "DLL collection completeness ($($byPid.Keys.Count) processes, all have modules or error reason)"
    } else {
        Add-R "T13" $false "DLL collection completeness ($($t13Failures.Count) processes missing modules and reason)" $t13Failures
    }
}

# ---------------------------------------------------------------
# T14 - DLL fields
# ---------------------------------------------------------------
if (-not $data.DLLs) {
    Add-R "T14" $true "DLL fields (SKIP - no DLLs key in JSON)" @() $true
} else {
    $dlls = @($data.DLLs)
    $t14Violations = @()
    $t14Warns      = @()

    foreach ($e in $dlls) {
        # Only check entries where ModuleName is not null (successfully collected, not error entries)
        if ($e.ModuleName -eq $null) { continue }

        if ($e.ProcessId -eq $null) {
            $t14Violations += "ModuleName=$($e.ModuleName) has null ProcessId"
        }
        if ($e.ProcessName -eq $null -or $e.ProcessName -eq '') {
            $t14Violations += "PID=$($e.ProcessId) ModuleName=$($e.ModuleName) has null/empty ProcessName"
        }
        if ($e.ModuleName -eq $null) {
            $t14Violations += "PID=$($e.ProcessId) ProcessName=$($e.ProcessName) has null ModuleName"
        }
        if ($e.ModulePath -eq $null) {
            $t14Violations += "PID=$($e.ProcessId) ModuleName=$($e.ModuleName) has null ModulePath"
        }
        if ($e.IsPrivatePath -eq $null) {
            $t14Violations += "PID=$($e.ProcessId) ModuleName=$($e.ModuleName) has null IsPrivatePath"
        }

        # FileHash check for non-system paths (WARN not FAIL if null — file read may fail)
        if ($e.ModulePath -ne $null) {
            $isSystem = ($e.ModulePath -like 'C:\Windows\System32\*' -or $e.ModulePath -like 'C:\Windows\SysWOW64\*')
            if (-not $isSystem -and $e.FileHash -eq $null) {
                $t14Warns += "PID=$($e.ProcessId) ModuleName=$($e.ModuleName) non-system DLL has null FileHash (file read may have failed)"
            }
        }
    }

    $dllCount = ($dlls | Where-Object { $_.ModuleName -ne $null }).Count
    if ($t14Violations.Count -eq 0) {
        $warnSuffix = if ($t14Warns.Count -gt 0) { " [$($t14Warns.Count) FileHash warn(s)]" } else { "" }
        Add-R "T14" $true "DLL fields ($dllCount DLL entries OK)$warnSuffix"
    } else {
        Add-R "T14" $false "DLL fields ($($t14Violations.Count) violations)" $t14Violations
    }
}

# ---------------------------------------------------------------
# T15 - Private path detection
# ---------------------------------------------------------------
if (-not $data.DLLs) {
    Add-R "T15" $true "Private path detection (SKIP - no DLLs key in JSON)" @() $true
} else {
    $dlls          = @($data.DLLs)
    $PRIVATE_MARKERS = @('\Temp\','\AppData\','\ProgramData\','\Users\Public\','\Downloads\')
    $t15Violations = @()

    foreach ($e in $dlls) {
        if ($e.ModulePath -eq $null) { continue }

        $shouldBePrivate = $false
        foreach ($marker in $PRIVATE_MARKERS) {
            if ($e.ModulePath -like "*$marker*") { $shouldBePrivate = $true; break }
        }

        if ($shouldBePrivate -and $e.IsPrivatePath -ne $true) {
            $t15Violations += "PID=$($e.ProcessId) ModuleName=$($e.ModuleName) Path=$($e.ModulePath) IsPrivatePath=$($e.IsPrivatePath) (expected true)"
        }
    }

    if ($t15Violations.Count -eq 0) {
        Add-R "T15" $true "Private path detection (all private-path DLLs correctly flagged)"
    } else {
        Add-R "T15" $false "Private path detection ($($t15Violations.Count) violations)" $t15Violations
    }
}

return @{ Passed=$script:passResults; Failed=$script:failResults; Info=$script:infoResults }
