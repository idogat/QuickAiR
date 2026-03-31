# QuickAiR — DFIR Volatile Artifact Collector
https://github.com/idogat/quickair

## Structure
Entry points:
  Collector.ps1          — orchestrator, runs all collectors
  Executor.ps1           — remote tool execution orchestrator
  QuickAiRLaunch.ps1      — WinForms job manager (single-instance)
  QuickAiRCollect.ps1     — WinForms collection trigger (quickair-collect://)
  QuickAiRSetup.ps1      — one-time protocol registration, ships with tool
  Register-QuickAiRProtocol.ps1 — registers quickair:// and quickair-collect:// handlers
Protocol handlers:
  quickair://            → QuickAiRLaunch.ps1  (tool execution)
  quickair-collect://    → QuickAiRCollect.ps1 (artifact collection)
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
  C:\DFIRLab\QuickAiRBridge\         — launch job handoff (not in repo)
  C:\DFIRLab\QuickAiRBridge\collect\ — collect job handoff (not in repo)

## Plugin Contracts
- Collector: drop .psm1 in Modules\Collectors\, export Invoke-Collector — see any existing header
- Executor: export Invoke-Executor — auto chain: WinRM → SMB+WMI → FAILED
- Launcher: see JobQueue.psm1 and PipeListener.psm1 headers for exports and state machine
- New collector plugin = new .psm1 + matching Tests\T<n>_<name>.ps1
- Plugin failure: caught by orchestrator, logged to manifest.collection_errors, never aborts run

## Test Lab Targets (dev/test only)
 localhost — always available, no credentials needed 
192.168.1.106 — server 2022 Creds: administrator / Aa123456
 192.168.1.100 —  domain DC Creds: server2012\administrator / Aa123456
 192.168.1.108 — , Server 2008 R2, PS 2.0 administrator / Aa123456
192.168.1.104 - windows 10 user:1\pass:1

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

## Subagents

Use these agents instead of doing the work directly.
Never bypass an agent to do its job inline.

  dfir-analyst    → any forensic review, coverage question,
                    UX or logic opinion about the toolkit
  test-writer     → writing Tests\T*.ps1 for a module
  report-dev      → adding or updating Report.html tabs
                    for a module's data

## Rules
  Never implement fixes without user approval first.
  Never write tests before dfir-analyst has reviewed the module.
  Never update the HTML tab before tests have passed.
  Never move to the next module without dfir-analyst GO or GO WITH
  on both the module+tests and the HTML tab.
  
## Review and Test Workflow

STEP 1 — dfir-analyst reviews the module
  Output: GO WITH or NO-GO with specific findings.

STEP 2 — Wait for user approval
  Present findings to user.
  Do not proceed until user confirms which findings to fix.

STEP 3 — Implement approved fixes
  Apply only the fixes the user approved. Nothing else.

STEP 4 — test-writer writes and runs tests
  Write Tests\T<n>_<ModuleName>.ps1.
  Run against localhost and all remote targets.
  Report failures — do not fix module issues autonomously.

STEP 5 — dfir-analyst re-reviews module + tests together
  NO-GO → back to STEP 2 with new findings.
  GO or GO WITH → proceed to STEP 6.

STEP 6 — report-dev updates the HTML tab
  Add or update the tab for this module in ReportStages\.
  Rebuild Report.html via build_report.ps1.

STEP 7 — dfir-analyst reviews the HTML changes
  Output: GO WITH or NO-GO with specific findings.

STEP 8 — Wait for user approval
  Present HTML findings to user.
  Do not proceed until user confirms which findings to fix.

STEP 9 — report-dev implements approved HTML fixes
  Apply only the fixes the user approved. Nothing else.
  Rebuild Report.html via build_report.ps1.

STEP 10 — dfir-analyst re-reviews HTML
  NO-GO → back to STEP 8 with new findings.
  GO or GO WITH → next module.