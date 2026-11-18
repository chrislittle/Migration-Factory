<#
.SYNOPSIS
    Wave worker process: lease -> run the state machine -> release, until no
    leasable work remains (all terminal, all leased elsewhere, or wave halted).
.DESCRIPTION
    Spawned by Start-VmfWave, one process per throttle slot. Workers share no
    memory - coordination is entirely lease/state-store based, so a killed
    worker costs one VM-step (resumed after the watchdog reaps its lease).

    Test seam: when VMF_TEST_ENGINE is set (path to a .ps1), the worker invokes
    it instead of the real state machine: & script <entryJson> <runPath> <runId>
    and expects it to leave the state doc terminal. Used by the multi-process
    integration test to exercise real process leasing without Azure.
    TEST-SEAM-HARDEN-1: in the hosted engine (a managed identity endpoint in
    the environment) this seam and VMF_TEST_AZURE_GUARD refuse: the worker
    takes no machine and exits 4.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RunPath,
    [Parameter(Mandatory)][string]$PlanPath,
    [Parameter(Mandatory)][string]$Wave,
    [Parameter(Mandatory)][string]$RunId,
    [Parameter(Mandatory)][string]$WorkerId,

    # CI-SPEED-2: how long to wait when every machine is held by another
    # worker. The DEFAULT IS THE PRODUCTION VALUE and is unchanged - polling a
    # lease store harder than this buys nothing on a real wave.
    #
    # It is a parameter so a test can ask for a short one. The multi-process
    # test spawns two real workers over four machines, so one of them always
    # meets this wait, and it alone was 30 of the file's 45 seconds. Making it
    # injectable keeps the contention real - two processes, real leases, a real
    # wait - and stops the suite paying half a minute for a sleep.
    [Parameter()][int]$IdleWaitSeconds = 30,

    # WAVE-MIX-2: the version of THIS WAVE of the plan the wave's start checks
    # passed (acknowledgement, accepted settings, approval, quota).
    # Start-VmfWave always passes it. The worker reads the plan again, AFTER
    # those checks - so an edit made in between would otherwise run with none
    # of them.
    # WAVE-APPROVE-1: the wave's version (Get-VmfWaveVersion), not the whole
    # plan's. It covers every entry of the wave and the plan-wide fields -
    # everything that let the wave start; the quota check's whole-plan family
    # totals can only refuse - so an edit to this wave is still caught, and an
    # edit to another wave, which keeps this wave's approval, no longer stops
    # its workers.
    [Parameter()][string]$WaveVersion = ''
)

$ErrorActionPreference = 'Stop'
# TEST-SEAM-HARDEN-1: both test seams below refuse in the hosted engine. The
# marker is a managed identity endpoint in the environment - IDENTITY_ENDPOINT,
# or MSI_SECRET on an older host. The Container Apps platform sets it in the
# engine job, the engine's own sign-in (Connect-AzAccount -Identity in
# docker/entrypoint.ps1) needs it, and the web service takes its tokens from it
# (FACADE-SIGNIN-COLD-1). No developer machine or test runner
# has it. A test value there is a mistake or an attack, so the worker takes no
# machine, runs no test script and loads no guard, and says so - a skip with no
# word would let a wave report as if it ran.
$testSeams = @(@('VMF_TEST_AZURE_GUARD', 'VMF_TEST_ENGINE') | Where-Object { [Environment]::GetEnvironmentVariable($_) })
if ($testSeams.Count -gt 0 -and ($env:IDENTITY_ENDPOINT -or $env:MSI_SECRET)) {
    $refusal = "Worker $WorkerId runs in the hosted engine, and the test setting $($testSeams -join ' and ') is set. " +
               'The worker took no machine. Remove the setting from the engine job.'
    # The run history line is best effort (STEP-LOG-5); stderr and the exit
    # code are not, and Start-VmfWave reports both (EVAL-M3).
    try {
        Import-Module (Join-Path $PSScriptRoot '..' 'VmMigrationFactory.psd1') -Force
        & (Get-Module VmMigrationFactory) { param($rp, $d) Write-VmfStepLine -RunPath $rp -Step 'worker' -Outcome refused -Detail $d } $RunPath $refusal
    }
    catch { [Console]::Error.WriteLine("The run history line was not written: $($_.Exception.Message)") }
    [Console]::Error.WriteLine($refusal)
    exit 4
}
# TEST-AZURE-GUARD-2: a second test seam. A unit test must never reach Azure,
# and a worker that a test starts is a new process that no Pester mock reaches.
# The test runner sets VMF_TEST_AZURE_GUARD for every test process, and a
# worker started there turns every Az cmdlet into a test error before it loads
# the module. The value is a switch, never a path: the guard is read from the
# repository's tests folder, which no image carries, so in an install the
# value does nothing.
if ($env:VMF_TEST_AZURE_GUARD) {
    $azureGuard = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' '..' 'tests' 'unit' '_AzureGuard.ps1'))
    if (Test-Path -LiteralPath $azureGuard -PathType Leaf) {
        . $azureGuard
        Block-VmfAzureCallsInProcess
        Write-Host "[$WorkerId] test Azure guard on"
    }
}
Import-Module (Join-Path $PSScriptRoot '..' 'VmMigrationFactory.psd1') -Force
$module = Get-Module VmMigrationFactory

$plan = & $module { param($file, $expected, $rp, $w, $wid)
    $read = Read-VmfPlanFileVersioned -Path $file
    # Ordinal: a version is lower-case hex, and a looser comparison can only
    # take more.
    if ($expected -and (-not $read -or -not [string]::Equals((Get-VmfWaveVersion -PlanText $read.Text -Wave $w), $expected, [System.StringComparison]::Ordinal))) {
        Write-VmfStepLine -RunPath $rp -Step 'worker' -Outcome refused `
            -Detail ("The plan changed after wave $w passed its start checks, so $wid took no machine. " +
                     'Accept and approve the wave again, then start it.')
        return $null
    }
    $read.Plan
} $PlanPath $WaveVersion $RunPath $Wave $WorkerId
# Non-zero, and said on stderr: Start-VmfWave reports a wave whose workers all
# stopped with the workers' own last words (EVAL-M3). Exit 0 would end the wave
# as "ok" with every machine still waiting.
if (-not $plan) { [Console]::Error.WriteLine("The plan changed after wave $Wave passed its start checks. No machine was taken."); exit 3 }

# STEP-LOG-5: every line of the worker goes through Write-VmfStepLine. A line
# that cannot be written stopped the worker with a machine leased, and its
# next machines waited for the watchdog.
$waitedSince = $null
while ($true) {
    $claim = & $module { param($rp, $p, $w, $id) Get-VmfNextWaveVm -RunPath $rp -Plan $p -Wave $w -WorkerId $id } `
        $RunPath $plan $Wave $WorkerId
    if (-not $claim) {
        # SCALE-2 (found by the scale-out drill's kill test, 2026-09-05):
        # nothing leasable is NOT the same as nothing left. A machine held by
        # a worker that has died - in another container, or in this one -
        # stays leased until its heartbeat expires and the orchestrator's
        # watchdog reaps it. A worker that exited here left that machine to
        # a whole-execution restart by the stall watchdog, twenty minutes
        # later. So: while the wave is still pending and not halted, WAIT,
        # and take the machine the moment it is freed. Idle costs nothing;
        # the orchestrator ends the wave when every machine is settled.
        # Only while a lease exists at all - live, or expired and waiting for
        # the watchdog. No lease and nothing leasable means nothing will ever
        # free up (a machine claimed by another run, say), and waiting would
        # hold the execution open for nothing.
        $pending = & $module { param($rp, $p, $w)
            (Test-VmfWavePending -RunPath $rp -Plan $p -Wave $w) -and -not (Test-VmfWaveHalted -RunPath $rp) -and
            (@(Get-VmfStoreNames -RunPath $rp -Folder 'leases' -Extension '.lease').Count -gt 0)
        } $RunPath $plan $Wave
        if (-not $pending) { break }   # done, halted, or nothing held by anyone: nothing will free up
        if (-not $waitedSince) { $waitedSince = Get-Date; Write-Host "[$WorkerId] nothing leasable yet - machines are held elsewhere; waiting" }
        Start-Sleep -Seconds $IdleWaitSeconds
        continue
    }
    $waitedSince = $null

    $entry = $claim.Entry
    $vmName = ($entry.vmId -split '/')[-1]

    # WAVE-MIX-2: this worker holds the plan it read at the start. If the
    # machine was moved or its target changed since, leave it untouched: give
    # back the lease and the claim, and never take it again in this execution.
    # REBUILD-ACCEPT-MACHINE-1: with the run, so a decision a person made on a
    # stopped machine of this wave is run as the plan says now - while the
    # wave is still accepted and approved - never on this worker's old copy.
    $fresh = & $module { param($file, $e, $rp) Test-VmfLeasedEntryCurrent -PlanPath $file -Entry $e -RunPath $rp } $PlanPath $entry $RunPath
    if (-not $fresh.Current) {
        & $module {
            param($rp, $e, $wid, $grp, $why, $w)
            Write-VmfStepLine -RunPath $rp -Step 'worker' -Outcome refused -VmId $e.vmId `
                -Detail "The plan changed for this machine after wave $w started ($why), so $wid did not touch it. Accept and approve its wave again, then start it."
            try { Remove-VmfLease -RunPath $rp -VmId $e.vmId -WorkerId $wid } catch { Write-Verbose "lease already gone: $_" }
            if ($grp) { try { Remove-VmfLease -RunPath $rp -VmId $grp -WorkerId $wid } catch { Write-Verbose "group lease already gone: $_" } }
            # The claim was taken under run.json's id (Get-VmfNextWaveVm), so it is released under it.
            $claimRunId = [string](Read-VmfStoreJson -RunPath $rp -RelPath 'run.json' -Depth 6).runId
            try { Remove-VmfVmClaim -RunPath $rp -VmId $e.vmId -RunId $claimRunId | Out-Null } catch { Write-Verbose "claim already gone: $_" }
        } $RunPath $entry $WorkerId $claim.GroupLockId $fresh.Reason $Wave
        $plan.entries = @($plan.entries | Where-Object { [string]$_.vmId -ne [string]$entry.vmId })
        continue
    }
    if ($fresh.Changed) {
        & $module { param($rp, $id, $w, $wid)
            Write-VmfStepLine -RunPath $rp -Step 'worker' -Outcome info -VmId $id `
                -Detail "A decision changed this machine after wave $w started. The wave is still accepted and approved, so $wid uses the plan as it is now."
        } $RunPath $entry.vmId $Wave $WorkerId
    }
    $entry = $fresh.Entry

    & $module { param($rp, $id, $wid) Write-VmfStepLine -RunPath $rp -Step 'worker' -Outcome info -VmId $id -Detail "leased by $wid" } `
        $RunPath $entry.vmId $WorkerId

    try {
        if ($env:VMF_TEST_ENGINE) {
            & $env:VMF_TEST_ENGINE ($entry | ConvertTo-Json -Depth 24 -Compress) $RunPath $RunId
        }
        else {
            # Self-contained per the engine's Heartbeat contract (args, no closure)
            $heartbeat = {
                param($rp, $vmid, $wid)
                & (Get-Module VmMigrationFactory) {
                    param($a, $b, $c) Update-VmfLeaseHeartbeat -RunPath $a -VmId $b -WorkerId $c
                } $rp $vmid $wid
            }
            & $module {
                param($e, $rp, $rid, $wid, $hb)
                Invoke-VmfStateMachine -PlanEntry $e -RunPath $rp -RunId $rid -WorkerId $wid -Heartbeat $hb | Out-Null
            } $entry $RunPath $RunId $WorkerId $heartbeat
        }
    }
    catch {
        # Heartbeat loss or engine crash: record and abandon this VM. The state
        # doc is checkpointed; the watchdog/next worker resumes it.
        & $module { param($rp, $id, $msg) Write-VmfStepLine -RunPath $rp -Step 'worker' -Outcome fail -VmId $id -Detail $msg } `
            $RunPath $entry.vmId "worker ${WorkerId}: $($_.Exception.Message)"
    }
    finally {
        & $module {
            param($rp, $id, $wid, $grp)
            try { Remove-VmfLease -RunPath $rp -VmId $id -WorkerId $wid } catch { Write-Verbose "lease already gone: $_" }
            if ($grp) { try { Remove-VmfLease -RunPath $rp -VmId $grp -WorkerId $wid } catch { Write-Verbose "group lease already gone: $_" } }
            # CLAIM-KEPT-AFTER-WAVE-1: a machine that settled (MIGRATED or
            # SKIPPED) gives its claim back here, after its final checkpoint -
            # never only at the end of the wave, which an execution that stops
            # first never reaches. Any other state keeps the claim. Never a
            # failure of the machine: the end-of-wave pass tries again.
            try { Remove-VmfSettledVmClaim -RunPath $rp -VmId $id | Out-Null } catch { Write-Verbose "claim not released here, the end of the wave tries again: $_" }
        } $RunPath $entry.vmId $WorkerId $claim.GroupLockId
    }
    Write-Host "[$WorkerId] finished $vmName"
}
Write-Host "[$WorkerId] no more leasable work - exiting"
