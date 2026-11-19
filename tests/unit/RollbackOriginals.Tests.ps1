#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# ROLLBACK-ORIGINALS-LEFT-1 (in 1.0 since 2026-11-08). Since the
# put-back disks, a rollback swaps on disks made from the first safety copy,
# and the disks the machine had before the migration stay in Azure, detached,
# costing money. Nothing named them and nothing deleted them.
#
# Now:
#   - the rollback records each disk it swapped off on rollbackOriginals
#     (vm-state v41), in the same write as the disk it put on, after each swap
#     (rule 4), and so does Finish the rollback;
#   - the record is kept through Try this machine again (it is not part of an
#     attempt);
#   - OLD-STATE-READERS-PAGE-1: a document with no rollbackOriginals has none -
#     nothing comes from the captures (no writer of this version leaves one);
#   - the machine's panel lists them (Get-VmfRollbackOriginalDisks, one rule
#     with the page, held to tests/fixtures/rollback-originals.json);
#   - Delete these disks deletes them through the engine operation that
#     deletes a restore's earlier disks (deleteearlier, with diskSet
#     rollback): each disk read first, an attached one kept, a gone one counted
#     as deleted, each one recorded the moment it is deleted;
#   - nothing deletes them on its own: the daily cleanup counts them as the
#     machine's disks (Get-VmfRecordedMachineDiskIds).
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    $script:sub = '00000000-0000-0000-0000-000000000000'
    $script:vmId = "/subscriptions/$script:sub/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/app-01"
    $script:disk = { param($name) "/subscriptions/$script:sub/resourceGroups/rg-app/providers/Microsoft.Compute/disks/$name" }
    $script:osOld = & $script:disk 'app-01-os'
    $script:d0Old = & $script:disk 'app-01-data0'
    $script:d1Old = & $script:disk 'app-01-data1'
    $script:osNew = & $script:disk 'app-01-os-asitwas-202611080950'
    $script:d0New = & $script:disk 'app-01-os-d0-asitwas-202611080950'
    $script:d1New = & $script:disk 'app-01-os-d1-asitwas-202611080950'

    function Script:RoCapture {
        param([string]$Os = $script:osOld, [string]$D0 = $script:d0Old, [string]$D1 = $script:d1Old)
        [pscustomobject]@{
            size = 'Standard_D2s_v4'; controller = 'SCSI'
            osDisk = [pscustomobject]@{ name = ($Os -split '/')[-1]; managedDiskId = $Os; skuName = 'Premium_LRS' }
            dataDisks = @(
                [pscustomobject]@{ lun = 0; name = ($D0 -split '/')[-1]; managedDiskId = $D0; skuName = 'Premium_LRS' }
                [pscustomobject]@{ lun = 1; name = ($D1 -split '/')[-1]; managedDiskId = $D1; skuName = 'Premium_LRS' })
        }
    }
    # A machine in a migration, in the state given, with the fields given.
    function Script:RoSeed {
        param([string]$State = 'FAILED_ROLLED_BACK', [hashtable]$Doc = @{}, [int]$Version = (Get-VmfTestStateVersion))
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId; st = $State; extra = $Doc; v = $Version; cap = (Script:RoCapture) } {
            param($rp, $id, $st, $extra, $v, $cap)
            Initialize-VmfRun -RunPath $rp -RunId 'ro-test' -Kind 'migration' | Out-Null
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document ([ordered]@{ schemaVersion = 1; entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; wave = 'w1'; path = 'A' }) }) -Depth 24
            New-VmfStateDoc -RunPath $rp -RunId 'ro-test' -VmId $id -Wave 'w1' | Out-Null
            if ($st -ne 'PLANNED') { Add-VmfStateTransition -RunPath $rp -VmId $id -NewState $st -Outcome ok -Detail 'test' | Out-Null }
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $doc | Add-Member -NotePropertyName captured -NotePropertyValue ([pscustomobject]@{ vmConfig = $cap }) -Force
            foreach ($k in $extra.Keys) { $doc | Add-Member -NotePropertyName $k -NotePropertyValue $extra[$k] -Force }
            $doc.schemaVersion = $v
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
    }
    function Script:RoDoc { InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id } }
    function Script:RoEvents { InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { param($rp) @(Read-VmfEvents -RunPath $rp) } }
    function Script:RoContext { [pscustomobject]@{ RunPath = $script:runPath; VmId = $script:vmId; VmName = 'app-01'; Rg = 'rg-app' } }
    function Script:RoRecord {
        param($OsDisk, [object[]]$DataDisks = @(), [switch]$Done)
        InModuleScope VmMigrationFactory -Parameters @{ c = (Script:RoContext); os = $OsDisk; dd = $DataDisks; done = [bool]$Done } {
            param($c, $os, $dd, $done)
            Set-VmfRollbackRecord -Context $c -Path 'A' -OsDisk $os -DataDisks @($dd) -Done:$done
        }
    }
    function Script:RoOriginals { param($Doc = (Script:RoDoc)) @(InModuleScope VmMigrationFactory -Parameters @{ d = $Doc } { param($d) Get-VmfRollbackOriginalDisks -Doc $d }) }
    # The rollback's record of the disks it put on, as the engine writes it.
    $script:rbOs = [ordered]@{ id = $script:osNew; name = 'app-01-os-asitwas-202611080950' }
    $script:rbData = @(
        [ordered]@{ lun = 0; diskId = $script:d0New; diskName = 'app-01-os-d0-asitwas-202611080950' }
        [ordered]@{ lun = 1; diskId = $script:d1New; diskName = 'app-01-os-d1-asitwas-202611080950' })
    function Script:RoRolledBack {
        param([hashtable]$Doc = @{}, [string]$State = 'FAILED_ROLLED_BACK')
        $rb = [pscustomobject]@{ rolledBackUtc = '2026-11-08T10:00:00.0000000Z'; path = 'A'; osDisk = [pscustomobject]$script:rbOs; dataDisks = @($script:rbData | ForEach-Object { [pscustomobject]$_ }); keptDataDisks = @() }
        $fields = @{ rollback = $rb }
        foreach ($k in $Doc.Keys) { $fields[$k] = $Doc[$k] }
        Script:RoSeed -State $State -Doc $fields
    }

    # Azure, as a map of disk id -> what a read of it gives (detached, a
    # machine id it is attached to, or unreadable); a disk not in the map is gone.
    function Script:RoMockAzure {
        param([hashtable]$Disks, [bool]$MachineExists = $true)
        $global:roDisks = @{}
        foreach ($k in $Disks.Keys) { $global:roDisks[$k.ToLowerInvariant()] = $Disks[$k] }
        $global:roDeleted = [System.Collections.Generic.List[object]]::new()
        $global:roDeleteFail = @{}
        $global:roMachine = $MachineExists
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { $null }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory Test-VmfVmExists { $global:roMachine }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment {
            $state = $global:roDisks[$DiskId.ToLowerInvariant()]
            if ($state -eq 'unreadable') { throw "Reading disk '$DiskId' failed with 500: the service is busy" }
            if (-not $state) { return [pscustomobject]@{ Exists = $false; ManagedBy = ''; SourceResourceId = '' } }
            [pscustomobject]@{ Exists = $true; ManagedBy = $(if ($state -eq 'detached') { '' } else { [string]$state }); SourceResourceId = '' }
        }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDiskById {
            if ($global:roDeleteFail[$DiskId.ToLowerInvariant()]) { throw "Deleting disk '$DiskId' failed with 409: OperationNotAllowed" }
            $global:roDeleted.Add([pscustomobject]@{ DiskId = $DiskId; MachineId = $MachineId; Groups = @($ResourceGroupNames) })
            $global:roDisks.Remove($DiskId.ToLowerInvariant())
        }
    }
    function Script:RoDelete { param([string]$Op = 'op-del-1') Remove-VmfRestoreEarlierDisks -RunPath $script:runPath -VmId $script:vmId -Set rollback -By 'operator@example.com' -CorrelationId $Op -Confirm:$false }
}

AfterAll {
    Remove-Variable roDisks, roDeleted, roDeleteFail, roMachine, roKilled, roReal -Scope Global -ErrorAction SilentlyContinue
}

Describe 'ROLLBACK-ORIGINALS-LEFT-1: which disks are the original disks a rollback left (one rule with the page)' {
    It 'Get-VmfRollbackOriginalDisks gives each case of the shared fixture' {
        $fixture = Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' 'rollback-originals.json') -Raw | ConvertFrom-Json
        @($fixture.cases).Count | Should -BeGreaterThan 7
        foreach ($case in $fixture.cases) {
            $got = @(InModuleScope VmMigrationFactory -Parameters @{ d = $case.doc } { param($d) Get-VmfRollbackOriginalDisks -Doc $d })
            $want = @($case.disks)
            $got.Count | Should -Be $want.Count -Because $case.why
            for ($i = 0; $i -lt $want.Count; $i++) {
                $got[$i].diskId | Should -BeExactly $want[$i].diskId -Because $case.why
                $got[$i].name | Should -BeExactly $want[$i].name -Because $case.why
                $got[$i].lun | Should -Be $want[$i].lun -Because $case.why
                $got[$i].detachedUtc | Should -BeExactly $want[$i].detachedUtc -Because $case.why
            }
        }
    }
}

Describe 'ROLLBACK-ORIGINALS-LEFT-1: the rollback records each disk it swapped off' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-ro-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    }
    AfterEach {
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
    }

    It 'after the OS disk swap the OS disk is on record; after the data swaps, each data disk - in the same write as the disk put on, at v41' {
        Script:RoSeed -State 'CONVERTING'
        Script:RoRecord -OsDisk $script:rbOs
        $doc = Script:RoDoc
        $doc.schemaVersion | Should -Be 51
        @($doc.rollbackOriginals).Count | Should -Be 1
        $doc.rollbackOriginals[0].diskId | Should -Be $script:osOld
        $doc.rollbackOriginals[0].diskName | Should -Be 'app-01-os'
        $doc.rollbackOriginals[0].lun | Should -BeNullOrEmpty
        [string]$doc.rollbackOriginals[0].detachedUtc | Should -Not -BeNullOrEmpty
        $doc.rollback.osDisk.id | Should -Be $script:osNew
        Script:RoRecord -OsDisk $script:rbOs -DataDisks $script:rbData -Done
        $doc = Script:RoDoc
        @($doc.rollbackOriginals.diskId) | Should -Be @($script:osOld, $script:d0Old, $script:d1Old)
        @($doc.rollbackOriginals | ForEach-Object { $_.lun }) | Should -Be @($null, 0, 1)
    }

    It 'kill and resume (rule 4): a rollback that runs its swaps again records each disk once, with the time it was first detached' {
        Script:RoSeed -State 'CONVERTING'
        Script:RoRecord -OsDisk $script:rbOs
        $first = [string](Script:RoDoc).rollbackOriginals[0].detachedUtc
        # The worker stopped here; the next one runs the rollback again from the start.
        Start-Sleep -Milliseconds 20
        Script:RoRecord -OsDisk $script:rbOs
        Script:RoRecord -OsDisk $script:rbOs -DataDisks $script:rbData
        Script:RoRecord -OsDisk $script:rbOs -DataDisks $script:rbData -Done
        $doc = Script:RoDoc
        @($doc.rollbackOriginals).Count | Should -Be 3
        [string]$doc.rollbackOriginals[0].detachedUtc | Should -Be $first
    }

    It 'a disk the rollback did not swap (no copy, or the same disk) is not recorded' {
        Script:RoSeed -State 'CONVERTING'
        Script:RoRecord -OsDisk $null
        @((Script:RoDoc).rollbackOriginals).Count | Should -Be 0
        Script:RoRecord -OsDisk ([ordered]@{ id = $script:osOld.ToUpperInvariant(); name = 'app-01-os' })
        @((Script:RoDoc).rollbackOriginals).Count | Should -Be 0 -Because 'resource IDs compare in any letter case'
    }

    It 'Finish the rollback records the original disk of each data disk it swapped back' {
        $sp = [pscustomobject]@{ kept = @(); kind = 'rollback'; leftUtc = '2026-11-08T10:00:00Z'; error = 'e'; usedBy = ''
            swaps = @([pscustomobject]@{ lun = 1; diskId = $script:d1New; diskName = 'app-01-os-d1-asitwas-202611080950'; name = 'app-01-data1' }); swapped = @() }
        $rb = [pscustomobject]@{ rolledBackUtc = '2026-11-08T10:00:00Z'; path = 'A'; osDisk = [pscustomobject]$script:rbOs
            dataDisks = @([pscustomobject]$script:rbData[0]); keptDataDisks = @() }
        Script:RoSeed -State 'FAILED_ROLLED_BACK' -Doc @{ swapPending = $sp; rollback = $rb
            rollbackOriginals = @([pscustomobject]@{ diskId = $script:osOld; diskName = 'app-01-os'; lun = $null; detachedUtc = '2026-11-08T09:58:00Z' }
                [pscustomobject]@{ diskId = $script:d0Old; diskName = 'app-01-data0'; lun = 0; detachedUtc = '2026-11-08T09:59:00Z' }) }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId; row = [pscustomobject]$script:rbData[1] } {
            param($rp, $id, $row) Add-VmfSwapFinished -RunPath $rp -VmId $id -Rows @($row)
        }
        $doc = Script:RoDoc
        @($doc.rollbackOriginals.diskId) | Should -Be @($script:osOld, $script:d0Old, $script:d1Old)
        $doc.rollbackOriginals[2].lun | Should -Be 1
    }

    It 'Try this machine again (-NewAttempt) keeps the record' {
        Script:RoRolledBack -Doc @{ rollbackOriginals = @([pscustomobject]@{ diskId = $script:osOld; diskName = 'app-01-os'; lun = $null; detachedUtc = '2026-11-08T09:58:00Z' }) }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } { param($rp, $id) Clear-VmfRetryState -RunPath $rp -VmId $id -From 'PRECHECK' -NewAttempt }
        @((Script:RoDoc).rollbackOriginals.diskId) | Should -Be @($script:osOld)
        @(Script:RoOriginals).Count | Should -Be 1
    }

    It 'nothing deletes them on its own: the cleanup counts them as disks of the machine, also when a made-disk list names one' {
        # An original of a second rollback is a disk the first one made; its
        # used mark was never written (a put-back that stopped between the two).
        Script:RoRolledBack -Doc @{
            rollbackOriginals = @([pscustomobject]@{ diskId = (& $script:disk 'app-01-os-asitwas-a1'); diskName = 'app-01-os-asitwas-a1'; lun = $null; detachedUtc = '2026-11-08T09:58:00Z' })
            rollbackDisksDuringRollback = @([pscustomobject]@{ diskId = (& $script:disk 'app-01-os-asitwas-a1'); diskName = 'app-01-os-asitwas-a1'; lun = $null; madeUtc = '2026-11-01T09:00:00Z' }) }
        $doc = Script:RoDoc
        @(InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfRecordedMachineDiskIds -StateDoc $d }) | Should -Contain (& $script:disk 'app-01-os-asitwas-a1')
        @(InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfDeletableMadeDisks -StateDoc $d }).Count | Should -Be 0
    }
}

Describe 'ROLLBACK-ORIGINALS-LEFT-1: Delete these disks deletes the original disks (deleteearlier, diskSet rollback)' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-ro-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:rec = @(
            [pscustomobject]@{ diskId = $script:osOld; diskName = 'app-01-os'; lun = $null; detachedUtc = '2026-11-08T09:58:00Z' }
            [pscustomobject]@{ diskId = $script:d0Old; diskName = 'app-01-data0'; lun = 0; detachedUtc = '2026-11-08T09:59:00Z' }
            [pscustomobject]@{ diskId = $script:d1Old; diskName = 'app-01-data1'; lun = 1; detachedUtc = '2026-11-08T09:59:00Z' })
    }
    AfterEach {
        InModuleScope VmMigrationFactory { $script:VmfMachineLeaseToken = $null; $script:VmfOpHeartbeat = $null }
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
    }

    It 'deletes only the original disks, by resource id, records each one so the list empties, and names them on the Activity line' {
        Script:RoRolledBack -Doc @{ rollbackOriginals = $script:rec }
        Script:RoMockAzure @{ $script:osOld = 'detached'; $script:d0Old = 'detached'; $script:d1Old = 'detached'; $script:osNew = $script:vmId; $script:d0New = $script:vmId; $script:d1New = $script:vmId }
        $r = Script:RoDelete
        @($global:roDeleted.DiskId) | Should -Be @($script:osOld, $script:d0Old, $script:d1Old)
        foreach ($d in $global:roDeleted) { $d.MachineId | Should -Be $script:vmId; @($d.Groups) | Should -Contain 'rg-app' }
        @($r.Deleted) | Should -Be @('app-01-os', 'app-01-data0', 'app-01-data1')
        $doc = Script:RoDoc
        $doc.schemaVersion | Should -Be 51
        foreach ($row in @($doc.rollbackOriginals)) {
            [string]$row.deletedUtc | Should -Not -BeNullOrEmpty
            $row.deletedBy | Should -Be 'operator@example.com'
            $row.gone | Should -BeFalse
        }
        @(Script:RoOriginals).Count | Should -Be 0
        $line = @(Script:RoEvents | Where-Object { $_.step -eq 'originalDelete' })[-1]
        $line.outcome | Should -Be 'ok'
        $line.detail | Should -Match "^The product deleted 3 original disks of 'app-01': app-01-os, app-01-data0, app-01-data1\. operator@example\.com asked for it\.$"
    }

    It 'a restore''s earlier disks are not touched by it, and the restore''s delete does not touch the originals' {
        $restore = [pscustomobject]@{ operationId = 'op-r'; restoredUtc = '2026-11-09T09:00:00Z'; diskIdChanged = $true; newDiskId = (& $script:disk 'app-01-os-r'); newDiskName = 'app-01-os-r'
            retainedDiskId = $script:osNew; previousDiskName = 'app-01-os-asitwas-202611080950'; dataDisks = @() }
        Script:RoRolledBack -Doc @{ rollbackOriginals = $script:rec; restore = $restore } -State 'MIGRATED'
        Script:RoMockAzure @{ $script:osOld = 'detached'; $script:d0Old = 'detached'; $script:d1Old = 'detached'; $script:osNew = 'detached' }
        Script:RoDelete | Out-Null
        @($global:roDeleted.DiskId) | Should -Not -Contain $script:osNew
        $global:roDeleted.Clear()
        InModuleScope VmMigrationFactory { $script:VmfMachineLeaseToken = $null; $script:VmfOpHeartbeat = $null }
        Remove-Item $script:runPath -Recurse -Force
        $script:runPath = "$($script:runPath)-2"
        Script:RoRolledBack -Doc @{ rollbackOriginals = $script:rec; restore = $restore } -State 'MIGRATED'
        Remove-VmfRestoreEarlierDisks -RunPath $script:runPath -VmId $script:vmId -By 'operator@example.com' -CorrelationId 'op-x' -Confirm:$false | Out-Null
        @($global:roDeleted.DiskId) | Should -Be @($script:osNew)
    }

    It 'keeps a disk attached to a machine, a disk it cannot read and a disk Azure does not delete, and says which; a gone disk counts as deleted' {
        Script:RoRolledBack -Doc @{ rollbackOriginals = $script:rec }
        $other = "/subscriptions/$script:sub/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/app-02"
        Script:RoMockAzure @{ $script:osOld = $other; $script:d0Old = 'unreadable' }   # data1 is gone
        $r = Script:RoDelete
        $global:roDeleted.Count | Should -Be 0
        @($r.Deleted) | Should -Be @('app-01-data1')
        @($r.Skipped.name) | Should -Be @('app-01-os', 'app-01-data0')
        $r.Skipped[0].why | Should -Match "attached to the machine 'app-02'"
        $r.Skipped[1].why | Should -Match 'could not read it'
        (@((Script:RoDoc).rollbackOriginals) | Where-Object diskId -EQ $script:d1Old).gone | Should -BeTrue
        @(Script:RoOriginals | ForEach-Object diskId) | Should -Be @($script:osOld, $script:d0Old)
        $line = @(Script:RoEvents | Where-Object { $_.step -eq 'originalDelete' })[-1]
        $line.outcome | Should -Be 'warn'
        $line.detail | Should -Match "The product did not delete app-01-os: it is attached to the machine 'app-02'\."
        $line.detail | Should -Match 'The product did not find app-01-data1 in Azure, so it counts as deleted\.'
    }

    It 'is refused, before any Azure call, while the move has not ended, while a refused swap waits, or with no disk to delete' {
        Script:RoRolledBack -Doc @{ rollbackOriginals = $script:rec } -State 'CONVERTING'
        Script:RoMockAzure @{ $script:osOld = 'detached' }
        { Script:RoDelete } | Should -Throw "*The move of 'app-01' has not ended*"
        Remove-Item $script:runPath -Recurse -Force
        $script:runPath = "$($script:runPath)-2"
        Script:RoRolledBack -Doc @{ rollbackOriginals = $script:rec; swapPending = [pscustomobject]@{ kept = @(); kind = 'rollback'; leftUtc = '2026-11-08T10:00:00Z'; error = 'e'; swaps = @(); swapped = @() } }
        { Script:RoDelete } | Should -Throw '*Finish the rollback*'
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment -Times 0 -Exactly
        Remove-Item $script:runPath -Recurse -Force
        $script:runPath = "$($script:runPath)-3"
        Script:RoSeed -State 'MIGRATED'
        $r = Script:RoDelete
        @($r.Deleted).Count | Should -Be 0
        (@(Script:RoEvents | Where-Object { $_.step -eq 'originalDelete' })[-1]).detail | Should -Match "'app-01' has no original disks left to delete\."
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment -Times 0 -Exactly
    }

    It 'deletes nothing of a machine Azure does not show: the original disks can be what rebuilds it' {
        Script:RoRolledBack -Doc @{ rollbackOriginals = $script:rec }
        Script:RoMockAzure @{ $script:osOld = 'detached'; $script:d0Old = 'detached'; $script:d1Old = 'detached' } -MachineExists $false
        $r = Script:RoDelete
        $global:roDeleted.Count | Should -Be 0
        @($r.Skipped).Count | Should -Be 3
        (@(Script:RoEvents | Where-Object { $_.step -eq 'originalDelete' })[-1]).detail | Should -Match 'Azure does not have the machine now\.'
        @(Script:RoOriginals).Count | Should -Be 3
    }

    It 'kill and resume (rule 4): a job stopped after a delete, before its record, deletes only what is left when it runs again' {
        Script:RoRolledBack -Doc @{ rollbackOriginals = $script:rec }
        Script:RoMockAzure @{ $script:osOld = 'detached'; $script:d0Old = 'detached'; $script:d1Old = 'detached' }
        $global:roReal = & (Get-Module VmMigrationFactory) { ${function:Add-VmfRollbackOriginalDeleted} }
        $global:roKilled = $false
        Mock -ModuleName VmMigrationFactory Add-VmfRollbackOriginalDeleted {
            if (-not $global:roKilled) { $global:roKilled = $true; throw 'the container stopped' }
            & $global:roReal -RunPath $RunPath -VmId $VmId -Entry $Entry
        }
        { Script:RoDelete } | Should -Throw '*the container stopped*'
        @($global:roDeleted.DiskId) | Should -Be @($script:osOld)
        @(Script:RoOriginals).Count | Should -Be 3 -Because 'nothing is on record yet'
        InModuleScope VmMigrationFactory { $script:VmfMachineLeaseToken = $null; $script:VmfOpHeartbeat = $null }
        $global:roDeleted.Clear()
        $again = Script:RoDelete -Op 'op-del-2'
        @($global:roDeleted.DiskId) | Should -Be @($script:d0Old, $script:d1Old)
        @($again.Deleted) | Should -Be @('app-01-os', 'app-01-data0', 'app-01-data1')
        (@((Script:RoDoc).rollbackOriginals) | Where-Object diskId -EQ $script:osOld).gone | Should -BeTrue
    }

    It 'the record of a deleted disk is written only for a disk the rule lists, once; a made disk is marked deleted on its list too' {
        $made = [pscustomobject]@{ diskId = $script:osOld; diskName = 'app-01-os'; lun = $null; madeUtc = '2026-11-01T09:00:00Z'; usedUtc = '2026-11-01T09:10:00Z' }
        Script:RoRolledBack -Doc @{ rollbackOriginals = $script:rec; rollbackDisksDuringRollback = @($made) }
        $entry = [ordered]@{ diskId = (& $script:disk 'not-on-the-record'); deletedUtc = '2026-11-08T11:00:00Z'; deletedBy = 'operator@example.com'; gone = $false }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId; e = $entry } { param($rp, $id, $e) Add-VmfRollbackOriginalDeleted -RunPath $rp -VmId $id -Entry $e } | Should -BeFalse
        $entry.diskId = $script:osOld.ToUpperInvariant()
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId; e = $entry } { param($rp, $id, $e) Add-VmfRollbackOriginalDeleted -RunPath $rp -VmId $id -Entry $e } | Should -BeTrue
        $entry.deletedUtc = '2026-11-08T12:00:00Z'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId; e = $entry } { param($rp, $id, $e) Add-VmfRollbackOriginalDeleted -RunPath $rp -VmId $id -Entry $e } | Should -BeTrue
        $doc = Script:RoDoc
        @($doc.rollbackOriginals | Where-Object { $_.deletedUtc }).Count | Should -Be 1
        ([datetime]$doc.rollbackOriginals[0].deletedUtc).ToUniversalTime() | Should -Be ([datetime]::Parse('2026-11-08T11:00:00Z').ToUniversalTime()) -Because 'a second record of one disk changes nothing'
        [string]@($doc.rollbackDisksDuringRollback)[0].deletedUtc | Should -Not -BeNullOrEmpty
    }
}

Describe 'ROLLBACK-ORIGINALS-LEFT-1: the service and the engine start it (rule 12)' {
    BeforeAll {
        $script:op = [pscustomobject]@{ Identity = 'operator@example.com'; Roles = @('Vmf.Operator') }
    }
    BeforeEach {
        [Environment]::SetEnvironmentVariable('VMF_ENGINE_JOB_ID', "/subscriptions/$script:sub/resourceGroups/rg/providers/Microsoft.App/jobs/engine")
        $script:store = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rof-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:store | Out-Null
        [Environment]::SetEnvironmentVariable('VMF_STORE_PATH', $script:store)
        Mock -ModuleName FacadeCore Get-VmfFacadeEngineJob {
            [pscustomobject]@{ properties = [pscustomobject]@{ template = [pscustomobject]@{ containers = @([pscustomobject]@{
                name = 'engine'; image = 'acr/vmf-engine:dev'; resources = [pscustomobject]@{ cpu = 1; memory = '2Gi' }; env = @() }) } } }
        }
        Mock -ModuleName FacadeCore Assert-VmfFacadeNotBeingDeleted { }
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $false }
        $global:roBody = $null
        Mock -ModuleName FacadeCore Invoke-AzRestMethod { $global:roBody = $Payload; [pscustomobject]@{ StatusCode = 202; Content = '{"name":"exec-1"}' } }
    }
    AfterEach {
        [Environment]::SetEnvironmentVariable('VMF_ENGINE_JOB_ID', $null)
        [Environment]::SetEnvironmentVariable('VMF_STORE_PATH', $null)
        Remove-Item $script:store -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Variable roBody -Scope Global -ErrorAction SilentlyContinue
    }

    It 'deleteearlier with diskSet rollback tells the engine which disks; without it, the engine deletes the restore''s earlier disks as before' {
        Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'deleteearlier' -RunId 'run-x' -VmId $script:vmId -DiskSet 'rollback' | Out-Null
        $envs = @(($global:roBody | ConvertFrom-Json).containers[0].env)
        ($envs | Where-Object name -EQ 'VMF_OPERATION').value | Should -Be 'deleteearlier'
        ($envs | Where-Object name -EQ 'VMF_DISK_SET').value | Should -Be 'rollback'
        ($envs | Where-Object name -EQ 'VMF_VM_ID').value | Should -Be $script:vmId
        Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'deleteearlier' -RunId 'run-x' -VmId $script:vmId | Out-Null
        @(($global:roBody | ConvertFrom-Json).containers[0].env | Where-Object name -EQ 'VMF_DISK_SET').Count | Should -Be 0
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'deleteearlier' -RunId 'run-x' -VmId $script:vmId -DiskSet 'everything' } | Should -Throw
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'deletemade' -RunId 'run-x' -VmId $script:vmId -DiskSet 'rollback' } | Should -Throw '400:*'
    }

    It 'refuses the original disks of a machine whose move has not ended, in the engine''s words, before a job starts' {
        Mock -ModuleName VmMigrationFactory Get-VmfMadeDiskDeleteRefusal { "The move of 'app-01' has not ended: it is at the step CONVERTING." }
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'deleteearlier' -RunId 'run-x' -VmId $script:vmId -DiskSet 'rollback' } | Should -Throw "400: The move of 'app-01' has not ended*"
        $global:roBody | Should -BeNullOrEmpty
        Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'deleteearlier' -RunId 'run-x' -VmId $script:vmId | Out-Null
        $global:roBody | Should -Not -BeNullOrEmpty -Because 'a restore''s earlier disks keep their own rule'
    }

    It 'the request body carries diskSet to the service, and the engine passes it on' {
        $route = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'app' 'PostStartEngine' 'run.ps1') -Raw
        $route | Should -Match '\$body\.diskSet\) \{ \$params\.DiskSet = \[string\]\$body\.diskSet \}'
        $text = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'docker' 'entrypoint.ps1')
        $block = [regex]::Match($text, "(?s)'deleteearlier' \{.*?Remove-VmfRestoreEarlierDisks @deleteParams").Value
        $block | Should -Match '\$env:VMF_DISK_SET'
        $block | Should -Match '\$deleteParams\.Set = \$env:VMF_DISK_SET'
    }
}

Describe 'ROLLBACK-ORIGINALS-LEFT-1: the contract (vm-state v41)' {
    It 'the schema, the store and the sample say v41, and the sample holds the record' {
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json') -Raw | ConvertFrom-Json
        $schema.properties.schemaVersion.const | Should -Be 51
        (InModuleScope VmMigrationFactory { $script:VmfStateDocSchemaVersion }) | Should -Be 51
        $item = $schema.properties.rollbackOriginals.items
        @($item.required) | Should -Be @('diskId', 'diskName', 'lun', 'detachedUtc')
        $item.additionalProperties | Should -BeFalse
        $sample = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'vm-state.sample.json') -Raw | ConvertFrom-Json
        $sample.schemaVersion | Should -Be 51
        @($sample.rollbackOriginals).Count | Should -BeGreaterThan 0
    }
    It 'the migration note says what changed and how an older record is read' {
        $notes = Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw
        $notes | Should -Match '## vm-state v40 -> v41 \(2026-11-08, ROLLBACK-ORIGINALS-LEFT-1\)'
        $notes | Should -Match 'rollbackOriginals'
    }
}
