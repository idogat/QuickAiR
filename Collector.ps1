#Requires -Version 5.1
# ╔══════════════════════════════════════╗
# ║  QuickAiR — Collector.ps1            ║
# ║  Thin orchestrator. Auto-discovers  ║
# ║  and runs Collectors\*.psm1 plugins ║
# ╠══════════════════════════════════════╣
# ║  Exports   : n/a (entry point)      ║
# ║  Inputs    : -Targets -Credential   ║
# ║              -OutputPath -Plugins   ║
# ║              -Quiet                 ║
# ║  Output    : <hostname>_<ts>.json   ║
# ║  Depends   : Core\* Collectors\*   ║
# ║  PS compat : 5.1 (analyst machine)  ║
# ║  Version   : 2.3                    ║
# ╚══════════════════════════════════════╝

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string[]]$Targets,

    [Parameter(Mandatory=$false)]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter(Mandatory=$false)]
    [string]$OutputPath = "",

    [Parameter(Mandatory=$false)]
    [string[]]$Plugins,

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
    Write-Host "QuickAiR requires Administrator. Please restart as Administrator (right-click -> Run as administrator) and re-run." -ForegroundColor Red
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

Write-Log 'INFO' "QuickAiR Collector v$COLLECTOR_VERSION starting"
Write-Log 'INFO' "Analyst: $env:COMPUTERNAME, PS $($PSVersionTable.PSVersion), OS: $((Get-WmiObject Win32_OperatingSystem).Caption)"
Write-Log 'INFO' "OutputPath: $OutputPath"

#region --- Tools Manifest ---
if (Test-Path 'C:\DFIRLab\tools' -PathType Container) {
    $_toolsManifest = Join-Path $PSScriptRoot "Modules\Core\Get-ToolsManifest.ps1"
    if (Test-Path $_toolsManifest) {
        try { & $_toolsManifest } catch { Write-Log 'WARN' "Tools manifest scan failed: $($_.Exception.Message)" }
    }
}
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
    $session        = $null
    $winrmReachable = $null
    if (-not $isLocalTarget) {
        try {
            $session        = New-RemoteSession -Target $target -Credential $effectiveCred
            $winrmReachable = $true
            Write-Log 'INFO' "Remote session created for $target"
        } catch {
            Write-Log 'ERROR' "Failed to create remote session: $($_.Exception.Message). Skipping."
            continue
        }
    }

    # SMB + WMI reachability probes
    $smbReachable  = $null
    $wmiReachable  = $null
    $smbShareName  = $null
    if ($isLocalTarget) {
        $smbReachable = $true
        $wmiReachable = $true
        $smbShareName = 'C$'
    } else {
        # WMI probe: connect to root\cimv2 (same pattern as WMI.psm1)
        try {
            $wmiScope = New-Object System.Management.ManagementScope("\\$target\root\cimv2")
            if ($effectiveCred) {
                $wmiScope.Options.Username = $effectiveCred.UserName
                $wmiScope.Options.Password = $effectiveCred.GetNetworkCredential().Password
            }
            $wmiScope.Connect()
            $wmiReachable = $true
            Write-Log 'INFO' "WMI reachable on $target"

            # SMB probe: enumerate admin shares via WMI (same pattern as SMBWMI.psm1 Find-AdminShare)
            try {
                $q = New-Object System.Management.ObjectQuery("SELECT Name, Path FROM Win32_Share WHERE Type = 2147483648")
                $searcher = New-Object System.Management.ManagementObjectSearcher($wmiScope, $q)
                $shares = @($searcher.Get())
                $shareNames = @()
                foreach ($s in $shares) { $shareNames += [string]$s['Name'] }
                if ($shareNames.Count -gt 0) {
                    $smbReachable = $true
                    $smbShareName = if ($shareNames -contains 'C$') { 'C$' } else { $shareNames[0] }
                } else {
                    $smbReachable = $false
                }
                Write-Log 'INFO' "SMB admin shares on ${target}: $($shareNames -join ', ')"
            } catch {
                $smbReachable = $false
                Write-Log 'WARN' "SMB share enumeration failed on ${target}: $($_.Exception.Message)"
            }
        } catch {
            $wmiReachable = $false
            $smbReachable = $false
            Write-Log 'WARN' "WMI unreachable on ${target}: $($_.Exception.Message)"
        }
    }

    # Auto-discover collectors (filter by -Plugins if specified)
    $collectorModules = Get-ChildItem "$PSScriptRoot\Modules\Collectors\*.psm1" | Sort-Object Name
    if ($Plugins -and $Plugins.Count -gt 0) {
        $collectorModules = @($collectorModules | Where-Object { $_.BaseName -in $Plugins })
    }

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
            Write-Log 'WARN' "Collector $($c.BaseName) failed: $($_.Exception.Message)"
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
        -CollectionErrors $collErr `
        -WinRMReachable   $winrmReachable `
        -WmiReachable     $wmiReachable `
        -SmbReachable     $smbReachable `
        -SmbShareName     $smbShareName

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
