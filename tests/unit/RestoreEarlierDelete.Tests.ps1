#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# RESTORE-EARLIER-DELETE-1 (approved design, 2026-10-25). A restore with
# "Yes. Keep them, detached, in Azure" leaves each managed disk the machine had
# detached in Azure. The machine's panel lists them under Its earlier managed
# disks, and each costs money - and the only way to delete them was the Azure
# portal (hard rule 12).
#
# Now Delete these disks, for an operator, starts the engine operation
# 'deleteearlier' through the service's engine route, as Restore this machine
# and Finish the restore start theirs. The engine (Remove-VmfRestoreEarlierDisks):
#   - deletes ONLY the disks the restore's own record names
#     (Get-VmfRestoreEarlierDisks, one rule with the page, held to
#     tests/fixtures/restore-earlier-disks.json), by resource id;
#   - skips a disk that is attached to any machine at that moment, and a disk
#     it cannot read, and says which;
#   - counts a disk that is already gone as deleted (rule 4);
#   - records each disk on restore.earlierDisksDeleted (vm-state v40) the
#     moment it is deleted, so the list empties and a job killed part way
#     deletes only what is left when it runs again;
#   - holds the machine as a restore does, and is refused on the machine
#     where a restore or finish is refused.
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
    $script:osOld = & $script:disk 'app-01-os'
    $script:d0Old = & $script:disk 'app-01-data0'
    $script:d1Old = & $script:disk 'app-01-data1'

    # A restore that kept the earlier disks: the OS disk and two data disks.
    function Script:ReRestore {
        param([hashtable]$Extra = @{})
        $r = [ordered]@{
            operationId = 'op-restore-1'; restoredUtc = '2026-11-06T09:00:00.0000000Z'; restoredBy = 'operator@example.com'; note = 'did not boot'
            fromSnapshotId = "/subscriptions/$script:sub/resourceGroups/rg-app/providers/Microsoft.Compute/snapshots/app-01-prepared"; fromCopy = 'prepared'
            diskNaming = 'new'; previousDiskId = $script:osOld; previousDiskName = 'app-01-os'
            newDiskId = (& $script:disk 'app-01-os-restored'); newDiskName = 'app-01-os-restored'; diskIdChanged = $true; retainedDiskId = $script:osOld
            dataDisks = @(
                [ordered]@{ lun = 0; previousDiskId = $script:d0Old; previousDiskName = 'app-01-data0'; newDiskId = (& $script:disk 'app-01-data0-r'); newDiskName = 'app-01-data0-r' }
                [ordered]@{ lun = 1; previousDiskId = $script:d1Old; previousDiskName = 'app-01-data1'; newDiskId = (& $script:disk 'app-01-data1-r'); newDiskName = 'app-01-data1-r' })
            dataDisksKept = @()
        }
        foreach ($k in $Extra.Keys) { $r[$k] = $Extra[$k] }
        $r
    }
    # A migration with the machine MIGRATED, then restored with the record given.
    function Script:ReSeed {
        param($Restore = (Script:ReRestore), [hashtable]$Doc = @{})
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId; r = $Restore; extra = $Doc } {
            param($rp, $id, $r, $extra)
            Initialize-VmfRun -RunPath $rp -RunId 're-test' -Kind 'migration' | Out-Null
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document ([ordered]@{ schemaVersion = 1; entries = @([ordered]@{ schemaVersion = 1; vmId = $id; wave = 'w1' }) }) -Depth 24
            New-VmfStateDoc -RunPath $rp -RunId 're-test' -VmId $id -Wave 'w1' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'MIGRATED' -Outcome ok -Detail 'moved' | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            if ($null -ne $r) { $doc | Add-Member -NotePropertyName restore -NotePropertyValue ([pscustomobject]$r) -Force }
            foreach ($k in $extra.Keys) { $doc | Add-Member -NotePropertyName $k -NotePropertyValue $extra[$k] -Force }
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
    }
    function Script:ReDoc { InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id } }
    function Script:ReEvents { InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { param($rp) @(Read-VmfEvents -RunPath $rp) } }

    # Azure, as a map of disk id -> what a read of it gives. A disk not in the
    # map reads as gone. $global:reDeleted lists each delete asked for.
    function Script:ReMockAzure {
        param([hashtable]$Disks)
        $global:reDisks = @{}
        foreach ($k in $Disks.Keys) { $global:reDisks[$k.ToLowerInvariant()] = $Disks[$k] }
        $global:reDeleted = [System.Collections.Generic.List[object]]::new()
        $global:reDeleteFail = @{}
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { $null }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment {
            $state = $global:reDisks[$DiskId.ToLowerInvariant()]
            if ($state -eq 'unreadable') { throw "Reading disk '$DiskId' failed with 500: the service is busy" }
            if (-not $state) { return [pscustomobject]@{ Exists = $false; ManagedBy = ''; SourceResourceId = '' } }
            [pscustomobject]@{ Exists = $true; ManagedBy = $(if ($state -eq 'detached') { '' } else { [string]$state }); SourceResourceId = '' }
        }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDiskById {
            if ($global:reDeleteFail[$DiskId.ToLowerInvariant()]) { throw "Deleting disk '$DiskId' failed with 409: OperationNotAllowed" }
            $global:reDeleted.Add([pscustomobject]@{ DiskId = $DiskId; MachineId = $MachineId; Groups = @($ResourceGroupNames) })
            $global:reDisks.Remove($DiskId.ToLowerInvariant())
        }
    }
    function Script:ReDelete { Remove-VmfRestoreEarlierDisks -RunPath $script:runPath -VmId $script:vmId -By 'operator@example.com' -CorrelationId 'op-del-1' -Confirm:$false }
}

AfterAll {
    Remove-Variable reDisks, reDeleted, reDeleteFail, reKilled, reReal -Scope Global -ErrorAction SilentlyContinue
}

Describe 'RESTORE-EARLIER-DELETE-1: which disks are the earlier disks of a restore (one rule with the page)' {
    It 'Get-VmfRestoreEarlierDisks gives each case of the shared fixture' {
        $fixture = Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' 'restore-earlier-disks.json') -Raw | ConvertFrom-Json
        @($fixture.cases).Count | Should -BeGreaterThan 8
        foreach ($case in $fixture.cases) {
            $got = @(InModuleScope VmMigrationFactory -Parameters @{ r = $case.restore } { param($r) Get-VmfRestoreEarlierDisks -Restore $r })
            $want = @($case.disks)
            $got.Count | Should -Be $want.Count -Because $case.why
            for ($i = 0; $i -lt $want.Count; $i++) {
                $got[$i].diskId | Should -BeExactly $want[$i].diskId -Because $case.why
                $got[$i].name | Should -BeExactly $want[$i].name -Because $case.why
                $got[$i].lun | Should -Be $want[$i].lun -Because $case.why
            }
        }
    }
}

Describe 'RESTORE-EARLIER-DELETE-1: the engine deletes the earlier disks of the restore (deleteearlier)' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-re-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    }
    AfterEach {
        InModuleScope VmMigrationFactory { $script:VmfMachineLeaseToken = $null; $script:VmfOpHeartbeat = $null }
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
    }

    It 'deletes only the disks the record names, by resource id, and records each one so the list empties' {
        Script:ReSeed
        $other = & $script:disk 'app-01-something-else'
        Script:ReMockAzure @{ $script:osOld = 'detached'; $script:d0Old = 'detached'; $script:d1Old = 'detached'; $other = 'detached' }
        $r = Script:ReDelete
        @($global:reDeleted.DiskId) | Should -Be @($script:osOld, $script:d0Old, $script:d1Old)
        foreach ($d in $global:reDeleted) {
            $d.MachineId | Should -Be $script:vmId
            @($d.Groups) | Should -Contain 'rg-app'
        }
        @($r.Deleted) | Should -Be @('app-01-os', 'app-01-data0', 'app-01-data1')
        @($r.Skipped).Count | Should -Be 0
        $doc = Script:ReDoc
        $doc.schemaVersion | Should -Be 51
        $rows = @($doc.restore.earlierDisksDeleted)
        @($rows.diskId) | Should -Be @($script:osOld, $script:d0Old, $script:d1Old)
        foreach ($row in $rows) {
            $row.deletedBy | Should -Be 'operator@example.com'
            [string]$row.deletedUtc | Should -Not -BeNullOrEmpty
            $row.gone | Should -BeFalse
        }
        @(InModuleScope VmMigrationFactory -Parameters @{ r = $doc.restore } { param($r) Get-VmfRestoreEarlierDisks -Restore $r }).Count | Should -Be 0
        $line = @(Script:ReEvents | Where-Object { $_.step -eq 'earlierDelete' })[-1]
        $line.outcome | Should -Be 'ok'
        $line.detail | Should -Match "^The product deleted 3 earlier managed disks of 'app-01': app-01-os, app-01-data0, app-01-data1\. operator@example\.com asked for it\.$"
    }

    It 'skips a disk attached to a machine at that moment, says which, and keeps it in the list' {
        Script:ReSeed
        $other = "/subscriptions/$script:sub/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/app-02"
        Script:ReMockAzure @{ $script:osOld = 'detached'; $script:d0Old = $other; $script:d1Old = 'detached' }
        $r = Script:ReDelete
        @($global:reDeleted.DiskId) | Should -Be @($script:osOld, $script:d1Old)
        @($r.Skipped).Count | Should -Be 1
        $r.Skipped[0].name | Should -Be 'app-01-data0'
        $r.Skipped[0].why | Should -Match "is attached to the machine 'app-02'"
        $left = @(InModuleScope VmMigrationFactory -Parameters @{ r = (Script:ReDoc).restore } { param($r) Get-VmfRestoreEarlierDisks -Restore $r })
        @($left.diskId) | Should -Be @($script:d0Old)
        $line = @(Script:ReEvents | Where-Object { $_.step -eq 'earlierDelete' })[-1]
        $line.outcome | Should -Be 'warn'
        $line.detail | Should -Match "The product did not delete app-01-data0: it is attached to the machine 'app-02'\."
    }

    It 'a disk that is already gone counts as deleted, with no delete asked of Azure' {
        Script:ReSeed
        Script:ReMockAzure @{ $script:osOld = 'detached'; $script:d1Old = 'detached' }   # data0 is gone
        $r = Script:ReDelete
        @($global:reDeleted.DiskId) | Should -Be @($script:osOld, $script:d1Old)
        @($r.Deleted) | Should -Contain 'app-01-data0'
        $row = @((Script:ReDoc).restore.earlierDisksDeleted | Where-Object { $_.diskId -eq $script:d0Old })
        $row.Count | Should -Be 1
        $row[0].gone | Should -BeTrue
    }

    It 'a disk it cannot read, or that Azure does not delete, is not recorded, and stays in the list' {
        Script:ReSeed
        Script:ReMockAzure @{ $script:osOld = 'unreadable'; $script:d0Old = 'detached'; $script:d1Old = 'detached' }
        $global:reDeleteFail[$script:d1Old.ToLowerInvariant()] = $true
        $r = Script:ReDelete
        @($global:reDeleted.DiskId) | Should -Be @($script:d0Old)
        @($r.Skipped.name) | Should -Be @('app-01-os', 'app-01-data1')
        $r.Skipped[0].why | Should -Match 'could not read it'
        $r.Skipped[1].why | Should -Match 'Azure did not delete it'
        @((Script:ReDoc).restore.earlierDisksDeleted.diskId) | Should -Be @($script:d0Old)
    }

    It 'with nothing left to delete it asks Azure nothing and says so' {
        Script:ReSeed (Script:ReRestore @{ diskNaming = 'preserve'; diskIdChanged = $false; retainedDiskId = $null; dataDisks = @() })
        Script:ReMockAzure @{}
        $r = Script:ReDelete
        @($r.Deleted).Count | Should -Be 0
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment -Times 0 -Exactly
        $line = @(Script:ReEvents | Where-Object { $_.step -eq 'earlierDelete' })[-1]
        $line.detail | Should -Match "The restore of 'app-01' has no earlier managed disks left to delete\."
    }

    It 'a machine with no restore is refused' {
        Script:ReSeed $null
        Script:ReMockAzure @{}
        { Script:ReDelete } | Should -Throw "*'app-01' has no restore*"
    }

    It 'is refused, before any Azure call, while a refused swap left the machine stopped (Finish the restore first)' {
        Script:ReSeed -Doc @{ swapPending = [pscustomobject]@{ kept = @(); kind = 'restore'; leftUtc = '2026-11-06T09:10:00Z'; error = 'e'; swaps = @(); swapped = @() } }
        Script:ReMockAzure @{ $script:osOld = 'detached' }
        { Script:ReDelete } | Should -Throw '*Use Finish the restore on this machine first*'
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment -Times 0 -Exactly
    }

    It 'is refused, before any Azure call, while a restore of the machine has not ended' {
        Script:ReSeed -Doc @{ putBackJob = [pscustomobject]@{ kind = 'restore'; operationId = 'op-2'; startedUtc = '2026-11-07T09:00:00Z'; options = [pscustomobject]@{}; stamp = '202611070900'; phase = 'made'; resumes = 0 } }
        Script:ReMockAzure @{ $script:osOld = 'detached' }
        { Script:ReDelete } | Should -Throw "*Restore this machine of 'app-01'*"
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment -Times 0 -Exactly
    }

    It 'is refused while a wave holds the machine, and holds the machine itself as a restore does' {
        Script:ReSeed
        Script:ReMockAzure @{ $script:osOld = 'detached'; $script:d0Old = 'detached'; $script:d1Old = 'detached' }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } { param($rp, $id) New-VmfLease -RunPath $rp -VmId $id -WorkerId 'worker-1' | Out-Null }
        { Script:ReDelete } | Should -Throw "*A wave migrates 'app-01' now*"
        Should -Invoke -ModuleName VmMigrationFactory Remove-VmfManagedDiskById -Times 0 -Exactly
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } { param($rp, $id) Remove-VmfLease -RunPath $rp -VmId $id -WorkerId 'worker-1' | Out-Null }
        $global:reHolder = $null
        Mock -ModuleName VmMigrationFactory Enter-VmfMachineLease { $global:reHolder = $Holder; [pscustomobject]@{ RunPath = $RunPath; VmId = $VmId; Holder = $Holder } }
        Mock -ModuleName VmMigrationFactory Exit-VmfMachineLease { }
        Script:ReDelete | Out-Null
        $global:reHolder | Should -Be 'restore:op-del-1'
        Remove-Variable reHolder -Scope Global -ErrorAction SilentlyContinue
    }

    It 'kill and resume (rule 4): a job stopped after a delete, before its record, deletes only what is left when it runs again' {
        Script:ReSeed
        Script:ReMockAzure @{ $script:osOld = 'detached'; $script:d0Old = 'detached'; $script:d1Old = 'detached' }
        # The job dies after Azure deleted the first disk, before the record of
        # it; the next job writes its records with the real function. A mock's
        # $PSBoundParameters is empty, so the call is rebuilt by name.
        $global:reReal = & (Get-Module VmMigrationFactory) { ${function:Add-VmfRestoreEarlierDeleted} }
        $global:reKilled = $false
        Mock -ModuleName VmMigrationFactory Add-VmfRestoreEarlierDeleted {
            if (-not $global:reKilled) { $global:reKilled = $true; throw 'the container stopped' }
            & $global:reReal -RunPath $RunPath -VmId $VmId -RestoreOperationId $RestoreOperationId -Entry $Entry
        }
        { Script:ReDelete } | Should -Throw '*the container stopped*'
        @($global:reDeleted.DiskId) | Should -Be @($script:osOld)
        @((Script:ReDoc).restore.earlierDisksDeleted | Where-Object { $_ }).Count | Should -Be 0
        # Started again: the first disk is gone, so it counts as deleted; the others are deleted.
        InModuleScope VmMigrationFactory { $script:VmfMachineLeaseToken = $null; $script:VmfOpHeartbeat = $null }
        $global:reDeleted.Clear()
        $again = Remove-VmfRestoreEarlierDisks -RunPath $script:runPath -VmId $script:vmId -By 'operator@example.com' -CorrelationId 'op-del-2' -Confirm:$false
        @($global:reDeleted.DiskId) | Should -Be @($script:d0Old, $script:d1Old) -Because 'the first disk was deleted by the job that stopped'
        @($again.Deleted) | Should -Be @('app-01-os', 'app-01-data0', 'app-01-data1')
        $rows = @((Script:ReDoc).restore.earlierDisksDeleted)
        @($rows.diskId) | Should -Be @($script:osOld, $script:d0Old, $script:d1Old)
        ($rows | Where-Object diskId -EQ $script:osOld).gone | Should -BeTrue
    }

    It 'the record of a deleted disk is written only on the restore that names it' {
        Script:ReSeed
        $entry = [ordered]@{ diskId = (& $script:disk 'not-on-the-record'); deletedUtc = '2026-11-07T10:00:00Z'; deletedBy = 'operator@example.com'; gone = $false }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId; e = $entry } { param($rp, $id, $e) Add-VmfRestoreEarlierDeleted -RunPath $rp -VmId $id -RestoreOperationId 'op-restore-1' -Entry $e } | Should -BeFalse
        $entry.diskId = $script:osOld
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId; e = $entry } { param($rp, $id, $e) Add-VmfRestoreEarlierDeleted -RunPath $rp -VmId $id -RestoreOperationId 'op-of-a-later-restore' -Entry $e } | Should -BeFalse
        @((Script:ReDoc).restore.PSObject.Properties.Name) | Should -Not -Contain 'earlierDisksDeleted'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId; e = $entry } { param($rp, $id, $e) Add-VmfRestoreEarlierDeleted -RunPath $rp -VmId $id -RestoreOperationId 'op-restore-1' -Entry $e } | Should -BeTrue
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId; e = $entry } { param($rp, $id, $e) Add-VmfRestoreEarlierDeleted -RunPath $rp -VmId $id -RestoreOperationId 'op-restore-1' -Entry $e } | Should -BeTrue
        @((Script:ReDoc).restore.earlierDisksDeleted).Count | Should -Be 1 -Because 'a second record of one disk adds nothing'
    }

    It 'a deleted disk that a put-back made is marked deleted on its list too' {
        $made = [pscustomobject]@{ diskId = $script:osOld; diskName = 'app-01-os'; madeUtc = '2026-11-01T09:00:00Z'; usedUtc = '2026-11-01T09:10:00Z' }
        Script:ReSeed -Doc @{ restoreDisks = @($made) }
        Script:ReMockAzure @{ $script:osOld = 'detached'; $script:d0Old = 'detached'; $script:d1Old = 'detached' }
        Script:ReDelete | Out-Null
        [string]@((Script:ReDoc).restoreDisks)[0].deletedUtc | Should -Not -BeNullOrEmpty
    }
}

Describe 'RESTORE-EARLIER-DELETE-1: the service starts it as it starts a restore (rule 12)' {
    BeforeAll {
        $script:op = [pscustomobject]@{ Identity = 'operator@example.com'; Roles = @('Vmf.Operator') }
    }
    BeforeEach {
        [Environment]::SetEnvironmentVariable('VMF_ENGINE_JOB_ID', "/subscriptions/$script:sub/resourceGroups/rg/providers/Microsoft.App/jobs/engine")
        $script:store = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-ref-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:store | Out-Null
        [Environment]::SetEnvironmentVariable('VMF_STORE_PATH', $script:store)
        Mock -ModuleName FacadeCore Get-VmfFacadeEngineJob {
            [pscustomobject]@{ properties = [pscustomobject]@{ template = [pscustomobject]@{ containers = @([pscustomobject]@{
                name = 'engine'; image = 'acr/vmf-engine:dev'; resources = [pscustomobject]@{ cpu = 1; memory = '2Gi' }; env = @() }) } } }
        }
        $global:reDeleting = $false
        Mock -ModuleName FacadeCore Assert-VmfFacadeNotBeingDeleted { $global:reDeleting = $true }
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $false }
        $global:reBody = $null
        Mock -ModuleName FacadeCore Invoke-AzRestMethod { $global:reBody = $Payload; [pscustomobject]@{ StatusCode = 202; Content = '{"name":"exec-1"}' } }
    }
    AfterEach {
        [Environment]::SetEnvironmentVariable('VMF_ENGINE_JOB_ID', $null)
        [Environment]::SetEnvironmentVariable('VMF_STORE_PATH', $null)
        Remove-Item $script:store -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Variable reBody, reDeleting, reAsked -Scope Global -ErrorAction SilentlyContinue
    }

    It 'deleteearlier starts the engine with the machine and who asked, for an operator only' {
        Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'deleteearlier' -RunId 'run-x' -VmId $script:vmId | Out-Null
        $envs = @(($global:reBody | ConvertFrom-Json).containers[0].env)
        ($envs | Where-Object name -EQ 'VMF_OPERATION').value | Should -Be 'deleteearlier'
        ($envs | Where-Object name -EQ 'VMF_VM_ID').value | Should -Be $script:vmId
        ($envs | Where-Object name -EQ 'VMF_RESTORED_BY').value | Should -Be 'operator@example.com'
        $global:reDeleting | Should -BeTrue -Because 'nothing deletes a disk of a migration that is being deleted'
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'deleteearlier' -RunId 'run-x' } | Should -Throw '400:*machine*'
        foreach ($role in 'Vmf.Viewer', 'Vmf.Approver') {
            $who = [pscustomobject]@{ Identity = 'someone@example.com'; Roles = @($role) }
            { Invoke-VmfFacadeStartEngine -Principal $who -Operation 'deleteearlier' -RunId 'run-x' -VmId $script:vmId } | Should -Throw '403*'
        }
    }

    It 'is refused where a restore of the machine is refused: a job of the machine runs, a hold stands, a restore has not ended' {
        $global:reAsked = $null
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $global:reAsked = @($Operation); $VmId -eq $script:vmId }
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'deleteearlier' -RunId 'run-x' -VmId $script:vmId } | Should -Throw '400: The engine works on this machine now*'
        @($global:reAsked) | Should -Contain 'restore'
        @($global:reAsked) | Should -Contain 'finish'
        @($global:reAsked) | Should -Contain 'deleteearlier'
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $false }
        Mock -ModuleName VmMigrationFactory Get-VmfMachineLeaseRefusal { "A wave migrates 'app-01' now." }
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'deleteearlier' -RunId 'run-x' -VmId $script:vmId } | Should -Throw "400: A wave migrates 'app-01' now."
        Mock -ModuleName VmMigrationFactory Get-VmfMachineLeaseRefusal { $null }
        Mock -ModuleName VmMigrationFactory Get-VmfPutBackJobRefusal { "Restore this machine of 'app-01' did not finish." }
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'deleteearlier' -RunId 'run-x' -VmId $script:vmId } | Should -Throw "400: Restore this machine of 'app-01' did not finish."
        $global:reBody | Should -BeNullOrEmpty -Because 'no job started'
    }

    It 'a restore and a finish are refused while a delete of the earlier disks of the machine runs' {
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { @($Operation) -contains 'deleteearlier' }
        Mock -ModuleName VmMigrationFactory Get-VmfPutBackRetirementRefusal { $null }
        Mock -ModuleName VmMigrationFactory Get-VmfPreviewPutBackRefusal { $null }
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'restore' -RunId 'run-x' -VmId $script:vmId -Note 'n' -DiskSource 'prepared' } | Should -Throw '400:*'
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'finish' -RunId 'run-x' -VmId $script:vmId -Note 'n' } | Should -Throw '400:*'
        $global:reBody | Should -BeNullOrEmpty
    }

    It 'the engine runs deleteearlier through Remove-VmfRestoreEarlierDisks, with the machine and who asked' {
        $text = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'docker' 'entrypoint.ps1')
        $text | Should -Match "'deleteearlier' \{"
        $text | Should -Match 'Remove-VmfRestoreEarlierDisks @deleteParams'
        $text | Should -Match 'VmId\s+= \$env:VMF_VM_ID'
    }

    It 'the route forwards the machine, and the page posts to it (REACH-1, REACH-2)' {
        Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'app' 'PostStartEngine' 'run.ps1') | Should -Match 'if \(\$body\.vmId\) \{ \$params\.VmId = \[string\]\$body\.vmId \}'
        $page = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'migrations.js')
        # MADE-DISK-DELETE-1: the shared slide-out posts the operation its entry names.
        $page | Should -Match "earlier: \{ op: 'deleteearlier'"
        $page | Should -Match 'apiFetch\(`runs/\$\{runSeg\(\)\}/engine/\$\{k\.op\}`, k\.set \? \{ vmId, diskSet: k\.set \} : \{ vmId \}\)'   # ROLLBACK-ORIGINALS-LEFT-1: a set only for the original disks
    }

    It 'no new Azure action: the engine deletes and reads a disk through the functions the permission map already names' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Remove-VmfRestoreEarlierDisks.ps1')
        $code | Should -Match 'Remove-VmfManagedDiskById'
        $code | Should -Match 'Get-VmfManagedDiskAttachment'
        $code | Should -Not -Match '\b(Invoke-AzRestMethod|Remove-AzDisk|Get-AzDisk)\b' -Because 'rule 3: every Azure call is in azureops'
        $map = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'rbac-actions.json') -Raw
        $map | Should -Match 'Remove-VmfManagedDiskById'
        $map | Should -Match 'Microsoft\.Compute/disks/delete'
    }
}

Describe 'RESTORE-EARLIER-DELETE-1: the contract (rule 1)' {
    It 'vm-state v40 declares restore.earlierDisksDeleted; the sample validates; a row with another field is refused' {
        $schemaFile = Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json'
        $schema = Get-Content $schemaFile -Raw | ConvertFrom-Json
        $schema.properties.schemaVersion.const | Should -Be 51
        (InModuleScope VmMigrationFactory { $script:VmfStateDocSchemaVersion }) | Should -Be 51
        $item = $schema.properties.restore.properties.earlierDisksDeleted.items
        @($item.required) | Should -Be @('diskId', 'deletedUtc')
        $sample = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'vm-state.sample.json') -Raw
        ($sample | ConvertFrom-Json).schemaVersion | Should -Be 51
        @(($sample | ConvertFrom-Json).restore.earlierDisksDeleted).Count | Should -BeGreaterThan 0
        Test-Json -Json $sample -SchemaFile $schemaFile | Should -BeTrue
        $base = { param($row) '{"schemaVersion":51,"runId":"r","vmId":"v","state":"MIGRATED","history":[],"restore":{"earlierDisksDeleted":[' + $row + ']}}' }
        Test-Json -Json (& $base '{"diskId":"/d/x","deletedUtc":"2026-11-07T10:00:00Z","deletedBy":"operator@example.com","gone":true}') -SchemaFile $schemaFile | Should -BeTrue
        Test-Json -Json (& $base '{"diskId":"/d/x","deletedUtc":"2026-11-07T10:00:00Z","name":"x"}') -SchemaFile $schemaFile -ErrorAction SilentlyContinue | Should -BeFalse
        Test-Json -Json (& $base '{"deletedUtc":"2026-11-07T10:00:00Z"}') -SchemaFile $schemaFile -ErrorAction SilentlyContinue | Should -BeFalse
        (Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw) | Should -Match '## vm-state v39 -> v40 \(2026-11-07, RESTORE-EARLIER-DELETE-1\)'
    }
}
