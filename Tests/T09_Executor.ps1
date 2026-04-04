#Requires -Version 5.1
# =============================================
#   QuickAiR -- T09_Executor.ps1
#   T24 WinRM.psm1 imports + exports
#   T25 WMI.psm1 imports + exports
#   T26 Unreachable IP returns CONNECTION_FAILED
#   T27 Missing local binary returns CONNECTION_FAILED
#   T28 localhost notepad.exe smoke test
#   T29 Get-BinaryType on regular binary: IsSFX=false
#   T30 Get-BinaryType on nonexistent path: IsSFX=false
#   T31 Byte pattern detection: ZIP magic appended → IsSFX=true
#   T32 SFX flow exit code 0 → FinalState=SFX_LAUNCHED
#   T33 SFX flow exit code 1 → FinalState=LAUNCH_FAILED
#   T34 SMBWMI.psm1 imports + exports Invoke-Executor
#   T35 SMB unreachable returns CONNECTION_FAILED
#   T36 SMBWMI localhost notepad.exe smoke test
#   T37 Auto both methods fail: combined error detail
#   T38 WMI-only localhost smoke test
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

$scriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoDir     = Split-Path -Parent $scriptDir
$executorDir = Join-Path $repoDir "Modules\Executors"
$winrmMod    = Join-Path $executorDir "WinRM.psm1"
$wmiMod      = Join-Path $executorDir "WMI.psm1"
$smbwmiMod   = Join-Path $executorDir "SMBWMI.psm1"

# ---------------------------------------------------------------
# T24 -- WinRM.psm1 imports cleanly, exports Invoke-Executor
# ---------------------------------------------------------------
try {
    if (-not (Test-Path $winrmMod)) { throw "File not found: $winrmMod" }
    Import-Module $winrmMod -Force -ErrorAction Stop
    $cmd = Get-Command Invoke-Executor -ErrorAction Stop
    if ($cmd.Source -match 'WinRM') {
        Add-R "T24" $true "WinRM.psm1 imports cleanly and exports Invoke-Executor"
    } else {
        Add-R "T24" $true "WinRM.psm1 imports and Invoke-Executor available (source=$($cmd.Source))"
    }
} catch {
    Add-R "T24" $false "WinRM.psm1 import failed" @($_.Exception.Message)
}

# ---------------------------------------------------------------
# T25 -- WMI.psm1 imports cleanly, exports Invoke-Executor
# ---------------------------------------------------------------
try {
    if (-not (Test-Path $wmiMod)) { throw "File not found: $wmiMod" }
    Import-Module $wmiMod -Force -ErrorAction Stop
    $cmd = Get-Command Invoke-Executor -ErrorAction Stop
    if ($null -ne $cmd) {
        Add-R "T25" $true "WMI.psm1 imports cleanly and exports Invoke-Executor"
    } else {
        Add-R "T25" $false "WMI.psm1 imported but Invoke-Executor not found" @()
    }
} catch {
    Add-R "T25" $false "WMI.psm1 import failed" @($_.Exception.Message)
}

# ---------------------------------------------------------------
# T26 -- Invalid target returns CONNECTION_FAILED within 35s
# ---------------------------------------------------------------
try {
    Import-Module $winrmMod -Force -ErrorAction Stop
    $t26Start = Get-Date
    $r26 = Invoke-Executor `
        -ComputerName "192.0.2.1" `
        -LocalBinaryPath "C:\Windows\System32\notepad.exe" `
        -RemoteDestPath "C:\Windows\Temp\notepad.exe" `
        -AliveCheckSeconds 1
    $t26Elapsed = [int]((Get-Date) - $t26Start).TotalSeconds

    $t26Details = @()
    if ($r26.FinalState -ne "CONNECTION_FAILED") {
        $t26Details += "Expected FinalState=CONNECTION_FAILED, got $($r26.FinalState)"
    }
    if ($t26Elapsed -gt 35) {
        $t26Details += "Elapsed ${t26Elapsed}s exceeds 35s limit"
    }
    if ($t26Details.Count -eq 0) {
        Add-R "T26" $true "Unreachable IP returned CONNECTION_FAILED in ${t26Elapsed}s"
    } else {
        Add-R "T26" $false "Unreachable IP test failed" $t26Details
    }
} catch {
    Add-R "T26" $false "T26 threw exception" @($_.Exception.Message)
}

# ---------------------------------------------------------------
# T27 -- Missing local binary returns CONNECTION_FAILED with "not found"
# ---------------------------------------------------------------
try {
    Import-Module $winrmMod -Force -ErrorAction Stop
    $r27 = Invoke-Executor `
        -ComputerName "localhost" `
        -LocalBinaryPath "C:\NonExistent\missing_binary_xyz.exe" `
        -RemoteDestPath "C:\Windows\Temp\missing_binary_xyz.exe" `
        -AliveCheckSeconds 1

    $t27Details = @()
    if ($r27.FinalState -ne "CONNECTION_FAILED") {
        $t27Details += "Expected FinalState=CONNECTION_FAILED, got $($r27.FinalState)"
    }
    $hasNotFound = ($r27.States | Where-Object { $_.Detail -match 'not found' })
    if (-not $hasNotFound) {
        $t27Details += "No state detail containing 'not found'. Details: $($r27.States | ForEach-Object { $_.Detail })"
    }
    if ($t27Details.Count -eq 0) {
        Add-R "T27" $true "Missing binary returned CONNECTION_FAILED with 'not found' detail"
    } else {
        Add-R "T27" $false "Missing binary test failed" $t27Details
    }
} catch {
    Add-R "T27" $false "T27 threw exception" @($_.Exception.Message)
}

# ---------------------------------------------------------------
# T28 -- localhost notepad.exe smoke test via WinRM
# ---------------------------------------------------------------
$t28TempFile = "C:\Windows\Temp\quickair_test_notepad_$(Get-Random).exe"
$t28PID      = $null

try {
    Import-Module $winrmMod -Force -ErrorAction Stop

    $r28 = Invoke-Executor `
        -ComputerName "localhost" `
        -LocalBinaryPath "C:\Windows\System32\notepad.exe" `
        -RemoteDestPath $t28TempFile `
        -AliveCheckSeconds 3

    $t28Details = @()

    # Required fields present
    $reqFields = @('ExecutionId','ComputerName','Method','LocalBinary','RemoteDest',
                   'Arguments','StartTimeUTC','EndTimeUTC','States','FinalState','PID','Error')
    foreach ($f in $reqFields) {
        $val = $r28.PSObject.Properties[$f]
        if ($null -eq $val) { $t28Details += "Missing field: $f" }
    }

    # StartTimeUTC ends in Z or +00:00 (both valid ISO 8601 UTC)
    if ($r28.StartTimeUTC -and $r28.StartTimeUTC -notmatch '(Z|\+00:00)$') {
        $t28Details += "StartTimeUTC not UTC (expected Z or +00:00 suffix): $($r28.StartTimeUTC)"
    }

    # States non-empty
    if (@($r28.States).Count -eq 0) {
        $t28Details += "States[] is empty"
    }

    # Capture PID for cleanup
    $t28PID = $r28.PID

    if ($t28Details.Count -eq 0) {
        Add-R "T28" $true "localhost notepad.exe smoke test passed (FinalState=$($r28.FinalState) PID=$t28PID)"
    } else {
        Add-R "T28" $false "localhost notepad.exe smoke test failed ($($t28Details.Count) issues)" $t28Details
    }
} catch {
    Add-R "T28" $false "T28 threw exception" @($_.Exception.Message)
} finally {
    # Cleanup: kill notepad test process
    if ($t28PID) {
        try { Stop-Process -Id $t28PID -Force -ErrorAction SilentlyContinue } catch { }
    }
    # Also kill any notepad processes launched from temp path
    try {
        Get-Process notepad -ErrorAction SilentlyContinue | Where-Object {
            try { $_.Path -eq $t28TempFile } catch { $false }
        } | Stop-Process -Force -ErrorAction SilentlyContinue
    } catch { }
    # Remove temp file
    if (Test-Path -LiteralPath $t28TempFile) {
        Remove-Item -LiteralPath $t28TempFile -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------
# T29 -- Get-BinaryType on regular Windows binary: IsSFX=false, no exception
# ---------------------------------------------------------------
try {
    $outputMod = Join-Path $repoDir "Modules\Core\Output.psm1"
    Import-Module $outputMod -Force -ErrorAction Stop

    $bt29 = Get-BinaryType -Path "C:\Windows\System32\cmd.exe"
    $t29Details = @()
    if ($bt29.IsSFX -ne $false) { $t29Details += "IsSFX should be false, got $($bt29.IsSFX)" }
    if ($null -eq $bt29.FileSizeBytes) { $t29Details += "FileSizeBytes is null" }
    if ($t29Details.Count -eq 0) {
        Add-R "T29" $true "Get-BinaryType on cmd.exe: IsSFX=false, no exception"
    } else {
        Add-R "T29" $false "Get-BinaryType on regular binary failed" $t29Details
    }
} catch {
    Add-R "T29" $false "T29 threw exception" @($_.Exception.Message)
}

# ---------------------------------------------------------------
# T30 -- Get-BinaryType on nonexistent path: IsSFX=false, no exception
# ---------------------------------------------------------------
try {
    $outputMod = Join-Path $repoDir "Modules\Core\Output.psm1"
    Import-Module $outputMod -Force -ErrorAction SilentlyContinue

    $bt30 = Get-BinaryType -Path "C:\NonExistent\no_such_file_xyz.exe"
    $t30Details = @()
    if ($bt30.IsSFX -ne $false) { $t30Details += "IsSFX should be false, got $($bt30.IsSFX)" }
    if ($t30Details.Count -eq 0) {
        Add-R "T30" $true "Get-BinaryType on nonexistent path: IsSFX=false, no exception"
    } else {
        Add-R "T30" $false "Get-BinaryType on nonexistent path failed" $t30Details
    }
} catch {
    Add-R "T30" $false "T30 threw exception" @($_.Exception.Message)
}

# ---------------------------------------------------------------
# T31 -- Byte pattern detection: file with ZIP magic appended
#        No valid PE needed -- testing byte detection only.
#        PASS: IsSFX=true, SFXType="ZIP"
# ---------------------------------------------------------------
$t31TempFile = [System.IO.Path]::GetTempFileName()
try {
    $outputMod = Join-Path $repoDir "Modules\Core\Output.psm1"
    Import-Module $outputMod -Force -ErrorAction SilentlyContinue

    # Build a minimal fake PE + ZIP magic appended:
    # DOS header (64 bytes), e_lfanew=0x3C pointing to offset 64=0x40
    # PE sig at 0x40, COFF header (20 bytes), no optional header (optHdrSize=0)
    # No sections → PE ends at section table start = 0x40+4+20+0 = 0x58
    # Then append ZIP magic: 50 4B 03 04
    $peBytes = New-Object byte[] 100
    # MZ header
    $peBytes[0] = 0x4D; $peBytes[1] = 0x5A  # MZ
    # e_lfanew at offset 0x3C = 64 = 0x40
    $peBytes[0x3C] = 0x40; $peBytes[0x3D] = 0x00; $peBytes[0x3E] = 0x00; $peBytes[0x3F] = 0x00
    # PE signature at offset 0x40
    $peBytes[0x40] = 0x50; $peBytes[0x41] = 0x45; $peBytes[0x42] = 0x00; $peBytes[0x43] = 0x00
    # COFF: Machine(2) Sections(2)=0 TimeDateStamp(4) SymTablePtr(4) SymCount(4) OptHdrSize(2)=0 Chars(2)
    # All zeros → 0 sections, optHdrSize=0 → sectionTable at 0x40+4+20=0x58
    # PE end computed as 0 (no sections) → falls through to $peEnd=$fileSize path
    # Append ZIP magic at end: bytes 96-99
    $peBytes[96] = 0x50; $peBytes[97] = 0x4B; $peBytes[98] = 0x03; $peBytes[99] = 0x04
    [System.IO.File]::WriteAllBytes($t31TempFile, $peBytes)

    $bt31 = Get-BinaryType -Path $t31TempFile
    $t31Details = @()
    if ($bt31.IsSFX -ne $true)    { $t31Details += "IsSFX should be true, got $($bt31.IsSFX)" }
    if ($bt31.SFXType -ne "ZIP")  { $t31Details += "SFXType should be ZIP, got $($bt31.SFXType)" }
    if ($t31Details.Count -eq 0) {
        Add-R "T31" $true "Byte pattern detection: ZIP magic → IsSFX=true, SFXType=ZIP"
    } else {
        Add-R "T31" $false "Byte pattern detection failed" $t31Details
    }
} catch {
    Add-R "T31" $false "T31 threw exception" @($_.Exception.Message)
} finally {
    if (Test-Path -LiteralPath $t31TempFile) {
        Remove-Item -LiteralPath $t31TempFile -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------
# T32 -- SFX flow exit code 0: cmd.exe /C exit 0, IsSFX overridden
#        PASS: FinalState=SFX_LAUNCHED
#        PASS: States[] contains no ALIVE state
#        PASS: BinaryType.IsSFX=true in result
# ---------------------------------------------------------------
try {
    Import-Module $winrmMod -Force -ErrorAction Stop

    $mockBT32 = [PSCustomObject]@{ IsSFX=$true; SFXType='ZIP'; DetectionMethod='Test'; FileSizeBytes=0; PESizeBytes=0; AppendedBytes=0 }
    $r32 = Invoke-Executor `
        -ComputerName "localhost" `
        -LocalBinaryPath "C:\Windows\System32\cmd.exe" `
        -RemoteDestPath "C:\Windows\Temp\quickair_sfx_t32_$(Get-Random).exe" `
        -Arguments "/C exit 0" `
        -AliveCheckSeconds 1 `
        -BinaryTypeOverride $mockBT32

    $t32Details = @()
    if ($r32.FinalState -ne "SFX_LAUNCHED") {
        $t32Details += "Expected FinalState=SFX_LAUNCHED, got $($r32.FinalState). Error=$($r32.Error)"
    }
    $hasAlive = @($r32.States | Where-Object { $_.State -eq "ALIVE" })
    if ($hasAlive.Count -gt 0) {
        $t32Details += "States[] should not contain ALIVE state"
    }
    if (-not $r32.BinaryType -or $r32.BinaryType.IsSFX -ne $true) {
        $t32Details += "BinaryType.IsSFX should be true in result"
    }
    if ($t32Details.Count -eq 0) {
        Add-R "T32" $true "SFX exit code 0: FinalState=SFX_LAUNCHED, no ALIVE state, BinaryType.IsSFX=true"
    } else {
        Add-R "T32" $false "SFX exit code 0 flow failed" $t32Details
    }

    # Cleanup: kill any launched process AND remove temp file
    if ($r32.PID) {
        try { Stop-Process -Id $r32.PID -Force -ErrorAction SilentlyContinue } catch { }
    }
    if ($r32.RemoteDest -and (Test-Path -LiteralPath $r32.RemoteDest)) {
        Remove-Item -LiteralPath $r32.RemoteDest -Force -ErrorAction SilentlyContinue
    }
} catch {
    Add-R "T32" $false "T32 threw exception" @($_.Exception.Message)
}

# ---------------------------------------------------------------
# T33 -- SFX flow exit code non-zero: cmd.exe /C exit 1, IsSFX overridden
#        PASS: FinalState=LAUNCH_FAILED
#        PASS: detail contains exit code value
# ---------------------------------------------------------------
try {
    Import-Module $winrmMod -Force -ErrorAction Stop

    $mockBT33 = [PSCustomObject]@{ IsSFX=$true; SFXType='ZIP'; DetectionMethod='Test'; FileSizeBytes=0; PESizeBytes=0; AppendedBytes=0 }
    $r33 = Invoke-Executor `
        -ComputerName "localhost" `
        -LocalBinaryPath "C:\Windows\System32\cmd.exe" `
        -RemoteDestPath "C:\Windows\Temp\quickair_sfx_t33_$(Get-Random).exe" `
        -Arguments "/C exit 1" `
        -AliveCheckSeconds 1 `
        -BinaryTypeOverride $mockBT33

    $t33Details = @()
    # After execution layer hardening, CLEANUP or CLEANUP_FAILED follows LAUNCH_FAILED
    $validFinal = @('LAUNCH_FAILED','CLEANUP','CLEANUP_FAILED')
    if ($r33.FinalState -notin $validFinal) {
        $t33Details += "Expected FinalState in ($($validFinal -join ',')), got $($r33.FinalState). Error=$($r33.Error)"
    }
    $failState = @($r33.States | Where-Object { $_.State -eq "LAUNCH_FAILED" }) | Select-Object -First 1
    if (-not $failState -or $failState.Detail -notmatch '1') {
        $t33Details += "LAUNCH_FAILED detail should contain exit code 1. Detail=$($failState.Detail)"
    }
    if ($t33Details.Count -eq 0) {
        Add-R "T33" $true "SFX exit code 1: FinalState=$($r33.FinalState), LAUNCH_FAILED state present with exit code"
    } else {
        Add-R "T33" $false "SFX exit code non-zero flow failed" $t33Details
    }

    # Cleanup: kill any launched process AND remove temp file
    if ($r33.PID) {
        try { Stop-Process -Id $r33.PID -Force -ErrorAction SilentlyContinue } catch { }
    }
    if ($r33.RemoteDest -and (Test-Path -LiteralPath $r33.RemoteDest)) {
        Remove-Item -LiteralPath $r33.RemoteDest -Force -ErrorAction SilentlyContinue
    }
} catch {
    Add-R "T33" $false "T33 threw exception" @($_.Exception.Message)
}

# ---------------------------------------------------------------
# T34 -- SMBWMI.psm1 imports cleanly, exports Invoke-Executor
# ---------------------------------------------------------------
try {
    if (-not (Test-Path $smbwmiMod)) { throw "File not found: $smbwmiMod" }
    Import-Module $smbwmiMod -Force -ErrorAction Stop
    $cmd = Get-Command Invoke-Executor -ErrorAction Stop
    if ($null -ne $cmd) {
        Add-R "T34" $true "SMBWMI.psm1 imports cleanly and exports Invoke-Executor"
    } else {
        Add-R "T34" $false "SMBWMI.psm1 imported but Invoke-Executor not found" @()
    }
} catch {
    Add-R "T34" $false "SMBWMI.psm1 import failed" @($_.Exception.Message)
}

# ---------------------------------------------------------------
# T35 -- SMB unreachable IP returns CONNECTION_FAILED, no exception
# ---------------------------------------------------------------
try {
    Import-Module $smbwmiMod -Force -ErrorAction Stop
    $t35Start = Get-Date
    $r35 = Invoke-Executor `
        -ComputerName "192.0.2.1" `
        -LocalBinaryPath "C:\Windows\System32\notepad.exe" `
        -RemoteDestPath "C:\Windows\Temp\notepad.exe" `
        -AliveCheckSeconds 1
    $t35Elapsed = [int]((Get-Date) - $t35Start).TotalSeconds

    $t35Details = @()
    if ($r35.FinalState -ne "CONNECTION_FAILED") {
        $t35Details += "Expected FinalState=CONNECTION_FAILED, got $($r35.FinalState)"
    }
    if ($r35.Method -ne "SMB+WMI") {
        $t35Details += "Expected Method=SMB+WMI, got $($r35.Method)"
    }
    $hasSMB = ($r35.States | Where-Object { $_.Detail -match 'SMB' })
    if (-not $hasSMB) {
        $t35Details += "No state detail containing 'SMB'. Details: $($r35.States | ForEach-Object { $_.Detail })"
    }
    if ($t35Elapsed -gt 35) {
        $t35Details += "Elapsed ${t35Elapsed}s exceeds 35s limit"
    }
    if ($t35Details.Count -eq 0) {
        Add-R "T35" $true "SMB unreachable returned CONNECTION_FAILED in ${t35Elapsed}s"
    } else {
        Add-R "T35" $false "SMB unreachable test failed" $t35Details
    }
} catch {
    Add-R "T35" $false "T35 threw exception" @($_.Exception.Message)
}

# ---------------------------------------------------------------
# T36 -- SMBWMI localhost smoke test (cmd.exe /c ping)
#        WMI launches in session 0 (no desktop) so we use cmd.exe
#        with a long ping to keep it alive for the alive check.
#        Verify Method=SMB+WMI, TRANSFERRED+SHA256, reaches ALIVE.
# ---------------------------------------------------------------
$t36TempFile = "C:\Windows\Temp\quickair_test_smbwmi_$(Get-Random).exe"
$t36PID      = $null

try {
    Import-Module $smbwmiMod -Force -ErrorAction Stop

    $r36 = Invoke-Executor `
        -ComputerName "localhost" `
        -LocalBinaryPath "C:\Windows\System32\cmd.exe" `
        -RemoteDestPath $t36TempFile `
        -Arguments "/c ping 127.0.0.1 -n 60" `
        -AliveCheckSeconds 3

    $t36Details = @()

    if ($r36.Method -ne "SMB+WMI") {
        $t36Details += "Expected Method=SMB+WMI, got $($r36.Method)"
    }

    # Should have TRANSFERRED state
    $hasTransferred = @($r36.States | Where-Object { $_.State -eq "TRANSFERRED" })
    if ($hasTransferred.Count -eq 0) {
        $t36Details += "Missing TRANSFERRED state"
    }

    # Should have SHA256 in transfer detail
    $hasSHA = ($r36.States | Where-Object { $_.Detail -match 'SHA256' })
    if (-not $hasSHA) {
        $t36Details += "No SHA256 in transfer detail"
    }

    # Should reach ALIVE
    if ($r36.FinalState -ne "ALIVE") {
        $t36Details += "Expected FinalState=ALIVE, got $($r36.FinalState). Error=$($r36.Error)"
    }

    $t36PID = $r36.PID

    if ($t36Details.Count -eq 0) {
        Add-R "T36" $true "SMBWMI localhost smoke test passed (FinalState=$($r36.FinalState) PID=$t36PID)"
    } else {
        Add-R "T36" $false "SMBWMI localhost smoke test failed ($($t36Details.Count) issues)" $t36Details
    }
} catch {
    Add-R "T36" $false "T36 threw exception" @($_.Exception.Message)
} finally {
    if ($t36PID) {
        try { Stop-Process -Id $t36PID -Force -ErrorAction SilentlyContinue } catch { }
    }
    if (Test-Path -LiteralPath $t36TempFile) {
        Remove-Item -LiteralPath $t36TempFile -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------
# T37 -- Auto both methods fail: combined error detail
#        Use unreachable IP so both WinRM and SMB+WMI fail.
#        Verify FinalState=CONNECTION_FAILED and Error contains
#        both "WinRM" and "SMB+WMI" error messages.
# ---------------------------------------------------------------
$t37OutDir = $null
try {
    # Invoke the actual Executor.ps1 with -Method Auto against unreachable IP.
    # Pass dummy credential to avoid interactive prompt.
    $executorPs1 = Join-Path $repoDir "Executor.ps1"
    $t37OutDir   = Join-Path $env:TEMP "quickair_t37_$(Get-Random)"
    $t37Cred     = New-Object System.Management.Automation.PSCredential(
        "test", (ConvertTo-SecureString "test" -AsPlainText -Force))

    $t37Start = Get-Date
    & $executorPs1 -Target "192.0.2.1" `
        -LocalBinaryPath "C:\Windows\System32\notepad.exe" `
        -RemoteDestPath "C:\Windows\Temp\notepad.exe" `
        -Method "Auto" `
        -AliveCheck 1 `
        -Credential $t37Cred `
        -OutputPath $t37OutDir 2>&1 | Out-Null
    $t37Elapsed = [int]((Get-Date) - $t37Start).TotalSeconds

    $t37Details = @()

    $t37Json = Get-ChildItem $t37OutDir -Filter "*.json" -ErrorAction SilentlyContinue |
               Select-Object -First 1
    if (-not $t37Json) {
        $t37Details += "No JSON output file found in $t37OutDir"
    } else {
        $t37Data = Get-Content $t37Json.FullName -Raw | ConvertFrom-Json
        if ($t37Data.FinalState -ne "CONNECTION_FAILED") {
            $t37Details += "Expected FinalState=CONNECTION_FAILED, got $($t37Data.FinalState)"
        }
        if ($t37Data.Error -notmatch 'WinRM') {
            $t37Details += "Error should mention WinRM: $($t37Data.Error)"
        }
        if ($t37Data.Error -notmatch 'SMB\+WMI') {
            $t37Details += "Error should mention SMB+WMI: $($t37Data.Error)"
        }
    }

    if ($t37Details.Count -eq 0) {
        Add-R "T37" $true "Auto both-fail via Executor.ps1: combined error in JSON (${t37Elapsed}s)"
    } else {
        Add-R "T37" $false "Auto both-fail test failed" $t37Details
    }
} catch {
    Add-R "T37" $false "T37 threw exception" @($_.Exception.Message)
} finally {
    if ($t37OutDir -and (Test-Path $t37OutDir)) {
        Remove-Item $t37OutDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------
# T38 -- WMI-only localhost smoke test
#        Launch cmd.exe /c ping via WMI on localhost.
#        Binary already exists (WMI skips transfer).
#        Verify: Method=WMI, TRANSFERRED state says "Skipped",
#        reaches ALIVE or ALIVE_ASSUMED state.
# ---------------------------------------------------------------
$t38PID = $null
try {
    Import-Module $wmiMod -Force -ErrorAction Stop

    $r38 = Invoke-Executor `
        -ComputerName "localhost" `
        -LocalBinaryPath "C:\Windows\System32\cmd.exe" `
        -RemoteDestPath "C:\Windows\System32\cmd.exe" `
        -Arguments "/c ping 127.0.0.1 -n 60" `
        -AliveCheckSeconds 3

    $t38Details = @()

    if ($r38.Method -ne "WMI") {
        $t38Details += "Expected Method=WMI, got $($r38.Method)"
    }

    $hasSkipped = @($r38.States | Where-Object {
        $_.State -eq "TRANSFER_SKIPPED" -or ($_.State -eq "TRANSFERRED" -and $_.Detail -match 'Skipped')
    })
    if ($hasSkipped.Count -eq 0) {
        $t38Details += "Missing TRANSFER_SKIPPED or TRANSFERRED/Skipped state"
    }

    if ($r38.FinalState -ne "ALIVE" -and $r38.FinalState -ne "ALIVE_ASSUMED") {
        $t38Details += "Expected FinalState ALIVE or ALIVE_ASSUMED, got $($r38.FinalState). Error=$($r38.Error)"
    }

    $t38PID = $r38.PID

    if ($t38Details.Count -eq 0) {
        Add-R "T38" $true "WMI localhost smoke test passed (FinalState=$($r38.FinalState) PID=$t38PID)"
    } else {
        Add-R "T38" $false "WMI localhost smoke test failed ($($t38Details.Count) issues)" $t38Details
    }
} catch {
    Add-R "T38" $false "T38 threw exception" @($_.Exception.Message)
} finally {
    if ($t38PID) {
        try { Stop-Process -Id $t38PID -Force -ErrorAction SilentlyContinue } catch { }
    }
}

return @{
    Passed = $script:passResults
    Failed = $script:failResults
    Info   = $script:infoResults
}
