#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# MADE-DISK-DELETE-1 (decision of 2026-11-08: a person may remove these disks
# in the app if they choose; the two-step slide-out design A was approved).
#
# A rollback and Restore this machine (and Rebuild this machine, in an earlier
# version) record each managed disk they make from a safety copy
# (rollbackDisksDuringRollback, restoreDisks, recoveryDisks). Since MADE-DISK-SHOWN-1 the
# machine's panel lists each one the record says nothing uses. A machine in
# FAILED_NEEDS_ATTENTION or NEEDS_DECISION kept such a disk with no end, and
# only the Azure portal could delete it (hard rule 12).
#
# Now Delete these disks now, for an operator, starts the engine operation
# 'deletemade' through the service's engine route - the shape of
# RESTORE-EARLIER-DELETE-1's 'deleteearlier'. The engine (Remove-VmfMadeDisks):
#   - deletes ONLY the disks the one rule lists (Get-VmfDeletableMadeDisks,
#     the rule of the daily cleanup, the delete of a migration and the panel),
#     by resource id, through the cleanup's own delete
#     (Remove-VmfRollbackDisksBeforeMoveEntries: each disk read first, an attached one kept
#     and marked used, a gone one counts as deleted, each deleted one marked
#     deletedUtc on its list - so the list empties and a job killed part way
#     deletes only what is left);
#   - is refused where a restore or a delete of the earlier disks is refused
#     (a restore or a finish that has not ended or stopped, a refused swap), on
#     a machine whose move has not ended, and while a wave holds the machine;
#   - holds the machine as a restore does;
#   - deletes nothing of a machine that Azure does not show (the cleanup's rule).
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    $script:sub = '00000000-0000-0000-0000-000000000000'
    $script:vmId = "/subscriptions/$script:sub/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/app-01"
    $script:disk = { param($name) "/subscriptions/$script:sub/resourceGroups/rg-app/providers/Microsoft.Compute/disks/$name" }
    $script:rbOs = & $script:disk 'app-01-os-asitwas'
    $script:rbD0 = & $script:disk 'app-01-d0-asitwas'
    $script:rsD1 = & $script:disk 'app-01-d1-restored'
    $script:used = & $script:disk 'app-01-used'
    $script:onRecord = & $script:disk 'app-01-os'
    $script:waits = & $script:disk 'app-01-d2-swap'

    # A machine that needs attention, with the disks a rollback and a restore
    # made. Free: rbOs, rbD0, rsD1. Not on the list: one marked used, one the
    # record says the machine runs on, one a refused swap waits for (only when
    # -Swap is given).
    function Script:MdSeed {
        param([string]$State = 'FAILED_NEEDS_ATTENTION', [hashtable]$Doc = @{}, [switch]$NoRecord)
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId; st = $State; extra = $Doc; none = [bool]$NoRecord
            rbOs = $script:rbOs; rbD0 = $script:rbD0; rsD1 = $script:rsD1; used = $script:used; onRecord = $script:onRecord } {
            param($rp, $id, $st, $extra, $none, $rbOs, $rbD0, $rsD1, $used, $onRecord)
            Initialize-VmfRun -RunPath $rp -RunId 'md-test' -Kind 'migration' | Out-Null
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document ([ordered]@{ schemaVersion = 1; entries = @([ordered]@{ schemaVersion = 1; vmId = $id; wave = 'w1' }) }) -Depth 24
            if ($none) { return }
            New-VmfStateDoc -RunPath $rp -RunId 'md-test' -VmId $id -Wave 'w1' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $id -NewState $st -Outcome ok -Detail 'stopped' | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $doc | Add-Member -NotePropertyName captured -NotePropertyValue ([pscustomobject]@{ osDisk = [pscustomobject]@{ id = $onRecord; name = 'app-01-os' } }) -Force
            $doc | Add-Member -NotePropertyName rollbackDisksDuringRollback -NotePropertyValue @(
                [pscustomobject]@{ diskId = $rbOs; diskName = 'app-01-os-asitwas'; lun = $null; madeUtc = '2026-11-06T10:05:00Z' }
                [pscustomobject]@{ diskId = $rbD0; diskName = 'app-01-d0-asitwas'; lun = 0; madeUtc = '2026-11-06T10:05:30Z' }
                [pscustomobject]@{ diskId = $used; diskName = 'app-01-used'; lun = 1; madeUtc = '2026-11-06T10:05:40Z'; usedUtc = '2026-11-06T10:10:00Z' }
                [pscustomobject]@{ diskId = $onRecord; diskName = 'app-01-os'; lun = $null; madeUtc = '2026-11-06T10:05:50Z' }) -Force
            $doc | Add-Member -NotePropertyName restoreDisks -NotePropertyValue @(
                [pscustomobject]@{ diskId = $rsD1; diskName = 'app-01-d1-restored'; lun = 1; madeUtc = '2026-11-07T09:00:00Z' }) -Force
            foreach ($k in $extra.Keys) { $doc | Add-Member -NotePropertyName $k -NotePropertyValue $extra[$k] -Force }
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
    }
    function Script:MdDoc { InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id } }
    function Script:MdEvents { InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { param($rp) @(Read-VmfEvents -RunPath $rp) } }
    function Script:MdLeft { InModuleScope VmMigrationFactory -Parameters @{ d = (Script:MdDoc) } { param($d) @(Get-VmfDeletableMadeDisks -StateDoc $d) } }

    # Azure, as a map of disk id -> what a read of it gives. A disk not in the
    # map reads as gone. $global:mdDeleted lists each delete asked for.
    function Script:MdMockAzure {
        param([hashtable]$Disks, $MachineHere = $true)
        $global:mdDisks = @{}
        foreach ($k in $Disks.Keys) { $global:mdDisks[$k.ToLowerInvariant()] = $Disks[$k] }
        $global:mdDeleted = [System.Collections.Generic.List[object]]::new()
        $global:mdDeleteFail = @{}
        $global:mdHere = $MachineHere
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { $null }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory Test-VmfVmExists {
            if ($global:mdHere -is [string] -and $global:mdHere -eq 'unreadable') { throw 'Reading the machine failed with 403: AuthorizationFailed' }
            [bool]$global:mdHere
        }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment {
            $state = $global:mdDisks[$DiskId.ToLowerInvariant()]
            if ($state -eq 'unreadable') { throw "Reading disk '$DiskId' failed with 403: AuthorizationFailed" }
            if (-not $state) { return [pscustomobject]@{ Exists = $false; ManagedBy = ''; SourceResourceId = '' } }
            [pscustomobject]@{ Exists = $true; ManagedBy = $(if ($state -eq 'detached') { '' } else { [string]$state }); SourceResourceId = '' }
        }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDiskById {
            if ($global:mdDeleteFail[$DiskId.ToLowerInvariant()]) { throw "Deleting disk '$DiskId' failed with 409: OperationNotAllowed" }
            $global:mdDeleted.Add([pscustomobject]@{ DiskId = $DiskId; MachineId = $MachineId; Groups = @($ResourceGroupNames) })
            $global:mdDisks.Remove($DiskId.ToLowerInvariant())
        }
    }
    function Script:MdAllFree { @{ $script:rbOs = 'detached'; $script:rbD0 = 'detached'; $script:rsD1 = 'detached'; $script:used = 'detached'; $script:onRecord = 'detached'; $script:waits = 'detached' } }
    function Script:MdDelete { param([string]$Op = 'op-md-1') Remove-VmfMadeDisks -RunPath $script:runPath -VmId $script:vmId -By 'operator@example.com' -CorrelationId $Op -Confirm:$false }
}

AfterAll {
    Remove-Variable mdDisks, mdDeleted, mdDeleteFail, mdHere, mdKilled, mdReal, mdHolder -Scope Global -ErrorAction SilentlyContinue
}

Describe 'MADE-DISK-DELETE-1: the engine deletes the disks a put-back made that nothing uses (deletemade)' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-md-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    }
    AfterEach {
        InModuleScope VmMigrationFactory { $script:VmfMachineLeaseToken = $null; $script:VmfOpHeartbeat = $null }
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
    }

    It 'deletes only the disks the shared rule lists, by resource id, and marks each one deleted so the list empties' {
        Script:MdSeed
        Script:MdMockAzure (Script:MdAllFree)
        $r = Script:MdDelete
        @($global:mdDeleted.DiskId) | Should -Be @($script:rbOs, $script:rbD0, $script:rsD1) -Because 'not a disk marked used, and not one the record says the machine runs on'
        foreach ($d in $global:mdDeleted) {
            $d.MachineId | Should -Be $script:vmId
            @($d.Groups) | Should -Contain 'rg-app'
        }
        @($r.Deleted) | Should -Be @('app-01-os-asitwas', 'app-01-d0-asitwas', 'app-01-d1-restored')
        @($r.Skipped).Count | Should -Be 0
        $doc = Script:MdDoc
        foreach ($id in $script:rbOs, $script:rbD0) { [string]@($doc.rollbackDisksDuringRollback | Where-Object diskId -EQ $id)[0].deletedUtc | Should -Not -BeNullOrEmpty }
        [string]@($doc.restoreDisks)[0].deletedUtc | Should -Not -BeNullOrEmpty
        [string]@($doc.rollbackDisksDuringRollback | Where-Object diskId -EQ $script:onRecord)[0].deletedUtc | Should -BeNullOrEmpty
        @(Script:MdLeft).Count | Should -Be 0 -Because 'the panel list empties'
        $line = @(Script:MdEvents | Where-Object { $_.step -eq 'madeDelete' })[-1]
        $line.outcome | Should -Be 'ok'
        $line.detail | Should -Match "^The product deleted 3 managed disks made from the safety copies of 'app-01': app-01-os-asitwas, app-01-d0-asitwas, app-01-d1-restored\. operator@example\.com asked for it\.$"
        $line.correlationId | Should -Be 'op-md-1'
    }

    It 'never deletes a disk a refused swap waits to put on the machine' {
        Script:MdSeed -Doc @{ restoreDisks = @([pscustomobject]@{ diskId = $script:waits; diskName = 'app-01-d2-swap'; lun = 2; madeUtc = '2026-11-07T09:00:00Z' }) }
        Script:MdMockAzure (Script:MdAllFree)
        # The swap record itself refuses the delete (Finish the restore first);
        # with no refusal, the rule still leaves the disk out.
        Mock -ModuleName VmMigrationFactory Get-VmfSwapPendingRefusal { $null }
        $doc = Script:MdDoc
        $doc | Add-Member -NotePropertyName swapPending -NotePropertyValue ([pscustomobject]@{ kept = @(); kind = 'restore'; swaps = @([pscustomobject]@{ lun = 2; diskId = $script:waits }); swapped = @() }) -Force
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; d = $doc } { param($rp, $d) Write-VmfStateDoc -RunPath $rp -Document $d }
        Script:MdDelete | Out-Null
        @($global:mdDeleted.DiskId) | Should -Not -Contain $script:waits
    }

    It 'keeps a disk attached to a machine at that moment, marks it used, and names it' {
        Script:MdSeed
        $other = "/subscriptions/$script:sub/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/app-02"
        $azure = Script:MdAllFree
        $azure[$script:rbD0] = $other
        Script:MdMockAzure $azure
        $r = Script:MdDelete
        @($global:mdDeleted.DiskId) | Should -Be @($script:rbOs, $script:rsD1)
        @($r.Skipped).Count | Should -Be 1
        $r.Skipped[0].name | Should -Be 'app-01-d0-asitwas'
        $r.Skipped[0].why | Should -Match "is attached to the machine 'app-02'"
        [string]@((Script:MdDoc).rollbackDisksDuringRollback | Where-Object diskId -EQ $script:rbD0)[0].usedUtc | Should -Not -BeNullOrEmpty -Because 'the cleanup''s rule: on a machine, it is that machine''s disk'
        $line = @(Script:MdEvents | Where-Object { $_.step -eq 'madeDelete' })[-1]
        $line.outcome | Should -Be 'warn'
        $line.detail | Should -Match "The product did not delete app-01-d0-asitwas: it is attached to the machine 'app-02'\."
    }

    It 'a disk that is already gone counts as deleted, with no delete asked of Azure' {
        Script:MdSeed
        $azure = Script:MdAllFree
        $azure.Remove($script:rbD0)
        Script:MdMockAzure $azure
        $r = Script:MdDelete
        @($global:mdDeleted.DiskId) | Should -Be @($script:rbOs, $script:rsD1)
        @($r.Deleted) | Should -Contain 'app-01-d0-asitwas'
        [string]@((Script:MdDoc).rollbackDisksDuringRollback | Where-Object diskId -EQ $script:rbD0)[0].deletedUtc | Should -Not -BeNullOrEmpty
    }

    It 'a disk it cannot read, or that Azure does not delete, is not marked, stays in the list, and is named' {
        Script:MdSeed
        $azure = Script:MdAllFree
        $azure[$script:rbOs] = 'unreadable'
        Script:MdMockAzure $azure
        $global:mdDeleteFail[$script:rsD1.ToLowerInvariant()] = $true
        $r = Script:MdDelete
        @($global:mdDeleted.DiskId) | Should -Be @($script:rbD0)
        @($r.Skipped.name) | Should -Be @('app-01-os-asitwas', 'app-01-d1-restored')
        @((Script:MdLeft).diskId) | Should -Be @($script:rbOs, $script:rsD1)
        $line = @(Script:MdEvents | Where-Object { $_.step -eq 'madeDelete' })[-1]
        $line.outcome | Should -Be 'warn'
        $line.detail | Should -Match 'The product did not delete app-01-os-asitwas: .*403'
        $line.detail | Should -Match 'The product did not delete app-01-d1-restored: .*409'
    }

    It 'with nothing left to delete it asks Azure nothing and says so' {
        Script:MdSeed -Doc @{ rollbackDisksDuringRollback = @(); restoreDisks = @() }
        Script:MdMockAzure @{}
        $r = Script:MdDelete
        @($r.Deleted).Count | Should -Be 0
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment -Times 0 -Exactly
        Should -Invoke -ModuleName VmMigrationFactory Test-VmfVmExists -Times 0 -Exactly
        $line = @(Script:MdEvents | Where-Object { $_.step -eq 'madeDelete' })[-1]
        $line.detail | Should -Match "'app-01' has no managed disks made from the safety copies left to delete\."
    }

    It 'a machine with no record in the migration is refused' {
        Script:MdSeed -NoRecord
        Script:MdMockAzure @{}
        { Script:MdDelete } | Should -Throw "*no record of 'app-01'*"
    }

    It 'deletes nothing of a machine that Azure does not show, or that it cannot read, and says why' -ForEach @(
        @{ Here = $false; Why = 'Azure does not have the machine now\.' }
        @{ Here = 'unreadable'; Why = 'could not read the machine in Azure' }) {
        Script:MdSeed
        Script:MdMockAzure (Script:MdAllFree) -MachineHere $Here
        $r = Script:MdDelete
        @($r.Deleted).Count | Should -Be 0
        Should -Invoke -ModuleName VmMigrationFactory Remove-VmfManagedDiskById -Times 0 -Exactly
        @(Script:MdLeft).Count | Should -Be 3
        $line = @(Script:MdEvents | Where-Object { $_.step -eq 'madeDelete' })[-1]
        $line.outcome | Should -Be 'warn'
        $line.detail | Should -Match $Why
        $line.detail | Should -Match 'does not delete a disk of a machine that Azure does not show'
    }

    It 'is refused, before any Azure call, on a machine whose move has not ended (<State>)' -ForEach @(
        @{ State = 'PRECHECK' }, @{ State = 'STOPPED' }, @{ State = 'VALIDATING' }) {
        Script:MdSeed -State $State
        Script:MdMockAzure (Script:MdAllFree)
        Mock -ModuleName VmMigrationFactory Enter-VmfMachineLease { throw 'the refusal comes before the hold' }
        { Script:MdDelete } | Should -Throw "*The move of 'app-01' has not ended*"
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment -Times 0 -Exactly
    }

    It 'is refused, before any Azure call, while a refused swap left the machine stopped (Finish the rollback first)' {
        Script:MdSeed -Doc @{ swapPending = [pscustomobject]@{ kept = @(); kind = 'rollback'; leftUtc = '2026-11-06T09:10:00Z'; error = 'e'; swaps = @(); swapped = @() } }
        Script:MdMockAzure (Script:MdAllFree)
        Mock -ModuleName VmMigrationFactory Enter-VmfMachineLease { throw 'the refusal comes before the hold' }
        { Script:MdDelete } | Should -Throw '*Use Finish the rollback on this machine first*'
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment -Times 0 -Exactly
    }

    It 'is refused, before any Azure call, while a restore has not ended, and while one that stopped holds the disks' -ForEach @(
        @{ Job = [pscustomobject]@{ kind = 'restore'; operationId = 'op-2'; startedUtc = '2026-11-07T09:00:00Z'; options = [pscustomobject]@{}; stamp = '202611070900'; phase = 'made'; resumes = 0 }; Words = "Restore this machine of 'app-01'*" }
        @{ Job = [pscustomobject]@{ kind = 'restore'; operationId = 'op-3'; startedUtc = '2026-11-07T09:00:00Z'; options = [pscustomobject]@{}; stamp = '202611070900'; phase = 'made'; resumes = 3; ended = [pscustomobject]@{ utc = '2026-11-07T10:00:00Z'; reason = 'gaveUp' } }; Words = 'Restore this machine stopped and did not finish*' }) {
        Script:MdSeed -Doc @{ putBackJob = $Job }
        Script:MdMockAzure (Script:MdAllFree)
        { Script:MdDelete } | Should -Throw "*$Words"
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment -Times 0 -Exactly
    }

    It 'is refused while a wave holds the machine, and holds the machine itself as a restore does' {
        Script:MdSeed
        Script:MdMockAzure (Script:MdAllFree)
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } { param($rp, $id) New-VmfLease -RunPath $rp -VmId $id -WorkerId 'worker-1' | Out-Null }
        { Script:MdDelete } | Should -Throw "*A wave migrates 'app-01' now*"
        Should -Invoke -ModuleName VmMigrationFactory Remove-VmfManagedDiskById -Times 0 -Exactly
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } { param($rp, $id) Remove-VmfLease -RunPath $rp -VmId $id -WorkerId 'worker-1' | Out-Null }
        $global:mdHolder = $null
        Mock -ModuleName VmMigrationFactory Enter-VmfMachineLease { $global:mdHolder = $Holder; [pscustomobject]@{ RunPath = $RunPath; VmId = $VmId; Holder = $Holder } }
        Mock -ModuleName VmMigrationFactory Exit-VmfMachineLease { }
        Script:MdDelete | Out-Null
        $global:mdHolder | Should -Be 'restore:op-md-1'
    }

    It 'reads the record again under the hold: a refusal that came while it waited for the hold stops it' {
        Script:MdSeed
        Script:MdMockAzure (Script:MdAllFree)
        # A restore starts between the first read and the hold.
        Mock -ModuleName VmMigrationFactory Enter-VmfMachineLease {
            & (Get-Module VmMigrationFactory) { param($rp, $id)
                $d = Read-VmfStateDoc -RunPath $rp -VmId $id
                $d | Add-Member -NotePropertyName putBackJob -NotePropertyValue ([pscustomobject]@{ kind = 'restore'; operationId = 'op-9'; startedUtc = '2026-11-07T09:00:00Z'; options = [pscustomobject]@{}; stamp = 's'; phase = 'begun'; resumes = 0 }) -Force
                Write-VmfStateDoc -RunPath $rp -Document $d
            } $RunPath $VmId
            [pscustomobject]@{ RunPath = $RunPath; VmId = $VmId; Holder = $Holder }
        }
        Mock -ModuleName VmMigrationFactory Exit-VmfMachineLease { }
        { Script:MdDelete } | Should -Throw "*Restore this machine of 'app-01'*"
        Should -Invoke -ModuleName VmMigrationFactory Remove-VmfManagedDiskById -Times 0 -Exactly
    }

    It 'kill and resume (rule 4): a job stopped after a delete, before its record, deletes only what is left when it runs again' {
        Script:MdSeed
        Script:MdMockAzure (Script:MdAllFree)
        # The container stops after Azure deleted the first disk, before the
        # mark of it. A mock's $PSBoundParameters is empty, so the call is
        # rebuilt by name.
        $global:mdReal = & (Get-Module VmMigrationFactory) { ${function:Set-VmfMadeDiskMark} }
        $global:mdKilled = $false
        Mock -ModuleName VmMigrationFactory Set-VmfMadeDiskMark {
            if (-not $global:mdKilled) { $global:mdKilled = $true; throw 'abandon this VM: the container stopped' }
            & $global:mdReal -RunPath $RunPath -VmId $VmId -DiskIds $DiskIds -Field $Field
        }
        { Script:MdDelete } | Should -Throw '*the container stopped*'
        @($global:mdDeleted.DiskId) | Should -Be @($script:rbOs)
        @(Script:MdLeft).Count | Should -Be 3 -Because 'nothing was marked'
        # Started again: the first disk is gone, so it counts as deleted; the others are deleted.
        InModuleScope VmMigrationFactory { $script:VmfMachineLeaseToken = $null; $script:VmfOpHeartbeat = $null }
        $global:mdDeleted.Clear()
        $again = Script:MdDelete -Op 'op-md-2'
        @($global:mdDeleted.DiskId) | Should -Be @($script:rbD0, $script:rsD1) -Because 'the first disk was deleted by the job that stopped'
        @($again.Deleted) | Should -Be @('app-01-os-asitwas', 'app-01-d0-asitwas', 'app-01-d1-restored')
        @(Script:MdLeft).Count | Should -Be 0
    }

    It 'the engine uses the shared rule and the cleanup''s delete, and no Azure call of its own (rule 3, the permission map)' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Remove-VmfMadeDisks.ps1')
        $code | Should -Match 'Get-VmfDeletableMadeDisks -StateDoc \$doc'
        $code | Should -Match 'Remove-VmfRollbackDisksBeforeMoveEntries -RunPath \$RunPath -VmId \$recorded -Disks \$disks -Step ''madeDelete'''
        $code | Should -Match 'Get-VmfMachineAbsentReason'
        $code | Should -Not -Match '\b(Invoke-AzRestMethod|Remove-AzDisk|Get-AzDisk)\b'
        $map = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'rbac-actions.json') -Raw
        $map | Should -Match 'Remove-VmfManagedDiskById'
        $map | Should -Match 'Microsoft\.Compute/disks/delete'
    }
}

Describe 'MADE-DISK-DELETE-1: the service starts it as it starts a delete of the earlier disks (rule 12)' {
    BeforeAll {
        $script:op = [pscustomobject]@{ Identity = 'operator@example.com'; Roles = @('Vmf.Operator') }
    }
    BeforeEach {
        [Environment]::SetEnvironmentVariable('VMF_ENGINE_JOB_ID', "/subscriptions/$script:sub/resourceGroups/rg/providers/Microsoft.App/jobs/engine")
        $script:store = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-mdf-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:store | Out-Null
        [Environment]::SetEnvironmentVariable('VMF_STORE_PATH', $script:store)
        Mock -ModuleName FacadeCore Get-VmfFacadeEngineJob {
            [pscustomobject]@{ properties = [pscustomobject]@{ template = [pscustomobject]@{ containers = @([pscustomobject]@{
                name = 'engine'; image = 'acr/vmf-engine:dev'; resources = [pscustomobject]@{ cpu = 1; memory = '2Gi' }; env = @() }) } } }
        }
        $global:mdDeleting = $false
        Mock -ModuleName FacadeCore Assert-VmfFacadeNotBeingDeleted { $global:mdDeleting = $true }
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $false }
        $global:mdBody = $null
        Mock -ModuleName FacadeCore Invoke-AzRestMethod { $global:mdBody = $Payload; [pscustomobject]@{ StatusCode = 202; Content = '{"name":"exec-1"}' } }
    }
    AfterEach {
        [Environment]::SetEnvironmentVariable('VMF_ENGINE_JOB_ID', $null)
        [Environment]::SetEnvironmentVariable('VMF_STORE_PATH', $null)
        Remove-Item $script:store -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Variable mdBody, mdDeleting, mdAsked -Scope Global -ErrorAction SilentlyContinue
    }

    It 'deletemade starts the engine with the machine and who asked, for an operator only' {
        Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'deletemade' -RunId 'run-x' -VmId $script:vmId | Out-Null
        $envs = @(($global:mdBody | ConvertFrom-Json).containers[0].env)
        ($envs | Where-Object name -EQ 'VMF_OPERATION').value | Should -Be 'deletemade'
        ($envs | Where-Object name -EQ 'VMF_VM_ID').value | Should -Be $script:vmId
        ($envs | Where-Object name -EQ 'VMF_RESTORED_BY').value | Should -Be 'operator@example.com'
        $global:mdDeleting | Should -BeTrue -Because 'nothing deletes a disk of a migration that is being deleted'
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'deletemade' -RunId 'run-x' } | Should -Throw '400:*machine*'
        foreach ($role in 'Vmf.Viewer', 'Vmf.Approver') {
            $who = [pscustomobject]@{ Identity = 'someone@example.com'; Roles = @($role) }
            { Invoke-VmfFacadeStartEngine -Principal $who -Operation 'deletemade' -RunId 'run-x' -VmId $script:vmId } | Should -Throw '403*'
        }
    }

    It 'is refused where a restore of the machine is refused: a job of the machine runs, a hold stands, a restore has not ended, the move has not ended' {
        $global:mdAsked = $null
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $global:mdAsked = @($Operation); $VmId -eq $script:vmId }
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'deletemade' -RunId 'run-x' -VmId $script:vmId } | Should -Throw '400: The engine works on this machine now*'
        foreach ($o in 'restore', 'finish', 'deleteearlier', 'deletemade') { @($global:mdAsked) | Should -Contain $o }
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $false }
        Mock -ModuleName VmMigrationFactory Get-VmfMachineLeaseRefusal { "A wave migrates 'app-01' now." }
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'deletemade' -RunId 'run-x' -VmId $script:vmId } | Should -Throw "400: A wave migrates 'app-01' now."
        Mock -ModuleName VmMigrationFactory Get-VmfMachineLeaseRefusal { $null }
        Mock -ModuleName VmMigrationFactory Get-VmfPutBackJobRefusal { "Restore this machine of 'app-01' did not finish." }
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'deletemade' -RunId 'run-x' -VmId $script:vmId } | Should -Throw "400: Restore this machine of 'app-01' did not finish."
        Mock -ModuleName VmMigrationFactory Get-VmfPutBackJobRefusal { $null }
        Mock -ModuleName VmMigrationFactory Get-VmfMadeDiskDeleteRefusal { "The move of 'app-01' has not ended." }
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'deletemade' -RunId 'run-x' -VmId $script:vmId } | Should -Throw "400: The move of 'app-01' has not ended."
        $global:mdBody | Should -BeNullOrEmpty -Because 'no job started'
    }

    It 'the engine''s own refusal is asked before a job starts, and only for this operation' {
        $global:mdAsked = $false
        Mock -ModuleName VmMigrationFactory Get-VmfMadeDiskDeleteRefusal { $global:mdAsked = $true; $null }
        Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'deleteearlier' -RunId 'run-x' -VmId $script:vmId | Out-Null
        $global:mdAsked | Should -BeFalse
        Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'deletemade' -RunId 'run-x' -VmId $script:vmId | Out-Null
        $global:mdAsked | Should -BeTrue
    }

    It 'a restore, a finish and a delete of the earlier disks are refused while a delete of the made disks of the machine runs' {
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { @($Operation) -contains 'deletemade' }
        Mock -ModuleName VmMigrationFactory Get-VmfPutBackRetirementRefusal { $null }
        Mock -ModuleName VmMigrationFactory Get-VmfPreviewPutBackRefusal { $null }
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'restore' -RunId 'run-x' -VmId $script:vmId -Note 'n' -DiskSource 'prepared' } | Should -Throw '400:*'
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'finish' -RunId 'run-x' -VmId $script:vmId -Note 'n' } | Should -Throw '400:*'
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'deleteearlier' -RunId 'run-x' -VmId $script:vmId } | Should -Throw '400:*'
        $global:mdBody | Should -BeNullOrEmpty
    }

    It 'the engine runs deletemade through Remove-VmfMadeDisks, with the machine and who asked' {
        $text = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'docker' 'entrypoint.ps1')
        $text | Should -Match "'deletemade' \{"
        $text | Should -Match 'Remove-VmfMadeDisks @madeParams'
        $block = [regex]::Match($text, "(?s)'deletemade' \{.*?Remove-VmfMadeDisks @madeParams").Value
        $block | Should -Match 'VmId\s+= \$env:VMF_VM_ID'
        $block | Should -Match 'By\s+= .*VMF_RESTORED_BY'
        $text | Should -Match 'Unknown VMF_OPERATION .*deletemade'
    }

    It 'the route forwards the machine, and the page posts to it (REACH-1, REACH-2)' {
        Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'app' 'PostStartEngine' 'run.ps1') | Should -Match 'if \(\$body\.vmId\) \{ \$params\.VmId = \[string\]\$body\.vmId \}'
        $page = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'migrations.js')
        $page | Should -Match "made: \{ op: 'deletemade'"
        $page | Should -Match 'apiFetch\(`runs/\$\{runSeg\(\)\}/engine/\$\{k\.op\}`, k\.set \? \{ vmId, diskSet: k\.set \} : \{ vmId \}\)'   # ROLLBACK-ORIGINALS-LEFT-1: a set only for the original disks
    }
}

Describe 'MADE-DISK-DELETE-1: the engine''s refusal is one function the service asks too' {
    It 'Get-VmfMadeDiskDeleteRefusal refuses a move that has not ended, a job, a held restore and a refused swap, and nothing else' {
        $ask = { param($d) InModuleScope VmMigrationFactory -Parameters @{ d = $d } { param($d) Get-VmfMadeDiskDeleteRefusal -Doc $d -VmName 'app-01' } }
        foreach ($st in 'MIGRATED', 'FAILED_ROLLED_BACK', 'SKIPPED', 'FAILED_NEEDS_ATTENTION', 'NEEDS_DECISION') {
            & $ask ([pscustomobject]@{ state = $st }) | Should -BeNullOrEmpty -Because "$st has ended"
        }
        foreach ($st in @(InModuleScope VmMigrationFactory { (Get-VmfEngineStates).Working })) {
            & $ask ([pscustomobject]@{ state = $st }) | Should -Match "The move of 'app-01' has not ended: it is at the step $st\." -Because $st
        }
        & $ask ([pscustomobject]@{ state = 'MIGRATED'; swapPending = [pscustomobject]@{ kept = @(); kind = 'restore'; swaps = @(); swapped = @() } }) | Should -Match 'Finish the restore'
        & $ask ([pscustomobject]@{ state = 'MIGRATED'; putBackJob = [pscustomobject]@{ kind = 'finish'; operationId = 'o'; options = [pscustomobject]@{ finishes = 'rollback' } } }) | Should -Match 'Finish the rollback'
    }
}
