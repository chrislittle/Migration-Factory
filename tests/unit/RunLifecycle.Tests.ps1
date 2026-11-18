#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# RUN-LIFECYCLE-1, raised then ruled 2026-08-28: a run that has
# only been scanned looked exactly like one being migrated with - it appeared
# in reports, offered actions, could not be resumed where the person left off,
# and could not be thrown away.
#
# The ruling was a visible life rather than a delayed birth, because the scan
# IS the first real action and the wizard's middle steps display its results.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Script:Plan([int]$n) {
        [pscustomobject]@{ entries = @(1..$n | ForEach-Object {
            [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm$_"; wave = 'w1'; path = 'A' } }) }
    }
    function Script:Doc([int]$i, [string]$state, $safety = $null, $retention = $null) {
        $d = [pscustomobject]@{
            vmId = "/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm$i"
            state = $state
        }
        if ($safety) { $d | Add-Member -NotePropertyName safety -NotePropertyValue $safety }
        if ($retention) { $d | Add-Member -NotePropertyName retention -NotePropertyValue $retention }
        $d
    }
    function Script:Stage($plan, $docs) {
        InModuleScope VmMigrationFactory -Parameters @{ p = $plan; d = $docs } { Get-VmfRunStage -Plan $p -StateDocs $d }
    }
}

Describe 'RUN-LIFECYCLE-1: the stage is derived, so it cannot drift' {
    It 'a scan with no plan is STILL BEING SET UP, not a migration' {
        $r = Script:Stage $null @()
        $r.Stage | Should -Be 'setup'
        $r.Detail | Should -Match 'nothing has been planned'
    }

    It 'a plan whose machines are all untouched is PLANNED' {
        # EVAL-M15: these fixtures said 'QUEUED', a state no engine writes, and
        # so they passed while the guard they were checking was wrong for every
        # real document. The fixture is now the state the store actually writes.
        (Script:Stage (Script:Plan 3) @()).Stage | Should -Be 'planned'
        (Script:Stage (Script:Plan 3) @((Script:Doc 1 'PLANNED'))).Stage | Should -Be 'planned'
    }

    It 'one machine on its way makes the run RUNNING' {
        (Script:Stage (Script:Plan 3) @((Script:Doc 1 'CONVERTING'))).Stage | Should -Be 'running'
    }

    It 'a run is FINISHED only when every machine has settled' {
        $plan = Script:Plan 2
        (Script:Stage $plan @((Script:Doc 1 'MIGRATED'))).Stage | Should -Be 'running'
        (Script:Stage $plan @((Script:Doc 1 'MIGRATED'), (Script:Doc 2 'MIGRATED'))).Stage | Should -Be 'finished'
    }

    It 'a machine waiting for a person counts as settled - the RUN is not still working' {
        # It needs somebody, not a worker. Calling the run "running" for ever
        # would hide it in the wrong place on every screen.
        $plan = Script:Plan 2
        (Script:Stage $plan @((Script:Doc 1 'MIGRATED'), (Script:Doc 2 'NEEDS_DECISION'))).Stage | Should -Be 'finished'
    }
}

# UNWAVED-MACHINES-UNDERWAY-1 (final lab, 2026-11-16): every wave had finished,
# and three planned machines were in no wave - their wave was deleted, or a
# person left them out. The stage counted them as not settled, so Delete this
# migration said "under way: 14 of 17 machines settled" and asked for Stop this
# migration, which the page does not show when nothing runs. A machine in no
# wave with no state document is not part of the migration
# (NOT-IN-WAVE-QUEUED-1, Test-VmfEntryOutsideRun): no wave takes it.
Describe 'UNWAVED-MACHINES-UNDERWAY-1: a machine in no wave that never ran is not under way' {
    BeforeAll {
        # Machines 1..$inWave in wave w1; the rest in no wave, spelled both
        # ways the plan holds it: the planner's 'unscheduled', and no name.
        function Script:MixedPlan([int]$inWave, [int]$noWave) {
            $n = 0
            [pscustomobject]@{ entries = @(
                    1..($inWave + $noWave) | ForEach-Object {
                        $n++
                        $w = if ($n -le $inWave) { 'w1' } elseif ($n % 2) { 'unscheduled' } else { $null }
                        [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm$_"; wave = $w; path = 'A' }
                    }) }
        }
    }

    It 'every machine in a wave settled, three in no wave: FINISHED, and they are in no count' {
        $plan = Script:MixedPlan 3 3
        $r = Script:Stage $plan @((Script:Doc 1 'MIGRATED'), (Script:Doc 2 'SKIPPED'), (Script:Doc 3 'FAILED_ROLLED_BACK'))
        $r.Stage | Should -Be 'finished'
        $r.Machines | Should -Be 3
        $r.Settled | Should -Be 3
        $r.Detail | Should -Be 'finished: all 3 machines have settled'
    }

    It 'a machine in no wave WITH a state document has history, and still counts' {
        $plan = Script:MixedPlan 2 2
        (Script:Stage $plan @((Script:Doc 1 'MIGRATED'), (Script:Doc 2 'MIGRATED'), (Script:Doc 3 'CONVERTING'))).Stage | Should -Be 'running'
        (Script:Stage $plan @((Script:Doc 1 'MIGRATED'), (Script:Doc 2 'MIGRATED'), (Script:Doc 4 'MIGRATED'))).Stage | Should -Be 'finished'
    }

    It 'a machine IN a wave with no state document is still not settled' {
        # Its wave takes it when it starts: not the case this item changes.
        (Script:Stage (Script:MixedPlan 3 2) @((Script:Doc 1 'MIGRATED'))).Stage | Should -Be 'running'
    }

    It 'a plan whose machines are all in no wave and never ran is PLANNED, not setup' {
        # Setup means no plan. The daily cleanup reads setup as that.
        $r = Script:Stage (Script:MixedPlan 0 3) @()
        $r.Stage | Should -Be 'planned'
    }
}

Describe 'RUN-LIFECYCLE-1: what may be thrown away' {
    BeforeAll {
        function Script:Discard($plan, $docs) {
            InModuleScope VmMigrationFactory -Parameters @{ p = $plan; d = $docs } { Test-VmfRunDiscardable -Plan $p -StateDocs $d }
        }
    }

    It 'refuses while a machine is part-way through a move, and names it' {
        $r = Script:Discard (Script:Plan 2) @((Script:Doc 1 'CONVERTING'), (Script:Doc 2 'PLANNED'))
        $r.Ok | Should -BeFalse
        $r.Detail | Should -Match 'vm1'
        $r.Detail | Should -Match '(?i)knows how to roll it back'
    }

    It 'ALLOWS a settled run, even one whose machines were touched' {
        # A refusal here would lock a machine into a run plan that may need
        # to be done again after an error.
        $r = Script:Discard (Script:Plan 2) @((Script:Doc 1 'MIGRATED'), (Script:Doc 2 'FAILED_ROLLED_BACK'))
        $r.Ok | Should -BeTrue
    }

    It 'but names the safety copies that would be orphaned' {
        $safety = [pscustomobject]@{ pristineSnapshotId = '/snap/pristine'; snapshotId = '/snap/prepared' }
        $r = Script:Discard (Script:Plan 1) @((Script:Doc 1 'MIGRATED' $safety))
        $r.Ok | Should -BeTrue
        @($r.OrphanSnapshots).Count | Should -Be 2
        $r.Detail | Should -Match '(?i)bill for ever|billing'
    }

    It 'copies already cleaned up are not counted twice' {
        $safety = [pscustomobject]@{ pristineSnapshotId = '/snap/pristine'; snapshotId = $null }
        $ret = [pscustomobject]@{ deletedUtc = '2026-08-01T00:00:00Z'; keepDays = 7 }
        $r = Script:Discard (Script:Plan 1) @((Script:Doc 1 'MIGRATED' $safety $ret))
        @($r.OrphanSnapshots).Count | Should -Be 0
    }

    It 'a run that never got past setup is discardable with nothing outstanding' {
        $r = Script:Discard $null @()
        $r.Ok | Should -BeTrue
        @($r.OrphanSnapshots).Count | Should -Be 0
    }
}

Describe 'RUN-LIFECYCLE-1: Remove-VmfRun' {
    BeforeEach {
        $script:store = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rm-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:run = Join-Path $script:store 'run-x'
        $script:vm = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; vm = $script:vm } {
            Initialize-VmfRun -RunPath $rp -RunId 'run-x' | Out-Null
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 12 -Document ([ordered]@{
                schemaVersion = 8; entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $vm; wave = 'w1'; path = 'A' }) })
            New-VmfStateDoc -RunPath $rp -RunId 'run-x' -VmId $vm -Wave 'w1' | Out-Null
            New-VmfVmClaim -RunPath $rp -VmId $vm -RunId 'run-x' | Out-Null
        }
        Mock -ModuleName VmMigrationFactory Get-VmfSignedInIdentity { @{ Identity = 'operator@contoso.com' } }
        Mock -ModuleName VmMigrationFactory Remove-VmfSnapshot { }
        Mock -ModuleName VmMigrationFactory Unlock-VmfSnapshot { }
    }
    AfterEach { if (Test-Path $script:store) { Remove-Item $script:store -Recurse -Force } }

    It 'refuses while a machine is part-way through a move' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; vm = $script:vm } {
            Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'CONVERTING' -Outcome ok | Out-Null
        }
        { Remove-VmfRun -RunPath $script:run -Reason 'x' -Confirm:$false } | Should -Throw '*knows how to roll it back*'
    }

    It 'insists on a decision about safety copies rather than silently orphaning them' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; vm = $script:vm } {
            Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'MIGRATED' -Outcome ok | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $vm
            $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{
                pristineSnapshotId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/snapshots/s1'
                snapshotId = $null; cloneVmId = $null }) -Force
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        { Remove-VmfRun -RunPath $script:run -Reason 'x' -Confirm:$false } | Should -Throw '*-DeleteSafetyCopies*'
    }

    It 'deletes the records, releases the machines, and reports what it did' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; vm = $script:vm } {
            Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'MIGRATED' -Outcome ok | Out-Null
        }
        $r = Remove-VmfRun -RunPath $script:run -Reason 'abandoned first attempt' -Confirm:$false
        $r.Removed | Should -BeTrue
        $r.MachinesReleased | Should -Be 1
        $r.RemovedBy | Should -Be 'operator@contoso.com'
        Test-Path $script:run | Should -BeFalse

        # and the machine is genuinely free for another migration
        $other = Join-Path $script:store 'run-y'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $other; vm = $script:vm } {
            Initialize-VmfRun -RunPath $rp -RunId 'run-y' | Out-Null
            (New-VmfVmClaim -RunPath $rp -VmId $vm -RunId 'run-y').Granted | Should -BeTrue
        }
    }

    It 'takes the safety copies with it when told to' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; vm = $script:vm } {
            Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'MIGRATED' -Outcome ok | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $vm
            $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{
                pristineSnapshotId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/snapshots/s1'
                snapshotId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/snapshots/s2'; cloneVmId = $null
                # SAFETY-RETRY-1: an earlier attempt's copy is the run's too.
                earlierCopies = @([pscustomobject]@{ pristineSnapshotId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/snapshots/s0'; keptUtc = '2026-09-20T00:00:00Z' }) }) -Force
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        $script:calls = [System.Collections.Generic.List[string]]::new()
        # DISCARD-ENGINE-1: each copy is read before (a copy already gone is
        # skipped) and after (it must really be gone) - so Azure is simulated:
        # there until its delete, gone after it.
        $script:gone = [System.Collections.Generic.HashSet[string]]::new()
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { -not $script:gone.Contains($SnapshotId) }
        Mock -ModuleName VmMigrationFactory Unlock-VmfSnapshot { $script:calls.Add("unlock $SnapshotId") }
        Mock -ModuleName VmMigrationFactory Remove-VmfSnapshot { $script:calls.Add("remove $SnapshotId"); [void]$script:gone.Add($SnapshotId) }
        $r = Remove-VmfRun -RunPath $script:run -Reason 'x' -DeleteSafetyCopies -Confirm:$false
        $r.SafetyCopiesDeleted | Should -Be 3
        Should -Invoke Remove-VmfSnapshot -ModuleName VmMigrationFactory -Times 3 -Exactly
        # SAFETY-3's lock comes off before each delete - a locked copy refuses it.
        foreach ($id in 's0', 's1', 's2') {
            $script:calls.IndexOf("unlock /subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/snapshots/$id") |
                Should -BeLessThan $script:calls.IndexOf("remove /subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/snapshots/$id")
            $script:calls | Should -Contain "unlock /subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/snapshots/$id"
        }
    }
}

Describe 'Stop-VmfRun: the way out of a run nothing can finish' {
    # A run whose machines had been deleted stayed running for ever: nothing
    # could cancel a run. Every path assumed a machine reaches an end state through the engine. A
    # machine whose worker died - or whose VM no longer exists - never does,
    # and the only per-machine action put it BACK into the pipeline.
    BeforeEach {
        $script:store = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-stop-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:run = Join-Path $script:store 'run-x'
        $script:vm1 = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
        $script:vm2 = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm2'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; a = $script:vm1; b = $script:vm2 } {
            Initialize-VmfRun -RunPath $rp -RunId 'run-x' | Out-Null
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 12 -Document ([ordered]@{
                schemaVersion = 8; entries = @(
                    [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $a; wave = 'w1'; path = 'A' },
                    [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $b; wave = 'w1'; path = 'A' }) })
            foreach ($vm in $a, $b) {
                New-VmfStateDoc -RunPath $rp -RunId 'run-x' -VmId $vm -Wave 'w1' | Out-Null
                New-VmfVmClaim -RunPath $rp -VmId $vm -RunId 'run-x' | Out-Null
            }
            Add-VmfStateTransition -RunPath $rp -VmId $a -NewState 'CONVERTING' -Outcome ok | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $b -NewState 'MIGRATED' -Outcome ok | Out-Null
        }
        Mock -ModuleName VmMigrationFactory Get-VmfSignedInIdentity { @{ Identity = 'operator@contoso.com' } }
    }
    AfterEach { if (Test-Path $script:store) { Remove-Item $script:store -Recurse -Force } }

    It 'closes out the unfinished machines and leaves the finished one alone' {
        $r = Stop-VmfRun -RunPath $script:run -Reason 'lab machines deleted' -Confirm:$false
        $r.MachinesClosedOut | Should -Be 1
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; a = $script:vm1; b = $script:vm2 } {
            (Read-VmfStateDoc -RunPath $rp -VmId $a).state | Should -Be 'SKIPPED'
            (Read-VmfStateDoc -RunPath $rp -VmId $b).state | Should -Be 'MIGRATED' -Because 'a machine that finished did not need rescuing'
            (@(Read-VmfStateDoc -RunPath $rp -VmId $a).history)[-1].detail | Should -Match 'operator@contoso.com'
        }
    }

    It 'PREP-ROLLBACK-1 (review 2): a machine left mid-rollback is not closed as left out - it needs attention, changed' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; a = $script:vm1 } {
            Set-VmfRollbackPending -Context @{ RunPath = $rp; VmId = $a } -Kind 'full' -State 'CONVERTING' -ReasonCode 'rolledBack' -Detail 'x'
        }
        Stop-VmfRun -RunPath $script:run -Reason 'lab machines deleted' -Confirm:$false | Out-Null
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; a = $script:vm1 } {
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $a
            $doc.state | Should -Be 'FAILED_NEEDS_ATTENTION'
            @($doc.history)[-1].machineState | Should -Be 'changed'
            @($doc.history)[-1].reasonCode | Should -Be 'rollbackFailed'
            $doc.PSObject.Properties['rollbackPending'] | Should -BeNullOrEmpty
        }
    }

    It 'releases the machines, so another migration can take them on - but not one it closes part way through its move' {
        # STOP-MIDMOVE-FREED-1 rewrote this: vm1 is at CONVERTING, so Stop
        # closes it as not as it was and keeps its claim (another migration
        # would copy the half-moved machine). vm2 finished, and is released.
        $r = Stop-VmfRun -RunPath $script:run -Reason 'x' -Confirm:$false
        $r.MachinesKept | Should -Be 1
        $r.MachinesReleased | Should -Be 1
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; a = $script:vm1; b = $script:vm2 } {
            Get-VmfVmClaim -RunPath $rp -VmId $b | Should -BeNullOrEmpty
            (Get-VmfVmClaim -RunPath $rp -VmId $a).runId | Should -Be 'run-x'
            @((Read-VmfStateDoc -RunPath $rp -VmId $a).history)[-1].machineState | Should -Be 'changed'
        }
    }

    It 'settles the run, so it can then be thrown away' {
        Stop-VmfRun -RunPath $script:run -Reason 'x' -Confirm:$false | Out-Null
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run } {
            $plan = Read-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24
            $docs = @(Get-VmfStoreNames -RunPath $rp -Folder 'state' -Extension '.json' |
                ForEach-Object { Read-VmfStoreJson -RunPath $rp -RelPath "state/$_" -Depth 24 })
            (Get-VmfRunStage -Plan $plan -StateDocs $docs).Stage | Should -Be 'finished'
            (Test-VmfRunDiscardable -Plan $plan -StateDocs $docs).Ok | Should -BeTrue
        }
    }

    It 'refuses while a live worker still holds a machine' {
        # Marking a machine skipped underneath a working worker would leave two
        # things believing they own it.
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; a = $script:vm1 } {
            New-VmfLease -RunPath $rp -VmId $a -WorkerId 'worker-1' | Out-Null
        }
        { Stop-VmfRun -RunPath $script:run -Reason 'x' -Confirm:$false } | Should -Throw '*still holds*'
    }

    It 'but -Force is the escape hatch when that worker is known to be gone' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; a = $script:vm1 } {
            New-VmfLease -RunPath $rp -VmId $a -WorkerId 'worker-1' | Out-Null
        }
        (Stop-VmfRun -RunPath $script:run -Reason 'worker host was destroyed' -Force -Confirm:$false).Stopped | Should -BeTrue
    }

    It 'pauses the run so nothing is picked up while it is being closed out' {
        Stop-VmfRun -RunPath $script:run -Reason 'x' -Confirm:$false | Out-Null
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run } {
            Test-VmfWaveHalted -RunPath $rp | Should -BeTrue
        }
    }
}

Describe 'A log an older version wrote does not strand its run' {
    # Found clearing a real store: events.jsonl was a BLOCK blob, so appending
    # returned 409 InvalidBlobType - and stopping a run writes a line about
    # stopping it, so the run could not be closed out or removed AT ALL. A log
    # that cannot be appended to must not outrank the run it describes.
    It 'converts the old log in place, keeping what was already in it' {
        InModuleScope VmMigrationFactory {
            $script:calls = [System.Collections.Generic.List[object]]::new()
            Mock Read-VmfStoreText { 'first line' }
            Mock Invoke-VmfStorageRequest {
                $isAppend  = $Uri -match 'comp=appendblock'
                $isCreate  = -not $isAppend -and $Headers -and $Headers['If-None-Match']
                $isConvert = -not $isAppend -and $Headers -and $Headers['x-ms-blob-type'] -eq 'AppendBlob' -and -not $Headers['If-None-Match']
                $convertedAlready = @($script:calls | Where-Object { $_.Convert }).Count -gt 0
                $script:calls.Add(@{ Method = $Method; Uri = $Uri; Body = $Body; Convert = $isConvert })
                if ($Method -eq 'DELETE') { return @{ StatusCode = 202; Content = '' } }
                if ($isCreate)  { return @{ StatusCode = 409; Content = '' } }          # blob is there (as a BLOCK blob)
                if ($isConvert) { return @{ StatusCode = 201; Content = '' } }          # rewritten as an append blob
                if ($isAppend -and -not $convertedAlready) {
                    return @{ StatusCode = 409; Content = '<Error><Code>InvalidBlobType</Code></Error>' }
                }
                return @{ StatusCode = 201; Content = '' }
            }

            { Add-VmfStoreLine -RunPath 'azblob://acct/cont/run-x' -RelPath 'logs/events.jsonl' -Line 'new line' } |
                Should -Not -Throw

            $appends = @($script:calls | Where-Object { $_.Uri -match 'comp=appendblock' })
            @($script:calls | Where-Object { $_.Method -eq 'DELETE' }).Count | Should -Be 1 -Because 'Azure will not change a blob type in place, so the old one must go first'
            @($appends | Where-Object { $_.Body -eq 'first line' }).Count | Should -Be 1 -Because 'what the old log already held must survive the conversion'
            @($appends)[-1].Body | Should -Match 'new line'
        }
    }
}

Describe 'A deletion is recorded somewhere that survives it' {
    It 'writes who deleted the run and why, beside the runs rather than inside the one being deleted' {
        # The dialog asks for a reason. Writing that reason into the run log and
        # then deleting the run log is a question with nowhere to put the answer.
        $store = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-audit-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $run = Join-Path $store 'run-x'
        $vm = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
        try {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $run; vm = $vm } {
                Initialize-VmfRun -RunPath $rp -RunId 'run-x' | Out-Null
                Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 12 -Document ([ordered]@{
                    schemaVersion = 8; entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $vm; wave = 'w1'; path = 'A' }) })
                New-VmfStateDoc -RunPath $rp -RunId 'run-x' -VmId $vm -Wave 'w1' | Out-Null
                Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'MIGRATED' -Outcome ok | Out-Null
            }
            Mock -ModuleName VmMigrationFactory Get-VmfSignedInIdentity { @{ Identity = 'operator@contoso.com' } }
            Remove-VmfRun -RunPath $run -Reason 'lab tidy-up' -Confirm:$false | Out-Null

            Test-Path $run | Should -BeFalse
            InModuleScope VmMigrationFactory -Parameters @{ rp = $run } {
                $scope = Get-VmfClaimScopePath -RunPath $rp
                $lines = @(Read-VmfStoreLines -RunPath $scope -RelPath 'deletions.jsonl' | ForEach-Object { $_ | ConvertFrom-Json })
                @($lines).Count | Should -Be 1
                @($lines)[0].runId | Should -Be 'run-x'
                @($lines)[0].removedBy | Should -Be 'operator@contoso.com'
                @($lines)[0].reason | Should -Be 'lab tidy-up'
            }
        }
        finally { if (Test-Path $store) { Remove-Item $store -Recurse -Force } }
    }
}

Describe 'Deleting a run leaves nothing behind' {
    It 'sweeps again when something appears after the first pass' {
        # Observed on a real store: a deleted run still had its events log,
        # written between the listing and the end. A half-deleted run shows up
        # in listings and cannot be opened, which is worse than not deleting.
        InModuleScope VmMigrationFactory {
            $script:calls = [System.Collections.Generic.List[object]]::new()
            Mock Invoke-VmfStorageRequest {
                $script:calls.Add(@{ Method = $Method; Uri = $Uri })
                if ($Method -eq 'GET') {
                    $listCount = @($script:calls | Where-Object { $_.Method -eq 'GET' }).Count
                    # first listing: two documents; the verification listing: a
                    # straggler that appeared after the first pass
                    $names = if ($listCount -eq 1) { @('run-x/plan.json', 'run-x/run.json') } else { @('run-x/logs/events.jsonl') }
                    $xml = '<EnumerationResults>' + (($names | ForEach-Object { "<Name>$_</Name>" }) -join '') + '<NextMarker></NextMarker></EnumerationResults>'
                    return @{ StatusCode = 200; Content = $xml }
                }
                return @{ StatusCode = 202; Content = '' }
            }
            $n = Remove-VmfStorePrefix -RunPath 'azblob://acct/cont/run-x' -Confirm:$false
            $n | Should -Be 3 -Because 'the straggler counts too'
            @($script:calls | Where-Object { $_.Method -eq 'DELETE' -and $_.Uri -match 'events\.jsonl' }).Count |
                Should -Be 1 -Because 'the second pass is what catches it'
        }
    }
}
