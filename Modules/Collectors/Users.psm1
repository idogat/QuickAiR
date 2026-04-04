# ╔══════════════════════════════════════╗
# ║  QuickAiR -- Users.psm1               ║
# ║  User account collection + WMI     ║
# ╠══════════════════════════════════════╣
# ║  Exports  : Invoke-Collector        ║
# ║  Output   : @{ data=@{             ║
# ║               is_domain_controller, ║
# ║               domain_name,         ║
# ║               machine_name,        ║
# ║               machine_sid,         ║
# ║               users=[],            ║
# ║               domain_accounts=[]   ║
# ║             }; source="";errors=[]}║
# ║  Fields   : SID, Username, Domain, ║
# ║    AccountType, FirstLogon{UTC,     ║
# ║    Confidence}, LastLogonUTC,       ║
# ║    LastLogonSource, ProfilePath,    ║
# ║    IsLoaded, HasLocalAccount,       ║
# ║    LocalDisabled, SIDMetadata,      ║
# ║    GroupMemberships                 ║
# ║  DC fields: SamAccountName,        ║
# ║    DisplayName, SID, Enabled,      ║
# ║    WhenCreatedUTC, LastLogonUTC,    ║
# ║    LastLogonTimestampUTC,           ║
# ║    PasswordLastSetUTC, LockedOut,   ║
# ║    BadLogonCount, MemberOf, Source  ║
# ║  Helpers  : ComputeFirstLogonConf, ║
# ║    GetSidAccountType, GetSidDomain,║
# ║    GetSidMetadata                  ║
# ║  PS compat: 2.0+ (target-side)     ║
# ║  Version  : 2.9                    ║
# ╚══════════════════════════════════════╝

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# ── PS 2.0-compatible scriptblock -- runs ON the target ──────────────────────
$script:USERS_SB = {
    $r = @{
        is_dc              = $false
        domain_name        = ''
        machine_name       = ''
        machine_sid        = $null
        profiles_raw       = @()
        local_accounts_raw = @()
        dc_domain_raw      = @()
        dc_source          = $null
        group_memberships  = @()
        errors             = @()
    }

    # ── System info ──────────────────────────────────────────────────────────
    try {
        $cs = Get-WmiObject Win32_ComputerSystem
        $r.is_dc       = ($cs.DomainRole -eq 4 -or $cs.DomainRole -eq 5)
        $r.domain_name = [string]$cs.Domain
        $r.machine_name= [string]$cs.Name
    } catch { $r.errors += "SysInfo: $($_.Exception.Message)" }

    # ── Machine SID prefix ───────────────────────────────────────────────────
    try {
        $lu = Get-WmiObject Win32_UserAccount -Filter "LocalAccount=True" | Select-Object -First 1
        if ($lu -and $lu.SID) {
            $p = $lu.SID.Split('-')
            $r.machine_sid = ($p[0..($p.Length - 2)]) -join '-'
        }
    } catch { $r.errors += "MachineSID: $($_.Exception.Message)" }

    $machineName      = $r.machine_name
    $machineSIDPrefix = $r.machine_sid

    # ── Registry LastWrite P/Invoke helper (works on all .NET versions) ─────
    $_rkHelper = $false
    $_regLwtAttempted = $false
    $_regLwtAvailable = $false
    if (-not $_regLwtAttempted) {
        $_regLwtAttempted = $true
        try { Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class RegLwt {
    [StructLayout(LayoutKind.Sequential)] struct FT { public uint lo; public uint hi; }
    const uint HKLM = 0x80000002;
    const uint KEY_QUERY_VALUE = 1;
    [DllImport("advapi32.dll",CharSet=CharSet.Unicode)]
    static extern int RegOpenKeyEx(UIntPtr h,string sub,uint opt,uint sam,out UIntPtr phk);
    [DllImport("advapi32.dll")] static extern int RegCloseKey(UIntPtr h);
    [DllImport("advapi32.dll")]
    static extern int RegQueryInfoKey(UIntPtr h,IntPtr a,IntPtr b,IntPtr c,
        IntPtr d,IntPtr e,IntPtr f,IntPtr g,IntPtr i,IntPtr j,IntPtr k,out FT ft);
    public static long GetLwt(string subKey) {
        UIntPtr hk;
        if (RegOpenKeyEx((UIntPtr)HKLM,subKey,0,KEY_QUERY_VALUE,out hk)!=0) return 0;
        FT ft;
        int res=RegQueryInfoKey(hk,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,
            IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,out ft);
        RegCloseKey(hk);
        return res!=0 ? 0 : ((long)ft.hi<<32)|(uint)ft.lo;
    }
}
'@ -ErrorAction Stop
            $_regLwtAvailable = $true
        } catch {}
    }
    try { if ($_regLwtAvailable) { [void][RegLwt]; $_rkHelper = $true } } catch {}

    # ── COLLECT 1: User profiles ─────────────────────────────────────────────
    try {
        $plRoot = "SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
        $hklm   = [Microsoft.Win32.Registry]::LocalMachine
        $plKey  = $hklm.OpenSubKey($plRoot)
        if ($plKey) {
            foreach ($sidStr in $plKey.GetSubKeyNames()) {
                $sk = $plKey.OpenSubKey($sidStr)
                if (-not $sk) { continue }

                $profilePath = [string]$sk.GetValue("ProfileImagePath")
                $state       = $sk.GetValue("State")
                $username    = if ($profilePath) { Split-Path $profilePath -Leaf } else { $null }

                # LastUseTime from FILETIME high/low dwords
                $lastUseRaw = $null
                try {
                    $lh = $sk.GetValue("LocalProfileLoadTimeHigh")
                    $ll = $sk.GetValue("LocalProfileLoadTimeLow")
                    if ($lh -ne $null -and $ll -ne $null) {
                        $ft = [Int64]$lh * 4294967296 + [Int64]([uint32]$ll)
                        if ($ft -gt 0) {
                            $lastUseRaw = [DateTime]::FromFileTimeUtc($ft).ToString('yyyy-MM-ddTHH:mm:ssZ')
                        }
                    }
                } catch {}

                $sk.Close()

                # Profile folder creation time
                $pfRaw = $null; $pfAvail = $false
                try {
                    if ($profilePath -and (Test-Path $profilePath)) {
                        $pfRaw   = (Get-Item $profilePath -ErrorAction Stop).CreationTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                        $pfAvail = $true
                    }
                } catch {}

                # NTUSER.DAT creation time (-Force required: file is hidden/system)
                $ntRaw = $null; $ntAvail = $false
                try {
                    if ($profilePath) {
                        $ntPath = Join-Path $profilePath "NTUSER.DAT"
                        $ntItem = Get-Item $ntPath -Force -ErrorAction Stop
                        $ntRaw   = $ntItem.CreationTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                        $ntAvail = $true
                    }
                } catch {
                    # NTUSER.DAT commonly locked for active user sessions
                    Write-Warning "Cannot read NTUSER.DAT for SID $sidStr at '$ntPath': $($_.Exception.Message)"
                }

                # Registry key LastWrite time (Get-Item; P/Invoke fallback for older .NET)
                $rkRaw = $null; $rkAvail = $false
                try {
                    $rki = Get-Item "HKLM:\$plRoot\$sidStr" -ErrorAction Stop
                    $lwt = $rki.LastWriteTime
                    if ($lwt -ne $null -and $lwt -gt [DateTime]::MinValue) {
                        $rkRaw   = $lwt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                        $rkAvail = $true
                    }
                } catch {}
                if (-not $rkAvail -and $_rkHelper) {
                    try {
                        $ft = [RegLwt]::GetLwt("$plRoot\$sidStr")
                        if ($ft -gt 0) {
                            $rkRaw   = [DateTime]::FromFileTimeUtc($ft).ToString('yyyy-MM-ddTHH:mm:ssZ')
                            $rkAvail = $true
                        }
                    } catch {}
                }

                $r.profiles_raw += @{
                    SID         = $sidStr
                    Username    = $username
                    ProfilePath = $profilePath
                    State       = $state
                    LastUseRaw  = $lastUseRaw
                    PFRaw       = $pfRaw;  PFAvail = $pfAvail
                    NTRaw       = $ntRaw;  NTAvail = $ntAvail
                    RKRaw       = $rkRaw;  RKAvail = $rkAvail
                }
            }
            $plKey.Close()
        }
    } catch { $r.errors += "Profiles: $($_.Exception.Message)" }

    # ── COLLECT 2: Local accounts ────────────────────────────────────────────
    try {
        $localUsers = Get-WmiObject Win32_UserAccount -Filter "LocalAccount=True"
        foreach ($u in $localUsers) {
            $r.local_accounts_raw += @{
                Name     = [string]$u.Name
                SID      = [string]$u.SID
                Disabled = [bool]$u.Disabled
            }
        }
    } catch { $r.errors += "LocalAccounts: $($_.Exception.Message)" }

    # ── COLLECT 2b: Local group memberships ──────────────────────────────────
    try {
        $groupUsers = Get-WmiObject Win32_GroupUser -ErrorAction Stop
        foreach ($gu in $groupUsers) {
            $gName = $null; $mName = $null
            try {
                if ($gu.GroupComponent -match 'Name="([^"]+)"') { $gName = $Matches[1] }
                if ($gu.PartComponent  -match 'Name="([^"]+)"') { $mName = $Matches[1] }
            } catch {}
            if ($gName -and $mName) {
                $r.group_memberships += @{ GroupName = $gName; MemberName = $mName }
            }
        }
    } catch {
        # Fallback: parse net localgroup for critical groups
        try {
            foreach ($grp in @('Administrators','Remote Desktop Users','Backup Operators')) {
                $out = & net localgroup $grp 2>$null
                if (-not $out) { continue }
                $inMembers = $false
                foreach ($line in $out) {
                    if ($line -match '^----') { $inMembers = $true; continue }
                    if ($line -match '^The command completed') { break }
                    if ($inMembers -and $line.Trim()) {
                        $r.group_memberships += @{ GroupName = $grp; MemberName = $line.Trim() }
                    }
                }
            }
        } catch { $r.errors += "GroupMemberships: $($_.Exception.Message)" }
    }

    # ── COLLECT 3: Domain accounts (DC only) ─────────────────────────────────
    if ($r.is_dc) {
        try {
            try {
                Import-Module ActiveDirectory -ErrorAction Stop
                $adUsers = Get-ADUser -Filter * -Properties `
                    Created,LastLogonDate,lastLogon,PasswordLastSet,
                    Enabled,BadLogonCount,LockedOut,MemberOf
                $r.dc_source = 'Get-ADUser'
                foreach ($u in $adUsers) {
                    $r.dc_domain_raw += @{
                        SamAccountName  = [string]$u.SamAccountName
                        DisplayName     = [string]$u.Name
                        SID             = if ($u.SID) { $u.SID.Value } else { $null }
                        Enabled         = [bool]$u.Enabled
                        WhenCreated          = if ($u.Created)       { $u.Created.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }       else { $null }
                        LastLogonTimestamp    = if ($u.LastLogonDate)  { $u.LastLogonDate.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $null }
                        LastLogon            = $(try { if ($u.lastLogon -and [Int64]$u.lastLogon -gt 0) { [DateTime]::FromFileTimeUtc([Int64]$u.lastLogon).ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $null } } catch { $null })
                        PasswordLastSet = if ($u.PasswordLastSet){ $u.PasswordLastSet.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')} else { $null }
                        LockedOut       = [bool]$u.LockedOut
                        BadLogonCount   = [int]$u.BadLogonCount
                        MemberOf        = @(foreach ($dn in @($u.MemberOf)) { if ($dn -match '^CN=([^,]+)') { $Matches[1] } })
                        Source          = 'Get-ADUser'
                    }
                }
            } catch {
                # ADSI fallback -- PS 2.0 / no RSAT
                $r.dc_source = 'ADSI'
                $adRoot   = New-Object System.DirectoryServices.DirectoryEntry("LDAP://RootDSE")
                $domDN    = $adRoot.Properties["defaultNamingContext"][0]
                $domEntry = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$domDN", $null, $null, [System.DirectoryServices.AuthenticationTypes]::Secure)
                $searcher = New-Object System.DirectoryServices.DirectorySearcher($domEntry)
                try {
                    $searcher.Filter   = "(&(objectClass=user)(objectCategory=person))"
                    $searcher.PageSize = 1000
                    $searcher.PropertiesToLoad.AddRange(@(
                        "samaccountname","displayname","objectsid","whencreated",
                        "lastlogontimestamp","lastlogon","pwdlastset","useraccountcontrol",
                        "badpwdcount","lockouttime","memberof"
                    ))
                    $results = $searcher.FindAll()
                    try {
                        foreach ($entry in $results) {
                            $p = $entry.Properties
                            $sidVal = $null
                            try {
                                $sidVal = (New-Object System.Security.Principal.SecurityIdentifier(
                                    [byte[]]$p["objectsid"][0], 0)).Value
                            } catch {}
                            $wc = $null
                            try { $wv = $p["whencreated"]; if ($wv -ne $null -and @($wv).Count -gt 0) {
                                $wc = ([datetime]@($wv)[0]).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } } catch {}
                            $llTs = $null
                            try { $llFt = [Int64]$p["lastlogontimestamp"][0]
                                if ($llFt -gt 0) { $llTs = [DateTime]::FromFileTimeUtc($llFt).ToString('yyyy-MM-ddTHH:mm:ssZ') } } catch {}
                            $llPerDC = $null
                            try { $llFtPerDC = [Int64]$p["lastlogon"][0]
                                if ($llFtPerDC -gt 0) { $llPerDC = [DateTime]::FromFileTimeUtc($llFtPerDC).ToString('yyyy-MM-ddTHH:mm:ssZ') } } catch {}
                            $pls = $null
                            try { $plsFt = [Int64]$p["pwdlastset"][0]
                                if ($plsFt -gt 0) { $pls = [DateTime]::FromFileTimeUtc($plsFt).ToString('yyyy-MM-ddTHH:mm:ssZ') } } catch {}
                            $uac = 0
                            try { $uac = [int]$p["useraccountcontrol"][0] } catch {}
                            $locked = $false
                            try { $locked = ([Int64]$p["lockouttime"][0]) -gt 0 } catch {}
                            $bpc = 0
                            try { $bpc = [int]$p["badpwdcount"][0] } catch {}
                            $samVal = $p["samaccountname"]; $dnVal = $p["displayname"]
                            $r.dc_domain_raw += @{
                                SamAccountName    = if ($samVal -ne $null -and @($samVal).Count -gt 0) { [string]@($samVal)[0] } else { $null }
                                DisplayName       = if ($dnVal -ne $null -and @($dnVal).Count -gt 0)   { [string]@($dnVal)[0] }  else { $null }
                                SID               = $sidVal
                                Enabled           = -not [bool]($uac -band 2)
                                WhenCreated       = $wc
                                LastLogonTimestamp = $llTs
                                LastLogon         = $llPerDC
                                PasswordLastSet   = $pls
                                LockedOut       = $locked
                                BadLogonCount   = $bpc
                                MemberOf        = @(foreach ($dn in @($p["memberof"])) { if ($dn -match '^CN=([^,]+)') { $Matches[1] } })
                                Source          = 'ADSI'
                            }
                        }
                    } finally { try { $results.Dispose() } catch {} }
                } finally { try { $searcher.Dispose() } catch {} }
            }
        } catch { $r.errors += "DomainAccounts: $($_.Exception.Message)" }
    }

    return $r
}

# ── Helpers (analyst-side) ───────────────────────────────────────────────────
function script:IsoToDate($s) {
    if (-not $s) { return $null }
    try { return [datetime]::Parse($s, $null, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { return $null }
}

function script:ComputeFirstLogonConfidence {
    param($pfUTC, $pfAvail, $ntUTC, $ntAvail, $rkUTC, $rkAvail)

    $available = @()
    if ($pfAvail -and $pfUTC) { $available += 'PF' }
    if ($ntAvail -and $ntUTC) { $available += 'NT' }
    if ($rkAvail -and $rkUTC) { $available += 'RK' }

    $firstUTC          = if ($pfUTC) { $pfUTC } elseif ($ntUTC) { $ntUTC } else { $rkUTC }
    $confidence        = 'LOW'
    $timestampMismatch = $false

    function _agree24($a,$b) {
        if (-not $a -or -not $b) { return $false }
        return [Math]::Abs(($a - $b).TotalHours) -le 24
    }
    function _agree1h($a,$b) {
        if (-not $a -or -not $b) { return $false }
        return [Math]::Abs(($a - $b).TotalHours) -le 1
    }

    if ($available.Count -eq 0) {
        $confidence = 'N/A'
        $firstUTC   = $null
    } elseif ($available.Count -eq 1) {
        $confidence = 'LOW'
    } elseif ($available.Count -eq 2) {
        $pfDt = script:IsoToDate $pfUTC
        $ntDt = script:IsoToDate $ntUTC
        $rkDt = script:IsoToDate $rkUTC

        if ($available -contains 'PF' -and $available -contains 'NT') {
            if (_agree24 $pfDt $ntDt) { $confidence = 'MEDIUM'; $firstUTC = $pfUTC }
            else { $confidence = '?'; $timestampMismatch = $true; $firstUTC = $pfUTC }
        } elseif ($available -contains 'PF' -and $available -contains 'RK') {
            if (_agree24 $pfDt $rkDt) { $confidence = 'MEDIUM'; $firstUTC = $pfUTC }
            else { $confidence = '?'; $timestampMismatch = $true; $firstUTC = $pfUTC }
        } else {
            if (_agree24 $ntDt $rkDt) { $confidence = 'MEDIUM'; $firstUTC = $ntUTC }
            else { $confidence = '?'; $timestampMismatch = $true; $firstUTC = $ntUTC }
        }
    } else {
        # 3 sources
        $pfDt = script:IsoToDate $pfUTC
        $ntDt = script:IsoToDate $ntUTC
        $rkDt = script:IsoToDate $rkUTC

        $pfNtAgree = _agree24 $pfDt $ntDt
        $pfRkAgree = _agree24 $pfDt $rkDt
        $ntRkAgree = _agree24 $ntDt $rkDt

        # HIGH requires all three within 1 hour
        $pfNtTight = _agree1h $pfDt $ntDt
        $pfRkTight = _agree1h $pfDt $rkDt

        if ($pfNtTight -and $pfRkTight) {
            $confidence = 'HIGH'; $firstUTC = $pfUTC
        } elseif ($pfNtAgree -and $pfRkAgree) {
            $confidence = 'MEDIUM'; $firstUTC = $pfUTC
        } elseif ($pfNtAgree -or $pfRkAgree -or $ntRkAgree) {
            $confidence = 'MEDIUM'
            $firstUTC = if ($pfNtAgree -or $pfRkAgree) { $pfUTC } else { $ntUTC }
        } else {
            $confidence = '?'; $timestampMismatch = $true; $firstUTC = $pfUTC
        }
    }

    return @{
        UTC               = $firstUTC
        Confidence        = $confidence
        TimestampMismatch = $timestampMismatch
    }
}

function script:GetSidAccountType($sidStr, $machineSIDPrefix) {
    if (-not $sidStr) { return 'Local' }
    if ($sidStr -eq 'S-1-5-18') { return 'System' }
    if ($sidStr -eq 'S-1-5-19') { return 'Service' }
    if ($sidStr -eq 'S-1-5-20') { return 'Service' }
    if ($machineSIDPrefix -and $sidStr -match ('^' + [regex]::Escape($machineSIDPrefix) + '-\d+$')) {
        return 'Local'
    }
    if ($sidStr -match '^S-1-5-21-') { return 'Domain' }
    if ($sidStr -match '^S-1-5-8[0-9]-') { return 'Service' }
    return 'Local'
}

function script:GetSidDomain($accountType, $machineName, $domainName) {
    switch ($accountType) {
        'System'  { return 'NT AUTHORITY' }
        'Service' { return 'NT AUTHORITY' }
        'Domain'  { return $domainName }
        default   { return $machineName }
    }
}

function script:GetSidMetadata($sidStr) {
    $known = @{
        'S-1-5-18' = 'Local System'
        'S-1-5-19' = 'Local Service'
        'S-1-5-20' = 'Network Service'
    }
    if ($known.ContainsKey($sidStr)) {
        return @{ WellKnown=$true; Description=$known[$sidStr] }
    }
    if ($sidStr -match '-500$') { return @{ WellKnown=$true; Description='Built-in Administrator' } }
    if ($sidStr -match '-501$') { return @{ WellKnown=$true; Description='Guest' } }
    return @{ WellKnown=$false; Description='' }
}

# ── Invoke-Collector ─────────────────────────────────────────────────────────
function script:Invoke-UsersWMIRemote {
    param([string]$ComputerName, [System.Management.Automation.PSCredential]$Credential)

    $wmiP = @{ ComputerName = $ComputerName; ErrorAction = 'Stop' }
    if ($Credential) { $wmiP.Credential = $Credential }

    $r = @{
        is_dc              = $false
        domain_name        = ''
        machine_name       = ''
        machine_sid        = $null
        profiles_raw       = @()
        local_accounts_raw = @()
        dc_domain_raw      = @()
        dc_source          = $null
        group_memberships  = @()
        errors             = @()
    }

    # ── System info ──────────────────────────────────────────────────────
    try {
        $cs = Get-WmiObject Win32_ComputerSystem @wmiP
        $r.is_dc       = ($cs.DomainRole -eq 4 -or $cs.DomainRole -eq 5)
        $r.domain_name = [string]$cs.Domain
        $r.machine_name= [string]$cs.Name
    } catch { $r.errors += "SysInfo: $($_.Exception.Message)" }

    # ── Machine SID prefix ───────────────────────────────────────────────
    try {
        $lu = Get-WmiObject Win32_UserAccount -Filter "LocalAccount=True" @wmiP | Select-Object -First 1
        if ($lu -and $lu.SID) {
            $p = $lu.SID.Split('-')
            $r.machine_sid = ($p[0..($p.Length - 2)]) -join '-'
        }
    } catch { $r.errors += "MachineSID: $($_.Exception.Message)" }

    # ── Profiles via StdRegProv ──────────────────────────────────────────
    try {
        $scope = New-Object System.Management.ManagementScope("\\$ComputerName\root\default")
        $scope.Options.Timeout = [TimeSpan]::FromSeconds(60)
        if ($Credential) {
            $scope.Options.Username = $Credential.UserName
            $scope.Options.Password = $Credential.GetNetworkCredential().Password
        }
        $scope.Connect()
        $reg  = New-Object System.Management.ManagementClass($scope, [System.Management.ManagementPath]'StdRegProv', $null)
        $HKLM = [uint32]2147483650
        $plRoot = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'

        # Enumerate profile SID subkeys
        $enumIn = $reg.GetMethodParameters('EnumKey')
        $enumIn['hDefKey']     = $HKLM
        $enumIn['sSubKeyName'] = $plRoot
        $enumOut = $reg.InvokeMethod('EnumKey', $enumIn, $null)
        $subKeys = @()
        if ($enumOut['ReturnValue'] -eq 0 -and $enumOut['sNames']) {
            $subKeys = @($enumOut['sNames'])
        }

        foreach ($sidStr in $subKeys) {
            # Read ProfileImagePath
            $inP = $reg.GetMethodParameters('GetStringValue')
            $inP['hDefKey']     = $HKLM
            $inP['sSubKeyName'] = "$plRoot\$sidStr"
            $inP['sValueName']  = 'ProfileImagePath'
            $outP = $reg.InvokeMethod('GetStringValue', $inP, $null)
            $profilePath = if ($outP['ReturnValue'] -eq 0) { [string]$outP['sValue'] } else { $null }
            $username = if ($profilePath) { Split-Path $profilePath -Leaf } else { $null }

            # Read State (DWORD)
            $inS = $reg.GetMethodParameters('GetDWORDValue')
            $inS['hDefKey']     = $HKLM
            $inS['sSubKeyName'] = "$plRoot\$sidStr"
            $inS['sValueName']  = 'State'
            $outS = $reg.InvokeMethod('GetDWORDValue', $inS, $null)
            $state = if ($outS['ReturnValue'] -eq 0) { $outS['uValue'] } else { $null }

            $r.profiles_raw += @{
                SID         = $sidStr
                Username    = $username
                ProfilePath = $profilePath
                State       = $state
                LastUseRaw  = $null
                PFRaw = $null; PFAvail = $false
                NTRaw = $null; NTAvail = $false
                RKRaw = $null; RKAvail = $false
            }
        }
    } catch {
        $r.errors += "Profiles(WMI): $($_.Exception.Message)"
    }

    if ($r.profiles_raw.Count -gt 0) {
        $r.errors += "WMI remote: profile timestamps (LastUse, ProfileFolder, NTUSER.DAT, RegistryKey) unavailable -- FirstLogon confidence degraded to N/A for all users"
    }

    # ── Local accounts ───────────────────────────────────────────────────
    try {
        $localUsers = Get-WmiObject Win32_UserAccount -Filter "LocalAccount=True" @wmiP
        foreach ($u in $localUsers) {
            $r.local_accounts_raw += @{
                Name     = [string]$u.Name
                SID      = [string]$u.SID
                Disabled = [bool]$u.Disabled
            }
        }
    } catch { $r.errors += "LocalAccounts: $($_.Exception.Message)" }

    # ── Group memberships ────────────────────────────────────────────────
    try {
        $groupUsers = Get-WmiObject Win32_GroupUser @wmiP
        foreach ($gu in $groupUsers) {
            $gName = $null; $mName = $null
            try {
                if ($gu.GroupComponent -match 'Name="([^"]+)"') { $gName = $Matches[1] }
                if ($gu.PartComponent  -match 'Name="([^"]+)"') { $mName = $Matches[1] }
            } catch {}
            if ($gName -and $mName) {
                $r.group_memberships += @{ GroupName = $gName; MemberName = $mName }
            }
        }
    } catch {
        $r.errors += "GroupMemberships(WMI): $($_.Exception.Message)"
    }

    # ── DC domain accounts ───────────────────────────────────────────────
    if ($r.is_dc) {
        try {
            try {
                Import-Module ActiveDirectory -ErrorAction Stop
                $adArgs = @{ Server = $ComputerName; Filter = '*'; Properties = @('Created','LastLogonDate','lastLogon','PasswordLastSet','Enabled','BadLogonCount','LockedOut','MemberOf') }
                if ($Credential) { $adArgs.Credential = $Credential }
                $adUsers = Get-ADUser @adArgs
                $r.dc_source = 'Get-ADUser'
                foreach ($u in $adUsers) {
                    $r.dc_domain_raw += @{
                        SamAccountName    = [string]$u.SamAccountName
                        DisplayName       = [string]$u.Name
                        SID               = if ($u.SID) { $u.SID.Value } else { $null }
                        Enabled           = [bool]$u.Enabled
                        WhenCreated       = if ($u.Created)       { $u.Created.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }       else { $null }
                        LastLogonTimestamp = if ($u.LastLogonDate)  { $u.LastLogonDate.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $null }
                        LastLogon         = $(try { if ($u.lastLogon -and [Int64]$u.lastLogon -gt 0) { [DateTime]::FromFileTimeUtc([Int64]$u.lastLogon).ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $null } } catch { $null })
                        PasswordLastSet   = if ($u.PasswordLastSet){ $u.PasswordLastSet.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')} else { $null }
                        LockedOut         = [bool]$u.LockedOut
                        BadLogonCount     = [int]$u.BadLogonCount
                        MemberOf          = @(foreach ($dn in @($u.MemberOf)) { if ($dn -match '^CN=([^,]+)') { $Matches[1] } })
                        Source            = 'Get-ADUser'
                    }
                }
            } catch {
                # ADSI fallback
                $r.dc_source = 'ADSI'
                $root = if ($Credential) {
                    New-Object System.DirectoryServices.DirectoryEntry("LDAP://$ComputerName", $Credential.UserName, $Credential.GetNetworkCredential().Password, [System.DirectoryServices.AuthenticationTypes]::Secure)
                } else {
                    New-Object System.DirectoryServices.DirectoryEntry("LDAP://$ComputerName")
                }
                $searcher = New-Object System.DirectoryServices.DirectorySearcher($root)
                try {
                    $searcher.Filter   = "(&(objectClass=user)(objectCategory=person))"
                    $searcher.PageSize = 1000
                    $searcher.PropertiesToLoad.AddRange(@(
                        "samaccountname","displayname","objectsid","whencreated",
                        "lastlogontimestamp","lastlogon","pwdlastset","useraccountcontrol",
                        "badpwdcount","lockouttime","memberof"
                    ))
                    $results = $searcher.FindAll()
                    try {
                        foreach ($entry in $results) {
                            $p = $entry.Properties
                            $sidVal = $null
                            try {
                                $sidVal = (New-Object System.Security.Principal.SecurityIdentifier(
                                    [byte[]]$p["objectsid"][0], 0)).Value
                            } catch {}
                            $wc = $null
                            try { $wv = $p["whencreated"]; if ($wv -ne $null -and @($wv).Count -gt 0) {
                                $wc = ([datetime]@($wv)[0]).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } } catch {}
                            $llTs = $null
                            try { $llFt = [Int64]$p["lastlogontimestamp"][0]
                                if ($llFt -gt 0) { $llTs = [DateTime]::FromFileTimeUtc($llFt).ToString('yyyy-MM-ddTHH:mm:ssZ') } } catch {}
                            $llPerDC = $null
                            try { $llFtPerDC = [Int64]$p["lastlogon"][0]
                                if ($llFtPerDC -gt 0) { $llPerDC = [DateTime]::FromFileTimeUtc($llFtPerDC).ToString('yyyy-MM-ddTHH:mm:ssZ') } } catch {}
                            $pls = $null
                            try { $plsFt = [Int64]$p["pwdlastset"][0]
                                if ($plsFt -gt 0) { $pls = [DateTime]::FromFileTimeUtc($plsFt).ToString('yyyy-MM-ddTHH:mm:ssZ') } } catch {}
                            $uac = 0
                            try { $uac = [int]$p["useraccountcontrol"][0] } catch {}
                            $locked = $false
                            try { $locked = ([Int64]$p["lockouttime"][0]) -gt 0 } catch {}
                            $bpc = 0
                            try { $bpc = [int]$p["badpwdcount"][0] } catch {}
                            $samVal = $p["samaccountname"]; $dnVal = $p["displayname"]
                            $r.dc_domain_raw += @{
                                SamAccountName    = if ($samVal -ne $null -and @($samVal).Count -gt 0) { [string]@($samVal)[0] } else { $null }
                                DisplayName       = if ($dnVal -ne $null -and @($dnVal).Count -gt 0)   { [string]@($dnVal)[0] }  else { $null }
                                SID               = $sidVal
                                Enabled           = -not [bool]($uac -band 2)
                                WhenCreated       = $wc
                                LastLogonTimestamp = $llTs
                                LastLogon         = $llPerDC
                                PasswordLastSet   = $pls
                                LockedOut         = $locked
                                BadLogonCount     = $bpc
                                MemberOf          = @(foreach ($dn in @($p["memberof"])) { if ($dn -match '^CN=([^,]+)') { $Matches[1] } })
                                Source            = 'ADSI'
                            }
                        }
                    } finally { try { $results.Dispose() } catch {} }
                } finally { try { $searcher.Dispose() } catch {} }
            }
        } catch { $r.errors += "DomainAccounts: $($_.Exception.Message)" }
    }

    return $r
}

function Invoke-Collector {
    param($Session, $TargetPSVersion, $TargetCapabilities)

    $errors = @()
    $raw    = $null

    try {
        if ($Session -ne $null -and $Session -is [hashtable] -and $Session.Method -eq 'WMI') {
            $raw = script:Invoke-UsersWMIRemote -ComputerName $Session.ComputerName -Credential $Session.Credential
        } elseif ($Session) {
            $raw = Invoke-Command -Session $Session -ScriptBlock $script:USERS_SB
        } else {
            $raw = & $script:USERS_SB
        }
    } catch {
        $errors += @{ artifact = 'Users'; message = $_.Exception.Message }
        Write-Log 'ERROR' "Users collection failed: $($_.Exception.Message)"
        return @{
            data   = @{
                is_domain_controller=$false; domain_name=$null; machine_name=$null; machine_sid=$null
                users=@(); domain_accounts=@()
            }
            source = 'error'
            errors = $errors
        }
    }

    foreach ($e in @($raw.errors)) {
        if ($e -and $e -is [string]) {
            $errors += @{ artifact = 'Users'; message = $e }
            Write-Log 'WARN' "Users: $e"
        }
    }

    $machineSIDPrefix = [string]$raw.machine_sid
    $machineName      = [string]$raw.machine_name
    $domainName       = [string]$raw.domain_name
    $plRoot           = "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"

    # Build local account lookup by SID
    $localAccountMap = @{}
    foreach ($u in @($raw.local_accounts_raw)) {
        if (-not $u) { continue }
        $localAccountMap[[string]$u.SID] = @{ Disabled=[bool]$u.Disabled; Name=[string]$u.Name }
    }

    # Build group membership lookup by username
    $groupMap = @{}
    foreach ($gm in @($raw.group_memberships)) {
        if (-not $gm) { continue }
        $mn = [string]$gm.MemberName
        if (-not $groupMap.ContainsKey($mn)) { $groupMap[$mn] = @() }
        $groupMap[$mn] += [string]$gm.GroupName
    }

    # Build users[] -- source = ProfileList, enriched with local account data
    $userMap = @{}

    foreach ($p in @($raw.profiles_raw)) {
        if (-not $p) { continue }
        $sidStr  = [string]$p.SID
        $acctType= script:GetSidAccountType $sidStr $machineSIDPrefix
        $domain  = script:GetSidDomain $acctType $machineName $domainName
        $sidMeta = script:GetSidMetadata $sidStr
        $isLoaded= $false
        try { $isLoaded = [bool](([int]$p.State) -band 1) } catch {}

        $fl = script:ComputeFirstLogonConfidence `
            $p.PFRaw $p.PFAvail $p.NTRaw $p.NTAvail $p.RKRaw $p.RKAvail

        $hasLocal = $localAccountMap.ContainsKey($sidStr)
        $localDis = if ($hasLocal) { $localAccountMap[$sidStr].Disabled } else { $null }

        $userMap[$sidStr] = @{
            SID             = $sidStr
            Username        = $p.Username
            Domain          = $domain
            AccountType     = $acctType
            SIDMetadata     = $sidMeta
            HasLocalAccount = $hasLocal
            LocalDisabled   = $localDis
            FirstLogon      = @{
                UTC           = $fl.UTC
                Confidence    = $fl.Confidence
                ProfileFolder = @{ Value=$p.PFRaw; Available=[bool]$p.PFAvail }
                NTUserDat     = @{ Value=$p.NTRaw; Available=[bool]$p.NTAvail }
                RegistryKey   = @{
                    Value     = $p.RKRaw
                    Available = [bool]$p.RKAvail
                    KeyPath   = "$plRoot\$sidStr"
                }
                TimestampMismatch = $fl.TimestampMismatch
            }
            LastLogonUTC    = $p.LastUseRaw
            LastLogonSource = if ($p.LastUseRaw) { 'ProfileList LocalProfileLoadTime' } else { $null }
            ProfilePath      = $p.ProfilePath
            IsLoaded         = $isLoaded
            GroupMemberships = if ($p.Username -and $groupMap.ContainsKey($p.Username)) { $groupMap[$p.Username] } else { @() }
        }
    }

    # Add local accounts with no profile
    foreach ($u in @($raw.local_accounts_raw)) {
        if (-not $u) { continue }
        $sidStr = [string]$u.SID
        if ($userMap.ContainsKey($sidStr)) {
            $userMap[$sidStr].HasLocalAccount = $true
            $userMap[$sidStr].LocalDisabled   = [bool]$u.Disabled
            if ($u.Name -and $groupMap.ContainsKey($u.Name) -and $userMap[$sidStr].GroupMemberships.Count -eq 0) {
                $userMap[$sidStr].GroupMemberships = $groupMap[$u.Name]
            }
            continue
        }
        $acctType = script:GetSidAccountType $sidStr $machineSIDPrefix
        $domain   = script:GetSidDomain $acctType $machineName $domainName
        $sidMeta  = script:GetSidMetadata $sidStr
        $userMap[$sidStr] = @{
            SID             = $sidStr
            Username        = $u.Name
            Domain          = $domain
            AccountType     = $acctType
            SIDMetadata     = $sidMeta
            HasLocalAccount = $true
            LocalDisabled   = [bool]$u.Disabled
            FirstLogon      = @{
                UTC           = $null
                Confidence    = 'N/A'
                ProfileFolder = @{ Value=$null; Available=$false }
                NTUserDat     = @{ Value=$null; Available=$false }
                RegistryKey   = @{ Value=$null; Available=$false; KeyPath="$plRoot\$sidStr" }
                TimestampMismatch = $false
            }
            LastLogonUTC      = $null
            LastLogonSource   = $null
            ProfilePath       = $null
            IsLoaded          = $false
            GroupMemberships  = if ($u.Name -and $groupMap.ContainsKey($u.Name)) { $groupMap[$u.Name] } else { @() }
        }
    }

    $users = @($userMap.Values)

    # Domain accounts
    $domainAccounts = @()
    foreach ($u in @($raw.dc_domain_raw)) {
        if (-not $u) { continue }
        $domainAccounts += @{
            SamAccountName         = $u.SamAccountName
            DisplayName            = $u.DisplayName
            SID                    = $u.SID
            Enabled                = [bool]$u.Enabled
            WhenCreatedUTC         = $u.WhenCreated
            LastLogonTimestampUTC  = $u.LastLogonTimestamp
            LastLogonUTC           = $u.LastLogon
            PasswordLastSetUTC     = $u.PasswordLastSet
            LockedOut         = [bool]$u.LockedOut
            BadLogonCount     = [int]$u.BadLogonCount
            MemberOf          = @($u.MemberOf)
            Source            = $u.Source
        }
    }

    $isWmiRemote = ($Session -ne $null -and $Session -is [hashtable] -and $Session.Method -eq 'WMI')
    $base = if ($isWmiRemote) { 'wmi_remote' } else { 'registry+wmi' }
    $src = if ($raw.dc_source) { "$base+$($raw.dc_source)" } else { $base }

    return @{
        data = @{
            is_domain_controller = [bool]$raw.is_dc
            domain_name          = [string]$raw.domain_name
            machine_name         = [string]$raw.machine_name
            machine_sid          = [string]$raw.machine_sid
            users                = $users
            domain_accounts      = $domainAccounts
        }
        source = $src
        errors = $errors
    }
}

Export-ModuleMember -Function Invoke-Collector
