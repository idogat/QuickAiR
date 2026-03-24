# External Integrations

**Analysis Date:** 2026-03-24

## APIs & External Services

**None**
- No external API integrations
- No cloud service SDKs
- No HTTP/REST API calls to external systems
- Fully air-gappable; zero internet dependencies

## Data Storage

**Local Filesystem Only:**
- Output: JSON files per host in `DFIROutput\<hostname>\<hostname>_<timestamp>.json`
- Temporary files: `C:\Windows\Temp\` (binary transfer staging on targets)
- No database (SQL Server, SQLite, etc.)
- No cloud storage (Azure Blob, S3, GCS)

**Data Format:**
- JSON output structure:
  - `manifest` - Collection metadata, versions, errors, collection timestamps
  - `processes` - Process list with parent-child relationships, SHA256, signatures
  - `network_tcp` - TCP connections with process correlation
  - `dns_cache` - DNS cache entries with query history
  - `users` - User profiles with SID correlation
  - `dlls` - Loaded DLLs with versions and signatures
- Execution results: `<hostname>_execution_<timestamp>.json` from `Executor.ps1`

**File Storage:**
- Local filesystem only - All artifacts stored locally
- No object storage integrations
- Output path is configurable via `-OutputPath` parameter

**Caching:**
- No caching layer
- DNS query caching queried directly from target's MSFT_DNSClientCache WMI class

## Authentication & Identity

**Auth Provider:**
- Custom Windows authentication
  - Kerberos (domain-joined targets)
  - NTLM (workgroup targets)
  - Local account (standalone systems)

**Implementation:**
- `Modules\Core\Connection.psm1` - WinRM PSSession establishment with optional credentials
- Credentials: Interactive prompt via `Get-Credential` if not provided
- Session security:
  - `New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck` for HTTP (unencrypted) WinRM
  - No certificate validation (analyst environment, non-production)
- SID (Security Identifier) used as primary cross-host user correlation key

**Credential Handling:**
- No credential storage or caching to disk
- In-memory only via PSCredential objects
- Credential cache in `$script:CredCache` in QuickerLaunch.ps1 (in-memory per session)

## Monitoring & Observability

**Error Tracking:**
- No external error tracking (Sentry, LogRocket, etc.)
- Errors logged to local JSON `manifest.collection_errors` array
- Test suite (`TestSuite.ps1`) validates error logging completeness

**Logs:**
- Local filesystem logging:
  - `DFIROutput\collection.log` - Collection run log with INFO/WARN timestamps
  - `agent.log` - General operational log (if exists)
- Log format: Plain text with timestamp, level, and message
- No centralized logging platform integration

## CI/CD & Deployment

**Hosting:**
- No hosted deployment
- Standalone portable executable suite
- No cloud platform dependencies

**CI Pipeline:**
- No automated CI/CD pipeline
- Manual test via `TestSuite.ps1` (11 automated checks)
- Build via `build_report.ps1` (PowerShell script)
- No GitHub Actions, Azure DevOps, GitLab CI, or Jenkins integration detected

## Environment Configuration

**Required env vars:**
- None - All configuration via command-line parameters or interactive prompts
- Analyzer environment: No special env vars needed
- Target environment: No env vars set during collection

**Secrets location:**
- Secrets: Not persisted
- Credentials: Interactive prompt via `Get-Credential` only
- No `.env` files
- No configuration files with embedded secrets

## Webhooks & Callbacks

**Incoming:**
- Quicker URI handler (`quicker://` protocol):
  - Registered via `Register-QuickerProtocol.ps1`
  - Listened by `QuickerLaunch.ps1` via named pipe in `C:\DFIRLab\QuickerBridge\`
  - JSON job batch in base64-encoded URI parameter
  - Example: `quicker://launch?jobs=<base64-json>`

**Outgoing:**
- None - Quicker never makes outbound connections
- No webhooks to external systems
- No callback URLs to collection servers or SIEMs

## Remote Execution Methods

**Primary:**
- WinRM (PS 5.1+ remote targets):
  - Transport: HTTP (port 5985) or HTTPS (5986)
  - Authentication: Kerberos or NTLM
  - Implementation: `Modules\Executors\WinRM.psm1`
  - State machine: CONNECTION → CONNECTED → TRANSFERRED → LAUNCHED → ALIVE/SFX_LAUNCHED

**Fallback:**
- SMB+WMI (PS 3.0-5.1 targets):
  - SMB share enumeration via WMI Win32_Share
  - Binary transfer: Copy via SMB UNC path
  - Execution: WMI Win32_Process.Create()
  - Implementation: `Modules\Executors\SMBWMI.psm1`

**Legacy:**
- WMI only (PS 2.0 targets):
  - Win32_Process.Create() for execution
  - No binary transfer (target-side tools only)
  - Implementation: `Modules\Executors\WMI.psm1`

## Collection Methods by PowerShell Version

**PS 5.1:**
- Processes: Get-CimInstance MSFT_Win32Process
- Network: Get-CimInstance MSFT_NetTCPConnection (native, no netstat fallback)
- DNS: Get-CimInstance MSFT_DNSClientCache (native, no ipconfig fallback)

**PS 3.0-4.x:**
- Processes: Get-CimInstance Win32_Process
- Network: `netstat -ano` → parsed output → cross-correlation with PID
- DNS: `ipconfig /displaydns` → parsed output

**PS 2.0:**
- Processes: New-Object System.Management.ManagementObjectSearcher (WMI direct)
- Network: `netstat -ano` → parsed output
- DNS: `ipconfig /displaydns` → parsed output

## Tool Execution Integration

**Tools manifest:**
- `tools.json` - Catalog of available tools in `C:\DFIRLab\tools\`
- Scanned at runtime by `Modules\Core\Get-ToolsManifest.ps1`
- Categories: memory, disk, memory+disk, custom
- No external tool repository integration

**Supported tools in lab:**
- Velociraptor 0.75.2
- Autoruns64.exe
- DumpIt.exe
- FTK Imager
- winpmem_64.exe

---

*Integration audit: 2026-03-24*
