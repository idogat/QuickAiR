# Codebase Concerns

**Analysis Date:** 2026-03-24

## Tech Debt

**UTF-8 BOM in PowerShell build script:**
- Issue: `build_report.ps1` (line 1) contains UTF-8 BOM, corrupting Unicode box-drawing characters in console output
- Files: `/c/DFIRLab/repo/build_report.ps1`
- Impact: Console display shows garbled box-drawing characters instead of structured output. Non-blocking but unprofessional appearance.
- Fix approach: Resave `build_report.ps1` as UTF-8 without BOM (use VS Code "Change End of Line" or PowerShell's `-Encoding UTF8NoBOM`)

**Silent error suppression patterns:**
- Issue: 18+ instances of `-ErrorAction SilentlyContinue` throughout collector and core modules suppress legitimate errors
- Files: `/c/DFIRLab/repo/Modules/Core/Connection.psm1`, `/c/DFIRLab/repo/Modules/Collectors/Network.psm1`, `/c/DFIRLab/repo/Modules/Collectors/Processes.psm1`
- Impact: Makes troubleshooting difficult; errors silently fail to collection errors array, but intermediate failures lose context
- Fix approach: Use explicit error capture via `$ErrorActionPreference='Stop'` with try/catch blocks, log caught exceptions to manifest.collection_errors with full message

**Regex-based SHA256 replacement for JSON manifest:**
- Issue: Line 77-78 in `/c/DFIRLab/repo/Modules/Core/Output.psm1` uses two separate regex passes to embed SHA256 into JSON
- Files: `/c/DFIRLab/repo/Modules/Core/Output.psm1` (lines 77-78)
- Impact: If JSON formatter changes whitespace patterns, SHA256 may fail to embed silently. Self-signed hash mechanism relies on string replacement in already-serialized JSON
- Fix approach: Compute SHA256 on initial JSON, modify JSON object BEFORE serialization, re-serialize with embedded hash in single pass

---

## Security Considerations

**WinRM certificate validation disabled:**
- Risk: `New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck` opens MITM attack surface on untrusted networks
- Files: `/c/DFIRLab/repo/Modules/Core/Connection.psm1` (lines 96, 139)
- Current mitigation: WinRM sessions created for analyst-to-target direction only; lab environment (not production). No TLS cert chains validated.
- Recommendations: (1) Document as lab-only workaround; (2) Add `-WarningAction Continue` to alert users; (3) Provide flag `$ValidateCertificates` to allow hardening in production; (4) Validate CA chain when `$ValidateCertificates=$true`

**Credential caching in launcher UI state:**
- Risk: QuickAiRLaunch.ps1 line 90 maintains `$script:CredCache` hashtable in memory for multiple executor invocations
- Files: `/c/DFIRLab/repo/QuickAiRLaunch.ps1` (line 90)
- Current mitigation: Single-instance WinForms app; credentials only held during job execution; cleared only at process exit
- Recommendations: (1) Clear credentials from `$CredCache` immediately after each job completes; (2) Add [SecureString] wrapper instead of [PSCredential]; (3) Implement credential expiry timer (default 10 minutes); (4) Zero credential on form close

**Hardcoded bridge directory path:**
- Risk: `/c/DFIRLab/repo/QuickAiRLaunch.ps1` line 62 hardcodes `$BRIDGE_DIR = 'C:\DFIRLab\QuickAiRBridge'` for inter-process job handoff
- Files: `/c/DFIRLab/repo/QuickAiRLaunch.ps1` (line 62)
- Current mitigation: Directory exists only at runtime (created by launcher), requires Administrator access, only used internally
- Recommendations: (1) Make `$BRIDGE_DIR` parameterizable or derive from `$env:TEMP`; (2) Document security assumption; (3) Add access control check to verify only Administrator can read/write

---

## Performance Bottlenecks

**Large JSON serialization without streaming:**
- Problem: Collector.ps1 line 71 calls `ConvertTo-Json -Depth 10` on entire dataset at once before writing to disk
- Files: `/c/DFIRLab/repo/Modules/Core/Output.psm1` (line 71)
- Cause: PowerShell's `ConvertTo-Json` loads entire object tree into memory before serialization
- Improvement path: (1) Stream JSON output using `[System.Text.Json.JsonWriter]` for large datasets; (2) Add memory check before serialization; (3) Implement chunked output for process/network lists >10k entries

**Virtual scroll re-render after every column resize:**
- Problem: ReportStages/03_core.js line 211 (`reapplyColWidthsFromStorage`) re-renders all visible rows after column width change
- Files: `/c/DFIRLab/repo/ReportStages/03_core.js` (line 211)
- Cause: Grid re-layout on every mouseup during drag; virtual scroll can render 100+ rows per visible section
- Improvement path: Debounce column width application; batch DOM updates; defer re-rendering until drag complete

**DNS reverse lookup on public IPs during collection:**
- Problem: Network collector performs DNS PTR lookups for every unique public IP synchronously during collection
- Files: `/c/DFIRLab/repo/Modules/Collectors/Network.psm1` (implied fallback path for DNS resolution)
- Cause: If collector encounters 50+ unique public IPs, 50+ sequential DNS queries (~2-5 sec each worst-case)
- Improvement path: (1) Implement DNS lookup timeout (current: unspecified); (2) Use async DNS queries if PS version supports; (3) Cache lookups within single run; (4) Defer PTR lookups to post-collection analysis phase

---

## Known Bugs

**Column width reset on virtual scroll navigation:**
- Symptoms: User resizes column width, scrolls to bottom of table, column widths revert to default
- Files: `/c/DFIRLab/repo/ReportStages/03_core.js` (lines 142-152, 211)
- Trigger: (1) Drag column header to resize; (2) Scroll table to load new rows via virtual scroll; (3) Widths reset for newly-rendered rows
- Workaround: Resize columns after viewing desired rows; use sessionStorage persistence (partially working)
- Root cause: `_applyGridTemplate` (line 142) applies widths only to already-rendered vrows; newly-created rows from virtual scroll don't inherit widths until next explicit apply
- Fix: Call `reapplyColWidthsFromStorage` automatically after virtual scroll render callback completes

**Netstat parsing on legacy OS may miss short-lived connections:**
- Symptoms: PS 2.0 collectors on Windows Server 2008 R2 may show incomplete connection list vs. PS 5.1 CIM
- Files: `/c/DFIRLab/repo/Modules/Collectors/Network.psm1` (lines 24-31, netstat_legacy path)
- Trigger: High-churn workloads with frequent connection establishment/teardown
- Workaround: Run collection during low-activity window; compare against CIM-based targets
- Root cause: `cmd /c netstat -ano` output is snapshot at parse time; connections opened/closed between invocation and parsing are missed
- Test note: T3 test allows 10% miss rate for legacy OS (TestReport.md line 56)

---

## Test Coverage Gaps

**Untested error scenarios in collectors:**
- What's not tested: Timeout handling when CIM queries hang >60 seconds; behavior when target has no processes/connections; malformed WMI responses
- Files: `/c/DFIRLab/repo/Modules/Collectors/Processes.psm1` (line 150: `OperationTimeoutSec 60` hardcoded), `/c/DFIRLab/repo/Modules/Collectors/Network.psm1` (similar timeout pattern)
- Risk: Hung collection if target CIM service is slow; collection aborts without partial data recovery
- Priority: High

**HTML GUI multi-host dataset loading bounds:**
- What's not tested: Behavior when loading 20+ JSON files simultaneously (current Report.html ~158KB + each JSON can be 1-5MB); memory exhaustion scenarios
- Files: `/c/DFIRLab/repo/ReportStages/03_core.js` (lines 293-298: handleFiles loop loads each JSON sequentially)
- Risk: Browser tab crash on weak machines; no streaming loader for large JSON datasets
- Priority: Medium

**PowerShell 2.0 target compatibility with complex command chains:**
- What's not tested: PS 2.0 invocation with nested object transformations in Processes.psm1 `.NET fallback` (lines 104-127)
- Files: `/c/DFIRLab/repo/Modules/Collectors/Processes.psm1` (lines 106-127: dotnet_fallback loop with property initialization)
- Risk: PS 2.0 may not support object initialization patterns used in CIM path; fallback may fail silently
- Priority: Medium (only affects PS 2.0 targets; testable on 2008 R2)

**Manifest collection_errors array edge cases:**
- What's not tested: Behavior when collection_errors array exceeds reasonable size (1000+ entries); JSON encoding of error messages containing quotes/newlines
- Files: `/c/DFIRLab/repo/Collector.ps1` (line 161, 171: errors appended to $collErr)
- Risk: Invalid JSON output if error message contains unescaped quote or newline
- Priority: Low (rare condition)

---

## Fragile Areas

**Plugin auto-discovery mechanism:**
- Files: `/c/DFIRLab/repo/Collector.ps1` (lines 150-174)
- Why fragile: Relies on `Get-ChildItem Modules\Collectors\*.psm1 | Sort-Object Name`. If plugin module exports wrong function signature or has no `Invoke-Collector` function, entire target collection fails
- Safe modification: (1) Add validation after Import-Module to verify function exists; (2) Skip plugins that fail import; (3) Log plugin load failures separately before invocation
- Test coverage: No unit tests for plugin contract validation

**Executor fallback chain (WinRM → SMB+WMI → FAILED):**
- Files: `/c/DFIRLab/repo/Executor.ps1` (lines 213-233)
- Why fragile: Auto-fallback chain uses error string matching (e.g., `$result.FinalState -eq "CONNECTION_FAILED"`) to determine whether to try next method. If result structure changes, fallback silently skips to FAILED
- Safe modification: (1) Use explicit state enum instead of string comparison; (2) Add integration test for fallback path; (3) Verify result object schema before accessing FinalState
- Test coverage: Only tested via end-to-end execution results; no unit tests for state machine logic

**Session-to-JSON correlation in Launcher:**
- Files: `/c/DFIRLab/repo/QuickAiRLaunch.ps1` (lines 394: load execution JSON), Executor.ps1 (line 268: write result JSON)
- Why fragile: Launcher searches for execution JSON by filename pattern `*_execution_*.json` and assumes first match is result. If multiple jobs write to same directory, glob may match wrong file
- Safe modification: (1) Include unique job ID in result filename; (2) Pass expected filename to executor; (3) Verify file write before read
- Test coverage: Single-instance launcher mitigates collision risk in practice; not tested for concurrent executions

---

## Scaling Limits

**In-memory fleet index for 100+ hosts:**
- Current capacity: Report.html state object holds full host JSON (processes, network, DNS) for all loaded hosts in memory
- Limit: Browser JavaScript heap limit (~500MB-2GB depending on browser/machine). At 1-5MB per host JSON, practical limit ~100-200 hosts per browser session
- Scaling path: (1) Implement lazy loading: keep only active host JSON in memory, fetch others via IndexedDB on demand; (2) Compress JSON with gzip before storage; (3) Stream large tables via virtual scroll with row-level data fetch

**Concurrent collection across many targets:**
- Current capacity: Collector.ps1 runs sequentially per-target (foreach line 86). No parallelism.
- Limit: 10 targets × 30 seconds per collection = 5 minutes minimum. Analyst cannot collect 100 targets in reasonable time.
- Scaling path: (1) Use `Invoke-AsJob` or PowerShell workflow to parallelize target collection; (2) Implement throttle (max 10 concurrent sessions); (3) Monitor job queue progress; (4) Aggregate results into single manifest

**Single-instance launcher architecture:**
- Current capacity: Launcher uses named mutex (QuickAiRLauncherMutex) to enforce single instance. Queue held in memory.
- Limit: If queue fills with 500+ jobs, WinForms grid renderer will stall. Mutex file-based; limited to one analyst machine at a time
- Scaling path: (1) Implement persistent queue (JSON file or SQLite) so launcher can restart without losing jobs; (2) Add queue persistence checkpoint every N jobs; (3) Implement multi-instance launcher with distributed job coordination

---

## Dependency Vulnerabilities

**No explicit version pinning on .NET/WMI APIs:**
- Issue: Code uses `.NET` and `WMI` classes available since .NET 2.0 with no version guard (e.g., `[System.Diagnostics.Process]::GetProcesses()`)
- Impact: If PowerShell is updated to use incompatible .NET runtime, process enumeration may fail silently
- Mitigation: Unlikely in practice (Microsoft maintains backward compatibility); code tested on PS 2.0-5.1

**PowerShell 2.0 deprecation:**
- Issue: Windows Server 2008 R2 ships with PS 2.0, officially deprecated. Support burden for PS 2.0 fallback paths
- Impact: Fallback code paths (WMI instead of CIM, `cmd netstat` instead of CIM) add complexity; testing burden high (only one test lab 2008 R2 machine)
- Recommendation: Document support matrix; consider drop of PS 2.0 support in v3.0 if Microsoft EOLs 2008 R2

---

## Missing Critical Features

**No ability to cancel collection in progress:**
- Problem: Collector.ps1 running against slow/hanging target blocks analyst. No timeout exposed to user; must kill PowerShell process.
- Blocks: Unable to interrupt hanging remote collection; cannot retry a target without re-running entire script
- Recommendation: (1) Implement per-target timeout parameter (default 120 sec); (2) Add UI progress indicator with "Cancel" button; (3) Save partial results if interrupted

**No audit logging of tool execution:**
- Problem: Executor.ps1 writes result JSON but does not log to Windows Event Log or external audit system
- Blocks: Compliance/forensic requirement in many organizations; cannot trace who executed what tools when
- Recommendation: (1) Add optional `-LogToEventLog` parameter; (2) Write to Security event log or custom event source; (3) Include job ID, operator, timestamp, target, tool path, result

**No support for multi-protocol remote collection (SSH, invoke-command over SSH):**
- Problem: WinRM-only; cannot collect from targets behind restrictive firewalls (SSH only)
- Blocks: Cannot perform collection in restricted network segments
- Recommendation: Out of scope for lab tool; if needed, add SSH invocation via `plink.exe` or PS 7 SSH transport

---

## Documentation Gaps

**CLAUDE.md rule about "never prompt user" contradicts Collector.ps1:**
- Issue: CLAUDE.md line 46 states "Never prompt user — fully autonomous" but Collector.ps1 lines 98-100 prompts for remote credentials if not supplied
- Files: `/c/DFIRLab/repo/CLAUDE.md` (line 46), `/c/DFIRLab/repo/Collector.ps1` (lines 98-100)
- Impact: Confusion about intended design; breaks unattended collection
- Fix: (1) Update CLAUDE.md to clarify that prompts are acceptable for analyst-facing tools (Collector, Executor) but NOT for remote target code; (2) Move credential prompt to launch script wrapper

---

*Concerns audit: 2026-03-24*
