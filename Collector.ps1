#Requires -Version 5.1
# Name: Quicker Collector
# Description: Quicker -- DFIR Volatile Artifact Collector
# Version: 1.6
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
$COLLECTOR_VERSION = "1.6"
$MAX_RETRY         = 3
$RETRY_WAIT_SEC    = 5
$OP_TIMEOUT_SEC    = 60
#endregion

#region --- Admin Check ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Quicker requires Administrator. Please restart as Administrator (right-click -> Run as administrator) and re-run." -ForegroundColor Red
    exit 1
}
#endregion

#region --- Setup Output & Log ---
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}
$LOG_FILE = Join-Path $OutputPath "collection.log"

function Write-Log {
    param([string]$Level, [string]$Message)
    $ts   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $line = "$ts $Level $Message"
    Add-Content -Path $LOG_FILE -Value $line -ErrorAction SilentlyContinue
    if (-not $Quiet) {
        switch ($Level) {
            'ERROR' { Write-Host $line -ForegroundColor Red    }
            'WARN'  { Write-Host $line -ForegroundColor Yellow }
            default { Write-Host $line }
        }
    }
}

Write-Log 'INFO' "Quicker Collector v$COLLECTOR_VERSION starting"
Write-Log 'INFO' "Analyst: $env:COMPUTERNAME, PS $($PSVersionTable.PSVersion), OS: $((Get-WmiObject Win32_OperatingSystem).Caption)"
Write-Log 'INFO' "OutputPath: $OutputPath"
#endregion

#region --- DateTime Normalization ---
# WMI DMTF: "20240115143022.000000+060" (offset in minutes east of UTC)
function ConvertTo-UtcIso {
    param([object]$Value, [int]$FallbackOffsetMin = 0)
    if ($null -eq $Value -or $Value -eq '') { return $null }

    # Already a [DateTime]
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [DateTimeKind]::Utc) {
            return $Value.ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
        return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }

    $s = $Value.ToString().Trim()

    # DMTF format
    if ($s -match '^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})\.\d+([+-]\d+)$') {
        try {
            $yr = [int]$Matches[1]; $mo = [int]$Matches[2]; $dy = [int]$Matches[3]
            $hr = [int]$Matches[4]; $mi = [int]$Matches[5]; $sc = [int]$Matches[6]
            $off = [int]$Matches[7]
            $local = [datetime]::new($yr, $mo, $dy, $hr, $mi, $sc)
            return $local.AddMinutes(-$off).ToString('yyyy-MM-ddTHH:mm:ssZ')
        } catch { return $null }
    }

    # Generic parse fallback
    try {
        $dt = [datetime]::Parse($s)
        return $dt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    } catch { return $null }
}
#endregion

#region --- IsPrivateIP ---
function Test-PrivateIP {
    param([string]$IP)
    if (-not $IP) { return $false }
    return ($IP -match '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.|0\.0\.0\.0$|::1$|fe80:)')
}
#endregion

#region --- Resolve Hostname ---
function Resolve-TargetHostname {
    param([string]$Target)
    if ($Target -eq 'localhost' -or $Target -eq '127.0.0.1') { return $env:COMPUTERNAME }
    if ($Target -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
        try {
            $h = [System.Net.Dns]::GetHostEntry($Target)
            return $h.HostName
        } catch {
            Write-Log 'WARN' "DNS resolution failed for $Target, using IP as fallback: $($_.Exception.Message)"
            return $Target
        }
    }
    return $Target
}
#endregion

#region --- TCP State Map ---
function ConvertFrom-TcpStateInt {
    param([int]$n)
    switch ($n) {
        1  { return 'CLOSED'       }
        2  { return 'LISTEN'       }
        3  { return 'SYN_SENT'     }
        4  { return 'SYN_RECEIVED' }
        5  { return 'ESTABLISHED'  }
        6  { return 'FIN_WAIT1'    }
        7  { return 'FIN_WAIT2'    }
        8  { return 'CLOSE_WAIT'   }
        9  { return 'CLOSING'      }
        10 { return 'LAST_ACK'     }
        11 { return 'TIME_WAIT'    }
        12 { return 'DELETE_TCB'   }
        default { return $n.ToString() }
    }
}
#endregion

#region --- SHA256 ---
function Get-FileSha256 {
    param([string]$Path)
    try { return (Get-FileHash -Path $Path -Algorithm SHA256 -ErrorAction Stop).Hash }
    catch { return $null }
}
#endregion

#region --- Capability Probe ---
function Get-TargetCaps {
    param([string]$Target, [System.Management.Automation.PSCredential]$Cred)

    $c = @{
        PSVersion             = 0
        OSVersion             = ''; OSBuild = ''; OSCaption = ''
        HasCIM                = $false
        HasNetTCPIP           = $false
        HasDNSClient          = $false
        IsServerCore          = $false
        TimezoneOffsetMinutes = 0
        Error                 = $null
    }

    $isLocal = ($Target -eq 'localhost' -or $Target -eq '127.0.0.1' -or $Target -ieq $env:COMPUTERNAME)

    try {
        if ($isLocal) {
            $c.PSVersion = $PSVersionTable.PSVersion.Major
            $os = Get-WmiObject Win32_OperatingSystem
            $c.OSVersion = $os.Version; $c.OSBuild = $os.BuildNumber; $c.OSCaption = $os.Caption
            $tz = Get-WmiObject Win32_TimeZone; $c.TimezoneOffsetMinutes = $tz.Bias
            $inst = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'InstallationType' -ErrorAction SilentlyContinue
            $c.IsServerCore = ($inst -and $inst.InstallationType -eq 'Server Core')

            if ($c.PSVersion -ge 3) {
                $c.HasCIM = $true
                try { Get-CimInstance -Namespace ROOT/StandardCimv2 -ClassName MSFT_NetTCPConnection -OperationTimeoutSec $OP_TIMEOUT_SEC -ErrorAction Stop | Select-Object -First 1 | Out-Null; $c.HasNetTCPIP = $true } catch {}
                try { Get-CimInstance -Namespace ROOT/StandardCimv2 -ClassName MSFT_DNSClientCache  -OperationTimeoutSec $OP_TIMEOUT_SEC -ErrorAction Stop | Select-Object -First 1 | Out-Null; $c.HasDNSClient = $true } catch {}
            }
        } else {
            # Remote: use WinRM only (no DCOM/RPC) - all probing via PSSession
            $so = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
            $spArgs = @{ ComputerName = $Target; SessionOption = $so; ErrorAction = 'Stop'; Port = 5985 }
            if ($Cred) { $spArgs.Credential = $Cred }
            $sess = New-PSSession @spArgs
            try {
                $r = Invoke-Command -Session $sess -ScriptBlock {
                    $v   = $PSVersionTable.PSVersion.Major
                    $os  = Get-WmiObject Win32_OperatingSystem
                    $tz  = Get-WmiObject Win32_TimeZone
                    $hCim = $v -ge 3
                    $hNet = $false; $hDns = $false
                    if ($hCim) {
                        try { Get-CimInstance -Namespace ROOT/StandardCimv2 -ClassName MSFT_NetTCPConnection -ErrorAction Stop | Select-Object -First 1 | Out-Null; $hNet = $true } catch {}
                        try { Get-CimInstance -Namespace ROOT/StandardCimv2 -ClassName MSFT_DNSClientCache  -ErrorAction Stop | Select-Object -First 1 | Out-Null; $hDns = $true } catch {}
                    }
                    $inst = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'InstallationType' -ErrorAction SilentlyContinue
                    New-Object PSObject -Property @{
                        PSVersion=$v; OSVersion=$os.Version; OSBuild=$os.BuildNumber; OSCaption=$os.Caption
                        TZBias=$tz.Bias; HasCIM=$hCim; HasNetTCPIP=$hNet; HasDNSClient=$hDns
                        IsServerCore=($inst -and $inst.InstallationType -eq 'Server Core')
                    }
                }
                $c.PSVersion             = $r.PSVersion
                $c.OSVersion             = $r.OSVersion
                $c.OSBuild               = $r.OSBuild
                $c.OSCaption             = $r.OSCaption
                $c.TimezoneOffsetMinutes = $r.TZBias
                $c.HasCIM                = $r.HasCIM
                $c.HasNetTCPIP           = $r.HasNetTCPIP
                $c.HasDNSClient          = $r.HasDNSClient
                $c.IsServerCore          = $r.IsServerCore
            } finally { Remove-PSSession $sess -ErrorAction SilentlyContinue }
        }
    } catch { $c.Error = $_.Exception.Message }

    return $c
}
#endregion

#region --- Process Collection ---
# PS 2.0-compatible scriptblock for remote WMI path
# Uses ManagementObjectSearcher with EnumerationOptions to prevent result truncation
$PROC_SB_WMI = {
    $out = @()
    $searcher = New-Object System.Management.ManagementObjectSearcher("root\cimv2", "SELECT * FROM Win32_Process")
    $searcher.Options.ReturnImmediately = $false
    $searcher.Options.Rewindable = $false
    $procs = $searcher.Get()
    foreach ($p in $procs) {
        $pid_ = $null; $ppid = $null; $name_ = $null; $cmdLine = $null; $exePath = $null; $cdate = $null; $ws = [long]0; $vs = [long]0; $sid = $null; $hc = $null
        try { $pid_   = [int]$p.ProcessId }       catch {}
        try { $ppid   = [int]$p.ParentProcessId } catch {}
        try { $name_  = $p.Name }                 catch {}
        try { $cmdLine = $p.CommandLine }          catch {}
        try { $exePath = $p.ExecutablePath }       catch {}
        try { $cdate  = $p.CreationDate }          catch {}
        try { $ws     = [long]$p.WorkingSetSize }  catch {}
        try { $vs     = [long]$p.VirtualSize }     catch {}
        try { $sid    = [int]$p.SessionId }        catch {}
        try { $hc     = [int]$p.HandleCount }      catch {}
        if ($pid_ -ne $null) {
            $out += New-Object PSObject -Property @{
                ProcessId       = $pid_
                ParentProcessId = $ppid
                Name            = $name_
                CommandLine     = $cmdLine
                ExecutablePath  = $exePath
                CreationDate    = $cdate
                WorkingSetSize  = $ws
                VirtualSize     = $vs
                SessionId       = $sid
                HandleCount     = $hc
                source          = 'wmi'
            }
        }
    }
    # .NET cross-check
    $dotnet = @()
    try {
        $dnProcs = [System.Diagnostics.Process]::GetProcesses()
        $wmiPids = @{}; foreach ($x in $out) { $wmiPids[$x.ProcessId] = $true }
        foreach ($dp in $dnProcs) {
            if (-not $wmiPids.ContainsKey([int]$dp.Id)) {
                $exeFn = $null; $startT = $null; $ws2 = [long]0; $vs2 = [long]0
                try { $exeFn  = $dp.MainModule.FileName }                                          catch {}
                try { $startT = $dp.StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } catch {}
                try { $ws2    = [long]$dp.WorkingSet64 }                                           catch {}
                try { $vs2    = [long]$dp.VirtualMemorySize64 }                                    catch {}
                $dotnet += New-Object PSObject -Property @{
                    ProcessId = [int]$dp.Id; ParentProcessId = $null
                    Name = $dp.ProcessName; CommandLine = $null; ExecutablePath = $exeFn
                    CreationDate = $startT; WorkingSetSize = $ws2; VirtualSize = $vs2
                    SessionId = $null; HandleCount = $null; source = 'dotnet_fallback'
                }
            }
        }
    } catch {}
    $out += $dotnet
    New-Object PSObject -Property @{ Procs = $out; FallbackCount = $dotnet.Count }
}

# CIM scriptblock for remote PS 3+ path
$PROC_SB_CIM = {
    $out = @()
    $raw = Get-CimInstance Win32_Process -OperationTimeoutSec 60
    foreach ($p in $raw) {
        $pid_ = $null; $ppid = $null; $name_ = $null
        try { $pid_  = [int]$p.ProcessId }       catch {}
        try { $ppid  = [int]$p.ParentProcessId } catch {}
        try { $name_ = $p.Name }                 catch {}
        if ($pid_ -eq $null) { continue }
        $entry = New-Object PSObject -Property @{
            ProcessId = $pid_; ParentProcessId = $ppid; Name = $name_
            CommandLine = $null; ExecutablePath = $null
            CreationDateUtc = $null; CreationDate = $null
            WorkingSetSize = [long]0; VirtualSize = [long]0
            SessionId = $null; HandleCount = $null; source = 'cim'
        }
        try { $entry.CommandLine     = $p.CommandLine } catch {}
        try { $entry.ExecutablePath  = $p.ExecutablePath } catch {}
        try { $entry.CreationDateUtc = if ($p.CreationDate) { $p.CreationDate.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $null } } catch {}
        try { $entry.CreationDate    = if ($p.CreationDate) { $p.CreationDate.ToString('o') } else { $null } } catch {}
        try { $entry.WorkingSetSize  = [long]$p.WorkingSetSize } catch {}
        try { $entry.VirtualSize     = [long]$p.VirtualSize }    catch {}
        try { $entry.SessionId       = [int]$p.SessionId }       catch {}
        try { $entry.HandleCount     = [int]$p.HandleCount }     catch {}
        $out += $entry
    }
    # .NET cross-check
    $dotnet = @()
    try {
        $dnProcs = [System.Diagnostics.Process]::GetProcesses()
        $cimPids = @{}; foreach ($x in $out) { $cimPids[$x.ProcessId] = $true }
        foreach ($dp in $dnProcs) {
            if (-not $cimPids.ContainsKey([int]$dp.Id)) {
                $exeFn = $null; $startT = $null; $ws2 = [long]0; $vs2 = [long]0
                try { $exeFn  = $dp.MainModule.FileName }                                          catch {}
                try { $startT = $dp.StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } catch {}
                try { $ws2    = [long]$dp.WorkingSet64 }                                           catch {}
                try { $vs2    = [long]$dp.VirtualMemorySize64 }                                    catch {}
                $dotnet += New-Object PSObject -Property @{
                    ProcessId = [int]$dp.Id; ParentProcessId = $null
                    Name = $dp.ProcessName; CommandLine = $null; ExecutablePath = $exeFn
                    CreationDateUtc = $startT; CreationDate = $null
                    WorkingSetSize = $ws2; VirtualSize = $vs2
                    SessionId = $null; HandleCount = $null; source = 'dotnet_fallback'
                }
            }
        }
    } catch {}
    $out += $dotnet
    New-Object PSObject -Property @{ Procs = $out; FallbackCount = $dotnet.Count }
}

function Get-ProcessData {
    param([string]$Target, [System.Management.Automation.PSCredential]$Cred, [hashtable]$Caps)

    $errors       = @()
    $procs        = @()
    $fallbackNote = $null
    $isLocal      = ($Target -eq 'localhost' -or $Target -eq '127.0.0.1' -or $Target -ieq $env:COMPUTERNAME)

    try {
        if ($isLocal) {
            if ($Caps.PSVersion -ge 3) {
                # CIM path - per-process try/catch to never silently drop
                $raw = Get-CimInstance Win32_Process -OperationTimeoutSec $OP_TIMEOUT_SEC
                foreach ($p in $raw) {
                    $pid_ = $null; $ppid = $null; $name_ = $null
                    try { $pid_  = [int]$p.ProcessId }       catch {}
                    try { $ppid  = [int]$p.ParentProcessId } catch {}
                    try { $name_ = $p.Name }                 catch {}
                    if ($pid_ -eq $null) { continue }
                    $entry = @{
                        ProcessId        = $pid_
                        ParentProcessId  = $ppid
                        Name             = $name_
                        CommandLine      = $null
                        ExecutablePath   = $null
                        CreationDateUTC  = $null
                        CreationDateLocal = $null
                        WorkingSetSize   = [long]0
                        VirtualSize      = [long]0
                        SessionId        = $null
                        HandleCount      = $null
                        source           = 'cim'
                    }
                    try { $entry.CommandLine      = $p.CommandLine } catch { $errors += @{ artifact='process_detail'; ProcessId=$pid_; Name=$name_; message=$_.Exception.Message } }
                    try { $entry.ExecutablePath   = $p.ExecutablePath } catch {}
                    try { $entry.CreationDateUTC  = if ($p.CreationDate) { $p.CreationDate.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $null } } catch {}
                    try { $entry.CreationDateLocal = if ($p.CreationDate) { $p.CreationDate.ToString('o') } else { $null } } catch {}
                    try { $entry.WorkingSetSize   = [long]$p.WorkingSetSize } catch {}
                    try { $entry.VirtualSize      = [long]$p.VirtualSize }   catch {}
                    try { $entry.SessionId        = [int]$p.SessionId }      catch {}
                    try { $entry.HandleCount      = [int]$p.HandleCount }    catch {}
                    $procs += $entry
                }
            } else {
                # WMI path with EnumerationOptions to prevent truncation
                $searcher = New-Object System.Management.ManagementObjectSearcher("root\cimv2", "SELECT * FROM Win32_Process")
                $searcher.Options.ReturnImmediately = $false
                $searcher.Options.Rewindable = $false
                $raw = $searcher.Get()
                foreach ($p in $raw) {
                    $pid_ = $null; $ppid = $null; $name_ = $null
                    try { $pid_  = [int]$p.ProcessId }       catch {}
                    try { $ppid  = [int]$p.ParentProcessId } catch {}
                    try { $name_ = $p.Name }                 catch {}
                    if ($pid_ -eq $null) { continue }
                    $utc = $null; $cd = $null; $cmdLine = $null; $exePath = $null; $ws = [long]0; $vs = [long]0; $sid = $null; $hc = $null
                    try { $cd      = $p.CreationDate; $utc = ConvertTo-UtcIso -Value $cd -FallbackOffsetMin $Caps.TimezoneOffsetMinutes } catch {}
                    try { $cmdLine = $p.CommandLine }         catch { $errors += @{ artifact='process_detail'; ProcessId=$pid_; Name=$name_; message=$_.Exception.Message } }
                    try { $exePath = $p.ExecutablePath }      catch {}
                    try { $ws      = [long]$p.WorkingSetSize } catch {}
                    try { $vs      = [long]$p.VirtualSize }   catch {}
                    try { $sid     = [int]$p.SessionId }      catch {}
                    try { $hc      = [int]$p.HandleCount }    catch {}
                    $procs += @{
                        ProcessId        = $pid_
                        ParentProcessId  = $ppid
                        Name             = $name_
                        CommandLine      = $cmdLine
                        ExecutablePath   = $exePath
                        CreationDateUTC  = $utc
                        CreationDateLocal = $cd
                        WorkingSetSize   = $ws
                        VirtualSize      = $vs
                        SessionId        = $sid
                        HandleCount      = $hc
                        source           = 'wmi'
                    }
                }
            }

            # .NET cross-check: catch any processes missing from WMI/CIM
            try {
                $dnProcs      = [System.Diagnostics.Process]::GetProcesses()
                $collectedPIDs = @{}
                foreach ($x in $procs) { $collectedPIDs[[int]$x.ProcessId] = $true }
                $fallbackCount = 0
                foreach ($dp in $dnProcs) {
                    if (-not $collectedPIDs.ContainsKey([int]$dp.Id)) {
                        $exeFn = $null; $startT = $null; $ws2 = [long]0; $vs2 = [long]0
                        try { $exeFn  = $dp.MainModule.FileName }                                          catch {}
                        try { $startT = $dp.StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } catch {}
                        try { $ws2    = [long]$dp.WorkingSet64 }                                           catch {}
                        try { $vs2    = [long]$dp.VirtualMemorySize64 }                                    catch {}
                        $procs += @{
                            ProcessId        = [int]$dp.Id
                            ParentProcessId  = $null
                            Name             = $dp.ProcessName
                            CommandLine      = $null
                            ExecutablePath   = $exeFn
                            CreationDateUTC  = $startT
                            CreationDateLocal = $null
                            WorkingSetSize   = $ws2
                            VirtualSize      = $vs2
                            SessionId        = $null
                            HandleCount      = $null
                            source           = 'dotnet_fallback'
                        }
                        $fallbackCount++
                        Write-Log 'WARN' "PID=$($dp.Id) Name=$($dp.ProcessName) absent from WMI/CIM - added via .NET fallback"
                    }
                }
                if ($fallbackCount -gt 0) {
                    $fallbackNote = "$fallbackCount process(es) added via .NET fallback (absent from WMI/CIM)"
                }
            } catch {
                Write-Log 'WARN' ".NET cross-check failed: $($_.Exception.Message)"
            }

        } else {
            $so = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
            $spArgs = @{ ComputerName = $Target; SessionOption = $so; ErrorAction = 'Stop' }
            if ($Cred) { $spArgs.Credential = $Cred }
            $sess = New-PSSession @spArgs
            try {
                $sb  = if ($Caps.PSVersion -ge 3) { $PROC_SB_CIM } else { $PROC_SB_WMI }
                $r   = Invoke-Command -Session $sess -ScriptBlock $sb
                $raw = $r.Procs
                if ($r.FallbackCount -gt 0) {
                    $fallbackNote = "$($r.FallbackCount) process(es) added via .NET fallback on remote (absent from WMI/CIM)"
                    Write-Log 'WARN' "Remote: $fallbackNote"
                }
                foreach ($p in $raw) {
                    $utcVal = if ($p.CreationDateUtc)  { $p.CreationDateUtc }
                              elseif ($p.CreationDate) { ConvertTo-UtcIso -Value $p.CreationDate -FallbackOffsetMin $Caps.TimezoneOffsetMinutes }
                              else                     { $null }
                    $locVal = if ($p.CreationDate -and -not $p.CreationDateUtc) { $p.CreationDate } else { $null }
                    $pid_   = $null; try { $pid_ = [int]$p.ProcessId } catch {}
                    if ($pid_ -eq $null) { continue }
                    $ppid2 = $null; try { if ($p.ParentProcessId -ne $null) { $ppid2 = [int]$p.ParentProcessId } } catch {}
                    $ws2   = [long]0; try { $ws2 = [long]$p.WorkingSetSize } catch {}
                    $vs2   = [long]0; try { $vs2 = [long]$p.VirtualSize }    catch {}
                    $procs += @{
                        ProcessId        = $pid_
                        ParentProcessId  = $ppid2
                        Name             = $p.Name
                        CommandLine      = $p.CommandLine
                        ExecutablePath   = $p.ExecutablePath
                        CreationDateUTC  = $utcVal
                        CreationDateLocal = $locVal
                        WorkingSetSize   = $ws2
                        VirtualSize      = $vs2
                        SessionId        = $p.SessionId
                        HandleCount      = $p.HandleCount
                        source           = $p.source
                    }
                }
            } finally { Remove-PSSession $sess -ErrorAction SilentlyContinue }
        }
    } catch {
        $errors += @{ artifact = 'processes'; message = $_.Exception.Message }
        Write-Log 'ERROR' "Process collection failed: $($_.Exception.Message)"
    }

    return @{ data = $procs; errors = $errors; sourceNote = $fallbackNote }
}
#endregion

#region --- Netstat Parser (shared) ---
function ConvertFrom-NetstatOutput {
    param([string[]]$Lines)
    $out = @()
    foreach ($line in $Lines) {
        $line = $line.Trim()
        if ($line -match '^TCP\s+(\[?[\d.:a-fA-F]+\]?):(\d+)\s+(\[?[\d.:a-fA-F*]+\]?):(\d+|\*)\s+(\S+)\s+(\d+)\s*$') {
            $la = $Matches[1] -replace '[\[\]]',''
            $ra = $Matches[3] -replace '[\[\]]',''
            $out += @{
                LocalAddress   = $la
                LocalPort      = [int]$Matches[2]
                RemoteAddress  = $ra
                RemotePort     = if ($Matches[4] -eq '*') { 0 } else { [int]$Matches[4] }
                State          = $Matches[5]
                OwningProcess  = [int]$Matches[6]
                InterfaceAlias = if ($la -eq '0.0.0.0' -or $la -eq '::') { 'ALL_INTERFACES' } else { $la }
                CreationTime   = $null
                ReverseDns     = $null
                DnsMatch       = $null
                IsPrivateIP    = $false
            }
        }
    }
    return $out
}
#endregion

#region --- Adapter Enumeration ---
# PS 2.0-compatible WMI scriptblock
$ADAPTER_SB_WMI = {
    $out = @()
    $ncidMap = @{}
    try {
        $netAdapters = Get-WmiObject Win32_NetworkAdapter
        foreach ($a in $netAdapters) {
            if ($a.InterfaceIndex -ne $null -and $a.NetConnectionID) {
                $ncidMap[[int]$a.InterfaceIndex] = $a.NetConnectionID
            }
        }
    } catch {}
    $cfgs = Get-WmiObject Win32_NetworkAdapterConfiguration -Filter "IPEnabled=true"
    foreach ($cfg in $cfgs) {
        $ips = @()
        if ($cfg.IPAddress) { foreach ($ip in $cfg.IPAddress) { if ($ip) { $ips += $ip } } }
        $gw  = $null
        if ($cfg.DefaultIPGateway) { $gw = @($cfg.DefaultIPGateway)[0] }
        $dns = @()
        if ($cfg.DNSServerSearchOrder) { foreach ($d in $cfg.DNSServerSearchOrder) { if ($d) { $dns += $d } } }
        $alias = if ($ncidMap.ContainsKey([int]$cfg.InterfaceIndex)) { $ncidMap[[int]$cfg.InterfaceIndex] } else { $cfg.Description }
        $out += New-Object PSObject -Property @{
            AdapterName    = $cfg.Description
            InterfaceAlias = $alias
            IPAddresses    = $ips
            MACAddress     = $cfg.MACAddress
            DefaultGateway = $gw
            DNSServers     = $dns
            DHCPEnabled    = [bool]$cfg.DHCPEnabled
        }
    }
    $out
}

# PS 3+ CIM scriptblock
$ADAPTER_SB_CIM = {
    $out = @()
    $ncidMap = @{}
    try {
        $netAdapters = Get-CimInstance Win32_NetworkAdapter
        foreach ($a in $netAdapters) {
            if ($a.InterfaceIndex -ne $null -and $a.NetConnectionID) {
                $ncidMap[[int]$a.InterfaceIndex] = $a.NetConnectionID
            }
        }
    } catch {}
    $cfgs = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=true"
    foreach ($cfg in $cfgs) {
        $ips = @()
        if ($cfg.IPAddress) { $ips = @($cfg.IPAddress | Where-Object { $_ }) }
        $gw  = $null
        if ($cfg.DefaultIPGateway) { $gw = @($cfg.DefaultIPGateway)[0] }
        $dns = @()
        if ($cfg.DNSServerSearchOrder) { $dns = @($cfg.DNSServerSearchOrder | Where-Object { $_ }) }
        $alias = if ($ncidMap.ContainsKey([int]$cfg.InterfaceIndex)) { $ncidMap[[int]$cfg.InterfaceIndex] } else { $cfg.Description }
        $out += New-Object PSObject -Property @{
            AdapterName    = $cfg.Description
            InterfaceAlias = $alias
            IPAddresses    = $ips
            MACAddress     = $cfg.MACAddress
            DefaultGateway = $gw
            DNSServers     = $dns
            DHCPEnabled    = [bool]$cfg.DHCPEnabled
        }
    }
    $out
}

function Get-AdapterData {
    param([string]$Target, [System.Management.Automation.PSCredential]$Cred, [hashtable]$Caps)

    $errors   = @()
    $adapters = @()
    $isLocal  = ($Target -eq 'localhost' -or $Target -eq '127.0.0.1' -or $Target -ieq $env:COMPUTERNAME)

    try {
        $sb = if ($Caps.PSVersion -ge 3) { $ADAPTER_SB_CIM } else { $ADAPTER_SB_WMI }
        if ($isLocal) {
            $raw = & $sb
        } else {
            $so = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
            $spArgs = @{ ComputerName = $Target; SessionOption = $so; ErrorAction = 'Stop' }
            if ($Cred) { $spArgs.Credential = $Cred }
            $sess = New-PSSession @spArgs
            try   { $raw = Invoke-Command -Session $sess -ScriptBlock $sb }
            finally { Remove-PSSession $sess -ErrorAction SilentlyContinue }
        }
        foreach ($a in @($raw)) {
            $ips = @(); if ($a.IPAddresses) { foreach ($ip in @($a.IPAddresses)) { if ($ip) { $ips += $ip.ToString() } } }
            $dns = @(); if ($a.DNSServers)  { foreach ($d  in @($a.DNSServers))  { if ($d)  { $dns += $d.ToString()  } } }
            $adapters += @{
                AdapterName    = $a.AdapterName
                InterfaceAlias = $a.InterfaceAlias
                IPAddresses    = $ips
                MACAddress     = $a.MACAddress
                DefaultGateway = $a.DefaultGateway
                DNSServers     = $dns
                DHCPEnabled    = $a.DHCPEnabled
            }
        }
    } catch {
        $errors += @{ artifact = 'network_adapters'; message = $_.Exception.Message }
        Write-Log 'ERROR' "Adapter enumeration failed: $($_.Exception.Message)"
    }

    return @{ data = $adapters; errors = $errors }
}
#endregion

#region --- Network TCP Collection ---
# PS 2.0-compatible scriptblock
$NET_SB_LEGACY = {
    $lines = cmd /c "netstat -ano" 2>&1
    New-Object PSObject -Property @{ Source = 'netstat_legacy'; Lines = $lines }
}
$NET_SB_FALLBACK = {
    $lines = & netstat -ano 2>&1
    New-Object PSObject -Property @{ Source = 'netstat_fallback'; Lines = $lines }
}
$NET_SB_CIM = {
    $out = @()
    try {
        $raw = Get-CimInstance -Namespace ROOT/StandardCimv2 -ClassName MSFT_NetTCPConnection
        foreach ($c in $raw) {
            $out += New-Object PSObject -Property @{
                LocalAddress   = $c.LocalAddress
                LocalPort      = [int]$c.LocalPort
                RemoteAddress  = $c.RemoteAddress
                RemotePort     = [int]$c.RemotePort
                OwningProcess  = [int]$c.OwningProcess
                StateInt       = [int]$c.State
                InterfaceAlias = $c.InterfaceAlias
            }
        }
        New-Object PSObject -Property @{ Source = 'cim'; Connections = $out }
    } catch {
        $lines = & netstat -ano 2>&1
        New-Object PSObject -Property @{ Source = 'netstat_fallback'; Lines = $lines }
    }
}

function Get-NetworkData {
    param([string]$Target, [System.Management.Automation.PSCredential]$Cred, [hashtable]$Caps)

    $errors  = @()
    $conns   = @()
    $source  = 'unknown'
    $isLocal = ($Target -eq 'localhost' -or $Target -eq '127.0.0.1' -or $Target -ieq $env:COMPUTERNAME)

    try {
        if ($isLocal) {
            if ($Caps.HasNetTCPIP) {
                $source = 'cim'
                $raw = Get-CimInstance -Namespace ROOT/StandardCimv2 -ClassName MSFT_NetTCPConnection -OperationTimeoutSec $OP_TIMEOUT_SEC
                foreach ($c in $raw) {
                    $la = $c.LocalAddress; $ra = $c.RemoteAddress
                    $conns += @{
                        LocalAddress   = $la
                        LocalPort      = [int]$c.LocalPort
                        RemoteAddress  = $ra
                        RemotePort     = [int]$c.RemotePort
                        OwningProcess  = [int]$c.OwningProcess
                        State          = ConvertFrom-TcpStateInt ([int]$c.State)
                        InterfaceAlias = if ($la -eq '0.0.0.0' -or $la -eq '::') { 'ALL_INTERFACES' } else { if ($c.InterfaceAlias) { $c.InterfaceAlias } else { $la } }
                        CreationTime   = $null
                        ReverseDns     = $null
                        DnsMatch       = $null
                        IsPrivateIP    = Test-PrivateIP $ra
                    }
                }
            } elseif ($Caps.PSVersion -ge 3) {
                $source = 'netstat_fallback'
                $lines  = & netstat -ano 2>&1
                $conns  = ConvertFrom-NetstatOutput -Lines $lines
            } else {
                $source = 'netstat_legacy'
                $lines  = cmd /c "netstat -ano" 2>&1
                $conns  = ConvertFrom-NetstatOutput -Lines $lines
            }
        } else {
            $so = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
            $spArgs = @{ ComputerName = $Target; SessionOption = $so; ErrorAction = 'Stop' }
            if ($Cred) { $spArgs.Credential = $Cred }
            $sess = New-PSSession @spArgs
            try {
                if ($Caps.HasNetTCPIP) { $sb = $NET_SB_CIM }
                elseif ($Caps.PSVersion -ge 3) { $sb = $NET_SB_FALLBACK }
                else { $sb = $NET_SB_LEGACY }

                $r = Invoke-Command -Session $sess -ScriptBlock $sb
                $source = $r.Source

                if ($r.Source -eq 'cim' -and $r.Connections) {
                    foreach ($c in $r.Connections) {
                        $la = $c.LocalAddress; $ra = $c.RemoteAddress
                        $conns += @{
                            LocalAddress   = $la
                            LocalPort      = [int]$c.LocalPort
                            RemoteAddress  = $ra
                            RemotePort     = [int]$c.RemotePort
                            OwningProcess  = [int]$c.OwningProcess
                            State          = ConvertFrom-TcpStateInt $c.StateInt
                            InterfaceAlias = if ($la -eq '0.0.0.0' -or $la -eq '::') { 'ALL_INTERFACES' } else { if ($c.InterfaceAlias) { $c.InterfaceAlias } else { $la } }
                            CreationTime   = $null
                            ReverseDns     = $null
                            DnsMatch       = $null
                            IsPrivateIP    = Test-PrivateIP $ra
                        }
                    }
                } elseif ($r.Lines) {
                    $conns = ConvertFrom-NetstatOutput -Lines $r.Lines
                }
            } finally { Remove-PSSession $sess -ErrorAction SilentlyContinue }
        }
    } catch {
        $errors += @{ artifact = 'network_tcp'; message = $_.Exception.Message }
        Write-Log 'ERROR' "Network collection failed: $($_.Exception.Message)"
    }

    return @{ data = $conns; source = $source; errors = $errors }
}
#endregion

#region --- DNS Cache Collection ---
# Shared ipconfig parser (PS 2.0 compatible)
$DNS_PARSE_SB = {
    param([string[]]$Lines)
    $out     = @()
    $entry   = ''; $data = ''; $recType = ''; $ttl = 0
    foreach ($line in $Lines) {
        $line = $line.Trim()
        if ($line -match 'Record Name[\s.]*:[\s]*(.+)') {
            # flush previous
            if ($entry -and $data) {
                $out += New-Object PSObject -Property @{ Entry=$entry; Name=$entry; Data=$data; Type=$recType; TTL=$ttl }
                $entry=''; $data=''; $recType=''; $ttl=0
            }
            $entry = $Matches[1].Trim()
        } elseif ($line -match 'Record Type[\s.]*:[\s]*(.+)') {
            $recType = $Matches[1].Trim()
        } elseif ($line -match 'Time To Live[\s.]*:[\s]*(\d+)') {
            $ttl = [int]$Matches[1]
        } elseif ($line -match '(A|AAAA)\s+\(Host\) Record[\s.]*:[\s]*(.+)') {
            $data = $Matches[2].Trim()
        } elseif ($line -match 'Host Record[\s.]*:[\s]*(.+)') {
            $data = $Matches[1].Trim()
        } elseif (-not $data -and $line -match '^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$') {
            $data = $line
        }
    }
    if ($entry -and $data) {
        $out += New-Object PSObject -Property @{ Entry=$entry; Name=$entry; Data=$data; Type=$recType; TTL=$ttl }
    }
    $out
}

$DNS_SB_CIM = {
    try {
        $out = @()
        $raw = Get-CimInstance -Namespace ROOT/StandardCimv2 -ClassName MSFT_DNSClientCache
        foreach ($d in $raw) {
            $out += New-Object PSObject -Property @{ Entry=$d.Entry; Name=$d.Name; Data=$d.Data; Type=[int]$d.Type; TTL=[int]$d.TimeToLive }
        }
        New-Object PSObject -Property @{ Source='cim'; Entries=$out }
    } catch {
        $lines = & ipconfig /displaydns 2>&1
        New-Object PSObject -Property @{ Source='ipconfig_fallback'; Lines=$lines }
    }
}

function Get-DnsData {
    param([string]$Target, [System.Management.Automation.PSCredential]$Cred, [hashtable]$Caps)

    $errors  = @()
    $entries = @()
    $source  = 'unknown'
    $isLocal = ($Target -eq 'localhost' -or $Target -eq '127.0.0.1' -or $Target -ieq $env:COMPUTERNAME)

    try {
        if ($isLocal) {
            if ($Caps.HasDNSClient) {
                $source = 'cim'
                $raw = Get-CimInstance -Namespace ROOT/StandardCimv2 -ClassName MSFT_DNSClientCache -OperationTimeoutSec $OP_TIMEOUT_SEC
                foreach ($d in $raw) {
                    $entries += @{ Entry=$d.Entry; Name=$d.Name; Data=$d.Data; Type=[int]$d.Type; TTL=[int]$d.TimeToLive }
                }
            } elseif ($Caps.PSVersion -ge 3) {
                $source = 'ipconfig_fallback'
                $lines  = & ipconfig /displaydns 2>&1
                $parsed = & $DNS_PARSE_SB -Lines $lines
                foreach ($d in $parsed) { $entries += @{ Entry=$d.Entry; Name=$d.Name; Data=$d.Data; Type=$d.Type; TTL=$d.TTL } }
            } else {
                $source = 'ipconfig_legacy'
                $lines  = cmd /c "ipconfig /displaydns" 2>&1
                $parsed = & $DNS_PARSE_SB -Lines $lines
                foreach ($d in $parsed) { $entries += @{ Entry=$d.Entry; Name=$d.Name; Data=$d.Data; Type=$d.Type; TTL=$d.TTL } }
            }
        } else {
            $so = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
            $spArgs = @{ ComputerName = $Target; SessionOption = $so; ErrorAction = 'Stop' }
            if ($Cred) { $spArgs.Credential = $Cred }
            $sess = New-PSSession @spArgs
            try {
                if ($Caps.HasDNSClient) { $sb = $DNS_SB_CIM }
                elseif ($Caps.PSVersion -ge 3) {
                    $sb = { $lines = & ipconfig /displaydns 2>&1; New-Object PSObject -Property @{ Source='ipconfig_fallback'; Lines=$lines } }
                } else {
                    $sb = { $lines = cmd /c "ipconfig /displaydns" 2>&1; New-Object PSObject -Property @{ Source='ipconfig_legacy'; Lines=$lines } }
                }

                $r = Invoke-Command -Session $sess -ScriptBlock $sb
                $source = $r.Source

                if ($r.Source -eq 'cim' -and $r.Entries) {
                    foreach ($d in $r.Entries) {
                        $entries += @{ Entry=$d.Entry; Name=$d.Name; Data=$d.Data; Type=[int]$d.Type; TTL=[int]$d.TTL }
                    }
                } elseif ($r.Lines) {
                    $parsed = & $DNS_PARSE_SB -Lines $r.Lines
                    foreach ($d in $parsed) { $entries += @{ Entry=$d.Entry; Name=$d.Name; Data=$d.Data; Type=$d.Type; TTL=$d.TTL } }
                }
            } finally { Remove-PSSession $sess -ErrorAction SilentlyContinue }
        }
    } catch {
        $errors += @{ artifact = 'dns_cache'; message = $_.Exception.Message }
        Write-Log 'ERROR' "DNS collection failed: $($_.Exception.Message)"
    }

    return @{ data = $entries; source = $source; errors = $errors }
}
#endregion

#region --- InterfaceAlias Resolution ---
function Resolve-InterfaceAlias {
    param([array]$Connections, [array]$Adapters)

    # Build IP → adapter alias map (strip IPv6 zone IDs for matching)
    $ipToAlias = @{}
    foreach ($adapter in $Adapters) {
        $alias = if ($adapter.InterfaceAlias) { $adapter.InterfaceAlias } else { $adapter.AdapterName }
        foreach ($ip in @($adapter.IPAddresses)) {
            if ($ip) {
                $ipKey = ($ip.ToString()) -replace '%.*$', ''
                if (-not $ipToAlias.ContainsKey($ipKey)) { $ipToAlias[$ipKey] = $alias }
            }
        }
    }

    $unknownCount = 0
    $out = @()
    foreach ($c in $Connections) {
        $la = if ($c.LocalAddress) { ($c.LocalAddress.ToString()) -replace '%.*$', '' } else { '' }

        $alias = if (-not $la -or $la -eq '0.0.0.0' -or $la -eq '::') {
            'ALL_INTERFACES'
        } elseif ($la -eq '127.0.0.1' -or $la -eq '::1') {
            'LOOPBACK'
        } elseif ($ipToAlias.ContainsKey($la)) {
            $ipToAlias[$la]
        } else {
            $unknownCount++
            'UNKNOWN'
        }

        $e = $c.Clone()
        $e.InterfaceAlias = $alias
        $out += $e
    }

    if ($unknownCount -gt 0) {
        Write-Log 'WARN' "InterfaceAlias: $unknownCount connection(s) unmatched to any adapter IP -> UNKNOWN"
    }
    return $out
}
#endregion

#region --- DNS Enrichment ---
function Add-DnsEnrichment {
    param([array]$Connections, [array]$DnsCache)

    # Build IP -> entry map from dns cache
    $dnsMap = @{}
    foreach ($d in $DnsCache) {
        if ($d.Data -and -not $dnsMap.ContainsKey($d.Data)) { $dnsMap[$d.Data] = $d.Entry }
    }

    # Unique remote IPs for reverse DNS
    $uniqueIPs = @($Connections | Where-Object { $_.RemoteAddress -and $_.RemoteAddress -ne '0.0.0.0' -and $_.RemoteAddress -ne '::' -and $_.RemoteAddress -ne '*' } | ForEach-Object { $_.RemoteAddress } | Sort-Object -Unique)

    $revMap = @{}
    foreach ($ip in $uniqueIPs) {
        try {
            $h = [System.Net.Dns]::GetHostEntry($ip)
            $revMap[$ip] = $h.HostName
        } catch {
            # No PTR record or lookup failed — store IP itself so ReverseDns is never null
            $revMap[$ip] = $ip
        }
    }

    $out = @()
    foreach ($c in $Connections) {
        $e = $c.Clone()
        $ip = $c.RemoteAddress
        if ($ip) {
            if ($revMap.ContainsKey($ip)) { $e.ReverseDns  = $revMap[$ip] }
            if ($dnsMap.ContainsKey($ip)) { $e.DnsMatch    = $dnsMap[$ip] }
            $e.IsPrivateIP = Test-PrivateIP $ip
        }
        $out += $e
    }
    return $out
}
#endregion

#region --- Main Collection Loop ---
$runStart   = Get-Date
$analystOS  = (Get-WmiObject Win32_OperatingSystem).Caption

Write-Log 'INFO' "Starting collection. Targets: $($Targets.Count)"

foreach ($target in $Targets) {
    $tStart  = Get-Date
    $collErr = @()

    Write-Log 'INFO' "Collection start | target=$target"

    # For remote targets, prompt for credentials if none provided
    $isLocalTarget = ($target -eq 'localhost' -or $target -eq '127.0.0.1' -or $target -ieq $env:COMPUTERNAME)
    $effectiveCred = $Credential
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
    $caps     = $null
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

    # Collect artifacts
    Write-Log 'INFO' "Collecting processes"
    $pResult  = Get-ProcessData -Target $target -Cred $effectiveCred -Caps $caps
    $collErr += $pResult.errors
    Write-Log 'INFO' "Processes complete | count=$($pResult.data.Count)"

    Write-Log 'INFO' "Collecting network TCP"
    $nResult  = Get-NetworkData -Target $target -Cred $effectiveCred -Caps $caps
    $collErr += $nResult.errors
    Write-Log 'INFO' "Network complete | count=$($nResult.data.Count) | source=$($nResult.source)"

    Write-Log 'INFO' "Collecting DNS cache"
    $dResult  = Get-DnsData -Target $target -Cred $effectiveCred -Caps $caps
    $collErr += $dResult.errors
    Write-Log 'INFO' "DNS complete | count=$($dResult.data.Count) | source=$($dResult.source)"

    Write-Log 'INFO' "Enumerating network adapters"
    $aResult  = Get-AdapterData -Target $target -Cred $effectiveCred -Caps $caps
    $collErr += $aResult.errors
    Write-Log 'INFO' "Adapters complete | count=$($aResult.data.Count)"

    Write-Log 'INFO' "Resolving interface aliases"
    $resolvedNet = Resolve-InterfaceAlias -Connections $nResult.data -Adapters $aResult.data

    Write-Log 'INFO' "Performing DNS enrichment"
    $enrichedNet = Add-DnsEnrichment -Connections $resolvedNet -DnsCache $dResult.data

    # Determine hostname for file naming - always use hostname, never raw IP
    $outHost = Resolve-TargetHostname -Target $target

    # Print adapter summary
    if (-not $Quiet -and $aResult.data.Count -gt 0) {
        $nicCount = $aResult.data.Count
        Write-Host ""
        Write-Host "  Found $nicCount NIC$(if ($nicCount -ne 1) {'s'}) on ${outHost}:" -ForegroundColor Cyan
        for ($ni = 0; $ni -lt $aResult.data.Count; $ni++) {
            $adp     = $aResult.data[$ni]
            $firstIP = if (@($adp.IPAddresses).Count -gt 0) { @($adp.IPAddresses)[0] } else { 'no IP' }
            Write-Host "    NIC $($ni+1): $($adp.InterfaceAlias) - $firstIP" -ForegroundColor Cyan
        }
    }
    Write-Log 'INFO' "Output hostname: $outHost"
    $ts      = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
    $hostDir = Join-Path $OutputPath $outHost
    if (-not (Test-Path $hostDir)) { New-Item -ItemType Directory -Path $hostDir -Force | Out-Null }
    $outFile = Join-Path $hostDir "$outHost`_$ts.json"

    # Build manifest
    $manifest = [ordered]@{
        hostname                       = $outHost
        collection_time_utc            = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        collector_version              = $COLLECTOR_VERSION
        analyst_machine_hostname       = $env:COMPUTERNAME
        analyst_machine_os             = $analystOS
        analyst_ps_version             = $PSVersionTable.PSVersion.ToString()
        target_ps_version              = $caps.PSVersion.ToString()
        target_os_version              = $caps.OSVersion
        target_os_build                = $caps.OSBuild
        target_os_caption              = $caps.OSCaption
        target_is_server_core          = $caps.IsServerCore
        target_timezone_offset_minutes = $caps.TimezoneOffsetMinutes
        network_source                 = $nResult.source
        dns_source                     = $dResult.source
        network_adapters               = $aResult.data
        process_source_note            = $pResult.sourceNote
        sha256                         = $null
        collection_errors              = $collErr
    }

    $output = [ordered]@{
        manifest    = $manifest
        processes   = $pResult.data
        network_tcp = $enrichedNet
        dns_cache   = $dResult.data
    }

    # Write JSON - phase 1: sha256=null (compute hash of this)
    $json = $output | ConvertTo-Json -Depth 10 -Compress:$false
    # Compute SHA256 from the UTF8 string bytes (no BOM, no trailing newline ambiguity)
    $sha256bytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
        [System.Text.Encoding]::UTF8.GetBytes($json))
    $sha256 = ($sha256bytes | ForEach-Object { $_.ToString('X2') }) -join ''
    # Embed SHA256: ConvertTo-Json formats null as "key":  null (may vary); match with \s+
    $json2 = $json -replace '"sha256":\s+null', ('"sha256": "' + $sha256 + '"')
    # If the above didn't replace (edge case: "sha256": null with one space), try again
    if ($json2 -eq $json) { $json2 = $json -replace '"sha256":\s*null', ('"sha256": "' + $sha256 + '"') }
    [System.IO.File]::WriteAllText($outFile, $json2, [System.Text.Encoding]::UTF8)

    $elapsed = [int]((Get-Date) - $tStart).TotalSeconds
    Write-Log 'INFO' "Target complete | elapsed=${elapsed}s | processes=$($pResult.data.Count) | connections=$($enrichedNet.Count) | dns=$($dResult.data.Count) | errors=$($collErr.Count)"
    Write-Log 'INFO' "Output: $outFile | SHA256: $sha256"

    if (-not $Quiet) {
        Write-Host ""
        Write-Host "  Output  : $outFile"     -ForegroundColor Green
        Write-Host "  Processes   : $($pResult.data.Count)"   -ForegroundColor Cyan
        Write-Host "  Connections : $($enrichedNet.Count)"    -ForegroundColor Cyan
        Write-Host "  DNS entries : $($dResult.data.Count)"   -ForegroundColor Cyan
        if ($collErr.Count -gt 0) {
            Write-Host "  Errors      : $($collErr.Count)" -ForegroundColor Yellow
        }
        Write-Host "  SHA256 : $sha256" -ForegroundColor DarkGray
    }
}

$totalSec = [int]((Get-Date) - $runStart).TotalSeconds
Write-Log 'INFO' "All targets complete | elapsed=${totalSec}s"
#endregion

