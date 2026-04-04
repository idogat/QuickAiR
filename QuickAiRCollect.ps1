#Requires -Version 5.1
# ╔══════════════════════════════════════════════════════════════╗
# ║  QuickAiR -- QuickAiRCollect.ps1                              ║
# ║  WinForms collection trigger.                               ║
# ║  Receives target list via quickair-collect:// URI.           ║
# ║  Single-instance via named mutex; second instance writes    ║
# ║  a bridge file and exits immediately.                       ║
# ╠══════════════════════════════════════════════════════════════╣
# ║  Parameters : -URI string (required)                        ║
# ║               -MaxConcurrent int (default 5)                ║
# ║                                                             ║
# ║  URI format : quickair-collect://collect?targets=<b64>       ║
# ║               [&maxConcurrent=N]                             ║
# ║  where base64-json decodes to a JSON array:                 ║
# ║    [{ "hostname":"192.168.1.106",                           ║
# ║       "outputPath":".\\DFIROutput\\",                       ║
# ║       "plugins":["Processes","Network"] }]                  ║
# ║                                                             ║
# ║  Depends    : Collector.ps1, Modules\Launcher\PipeListener  ║
# ║  Version    : 2.4                                           ║
# ╚══════════════════════════════════════════════════════════════╝

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]  [string]$URI,
    [Parameter(Mandatory=$false)] [int]   $MaxConcurrent = 5
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

#region ── Self-elevate if not Administrator ───────────────────
$_isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $_isAdmin) {
    $tmpUri = Join-Path $env:TEMP "quickair_collect_uri_$([guid]::NewGuid().ToString('N')).txt"
    [System.IO.File]::WriteAllText($tmpUri, $URI, [System.Text.Encoding]::UTF8)
    # Restrict temp file to current user only
    try {
        $acl = Get-Acl -LiteralPath $tmpUri
        $acl.SetAccessRuleProtection($true, $false)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
            'FullControl', 'Allow')
        $acl.SetAccessRule($rule)
        Set-Acl -LiteralPath $tmpUri -AclObject $acl
    } catch {}
    $fileUri = "file:$tmpUri"
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        '-ExecutionPolicy', 'Bypass',
        '-File', $MyInvocation.MyCommand.Path,
        '-URI', $fileUri
    )
    exit 0
}
#endregion

#region ── Assemblies ───────────────────────────────────────────
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
#endregion

#region ── Launcher modules ─────────────────────────────────────
$_launcherDir = Join-Path $PSScriptRoot 'Modules\Launcher'
Import-Module (Join-Path $_launcherDir 'PipeListener.psm1') -Force
#endregion

#region ── Constants ────────────────────────────────────────────
$BRIDGE_DIR     = 'C:\DFIRLab\QuickAiRBridge\collect'
$MUTEX_NAME     = 'QuickAiRCollectorMutex'
$REFRESH_MS     = 500
$BRIDGE_MS      = 1000
$COLLECTOR_PS1  = Join-Path $PSScriptRoot 'Collector.ps1'
$DEFAULT_OUTPUT = Join-Path $PSScriptRoot 'DFIROutput'

$COL_BG        = [System.Drawing.ColorTranslator]::FromHtml('#0d1117')
$COL_FG        = [System.Drawing.Color]::White
$COL_PANEL     = [System.Drawing.ColorTranslator]::FromHtml('#161b22')
$COL_ROW_RUN   = [System.Drawing.ColorTranslator]::FromHtml('#1e2a3a')
$COL_ROW_DONE  = [System.Drawing.ColorTranslator]::FromHtml('#1a2a1a')
$COL_ROW_FAIL  = [System.Drawing.ColorTranslator]::FromHtml('#2a1a1a')
$COL_ROW_NORM  = [System.Drawing.ColorTranslator]::FromHtml('#0d1117')
$COL_HEADER    = [System.Drawing.ColorTranslator]::FromHtml('#8b949e')
$COL_BLUE      = [System.Drawing.ColorTranslator]::FromHtml('#58a6ff')
$COL_GREEN     = [System.Drawing.Color]::LightGreen
$COL_RED       = [System.Drawing.Color]::Tomato
$COL_GREY      = [System.Drawing.Color]::Gray
$COL_ACCENT    = [System.Drawing.ColorTranslator]::FromHtml('#1f6feb')
$COL_BTN_DARK  = [System.Drawing.ColorTranslator]::FromHtml('#21262d')
$COL_BTN_RED   = [System.Drawing.ColorTranslator]::FromHtml('#8b2020')
$COL_BTN_RED2  = [System.Drawing.ColorTranslator]::FromHtml('#6e2020')
$COL_BTN_GREEN = [System.Drawing.ColorTranslator]::FromHtml('#1f4e2e')

# Discover available collector plugins
$ALL_PLUGINS = @(Get-ChildItem "$PSScriptRoot\Modules\Collectors\*.psm1" -ErrorAction SilentlyContinue |
                     Sort-Object Name | ForEach-Object { $_.BaseName })
#endregion

#region ── Script-scope state ───────────────────────────────────
$script:Targets        = [System.Collections.Generic.List[object]]::new()
$script:HostRows     = [System.Collections.Generic.List[object]]::new()
$script:Lock           = [System.Object]::new()
$script:RowCounter     = 0
$script:Listener       = $null
$script:CredCache      = @{}
$script:Form           = $null
$script:Grid           = $null
$script:StatusLabel    = $null
$script:SpinLabel      = $null
$script:BtnClose       = $null
$script:RefreshTimer   = $null
$script:BridgeTimer    = $null
$script:ScheduleRunning = $false
$script:MaxConcurrent  = [Math]::Max(1, [Math]::Min(20, $MaxConcurrent))
#endregion

#region ── URI parsing ──────────────────────────────────────────
function Parse-CollectURI {
    param([string]$URI)

    # Validate URI scheme before any parsing
    if ($URI -notmatch '^(quickair-collect://|file:)') {
        Write-Warning "Invalid URI scheme. Expected quickair-collect:// or file: prefix."
        return @()
    }

    # If URI was passed via temp file (from self-elevation), read the real URI
    if ($URI -match '^file:(.+)$') {
        $tmpPath = $Matches[1]
        if (Test-Path $tmpPath) {
            $URI = [System.IO.File]::ReadAllText($tmpPath, [System.Text.Encoding]::UTF8)
            Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue
        }
    }

    $rawTargets = $null
    try {
        $query = ''
        if ($URI -match '\?(.+)$') { $query = $Matches[1] }

        $qParams = @{}
        foreach ($pair in $query -split '&') {
            if ($pair -match '^([^=]+)=(.*)$') {
                $qParams[$Matches[1]] = [System.Uri]::UnescapeDataString($Matches[2])
            }
        }

        if ($qParams['targets']) {
            $b64 = $qParams['targets']
            if ($b64.Length -gt 1048576) {   # 1 MB limit on base64 payload
                Write-Warning "URI payload exceeds 1 MB limit ($($b64.Length) bytes). Rejected."
                return @()
            }
            $json       = [System.Text.Encoding]::UTF8.GetString(
                              [System.Convert]::FromBase64String($b64))
            $rawTargets = $json | ConvertFrom-Json
        }
        else {
            return @()
        }

        # Apply maxConcurrent from URI if provided
        if ($qParams['maxConcurrent']) {
            $mc = 0
            if ([int]::TryParse($qParams['maxConcurrent'], [ref]$mc)) {
                $script:MaxConcurrent = [Math]::Max(1, [Math]::Min(20, $mc))
            }
        }
    }
    catch {
        $errMsg = "URI parse failed: $_"
        Write-Warning $errMsg
        [System.Windows.Forms.MessageBox]::Show(
            $errMsg,
            'QuickAiR - URI Parse Error',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        exit 1
    }

    # Validate each target
    $valid    = @()
    $allItems = @($rawTargets)
    if ($allItems.Count -eq 0) { return @() }

    foreach ($raw in $allItems) {
        $ok     = $true
        $reason = ''

        $host_ = if ($raw.PSObject.Properties['hostname']) { [string]$raw.hostname } else { '' }
        if ([string]::IsNullOrWhiteSpace($host_)) {
            $ok = $false; $reason = 'hostname is null or empty'
        }
        elseif ($host_ -notmatch '^[\w][\w\.\-]{0,253}$') {
            $ok = $false; $reason = "hostname invalid format: '$host_'"
        }

        if ($ok) { $valid += $raw }
        else     { Write-Warning "Target skipped - $reason" }
    }

    return @($valid)
}
#endregion

#region ── Target & host row management ─────────────────────────
function Add-Targets {
    param([array]$rawTargets)
    # Deduplicate hostnames
    $existingHosts = @{}
    [System.Threading.Monitor]::Enter($script:Lock)
    foreach ($t in $script:HostRows) { $existingHosts[$t.Hostname.ToLower()] = $true }
    [System.Threading.Monitor]::Exit($script:Lock)

    foreach ($raw in $rawTargets) {
        $host_   = ([string]$raw.hostname).Trim()
        if ($existingHosts.ContainsKey($host_.ToLower())) {
            Write-Host "Duplicate hostname '$host_' skipped" -ForegroundColor Yellow
            continue
        }
        $existingHosts[$host_.ToLower()] = $true
        $outPath = if ($raw.PSObject.Properties['outputPath'] -and -not [string]::IsNullOrWhiteSpace($raw.outputPath)) {
                       $rawOut = [string]$raw.outputPath
                       if ([System.IO.Path]::IsPathRooted($rawOut)) { $rawOut }
                       else { Join-Path $PSScriptRoot $rawOut }
                   } else { $DEFAULT_OUTPUT }
        $plugins = if ($raw.PSObject.Properties['plugins'] -and $raw.plugins -and @($raw.plugins).Count -gt 0) {
                       @($raw.plugins | ForEach-Object { [string]$_ }) | Where-Object { $_ -in $ALL_PLUGINS }
                   } else { @($ALL_PLUGINS) }

        if ($plugins.Count -eq 0) { $plugins = @($ALL_PLUGINS) }

        $tid = [guid]::NewGuid().ToString()

        # One row per host (not per plugin)
        $script:RowCounter++
        $row = [PSCustomObject]@{
            RowNumber    = $script:RowCounter
            TargetId     = $tid
            Hostname     = $host_
            Plugins      = $plugins
            PluginCount  = $plugins.Count
            OutputPath   = $outPath
            Status       = 'Queued'
            Detail       = ''
            Progress     = ''
            StartTime    = [DateTime]::MinValue
            EndTime      = [DateTime]::MinValue
            IsDone       = $false
            IsCancelled  = $false
            Credential   = $null
            PS_          = $null
            RunHandle_   = $null
            ProgressFile = ''
        }

        [System.Threading.Monitor]::Enter($script:Lock)
        $script:Targets.Add($row)
        $script:HostRows.Add($row)
        [System.Threading.Monitor]::Exit($script:Lock)

        if ($null -ne $script:Grid -and -not $script:Grid.IsDisposed) {
            Add-GridRow $row
        }
    }
}
#endregion

#region ── Status display helpers ───────────────────────────────
function Get-StatusDisplay {
    param([string]$s)
    switch ($s) {
        'Queued'     { return [char]0x231B + ' Queued'     }
        'Waiting'    { return [char]0x231B + ' Waiting'    }
        'Connecting' { return [char]0x27F3 + ' Connecting' }
        'Setting Up' { return [char]0x27F3 + ' Setting Up' }
        'Collecting' { return [char]0x27F3 + ' Collecting' }
        'Complete'   { return [char]0x2713 + ' Complete'   }
        'Failed'     { return [char]0x2717 + ' Failed'     }
        'Cancelled'  { return [char]0x2717 + ' Cancelled'  }
        default      { return $s }
    }
}

function Get-StatusColor {
    param([string]$s)
    if ($s -eq 'Complete')                       { return $COL_GREEN }
    if ($s -match 'Failed|Cancelled')            { return $COL_RED   }
    if ($s -match 'Queued|Waiting')              { return $COL_GREY  }
    if ($s -eq 'Setting Up')                     { return $COL_BLUE  }
    return $COL_BLUE
}

function Get-RowBgColor {
    param([string]$status, [bool]$isDone)
    if ($isDone) {
        if ($status -match 'Failed|Cancelled') { return $COL_ROW_FAIL }
        return $COL_ROW_DONE
    }
    if ($status -ne 'Queued') { return $COL_ROW_RUN }
    return $COL_ROW_NORM
}

function Test-AuthError {
    param([string]$detail)
    if ([string]::IsNullOrWhiteSpace($detail)) { return $false }
    $patterns = @('user name or password', 'Access.+denied', 'LogonFailure', '401', 'Unauthorized')
    foreach ($p in $patterns) {
        if ($detail -match $p) { return $true }
    }
    return $false
}
#endregion

#region ── Credential handling ──────────────────────────────────
function Show-CredentialDialog {
    param([string]$hostname)

    $dlg = [System.Windows.Forms.Form]::new()
    $dlg.Text            = 'Credentials Required'
    $dlg.Size            = [System.Drawing.Size]::new(390, 235)
    $dlg.StartPosition   = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.BackColor       = [System.Drawing.ColorTranslator]::FromHtml('#1a1f2e')
    $dlg.ForeColor       = [System.Drawing.Color]::White

    function MkLabel($text, $y) {
        $l = [System.Windows.Forms.Label]::new()
        $l.Text = $text; $l.Location = [System.Drawing.Point]::new(12, $y)
        $l.Size = [System.Drawing.Size]::new(360, 18); $l.ForeColor = [System.Drawing.Color]::White
        return $l
    }
    function MkBox($y, $pw) {
        $t = [System.Windows.Forms.TextBox]::new()
        $t.Location = [System.Drawing.Point]::new(12, $y)
        $t.Size     = [System.Drawing.Size]::new(360, 22)
        $t.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#0d1117')
        $t.ForeColor = [System.Drawing.Color]::White
        if ($pw) { $t.PasswordChar = [char]'*' }
        return $t
    }

    $lbl0   = MkLabel "Enter credentials for: $hostname" 10
    $lblU   = MkLabel 'Username (DOMAIN\user or user):' 40
    $txtU   = MkBox 58 $false
    $lblP   = MkLabel 'Password:' 88
    $txtP   = MkBox 106 $true

    $btnOK = [System.Windows.Forms.Button]::new()
    $btnOK.Text = 'OK'; $btnOK.Location = [System.Drawing.Point]::new(192, 158)
    $btnOK.Size = [System.Drawing.Size]::new(85, 28)
    $btnOK.BackColor = $COL_ACCENT; $btnOK.ForeColor = [System.Drawing.Color]::White
    $btnOK.FlatStyle = 'Flat'; $btnOK.DialogResult = [System.Windows.Forms.DialogResult]::OK

    $btnCancel = [System.Windows.Forms.Button]::new()
    $btnCancel.Text = 'Cancel'; $btnCancel.Location = [System.Drawing.Point]::new(285, 158)
    $btnCancel.Size = [System.Drawing.Size]::new(85, 28)
    $btnCancel.BackColor = $COL_BTN_DARK; $btnCancel.ForeColor = [System.Drawing.Color]::White
    $btnCancel.FlatStyle = 'Flat'; $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $dlg.Controls.AddRange(@($lbl0, $lblU, $txtU, $lblP, $txtP, $btnOK, $btnCancel))
    $dlg.AcceptButton = $btnOK
    $dlg.CancelButton = $btnCancel

    $r = $dlg.ShowDialog($script:Form)
    $user = $txtU.Text.Trim()
    $pass = $txtP.Text
    $txtP.Text = ''   # clear plaintext from TextBox buffer
    $dlg.Dispose()

    if ($r -eq [System.Windows.Forms.DialogResult]::OK -and $user) {
        if ([string]::IsNullOrEmpty($pass)) { $pass = [char]0x0 }  # SecureString requires non-empty
        $sec  = ConvertTo-SecureString $pass -AsPlainText -Force
        $pass = $null  # clear plaintext from variable
        return [System.Management.Automation.PSCredential]::new($user, $sec)
    }
    return $null
}

function Resolve-Credential {
    param([object]$target)

    $isLocal = ($target.Hostname -eq 'localhost' -or
                $target.Hostname -eq '127.0.0.1' -or
                $target.Hostname -ieq $env:COMPUTERNAME)
    if ($isLocal) { return $null }

    $key = $target.Hostname.ToLower()
    if ($script:CredCache.ContainsKey($key)) { return $script:CredCache[$key] }

    $cred = Show-CredentialDialog $target.Hostname
    if ($null -eq $cred) { return 'CANCELLED' }

    $domKey = if ($cred.UserName -match '^([^\\]+)\\') { $Matches[1].ToLower() } else { $key }
    $script:CredCache[$domKey] = $cred
    $script:CredCache[$key]    = $cred
    return $cred
}

function Resolve-AllCredentials {
    # Prompt for all unique non-local hosts upfront before scheduling starts.
    [System.Threading.Monitor]::Enter($script:Lock)
    $snap = @($script:HostRows)
    [System.Threading.Monitor]::Exit($script:Lock)

    $seen = @{}
    foreach ($pr in $snap) {
        $h = $pr.Hostname
        if ($seen.ContainsKey($h)) { continue }
        $seen[$h] = $true

        $isLocal = ($h -eq 'localhost' -or $h -eq '127.0.0.1' -or $h -ieq $env:COMPUTERNAME)
        if ($isLocal) { continue }

        $key = $h.ToLower()
        if ($script:CredCache.ContainsKey($key)) { continue }

        $cred = Show-CredentialDialog $h
        if ($null -eq $cred) {
            foreach ($pr2 in $snap) {
                if ($pr2.Hostname -eq $h -and -not $pr2.IsDone) {
                    $pr2.Status = 'Failed'; $pr2.Detail = 'Credential cancelled'
                    $pr2.IsDone = $true; $pr2.EndTime = [DateTime]::UtcNow
                }
            }
            continue
        }
        $domKey = if ($cred.UserName -match '^([^\\]+)\\') { $Matches[1].ToLower() } else { $key }
        $script:CredCache[$domKey] = $cred
        $script:CredCache[$key]    = $cred
    }
}
#endregion

#region ── Job execution ────────────────────────────────────────
function Start-HostRunspace {
    param([object]$hostRow)

    $hostRow.Status    = 'Waiting'
    $hostRow.Detail    = 'Waiting'
    $hostRow.StartTime = [DateTime]::UtcNow

    # Create a progress file for Collector.ps1 to write per-plugin status.
    # The scheduler reads this file -- the runspace must NOT delete it.
    $progressFile = Join-Path $env:TEMP "quickair_progress_$([guid]::NewGuid().ToString('N')).txt"
    # Write CONNECTING so the scheduler can show the state immediately
    try { [System.IO.File]::WriteAllText($progressFile, "CONNECTING`n") } catch {}
    $hostRow.ProgressFile = $progressFile

    $collectorPath = $COLLECTOR_PS1
    $allPlugins    = $hostRow.Plugins
    $hostname      = $hostRow.Hostname
    $outputPath    = $hostRow.OutputPath
    $credential    = $hostRow.Credential

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.AddScript({
        param($collectorPath, $hostname, $outputPath, $allPlugins, $credential, $progressFile)
        Set-StrictMode -Off
        $ErrorActionPreference = 'Continue'
        try {
            $splat = @{
                Targets      = @($hostname)
                OutputPath   = $outputPath
                Plugins      = $allPlugins
                Quiet        = $true
                ProgressFile = $progressFile
            }
            if ($null -ne $credential -and $credential -ne 'CANCELLED') {
                $splat['Credential'] = $credential
            }

            $collectStart = [DateTime]::UtcNow
            & $collectorPath @splat | Out-Null

            # Read output path from progress file (Collector.ps1 writes OUTPUT:<path>)
            $resultJson = ''
            try {
                $pfLines = [System.IO.File]::ReadAllLines($progressFile)
                foreach ($pfLine in $pfLines) {
                    if ($pfLine -match '^OUTPUT:(.+)$') { $resultJson = $Matches[1]; break }
                }
            } catch {}

            # Signal completion via progress file (scheduler reads this)
            if ($resultJson) {
                [System.IO.File]::AppendAllText($progressFile, "RESULT:$resultJson`n")
            }
            [System.IO.File]::AppendAllText($progressFile, "HOSTDONE`n")
        }
        catch {
            # Signal failure via progress file
            try { [System.IO.File]::AppendAllText($progressFile, "HOSTFAILED:Collection error: $($_.Exception.Message). Check collection.log in the output folder for details.`n") } catch {}
        }
    }).AddArgument($collectorPath).AddArgument($hostname).AddArgument($outputPath).AddArgument($allPlugins).AddArgument($credential).AddArgument($progressFile) | Out-Null

    $hostRow.PS_        = $ps
    $hostRow.RunHandle_ = $ps.BeginInvoke()
}
#endregion

#region ── DataGridView helpers ─────────────────────────────────
function Set-RowStyle {
    param([System.Windows.Forms.DataGridViewRow]$row, [string]$status, [bool]$isDone)
    $bg = Get-RowBgColor $status $isDone
    $fc = Get-StatusColor $status
    for ($ci = 0; $ci -lt $row.Cells.Count; $ci++) {
        $row.Cells[$ci].Style.BackColor = $bg
    }
    $row.Cells[2].Style.ForeColor = $fc
}

function Add-GridRow {
    param([object]$pRow)
    $rowIdx = $script:Grid.Rows.Add(
        [object]$pRow.RowNumber,
        [object]$pRow.Hostname,
        [object](Get-StatusDisplay $pRow.Status),
        [object]([string]$pRow.Progress),
        [object]([string]$pRow.Detail),
        [object]'')
    $row = $script:Grid.Rows[$rowIdx]
    $row.Tag = $pRow.TargetId
    $row.Cells[4].ToolTipText = [string]$pRow.Detail
    Set-RowStyle $row $pRow.Status $false
}

function Update-GridRow {
    param([object]$pRow, [string]$timeStr, [bool]$isDone)
    $tag = $pRow.TargetId
    for ($ri = 0; $ri -lt $script:Grid.Rows.Count; $ri++) {
        $row = $script:Grid.Rows[$ri]
        if ($row.Tag -ne $tag) { continue }
        $row.Cells[2].Value = [object](Get-StatusDisplay $pRow.Status)
        $row.Cells[3].Value = [object]([string]$pRow.Progress)
        $row.Cells[4].Value = [object]([string]$pRow.Detail)
        $row.Cells[4].ToolTipText = [string]$pRow.Detail
        $row.Cells[5].Value = [object]$timeStr
        Set-RowStyle $row $pRow.Status $isDone
        break
    }
}

#endregion

#region ── Scheduler (UI thread, 500ms) ─────────────────────────
function Invoke-Schedule {
    if ($script:ScheduleRunning) { return }
    $script:ScheduleRunning = $true
    try {

    # Snapshot host rows
    [System.Threading.Monitor]::Enter($script:Lock)
    $prSnap = @($script:HostRows)
    [System.Threading.Monitor]::Exit($script:Lock)

    # Count states from host rows
    $running = 0; $queued = 0; $done = 0; $failed = 0
    foreach ($pr in $prSnap) {
        switch -Regex ($pr.Status) {
            'Complete'          { $done++    }
            'Failed|Cancelled'  { $failed++  }
            'Queued|Waiting'    { $queued++   }
            default             { $running++  }
        }
    }
    $script:StatusLabel.Text = "Running: $running  |  Queued: $queued  |  Done: $done  |  Failed: $failed  |  Max Concurrent:"

    # Start queued hosts up to MaxConcurrent (one runspace per host)
    $activeHosts = 0
    foreach ($pr in $prSnap) {
        if (-not $pr.IsDone -and $pr.Status -ne 'Queued') { $activeHosts++ }
    }

    while ($activeHosts -lt $script:MaxConcurrent) {
        # Find next queued host row
        $nextRow = $null
        foreach ($pr in $prSnap) {
            if (-not $pr.IsDone -and $pr.Status -eq 'Queued') {
                $nextRow = $pr; break
            }
        }
        if ($null -eq $nextRow) { break }

        # Resolve credential (cached per host)
        $isLocal = ($nextRow.Hostname -eq 'localhost' -or
                    $nextRow.Hostname -eq '127.0.0.1' -or
                    $nextRow.Hostname -ieq $env:COMPUTERNAME)
        $cred = $null
        if (-not $isLocal) {
            $key = $nextRow.Hostname.ToLower()
            if ($script:CredCache.ContainsKey($key)) {
                $cred = $script:CredCache[$key]
            } else {
                $cred = Show-CredentialDialog $nextRow.Hostname
                if ($null -eq $cred) {
                    $nextRow.Status = 'Failed'; $nextRow.Detail = 'Credential cancelled by analyst. Re-run collection to retry.'
                    $nextRow.IsDone = $true; $nextRow.EndTime = [DateTime]::UtcNow
                    continue
                }
                $script:CredCache[$key] = $cred
                $domKey = if ($cred.UserName -match '^([^\\]+)\\') { $Matches[1].ToLower() } else { $key }
                $script:CredCache[$domKey] = $cred
            }
        }
        $nextRow.Credential = $cred

        Start-HostRunspace $nextRow
        $activeHosts++
    }

    # Read progress files and build accumulated detail for each host row
    foreach ($pr in $prSnap) {
        if ($pr.IsDone) {
            # Already resolved -- just update grid
            $elapsed = if ($pr.EndTime -ne [DateTime]::MinValue -and $pr.StartTime -ne [DateTime]::MinValue) {
                [int]($pr.EndTime - $pr.StartTime).TotalSeconds } else { 0 }
            $timeStr = if ($pr.IsDone) { "${elapsed}s" } else { '' }
            Update-GridRow $pr $timeStr $true
            continue
        }

        if ($null -eq $pr.PS_ -or -not $pr.ProgressFile) {
            Update-GridRow $pr '' $false
            continue
        }

        # Parse progress file
        $connecting  = $false
        $probeInfo   = ''
        $completed   = [System.Collections.Generic.List[string]]::new()   # ordered: done/failed plugin names
        $failedSet   = @{}                                                 # plugin names that failed
        $currentPlug = ''
        $result      = ''
        $hostDone    = $false
        $hostFailed  = ''

        $pf = $pr.ProgressFile
        if (Test-Path $pf) {
            $lines = $null
            for ($readRetry = 0; $readRetry -lt 3; $readRetry++) {
                try { $lines = [System.IO.File]::ReadAllLines($pf); break }
                catch [System.IO.IOException] { Start-Sleep -Milliseconds 50 }
            }
            try {
                if ($null -eq $lines) { $lines = @() }
                foreach ($line in $lines) {
                    $line = $line.Trim()
                    if     ($line -eq 'CONNECTING')               { $connecting = $true }
                    elseif ($line -match '^PROBE:(.+)$')          { $probeInfo = $Matches[1] }
                    elseif ($line -match '^COLLECTING:(.+)$')     { $currentPlug = $Matches[1] }
                    elseif ($line -match '^DONE:(.+)$')           { $completed.Add($Matches[1]); $currentPlug = '' }
                    elseif ($line -match '^FAILED:([^:]+):(.*)$') { $completed.Add($Matches[1]); $failedSet[$Matches[1]] = $true; $currentPlug = '' }
                    elseif ($line -match '^OUTPUT:(.+)$')         { $result = $Matches[1] }
                    elseif ($line -match '^RESULT:(.+)$')         { $result = $Matches[1] }
                    elseif ($line -eq 'HOSTDONE')                 { $hostDone = $true }
                    elseif ($line -match '^HOSTFAILED:(.+)$')     { $hostFailed = $Matches[1] }
                }
            } catch {}
        }

        # Build detail and status from parsed state
        if ($hostFailed) {
            $pr.Status  = 'Failed'
            $pr.Detail  = if (Test-AuthError $hostFailed) { 'Authentication failed '+[char]0x2014+' wrong username or password.' } else { $hostFailed }
            $pr.IsDone  = $true
            $pr.EndTime = [DateTime]::UtcNow
        }
        elseif ($hostDone) {
            if ($result -and (Test-Path $result) -and (Get-Item $result).Length -gt 0) {
                $pr.Status   = 'Complete'
                $pr.Detail   = "Output: $result"
                $pr.Progress = "$($pr.PluginCount)/$($pr.PluginCount)"
            } else {
                $pr.Status = 'Failed'
                $pr.Detail = 'No output file produced. Collection may have been interrupted. Check collection.log in the output folder for details.'
            }
            $pr.IsDone  = $true
            $pr.EndTime = [DateTime]::UtcNow
        }
        elseif ($currentPlug) {
            # A plugin is currently running
            $pr.Status = 'Collecting'
            # Find ordinal of current plugin in the Plugins array (1-based)
            $plugIdx = 0
            for ($pi = 0; $pi -lt $pr.Plugins.Count; $pi++) {
                if ($pr.Plugins[$pi] -eq $currentPlug) { $plugIdx = $pi + 1; break }
            }
            if ($plugIdx -eq 0) { $plugIdx = $completed.Count + 1 }
            $pr.Progress = "$plugIdx/$($pr.PluginCount)"
            # Build detail: completed plugins + current
            $doneParts = @()
            foreach ($dp in $completed) {
                $mark = if ($failedSet.ContainsKey($dp)) { [char]0x2717 } else { [char]0x2713 }
                $doneParts += "$dp $mark"
            }
            $doneStr = $doneParts -join ' '
            if ($doneStr) {
                $pr.Detail = "$doneStr | Running: $currentPlug"
            } else {
                $pr.Detail = "Running: $currentPlug"
            }
        }
        elseif ($probeInfo) {
            $pr.Status   = 'Setting Up'
            $pr.Progress = [string]([char]0x2014)
            # Format: PS=5.1|CIM=True|NetCIM=True|DnsCIM=True|Method=WMI → readable
            if ($probeInfo -match 'Method=WMI') {
                $pr.Detail = "WinRM failed " + [char]0x2014 + " WMI fallback | $($probeInfo -replace '\|', ' | ')"
            } else {
                $pr.Detail = "Capability probe OK | $($probeInfo -replace '\|', ' | ')"
            }
        }
        elseif ($connecting) {
            $pr.Status   = 'Setting Up'
            $pr.Progress = [string]([char]0x2014)
            $pr.Detail   = "Connecting to $($pr.Hostname)..."
        }

        # Fallback: detect runspace completion when no progress file data resolved status
        if (-not $pr.IsDone -and $null -ne $pr.RunHandle_ -and $pr.RunHandle_.IsCompleted) {
            $hasErrors = $false
            $errMsg    = ''
            try {
                if ($pr.PS_.Streams.Error.Count -gt 0) {
                    $hasErrors = $true
                    $errMsg    = [string]$pr.PS_.Streams.Error[0]
                }
            } catch {}
            if ($hasErrors) {
                $authDetail = if (Test-AuthError $errMsg) { 'Authentication failed '+[char]0x2014+' wrong username or password.' } else { "Collection error: $errMsg. Check collection.log in the output folder for details." }
                $pr.Status = 'Failed'; $pr.Detail = $authDetail
            } else {
                $outDir = Join-Path $pr.OutputPath $pr.Hostname
                $outFiles = @(Get-ChildItem $outDir -Filter '*.json' -ErrorAction SilentlyContinue |
                              Sort-Object LastWriteTimeUtc -Descending)
                if ($outFiles.Count -gt 0 -and $outFiles[0].Length -gt 0) {
                    $pr.Status = 'Complete'; $pr.Detail = "Output: $($outFiles[0].FullName)"
                    $pr.Progress = "$($pr.PluginCount)/$($pr.PluginCount)"
                } else {
                    $pr.Status = 'Failed'; $pr.Detail = 'No output file produced. Collection may have been interrupted. Check collection.log in the output folder for details.'
                }
            }
            $pr.IsDone  = $true
            $pr.EndTime = [DateTime]::UtcNow
        }

        # Dispose completed runspaces and clean up progress file
        if ($pr.IsDone -and $null -ne $pr.PS_ -and $null -ne $pr.RunHandle_ -and $pr.RunHandle_.IsCompleted) {
            if ($pr.ProgressFile) {
                Remove-Item $pr.ProgressFile -Force -ErrorAction SilentlyContinue
            }
            try { $pr.PS_.Dispose() } catch { }
            $pr.PS_        = $null
            $pr.RunHandle_ = $null
        }

        # Compute elapsed time
        $elapsed = if ($pr.IsDone -and $pr.EndTime -ne [DateTime]::MinValue -and $pr.StartTime -ne [DateTime]::MinValue) {
            [int]($pr.EndTime - $pr.StartTime).TotalSeconds
        } elseif ($pr.StartTime -ne [DateTime]::MinValue -and $pr.Status -match 'Collecting|Setting Up') {
            [int]([DateTime]::UtcNow - $pr.StartTime).TotalSeconds
        } else { 0 }
        $timeStr = if ($pr.Status -match 'Collecting|Setting Up' -or $pr.IsDone) { "${elapsed}s" } else { '' }

        Update-GridRow $pr $timeStr $pr.IsDone
    }

    } finally { $script:ScheduleRunning = $false }
}
#endregion

#region ── UI builder ───────────────────────────────────────────
function Build-UI {
    # ── Form ──────────────────────────────────────────────────
    $form = [System.Windows.Forms.Form]::new()
    $form.Text          = 'QuickAiR Collector'
    $form.Size          = [System.Drawing.Size]::new(1000, 500)
    $form.MinimumSize   = [System.Drawing.Size]::new(800, 350)
    $form.BackColor     = $COL_BG
    $form.ForeColor     = $COL_FG
    $form.TopMost       = $false
    $form.ShowInTaskbar = $true
    $form.Font          = [System.Drawing.Font]::new('Consolas', 9)
    $script:Form = $form

    # ── Status bar (top) ──────────────────────────────────────
    $statusPanel            = [System.Windows.Forms.Panel]::new()
    $statusPanel.Dock       = 'Top'
    $statusPanel.Height     = 32
    $statusPanel.BackColor  = $COL_PANEL

    $statusLabel           = [System.Windows.Forms.Label]::new()
    $statusLabel.AutoSize  = $false
    $statusLabel.Location  = [System.Drawing.Point]::new(8, 8)
    $statusLabel.Size      = [System.Drawing.Size]::new(660, 16)
    $statusLabel.ForeColor = $COL_FG
    $statusLabel.Text      = 'Running: 0  |  Queued: 0  |  Done: 0  |  Failed: 0  |  Max Concurrent:'
    $script:StatusLabel = $statusLabel

    $spinLabel           = [System.Windows.Forms.Label]::new()
    $spinLabel.Text      = "$($script:MaxConcurrent)"
    $spinLabel.AutoSize  = $false
    $spinLabel.Location  = [System.Drawing.Point]::new(664, 8)
    $spinLabel.Size      = [System.Drawing.Size]::new(26, 16)
    $spinLabel.ForeColor = $COL_BLUE
    $spinLabel.TextAlign = 'MiddleCenter'
    $script:SpinLabel = $spinLabel

    $spinUp           = [System.Windows.Forms.Button]::new()
    $spinUp.Text      = [char]0x25B2   # ▲
    $spinUp.Size      = [System.Drawing.Size]::new(20, 14)
    $spinUp.Location  = [System.Drawing.Point]::new(693, 2)
    $spinUp.FlatStyle = 'Flat'
    $spinUp.BackColor = $COL_BTN_DARK
    $spinUp.ForeColor = $COL_FG
    $spinUp.Font      = [System.Drawing.Font]::new('Consolas', 7)
    $spinUp.Add_Click({
        if ($script:MaxConcurrent -lt 20) {
            $script:MaxConcurrent++
            $script:SpinLabel.Text = "$($script:MaxConcurrent)"
        }
    })

    $spinDown           = [System.Windows.Forms.Button]::new()
    $spinDown.Text      = [char]0x25BC  # ▼
    $spinDown.Size      = [System.Drawing.Size]::new(20, 14)
    $spinDown.Location  = [System.Drawing.Point]::new(693, 16)
    $spinDown.FlatStyle = 'Flat'
    $spinDown.BackColor = $COL_BTN_DARK
    $spinDown.ForeColor = $COL_FG
    $spinDown.Font      = [System.Drawing.Font]::new('Consolas', 7)
    $spinDown.Add_Click({
        if ($script:MaxConcurrent -gt 1) {
            $script:MaxConcurrent--
            $script:SpinLabel.Text = "$($script:MaxConcurrent)"
        }
    })

    $statusPanel.Controls.AddRange(@($statusLabel, $spinLabel, $spinUp, $spinDown))

    # ── Job table (fills remaining space) ─────────────────────
    $grid = [System.Windows.Forms.DataGridView]::new()
    $grid.Dock                          = 'Fill'
    $grid.BackgroundColor               = $COL_BG
    $grid.GridColor                     = [System.Drawing.ColorTranslator]::FromHtml('#30363d')
    $grid.BorderStyle                   = 'None'
    $grid.RowHeadersVisible             = $false
    $grid.AllowUserToAddRows            = $false
    $grid.AllowUserToDeleteRows         = $false
    $grid.ReadOnly                      = $true
    $grid.SelectionMode                 = 'FullRowSelect'
    $grid.MultiSelect                   = $true
    $grid.AutoSizeRowsMode              = 'None'
    $grid.RowTemplate.Height            = 22
    $grid.ColumnHeadersHeight           = 24
    $grid.EnableHeadersVisualStyles     = $false
    $hdrStyle = $grid.ColumnHeadersDefaultCellStyle
    $hdrStyle.BackColor  = $COL_PANEL
    $hdrStyle.ForeColor  = $COL_HEADER
    $hdrStyle.Font       = [System.Drawing.Font]::new('Consolas', 9, [System.Drawing.FontStyle]::Bold)
    $grid.DefaultCellStyle.BackColor          = $COL_BG
    $grid.DefaultCellStyle.ForeColor          = $COL_FG
    $grid.DefaultCellStyle.SelectionBackColor = $COL_ACCENT
    $grid.DefaultCellStyle.SelectionForeColor = $COL_FG
    $script:Grid = $grid

    # Columns: # | Hostname | Status | Progress | Detail | Time
    $colDefs = @(
        @{H='#';        W=40;  Fill=$false}
        @{H='Hostname'; W=160; Fill=$false}
        @{H='Status';   W=140; Fill=$false}
        @{H='Progress'; W=80;  Fill=$false}
        @{H='Detail';   W=0;   Fill=$true }
        @{H='Time';     W=60;  Fill=$false}
    )
    foreach ($cd in $colDefs) {
        $col              = [System.Windows.Forms.DataGridViewTextBoxColumn]::new()
        $col.HeaderText   = $cd.H
        $col.ReadOnly     = $true
        if ($cd.Fill) { $col.AutoSizeMode = 'Fill' }
        else           { $col.Width = $cd.W; $col.AutoSizeMode = 'None' }
        $grid.Columns.Add($col) | Out-Null
    }

    # ── Bottom bar ────────────────────────────────────────────
    $bottomPanel           = [System.Windows.Forms.Panel]::new()
    $bottomPanel.Dock      = 'Bottom'
    $bottomPanel.Height    = 38
    $bottomPanel.BackColor = $COL_PANEL

    function New-BottomBtn($text, $x, $bgHex) {
        $b = [System.Windows.Forms.Button]::new()
        $b.Text      = $text
        $b.Location  = [System.Drawing.Point]::new($x, 5)
        $b.Size      = [System.Drawing.Size]::new(140, 28)
        $b.FlatStyle = 'Flat'
        $b.BackColor = [System.Drawing.ColorTranslator]::FromHtml($bgHex)
        $b.ForeColor = [System.Drawing.Color]::White
        return $b
    }

    $btnCancelSel  = New-BottomBtn 'Cancel Selected'   8   '#8b2020'
    $btnCancelAll  = New-BottomBtn 'Cancel All'         156 '#6e2020'
    $btnOpenOutput = New-BottomBtn 'Open Output Folder' 304 '#1f4e2e'
    $btnRetrySel   = New-BottomBtn 'Retry'               452 '#1f4e6e'
    $btnClose      = New-BottomBtn 'Close'              600 '#21262d'
    $script:BtnClose = $btnClose

    $btnCancelSel.Add_Click({
        # Get target IDs from selected grid rows
        $targetIds = @{}
        foreach ($row in @($script:Grid.SelectedRows)) {
            $targetIds[[string]$row.Tag] = $true
        }
        [System.Threading.Monitor]::Enter($script:Lock)
        $snap = @($script:HostRows)
        [System.Threading.Monitor]::Exit($script:Lock)
        foreach ($pr in $snap) {
            if ($targetIds.ContainsKey($pr.TargetId) -and -not $pr.IsDone) {
                $pr.IsCancelled = $true
                if ($null -ne $pr.PS_) { try { $pr.PS_.Stop() } catch { } }
                $pr.Status = 'Cancelled'; $pr.Detail = 'Cancelled by user'; $pr.IsDone = $true; $pr.EndTime = [DateTime]::UtcNow
            }
        }
    })

    $btnCancelAll.Add_Click({
        [System.Threading.Monitor]::Enter($script:Lock)
        $snap = @($script:HostRows)
        [System.Threading.Monitor]::Exit($script:Lock)
        foreach ($pr in $snap) {
            if (-not $pr.IsDone) {
                $pr.IsCancelled = $true
                if ($null -ne $pr.PS_) { try { $pr.PS_.Stop() } catch { } }
                $pr.Status = 'Cancelled'; $pr.Detail = 'Cancelled by user'; $pr.IsDone = $true; $pr.EndTime = [DateTime]::UtcNow
            }
        }
    })

    $btnOpenOutput.Add_Click({
        $outPath = $DEFAULT_OUTPUT
        # Try to use the first target's output path
        [System.Threading.Monitor]::Enter($script:Lock)
        if ($script:Targets.Count -gt 0) { $outPath = $script:Targets[0].OutputPath }
        [System.Threading.Monitor]::Exit($script:Lock)
        if (-not (Test-Path $outPath)) {
            New-Item -ItemType Directory -Path $outPath -Force | Out-Null
        }
        Start-Process explorer.exe -ArgumentList $outPath
    })

    $btnRetrySel.Add_Click({
        # Collect target IDs from selected grid rows
        $selectedIds = @{}
        foreach ($row in @($script:Grid.SelectedRows)) {
            $selectedIds[[string]$row.Tag] = $true
        }
        [System.Threading.Monitor]::Enter($script:Lock)
        $snap = @($script:HostRows)
        [System.Threading.Monitor]::Exit($script:Lock)
        foreach ($pr in $snap) {
            if (-not $selectedIds.ContainsKey($pr.TargetId)) { continue }
            if (-not $pr.IsDone) { continue }
            if ($pr.Status -eq 'Complete') { continue }

            # Clear cached credential so user gets a fresh prompt
            $targetKey = $pr.Hostname.ToLower()
            $script:CredCache.Remove($targetKey)
            if ($pr.Credential -and $pr.Credential.UserName -match '^([^\\]+)\\') {
                $script:CredCache.Remove($Matches[1].ToLower())
            }

            # Prompt fresh credential on UI thread
            $cred = Show-CredentialDialog $pr.Hostname
            if ($null -eq $cred) { continue }   # Cancelled -- rows stay Failed, Retry stays visible

            # Store new credential in cache
            $script:CredCache[$targetKey] = $cred
            $domKey = if ($cred.UserName -match '^([^\\]+)\\') { $Matches[1].ToLower() } else { $targetKey }
            $script:CredCache[$domKey] = $cred

            # Reset host row -- scheduler picks it up on next tick
            $pr.Status       = 'Queued'
            $pr.Detail       = ''
            $pr.Progress     = ''
            $pr.IsDone       = $false
            $pr.Credential   = $null
            $pr.EndTime      = [DateTime]::MinValue
            $pr.ProgressFile = ''
            if ($null -ne $pr.PS_) { try { $pr.PS_.Dispose() } catch { } }
            $pr.PS_          = $null
            $pr.RunHandle_   = $null
        }
    })

    $btnClose.Add_Click({
        [System.Threading.Monitor]::Enter($script:Lock)
        $anyRunning = @($script:HostRows | Where-Object { -not $_.IsDone })
        [System.Threading.Monitor]::Exit($script:Lock)
        if ($anyRunning.Count -gt 0) {
            $script:StatusLabel.Text = "$($anyRunning.Count) job(s) still running. Cancel them first."
        } else {
            $form.Close()
        }
    })

    $bottomPanel.Controls.AddRange(@($btnCancelSel, $btnCancelAll, $btnOpenOutput, $btnRetrySel, $btnClose))

    # ── Assemble ──────────────────────────────────────────────
    $form.Controls.Add($grid)
    $form.Controls.Add($bottomPanel)
    $form.Controls.Add($statusPanel)

    # ── Timers ────────────────────────────────────────────────
    $script:RefreshTimer          = [System.Windows.Forms.Timer]::new()
    $script:RefreshTimer.Interval = $REFRESH_MS
    $script:RefreshTimer.Add_Tick({
        try { Invoke-Schedule }
        catch {
            $msg = "$(([DateTime]::UtcNow.ToString('o'))) REFRESH: $($_.Exception.GetType().FullName): $($_.Exception.Message)`n$($_.ScriptStackTrace)`n`n"
            $logPath = 'C:\DFIRLab\collector_error.log'
            try { if ((Test-Path $logPath) -and (Get-Item $logPath).Length -gt 5MB) { Move-Item $logPath "$logPath.old" -Force } } catch {}
            [System.IO.File]::AppendAllText($logPath, $msg)
        }
    })
    $script:RefreshTimer.Start()

    $script:BridgeTimer          = [System.Windows.Forms.Timer]::new()
    $script:BridgeTimer.Interval = $BRIDGE_MS
    $script:BridgeTimer.Add_Tick({
        try {
            $newTargets = Read-PendingJobs -Listener $script:Listener
            if ($newTargets -and $newTargets.Count -gt 0) { Add-Targets $newTargets }
        }
        catch {
            $msg = "$(([DateTime]::UtcNow.ToString('o'))) BRIDGE: $($_.Exception.GetType().FullName): $($_.Exception.Message)`n$($_.ScriptStackTrace)`n`n"
            $logPath = 'C:\DFIRLab\collector_error.log'
            try { if ((Test-Path $logPath) -and (Get-Item $logPath).Length -gt 5MB) { Move-Item $logPath "$logPath.old" -Force } } catch {}
            [System.IO.File]::AppendAllText($logPath, $msg)
        }
    })
    $script:BridgeTimer.Start()

    $form.Add_FormClosing({
        param($frmSender, $fce)

        [System.Threading.Monitor]::Enter($script:Lock)
        $anyRunning = @($script:HostRows | Where-Object { -not $_.IsDone })
        [System.Threading.Monitor]::Exit($script:Lock)
        if ($anyRunning.Count -gt 0) {
            $fce.Cancel = $true
            $script:StatusLabel.Text = "$($anyRunning.Count) job(s) still running. Cancel them first."
            return
        }

        try { $script:RefreshTimer.Stop();  $script:RefreshTimer.Dispose() } catch { }
        try { $script:BridgeTimer.Stop();   $script:BridgeTimer.Dispose()  } catch { }
        try { if ($null -ne $script:Listener) { $script:Listener.StopFlag.Value = $true } } catch { }

        [System.Threading.Monitor]::Enter($script:Lock)
        $snap = @($script:HostRows)
        [System.Threading.Monitor]::Exit($script:Lock)
        foreach ($pr in $snap) {
            if ($null -ne $pr.PS_) {
                try { $pr.PS_.Stop() } catch { }
            }
        }
    })

    return $form
}
#endregion

#region ── Entry point ──────────────────────────────────────────

# Parse URI
$rawTargets = @(Parse-CollectURI $URI)

# Single-instance check via named mutex
$mutex    = [System.Threading.Mutex]::new($false, $MUTEX_NAME)
$acquired = $false
try { $acquired = $mutex.WaitOne(3000) } catch { $acquired = $false }

if (-not $acquired) {
    # Another instance is running -- hand off targets via bridge file and exit
    if ($rawTargets.Count -gt 0) {
        Send-JobBatch -BridgeDir $BRIDGE_DIR -Jobs $rawTargets
    }
    $mutex.Dispose()
    exit 0
}

# We are the primary instance
try {
    $logPath = 'C:\DFIRLab\collector_error.log'
    [System.Windows.Forms.Application]::SetUnhandledExceptionMode(
        [System.Windows.Forms.UnhandledExceptionMode]::CatchException)
    $threadExHandler = [System.Threading.ThreadExceptionEventHandler]{
        param($s2, $e2)
        $msg = "THREAD_EX $(([DateTime]::UtcNow.ToString('o'))): $($e2.Exception.GetType()): $($e2.Exception.Message)`n$($e2.Exception.StackTrace)`n`n"
        [System.IO.File]::AppendAllText($logPath, $msg)
    }
    [System.Windows.Forms.Application]::add_ThreadException($threadExHandler)

    $script:Listener = Start-BridgeListener -BridgeDir $BRIDGE_DIR

    $form = Build-UI
    try {
        if ($rawTargets -and $rawTargets.Count -gt 0) {
            Add-Targets $rawTargets
            Resolve-AllCredentials
        }
    }
    catch {
        $msg = "ADD-TARGETS $(([DateTime]::UtcNow.ToString('o'))): $($_.Exception.GetType()): $($_.Exception.Message)`n$($_.ScriptStackTrace)`n`n"
        [System.IO.File]::AppendAllText($logPath, $msg)
    }
    [System.Windows.Forms.Application]::Run($form)
}
finally {
    try { Stop-BridgeListener $script:Listener } catch { }
    [System.Threading.Monitor]::Enter($script:Lock)
    $finalSnap = @($script:HostRows)
    [System.Threading.Monitor]::Exit($script:Lock)
    foreach ($pr in $finalSnap) {
        if ($null -ne $pr.PS_) {
            try { $pr.PS_.Dispose() } catch { }
            $pr.PS_ = $null
        }
        if ($pr.ProgressFile) {
            Remove-Item $pr.ProgressFile -Force -ErrorAction SilentlyContinue
        }
    }
    if ($script:CredCache) { $script:CredCache.Clear() }
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}
#endregion
