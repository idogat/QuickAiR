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
- Update file header version after every change
- Update CLAUDE.md if architecture changes
- Never commit screenshots or unnecessary files
