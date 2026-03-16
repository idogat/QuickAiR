#Requires -Version 5.1
# ╔══════════════════════════════════════╗
# ║  Quicker — Processes.psm1           ║
# ║  Process list via CIM (PS3+) or WMI ║
# ║  (PS2). Includes .NET fallback.     ║
# ╠══════════════════════════════════════╣
# ║  Exports   : Invoke-Collector       ║
# ║  Inputs    : -Session               ║
# ║              -TargetPSVersion       ║
# ║              -TargetCapabilities    ║
# ║  Output    : @{ data=processes[];   ║
# ║               source=string;        ║
# ║               errors=[] }           ║
# ║  Depends   : Core\DateTime.psm1     ║
# ║  PS compat : 2.0+ (target-side)     ║
# ║  Version   : 2.0                    ║
# ╚══════════════════════════════════════╝

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# PS 2.0-compatible WMI process enumeration scriptblock
$script:PROC_SB_WMI = {
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

# CIM scriptblock for PS 3+ path
$script:PROC_SB_CIM = {
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

function Invoke-Collector {
    param(
        $Session,
        $TargetPSVersion,
        $TargetCapabilities
    )

    $errors       = @()
    $procs        = @()
    $fallbackNote = $null
    $sourceStr    = 'unknown'

    try {
        if ($Session -ne $null) {
            # Remote path
            $sb = if ($TargetPSVersion -ge 3) { $script:PROC_SB_CIM } else { $script:PROC_SB_WMI }
            $r   = Invoke-Command -Session $Session -ScriptBlock $sb
            $raw = $r.Procs
            if ($r.FallbackCount -gt 0) {
                $fallbackNote = "$($r.FallbackCount) process(es) added via .NET fallback on remote (absent from WMI/CIM)"
                Write-Log 'WARN' "Remote: $fallbackNote"
            }
            $baseSource = if ($TargetPSVersion -ge 3) { 'cim' } else { 'wmi' }
            $sourceStr  = if ($r.FallbackCount -gt 0) { "$baseSource+dotnet_fallback" } else { $baseSource }

            foreach ($p in $raw) {
                $utcVal = if ($p.CreationDateUtc)  { $p.CreationDateUtc }
                          elseif ($p.CreationDate) { ConvertTo-UtcIso -Value $p.CreationDate -FallbackOffsetMin $TargetCapabilities.TimezoneOffsetMinutes }
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
        } else {
            # Local path
            if ($TargetCapabilities.PSVersion -ge 3) {
                # CIM path - per-process try/catch to never silently drop
                $raw = Get-CimInstance Win32_Process -OperationTimeoutSec 60
                $sourceStr = 'cim'
                $fallbackCount = 0
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

                # .NET cross-check
                try {
                    $dnProcs       = [System.Diagnostics.Process]::GetProcesses()
                    $collectedPIDs = @{}
                    foreach ($x in $procs) { $collectedPIDs[[int]$x.ProcessId] = $true }
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
                        $sourceStr = 'cim+dotnet_fallback'
                    }
                } catch {
                    Write-Log 'WARN' ".NET cross-check failed: $($_.Exception.Message)"
                }

            } else {
                # WMI path
                $sourceStr = 'wmi'
                $fallbackCount = 0
                $searcher = New-Object System.Management.ManagementObjectSearcher("root\cimv2", "SELECT * FROM Win32_Process")
                $searcher.Options.ReturnImmediately = $false
                $searcher.Options.Rewindable = $false
                $raw2 = $searcher.Get()
                foreach ($p in $raw2) {
                    $pid_ = $null; $ppid = $null; $name_ = $null
                    try { $pid_  = [int]$p.ProcessId }       catch {}
                    try { $ppid  = [int]$p.ParentProcessId } catch {}
                    try { $name_ = $p.Name }                 catch {}
                    if ($pid_ -eq $null) { continue }
                    $utc = $null; $cd = $null; $cmdLine = $null; $exePath = $null; $ws = [long]0; $vs = [long]0; $sid = $null; $hc = $null
                    try { $cd      = $p.CreationDate; $utc = ConvertTo-UtcIso -Value $cd -FallbackOffsetMin $TargetCapabilities.TimezoneOffsetMinutes } catch {}
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

                # .NET cross-check
                try {
                    $dnProcs       = [System.Diagnostics.Process]::GetProcesses()
                    $collectedPIDs = @{}
                    foreach ($x in $procs) { $collectedPIDs[[int]$x.ProcessId] = $true }
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
                        $sourceStr = 'wmi+dotnet_fallback'
                    }
                } catch {
                    Write-Log 'WARN' ".NET cross-check failed: $($_.Exception.Message)"
                }
            }
        }
    } catch {
        $errors += @{ artifact = 'processes'; message = $_.Exception.Message }
        Write-Log 'ERROR' "Process collection failed: $($_.Exception.Message)"
    }

    return @{ data = $procs; source = $sourceStr; errors = $errors }
}

Export-ModuleMember -Function Invoke-Collector
