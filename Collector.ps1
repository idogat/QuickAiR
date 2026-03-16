#Requires -Version 5.1
# Name: Quicker Collector
# Description: Quicker -- DFIR Volatile Artifact Collector
# Version: 2.0
# CHANGES:
#   1.0 - Initial implementation: pslist + network TCP + DNS cache
#         PS 2.0 through 5.1 target support via dual WMI/CIM paths
#         WinRM-only connectivity, read-only, no external calls
#   1.1 - Fix SHA256 computation: use UTF8 string bytes (no BOM/newline ambiguity)
#   1.2 - Prompt for credentials when connecting to remote target with no -Credential supplied
#         Fix remote capability probe: use WinRM only (no DCOM/RPC), port 5985 explicit
#         Reduce retry wait to 5s for faster failure detection
#         Auto-add target to WinRM TrustedHosts for non-domain connections
#   1.3 - Fix output path resolving to system32 when run as Administrator without -OutputPath
#         OutputPath now always resolves relative to script location, not CWD
#   1.4 - Fix output folder/file always uses hostname not IP (DNS resolution with IP fallback)
#         Fix missing processes: .NET cross-check catches processes absent from WMI/CIM
#         Fix silent process drops on access denied: include process with partial data
#         Fix WMI result truncation: EnumerationOptions.ReturnImmediately/Rewindable
#         Increase CIM operation timeout to 60s
#   1.5 - Rebrand to Quicker
#         Fix ReverseDns: store IP as fallback when no PTR record exists (never null for public IPs)
#   1.6 - Multi-NIC support: enumerate all adapters on target (WMI/CIM)
#         manifest.network_adapters stores full adapter list
#         InterfaceAlias assigned per-connection by matching LocalAddress to adapter IPs
#         ALL_INTERFACES for 0.0.0.0/:: bindings, LOOPBACK for 127.0.0.1/::1
#         UNKNOWN + WARN logged when LocalAddress does not match any adapter IP
#   2.0 - Plugin-based architecture refactor
#         Collector.ps1 is now a thin orchestrator
#         Core modules: DateTime, Connection, Output
#         Collector modules: Processes, Network (auto-discovered)

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string[]]$Targets,

    [Parameter(Mandatory=$false)]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter(Mandatory=$false)]
    [string]$OutputPath = "",

    [Parameter(Mandatory=$false)]
    [switch]$Quiet
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

#region --- Resolve OutputPath to absolute ---
if (-not $OutputPath) {
    $OutputPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "DFIROutput"
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
#endregion

#region --- Constants ---
$COLLECTOR_VERSION = "2.0"
$MAX_RETRY         = 3
$RETRY_WAIT_SEC    = 5
#endregion

#region --- Admin Check ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Quicker requires Administrator. Please restart as Administrator (right-click -> Run as administrator) and re-run." -ForegroundColor Red
    exit 1
}
#endregion

#region --- Import Core Modules ---
Import-Module "$PSScriptRoot\Modules\Core\DateTime.psm1"   -Force
Import-Module "$PSScriptRoot\Modules\Core\Connection.psm1" -Force
Import-Module "$PSScriptRoot\Modules\Core\Output.psm1"     -Force
#endregion

#region --- Setup Output & Log ---
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}
Initialize-Log -Path (Join-Path $OutputPath "collection.log") -Quiet:$Quiet.IsPresent

Write-Log 'INFO' "Quicker Collector v$COLLECTOR_VERSION starting"
Write-Log 'INFO' "Analyst: $env:COMPUTERNAME, PS $($PSVersionTable.PSVersion), OS: $((Get-WmiObject Win32_OperatingSystem).Caption)"
Write-Log 'INFO' "OutputPath: $OutputPath"
#endregion

#region --- Main Collection Loop ---
$runStart  = Get-Date
$analystOS = (Get-WmiObject Win32_OperatingSystem).Caption

Write-Log 'INFO' "Starting collection. Targets: $($Targets.Count)"

foreach ($target in $Targets) {
    $tStart  = Get-Date
    $collErr = @()

    Write-Log 'INFO' "Collection start | target=$target"

    # Local target check
    $isLocalTarget = ($target -eq 'localhost' -or $target -eq '127.0.0.1' -or $target -ieq $env:COMPUTERNAME)
    $effectiveCred = $Credential

    # For remote targets, prompt for credentials if none provided
    if (-not $isLocalTarget -and -not $effectiveCred) {
        Write-Host "Enter credentials for $target (leave blank to attempt current user):" -ForegroundColor Cyan
        try { $effectiveCred = Get-Credential -Message "Credentials for $target" -ErrorAction Stop } catch { $effectiveCred = $null }
    }

    # Ensure target is in WinRM TrustedHosts (required for non-domain WinRM connections)
    if (-not $isLocalTarget) {
        try {
            $current = (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction Stop).Value
            if ($current -ne '*' -and $current -notmatch [regex]::Escape($target)) {
                $newList = if ($current) { "$current,$target" } else { $target }
                Set-Item WSMan:\localhost\Client\TrustedHosts -Value $newList -Force -ErrorAction Stop
                Write-Log 'INFO' "Added $target to WinRM TrustedHosts"
            }
        } catch { Write-Log 'WARN' "Could not update TrustedHosts: $($_.Exception.Message)" }
    }

    # Capability probe with retry
    $caps      = $null
    $connected = $false
    for ($attempt = 1; $attempt -le $MAX_RETRY; $attempt++) {
        try {
            $caps = Get-TargetCaps -Target $target -Cred $effectiveCred
            if ($caps.Error) { throw $caps.Error }
            $connected = $true
            Write-Log 'INFO' "Capability probe OK | PS=$($caps.PSVersion) | CIM=$($caps.HasCIM) | NetCIM=$($caps.HasNetTCPIP) | DnsCIM=$($caps.HasDNSClient)"
            break
        } catch {
            Write-Log 'WARN' "Probe attempt $attempt/$MAX_RETRY failed: $($_.Exception.Message)"
            if ($attempt -lt $MAX_RETRY) { Start-Sleep -Seconds $RETRY_WAIT_SEC }
        }
    }

    if (-not $connected) {
        Write-Log 'ERROR' "All $MAX_RETRY probe attempts failed for target. Skipping."
        continue
    }

    # Create shared session (remote) or use $null (local)
    $session = $null
    if (-not $isLocalTarget) {
        try {
            $session = New-RemoteSession -Target $target -Credential $effectiveCred
            Write-Log 'INFO' "Remote session created for $target"
        } catch {
            Write-Log 'ERROR' "Failed to create remote session: $($_.Exception.Message). Skipping."
            continue
        }
    }

    # Auto-discover collectors
    $collectorModules = Get-ChildItem "$PSScriptRoot\Modules\Collectors\*.psm1" | Sort-Object Name

    $output          = [ordered]@{}
    $sources         = @{}
    $networkAdapters = @()

    foreach ($c in $collectorModules) {
        Import-Module $c.FullName -Force
        Write-Log 'INFO' "Running collector: $($c.BaseName)"
        try {
            $result = Invoke-Collector -Session $session -TargetPSVersion $caps.PSVersion -TargetCapabilities $caps
            $collErr += $result.errors
            $sources[$c.BaseName] = $result.source
            if ($c.BaseName -eq 'Network') {
                $output['Network'] = @{ tcp = $result.data.tcp; dns = $result.data.dns }
                $networkAdapters   = $result.data.adapters
            } else {
                $output[$c.BaseName] = $result.data
            }
            Write-Log 'INFO' "Collector $($c.BaseName) complete"
        } catch {
            $collErr += @{ artifact = $c.BaseName; message = $_.Exception.Message }
            Write-Log 'ERROR' "Collector $($c.BaseName) failed: $($_.Exception.Message)"
        }
    }

    # Close shared session
    if ($session) { Remove-PSSession $session -ErrorAction SilentlyContinue }

    # Resolve hostname for output
    $outHost = Resolve-TargetHostname -Target $target
    Write-Log 'INFO' "Output hostname: $outHost"

    # Print adapter summary
    if (-not $Quiet -and $networkAdapters.Count -gt 0) {
        $nicCount = $networkAdapters.Count
        Write-Host ""
        Write-Host "  Found $nicCount NIC$(if ($nicCount -ne 1) {'s'}) on ${outHost}:" -ForegroundColor Cyan
        for ($ni = 0; $ni -lt $networkAdapters.Count; $ni++) {
            $adp     = $networkAdapters[$ni]
            $firstIP = if (@($adp.IPAddresses).Count -gt 0) { @($adp.IPAddresses)[0] } else { 'no IP' }
            Write-Host "    NIC $($ni+1): $($adp.InterfaceAlias) - $firstIP" -ForegroundColor Cyan
        }
    }

    # Build manifest
    $manifest = Build-Manifest `
        -Hostname         $outHost `
        -CollectorVersion $COLLECTOR_VERSION `
        -AnalystOS        $analystOS `
        -Caps             $caps `
        -Sources          $sources `
        -NetworkAdapters  $networkAdapters `
        -CollectionErrors $collErr

    # Build full output: manifest first, then each collector's data
    $jsonOutput = [ordered]@{}
    $jsonOutput['manifest'] = $manifest
    foreach ($key in $output.Keys) {
        $jsonOutput[$key] = $output[$key]
    }

    # Write JSON output
    $written = Write-JsonOutput -Data $jsonOutput -HostDir (Join-Path $OutputPath $outHost) -Hostname $outHost
    Write-Log 'INFO' "Output: $($written.Path) | SHA256: $($written.Hash)"

    $procCount  = @($output['Processes']).Count
    $connCount  = @($output['Network'].tcp).Count
    $dnsCount   = @($output['Network'].dns).Count
    $elapsed    = [int]((Get-Date) - $tStart).TotalSeconds
    Write-Log 'INFO' "Target complete | elapsed=${elapsed}s | processes=$procCount | connections=$connCount | dns=$dnsCount | errors=$($collErr.Count)"

    if (-not $Quiet) {
        Write-Host ""
        Write-Host "  Output      : $($written.Path)"  -ForegroundColor Green
        Write-Host "  Processes   : $procCount"         -ForegroundColor Cyan
        Write-Host "  Connections : $connCount"         -ForegroundColor Cyan
        Write-Host "  DNS entries : $dnsCount"          -ForegroundColor Cyan
        if ($collErr.Count -gt 0) {
            Write-Host "  Errors      : $($collErr.Count)" -ForegroundColor Yellow
        }
        Write-Host "  SHA256 : $($written.Hash)" -ForegroundColor DarkGray
    }
}

$totalSec = [int]((Get-Date) - $runStart).TotalSeconds
Write-Log 'INFO' "All targets complete | elapsed=${totalSec}s"
#endregion
