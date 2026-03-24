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


<!-- Collector sections follow -->
