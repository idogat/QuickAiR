#Requires -Version 5.1
# ╔══════════════════════════════════════╗
# ║  Quicker — Connection.psm1          ║
# ║  WinRM sessions, capability probe,  ║
# ║  hostname resolution, auth utils    ║
# ╠══════════════════════════════════════╣
# ║  Exports   : Test-PrivateIP         ║
# ║              Resolve-TargetHostname ║
# ║              ConvertFrom-TcpStateInt║
# ║              Get-TargetCaps         ║
# ║              New-RemoteSession      ║
# ║  Inputs    : -Target -Cred          ║
# ║  Output    : caps hashtable;        ║
# ║              PSSession              ║
# ║  Depends   : none                   ║
# ║  PS compat : 5.1 (analyst machine)  ║
# ║  Version   : 2.0                    ║
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
                try { Get-CimInstance -Namespace ROOT/StandardCimv2 -ClassName MSFT_NetTCPConnection -OperationTimeoutSec $script:OP_TIMEOUT_SEC -ErrorAction Stop | Select-Object -First 1 | Out-Null; $c.HasNetTCPIP = $true } catch {}
                try { Get-CimInstance -Namespace ROOT/StandardCimv2 -ClassName MSFT_DNSClientCache  -OperationTimeoutSec $script:OP_TIMEOUT_SEC -ErrorAction Stop | Select-Object -First 1 | Out-Null; $c.HasDNSClient = $true } catch {}
            }
        } else {
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

function New-RemoteSession {
    param(
        [string]$Target,
        [System.Management.Automation.PSCredential]$Credential
    )
    $so = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
    $spArgs = @{ ComputerName = $Target; SessionOption = $so; ErrorAction = 'Stop'; Port = 5985 }
    if ($Credential) { $spArgs.Credential = $Credential }
    $sess = New-PSSession @spArgs
    return $sess
}

Export-ModuleMember -Function Test-PrivateIP, Resolve-TargetHostname, ConvertFrom-TcpStateInt, Get-TargetCaps, New-RemoteSession
