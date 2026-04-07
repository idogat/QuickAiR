#Requires -Version 5.1
# ╔══════════════════════════════════════╗
# ║  QuickAiR -- Connection.psm1          ║
# ║  WinRM sessions, WMI fallback,     ║
# ║  capability probe, hostname res.   ║
# ║  NOTE: WMI "session" = param bag,  ║
# ║  not a persistent connection.      ║
# ║  Each collector re-authenticates.  ║
# ╠══════════════════════════════════════╣
# ║  Exports   : Test-PrivateIP         ║
# ║              Resolve-TargetHostname ║
# ║              ConvertFrom-TcpStateInt║
# ║              Get-TargetCaps         ║
# ║              Get-TargetCapsWMI     ║
# ║              New-RemoteSession      ║
# ║              New-WMISession         ║
# ║  Inputs    : -Target -Cred          ║
# ║  Output    : caps hashtable;        ║
# ║              PSSession | hashtable  ║
# ║  Depends   : Core\Output.psm1       ║
# ║  PS compat : 5.1 (analyst machine)  ║
# ║  Version   : 2.9                    ║
# ╚══════════════════════════════════════╝

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

$script:OP_TIMEOUT_SEC = 60

function Test-PrivateIP {
    param([string]$IP)
    if (-not $IP) { return $false }
    return ($IP -match '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.|0\.0\.0\.0$|::1$|fe80:)')
}

function Resolve-TargetHostname {
    param([string]$Target)
    if ($Target -eq 'localhost' -or $Target -eq '127.0.0.1') { return $env:COMPUTERNAME }
    if ($Target -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
        $ar = $null
        try {
            # Use async DNS with 5-second timeout to avoid blocking on unreachable DNS
            $ar = [System.Net.Dns]::BeginGetHostEntry($Target, $null, $null)
            if ($ar.AsyncWaitHandle.WaitOne(5000)) {
                $h = [System.Net.Dns]::EndGetHostEntry($ar)
                return $h.HostName
            } else {
                # Complete the async operation to prevent dangling callback (W-02)
                try { $null = [System.Net.Dns]::EndGetHostEntry($ar) } catch {}
                Write-Log 'WARN' "DNS resolution timed out (5s) for $Target, using IP as fallback"
                return $Target
            }
        } catch {
            Write-Log 'WARN' "DNS resolution failed for $Target, using IP as fallback: $($_.Exception.Message)"
            return $Target
        } finally {
            if ($ar) { try { $ar.AsyncWaitHandle.Close() } catch {} }
        }
    }
    return $Target
}

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
        12  { return 'DELETE_TCB'   }
        100 { return 'BOUND'        }
        default { return $n.ToString() }
    }
}

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

    $shortTarget = ($Target -split '\.')[0]
    $isLocal = ($Target -eq 'localhost' -or $Target -eq '127.0.0.1' -or $Target -eq '::1' -or $shortTarget -ieq $env:COMPUTERNAME)

    try {
        if ($isLocal) {
            $c.PSVersion = $PSVersionTable.PSVersion.Major
            $os = Get-WmiObject Win32_OperatingSystem -ErrorAction Stop
            $c.OSVersion = $os.Version; $c.OSBuild = $os.BuildNumber; $c.OSCaption = $os.Caption
            $tz = Get-WmiObject Win32_TimeZone
            if ($tz) { $c.TimezoneOffsetMinutes = $tz.Bias }
            else { $c.TimezoneOffsetMinutes = 0; Write-Log 'WARN' "Win32_TimeZone returned null for local -- defaulting TimezoneOffsetMinutes to 0 (UTC)" }
            $inst = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'InstallationType' -ErrorAction SilentlyContinue
            $c.IsServerCore = ($inst -and $inst.InstallationType -eq 'Server Core')

            if ($c.PSVersion -ge 3) {
                $c.HasCIM = $true
                try { Get-CimInstance -Namespace ROOT/StandardCimv2 -ClassName MSFT_NetTCPConnection -OperationTimeoutSec $script:OP_TIMEOUT_SEC -ErrorAction Stop | Select-Object -First 1 | Out-Null; $c.HasNetTCPIP = $true } catch {}
                try { Get-CimInstance -Namespace ROOT/StandardCimv2 -ClassName MSFT_DNSClientCache  -OperationTimeoutSec $script:OP_TIMEOUT_SEC -ErrorAction Stop | Select-Object -First 1 | Out-Null; $c.HasDNSClient = $true } catch {}
            }
        } else {
            $so = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck -OpenTimeout 30000 -OperationTimeout 60000
            $spArgs = @{ ComputerName = $Target; SessionOption = $so; ErrorAction = 'Stop'; Port = 5985 }
            if ($Cred) { $spArgs.Credential = $Cred }
            $sess = New-PSSession @spArgs
            try {
                $r = Invoke-Command -Session $sess -ScriptBlock {
                    $v   = $PSVersionTable.PSVersion.Major
                    $os  = Get-WmiObject Win32_OperatingSystem -ErrorAction Stop
                    $tz  = Get-WmiObject Win32_TimeZone
                    $tzBias = if ($tz) { $tz.Bias } else { 0 }
                    $hCim = $v -ge 3
                    $hNet = $false; $hDns = $false
                    if ($hCim) {
                        try { Get-CimInstance -Namespace ROOT/StandardCimv2 -ClassName MSFT_NetTCPConnection -OperationTimeoutSec 10 -ErrorAction Stop | Select-Object -First 1 | Out-Null; $hNet = $true } catch {}
                        try { Get-CimInstance -Namespace ROOT/StandardCimv2 -ClassName MSFT_DNSClientCache  -OperationTimeoutSec 10 -ErrorAction Stop | Select-Object -First 1 | Out-Null; $hDns = $true } catch {}
                    }
                    $inst = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'InstallationType' -ErrorAction SilentlyContinue
                    New-Object PSObject -Property @{
                        PSVersion=$v; OSVersion=$os.Version; OSBuild=$os.BuildNumber; OSCaption=$os.Caption
                        TZBias=$tzBias; TZNull=($null -eq $tz); HasCIM=$hCim; HasNetTCPIP=$hNet; HasDNSClient=$hDns
                        IsServerCore=($inst -and $inst.InstallationType -eq 'Server Core')
                    }
                }
                $c.PSVersion             = $r.PSVersion
                $c.OSVersion             = $r.OSVersion
                $c.OSBuild               = $r.OSBuild
                $c.OSCaption             = $r.OSCaption
                $c.TimezoneOffsetMinutes = $r.TZBias
                if ($r.PSObject.Properties['TZNull'] -and $r.TZNull) {
                    Write-Log 'WARN' "Win32_TimeZone returned null on remote $Target -- defaulting TimezoneOffsetMinutes to 0 (UTC)"
                }
                $c.HasCIM                = $r.HasCIM
                $c.HasNetTCPIP           = $r.HasNetTCPIP
                $c.HasDNSClient          = $r.HasDNSClient
                $c.IsServerCore          = $r.IsServerCore
            } finally { Remove-PSSession $sess -ErrorAction SilentlyContinue }
        }
    } catch { $c.Error = $_.Exception.Message }

    return $c
}

function Get-TargetCapsWMI {
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

    try {
        $wmiP = @{ ComputerName = $Target; ErrorAction = 'Stop' }
        if ($Cred) { $wmiP.Credential = $Cred }

        $os = Get-WmiObject Win32_OperatingSystem @wmiP
        $c.OSVersion = $os.Version
        $c.OSBuild   = $os.BuildNumber
        $c.OSCaption = $os.Caption

        $tz = Get-WmiObject Win32_TimeZone @wmiP
        if ($tz) {
            $c.TimezoneOffsetMinutes = $tz.Bias
        } else {
            $c.TimezoneOffsetMinutes = 0
            Write-Log 'WARN' "Win32_TimeZone returned null for $Target -- defaulting TimezoneOffsetMinutes to 0 (UTC). Timestamps may be inaccurate if target is not UTC."
        }

        # PS version via remote registry (StdRegProv)
        $scope = $null; $reg = $null
        try {
            $scope = New-Object System.Management.ManagementScope("\\$Target\root\default")
            $scope.Options.Timeout = [TimeSpan]::FromSeconds($script:OP_TIMEOUT_SEC)
            if ($Cred) {
                # SECURITY NOTE: ManagementScope has no SecureString overload -- plaintext
                # password unavoidable. Scope.Dispose() in finally block limits lifetime.
                $scope.Options.Username = $Cred.UserName
                $scope.Options.Password = $Cred.GetNetworkCredential().Password
            }
            try { $scope.Connect() } catch {
                throw (New-Object System.Management.ManagementException("WMI registry scope connection failed for $Target"))
            }
            $reg = New-Object System.Management.ManagementClass($scope, [System.Management.ManagementPath]'StdRegProv', $null)
            $HKLM = [uint32]2147483650
            $inP  = $reg.GetMethodParameters('GetStringValue')
            $inP['hDefKey']     = $HKLM
            $inP['sSubKeyName'] = 'SOFTWARE\Microsoft\PowerShell\3\PowerShellEngine'
            $inP['sValueName']  = 'PowerShellVersion'
            $out = $reg.InvokeMethod('GetStringValue', $inP, $null)
            if ($out['ReturnValue'] -eq 0 -and $out['sValue']) {
                $verParts = $out['sValue'] -split '\.'
                $c.PSVersion = [int]$verParts[0]
            }
            # IsServerCore
            $inP2 = $reg.GetMethodParameters('GetStringValue')
            $inP2['hDefKey']     = $HKLM
            $inP2['sSubKeyName'] = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion'
            $inP2['sValueName']  = 'InstallationType'
            $out2 = $reg.InvokeMethod('GetStringValue', $inP2, $null)
            if ($out2['ReturnValue'] -eq 0 -and $out2['sValue'] -eq 'Server Core') {
                $c.IsServerCore = $true
            }
        } catch {
            # Registry unavailable -- infer PS version from OS build
            $build = [int]$c.OSBuild
            if     ($build -ge 10240) { $c.PSVersion = 5 }
            elseif ($build -ge 9200)  { $c.PSVersion = 3 }
            else                      { $c.PSVersion = 2 }
        } finally {
            if ($reg)   { try { $reg.Dispose() }   catch {} }
            if ($scope) { try { $scope.Dispose() } catch {} }
        }

        if ($c.PSVersion -eq 0) {
            $build = [int]$c.OSBuild
            if     ($build -ge 10240) { $c.PSVersion = 5 }
            elseif ($build -ge 9200)  { $c.PSVersion = 3 }
            else                      { $c.PSVersion = 2 }
        }

        # CIM not available without WinRM
        $c.HasCIM      = $false
        $c.HasNetTCPIP = $false
        $c.HasDNSClient = $false

    } catch { $c.Error = $_.Exception.Message }

    return $c
}

function New-WMISession {
    param(
        [string]$Target,
        [System.Management.Automation.PSCredential]$Credential
    )
    # Connectivity probe with timeout via ManagementScope
    $probeScope = $null
    try {
        $probeScope = New-Object System.Management.ManagementScope("\\$Target\root\cimv2")
        $probeScope.Options.Timeout = [TimeSpan]::FromSeconds($script:OP_TIMEOUT_SEC)
        if ($Credential) {
            # SECURITY NOTE: ManagementScope has no SecureString overload -- plaintext
            # password unavoidable. Scope.Dispose() in finally block limits lifetime.
            $probeScope.Options.Username = $Credential.UserName
            $probeScope.Options.Password = $Credential.GetNetworkCredential().Password
        }
        $probeScope.Connect()
    } finally {
        if ($probeScope) { try { $probeScope.Dispose() } catch {} }
    }

    # Probe ROOT\StandardCimv2 availability (needed for TCP/UDP collection)
    $hasStdCimv2 = $false
    $stdScope = $null
    try {
        $stdScope = New-Object System.Management.ManagementScope("\\$Target\ROOT\StandardCimv2")
        $stdScope.Options.Timeout = [TimeSpan]::FromSeconds($script:OP_TIMEOUT_SEC)
        if ($Credential) {
            # SECURITY NOTE: ManagementScope -- see note in New-WMISession above.
            $stdScope.Options.Username = $Credential.UserName
            $stdScope.Options.Password = $Credential.GetNetworkCredential().Password
        }
        try {
            $stdScope.Connect()
            $hasStdCimv2 = $true
        } catch {
            Write-Log 'WARN' "StandardCimv2 probe failed for $Target"
        }
    } catch {} finally {
        if ($stdScope) { try { $stdScope.Dispose() } catch {} }
    }

    return @{
        ComputerName    = $Target
        Credential      = $Credential
        Method          = 'WMI'
        HasStandardCimv2 = $hasStdCimv2
    }
}

function New-RemoteSession {
    param(
        [string]$Target,
        [System.Management.Automation.PSCredential]$Credential
    )
    $so = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck -OpenTimeout 30000 -OperationTimeout 60000
    $spArgs = @{ ComputerName = $Target; SessionOption = $so; ErrorAction = 'Stop'; Port = 5985 }
    if ($Credential) { $spArgs.Credential = $Credential }
    $sess = New-PSSession @spArgs
    $sess | Add-Member -NotePropertyName Method -NotePropertyValue 'WinRM'
    return $sess
}

Export-ModuleMember -Function Test-PrivateIP, Resolve-TargetHostname, ConvertFrom-TcpStateInt, Get-TargetCaps, Get-TargetCapsWMI, New-RemoteSession, New-WMISession
