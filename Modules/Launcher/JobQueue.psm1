#Requires -Version 5.1
# ╔══════════════════════════════════════════════════════════════╗
# ║  QuickAiR -- JobQueue.psm1                                   ║
# ║  Thread-safe job queue and state management.               ║
# ║  Wraps a Generic List with monitor-lock for thread safety. ║
# ║  Enforces forward-only status transitions.                 ║
# ╠══════════════════════════════════════════════════════════════╣
# ║  Exports   : New-JobQueue, Add-Job, Get-NextJob,           ║
# ║              Update-JobStatus, Reset-JobStatus,            ║
# ║              Get-QueueSummary                              ║
# ║  Depends   : none                                          ║
# ║  PS compat : 5.1 (analyst machine)                        ║
# ║  Version   : 1.6                                          ║
# ╚══════════════════════════════════════════════════════════════╝

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

#region ── Module constants ──────────────────────────────────────
$script:FORBIDDEN = @(';', '&', '|', '`', '$(', ')', '{', '}')

# Status transition order -- higher = further along.
# Terminal states share 100; any transition to them from a non-terminal
# state is always valid (100 >= anything <= 3).
$script:StatusOrder = @{
    'Queued'            = 0
    'Connecting'        = 1
    'TRANSFERRED'       = 2
    'LAUNCHED'          = 3
    'ALIVE'             = 100
    'SFX_LAUNCHED'      = 100
    'CONNECTION_FAILED' = 100
    'TRANSFER_FAILED'   = 100
    'LAUNCH_FAILED'     = 100
    'FAILED'            = 100
    'VALIDATION_FAILED' = 100
    'CANCELLED'         = 100
    'TIMEOUT'           = 100
}

$script:TerminalStatuses = @(
    'ALIVE', 'SFX_LAUNCHED', 'CONNECTION_FAILED', 'TRANSFER_FAILED',
    'LAUNCH_FAILED', 'FAILED', 'VALIDATION_FAILED', 'CANCELLED', 'TIMEOUT'
)
#endregion

#region ── Private helpers ──────────────────────────────────────
function Invoke-JobValidation {
    param($raw)
    $errs = @()
    if (-not $raw.target -or $raw.target -notmatch '^[\w\.\-]+$') {
        $errs += "Invalid target: $($raw.target)"
    }
    foreach ($c in $script:FORBIDDEN) {
        if ($raw.binary     -and ([string]$raw.binary).Contains($c))     { $errs += "Binary path contains forbidden char: $c" }
        if ($raw.remoteDest -and ([string]$raw.remoteDest).Contains($c)) { $errs += "RemoteDest contains forbidden char: $c" }
        if ($raw.arguments  -and ([string]$raw.arguments).Contains($c))  { $errs += "Arguments contains forbidden char: $c" }
    }
    if ($raw.binary -and ([string]$raw.binary).StartsWith('\\')) {
        $errs += "Binary path must not be a UNC path"
    }
    if ($raw.remoteDest -and ([string]$raw.remoteDest).Contains('..')) {
        $errs += "RemoteDest must not contain path traversal (..)"
    }
    if (-not $raw.binary) { $errs += 'binary path is required' }
    $ac = 0
    if ($raw.aliveCheck) { [int]::TryParse("$($raw.aliveCheck)", [ref]$ac) | Out-Null }
    else                 { $ac = 10 }
    if ($ac -lt 5 -or $ac -gt 300) { $errs += "aliveCheck must be 5-300 (got $ac)" }
    return $errs
}

function New-JobEntry {
    param($Queue, $raw)
    $Queue.JobCounter++
    $ac = 10
    if ($raw.aliveCheck) { [int]::TryParse("$($raw.aliveCheck)", [ref]$ac) | Out-Null }
    return [PSCustomObject]@{
        JobId         = [guid]::NewGuid().ToString()
        RowNumber     = $Queue.JobCounter
        Type          = if ($raw.type)       { [string]$raw.type }
                       elseif ($raw.tool -eq 'disk')   { 'Disk' }
                       elseif ($raw.tool -eq 'memory') { 'Memory' }
                       else { 'Memory' }
        Target        = ([string]$raw.target).Trim()
        Binary        = if ($raw.binary)     { ([string]$raw.binary).Trim().Trim('"').Trim("'").Trim() }     else { '' }
        RemoteDest    = if ($raw.remoteDest) { ([string]$raw.remoteDest).Trim().Trim('"').Trim("'").Trim() } else { '' }
        Arguments     = if ($raw.arguments)  { ([string]$raw.arguments).Trim() }  else { '' }
        Method        = if ($raw.method)     { [string]$raw.method }     else { 'Auto' }
        RemoteShare   = if ($raw.remoteShare) { ([string]$raw.remoteShare).Trim() } elseif ($raw.smbShare) { ([string]$raw.smbShare).Trim() } else { '' }
        AliveCheck    = $ac
        Status        = 'Queued'
        Detail        = ''
        DisplayMethod = ''
        StartTime     = [DateTime]::MinValue
        EndTime       = [DateTime]::MinValue
        IsDone        = $false
        IsCancelled   = $false
        Credential    = $null
        PS_           = $null
        RunHandle_    = $null
        OutputPath_   = ''
    }
}

function New-FailedEntry {
    param($Queue, $raw, [string]$detail)
    $Queue.JobCounter++
    return [PSCustomObject]@{
        JobId         = [guid]::NewGuid().ToString()
        RowNumber     = $Queue.JobCounter
        Type          = if ($raw.type)             { [string]$raw.type }
                       elseif ($raw.tool -eq 'disk')   { 'Disk' }
                       elseif ($raw.tool -eq 'memory') { 'Memory' }
                       else { '?' }
        Target        = if ($raw.target) { [string]$raw.target } else { '?' }
        Binary        = ''
        RemoteDest    = ''
        Arguments     = ''
        Method        = ''
        RemoteShare   = ''
        AliveCheck    = 10
        Status        = 'VALIDATION_FAILED'
        Detail        = $detail
        DisplayMethod = ''
        StartTime     = [DateTime]::MinValue
        EndTime       = [DateTime]::UtcNow
        IsDone        = $true
        IsCancelled   = $false
        Credential    = $null
        PS_           = $null
        RunHandle_    = $null
        OutputPath_   = ''
    }
}
#endregion

#region ── Exported functions ───────────────────────────────────
function New-JobQueue {
    <#
    .SYNOPSIS
        Creates a new job queue object with thread-safe state management.
    .PARAMETER MaxConcurrent
        Maximum concurrent jobs (1-20, default 5).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)] [int]$MaxConcurrent = 5
    )
    return [PSCustomObject]@{
        Jobs          = [System.Collections.Generic.List[object]]::new()
        Lock          = [System.Object]::new()
        MaxConcurrent = [Math]::Max(1, [Math]::Min(20, $MaxConcurrent))
        JobCounter    = 0
    }
}

function Add-Job {
    <#
    .SYNOPSIS
        Validates a raw job object and appends it to the queue.
    .OUTPUTS
        The created job state object (valid or VALIDATION_FAILED).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] $Queue,
        [Parameter(Mandatory=$true)] $Raw
    )
    $errs = Invoke-JobValidation $Raw
    $j = if ($errs.Count -gt 0) { New-FailedEntry $Queue $Raw ($errs -join '; ') }
         else                   { New-JobEntry    $Queue $Raw }

    [System.Threading.Monitor]::Enter($Queue.Lock)
    try    { $Queue.Jobs.Add($j) }
    finally{ [System.Threading.Monitor]::Exit($Queue.Lock) }
    return $j
}

function Get-NextJob {
    <#
    .SYNOPSIS
        Returns the next Queued job if a concurrency slot is available,
        or $null if all slots are occupied or no jobs are waiting.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] $Queue
    )
    [System.Threading.Monitor]::Enter($Queue.Lock)
    try {
        $running = 0
        foreach ($j in $Queue.Jobs) {
            if (-not $j.IsDone -and $j.Status -ne 'Queued') { $running++ }
        }
        if ($running -ge $Queue.MaxConcurrent) { return $null }

        foreach ($j in $Queue.Jobs) {
            if (-not $j.IsDone -and $j.Status -eq 'Queued') { return $j }
        }
        return $null
    } finally {
        [System.Threading.Monitor]::Exit($Queue.Lock)
    }
}

function Update-JobStatus {
    <#
    .SYNOPSIS
        Updates a job's status, enforcing forward-only transitions.
        Logs a WARN and returns $false if the transition would be backwards.
    .OUTPUTS
        $true if updated; $false if invalid transition or job not found.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]  $Queue,
        [Parameter(Mandatory=$true)]  [string]$JobId,
        [Parameter(Mandatory=$true)]  [string]$Status,
        [Parameter(Mandatory=$false)] [string]$Detail = $null
    )
    [System.Threading.Monitor]::Enter($Queue.Lock)
    try {
        $j = $null
        foreach ($item in $Queue.Jobs) {
            if ($item.JobId -eq $JobId) { $j = $item; break }
        }

        if ($null -eq $j) {
            Write-Warning "Update-JobStatus: job $JobId not found"
            return $false
        }

        $curOrder = if ($script:StatusOrder.ContainsKey($j.Status)) { $script:StatusOrder[$j.Status] } else { -1 }
        $newOrder = if ($script:StatusOrder.ContainsKey($Status))   { $script:StatusOrder[$Status] }   else { 100 }

        if ($newOrder -lt $curOrder) {
            Write-Warning "Update-JobStatus: invalid backward transition $($j.Status) -> $Status for job $JobId"
            return $false
        }

        $j.Status = $Status
        if ($null -ne $Detail) { $j.Detail = $Detail }
        if ($Status -in $script:TerminalStatuses) {
            $j.IsDone     = $true
            $j.EndTime    = [DateTime]::UtcNow
            $j.Credential = $null   # clear credential reference on terminal state
        }
        return $true
    } finally {
        [System.Threading.Monitor]::Exit($Queue.Lock)
    }
}

function Reset-JobStatus {
    <#
    .SYNOPSIS
        Resets a terminal-state job back to Queued for retry.
        Intentional exception to forward-only state machine — used by UI retry button.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] $Queue,
        [Parameter(Mandatory=$true)] [string]$JobId
    )
    [System.Threading.Monitor]::Enter($Queue.Lock)
    try {
        $j = $null
        foreach ($item in $Queue.Jobs) {
            if ($item.JobId -eq $JobId) { $j = $item; break }
        }
        if ($null -eq $j) {
            Write-Warning "Reset-JobStatus: job $JobId not found"
            return $false
        }
        if (-not $j.IsDone) {
            Write-Warning "Reset-JobStatus: job $JobId is not in a terminal state ($($j.Status))"
            return $false
        }
        $j.Status     = 'Queued'
        $j.IsDone     = $false
        $j.Detail     = $null
        $j.EndTime    = $null
        return $true
    } finally {
        [System.Threading.Monitor]::Exit($Queue.Lock)
    }
}

function Get-QueueSummary {
    <#
    .SYNOPSIS
        Returns a hashtable with job counts: Running, Queued, Done, Failed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] $Queue
    )
    [System.Threading.Monitor]::Enter($Queue.Lock)
    $snapshot = @($Queue.Jobs)
    [System.Threading.Monitor]::Exit($Queue.Lock)

    $running = 0; $queued = 0; $done = 0; $failed = 0
    foreach ($j in $snapshot) {
        if ($j.IsDone) {
            if ($j.Status -match 'FAILED|CANCELLED|TIMEOUT') { $failed++ } else { $done++ }
        }
        elseif ($j.Status -ne 'Queued') { $running++ }
        else                            { $queued++ }
    }
    return @{ Running = $running; Queued = $queued; Done = $done; Failed = $failed }
}
#endregion

Export-ModuleMember -Function New-JobQueue, Add-Job, Get-NextJob, Update-JobStatus, Get-QueueSummary
