# DFIR Artifact Coverage Matrix


## Legend

Use this key to read the tables throughout this document.

### Tier Column Labels

| Column Header | Condition |
|---------------|-----------|
| `PS 5.1 / Full CIM` | PSVersion >= 3 AND HasNetTCPIP=true AND HasDNSClient=true |
| `PS 3+ / Partial CIM` | PSVersion >= 3 AND (HasNetTCPIP=false OR HasDNSClient=false) |
| `PS 2.0 / Legacy` | PSVersion < 3 |

### Cell State Notation

| Notation | Meaning |
|----------|---------|
| `populated` | Field present and correct at this tier |
| `null (all tiers)` | Field initialized to `$null` and never set at any tier — confirmed in source |
| `null` | Field absent at this specific tier only |
| `derived — {reason}` | Value present but less accurate than preferred tier |
| `string (regex parse)` | Value present as string from text parsing (e.g., DNS Type at ipconfig tiers) |
| `PS2_SIGNED / PS2_UNSUPPORTED` | `Signature.Status` at PS 2.0 WMI tier — binary signed/not-signed only |

All PowerShell class names, method names, CIM class names, field names, and `source` field string values appear in backtick code spans throughout this document.

### Coverage Gap Notation

Coverage gaps use the format:

```
- **{Gap name}**: {one-sentence description of what is missing and why}
```


## Tier Model

The collection method and data fidelity depend on the PowerShell version and available CIM namespaces on the target. The capability probe in `Connection.psm1` detects these at runtime.

| Tier | Condition | CIM Classes Available |
|------|-----------|----------------------|
| `PS 5.1 / Full CIM` | PSVersion >= 3, HasNetTCPIP=true, HasDNSClient=true | `Win32_Process`, `MSFT_NetTCPConnection`, `MSFT_DNSClientCache` |
| `PS 3+ / Partial CIM` | PSVersion >= 3, HasNetTCPIP=false or HasDNSClient=false | `Win32_Process` (CIM), but netstat/ipconfig for Network/DNS |
| `PS 2.0 / Legacy` | PSVersion < 3 | No CIM; WMI `Win32_Process`, `cmd netstat`, `cmd ipconfig` |

**Note:** `HasNetTCPIP` and `HasDNSClient` are probed independently. A PS 5.1 target can have `HasNetTCPIP=false` if the NetTCPIP module is absent (e.g., Server Core minimal install). Each Network sub-collector (TCP and DNS) branches independently on its own flag.


## Capability Probe

The `Get-TargetCaps` function in `Modules/Core/Connection.psm1` runs on the remote session before any collector executes. It returns the following capability flags that each collector uses to select its data path.

| Flag | Type | How Detected |
|------|------|-------------|
| `PSVersion` | int | `$PSVersionTable.PSVersion.Major` |
| `HasCIM` | bool | PSVersion >= 3 |
| `HasNetTCPIP` | bool | `Get-CimInstance MSFT_NetTCPConnection` accessible in `ROOT/StandardCimv2` |
| `HasDNSClient` | bool | `Get-CimInstance MSFT_DNSClientCache` accessible in `ROOT/StandardCimv2` |
| `IsServerCore` | bool | Registry `InstallationType` key detection |
| `TimezoneOffsetMinutes` | int | Target timezone offset for UTC conversion |




## Processes

Processes collects running process details from the target. The collection method and available data fields vary by tier.

### Fallback Chain

| Tier | Condition | Collection Method | `source` value |
|------|-----------|-------------------|----------------|
| PS 3+ | HasCIM=true | `Get-CimInstance Win32_Process` | `cim` |
| PS 2.0 | PSVersion < 3 | `ManagementObjectSearcher Win32_Process` (WMI) | `wmi` |
| Any (supplement) | PIDs in .NET not in WMI/CIM | `[System.Diagnostics.Process]::GetProcesses()` | `dotnet_fallback` |

Supplement at all tiers: processes absent from WMI/CIM are added via `.NET System.Diagnostics.Process.GetProcesses()` with `source = dotnet_fallback`. These entries have null values for: `ParentProcessId`, `CommandLine`, `SessionId`, `HandleCount`.

Combined source strings when supplement fires: `cim+dotnet_fallback` or `wmi+dotnet_fallback`.

**Note:** The `PS 5.1 / Full CIM` and `PS 3+ / Partial CIM` columns are identical for Processes — both use `Get-CimInstance Win32_Process`. The CIM/netstat distinction (HasNetTCPIP / HasDNSClient) affects Network collection, not Processes.

### Field Fidelity

| Field | PS 5.1 / Full CIM | PS 3+ / Partial CIM | PS 2.0 / Legacy | `dotnet_fallback` |
|-------|-------------------|---------------------|-----------------|-------------------|
| `ProcessId` | populated | populated | populated | populated |
| `ParentProcessId` | populated | populated | populated | **null** |
| `Name` | populated | populated | populated | populated (`ProcessName`) |
| `CommandLine` | populated | populated | populated | **null** |
| `ExecutablePath` | populated | populated | populated | populated (`MainModule.FileName`) |
| `CreationDateUTC` | populated (UTC) | populated (UTC) | populated (WMI DMTF converted) | populated (`StartTime` UTC) |
| `WorkingSetSize` | populated | populated | populated | populated (`WorkingSet64`) |
| `VirtualSize` | populated | populated | populated | populated (`VirtualMemorySize64`) |
| `SessionId` | populated | populated | populated | **null** |
| `HandleCount` | populated | populated | populated | **null** |
| `SHA256` | populated | populated | populated | populated if path available |
| `Signature.IsValid` | populated (bool) | populated (bool) | **null** | populated (PS3+) or null (PS2) |
| `Signature.Thumbprint` | populated | populated | **null** | populated (PS3+) or null (PS2) |
| `Signature.NotAfter` | populated | populated | **null** | populated (PS3+) or null (PS2) |
| `Signature.TimeStamper` | populated | populated | **null** | populated (PS3+) or null (PS2) |
| `Signature.Status` | populated (e.g. `Valid`) | populated | `PS2_SIGNED / PS2_UNSUPPORTED` | populated (PS3+) |
| `Signature.SignerSubject` | populated | populated | populated (X509 Subject only) | populated (PS3+) |

PS 2.0 Signature uses `X509Certificate.CreateFromSignedFile()` — no `Get-AuthenticodeSignature`. Status is `PS2_SIGNED` or `PS2_UNSUPPORTED` only. `IsValid`, `Thumbprint`, `NotAfter`, `TimeStamper` are always null.

### Coverage Gaps

- **dotnet_fallback field losses**: `ParentProcessId`=null, `CommandLine`=null, `SessionId`=null, `HandleCount`=null — process tree reconstruction impossible for these entries
- **PS 2.0 Signature limitation**: Binary signed/not-signed status only — no certificate validation detail (`IsValid`, `Thumbprint`, `NotAfter`, `TimeStamper` always null)


## Network — TCP Connections

Network — TCP Connections collects active TCP connection details from the target. The collection method and available data fields vary by tier.

### Fallback Chain

| Tier | Condition | Collection Method | `source.network` value |
|------|-----------|-------------------|------------------------|
| Full CIM | HasNetTCPIP=true | `Get-CimInstance MSFT_NetTCPConnection` (`ROOT/StandardCimv2`) | `cim` |
| PS 3+ partial | PSVersion >= 3, HasNetTCPIP=false | `& netstat -ano` (PowerShell invocation) | `netstat_fallback` |
| PS 2.0 | PSVersion < 3 | `cmd /c "netstat -ano"` | `netstat_legacy` |

### Field Fidelity

| Field | CIM (`cim`) | `netstat_fallback` / `netstat_legacy` |
|-------|-------------|---------------------------------------|
| `LocalAddress` | populated | populated (regex parse) |
| `LocalPort` | populated | populated (regex parse) |
| `RemoteAddress` | populated | populated (regex parse) |
| `RemotePort` | populated | populated (regex parse) |
| `OwningProcess` (PID) | populated | populated (regex parse, last column) |
| `State` | populated (converted via `ConvertFrom-TcpStateInt`) | populated (string from netstat, e.g. `ESTABLISHED`) |
| `InterfaceAlias` | populated (CIM-native field) | derived — IP-to-adapter matching via `Resolve-InterfaceAlias`; unmatched IPs get `UNKNOWN` |
| `CreationTime` | null (all tiers) — `MSFT_NetTCPConnection` does not expose this field | null (all tiers) |
| `ReverseDns` | populated (post-collection DNS lookup) | populated (same post-collection step) |
| `DnsMatch` | populated (DNS cache cross-reference) | populated (same step) |
| `IsPrivateIP` | populated | populated |

### Coverage Gaps

- **No connection creation timestamps**: `CreationTime` is null at ALL tiers — neither CIM nor netstat provides this field; `MSFT_NetTCPConnection` does not expose connection creation time
- **InterfaceAlias less precise at netstat tiers**: Derived from IP-to-adapter matching, not CIM-native; unmatched addresses return `UNKNOWN`
- **Netstat parsing on legacy OS**: PS 2.0 targets (Server 2008 R2) may miss short-lived connections on high-churn workloads — T3 test allows 10% miss rate


## Network — DNS Cache

Network — DNS Cache collects the DNS resolver cache from the target. The collection method and available data fields vary by tier.

### Fallback Chain

| Tier | Condition | Collection Method | `source.dns` value |
|------|-----------|-------------------|--------------------|
| Full CIM | HasDNSClient=true | `Get-CimInstance MSFT_DNSClientCache` (`ROOT/StandardCimv2`) | `cim` |
| PS 3+ partial | PSVersion >= 3, HasDNSClient=false | `& ipconfig /displaydns` + regex parse | `ipconfig_fallback` |
| PS 2.0 | PSVersion < 3 | `cmd /c "ipconfig /displaydns"` + regex parse | `ipconfig_legacy` |

### Field Fidelity

| Field | CIM (`cim`) | `ipconfig_fallback` / `ipconfig_legacy` |
|-------|-------------|----------------------------------------|
| `Entry` | populated | populated (regex: `Record Name`) |
| `Name` | populated | populated (same as Entry) |
| `Data` | populated | populated (IP from `Host Record`) |
| `Type` | integer (e.g. 1=A, 28=AAAA) | string (regex parse of `Record Type`) |
| `TTL` | integer | integer (regex parse of `Time To Live` line) |

### Coverage Gaps

- **DNS Type field format difference**: CIM returns integer type code; ipconfig path returns string representation — consumers must handle both formats
- **TTL parsing fragility**: ipconfig TTL extracted via regex `Time To Live[\s.]*:[\s]*(\d+)` — Windows ipconfig output formatting has varied across OS versions; TTL may be 0 or incorrect on untested OS versions




## DLLs

DLLs collects loaded module (DLL) details for each process from the target. The collection method and available data fields vary by tier.

### Fallback Chain

| Tier | Condition | Collection Method | `source` value |
|------|-----------|-------------------|----------------|
| PS 3+ | PSVersion >= 3 | `[System.Diagnostics.Process]::GetProcesses()` + `.Modules` | `dotnet` |
| PS 2.0 | PSVersion < 3 | `Win32_ProcessVMMapsFiles` WMI association, fallback to `CIM_ProcessExecutable` | `wmi` |

**Note:** These are entirely different enumeration mechanisms — the WMI path is NOT a degraded version of the .NET path.

**PS 2.0 WMI association query:** The PS 2.0 path tries `Win32_ProcessVMMapsFiles` first; if that throws, tries `CIM_ProcessExecutable`. Both use `Antecedent`/`Dependent` traversal. If both fail, emits a stub entry with `reason = 'WMI_UNAVAILABLE'` and no module data.

**Protected process exclusion (all tiers):** `lsass`, `csrss`, `smss`, `wininit`, `System`, `Idle` are skipped at ALL tiers — hardcoded exclusion list in `DLLs.psm1` at two locations (PS 3+ path and PS 2.0 path).

### Field Fidelity

| Field | .NET `dotnet` (PS 3+) | WMI (PS 2.0) |
|-------|----------------------|--------------|
| `ProcessId` | populated | populated |
| `ProcessName` | populated | populated |
| `ModuleName` | populated (`.ModuleName`) | populated (filename from path) |
| `ModulePath` | populated (`.FileName`) | populated (from WMI association object) |
| `FileVersion` | populated (`[FileVersionInfo]::GetVersionInfo`) | populated (`CIM_DataFile.Version`) |
| `Company` | populated (`FileVersionInfo.CompanyName`) | populated (`CIM_DataFile.Manufacturer`) |
| `FileHash` (SHA256) | populated | populated |
| `IsPrivatePath` | populated (checks `\Temp\`, `\AppData\`, `\ProgramData\`, `\Users\Public\`, `\Downloads\`) | populated (same logic) |
| `Signature.IsValid` | populated (bool) | **null** |
| `Signature.Thumbprint` | populated | **null** |
| `Signature.NotAfter` | populated | **null** |
| `Signature.TimeStamper` | populated | **null** |
| `Signature.Status` | populated (e.g. `Valid`) | `PS2_SIGNED / PS2_UNSUPPORTED` |
| `Signature.SignerSubject` | populated | populated (X509 Subject only) |
| `LoadedAt` | null (all tiers) — neither `.NET` nor WMI API provides DLL load timestamp | null (all tiers) |

**FileVersion/Company source difference:** The .NET path uses `System.Diagnostics.FileVersionInfo` (file metadata). The WMI path uses `Get-WmiObject CIM_DataFile` (WMI database). Values may differ for files where the WMI database is stale or incomplete.

### Coverage Gaps

- **Protected processes skipped**: `lsass`, `csrss`, `smss`, `wininit`, `System`, `Idle` are never enumerated at any tier — hardcoded exclusion list in `DLLs.psm1`
- **No DLL load timestamps**: `LoadedAt` is null at all tiers — no Windows API provides DLL load time
- **ACCESS_DENIED stubs**: Processes where `.Modules` access throws ACCESS_DENIED (.NET path) produce a stub entry with `reason='ACCESS_DENIED'` and no module data
- **PS 2.0 Signature limitation**: Same binary `PS2_SIGNED`/`PS2_UNSUPPORTED` limitation as Processes — `IsValid`, `Thumbprint`, `NotAfter`, `TimeStamper` always null
- **FileVersion/Company source divergence at PS 2.0**: WMI `CIM_DataFile` values may differ from .NET `FileVersionInfo` for files where the WMI database is stale


## Users

Users collects local account inventory, user profile metadata, and (on domain controllers) domain account details from the target. The collection method and available data fields vary by tier.

**Key architectural note:** The entire `$script:USERS_SB` scriptblock runs at ALL PS versions without branching on `PSVersion`. It uses `Get-WmiObject` (not `Get-CimInstance`) throughout — PS 2.0-compatible and works identically on PS 2.0 through PS 5.1. There is no PS-version-dependent fallback for local/profile collection.

### Collection Sub-Components

| Sub-component | Method | PS Version Dependency |
|---------------|--------|-----------------------|
| System info (`is_dc`, domain, machine name) | `Get-WmiObject Win32_ComputerSystem` | None — WMI at all tiers |
| Machine SID prefix | `Get-WmiObject Win32_UserAccount` | None — WMI at all tiers |
| User profiles | `HKLM:\...\ProfileList` registry enumeration | None — `Microsoft.Win32.Registry` API |
| Profile timestamps | ProfileFolder mtime + NTUSER.DAT mtime + Registry LastWriteTime | None — file system + registry |
| Local accounts | `Get-WmiObject Win32_UserAccount -Filter "LocalAccount=True"` | None — WMI at all tiers |
| DC domain accounts | `Get-ADUser` (preferred) -> ADSI `DirectorySearcher` (fallback) | None — PS version independent |

**`source` field construction:**

| Scenario | `source` value |
|----------|----------------|
| Non-DC target | `WMI` |
| DC target with `Get-ADUser` available | `WMI+Get-ADUser` |
| DC target with ADSI fallback | `WMI+ADSI` |

**SID note:** `SID` is the primary cross-host user correlation key in this toolkit. SID is populated at all tiers for both local accounts and DC domain accounts.

### DC Domain Account Fidelity

| Field | `Get-ADUser` | ADSI (`DirectorySearcher`) |
|-------|-------------|---------------------------|
| `SamAccountName` | populated | populated |
| `DisplayName` | populated | populated |
| `SID` | populated | populated (byte array converted to `SecurityIdentifier`) |
| `Enabled` | populated | derived from `userAccountControl` flag (bit 2) |
| `WhenCreatedUTC` | populated | populated (`whencreated` attribute) |
| `LastLogonUTC` | populated (`LastLogonDate` — replicated) | populated (`lastlogontimestamp` — replicated, up to 14 days lag) |
| `PasswordLastSetUTC` | populated | populated (`pwdlastset` FILETIME) |
| `LockedOut` | populated | derived from `lockouttime > 0` |
| `BadLogonCount` | populated | populated (`badpwdcount`) |

DC domain accounts: `LastLogonUTC` reflects `lastlogontimestamp` replication, which occurs every up to 14 days by default. This applies to both `Get-ADUser` and ADSI paths — neither provides real-time per-DC logon data.

### Coverage Gaps

- **No PS-version degradation for local/profile collection**: Same fields collected at all tiers — no fallback path exists for this sub-component
- **DC LastLogon replication lag**: `LastLogonUTC` has up to 14-day replication lag regardless of `Get-ADUser` vs ADSI — Active Directory default (`lastlogontimestamp` attribute)
- **No session enumeration**: Collection is account inventory, not active session state — logged-on users and active sessions are not collected


## Toolkit-Wide Coverage Gaps

The following artifact types are never collected at any tier. These are explicit scope boundaries, not collector failures.

| Gap | Notes |
|-----|-------|
| Windows Event Logs | Explicitly out of scope |
| Registry hives (raw) | Registry is read only for `ProfileList` key during Users collection |
| Memory dumps / RAM contents | Out of scope |
| File system artifacts (file listings, hash scans) | Out of scope |
| Network packet captures | Out of scope |
| Services / scheduled tasks | Not a collector module |
| Autorun / persistence locations | Not a collector module |
