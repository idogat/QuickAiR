#Requires -Version 5.1
# =============================================
#   Quicker -- T09_Executor.ps1
#   T24 WinRM.psm1 imports + exports
#   T25 WMI.psm1 imports + exports
#   T26 Unreachable IP returns CONNECTION_FAILED
#   T27 Missing local binary returns CONNECTION_FAILED
#   T28 localhost notepad.exe smoke test
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

# ---------------------------------------------------------------
# T24 — WinRM.psm1 imports cleanly, exports Invoke-Executor
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
# T25 — WMI.psm1 imports cleanly, exports Invoke-Executor
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
# T26 — Invalid target returns CONNECTION_FAILED within 35s
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
# T27 — Missing local binary returns CONNECTION_FAILED with "not found"
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
# T28 — localhost notepad.exe smoke test via WinRM
# ---------------------------------------------------------------
$t28TempFile = "C:\Windows\Temp\quicker_test_notepad_$(Get-Random).exe"
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

    # StartTimeUTC ends in Z
    if ($r28.StartTimeUTC -and $r28.StartTimeUTC -notmatch 'Z$') {
        $t28Details += "StartTimeUTC does not end in Z: $($r28.StartTimeUTC)"
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

return @{
    Passed = $script:passResults
    Failed = $script:failResults
    Info   = $script:infoResults
}
