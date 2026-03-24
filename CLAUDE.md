# Quicker — DFIR Volatile Artifact Collector
https://github.com/idogat/quicker

## Structure
Entry points:
  Collector.ps1          — orchestrator, runs all collectors
  Executor.ps1           — remote tool execution orchestrator
  QuickerLaunch.ps1      — WinForms job manager (single-instance)
  Register-QuickerProtocol.ps1 — registers quicker:// URI handler
Core:
  Modules\Core\          — Connection, DateTime, Output
Collectors:
  Modules\Collectors\    — auto-discovered plugins (Processes, Network, Users, DLLs…)
Executors:
  Modules\Executors\     — WinRM.psm1, WMI.psm1
Launcher:
  Modules\Launcher\      — JobQueue.psm1, PipeListener.psm1
Report:
  Report.html            — single-file offline GUI (never edit directly)
  ReportStages\          — stage files: 01_head → 10_close (edit these)
  build_report.ps1       — concatenates stages into Report.html
Tests:
  TestSuite.ps1          — test runner (auto-discovers Tests\)
  Tests\                 — T01–T09 per-module test files
Runtime only:
  C:\DFIRLab\QuickerBridge\ — inter-process job handoff (not in repo)

## Plugin Contracts
- Collector: drop .psm1 in Modules\Collectors\, export Invoke-Collector — see any existing header
- Executor: export Invoke-Executor — auto chain: WinRM → SMB+WMI → FAILED
- Launcher: see JobQueue.psm1 and PipeListener.psm1 headers for exports and state machine
- New collector plugin = new .psm1 + matching Tests\T<n>_<name>.ps1
- Plugin failure: caught by orchestrator, logged to manifest.collection_errors, never aborts run

## Test Lab Targets (dev/test only)
- localhost              — PS 5.1, no credential
- 192.168.1.250          — domain member, 2 NICs
- 192.168.1.100          — domain DC, 2 NICs
- 192.168.1.236          — workgroup, Server 2008 R2, PS 2.0, 2 NICs
- Creds: administrator / Aa123456

## Production
All behavior detected at runtime — never hardcode targets, credentials, or OS assumptions.

## Rules
- Never prompt user — fully autonomous
- Never write to Windows Event Log
- No external network calls, no downloads, no external dependencies
- Read-only collection only
- Run as Administrator
- All datetimes UTC ISO 8601 everywhere — PS, JSON fields end in UTC/Z, HTML uses fmtUTC()
- UTC conversion: ToUniversalTime(), FromFileTimeUtc() — never local time, never FromFileTime()
- PS 2.0 compatible on all target-side code paths
- SID is primary cross-host user correlation key

## Report.html
- Never edit directly — edit ReportStages\ files, then run build_report.ps1
- New stages must sort before 10_close.html — verify build output after every change
- Screenshot with Playwright after build, then delete screenshot immediately

## Agent Efficiency
- Read file headers before full files — detail lives in headers not here
- Use str_replace for edits, never full rewrites
- One logical change at a time — verify before proceeding
- Never commit screenshots or unnecessary files

## Living Documents
CLAUDE.md:
- Update after every architectural change, file add/remove, or contract change
- Keep under 80 lines — trim if exceeded; never let it become stale
File headers:
- Update version, function list, dependencies, and description after every change
- A stale header is worse than no header
End of every task:
- Review CLAUDE.md and headers of every changed file — fix any drift
- Commit header updates with the task commit, never without

<!-- GSD:project-start source:PROJECT.md -->
## Project

**Quicker DFIR Toolkit — Production Documentation**

Production documentation suite for the Quicker DFIR toolkit — an operational runbook, artifact coverage matrix, and analyst interpretation guide. Written for a mixed team of junior and senior DFIR analysts who need both onboarding material and quick-reference resources for day-to-day incident response work.

**Core Value:** Analysts can pick up the toolkit and operate it correctly without tribal knowledge — from running collections through interpreting results in the report viewer.

### Constraints

- **Format**: Markdown files in docs/ folder — must render cleanly on GitHub and in local editors
- **Audience**: Mixed junior/senior analysts — avoid assuming deep tool familiarity but don't over-explain IR fundamentals
- **Accuracy**: All parameters, paths, and behaviors must match current codebase (not aspirational)
- **Air-gap**: Docs must not reference or require external URLs for core content
<!-- GSD:project-end -->

<!-- GSD:stack-start source:codebase/STACK.md -->
## Technology Stack

## Languages
- PowerShell 5.1 - All orchestration, collectors, and remote execution (analyst machine and entry points)
- PowerShell 2.0+ - Target-side collection code (backward compatibility for legacy Windows systems)
- JavaScript (Vanilla ES6) - Single-file offline HTML GUI with no external framework dependencies
- HTML5 / CSS3 - Report interface with dark theme styling
- Batch/CMD - Fallback netstat/ipconfig for PS 2.0-3 targets without modern cmdlets
## Runtime
- PowerShell 5.1 (analyst machine minimum, for Collector.ps1, Executor.ps1, QuickerLaunch.ps1)
- PowerShell 2.0-5.1 (target machines, auto-detected and adapted)
- Windows 10/11 and Windows Server 2008 R2+
- WinRM 1.0+ for remote collection
- .NET Framework 4.5+ (implied by PowerShell 5.1)
- No external package manager - All dependencies are built-in Windows APIs
- Lockfile: Not applicable
## Frameworks
- Windows Management Instrumentation (WMI) - Process, network, user enumeration
- Common Information Model (CIM) - Modern WMI replacement for PS 3.0+
- WinRM (Windows Remote Management) - Remote PowerShell session management via PSSession
- Windows Forms (System.Windows.Forms) - GUI for QuickerLaunch.ps1 job manager
- System.Drawing - Color and graphics for WinForms UI
- Custom Pester-compatible test runner (`TestSuite.ps1`) - 11 automated checks for data completeness and integrity
- No external test framework dependency
- PowerShell script-based build: `build_report.ps1` - Concatenates ReportStages/*.html and *.js files into Report.html
- No external build tool required
## Key Dependencies
- Windows APIs (built-in):
- No external infrastructure dependencies
- No cloud SDK integrations
- No CDN or external asset dependencies
- No package repositories (npm, NuGet, PyPI) required
## Configuration
- Manual credential entry via `Get-Credential` prompt (no env vars stored)
- Target discovery via hostname/IP with WinRM port 5985
- Output path configurable via `-OutputPath` parameter (default: `.\DFIROutput\`)
- No environment variables required for operation
- Tool manifest via `C:\DFIRLab\tools` directory scanning
- `build_report.ps1`: Reads ordered ReportStages/*.html and *.js files, concatenates into Report.html
- Version numbers in file headers (3.39 for HTML/JS core, 1.8 for Executor, 2.2 for Collector)
- No build configuration files (.json, .yaml, .xml)
## Platform Requirements
- Windows 11/Server 2022 (tested analyst environment)
- PowerShell 5.1
- Administrator privileges for collector execution
- WinRM enabled for remote targets (via `winrm quickconfig` or group policy)
- Target: Windows 10/11, Server 2008 R2 through 2022
- Analyzer: Any modern browser (HTML/JS fully offline, no server required)
- Deployment: Single directory with no installation; all binaries portable
- No external network access required (fully air-gappable)
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->
## Conventions

## Naming Patterns
- PowerShell scripts: PascalCase with `.ps1` extension (e.g., `Collector.ps1`, `QuickerLaunch.ps1`)
- PowerShell modules: PascalCase with `.psm1` extension (e.g., `Connection.psm1`, `Output.psm1`)
- Test files: `T##_<Description>.ps1` format with zero-padded number (e.g., `T01_Processes.ps1`, `T02_Network.ps1`)
- JavaScript files: number-prefixed with descriptive names (e.g., `03_core.js`, `05_processes.js`)
- PowerShell: PascalCase (e.g., `Invoke-Collector`, `Get-TargetCaps`, `ConvertFrom-TcpStateInt`, `Write-Log`)
- PowerShell private helpers: prefix with underscore (e.g., `_sha256`, `_applyGridTemplate`)
- JavaScript: camelCase (e.g., `sortTable`, `applySortToRows`, `handleFiles`, `loadJsonFile`, `switchHost`)
- PowerShell: camelCase for locals (e.g., `$outputPath`, `$maxRetry`, `$collErr`, `$netTcp`)
- PowerShell: CONSTANT_CASE for script-scope constants (e.g., `$COLLECTOR_VERSION`, `$MAX_RETRY`, `$OP_TIMEOUT_SEC`)
- PowerShell script-scope variables: `$script:varName` (e.g., `$script:LogFile`, `$script:OP_TIMEOUT_SEC`, `$script:passResults`)
- JavaScript: const for objects/state, then camelCase for properties (e.g., `const state = { hosts: {}, activeHost: null }`)
- JavaScript module-level state: CONSTANT_CASE (e.g., `const ANALYZER_VERSION = "3.6"`)
- PowerShell: hashtables with ordered construction for manifests (e.g., `[ordered]@{ hostname = ...; collection_time_utc = ... }`)
- PowerShell PSCustomObject: inline `New-Object PSObject -Property @{ ... }`
- JSON field names: snake_case (e.g., `collection_time_utc`, `target_ps_version`, `CreationDate`)
## Code Style
- PowerShell: No external formatter configured, follows consistent indentation with 4-space tabs
- No prettierrc or eslint config files—conventions are manual
- Multi-line parameter blocks use aligned parentheses:
- Hash tables aligned with line continuation:
- No external linting tool—manual review
- `Set-StrictMode -Off` used globally across scripts (pragmatic choice for PS 2.0 compatibility)
- `$ErrorActionPreference = 'Continue'` used for fail-safe error recovery
- Block headers in ASCII box format for major script sections:
- Inline comments for complex logic (e.g., `# SHA256 verification`)
- Region markers: `#region --- Comment ---` and `#endregion` for logical grouping
- No `-` prefix in region names; use `--- Comment ---` format
- PowerShell: Header comment blocks with Exports, Inputs, Output, Depends metadata
- JavaScript: Single-line headers with function signatures and version info
- Test files: Comment headers explain test ID (T1–T12) and purpose
## Import Organization
- Scripts are concatenated into HTML template in order: `01_head.html` → `02_shell.html` → `03_core.js` → `04_fleet.js` → `05_processes.js` → ... → `10_close.html`
- State object initialized in `03_core.js` before dependent scripts run
- No module system; global function namespace with naming conventions to avoid collision
## Error Handling
- Try-catch blocks with `Write-Log 'WARN'` or `Write-Log 'ERROR'` followed by context string
- Exception messages captured: `$_.Exception.Message`
- Graceful degradation: if CIM fails, fall back to WMI; if WMI fails, fall back to netstat
- No throw unless catastrophic; most errors logged and collection continues
## Logging
- `Write-Host` for user-facing messages (colored: Green, Red, Yellow, Cyan)
- `Write-Log` writes to file and optionally to console based on `-Quiet` flag
## Function Design
- Always use `param()` block at start of function
- Named parameters with `[Parameter()]` attributes for public functions
- Splatting used for complex parameter passing (e.g., `$spArgs = @{ ComputerName = $Target }; New-PSSession @spArgs`)
- Functions return PSCustomObject or hashtable with predictable schema
- Collector functions return: `@{ data=...; source=...; errors=[] }`
- Test functions return: `@{ Passed=@(); Failed=@(); Info=@() }`
## Module Design
- Use `Export-ModuleMember -Function <names>` at end of `.psm1` file
- Example from `DateTime.psm1`:
- Collector modules export single `Invoke-Collector` function
- Private scriptblocks declared as `$script:CONST_SB_NAME = { ... }`
- PS 2.0-compatible payloads stored as scriptblocks (e.g., `$script:PROC_SB_WMI`, `$script:NET_SB_CIM`)
- Passed to remote session via `Invoke-Command -ScriptBlock`
- Cannot reference outer scope; all data passed via parameters
#Requires -Version 5.1
## Test File Conventions
## JSON Output Schema
- `hostname`, `collection_time_utc`, `collector_version`, `analyst_os`, `target_ps_version`
- `osversion`, `osbuild`, `oscaption`, `isservercore`, `timezone_offset_minutes`
- Data sources (e.g., `Processes_source`, `Network_source`)
- `sha256` (computed last, then embedded)
- Dates: ISO 8601 UTC format `yyyy-MM-ddTHH:mm:ssZ`
- Snake_case field names in JSON output
- Nested objects: `Network: { tcp: [...], dns: [...], adapters: [...] }`
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->
## Architecture

## Pattern Overview
- Plugin-based collector architecture (auto-discovers Collectors\*.psm1)
- Fallback-chain execution (WinRM → SMB+WMI → WMI)
- Browser-based offline HTML GUI with embedded JavaScript analysis
- Thread-safe job queue for concurrent remote execution
- Tiered data collection (PS 5.1 → PS 2.0 fallback paths)
## Layers
- Purpose: Command-line orchestrators that initiate work
- Location: `C:\DFIRLab\repo\Collector.ps1`, `C:\DFIRLab\repo\Executor.ps1`, `C:\DFIRLab\repo\QuickerLaunch.ps1`
- Contains: Parameter validation, target resolution, main loops
- Depends on: Core modules, Collectors, Executors, Launcher modules
- Used by: Analyst machines (CLI) and GUI workflow
- Purpose: Shared infrastructure (logging, connections, output, datetime utilities)
- Location: `C:\DFIRLab\repo\Modules\Core\`
- Contains:
- Depends on: None (lowest layer)
- Used by: All collector, executor, and launcher modules
- Purpose: Pluggable data collection modules (auto-discovered at runtime)
- Location: `C:\DFIRLab\repo\Modules\Collectors\`
- Contains:
- Depends on: Core\DateTime.psm1, remote sessions or local WMI
- Used by: Collector.ps1 (discovers all .psm1 files in directory)
- Purpose: Three independent methods to transfer binaries and launch tools on targets
- Location: `C:\DFIRLab\repo\Modules\Executors\`
- Contains:
- Depends on: Core\Output.psm1
- Used by: Executor.ps1 (tries methods in priority order)
- Purpose: Persistent queue manager with UI for concurrent job execution
- Location: `C:\DFIRLab\repo\Modules\Launcher\`
- Contains:
- Depends on: None
- Used by: QuickerLaunch.ps1 (maintains singleton WinForms application)
- Purpose: Offline browser-based GUI for analyzing collected data
- Location: `C:\DFIRLab\repo\ReportStages\`, `C:\DFIRLab\repo\Report.html`
- Contains:
- Depends on: Local JSON files (drag-and-drop or file picker)
- Used by: Browser (fully offline, no server)
## Data Flow
- Collector.ps1: Maintains target loop state; immutable outputs
- Executor.ps1: Maintains state transitions (queued → transferred → launched → alive)
- JobQueue: Enforces forward-only status transitions (see StatusOrder hash)
- QuickerLaunch.ps1: Maintains queue state in memory; UI updates every 500ms
- Report.html: Client-side state (current host, current search filters)
## Key Abstractions
- Purpose: Standardized function signature for all collectors
- Examples: `Modules\Collectors\Processes.psm1`, `Modules\Collectors\Network.psm1`
- Pattern: Each module exports `function Invoke-Collector { param(-Session, -TargetPSVersion, -TargetCapabilities) }` returning `@{ data = ...; source = ...; errors = @() }`
- Purpose: Standardized transfer + execution logic across methods
- Examples: `Modules\Executors\WinRM.psm1`, `Modules\Executors\SMBWMI.psm1`
- Pattern: Each executor exports `function Invoke-Executor { ... }` returning ordered hashtable with ExecutionId, ComputerName, Method, States array, FinalState
- Purpose: Detect target capabilities without breaking on missing CIM classes
- Pattern: Get-TargetCaps returns hashtable with PSVersion, HasCIM, HasNetTCPIP, HasDNSClient, IsServerCore
- Used by: Collectors decide which data path to use (try CIM, fallback to netstat, fallback to cmd)
- Purpose: Immutable job definition with validation
- Pattern: PSCustomObject with JobId, RowNumber, Type, Target, Binary, RemoteDest, Arguments, AliveCheck, Status
- Used by: JobQueue enforces status transitions; UI displays row per job
## Entry Points
- Location: `C:\DFIRLab\repo\Collector.ps1`
- Triggers: Analyst runs `.\Collector.ps1 -Targets 192.168.1.10 -Credential (Get-Credential)`
- Responsibilities:
- Location: `C:\DFIRLab\repo\Executor.ps1`
- Triggers: Analyst runs manually or QuickerLaunch.ps1 invokes via `Invoke-Expression`
- Responsibilities:
- Location: `C:\DFIRLab\repo\QuickerLaunch.ps1`
- Triggers: Report.html triggers quicker://launch URI scheme (via registry)
- Responsibilities:
- Location: `C:\DFIRLab\repo\Report.html` (assembled from ReportStages/*.html and *.js)
- Triggers: Analyst opens in browser
- Responsibilities:
## Error Handling
- Try CIM classes; if not available, mark HasCIM=false
- Collectors check capability flags and choose data method
- No exception thrown; collection continues with lower-fidelity data
- Retry capability probe up to 3 times with 5-second wait
- If all probes fail, skip target
- Each collector error logged with artifact name and message
- Errors included in manifest for analyst review
- WinRM connection failure: try SMB+WMI, then WMI
- Binary transfer verification: compute SHA256, compare with local
- Process launch verification: wait AliveCheck seconds, verify PID still exists
- State transitions: only forward-moving (queued → connecting → transferred → launched → alive/failed)
- All errors logged to state array with timestamp
- Compute SHA256 of serialized JSON
- Embed hash back into JSON object
- Validate integrity on read (Report.html checks sha256 field)
## Cross-Cutting Concerns
- Framework: `Modules\Core\Output.psm1` Write-Log function
- Level: INFO, WARN, ERROR
- Format: `<ISO8601-UTC> <LEVEL> <MESSAGE>`
- Output: Written to `collection.log` (Collector.ps1) and console (unless -Quiet)
- Pattern: Call `Initialize-Log -Path <path> -Quiet:$false` at startup; use `Write-Log 'INFO' "message"` throughout
- Collector.ps1: Verify admin rights, target list non-empty
- Executor.ps1: Validate local binary exists, target string is valid
- JobQueue: Validate target, binary, remoteDest don't contain forbidden characters (`;`, `&`, `|`, backtick, `$(`, `)`, `{`, `}`)
- Report.html: Validate JSON structure (manifest, processes, network, dns fields)
- WinRM: PSCredential passed to New-RemoteSession; stored in memory only
- SMB+WMI: PSCredential used for Share enumeration and WMI connection
- Local collection: Uses process token (no credentials needed)
- QuickerLaunch: Credential cache keyed by domain\hostname; re-prompted on first use per cache key
- Collector.ps1: Sequential target loop (one WinRM session per target)
- Executor.ps1: Single target, no concurrency
- QuickerLaunch.ps1: JobQueue uses thread-safe Generic List with monitor-lock; multiple jobs execute concurrently (max 5 by default)
- Report.html: Single-threaded JavaScript, no concurrency concerns
- SHA256 embedded in JSON output; verified on load
- Timestamps in UTC ISO8601 format
- Process→Network correlation done at analyst machine (not on target)
- No data transformation on collection (raw values stored)
<!-- GSD:architecture-end -->

<!-- GSD:workflow-start source:GSD defaults -->
## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:
- `/gsd:quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd:debug` for investigation and bug fixing
- `/gsd:execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->

<!-- GSD:profile-start -->
## Developer Profile

> Profile not yet configured. Run `/gsd:profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
