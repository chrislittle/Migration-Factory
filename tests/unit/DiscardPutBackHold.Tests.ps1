#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# DISCARD-PUTBACK-HOLD-1: "Delete this migration" asked only each machine's
# state (Test-VmfRunDiscardable). A machine in a settled state whose restore
# has not ended, or one the service gave up on (ended.reason gaveUp),
# or a later one that carries that mark (held), passed. The delete then
# removed the record and, with "Delete the copies as well", the safety copies
# that a restore needs - for a machine that can be part way. The daily cleanup already keeps them
# (Test-VmfPutBackJobHolds, RESUME-GIVEUP-KEEP-1).
#
# Now the delete refuses such a machine, as it refuses a machine part way
# through a move, in the engine (Remove-VmfRun) and in the service
# (Invoke-VmfFacadeDiscardRun, 400), with both choices, and names the machine
# and the reason (Get-VmfPutBackHoldWhy). A machine whose restore finished -
# the record is removed in the same write - is not held, and may go.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    # The putBackJob records under test. Each is the record a machine has
    # after the named event; $null is a machine whose restore finished (the
    # finish removes the record in the same write).
    $script:DphJobs = @{
        open     = [pscustomobject]@{ operationId = 'op-1'; kind = 'restore'; startedUtc = '2026-10-20T07:00:00Z'; phase = 'stopped' }
        gaveUp   = [pscustomobject]@{ operationId = 'op-1'; kind = 'restore'; startedUtc = '2026-10-20T07:00:00Z'; phase = 'stopped'
            ended = [pscustomobject]@{ utc = '2026-10-20T09:00:00Z'; outcome = 'fail'; reason = 'gaveUp'; why = 'x' } }
        held     = [pscustomobject]@{ operationId = 'op-2'; kind = 'restore'; startedUtc = '2026-10-21T07:00:00Z'
            ended = [pscustomobject]@{ utc = '2026-10-21T09:00:00Z'; outcome = 'fail'; reason = 'failed'; why = 'x' }
            held = [pscustomobject]@{ operationId = 'op-1'; sinceUtc = '2026-10-21T07:00:00Z'; why = $null } }
        answered = [pscustomobject]@{ operationId = 'op-1'; kind = 'restore'; startedUtc = '2026-10-20T07:00:00Z'
            ended = [pscustomobject]@{ utc = '2026-10-20T09:00:00Z'; outcome = 'fail'; reason = 'failed'; why = 'x' } }
    }

    # One migration, one machine (vm-held1) in a settled state with one
    # safety copy and the putBackJob record $Job.
    function Global:DphRun {
        param($Job)
        $store = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-dph-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $run = Join-Path $store 'run-x'
        $vm = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm-held1'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $run; vm = $vm; job = $Job } {
            param($rp, $vm, $job)
            Initialize-VmfRun -RunPath $rp -RunId 'run-x' | Out-Null
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 12 -Document ([ordered]@{
                    schemaVersion = 8; entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $vm; wave = 'w1'; path = 'B' }) })
            New-VmfStateDoc -RunPath $rp -RunId 'run-x' -VmId $vm -Wave 'w1' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'FAILED_NEEDS_ATTENTION' -Outcome ok | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $vm
            $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{
                    pristineSnapshotId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/snapshots/s1'
                    snapshotId = $null; cloneVmId = $null }) -Force
            if ($job) { $doc | Add-Member -NotePropertyName putBackJob -NotePropertyValue $job -Force }
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        @{ Store = $store; Run = $run; Vm = $vm }
    }
    function Global:DphDoc([string]$RunPath, [string]$VmId) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath; vm = $VmId } { param($rp, $vm) Read-VmfStateDoc -RunPath $rp -VmId $vm }
    }

    $claims = @(@{ typ = 'preferred_username'; val = 'operator@example.com' }, @{ typ = 'roles'; val = 'Vmf.Operator' })
    $principalDoc = @{ auth_typ = 'aad'; claims = $claims } | ConvertTo-Json -Depth 5
    $script:operator = ConvertFrom-VmfClientPrincipal -Header ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($principalDoc)))
}
AfterAll {
    Remove-Item 'function:\DphRun', 'function:\DphDoc' -ErrorAction SilentlyContinue
    Remove-Variable -Name DphStarts, DphAzure -Scope Global -ErrorAction SilentlyContinue
}

Describe 'DISCARD-PUTBACK-HOLD-1: the rule (Test-VmfRunDiscardable)' {
    AfterEach { if ($script:fx -and (Test-Path $script:fx.Store)) { Remove-Item $script:fx.Store -Recurse -Force } }

    It 'refuses a machine whose record holds its copies (<case>), and names the machine and the reason' -ForEach @(
        @{ case = 'open'; want = 'vm-held1: Restore this machine has not ended\. Wait until it ends\.' }
        @{ case = 'gaveUp'; want = 'vm-held1: Restore this machine stopped and did not finish\. Use Restore this machine again\.' }
        @{ case = 'held'; want = 'vm-held1: Restore this machine stopped and did not finish\. Use Restore this machine again\.' }
    ) {
        $script:fx = DphRun -Job $script:DphJobs[$case]
        $doc = DphDoc $script:fx.Run $script:fx.Vm
        InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Test-VmfPutBackJobHolds -Doc $d } | Should -BeTrue -Because 'the fixture is a held machine'

        $v = InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Test-VmfRunDiscardable -Plan $null -StateDocs @($d) }
        $v.Ok | Should -BeFalse -Because 'the record and the copies are what a restore needs'
        $v.Detail | Should -Match 'vm-held1' -Because 'the refusal names the machine'
        $v.Detail | Should -Match $want -Because 'and the reason, and what to do, by the kind of the job'
        $v.Detail | Should -Not -Match 'left alone' -Because 'the cleanup''s words are not true of a delete'
        @($v.OrphanSnapshots).Count | Should -Be 0 -Because 'a refusal lists nothing to delete'
    }

    It 'lets a machine go whose restore finished, or whose restore ended with an answer (<case>)' -ForEach @(
        @{ case = 'finished' }, @{ case = 'answered' }
    ) {
        $job = if ($case -eq 'finished') { $null } else { $script:DphJobs[$case] }
        $script:fx = DphRun -Job $job
        $doc = DphDoc $script:fx.Run $script:fx.Vm
        InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Test-VmfPutBackJobHolds -Doc $d } | Should -BeFalse -Because 'the fixture holds nothing'
        $v = InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Test-VmfRunDiscardable -Plan $null -StateDocs @($d) }
        $v.Ok | Should -BeTrue
        @($v.OrphanSnapshots).Count | Should -Be 1
    }

    It 'says what to do by the kind of the job: <case>' -ForEach @(
        @{ case = 'an open Finish the rollback'; job = [pscustomobject]@{ operationId = 'op-f'; kind = 'finish'; options = [pscustomobject]@{ finishes = 'rollback' } }
            want = 'vm-a: Finish the rollback has not ended\. Wait until it ends\. Then'; not = 'Rebuild this machine|Use ' }
        @{ case = 'an open Finish the restore'; job = [pscustomobject]@{ operationId = 'op-f'; kind = 'finish'; options = [pscustomobject]@{ finishes = 'restore' } }
            want = 'vm-a: Finish the restore has not ended\. Wait until it ends\. Then'; not = 'Rebuild this machine|Use ' }
        @{ case = 'a given-up Finish the rollback'; job = [pscustomobject]@{ operationId = 'op-f'; kind = 'finish'; options = [pscustomobject]@{ finishes = 'rollback' }
                ended = [pscustomobject]@{ reason = 'gaveUp' } }
            want = 'vm-a: Finish the rollback stopped and did not finish\. Use Finish the rollback again\. Then'; not = 'Rebuild this machine|Wait' }
        @{ case = 'a given-up restore'; job = [pscustomobject]@{ operationId = 'op-r'; kind = 'restore'; ended = [pscustomobject]@{ reason = 'gaveUp' } }
            want = 'vm-a: Restore this machine stopped and did not finish\. Use Restore this machine again\. Then'; not = 'Wait' }
        @{ case = 'an open restore'; job = [pscustomobject]@{ operationId = 'op-r'; kind = 'restore' }
            want = 'vm-a: Restore this machine has not ended\. Wait until it ends\. Then'; not = 'Rebuild this machine|Use ' }
    ) {
        $d = [pscustomobject]@{ vmId = '/x/virtualMachines/vm-a'; state = 'FAILED_NEEDS_ATTENTION'; putBackJob = $job }
        $v = InModuleScope VmMigrationFactory -Parameters @{ d = $d } { param($d) Test-VmfRunDiscardable -Plan $null -StateDocs @($d) }
        $v.Ok | Should -BeFalse
        $v.Detail | Should -Match $want
        $v.Detail | Should -Not -Match $not -Because 'the guidance is for this kind of job only'
        $v.Detail | Should -Not -Match 'left alone'
    }

    It 'gives each of two machines its own guidance' {
        $a = [pscustomobject]@{ vmId = '/x/virtualMachines/vm-a'; state = 'FAILED_NEEDS_ATTENTION'
            putBackJob = [pscustomobject]@{ operationId = 'op-f'; kind = 'finish'; options = [pscustomobject]@{ finishes = 'restore' } } }
        $b = [pscustomobject]@{ vmId = '/x/virtualMachines/vm-b'; state = 'FAILED_ROLLED_BACK'
            putBackJob = [pscustomobject]@{ operationId = 'op-b'; kind = 'restore'; ended = [pscustomobject]@{ reason = 'gaveUp' } } }
        $v = InModuleScope VmMigrationFactory -Parameters @{ d = @($a, $b) } { param($d) Test-VmfRunDiscardable -Plan $null -StateDocs $d }
        $v.Detail | Should -Match 'vm-a: Finish the restore has not ended\. Wait until it ends\. vm-b: Restore this machine stopped and did not finish\. Use Restore this machine again\. Then delete the migration again\.$'
        $v.Detail | Should -Match '^The migration was not deleted\. The product needs its record and its safety copies for each machine that follows\. vm-a'
    }

    It 'names every held machine, and a machine part way through a move is still refused first' {
        $a = [pscustomobject]@{ vmId = '/x/virtualMachines/vm-held1'; state = 'FAILED_NEEDS_ATTENTION'; putBackJob = $script:DphJobs.gaveUp }
        $b = [pscustomobject]@{ vmId = '/x/virtualMachines/vm-held2'; state = 'FAILED_ROLLED_BACK'; putBackJob = $script:DphJobs.open }
        $c = [pscustomobject]@{ vmId = '/x/virtualMachines/vm-free'; state = 'FAILED_ROLLED_BACK' }
        $v = InModuleScope VmMigrationFactory -Parameters @{ d = @($a, $b, $c) } { param($d) Test-VmfRunDiscardable -Plan $null -StateDocs $d }
        $v.Ok | Should -BeFalse
        $v.Detail | Should -Match 'vm-held1'
        $v.Detail | Should -Match 'vm-held2'
        $v.Detail | Should -Not -Match 'vm-free'
        $m = [pscustomobject]@{ vmId = '/x/virtualMachines/vm-moving'; state = 'CONVERTING' }
        $v2 = InModuleScope VmMigrationFactory -Parameters @{ d = @($a, $m) } { param($d) Test-VmfRunDiscardable -Plan $null -StateDocs $d }
        $v2.Ok | Should -BeFalse
        $v2.Detail | Should -Match 'CONVERTING'
    }
}

Describe 'DISCARD-PUTBACK-HOLD-1: the engine refuses the delete (Remove-VmfRun)' {
    BeforeEach {
        $global:DphAzure = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { $global:DphAzure.Add('exists'); $false }
        Mock -ModuleName VmMigrationFactory Unlock-VmfSnapshot { $global:DphAzure.Add('unlock') }
        Mock -ModuleName VmMigrationFactory Remove-VmfSnapshot { $global:DphAzure.Add('delete') }
        Mock -ModuleName VmMigrationFactory New-VmfMigrationRecord { }
        Mock -ModuleName VmMigrationFactory Get-VmfSignedInIdentity { @{ Identity = 'operator@example.com' } }
    }
    AfterEach { if ($script:fx -and (Test-Path $script:fx.Store)) { Remove-Item $script:fx.Store -Recurse -Force } }

    It 'refuses with <choice> for a machine that is <case>, and changes nothing' -ForEach @(
        @{ choice = 'DeleteSafetyCopies'; case = 'gaveUp' }, @{ choice = 'KeepSafetyCopies'; case = 'gaveUp' },
        @{ choice = 'DeleteSafetyCopies'; case = 'open' }, @{ choice = 'KeepSafetyCopies'; case = 'held' }
    ) {
        $script:fx = DphRun -Job $script:DphJobs[$case]
        $splat = @{ RunPath = $script:fx.Run; Reason = 'x'; RemovedBy = 'operator@example.com'; Confirm = $false; $choice = $true }
        { Remove-VmfRun @splat } | Should -Throw '*vm-held1: * this machine *'
        @($global:DphAzure).Count | Should -Be 0 -Because 'no copy is touched in Azure'
        Test-Path (Join-Path $script:fx.Run 'plan.json') | Should -BeTrue -Because 'the record stays'
        (DphDoc $script:fx.Run $script:fx.Vm).putBackJob | Should -Not -BeNullOrEmpty
    }

    It 'checks again before the record goes: a restore that starts while the copies are deleted keeps the migration' {
        $script:fx = DphRun -Job $null
        $global:DphLate = @{ Run = $script:fx.Run; Vm = $script:fx.Vm; Job = $script:DphJobs.open }
        # The copy is deleted (Azure no longer has it); a restore starts meanwhile.
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists {
            $global:DphAzure.Add('exists')
            InModuleScope VmMigrationFactory -Parameters $global:DphLate { param($Run, $Vm, $Job)
                $doc = Read-VmfStateDoc -RunPath $Run -VmId $Vm
                if (-not $doc.PSObject.Properties['putBackJob']) {
                    $doc | Add-Member -NotePropertyName putBackJob -NotePropertyValue $Job -Force
                    Write-VmfStateDoc -RunPath $Run -Document $doc
                }
            }
            $false
        }
        try {
            { Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -DeleteSafetyCopies -Confirm:$false } |
                Should -Throw '*vm-held1: Restore this machine has not ended*'
            @($global:DphAzure) | Should -Contain 'exists' -Because 'the first check passed and the copies were deleted'
            Test-Path (Join-Path $script:fx.Run 'plan.json') | Should -BeTrue -Because 'the second check keeps the record'
            (DphDoc $script:fx.Run $script:fx.Vm).putBackJob | Should -Not -BeNullOrEmpty
        }
        finally { Remove-Variable -Name DphLate -Scope Global -ErrorAction SilentlyContinue }
    }

    It 'deletes a migration whose machine''s restore finished, with <choice>' -ForEach @(
        @{ choice = 'DeleteSafetyCopies' }, @{ choice = 'KeepSafetyCopies' }
    ) {
        $script:fx = DphRun -Job $null
        $splat = @{ RunPath = $script:fx.Run; Reason = 'x'; RemovedBy = 'operator@example.com'; Confirm = $false; $choice = $true }
        (Remove-VmfRun @splat).Removed | Should -BeTrue
        if ($choice -eq 'DeleteSafetyCopies') { @($global:DphAzure) | Should -Contain 'exists' -Because 'the engine looks for the copy before it deletes it' }
        else { @($global:DphAzure).Count | Should -Be 0 }
    }
}

Describe 'DISCARD-PUTBACK-HOLD-1: the service refuses the delete (Invoke-VmfFacadeDiscardRun)' {
    BeforeEach {
        $global:DphStarts = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName FacadeCore Invoke-VmfFacadeStartEngine {
            $global:DphStarts.Add($Operation)
            [pscustomobject]@{ operation = $Operation; runId = $RunId; execution = 'vmf-engine-abc'; executions = @('vmf-engine-abc') }
        }
        # A job the service gave up on runs no more: the engine check says no.
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $false }
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { throw 'the service must not read a copy' }
        Mock -ModuleName VmMigrationFactory Remove-VmfSnapshot { throw 'the service must not delete a copy' }
        Mock -ModuleName VmMigrationFactory New-VmfMigrationRecord { }
    }
    AfterEach { if ($script:fx -and (Test-Path $script:fx.Store)) { Remove-Item $script:fx.Store -Recurse -Force } }

    It 'answers 400 with <name> for a machine that is <case>, and starts nothing and writes nothing' -ForEach @(
        @{ name = 'Delete the copies as well'; delete = $true; case = 'gaveUp' }, @{ name = 'Keep the copies'; delete = $false; case = 'gaveUp' },
        @{ name = 'Delete the copies as well'; delete = $true; case = 'held' }, @{ name = 'Keep the copies'; delete = $false; case = 'open' }
    ) {
        $script:fx = DphRun -Job $script:DphJobs[$case]
        $args2 = @{ Principal = $script:operator; StorePath = $script:fx.Run; RunId = 'run-x'; Note = 'n' }
        if ($delete) { $args2.DeleteSafetyCopies = $true }
        { Invoke-VmfFacadeDiscardRun @args2 } | Should -Throw '400: *vm-held1: * this machine *'
        @($global:DphStarts).Count | Should -Be 0 -Because 'no engine starts for a delete that is refused'
        Test-Path (Join-Path $script:fx.Run 'plan.json') | Should -BeTrue -Because 'the record stays'
        $lines = @(InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run } { param($rp) Read-VmfEvents -RunPath $rp } |
                Where-Object { $_.step -in @('discard', 'run') })
        $lines.Count | Should -Be 0 -Because 'a refused delete writes no "discarded by" or start line'
    }

    It 'deletes a migration whose machine''s restore finished: Keep the copies here, Delete the copies as well through the engine' {
        $script:fx = DphRun -Job $null
        $r = Invoke-VmfFacadeDiscardRun -Principal $script:operator -StorePath $script:fx.Run -RunId 'run-x' -Note 'n' -DeleteSafetyCopies
        $r.queued | Should -BeTrue
        @($global:DphStarts) | Should -Be @('discard')
        Remove-Item $script:fx.Store -Recurse -Force
        $script:fx = DphRun -Job $null
        Invoke-VmfFacadeDiscardRun -Principal $script:operator -StorePath $script:fx.Run -RunId 'run-x' -Note 'n' | Out-Null
        Test-Path (Join-Path $script:fx.Run 'plan.json') | Should -BeFalse -Because 'Keep the copies deletes the record here'
    }
}
