#Requires -Version 5.1
# ╔══════════════════════════════════════════════════════════════╗
# ║  Quicker — QuickerLaunch.ps1                               ║
# ║  Persistent WinForms job manager.                          ║
# ║  Receives job batches via quicker:// URI.                  ║
# ║  Single-instance via named mutex; second instance writes   ║
# ║  a bridge file and exits immediately.                      ║
# ╠══════════════════════════════════════════════════════════════╣
# ║  Parameters : -URI string (required)                       ║
# ║               -MaxConcurrent int (default 5)               ║
# ║                                                            ║
# ║  URI format : quicker://launch?jobs=<base64-json>          ║
# ║  where base64-json decodes to a JSON array of job objects: ║
# ║    [{ "type":"Memory", "target":"hostname",                ║
# ║       "binary":"C:\\path\\tool.exe",                       ║
# ║       "remoteDest":"C:\\Windows\\Temp\\tool.exe",          ║
# ║       "arguments":"", "method":"Auto",                     ║
# ║       "aliveCheck":10 }]                                   ║
# ║                                                            ║
# ║  Depends    : Executor.ps1 (same directory)               ║
# ║  Version    : 1.0                                          ║
# ╚══════════════════════════════════════════════════════════════╝

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]  [string]$URI,
    [Parameter(Mandatory=$false)] [int]   $MaxConcurrent = 5
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

#region ── Assemblies ───────────────────────────────────────────
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
#endregion

#region ── Constants ────────────────────────────────────────────
$BRIDGE_DIR    = 'C:\DFIRLab\QuickerBridge'
$MUTEX_NAME    = 'QuickerLauncherMutex'
$REFRESH_MS    = 500
$BRIDGE_MS     = 1000
$EXECUTOR_PS1  = Join-Path $PSScriptRoot 'Executor.ps1'

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
#endregion

#region ── Script-scope state ───────────────────────────────────
$script:Jobs           = [System.Collections.Generic.List[object]]::new()
$script:JobCounter     = 0
$script:JobLock        = [System.Object]::new()
$script:CredCache      = @{}          # keyed by domain or hostname
$script:MaxConcurrent  = [Math]::Max(1, [Math]::Min(20, $MaxConcurrent))
$script:Form           = $null
$script:Grid           = $null
$script:StatusLabel    = $null
$script:SpinLabel      = $null
$script:BtnClose       = $null
#endregion

#region ── URI parsing ──────────────────────────────────────────
function Parse-QuickerURI {
    param([string]$URI)
    $jobs = @()
    try {
        $query = ''
        if ($URI -match '\?(.+)$') { $query = $Matches[1] }
        $qParams = @{}
        foreach ($pair in $query -split '&') {
            if ($pair -match '^([^=]+)=(.*)$') {
                $qParams[$Matches[1]] = [System.Uri]::UnescapeDataString($Matches[2])
            }
        }
        if ($qParams['jobs']) {
            $json  = [System.Text.Encoding]::UTF8.GetString(
                         [System.Convert]::FromBase64String($qParams['jobs']))
            $jobs  = $json | ConvertFrom-Json
        }
    }
    catch { Write-Warning "URI parse failed: $_" }
    return @($jobs)
}
#endregion

#region ── Validation ───────────────────────────────────────────
$FORBIDDEN = @(';','&','|','`','$(',')','{','}')

function Validate-Job {
    param($raw)
    $errs = @()

    if (-not $raw.target -or $raw.target -notmatch '^[\w\.\-]+$') {
        $errs += "Invalid target: $($raw.target)"
    }

    foreach ($c in $FORBIDDEN) {
        if ($raw.binary    -and ([string]$raw.binary).Contains($c))     { $errs += "Binary path contains forbidden char: $c" }
        if ($raw.remoteDest -and ([string]$raw.remoteDest).Contains($c)) { $errs += "RemoteDest contains forbidden char: $c" }
    }

    if (-not $raw.binary) { $errs += "binary path is required" }

    $ac = 0
    if ($raw.aliveCheck) { [int]::TryParse("$($raw.aliveCheck)", [ref]$ac) | Out-Null }
    else { $ac = 10 }
    if ($ac -lt 5 -or $ac -gt 300) { $errs += "aliveCheck must be 5-300 (got $ac)" }

    return $errs
}
#endregion

#region ── Job state ────────────────────────────────────────────
function New-JobState {
    param($raw)
    $script:JobCounter++
    $ac = 10
    if ($raw.aliveCheck) { [int]::TryParse("$($raw.aliveCheck)", [ref]$ac) | Out-Null }

    return [PSCustomObject]@{
        JobId         = [guid]::NewGuid().ToString()
        RowNumber     = $script:JobCounter
        Type          = if ($raw.type)       { [string]$raw.type }       else { 'Memory' }
        Target        = ([string]$raw.target).Trim()
        Binary        = if ($raw.binary)     { [string]$raw.binary }     else { '' }
        RemoteDest    = if ($raw.remoteDest) { [string]$raw.remoteDest } else { '' }
        Arguments     = if ($raw.arguments)  { [string]$raw.arguments }  else { '' }
        Method        = if ($raw.method)     { [string]$raw.method }     else { 'Auto' }
        AliveCheck    = $ac
        Status        = 'Queued'
        Detail        = ''
        DisplayMethod = ''
        StartTime     = [DateTime]::MinValue
        IsDone        = $false
        IsCancelled   = $false
        Credential    = $null
        PS_           = $null   # PowerShell runspace object
        RunHandle_    = $null   # async handle
        OutputPath_   = ''
    }
}

function New-FailedJob {
    param($raw, [string]$detail)
    $script:JobCounter++
    return [PSCustomObject]@{
        JobId         = [guid]::NewGuid().ToString()
        RowNumber     = $script:JobCounter
        Type          = if ($raw.type)   { [string]$raw.type }   else { '?' }
        Target        = if ($raw.target) { [string]$raw.target } else { '?' }
        Binary        = ''
        RemoteDest    = ''
        Arguments     = ''
        Method        = ''
        AliveCheck    = 10
        Status        = 'VALIDATION_FAILED'
        Detail        = $detail
        DisplayMethod = ''
        StartTime     = [DateTime]::MinValue
        IsDone        = $true
        IsCancelled   = $false
        Credential    = $null
        PS_           = $null
        RunHandle_    = $null
        OutputPath_   = ''
    }
}

function Add-Jobs {
    param([array]$rawJobs)
    foreach ($raw in $rawJobs) {
        $errs = Validate-Job $raw
        $j    = if ($errs.Count -gt 0) { New-FailedJob $raw ($errs -join '; ') }
                else                   { New-JobState  $raw }

        [System.Threading.Monitor]::Enter($script:JobLock)
        try { $script:Jobs.Add($j) } finally { [System.Threading.Monitor]::Exit($script:JobLock) }

        if ($null -ne $script:Grid -and -not $script:Grid.IsDisposed) {
            Add-GridRow $j
        }
    }
}
#endregion

#region ── Status display helpers ───────────────────────────────
function Get-StatusDisplay {
    param([string]$s)
    switch ($s) {
        'Queued'            { '⏳ Queued'        }
        'Connecting'        { '⟳ Connecting'    }
        'TRANSFERRED'       { '⟳ Transferring'  }
        'LAUNCHED'          { '⟳ Launching'     }
        'ALIVE'             { '✓ ALIVE'          }
        'SFX_LAUNCHED'      { '✓ SFX_LAUNCHED'   }
        'CONNECTION_FAILED' { '✗ FAILED'         }
        'TRANSFER_FAILED'   { '✗ FAILED'         }
        'LAUNCH_FAILED'     { '✗ FAILED'         }
        'FAILED'            { '✗ FAILED'         }
        'VALIDATION_FAILED' { '✗ FAILED'         }
        'CANCELLED'         { '✗ CANCELLED'      }
        'TIMEOUT'           { '✗ TIMEOUT'        }
        default             { $s                 }
    }
}

function Get-StatusColor {
    param([string]$s)
    if ($s -in 'ALIVE','SFX_LAUNCHED')                                     { return $COL_GREEN }
    if ($s -match 'FAILED|CANCELLED|TIMEOUT|VALIDATION_FAILED')            { return $COL_RED   }
    if ($s -eq 'Queued')                                                   { return $COL_GREY  }
    return $COL_BLUE
}

function Get-RowBgColor {
    param([object]$j)
    if ($j.IsDone) {
        if ($j.Status -match 'FAILED|CANCELLED|TIMEOUT|VALIDATION_FAILED') { return $COL_ROW_FAIL }
        return $COL_ROW_DONE
    }
    if ($j.Status -ne 'Queued') { return $COL_ROW_RUN }
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
    # Returns $null (no cred needed), a PSCredential, or the string 'CANCELLED'
    param([object]$job)

    $isLocal = ($job.Target -eq 'localhost' -or
                $job.Target -eq '127.0.0.1' -or
                $job.Target -ieq $env:COMPUTERNAME)
    if ($isLocal) { return $null }

    # Build cache key: prefer domain from cached username, else use target
    $key = $job.Target.ToLower()
    if ($script:CredCache.ContainsKey($key)) { return $script:CredCache[$key] }

    $cred = Show-CredentialDialog $job.Target
    if ($null -eq $cred) { return 'CANCELLED' }

    # Cache by domain (e.g. CORP from CORP\analyst) AND by target
    $domKey = if ($cred.UserName -match '^([^\\]+)\\') { $Matches[1].ToLower() } else { $key }
    $script:CredCache[$domKey] = $cred
    $script:CredCache[$key]    = $cred
    return $cred
}
#endregion

#region ── Job execution ────────────────────────────────────────
function Start-JobRunspace {
    param([object]$job)

    $job.Status    = 'Connecting'
    $job.StartTime = [DateTime]::UtcNow

    $outPath = Join-Path $BRIDGE_DIR "results\$($job.JobId)"
    $job.OutputPath_ = $outPath
    [System.IO.Directory]::CreateDirectory($outPath) | Out-Null

    $exePath = $EXECUTOR_PS1

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.AddScript({
        param($exePath, $job, $outPath)
        Set-StrictMode -Off
        $ErrorActionPreference = 'Continue'
        try {
            if ($job.IsCancelled) {
                $job.Status = 'CANCELLED'
                $job.Detail = 'Cancelled before start'
                $job.IsDone = $true
                return
            }

            $splat = @{
                Target          = $job.Target
                LocalBinaryPath = $job.Binary
                RemoteDestPath  = $job.RemoteDest
                Arguments       = $job.Arguments
                Method          = $job.Method
                AliveCheck      = $job.AliveCheck
                OutputPath      = $outPath
            }
            if ($null -ne $job.Credential -and $job.Credential -ne 'CANCELLED') {
                $splat['Credential'] = $job.Credential
            }

            & $exePath @splat | Out-Null

            # Read result JSON written by Executor.ps1
            $jsonFiles = @(Get-ChildItem $outPath -Filter '*.json' -ErrorAction SilentlyContinue)
            if ($jsonFiles.Count -gt 0) {
                $data = Get-Content $jsonFiles[0].FullName -Raw | ConvertFrom-Json
                $job.DisplayMethod = if ($data.Method) { [string]$data.Method } else { '' }
                $job.Status        = if ($data.FinalState) { [string]$data.FinalState } else { 'FAILED' }
                if ($data.States -and $data.States.Count -gt 0) {
                    $job.Detail = [string]($data.States[$data.States.Count - 1].Detail)
                }
            }
            else {
                $job.Status = 'FAILED'
                $job.Detail = 'No result JSON produced'
            }
        }
        catch {
            $job.Status = 'FAILED'
            $job.Detail = $_.Exception.Message
        }
        finally {
            $job.IsDone = $true
        }
    }).AddArgument($exePath).AddArgument($job).AddArgument($outPath) | Out-Null

    $job.PS_        = $ps
    $job.RunHandle_ = $ps.BeginInvoke()
}
#endregion

#region ── DataGridView helpers ─────────────────────────────────
function Set-RowStyle {
    param([System.Windows.Forms.DataGridViewRow]$row, [object]$job)
    $bg = Get-RowBgColor $job
    $fc = Get-StatusColor $job.Status
    for ($ci = 0; $ci -lt $row.Cells.Count; $ci++) {
        $row.Cells[$ci].Style.BackColor = $bg
    }
    $row.Cells[4].Style.ForeColor = $fc
}

function Add-GridRow {
    param([object]$job)
    # Use Rows.Add(params Object[]) — avoids CreateCells void-return issue
    $rowIdx = $script:Grid.Rows.Add(
        [object]$job.RowNumber,
        [object]([string]$job.Type),
        [object]([string]$job.Target),
        [object]([string]$job.DisplayMethod),
        [object](Get-StatusDisplay $job.Status),
        [object]([string]$job.Detail),
        [object]'')
    $row = $script:Grid.Rows[$rowIdx]
    $row.Tag = $job.JobId
    Set-RowStyle $row $job
}

function Update-GridRow {
    param([object]$job)
    $elapsed = if ($job.StartTime -ne [DateTime]::MinValue) {
        [int]([DateTime]::UtcNow - $job.StartTime).TotalSeconds
    } else { 0 }
    $timeStr = if ($job.StartTime -ne [DateTime]::MinValue) { "${elapsed}s" } else { '' }

    for ($ri = 0; $ri -lt $script:Grid.Rows.Count; $ri++) {
        $row = $script:Grid.Rows[$ri]
        if ($row.Tag -ne $job.JobId) { continue }
        $row.Cells[0].Value = [object]$job.RowNumber
        $row.Cells[1].Value = [object]([string]$job.Type)
        $row.Cells[2].Value = [object]([string]$job.Target)
        $row.Cells[3].Value = [object]([string]$job.DisplayMethod)
        $row.Cells[4].Value = [object](Get-StatusDisplay $job.Status)
        $row.Cells[5].Value = [object]([string]$job.Detail)
        $row.Cells[6].Value = [object]$timeStr
        Set-RowStyle $row $job
        break
    }
}
#endregion

#region ── Scheduler (UI thread, 500ms) ─────────────────────────
function Invoke-Schedule {
    [System.Threading.Monitor]::Enter($script:JobLock)
    $snapshot = @($script:Jobs)
    [System.Threading.Monitor]::Exit($script:JobLock)

    $running = 0; $queued = 0; $done = 0; $failed = 0

    foreach ($j in $snapshot) {
        if ($j.IsDone) {
            if ($j.Status -match 'FAILED|CANCELLED|TIMEOUT') { $failed++ } else { $done++ }
        }
        elseif ($j.Status -ne 'Queued') { $running++ }
        else                            { $queued++ }
    }

    $script:StatusLabel.Text = "Running: $running  |  Queued: $queued  |  Done: $done  |  Failed: $failed  |  Max Concurrent:"

    # Start queued jobs up to MaxConcurrent
    $maxC = $script:MaxConcurrent
    foreach ($j in $snapshot) {
        if ($running -ge $maxC) { break }
        if ($j.IsDone -or $j.Status -ne 'Queued') { continue }

        $cred = Resolve-Credential $j
        if ($cred -eq 'CANCELLED') {
            $j.Status = 'FAILED'
            $j.Detail = 'Credential cancelled'
            $j.IsDone = $true
            $failed++
            continue
        }
        $j.Credential = $cred
        Start-JobRunspace $j
        $running++
    }

    # Refresh all rows; dispose completed runspaces
    foreach ($j in $snapshot) {
        if ($j.IsDone -and $null -ne $j.PS_) {
            try { $j.PS_.Dispose() } catch { }
            $j.PS_       = $null
            $j.RunHandle_ = $null
        }
        Update-GridRow $j
    }

    # Close button: only enabled when all jobs finished
    if ($null -ne $script:BtnClose) {
        $anyActive = @($snapshot | Where-Object { -not $_.IsDone })
        $script:BtnClose.Enabled = ($anyActive.Count -eq 0)
    }
}
#endregion

#region ── Bridge watcher (UI thread, 1000ms) ───────────────────
function Watch-Bridge {
    if (-not (Test-Path $BRIDGE_DIR)) { return }
    # Only pick up .json files directly in BRIDGE_DIR (not subdirs)
    $files = @(Get-ChildItem $BRIDGE_DIR -Filter '*.json' -File -ErrorAction SilentlyContinue |
                   Where-Object { $_.DirectoryName -eq $BRIDGE_DIR })
    foreach ($f in $files) {
        try {
            $content = [System.IO.File]::ReadAllText($f.FullName)
            [System.IO.File]::Delete($f.FullName)
            $rawJobs = $content | ConvertFrom-Json
            if ($rawJobs) { Add-Jobs @($rawJobs) }
        }
        catch { }
    }
}
#endregion

#region ── UI builder ───────────────────────────────────────────
function Build-UI {
    # ── Form ──────────────────────────────────────────────────
    $form = [System.Windows.Forms.Form]::new()
    $form.Text          = 'Quicker Launcher'
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

    # Columns: # | Type | Host | Method | Status | Detail | Time
    $colDefs = @(
        @{H='#';      W=40;  Fill=$false}
        @{H='Type';   W=70;  Fill=$false}
        @{H='Host';   W=160; Fill=$false}
        @{H='Method'; W=70;  Fill=$false}
        @{H='Status'; W=140; Fill=$false}
        @{H='Detail'; W=0;   Fill=$true }
        @{H='Time';   W=60;  Fill=$false}
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
        $b.Size      = [System.Drawing.Size]::new(130, 28)
        $b.FlatStyle = 'Flat'
        $b.BackColor = [System.Drawing.ColorTranslator]::FromHtml($bgHex)
        $b.ForeColor = [System.Drawing.Color]::White
        return $b
    }

    $btnCancelSel = New-BottomBtn 'Cancel Selected'  8   '#8b2020'
    $btnCancelAll = New-BottomBtn 'Cancel All'       146 '#6e2020'
    $btnClearDone = New-BottomBtn 'Clear Done'       284 '#1f4e2e'
    $btnClose     = New-BottomBtn 'Close'            422 '#21262d'
    $btnClose.Enabled = $false
    $script:BtnClose  = $btnClose

    $btnCancelSel.Add_Click({
        foreach ($row in @($script:Grid.SelectedRows)) {
            $jid = $row.Tag
            $j   = @($script:Jobs | Where-Object { $_.JobId -eq $jid }) | Select-Object -First 1
            if ($null -ne $j -and -not $j.IsDone) {
                $j.IsCancelled = $true
                if ($null -ne $j.PS_) { try { $j.PS_.Stop() } catch { } }
                $j.Status = 'CANCELLED'; $j.Detail = 'Cancelled by user'; $j.IsDone = $true
            }
        }
    })

    $btnCancelAll.Add_Click({
        [System.Threading.Monitor]::Enter($script:JobLock)
        $snap = @($script:Jobs)
        [System.Threading.Monitor]::Exit($script:JobLock)
        foreach ($j in $snap) {
            if (-not $j.IsDone) {
                $j.IsCancelled = $true
                if ($null -ne $j.PS_) { try { $j.PS_.Stop() } catch { } }
                $j.Status = 'CANCELLED'; $j.Detail = 'Cancelled by user'; $j.IsDone = $true
            }
        }
    })

    $btnClearDone.Add_Click({
        [System.Threading.Monitor]::Enter($script:JobLock)
        $snap = @($script:Jobs)
        [System.Threading.Monitor]::Exit($script:JobLock)
        $doneJobs = @($snap | Where-Object { $_.IsDone })
        foreach ($j in $doneJobs) {
            [System.Threading.Monitor]::Enter($script:JobLock)
            try { [void]$script:Jobs.Remove($j) } finally { [System.Threading.Monitor]::Exit($script:JobLock) }
        }
        # Rebuild grid from remaining jobs
        $script:Grid.Rows.Clear()
        [System.Threading.Monitor]::Enter($script:JobLock)
        $remaining = @($script:Jobs)
        [System.Threading.Monitor]::Exit($script:JobLock)
        foreach ($j in $remaining) { Add-GridRow $j }
    })

    $btnClose.Add_Click({
        $anyActive = @($script:Jobs | Where-Object { -not $_.IsDone })
        if ($anyActive.Count -eq 0) { $form.Close() }
    })

    $bottomPanel.Controls.AddRange(@($btnCancelSel, $btnCancelAll, $btnClearDone, $btnClose))

    # ── Assemble ──────────────────────────────────────────────
    # Add order matters: Fill panel placed first, then docked panels
    $form.Controls.Add($grid)
    $form.Controls.Add($bottomPanel)
    $form.Controls.Add($statusPanel)

    # ── Timers ────────────────────────────────────────────────
    $refreshTimer          = [System.Windows.Forms.Timer]::new()
    $refreshTimer.Interval = $REFRESH_MS
    $refreshTimer.Add_Tick({
        try { Invoke-Schedule }
        catch {
            $msg = "$(([DateTime]::UtcNow.ToString('o'))) REFRESH: $($_.Exception.GetType().FullName): $($_.Exception.Message)`n$($_.ScriptStackTrace)`n`n"
            [System.IO.File]::AppendAllText('C:\DFIRLab\launcher_error.log', $msg)
        }
    })
    $refreshTimer.Start()

    $bridgeTimer          = [System.Windows.Forms.Timer]::new()
    $bridgeTimer.Interval = $BRIDGE_MS
    $bridgeTimer.Add_Tick({
        try { Watch-Bridge }
        catch {
            $msg = "$(([DateTime]::UtcNow.ToString('o'))) BRIDGE: $($_.Exception.GetType().FullName): $($_.Exception.Message)`n$($_.ScriptStackTrace)`n`n"
            [System.IO.File]::AppendAllText('C:\DFIRLab\launcher_error.log', $msg)
        }
    })
    $bridgeTimer.Start()

    $form.Add_FormClosing({
        $refreshTimer.Stop()
        $refreshTimer.Dispose()
        $bridgeTimer.Stop()
        $bridgeTimer.Dispose()
    })

    return $form
}
#endregion

#region ── Entry point ──────────────────────────────────────────

# Ensure bridge directory exists
if (-not (Test-Path $BRIDGE_DIR)) {
    New-Item -ItemType Directory -Path $BRIDGE_DIR -Force | Out-Null
}

# Parse URI
$rawJobs = Parse-QuickerURI $URI

# Clamp MaxConcurrent
$script:MaxConcurrent = [Math]::Max(1, [Math]::Min(20, $MaxConcurrent))

# Single-instance check via named mutex
$mutex    = [System.Threading.Mutex]::new($false, $MUTEX_NAME)
$acquired = $false
try { $acquired = $mutex.WaitOne(100) } catch { $acquired = $false }

if (-not $acquired) {
    # Another instance is running — hand off jobs via bridge file and exit
    $bridgeFile = Join-Path $BRIDGE_DIR "$([guid]::NewGuid().ToString()).json"
    $rawJobs | ConvertTo-Json -Depth 5 | Set-Content $bridgeFile -Encoding UTF8
    $mutex.Dispose()
    exit 0
}

# We are the primary instance
try {
    # Catch any unhandled WinForms thread exceptions and log them
    $logPath = 'C:\DFIRLab\launcher_error.log'
    [System.Windows.Forms.Application]::SetUnhandledExceptionMode(
        [System.Windows.Forms.UnhandledExceptionMode]::CatchException)
    $threadExHandler = [System.Threading.ThreadExceptionEventHandler]{
        param($s2, $e2)
        $msg = "THREAD_EX $(([DateTime]::UtcNow.ToString('o'))): $($e2.Exception.GetType()): $($e2.Exception.Message)`n$($e2.Exception.StackTrace)`n`n"
        [System.IO.File]::AppendAllText($logPath, $msg)
    }
    [System.Windows.Forms.Application]::add_ThreadException($threadExHandler)

    $form = Build-UI
    try {
        if ($rawJobs -and $rawJobs.Count -gt 0) { Add-Jobs $rawJobs }
    }
    catch {
        $msg = "ADD-JOBS $(([DateTime]::UtcNow.ToString('o'))): $($_.Exception.GetType()): $($_.Exception.Message)`n$($_.ScriptStackTrace)`n`n"
        [System.IO.File]::AppendAllText($logPath, $msg)
    }
    [System.Windows.Forms.Application]::Run($form)
}
finally {
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}
#endregion
