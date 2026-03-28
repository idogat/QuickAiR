# Technology Stack

**Analysis Date:** 2026-03-24

## Languages

**Primary:**
- PowerShell 5.1 - All orchestration, collectors, and remote execution (analyst machine and entry points)
- PowerShell 2.0+ - Target-side collection code (backward compatibility for legacy Windows systems)
- JavaScript (Vanilla ES6) - Single-file offline HTML GUI with no external framework dependencies
- HTML5 / CSS3 - Report interface with dark theme styling

**Secondary:**
- Batch/CMD - Fallback netstat/ipconfig for PS 2.0-3 targets without modern cmdlets

## Runtime

**Environment:**
- PowerShell 5.1 (analyst machine minimum, for Collector.ps1, Executor.ps1, QuickAiRLaunch.ps1)
- PowerShell 2.0-5.1 (target machines, auto-detected and adapted)
- Windows 10/11 and Windows Server 2008 R2+
- WinRM 1.0+ for remote collection
- .NET Framework 4.5+ (implied by PowerShell 5.1)

**Package Manager:**
- No external package manager - All dependencies are built-in Windows APIs
- Lockfile: Not applicable

## Frameworks

**Core:**
- Windows Management Instrumentation (WMI) - Process, network, user enumeration
- Common Information Model (CIM) - Modern WMI replacement for PS 3.0+
- WinRM (Windows Remote Management) - Remote PowerShell session management via PSSession
- Windows Forms (System.Windows.Forms) - GUI for QuickAiRLaunch.ps1 job manager
- System.Drawing - Color and graphics for WinForms UI

**Testing:**
- Custom Pester-compatible test runner (`TestSuite.ps1`) - 11 automated checks for data completeness and integrity
- No external test framework dependency

**Build/Dev:**
- PowerShell script-based build: `build_report.ps1` - Concatenates ReportStages/*.html and *.js files into Report.html
- No external build tool required

## Key Dependencies

**Critical:**
- Windows APIs (built-in):
  - Win32_Process - Process enumeration
  - MSFT_NetTCPConnection - Network TCP connections (PS 3.0+)
  - MSFT_DNSClientCache - DNS cache enumeration
  - Win32_UserProfile - User account enumeration
  - Win32_SystemDriver - DLL/driver enumeration
  - Win32_TimeZone - Timezone offset calculation
  - System.Net.Dns - Hostname resolution
  - System.Management - WMI base classes
  - System.Security.Cryptography.SHA256 - Process binary hashing
  - System.Security.Cryptography.X509Certificates - Code signature verification

**Infrastructure:**
- No external infrastructure dependencies
- No cloud SDK integrations
- No CDN or external asset dependencies
- No package repositories (npm, NuGet, PyPI) required

## Configuration

**Environment:**
- Manual credential entry via `Get-Credential` prompt (no env vars stored)
- Target discovery via hostname/IP with WinRM port 5985
- Output path configurable via `-OutputPath` parameter (default: `.\DFIROutput\`)
- No environment variables required for operation
- Tool manifest via `C:\DFIRLab\tools` directory scanning

**Build:**
- `build_report.ps1`: Reads ordered ReportStages/*.html and *.js files, concatenates into Report.html
- Version numbers in file headers (3.39 for HTML/JS core, 1.8 for Executor, 2.2 for Collector)
- No build configuration files (.json, .yaml, .xml)

## Platform Requirements

**Development:**
- Windows 11/Server 2022 (tested analyst environment)
- PowerShell 5.1
- Administrator privileges for collector execution
- WinRM enabled for remote targets (via `winrm quickconfig` or group policy)

**Production:**
- Target: Windows 10/11, Server 2008 R2 through 2022
- Analyzer: Any modern browser (HTML/JS fully offline, no server required)
- Deployment: Single directory with no installation; all binaries portable
- No external network access required (fully air-gappable)

---

*Stack analysis: 2026-03-24*
