# Quicker — DFIR Volatile Artifact Collector
https://github.com/idogat/quicker

## Think Before Acting
Before executing any task:

1. READ first — read all relevant file headers
   before reading full files. Read full files
   only if headers are insufficient.

2. PLAN before writing — state your plan in
   agent.log before touching any file:
     - What files will be changed
     - What the change achieves
     - What could break
     - How you will verify

3. ONE CHANGE AT A TIME — make one logical
   change, verify it works, then proceed.
   Never make multiple unrelated changes
   in one step.

4. VERIFY before moving on — every change
   must be verified before the next change
   starts. A broken step is never skipped.

5. DIAGNOSE before fixing — when something
   fails, read the error fully, identify root
   cause, then fix. Never guess-and-patch.

6. STOP if uncertain — if the right approach
   is unclear, log the uncertainty and the
   options considered, then pick the most
   conservative option.

Never start writing code before completing
steps 1 and 2.

## Structure
Collector.ps1          — orchestrator, entry point
Report.html            — offline single-file GUI (do not edit directly)
ReportStages\          — HTML stage files (edit these, not Report.html)
build_report.ps1       — concatenates stages into Report.html
TestSuite.ps1          — test runner (auto-discovers Tests\)
Modules\Core\          — Connection, DateTime, Output
Modules\Collectors\    — Processes, Network, Users (+ future plugins)
Modules\Collectors\Users.psm1  — user accounts, sessions, profiles,
                                 DC domain enumeration (Get-ADUser / ADSI)
Executor.ps1           — remote tool execution orchestrator
Modules\Executors\     — WinRM.psm1, WMI.psm1
Tests\                 — T01-T09 per-module test files
QuickerLaunch.ps1      — WinForms job manager (single-instance, mutex)
Register-QuickerProtocol.ps1 — registers quicker:// URI handler
Modules\Launcher\      — JobQueue.psm1, PipeListener.psm1
C:\DFIRLab\QuickerBridge\ — inter-process job handoff folder
                             (not in repo — runtime only)

## Cross-Host User Correlation
Report.html builds window.userIndex from all loaded host JSONs.
Per-user view (USERS tab) correlates data from DC + all member machines.
SID is the primary correlation key — usernames can differ across hosts.
userIndex keyed by SID; entries have: domainAccount, appearances, sessions, groups.

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
creds to all terget:
user:administrator
password:Aa123456

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

## Time and Datetime Rule
ALL datetimes everywhere — collection, JSON output,
and HTML display — must be UTC. No exceptions.

Collection (PowerShell):
  Always convert to UTC before storing:
    $dt.ToUniversalTime().ToString("o")
  Never store local time as primary value.
  Never use Get-Date without .ToUniversalTime()
  FILETIME conversion must use FromFileTimeUtc()
    not FromFileTime()

JSON output:
  All datetime fields end in Z (UTC indicator)
  Field names end in UTC (e.g. LastLogonUTC)
  Format: ISO 8601 — "2026-01-15T14:30:00Z"

HTML display:
  Always use fmtUTC() formatter
  Never use toLocaleDateString()
  Never use toLocaleString()
  Never use toLocaleTimeString()
  Display format: YYYY-MM-DD HH:mm:ss UTC

If you find any datetime not in UTC anywhere
in any file — fix it immediately before
proceeding with the task.

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

## Report.html Editing Rule
Never edit Report.html directly.
Edit the relevant ReportStages\*.js or *.html file.
Run .\build_report.ps1 to rebuild Report.html.
Adding new tab = add new stage file + run build.

## Report.html Build Rule
After every build_report.ps1 run verify:
  Exactly 1 <script> open tag
  Exactly 1 </script> close tag
  JS content between tags > 50KB
  No JS visible as text in browser
If any check fails: fix before committing.

## build_report.ps1 Rule
Always run .\build_report.ps1 after any stage file change.
Build exits with code 1 if structure invalid.
Never commit Report.html that fails build check.
Use Playwright to screenshot after every build.
Stage file naming: closing HTML must sort AFTER all JS stages.
Current order: 01_head, 02_shell, 03_core, 04_fleet, 05_processes,
  06_network, 06b_dlls, 07_dns, 08_manifest, 09_users, 10_close.
New stages must be named so they sort before 10_close.html.

## Playwright Rule
Take screenshot → analyze → delete immediately.
Never commit screenshot files to repo.
Clean all .png files at end of every session.

## Executor Module Contract
Exports: Invoke-Executor
Params: ComputerName, Credential,
  LocalBinaryPath, RemoteDestPath,
  Arguments, AliveCheckSeconds
Returns: ExecutionId, ComputerName, Method,
  States[], FinalState, PID, Error
WinRM: transfers binary then executes
SMB+WMI: transfers via SMB admin share,
  executes via WMI. Fallback when WinRM
  unavailable. Requires port 445 + WMI access.
WMI: executes only, no transfer
Auto chain: WinRM → SMB+WMI → FAILED

## Launcher Module Contract
JobQueue.psm1:
  Exports: New-JobQueue, Add-Job, Get-NextJob,
           Update-JobStatus, Get-QueueSummary
  Thread-safe job state management via Monitor lock.
  Enforces forward-only status transitions:
    Queued(0) → Connecting(1) → TRANSFERRED(2)
    → LAUNCHED(3) → ALIVE|SFX_LAUNCHED|FAILED|TIMEOUT(100)
  Invalid backward transitions logged as WARN, rejected.
  New-JobQueue returns object with .Jobs .Lock .MaxConcurrent .JobCounter

PipeListener.psm1:
  Exports: Start-BridgeListener, Stop-BridgeListener,
           Send-JobBatch, Read-PendingJobs
  Background runspace polls C:\DFIRLab\QuickerBridge\ every 1s.
  New *.json files read, deleted, raw JSON pushed to ConcurrentQueue.
  Read-PendingJobs drains the ConcurrentQueue on the UI thread.
  Send-JobBatch writes <guid>.json for second-instance handoff.


