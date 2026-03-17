#Requires -Version 5.1
# ???????????????????????????????????????????????????????????????????????????????????????????????????????????????????????-
# ???  Quicker ??? T08_Users.ps1            ???
# ???  T19 Users structure,               ???
# ???  T20 First logon cross-check,       ???
# ???  T21 DC domain accounts,            ???
# ???  T22 Session logon types,           ???
# ???  T23 SID populated everywhere       ???
# ????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????
# ???  Inputs    : -JsonPath -HtmlPath    ???
# ???  Output    : @{ Passed=@();         ???
# ???               Failed=@(); Info=@() }???
# ???  PS compat : 5.1                    ???
# ????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????
[CmdletBinding()]
param(
    [string]$JsonPath = "",
    [string]$HtmlPath = ""
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

$script:passResults = @()
$script:failResults = @()
$script:infoResults = @()

function Add-R {
    param([string]$Id, [bool]$Pass, [string]$Summary, [string[]]$Details=@(), [bool]$IsInfo=$false)
    $obj = [PSCustomObject]@{Id=$Id;Pass=$Pass;InfoOnly=$IsInfo;Summary=$Summary;Details=$Details}
    if ($IsInfo)   { $script:infoResults += $obj }
    elseif ($Pass) { $script:passResults += $obj }
    else           { $script:failResults += $obj }
}

$jsonRaw = [System.IO.File]::ReadAllText($JsonPath, [System.Text.Encoding]::UTF8)
$data    = $jsonRaw | ConvertFrom-Json

# ---------------------------------------------------------------
# T19 ??? Users data structure
# ---------------------------------------------------------------
if (-not $data.Users) {
    Add-R "T19" $true "Users data structure (SKIP - no Users key in JSON)" @() $true
} else {
    $u      = $data.Users
    $misses = @()
    foreach ($key in @('sessions','profiles','local_accounts','group_members')) {
        if ($null -eq $u.$key) { $misses += "missing key: $key" }
    }
    if ($null -eq $u.is_domain_controller) { $misses += "missing: is_domain_controller" }
    if ($misses.Count -eq 0) {
        $sessCount = @($u.sessions).Count
        $profCount = @($u.profiles).Count
        $laCount   = @($u.local_accounts).Count
        $gmCount   = @($u.group_members).Count
        Add-R "T19" $true "Users data structure OK (sessions=$sessCount profiles=$profCount local=$laCount groups=$gmCount)"
    } else {
        Add-R "T19" $false "Users data structure missing keys ($($misses.Count))" $misses
    }
}

# ---------------------------------------------------------------
# T20 ??? Profile first logon cross-check
# ---------------------------------------------------------------
if (-not $data.Users -or -not $data.Users.profiles) {
    Add-R "T20" $true "Profile first logon cross-check (SKIP ??? no profiles)" @() $true
} else {
    $profiles  = @($data.Users.profiles)
    $validConf = @('HIGH','MEDIUM','LOW','TAMPERED')
    $t20Fails  = @()

    foreach ($p in $profiles) {
        if ($null -eq $p.FirstLogon) {
            $t20Fails += "SID=$($p.SID) Username=$($p.Username): missing FirstLogon block"
            continue
        }
        $fl = $p.FirstLogon
        foreach ($fkey in @('UTC','Confidence','ProfileFolder','NTUserDat','RegistryKey')) {
            if ($null -eq $fl.$fkey) {
                $t20Fails += "SID=$($p.SID): FirstLogon missing '$fkey'"
            }
        }
        if ($fl.Confidence -and $validConf -notcontains $fl.Confidence) {
            $t20Fails += "SID=$($p.SID): invalid Confidence '$($fl.Confidence)'"
        }
        if ($fl.TamperedFlag -eq $null) {
            $t20Fails += "SID=$($p.SID): FirstLogon missing TamperedFlag"
        }
    }

    if ($t20Fails.Count -eq 0) {
        Add-R "T20" $true "Profile first logon cross-check OK ($($profiles.Count) profiles, all have required fields)"
    } else {
        Add-R "T20" $false "Profile first logon cross-check: $($t20Fails.Count) issues" $t20Fails
    }
}

# ---------------------------------------------------------------
# T21 ??? DC domain accounts (if DC)
# ---------------------------------------------------------------
if (-not $data.Users) {
    Add-R "T21" $true "DC domain accounts (SKIP ??? no Users key)" @() $true
} else {
    $isDC = [bool]$data.Users.is_domain_controller
    $das  = @($data.Users.domain_accounts)

    if (-not $isDC) {
        if ($das.Count -eq 0) {
            Add-R "T21" $true "DC domain accounts OK (non-DC: domain_accounts empty as expected)"
        } else {
            Add-R "T21" $false "DC domain accounts: non-DC has $($das.Count) domain_accounts (expected 0)"
        }
    } else {
        if ($das.Count -eq 0) {
            Add-R "T21" $false "DC domain accounts: is_domain_controller=true but domain_accounts is empty"
        } else {
            $t21Fails = @()
            $validSrc = @('Get-ADUser','ADSI')
            foreach ($a in $das) {
                if (-not $a.SamAccountName) { $t21Fails += "SID=$($a.SID): missing SamAccountName" }
                if (-not $a.WhenCreatedUTC) { $t21Fails += "SamAccountName=$($a.SamAccountName): missing WhenCreatedUTC" }
                if ($a.Source -and $validSrc -notcontains $a.Source) {
                    $t21Fails += "SamAccountName=$($a.SamAccountName): invalid Source '$($a.Source)'"
                }
            }
            if ($t21Fails.Count -eq 0) {
                Add-R "T21" $true "DC domain accounts OK ($($das.Count) domain accounts, source=$($das[0].Source))"
            } else {
                Add-R "T21" $false "DC domain accounts: $($t21Fails.Count) issues" $t21Fails
            }
        }
    }
}

# ---------------------------------------------------------------
# T22 ??? Session logon types
# ---------------------------------------------------------------
if (-not $data.Users -or -not $data.Users.sessions) {
    Add-R "T22" $true "Session logon types (SKIP ??? no sessions)" @() $true
} else {
    $sessions = @($data.Users.sessions)
    if ($sessions.Count -eq 0) {
        Add-R "T22" $true "Session logon types (SKIP ??? sessions array empty)" @() $true
    } else {
        $t22Fails = @()
        foreach ($s in $sessions) {
            if ($null -eq $s.LogonType) {
                $t22Fails += "Username=$($s.Username): null LogonType"
            }
            if ($null -eq $s.LogonTypeName -or $s.LogonTypeName -eq '') {
                $t22Fails += "Username=$($s.Username) LogonType=$($s.LogonType): null/empty LogonTypeName"
            }
        }
        if ($t22Fails.Count -eq 0) {
            Add-R "T22" $true "Session logon types OK ($($sessions.Count) sessions, all have LogonType + LogonTypeName)"
        } else {
            Add-R "T22" $false "Session logon types: $($t22Fails.Count) issues" $t22Fails
        }
    }
}

# ---------------------------------------------------------------
# T23 ??? SID populated everywhere
# ---------------------------------------------------------------
if (-not $data.Users) {
    Add-R "T23" $true "SID populated (SKIP ??? no Users key)" @() $true
} else {
    $u      = $data.Users
    $warns  = @()
    $fails  = @()

    # Sessions: SID required when username is non-null
    foreach ($s in @($u.sessions)) {
        if ($s.Username -and -not $s.SID) {
            $warns += "Session Username=$($s.Username) LogonId=$($s.LogonId): null SID (warn)"
        }
    }

    # Profiles: SID always from ProfileList key name
    foreach ($p in @($u.profiles)) {
        if (-not $p.SID) { $fails += "Profile Username=$($p.Username): null SID" }
    }

    # Local accounts: SID from Win32_UserAccount
    foreach ($a in @($u.local_accounts)) {
        if (-not $a.SID) { $fails += "LocalAccount Name=$($a.Name): null SID" }
    }

    # Domain accounts (DC only)
    if ([bool]$u.is_domain_controller) {
        foreach ($a in @($u.domain_accounts)) {
            if (-not $a.SID) { $fails += "DomainAccount SamAccountName=$($a.SamAccountName): null SID" }
        }
    }

    # Group members: SID required (warn if null)
    foreach ($m in @($u.group_members)) {
        if (-not $m.MemberSID) {
            $warns += "GroupMember Group=$($m.GroupName) Member=$($m.MemberName): null MemberSID (warn)"
        }
    }

    $allDetails = $fails + $warns
    if ($fails.Count -eq 0) {
        $warnSuffix = if ($warns.Count -gt 0) { " [$($warns.Count) SID warn(s)]" } else { "" }
        Add-R "T23" $true "SID populated OK$warnSuffix" $warns
    } else {
        Add-R "T23" $false "SID populated: $($fails.Count) null SIDs where required" $allDetails
    }
}

return @{ Passed=$script:passResults; Failed=$script:failResults; Info=$script:infoResults }

