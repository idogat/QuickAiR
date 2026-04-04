#Requires -Version 5.1
# ╔══════════════════════════════════════╗
# ║  QuickAiR -- T05_MultiNIC.ps1         ║
# ║  T12 multi-NIC interface assignment ║
# ║  verification                       ║
# ╠══════════════════════════════════════╣
# ║  Inputs    : -JsonPath -HtmlPath    ║
# ║  Output    : @{ Passed=@();         ║
# ║               Failed=@(); Info=@() }║
# ║  PS compat : 5.1                    ║
# ╚══════════════════════════════════════╝
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
    if ($IsInfo)       { $script:infoResults  += $obj }
    elseif ($Pass)     { $script:passResults  += $obj }
    else               { $script:failResults  += $obj }
}

# Load JSON
$jsonRaw  = [System.IO.File]::ReadAllText($JsonPath, [System.Text.Encoding]::UTF8)
$data     = $jsonRaw | ConvertFrom-Json
$manifest = $data.manifest
$netTcp   = @($data.Network.tcp)

# ---------------------------------------------------------------
# T12 - Multi-NIC interface assignment
# ---------------------------------------------------------------
$adapterArr = @($manifest.network_adapters)

if ($adapterArr.Count -lt 2) {
    Add-R "T12" $true "Multi-NIC interface assignment (SKIP - $($adapterArr.Count) adapter(s), multi-NIC test requires >= 2)" @() $true
} else {
    $t12Fails = @()

    # All connections must have non-null, non-empty InterfaceAlias
    foreach ($c in $netTcp) {
        if ($c.InterfaceAlias -eq $null) {
            $t12Fails += "NULL InterfaceAlias: LocalAddr=$($c.LocalAddress):$($c.LocalPort)"
        } elseif ($c.InterfaceAlias -eq '') {
            $t12Fails += "EMPTY InterfaceAlias: LocalAddr=$($c.LocalAddress):$($c.LocalPort)"
        }
    }

    # ALL_INTERFACES must only appear on 0.0.0.0 or :: bindings
    foreach ($c in $netTcp) {
        if ($c.InterfaceAlias -eq 'ALL_INTERFACES') {
            $la = $c.LocalAddress
            if ($la -ne $null -and $la -ne '' -and $la -ne '0.0.0.0' -and $la -ne '::') {
                $t12Fails += "ALL_INTERFACES on non-wildcard address: LocalAddr=${la}:$($c.LocalPort)"
            }
        }
    }

    # LOOPBACK must only appear on 127.0.0.1 or ::1 bindings
    foreach ($c in $netTcp) {
        if ($c.InterfaceAlias -eq 'LOOPBACK') {
            $la = $c.LocalAddress
            if ($la -ne '127.0.0.1' -and $la -ne '::1') {
                $t12Fails += "LOOPBACK on non-loopback address: LocalAddr=${la}:$($c.LocalPort)"
            }
        }
    }

    $nicCount = $adapterArr.Count
    if ($t12Fails.Count -eq 0) {
        Add-R "T12" $true "Multi-NIC interface assignment ($nicCount NICs, all connections assigned correctly)"
    } else {
        Add-R "T12" $false "Multi-NIC interface assignment ($($t12Fails.Count) violations on $nicCount NICs)" $t12Fails
    }
}

return @{ Passed=$script:passResults; Failed=$script:failResults; Info=$script:infoResults }
