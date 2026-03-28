# QuickAiR — Requirements Specification

Version: 1.0
Date: 2026-03-28
Source: Structured requirements interview (codebase analysis + product owner)

---

## 1. Problem Statement

QuickAiR solves the problem of **distributing forensic collection tools to Windows and Linux endpoints during incident response** — remotely, at scale, without the analyst needing to know the target environment's capabilities or remote access methods.

### The core pain point

IR analysts need to push disk and memory collection tools to endpoints. Today this fails because:

1. **Method confusion.** Analysts don't know whether a target supports WinRM, needs SMB+WMI, or requires a different approach. IT teams often don't know their own environments either — the analyst faces the unknown every time.
2. **Direct login is forensically noisy.** The obvious fallback (RDP on Windows, SSH interactive session on Linux, or direct console login) creates logon artifacts, modifies the target's state, and can contaminate the investigation.
3. **No visibility.** There is no central view of which hosts received the tool, which launched successfully, which failed to connect or transfer, and why.

### What QuickAiR delivers

- **Auto-chaining remote access:** Probe the target, discover what works (WinRM → SMB+WMI → FAILED), and push tools without the analyst choosing a method.
- **A volatile artifact collector** that helps analysts **scope** the investigation — which hosts have suspicious processes, connections, or users — before deciding where to push heavier disk/memory tools.
- **A single-file HTML report** that serves as the **primary interface for the entire IR workflow** — view volatile data, trigger tool deployment, monitor status — without opening a PowerShell CLI.

### What it does NOT deliver

- Disk forensic artifact collection (registry hives, event logs, prefetch, MFT). QuickAiR collects volatile state only.
- Automated threat detection or anomaly scoring. Triage is the analyst's job.
- Memory dump acquisition. QuickAiR can *deploy* memory tools (via Executor) but does not natively dump or analyze memory.

---

## 2. Use Cases

### UC-1: Scoped Tool Deployment (primary workflow)

**Actor:** IR analyst responding to an alert.
**Flow:**
1. Alert received (from SIEM, EDR, or other source).
2. Run volatile collector against suspect hosts to scope the incident from the report.html.
3. Review Report.html — identify which hosts need full disk/memory collection.
4. From the Report, push disk and memory tools to selected hosts.
5. Monitor deployment status in the Report.
6. Analyze collected artifacts offline.

**Key:** Steps 2–5 happen entirely within Report.html — no CLI.

### UC-2: Direct Tool Deployment (no scoping)

**Actor:** Analyst who already knows which hosts to collect, or whose volatile data was inconclusive.
**Flow:** Skip scoping. Push tools directly to target hosts from the Report.
**Why this matters:** Sometimes the alert is clear enough, or the volatile collector didn't surface useful data. The tool push must always work regardless.

### UC-3: Single-Host Local Triage

**Actor:** Analyst on the machine under investigation.
**Flow:** Run `Collector.ps1 -Targets localhost`. Review results in Report.html.
**Constraint:** No credentials needed. Must run as Administrator.

### UC-4: Multi-Host Remote Collection

**Actor:** Analyst on a jump box with network access to targets.
**Flow:** Collection runs against multiple hosts sequentially. JSON output per host.
**Constraint:** WinRM (port 5985) must be reachable. Scale: 1 to 100+ hosts.

### UC-5: Batch Tool Deployment via Browser Integration

**Actor:** Analyst clicking a `quickair://` link from any source (Report, case tool, bookmark).
**Flow:** QuickAiRLaunch.ps1 opens (single-instance), decodes job batch, launches Executor per job with concurrent limit.
**Constraint:** URI handler must be registered. WinForms required on analyst machine.

### UC-6: Offline Analysis and Fleet Comparison

**Actor:** Analyst reviewing collected data, possibly on a different machine or later.
**Flow:** Open Report.html, drag-drop JSON files. Fleet comparison + per-host drill-down.
**Constraint:** Must work fully offline (file:// protocol). Must handle JSON from different collection runs.

### UC-7: Domain Controller Enumeration

**Actor:** Analyst investigating AD compromise.
**Flow:** Standard collection. Users module auto-detects DC role and enumerates all domain accounts (Get-ADUser with ADSI fallback).
**Constraint:** Must not break on DCs without RSAT tools installed.

### Edge Cases

| Edge Case | Required Handling |
|-----------|-------------------|
| No WinRM on target | Collector first attempts better diagnostics (why WinRM failed — firewall, service disabled, port blocked, auth issue) and attempts auto-fix if possible. If WinRM cannot be established, fall back to WMI-based collection via the same SMB+WMI chain the Executor uses. |
| Target goes offline mid-collection | Partial data should not be silently lost. Per-module error tracking in manifest. |
| Mixed domains / trust issues | Credential handling per target. Clear error reporting when auth fails. |
| PS 2.0 target (Server 2008 R2) | All target-side code must have PS 2.0 fallback. Output structure identical. |
| Unknown environment | Capability probe before collection. Adapt method automatically. |
| WDAC / AppLocker blocking Add-Type | Graceful failure with logged error. Never crash the collection. |
| Large fleet (100+ hosts) | Sequential collection is acceptable for v1. Must complete reliably. |

---

## 3. Functional Requirements

### FR-1: Remote Tool Execution (Primary Value)

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-1.1 | Transfer binary to remote target and verify SHA256 match on arrival | MUST |
| FR-1.2 | Auto-chain remote access: WinRM → SMB+WMI → FAILED | MUST |
| FR-1.3 | Launch binary on target and capture PID | MUST |
| FR-1.4 | Alive-check after configurable delay (default 10s) — confirms the tool launched and is running, NOT that it completed successfully | MUST |
| FR-1.5 | SFX binary detection (ZIP, RAR, 7zip, NSIS, Inno Setup) | SHOULD |
| FR-1.6 | State machine with clear terminal states: ALIVE, SFX_LAUNCHED, CONNECTION_FAILED, TRANSFER_FAILED, LAUNCH_FAILED | MUST |
| FR-1.7 | Write execution result JSON with state history | MUST |

### FR-2: Job Manager (QuickAiRLaunch)

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-2.1 | Accept job batches via `quickair://` URI with base64-encoded JSON | MUST |
| FR-2.2 | Single-instance enforcement via named mutex | MUST |
| FR-2.3 | WinForms grid showing job status with real-time updates | MUST |
| FR-2.4 | Configurable max concurrent jobs (default 5) | MUST |
| FR-2.5 | Thread-safe job queue with forward-only status transitions | MUST |
| FR-2.6 | Input validation: forbidden characters in paths, target hostname format | MUST |
| FR-2.7 | Credential caching per domain/hostname during session (in-memory only) | SHOULD |
| FR-2.8 | Self-elevate to Administrator if not already elevated | MUST |

### FR-3: Report as Primary Interface

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-3.1 | Single-file offline HTML with zero external dependencies | MUST |
| FR-3.2 | Load JSON files via drag-drop or file picker | MUST |
| FR-3.3 | Trigger volatile collection from the Report (no CLI needed) | MUST |
| FR-3.4 | Trigger tool deployment to specific hosts from the Report | MUST |
| FR-3.5 | Display tool deployment status in the Report | MUST |
| FR-3.6 | Fleet tab: host comparison with OS, PS version, artifact counts, error counts | MUST |
| FR-3.7 | Processes tab: virtual-scroll table, all fields, expandable rows, cross-links | MUST |
| FR-3.8 | Network tab: TCP+UDP connections, DNS match, filters (established/listeners/external) | MUST |
| FR-3.9 | DLLs tab: per-process listing with hash, signature, private path flag | MUST |
| FR-3.10 | DNS tab: cache entries with type and TTL | MUST |
| FR-3.11 | Users tab: cross-host SID correlation, first/last logon, confidence badges | MUST |
| FR-3.12 | Manifest tab: collection metadata, sources, errors | MUST |
| FR-3.13 | Execute tab: tool deployment results | MUST |
| FR-3.14 | Cross-module navigation: PID links between Processes, Network, and DLLs | MUST |
| FR-3.15 | Column sorting and global search | MUST |
| FR-3.16 | Handle null/sparse data gracefully (PS 2.0 output, access-denied fields) | MUST |
| FR-3.17 | Intuitive for mixed-skill team (junior SOC to senior IR) | MUST |
| FR-3.18 | All timestamps displayed in UTC with unambiguous format | MUST |

### FR-4: Process Collection

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-4.1 | Collect PID, PPID, Name, CommandLine, ExecutablePath, CreationDateUTC | MUST |
| FR-4.2 | Collect WorkingSetSize, VirtualSize, SessionId, HandleCount | MUST |
| FR-4.3 | Collect process Owner (domain\user) | MUST |
| FR-4.4 | Collect IntegrityLevel via P/Invoke token query, with error reporting | MUST |
| FR-4.5 | Compute SHA256 of executable at collection time, per process, no caching | MUST |
| FR-4.6 | Validate Authenticode signature (full chain on PS 3+, cert-present on PS 2.0) | MUST |
| FR-4.7 | Cross-validate: CIM/WMI list vs .NET GetProcesses() — flag DKOM anomalies | MUST |
| FR-4.8 | Three-tier collection: CIM → WMI → .NET fallback | MUST |
| FR-4.9 | CreationDate: DMTF to UTC ISO 8601 with timezone from capability probe | MUST |
| FR-4.10 | Record `source` field per process (cim, wmi, dotnet_fallback) | MUST |

### FR-5: Network Collection

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-5.1 | Collect TCP connections: Local/Remote Address+Port, State, OwningProcess, InterfaceAlias, CreationTime | MUST |
| FR-5.2 | Collect UDP endpoints: LocalAddress, LocalPort, OwningProcess | MUST |
| FR-5.3 | Collect DNS cache: Entry, Name, Data, Type, TTL | MUST |
| FR-5.4 | Collect network adapters: Name, Alias, IPs, MAC, Gateway, DNS, DHCP | MUST |
| FR-5.5 | DNS enrichment: match RemoteAddress to DNS cache without active queries | MUST |
| FR-5.6 | Interface alias resolution per connection | MUST |
| FR-5.7 | Private IP classification | MUST |
| FR-5.8 | Three-tier collection: CIM → netstat → legacy cmd | MUST |

### FR-6: User Collection

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-6.1 | Enumerate profiles from registry with SID, Username, ProfilePath, loaded state | MUST |
| FR-6.2 | Enumerate local accounts with Disabled status | MUST |
| FR-6.3 | FirstLogon triangulation: profile folder, NTUSER.DAT, registry key LastWrite | MUST |
| FR-6.4 | Confidence scoring: HIGH (3 agree) / MEDIUM (2) / LOW (1) / ? (none) | MUST |
| FR-6.5 | AccountType classification by SID: Local, Domain, System, Service | MUST |
| FR-6.6 | Machine SID derivation | MUST |
| FR-6.7 | DC detection and domain account enumeration (Get-ADUser + ADSI fallback) | MUST |
| FR-6.8 | SID is primary cross-host correlation key | MUST |

### FR-7: DLL Collection

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-7.1 | Enumerate loaded modules per process: PID, Name, Path | MUST |
| FR-7.2 | SHA256 hash per DLL | MUST |
| FR-7.3 | FileVersion and Company from version info | MUST |
| FR-7.4 | Authenticode signature per DLL | MUST |
| FR-7.5 | Private/suspicious path detection (Temp, AppData, Downloads, etc.) | MUST |
| FR-7.6 | Skip protected processes with explicit logging | MUST |
| FR-7.7 | PS 2.0 fallback via WMI | MUST |

### FR-8: Orchestration

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-8.1 | Auto-discover collector plugins from `Modules\Collectors\*.psm1` | MUST |
| FR-8.2 | Capability probe each target: PS version, OS, CIM availability, timezone | MUST |
| FR-8.3 | Retry capability probe up to 3 times | MUST |
| FR-8.4 | Single shared WinRM session per target | MUST |
| FR-8.5 | Per-collector failure isolation — never abort the run | MUST |
| FR-8.6 | Manifest with hostname, timestamps, versions, sources, errors | MUST |
| FR-8.7 | JSON output with embedded SHA256 integrity hash | MUST |
| FR-8.8 | When WinRM fails, provide clear diagnostics (reason: firewall, service disabled, port blocked, auth failure) | MUST |
| FR-8.9 | When WinRM cannot be established, fall back to WMI-based remote collection (SMB+WMI chain) | MUST |
| FR-8.10 | Collect from multiple targets in parallel (configurable concurrency limit) instead of sequentially | MUST |
| FR-8.11 | Revert WinRM TrustedHosts after each target — remove only the entry that was added, leave pre-existing entries intact | MUST |

---

## 4. Non-Functional Requirements

All three hard constraints are **equally non-negotiable**:

### NFR-1: No Forensic Noise
- Target filesystem must not be modified during collection.
- Target registry must not be modified.
- Target event log must not be written to.
- Exception: `Add-Type` may create temporary assemblies (accepted as unavoidable for IntegrityLevel).
- Exception: Executor explicitly writes to target by design (file transfer + execution).

### NFR-2: Works Everywhere
- **Analyst machine:** Windows (PowerShell 5.1+) or Linux (PowerShell 7+ / native shell).
- **Windows targets:** Server 2008 R2 (PS 2.0) through Windows 11 / Server 2025.
- **Linux targets:** Major distributions with SSH access. Scope and collection methods TBD.
- All collection paths must produce structurally identical output. Missing fields are null, never absent.
- Must handle unknown environments: probe first, adapt automatically, fail gracefully.

### NFR-3: No External Dependencies
- Zero tools, binaries, or modules required on targets beyond base Windows.
- No downloads, no package managers, no external API calls.
- Report.html works fully offline (file:// protocol), no CDN, no server.

### NFR-4: Performance
- Single host collection: under 120 seconds for typical endpoint.
- Report: 10,000+ rows via virtual scrolling without lag.
- SHA256: path-based cache to avoid redundant hashing.

### NFR-5: Usability
- Intuitive for mixed-skill teams (junior SOC through senior IR).
- Report.html is the primary interface — analyst should not need CLI for standard workflow.
- Clear error messages when things fail (connection, auth, capability).

### NFR-6: Data Integrity
- JSON output includes SHA256 of pre-hash serialization.
- Executor verifies SHA256 of transferred binaries.
- All timestamps UTC ISO 8601 everywhere (PS, JSON, HTML).

### NFR-7: Security
- No credentials stored to disk. Session-only in-memory caching.
- URI handler input validated for injection.
- Forward-only job status transitions.

### NFR-8: Extensibility
- New collectors: drop `.psm1` in `Modules\Collectors\`, export `Invoke-Collector`.
- New executors: export `Invoke-Executor`.
- New report tabs: add stage file in `ReportStages\`.

---

## 5. Out of Scope

1. **Disk forensic collection** — registry hives, event logs, prefetch, MFT, shimcache, amcache.
2. **Memory acquisition** — QuickAiR deploys memory tools but does not dump/analyze memory.
3. **Automated anomaly detection or scoring** — explicitly out of scope for v1.
4. **EDR/AV integration.**
5. **macOS support.**
6. **VirusTotal or threat intel lookups** — SHA256 collected for offline lookup only.
7. **Real-time monitoring** — point-in-time snapshot only.
8. **Chain-of-custody management** — SHA256 integrity provided, formal chain-of-custody is not.
9. **Monitoring deployed tool completion** — QuickAiR verifies that tools launched successfully (process is alive), but does not monitor whether disk/memory collection tools finish successfully or collect their output.

---

## 6. Open Questions

### OQ-1: Collection from Report.html
FR-3.3 requires triggering volatile collection from the Report. The `quickair://` URI currently handles Executor jobs only. Extending the URI scheme (e.g., `quickair://collect?targets=...`) is one option. Design TBD.

### OQ-2: WinRM HTTPS Support
Port 5985 (HTTP) is hardcoded. Many enterprises mandate HTTPS (port 5986). Should `-UseSSL` be supported?

### OQ-3: Partial Collection Recovery
If a session drops mid-collection, partial data is lost. Per-module error tracking exists but partial results are not written. Should they be?

### OQ-5: Add-Type and WDAC
IntegrityLevel and RegLwt use `Add-Type` on the target. WDAC-enforced targets will block this. Is graceful failure sufficient, or should an alternative path exist?

### OQ-6: PS 2.0 Signature Fidelity
PS 2.0 produces `PS2_CERT_PRESENT` (can't validate chain). Should the Report visually distinguish this from fully validated signatures?

### OQ-7: SID History / Multi-Domain
User correlation uses bare SID. Migrated users with SID history appear as separate identities. Is this acceptable?

### OQ-9: Future Collector Modules
Current four modules (Processes, Network, Users, DLLs) are sufficient for v1. Candidates for future modules:
- Services (persistence detection)
- Scheduled Tasks (persistence)
- Startup Items (Run/RunOnce keys)
- WMI Subscriptions (persistence)
- Named Pipes (C2 detection)
- Installed Software (vulnerability context)

### OQ-10: Linux Support Scope
The vision includes both Windows and Linux targets. The current codebase is entirely Windows-based (WMI, CIM, WinRM, Win32 P/Invoke). Key design questions:
- What remote access method for Linux? SSH is the obvious answer but requires a different session model.
- What volatile artifacts on Linux? `/proc` filesystem (processes, network), `/etc/passwd` (users), loaded shared libraries, DNS from `systemd-resolve` or `/etc/resolv.conf`.
- Should the collector be PowerShell 7 cross-platform, or native bash/python on Linux targets?
- Should the Executor support Linux tool deployment (SCP + SSH exec)?
- How does the Report handle mixed Windows+Linux fleet data in the same view?

### OQ-11: Report Data Freshness
No mechanism to warn about stale data. Loading a 3-day-old JSON alongside a fresh one may mislead. Should collection age be surfaced?

---

*End of Requirements Specification*
