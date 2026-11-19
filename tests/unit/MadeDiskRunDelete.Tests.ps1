#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# MADE-DISK-RUN-DELETE-1: "Delete this migration" with "Delete the copies as
# well" deleted the safety copies and the rollback disks, and did
# not look at the lists of disks a put-back made from a copy
# (rollbackDisksDuringRollback, restoreDisks - MADE-DISK-RECORD-1). A machine
# whose move ended less than a day before, or one that waits for a person, can
# still have an unused disk on one of them. The delete then removed the run
# store, the only record of that disk, and the disk billed until a person
# found it.
#
# Now the run delete finds them the way the daily cleanup does
# (Get-VmfDeletableMadeDisks, which Get-VmfDueMadeDisks also asks) and deletes
# them with the rollback disks, through Remove-VmfRollbackDisksBeforeMoveEntries:
# each read by its resource id first, never one that is attached, and a read
# that fails is no answer - the disk stays and so does the migration.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:MdrDisk([string]$Name) {
        "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/disks/$Name"
    }

    # One migration, one machine in $State, no safety copy and no disk for the
    # way back - so every disk the delete finds is one a put-back made:
    #   rollbackDisksDuringRollback: mdr-rb-1 and mdr-rc-1 (unused), mdr-rb-used (used), mdr-rb-gone (deleted)
    #   restoreDisks:  mdr-rs-1 (unused, LUN 0), vm1-os (the machine's disk by
    #                  its capture), mdr-rs-wait (a refused swap waits for it)
    function Global:MdrRun {
        param([string]$State = 'FAILED_NEEDS_ATTENTION', [switch]$WithCopy)
        $store = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-mdr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $run = Join-Path $store 'run-x'
        $vm = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $run; vm = $vm; st = $State; wc = [bool]$WithCopy } {
            param($rp, $vm, $st, $wc)
            $id = { param($n) "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/disks/$n" }
            $e = { param($n, $lun, $used, $gone) [pscustomobject]@{ diskId = (& $id $n); diskName = $n; lun = $lun; madeUtc = '2026-10-20T07:00:00Z'
                    usedUtc = $used; deletedUtc = $gone } }
            Initialize-VmfRun -RunPath $rp -RunId 'run-x' | Out-Null
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 12 -Document ([ordered]@{
                    schemaVersion = 8; entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $vm; wave = 'w1'; path = 'A' }) })
            New-VmfStateDoc -RunPath $rp -RunId 'run-x' -VmId $vm -Wave 'w1' | Out-Null
            New-VmfVmClaim -RunPath $rp -VmId $vm -RunId 'run-x' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState $st -Outcome ok | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $vm
            $doc | Add-Member -NotePropertyName captured -NotePropertyValue ([pscustomobject]@{
                    vmConfig = [pscustomobject]@{ osDisk = [pscustomobject]@{ id = (& $id 'vm1-os'); name = 'vm1-os' }; dataDisks = @() } }) -Force
            $doc | Add-Member -NotePropertyName rollbackDisksDuringRollback -NotePropertyValue @(
                (& $e 'mdr-rb-1' $null $null $null), (& $e 'mdr-rc-1' $null $null $null), (& $e 'mdr-rb-used' $null '2026-10-20T08:00:00Z' $null), (& $e 'mdr-rb-gone' $null $null '2026-10-20T09:00:00Z')) -Force
            $doc | Add-Member -NotePropertyName restoreDisks -NotePropertyValue @(
                (& $e 'mdr-rs-1' 0 $null $null), (& $e 'vm1-os' $null $null $null), (& $e 'mdr-rs-wait' 1 $null $null)) -Force
            $doc | Add-Member -NotePropertyName swapPending -NotePropertyValue ([pscustomobject]@{ kept = @(); kind = 'restore'; leftUtc = '2026-10-20T08:00:00Z'; error = 'x'
                    swaps = @([pscustomobject]@{ lun = 1; diskId = (& $id 'mdr-rs-wait'); diskName = 'mdr-rs-wait' }) }) -Force
            if ($wc) {
                $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{ pristineSnapshotId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/snapshots/s1'
                        snapshotId = $null; cloneVmId = $null }) -Force
            }
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        @{ Store = $store; Run = $run; Vm = $vm }
    }

    # Azure, as far as these tests need it: every disk exists and is attached
    # to nothing, unless named in Attached (to another machine) or ReadFails
    # (the read throws) or Refuse (the delete throws).
    function Global:MdrAzure {
        param([string[]]$Attached = @(), [string[]]$ReadFails = @(), [string[]]$Refuse = @())
        $global:MdrSim = @{ Attached = $Attached; ReadFails = $ReadFails; Refuse = $Refuse
            Reads = [System.Collections.Generic.List[string]]::new(); Deletes = [System.Collections.Generic.List[string]]::new() }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment {
            $n = ($DiskId -split '/')[-1]
            $global:MdrSim.Reads.Add($n)
            if ($n -in $global:MdrSim.ReadFails) { throw "Reading disk '$DiskId' failed with 500: InternalServerError" }
            $on = if ($n -in $global:MdrSim.Attached) { '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm9' } else { '' }
            [pscustomobject]@{ Exists = $true; ManagedBy = $on; SourceResourceId = '' }
        }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDiskById {
            $n = ($DiskId -split '/')[-1]
            $global:MdrSim.Deletes.Add($n)
            if ($n -in $global:MdrSim.Refuse) { throw 'ScopeLocked: the disk is locked.' }
        }
        Mock -ModuleName VmMigrationFactory New-VmfMigrationRecord { }
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { $false }
        Mock -ModuleName VmMigrationFactory Unlock-VmfSnapshot { }
        Mock -ModuleName VmMigrationFactory Remove-VmfSnapshot { }
        Mock -ModuleName VmMigrationFactory Get-VmfSignedInIdentity { @{ Identity = 'operator@example.com' } }
    }

    function Global:MdrDoc([string]$RunPath, [string]$VmId) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath; vm = $VmId } { param($rp, $vm) Read-VmfStateDoc -RunPath $rp -VmId $vm }
    }
    function Global:MdrVerdict([string]$RunPath, [string]$VmId) {
        InModuleScope VmMigrationFactory -Parameters @{ d = (Global:MdrDoc $RunPath $VmId) } { param($d) Test-VmfRunDiscardable -Plan $null -StateDocs @($d) }
    }
}
AfterAll {
    Remove-Item 'function:\MdrDisk', 'function:\MdrRun', 'function:\MdrAzure', 'function:\MdrDoc', 'function:\MdrVerdict' -ErrorAction SilentlyContinue
    Remove-Variable -Name MdrSim -Scope Global -ErrorAction SilentlyContinue
}

Describe 'MADE-DISK-RUN-DELETE-1: the delete finds the unused disks a put-back made' {
    AfterEach { if ($script:fx -and (Test-Path $script:fx.Store)) { Remove-Item $script:fx.Store -Recurse -Force } }

    It 'lists each unused disk on the two lists, with its list - never a used, deleted, recorded or waiting one' {
        $script:fx = MdrRun
        $v = MdrVerdict $script:fx.Run $script:fx.Vm
        $v.Ok | Should -BeTrue
        @($v.MadeDisks | ForEach-Object { $_.diskName } | Sort-Object) | Should -Be @('mdr-rb-1', 'mdr-rc-1', 'mdr-rs-1')
        ($v.MadeDisks | Where-Object diskName -EQ 'mdr-rb-1').List | Should -Be 'rollbackDisksDuringRollback' -Because 'a disk is marked on its own list'
        ($v.MadeDisks | Where-Object diskName -EQ 'mdr-rc-1').List | Should -Be 'rollbackDisksDuringRollback'
        ($v.MadeDisks | Where-Object diskName -EQ 'mdr-rs-1').List | Should -Be 'restoreDisks'
        @($v.MadeDisks | ForEach-Object { $_.VmId } | Select-Object -Unique) | Should -Be @($script:fx.Vm)
        @($v.RollbackDisksBeforeMove).Count | Should -Be 0 -Because 'these are not the rollback disks'
    }

    It 'the daily cleanup and the delete ask the same question' {
        $script:fx = MdrRun -State 'MIGRATED'
        $doc = MdrDoc $script:fx.Run $script:fx.Vm
        $due = InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfDueMadeDisks -StateDocs @($d) }
        $v = MdrVerdict $script:fx.Run $script:fx.Vm
        @($due.Disks | ForEach-Object { $_.diskId } | Sort-Object) | Should -Be @($v.MadeDisks | ForEach-Object { $_.diskId } | Sort-Object)
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'state' 'Retention.ps1')
        $body = [regex]::Match($code, '(?s)function Get-VmfDueMadeDisks \{.*?\n\}').Value
        $body | Should -Match 'Get-VmfDeletableMadeDisks' -Because 'one rule says which made disk may be deleted'
    }

    It 'says the disks in the detail, and a delete with no choice is refused' {
        $script:fx = MdrRun
        MdrAzure
        (MdrVerdict $script:fx.Run $script:fx.Vm).Detail | Should -Match '3 disks that a rollback or a restore made from the copies'
        { Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -Confirm:$false } |
            Should -Throw '*3 disks that a rollback or a restore made*-DeleteSafetyCopies*'
        Test-Path (Join-Path $script:fx.Run 'plan.json') | Should -BeTrue -Because 'a refusal removes nothing'
        $global:MdrSim.Deletes.Count | Should -Be 0
    }
}

Describe 'MADE-DISK-RUN-DELETE-1: Delete the copies as well deletes them, and never a used disk' {
    AfterEach {
        if ($script:fx -and (Test-Path $script:fx.Store)) { Remove-Item $script:fx.Store -Recurse -Force }
        Remove-Variable -Name MdrSim -Scope Global -ErrorAction SilentlyContinue
    }

    It 'deletes each unused disk, read first by its resource id, and then the migration' {
        $script:fx = MdrRun
        MdrAzure
        $r = Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -DeleteSafetyCopies -Confirm:$false
        $r.Removed | Should -BeTrue
        @($global:MdrSim.Deletes | Sort-Object) | Should -Be @('mdr-rb-1', 'mdr-rc-1', 'mdr-rs-1')
        foreach ($n in 'mdr-rb-1', 'mdr-rc-1', 'mdr-rs-1') { $global:MdrSim.Reads | Should -Contain $n -Because "$n is read before it is deleted" }
        foreach ($n in 'vm1-os', 'mdr-rs-wait', 'mdr-rb-used', 'mdr-rb-gone') {
            $global:MdrSim.Deletes | Should -Not -Contain $n -Because "$n is the machine's, waits for a finish, or is off the list"
        }
        Test-Path $script:fx.Run | Should -BeFalse
    }

    It 'NEVER deletes a disk that is attached to a machine' {
        $script:fx = MdrRun
        MdrAzure -Attached @('mdr-rs-1')
        $r = Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -DeleteSafetyCopies -Confirm:$false
        $r.Removed | Should -BeTrue -Because 'an attached disk is the disk of a machine, and nothing bills on no record'
        $global:MdrSim.Deletes | Should -Not -Contain 'mdr-rs-1'
        @($global:MdrSim.Deletes | Sort-Object) | Should -Be @('mdr-rb-1', 'mdr-rc-1')
    }

    It 'a read that fails is no answer: the disk is not deleted, and the migration is kept' {
        $script:fx = MdrRun
        MdrAzure -ReadFails @('mdr-rb-1')
        { Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -DeleteSafetyCopies -Confirm:$false } |
            Should -Throw "*1 of 3 disks that a rollback or a restore made from the copies were not deleted: 'mdr-rb-1' (*500*The migration is kept*"
        $global:MdrSim.Deletes | Should -Not -Contain 'mdr-rb-1'
        Test-Path (Join-Path $script:fx.Run 'plan.json') | Should -BeTrue -Because 'the record is the only thing that names the disk'
        $doc = MdrDoc $script:fx.Run $script:fx.Vm
        [string](@($doc.rollbackDisksDuringRollback) | Where-Object diskName -EQ 'mdr-rb-1').deletedUtc | Should -BeNullOrEmpty
        [string](@($doc.rollbackDisksDuringRollback) | Where-Object diskName -EQ 'mdr-rc-1').deletedUtc | Should -Not -BeNullOrEmpty -Because 'a second try skips the disks already deleted'
    }

    It 'a delete Azure refuses keeps the migration, and a second try deletes only the rest' {
        $script:fx = MdrRun
        MdrAzure -Refuse @('mdr-rc-1')
        { Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -DeleteSafetyCopies -Confirm:$false } |
            Should -Throw "*'mdr-rc-1'*ScopeLocked*"
        Test-Path (Join-Path $script:fx.Run 'plan.json') | Should -BeTrue
        $line = @(InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run } { param($rp) Read-VmfEvents -RunPath $rp -Step 'discard' }) | Where-Object outcome -EQ 'fail'
        @($line).Count | Should -Be 1 -Because 'the run history names the disk that was not deleted'
        $line[0].detail | Should -Match 'mdr-rc-1'
        $line[0].detail | Should -Match ('^' + [regex]::Escape("The product did not delete the disk 'mdr-rc-1' that a rollback or a restore made from a copy: ")) -Because 'since 2026-11-12 the product is the actor'
        MdrAzure
        $r = Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -DeleteSafetyCopies -Confirm:$false
        $r.Removed | Should -BeTrue
        @($global:MdrSim.Deletes) | Should -Be @('mdr-rc-1')
    }

    It 'with a safety copy too, the disks go - and the copy stays, because the swap that is left makes the machine changed (DELETE-CHANGED-FREED-1)' {
        $script:fx = MdrRun -WithCopy
        MdrAzure
        $r = Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -DeleteSafetyCopies -Confirm:$false
        $r.Removed | Should -BeTrue
        $r.SafetyCopiesAlreadyGone | Should -Be 0 -Because 'the copy of a machine left changed is never asked about'
        $r.SafetyCopiesKept | Should -Be 1
        @($r.ChangedMachinesKept) | Should -Be @('vm1')
        @($global:MdrSim.Deletes).Count | Should -Be 3
    }

    It 'review: a machine whose restore has not ended, or was given up, keeps its made disks, and the delete is refused (DISCARD-PUTBACK-HOLD-1)' {
        foreach ($ended in @($null, [pscustomobject]@{ utc = '2026-10-20T09:00:00Z'; reason = 'gaveUp'; why = 'x' })) {
            $script:fx = MdrRun
            # A second machine with one unused made disk, and a hold.
            $vm2 = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm2'
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run; vm = $script:fx.Vm; vm2 = $vm2; ended = $ended } {
                param($rp, $vm, $vm2, $ended)
                Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 12 -Document ([ordered]@{
                        schemaVersion = 8; entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $vm; wave = 'w1'; path = 'A' }, [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $vm2; wave = 'w1'; path = 'A' }) })
                New-VmfStateDoc -RunPath $rp -RunId 'run-x' -VmId $vm2 -Wave 'w1' | Out-Null
                Add-VmfStateTransition -RunPath $rp -VmId $vm2 -NewState 'FAILED_NEEDS_ATTENTION' -Outcome ok | Out-Null
                $doc = Read-VmfStateDoc -RunPath $rp -VmId $vm2
                $doc | Add-Member -NotePropertyName restoreDisks -NotePropertyValue @([pscustomobject]@{
                        diskId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/disks/mdr-held-1'
                        diskName = 'mdr-held-1'; lun = $null; madeUtc = '2026-10-20T07:00:00Z'; usedUtc = $null; deletedUtc = $null }) -Force
                $job = [ordered]@{ operationId = 'op-1'; kind = 'restore'; startedUtc = '2026-10-20T07:00:00Z' }
                if ($ended) { $job.ended = $ended }
                $doc | Add-Member -NotePropertyName putBackJob -NotePropertyValue ([pscustomobject]$job) -Force
                Write-VmfStateDoc -RunPath $rp -Document $doc
                Test-VmfPutBackJobHolds -Doc (Read-VmfStateDoc -RunPath $rp -VmId $vm2) | Should -BeTrue -Because 'the fixture is a held machine'
            }
            MdrAzure
            try {
                $v = MdrVerdict $script:fx.Run $vm2
                @($v.MadeDisks).Count | Should -Be 0 -Because 'a held machine keeps every disk made for it, as the daily cleanup does'
                # DISCARD-PUTBACK-HOLD-1: the whole delete is refused, so no
                # disk of either machine goes.
                $v.Ok | Should -BeFalse
                { Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -DeleteSafetyCopies -Confirm:$false } |
                    Should -Throw '*vm2*Restore this machine*'
                $global:MdrSim.Deletes | Should -Not -Contain 'mdr-held-1'
                $global:MdrSim.Reads | Should -Not -Contain 'mdr-held-1'
                @($global:MdrSim.Deletes).Count | Should -Be 0 -Because 'a refused delete deletes nothing'
            }
            finally { if (Test-Path $script:fx.Store) { Remove-Item $script:fx.Store -Recurse -Force } }
        }
    }

    It 'keeping the copies keeps the disks, and touches nothing in Azure' {
        $script:fx = MdrRun
        MdrAzure
        (Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -KeepSafetyCopies -Confirm:$false).Removed | Should -BeTrue
        $global:MdrSim.Reads.Count | Should -Be 0
        $global:MdrSim.Deletes.Count | Should -Be 0
    }
}

Describe 'MADE-DISK-RUN-DELETE-1: the service starts the engine for them' {
    BeforeAll {
        $claims = @(@{ typ = 'preferred_username'; val = 'operator@example.com' }, @{ typ = 'roles'; val = 'Vmf.Operator' })
        $doc = @{ auth_typ = 'aad'; claims = $claims } | ConvertTo-Json -Depth 5
        $script:operator = ConvertFrom-VmfClientPrincipal -Header ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($doc)))
    }
    BeforeEach {
        $global:MdrStarts = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName FacadeCore Invoke-VmfFacadeStartEngine {
            $global:MdrStarts.Add($Operation)
            [pscustomobject]@{ operation = $Operation; runId = $RunId; execution = 'vmf-engine-abc'; executions = @('vmf-engine-abc') }
        }
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $false }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment { throw 'the service must not read a disk' }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDiskById { throw 'the service must not delete a disk' }
    }
    AfterEach {
        if ($script:fx -and (Test-Path $script:fx.Store)) { Remove-Item $script:fx.Store -Recurse -Force }
        Remove-Variable -Name MdrStarts -Scope Global -ErrorAction SilentlyContinue
    }

    It 'no copy left, but unused disks a put-back made: starts the engine, which can delete them' {
        $script:fx = MdrRun
        $r = Invoke-VmfFacadeDiscardRun -Principal $script:operator -StorePath $script:fx.Run -RunId 'run-x' -Note 'n' -DeleteSafetyCopies
        @($global:MdrStarts) | Should -Be @('discard') -Because 'only the engine may delete a disk, and the run must not go without them'
        $r.safetyCopies | Should -Be 0
        $r.madeDisks | Should -Be 3
        Test-Path (Join-Path $script:fx.Run 'plan.json') | Should -BeTrue -Because 'the engine removes the records, after the disks'
        $start = @(InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run } { param($rp) Read-VmfEvents -RunPath $rp -Step 'discard' }) | Where-Object outcome -EQ 'start'
        $start[0].detail | Should -Match '3 disks that a rollback or a restore made from the copies'
    }
}

Describe 'MADE-DISK-RUN-DELETE-1: the dialog says what is deleted' {
    It 'the question and Delete the copies as well name the disks made from the copies' {
        $page = Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'migrations.html')
        $text = { param($key) [regex]::Match($page, "(?m)^\s*$key\s*:\s*'([^']*)'").Groups[1].Value }
        (& $text 'discardCopies') | Should -Match 'disks' -Because 'the question says what lives in Azure'
        (& $text 'discardDeleteCopies') | Should -Match '^Delete the copies as well\. .*disk.*made from' -Because 'the choice names what it deletes'
        (& $text 'discardKeepCopies') | Should -Match '^Keep the copies\. .*disks'
    }
}
