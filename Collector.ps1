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
# ║  Version   : 3.4                    ║
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
    [switch]$Quiet,

    [Parameter(Mandatory=$false)]
    [string]$ProgressFile = ""
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

#region --- Resolve OutputPath to absolute ---
if (-not $OutputPath) {
    $OutputPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "DFIROutput"
}
if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) $OutputPath
}
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

#region --- Auto-register quickair:// protocols (idempotent) ---
$_regRoot     = 'HKCU:\SOFTWARE\Classes\quickair'
$_regRootCol  = 'HKCU:\SOFTWARE\Classes\quickair-collect'
if (-not (Test-Path "$_regRoot\shell\open\command") -or
    -not (Test-Path "$_regRootCol\shell\open\command")) {
    try {
        $launchScript  = Join-Path $PSScriptRoot 'QuickAiRLaunch.ps1'
        $collectScript = Join-Path $PSScriptRoot 'QuickAiRCollect.ps1'

        foreach ($entry in @(
            @{ Root = $_regRoot;    Label = 'URL:QuickAiR DFIR Launcher';   Script = $launchScript  },
            @{ Root = $_regRootCol; Label = 'URL:QuickAiR DFIR Collector';  Script = $collectScript }
        )) {
            $cmdKey = "$($entry.Root)\shell\open\command"
            if (-not (Test-Path $entry.Root))  { New-Item -Path $entry.Root  -Force | Out-Null }
            if (-not (Test-Path $cmdKey))       { New-Item -Path $cmdKey      -Force | Out-Null }
            Set-ItemProperty  -Path $entry.Root -Name '(Default)'    -Value $entry.Label
            New-ItemProperty  -Path $entry.Root -Name 'URL Protocol' -Value '' -PropertyType String -Force | Out-Null
            $cmd = 'powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $entry.Script + '" -URI "%1"'
            Set-ItemProperty  -Path $cmdKey     -Name '(Default)'    -Value $cmd
        }
    } catch {
        # Non-fatal — protocols may already work or analyst can register manually
    }
}
#endregion

#region --- Import Core Modules ---
Import-Module "$PSScriptRoot\Modules\Core\DateTime.psm1"   -Force
Import-Module "$PSScriptRoot\Modules\Core\Connection.psm1" -Force
Import-Module "$PSScriptRoot\Modules\Core\Output.psm1"     -Force
#endregion

#region --- Setup Output & Log ---
try {
    New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop | Out-Null
} catch {
    Write-Host "FATAL: Cannot create output directory '$OutputPath': $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
Initialize-Log -Path (Join-Path $OutputPath "collection.log") -Quiet:$Quiet.IsPresent

$analystOS = 'Unknown'
try { $analystOS = (Get-WmiObject Win32_OperatingSystem).Caption } catch { }

Write-Log 'INFO' "QuickAiR Collector v$COLLECTOR_VERSION starting"
Write-Log 'INFO' "Analyst: $env:COMPUTERNAME, PS $($PSVersionTable.PSVersion), OS: $analystOS"
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

Write-Log 'INFO' "Starting collection. Targets: $($Targets.Count)"

foreach ($target in $Targets) {
    $tStart  = Get-Date
    $collErr = @()

    Write-Log 'INFO' "Collection start | target=$target"

    # Local target check
    $shortTarget = ($target -split '\.')[0]
    $isLocalTarget = ($target -eq 'localhost' -or $target -eq '127.0.0.1' -or $target -eq '::1' -or $shortTarget -ieq $env:COMPUTERNAME)
    $effectiveCred = $Credential

    # For remote targets, use current-user credentials if none provided (autonomous mode)
    if (-not $isLocalTarget -and -not $effectiveCred) {
        Write-Log 'INFO' "No credentials supplied for $target — using current-user context"
    }

    # Ensure target is in WinRM TrustedHosts (required for non-domain WinRM connections)
    $originalTrustedHosts = $null
    if (-not $isLocalTarget) {
        try {
            $originalTrustedHosts = (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction Stop).Value
            if ($originalTrustedHosts -ne '*' -and $originalTrustedHosts -notmatch [regex]::Escape($target)) {
                $newList = if ($originalTrustedHosts) { "$originalTrustedHosts,$target" } else { $target }
                Set-Item WSMan:\localhost\Client\TrustedHosts -Value $newList -Force -ErrorAction Stop
                Write-Log 'INFO' "Added $target to WinRM TrustedHosts"
            } else {
                $originalTrustedHosts = $null  # no change made, no restore needed
            }
        } catch { Write-Log 'WARN' "Could not update TrustedHosts: $($_.Exception.Message)"; $originalTrustedHosts = $null }
    }

    # Shorten verbose WinRM errors to short actionable messages
    function Format-ConnectionError([string]$msg) {
        if ([string]::IsNullOrWhiteSpace($msg)) { return 'Connection failed.' }
        $map = @(
            @{ Pattern = 'client cannot connect to the destination';   Short = 'Connection refused: host unreachable or WinRM not listening.' }
            @{ Pattern = 'server name cannot be resolved';             Short = 'DNS resolution failed: hostname not found.' }
            @{ Pattern = 'network path was not found';                 Short = 'Network path not found: host unreachable.' }
            @{ Pattern = 'Access is denied|logon failure|user name or password'; Short = 'Authentication failed: credentials rejected by target.' }
            @{ Pattern = 'WinRM cannot complete';                      Short = 'WinRM not configured on target.' }
            @{ Pattern = 'WinRM client cannot process the request';    Short = 'WinRM request failed: check target configuration.' }
            @{ Pattern = 'connection attempt failed';                  Short = 'Connection timed out: host unreachable.' }
        )
        foreach ($m in $map) {
            if ($msg -match $m.Pattern) { return $m.Short }
        }
        # Fallback: first sentence, max 120 chars
        $short = ($msg -split '\.\s', 2)[0]
        if ($short.Length -gt 120) { $short = $short.Substring(0, 117) + '...' }
        return $short
    }

    # Capability probe with retry (WinRM first, then WMI fallback)
    $caps              = $null
    $connected         = $false
    $usingWmiFallback  = $false
    $winrmProbeError   = ''
    $lastProbeError    = ''
    for ($attempt = 1; $attempt -le $MAX_RETRY; $attempt++) {
        try {
            $caps = Get-TargetCaps -Target $target -Cred $effectiveCred
            if ($caps.Error) { throw $caps.Error }
            $connected = $true
            Write-Log 'INFO' "Capability probe OK | PS=$($caps.PSVersion) | CIM=$($caps.HasCIM) | NetCIM=$($caps.HasNetTCPIP) | DnsCIM=$($caps.HasDNSClient)"
            if ($ProgressFile) {
                try { [System.IO.File]::AppendAllText($ProgressFile, "PROBE:PS=$($caps.PSVersion)|CIM=$($caps.HasCIM)|NetCIM=$($caps.HasNetTCPIP)|DnsCIM=$($caps.HasDNSClient)`n") } catch { Write-Log 'WARN' "Progress write: $($_.Exception.Message)" }
            }
            break
        } catch {
            $lastProbeError = $_.Exception.Message
            Write-Log 'WARN' "Probe attempt $attempt/$MAX_RETRY failed: $lastProbeError"
            if ($attempt -lt $MAX_RETRY) { Start-Sleep -Seconds $RETRY_WAIT_SEC }
        }
    }

    # WMI fallback probe if WinRM failed
    if (-not $connected -and -not $isLocalTarget) {
        $winrmProbeError = $lastProbeError
        Write-Log 'WARN' "WinRM probe failed for $target. Attempting WMI fallback..."
        try {
            $caps = Get-TargetCapsWMI -Target $target -Cred $effectiveCred
            if ($caps.Error) { throw $caps.Error }
            $connected        = $true
            $usingWmiFallback = $true
            Write-Log 'INFO' "WMI capability probe OK | PS=$($caps.PSVersion) | Method=WMI"
            if ($ProgressFile) {
                try { [System.IO.File]::AppendAllText($ProgressFile, "PROBE:PS=$($caps.PSVersion)|CIM=False|NetCIM=False|DnsCIM=False|Method=WMI`n") } catch { Write-Log 'WARN' "Progress write: $($_.Exception.Message)" }
            }
        } catch {
            $lastProbeError = $_.Exception.Message
            Write-Log 'WARN' "WMI probe also failed: $lastProbeError"
        }
    }

    if (-not $connected) {
        $failMsg = if ($winrmProbeError -and $lastProbeError -ne $winrmProbeError) {
            "WinRM: $(Format-ConnectionError $winrmProbeError) | WMI: $(Format-ConnectionError $lastProbeError)"
        } elseif ($lastProbeError) {
            Format-ConnectionError $lastProbeError
        } else {
            'Connection failed: host unreachable or WinRM not configured.'
        }
        Write-Log 'ERROR' "All probe attempts failed for $target. Skipping."
        if ($ProgressFile) {
            try { [System.IO.File]::AppendAllText($ProgressFile, "HOSTFAILED:$failMsg`n") } catch { Write-Log 'WARN' "Progress write: $($_.Exception.Message)" }
        }
        continue
    }

    # Create shared session (remote) or use $null (local)
    $session          = $null
    $winrmReachable   = $null
    $connectionMethod = 'local'
    try { # session-safety: finally block ensures PSSession cleanup
    if (-not $isLocalTarget) {
        if (-not $usingWmiFallback) {
            # Try WinRM session first
            try {
                $session          = New-RemoteSession -Target $target -Credential $effectiveCred
                $winrmReachable   = $true
                $connectionMethod = 'WinRM'
                Write-Log 'INFO' "Connected to $target via WinRM"
            } catch {
                $sessErr        = $_.Exception.Message
                $winrmReachable = $false
                Write-Log 'WARN' "WinRM session failed for ${target}: $(Format-ConnectionError $sessErr)"
                # Fall back to WMI session
                try {
                    $session           = New-WMISession -Target $target -Credential $effectiveCred
                    $connectionMethod  = 'WMI'
                    $usingWmiFallback  = $true
                    Write-Log 'INFO' "Connected to $target via WMI (fallback)"
                    if (-not $Quiet) {
                        Write-Host "  WinRM unavailable - using WMI fallback for $target" -ForegroundColor Yellow
                    }
                    # Re-probe caps via WMI if WinRM probe had succeeded but session failed
                    if ($caps -and $caps.HasCIM) {
                        $caps = Get-TargetCapsWMI -Target $target -Cred $effectiveCred
                    }
                } catch {
                    Write-Log 'ERROR' "Both WinRM and WMI failed for $target. Skipping."
                    if ($ProgressFile) {
                        $reason = Format-ConnectionError $sessErr
                        try { [System.IO.File]::AppendAllText($ProgressFile, "HOSTFAILED:$reason`n") } catch { Write-Log 'WARN' "Progress write: $($_.Exception.Message)" }
                    }
                    continue
                }
            }
        } else {
            # WMI probe succeeded but WinRM probe failed — retry WinRM session once
            # (transient WinRM failures should not permanently degrade collection)
            $winrmReachable = $false
            $winrmRetried   = $false
            try {
                $session          = New-RemoteSession -Target $target -Credential $effectiveCred
                $winrmReachable   = $true
                $connectionMethod = 'WinRM'
                $usingWmiFallback = $false
                $winrmRetried     = $true
                # Re-probe caps via WinRM for accurate capability data
                try { $caps = Get-TargetCaps -Target $target -Cred $effectiveCred } catch { Write-Log 'WARN' "WinRM caps re-probe failed, keeping WMI caps" }
                Write-Log 'INFO' "WinRM session succeeded on retry for $target (avoiding WMI degradation)"
            } catch {
                Write-Log 'INFO' "WinRM session retry failed for $target, proceeding with WMI"
            }
            if (-not $winrmRetried) {
                try {
                    $session          = New-WMISession -Target $target -Credential $effectiveCred
                    $connectionMethod = 'WMI'
                    Write-Log 'INFO' "Connected to $target via WMI (WinRM unavailable)"
                    if (-not $Quiet) {
                        Write-Host "  WinRM unavailable - using WMI fallback for $target" -ForegroundColor Yellow
                    }
                } catch {
                    Write-Log 'ERROR' "WMI session creation failed for $target. Skipping."
                    if ($ProgressFile) {
                        try { [System.IO.File]::AppendAllText($ProgressFile, "HOSTFAILED:WMI session failed`n") } catch { Write-Log 'WARN' "Progress write: $($_.Exception.Message)" }
                    }
                    continue
                }
            }
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
    } elseif ($connectionMethod -eq 'WMI') {
        # WMI already confirmed reachable by session creation
        $wmiReachable = $true
        # SMB probe via existing WMI scope
        $wmiScope = $null; $searcher = $null
        try {
            $wmiScope = New-Object System.Management.ManagementScope("\\$target\root\cimv2")
            $wmiScope.Options.Timeout = [TimeSpan]::FromSeconds(30)
            if ($effectiveCred) {
                $wmiScope.Options.Username = $effectiveCred.UserName
                $wmiScope.Options.Password = $effectiveCred.GetNetworkCredential().Password
            }
            try { $wmiScope.Connect() } catch {
                throw (New-Object System.Management.ManagementException("WMI SMB probe connection failed for $target"))
            }
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
        } finally {
            if ($searcher)  { try { $searcher.Dispose() }  catch {} }
            if ($wmiScope)  { try { $wmiScope.Dispose() }  catch {} }
        }
    } else {
        # WinRM session — run standard WMI + SMB probes
        $wmiScope = $null; $searcher = $null
        try {
            $wmiScope = New-Object System.Management.ManagementScope("\\$target\root\cimv2")
            $wmiScope.Options.Timeout = [TimeSpan]::FromSeconds(30)
            if ($effectiveCred) {
                $wmiScope.Options.Username = $effectiveCred.UserName
                $wmiScope.Options.Password = $effectiveCred.GetNetworkCredential().Password
            }
            try { $wmiScope.Connect() } catch {
                throw (New-Object System.Management.ManagementException("WMI probe connection failed for $target"))
            }
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
            } finally {
                if ($searcher) { try { $searcher.Dispose() } catch {} }
            }
        } catch {
            $wmiReachable = $false
            $smbReachable = $false
            Write-Log 'WARN' "WMI unreachable on ${target}: $($_.Exception.Message)"
        } finally {
            if ($wmiScope) { try { $wmiScope.Dispose() } catch {} }
        }
    }

    # Validate caps before running collectors
    if (-not $caps -or $null -eq $caps.PSVersion) {
        Write-Log 'ERROR' "Capability probe returned incomplete data for $target. Skipping."
        if ($ProgressFile) {
            try { [System.IO.File]::AppendAllText($ProgressFile, "HOSTFAILED:Incomplete capability data`n") } catch { Write-Log 'WARN' "Progress write: $($_.Exception.Message)" }
        }
        continue
    }

    # Auto-discover collectors with forensic priority ordering
    # Processes first (highest IR value), then Network, Users, DLLs, then any others alphabetically
    $COLLECTOR_PRIORITY = @('Processes','Network','Users','DLLs')
    $allModules = Get-ChildItem "$PSScriptRoot\Modules\Collectors\*.psm1"
    $prioritized = @()
    foreach ($name in $COLLECTOR_PRIORITY) {
        $match = $allModules | Where-Object { $_.BaseName -eq $name }
        if ($match) { $prioritized += $match }
    }
    $remainder = $allModules | Where-Object { $_.BaseName -notin $COLLECTOR_PRIORITY } | Sort-Object Name
    $collectorModules = @($prioritized) + @($remainder)
    if ($Plugins -and $Plugins.Count -gt 0) {
        $collectorModules = @($collectorModules | Where-Object { $_.BaseName -in $Plugins })
    }

    $output          = [ordered]@{}
    $sources         = @{}
    $networkAdapters = @()

    foreach ($c in $collectorModules) {
        try {
            Import-Module $c.FullName -Force -ErrorAction Stop
        } catch {
            $collErr += @{ artifact = $c.BaseName; message = "Module import failed: $($_.Exception.Message)" }
            Write-Log 'ERROR' "Failed to import collector $($c.BaseName): $($_.Exception.Message)"
            if ($ProgressFile) {
                try { [System.IO.File]::AppendAllText($ProgressFile, "FAILED:$($c.BaseName):Import error`n") } catch { Write-Log 'WARN' "Progress write: $($_.Exception.Message)" }
            }
            continue
        }
        Write-Log 'INFO' "Running collector: $($c.BaseName)"
        if ($ProgressFile) {
            try { [System.IO.File]::AppendAllText($ProgressFile, "COLLECTING:$($c.BaseName)`n") } catch { Write-Log 'WARN' "Progress write: $($_.Exception.Message)" }
        }
        try {
            $result = Invoke-Collector -Session $session -TargetPSVersion $caps.PSVersion -TargetCapabilities $caps
            if ($null -eq $result -or $null -eq $result.data) {
                $collErr += @{ artifact = $c.BaseName; message = 'Plugin returned null or missing data property' }
                Write-Log 'WARN' "Collector $($c.BaseName) returned invalid result structure"
                continue
            }
            if ($result.PSObject.Properties['errors'] -and $result.errors) {
                foreach ($e in $result.errors) {
                    if ($e -is [string]) {
                        $collErr += @{ artifact = $c.BaseName; message = $e }
                    } else {
                        $collErr += $e
                    }
                }
            }
            $sources[$c.BaseName] = if ($result.PSObject.Properties['source']) { $result.source } else { @{} }
            if ($c.BaseName -eq 'Network') {
                $output['Network'] = @{ tcp = $result.data.tcp; udp = $result.data.udp; dns = $result.data.dns; adapters = $result.data.adapters }
                $networkAdapters   = $result.data.adapters
            } else {
                $output[$c.BaseName] = $result.data
            }
            Write-Log 'INFO' "Collector $($c.BaseName) complete"
            if ($ProgressFile) {
                try { [System.IO.File]::AppendAllText($ProgressFile, "DONE:$($c.BaseName)`n") } catch { Write-Log 'WARN' "Progress write: $($_.Exception.Message)" }
            }
        } catch {
            $collErr += @{ artifact = $c.BaseName; message = $_.Exception.Message }
            Write-Log 'WARN' "Collector $($c.BaseName) failed: $($_.Exception.Message)"
            if ($ProgressFile) {
                try { [System.IO.File]::AppendAllText($ProgressFile, "FAILED:$($c.BaseName):$($_.Exception.Message)`n") } catch { Write-Log 'WARN' "Progress write: $($_.Exception.Message)" }
            }
        }
    }

    } finally {
        # Close shared session (WMI hashtable sessions need no cleanup)
        if ($session -and $session -is [System.Management.Automation.Runspaces.PSSession]) {
            Remove-PSSession $session -ErrorAction SilentlyContinue
        }
    }

    # Restore TrustedHosts if we modified it
    if ($null -ne $originalTrustedHosts) {
        try {
            Set-Item WSMan:\localhost\Client\TrustedHosts -Value $originalTrustedHosts -Force -ErrorAction Stop
            Write-Log 'INFO' "Restored WinRM TrustedHosts"
        } catch { Write-Log 'WARN' "Could not restore TrustedHosts: $($_.Exception.Message)" }
    }

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
        -SmbShareName     $smbShareName `
        -ConnectionMethod  $connectionMethod `
        -WmiFallbackUsed   $usingWmiFallback `
        -DegradedArtifacts $(if ($usingWmiFallback) { @('DLLs','DNS_cache','process_hashes','process_signatures','integrity_levels','dotnet_crosscheck','user_firstlogon_timestamps') } else { @() })

    # Build full output: manifest first, then each collector's data
    $jsonOutput = [ordered]@{}
    $jsonOutput['manifest'] = $manifest
    foreach ($key in $output.Keys) {
        $jsonOutput[$key] = $output[$key]
    }

    # Write JSON output
    $written = Write-JsonOutput -Data $jsonOutput -HostDir (Join-Path $OutputPath $outHost) -Hostname $outHost
    Write-Log 'INFO' "Output: $($written.Path) | SHA256: $($written.Hash)"
    if ($ProgressFile) {
        try { [System.IO.File]::AppendAllText($ProgressFile, "OUTPUT:$($written.Path)`n") } catch { Write-Log 'WARN' "Progress write: $($_.Exception.Message)" }
    }

    $procCount  = if ($output.Contains('Processes') -and $output['Processes']) { @($output['Processes']).Count } else { 0 }
    $connCount  = if ($output.Contains('Network') -and $output['Network'] -and $output['Network'].tcp) { @($output['Network'].tcp).Count } else { 0 }
    $dnsCount   = if ($output.Contains('Network') -and $output['Network'] -and $output['Network'].dns) { @($output['Network'].dns).Count } else { 0 }
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
