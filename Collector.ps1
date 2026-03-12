#Requires -Version 5.1
<#
.SYNOPSIS
    DFIR Volatile Collector — remote pslist + network collection
.VERSION
    1.0.0
.CHANGES
    1.0.0 - Initial production release
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string[]]$Targets,

    [Parameter(Mandatory=$true)]
    [ValidateSet("WinRM","SMB")]
    [string]$Protocol,

    [Parameter(Mandatory=$true)]
    [PSCredential]$Credential,

    [string]$OutputPath = ".\DFIROutput\",

    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Script:CollectorVersion = "1.0.0"

$Script:AnalystContext = @{
    analyst_machine_hostname = $env:COMPUTERNAME
    analyst_machine_os       = (Get-WmiObject Win32_OperatingSystem).Caption
    analyst_ps_version       = $PSVersionTable.PSVersion.Major
    collector_version        = $Script:CollectorVersion
}

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

function Initialize-TargetLogs {
    param([string]$TargetOutputDir)
    if (-not (Test-Path $TargetOutputDir)) {
        New-Item -ItemType Directory -Path $TargetOutputDir -Force | Out-Null
    }
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR")]
        [string]$Level = "INFO",
        [string]$LogFile
    )
    $ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $line = "$ts $Level $Message"
    if (-not $Quiet) { Write-Host $line }
    if ($LogFile) {
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    }
}

function Write-ErrorLog {
    param(
        [string]$Message,
        [string]$ErrorLogFile,
        [string]$CollectionLogFile
    )
    $ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $line = "$ts ERROR $Message"
    if (-not $Quiet) { Write-Warning $line }
    if ($ErrorLogFile) {
        Add-Content -Path $ErrorLogFile -Value $line -Encoding UTF8
    }
    if ($CollectionLogFile) {
        Add-Content -Path $CollectionLogFile -Value $line -Encoding UTF8
    }
}

# ---------------------------------------------------------------------------
# DateTime normalization
# ---------------------------------------------------------------------------

function Convert-WmiDateToUtc {
    param(
        [string]$WmiDate,
        [int]$TzOffsetMinutes = 0
    )
    if ([string]::IsNullOrEmpty($WmiDate)) { return $null }
    try {
        # DMTF format: YYYYMMDDHHmmss.ffffff+TZO  (e.g. 20240115143022.000000+060)
        if ($WmiDate -match '^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})\.\d+([+\-])(\d{3})$') {
            $yr  = [int]$Matches[1]
            $mo  = [int]$Matches[2]
            $dy  = [int]$Matches[3]
            $hr  = [int]$Matches[4]
            $mn  = [int]$Matches[5]
            $sc  = [int]$Matches[6]
            $sgn = $Matches[7]
            $off = [int]$Matches[8]
            if ($sgn -eq '-') { $off = -$off }
            $local = New-Object DateTime($yr,$mo,$dy,$hr,$mn,$sc,[System.DateTimeKind]::Unspecified)
            $utc   = $local.AddMinutes(-$off)
            return $utc.ToString("yyyy-MM-ddTHH:mm:ssZ")
        } elseif ($WmiDate -match '^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})\.\d+$') {
            # No timezone suffix – use caller-supplied offset
            $yr = [int]$Matches[1]; $mo = [int]$Matches[2]; $dy = [int]$Matches[3]
            $hr = [int]$Matches[4]; $mn = [int]$Matches[5]; $sc = [int]$Matches[6]
            $local = New-Object DateTime($yr,$mo,$dy,$hr,$mn,$sc,[System.DateTimeKind]::Unspecified)
            $utc   = $local.AddMinutes(-$TzOffsetMinutes)
            return $utc.ToString("yyyy-MM-ddTHH:mm:ssZ")
        } else {
            return $null
        }
    } catch {
        return $null
    }
}

# ---------------------------------------------------------------------------
# SHA-256 helper
# ---------------------------------------------------------------------------

function Get-FileSha256 {
    param([string]$FilePath)
    try {
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $stream = [System.IO.File]::OpenRead($FilePath)
        $hash   = [BitConverter]::ToString($sha256.ComputeHash($stream)) -replace '-',''
        $stream.Close()
        $sha256.Dispose()
        return $hash
    } catch {
        return "HASH_ERROR"
    }
}

function Get-BytesSha256 {
    param([byte[]]$Bytes)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $hash   = [BitConverter]::ToString($sha256.ComputeHash($Bytes)) -replace '-',''
    $sha256.Dispose()
    return $hash
}

# ---------------------------------------------------------------------------
# Netstat parser (shared by Tier 2 and Tier 3)
# ---------------------------------------------------------------------------

function Parse-NetstatOutput {
    param([string[]]$Lines)
    $results = New-Object System.Collections.ArrayList
    $stateMap = @{
        'LISTENING'    = 'Listen'
        'ESTABLISHED'  = 'Established'
        'CLOSE_WAIT'   = 'CloseWait'
        'TIME_WAIT'    = 'TimeWait'
        'SYN_SENT'     = 'SynSent'
        'SYN_RECEIVED' = 'SynReceived'
        'FIN_WAIT_1'   = 'FinWait1'
        'FIN_WAIT_2'   = 'FinWait2'
        'LAST_ACK'     = 'LastAck'
        'CLOSING'      = 'Closing'
        'CLOSED'       = 'Closed'
    }
    foreach ($line in $Lines) {
        $line = $line.Trim()
        if ($line -notmatch '^(TCP|UDP)') { continue }
        $parts = $line -split '\s+'
        if ($parts.Count -lt 4) { continue }
        $proto    = $parts[0]
        $localRaw = $parts[1]
        $remRaw   = $parts[2]
        # UDP has no state field
        if ($proto -eq 'UDP') {
            $stateRaw = ''
            $pidRaw   = $parts[3]
        } else {
            if ($parts.Count -lt 5) { continue }
            $stateRaw = $parts[3]
            $pidRaw   = $parts[4]
        }

        # Parse local
        if ($localRaw -match '^\[(.+)\]:(\d+)$') {
            $localAddr = $Matches[1]; $localPort = [int]$Matches[2]
        } elseif ($localRaw -match '^(.+):(\d+)$') {
            $localAddr = $Matches[1]; $localPort = [int]$Matches[2]
        } else { continue }

        # Parse remote
        if ($remRaw -match '^\[(.+)\]:(\d+)$') {
            $remAddr = $Matches[1]; $remPort = [int]$Matches[2]
        } elseif ($remRaw -match '^(.+):(\d+)$') {
            $remAddr = $Matches[1]; $remPort = [int]$Matches[2]
        } else { $remAddr = ''; $remPort = 0 }

        $stateKey = $stateRaw.Trim()
        $mappedState = if ($stateMap.ContainsKey($stateKey)) { $stateMap[$stateKey] } else { $stateKey }

        $owningPid = 0
        [int]::TryParse($pidRaw.Trim(), [ref]$owningPid) | Out-Null

        $obj = New-Object PSObject -Property @{
            LocalAddress  = $localAddr
            LocalPort     = $localPort
            RemoteAddress = $remAddr
            RemotePort    = $remPort
            State         = $mappedState
            OwningProcess = $owningPid
            CreationTime  = $null
            CreationTimeUTC = $null
            InterfaceAlias  = $null
            ReverseDns      = $null
            DnsMatch        = $null
        }
        [void]$results.Add($obj)
    }
    return $results
}

# ---------------------------------------------------------------------------
# ipconfig /all parser — returns hashtable of IP -> AdapterName
# ---------------------------------------------------------------------------

function Get-AdapterMap {
    param([string[]]$IpconfigLines)
    $map = @{}
    $currentAdapter = ''
    foreach ($line in $IpconfigLines) {
        if ($line -match '^[A-Za-z].+adapter (.+):') {
            $currentAdapter = $Matches[1].Trim()
        } elseif ($line -match 'IPv4 Address[\. ]+:\s*(.+)') {
            $ip = $Matches[1].Trim() -replace '\(Preferred\)','' -replace '\s',''
            if ($ip -ne '' -and $currentAdapter -ne '') {
                $map[$ip] = $currentAdapter
            }
        } elseif ($line -match 'IP Address[\. ]+:\s*(.+)') {
            # Legacy label
            $ip = $Matches[1].Trim() -replace '\(Preferred\)','' -replace '\s',''
            if ($ip -ne '' -and $currentAdapter -ne '') {
                $map[$ip] = $currentAdapter
            }
        }
    }
    return $map
}

function Set-InterfaceAlias {
    param($Connections, $AdapterMap)
    foreach ($conn in $Connections) {
        $la = $conn.LocalAddress
        if ($la -eq '0.0.0.0' -or $la -eq '::') {
            $conn.InterfaceAlias = 'ALL_INTERFACES'
        } elseif ($AdapterMap.ContainsKey($la)) {
            $conn.InterfaceAlias = $AdapterMap[$la]
        } else {
            $conn.InterfaceAlias = $null
        }
    }
}

# ---------------------------------------------------------------------------
# DNS enrichment
# ---------------------------------------------------------------------------

function Invoke-DnsEnrichment {
    param($TcpConnections, $DnsCache)
    # Build lookup from DNS cache: Data -> Entry
    $dnsLookup = @{}
    foreach ($entry in $DnsCache) {
        $data = $entry.Data
        if ($data -and -not $dnsLookup.ContainsKey($data)) {
            $dnsLookup[$data] = $entry.Entry
        }
    }

    $uniqueIps = $TcpConnections |
        Where-Object { $_.RemoteAddress -and $_.RemoteAddress -ne '' -and
                       $_.RemoteAddress -ne '0.0.0.0' -and $_.RemoteAddress -ne '::' } |
        ForEach-Object { $_.RemoteAddress } | Sort-Object -Unique

    $reverseDnsMap = @{}
    foreach ($ip in $uniqueIps) {
        try {
            $entry = [System.Net.Dns]::GetHostEntry($ip)
            $reverseDnsMap[$ip] = $entry.HostName
        } catch {
            $reverseDnsMap[$ip] = $null
        }
    }

    foreach ($conn in $TcpConnections) {
        $ra = $conn.RemoteAddress
        if ($ra -and $reverseDnsMap.ContainsKey($ra)) {
            $conn.ReverseDns = $reverseDnsMap[$ra]
        }
        if ($ra -and $dnsLookup.ContainsKey($ra)) {
            $conn.DnsMatch = $dnsLookup[$ra]
        }
    }
}

# ---------------------------------------------------------------------------
# Capability probe
# ---------------------------------------------------------------------------

function Get-TargetCapabilities {
    param(
        [string]$Target,
        [System.Management.Automation.Runspaces.PSSession]$Session,
        [string]$CollectionLog,
        [string]$ErrorLog
    )

    $caps = New-Object PSObject -Property @{
        PSVersion             = 0
        OSVersion             = ''
        OSBuild               = ''
        OSCaption             = ''
        IsLegacy              = $true
        HasCIM                = $false
        HasNetTCPIP           = $false
        HasDNSClient          = $false
        HasGetNetNeighbor     = $false
        WMFVersion            = ''
        IsServerCore          = $false
        TimezoneOffsetMinutes = 0
    }

    try {
        $probeResult = Invoke-Command -Session $Session -ScriptBlock {
            $out = @{}
            $out['PSVersion'] = $PSVersionTable.PSVersion.Major

            try {
                $os = Get-WmiObject Win32_OperatingSystem
                $out['OSVersion'] = $os.Version
                $out['OSBuild']   = $os.BuildNumber
                $out['OSCaption'] = $os.Caption
            } catch {}

            try {
                $tz = Get-WmiObject Win32_TimeZone
                $out['TzOffset'] = $tz.Bias
            } catch { $out['TzOffset'] = 0 }

            # CIM probe
            try {
                Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop | Out-Null
                $out['HasCIM'] = $true
            } catch { $out['HasCIM'] = $false }

            # NetTCPIP namespace
            try {
                $ns = Get-WmiObject -Namespace ROOT/StandardCimv2 -Class MSFT_NetTCPConnection `
                    -ErrorAction Stop | Select-Object -First 1
                $out['HasNetTCPIP'] = $true
            } catch { $out['HasNetTCPIP'] = $false }

            # DNS client namespace
            try {
                $dns = Get-WmiObject -Namespace ROOT/StandardCimv2 -Class MSFT_DNSClientCache `
                    -ErrorAction Stop | Select-Object -First 1
                $out['HasDNSClient'] = $true
            } catch { $out['HasDNSClient'] = $false }

            # Get-NetNeighbor
            try {
                Get-Command Get-NetNeighbor -ErrorAction Stop | Out-Null
                $out['HasGetNetNeighbor'] = $true
            } catch { $out['HasGetNetNeighbor'] = $false }

            # WMF version
            $out['WMFVersion'] = $PSVersionTable.PSVersion.ToString()

            # ServerCore check
            try {
                $installType = (Get-ItemProperty `
                    'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' `
                    -Name InstallationType -ErrorAction Stop).InstallationType
                $out['IsServerCore'] = ($installType -eq 'Server Core')
            } catch { $out['IsServerCore'] = $false }

            $out
        } -ErrorAction Stop

        $caps.PSVersion             = [int]$probeResult['PSVersion']
        $caps.OSVersion             = [string]$probeResult['OSVersion']
        $caps.OSBuild               = [string]$probeResult['OSBuild']
        $caps.OSCaption             = [string]$probeResult['OSCaption']
        $caps.IsLegacy              = ($caps.PSVersion -lt 3)
        $caps.HasCIM                = [bool]$probeResult['HasCIM']
        $caps.HasNetTCPIP           = [bool]$probeResult['HasNetTCPIP']
        $caps.HasDNSClient          = [bool]$probeResult['HasDNSClient']
        $caps.HasGetNetNeighbor     = [bool]$probeResult['HasGetNetNeighbor']
        $caps.WMFVersion            = [string]$probeResult['WMFVersion']
        $caps.IsServerCore          = [bool]$probeResult['IsServerCore']
        $caps.TimezoneOffsetMinutes = [int]$probeResult['TzOffset']

        Write-Log -Message "Capability probe complete: PSv=$($caps.PSVersion) IsLegacy=$($caps.IsLegacy) HasCIM=$($caps.HasCIM) HasNetTCPIP=$($caps.HasNetTCPIP) HasDNSClient=$($caps.HasDNSClient)" `
            -Level INFO -LogFile $CollectionLog
    } catch {
        Write-ErrorLog -Message "Capability probe failed: $($_.Exception.Message)" `
            -ErrorLogFile $ErrorLog -CollectionLogFile $CollectionLog
    }

    return $caps
}

# ---------------------------------------------------------------------------
# Runspace wrapper with timeout
# ---------------------------------------------------------------------------

function Invoke-WithTimeout {
    param(
        [scriptblock]$ScriptBlock,
        [int]$TimeoutSeconds = 60,
        [hashtable]$ArgumentMap = @{}
    )
    $rs   = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    foreach ($kv in $ArgumentMap.GetEnumerator()) {
        $rs.SessionStateProxy.SetVariable($kv.Key, $kv.Value)
    }
    $ps   = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($ScriptBlock)
    $async = $ps.BeginInvoke()
    $done  = $async.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
    if (-not $done) {
        $ps.Stop()
        $ps.Dispose()
        $rs.Close()
        throw "Operation timed out after $TimeoutSeconds seconds"
    }
    $result = $ps.EndInvoke($async)
    $ps.Dispose()
    $rs.Close()
    return $result
}

# ---------------------------------------------------------------------------
# Retry wrapper
# ---------------------------------------------------------------------------

function Invoke-WithRetry {
    param(
        [scriptblock]$ScriptBlock,
        [int]$MaxAttempts = 5,
        [int]$DelaySeconds = 30,
        [string]$CollectionLog,
        [string]$ErrorLog
    )
    $attempt = 0
    while ($attempt -lt $MaxAttempts) {
        $attempt++
        try {
            return (& $ScriptBlock)
        } catch {
            if ($attempt -ge $MaxAttempts) {
                throw
            }
            Write-Log -Message "Attempt $attempt failed, retrying in ${DelaySeconds}s: $($_.Exception.Message)" `
                -Level WARN -LogFile $CollectionLog
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

# ---------------------------------------------------------------------------
# Pslist collection
# ---------------------------------------------------------------------------

function Get-RemotePslist {
    param(
        [string]$Target,
        [System.Management.Automation.Runspaces.PSSession]$Session,
        $CimSession,
        [PSCredential]$Credential,
        $Caps,
        [int]$TzOffset,
        [string]$CollectionLog,
        [string]$ErrorLog
    )

    $fields = @('ProcessId','ParentProcessId','Name','CommandLine',
                'ExecutablePath','CreationDate','WorkingSetSize',
                'VirtualSize','SessionId','HandleCount')

    $processes = $null

    if ($Caps.PSVersion -ge 3 -and $CimSession) {
        try {
            $processes = Invoke-Command -Session $Session -ScriptBlock {
                param($flds)
                Get-CimInstance Win32_Process -OperationTimeoutSec 30 |
                    Select-Object -Property $flds
            } -ArgumentList (,$fields) -ErrorAction Stop
        } catch {
            Write-Log -Message "CIM pslist failed, falling back to WMI: $($_.Exception.Message)" `
                -Level WARN -LogFile $CollectionLog
            $processes = $null
        }
    }

    if ($null -eq $processes) {
        try {
            $processes = Invoke-Command -Session $Session -ScriptBlock {
                param($flds)
                Get-WmiObject Win32_Process | Select-Object -Property $flds
            } -ArgumentList (,$fields) -ErrorAction Stop
        } catch {
            Write-ErrorLog -Message "WMI pslist failed: $($_.Exception.Message)" `
                -ErrorLogFile $ErrorLog -CollectionLogFile $CollectionLog
            return @()
        }
    }

    $result = New-Object System.Collections.ArrayList
    foreach ($proc in $processes) {
        $utcDate = Convert-WmiDateToUtc -WmiDate ([string]$proc.CreationDate) -TzOffsetMinutes $TzOffset
        $obj = New-Object PSObject -Property @{
            ProcessId         = $proc.ProcessId
            ParentProcessId   = $proc.ParentProcessId
            Name              = $proc.Name
            CommandLine       = $proc.CommandLine
            ExecutablePath    = $proc.ExecutablePath
            CreationDateLocal = $proc.CreationDate
            CreationDateUTC   = $utcDate
            WorkingSetSize    = $proc.WorkingSetSize
            VirtualSize       = $proc.VirtualSize
            SessionId         = $proc.SessionId
            HandleCount       = $proc.HandleCount
        }
        [void]$result.Add($obj)
    }
    return $result
}

# ---------------------------------------------------------------------------
# Network TCP collection
# ---------------------------------------------------------------------------

function Get-RemoteNetworkTcp {
    param(
        [string]$Target,
        [System.Management.Automation.Runspaces.PSSession]$Session,
        $Caps,
        [PSCredential]$Credential,
        [string]$CollectionLog,
        [string]$ErrorLog,
        [ref]$NetworkSource
    )

    $connections = $null
    $NetworkSource.Value = 'cim'

    # Detect Server 2012 R2 (build 9600)
    $is2012R2 = ($Caps.OSBuild -eq '9600')

    # Tier 1: Modern CIM
    if ($Caps.PSVersion -ge 3 -and $Caps.HasNetTCPIP -and -not $is2012R2) {
        try {
            $raw = Invoke-Command -Session $Session -ScriptBlock {
                Get-CimInstance -Namespace ROOT/StandardCimv2 -ClassName MSFT_NetTCPConnection `
                    -ErrorAction Stop |
                    Select-Object LocalAddress, LocalPort, RemoteAddress, RemotePort,
                                  OwningProcess, State, CreationTime
            } -ErrorAction Stop

            if ($raw -and $raw.Count -gt 0) {
                $connections = New-Object System.Collections.ArrayList
                foreach ($r in $raw) {
                    $obj = New-Object PSObject -Property @{
                        LocalAddress  = [string]$r.LocalAddress
                        LocalPort     = [int]$r.LocalPort
                        RemoteAddress = [string]$r.RemoteAddress
                        RemotePort    = [int]$r.RemotePort
                        OwningProcess = [int]$r.OwningProcess
                        State         = [string]$r.State
                        CreationTime  = if ($r.CreationTime) { $r.CreationTime.ToString("yyyy-MM-ddTHH:mm:ssZ") } else { $null }
                        InterfaceAlias = $null
                        ReverseDns    = $null
                        DnsMatch      = $null
                    }
                    [void]$connections.Add($obj)
                }
                $NetworkSource.Value = 'cim'
                Write-Log -Message "TCP Tier 1 (CIM) collected $($connections.Count) connections" `
                    -Level INFO -LogFile $CollectionLog
            } else {
                $connections = $null
            }
        } catch {
            Write-Log -Message "TCP Tier 1 failed: $($_.Exception.Message)" `
                -Level WARN -LogFile $CollectionLog
            $connections = $null
        }
    }

    # Tier 2: netstat fallback (PS3+)
    if ($null -eq $connections -and $Caps.PSVersion -ge 3) {
        try {
            $netstatLines = Invoke-Command -Session $Session -ScriptBlock {
                $out = netstat -ano 2>&1
                $out -split "`n"
            } -ErrorAction Stop

            $ipconfigLines = Invoke-Command -Session $Session -ScriptBlock {
                (ipconfig /all) -split "`n"
            } -ErrorAction Stop

            $connections = Parse-NetstatOutput -Lines $netstatLines
            $adapterMap  = Get-AdapterMap -IpconfigLines $ipconfigLines
            Set-InterfaceAlias -Connections $connections -AdapterMap $adapterMap
            $NetworkSource.Value = 'netstat_fallback'
            Write-Log -Message "TCP Tier 2 (netstat_fallback) collected $($connections.Count) connections" `
                -Level INFO -LogFile $CollectionLog
        } catch {
            Write-Log -Message "TCP Tier 2 failed: $($_.Exception.Message)" `
                -Level WARN -LogFile $CollectionLog
            $connections = $null
        }
    }

    # Tier 3: legacy netstat (PS2.0)
    if ($null -eq $connections) {
        try {
            $netstatLines = Invoke-Command -Session $Session -ScriptBlock {
                (cmd /c "netstat -ano") -split "`n"
            } -ErrorAction Stop

            $ipconfigLines = Invoke-Command -Session $Session -ScriptBlock {
                (cmd /c "ipconfig /all") -split "`n"
            } -ErrorAction Stop

            $connections = Parse-NetstatOutput -Lines $netstatLines
            $adapterMap  = Get-AdapterMap -IpconfigLines $ipconfigLines
            Set-InterfaceAlias -Connections $connections -AdapterMap $adapterMap
            $NetworkSource.Value = 'netstat_legacy'
            Write-Log -Message "TCP Tier 3 (netstat_legacy) collected $($connections.Count) connections" `
                -Level INFO -LogFile $CollectionLog
        } catch {
            Write-ErrorLog -Message "TCP Tier 3 failed: $($_.Exception.Message)" `
                -ErrorLogFile $ErrorLog -CollectionLogFile $CollectionLog
            $connections = @()
        }
    }

    return $connections
}

# ---------------------------------------------------------------------------
# DNS cache collection
# ---------------------------------------------------------------------------

function Get-RemoteNetworkDns {
    param(
        [string]$Target,
        [System.Management.Automation.Runspaces.PSSession]$Session,
        $Caps,
        [string]$CollectionLog,
        [string]$ErrorLog,
        [ref]$DnsSource
    )

    $dnsEntries = $null
    $DnsSource.Value = 'cim'

    # Tier 1: Modern CIM
    if ($Caps.PSVersion -ge 3 -and $Caps.HasDNSClient) {
        try {
            $raw = Invoke-Command -Session $Session -ScriptBlock {
                Get-CimInstance -Namespace ROOT/StandardCimv2 -ClassName MSFT_DNSClientCache `
                    -ErrorAction Stop |
                    Select-Object Entry, Name, Data, Type, TTL
            } -ErrorAction Stop

            if ($raw) {
                $dnsEntries = New-Object System.Collections.ArrayList
                foreach ($r in $raw) {
                    $obj = New-Object PSObject -Property @{
                        Entry = [string]$r.Entry
                        Name  = [string]$r.Name
                        Data  = [string]$r.Data
                        Type  = [string]$r.Type
                        TTL   = $r.TTL
                    }
                    [void]$dnsEntries.Add($obj)
                }
                $DnsSource.Value = 'cim'
                Write-Log -Message "DNS Tier 1 (CIM) collected $($dnsEntries.Count) entries" `
                    -Level INFO -LogFile $CollectionLog
            } else {
                $dnsEntries = $null
            }
        } catch {
            Write-Log -Message "DNS Tier 1 failed: $($_.Exception.Message)" `
                -Level WARN -LogFile $CollectionLog
            $dnsEntries = $null
        }
    }

    # Tier 2: ipconfig /displaydns (PS3+)
    if ($null -eq $dnsEntries -and $Caps.PSVersion -ge 3) {
        try {
            $dnsLines = Invoke-Command -Session $Session -ScriptBlock {
                (ipconfig /displaydns) -split "`n"
            } -ErrorAction Stop

            $dnsEntries = Parse-IpconfigDns -Lines $dnsLines
            $DnsSource.Value = 'ipconfig_fallback'
            Write-Log -Message "DNS Tier 2 (ipconfig_fallback) collected $($dnsEntries.Count) entries" `
                -Level INFO -LogFile $CollectionLog
        } catch {
            Write-Log -Message "DNS Tier 2 failed: $($_.Exception.Message)" `
                -Level WARN -LogFile $CollectionLog
            $dnsEntries = $null
        }
    }

    # Tier 3: legacy ipconfig (PS2.0)
    if ($null -eq $dnsEntries) {
        try {
            $dnsLines = Invoke-Command -Session $Session -ScriptBlock {
                (cmd /c "ipconfig /displaydns") -split "`n"
            } -ErrorAction Stop

            $dnsEntries = Parse-IpconfigDns -Lines $dnsLines
            $DnsSource.Value = 'ipconfig_legacy'
            Write-Log -Message "DNS Tier 3 (ipconfig_legacy) collected $($dnsEntries.Count) entries" `
                -Level INFO -LogFile $CollectionLog
        } catch {
            Write-ErrorLog -Message "DNS Tier 3 failed: $($_.Exception.Message)" `
                -ErrorLogFile $ErrorLog -CollectionLogFile $CollectionLog
            $dnsEntries = @()
        }
    }

    return $dnsEntries
}

function Parse-IpconfigDns {
    param([string[]]$Lines)
    $results = New-Object System.Collections.ArrayList
    $currentEntry = ''
    $currentData  = @{}

    foreach ($line in $Lines) {
        $line = $line.TrimEnd()
        if ($line -match '^\s*-+\s*$') { continue }

        # New record name header line: "    fqdn.example.com"
        if ($line -match '^\s{4}([^\s].+)\s*$' -and $line -notmatch ':') {
            # Flush previous
            if ($currentEntry -ne '' -and $currentData.Count -gt 0) {
                $obj = New-Object PSObject -Property @{
                    Entry = $currentEntry
                    Name  = $currentEntry
                    Data  = if ($currentData.ContainsKey('Record Name')) { $currentData['Record Name'] } else { '' }
                    Type  = if ($currentData.ContainsKey('Record Type')) { $currentData['Record Type'] } else { '' }
                    TTL   = if ($currentData.ContainsKey('Time To Live')) { $currentData['Time To Live'] } else { '' }
                }
                [void]$results.Add($obj)
                $currentData = @{}
            }
            $currentEntry = $Matches[1].Trim()
        } elseif ($line -match '^\s+(.+?)\s*\.\s*\.\s*\.\s*:\s*(.+)$') {
            $key = $Matches[1].Trim()
            $val = $Matches[2].Trim()
            $currentData[$key] = $val
        } elseif ($line -match '^\s+(.+?)\s+:\s+(.+)$') {
            $key = $Matches[1].Trim()
            $val = $Matches[2].Trim()
            $currentData[$key] = $val
        }
    }
    # Flush last
    if ($currentEntry -ne '' -and $currentData.Count -gt 0) {
        $obj = New-Object PSObject -Property @{
            Entry = $currentEntry
            Name  = $currentEntry
            Data  = if ($currentData.ContainsKey('Record Name')) { $currentData['Record Name'] } else { '' }
            Type  = if ($currentData.ContainsKey('Record Type')) { $currentData['Record Type'] } else { '' }
            TTL   = if ($currentData.ContainsKey('Time To Live')) { $currentData['Time To Live'] } else { '' }
        }
        [void]$results.Add($obj)
    }
    return $results
}

# ---------------------------------------------------------------------------
# SMB stub generator
# ---------------------------------------------------------------------------

function Get-StubContent {
    # PS 2.0 compatible stub. No CIM, no [PSCustomObject], no shorthand Where-Object.
    $stub = @'
# DFIR collection stub — PS 2.0 compatible
$ErrorActionPreference = "SilentlyContinue"

$job = Start-Job -ScriptBlock {
    $out = @{}

    # Pslist
    try {
        $procs = Get-WmiObject Win32_Process |
            Select-Object ProcessId, ParentProcessId, Name, CommandLine,
                          ExecutablePath, CreationDate, WorkingSetSize,
                          VirtualSize, SessionId, HandleCount
        $procList = @()
        foreach ($p in $procs) {
            $procList += @{
                ProcessId       = $p.ProcessId
                ParentProcessId = $p.ParentProcessId
                Name            = $p.Name
                CommandLine     = $p.CommandLine
                ExecutablePath  = $p.ExecutablePath
                CreationDate    = $p.CreationDate
                WorkingSetSize  = $p.WorkingSetSize
                VirtualSize     = $p.VirtualSize
                SessionId       = $p.SessionId
                HandleCount     = $p.HandleCount
            }
        }
        $out['pslist'] = $procList
    } catch {
        $out['pslist'] = @()
        $out['pslist_error'] = $_.Exception.Message
    }

    # Network TCP via netstat
    try {
        $netstatRaw = (cmd /c "netstat -ano") -split "`n"
        $tcpList = @()
        $stateMap = @{
            'LISTENING'   = 'Listen'
            'ESTABLISHED' = 'Established'
            'CLOSE_WAIT'  = 'CloseWait'
            'TIME_WAIT'   = 'TimeWait'
            'SYN_SENT'    = 'SynSent'
            'SYN_RECEIVED'= 'SynReceived'
            'FIN_WAIT_1'  = 'FinWait1'
            'FIN_WAIT_2'  = 'FinWait2'
            'LAST_ACK'    = 'LastAck'
            'CLOSING'     = 'Closing'
            'CLOSED'      = 'Closed'
        }
        foreach ($line in $netstatRaw) {
            $line = $line.Trim()
            if ($line -notmatch '^(TCP|UDP)') { continue }
            $parts = $line -split '\s+'
            if ($parts.Count -lt 4) { continue }
            $proto = $parts[0]
            $localRaw = $parts[1]
            $remRaw   = $parts[2]
            if ($proto -eq 'UDP') {
                $stateRaw = ''
                $pidRaw   = $parts[3]
            } else {
                if ($parts.Count -lt 5) { continue }
                $stateRaw = $parts[3]
                $pidRaw   = $parts[4]
            }
            if ($localRaw -match '^\[(.+)\]:(\d+)$') {
                $la = $Matches[1]; $lp = [int]$Matches[2]
            } elseif ($localRaw -match '^(.+):(\d+)$') {
                $la = $Matches[1]; $lp = [int]$Matches[2]
            } else { continue }
            if ($remRaw -match '^\[(.+)\]:(\d+)$') {
                $ra = $Matches[1]; $rp = [int]$Matches[2]
            } elseif ($remRaw -match '^(.+):(\d+)$') {
                $ra = $Matches[1]; $rp = [int]$Matches[2]
            } else { $ra = ''; $rp = 0 }
            $sk = $stateRaw.Trim()
            $ms = if ($stateMap.ContainsKey($sk)) { $stateMap[$sk] } else { $sk }
            $op = 0
            [int]::TryParse($pidRaw.Trim(), [ref]$op) | Out-Null
            $tcpList += @{
                LocalAddress  = $la
                LocalPort     = $lp
                RemoteAddress = $ra
                RemotePort    = $rp
                State         = $ms
                OwningProcess = $op
            }
        }
        $out['network_tcp'] = $tcpList
        $out['network_source'] = 'netstat_legacy'
    } catch {
        $out['network_tcp'] = @()
        $out['network_tcp_error'] = $_.Exception.Message
        $out['network_source'] = 'netstat_legacy'
    }

    # DNS via ipconfig
    try {
        $dnsRaw = (cmd /c "ipconfig /displaydns") -split "`n"
        $dnsList  = @()
        $curEntry = ''
        $curData  = @{}
        foreach ($line in $dnsRaw) {
            $line = $line.TrimEnd()
            if ($line -match '^\s*-+\s*$') { continue }
            if ($line -match '^\s{4}([^\s].+)\s*$' -and $line -notmatch ':') {
                if ($curEntry -ne '' -and $curData.Count -gt 0) {
                    $dnsList += @{
                        Entry = $curEntry
                        Name  = $curEntry
                        Data  = if ($curData.ContainsKey('Record Name')) { $curData['Record Name'] } else { '' }
                        Type  = if ($curData.ContainsKey('Record Type')) { $curData['Record Type'] } else { '' }
                        TTL   = if ($curData.ContainsKey('Time To Live')) { $curData['Time To Live'] } else { '' }
                    }
                    $curData = @{}
                }
                $curEntry = $Matches[1].Trim()
            } elseif ($line -match '^\s+(.+?)\s+:\s+(.+)$') {
                $curData[$Matches[1].Trim()] = $Matches[2].Trim()
            }
        }
        if ($curEntry -ne '' -and $curData.Count -gt 0) {
            $dnsList += @{
                Entry = $curEntry
                Name  = $curEntry
                Data  = if ($curData.ContainsKey('Record Name')) { $curData['Record Name'] } else { '' }
                Type  = if ($curData.ContainsKey('Record Type')) { $curData['Record Type'] } else { '' }
                TTL   = if ($curData.ContainsKey('Time To Live')) { $curData['Time To Live'] } else { '' }
            }
        }
        $out['network_dns'] = $dnsList
        $out['dns_source'] = 'ipconfig_legacy'
    } catch {
        $out['network_dns'] = @()
        $out['dns_error'] = $_.Exception.Message
        $out['dns_source'] = 'ipconfig_legacy'
    }

    $out
}

$completed = Wait-Job $job -Timeout 90
if ($null -eq $completed) {
    Stop-Job $job
    $result = @{ error = 'stub_timeout' }
} else {
    $result = Receive-Job $job
}
Remove-Job $job -Force

$json = $result | ConvertTo-Json -Depth 10
$json | Out-File -FilePath 'C:\Windows\Temp\dfir_out.json' -Encoding UTF8 -Force

Remove-Item $MyInvocation.MyCommand.Path -Force -ErrorAction SilentlyContinue
'@
    return $stub
}

# ---------------------------------------------------------------------------
# WinRM collection orchestrator
# ---------------------------------------------------------------------------

function Invoke-WinRMCollection {
    param(
        [string]$Target,
        [PSCredential]$Credential,
        [string]$TargetOutputDir,
        [string]$Timestamp
    )

    $collectionLog = Join-Path $TargetOutputDir "collection.log"
    $errorLog      = Join-Path $TargetOutputDir "errors.log"

    Initialize-TargetLogs -TargetOutputDir $TargetOutputDir
    Write-Log -Message "Starting WinRM collection for $Target" -Level INFO -LogFile $collectionLog

    # --- Establish session with retry ---
    $session    = $null
    $cimSession = $null

    $session = Invoke-WithRetry -MaxAttempts 5 -DelaySeconds 30 `
        -CollectionLog $collectionLog -ErrorLog $errorLog -ScriptBlock {

        $sessionOpt = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck `
            -OperationTimeout 60000 -OpenTimeout 30000
        New-PSSession -ComputerName $Target -Credential $Credential `
            -SessionOption $sessionOpt -ErrorAction Stop
    }

    if ($null -eq $session) {
        Write-ErrorLog -Message "Failed to establish PSSession to $Target after retries" `
            -ErrorLogFile $errorLog -CollectionLogFile $collectionLog
        return $null
    }

    Write-Log -Message "PSSession established" -Level INFO -LogFile $collectionLog

    # --- Capability probe ---
    $caps = Get-TargetCapabilities -Target $Target -Session $session `
        -CollectionLog $collectionLog -ErrorLog $errorLog

    # --- CIM session for modern targets ---
    if ($caps.PSVersion -ge 3) {
        try {
            $cimOpt     = New-CimSessionOption -Protocol Wsman
            $cimSession = New-CimSession -ComputerName $Target -Credential $Credential `
                -SessionOption $cimOpt -ErrorAction Stop
        } catch {
            Write-Log -Message "CimSession creation failed: $($_.Exception.Message)" `
                -Level WARN -LogFile $collectionLog
            $cimSession = $null
        }
    }

    # For legacy targets, also attempt a WinRM session on HTTP 5985 with Basic auth
    if ($caps.IsLegacy) {
        try {
            $legacyOpt = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
            $legacySession = New-PSSession -ComputerName $Target -Credential $Credential `
                -Port 5985 -Authentication Basic -SessionOption $legacyOpt -ErrorAction Stop
            Remove-PSSession $session -ErrorAction SilentlyContinue
            $session = $legacySession
            Write-Log -Message "Using legacy WinRM session (Basic/HTTP)" -Level INFO -LogFile $collectionLog
        } catch {
            Write-Log -Message "Legacy session upgrade failed, using existing session: $($_.Exception.Message)" `
                -Level WARN -LogFile $collectionLog
        }
    }

    # --- Collect artifacts ---
    $networkSourceRef = [ref]'cim'
    $dnsSourceRef     = [ref]'cim'

    $pslist     = @()
    $networkTcp = @()
    $networkDns = @()

    try {
        $pslist = Get-RemotePslist -Target $Target -Session $session -CimSession $cimSession `
            -Credential $Credential -Caps $caps -TzOffset $caps.TimezoneOffsetMinutes `
            -CollectionLog $collectionLog -ErrorLog $errorLog
    } catch {
        Write-ErrorLog -Message "Pslist collection exception: $($_.Exception.Message)" `
            -ErrorLogFile $errorLog -CollectionLogFile $collectionLog
    }

    try {
        $networkTcp = Get-RemoteNetworkTcp -Target $Target -Session $session -Caps $caps `
            -Credential $Credential -CollectionLog $collectionLog -ErrorLog $errorLog `
            -NetworkSource $networkSourceRef
    } catch {
        Write-ErrorLog -Message "Network TCP collection exception: $($_.Exception.Message)" `
            -ErrorLogFile $errorLog -CollectionLogFile $collectionLog
    }

    try {
        $networkDns = Get-RemoteNetworkDns -Target $Target -Session $session -Caps $caps `
            -CollectionLog $collectionLog -ErrorLog $errorLog -DnsSource $dnsSourceRef
    } catch {
        Write-ErrorLog -Message "DNS collection exception: $($_.Exception.Message)" `
            -ErrorLogFile $errorLog -CollectionLogFile $collectionLog
    }

    # --- DNS enrichment ---
    try {
        Invoke-DnsEnrichment -TcpConnections $networkTcp -DnsCache $networkDns
    } catch {
        Write-Log -Message "DNS enrichment failed: $($_.Exception.Message)" `
            -Level WARN -LogFile $collectionLog
    }

    # --- Cleanup sessions ---
    if ($cimSession) {
        Remove-CimSession $cimSession -ErrorAction SilentlyContinue
    }
    Remove-PSSession $session -ErrorAction SilentlyContinue

    # --- Write output files ---
    $hostname       = $Target
    $pslistFile     = Join-Path $TargetOutputDir "${hostname}_pslist_${Timestamp}.json"
    $tcpFile        = Join-Path $TargetOutputDir "${hostname}_network_tcp_${Timestamp}.json"
    $dnsFile        = Join-Path $TargetOutputDir "${hostname}_network_dns_${Timestamp}.json"
    $manifestFile   = Join-Path $TargetOutputDir "${hostname}_manifest.json"

    $pslist     | ConvertTo-Json -Depth 10 | Out-File -FilePath $pslistFile  -Encoding UTF8
    $networkTcp | ConvertTo-Json -Depth 10 | Out-File -FilePath $tcpFile     -Encoding UTF8
    $networkDns | ConvertTo-Json -Depth 10 | Out-File -FilePath $dnsFile     -Encoding UTF8

    # Build file entries for manifest
    $fileEntries = @()
    foreach ($fp in @($pslistFile, $tcpFile, $dnsFile)) {
        if (Test-Path $fp) {
            $fileEntries += @{
                name       = (Split-Path $fp -Leaf)
                sha256     = (Get-FileSha256 -FilePath $fp)
                size_bytes = (Get-Item $fp).Length
            }
        }
    }

    # OS caption from WMI collected during probe
    $manifest = [ordered]@{
        hostname                 = $hostname
        collection_time_utc      = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        collector_version        = $Script:CollectorVersion
        analyst_machine_hostname = $Script:AnalystContext.analyst_machine_hostname
        analyst_machine_os       = $Script:AnalystContext.analyst_machine_os
        analyst_ps_version       = $Script:AnalystContext.analyst_ps_version
        protocol_used            = "WinRM"
        os_version               = $caps.OSVersion
        os_build                 = $caps.OSBuild
        os_caption               = $caps.OSCaption
        is_server_core           = $caps.IsServerCore
        ps_version               = $caps.PSVersion
        wmf_version              = $caps.WMFVersion
        timezone_offset_minutes  = $caps.TimezoneOffsetMinutes
        network_source           = $networkSourceRef.Value
        dns_source               = $dnsSourceRef.Value
        stub_sha256              = $null
        capability_flags         = @{
            HasCIM            = $caps.HasCIM
            HasNetTCPIP       = $caps.HasNetTCPIP
            HasDNSClient      = $caps.HasDNSClient
            HasGetNetNeighbor = $caps.HasGetNetNeighbor
            IsLegacy          = $caps.IsLegacy
        }
        files = $fileEntries
    }

    $manifest | ConvertTo-Json -Depth 10 | Out-File -FilePath $manifestFile -Encoding UTF8

    Write-Log -Message "WinRM collection complete for $Target" -Level INFO -LogFile $collectionLog
    return $manifest
}

# ---------------------------------------------------------------------------
# SMB collection orchestrator
# ---------------------------------------------------------------------------

function Invoke-SMBCollection {
    param(
        [string]$Target,
        [PSCredential]$Credential,
        [string]$TargetOutputDir,
        [string]$Timestamp
    )

    $collectionLog = Join-Path $TargetOutputDir "collection.log"
    $errorLog      = Join-Path $TargetOutputDir "errors.log"

    Initialize-TargetLogs -TargetOutputDir $TargetOutputDir
    Write-Log -Message "Starting SMB collection for $Target" -Level INFO -LogFile $collectionLog

    $psDrive = $null
    $stubPath = "\\$Target\C$\Windows\Temp\dfir_stub.ps1"
    $outPath  = "\\$Target\C$\Windows\Temp\dfir_out.json"
    $stubHash = $null

    try {
        # Map C$
        $psDrive = Invoke-WithRetry -MaxAttempts 5 -DelaySeconds 30 `
            -CollectionLog $collectionLog -ErrorLog $errorLog -ScriptBlock {
            New-PSDrive -Name "DFIRTarget" -PSProvider FileSystem `
                -Root "\\$Target\C$" -Credential $Credential -ErrorAction Stop
        }
        Write-Log -Message "C$ mapped successfully" -Level INFO -LogFile $collectionLog
    } catch {
        Write-ErrorLog -Message "SMB drive mapping failed: $($_.Exception.Message)" `
            -ErrorLogFile $errorLog -CollectionLogFile $collectionLog
        return $null
    }

    try {
        # Generate and hash stub
        $stubContent = Get-StubContent
        $stubBytes   = [System.Text.Encoding]::UTF8.GetBytes($stubContent)
        $stubHash    = Get-BytesSha256 -Bytes $stubBytes

        # Write stub
        $stubContent | Out-File -FilePath $stubPath -Encoding UTF8 -Force
        Write-Log -Message "Stub written (SHA256=$stubHash)" -Level INFO -LogFile $collectionLog

        # Execute stub via WMI
        $wmiResult = Invoke-WmiMethod -Class Win32_Process -Name Create `
            -ArgumentList "powershell.exe -NonInteractive -ExecutionPolicy Bypass -File C:\Windows\Temp\dfir_stub.ps1" `
            -ComputerName $Target -Credential $Credential -ErrorAction Stop

        if ($wmiResult.ReturnValue -ne 0) {
            throw "WMI process creation returned $($wmiResult.ReturnValue)"
        }
        Write-Log -Message "Stub execution launched via WMI" -Level INFO -LogFile $collectionLog

        # Poll for output (120s timeout)
        $deadline = (Get-Date).AddSeconds(120)
        $outReady = $false
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 3
            if (Test-Path $outPath) {
                # Verify file is non-empty and parseable
                $size = (Get-Item $outPath).Length
                if ($size -gt 2) {
                    $outReady = $true
                    break
                }
            }
        }

        if (-not $outReady) {
            throw "Timed out waiting for stub output after 120s"
        }

        Write-Log -Message "Stub output available" -Level INFO -LogFile $collectionLog

        # Read results
        $jsonRaw = Get-Content -Path $outPath -Raw -Encoding UTF8
        $result  = $jsonRaw | ConvertFrom-Json

        # Cleanup remote files
        Remove-Item $stubPath -Force -ErrorAction SilentlyContinue
        Remove-Item $outPath  -Force -ErrorAction SilentlyContinue

    } catch {
        Write-ErrorLog -Message "SMB collection failed: $($_.Exception.Message)" `
            -ErrorLogFile $errorLog -CollectionLogFile $collectionLog
        # Best-effort cleanup
        Remove-Item $stubPath -Force -ErrorAction SilentlyContinue
        Remove-Item $outPath  -Force -ErrorAction SilentlyContinue
        if ($psDrive) { Remove-PSDrive -Name "DFIRTarget" -Force -ErrorAction SilentlyContinue }
        return $null
    } finally {
        if ($psDrive) { Remove-PSDrive -Name "DFIRTarget" -Force -ErrorAction SilentlyContinue }
    }

    # --- Process result ---
    $hostname = $Target
    $pslistFile   = Join-Path $TargetOutputDir "${hostname}_pslist_${Timestamp}.json"
    $tcpFile      = Join-Path $TargetOutputDir "${hostname}_network_tcp_${Timestamp}.json"
    $dnsFile      = Join-Path $TargetOutputDir "${hostname}_network_dns_${Timestamp}.json"
    $manifestFile = Join-Path $TargetOutputDir "${hostname}_manifest.json"

    $networkSource = 'netstat_legacy'
    $dnsSource     = 'ipconfig_legacy'

    if ($result.network_source) { $networkSource = $result.network_source }
    if ($result.dns_source)     { $dnsSource     = $result.dns_source     }

    # Pslist: add UTC dates
    $pslistOut = New-Object System.Collections.ArrayList
    if ($result.pslist) {
        foreach ($p in $result.pslist) {
            $utcDate = Convert-WmiDateToUtc -WmiDate ([string]$p.CreationDate)
            $obj = New-Object PSObject -Property @{
                ProcessId         = $p.ProcessId
                ParentProcessId   = $p.ParentProcessId
                Name              = $p.Name
                CommandLine       = $p.CommandLine
                ExecutablePath    = $p.ExecutablePath
                CreationDateLocal = $p.CreationDate
                CreationDateUTC   = $utcDate
                WorkingSetSize    = $p.WorkingSetSize
                VirtualSize       = $p.VirtualSize
                SessionId         = $p.SessionId
                HandleCount       = $p.HandleCount
            }
            [void]$pslistOut.Add($obj)
        }
    }

    # Network TCP: flatten to objects
    $tcpOut = New-Object System.Collections.ArrayList
    if ($result.network_tcp) {
        foreach ($c in $result.network_tcp) {
            $obj = New-Object PSObject -Property @{
                LocalAddress  = $c.LocalAddress
                LocalPort     = $c.LocalPort
                RemoteAddress = $c.RemoteAddress
                RemotePort    = $c.RemotePort
                State         = $c.State
                OwningProcess = $c.OwningProcess
                CreationTime  = $null
                InterfaceAlias = $c.InterfaceAlias
                ReverseDns    = $null
                DnsMatch      = $null
            }
            [void]$tcpOut.Add($obj)
        }
    }

    # DNS cache
    $dnsOut = New-Object System.Collections.ArrayList
    if ($result.network_dns) {
        foreach ($d in $result.network_dns) {
            $obj = New-Object PSObject -Property @{
                Entry = $d.Entry
                Name  = $d.Name
                Data  = $d.Data
                Type  = $d.Type
                TTL   = $d.TTL
            }
            [void]$dnsOut.Add($obj)
        }
    }

    # DNS enrichment
    try {
        Invoke-DnsEnrichment -TcpConnections $tcpOut -DnsCache $dnsOut
    } catch {
        Write-Log -Message "DNS enrichment failed: $($_.Exception.Message)" `
            -Level WARN -LogFile $collectionLog
    }

    # Write files
    $pslistOut | ConvertTo-Json -Depth 10 | Out-File -FilePath $pslistFile  -Encoding UTF8
    $tcpOut    | ConvertTo-Json -Depth 10 | Out-File -FilePath $tcpFile     -Encoding UTF8
    $dnsOut    | ConvertTo-Json -Depth 10 | Out-File -FilePath $dnsFile     -Encoding UTF8

    $fileEntries = @()
    foreach ($fp in @($pslistFile, $tcpFile, $dnsFile)) {
        if (Test-Path $fp) {
            $fileEntries += @{
                name       = (Split-Path $fp -Leaf)
                sha256     = (Get-FileSha256 -FilePath $fp)
                size_bytes = (Get-Item $fp).Length
            }
        }
    }

    $manifest = [ordered]@{
        hostname                 = $hostname
        collection_time_utc      = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        collector_version        = $Script:CollectorVersion
        analyst_machine_hostname = $Script:AnalystContext.analyst_machine_hostname
        analyst_machine_os       = $Script:AnalystContext.analyst_machine_os
        analyst_ps_version       = $Script:AnalystContext.analyst_ps_version
        protocol_used            = "SMB"
        os_version               = $null
        os_build                 = $null
        os_caption               = $null
        is_server_core           = $null
        ps_version               = $null
        wmf_version              = $null
        timezone_offset_minutes  = $null
        network_source           = $networkSource
        dns_source               = $dnsSource
        stub_sha256              = $stubHash
        capability_flags         = @{
            HasCIM            = $false
            HasNetTCPIP       = $false
            HasDNSClient      = $false
            HasGetNetNeighbor = $false
            IsLegacy          = $true
        }
        files = $fileEntries
    }

    $manifest | ConvertTo-Json -Depth 10 | Out-File -FilePath $manifestFile -Encoding UTF8

    Write-Log -Message "SMB collection complete for $Target" -Level INFO -LogFile $collectionLog
    return $manifest
}

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

# Resolve and create output root
$OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$runTimestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")

Write-Log -Message "DFIR Collector v$($Script:CollectorVersion) starting. Protocol=$Protocol Targets=$($Targets.Count)" `
    -Level INFO -LogFile (Join-Path $OutputPath "collection.log")

foreach ($target in $Targets) {
    $target = $target.Trim()
    if ([string]::IsNullOrEmpty($target)) { continue }

    $targetOutputDir = Join-Path $OutputPath $target
    Initialize-TargetLogs -TargetOutputDir $targetOutputDir

    $collLog  = Join-Path $targetOutputDir "collection.log"
    $errLog   = Join-Path $targetOutputDir "errors.log"

    Write-Log -Message "Processing target: $target" -Level INFO -LogFile $collLog

    try {
        switch ($Protocol) {
            "WinRM" {
                $result = Invoke-WinRMCollection -Target $target -Credential $Credential `
                    -TargetOutputDir $targetOutputDir -Timestamp $runTimestamp
            }
            "SMB" {
                $result = Invoke-SMBCollection -Target $target -Credential $Credential `
                    -TargetOutputDir $targetOutputDir -Timestamp $runTimestamp
            }
        }

        if ($result) {
            Write-Log -Message "Target $target completed successfully" -Level INFO -LogFile $collLog
        } else {
            Write-Log -Message "Target $target collection returned no result" -Level WARN -LogFile $collLog
        }
    } catch {
        Write-ErrorLog -Message "Unhandled exception for target $target: $($_.Exception.Message)" `
            -ErrorLogFile $errLog -CollectionLogFile $collLog
    }
}

Write-Log -Message "All targets processed. Output: $OutputPath" -Level INFO `
    -LogFile (Join-Path $OutputPath "collection.log")
