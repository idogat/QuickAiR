#Requires -Version 5.1
# ╔══════════════════════════════════════════════════════════════╗
# ║  Quicker — T06_DLLs.ps1                                     ║
# ║  T13 DLL collection completeness                            ║
# ║  T14 DLL field validation                                   ║
# ║  T15 Private path detection (positive cases)                ║
# ║  T76 Signature field structure and types                    ║
# ║  T77 Source field valid values (dotnet or wmi)              ║
# ║  T78 SHA256Error valid values                               ║
# ║  T79 Protected process skip (no lsass/csrss/etc)            ║
# ║  T80 Negative IsPrivatePath (System32/SysWOW64 = false)     ║
# ║  T81 Error/reason entry structure                           ║
# ║  T82 LoadedAt field removed from all entries                ║
# ╠══════════════════════════════════════════════════════════════╣
# ║  Inputs    : -JsonPath -HtmlPath                            ║
# ║  Output    : @{ Passed=@();                                 ║
# ║               Failed=@(); Info=@() }                        ║
# ║  PS compat : 5.1                                            ║
# ║  Version   : 2.0                                            ║
# ╚══════════════════════════════════════════════════════════════╝
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

$manifest = $data.manifest

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
        $dllPid = $d.ProcessId
        if ($dllPid -eq $null) { $dllPid = '__null__' }
        if (-not $byPid.ContainsKey($dllPid)) { $byPid[$dllPid] = @() }
        $byPid[$dllPid] += $d
    }

    $t13Failures = @()
    foreach ($dllPid in $byPid.Keys) {
        $entries = $byPid[$dllPid]
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
            $t13Failures += "ProcessId=$dllPid ProcessName=$($sample.ProcessName)"
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

        if ($t14Violations.Count -ge 25) { break }
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
# T15 - Private path detection (positive cases)
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
        if ($t15Violations.Count -ge 25) { break }
    }

    if ($t15Violations.Count -eq 0) {
        Add-R "T15" $true "Private path detection (all private-path DLLs correctly flagged)"
    } else {
        Add-R "T15" $false "Private path detection ($($t15Violations.Count) violations)" $t15Violations
    }
}

# ---------------------------------------------------------------
# T76 - Signature field structure and types
# ---------------------------------------------------------------
if (-not $data.DLLs) {
    Add-R "T76" $true "Signature field structure (SKIP - no DLLs key in JSON)" @() $true
} else {
    $dlls = @($data.DLLs)
    $SIG_REQUIRED_FIELDS = @('IsSigned','IsValid','Status','SignerSubject','SignerCompany','Issuer','Thumbprint','NotAfter','TimeStamper','IsOSBinary','SignatureType')
    $t76Violations = @()

    foreach ($e in $dlls) {
        if ($e.ModuleName -eq $null) { continue }
        if ($e.Signature -eq $null) { continue }

        $sigProps = $e.Signature.PSObject.Properties.Name
        foreach ($f in $SIG_REQUIRED_FIELDS) {
            if ($sigProps -notcontains $f) {
                $t76Violations += "PID=$($e.ProcessId) ModuleName=$($e.ModuleName) Signature missing field '$f'"
            }
        }

        # IsSigned must be bool or null
        $isSignedVal = $e.Signature.IsSigned
        if ($isSignedVal -ne $null) {
            $t = $isSignedVal.GetType().Name
            if ($t -ne 'Boolean') {
                $t76Violations += "PID=$($e.ProcessId) ModuleName=$($e.ModuleName) Signature.IsSigned type='$t' (expected Boolean or null)"
            }
        }

        # IsValid must be bool or null
        $isValidVal = $e.Signature.IsValid
        if ($isValidVal -ne $null) {
            $t = $isValidVal.GetType().Name
            if ($t -ne 'Boolean') {
                $t76Violations += "PID=$($e.ProcessId) ModuleName=$($e.ModuleName) Signature.IsValid type='$t' (expected Boolean or null)"
            }
        }

        # Status must be a non-empty string
        $statusVal = $e.Signature.Status
        if ($statusVal -ne $null -and $statusVal -eq '') {
            $t76Violations += "PID=$($e.ProcessId) ModuleName=$($e.ModuleName) Signature.Status is empty string (expected non-empty)"
        }

        # NotAfter must match UTC ISO 8601 when non-null
        $notAfterVal = $e.Signature.NotAfter
        if ($notAfterVal -ne $null -and $notAfterVal -ne '') {
            if ($notAfterVal -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}') {
                $t76Violations += "PID=$($e.ProcessId) ModuleName=$($e.ModuleName) Signature.NotAfter='$notAfterVal' not ISO 8601 format"
            }
        }

        if ($t76Violations.Count -ge 25) { break }
    }

    $sigCount = ($dlls | Where-Object { $_.ModuleName -ne $null -and $_.Signature -ne $null }).Count
    $nullSigCount = ($dlls | Where-Object { $_.ModuleName -ne $null -and $_.Signature -eq $null }).Count
    if ($t76Violations.Count -eq 0) {
        Add-R "T76" $true "Signature field structure valid ($sigCount entries with Signature checked, $nullSigCount with null Signature)"
    } else {
        Add-R "T76" $false "Signature field structure: $($t76Violations.Count) violations" $t76Violations
    }
}

# ---------------------------------------------------------------
# T77 - Source field valid values (dotnet or wmi)
# ---------------------------------------------------------------
if (-not $data.DLLs) {
    Add-R "T77" $true "Source field validation (SKIP - no DLLs key in JSON)" @() $true
} else {
    $dlls = @($data.DLLs)
    $VALID_SOURCES = @('dotnet','wmi')
    $t77Violations = @()

    foreach ($e in $dlls) {
        $srcVal = $e.source
        if ($srcVal -eq $null -or $srcVal -eq '') {
            $t77Violations += "PID=$($e.ProcessId) ModuleName=$($e.ModuleName) has null/empty source field"
        } elseif ($VALID_SOURCES -notcontains $srcVal) {
            $t77Violations += "PID=$($e.ProcessId) ModuleName=$($e.ModuleName) has source='$srcVal' (expected: dotnet or wmi)"
        }
        if ($t77Violations.Count -ge 25) { break }
    }

    if ($t77Violations.Count -eq 0) {
        Add-R "T77" $true "Source field valid on all $($dlls.Count) DLL entries (dotnet or wmi)"
    } else {
        Add-R "T77" $false "Source field invalid: $($t77Violations.Count) violations" $t77Violations
    }
}

# ---------------------------------------------------------------
# T78 - SHA256Error valid values
# ---------------------------------------------------------------
if (-not $data.DLLs) {
    Add-R "T78" $true "SHA256Error validation (SKIP - no DLLs key in JSON)" @() $true
} else {
    $dlls = @($data.DLLs)
    $VALID_SHA256_ERRORS = @('ACCESS_DENIED','FILE_NOT_FOUND','PATH_NULL')
    $t78Violations = @()

    foreach ($e in $dlls) {
        if ($e.ModuleName -eq $null) { continue }
        $errVal = $e.SHA256Error
        if ($errVal -eq $null) { continue }

        $isValid = ($VALID_SHA256_ERRORS -contains $errVal) -or ($errVal -like 'COMPUTE_ERROR*')
        if (-not $isValid) {
            $t78Violations += "PID=$($e.ProcessId) ModuleName=$($e.ModuleName) SHA256Error='$errVal' (expected null, ACCESS_DENIED, FILE_NOT_FOUND, PATH_NULL, or COMPUTE_ERROR:...)"
        }
        if ($t78Violations.Count -ge 25) { break }
    }

    $errCount = ($dlls | Where-Object { $_.ModuleName -ne $null -and $_.SHA256Error -ne $null }).Count
    if ($t78Violations.Count -eq 0) {
        Add-R "T78" $true "SHA256Error valid values ($errCount entries with non-null SHA256Error, all valid)"
    } else {
        Add-R "T78" $false "SHA256Error invalid values: $($t78Violations.Count) violations" $t78Violations
    }
}

# ---------------------------------------------------------------
# T79 - Protected process skip (no lsass/csrss/smss/wininit/System/Idle in output)
# ---------------------------------------------------------------
if (-not $data.DLLs) {
    Add-R "T79" $true "Protected process skip (SKIP - no DLLs key in JSON)" @() $true
} else {
    $dlls = @($data.DLLs)
    $PROTECTED_PROCS = @('lsass','csrss','smss','wininit','System','Idle')
    $t79Violations = @()

    foreach ($e in $dlls) {
        $pName = $e.ProcessName
        if ($pName -eq $null) { continue }
        $pNameNoExt = $pName -replace '\.exe$',''
        foreach ($pp in $PROTECTED_PROCS) {
            if ($pNameNoExt -ieq $pp -or $pName -ieq $pp) {
                $t79Violations += "PID=$($e.ProcessId) ProcessName=$pName is a protected process and should have been skipped"
                break
            }
        }
        if ($t79Violations.Count -ge 25) { break }
    }

    if ($t79Violations.Count -eq 0) {
        Add-R "T79" $true "Protected process skip: no lsass/csrss/smss/wininit/System/Idle entries in DLL output ($($dlls.Count) entries checked)"
    } else {
        Add-R "T79" $false "Protected process skip: $($t79Violations.Count) protected process entries found in output" $t79Violations
    }
}

# ---------------------------------------------------------------
# T80 - Negative IsPrivatePath (System32/SysWOW64 paths must have IsPrivatePath = false)
# ---------------------------------------------------------------
if (-not $data.DLLs) {
    Add-R "T80" $true "Negative IsPrivatePath (SKIP - no DLLs key in JSON)" @() $true
} else {
    $dlls = @($data.DLLs)
    $t80Violations = @()

    foreach ($e in $dlls) {
        if ($e.ModulePath -eq $null) { continue }

        $isSystemPath = ($e.ModulePath -like 'C:\Windows\System32\*' -or $e.ModulePath -like 'C:\Windows\SysWOW64\*')
        if ($isSystemPath -and $e.IsPrivatePath -eq $true) {
            $t80Violations += "PID=$($e.ProcessId) ModuleName=$($e.ModuleName) Path=$($e.ModulePath) IsPrivatePath=true (expected false for system path)"
        }
        if ($t80Violations.Count -ge 25) { break }
    }

    $systemPathCount = ($dlls | Where-Object { $_.ModulePath -like 'C:\Windows\System32\*' -or $_.ModulePath -like 'C:\Windows\SysWOW64\*' }).Count
    if ($t80Violations.Count -eq 0) {
        Add-R "T80" $true "Negative IsPrivatePath: $systemPathCount System32/SysWOW64 entries all have IsPrivatePath=false"
    } else {
        Add-R "T80" $false "Negative IsPrivatePath: $($t80Violations.Count) system-path entries incorrectly have IsPrivatePath=true" $t80Violations
    }
}

# ---------------------------------------------------------------
# T81 - Error/reason entry structure
# ---------------------------------------------------------------
if (-not $data.DLLs) {
    Add-R "T81" $true "Error/reason entry structure (SKIP - no DLLs key in JSON)" @() $true
} else {
    $dlls = @($data.DLLs)
    $t81Violations = @()
    $reasonEntryCount = 0

    foreach ($e in $dlls) {
        $reasonVal = $e.reason
        if ($reasonVal -eq $null -or $reasonVal -eq '') { continue }
        $reasonEntryCount++

        # reason entries must have ProcessId and ProcessName
        if ($e.ProcessId -eq $null) {
            $t81Violations += "reason='$reasonVal' entry missing ProcessId (ProcessName=$($e.ProcessName))"
        }
        if ($e.ProcessName -eq $null -or $e.ProcessName -eq '') {
            $t81Violations += "reason='$reasonVal' entry missing ProcessName (ProcessId=$($e.ProcessId))"
        }
        # ModuleName and ModulePath should be null on error entries (not mandatory but document if not null)
        # No failure for non-null ModuleName/ModulePath — module may partially populate them

        if ($t81Violations.Count -ge 25) { break }
    }

    if ($t81Violations.Count -eq 0) {
        Add-R "T81" $true "Error/reason entry structure valid ($reasonEntryCount reason entries all have ProcessId and ProcessName)"
    } else {
        Add-R "T81" $false "Error/reason entry structure: $($t81Violations.Count) violations" $t81Violations
    }
}

# ---------------------------------------------------------------
# T82 - LoadedAt field removed from all entries (v2.5 schema)
# ---------------------------------------------------------------
if (-not $data.DLLs) {
    Add-R "T82" $true "LoadedAt field removed (SKIP - no DLLs key in JSON)" @() $true
} else {
    $dlls = @($data.DLLs)
    $t82Violations = @()

    foreach ($e in $dlls) {
        $props = $e.PSObject.Properties.Name
        if ($props -contains 'LoadedAt') {
            $t82Violations += "PID=$($e.ProcessId) ModuleName=$($e.ModuleName) still has LoadedAt field (removed in v2.5)"
        }
        if ($t82Violations.Count -ge 25) { break }
    }

    if ($t82Violations.Count -eq 0) {
        Add-R "T82" $true "LoadedAt field absent from all $($dlls.Count) DLL entries (v2.5 schema correct)"
    } else {
        Add-R "T82" $false "LoadedAt field present on $($t82Violations.Count) entries (should have been removed in v2.5)" $t82Violations
    }
}

return @{ Passed=$script:passResults; Failed=$script:failResults; Info=$script:infoResults }
