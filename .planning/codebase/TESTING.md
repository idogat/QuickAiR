# Testing Patterns

**Analysis Date:** 2026-03-24

## Test Framework

**Runner:**
- PowerShell Test Suite (`TestSuite.ps1`)
- No external test framework (xUnit, Pester); custom built
- Runs all tests in `Tests\` directory via auto-discovery
- Tests are `.ps1` scripts, not Pester tests

**Test Discovery:**
```powershell
$tests = Get-ChildItem "$scriptDir\Tests\T*.ps1" | Sort-Object Name
foreach ($t in $tests) {
    $result = & $t.FullName @tArgs
}
```

**Run Commands:**
```bash
.\TestSuite.ps1                           # Run all tests against latest JSON
.\TestSuite.ps1 -JsonPath <path>          # Test specific JSON file
.\TestSuite.ps1 -HtmlPath <path>          # Test specific HTML file
.\TestSuite.ps1 -T3Threshold 0.05         # Allow 5% miss rate for T3 (network)
.\TestSuite.ps1 -DcMode                   # Enable DC-specific sanity checks
```

## Test File Organization

**Location:**
- Tests stored in `Tests\` directory at repo root
- Each test is standalone `.ps1` script

**Naming:**
- Format: `T##_<Description>.ps1` where ## is zero-padded number
- Current tests: T01–T11 (T01_Processes, T02_Network, T03_Manifest, T04_HTML, T05_MultiNIC, T06_DLLs, T07_Signatures, T08_Users, T09_Executor, T10_Launcher)

**Directory Structure:**
```
Tests/
├── T01_Processes.ps1       # Process completeness and field validation
├── T02_Network.ps1         # Network connections, DNS, process assignment
├── T03_Manifest.ps1        # JSON integrity, SHA256 verification
├── T04_HTML.ps1            # HTML sanity, field coverage
├── T05_MultiNIC.ps1        # Multi-NIC adapter mapping
├── T06_DLLs.ps1            # DLL and signature validation
├── T07_Signatures.ps1      # File signature verification
├── T08_Users.ps1           # User and group enumeration
├── T09_Executor.ps1        # Executor.ps1 execution results
└── T10_Launcher.ps1        # QuickAiRLaunch.ps1 execution tracking
```

## Test Structure

**Suite Organization:**

Each test file has this structure:

```powershell
#Requires -Version 5.1
# ╔══════════════════════════════════════╗
# ║  QuickAiR — T##_<Name>.ps1          ║
# ║  What this test does                ║
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

# Initialize result arrays (script-scope)
$script:passResults = @()
$script:failResults = @()
$script:infoResults = @()

# Result helper function
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

# Extract needed fields
$manifest = $data.manifest
$procs    = @($data.Processes)

# Test logic (one or more T## blocks)
# Each test calls Add-R with results

# Return result object
@{
    Passed = $script:passResults
    Failed = $script:failResults
    Info   = $script:infoResults
}
```

**Patterns:**

From `T01_Processes.ps1`:
- Load JSON with UTF-8 encoding: `[System.IO.File]::ReadAllText($JsonPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json`
- Extract manifest and data: `$manifest = $data.manifest; $procs = @($data.Processes)`
- Conditional logic for localhost-only tests: `if (-not $isLocalJson) { Add-R "T1" $true "... (SKIP - remote host)" @() $true }`
- Collect missing items into arrays: `$t1Missing = @(); foreach (...) { if (condition) { $t1Missing += "message" } }`
- Report pass/fail with counts: `Add-R "T1" $true "Process completeness ($count/$total)"`
- Report failures with details: `Add-R "T1" $false "Process completeness failed" $t1Missing`

## Mocking

**Not Used:**
- No mocking framework used (Pester Mock not used)
- Tests run against actual data: collected JSON files and generated HTML reports
- Each test is deterministic given the input files

**Test Data:**
- Input: JSON files from `DFIROutput\` directory (format: `<hostname>_<timestamp>.json`)
- Input: HTML report file (`Report.html`)
- Data structure expected: See Test Inputs section below

## Fixtures and Factories

**Test Data:**
- Real execution results stored in `ExecutionResults\` and `DFIROutput\` directories
- Format: JSON output from Collector.ps1, structured as:
  ```json
  {
    "manifest": { "hostname": "...", "collection_time_utc": "...", ... },
    "Processes": [ { "ProcessId": 1234, "Name": "process.exe", ... }, ... ],
    "Network": { "tcp": [...], "dns": [...] }
  }
  ```

**Location:**
- `DFIROutput\` contains collected JSON per host
- `ExecutionResults\` contains executor result files (format: `<hostname>_execution_<timestamp>.json`)

**Test Data Loading:**
```powershell
if (-not $JsonPath) {
    $outputDir = Join-Path $scriptDir "DFIROutput"
    $latest = Get-ChildItem -Path $outputDir -Recurse -Filter "*.json" |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $JsonPath = $latest.FullName
}
```

## Coverage

**Requirements:** None enforced programmatically

**Test Coverage by Area:**
- **Processes (T1–T2):** Completeness (localhost only), field validation, .NET cross-check
- **Network (T3–T7):** Connection completeness (with configurable threshold), process assignment, DNS correlation, reverse DNS
- **Manifest (T8–T9):** SHA256 integrity, collection time format, PS version, source validation, error log audit
- **HTML (T10–T11):** File size, no external resources, structural markers, required fields
- **Multi-NIC (T12):** Adapter enumeration, InterfaceAlias assignment
- **DLLs (T6):** DLL enumeration and signature validation
- **Signatures (T7):** File signature verification and validation
- **Users (T8):** User and group enumeration
- **Executor (T9):** Remote execution results parsing
- **Launcher (T10):** Job queue and execution tracking

## Test Types

**Unit Tests:**
- Not used; all tests are integration/validation tests
- No isolated function testing

**Integration Tests:**
- Tests validate complete flow: collection → JSON output → HTML report generation
- Example: T1 runs collection on localhost, then validates JSON contains all processes

**Validation Tests:**
- T1–T11 validate data integrity, completeness, format compliance
- Example: T3 validates that JSON network connections match live `netstat` output
- Example: T8 verifies SHA256 hash matches JSON content

**Sanity Checks:**
- DC-mode checks: when `-DcMode` flag passed, extra validation for Domain Controller-specific requirements
  - Required ports: 53 (DNS), 88 (Kerberos), 389 (LDAP)
  - Required processes: lsass.exe, dns.exe or ntds.exe
- Example from TestSuite.ps1:
  ```powershell
  if ($DcMode) {
      $dcPorts = @(53, 88, 135, 389, 445, 636, 3268, 3269)
      foreach ($port in $dcPorts) {
          if ($jsonPorts -notcontains $port) { $dcWarn += "WARN: DC port $port absent" }
      }
  }
  ```

## Common Patterns

**Async Testing:**
- Not applicable; all tests are synchronous PowerShell scripts
- Remote collection uses WinRM sessions, but test suite waits for JSON output before running

**Error Testing:**
```powershell
# From T03_Manifest.ps1 - SHA256 verification with fallback formats
$hashVerified = $false
foreach ($nullFmt in @('  null', ' null', 'null')) {
    $reconstructed = $jsonRaw -replace ('"sha256":\s*"[^"]*"'), ('"sha256":' + $nullFmt)
    $bytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
        [System.Text.Encoding]::UTF8.GetBytes($reconstructed))
    $computed = ($bytes | ForEach-Object { $_.ToString('X2') }) -join ''
    if ($computed -ieq $storedHash) { $hashVerified = $true; break }
}
```

**Threshold-Based Testing:**
```powershell
# From T02_Network.ps1 - Allow miss rate for legacy network enumeration
$missRate = if ($total3 -gt 0) { $t3Missing.Count / $total3 } else { 0 }
$t3Pass   = ($t3Missing.Count -eq 0) -or ($T3Threshold -gt 0 -and $missRate -le $T3Threshold)
```

**Regex Validation:**
```powershell
# From T03_Manifest.ps1 - ISO 8601 date validation
if ($manifest.collection_time_utc -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') {
    $t8Fails += "collection_time_utc not valid ISO 8601: $($manifest.collection_time_utc)"
}
```

**Set-Based Completeness Testing:**
```powershell
# From T01_Processes.ps1 - Fast lookup for missing items
$collectedPidSet = @{}
foreach ($p in $procs) { $collectedPidSet[[int]$p.ProcessId] = $true }

$t1Missing = @()
foreach ($dp in $expectedProcs) {
    if (-not $collectedPidSet.ContainsKey([int]$dp.Id)) {
        $t1Missing += "PID=$($dp.Id) Name=$($dp.ProcessName)"
    }
}
```

## Output Format

**Test Result Schema:**
```powershell
@{
    Passed = @(
        [PSCustomObject]@{
            Id        = "T1"
            Pass      = $true
            InfoOnly  = $false
            Summary   = "Process completeness (42/43)"
            Details   = @()
        }
    )
    Failed = @(
        [PSCustomObject]@{
            Id        = "T2"
            Pass      = $false
            InfoOnly  = $false
            Summary   = "Process field validation (2 failures)"
            Details   = @(
                "ProcessId 1234: missing CreationDate"
                "ProcessId 5678: invalid WorkingSetSize"
            )
        }
    )
    Info = @(
        [PSCustomObject]@{
            Id        = "T1"
            Pass      = $false
            InfoOnly  = $true
            Summary   = "Collection errors found (3 warnings)"
            Details   = @("Warning 1", "Warning 2", "Warning 3")
        }
    )
}
```

**TestSuite.ps1 Console Output:**
```
[PASS] T1    - Process completeness (42/43)
[FAIL] T2    - Process field validation (2 failures)
       Process field 'CreationDate' missing
       ... (up to 25 details per test)
[INFO] T9    - Collection errors (3 warnings)
```

**Summary:**
```
Results: 11 total, 9 passed, 2 failed
DC Sanity: PASS (all required ports/processes present)
```

## Configuration

**TestSuite.ps1 Flags:**
- `-JsonPath <path>`: Override auto-detected JSON file
- `-HtmlPath <path>`: Override auto-detected Report.html location
- `-T3Threshold <float>`: Fractional miss rate allowed for network completeness test (e.g., 0.05 = 5% miss rate allowed, default 0)
- `-DcMode`: Enable Domain Controller-specific validation checks

**Example:**
```powershell
.\TestSuite.ps1 -JsonPath "DFIROutput\WIN-497ODI0A5CH\*.json" -T3Threshold 0.1 -DcMode
```

## Known Limitations

**Localhost-only Tests:**
- T1 (process completeness) skips for remote hosts (no way to enumerate expected processes on analyst machine)
- T3 (network completeness) skips for remote hosts (can't run netstat on analyst machine to compare)
- T5 (DNS completeness) skips for remote hosts
- Pattern: `if (-not $isLocalJson) { Add-R "T#" $true "... (SKIP - remote host)" @() $true }`

**Timing Artifacts:**
- T3/T5 may fail for localhost due to collection session itself creating network/DNS entries after JSON is written
- T7 may fail on legacy collectors where reverse DNS fix was not present

**PS 2.0 Compatibility:**
- Tests run on PS 5.1 on analyst machine
- Target systems may run PS 2.0+, but test framework always PS 5.1+
- Thresholds (e.g., T3Threshold) provided for legacy OS network enumeration

---

*Testing analysis: 2026-03-24*
