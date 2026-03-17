#Requires -Version 5.1
# =============================================
#   Quicker -- T08_Users.ps1
#   T19 Users data structure
#   T20 FirstLogon cross-check
#   T21 DC domain accounts
#   T22 SID populated everywhere
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

return @{ Passed=$script:passResults; Failed=$script:failResults; Info=$script:infoResults }
