# Coding Conventions

**Analysis Date:** 2026-03-24

## Naming Patterns

**Files:**
- PowerShell scripts: PascalCase with `.ps1` extension (e.g., `Collector.ps1`, `QuickAiRLaunch.ps1`)
- PowerShell modules: PascalCase with `.psm1` extension (e.g., `Connection.psm1`, `Output.psm1`)
- Test files: `T##_<Description>.ps1` format with zero-padded number (e.g., `T01_Processes.ps1`, `T02_Network.ps1`)
- JavaScript files: number-prefixed with descriptive names (e.g., `03_core.js`, `05_processes.js`)

**Functions:**
- PowerShell: PascalCase (e.g., `Invoke-Collector`, `Get-TargetCaps`, `ConvertFrom-TcpStateInt`, `Write-Log`)
- PowerShell private helpers: prefix with underscore (e.g., `_sha256`, `_applyGridTemplate`)
- JavaScript: camelCase (e.g., `sortTable`, `applySortToRows`, `handleFiles`, `loadJsonFile`, `switchHost`)

**Variables:**
- PowerShell: camelCase for locals (e.g., `$outputPath`, `$maxRetry`, `$collErr`, `$netTcp`)
- PowerShell: CONSTANT_CASE for script-scope constants (e.g., `$COLLECTOR_VERSION`, `$MAX_RETRY`, `$OP_TIMEOUT_SEC`)
- PowerShell script-scope variables: `$script:varName` (e.g., `$script:LogFile`, `$script:OP_TIMEOUT_SEC`, `$script:passResults`)
- JavaScript: const for objects/state, then camelCase for properties (e.g., `const state = { hosts: {}, activeHost: null }`)
- JavaScript module-level state: CONSTANT_CASE (e.g., `const ANALYZER_VERSION = "3.6"`)

**Types/Objects:**
- PowerShell: hashtables with ordered construction for manifests (e.g., `[ordered]@{ hostname = ...; collection_time_utc = ... }`)
- PowerShell PSCustomObject: inline `New-Object PSObject -Property @{ ... }`
- JSON field names: snake_case (e.g., `collection_time_utc`, `target_ps_version`, `CreationDate`)

## Code Style

**Formatting:**
- PowerShell: No external formatter configured, follows consistent indentation with 4-space tabs
- No prettierrc or eslint config files—conventions are manual
- Multi-line parameter blocks use aligned parentheses:
  ```powershell
  param(
      [Parameter(Mandatory=$true)]
      [string[]]$Targets,
      [Parameter(Mandatory=$false)]
      [string]$OutputPath = ""
  )
  ```
- Hash tables aligned with line continuation:
  ```powershell
  $obj = [PSCustomObject]@{
      Id=$id
      Pass=$pass
      Summary=$summary
  }
  ```

**Linting:**
- No external linting tool—manual review
- `Set-StrictMode -Off` used globally across scripts (pragmatic choice for PS 2.0 compatibility)
- `$ErrorActionPreference = 'Continue'` used for fail-safe error recovery

**Comments:**
- Block headers in ASCII box format for major script sections:
  ```
  # ╔══════════════════════════════════════╗
  # ║  QuickAiR — Collector.ps1            ║
  # ║  Thin orchestrator...               ║
  # ╚══════════════════════════════════════╝
  ```
- Inline comments for complex logic (e.g., `# SHA256 verification`)
- Region markers: `#region --- Comment ---` and `#endregion` for logical grouping
- No `-` prefix in region names; use `--- Comment ---` format

**JSDoc/Comments:**
- PowerShell: Header comment blocks with Exports, Inputs, Output, Depends metadata
- JavaScript: Single-line headers with function signatures and version info
- Test files: Comment headers explain test ID (T1–T12) and purpose

## Import Organization

**PowerShell Module Loading Order:**
1. Built-in assemblies (`Add-Type`)
2. Core modules from `Modules\Core\`:
   - `DateTime.psm1` (UTC normalization)
   - `Connection.psm1` (WinRM, capability probe)
   - `Output.psm1` (logging, JSON write)
3. Collector modules from `Modules\Collectors\` (auto-discovered at runtime)
4. Executor modules from `Modules\Executors\` (loaded as needed)

**Pattern:**
```powershell
Import-Module "$PSScriptRoot\Modules\Core\DateTime.psm1"   -Force
Import-Module "$PSScriptRoot\Modules\Core\Connection.psm1" -Force
```

**JavaScript Inline Assembly:**
- Scripts are concatenated into HTML template in order: `01_head.html` → `02_shell.html` → `03_core.js` → `04_fleet.js` → `05_processes.js` → ... → `10_close.html`
- State object initialized in `03_core.js` before dependent scripts run
- No module system; global function namespace with naming conventions to avoid collision

## Error Handling

**Patterns:**
- Try-catch blocks with `Write-Log 'WARN'` or `Write-Log 'ERROR'` followed by context string
- Exception messages captured: `$_.Exception.Message`
- Graceful degradation: if CIM fails, fall back to WMI; if WMI fails, fall back to netstat
- No throw unless catastrophic; most errors logged and collection continues

**Example from Collector.ps1:**
```powershell
try {
    $result = & $collector.FullName -Session $sess -TargetPSVersion $caps.PSVersion -TargetCapabilities $caps
    $collData.Add($collector.BaseName, $result)
} catch {
    Write-Log 'WARN' "Collector $($collector.BaseName) failed: $($_.Exception.Message)"
    $collErr += $collector.BaseName
}
```

**Test Framework Pattern from T01_Processes.ps1:**
```powershell
function Add-R {
    param([string]$Id, [bool]$Pass, [string]$Summary, [string[]]$Details=@(), [bool]$IsInfo=$false)
    $obj = [PSCustomObject]@{Id=$Id;Pass=$Pass;InfoOnly=$IsInfo;Summary=$Summary;Details=$Details}
    if ($IsInfo)       { $script:infoResults  += $obj }
    elseif ($Pass)     { $script:passResults  += $obj }
    else               { $script:failResults  += $obj }
}
```

## Logging

**Framework:** `Write-Log` function from `Modules\Core\Output.psm1`

**Levels:** INFO, WARN, ERROR

**Usage:**
```powershell
Write-Log 'INFO' "Collection start | target=$target"
Write-Log 'WARN' "Could not update TrustedHosts: $($_.Exception.Message)"
Write-Log 'ERROR' "All $MAX_RETRY probe attempts failed"
```

**Output to Host:**
- `Write-Host` for user-facing messages (colored: Green, Red, Yellow, Cyan)
- `Write-Log` writes to file and optionally to console based on `-Quiet` flag

**Example:**
```powershell
Write-Host "  Output      : $($written.Path)"  -ForegroundColor Green
Write-Log 'INFO' "Output: $($written.Path) | SHA256: $($written.Hash)"
```

## Function Design

**Size:** Functions typically 20–60 lines; complex collectors split into nested scriptblocks for PS 2.0 remote execution

**Parameters:**
- Always use `param()` block at start of function
- Named parameters with `[Parameter()]` attributes for public functions
- Splatting used for complex parameter passing (e.g., `$spArgs = @{ ComputerName = $Target }; New-PSSession @spArgs`)

**Return Values:**
- Functions return PSCustomObject or hashtable with predictable schema
- Collector functions return: `@{ data=...; source=...; errors=[] }`
- Test functions return: `@{ Passed=@(); Failed=@(); Info=@() }`

**Example Function Header:**
```powershell
function Get-TargetCaps {
    param([string]$Target, [System.Management.Automation.PSCredential]$Cred)

    $c = @{
        PSVersion             = 0
        OSVersion             = ''
        HasCIM                = $false
        # ... more fields
    }
    # ... logic
    return $c
}
```

## Module Design

**Module Exports:**
- Use `Export-ModuleMember -Function <names>` at end of `.psm1` file
- Example from `DateTime.psm1`:
  ```powershell
  Export-ModuleMember -Function ConvertTo-UtcIso
  ```
- Collector modules export single `Invoke-Collector` function
- Private scriptblocks declared as `$script:CONST_SB_NAME = { ... }`

**Scriptblock Variables:**
- PS 2.0-compatible payloads stored as scriptblocks (e.g., `$script:PROC_SB_WMI`, `$script:NET_SB_CIM`)
- Passed to remote session via `Invoke-Command -ScriptBlock`
- Cannot reference outer scope; all data passed via parameters

**Module Structure:**
```powershell
#Requires -Version 5.1
# [Header box comment with metadata]
Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# Script-scope constants
$script:OP_TIMEOUT_SEC = 60

# [Public functions]

# [Private helpers or scriptblocks]
$script:PROC_SB_WMI = { ... }

Export-ModuleMember -Function Invoke-Collector
```

## Test File Conventions

**Test Naming:** `T##_<Name>.ps1` where ## is zero-padded number (01–12)

**Test Structure:**
1. File header with metadata box
2. `param()` block accepting `-JsonPath`, `-HtmlPath`, and optional test-specific params
3. Initialize `$script:passResults`, `$script:failResults`, `$script:infoResults` arrays
4. Define `Add-R` helper function to categorize results
5. Load JSON: `[System.IO.File]::ReadAllText($JsonPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json`
6. Run test logic and call `Add-R` to record results
7. Return: `@{ Passed=$script:passResults; Failed=$script:failResults; Info=$script:infoResults }`

**Result Object Schema:**
```powershell
@{
    Id        = "T1"              # Test identifier
    Pass      = $true|$false      # Test passed
    InfoOnly  = $true|$false      # Informational only
    Summary   = "Description"     # One-line result
    Details   = @("line1", ...)   # Details array
}
```

## JSON Output Schema

**Manifest Fields (ordered):**
- `hostname`, `collection_time_utc`, `collector_version`, `analyst_os`, `target_ps_version`
- `osversion`, `osbuild`, `oscaption`, `isservercore`, `timezone_offset_minutes`
- Data sources (e.g., `Processes_source`, `Network_source`)
- `sha256` (computed last, then embedded)

**Data Format:**
- Dates: ISO 8601 UTC format `yyyy-MM-ddTHH:mm:ssZ`
- Snake_case field names in JSON output
- Nested objects: `Network: { tcp: [...], dns: [...], adapters: [...] }`

---

*Convention analysis: 2026-03-24*
