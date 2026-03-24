# Phase 1: Coverage Matrix - Context

**Gathered:** 2026-03-24 (assumptions mode)
**Status:** Ready for planning

<domain>
## Phase Boundary

Write docs/COVERAGE-MATRIX.md — an artifact x data source grid showing exactly what each collector gathers, at which fallback tier, the specific collection method used, and where coverage gaps exist. This is a reference document for analysts and for downstream doc authors (Phase 2 Runbook and Phase 3 Interpretation Guide will cross-reference it).

</domain>

<decisions>
## Implementation Decisions

### Fallback Tier Structure
- **D-01:** Use a three-tier model: PS 2.0 (legacy WMI/cmd), PS 3+ without full CIM namespaces (CIM available but NetTCPIP/DNSClient may be absent), and PS 5.1 (full CIM with all namespaces). The tier boundary is PS version >= 3 for CIM availability, with separate capability flags (HasNetTCPIP, HasDNSClient) determining sub-tier behavior within PS 3+.
- **D-02:** Column layout per artifact row: Artifact | Data Fields | PS 5.1 (Full CIM) | PS 3+ (Partial CIM) | PS 2.0 (Legacy) | Fidelity Notes | Coverage Gaps

### Collector-Specific Fallback Chains
- **D-03:** Each collector's fallback chain must be documented individually — they are NOT uniform. Network has the most complex chain (3 TCP paths + 3 DNS paths, each independent). DLLs uses completely different APIs per tier (not degraded CIM). Users has NO PS-version-dependent branching for local/profile collection. Processes branches CIM vs WMI with .NET cross-check supplement at both tiers.
- **D-04:** Network TCP paths: CIM MSFT_NetTCPConnection (HasNetTCPIP) -> netstat -ano via PowerShell (PS>=3) -> cmd /c netstat -ano (PS 2.0). Network DNS paths: CIM MSFT_DNSClientCache (HasDNSClient) -> ipconfig /displaydns via PS (PS>=3) -> cmd /c ipconfig /displaydns (PS 2.0).
- **D-05:** DLLs paths: .NET System.Diagnostics.Process.GetProcesses() + .Modules (PS 3+) -> WMI CIM_ProcessExecutable / Win32_ProcessVMMapsFiles association classes (PS 2.0). These are entirely different enumeration mechanisms.
- **D-06:** Users: Single WMI + Registry scriptblock at all PS versions. Only branching is DC detection: Get-ADUser -> ADSI DirectorySearcher fallback.
- **D-07:** Processes: CIM Win32_Process (PS 3+) vs WMI Get-WmiObject Win32_Process (PS 2.0), both supplemented with .NET cross-check for processes missed by WMI/CIM.

### Data Field Fidelity Degradation
- **D-08:** Document specific field-level losses at each tier, not just "degraded." Every fidelity note must name the exact fields affected and what value they degrade to.
- **D-09:** Key documented losses: Processes PS 2.0/WMI Signature loses IsValid, Thumbprint, NotAfter, TimeStamper (only PS2_SIGNED/PS2_UNSUPPORTED status). Processes .NET fallback entries lose ParentProcessId, CommandLine, SessionId, HandleCount (all null).
- **D-10:** Network netstat fallback: InterfaceAlias derived from IP matching (not CIM-native), less precise. CreationTime always null. PID correlation preserved in netstat -ano but parsing is regex-based.
- **D-11:** DNS ipconfig fallback: numeric Type field replaced with string representation. TTL parsing is regex-based and may vary across Windows versions.
- **D-12:** DLLs PS 2.0/WMI: Signature detail limited (same PS2 limitation as Processes). FileVersion/Company sourced from WMI CIM_DataFile instead of .NET FileVersionInfo.

### Coverage Gaps
- **D-13:** DLLs collector skips protected processes (lsass, csrss, smss, wininit, System, Idle) at ALL tiers — these are never enumerated. This must be called out explicitly.
- **D-14:** Processes .NET fallback (dotnet_fallback source) entries lose ParentProcessId, CommandLine, SessionId, HandleCount — process tree reconstruction is impossible for these entries.
- **D-15:** Network netstat path cannot provide connection creation timestamps.
- **D-16:** Users local/profile collection has no PS-version degradation. DC domain account collection: Get-ADUser -> ADSI fallback where ADSI lastlogontimestamp is replicated only every ~14 days.
- **D-17:** Document what the toolkit does NOT collect at any tier: no event logs, no registry hives, no memory dumps, no file system artifacts. These are explicit out-of-scope gaps.

### Claude's Discretion
- Exact markdown table formatting and whether to use one large table or per-collector sub-tables
- Whether to include a visual legend/key at the top of the document
- Ordering of artifacts in the matrix (alphabetical vs data-flow order)
- Whether fidelity notes go in a dedicated column or as footnotes

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Collector Source Files (PRIMARY — source of truth for all fallback paths)
- `Modules/Collectors/Processes.psm1` — CIM vs WMI branching, .NET fallback, Signature collection per tier
- `Modules/Collectors/Network.psm1` — TCP (CIM/netstat) and DNS (CIM/ipconfig) independent fallback chains, InterfaceAlias derivation
- `Modules/Collectors/DLLs.psm1` — .NET vs WMI enumeration, protected process exclusion list, Signature per tier
- `Modules/Collectors/Users.psm1` — WMI+Registry scriptblock (all tiers), DC detection with Get-ADUser/ADSI fallback

### Core Infrastructure
- `Modules/Core/Connection.psm1` — Capability probe: HasCIM, HasNetTCPIP, HasDNSClient, PSVersion detection, IsServerCore
- `Modules/Core/Output.psm1` — Manifest building, JSON schema, SHA256 hashing

### Codebase Analysis
- `.planning/codebase/ARCHITECTURE.md` — System overview, data flow, collector plugin interface
- `.planning/codebase/CONCERNS.md` — Known bugs and fragile areas affecting coverage accuracy

### Entry Points
- `Collector.ps1` — Orchestrator that auto-discovers and invokes all collector modules

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- Capability probe in Connection.psm1 defines the exact tier boundaries (PSVersion >= 3, HasCIM, HasNetTCPIP, HasDNSClient)
- Each collector's `Invoke-Collector` function documents its own `source` field in the return value, which names the collection method used
- Manifest in Output.psm1 records `Processes_source`, `Network_source` (with sub-keys for network and dns methods) per collection

### Established Patterns
- All collectors follow the same interface: `param(-Session, -TargetPSVersion, -TargetCapabilities)` returning `@{ data=...; source=...; errors=@() }`
- Fallback decisions are made inside each collector, not by the orchestrator — the collector receives capabilities and decides internally
- Protected process list in DLLs.psm1 is hardcoded as `$script:PROTECTED_PROCS` at two locations (PS 3+ path and PS 2.0 path)

### Integration Points
- COVERAGE-MATRIX.md will be cross-referenced by Phase 2 (RUNBOOK.md) for parameter documentation and by Phase 3 (INTERPRET.md) for field definitions
- Matrix headings must be stable anchor targets for cross-document linking in Phase 4

</code_context>

<specifics>
## Specific Ideas

- STATE.md decision: "Read collector .psm1 source files directly before writing matrix — codebase map summary is not sufficient for fallback tier accuracy"
- CONCERNS.md should be consulted for known bugs that affect coverage accuracy
- The `source` field in collector return values (e.g., "cim", "wmi", "netstat", "ipconfig") provides authoritative method names for the matrix

</specifics>

<deferred>
## Deferred Ideas

- PS version compatibility matrix per collector module (v2 requirement COV-05)
- Data field inventory per artifact per fallback tier with exact property names (v2 requirement COV-06)
- MITRE ATT&CK mapping of collected artifacts — out of scope per PROJECT.md

</deferred>

---

*Phase: 01-coverage-matrix*
*Context gathered: 2026-03-24 via assumptions mode*
