#Requires -Version 5.1
# DFIR Volatile Collector
# Version: 1.3
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
$COLLECTOR_VERSION = "1.3"
$MAX_RETRY         = 3
$RETRY_WAIT_SEC    = 5
$OP_TIMEOUT_SEC    = 30
#endregion

#region --- Admin Check ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Please restart Claude Code as Administrator (right-click -> Run as administrator) and re-run." -ForegroundColor Red
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

Write-Log 'INFO' "DFIR Volatile Collector v$COLLECTOR_VERSION starting"
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
            # Remote: use WinRM only (no DCOM/RPC) — all probing via PSSession
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
$PROC_SB_WMI = {
    $out = @()
    $procs = Get-WmiObject Win32_Process
    foreach ($p in $procs) {
        $out += New-Object PSObject -Property @{
            ProcessId       = [int]$p.ProcessId
            ParentProcessId = [int]$p.ParentProcessId
            Name            = $p.Name
            CommandLine     = $p.CommandLine
            ExecutablePath  = $p.ExecutablePath
            CreationDate    = $p.CreationDate
            WorkingSetSize  = [long]$p.WorkingSetSize
            VirtualSize     = [long]$p.VirtualSize
            SessionId       = [int]$p.SessionId
            HandleCount     = [int]$p.HandleCount
        }
    }
    $out
}

# CIM scriptblock for remote PS 3+ path
$PROC_SB_CIM = {
    $out = @()
    $procs = Get-CimInstance Win32_Process
    foreach ($p in $procs) {
        $out += New-Object PSObject -Property @{
            ProcessId       = [int]$p.ProcessId
            ParentProcessId = [int]$p.ParentProcessId
            Name            = $p.Name
            CommandLine     = $p.CommandLine
            ExecutablePath  = $p.ExecutablePath
            CreationDateUtc = if ($p.CreationDate) { $p.CreationDate.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $null }
            CreationDate    = if ($p.CreationDate) { $p.CreationDate.ToString('o') } else { $null }
            WorkingSetSize  = [long]$p.WorkingSetSize
            VirtualSize     = [long]$p.VirtualSize
            SessionId       = [int]$p.SessionId
            HandleCount     = [int]$p.HandleCount
        }
    }
    $out
}

function Get-ProcessData {
    param([string]$Target, [System.Management.Automation.PSCredential]$Cred, [hashtable]$Caps)

    $errors  = @()
    $procs   = @()
    $isLocal = ($Target -eq 'localhost' -or $Target -eq '127.0.0.1' -or $Target -ieq $env:COMPUTERNAME)

    try {
        if ($isLocal) {
            if ($Caps.PSVersion -ge 3) {
                $raw = Get-CimInstance Win32_Process -OperationTimeoutSec $OP_TIMEOUT_SEC
                foreach ($p in $raw) {
                    $procs += @{
                        ProcessId        = [int]$p.ProcessId
                        ParentProcessId  = [int]$p.ParentProcessId
                        Name             = $p.Name
                        CommandLine      = $p.CommandLine
                        ExecutablePath   = $p.ExecutablePath
                        CreationDateUTC  = if ($p.CreationDate) { $p.CreationDate.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $null }
                        CreationDateLocal= if ($p.CreationDate) { $p.CreationDate.ToString('o') } else { $null }
                        WorkingSetSize   = [long]$p.WorkingSetSize
                        VirtualSize      = [long]$p.VirtualSize
                        SessionId        = [int]$p.SessionId
                        HandleCount      = [int]$p.HandleCount
                    }
                }
            } else {
                $raw = Get-WmiObject Win32_Process
                foreach ($p in $raw) {
                    $utc = ConvertTo-UtcIso -Value $p.CreationDate -FallbackOffsetMin $Caps.TimezoneOffsetMinutes
                    $procs += @{
                        ProcessId        = [int]$p.ProcessId
                        ParentProcessId  = [int]$p.ParentProcessId
                        Name             = $p.Name
                        CommandLine      = $p.CommandLine
                        ExecutablePath   = $p.ExecutablePath
                        CreationDateUTC  = $utc
                        CreationDateLocal= $p.CreationDate
                        WorkingSetSize   = [long]$p.WorkingSetSize
                        VirtualSize      = [long]$p.VirtualSize
                        SessionId        = [int]$p.SessionId
                        HandleCount      = [int]$p.HandleCount
                    }
                }
            }
        } else {
            $so = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
            $spArgs = @{ ComputerName = $Target; SessionOption = $so; ErrorAction = 'Stop' }
            if ($Cred) { $spArgs.Credential = $Cred }
            $sess = New-PSSession @spArgs
            try {
                $sb  = if ($Caps.PSVersion -ge 3) { $PROC_SB_CIM } else { $PROC_SB_WMI }
                $raw = Invoke-Command -Session $sess -ScriptBlock $sb
                foreach ($p in $raw) {
                    $utcVal  = if ($p.CreationDateUtc)  { $p.CreationDateUtc }
                               elseif ($p.CreationDate) { ConvertTo-UtcIso -Value $p.CreationDate -FallbackOffsetMin $Caps.TimezoneOffsetMinutes }
                               else                     { $null }
                    $locVal  = if ($p.CreationDate) { $p.CreationDate } else { $null }
                    $procs += @{
                        ProcessId        = [int]$p.ProcessId
                        ParentProcessId  = [int]$p.ParentProcessId
                        Name             = $p.Name
                        CommandLine      = $p.CommandLine
                        ExecutablePath   = $p.ExecutablePath
                        CreationDateUTC  = $utcVal
                        CreationDateLocal= $locVal
                        WorkingSetSize   = [long]$p.WorkingSetSize
                        VirtualSize      = [long]$p.VirtualSize
                        SessionId        = [int]$p.SessionId
                        HandleCount      = [int]$p.HandleCount
                    }
                }
            } finally { Remove-PSSession $sess -ErrorAction SilentlyContinue }
        }
    } catch {
        $errors += @{ artifact = 'processes'; message = $_.Exception.Message }
        Write-Log 'ERROR' "Process collection failed: $($_.Exception.Message)"
    }

    return @{ data = $procs; errors = $errors }
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
        } catch { $revMap[$ip] = $null }
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

    Write-Log 'INFO' "Performing DNS enrichment"
    $enrichedNet = Add-DnsEnrichment -Connections $nResult.data -DnsCache $dResult.data

    # Determine hostname for file naming
    $outHost = if ($target -eq 'localhost' -or $target -eq '127.0.0.1') { $env:COMPUTERNAME } else { $target }
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
        sha256                         = $null
        collection_errors              = $collErr
    }

    $output = [ordered]@{
        manifest    = $manifest
        processes   = $pResult.data
        network_tcp = $enrichedNet
        dns_cache   = $dResult.data
    }

    # Write JSON — phase 1: sha256=null (compute hash of this)
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
