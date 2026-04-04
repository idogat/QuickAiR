#Requires -Version 5.1
# =============================================
#   QuickAiR -- T08_Users.ps1
#   T19  Users data structure
#   T20  FirstLogon cross-check
#   T21  DC domain accounts
#   T22  SID populated everywhere
#   T23  GroupMemberships populated
#   T83  LastLogonSource consistency
#   T84  DC lastLogon fields (domain_accounts)
#   T85  DC MemberOf field
# =============================================
#   Inputs    : -JsonPath -HtmlPath
#   Output    : @{ Passed=@();
#                Failed=@(); Info=@() }
#   PS compat : 5.1
# =============================================
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

$jsonHostname   = $data.manifest.hostname
$localHostnames = @($env:COMPUTERNAME, 'localhost', '127.0.0.1')
$isLocalJson    = ($localHostnames -icontains $jsonHostname)

# ---------------------------------------------------------------
# T19 - Users data structure
# ---------------------------------------------------------------
if (-not $data.Users) {
    Add-R "T19" $true "Users data structure (SKIP - no Users key in JSON)" @() $true
} else {
    $u      = $data.Users
    $misses = @()
    if ($null -eq $u.users)                { $misses += "missing key: users" }
    if ($null -eq $u.is_domain_controller) { $misses += "missing: is_domain_controller" }
    if ($null -eq $u.domain_name)          { $misses += "missing: domain_name" }
    if ($null -eq $u.machine_name)         { $misses += "missing: machine_name" }

    if ([bool]$u.is_domain_controller -and $null -eq $u.domain_accounts) {
        $misses += "DC: missing key: domain_accounts"
    }

    if ($misses.Count -eq 0) {
        $userCount = @($u.users).Count
        $daCount   = @($u.domain_accounts).Count
        Add-R "T19" $true "Users data structure OK (users=$userCount domain_accounts=$daCount is_dc=$($u.is_domain_controller))"
    } else {
        Add-R "T19" $false "Users data structure missing fields ($($misses.Count))" $misses
    }
}

# ---------------------------------------------------------------
# T20 - FirstLogon cross-check
# ---------------------------------------------------------------
if (-not $data.Users -or -not $data.Users.users) {
    Add-R "T20" $true "FirstLogon cross-check (SKIP - no users array)" @() $true
} else {
    $users     = @($data.Users.users)
    $validConf = @('HIGH','MEDIUM','LOW','?','N/A')
    $t20Fails  = @()

    foreach ($user in $users) {
        $sidLabel = "SID=$($user.SID)"
        if ($null -eq $user.FirstLogon) {
            $t20Fails += "$sidLabel Username=$($user.Username): missing FirstLogon block"
            continue
        }
        $fl = $user.FirstLogon
        foreach ($fkey in @('Confidence','ProfileFolder','NTUserDat','RegistryKey')) {
            if ($null -eq $fl.$fkey) {
                $t20Fails += "$sidLabel FirstLogon missing '$fkey'"
            }
        }
        # UTC may be null when Confidence is N/A (no profile, never logged on)
        if ($null -eq $fl.UTC -and $fl.Confidence -ne 'N/A') {
            $t20Fails += "$sidLabel FirstLogon.UTC null but Confidence=$($fl.Confidence)"
        }
        if ($fl.Confidence -and $validConf -notcontains $fl.Confidence) {
            $t20Fails += "$sidLabel invalid Confidence '$($fl.Confidence)'"
        }
        if ($null -eq $fl.TimestampMismatch) {
            $t20Fails += "$sidLabel FirstLogon missing TimestampMismatch"
        }
        foreach ($src in @('ProfileFolder','NTUserDat')) {
            $sub = $fl.$src
            if ($sub -and $null -eq $sub.Available) {
                $t20Fails += "$sidLabel FirstLogon.$src missing Available"
            }
        }
        $rk = $fl.RegistryKey
        if ($rk) {
            if ($null -eq $rk.Available) { $t20Fails += "$sidLabel FirstLogon.RegistryKey missing Available" }
            if ($null -eq $rk.KeyPath)   { $t20Fails += "$sidLabel FirstLogon.RegistryKey missing KeyPath" }
        }
    }

    if ($t20Fails.Count -eq 0) {
        Add-R "T20" $true "FirstLogon cross-check OK ($($users.Count) users, all have required fields)"
    } else {
        Add-R "T20" $false "FirstLogon cross-check: $($t20Fails.Count) issues" $t20Fails
    }
}

# ---------------------------------------------------------------
# T21 - DC domain accounts
# ---------------------------------------------------------------
if (-not $data.Users) {
    Add-R "T21" $true "DC domain accounts (SKIP - no Users key)" @() $true
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
                if (-not $a.SID)            { $t21Fails += "SamAccountName=$($a.SamAccountName): missing SID" }
                if (-not $a.SamAccountName) { $t21Fails += "SID=$($a.SID): missing SamAccountName" }
                if (-not $a.WhenCreatedUTC) { $t21Fails += "SamAccountName=$($a.SamAccountName): missing WhenCreatedUTC" }
                if ($a.Source -and $validSrc -notcontains $a.Source) {
                    $t21Fails += "SamAccountName=$($a.SamAccountName): invalid Source '$($a.Source)'"
                }
            }
            if ($t21Fails.Count -eq 0) {
                Add-R "T21" $true "DC domain accounts OK ($($das.Count) accounts, source=$($das[0].Source))"
            } else {
                Add-R "T21" $false "DC domain accounts: $($t21Fails.Count) issues" $t21Fails
            }
        }
    }
}

# ---------------------------------------------------------------
# T22 - SID populated everywhere
# ---------------------------------------------------------------
if (-not $data.Users) {
    Add-R "T22" $true "SID populated (SKIP - no Users key)" @() $true
} else {
    $u     = $data.Users
    $fails = @()

    foreach ($user in @($u.users)) {
        if (-not $user.SID) { $fails += "User Username=$($user.Username): null SID" }
    }

    if ([bool]$u.is_domain_controller) {
        foreach ($a in @($u.domain_accounts)) {
            if (-not $a.SID) { $fails += "DomainAccount SamAccountName=$($a.SamAccountName): null SID" }
        }
    }

    if ($fails.Count -eq 0) {
        Add-R "T22" $true "SID populated OK"
    } else {
        Add-R "T22" $false "SID populated: $($fails.Count) null SIDs" $fails
    }
}

# ---------------------------------------------------------------
# T23 - GroupMemberships populated
# ---------------------------------------------------------------
if (-not $data.Users -or -not $data.Users.users) {
    Add-R "T23" $true "GroupMemberships populated (SKIP - no Users key or users array)" @() $true
} else {
    $users    = @($data.Users.users)
    $t23Fails = @()

    # Every user entry must have a GroupMemberships key (array, can be empty)
    foreach ($user in $users) {
        $sidLabel = "SID=$($user.SID) Username=$($user.Username)"
        $props = $user.PSObject.Properties.Name
        if ($props -notcontains 'GroupMemberships') {
            $t23Fails += "$sidLabel missing GroupMemberships key"
            if ($t23Fails.Count -ge 25) { break }
            continue
        }
        # Each entry in GroupMemberships must be a non-empty string (empty array is valid)
        # PS serializes empty @() as {} which deserializes as PSCustomObject -- skip these
        if ($null -eq $user.GroupMemberships -or $user.GroupMemberships -is [PSCustomObject]) { continue }
        $gm = @($user.GroupMemberships)
        for ($i = 0; $i -lt $gm.Count; $i++) {
            $entry = $gm[$i]
            if ($null -eq $entry) { continue }
            if ([string]::IsNullOrEmpty([string]$entry)) {
                $t23Fails += "$sidLabel GroupMemberships[$i] is empty string"
                if ($t23Fails.Count -ge 25) { break }
            }
        }
        if ($t23Fails.Count -ge 25) { break }
    }

    # On localhost: at least one user should have non-empty GroupMemberships (admin account)
    if ($t23Fails.Count -eq 0 -and $isLocalJson) {
        $usersWithGroups = @($users | Where-Object { $_.GroupMemberships -and $_.GroupMemberships -isnot [PSCustomObject] -and @($_.GroupMemberships).Count -gt 0 })
        if ($usersWithGroups.Count -eq 0) {
            $t23Fails += "localhost: no user has any GroupMemberships - expected at least the Administrators group member"
        }
    }

    if ($t23Fails.Count -eq 0) {
        $usersWithGroups = @($users | Where-Object { $_.GroupMemberships -and $_.GroupMemberships -isnot [PSCustomObject] -and @($_.GroupMemberships).Count -gt 0 })
        Add-R "T23" $true "GroupMemberships populated OK ($($users.Count) users, $($usersWithGroups.Count) have memberships, all entries are non-empty strings)"
    } else {
        Add-R "T23" $false "GroupMemberships: $($t23Fails.Count) issues" ($t23Fails | Select-Object -First 25)
    }
}

# ---------------------------------------------------------------
# T83 - LastLogonSource consistency
# For users where LastLogonUTC is $null, LastLogonSource must also be $null.
# For users where LastLogonUTC is not $null, LastLogonSource must be a non-empty string.
# ---------------------------------------------------------------
if (-not $data.Users -or -not $data.Users.users) {
    Add-R "T83" $true "LastLogonSource consistency (SKIP - no Users key or users array)" @() $true
} else {
    $users    = @($data.Users.users)
    $t83Fails = @()

    foreach ($user in $users) {
        $sidLabel  = "SID=$($user.SID) Username=$($user.Username)"
        $llu       = $user.LastLogonUTC
        $lls       = $user.LastLogonSource
        $props     = $user.PSObject.Properties.Name

        if ($props -notcontains 'LastLogonUTC') {
            $t83Fails += "$sidLabel missing LastLogonUTC key"
            if ($t83Fails.Count -ge 25) { break }
            continue
        }
        if ($props -notcontains 'LastLogonSource') {
            $t83Fails += "$sidLabel missing LastLogonSource key"
            if ($t83Fails.Count -ge 25) { break }
            continue
        }

        if ($null -eq $llu -or $llu -eq '') {
            # LastLogonUTC is null: LastLogonSource must also be null
            if ($null -ne $lls -and $lls -ne '') {
                $t83Fails += "$sidLabel LastLogonUTC is null but LastLogonSource='$lls' (expected null)"
            }
        } else {
            # LastLogonUTC is set: LastLogonSource must be a non-empty string
            if ($null -eq $lls -or $lls -eq '') {
                $t83Fails += "$sidLabel LastLogonUTC='$llu' but LastLogonSource is null/empty"
            }
        }
        if ($t83Fails.Count -ge 25) { break }
    }

    if ($t83Fails.Count -eq 0) {
        Add-R "T83" $true "LastLogonSource consistency OK ($($users.Count) users checked)"
    } else {
        Add-R "T83" $false "LastLogonSource consistency: $($t83Fails.Count) violations" $t83Fails
    }
}

# ---------------------------------------------------------------
# T84 - DC lastLogon fields (domain_accounts)
# If is_domain_controller is true: each domain_account must have
# both LastLogonUTC and LastLogonTimestampUTC keys (values can be $null).
# If is_domain_controller is false: skip (T21 already validates this case).
# ---------------------------------------------------------------
if (-not $data.Users) {
    Add-R "T84" $true "DC lastLogon fields (SKIP - no Users key)" @() $true
} else {
    $isDC = [bool]$data.Users.is_domain_controller
    if (-not $isDC) {
        Add-R "T84" $true "DC lastLogon fields (SKIP - not a domain controller)" @() $true
    } else {
        $das      = @($data.Users.domain_accounts)
        if ($das.Count -eq 0) {
            Add-R "T84" $true "DC lastLogon fields (SKIP - no domain_accounts to check)" @() $true
        } else {
            $t84Fails = @()
            foreach ($a in $das) {
                $label = "SamAccountName=$($a.SamAccountName)"
                $props = $a.PSObject.Properties.Name
                if ($props -notcontains 'LastLogonUTC') {
                    $t84Fails += "$label missing LastLogonUTC key"
                }
                if ($props -notcontains 'LastLogonTimestampUTC') {
                    $t84Fails += "$label missing LastLogonTimestampUTC key"
                }
                if ($t84Fails.Count -ge 25) { break }
            }
            if ($t84Fails.Count -eq 0) {
                Add-R "T84" $true "DC lastLogon fields OK ($($das.Count) domain_accounts - all have LastLogonUTC and LastLogonTimestampUTC keys)"
            } else {
                Add-R "T84" $false "DC lastLogon fields: $($t84Fails.Count) missing keys" $t84Fails
            }
        }
    }
}

# ---------------------------------------------------------------
# T85 - DC MemberOf field
# If is_domain_controller is true: each domain_account must have
# a MemberOf key (array, can be empty).
# If is_domain_controller is false: skip.
# ---------------------------------------------------------------
if (-not $data.Users) {
    Add-R "T85" $true "DC MemberOf field (SKIP - no Users key)" @() $true
} else {
    $isDC = [bool]$data.Users.is_domain_controller
    if (-not $isDC) {
        Add-R "T85" $true "DC MemberOf field (SKIP - not a domain controller)" @() $true
    } else {
        $das      = @($data.Users.domain_accounts)
        if ($das.Count -eq 0) {
            Add-R "T85" $true "DC MemberOf field (SKIP - no domain_accounts to check)" @() $true
        } else {
            $t85Fails = @()
            foreach ($a in $das) {
                $label = "SamAccountName=$($a.SamAccountName)"
                $props = $a.PSObject.Properties.Name
                if ($props -notcontains 'MemberOf') {
                    $t85Fails += "$label missing MemberOf key"
                    if ($t85Fails.Count -ge 25) { break }
                    continue
                }
                # MemberOf must be array-compatible (each entry must be non-empty string when present)
                $mo = @($a.MemberOf)
                for ($i = 0; $i -lt $mo.Count; $i++) {
                    $entry = $mo[$i]
                    if ([string]::IsNullOrEmpty([string]$entry)) {
                        $t85Fails += "$label MemberOf[$i] is null or empty string"
                        if ($t85Fails.Count -ge 25) { break }
                    }
                }
                if ($t85Fails.Count -ge 25) { break }
            }
            if ($t85Fails.Count -eq 0) {
                Add-R "T85" $true "DC MemberOf field OK ($($das.Count) domain_accounts - all have MemberOf key)"
            } else {
                Add-R "T85" $false "DC MemberOf field: $($t85Fails.Count) issues" $t85Fails
            }
        }
    }
}

return @{ Passed=$script:passResults; Failed=$script:failResults; Info=$script:infoResults }
