# Quicker — DFIR Volatile Artifact Collector
https://github.com/idogat/quicker

## Structure
Collector.ps1          — orchestrator, entry point
Report.html            — offline single-file GUI
TestSuite.ps1          — test runner (auto-discovers Tests\)
Modules\Core\          — Connection, DateTime, Output
Modules\Collectors\    — Processes, Network (+ future plugins)
Tests\                 — T01-T05 per-module test files

## Adding A New Collector Plugin
Drop *.psm1 into Modules\Collectors\
Implement Invoke-Collector — see any existing module header.
Auto-discovered at runtime. No changes to Collector.ps1.
JSON output key = module filename without extension.
Add matching test file to Tests\T<n>_<name>.ps1

## Test Lab Targets (dev/test only — not prod)
localhost              — PS 5.1, no credential
192.168.1.250          — domain, 2 NICs
192.168.1.100          — domain DC, 2 NICs
192.168.1.236          — workgroup, Server 2008 R2,
                         PS 2.0, 2 NICs

## Production Targets
Unknown at development time.
Collector must handle any Windows target dynamically:
  - Any PS version 2.0 through 5.1
  - Domain or workgroup
  - Any number of NICs
  - Any OS from Server 2008 R2 to Server 2022 / Win11
  - Credentials always provided at runtime
  - Never hardcode any IP, hostname, or credential
  - All behavior detected via capability probe at runtime

## Rules
- Never prompt user — autonomous always
- Never write to Windows Event Log
- No external network calls ever
- Read-only collection
- Run as Administrator
- All datetimes UTC ISO 8601
- PS 2.0 compatible on target-side paths
- No downloads, no external dependencies

## Efficiency Rules
- Read file headers before reading full file
- Use str_replace for edits, never full rewrites
- Write files >200 lines in stages, concatenate after
- Read only files relevant to current task
- Update file header version after every change
- Update CLAUDE.md if architecture changes

## Plugin Failure Behavior
If Invoke-Collector throws: catch in orchestrator,
add to manifest.collection_errors, log WARN, continue.
Never let one plugin crash abort the whole collection.
