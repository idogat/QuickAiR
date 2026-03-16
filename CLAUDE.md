# Quicker — DFIR Volatile Artifact Collector

## Architecture
Plugin-based modular PowerShell collector.

Collector.ps1          — thin orchestrator only
Report.html            — offline single-file GUI
TestSuite.ps1          — auto-discovers Tests\T*.ps1
Modules\
  Core\
    Connection.psm1    — WinRM session, auth, retry
    Output.psm1        — JSON write, SHA256, manifest
    DateTime.psm1      — UTC normalization
  Collectors\
    Processes.psm1     — process list
    Network.psm1       — TCP connections + DNS cache
Tests\
  T01_Processes.ps1
  T02_Network.ps1
  ...

## Collector Module Contract
Every Modules\Collectors\*.psm1 must implement:
  function Invoke-Collector {
    param($Session, $TargetPSVersion, $TargetCapabilities)
    return @{ data=@(); source=""; errors=@() }
  }
Orchestrator auto-discovers and runs all modules.
Return key in JSON = module filename without extension.

## Rules
- Never prompt user — all decisions autonomous
- Never write to Windows Event Log
- Never make external network calls
- Read-only collection — never modify target state
- Run as Administrator (abort with instructions if not)
- All datetimes UTC ISO 8601
- PS 2.0 compatible on target-side code paths
- No external dependencies, no downloads

## Output
One JSON per host:
  <OutputPath>\<hostname>\<hostname>_<timestamp>.json
  Keys: manifest + one key per collector module

## Targets
localhost, 192.168.1.250, 192.168.1.100 (DC), 192.168.1.236 (2008R2)
All have 2 NICs except localhost.

## Repo
https://github.com/idogat/quicker