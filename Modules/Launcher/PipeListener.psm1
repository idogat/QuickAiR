#Requires -Version 5.1
# ╔══════════════════════════════════════════════════════════════╗
# ║  QuickAiR — PipeListener.psm1                               ║
# ║  Bridge folder file watcher for inter-process job handoff. ║
# ║  Second QuickAiRLaunch.ps1 instance writes <guid>.json;     ║
# ║  background runspace reads and deletes them.               ║
# ╠══════════════════════════════════════════════════════════════╣
# ║  Exports   : Start-BridgeListener, Stop-BridgeListener,   ║
# ║              Send-JobBatch, Read-PendingJobs               ║
# ║  Depends   : none                                          ║
# ║  PS compat : 5.1 (analyst machine)                        ║
# ║  Version   : 1.0                                          ║
# ╚══════════════════════════════════════════════════════════════╝

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

function Start-BridgeListener {
    <#
    .SYNOPSIS
        Starts a background runspace that polls the bridge folder every second.
        New JSON files are read, deleted, and queued for Read-PendingJobs to drain.
    .PARAMETER BridgeDir
        Path to the bridge folder. Created if missing.
    .PARAMETER IntervalMs
        Polling interval in milliseconds (default 1000).
    .OUTPUTS
        Listener object. Pass to Stop-BridgeListener and Read-PendingJobs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]  [string]$BridgeDir,
        [Parameter(Mandatory=$false)] [int]   $IntervalMs = 1000
    )

    if (-not (Test-Path $BridgeDir)) {
        New-Item -ItemType Directory -Path $BridgeDir -Force | Out-Null
    }

    # Thread-safe queue: runspace enqueues raw JSON strings; UI thread dequeues.
    $pendingQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

    # Stop flag as PSCustomObject so the runspace sees updated value by reference.
    $stopFlag = [PSCustomObject]@{ Value = $false }

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()

    $rs.SessionStateProxy.SetVariable('BridgeDir_',    $BridgeDir)
    $rs.SessionStateProxy.SetVariable('PendingQueue_', $pendingQueue)
    $rs.SessionStateProxy.SetVariable('StopFlag_',     $stopFlag)
    $rs.SessionStateProxy.SetVariable('IntervalMs_',   $IntervalMs)

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        Set-StrictMode -Off
        $ErrorActionPreference = 'SilentlyContinue'
        while (-not $StopFlag_.Value) {
            Start-Sleep -Milliseconds $IntervalMs_
            if (-not (Test-Path $BridgeDir_)) { continue }
            $files = @(Get-ChildItem $BridgeDir_ -Filter '*.json' -File -ErrorAction SilentlyContinue |
                           Where-Object { $_.DirectoryName -eq $BridgeDir_ })
            foreach ($f in $files) {
                try {
                    $content = [System.IO.File]::ReadAllText($f.FullName)
                    [System.IO.File]::Delete($f.FullName)
                    [void]$PendingQueue_.Enqueue($content)
                }
                catch { }
            }
        }
    })

    $handle = $ps.BeginInvoke()

    return [PSCustomObject]@{
        Runspace     = $rs
        PowerShell   = $ps
        Handle       = $handle
        PendingQueue = $pendingQueue
        StopFlag     = $stopFlag
        BridgeDir    = $BridgeDir
    }
}

function Stop-BridgeListener {
    <#
    .SYNOPSIS
        Signals the bridge listener runspace to stop and disposes resources.
    .PARAMETER Listener
        Listener object returned by Start-BridgeListener.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] $Listener
    )
    if ($null -eq $Listener) { return }
    try { $Listener.StopFlag.Value = $true } catch { }
    try { $Listener.PowerShell.Stop() }      catch { }
    try { $Listener.Runspace.Close() }       catch { }
    try { $Listener.PowerShell.Dispose() }   catch { }
}

function Send-JobBatch {
    <#
    .SYNOPSIS
        Writes a job array as JSON to the bridge folder.
        Used by a second QuickAiRLaunch.ps1 instance to hand off jobs
        to the already-running primary instance.
    .PARAMETER BridgeDir
        Path to the bridge folder. Created if missing.
    .PARAMETER Jobs
        Array of raw job objects to send.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$BridgeDir,
        [Parameter(Mandatory=$true)] [array] $Jobs
    )
    if (-not (Test-Path $BridgeDir)) {
        New-Item -ItemType Directory -Path $BridgeDir -Force | Out-Null
    }
    $file = Join-Path $BridgeDir "$([guid]::NewGuid().ToString()).json"
    $Jobs | ConvertTo-Json -Depth 5 | Set-Content $file -Encoding UTF8
}

function Read-PendingJobs {
    <#
    .SYNOPSIS
        Drains all pending job batches queued by the background runspace.
        Returns a flat array of raw job objects. Called from the UI thread.
    .PARAMETER Listener
        Listener object returned by Start-BridgeListener.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] $Listener
    )
    $result  = [System.Collections.Generic.List[object]]::new()
    $content = $null
    while ($Listener.PendingQueue.TryDequeue([ref]$content)) {
        try {
            $rawJobs = $content | ConvertFrom-Json
            if ($rawJobs) {
                foreach ($j in @($rawJobs)) { $result.Add($j) }
            }
        }
        catch { }
    }
    return @($result)
}

Export-ModuleMember -Function Start-BridgeListener, Stop-BridgeListener, Send-JobBatch, Read-PendingJobs
