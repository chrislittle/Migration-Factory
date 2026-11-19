<#
    PUBLISH-RUN-LOG-1: wait for one run of a Container Apps job, and keep what
    the run wrote to its console.

    WHY. MEASURED in the lab on 2026-11-05: an `azd up` failed because the
    publish run ended as Failed, in under a minute, and the next `azd up` passed
    with no change. Every place that should have held the cause held nothing:

      az containerapp job execution show   status Failed and the template; no reason
      az containerapp job logs show        nothing - the replica was already gone
      Log Analytics                        nothing - the console table had stopped,
                                           and it cannot be read from outside a
                                           network security perimeter anyway

    The run's console is the one place the cause is, and it lives only as long
    as the replica. So it is read WHILE the run lives, from the operator's
    machine (measured: this works for a live run from outside the perimeter),
    into a file, and the end of it goes in the error.

    HOW THE READ IS MADE, AND WHY IT IS MADE THIS WAY. Each fact below is from
    the containerapp extension's own source (custom.py, stream_job_logs), read
    on 2026-11-05:

      - `--container` is REQUIRED (`az containerapp job logs show --help`).
      - With no `--replica`, the command asks Azure for the execution's
        replicas and stops at once with "No replicas found for execution" when
        there are none yet. A read started the moment the job starts usually
        meets that, so a read that ends while the run lives is STARTED AGAIN.
      - The lines are written with Python's print() and no flush, and az.cmd
        starts Python with -I, which ignores PYTHONUNBUFFERED. Into a file, the
        output is held in a buffer until the process ends. So a read is given
        time to END BY ITSELF when the run ends (the stream closes with the
        container), and is ended by force only after that; a forced end says
        the output can be incomplete.
      - `--tail` accepts 0 to 300; 300 is asked for, so a read started again
        gets everything from the start of a short run.

    Every read writes its own file. A replica that is gone answers a new read
    with nothing, and that must never erase what an earlier read kept - so the
    longest read is the one kept.

    WHAT IT NEVER SAYS. "The run wrote nothing" only when a read connected and
    ended by itself with no lines. A read that never connected, or that had to
    be ended, proves nothing about the run, and the message says that instead.

    Install tooling, not the module: like the rest of tools/ and infra/, it
    calls the Azure CLI directly.
#>

# INSTALL-THROTTLE-RETRY-2: the run's status and console reads try a throttled
# answer again.
. (Join-Path $PSScriptRoot 'Invoke-VmfAzStep.ps1')

function Get-VmfJobConsoleArguments {
    <#
    .SYNOPSIS
        The az arguments that read one execution's console, as text.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$JobName,
        [Parameter(Mandatory)][string]$Execution,
        [Parameter(Mandatory)][string]$Container,
        [switch]$Follow
    )
    $a = [System.Collections.Generic.List[string]]::new()
    $a.AddRange([string[]]@('containerapp', 'job', 'logs', 'show',
            '-g', $ResourceGroup, '-n', $JobName,
            '--container', $Container, '--execution', $Execution))
    if ($Follow) { $a.Add('--follow') }
    $a.AddRange([string[]]@('--tail', '300', '--format', 'text', '--only-show-errors'))
    , $a.ToArray()
}

function Get-VmfJobConsolePath {
    <#
    .SYNOPSIS
        Where one execution's console is kept: the azd environment's folder
        (.azure/<environment>, which git ignores) when azd runs the install,
        else the temporary folder (a run by hand).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Execution,
        [string]$RepoRoot = '',
        [string]$EnvironmentName = ''
    )
    $dir = [System.IO.Path]::GetTempPath()
    # Only a plain name: an environment name is azd's, and a path in it is not
    # a folder azd made.
    if ($RepoRoot -and $EnvironmentName -and $EnvironmentName -match '^[A-Za-z0-9][A-Za-z0-9._-]*$' -and $EnvironmentName -notmatch '\.\.') {
        $envDir = Join-Path $RepoRoot '.azure' $EnvironmentName
        if (Test-Path -LiteralPath $envDir -PathType Container) { $dir = $envDir }
    }
    Join-Path $dir "$Execution.console.log"
}

function Start-VmfJobConsoleFollow {
    <#
    .SYNOPSIS
        Starts one console read in its own process, with its output and its
        errors each in a file. Returns the process.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$OutPath,
        [Parameter(Mandatory)][string]$ErrPath,
        [string]$AzPath = ''
    )
    if (-not $AzPath) {
        # az on Windows is az.cmd; a process is started from a full path, not
        # from a name the shell would look up.
        $AzPath = @(Get-Command az -CommandType Application -ErrorAction Stop)[0].Source
    }
    Start-Process -FilePath $AzPath -ArgumentList $Arguments -NoNewWindow -PassThru `
        -RedirectStandardOutput $OutPath -RedirectStandardError $ErrPath
}

function Stop-VmfJobConsoleFollow {
    <#
    .SYNOPSIS
        Gives a console read time to end by itself, then ends it with every
        process under it. True when it ended by itself (or there was none).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][AllowNull()]$Process,
        [int]$WaitSeconds = 30
    )
    if (-not $Process) { return $true }
    if ($Process.WaitForExit($WaitSeconds * 1000)) { return $true }
    # az.cmd runs Python under cmd.exe: ending only the first process would
    # leave the read running after the install.
    try { $Process.Kill($true) } catch { $null = $_ }
    $null = $Process.WaitForExit(10000)
    return $false
}

function Wait-VmfJobRun {
    <#
    .SYNOPSIS
        Waits for one execution of a Container Apps job to end, reading its
        console while it runs.
    .DESCRIPTION
        Returns an object:

          Status       Succeeded, Failed, Degraded or Stopped; empty when the
                       run had not ended by the time limit
          Read         lines   - the console gave lines; they are in Lines
                       empty   - a read connected and ended by itself with no
                                 lines: the run wrote nothing
                       unread  - no read connected, or one had to be ended
                                 with nothing; ReadError says what Azure said
          Lines        what the run wrote (the most kept by any one read)
          Cut          a read had to be ended, so the end can be missing
          ReadError    the last error a read gave
          ConsolePath  the file the lines are in
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$JobName,
        [Parameter(Mandatory)][string]$Execution,
        [Parameter(Mandatory)][string]$Container,
        [Parameter(Mandatory)][string]$ConsolePath,
        [double]$TimeoutMinutes = 18,
        [int]$PollSeconds = 5,
        [int]$MaxReads = 60
    )

    # The statuses Azure gives an execution that has ended (JobExecutionRunningState
    # in the containerapp extension: Running, Processing, Stopped, Degraded,
    # Failed, Unknown, Succeeded).
    $ended = @('Succeeded', 'Failed', 'Degraded', 'Stopped')
    $followArgs = Get-VmfJobConsoleArguments -ResourceGroup $ResourceGroup -JobName $JobName `
        -Execution $Execution -Container $Container -Follow

    $reads = [System.Collections.Generic.List[object]]::new()
    $current = $null
    $status = ''
    $endedItself = $true
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $best = @()
    $connected = $false
    $readError = ''
    # The read files are removed in the OUTER finally, so a throw or Ctrl+C
    # anywhere below leaves none of them behind.
    try {
    try {
        while ((Get-Date) -lt $deadline) {
            if ((-not $current -or $current.HasExited) -and $reads.Count -lt $MaxReads) {
                $out = '{0}.read{1}' -f $ConsolePath, ($reads.Count + 1)
                $read = [pscustomobject]@{ Out = $out; Err = "$out.err"; Process = $null; StartError = '' }
                try { $read.Process = Start-VmfJobConsoleFollow -Arguments $followArgs -OutPath $read.Out -ErrPath $read.Err }
                catch { $read.StartError = [string]$_.Exception.Message }
                $reads.Add($read)
                $current = $read.Process
            }
            Start-Sleep -Seconds $PollSeconds
            # INSTALL-THROTTLE-RETRY-2: a throttled read is tried again; any
            # other failure is one more poll, as before.
            $poll = Invoke-VmfAzCall -Step "read the run $Execution of $JobName" -Quiet -Command {
                az containerapp job execution show -g $ResourceGroup -n $JobName --job-execution-name $Execution -o json
            }
            if ($poll.ExitCode -ne 0) { continue }
            $json = $poll.Output
            try { $status = [string](($json | ConvertFrom-Json).properties.status) } catch { $status = '' }
            if ($status -in $ended) { break }
            $status = ''
        }
    }
    finally {
        $endedItself = Stop-VmfJobConsoleFollow -Process $current
    }

    # What each read gave.
    foreach ($read in $reads) {
        $lines = @()
        if (Test-Path -LiteralPath $read.Out) {
            $lines = @(Get-Content -LiteralPath $read.Out | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
        if ($lines.Count -gt $best.Count) { $best = $lines }
        $errText = ''
        if (Test-Path -LiteralPath $read.Err) { $errText = [string](Get-Content -LiteralPath $read.Err -Raw) }
        if ($read.StartError) { $errText = $read.StartError }
        $errLines = @(([string]$errText) -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($errLines.Count -gt 0) { $readError = $errLines[-1].Trim() }
        # Connected: the read ended BY ITSELF, with no error. A read that was
        # ended by force has not exited 0, so it never counts.
        if ($read.Process -and $read.Process.HasExited -and $read.Process.ExitCode -eq 0 -and $errLines.Count -eq 0) {
            $connected = $true
        }
    }
    if (-not $endedItself -and $best.Count -eq 0) {
        $readError = "The console read did not end by itself after the run, and gave no lines."
    }

    # The run has ended, and the follow kept nothing: one plain read, in case
    # the replica is still there.
    if ($best.Count -eq 0 -and -not $connected) {
        $readArgs = Get-VmfJobConsoleArguments -ResourceGroup $ResourceGroup -JobName $JobName `
            -Execution $Execution -Container $Container
        # INSTALL-THROTTLE-RETRY-2: a throttled read is tried again.
        $lateRead = Invoke-VmfAzCall -Step "read the console of the run $Execution" -Quiet -Command { az @readArgs }
        if ($lateRead.ExitCode -eq 0) {
            $best = @($lateRead.Output | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($best.Count -eq 0) { $connected = $true }
        }
        else {
            $lateErr = @(@($lateRead.Output | ForEach-Object { [string]$_ }) + @($lateRead.ErrorLines) |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($lateErr.Count -gt 0) { $readError = $lateErr[-1].Trim() }
        }
    }
    }
    finally {
        foreach ($read in $reads) {
            Remove-Item -LiteralPath $read.Out, $read.Err -Force -ErrorAction SilentlyContinue
        }
    }

    [System.IO.File]::WriteAllLines($ConsolePath, [string[]]$best)

    $state = if ($best.Count -gt 0) { 'lines' } elseif ($connected) { 'empty' } else { 'unread' }
    [pscustomobject]@{
        Status      = $status
        Read        = $state
        Lines       = [string[]]$best
        Cut         = (-not $endedItself)
        ReadError   = $readError
        ConsolePath = $ConsolePath
    }
}

function Format-VmfJobRunFailure {
    <#
    .SYNOPSIS
        The message for a run that did not succeed: what Azure said about it,
        and what the run wrote - or, plainly, that it wrote nothing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$What,
        [Parameter(Mandatory)][string]$JobName,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$Execution,
        [Parameter()][AllowEmptyString()][string]$Status = '',
        [Parameter(Mandatory)][ValidateSet('lines', 'empty', 'unread')][string]$Read,
        [Parameter()][AllowEmptyCollection()][string[]]$Lines = @(),
        [Parameter()][AllowEmptyString()][string]$ReadError = '',
        [Parameter()][string]$ConsolePath = '',
        [switch]$Cut,
        [int]$TimeoutMinutes = 18,
        [int]$TailLines = 40
    )
    $nl = [Environment]::NewLine
    $m = [System.Text.StringBuilder]::new()
    if ($Status) { [void]$m.Append("$What $JobName ended as $Status (execution $Execution).") }
    else { [void]$m.Append("$What $JobName had not ended after $TimeoutMinutes minutes (execution $Execution).") }
    [void]$m.Append(' The install stopped before it restarted the service.')

    switch ($Read) {
        'lines' {
            $tail = @($Lines | Select-Object -Last $TailLines)
            [void]$m.Append("$nl${nl}The last $($tail.Count) lines the run wrote:$nl")
            foreach ($line in $tail) { [void]$m.Append("  $line$nl") }
            if ($ConsolePath) { [void]$m.Append("All of its output is in $ConsolePath$nl") }
            if ($Cut) { [void]$m.Append("The read of the console did not end by itself, so this output can be incomplete.$nl") }
        }
        'empty' {
            # Only what was measured: the read connected and got no lines. A
            # run that DID start also gives nothing once its replica is gone
            # (lab, 2026-11-05), so the cause is never stated as fact.
            [void]$m.Append("$nl${nl}The read of the console connected and got no lines. So the run most likely stopped before its script started: at the image pull, the identity or the start.$nl")
        }
        'unread' {
            [void]$m.Append("$nl${nl}This tool could not read the console of the run.")
            if ($ReadError) { [void]$m.Append(" Azure said: $ReadError") }
            [void]$m.Append($nl)
            if ($ReadError -match 'No replicas found') {
                [void]$m.Append("Azure showed no replica for the run while this tool read it. So the run most likely stopped before its script started: at the image pull, the identity or the start.$nl")
            }
        }
    }
    [void]$m.Append("${nl}Azure's record of the run:$nl")
    [void]$m.Append("  az containerapp job execution show -g $ResourceGroup -n $JobName --job-execution-name $Execution")
    $m.ToString()
}
