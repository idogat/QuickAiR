# QuickAiR — DFIR Volatile Artifact Collector
https://github.com/idogat/quickair

## Structure
Entry points:
  Collector.ps1          — orchestrator, runs all collectors
  Executor.ps1           — remote tool execution orchestrator
  QuickAiRLaunch.ps1     — WinForms job manager (single-instance)
  QuickAiRCollect.ps1    — WinForms collection trigger (quickair-collect://)
  QuickAiRSetup.ps1      — one-time protocol registration, ships with tool
  Register-QuickAiRProtocol.ps1 — registers quickair:// and quickair-collect:// handlers
Core:       Modules\Core\       — Connection, DateTime, Output
Collectors: Modules\Collectors\ — auto-discovered plugins (Processes, Network, Users, DLLs…)
Executors:  Modules\Executors\  — WinRM.psm1, WMI.psm1, SMBWMI.psm1
Launcher:   Modules\Launcher\   — JobQueue.psm1, PipeListener.psm1
Report:     Report.html (never edit directly) — edit ReportStages\, run build_report.ps1
Versioning: VERSION — major.minor.patch, patch auto-bumped by .git/hooks/pre-commit
Tests:      TestSuite.ps1 + Tests\T01–T14
Runtime:    C:\DFIRLab\QuickAiRBridge\ (not in repo)

## Plugin Contracts
- Collector: drop .psm1 in Modules\Collectors\, export Invoke-Collector
- Executor: export Invoke-Executor — auto chain: WinRM → SMB+WMI → FAILED (falls back on CONNECTION_FAILED or TRANSFER_FAILED)
- Executor states: CONNECTED, TRANSFERRED, TRANSFER_SKIPPED, LAUNCHED, ALIVE, ALIVE_ASSUMED, SFX_LAUNCHED, SFX_ASSUMED, CLEANUP, *_FAILED
- Executor cleanup: transferred binary deleted on failure; alive check verifies PID + process name
- Launcher: see JobQueue.psm1 and PipeListener.psm1 headers
- New collector = new .psm1 + matching Tests\T<n>_<name>.ps1
- Plugin failure: caught by orchestrator, logged to manifest.collection_errors, never aborts run
- WMI fallback: WinRM fails → WMI session (hashtable). Plugins check session.Method to route.

## Test Lab Targets (dev/test only)
  localhost — always available, no credentials needed
  192.168.1.107 — Win10, WinRM disabled (WMI fallback) Creds: 1 / 1
  192.168.1.104 — Win10 Creds: administrator / Aa123456
  192.168.1.100 — domain DC Creds: server2012\administrator / Aa123456
  192.168.1.106 — Server 2022 Creds: administrator / Aa123456

## Rules
- Never prompt user — fully autonomous, read-only collection, run as Administrator (Executor.ps1 is interactive by design)
- Never write to Windows Event Log
- No external network calls, no downloads, no external dependencies
- All datetimes UTC ISO 8601 — ToUniversalTime(), FromFileTimeUtc(), never local time
- PS 2.0 compatible on all target-side code paths
- SID is primary cross-host user correlation key
- Production: all behavior detected at runtime — never hardcode targets, credentials, or OS assumptions
- Report.html: edit ReportStages\, new stages sort before 10_close.html, Playwright screenshot then delete
- Never implement fixes without user approval first

## Agent Efficiency
- Read file headers before full files — detail lives in headers not here
- Use str_replace for edits, never full rewrites — one logical change at a time
- Never commit screenshots or unnecessary files

## Living Documents
- CLAUDE.md: update after every arch change, file add/remove, or contract change — limit 100 lines
- File headers: update version, function list, deps after every change — stale header > no header
- End of every task: review CLAUDE.md + changed file headers, commit together

## Subagents — use these instead of doing the work directly
  dfir-analyst → forensic review, coverage, UX/logic opinions
  test-writer  → writing Tests\T*.ps1 for a module
  report-dev   → adding/updating Report.html tabs in ReportStages\

## Review and Test Workflow
1. dfir-analyst reviews module → GO WITH or NO-GO
2. Wait for user approval — only fix what user confirms
3. Implement approved fixes
4. test-writer writes + runs tests (localhost + all remotes) — report failures, don't auto-fix
5. dfir-analyst re-reviews module + tests → NO-GO = back to step 2, GO = continue
6. report-dev updates HTML tab, rebuilds Report.html
7. dfir-analyst reviews HTML → GO WITH or NO-GO
8. Wait for user approval on HTML findings
9. report-dev implements approved HTML fixes, rebuilds
10. dfir-analyst re-reviews HTML → NO-GO = back to step 8, GO = next module
