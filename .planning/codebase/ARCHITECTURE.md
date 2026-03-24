# Architecture

**Analysis Date:** 2026-03-24

## Pattern Overview

**Overall:** Modular orchestrator pattern with three independent PowerShell pipelines: Collector (remote data gathering), Executor (tool deployment), and Launcher (persistent job manager). Client-server separation via HTTP bridge.

**Key Characteristics:**
- Plugin-based collector architecture (auto-discovers Collectors\*.psm1)
- Fallback-chain execution (WinRM → SMB+WMI → WMI)
- Browser-based offline HTML GUI with embedded JavaScript analysis
- Thread-safe job queue for concurrent remote execution
- Tiered data collection (PS 5.1 → PS 2.0 fallback paths)

## Layers

**Entry Points Layer:**
- Purpose: Command-line orchestrators that initiate work
- Location: `C:\DFIRLab\repo\Collector.ps1`, `C:\DFIRLab\repo\Executor.ps1`, `C:\DFIRLab\repo\QuickerLaunch.ps1`
- Contains: Parameter validation, target resolution, main loops
- Depends on: Core modules, Collectors, Executors, Launcher modules
- Used by: Analyst machines (CLI) and GUI workflow

**Core Utilities Layer:**
- Purpose: Shared infrastructure (logging, connections, output, datetime utilities)
- Location: `C:\DFIRLab\repo\Modules\Core\`
- Contains:
  - `Connection.psm1`: WinRM session management, capability probing, hostname resolution
  - `Output.psm1`: JSON serialization, SHA256 hashing, logging, manifest building
  - `DateTime.psm1`: Timestamp formatting and timezone conversion
  - `Get-ToolsManifest.ps1`: Tools metadata scanning
- Depends on: None (lowest layer)
- Used by: All collector, executor, and launcher modules

**Collector Plugins Layer:**
- Purpose: Pluggable data collection modules (auto-discovered at runtime)
- Location: `C:\DFIRLab\repo\Modules\Collectors\`
- Contains:
  - `Processes.psm1`: Process enumeration (CIM → WMI → .NET fallback)
  - `Network.psm1`: TCP connections and DNS cache (CIM → netstat → ipconfig fallback)
  - `DLLs.psm1`: Loaded assemblies per process
  - `Users.psm1`: Active user sessions
- Depends on: Core\DateTime.psm1, remote sessions or local WMI
- Used by: Collector.ps1 (discovers all .psm1 files in directory)

**Remote Execution Layer:**
- Purpose: Three independent methods to transfer binaries and launch tools on targets
- Location: `C:\DFIRLab\repo\Modules\Executors\`
- Contains:
  - `WinRM.psm1`: PowerShell remoting via PSSession (preferred)
  - `SMBWMI.psm1`: File transfer via SMB share + execution via WMI
  - `WMI.psm1`: Direct WMI execution (legacy)
- Depends on: Core\Output.psm1
- Used by: Executor.ps1 (tries methods in priority order)

**Launcher Job Management Layer:**
- Purpose: Persistent queue manager with UI for concurrent job execution
- Location: `C:\DFIRLab\repo\Modules\Launcher\`
- Contains:
  - `JobQueue.psm1`: Thread-safe generic list with forward-only status transitions
  - `PipeListener.psm1`: Named pipe listener for job batch delivery (bridge file support)
- Depends on: None
- Used by: QuickerLaunch.ps1 (maintains singleton WinForms application)

**Reporting & Visualization Layer:**
- Purpose: Offline browser-based GUI for analyzing collected data
- Location: `C:\DFIRLab\repo\ReportStages\`, `C:\DFIRLab\repo\Report.html`
- Contains:
  - `01_head.html`: HTML shell and styling
  - `02_shell.html`: Navigation chrome
  - `03_core.js`: Data loading, state management, cross-tab communication
  - `04_fleet.js`: Multi-host summary and switching
  - `05_processes.js`: Process tree visualization with network pivot
  - `06_network.js`: TCP connections with process correlation
  - `06b_dlls.js`: DLL inventory per process
  - `07_dns.js`: DNS cache with connection cross-reference
  - `08_manifest.js`: Collection metadata and errors
  - `09_users.js`: User session details
  - `09b_execute.js`: Job execution UI (reads/writes bridge files)
  - `10_close.html`: Footer
- Depends on: Local JSON files (drag-and-drop or file picker)
- Used by: Browser (fully offline, no server)

## Data Flow

**Collection Flow (Collector.ps1):**

1. Parse targets and credentials; verify admin rights
2. Import Core modules (Connection, Output, DateTime)
3. Auto-discover Collectors\*.psm1 files; sort by name
4. For each target:
   a. Test if local or remote (localhost, IP match, env:COMPUTERNAME)
   b. Add target to WinRM TrustedHosts if remote
   c. Run capability probe (PS version, CIM support, DNS client, timezone)
   d. Create PSSession for remote targets
   e. For each collector module:
      - Invoke Invoke-Collector with remote session
      - Collectors choose data method based on capabilities
      - Collect process list, TCP connections, DNS cache, DLLs, users
   f. Close PSSession
   g. Build manifest with metadata, errors, sources
   h. Serialize output to `<OutputPath>\<hostname>\<hostname>_<timestamp>.json`
   i. Log summary (process count, connection count, DNS entries, errors)

**Execution Flow (Executor.ps1):**

1. Parse target, binary, destination, method, alive check duration
2. Resolve target to hostname (DNS or IP)
3. For each method in chain (WinRM → SMB+WMI → WMI):
   a. Load executor module (WinRM.psm1, SMBWMI.psm1, or WMI.psm1)
   b. Invoke-Executor function:
      - Verify local binary exists
      - Create session or SMB connection to target
      - Transfer binary (verify with SHA256)
      - Execute binary via PSSession invoke-command, SMB+WMI, or WMI
      - Capture PID
      - Wait AliveCheck seconds
      - Verify process still running
      - Transition state (CONNECTION_FAILED → TRANSFERRED → LAUNCHED → ALIVE/SFX_LAUNCHED)
   c. If final state is not terminal, try next method
4. Build result object with all state transitions and timestamps
5. Serialize to `<OutputPath>\<hostname>_execution_<timestamp>.json`

**Launcher Flow (QuickerLaunch.ps1):**

1. Self-elevate if not running as Administrator
2. Create named mutex to enforce single instance (second instance uses bridge file)
3. Load JobQueue.psm1 and PipeListener.psm1
4. Decode URI parameter (quicker://launch?jobs=<base64-json>)
5. Parse job array from URI or read from bridge file
6. Create JobQueue with max concurrent workers (default 5)
7. Add jobs to queue (validate targets, binaries, paths)
8. Create WinForms UI (Grid, status label, buttons)
9. Start refresh timer (500ms):
   - Poll queue for next job in Queued status
   - Invoke Executor.ps1 in background job
   - Update job status as states transition
   - Refresh grid with row colors (running=blue, done=green, failed=red)
10. Monitor PipeListener for new job batches; add to existing queue
11. When all jobs terminal, stay running until user closes

**Visualization Flow (Report.html):**

1. User opens Report.html in browser (fully offline)
2. Load JSON files via file picker or drag-and-drop
3. Core.js parses JSON array, validates structure
4. Fleet.js displays host summary; user selects active host
5. For active host, populate tabs:
   - Processes: Display process tree; highlight parent-child links
   - Network: Show TCP connections with process/PID correlation
   - DNS: Show DNS entries cross-referenced with connections
   - DLLs: Show loaded assemblies per process
   - Users: Show active sessions
   - Manifest: Show collection metadata, errors, sources
6. Execute.js builds job batch JSON and encodes to base64
7. On "Launch All", trigger quicker://launch?jobs=<base64> (URI scheme)
8. QuickerLaunch.ps1 receives jobs, displays job manager window
9. After jobs complete, user can refresh JSON from ExecutionResults folder

**State Management:**

- Collector.ps1: Maintains target loop state; immutable outputs
- Executor.ps1: Maintains state transitions (queued → transferred → launched → alive)
- JobQueue: Enforces forward-only status transitions (see StatusOrder hash)
- QuickerLaunch.ps1: Maintains queue state in memory; UI updates every 500ms
- Report.html: Client-side state (current host, current search filters)

## Key Abstractions

**Invoke-Collector (Plugin Interface):**
- Purpose: Standardized function signature for all collectors
- Examples: `Modules\Collectors\Processes.psm1`, `Modules\Collectors\Network.psm1`
- Pattern: Each module exports `function Invoke-Collector { param(-Session, -TargetPSVersion, -TargetCapabilities) }` returning `@{ data = ...; source = ...; errors = @() }`

**Invoke-Executor (Execution Engine):**
- Purpose: Standardized transfer + execution logic across methods
- Examples: `Modules\Executors\WinRM.psm1`, `Modules\Executors\SMBWMI.psm1`
- Pattern: Each executor exports `function Invoke-Executor { ... }` returning ordered hashtable with ExecutionId, ComputerName, Method, States array, FinalState

**Capability Probe:**
- Purpose: Detect target capabilities without breaking on missing CIM classes
- Pattern: Get-TargetCaps returns hashtable with PSVersion, HasCIM, HasNetTCPIP, HasDNSClient, IsServerCore
- Used by: Collectors decide which data path to use (try CIM, fallback to netstat, fallback to cmd)

**Job Entry Object:**
- Purpose: Immutable job definition with validation
- Pattern: PSCustomObject with JobId, RowNumber, Type, Target, Binary, RemoteDest, Arguments, AliveCheck, Status
- Used by: JobQueue enforces status transitions; UI displays row per job

## Entry Points

**Collector.ps1:**
- Location: `C:\DFIRLab\repo\Collector.ps1`
- Triggers: Analyst runs `.\Collector.ps1 -Targets 192.168.1.10 -Credential (Get-Credential)`
- Responsibilities:
  - Main orchestrator for data collection
  - Loads Core modules and auto-discovers collectors
  - Manages target loop and WinRM TrustedHosts
  - Invokes capability probes
  - Builds manifest and JSON output
  - Logs collection metadata

**Executor.ps1:**
- Location: `C:\DFIRLab\repo\Executor.ps1`
- Triggers: Analyst runs manually or QuickerLaunch.ps1 invokes via `Invoke-Expression`
- Responsibilities:
  - Transfers binary to target via WinRM/SMB+WMI/WMI
  - Launches tool and verifies execution
  - Returns state transitions and PID
  - Writes JSON result to ExecutionResults folder

**QuickerLaunch.ps1:**
- Location: `C:\DFIRLab\repo\QuickerLaunch.ps1`
- Triggers: Report.html triggers quicker://launch URI scheme (via registry)
- Responsibilities:
  - Persistent job manager with WinForms UI
  - Maintains single instance via named mutex
  - Manages job queue and status transitions
  - Spawns background jobs for concurrent execution
  - Listens for new batches via named pipe

**Report.html:**
- Location: `C:\DFIRLab\repo\Report.html` (assembled from ReportStages/*.html and *.js)
- Triggers: Analyst opens in browser
- Responsibilities:
  - Loads and parses JSON collection files
  - Displays fleet summary, process tree, network connections, DNS cache
  - Provides cross-tab search and correlation
  - Generates job batches and triggers QuickerLaunch via URI

## Error Handling

**Strategy:** Graceful degradation with error collection. Each data source has fallback path; errors logged but collection continues.

**Patterns:**

**Capability Probing:**
- Try CIM classes; if not available, mark HasCIM=false
- Collectors check capability flags and choose data method
- No exception thrown; collection continues with lower-fidelity data

**Remote Collection:**
- Retry capability probe up to 3 times with 5-second wait
- If all probes fail, skip target
- Each collector error logged with artifact name and message
- Errors included in manifest for analyst review

**Remote Execution:**
- WinRM connection failure: try SMB+WMI, then WMI
- Binary transfer verification: compute SHA256, compare with local
- Process launch verification: wait AliveCheck seconds, verify PID still exists
- State transitions: only forward-moving (queued → connecting → transferred → launched → alive/failed)
- All errors logged to state array with timestamp

**JSON Serialization:**
- Compute SHA256 of serialized JSON
- Embed hash back into JSON object
- Validate integrity on read (Report.html checks sha256 field)

## Cross-Cutting Concerns

**Logging:**
- Framework: `Modules\Core\Output.psm1` Write-Log function
- Level: INFO, WARN, ERROR
- Format: `<ISO8601-UTC> <LEVEL> <MESSAGE>`
- Output: Written to `collection.log` (Collector.ps1) and console (unless -Quiet)
- Pattern: Call `Initialize-Log -Path <path> -Quiet:$false` at startup; use `Write-Log 'INFO' "message"` throughout

**Validation:**
- Collector.ps1: Verify admin rights, target list non-empty
- Executor.ps1: Validate local binary exists, target string is valid
- JobQueue: Validate target, binary, remoteDest don't contain forbidden characters (`;`, `&`, `|`, backtick, `$(`, `)`, `{`, `}`)
- Report.html: Validate JSON structure (manifest, processes, network, dns fields)

**Authentication:**
- WinRM: PSCredential passed to New-RemoteSession; stored in memory only
- SMB+WMI: PSCredential used for Share enumeration and WMI connection
- Local collection: Uses process token (no credentials needed)
- QuickerLaunch: Credential cache keyed by domain\hostname; re-prompted on first use per cache key

**Concurrency:**
- Collector.ps1: Sequential target loop (one WinRM session per target)
- Executor.ps1: Single target, no concurrency
- QuickerLaunch.ps1: JobQueue uses thread-safe Generic List with monitor-lock; multiple jobs execute concurrently (max 5 by default)
- Report.html: Single-threaded JavaScript, no concurrency concerns

**Data Integrity:**
- SHA256 embedded in JSON output; verified on load
- Timestamps in UTC ISO8601 format
- Process→Network correlation done at analyst machine (not on target)
- No data transformation on collection (raw values stored)

---

*Architecture analysis: 2026-03-24*
