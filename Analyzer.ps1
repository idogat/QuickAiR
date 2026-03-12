#Requires -Version 5.1
<#
.SYNOPSIS
    DFIR Volatile Analyzer — disk/memory comparison and process-network correlation
.VERSION
    1.0.0
.CHANGES
    1.0.0 - Initial production release
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$InputPath,

    [string]$OutputPath = ".\DFIRAnalysis\",

    [PSCredential]$Credential  # optional - needed for disk/memory comparison
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Script:AnalyzerVersion = "1.0.0"

$Script:AnalystContext = @{
    analyzer_version        = $Script:AnalyzerVersion
    analysis_time_utc       = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    analyst_machine_os      = (Get-WmiObject Win32_OperatingSystem).Caption
    analyst_ps_version      = $PSVersionTable.PSVersion.Major
}

$Script:ProtectedProcessNames = @('lsass','csrss','smss','wininit','System','Idle')

$Script:FlagWeights = @{
    'GHOST_PROCESS'             = 25   # red
    'NO_IMAGE_PATH'             = 15   # orange
    'DISK_MEMORY_MISMATCH'      = 35   # red
    'MEMORY_NOT_PE'             = 35   # red
    'PRIVATE_EXECUTABLE_MEMORY' = 30   # red
    'PHANTOM_MODULE'            = 20   # orange
    'SUSPICIOUS_MODULE_PATH'    = 10   # amber
    'NAME_SPOOF'                = 25   # red
    'PARENT_SPOOF'              = 20   # orange
    'SUSPICIOUS_PATH'           = 10   # amber
}

# Known expected parent-child relationships (child -> expected parent names)
$Script:KnownParentRelationships = @{
    'svchost.exe'  = @('services.exe')
    'explorer.exe' = @('userinit.exe','winlogon.exe')
}

# Ports considered non-suspicious for outbound connections
$Script:CommonPorts = @(80, 443, 53, 135, 139, 445, 3389, 8080, 8443, 587, 465, 25, 22, 21, 110, 143, 993, 995, 123, 67, 68, 137, 138, 161, 389, 636, 3268, 3269, 88, 464, 1433, 1521, 5985, 5986)

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

$Script:AnalysisLogFile = $null

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR")]
        [string]$Level = "INFO"
    )
    $ts   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $line = "$ts $Level $Message"
    Write-Verbose $line
    if ($Script:AnalysisLogFile) {
        try { Add-Content -Path $Script:AnalysisLogFile -Value $line -Encoding UTF8 } catch {}
    }
}

# ---------------------------------------------------------------------------
# Utility: private IP detection
# ---------------------------------------------------------------------------

function Test-IsPrivateIP {
    param([string]$IP)
    if ([string]::IsNullOrEmpty($IP))                              { return $false }
    if ($IP -match '^127\.'  -or $IP -eq '::1')                   { return $true  }
    if ($IP -match '^10\.')                                        { return $true  }
    if ($IP -match '^172\.(1[6-9]|2[0-9]|3[01])\.')               { return $true  }
    if ($IP -match '^192\.168\.')                                  { return $true  }
    return $false
}

# ---------------------------------------------------------------------------
# Utility: suspicious connection determination
# ---------------------------------------------------------------------------

function Test-IsSuspiciousConnection {
    param(
        [string]$RemoteAddress,
        [int]$RemotePort,
        [string]$ProcessName,
        [bool]$ProcessHasFlags
    )
    if ($ProcessHasFlags)                                              { return $true }
    $remotePort = [int]$RemotePort
    if ($remotePort -gt 0 -and $Script:CommonPorts -notcontains $remotePort) { return $true }
    if (-not (Test-IsPrivateIP -IP $RemoteAddress)) {
        $systemProcs = @('system','idle','svchost.exe','lsass.exe','csrss.exe','smss.exe','wininit.exe','winlogon.exe','services.exe')
        if ($systemProcs -contains $ProcessName.ToLower()) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Utility: bytes to hex string
# ---------------------------------------------------------------------------

function ConvertTo-HexString {
    param([byte[]]$Bytes)
    if ($null -eq $Bytes) { return $null }
    return ([System.BitConverter]::ToString($Bytes) -replace '-','').ToLower()
}

# ---------------------------------------------------------------------------
# Utility: read uint32 little-endian from byte array
# ---------------------------------------------------------------------------

function Read-UInt32LE {
    param([byte[]]$Buf, [int]$Offset)
    if ($null -eq $Buf -or ($Offset + 4) -gt $Buf.Length) { return $null }
    return [uint32]($Buf[$Offset] -bor ($Buf[$Offset+1] -shl 8) -bor ($Buf[$Offset+2] -shl 16) -bor ($Buf[$Offset+3] -shl 24))
}

# ---------------------------------------------------------------------------
# Utility: find newest file matching a glob in a directory
# ---------------------------------------------------------------------------

function Get-NewestFile {
    param([string]$Dir, [string]$Pattern)
    $files = Get-ChildItem -Path $Dir -Filter $Pattern -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending
    if ($files) { return $files[0].FullName }
    return $null
}

# ---------------------------------------------------------------------------
# Module 1: Process-Network correlation
# ---------------------------------------------------------------------------

function Invoke-ProcessNetworkCorrelation {
    param(
        [object[]]$Processes,
        [object[]]$NetworkTcp
    )

    # Build PID -> process lookup
    $pidMap = @{}
    foreach ($p in $Processes) {
        $pid = [int]$p.ProcessId
        $pidMap[$pid] = $p
    }

    # Build parent -> children map
    $childMap = @{}
    foreach ($p in $Processes) {
        $ppid = [int]$p.ParentProcessId
        if (-not $childMap.ContainsKey($ppid)) { $childMap[$ppid] = [System.Collections.ArrayList]@() }
        [void]$childMap[$ppid].Add([int]$p.ProcessId)
    }

    # Build PID -> connections map
    $connMap = @{}
    foreach ($conn in $NetworkTcp) {
        $owner = [int]$conn.OwningProcess
        if (-not $connMap.ContainsKey($owner)) { $connMap[$owner] = [System.Collections.ArrayList]@() }
        [void]$connMap[$owner].Add($conn)
    }

    # Enrich each process
    $enriched = [System.Collections.ArrayList]@()
    foreach ($p in $Processes) {
        $pid  = [int]$p.ProcessId
        $ppid = [int]$p.ParentProcessId

        # Resolve parent name
        $parentName = $null
        if ($pidMap.ContainsKey($ppid)) { $parentName = $pidMap[$ppid].Name }

        # Build child list
        $children = [System.Collections.ArrayList]@()
        if ($childMap.ContainsKey($pid)) {
            foreach ($cid in $childMap[$pid]) {
                if ($pidMap.ContainsKey($cid)) { [void]$children.Add($pidMap[$cid].Name) }
            }
        }

        # Build network connections array
        $netConns = [System.Collections.ArrayList]@()
        if ($connMap.ContainsKey($pid)) {
            foreach ($conn in $connMap[$pid]) {
                $remoteAddr = [string]$conn.RemoteAddress
                $isPrivate  = Test-IsPrivateIP -IP $remoteAddr

                $connObj = [ordered]@{
                    LocalAddress   = [string]$conn.LocalAddress
                    LocalPort      = [int]$conn.LocalPort
                    RemoteAddress  = $remoteAddr
                    RemotePort     = [int]$conn.RemotePort
                    OwningProcess  = $pid
                    State          = [string]$conn.State
                    CreationTime   = if ($conn.CreationTime) { [string]$conn.CreationTime } else { $null }
                    DnsMatch       = if ($conn.DnsMatch)     { [string]$conn.DnsMatch     } else { $null }
                    ReverseDns     = if ($conn.ReverseDns)   { [string]$conn.ReverseDns   } else { $null }
                    IsPrivateIP    = $isPrivate
                    IsSuspicious   = $false   # updated after flags are computed
                    InterfaceAlias = if ($conn.InterfaceAlias) { [string]$conn.InterfaceAlias } else { $null }
                }
                [void]$netConns.Add($connObj)
            }
        }

        $procObj = [ordered]@{
            ProcessId        = $pid
            ParentProcessId  = $ppid
            Name             = [string]$p.Name
            CommandLine      = if ($p.CommandLine)    { [string]$p.CommandLine    } else { $null }
            ExecutablePath   = if ($p.ExecutablePath) { [string]$p.ExecutablePath } else { $null }
            WorkingSetSize   = if ($null -ne $p.WorkingSetSize) { [long]$p.WorkingSetSize } else { 0 }
            VirtualSize      = if ($null -ne $p.VirtualSize)    { [long]$p.VirtualSize    } else { 0 }
            SessionId        = if ($null -ne $p.SessionId)      { [int]$p.SessionId       } else { 0 }
            HandleCount      = if ($null -ne $p.HandleCount)    { [int]$p.HandleCount     } else { 0 }
            CreationDateUTC  = if ($p.CreationDateUTC)   { [string]$p.CreationDateUTC  } else { $null }
            CreationDateLocal= if ($p.CreationDateLocal) { [string]$p.CreationDateLocal} else { $null }
            ParentName       = $parentName
            ChildProcesses   = @($children)
            NetworkConnections = @($netConns)
            DiskMemoryAnalysis = $null   # populated in Module 2
            Flags            = [System.Collections.ArrayList]@()
            RiskScore        = 0
        }
        [void]$enriched.Add($procObj)
    }

    return $enriched
}

# ---------------------------------------------------------------------------
# Module 2: Disk vs Memory — C# type definitions
# ---------------------------------------------------------------------------

$Script:ModuleEnumSource = @"
using System;
using System.Diagnostics;
using System.Collections.Generic;
public class ModuleEnum {
    public static List<string> GetModules(int pid) {
        var result = new List<string>();
        try {
            var p = Process.GetProcessById(pid);
            foreach (ProcessModule m in p.Modules) {
                result.Add(m.FileName);
            }
        } catch {}
        return result;
    }
}
"@

$Script:PEInspectorSource = @"
using System;
using System.Runtime.InteropServices;
using System.IO;
using System.Diagnostics;
using System.Collections.Generic;

public class PEInspector {
    [DllImport("kernel32.dll")]
    public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);

    [DllImport("kernel32.dll")]
    public static extern bool ReadProcessMemory(IntPtr hProcess, IntPtr baseAddr, byte[] buffer, int size, out int read);

    [DllImport("kernel32.dll")]
    public static extern bool CloseHandle(IntPtr h);

    [DllImport("kernel32.dll")]
    public static extern IntPtr VirtualQueryEx(IntPtr hProcess, IntPtr addr, ref MEMORY_BASIC_INFORMATION mbi, uint size);

    [StructLayout(LayoutKind.Sequential)]
    public struct MEMORY_BASIC_INFORMATION {
        public IntPtr BaseAddress;
        public IntPtr AllocationBase;
        public uint   AllocationProtect;
        public IntPtr RegionSize;
        public uint   State;
        public uint   Protect;
        public uint   Type;
    }

    public static byte[] ReadMemoryHeader(int pid, IntPtr baseAddr) {
        IntPtr hProc = OpenProcess(0x0010 | 0x0400, false, pid);
        if (hProc == IntPtr.Zero) return null;
        byte[] buf  = new byte[512];
        int    read = 0;
        ReadProcessMemory(hProc, baseAddr, buf, buf.Length, out read);
        CloseHandle(hProc);
        return buf;
    }

    public static byte[] ReadDiskHeader(string path) {
        try {
            using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite)) {
                byte[] buf = new byte[512];
                fs.Read(buf, 0, buf.Length);
                return buf;
            }
        } catch { return null; }
    }

    public static IntPtr GetModuleBase(int pid) {
        try {
            var p = Process.GetProcessById(pid);
            return p.MainModule.BaseAddress;
        } catch { return IntPtr.Zero; }
    }

    public static List<MEMORY_BASIC_INFORMATION> EnumerateRegions(IntPtr hProcess) {
        var regions = new List<MEMORY_BASIC_INFORMATION>();
        IntPtr addr = IntPtr.Zero;
        while (true) {
            var    mbi    = new MEMORY_BASIC_INFORMATION();
            IntPtr result = VirtualQueryEx(hProcess, addr, ref mbi, (uint)Marshal.SizeOf(mbi));
            if (result == IntPtr.Zero) break;
            regions.Add(mbi);
            try { addr = new IntPtr(mbi.BaseAddress.ToInt64() + (long)mbi.RegionSize.ToInt64()); }
            catch { break; }
        }
        return regions;
    }
}
"@

# Tracks whether types have been compiled on remote target during this run
$Script:TypesCompiled = $false

# ---------------------------------------------------------------------------
# Remote type compilation helper (runs on the remote target via WinRM)
# ---------------------------------------------------------------------------

function Invoke-RemoteTypeCompilation {
    param(
        [System.Management.Automation.Runspaces.PSSession]$Session
    )
    $moduleEnumSrc  = $Script:ModuleEnumSource
    $peInspectorSrc = $Script:PEInspectorSource

    Invoke-Command -Session $Session -ScriptBlock {
        param($modSrc, $peSrc)
        if (-not ([System.Management.Automation.PSTypeName]'ModuleEnum').Type) {
            Add-Type -TypeDefinition $modSrc -Language CSharp -ErrorAction SilentlyContinue
        }
        if (-not ([System.Management.Automation.PSTypeName]'PEInspector').Type) {
            Add-Type -TypeDefinition $peSrc -Language CSharp -ErrorAction SilentlyContinue
        }
    } -ArgumentList $moduleEnumSrc, $peInspectorSrc -ErrorAction Stop
}

# ---------------------------------------------------------------------------
# Race condition check: verify PID still running (remote)
# ---------------------------------------------------------------------------

function Test-RemotePidRunning {
    param(
        [System.Management.Automation.Runspaces.PSSession]$Session,
        [int]$Pid,
        [bool]$IsLegacy
    )
    try {
        $result = Invoke-Command -Session $Session -ScriptBlock {
            param($p, $legacy)
            if ($legacy) {
                $check = Get-WmiObject Win32_Process -Filter "ProcessId=$p" -ErrorAction SilentlyContinue
            } else {
                $check = Get-Process -Id $p -ErrorAction SilentlyContinue
            }
            return ($null -ne $check)
        } -ArgumentList $Pid, $IsLegacy -ErrorAction SilentlyContinue
        return [bool]$result
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# Check A: executable backed by file on disk (remote)
# ---------------------------------------------------------------------------

function Invoke-CheckA {
    param(
        [System.Management.Automation.Runspaces.PSSession]$Session,
        [string]$ExecutablePath
    )
    # Returns: "EXISTS", "NOT_FOUND", "EMPTY_PATH"
    if ([string]::IsNullOrEmpty($ExecutablePath)) { return "EMPTY_PATH" }

    try {
        $exists = Invoke-Command -Session $Session -ScriptBlock {
            param($ep) Test-Path $ep -ErrorAction SilentlyContinue
        } -ArgumentList $ExecutablePath -ErrorAction Stop
        return if ($exists) { "EXISTS" } else { "NOT_FOUND" }
    } catch {
        return "UNKNOWN"
    }
}

# ---------------------------------------------------------------------------
# Check B: module list vs loaded image paths (remote)
# ---------------------------------------------------------------------------

function Invoke-CheckB {
    param(
        [System.Management.Automation.Runspaces.PSSession]$Session,
        [int]$Pid
    )
    # Returns hashtable: { Status, PhantomModules, SuspiciousModulePaths }
    $result = @{
        Status                = "OK"
        PhantomModules        = [System.Collections.ArrayList]@()
        SuspiciousModulePaths = [System.Collections.ArrayList]@()
    }

    try {
        $remoteResult = Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock {
            param($p)
            $out = @{ Modules = @(); Error = $null; IsAccessViolation = $false }
            try {
                $mods = [ModuleEnum]::GetModules($p)
                $out.Modules = @($mods)
            } catch [System.AccessViolationException] {
                $out.IsAccessViolation = $true
                $out.Error = 'AccessViolationException'
            } catch {
                $out.Error = $_.Exception.Message
            }
            return $out
        } -ArgumentList $Pid

        if ($remoteResult.IsAccessViolation) {
            $result.Status = "PARTIAL"
            return $result
        }
        if ($remoteResult.Error -and -not $remoteResult.Modules) {
            $result.Status = "ERROR"
            return $result
        }

        $suspiciousPathFragments = @('\Temp\','\AppData\','\ProgramData\','\Users\Public\')

        foreach ($modPath in $remoteResult.Modules) {
            if ([string]::IsNullOrEmpty($modPath)) { continue }

            # Check existence
            $exists = Invoke-Command -Session $Session -ScriptBlock {
                param($mp) Test-Path $mp -ErrorAction SilentlyContinue
            } -ArgumentList $modPath -ErrorAction SilentlyContinue

            if (-not $exists) {
                [void]$result.PhantomModules.Add($modPath)
            }

            # Check suspicious path
            foreach ($frag in $suspiciousPathFragments) {
                if ($modPath -like "*$frag*") {
                    [void]$result.SuspiciousModulePaths.Add($modPath)
                    break
                }
            }
        }
    } catch {
        $result.Status = "ERROR"
    }

    return $result
}

# ---------------------------------------------------------------------------
# Check C: PE header comparison disk vs memory (remote)
# ---------------------------------------------------------------------------

function Invoke-CheckC {
    param(
        [System.Management.Automation.Runspaces.PSSession]$Session,
        [int]$Pid,
        [string]$ExecutablePath,
        [bool]$Is2008R2
    )
    # Returns hashtable: { Status, Flags[], DiskHeaderHex, MemoryHeaderHex, MismatchFields[] }
    $result = @{
        Status          = "OK"
        Flags           = [System.Collections.ArrayList]@()
        DiskHeaderHex   = $null
        MemoryHeaderHex = $null
        MismatchFields  = [System.Collections.ArrayList]@()
    }

    try {
        $remoteResult = Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock {
            param($p, $execPath, $legacy2008)
            $out = @{
                DiskBytes   = $null
                MemBytes    = $null
                BaseAddr    = [int64]0
                OpenFailed  = $false
                Error       = $null
            }
            try {
                $base = [PEInspector]::GetModuleBase($p)
                if ($base -eq [IntPtr]::Zero) {
                    $out.Error = 'GetModuleBase returned zero'
                    return $out
                }
                $out.BaseAddr = $base.ToInt64()

                $memBytes = [PEInspector]::ReadMemoryHeader($p, $base)
                if ($null -eq $memBytes) {
                    if ($legacy2008) { $out.OpenFailed = $true }
                    else             { $out.Error = 'ReadMemoryHeader returned null' }
                    return $out
                }
                $out.MemBytes = $memBytes

                $diskBytes = [PEInspector]::ReadDiskHeader($execPath)
                $out.DiskBytes = $diskBytes
            } catch {
                $out.Error = $_.Exception.Message
            }
            return $out
        } -ArgumentList $Pid, $ExecutablePath, $Is2008R2

        if ($remoteResult.OpenFailed) {
            $result.Status = "SKIPPED_ACCESS_DENIED"
            return $result
        }
        if ($remoteResult.Error -or $null -eq $remoteResult.MemBytes) {
            $result.Status = "ERROR"
            return $result
        }

        $memBytes  = $remoteResult.MemBytes
        $diskBytes = $remoteResult.DiskBytes

        $result.MemoryHeaderHex = ConvertTo-HexString -Bytes $memBytes
        if ($diskBytes) { $result.DiskHeaderHex = ConvertTo-HexString -Bytes $diskBytes }

        # Byte 0-1: MZ magic check in memory
        if ($memBytes.Length -ge 2 -and -not ($memBytes[0] -eq 0x4D -and $memBytes[1] -eq 0x5A)) {
            [void]$result.Flags.Add('MEMORY_NOT_PE')
            [void]$result.MismatchFields.Add('MZ_MAGIC')
        }

        if ($diskBytes -and $diskBytes.Length -ge 2 -and $memBytes.Length -ge 2) {
            $hasMismatch = $false

            # e_lfanew at bytes 60-63
            if ($diskBytes.Length -ge 64 -and $memBytes.Length -ge 64) {
                $diskElfanew = Read-UInt32LE -Buf $diskBytes -Offset 60
                $memElfanew  = Read-UInt32LE -Buf $memBytes  -Offset 60
                if ($null -ne $diskElfanew -and $null -ne $memElfanew -and $diskElfanew -ne $memElfanew) {
                    [void]$result.MismatchFields.Add('e_lfanew')
                    $hasMismatch = $true
                }

                # PE signature at e_lfanew offset (if within first 512 bytes)
                if ($null -ne $diskElfanew -and $diskElfanew -le 508 -and $memElfanew -le 508) {
                    $diskPESig = Read-UInt32LE -Buf $diskBytes -Offset ([int]$diskElfanew)
                    $memPESig  = Read-UInt32LE -Buf $memBytes  -Offset ([int]$memElfanew)
                    if ($null -ne $diskPESig -and $null -ne $memPESig -and $diskPESig -ne $memPESig) {
                        [void]$result.MismatchFields.Add('PE_SIGNATURE')
                        [void]$result.Flags.Add('PE_SIGNATURE_MISMATCH')
                        $hasMismatch = $true
                    }

                    # SizeOfImage at e_lfanew + 0x18 + 0x38 = e_lfanew + 0x50 (optional header)
                    # Actually SizeOfImage is at PE optional header offset 0x38 from optional header start
                    # PE header layout: PE sig (4) + COFF (20) + OptionalHeader
                    # SizeOfImage in optional header is at offset 0x38 from optional header base
                    # optional header base = e_lfanew + 4 (PE sig) + 20 (COFF) = e_lfanew + 24
                    # SizeOfImage = e_lfanew + 24 + 56 = e_lfanew + 80 (0x50)
                    $sizeOfImageOffset = [int]$diskElfanew + 80
                    if ($sizeOfImageOffset -le 508) {
                        $diskSOI = Read-UInt32LE -Buf $diskBytes -Offset $sizeOfImageOffset
                        $memSOI  = Read-UInt32LE -Buf $memBytes  -Offset $sizeOfImageOffset
                        if ($null -ne $diskSOI -and $null -ne $memSOI -and $diskSOI -ne $memSOI) {
                            [void]$result.MismatchFields.Add('SizeOfImage')
                            [void]$result.Flags.Add('SIZE_OF_IMAGE_MISMATCH')
                            $hasMismatch = $true
                        }
                    }
                }
            }

            # e_lfanew mismatch flag (distinct from PE_HEADER_MISMATCH)
            $diskElfanewVal = Read-UInt32LE -Buf $diskBytes -Offset 60
            $memElfanewVal  = Read-UInt32LE -Buf $memBytes  -Offset 60
            if ($null -ne $diskElfanewVal -and $null -ne $memElfanewVal -and $diskElfanewVal -ne $memElfanewVal) {
                if ($result.Flags -notcontains 'PE_HEADER_MISMATCH') {
                    [void]$result.Flags.Add('PE_HEADER_MISMATCH')
                }
                $hasMismatch = $true
            }

            if ($hasMismatch) {
                [void]$result.Flags.Add('DISK_MEMORY_MISMATCH')
            }
        }

        $result.Status = "OK"
    } catch {
        $result.Status = "ERROR"
    }

    return $result
}

# ---------------------------------------------------------------------------
# Check D: memory region type anomalies (remote)
# ---------------------------------------------------------------------------

function Invoke-CheckD {
    param(
        [System.Management.Automation.Runspaces.PSSession]$Session,
        [int]$Pid,
        [bool]$Is2008R2
    )
    # Returns hashtable: { Status, PrivateExecRegions[] }
    $result = @{
        Status             = "OK"
        PrivateExecRegions = [System.Collections.ArrayList]@()
    }

    try {
        $remoteResult = Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock {
            param($p)
            $out = @{ Regions = @(); Failed = $false; Error = $null }
            try {
                $hProc = [PEInspector]::OpenProcess(0x0010 -bor 0x0400, $false, $p)
                if ($hProc -eq [IntPtr]::Zero) {
                    $out.Failed = $true
                    return $out
                }
                try {
                    $regions = [PEInspector]::EnumerateRegions($hProc)
                    $execProtects = @(0x10, 0x20, 0x40, 0x80)  # PAGE_EXECUTE*
                    $MEM_PRIVATE = 0x20000
                    $MEM_COMMIT  = 0x1000
                    $found = @()
                    foreach ($r in $regions) {
                        if ($r.Type    -eq $MEM_PRIVATE -and
                            $r.State   -eq $MEM_COMMIT  -and
                            $execProtects -contains $r.Protect) {
                            $found += @{
                                BaseAddress = $r.BaseAddress.ToInt64()
                                RegionSize  = $r.RegionSize.ToInt64()
                                Protect     = $r.Protect
                            }
                        }
                    }
                    $out.Regions = $found
                } finally {
                    [PEInspector]::CloseHandle($hProc) | Out-Null
                }
            } catch {
                $out.Failed = $true
                $out.Error  = $_.Exception.Message
            }
            return $out
        } -ArgumentList $Pid

        if ($remoteResult.Failed) {
            if ($Is2008R2) {
                $result.Status = "SKIPPED_VQUERY_UNAVAILABLE"
            } else {
                $result.Status = "ERROR"
            }
            return $result
        }

        foreach ($r in $remoteResult.Regions) {
            [void]$result.PrivateExecRegions.Add([ordered]@{
                BaseAddress = "0x{0:x16}" -f [int64]$r.BaseAddress
                RegionSize  = [int64]$r.RegionSize
                Protect     = "0x{0:x2}" -f [int]$r.Protect
            })
        }

        $result.Status = "OK"
    } catch {
        $result.Status = "ERROR"
    }

    return $result
}

# ---------------------------------------------------------------------------
# Module 2 orchestrator: disk vs memory analysis for a single process
# ---------------------------------------------------------------------------

function Invoke-DiskMemoryAnalysis {
    param(
        [System.Management.Automation.Runspaces.PSSession]$Session,
        [object]$Process,
        [bool]$Is2008R2,
        [bool]$Is2012R2,
        [bool]$IsLegacy
    )

    $dma = [ordered]@{
        GhostProcess           = $false
        NoImagePath            = $false
        DiskMemoryMismatch     = $false
        MismatchFields         = @()
        PhantomModules         = @()
        SuspiciousModulePaths  = @()
        PrivateExecutableMemory= $false
        PrivateExecRegions     = @()
        MemoryHeaderHex        = $null
        DiskHeaderHex          = $null
        AnalysisStatus         = "COMPLETE"
    }

    $procName = [string]$Process.Name
    $pid      = [int]$Process.ProcessId
    $execPath = if ($Process.ExecutablePath) { [string]$Process.ExecutablePath } else { $null }

    # --- Protected process guard ---
    foreach ($prot in $Script:ProtectedProcessNames) {
        if ($procName -ieq $prot) {
            $dma.AnalysisStatus = "SKIPPED_PROTECTED"
            return $dma
        }
    }

    # --- Skip Session 0 SYSTEM processes with no ExecutablePath ---
    $sessionId = if ($null -ne $Process.SessionId) { [int]$Process.SessionId } else { -1 }
    if ($sessionId -eq 0 -and [string]::IsNullOrEmpty($execPath)) {
        $dma.AnalysisStatus = "SKIPPED_KERNEL_COMPONENT"
        return $dma
    }

    # --- Race condition check ---
    $stillRunning = Test-RemotePidRunning -Session $Session -Pid $pid -IsLegacy $IsLegacy
    if (-not $stillRunning) {
        Write-Log -Message "Process $procName (PID $pid) exited during analysis" -Level INFO
        $dma.AnalysisStatus = "PROCESS_EXITED_DURING_ANALYSIS"
        return $dma
    }

    # --- Check A: executable on disk ---
    $checkAResult = Invoke-CheckA -Session $Session -ExecutablePath $execPath
    switch ($checkAResult) {
        "EMPTY_PATH" { $dma.NoImagePath = $true  }
        "NOT_FOUND"  { $dma.GhostProcess = $true }
        default      {}
    }

    # If no valid exec path, skip memory checks
    if ($dma.NoImagePath -or $dma.GhostProcess) {
        return $dma
    }

    # --- Check B: module list ---
    $checkBResult = Invoke-CheckB -Session $Session -Pid $pid
    if ($checkBResult.Status -eq "PARTIAL") {
        $dma.AnalysisStatus = "PARTIAL"
        # Continue with remaining checks
    }
    if ($checkBResult.PhantomModules.Count -gt 0) {
        $dma.PhantomModules = @($checkBResult.PhantomModules)
    }
    if ($checkBResult.SuspiciousModulePaths.Count -gt 0) {
        $dma.SuspiciousModulePaths = @($checkBResult.SuspiciousModulePaths)
    }

    # --- Check C: PE header comparison ---
    $checkCResult = Invoke-CheckC -Session $Session -Pid $pid -ExecutablePath $execPath -Is2008R2 $Is2008R2
    if ($checkCResult.Status -eq "SKIPPED_ACCESS_DENIED") {
        Write-Log -Message "OpenProcess access denied for $procName (PID $pid) — skipping PE header check" -Level INFO
        if ($dma.AnalysisStatus -eq "COMPLETE") { $dma.AnalysisStatus = "SKIPPED_ACCESS_DENIED" }
    } elseif ($checkCResult.Status -eq "OK" -or $checkCResult.Status -eq "") {
        $dma.MemoryHeaderHex = $checkCResult.MemoryHeaderHex
        $dma.DiskHeaderHex   = $checkCResult.DiskHeaderHex
        $dma.MismatchFields  = @($checkCResult.MismatchFields)
        if ($checkCResult.Flags -contains 'DISK_MEMORY_MISMATCH') { $dma.DiskMemoryMismatch = $true }
    }

    # --- Check D: private executable memory regions ---
    $checkDResult = Invoke-CheckD -Session $Session -Pid $pid -Is2008R2 $Is2008R2
    if ($checkDResult.Status -eq "SKIPPED_VQUERY_UNAVAILABLE") {
        Write-Log -Message "VirtualQueryEx unavailable on this OS for $procName (PID $pid)" -Level INFO
    } elseif ($checkDResult.Status -eq "OK") {
        if ($checkDResult.PrivateExecRegions.Count -gt 0) {
            $dma.PrivateExecutableMemory = $true
            $dma.PrivateExecRegions = @($checkDResult.PrivateExecRegions)
        }
    }

    # Consolidate partial status
    if ($dma.AnalysisStatus -eq "COMPLETE" -and $checkBResult.Status -eq "PARTIAL") {
        $dma.AnalysisStatus = "PARTIAL"
    }

    return $dma, $checkCResult.Flags
}

# ---------------------------------------------------------------------------
# Flag assignment and risk scoring
# ---------------------------------------------------------------------------

function Set-ProcessFlags {
    param(
        [object]$Process,
        [object]$DMA,
        [string[]]$CheckCFlags
    )

    $flags = [System.Collections.ArrayList]@()

    # From DMA results
    if ($DMA.NoImagePath)            { [void]$flags.Add('NO_IMAGE_PATH')      }
    if ($DMA.GhostProcess)           { [void]$flags.Add('GHOST_PROCESS')      }
    if ($DMA.DiskMemoryMismatch)     { [void]$flags.Add('DISK_MEMORY_MISMATCH') }
    if ($DMA.PrivateExecutableMemory){ [void]$flags.Add('PRIVATE_EXECUTABLE_MEMORY') }
    if ($DMA.PhantomModules.Count -gt 0)        { [void]$flags.Add('PHANTOM_MODULE')         }
    if ($DMA.SuspiciousModulePaths.Count -gt 0) { [void]$flags.Add('SUSPICIOUS_MODULE_PATH') }

    # Check C sub-flags
    if ($CheckCFlags) {
        foreach ($f in $CheckCFlags) {
            if ($f -and $flags -notcontains $f) { [void]$flags.Add($f) }
        }
    }

    # NAME_SPOOF: process Name vs filename of ExecutablePath
    $execPath = [string]$Process.ExecutablePath
    $procName = [string]$Process.Name
    if (-not [string]::IsNullOrEmpty($execPath)) {
        $diskFilename = [System.IO.Path]::GetFileName($execPath)
        if ($diskFilename -and $procName -and
            $diskFilename.ToLower() -ne $procName.ToLower()) {
            [void]$flags.Add('NAME_SPOOF')
        }
    }

    # PARENT_SPOOF
    $procNameLower = $procName.ToLower()
    if ($Script:KnownParentRelationships.ContainsKey($procNameLower)) {
        $expectedParents = $Script:KnownParentRelationships[$procNameLower]
        $actualParent    = [string]$Process.ParentName
        if (-not [string]::IsNullOrEmpty($actualParent)) {
            $match = $false
            foreach ($ep in $expectedParents) {
                if ($actualParent.ToLower() -eq $ep.ToLower()) { $match = $true; break }
            }
            if (-not $match) { [void]$flags.Add('PARENT_SPOOF') }
        }
    }

    # SUSPICIOUS_PATH
    if (-not [string]::IsNullOrEmpty($execPath)) {
        $suspFragments = @('\Temp\','\AppData\','\Users\Public\','\ProgramData\')
        foreach ($frag in $suspFragments) {
            if ($execPath -like "*$frag*") {
                [void]$flags.Add('SUSPICIOUS_PATH')
                break
            }
        }
    }

    return @($flags)
}

function Compute-RiskScore {
    param(
        [string[]]$Flags,
        [bool]$HasNetworkConnections
    )
    $score = 0
    foreach ($f in $Flags) {
        if ($Script:FlagWeights.ContainsKey($f)) {
            $score += $Script:FlagWeights[$f]
        }
    }
    if ($HasNetworkConnections -and $Flags.Count -gt 0) { $score += 25 }
    if ($score -gt 100) { $score = 100 }
    return $score
}

# ---------------------------------------------------------------------------
# Network enrichment pass: update IsSuspicious after flags are known
# ---------------------------------------------------------------------------

function Update-NetworkSuspicious {
    param([object[]]$Processes)
    foreach ($proc in $Processes) {
        $hasFlags = ($proc.Flags.Count -gt 0)
        foreach ($conn in $proc.NetworkConnections) {
            $conn.IsSuspicious = Test-IsSuspiciousConnection `
                -RemoteAddress $conn.RemoteAddress `
                -RemotePort    $conn.RemotePort    `
                -ProcessName   $proc.Name          `
                -ProcessHasFlags $hasFlags
        }
    }
}

# ---------------------------------------------------------------------------
# Build enriched network array (host-level)
# ---------------------------------------------------------------------------

function Build-NetworkArray {
    param(
        [object[]]$NetworkTcp,
        [object[]]$Processes
    )

    # Build PID -> process lookup
    $pidMap = @{}
    foreach ($p in $Processes) { $pidMap[[int]$p.ProcessId] = $p }

    $result = [System.Collections.ArrayList]@()
    foreach ($conn in $NetworkTcp) {
        $owner       = [int]$conn.OwningProcess
        $procName    = $null
        $procPath    = $null
        $procFlags   = @()
        if ($pidMap.ContainsKey($owner)) {
            $procName  = $pidMap[$owner].Name
            $procPath  = $pidMap[$owner].ExecutablePath
            $procFlags = @($pidMap[$owner].Flags)
        }
        $remoteAddr = [string]$conn.RemoteAddress
        $isPrivate  = Test-IsPrivateIP -IP $remoteAddr
        $isSusp     = Test-IsSuspiciousConnection `
            -RemoteAddress $remoteAddr `
            -RemotePort    ([int]$conn.RemotePort) `
            -ProcessName   ($procName ?? '') `
            -ProcessHasFlags ($procFlags.Count -gt 0)

        $obj = [ordered]@{
            LocalAddress   = [string]$conn.LocalAddress
            LocalPort      = [int]$conn.LocalPort
            RemoteAddress  = $remoteAddr
            RemotePort     = [int]$conn.RemotePort
            State          = [string]$conn.State
            OwningProcess  = $owner
            ProcessName    = $procName
            ProcessPath    = $procPath
            ProcessFlags   = $procFlags
            DnsMatch       = if ($conn.DnsMatch)     { [string]$conn.DnsMatch     } else { $null }
            ReverseDns     = if ($conn.ReverseDns)   { [string]$conn.ReverseDns   } else { $null }
            IsPrivateIP    = $isPrivate
            IsSuspicious   = $isSusp
            InterfaceAlias = if ($conn.InterfaceAlias) { [string]$conn.InterfaceAlias } else { $null }
        }
        [void]$result.Add($obj)
    }
    return @($result)
}

# ---------------------------------------------------------------------------
# Build summary
# ---------------------------------------------------------------------------

function Build-Summary {
    param(
        [object[]]$Processes,
        [object[]]$NetworkArray
    )

    $summary = [ordered]@{
        total_processes                 = $Processes.Count
        flagged_processes               = 0
        ghost_processes                 = 0
        suspicious_paths                = 0
        name_spoofs                     = 0
        parent_spoofs                   = 0
        disk_memory_mismatches          = 0
        private_exec_memory             = 0
        total_connections               = $NetworkArray.Count
        suspicious_connections          = 0
        unique_remote_ips               = 0
        unique_remote_hosts             = 0
        skipped_protected               = 0
        skipped_access_denied           = 0
        process_exited_during_analysis  = 0
        high_risk_processes             = [System.Collections.ArrayList]@()
    }

    $remoteIPs    = [System.Collections.Generic.HashSet[string]]@()
    $remoteHosts  = [System.Collections.Generic.HashSet[string]]@()

    foreach ($proc in $Processes) {
        $dma    = $proc.DiskMemoryAnalysis
        $flags  = @($proc.Flags)
        $status = if ($dma) { [string]$dma.AnalysisStatus } else { "COMPLETE" }

        if ($flags.Count -gt 0) { $summary.flagged_processes++ }
        if ($flags -contains 'GHOST_PROCESS')              { $summary.ghost_processes++           }
        if ($flags -contains 'SUSPICIOUS_PATH')            { $summary.suspicious_paths++           }
        if ($flags -contains 'NAME_SPOOF')                 { $summary.name_spoofs++                }
        if ($flags -contains 'PARENT_SPOOF')               { $summary.parent_spoofs++              }
        if ($flags -contains 'DISK_MEMORY_MISMATCH')       { $summary.disk_memory_mismatches++     }
        if ($flags -contains 'PRIVATE_EXECUTABLE_MEMORY')  { $summary.private_exec_memory++        }

        switch ($status) {
            "SKIPPED_PROTECTED"              { $summary.skipped_protected++ }
            "SKIPPED_ACCESS_DENIED"          { $summary.skipped_access_denied++ }
            "PROCESS_EXITED_DURING_ANALYSIS" { $summary.process_exited_during_analysis++ }
        }

        if ($proc.RiskScore -ge 50) {
            [void]$summary.high_risk_processes.Add([ordered]@{
                ProcessId  = $proc.ProcessId
                Name       = $proc.Name
                RiskScore  = $proc.RiskScore
                Flags      = $flags
            })
        }
    }

    foreach ($conn in $NetworkArray) {
        if ($conn.IsSuspicious) { $summary.suspicious_connections++ }
        $ra = [string]$conn.RemoteAddress
        if (-not [string]::IsNullOrEmpty($ra) -and $ra -ne '0.0.0.0' -and $ra -ne '::') {
            [void]$remoteIPs.Add($ra)
        }
        $rd = [string]$conn.ReverseDns
        if (-not [string]::IsNullOrEmpty($rd)) { [void]$remoteHosts.Add($rd) }
        $dm = [string]$conn.DnsMatch
        if (-not [string]::IsNullOrEmpty($dm)) { [void]$remoteHosts.Add($dm) }
    }

    $summary.unique_remote_ips   = $remoteIPs.Count
    $summary.unique_remote_hosts = $remoteHosts.Count
    $summary.high_risk_processes = @($summary.high_risk_processes)

    return $summary
}

# ---------------------------------------------------------------------------
# Per-host analysis orchestrator
# ---------------------------------------------------------------------------

function Invoke-HostAnalysis {
    param(
        [string]$HostDir,
        [string]$Hostname
    )

    Write-Log -Message "Starting analysis for host: $Hostname" -Level INFO

    # --- Locate input files ---
    $manifestFile = Get-NewestFile -Dir $HostDir -Pattern "*_manifest.json"
    $pslistFile   = Get-NewestFile -Dir $HostDir -Pattern "*_pslist_*.json"
    $tcpFile      = Get-NewestFile -Dir $HostDir -Pattern "*_network_tcp_*.json"
    $dnsFile      = Get-NewestFile -Dir $HostDir -Pattern "*_network_dns_*.json"

    if (-not $manifestFile) {
        Write-Log -Message "No manifest file found in $HostDir — skipping host" -Level WARN
        return $null
    }

    # --- Load JSON data ---
    $manifest = $null
    try {
        $manifest = Get-Content -Path $manifestFile -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Log -Message "Failed to parse manifest for $Hostname`: $($_.Exception.Message)" -Level ERROR
        return $null
    }

    $processes  = @()
    $networkTcp = @()
    $dnsCache   = @()

    if ($pslistFile) {
        try { $processes  = @(Get-Content -Path $pslistFile -Raw -Encoding UTF8 | ConvertFrom-Json) }
        catch { Write-Log -Message "Failed to parse pslist for $Hostname`: $($_.Exception.Message)" -Level WARN }
    }
    if ($tcpFile) {
        try { $networkTcp = @(Get-Content -Path $tcpFile   -Raw -Encoding UTF8 | ConvertFrom-Json) }
        catch { Write-Log -Message "Failed to parse network_tcp for $Hostname`: $($_.Exception.Message)" -Level WARN }
    }
    if ($dnsFile) {
        try { $dnsCache   = @(Get-Content -Path $dnsFile   -Raw -Encoding UTF8 | ConvertFrom-Json) }
        catch { Write-Log -Message "Failed to parse network_dns for $Hostname`: $($_.Exception.Message)" -Level WARN }
    }

    # Validate dates in pslist (warn on normalization issues)
    foreach ($p in $processes) {
        if ($p.CreationDateUTC) {
            try {
                [System.DateTime]::Parse([string]$p.CreationDateUTC) | Out-Null
            } catch {
                Write-Log -Message "CreationDateUTC normalization warning for process $($p.Name): $($p.CreationDateUTC)" -Level WARN
            }
        }
    }

    # --- OS detection ---
    $osVersion  = if ($manifest.os_version)  { [string]$manifest.os_version  } else { "" }
    $is2008R2   = $osVersion -match "^6\.1\."
    $is2012R2   = $osVersion -match "^6\.3\."
    $isLegacy   = if ($manifest.capability_flags) { [bool]$manifest.capability_flags.IsLegacy } else { $false }

    # --- Module 1: Process-Network correlation ---
    $enrichedProcesses = Invoke-ProcessNetworkCorrelation -Processes $processes -NetworkTcp $networkTcp

    # --- Module 2: Disk vs Memory ---
    $session = $null
    $hasCred = ($null -ne $Credential)

    if ($hasCred) {
        # Attempt WinRM session to target
        try {
            $sessionParams = @{
                ComputerName = $Hostname
                Credential   = $Credential
                ErrorAction  = 'Stop'
            }
            $session = New-PSSession @sessionParams

            # Compile C# types on remote target
            try {
                Invoke-RemoteTypeCompilation -Session $session
                Write-Log -Message "Remote type compilation successful on $Hostname" -Level INFO
            } catch {
                Write-Log -Message "Remote type compilation failed on $Hostname`: $($_.Exception.Message) — disk/memory checks unavailable" -Level WARN
                Remove-PSSession $session -ErrorAction SilentlyContinue
                $session = $null
            }
        } catch {
            Write-Log -Message "WinRM session to $Hostname failed: $($_.Exception.Message) — skipping disk/memory analysis" -Level WARN
            $session = $null
        }
    }

    foreach ($proc in $enrichedProcesses) {
        $pid      = [int]$proc.ProcessId
        $procName = [string]$proc.Name

        if ($null -eq $session) {
            # No credential or session — skip memory analysis
            $proc.DiskMemoryAnalysis = [ordered]@{
                GhostProcess            = $false
                NoImagePath             = $false
                DiskMemoryMismatch      = $false
                MismatchFields          = @()
                PhantomModules          = @()
                SuspiciousModulePaths   = @()
                PrivateExecutableMemory = $false
                PrivateExecRegions      = @()
                MemoryHeaderHex         = $null
                DiskHeaderHex           = $null
                AnalysisStatus          = "ANALYSIS_SKIPPED_NO_ACCESS"
            }
            $proc.Flags     = [System.Collections.ArrayList]@()
            $proc.RiskScore = 0
            continue
        }

        # Run full disk/memory analysis
        $dmaResult   = $null
        $checkCFlags = @()
        try {
            $dmaOut = Invoke-DiskMemoryAnalysis `
                -Session    $session   `
                -Process    $proc      `
                -Is2008R2   $is2008R2  `
                -Is2012R2   $is2012R2  `
                -IsLegacy   $isLegacy

            # Invoke-DiskMemoryAnalysis returns either 1 or 2 values
            if ($dmaOut -is [array] -and $dmaOut.Count -ge 2) {
                $dmaResult   = $dmaOut[0]
                $checkCFlags = @($dmaOut[1])
            } else {
                $dmaResult = $dmaOut
            }
        } catch {
            Write-Log -Message "DiskMemoryAnalysis exception for $procName (PID $pid): $($_.Exception.Message)" -Level WARN
            $dmaResult = [ordered]@{
                GhostProcess            = $false
                NoImagePath             = $false
                DiskMemoryMismatch      = $false
                MismatchFields          = @()
                PhantomModules          = @()
                SuspiciousModulePaths   = @()
                PrivateExecutableMemory = $false
                PrivateExecRegions      = @()
                MemoryHeaderHex         = $null
                DiskHeaderHex           = $null
                AnalysisStatus          = "PARTIAL"
            }
        }

        $proc.DiskMemoryAnalysis = $dmaResult

        # Assign flags
        $flags = Set-ProcessFlags -Process $proc -DMA $dmaResult -CheckCFlags $checkCFlags
        $proc.Flags = [System.Collections.ArrayList]@($flags)

        # Log each flag raised
        foreach ($f in $flags) {
            Write-Log -Message "FLAG $f raised for process $procName (PID $pid)" -Level INFO
        }

        # Compute risk score
        $hasConns       = ($proc.NetworkConnections.Count -gt 0)
        $proc.RiskScore = Compute-RiskScore -Flags $flags -HasNetworkConnections $hasConns
    }

    # Close WinRM session
    if ($session) {
        try { Remove-PSSession $session -ErrorAction SilentlyContinue } catch {}
    }

    # Update IsSuspicious on per-process connections now that flags are set
    Update-NetworkSuspicious -Processes $enrichedProcesses

    # Build host-level network array
    $networkArray = Build-NetworkArray -NetworkTcp $networkTcp -Processes $enrichedProcesses

    # Build summary
    $summary = Build-Summary -Processes $enrichedProcesses -NetworkArray $networkArray

    # Convert process flags/children from ArrayList to plain arrays for JSON serialization
    foreach ($proc in $enrichedProcesses) {
        $proc.Flags          = @($proc.Flags)
        $proc.ChildProcesses = @($proc.ChildProcesses)
        # Ensure NetworkConnections is a plain array
        $proc.NetworkConnections = @($proc.NetworkConnections)
        # DMA sub-arrays
        if ($proc.DiskMemoryAnalysis) {
            $proc.DiskMemoryAnalysis.MismatchFields        = @($proc.DiskMemoryAnalysis.MismatchFields)
            $proc.DiskMemoryAnalysis.PhantomModules        = @($proc.DiskMemoryAnalysis.PhantomModules)
            $proc.DiskMemoryAnalysis.SuspiciousModulePaths = @($proc.DiskMemoryAnalysis.SuspiciousModulePaths)
            $proc.DiskMemoryAnalysis.PrivateExecRegions    = @($proc.DiskMemoryAnalysis.PrivateExecRegions)
        }
    }

    # Assemble final output document
    $output = [ordered]@{
        hostname                   = $Hostname
        analysis_time_utc          = $Script:AnalystContext.analysis_time_utc
        analyzer_version           = $Script:AnalyzerVersion
        original_collector_version = if ($manifest.collector_version) { [string]$manifest.collector_version } else { $null }
        analyst_machine_os         = $Script:AnalystContext.analyst_machine_os
        analyst_ps_version         = $Script:AnalystContext.analyst_ps_version
        os_version                 = if ($manifest.os_version)  { [string]$manifest.os_version  } else { $null }
        os_build                   = if ($manifest.os_build)    { [string]$manifest.os_build    } else { $null }
        ps_version                 = if ($manifest.ps_version)  { $manifest.ps_version          } else { $null }
        timezone_offset_minutes    = if ($null -ne $manifest.timezone_offset_minutes) { [int]$manifest.timezone_offset_minutes } else { 0 }
        processes                  = @($enrichedProcesses)
        network                    = $networkArray
        dns_cache                  = @($dnsCache)
        summary                    = $summary
    }

    Write-Log -Message "Analysis complete for host $Hostname — flagged=$($summary.flagged_processes) high_risk=$($summary.high_risk_processes.Count)" -Level INFO

    return $output
}

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

# Resolve paths
$InputPath  = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InputPath)
$OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)

# Create output directory
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

# Initialize analysis log
$Script:AnalysisLogFile = Join-Path $OutputPath "analysis.log"

Write-Log -Message "DFIR Analyzer v$($Script:AnalyzerVersion) starting. InputPath=$InputPath OutputPath=$OutputPath" -Level INFO
Write-Log -Message "Analyst OS: $($Script:AnalystContext.analyst_machine_os) PS: $($Script:AnalystContext.analyst_ps_version)" -Level INFO

# Discover host directories
$hostDirs = @()
try {
    $hostDirs = @(Get-ChildItem -Path $InputPath -Directory -ErrorAction Stop)
} catch {
    Write-Log -Message "Failed to enumerate InputPath $InputPath`: $($_.Exception.Message)" -Level ERROR
    exit 1
}

if ($hostDirs.Count -eq 0) {
    Write-Log -Message "No host subdirectories found in $InputPath" -Level WARN
    exit 0
}

Write-Log -Message "Found $($hostDirs.Count) host(s) to analyze" -Level INFO

$successCount = 0
$failCount    = 0

foreach ($hostDir in $hostDirs) {
    $hostname   = $hostDir.Name
    $hostDirFull= $hostDir.FullName
    $outputFile = Join-Path $OutputPath "${hostname}_analysis.json"

    try {
        $result = Invoke-HostAnalysis -HostDir $hostDirFull -Hostname $hostname
        if ($result) {
            $json = $result | ConvertTo-Json -Depth 20
            $json | Out-File -FilePath $outputFile -Encoding UTF8 -Force
            Write-Log -Message "Analysis written to $outputFile" -Level INFO
            $successCount++
        } else {
            Write-Log -Message "No analysis result for host $hostname" -Level WARN
            $failCount++
        }
    } catch {
        Write-Log -Message "Unhandled exception analyzing host $hostname`: $($_.Exception.Message)" -Level ERROR
        $failCount++
    }
}

Write-Log -Message "DFIR Analyzer v$($Script:AnalyzerVersion) complete. Success=$successCount Failed=$failCount OutputPath=$OutputPath" -Level INFO
