#Requires -Version 5.1
# ╔══════════════════════════════════════╗
# ║  Quicker — Users.psm1               ║
# ║  User account and session collection║
# ╠══════════════════════════════════════╣
# ║  Exports  : Invoke-Collector        ║
# ║  Output   : @{ data=@{             ║
# ║               sessions=[],         ║
# ║               profiles=[],         ║
# ║               local_accounts=[],   ║
# ║               domain_accounts=[],  ║
# ║               group_members=[]     ║
# ║             }; source="";errors=[]}║
# ║  PS compat: 2.0+ (target-side)     ║
# ║  Version  : 1.3                    ║
# ╚══════════════════════════════════════╝

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# ── PS 2.0-compatible scriptblock — runs ON the target ──────────────────────
$script:USERS_SB = {
    $r = @{
        is_dc            = $false
        domain_name      = ''
        machine_name     = ''
        machine_sid      = $null
        sessions_raw     = @()
        profiles_raw     = @()
        local_accounts_raw = @()
        group_members_raw= @()
        dc_domain_raw    = @()
        dc_source        = $null
        errors           = @()
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

    # ── COLLECT 1: Logon sessions ────────────────────────────────────────────
    try {
        $wmiSessions = Get-WmiObject Win32_LogonSession
        $wmiLoggedOn = Get-WmiObject Win32_LoggedOnUser

        $userMap = @{}
        foreach ($lo in $wmiLoggedOn) {
            $logonId = $null; $uName = $null; $uDomain = $null
            if ($lo.Dependent  -match 'LogonId="([^"]+)"') { $logonId = $Matches[1] }
            if ($lo.Antecedent -match 'Name="([^"]+)"')    { $uName   = $Matches[1] }
            if ($lo.Antecedent -match 'Domain="([^"]+)"')  { $uDomain = $Matches[1] }
            if ($logonId) { $userMap[$logonId] = @{ N=$uName; D=$uDomain } }
        }

        foreach ($s in $wmiSessions) {
            $lid = [string]$s.LogonId
            $ui  = if ($userMap.ContainsKey($lid)) { $userMap[$lid] } else { @{N=$null;D=$null} }
            $un  = $ui.N; $ud = $ui.D
            $sid = $null
            if ($un -and $ud) {
                try {
                    $sid = (New-Object System.Security.Principal.NTAccount($ud,$un)).Translate(
                        [System.Security.Principal.SecurityIdentifier]).Value
                } catch {
                    try {
                        $wua = Get-WmiObject Win32_UserAccount `
                            -Filter "Name='$un' AND Domain='$ud'" | Select-Object -First 1
                        if ($wua) { $sid = $wua.SID }
                    } catch {}
                }
            }
            $r.sessions_raw += @{
                LogonId            = $lid
                LogonType          = [int]$s.LogonType
                StartTime_raw      = [string]$s.StartTime
                UserName           = $un
                UserDomain         = $ud
                SID                = $sid
                IsLocal            = ($ud -and ($ud -ieq $machineName))
                HasActiveProcesses = $false
                IsReallyActive     = $false
            }
        }

        # Cross-check sessions against running processes
        $activeSessionIds = @{}
        try {
            Get-WmiObject Win32_Process | ForEach-Object {
                $activeSessionIds[[string]$_.SessionId] = $true
            }
        } catch {}
        foreach ($s in $r.sessions_raw) {
            $hasProc = $activeSessionIds.ContainsKey([string]$s.LogonId)
            $isSvc   = ($s.LogonType -eq 4 -or $s.LogonType -eq 5)
            $s.HasActiveProcesses = $hasProc
            $s.IsReallyActive     = $hasProc -or $isSvc
        }
    } catch { $r.errors += "Sessions: $($_.Exception.Message)" }

    # ── Registry LastWrite P/Invoke helper (works on all .NET versions) ─────
    $_rkHelper = $false
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
'@ -ErrorAction Stop } catch {}
    try { [void][RegLwt]; $_rkHelper = $true } catch {}

    # ── COLLECT 2: User profiles ─────────────────────────────────────────────
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
                            $lastUseRaw = [DateTime]::FromFileTimeUtc($ft).ToString('o')
                        }
                    }
                } catch {}

                $sk.Close()

                # Profile folder creation time
                $pfRaw = $null; $pfAvail = $false
                try {
                    if ($profilePath -and (Test-Path $profilePath)) {
                        $pfRaw   = (Get-Item $profilePath -ErrorAction Stop).CreationTime.ToString('o')
                        $pfAvail = $true
                    }
                } catch {}

                # NTUSER.DAT creation time (-Force required: file is hidden/system)
                $ntRaw = $null; $ntAvail = $false
                try {
                    if ($profilePath) {
                        $ntPath = Join-Path $profilePath "NTUSER.DAT"
                        $ntItem = Get-Item $ntPath -Force -ErrorAction Stop
                        $ntRaw   = $ntItem.CreationTime.ToString('o')
                        $ntAvail = $true
                    }
                } catch {}

                # Registry key LastWrite time (Get-Item; P/Invoke fallback for older .NET)
                $rkRaw = $null; $rkAvail = $false
                try {
                    $rki = Get-Item "HKLM:\$plRoot\$sidStr" -ErrorAction Stop
                    $lwt = $rki.LastWriteTime
                    if ($lwt -ne $null -and $lwt -gt [DateTime]::MinValue) {
                        $rkRaw   = $lwt.ToUniversalTime().ToString('o')
                        $rkAvail = $true
                    }
                } catch {}
                if (-not $rkAvail -and $_rkHelper) {
                    try {
                        $ft = [RegLwt]::GetLwt("$plRoot\$sidStr")
                        if ($ft -gt 0) {
                            $rkRaw   = [DateTime]::FromFileTimeUtc($ft).ToString('o')
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

    # ── COLLECT 3: Local accounts ────────────────────────────────────────────
    try {
        $profileSIDSet = @{}
        foreach ($p in $r.profiles_raw) { $profileSIDSet[[string]$p.SID] = $p.LastUseRaw }

        $localUsers = Get-WmiObject Win32_UserAccount -Filter "LocalAccount=True"
        foreach ($u in $localUsers) {
            $sidStr    = [string]$u.SID
            $hasProf   = $profileSIDSet.ContainsKey($sidStr)
            $lastLogon = if ($hasProf) { $profileSIDSet[$sidStr] } else { $null }
            $r.local_accounts_raw += @{
                Name             = [string]$u.Name
                SID              = $sidStr
                Disabled         = [bool]$u.Disabled
                PasswordRequired = [bool]$u.PasswordRequired
                PasswordExpires  = -not [bool]$u.PasswordChangeable
                AccountType      = [int]$u.AccountType
                Description      = [string]$u.Description
                HasProfile       = $hasProf
                LastLogonUTC     = $lastLogon
            }
        }
    } catch { $r.errors += "LocalAccounts: $($_.Exception.Message)" }

    # ── COLLECT 4: Domain accounts (DC only) ─────────────────────────────────
    if ($r.is_dc) {
        try {
            try {
                Import-Module ActiveDirectory -ErrorAction Stop
                $adUsers = Get-ADUser -Filter * -Properties `
                    Created,LastLogonDate,PasswordLastSet,PasswordNeverExpires,
                    Enabled,DistinguishedName,BadLogonCount,LockedOut
                $r.dc_source = 'Get-ADUser'
                foreach ($u in $adUsers) {
                    $r.dc_domain_raw += @{
                        SamAccountName      = [string]$u.SamAccountName
                        DisplayName         = [string]$u.Name
                        SID                 = if ($u.SID) { $u.SID.Value } else { $null }
                        Enabled             = [bool]$u.Enabled
                        WhenCreated         = if ($u.Created)       { $u.Created.ToUniversalTime().ToString('o') }       else { $null }
                        LastLogon           = if ($u.LastLogonDate)  { $u.LastLogonDate.ToUniversalTime().ToString('o') } else { $null }
                        PasswordLastSet     = if ($u.PasswordLastSet){ $u.PasswordLastSet.ToUniversalTime().ToString('o')} else { $null }
                        PasswordNeverExpires= [bool]$u.PasswordNeverExpires
                        LockedOut           = [bool]$u.LockedOut
                        BadLogonCount       = [int]$u.BadLogonCount
                        DistinguishedName   = [string]$u.DistinguishedName
                        Source              = 'Get-ADUser'
                    }
                }
            } catch {
                # ADSI fallback — PS 2.0 / no RSAT
                $r.dc_source = 'ADSI'
                $searcher = New-Object System.DirectoryServices.DirectorySearcher
                $searcher.Filter   = "(&(objectClass=user)(objectCategory=person))"
                $searcher.PageSize = 1000
                $searcher.PropertiesToLoad.AddRange(@(
                    "samaccountname","displayname","objectsid","whencreated",
                    "lastlogontimestamp","pwdlastset","useraccountcontrol",
                    "distinguishedname","badpwdcount","lockouttime"
                ))
                $results = $searcher.FindAll()
                foreach ($entry in $results) {
                    $p = $entry.Properties
                    $sidVal = $null
                    try {
                        $sidVal = (New-Object System.Security.Principal.SecurityIdentifier(
                            [byte[]]$p["objectsid"][0], 0)).Value
                    } catch {}
                    $wc = $null
                    try { if ($p["whencreated"].Count -gt 0) {
                        $wc = ([datetime]$p["whencreated"][0]).ToUniversalTime().ToString('o') } } catch {}
                    $ll = $null
                    try { $llFt = [Int64]$p["lastlogontimestamp"][0]
                        if ($llFt -gt 0) { $ll = [DateTime]::FromFileTime($llFt).ToUniversalTime().ToString('o') } } catch {}
                    $pls = $null
                    try { $plsFt = [Int64]$p["pwdlastset"][0]
                        if ($plsFt -gt 0) { $pls = [DateTime]::FromFileTime($plsFt).ToUniversalTime().ToString('o') } } catch {}
                    $uac = 0
                    try { $uac = [int]$p["useraccountcontrol"][0] } catch {}
                    $locked = $false
                    try { $locked = ([Int64]$p["lockouttime"][0]) -gt 0 } catch {}
                    $bpc = 0
                    try { $bpc = [int]$p["badpwdcount"][0] } catch {}
                    $r.dc_domain_raw += @{
                        SamAccountName      = if ($p["samaccountname"].Count -gt 0) { [string]$p["samaccountname"][0] } else { $null }
                        DisplayName         = if ($p["displayname"].Count -gt 0)    { [string]$p["displayname"][0] }    else { $null }
                        SID                 = $sidVal
                        Enabled             = -not [bool]($uac -band 2)
                        WhenCreated         = $wc
                        LastLogon           = $ll
                        PasswordLastSet     = $pls
                        PasswordNeverExpires= [bool]($uac -band 0x10000)
                        LockedOut           = $locked
                        BadLogonCount       = $bpc
                        DistinguishedName   = if ($p["distinguishedname"].Count -gt 0) { [string]$p["distinguishedname"][0] } else { $null }
                        Source              = 'ADSI'
                    }
                }
                try { $results.Dispose() } catch {}
            }
        } catch { $r.errors += "DomainAccounts: $($_.Exception.Message)" }
    }

    # ── COLLECT 5: Group membership ───────────────────────────────────────────
    try {
        $TARGET_GROUPS = @('Administrators','Remote Desktop Users',
                           'Remote Management Users','Backup Operators','Power Users')
        $wmiGU     = Get-WmiObject Win32_GroupUser
        $wmiGroups = Get-WmiObject Win32_Group -Filter "LocalAccount=True"
        $validGrps = @{}
        foreach ($g in $wmiGroups) {
            foreach ($tg in $TARGET_GROUPS) { if ($g.Name -ieq $tg) { $validGrps[$g.Name] = $true } }
        }

        foreach ($gu in $wmiGU) {
            $grpName = $null; $memName = $null; $memDomain = $null
            if ($gu.GroupComponent -match 'Name="([^"]+)"')  { $grpName   = $Matches[1] }
            if (-not $validGrps.ContainsKey($grpName))       { continue }
            if ($gu.PartComponent  -match 'Name="([^"]+)"')  { $memName   = $Matches[1] }
            if ($gu.PartComponent  -match 'Domain="([^"]+)"'){ $memDomain = $Matches[1] }

            $memSID = $null
            if ($memName -and $memDomain) {
                try {
                    $memSID = (New-Object System.Security.Principal.NTAccount($memDomain,$memName)).Translate(
                        [System.Security.Principal.SecurityIdentifier]).Value
                } catch {
                    try {
                        $wua = Get-WmiObject Win32_UserAccount `
                            -Filter "Name='$memName' AND Domain='$memDomain'" | Select-Object -First 1
                        if ($wua) { $memSID = $wua.SID }
                    } catch {}
                }
            }
            $r.group_members_raw += @{
                GroupName    = $grpName
                MemberName   = $memName
                MemberDomain = $memDomain
                MemberSID    = $memSID
                IsLocal      = ($memDomain -and ($memDomain -ieq $machineName))
            }
        }
    } catch { $r.errors += "GroupMembers: $($_.Exception.Message)" }

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
    $note              = ''

    function _agree24($a,$b) {
        if (-not $a -or -not $b) { return $false }
        return [Math]::Abs(($a - $b).TotalHours) -le 24
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
            else {
                $confidence = '?'; $timestampMismatch = $true
                $note = "Profile folder: $pfUTC`nNTUSER.DAT: $ntUTC"
                $firstUTC = $pfUTC
            }
        } elseif ($available -contains 'PF' -and $available -contains 'RK') {
            if (_agree24 $pfDt $rkDt) { $confidence = 'MEDIUM'; $firstUTC = $pfUTC }
            else {
                $confidence = '?'; $timestampMismatch = $true
                $note = "Profile folder: $pfUTC`nProfileList key: $rkUTC"
                $firstUTC = $pfUTC
            }
        } else {
            if (_agree24 $ntDt $rkDt) { $confidence = 'MEDIUM'; $firstUTC = $ntUTC }
            else {
                $confidence = '?'; $timestampMismatch = $true
                $note = "NTUSER.DAT: $ntUTC`nProfileList key: $rkUTC"
                $firstUTC = $ntUTC
            }
        }
    } else {
        # 3 sources
        $pfDt = script:IsoToDate $pfUTC
        $ntDt = script:IsoToDate $ntUTC
        $rkDt = script:IsoToDate $rkUTC

        $pfNtAgree = _agree24 $pfDt $ntDt
        $pfRkAgree = _agree24 $pfDt $rkDt
        $ntRkAgree = _agree24 $ntDt $rkDt

        if ($pfNtAgree -and $pfRkAgree) {
            $confidence = 'HIGH'; $firstUTC = $pfUTC
        } elseif ($pfNtAgree -or $pfRkAgree -or $ntRkAgree) {
            $confidence = 'MEDIUM'
            if ($pfNtAgree)     { $firstUTC = $pfUTC; $note = 'RegistryKey differs' }
            elseif ($pfRkAgree) { $firstUTC = $pfUTC; $note = 'NTUserDat differs' }
            else                { $firstUTC = $ntUTC; $note = 'ProfileFolder differs' }
        } else {
            $confidence = '?'; $timestampMismatch = $true
            $note = "Profile folder: $pfUTC`nNTUSER.DAT: $ntUTC`nProfileList key: $rkUTC"
            $firstUTC = $pfUTC
        }
    }

    return @{
        UTC               = $firstUTC
        Confidence        = $confidence
        TimestampMismatch = $timestampMismatch
        TamperedNote      = $note
    }
}

function script:SidAccountType($sidStr, $machineSIDPrefix) {
    if (-not $sidStr) { return 'Unknown' }
    if ($sidStr -eq 'S-1-5-18')  { return 'SYSTEM' }
    if ($sidStr -eq 'S-1-5-19')  { return 'LocalService' }
    if ($sidStr -eq 'S-1-5-20')  { return 'NetworkService' }
    if ($machineSIDPrefix -and $sidStr -match ('^' + [regex]::Escape($machineSIDPrefix) + '-\d+$')) {
        return 'Local'
    }
    if ($sidStr -match '^S-1-5-21-') { return 'Domain' }
    return 'Unknown'
}

# ── Invoke-Collector ─────────────────────────────────────────────────────────
function Invoke-Collector {
    param($Session, $TargetPSVersion, $TargetCapabilities)

    $errors = @()
    $raw    = $null

    try {
        if ($Session) {
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
                sessions=@(); profiles=@(); local_accounts=@(); domain_accounts=@(); group_members=@()
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

    $logonTypeMap = @{
        2='Interactive'; 3='Network'; 4='Batch'; 5='Service'
        7='Unlock'; 10='RemoteInteractive (RDP)'; 11='CachedInteractive'
    }

    # Sessions
    $sessions = @()
    foreach ($s in @($raw.sessions_raw)) {
        if (-not $s) { continue }
        $lt = [int]$s.LogonType
        $typeName = if ($logonTypeMap.ContainsKey($lt)) { $logonTypeMap[$lt] } else { "Type$lt" }
        $sessions += @{
            Username           = $s.UserName
            Domain             = $s.UserDomain
            LogonId            = $s.LogonId
            LogonType          = $lt
            LogonTypeName      = $typeName
            LogonTimeUTC       = ConvertTo-UtcIso -Value $s.StartTime_raw
            LogonTimeLocal     = $s.StartTime_raw
            IsLocal            = [bool]$s.IsLocal
            SID                = $s.SID
            HasActiveProcesses = [bool]$s.HasActiveProcesses
            IsReallyActive     = [bool]$s.IsReallyActive
            Source             = 'Win32_LogonSession+Win32_LoggedOnUser'
        }
    }

    # Profiles
    $profiles = @()
    foreach ($p in @($raw.profiles_raw)) {
        if (-not $p) { continue }
        $sidStr  = [string]$p.SID
        $acctType= script:SidAccountType $sidStr $machineSIDPrefix
        $isLoaded= $false
        try { $isLoaded = [bool](([int]$p.State) -band 1) } catch {}
        $fl = script:ComputeFirstLogonConfidence `
            $p.PFRaw $p.PFAvail $p.NTRaw $p.NTAvail $p.RKRaw $p.RKAvail
        $profiles += @{
            SID            = $sidStr
            Username       = $p.Username
            AccountType    = $acctType
            ProfilePath    = $p.ProfilePath
            LastUseTimeUTC = $p.LastUseRaw
            IsLoaded       = $isLoaded
            FirstLogon     = @{
                UTC          = $fl.UTC
                Confidence   = $fl.Confidence
                ProfileFolder= @{ Value=$p.PFRaw; UTC=$p.PFRaw; Available=[bool]$p.PFAvail }
                NTUserDat    = @{ Value=$p.NTRaw; UTC=$p.NTRaw; Available=[bool]$p.NTAvail }
                RegistryKey  = @{ Value=$p.RKRaw; UTC=$p.RKRaw; Available=[bool]$p.RKAvail }
                TimestampMismatch = $fl.TimestampMismatch
                TamperedNote      = $fl.TamperedNote
            }
        }
    }

    # Local accounts
    $localAccounts = @()
    foreach ($u in @($raw.local_accounts_raw)) {
        if (-not $u) { continue }
        $localAccounts += @{
            Name             = $u.Name
            SID              = $u.SID
            Disabled         = [bool]$u.Disabled
            PasswordRequired = [bool]$u.PasswordRequired
            PasswordExpires  = [bool]$u.PasswordExpires
            AccountType      = $u.AccountType
            Description      = $u.Description
            HasProfile       = [bool]$u.HasProfile
            LastLogonUTC     = $u.LastLogonUTC
            Source           = 'Win32_UserAccount'
        }
    }

    # Domain accounts
    $domainAccounts = @()
    foreach ($u in @($raw.dc_domain_raw)) {
        if (-not $u) { continue }
        $domainAccounts += @{
            SamAccountName      = $u.SamAccountName
            DisplayName         = $u.DisplayName
            SID                 = $u.SID
            Enabled             = [bool]$u.Enabled
            WhenCreatedUTC      = $u.WhenCreated
            WhenCreatedLocal    = $u.WhenCreated
            LastLogonUTC        = $u.LastLogon
            LastLogonLocal      = $u.LastLogon
            PasswordLastSetUTC  = $u.PasswordLastSet
            PasswordNeverExpires= [bool]$u.PasswordNeverExpires
            LockedOut           = [bool]$u.LockedOut
            BadLogonCount       = [int]$u.BadLogonCount
            DistinguishedName   = $u.DistinguishedName
            Source              = $u.Source
        }
    }

    # Group members
    $groupMembers = @()
    foreach ($m in @($raw.group_members_raw)) {
        if (-not $m) { continue }
        $groupMembers += @{
            GroupName    = $m.GroupName
            MemberName   = $m.MemberName
            MemberDomain = $m.MemberDomain
            MemberSID    = $m.MemberSID
            IsLocal      = [bool]$m.IsLocal
            Source       = 'Win32_GroupUser'
        }
    }

    $src = if ($raw.dc_source) { "WMI+$($raw.dc_source)" } else { 'WMI' }

    return @{
        data = @{
            is_domain_controller = [bool]$raw.is_dc
            domain_name          = [string]$raw.domain_name
            machine_name         = [string]$raw.machine_name
            machine_sid          = [string]$raw.machine_sid
            sessions             = $sessions
            profiles             = $profiles
            local_accounts       = $localAccounts
            domain_accounts      = $domainAccounts
            group_members        = $groupMembers
        }
        source = $src
        errors = $errors
    }
}

Export-ModuleMember -Function Invoke-Collector
