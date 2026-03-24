# Phase 1: Coverage Matrix - Research

**Researched:** 2026-03-24
**Domain:** DFIR toolkit artifact coverage documentation — PowerShell collector fallback tiers, data field fidelity, and coverage gaps
**Confidence:** HIGH (all findings derived directly from collector source files)

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01:** Three-tier model: PS 2.0 (legacy WMI/cmd), PS 3+ without full CIM namespaces (CIM available but NetTCPIP/DNSClient may be absent), and PS 5.1 (full CIM with all namespaces). Tier boundary is PS version >= 3 for CIM availability; HasNetTCPIP and HasDNSClient flags determine sub-tier behavior within PS 3+.
- **D-02:** Column layout per artifact row: Artifact | Data Fields | PS 5.1 (Full CIM) | PS 3+ (Partial CIM) | PS 2.0 (Legacy) | Fidelity Notes | Coverage Gaps
- **D-03:** Each collector's fallback chain must be documented individually — they are NOT uniform.
- **D-04:** Network TCP paths: CIM MSFT_NetTCPConnection (HasNetTCPIP) -> netstat -ano via PowerShell (PS>=3) -> cmd /c netstat -ano (PS 2.0). Network DNS paths: CIM MSFT_DNSClientCache (HasDNSClient) -> ipconfig /displaydns via PS (PS>=3) -> cmd /c ipconfig /displaydns (PS 2.0).
- **D-05:** DLLs paths: .NET System.Diagnostics.Process.GetProcesses() + .Modules (PS 3+) -> WMI CIM_ProcessExecutable / Win32_ProcessVMMapsFiles association classes (PS 2.0). These are entirely different enumeration mechanisms.
- **D-06:** Users: Single WMI + Registry scriptblock at all PS versions. Only branching is DC detection: Get-ADUser -> ADSI DirectorySearcher fallback.
- **D-07:** Processes: CIM Win32_Process (PS 3+) vs WMI Get-WmiObject Win32_Process (PS 2.0), both supplemented with .NET cross-check for processes missed by WMI/CIM.
- **D-08:** Document specific field-level losses at each tier, not just "degraded." Every fidelity note must name the exact fields affected and what value they degrade to.
- **D-09:** Processes PS 2.0/WMI Signature: loses IsValid, Thumbprint, NotAfter, TimeStamper (only PS2_SIGNED/PS2_UNSUPPORTED status). .NET fallback entries lose ParentProcessId, CommandLine, SessionId, HandleCount (all null).
- **D-10:** Network netstat fallback: InterfaceAlias derived from IP matching (not CIM-native), less precise. CreationTime always null. PID correlation preserved in netstat -ano but parsing is regex-based.
- **D-11:** DNS ipconfig fallback: numeric Type field replaced with string representation. TTL parsing is regex-based and may vary across Windows versions.
- **D-12:** DLLs PS 2.0/WMI: Signature detail limited (same PS2 limitation as Processes). FileVersion/Company sourced from WMI CIM_DataFile instead of .NET FileVersionInfo.
- **D-13:** DLLs collector skips protected processes (lsass, csrss, smss, wininit, System, Idle) at ALL tiers — these are never enumerated.
- **D-14:** .NET fallback process entries lose ParentProcessId, CommandLine, SessionId, HandleCount — process tree reconstruction is impossible for these entries.
- **D-15:** Network netstat path cannot provide connection creation timestamps.
- **D-16:** Users local/profile collection has no PS-version degradation. DC domain account collection: Get-ADUser -> ADSI fallback where ADSI lastlogontimestamp is replicated only every ~14 days.
- **D-17:** Document what the toolkit does NOT collect at any tier: no event logs, no registry hives, no memory dumps, no file system artifacts.

### Claude's Discretion

- Exact markdown table formatting and whether to use one large table or per-collector sub-tables
- Whether to include a visual legend/key at the top of the document
- Ordering of artifacts in the matrix (alphabetical vs data-flow order)
- Whether fidelity notes go in a dedicated column or as footnotes

### Deferred Ideas (OUT OF SCOPE)

- PS version compatibility matrix per collector module (v2 requirement COV-05)
- Data field inventory per artifact per fallback tier with exact property names (v2 requirement COV-06)
- MITRE ATT&CK mapping of collected artifacts — out of scope per PROJECT.md
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| COV-01 | Artifact x data source grid covering all collectors (Processes, Network, DNS, DLLs, Users) | Source files read for all five collectors; exact collection method names (cim, wmi, netstat, ipconfig, dotnet) verified |
| COV-02 | Fallback path columns showing PS version tiers and collection method per artifact | Three-tier decision logic verified in Connection.psm1 (Get-TargetCaps) and each collector's Invoke-Collector |
| COV-03 | Coverage gap column — explicit gaps (no event logs, no registry, no RAM, DLL/Users fallback limitations) | Protected process list hardcoded in DLLs.psm1; Users DC ADSI replication lag verified in source; toolkit scope gaps from CLAUDE.md |
| COV-04 | Fidelity notes per fallback tier (e.g., netstat path loses PID correlation, DNS fallback loses TTL) | All field-level losses verified by reading scriptblock output schemas in each .psm1 file |
</phase_requirements>

---

## Summary

This phase produces `docs/COVERAGE-MATRIX.md` — a markdown reference document for analysts. The document is entirely derived from the four collector source files (`Processes.psm1`, `Network.psm1`, `DLLs.psm1`, `Users.psm1`) and the capability probe in `Connection.psm1`. No external research is needed: the source code is the authoritative specification.

The capability probe in `Connection.psm1` (`Get-TargetCaps`) establishes the tier boundary decision tree: PSVersion >= 3 enables CIM (`HasCIM = true`); within PS 3+, the presence of `ROOT/StandardCimv2` CIM classes `MSFT_NetTCPConnection` and `MSFT_DNSClientCache` determines `HasNetTCPIP` and `HasDNSClient` respectively. These two flags are independent of each other and of the base PS version tier — a PS 5.1 target can have `HasNetTCPIP = false` if the NetTCPIP module is absent (e.g., Server Core minimal install).

The five collectors divide into two groups by branching complexity: Processes and Network have multi-tier branching with meaningful fidelity loss at each step; DLLs uses a binary .NET vs. WMI split with completely different enumeration mechanisms; Users has no PS-version branching at all for local/profile collection, only a DC-specific branch for domain accounts.

**Primary recommendation:** Write the document with per-collector subsections (not one giant flat table) because the branching logic and fidelity losses differ enough across collectors that a single monolithic table would obscure critical distinctions. Use the `source` field string values from each collector as the canonical method names in the matrix.

---

## Standard Stack

This phase produces markdown documentation, not code. There is no library stack to install.

| Component | Value | Notes |
|-----------|-------|-------|
| Output format | Markdown (.md) | Must render on GitHub and local editors per CLAUDE.md constraints |
| Output path | `docs/COVERAGE-MATRIX.md` | `docs/` directory does not yet exist — must be created |
| Source of truth | Collector .psm1 files | Read directly; codebase map summary is NOT sufficient |
| Cross-reference targets | Phase 2 (RUNBOOK.md), Phase 3 (INTERPRET.md) | Heading anchors must be stable |

---

## Architecture Patterns

### Document Structure (Recommended)

```
docs/COVERAGE-MATRIX.md
├── Legend / Key (tier definitions, confidence notation)
├── Tier Model Overview (PS 2.0 / PS 3+ Partial / PS 5.1 Full CIM)
├── Capability Probe (how tiers are detected at runtime)
├── Per-Collector Sections:
│   ├── Processes
│   ├── Network — TCP Connections
│   ├── Network — DNS Cache
│   ├── DLLs
│   └── Users
└── Toolkit-Wide Coverage Gaps (what is never collected at any tier)
```

### Tier Model (verified from Connection.psm1 Get-TargetCaps)

| Tier Name | Condition | CIM Classes Available |
|-----------|-----------|----------------------|
| PS 5.1 / Full CIM | PSVersion >= 3 AND HasNetTCPIP=true AND HasDNSClient=true | Win32_Process, MSFT_NetTCPConnection, MSFT_DNSClientCache |
| PS 3+ / Partial CIM | PSVersion >= 3 AND (HasNetTCPIP=false OR HasDNSClient=false) | Win32_Process (CIM), but netstat/ipconfig for Network/DNS |
| PS 2.0 / Legacy | PSVersion < 3 | No CIM; WMI Win32_Process, cmd netstat, cmd ipconfig |

**Important nuance verified in source:** `HasNetTCPIP` and `HasDNSClient` are probed independently. A PS 5.1 target can fail one probe but pass the other. Each Network sub-collector (TCP and DNS) branches independently on its own flag.

### Pattern: Per-Collector Sub-Tables

Each collector section should show:
1. A fallback chain table (which method at which tier, with the exact `source` string value from code)
2. A data fields table (which fields are populated at each tier, what null/degraded values appear)
3. A coverage gaps cell (explicit named gaps for that artifact)

---

## Collector-by-Collector Findings

### Processes (verified from Processes.psm1)

**Fallback chain:**
| Tier | Method | `source` field value |
|------|--------|---------------------|
| PS 3+ | `Get-CimInstance Win32_Process` | `cim` |
| PS 2.0 | `ManagementObjectSearcher Win32_Process` (WMI) | `wmi` |
| Any tier (supplement) | `[System.Diagnostics.Process]::GetProcesses()` | `dotnet_fallback` |

**dotnet_fallback trigger:** Any PID in .NET GetProcesses() that is absent from the WMI/CIM list is added with `source = 'dotnet_fallback'`. This runs at BOTH the CIM and WMI tiers. Combined source strings: `cim+dotnet_fallback` or `wmi+dotnet_fallback`.

**Field fidelity by tier (verified from scriptblock output schemas):**

| Field | CIM (PS 3+) | WMI (PS 2.0) | dotnet_fallback |
|-------|------------|--------------|-----------------|
| ProcessId | populated | populated | populated |
| ParentProcessId | populated | populated | **null** |
| Name | populated | populated | populated (ProcessName) |
| CommandLine | populated | populated | **null** |
| ExecutablePath | populated | populated | populated (MainModule.FileName) |
| CreationDateUTC | populated (UTC) | populated (WMI DMTF converted) | populated (StartTime UTC) |
| WorkingSetSize | populated | populated | populated (WorkingSet64) |
| VirtualSize | populated | populated | populated (VirtualMemorySize64) |
| SessionId | populated | populated | **null** |
| HandleCount | populated | populated | **null** |
| SHA256 | populated | populated | populated if path available |
| Signature.IsValid | populated (bool) | **null** | populated (PS3+) or null (PS2) |
| Signature.Thumbprint | populated | **null** | populated (PS3+) or null (PS2) |
| Signature.NotAfter | populated | **null** | populated (PS3+) or null (PS2) |
| Signature.TimeStamper | populated | **null** | populated (PS3+) or null (PS2) |
| Signature.Status | populated (e.g. "Valid") | `PS2_SIGNED` or `PS2_UNSUPPORTED` | populated (PS3+) |
| Signature.SignerSubject | populated | populated (Subject only, from X509Certificate) | populated (PS3+) |

**Signature in PS 2.0 WMI path detail (from source):**
- Uses `X509Certificate.CreateFromSignedFile()` — no `Get-AuthenticodeSignature`
- If file is signed: `IsSigned=true`, `Status='PS2_SIGNED'`, SignerSubject populated, all other fields null
- If file is not signed or throws: `IsSigned=null`, `Status='PS2_UNSUPPORTED'`, all fields null
- Fields permanently null at PS 2.0: `IsValid`, `Thumbprint`, `NotAfter`, `TimeStamper`, `SignerCompany`

**Coverage gaps for Processes:**
- `dotnet_fallback` entries: ParentProcessId=null, CommandLine=null, SessionId=null, HandleCount=null — process tree reconstruction impossible for these entries
- PS 2.0 Signature is binary (signed/not-signed), not certificate-validated

---

### Network — TCP Connections (verified from Network.psm1)

**Fallback chain:**
| Tier | Condition | Method | `source.network` value |
|------|-----------|--------|------------------------|
| Full CIM | HasNetTCPIP=true | `Get-CimInstance MSFT_NetTCPConnection` (ROOT/StandardCimv2) | `cim` |
| PS 3+ partial | PSVersion>=3, HasNetTCPIP=false | `& netstat -ano` (PowerShell invocation) | `netstat_fallback` |
| PS 2.0 | PSVersion<3 | `cmd /c "netstat -ano"` | `netstat_legacy` |

**Field fidelity by tier:**

| Field | CIM | netstat_fallback / netstat_legacy |
|-------|-----|----------------------------------|
| LocalAddress | populated | populated (regex parse) |
| LocalPort | populated | populated (regex parse) |
| RemoteAddress | populated | populated (regex parse) |
| RemotePort | populated | populated (regex parse) |
| OwningProcess (PID) | populated | populated (regex parse, last column) |
| State | populated (converted from int via ConvertFrom-TcpStateInt) | populated (string from netstat, e.g. ESTABLISHED) |
| InterfaceAlias | CIM-native field | **derived** via IP-to-adapter matching (Resolve-InterfaceAlias); unknown IPs → `UNKNOWN` |
| CreationTime | **always null** (not in CIM output) | **always null** |
| ReverseDns | populated (post-collection DNS lookup) | populated (same post-collection step) |
| DnsMatch | populated (DNS cache cross-reference) | populated (same step) |
| IsPrivateIP | populated | populated |

**Key fidelity detail:** `CreationTime` is null at ALL tiers. The CIM class `MSFT_NetTCPConnection` does not expose connection creation time. This is documented in CONTEXT.md D-15 but is confirmed in the code: the field is initialized to `$null` and never set.

**InterfaceAlias at netstat tiers:** `Resolve-InterfaceAlias` builds an IP-to-alias map from the adapter list, then matches each connection's LocalAddress. Unmatched addresses get `UNKNOWN`. Loopback gets `LOOPBACK`. All-interfaces (0.0.0.0 or ::) get `ALL_INTERFACES`. This is less precise than the CIM-native `$c.InterfaceAlias`.

**Known bug (from CONCERNS.md):** Netstat parsing on PS 2.0 targets (Windows Server 2008 R2) may miss short-lived connections on high-churn workloads. The T3 test allows a 10% miss rate for legacy OS.

---

### Network — DNS Cache (verified from Network.psm1)

**Fallback chain:**
| Tier | Condition | Method | `source.dns` value |
|------|-----------|--------|-------------------|
| Full CIM | HasDNSClient=true | `Get-CimInstance MSFT_DNSClientCache` (ROOT/StandardCimv2) | `cim` |
| PS 3+ partial | PSVersion>=3, HasDNSClient=false | `& ipconfig /displaydns` + regex parse | `ipconfig_fallback` |
| PS 2.0 | PSVersion<3 | `cmd /c "ipconfig /displaydns"` + regex parse | `ipconfig_legacy` |

**Field fidelity by tier:**

| Field | CIM | ipconfig_fallback / ipconfig_legacy |
|-------|-----|-------------------------------------|
| Entry | populated | populated (regex: "Record Name") |
| Name | populated | populated (same as Entry) |
| Data | populated | populated (IP address from "Host Record") |
| Type | **integer** (e.g., 1=A, 28=AAAA) | **string** from ipconfig output (e.g., "1 (A)" or similar) |
| TTL | **integer** | **integer** (regex parse of "Time To Live" line) |

**Type field detail (from DNS_PARSE_SB in source):** The ipconfig parser captures the raw "Record Type" text from ipconfig output. This is the string that Windows prints (e.g., a numeric string like "1"), not a typed integer. The CIM path stores `[int]$d.Type`. These values are not guaranteed to be identical in format.

**TTL parsing risk (from CONTEXT.md D-11, confirmed in source):** TTL is extracted via `Time To Live[\s.]*:[\s]*(\d+)` regex. Windows ipconfig output formatting has varied across OS versions. If the format changes, TTL may be 0 or incorrect.

---

### DLLs (verified from DLLs.psm1)

**Fallback chain:**
| Tier | Condition | Method | `source` value per entry |
|------|-----------|--------|--------------------------|
| PS 3+ | PSVersion>=3 | `[System.Diagnostics.Process]::GetProcesses()` + `.Modules` | `dotnet` |
| PS 2.0 | PSVersion<3 | `Win32_ProcessVMMapsFiles` WMI association, with fallback to `CIM_ProcessExecutable` | `wmi` |

**This is a completely different enumeration mechanism at each tier** — not a degraded version of the same API.

**Protected process exclusion (hardcoded in BOTH scriptblocks):**
```
$PROTECTED_PROCS = @('lsass','csrss','smss','wininit','System','Idle')
```
These six process names are skipped at ALL tiers. The .NET path uses exact case-insensitive name match. The WMI path strips `.exe` extension before comparing. This list is hardcoded at two locations in `DLLs.psm1` (lines ~39 and ~172).

**Field fidelity by tier:**

| Field | .NET dotnet (PS 3+) | WMI (PS 2.0) |
|-------|---------------------|--------------|
| ProcessId | populated | populated |
| ProcessName | populated | populated |
| ModuleName | populated (.ModuleName) | populated (filename from path) |
| ModulePath | populated (.FileName) | populated (from WMI association object) |
| FileVersion | populated ([FileVersionInfo]::GetVersionInfo) | populated (CIM_DataFile.Version) |
| Company | populated (FileVersionInfo.CompanyName) | populated (CIM_DataFile.Manufacturer) |
| FileHash (SHA256) | populated | populated |
| IsPrivatePath | populated (checks \Temp\, \AppData\, \ProgramData\, \Users\Public\, \Downloads\) | populated (same logic) |
| Signature.IsValid | populated (bool) | **null** |
| Signature.Thumbprint | populated | **null** |
| Signature.NotAfter | populated | **null** |
| Signature.TimeStamper | populated | **null** |
| Signature.Status | populated (e.g. "Valid") | `PS2_SIGNED` or `PS2_UNSUPPORTED` |
| Signature.SignerSubject | populated | populated (X509 Subject only) |
| LoadedAt | **always null** (neither API provides load timestamp) | **always null** |

**FileVersion/Company source difference:** .NET path uses `System.Diagnostics.FileVersionInfo` (file metadata). WMI path uses `Get-WmiObject CIM_DataFile` (WMI database). These may differ for files where the WMI database is stale or incomplete.

**WMI association query method:** The PS 2.0 path tries `Win32_ProcessVMMapsFiles` first, then falls back to `CIM_ProcessExecutable`. If both fail, emits a stub entry with `reason = 'WMI_UNAVAILABLE'` and no module data.

**Coverage gaps for DLLs:**
- Protected process list (lsass, csrss, smss, wininit, System, Idle) — never enumerated at any tier
- `LoadedAt` is null at all tiers — no DLL load timestamp available
- Processes where `.Modules` access throws ACCESS_DENIED (.NET path) produce a stub entry with reason='ACCESS_DENIED' and no module data

---

### Users (verified from Users.psm1)

**Key architectural fact:** The entire `$script:USERS_SB` scriptblock runs at ALL PS versions without branching on PSVersion. The scriptblock uses `Get-WmiObject` (not `Get-CimInstance`) throughout — this is PS 2.0-compatible and works identically on PS 2.0 through PS 5.1.

**Collection sub-components:**

| Sub-component | Method | PS version dependency |
|---------------|--------|-----------------------|
| System info (is_dc, domain, machine name) | `Get-WmiObject Win32_ComputerSystem` | None — WMI at all tiers |
| Machine SID prefix | `Get-WmiObject Win32_UserAccount` | None — WMI at all tiers |
| User profiles | `HKLM:\...\ProfileList` registry enumeration | None — Microsoft.Win32.Registry API |
| Profile FirstLogon timestamps | ProfileFolder mtime + NTUSER.DAT mtime + Registry LastWriteTime | None — file system + registry |
| Local accounts | `Get-WmiObject Win32_UserAccount -Filter "LocalAccount=True"` | None — WMI at all tiers |
| DC domain accounts | `Get-ADUser` (preferred) -> ADSI DirectorySearcher (fallback) | None — PS version independent |

**`source` field construction (from Invoke-Collector):**
- Non-DC: `source = 'WMI'`
- DC with Get-ADUser: `source = 'WMI+Get-ADUser'`
- DC with ADSI fallback: `source = 'WMI+ADSI'`

**DC domain account fidelity (Get-ADUser vs ADSI):**

| Field | Get-ADUser | ADSI (DirectorySearcher) |
|-------|-----------|--------------------------|
| SamAccountName | populated | populated |
| DisplayName | populated | populated |
| SID | populated | populated (byte array converted to SecurityIdentifier) |
| Enabled | populated | derived from userAccountControl flag (bit 2) |
| WhenCreatedUTC | populated | populated (whencreated attribute) |
| LastLogonUTC | populated (LastLogonDate — replicated) | populated (lastlogontimestamp — replicated, ~14-day lag) |
| PasswordLastSetUTC | populated | populated (pwdlastset FILETIME) |
| LockedOut | populated | derived from lockouttime > 0 |
| BadLogonCount | populated | populated (badpwdcount) |

**Replication lag detail (from CONTEXT.md D-16, confirmed in source):** ADSI uses `lastlogontimestamp` attribute, which Active Directory replicates only every ~14 days by default. `Get-ADUser` uses `LastLogonDate`, which is also derived from `lastlogontimestamp` — so both suffer the same replication lag. Neither Get-ADUser nor ADSI provides real-time `lastLogon` (per-DC, non-replicated). This is a fundamental AD limitation, not a collector bug.

**Coverage gaps for Users:**
- No PS-version-dependent degradation for local/profile collection — same fields at all tiers
- DC domain account LastLogon has ~14-day replication lag regardless of Get-ADUser vs ADSI
- No session enumeration (logged-on users / active sessions) — collection is account inventory, not session state

---

### Toolkit-Wide Coverage Gaps (from CLAUDE.md + CONTEXT.md D-17)

The following artifact types are NEVER collected at any tier:

| Gap | Notes |
|-----|-------|
| Windows Event Logs | Explicitly out of scope |
| Registry hives (raw) | Registry is read only for ProfileList key during Users collection |
| Memory dumps / RAM contents | Out of scope |
| File system artifacts (file listings, hash scans) | Out of scope |
| Network packet captures | Out of scope |
| Services / scheduled tasks | Not a collector module |
| Autorun / persistence locations | Not a collector module |

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Tier-conditional content in COVERAGE-MATRIX.md | Conditional logic in markdown | Author three explicit columns per artifact | Markdown is static; the matrix IS the tiers |
| Coverage gap statements | Inferring gaps from capability flags | Read CONTEXT.md D-13 through D-17 and code | Gaps are explicitly specified AND verified in source |
| Field names | Guessing from architecture docs | Read the exact field names from each scriptblock's output object | Field names in JSON output differ from WMI property names (e.g., `WorkingSetSize` not `WorkingSet`) |

---

## Common Pitfalls

### Pitfall 1: Confusing the Tier Model for Network
**What goes wrong:** Writing "PS 5.1 uses CIM" as if that's the only differentiator for Network. Actually Network has TWO independent capability flags (`HasNetTCPIP` and `HasDNSClient`), not one. A PS 5.1 target can use CIM for DNS but netstat for TCP, or vice versa.
**Why it happens:** The three-tier framing in D-01 sounds like three clean tiers, but Network has 3 TCP paths AND 3 DNS paths that branch independently.
**How to avoid:** Document Network TCP and Network DNS as separate subsections, each with their own fallback chain table.

### Pitfall 2: Treating dotnet_fallback as a Separate Tier
**What goes wrong:** Creating a fourth tier column for "dotnet_fallback" in the Processes matrix.
**Why it happens:** `dotnet_fallback` appears as a `source` value and has significant field losses.
**How to avoid:** dotnet_fallback is a SUPPLEMENT at both CIM and WMI tiers, not a tier itself. It should be documented as a note within both the PS 3+ and PS 2.0 cells, or as a row in the fidelity table explaining which fields are null when a process appears via .NET fallback.

### Pitfall 3: Stating Users Has No Coverage Gaps
**What goes wrong:** Since Users has no PS-version branching, concluding it has no gaps.
**Why it happens:** "No degradation" != "no gaps."
**How to avoid:** Users has a meaningful gap: DC `LastLogon` has ~14-day replication lag (both Get-ADUser and ADSI). Local collection has no session state. These must appear in the gaps column.

### Pitfall 4: Incorrect DLLs Protected Process List
**What goes wrong:** Listing the protected processes from memory rather than from source.
**Why it happens:** Common security knowledge suggests more processes should be protected.
**How to avoid:** The hardcoded list is exactly: `lsass, csrss, smss, wininit, System, Idle`. These six only. Use this verbatim.

### Pitfall 5: Stating CreationTime is Available for Network at Any Tier
**What goes wrong:** Assuming CIM MSFT_NetTCPConnection provides connection creation timestamps.
**Why it happens:** Other network tools (Sysmon, ETW) do capture connection timestamps.
**How to avoid:** `CreationTime` is explicitly initialized to `$null` and never set in Network.psm1. This is a gap at ALL tiers, including CIM.

### Pitfall 6: Overstating DLLs WMI Path Association Query
**What goes wrong:** Describing only `Win32_ProcessVMMapsFiles` as the PS 2.0 method.
**Why it happens:** D-05 in CONTEXT.md mentions both but may read as primary/backup.
**How to avoid:** The code tries `Win32_ProcessVMMapsFiles` first; if that throws, tries `CIM_ProcessExecutable`. Both use `Antecedent`/`Dependent` traversal. Document both in the method description.

### Pitfall 7: Not Creating the docs/ Directory
**What goes wrong:** Writing to `docs/COVERAGE-MATRIX.md` without creating `docs/`.
**Why it happens:** The directory does not exist yet (verified: `docs/` is absent from the repo).
**How to avoid:** The implementation plan must include creating `docs/` before writing the file.

---

## Code Examples

Verified patterns from source — use these authoritative strings in the matrix:

### Capability Probe Output (Connection.psm1 Get-TargetCaps)
```powershell
# Source: C:/DFIRLab/repo/Modules/Core/Connection.psm1
# Return structure:
@{
    PSVersion             = [int]   # Major version (2, 3, 4, 5)
    HasCIM                = [bool]  # PSVersion >= 3
    HasNetTCPIP           = [bool]  # MSFT_NetTCPConnection accessible
    HasDNSClient          = [bool]  # MSFT_DNSClientCache accessible
    IsServerCore          = [bool]
    TimezoneOffsetMinutes = [int]
}
```

### Authoritative Source String Values (from collector return values)
```
Processes:  'cim', 'wmi', 'cim+dotnet_fallback', 'wmi+dotnet_fallback'
Network TCP: 'cim', 'netstat_fallback', 'netstat_legacy'
Network DNS: 'cim', 'ipconfig_fallback', 'ipconfig_legacy'
DLLs:       'dotnet', 'wmi', 'mixed' (if both appear in same collection)
Users:      'WMI', 'WMI+Get-ADUser', 'WMI+ADSI'
```

### Processes .NET fallback null fields (from PROC_SB_WMI and PROC_SB_CIM)
```powershell
# dotnet_fallback entries always have:
ParentProcessId = $null
CommandLine     = $null
SessionId       = $null
HandleCount     = $null
source          = 'dotnet_fallback'
```

### DLLs Protected Process List (hardcoded in DLLs.psm1 lines ~39 and ~172)
```powershell
$PROTECTED_PROCS = @('lsass','csrss','smss','wininit','System','Idle')
```

---

## State of the Art

This is internal documentation — no external library version tracking required.

| Old Approach | Current Approach | Notes |
|--------------|------------------|-------|
| WMI (`Get-WmiObject`) | CIM (`Get-CimInstance`) | CIM is the preferred path for PS 3+; WMI is the legacy fallback |
| `cmd /c netstat` | `& netstat -ano` then CIM | Three separate TCP collection paths — see fallback chain |

---

## Open Questions

1. **Does Network CIM path ever provide CreationTime?**
   - What we know: `CreationTime` is initialized to `$null` in all code paths; `MSFT_NetTCPConnection` CIM class is not queried for a creation time field.
   - What's unclear: Whether a future Windows version could expose this via the same CIM class.
   - Recommendation: State explicitly in the matrix that CreationTime is unavailable at all tiers. This is not a gap to investigate — it's a confirmed absence.

2. **DLLs `LoadedAt` field**
   - What we know: Set to `$null` in both the .NET and WMI scriptblocks.
   - What's unclear: Whether any Windows API could provide DLL load timestamp.
   - Recommendation: Document as unavailable at all tiers. No investigation needed for this phase.

3. **Users LastLogon replication lag — exact interval**
   - What we know: CONTEXT.md states "~14 days." This is the AD default `ms-DS-Logon-Time-Sync-Interval` value.
   - What's unclear: Whether to state "up to 14 days" or "~14 days" in the matrix.
   - Recommendation: Use "up to 14 days (Active Directory replication default)" for accuracy.

---

## Environment Availability

Step 2.6: SKIPPED — This phase produces only a markdown documentation file. No external tools, runtimes, services, or CLI utilities beyond a text editor are required. The source files are already on disk.

---

## Validation Architecture

`nyquist_validation` is enabled in `.planning/config.json`.

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Custom `TestSuite.ps1` (auto-discovers `Tests\T*.ps1`) |
| Config file | None — runner is `TestSuite.ps1` at repo root |
| Quick run command | `pwsh -File C:/DFIRLab/repo/TestSuite.ps1` (or PowerShell 5.1 equivalent) |
| Full suite command | `pwsh -File C:/DFIRLab/repo/TestSuite.ps1` |

### Phase Requirements -> Test Map

This phase produces a markdown documentation file (`docs/COVERAGE-MATRIX.md`). There are no executable code changes that can be unit-tested by the existing test suite. Validation is editorial (content accuracy) rather than automated (code behavior).

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| COV-01 | docs/COVERAGE-MATRIX.md exists with all 5 artifact sections | smoke (file check) | `Test-Path C:/DFIRLab/repo/docs/COVERAGE-MATRIX.md` | No — Wave 0 |
| COV-02 | All three PS tier columns present for each artifact | editorial review | Manual — grep for "PS 2.0", "PS 3+", "PS 5.1" in file | N/A |
| COV-03 | Coverage gaps section present and names specific gaps | editorial review | Manual — confirm DLLs protected list, Users replication lag, netstat gaps present | N/A |
| COV-04 | Fidelity notes present for each fallback tier | editorial review | Manual — confirm null fields named for dotnet_fallback, PS2 Signature limits | N/A |

### Sampling Rate
- **Per task commit:** `Test-Path C:/DFIRLab/repo/docs/COVERAGE-MATRIX.md` (confirms file created)
- **Per wave merge:** Full editorial review against source file truth (manual)
- **Phase gate:** All four requirements editorially verified before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `docs/` directory — must be created before writing COVERAGE-MATRIX.md
- No test framework gaps — existing `TestSuite.ps1` infrastructure is unaffected by this documentation phase

---

## Project Constraints (from CLAUDE.md)

All directives from CLAUDE.md applicable to this phase:

| Directive | Application to This Phase |
|-----------|--------------------------|
| Format: Markdown files in `docs/` folder, must render on GitHub and local editors | Output target is `docs/COVERAGE-MATRIX.md` |
| Audience: Mixed junior/senior analysts — no deep tool familiarity assumed | Write tier names plainly; define CIM/WMI/netstat before using as column headers |
| Accuracy: All parameters, paths, and behaviors must match current codebase | All content must be derived from source .psm1 files, not README or memory |
| Air-gap: Docs must not reference or require external URLs for core content | No external links in COVERAGE-MATRIX.md |
| All datetimes UTC ISO 8601 everywhere | Timestamps referenced in fidelity notes should use UTC field name conventions |
| SID is primary cross-host user correlation key | Reference this in Users section when documenting account types |
| Never edit Report.html directly | Not applicable to this phase |

---

## Sources

### Primary (HIGH confidence)
- `C:/DFIRLab/repo/Modules/Collectors/Processes.psm1` — Full read; CIM vs WMI branching, .NET fallback, Signature collection per tier, exact null fields
- `C:/DFIRLab/repo/Modules/Collectors/Network.psm1` — Full read; TCP (CIM/netstat) and DNS (CIM/ipconfig) independent fallback chains, InterfaceAlias derivation, DNS parse regex
- `C:/DFIRLab/repo/Modules/Collectors/DLLs.psm1` — Full read; .NET vs WMI enumeration, protected process list (both locations), Signature per tier
- `C:/DFIRLab/repo/Modules/Collectors/Users.psm1` — Full read; WMI+Registry scriptblock, DC detection, Get-ADUser/ADSI fallback, field schema
- `C:/DFIRLab/repo/Modules/Core/Connection.psm1` — Full read; Get-TargetCaps capability probe, exact tier decision logic
- `.planning/phases/01-coverage-matrix/01-CONTEXT.md` — All locked decisions D-01 through D-17
- `.planning/codebase/CONCERNS.md` — Known bugs affecting coverage accuracy (netstat miss rate, silent error suppression)
- `C:/DFIRLab/repo/CLAUDE.md` — Project constraints and conventions

### Secondary (MEDIUM confidence)
- `.planning/codebase/ARCHITECTURE.md` — System overview, verified against source files
- `.planning/REQUIREMENTS.md` — Requirement IDs COV-01 through COV-04

### Tertiary (LOW confidence)
- None — all findings verified against primary source files

---

## Metadata

**Confidence breakdown:**
- Collector fallback chains: HIGH — read directly from Invoke-Collector source
- Field fidelity tables: HIGH — read directly from scriptblock output object definitions
- Coverage gaps: HIGH — gaps are hardcoded in source (protected list) or explicitly documented in CONTEXT.md decisions
- Document structure recommendations: MEDIUM — based on code complexity analysis; Claude's discretion per CONTEXT.md

**Research date:** 2026-03-24
**Valid until:** Valid until collector source files change (no expiry for static codebase documentation)
