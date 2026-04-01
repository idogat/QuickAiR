#Requires -Version 5.1
# ╔══════════════════════════════════════════════════════════════╗
# ║  QuickAiR — QuickAiRCollect.ps1                              ║
# ║  WinForms collection trigger.                               ║
# ║  Receives target list via quickair-collect:// URI.           ║
# ║  Single-instance via named mutex; second instance writes    ║
# ║  a bridge file and exits immediately.                       ║
# ╠══════════════════════════════════════════════════════════════╣
# ║  Parameters : -URI string (required)                        ║
# ║               -MaxConcurrent int (default 5)                ║
# ║                                                             ║
# ║  URI format : quickair-collect://collect?targets=<base64>    ║
# ║  where base64-json decodes to a JSON array:                 ║
# ║    [{ "hostname":"192.168.1.106",                           ║
# ║       "outputPath":".\\DFIROutput\\",                       ║
# ║       "plugins":["Processes","Network"] }]                  ║
# ║                                                             ║
# ║  Depends    : Collector.ps1, Modules\Launcher\PipeListener  ║
# ║  Version    : 1.7                                           ║
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
$script:PluginRows     = [System.Collections.Generic.List[object]]::new()
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
            $json       = [System.Text.Encoding]::UTF8.GetString(
                              [System.Convert]::FromBase64String($qParams['targets']))
            $rawTargets = $json | ConvertFrom-Json
        }
        else {
            return @()
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

#region ── Target & plugin row management ───────────────────────
function Add-Targets {
    param([array]$rawTargets)
    foreach ($raw in $rawTargets) {
        $host_   = ([string]$raw.hostname).Trim()
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
        $target = [PSCustomObject]@{
            TargetId     = $tid
            Hostname     = $host_
            OutputPath   = $outPath
            Plugins      = $plugins
            Status       = 'Queued'
            Detail       = ''
            StartTime    = [DateTime]::MinValue
            EndTime      = [DateTime]::MinValue
            IsDone       = $false
            IsCancelled  = $false
            Credential   = $null
            PS_          = $null
            RunHandle_   = $null
            ResultJson   = ''
            Resolved     = $false
        }

        [System.Threading.Monitor]::Enter($script:Lock)
        $script:Targets.Add($target)
        [System.Threading.Monitor]::Exit($script:Lock)

        # Create one plugin row per plugin
        $first = $true
        foreach ($p in $plugins) {
            $script:RowCounter++
            $row = [PSCustomObject]@{
                RowNumber   = $script:RowCounter
                TargetId    = $tid
                Hostname    = $host_
                Plugin      = $p
                OutputPath  = $outPath
                Status      = 'Queued'
                Detail      = ''
                StartTime   = [DateTime]::MinValue
                EndTime     = [DateTime]::MinValue
                IsDone      = $false
                IsCancelled = $false
                Credential  = $null
                PS_         = $null
                RunHandle_  = $null
            }
            [System.Threading.Monitor]::Enter($script:Lock)
            $script:PluginRows.Add($row)
            [System.Threading.Monitor]::Exit($script:Lock)

            if ($null -ne $script:Grid -and -not $script:Grid.IsDisposed) {
                Add-GridRow $row
            }
            $first = $false
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
    $dlg.Dispose()

    if ($r -eq [System.Windows.Forms.DialogResult]::OK -and $user) {
        $sec  = ConvertTo-SecureString $pass -AsPlainText -Force
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
#endregion

#region ── Job execution ────────────────────────────────────────
function Start-HostRunspace {
    param([array]$pluginRows)

    # Mark all rows as Waiting; the scheduler reads the progress file to update them.
    foreach ($pr in $pluginRows) {
        $pr.Status    = 'Waiting'
        $pr.Detail    = 'Waiting'
        $pr.StartTime = [DateTime]::UtcNow
    }

    # Create a progress file for Collector.ps1 to write per-plugin status.
    # The scheduler reads this file — the runspace must NOT delete it.
    $progressFile = Join-Path $env:TEMP "quickair_progress_$([guid]::NewGuid().ToString('N')).txt"
    # Write CONNECTING so the scheduler can show the state immediately
    try { [System.IO.File]::WriteAllText($progressFile, "CONNECTING`n") } catch {}
    $pluginRows[0] | Add-Member -NotePropertyName 'ProgressFile' -NotePropertyValue $progressFile -Force

    $collectorPath = $COLLECTOR_PS1
    $allPlugins    = @($pluginRows | ForEach-Object { $_.Plugin })
    $hostname      = $pluginRows[0].Hostname
    $outputPath    = $pluginRows[0].OutputPath
    $credential    = $pluginRows[0].Credential

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

            # Find output JSON and write result to progress file
            $resultJson = ''
            $hostDirs = @(Get-ChildItem $outputPath -Directory -ErrorAction SilentlyContinue)
            foreach ($d in $hostDirs) {
                $jsonFiles = @(Get-ChildItem $d.FullName -Filter '*.json' -ErrorAction SilentlyContinue |
                                   Where-Object { $_.LastWriteTimeUtc -ge $collectStart } |
                                   Sort-Object LastWriteTimeUtc -Descending)
                if ($jsonFiles.Count -gt 0) {
                    $resultJson = $jsonFiles[0].FullName
                    break
                }
            }

            # Signal completion via progress file (scheduler reads this)
            if ($resultJson) {
                [System.IO.File]::AppendAllText($progressFile, "RESULT:$resultJson`n")
            }
            [System.IO.File]::AppendAllText($progressFile, "HOSTDONE`n")
        }
        catch {
            # Signal failure via progress file
            try { [System.IO.File]::AppendAllText($progressFile, "HOSTFAILED:$($_.Exception.Message)`n") } catch {}
        }
    }).AddArgument($collectorPath).AddArgument($hostname).AddArgument($outputPath).AddArgument($allPlugins).AddArgument($credential).AddArgument($progressFile) | Out-Null

    $pluginRows[0].PS_        = $ps
    $pluginRows[0].RunHandle_ = $ps.BeginInvoke()
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
    $hostDisplay = $pRow.Hostname
    $plugDisplay = $pRow.Plugin
    $rowIdx = $script:Grid.Rows.Add(
        [object]$pRow.RowNumber,
        [object]$hostDisplay,
        [object](Get-StatusDisplay $pRow.Status),
        [object]$plugDisplay,
        [object]([string]$pRow.Detail),
        [object]'')
    $row = $script:Grid.Rows[$rowIdx]
    $row.Tag = "$($pRow.TargetId)|$($pRow.Plugin)"
    Set-RowStyle $row $pRow.Status $false
}

function Update-GridRow {
    param([object]$pRow, [string]$timeStr, [bool]$isDone)
    $tag = "$($pRow.TargetId)|$($pRow.Plugin)"
    for ($ri = 0; $ri -lt $script:Grid.Rows.Count; $ri++) {
        $row = $script:Grid.Rows[$ri]
        if ($row.Tag -ne $tag) { continue }
        $row.Cells[2].Value = [object](Get-StatusDisplay $pRow.Status)
        $row.Cells[4].Value = [object]([string]$pRow.Detail)
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

    # Snapshot plugin rows
    [System.Threading.Monitor]::Enter($script:Lock)
    $prSnap = @($script:PluginRows)
    [System.Threading.Monitor]::Exit($script:Lock)

    # Count states from plugin rows
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
    # Identify hosts that already have a running runspace
    $busyHosts = @{}
    foreach ($pr in $prSnap) {
        if (-not $pr.IsDone -and $pr.Status -ne 'Queued') { $busyHosts[$pr.Hostname] = $true }
    }
    $activeHosts = $busyHosts.Count

    while ($activeHosts -lt $script:MaxConcurrent) {
        # Find next hostname with all-queued plugin rows
        $nextHost = $null
        foreach ($pr in $prSnap) {
            if (-not $pr.IsDone -and $pr.Status -eq 'Queued' -and -not $busyHosts.ContainsKey($pr.Hostname)) {
                $nextHost = $pr.Hostname; break
            }
        }
        if ($null -eq $nextHost) { break }

        # Gather all queued plugin rows for this host
        $hostRows = @($prSnap | Where-Object { $_.Hostname -eq $nextHost -and $_.Status -eq 'Queued' })

        # Resolve credential (cached per host)
        $isLocal = ($nextHost -eq 'localhost' -or
                    $nextHost -eq '127.0.0.1' -or
                    $nextHost -ieq $env:COMPUTERNAME)
        $cred = $null
        if (-not $isLocal) {
            $key = $nextHost.ToLower()
            if ($script:CredCache.ContainsKey($key)) {
                $cred = $script:CredCache[$key]
            } else {
                $cred = Show-CredentialDialog $nextHost
                if ($null -eq $cred) {
                    foreach ($pr in $hostRows) {
                        $pr.Status = 'Failed'; $pr.Detail = 'Credential cancelled'
                        $pr.IsDone = $true; $pr.EndTime = [DateTime]::UtcNow
                    }
                    continue
                }
                $script:CredCache[$key] = $cred
                $domKey = if ($cred.UserName -match '^([^\\]+)\\') { $Matches[1].ToLower() } else { $key }
                $script:CredCache[$domKey] = $cred
            }
        }
        foreach ($pr in $hostRows) { $pr.Credential = $cred }

        Start-HostRunspace $hostRows
        $busyHosts[$nextHost] = $true
        $activeHosts++
    }

    # Read progress files (append-based, multi-line) and build per-host state
    # Format: CONNECTING, COLLECTING:<plugin>, DONE:<plugin>, FAILED:<plugin>:<msg>,
    #         RESULT:<json_path>, HOSTDONE, HOSTFAILED:<msg>
    $progressData = @{}   # key=hostname, value=@{ Plugins=@{}; Connecting=$bool; HostDone=$bool; HostFailed=''; Result='' }
    foreach ($pr in $prSnap) {
        if ($null -ne $pr.PS_ -and $pr.PSObject.Properties['ProgressFile'] -and $pr.ProgressFile) {
            $pf = $pr.ProgressFile
            if (-not $progressData.ContainsKey($pr.Hostname) -and (Test-Path $pf)) {
                $hostState = @{ Plugins = @{}; Connecting = $false; HostDone = $false; HostFailed = ''; Result = '' }
                try {
                    $lines = [System.IO.File]::ReadAllLines($pf)
                    foreach ($line in $lines) {
                        $line = $line.Trim()
                        if     ($line -eq 'CONNECTING')                  { $hostState.Connecting = $true }
                        elseif ($line -match '^COLLECTING:(.+)$')        { $hostState.Plugins[$Matches[1]] = 'Collecting' }
                        elseif ($line -match '^DONE:(.+)$')              { $hostState.Plugins[$Matches[1]] = 'Complete' }
                        elseif ($line -match '^FAILED:([^:]+):(.*)$')    { $hostState.Plugins[$Matches[1]] = "Failed:$($Matches[2])" }
                        elseif ($line -match '^RESULT:(.+)$')            { $hostState.Result     = $Matches[1] }
                        elseif ($line -eq 'HOSTDONE')                    { $hostState.HostDone   = $true }
                        elseif ($line -match '^HOSTFAILED:(.+)$')        { $hostState.HostFailed = $Matches[1] }
                    }
                } catch {}
                $progressData[$pr.Hostname] = $hostState
            }
        }
    }

    # Apply progress to plugin rows
    foreach ($pr in $prSnap) {
        if ($pr.IsDone) { <# already resolved #> }
        elseif ($progressData.ContainsKey($pr.Hostname)) {
            $hs = $progressData[$pr.Hostname]

            # Per-plugin status from Collector.ps1
            if ($hs.Plugins.ContainsKey($pr.Plugin)) {
                $st = $hs.Plugins[$pr.Plugin]
                if ($st -eq 'Collecting' -and $pr.Status -ne 'Collecting') {
                    $pr.Status    = 'Collecting'
                    $pr.Detail    = 'Collecting...'
                    $pr.StartTime = [DateTime]::UtcNow
                }
                elseif ($st -eq 'Complete' -and -not $pr.IsDone) {
                    $pr.Status  = 'Complete'
                    $pr.Detail  = 'Done'
                    $pr.IsDone  = $true
                    $pr.EndTime = [DateTime]::UtcNow
                }
                elseif ($st -match '^Failed:(.*)$' -and -not $pr.IsDone) {
                    $pr.Status  = 'Failed'
                    $pr.Detail  = $Matches[1]
                    $pr.IsDone  = $true
                    $pr.EndTime = [DateTime]::UtcNow
                }
            }
            # Connecting state — show on first row only (skip if another row already Connecting)
            elseif ($hs.Connecting -and $hs.Plugins.Count -eq 0 -and $pr.Status -eq 'Waiting') {
                $alreadyConnecting = $false
                foreach ($other in $prSnap) {
                    if ($other.Hostname -eq $pr.Hostname -and $other.Status -eq 'Connecting') {
                        $alreadyConnecting = $true; break
                    }
                }
                if (-not $alreadyConnecting) {
                    $pr.Status = 'Connecting'
                    $pr.Detail = 'Connecting...'
                }
            }

            # HOSTDONE — mark any remaining undone rows, verify output first
            if ($hs.HostDone -and -not $pr.IsDone) {
                if ($hs.Result -and (Test-Path $hs.Result) -and (Get-Item $hs.Result).Length -gt 0) {
                    $pr.Status = 'Complete'
                    $pr.Detail = $hs.Result
                } else {
                    $pr.Status = 'Failed'
                    $pr.Detail = 'Output file not written - collection may have failed'
                }
                $pr.IsDone  = $true
                $pr.EndTime = [DateTime]::UtcNow
            }
            # HOSTFAILED — mark any remaining undone rows as Failed
            elseif ($hs.HostFailed -and -not $pr.IsDone) {
                $pr.Status  = 'Failed'
                $pr.Detail  = $hs.HostFailed
                $pr.IsDone  = $true
                $pr.EndTime = [DateTime]::UtcNow
            }
        }

        # Fallback: detect runspace completion when no progress file data
        if (-not $pr.IsDone -and $null -ne $pr.RunHandle_ -and $pr.RunHandle_.IsCompleted) {
            # Runspace finished but status not resolved by progress file
            $hasErrors = $false
            $errMsg    = ''
            try {
                if ($pr.PS_.Streams.Error.Count -gt 0) {
                    $hasErrors = $true
                    $errMsg    = [string]$pr.PS_.Streams.Error[0]
                }
            } catch {}
            if ($hasErrors) {
                $pr.Status = 'Failed'; $pr.Detail = $errMsg
            } else {
                $outDir = Join-Path $pr.OutputPath $pr.Hostname
                $outFiles = @(Get-ChildItem $outDir -Filter '*.json' -ErrorAction SilentlyContinue |
                              Sort-Object LastWriteTimeUtc -Descending)
                if ($outFiles.Count -gt 0 -and $outFiles[0].Length -gt 0) {
                    $pr.Status = 'Complete'; $pr.Detail = $outFiles[0].FullName
                } else {
                    $pr.Status = 'Failed'; $pr.Detail = 'Output file not written - collection may have failed'
                }
            }
            $pr.IsDone  = $true
            $pr.EndTime = [DateTime]::UtcNow
        }

        # Dispose completed runspaces and clean up progress file
        # Wait for runspace to finish (HOSTDONE/RESULT written) before cleanup
        if ($pr.IsDone -and $null -ne $pr.PS_ -and $null -ne $pr.RunHandle_ -and $pr.RunHandle_.IsCompleted) {
            $allDone = $true
            foreach ($other in $prSnap) {
                if ($other.Hostname -eq $pr.Hostname -and -not $other.IsDone) { $allDone = $false; break }
            }
            if ($allDone) {
                # Clean up progress file (scheduler owns cleanup, not the runspace)
                if ($pr.PSObject.Properties['ProgressFile'] -and $pr.ProgressFile) {
                    Remove-Item $pr.ProgressFile -Force -ErrorAction SilentlyContinue
                }
                try { $pr.PS_.Dispose() } catch { }
                $pr.PS_        = $null
                $pr.RunHandle_ = $null
            }
        }

        # Compute per-plugin elapsed time
        $elapsed = if ($pr.IsDone -and $pr.EndTime -ne [DateTime]::MinValue -and $pr.StartTime -ne [DateTime]::MinValue) {
            [int]($pr.EndTime - $pr.StartTime).TotalSeconds
        } elseif ($pr.StartTime -ne [DateTime]::MinValue -and $pr.Status -match 'Collecting|Connecting') {
            [int]([DateTime]::UtcNow - $pr.StartTime).TotalSeconds
        } else { 0 }
        $timeStr = if ($pr.Status -match 'Collecting|Connecting' -or $pr.IsDone) { "${elapsed}s" } else { '' }

        Update-GridRow $pr $timeStr $pr.IsDone
    }

    # Post-loop: verify output file for hosts where HOSTDONE was received
    foreach ($hostname in $progressData.Keys) {
        $hs = $progressData[$hostname]
        if (-not $hs.HostDone) { continue }
        $fileOk = ($hs.Result -and (Test-Path $hs.Result) -and (Get-Item $hs.Result).Length -gt 0)
        foreach ($pr in $prSnap) {
            if ($pr.Hostname -ne $hostname -or $pr.Status -ne 'Complete') { continue }
            $changed = $false
            if ($fileOk) {
                if ($pr.Detail -ne $hs.Result) { $pr.Detail = $hs.Result; $changed = $true }
            } else {
                $pr.Status = 'Failed'
                $pr.Detail = 'Output file not written - collection may have failed'
                $changed = $true
            }
            if ($changed) {
                $elapsed = if ($pr.EndTime -ne [DateTime]::MinValue -and $pr.StartTime -ne [DateTime]::MinValue) {
                    [int]($pr.EndTime - $pr.StartTime).TotalSeconds } else { 0 }
                Update-GridRow $pr "${elapsed}s" $pr.IsDone
            }
        }
    }

    } finally { $script:ScheduleRunning = $false }
}
#endregion

#region ── UI builder ───────────────────────────────────────────
function Build-UI {
    # ── Form ──────────────────────────────────────────────────
    $form = [System.Windows.Forms.Form]::new()
    $form.Text          = 'QuickAiR Collector'
    $form.Size          = [System.Drawing.Size]::new(900, 500)
    $form.MinimumSize   = [System.Drawing.Size]::new(700, 350)
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

    # Columns: # | Hostname | Status | Plugin | Detail | Time
    $colDefs = @(
        @{H='#';        W=40;  Fill=$false}
        @{H='Hostname'; W=160; Fill=$false}
        @{H='Status';   W=140; Fill=$false}
        @{H='Plugin';   W=120; Fill=$false}
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
    $btnClose      = New-BottomBtn 'Close'              452 '#21262d'
    $script:BtnClose = $btnClose

    $btnCancelSel.Add_Click({
        # Get hostnames from selected grid rows
        $hostnames = @{}
        foreach ($row in @($script:Grid.SelectedRows)) {
            $tag = [string]$row.Tag
            if ($tag -match '^([^|]+)\|') {
                [System.Threading.Monitor]::Enter($script:Lock)
                $pr = @($script:PluginRows | Where-Object { $_.TargetId -eq $Matches[1] }) | Select-Object -First 1
                [System.Threading.Monitor]::Exit($script:Lock)
                if ($pr) { $hostnames[$pr.Hostname] = $true }
            }
        }
        [System.Threading.Monitor]::Enter($script:Lock)
        $snap = @($script:PluginRows)
        [System.Threading.Monitor]::Exit($script:Lock)
        foreach ($pr in $snap) {
            if ($hostnames.ContainsKey($pr.Hostname) -and -not $pr.IsDone) {
                $pr.IsCancelled = $true
                if ($null -ne $pr.PS_) { try { $pr.PS_.Stop() } catch { } }
                $pr.Status = 'Cancelled'; $pr.Detail = 'Cancelled by user'; $pr.IsDone = $true; $pr.EndTime = [DateTime]::UtcNow
            }
        }
    })

    $btnCancelAll.Add_Click({
        [System.Threading.Monitor]::Enter($script:Lock)
        $snap = @($script:PluginRows)
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

    $btnClose.Add_Click({
        [System.Threading.Monitor]::Enter($script:Lock)
        $anyRunning = @($script:PluginRows | Where-Object { -not $_.IsDone })
        [System.Threading.Monitor]::Exit($script:Lock)
        if ($anyRunning.Count -gt 0) {
            $script:StatusLabel.Text = "$($anyRunning.Count) job(s) still running. Cancel them first."
        } else {
            $form.Close()
        }
    })

    $bottomPanel.Controls.AddRange(@($btnCancelSel, $btnCancelAll, $btnOpenOutput, $btnClose))

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
            [System.IO.File]::AppendAllText('C:\DFIRLab\collector_error.log', $msg)
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
            [System.IO.File]::AppendAllText('C:\DFIRLab\collector_error.log', $msg)
        }
    })
    $script:BridgeTimer.Start()

    $form.Add_FormClosing({
        param($frmSender, $fce)

        [System.Threading.Monitor]::Enter($script:Lock)
        $anyRunning = @($script:PluginRows | Where-Object { -not $_.IsDone })
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
        $snap = @($script:PluginRows)
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
try { $acquired = $mutex.WaitOne(100) } catch { $acquired = $false }

if (-not $acquired) {
    # Another instance is running — hand off targets via bridge file and exit
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
        if ($rawTargets -and $rawTargets.Count -gt 0) { Add-Targets $rawTargets }
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
    $finalSnap = @($script:PluginRows)
    [System.Threading.Monitor]::Exit($script:Lock)
    foreach ($pr in $finalSnap) {
        if ($null -ne $pr.PS_) {
            try { $pr.PS_.Dispose() } catch { }
            $pr.PS_ = $null
        }
    }
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}
#endregion
