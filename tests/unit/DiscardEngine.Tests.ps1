#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# DISCARD-ENGINE-1 (GitHub issue 427): "Delete this migration" with "Delete the
# copies as well" failed in the service with "The term 'Remove-AzResourceLock'
# is not recognized".
#
# The delete ran IN the service. The service loads Az.Accounts only, and by
# design holds no right to delete anything in a customer's subscription. The
# product already knew the split - the daily cleanup previews in the service
# and starts the ENGINE to delete - and this path did not follow it.
#
# Now: the service checks the request and starts the engine's 'discard'
# operation. The engine deletes every copy first (unlock, delete, confirm it is
# gone) and removes the records only when every copy is gone. A copy that
# cannot be deleted keeps the records, is named in the log, and a second try
# skips the copies already gone.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:sub = '00000000-0000-0000-0000-000000000000'
    function Global:DeSnap([string]$Name) {
        "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/snapshots/$Name"
    }

    # One migration, one machine MIGRATED, three safety copies (one from an
    # earlier attempt - SAFETY-RETRY-1 says those are the run's too).
    function Global:DeRun {
        param([string]$State = 'MIGRATED', [switch]$SecondMachine)
        $store = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-de-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $run = Join-Path $store 'run-x'
        $vm = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $run; vm = $vm; st = $State; s0 = (DeSnap 's0'); s1 = (DeSnap 's1'); s2 = (DeSnap 's2') } {
            Initialize-VmfRun -RunPath $rp -RunId 'run-x' | Out-Null
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 12 -Document ([ordered]@{
                schemaVersion = 8; entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $vm; wave = 'w1'; path = 'A' }) })
            New-VmfStateDoc -RunPath $rp -RunId 'run-x' -VmId $vm -Wave 'w1' | Out-Null
            New-VmfVmClaim -RunPath $rp -VmId $vm -RunId 'run-x' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState $st -Outcome ok | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $vm
            $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{
                pristineSnapshotId = $s1; snapshotId = $s2; cloneVmId = $null
                earlierCopies = @([pscustomobject]@{ pristineSnapshotId = $s0; keptUtc = '2026-09-20T00:00:00Z' }) }) -Force
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        $vm2 = $null
        if ($SecondMachine) {
            # A second machine, MIGRATED, with copies t1 and t2.
            $vm2 = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm2'
            InModuleScope VmMigrationFactory -Parameters @{ rp = $run; vm = $vm; vm2 = $vm2; t1 = (DeSnap 't1'); t2 = (DeSnap 't2') } {
                Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 12 -Document ([ordered]@{
                    schemaVersion = 8; entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $vm; wave = 'w1'; path = 'A' }, [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $vm2; wave = 'w1'; path = 'A' }) })
                New-VmfStateDoc -RunPath $rp -RunId 'run-x' -VmId $vm2 -Wave 'w1' | Out-Null
                Add-VmfStateTransition -RunPath $rp -VmId $vm2 -NewState 'MIGRATED' -Outcome ok | Out-Null
                $doc = Read-VmfStateDoc -RunPath $rp -VmId $vm2
                $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{
                    pristineSnapshotId = $t1; snapshotId = $t2; cloneVmId = $null }) -Force
                Write-VmfStateDoc -RunPath $rp -Document $doc
            }
        }
        @{ Store = $store; Run = $run; Vm = $vm; Vm2 = $vm2 }
    }

    # Azure, as far as these tests need it: which copies exist, which refuse
    # to be deleted, and which Azure accepts a delete for and keeps anyway.
    # Global, because a Mock body runs in a scope of its own.
    function Global:DeAzure {
        param([string[]]$There = @('s0', 's1', 's2'), [string[]]$Refuse = @(), [string[]]$Linger = @(), [string]$RunPath,
              [switch]$LockFails, [scriptblock]$OnRemove)
        $global:DeSim = @{
            There = [System.Collections.Generic.HashSet[string]]::new([string[]]@($There | ForEach-Object { DeSnap $_ }))
            Refuse = @($Refuse | ForEach-Object { DeSnap $_ })
            Linger = @($Linger | ForEach-Object { DeSnap $_ })
            Calls = [System.Collections.Generic.List[string]]::new()
            RunPath = $RunPath
            PlanThereAtDelete = [System.Collections.Generic.List[bool]]::new()
            LockFails = [bool]$LockFails
            OnRemove = $OnRemove
            CopiesLeftAtRecord = [System.Collections.Generic.List[int]]::new()
        }
        Mock -ModuleName VmMigrationFactory Lock-VmfSnapshot {
            $global:DeSim.Calls.Add("lock $(($SnapshotId -split '/')[-1])")
            if ($global:DeSim.LockFails) { throw 'AuthorizationFailed: locks/write' }
            "$SnapshotId/providers/Microsoft.Authorization/locks/vmf-safety-copy"
        }
        # ATTEST-1 / N2: how many copies Azure still had when the 'deleted'
        # record was written - it must be none.
        Mock -ModuleName VmMigrationFactory New-VmfMigrationRecord {
            $global:DeSim.CopiesLeftAtRecord.Add($global:DeSim.There.Count)
        }
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists {
            $global:DeSim.Calls.Add("read $(($SnapshotId -split '/')[-1])")
            $global:DeSim.There.Contains($SnapshotId)
        }
        Mock -ModuleName VmMigrationFactory Unlock-VmfSnapshot {
            $global:DeSim.Calls.Add("unlock $(($SnapshotId -split '/')[-1])")
        }
        Mock -ModuleName VmMigrationFactory Remove-VmfSnapshot {
            $global:DeSim.Calls.Add("remove $(($SnapshotId -split '/')[-1])")
            $global:DeSim.PlanThereAtDelete.Add((Test-Path (Join-Path $global:DeSim.RunPath 'plan.json')))
            if ($SnapshotId -in $global:DeSim.Refuse) {
                throw "Deleting snapshot '$SnapshotId' failed with 403: AuthorizationFailed"
            }
            if ($SnapshotId -notin $global:DeSim.Linger) { [void]$global:DeSim.There.Remove($SnapshotId) }
            if ($global:DeSim.OnRemove) { & $global:DeSim.OnRemove $SnapshotId }
        }
        Mock -ModuleName VmMigrationFactory Start-Sleep { }
        Mock -ModuleName VmMigrationFactory Get-VmfSignedInIdentity { @{ Identity = 'operator@example.com' } }
    }

    function Global:DeEvents([string]$RunPath, [string]$Step) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath; st = $Step } { Read-VmfEvents -RunPath $rp -Step $st }
    }
}
AfterAll {
    Remove-Item 'function:\DeSnap', 'function:\DeRun', 'function:\DeAzure', 'function:\DeEvents' -ErrorAction SilentlyContinue
    Remove-Variable -Name DeSim -Scope Global -ErrorAction SilentlyContinue
}

Describe 'DISCARD-ENGINE-1: the engine deletes every copy, then the records' {
    AfterEach { if ($script:fx -and (Test-Path $script:fx.Store)) { Remove-Item $script:fx.Store -Recurse -Force } }

    It 'unlocks, deletes and confirms each copy is gone, all before a record is removed' {
        $script:fx = DeRun
        DeAzure -RunPath $script:fx.Run
        $r = Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -DeleteSafetyCopies -Confirm:$false
        $r.Removed | Should -BeTrue
        $r.SafetyCopiesDeleted | Should -Be 3
        $calls = $global:DeSim.Calls
        foreach ($s in 's0', 's1', 's2') {
            $unlock = $calls.IndexOf("unlock $s"); $remove = $calls.IndexOf("remove $s")
            $unlock | Should -BeGreaterOrEqual 0 -Because "the lock on $s comes off"
            $unlock | Should -BeLessThan $remove -Because 'a locked copy refuses the delete'
            # The read AFTER the delete is the confirmation.
            $calls.LastIndexOf("read $s") | Should -BeGreaterThan $remove -Because "$s is confirmed gone after the delete"
        }
        @($global:DeSim.PlanThereAtDelete) | Should -Not -Contain $false -Because 'the records stay until every copy is gone'
        Test-Path $script:fx.Run | Should -BeFalse
    }

    It 'ROLLBACK-DISKS-FIRST-1: deleting with the copies also deletes the rollback disks that nothing used, and one not deleted keeps every record' {
        foreach ($refuse in $false, $true) {
            $script:fx = DeRun -State 'FAILED_NEEDS_ATTENTION'
            DeAzure -RunPath $script:fx.Run
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run; vm = $script:fx.Vm } {
                param($rp, $vm)
                $doc = Read-VmfStateDoc -RunPath $rp -VmId $vm
                $disk = { param($n, $used) [pscustomobject]@{ lun = $null; name = 'vm1-os'; diskId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/disks/$n"
                        diskName = $n; madeUtc = '2026-10-11T07:00:00Z'; usedUtc = $used; deletedUtc = $null } }
                $doc.safety | Add-Member -NotePropertyName rollbackDisksBeforeMove -NotePropertyValue ([pscustomobject]@{ stamp = '202610110700'; pristineSnapshotId = $doc.safety.pristineSnapshotId; complete = $true
                        disks = @((& $disk 'vm1-os-asitwas-202610110700' $null), (& $disk 'vm1-os-asitwas-used' '2026-10-11T08:00:00Z')) }) -Force
                Write-VmfStateDoc -RunPath $rp -Document $doc
            }
            $global:DeDisks = [System.Collections.Generic.List[string]]::new()
            $global:DeRefuseDisk = $refuse
            Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment { [pscustomobject]@{ Exists = $true; ManagedBy = '' } }
            Mock -ModuleName VmMigrationFactory Remove-VmfManagedDiskById {
                $global:DeDisks.Add(($DiskId -split '/')[-1])
                if ($global:DeRefuseDisk) { throw 'ScopeLocked: the disk is locked.' }
            }
            try {
                if (-not $refuse) {
                    $r = Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -DeleteSafetyCopies -Confirm:$false
                    $r.Removed | Should -BeTrue
                    @($global:DeDisks) | Should -Be @('vm1-os-asitwas-202610110700') -Because 'a disk a put-back used is the machine''s own'
                }
                else {
                    { Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -DeleteSafetyCopies -Confirm:$false } | Should -Throw '*rollback disks were not deleted*'
                    @(DeEvents $script:fx.Run 'discard' | Where-Object { $_.outcome -eq 'fail' -and [string]$_.detail -like "The product did not delete the rollback disk 'vm1-os-asitwas-202610110700': *" }) | Should -HaveCount 1 -Because 'since 2026-11-12 the product is the actor'
                    Test-Path (Join-Path $script:fx.Run 'plan.json') | Should -BeTrue -Because 'nothing is half removed'
                }
            }
            finally {
                Remove-Variable DeDisks, DeRefuseDisk -Scope Global -ErrorAction SilentlyContinue
                if (Test-Path $script:fx.Store) { Remove-Item $script:fx.Store -Recurse -Force }
            }
        }
    }

    It 'a copy that cannot be deleted keeps the records, is named in the log, and the rest are still tried' {
        $script:fx = DeRun
        DeAzure -RunPath $script:fx.Run -Refuse @('s1')
        { Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -DeleteSafetyCopies -Confirm:$false } |
            Should -Throw '*s1*'
        Test-Path (Join-Path $script:fx.Run 'plan.json') | Should -BeTrue -Because 'nothing is half removed'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run; vm = $script:fx.Vm } {
            (Get-VmfVmClaim -RunPath $rp -VmId $vm) | Should -Not -BeNullOrEmpty -Because 'the machine is still held by this migration'
        }
        $global:DeSim.Calls | Should -Contain 'remove s2' -Because 'one refusal does not stop the other copies'
        $fails = @(DeEvents $script:fx.Run 'discardCopy' | Where-Object outcome -EQ 'fail')
        @($fails | Where-Object { $_.detail -match 's1' }).Count | Should -Be 1 -Because 'the copy that failed is named'
        @($fails | Where-Object { $_.detail -match '403' }).Count | Should -Be 1 -Because 'with what Azure said'
    }

    It 'a copy Azure accepts a delete for and keeps is NOT counted as gone' {
        $script:fx = DeRun
        DeAzure -RunPath $script:fx.Run -Linger @('s2')
        { Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -DeleteSafetyCopies -Confirm:$false } |
            Should -Throw '*s2*'
        Test-Path (Join-Path $script:fx.Run 'plan.json') | Should -BeTrue
        @($global:DeSim.Calls | Where-Object { $_ -eq 'read s2' }).Count | Should -BeGreaterThan 2 -Because 'it asks again before it gives up'
    }

    It 'trying again skips the copies already gone, and finishes' {
        $script:fx = DeRun
        DeAzure -RunPath $script:fx.Run -There @('s1')
        $r = Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -DeleteSafetyCopies -Confirm:$false
        $r.Removed | Should -BeTrue
        $global:DeSim.Calls | Should -Not -Contain 'unlock s0'
        $global:DeSim.Calls | Should -Not -Contain 'remove s0'
        $global:DeSim.Calls | Should -Not -Contain 'remove s2'
        $global:DeSim.Calls | Should -Contain 'remove s1'
        $r.SafetyCopiesDeleted | Should -Be 1
        $r.SafetyCopiesAlreadyGone | Should -Be 2
        Test-Path $script:fx.Run | Should -BeFalse
    }

    It 'keeping the copies touches nothing in Azure' {
        $script:fx = DeRun
        DeAzure -RunPath $script:fx.Run
        (Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -KeepSafetyCopies -Confirm:$false).Removed | Should -BeTrue
        $global:DeSim.Calls.Count | Should -Be 0
    }

    It 'N2: the record of the deleted migration is written only after every copy is gone' {
        $script:fx = DeRun
        DeAzure -RunPath $script:fx.Run
        Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -DeleteSafetyCopies -Confirm:$false | Out-Null
        @($global:DeSim.CopiesLeftAtRecord) | Should -Be @(0)
    }

    It 'N2: and it is not written at all when a copy is not deleted' {
        $script:fx = DeRun
        DeAzure -RunPath $script:fx.Run -Refuse @('s1')
        { Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -DeleteSafetyCopies -Confirm:$false } | Should -Throw
        $global:DeSim.CopiesLeftAtRecord.Count | Should -Be 0
    }

    It 'S5: a refused delete puts the lock back, and the log says so' {
        $script:fx = DeRun
        DeAzure -RunPath $script:fx.Run -Refuse @('s1')
        { Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -DeleteSafetyCopies -Confirm:$false } | Should -Throw
        $calls = $global:DeSim.Calls
        $calls.IndexOf('lock s1') | Should -BeGreaterThan $calls.IndexOf('remove s1') -Because 'the lock goes back after the refusal'
        $calls | Should -Not -Contain 'lock s2' -Because 'a copy that was deleted is not locked again'
        $fail = @(DeEvents $script:fx.Run 'discardCopy' | Where-Object { $_.outcome -eq 'fail' -and $_.detail -match 's1' })
        $fail[0].detail | Should -Match 'The product put the lock back on the copy\.'
    }

    It 'S5: and when the lock cannot go back, the log says that instead' {
        $script:fx = DeRun
        DeAzure -RunPath $script:fx.Run -Refuse @('s1') -LockFails
        { Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -DeleteSafetyCopies -Confirm:$false } | Should -Throw '*s1*'
        $fail = @(DeEvents $script:fx.Run 'discardCopy' | Where-Object { $_.outcome -eq 'fail' -and $_.detail -match 's1' })
        $fail[0].detail | Should -Match 'The copy has no lock\. The product could not put the lock back'
    }

    It 'S2: a retry that takes new copies during the delete stops it, and the records stay' {
        $script:fx = DeRun
        $global:DeNewCopy = @{ Run = $script:fx.Run; Vm = $script:fx.Vm; Snap = (DeSnap 's3-a2') }
        DeAzure -RunPath $script:fx.Run -OnRemove {
            param($id)
            if ($id -notlike '*/s2') { return }
            InModuleScope VmMigrationFactory -Parameters $global:DeNewCopy {
                $doc = Read-VmfStateDoc -RunPath $Run -VmId $Vm
                $doc.safety.pristineSnapshotId = $Snap
                Write-VmfStateDoc -RunPath $Run -Document $doc
            }
        }
        { Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -DeleteSafetyCopies -Confirm:$false } |
            Should -Throw '*s3-a2*'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run; vm = $script:fx.Vm } {
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $vm
            ($doc.PSObject.Properties['retention'] -and $doc.retention -and $doc.retention.deletedUtc) | Should -BeFalse `
                -Because 'its document names a new copy, so it is not recorded as having none'
        }
        Test-Path (Join-Path $script:fx.Run 'plan.json') | Should -BeTrue
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run; vm = $script:fx.Vm } {
            (Get-VmfVmClaim -RunPath $rp -VmId $vm) | Should -Not -BeNullOrEmpty
        }
        @(DeEvents $script:fx.Run 'discard' | Where-Object { $_.outcome -eq 'fail' -and $_.detail -match 'changed' }).Count | Should -Be 1
        Remove-Variable -Name DeNewCopy -Scope Global -ErrorAction SilentlyContinue
    }

    It 'S2: a machine that started to move during the delete stops it, and the records stay' {
        $script:fx = DeRun
        $global:DeNewCopy = @{ Run = $script:fx.Run; Vm = $script:fx.Vm }
        DeAzure -RunPath $script:fx.Run -OnRemove {
            param($id)
            if ($id -notlike '*/s2') { return }
            InModuleScope VmMigrationFactory -Parameters $global:DeNewCopy {
                Add-VmfStateTransition -RunPath $Run -VmId $Vm -NewState 'CONVERTING' -Outcome ok | Out-Null
            }
        }
        { Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -DeleteSafetyCopies -Confirm:$false } |
            Should -Throw '*knows how to roll it back*'
        Test-Path (Join-Path $script:fx.Run 'plan.json') | Should -BeTrue
        @(DeEvents $script:fx.Run 'discard' | Where-Object { $_.outcome -eq 'fail' -and $_.detail -match 'changed' }).Count | Should -Be 1
        Remove-Variable -Name DeNewCopy -Scope Global -ErrorAction SilentlyContinue
    }

    It 'review 2 item 1: a copy that is not deleted writes its own line, which does not end the delete' {
        $script:fx = DeRun
        DeAzure -RunPath $script:fx.Run -Refuse @('s1')
        { Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -DeleteSafetyCopies -Confirm:$false } | Should -Throw
        @(DeEvents $script:fx.Run 'discard' | Where-Object { $_.outcome -eq 'fail' }).Count | Should -Be 0 `
            -Because "a 'discard' failure ends the delete on every screen; only the engine's own end may write one"
        @(DeEvents $script:fx.Run 'discardCopy' | Where-Object { $_.outcome -eq 'fail' }).Count | Should -Be 1
    }

    It 'review 2 note c: a line goes in before each unlock, so a kill between unlock and delete is visible' {
        $script:fx = DeRun
        # A refused delete keeps the run, so its log can be read afterwards.
        DeAzure -RunPath $script:fx.Run -There @('s1') -Refuse @('s1')
        Mock -ModuleName VmMigrationFactory Unlock-VmfSnapshot {
            $global:DeSim.Calls.Add('unlock s1')
            $global:DeSim.LinesAtUnlock = @(Get-Content (Join-Path $global:DeSim.RunPath 'logs' 'events.jsonl') | Where-Object { $_ -match '"step":"discardCopy"' }).Count
        }
        { Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -DeleteSafetyCopies -Confirm:$false } | Should -Throw
        $global:DeSim.LinesAtUnlock | Should -Be 1 -Because 'the line is written BEFORE the lock comes off'
        $lines = @(DeEvents $script:fx.Run 'discardCopy')
        $lines[0].outcome | Should -Be 'info'
        $lines[0].detail | Should -Match 's1'
        $lines[0].detail | Should -Match 'lock'
    }

    It 'review 2 item 2: a reservation made during the delete stops it before the record, the claims and the deletions line' {
        $script:fx = DeRun
        $global:DeNewCopy = @{ Run = $script:fx.Run }
        DeAzure -RunPath $script:fx.Run -OnRemove {
            param($id)
            if ($id -notlike '*/s2') { return }
            InModuleScope VmMigrationFactory -Parameters $global:DeNewCopy {
                Write-VmfStoreJson -RunPath $Run -RelPath 'capacity/w1-d2ds.json' -Depth 12 -Document ([ordered]@{
                    schemaVersion = 8; wave = 'w1'; region = 'centralus'; size = 'Standard_D2ds_v6'; count = 1; state = 'RESERVED' })
            }
        }
        { Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -DeleteSafetyCopies -Confirm:$false } |
            Should -Throw '400: Wave w1 has an on-demand capacity reservation in Azure (RESERVED)*'
        Test-Path (Join-Path $script:fx.Run 'plan.json') | Should -BeTrue
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run; vm = $script:fx.Vm } {
            (Get-VmfVmClaim -RunPath $rp -VmId $vm) | Should -Not -BeNullOrEmpty
            $scope = Get-VmfClaimScopePath -RunPath $rp
            @(Read-VmfStoreLines -RunPath $scope -RelPath 'deletions.jsonl').Count | Should -Be 0
        }
        $global:DeSim.CopiesLeftAtRecord.Count | Should -Be 0
        @(DeEvents $script:fx.Run 'discard' | Where-Object { $_.outcome -eq 'fail' -and $_.detail -match 'reservation' }).Count | Should -Be 1
        Remove-Variable -Name DeNewCopy -Scope Global -ErrorAction SilentlyContinue
    }

    It 'review 2 item 4: a machine whose copies are all gone is recorded as deleted; one with a copy left is not' {
        $script:fx = DeRun -SecondMachine
        DeAzure -RunPath $script:fx.Run -There @('s0', 's1', 's2', 't1', 't2') -Refuse @('s1')
        { Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -DeleteSafetyCopies -Confirm:$false } | Should -Throw '*s1*'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run; vm = $script:fx.Vm; vm2 = $script:fx.Vm2 } {
            $gone = Read-VmfStateDoc -RunPath $rp -VmId $vm2
            $gone.retention.deletedUtc | Should -Not -BeNullOrEmpty
            $gone.retention.deletedBy | Should -Be 'operator@example.com'
            @($gone.retention.deletedSnapshotIds).Count | Should -Be 2
            $gone.retention.keepDays | Should -BeNullOrEmpty -Because 'no retention period deleted them'
            $kept = Read-VmfStateDoc -RunPath $rp -VmId $vm
            ($kept.PSObject.Properties['retention'] -and $kept.retention -and $kept.retention.deletedUtc) | Should -BeFalse `
                -Because 'its copy s1 still exists, and a second try must still delete it'
        }
        # And a restore of the machine whose copies are gone says so, in words
        # that do not blame a retention period.
        Mock -ModuleName VmMigrationFactory Get-VmfSignedInIdentity { @{ Identity = 'operator@example.com' } }
        $said = $null
        try { Restore-VmfVm -RunPath $script:fx.Run -VmId $script:fx.Vm2 -RestoredBy 'operator@example.com' -Note 'n' -Confirm:$false } catch { $said = $_.Exception.Message }
        $said | Should -BeLike '*were deleted*when the migration was deleted*nothing left to restore from*'
        $said | Should -Not -BeLike '*days its wave was set*'
    }

    It 'review 2 item 4: a second try skips the recorded machine and finishes' {
        $script:fx = DeRun -SecondMachine
        DeAzure -RunPath $script:fx.Run -There @('s0', 's1', 's2', 't1', 't2') -Refuse @('s1')
        { Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -DeleteSafetyCopies -Confirm:$false } | Should -Throw
        $global:DeSim.Refuse = @()
        $r = Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -DeleteSafetyCopies -Confirm:$false
        $r.Removed | Should -BeTrue
        Test-Path $script:fx.Run | Should -BeFalse
    }
    It 'hard rule 4: killed after the machines are released and before the records go, a second run finishes' {
        $script:fx = DeRun
        DeAzure -RunPath $script:fx.Run
        $global:DeKill = @{ Done = $false }
        Mock -ModuleName VmMigrationFactory Remove-VmfStorePrefix {
            if (-not $global:DeKill.Done) { $global:DeKill.Done = $true; throw 'the container was stopped' }
            Remove-Item -LiteralPath $RunPath -Recurse -Force; 1
        }
        { Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -DeleteSafetyCopies -Confirm:$false } |
            Should -Throw '*stopped*'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run; vm = $script:fx.Vm } {
            (Get-VmfVmClaim -RunPath $rp -VmId $vm) | Should -BeNullOrEmpty -Because 'the kill came after the machines were released'
        }
        $removesBefore = @($global:DeSim.Calls | Where-Object { $_ -like 'remove *' }).Count
        $r = Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -DeleteSafetyCopies -Confirm:$false
        $r.Removed | Should -BeTrue
        # The first run recorded the machine's copies as gone (review 2 item 4),
        # so the second asks nothing of Azure and deletes nothing twice.
        @($global:DeSim.Calls | Where-Object { $_ -like 'remove *' }).Count | Should -Be $removesBefore
        Test-Path $script:fx.Run | Should -BeFalse
        Remove-Variable -Name DeKill -Scope Global -ErrorAction SilentlyContinue
    }

    It 'STEP-LOG-4: the line for a rollback disk that was not deleted cannot be written - the delete stops in its own words' {
        $script:fx = DeRun -State 'FAILED_NEEDS_ATTENTION'
        DeAzure -RunPath $script:fx.Run
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run; vm = $script:fx.Vm } {
            param($rp, $vm)
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $vm
            $disk = { param($n) [pscustomobject]@{ lun = $null; name = 'vm1-os'; diskId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/disks/$n"
                    diskName = $n; madeUtc = '2026-10-11T07:00:00Z'; usedUtc = $null; deletedUtc = $null } }
            $doc.safety | Add-Member -NotePropertyName rollbackDisksBeforeMove -NotePropertyValue ([pscustomobject]@{ stamp = '202610110700'; pristineSnapshotId = $doc.safety.pristineSnapshotId; complete = $true
                    disks = @((& $disk 'vm1-os-asitwas-202610110700')) }) -Force
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment { [pscustomobject]@{ Exists = $true; ManagedBy = '' } }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDiskById { throw 'ScopeLocked: the disk is locked.' }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'discard' -and $Outcome -eq 'fail' } { throw 'The store did not answer.' }
        { Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -DeleteSafetyCopies -Confirm:$false -WarningAction SilentlyContinue } |
            Should -Throw '1 of 1 rollback disks were not deleted*'
        Test-Path (Join-Path $script:fx.Run 'plan.json') | Should -BeTrue
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'discard' -and $Outcome -eq 'fail' } -Times 1 -Exactly
    }

    It 'STEP-LOG-4: the line for a reservation made during the delete cannot be written - the refusal is the reservation''s, not the store''s error' {
        $script:fx = DeRun
        $global:DeNewCopy = @{ Run = $script:fx.Run }
        DeAzure -RunPath $script:fx.Run -OnRemove {
            param($id)
            if ($id -notlike '*/s2') { return }
            InModuleScope VmMigrationFactory -Parameters $global:DeNewCopy {
                Write-VmfStoreJson -RunPath $Run -RelPath 'capacity/w1-d2ds.json' -Depth 12 -Document ([ordered]@{
                    schemaVersion = 8; wave = 'w1'; region = 'centralus'; size = 'Standard_D2ds_v6'; count = 1; state = 'RESERVED' })
            }
        }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'discard' -and $Outcome -eq 'fail' } { throw 'The store did not answer.' }
        { Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -DeleteSafetyCopies -Confirm:$false -WarningAction SilentlyContinue } |
            Should -Throw '400: Wave w1 has an on-demand capacity reservation in Azure (RESERVED)*'
        Test-Path (Join-Path $script:fx.Run 'plan.json') | Should -BeTrue
        Remove-Variable -Name DeNewCopy -Scope Global -ErrorAction SilentlyContinue
    }

    It 'STEP-LOG-4: the line for a migration that changed during the delete cannot be written - the refusal says what changed' {
        $script:fx = DeRun
        $global:DeNewCopy = @{ Run = $script:fx.Run; Vm = $script:fx.Vm }
        DeAzure -RunPath $script:fx.Run -OnRemove {
            param($id)
            if ($id -notlike '*/s2') { return }
            InModuleScope VmMigrationFactory -Parameters $global:DeNewCopy {
                Add-VmfStateTransition -RunPath $Run -VmId $Vm -NewState 'CONVERTING' -Outcome ok | Out-Null
            }
        }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'discard' -and $Outcome -eq 'fail' } { throw 'The store did not answer.' }
        { Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -DeleteSafetyCopies -Confirm:$false -WarningAction SilentlyContinue } |
            Should -Throw 'The migration changed while its safety copies were deleted*knows how to roll it back*'
        Test-Path (Join-Path $script:fx.Run 'plan.json') | Should -BeTrue
        Remove-Variable -Name DeNewCopy -Scope Global -ErrorAction SilentlyContinue
    }
}

Describe 'DISCARD-ENGINE-1: the service checks the request and starts the engine' {
    BeforeAll {
        $claims = @(@{ typ = 'preferred_username'; val = 'operator@example.com' }, @{ typ = 'roles'; val = 'Vmf.Operator' })
        $doc = @{ auth_typ = 'aad'; claims = $claims } | ConvertTo-Json -Depth 5
        $script:operator = ConvertFrom-VmfClientPrincipal -Header ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($doc)))
    }
    BeforeEach {
        $global:DeStarts = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName FacadeCore Invoke-VmfFacadeStartEngine {
            $global:DeStarts.Add([pscustomobject]@{ Operation = $Operation; RunId = $RunId; Project = $Project; Note = $Note; Who = $Principal.Identity })
            [pscustomobject]@{ operation = $Operation; runId = $RunId; execution = 'vmf-engine-abc'; executions = @('vmf-engine-abc') }
        }
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $false }
        # The service must never reach these: they need rights it does not hold.
        Mock -ModuleName VmMigrationFactory Unlock-VmfSnapshot { throw 'the service must not unlock a copy' }
        Mock -ModuleName VmMigrationFactory Remove-VmfSnapshot { throw 'the service must not delete a copy' }
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { throw 'the service must not read a copy' }
    }
    AfterEach {
        if ($script:fx -and (Test-Path $script:fx.Store)) { Remove-Item $script:fx.Store -Recurse -Force }
        Remove-Variable -Name DeStarts -Scope Global -ErrorAction SilentlyContinue
    }

    It 'with copies to delete: starts the discard operation, and removes nothing itself' {
        $script:fx = DeRun
        $r = Invoke-VmfFacadeDiscardRun -Principal $script:operator -StorePath $script:fx.Run -RunId 'run-x' -Project 'proj-1' `
            -Note 'first attempt abandoned' -DeleteSafetyCopies
        $global:DeStarts.Count | Should -Be 1
        $global:DeStarts[0].Operation | Should -Be 'discard'
        $global:DeStarts[0].RunId | Should -Be 'run-x'
        $global:DeStarts[0].Project | Should -Be 'proj-1'
        $global:DeStarts[0].Note | Should -Be 'first attempt abandoned'
        $r.queued | Should -BeTrue
        $r.execution | Should -Be 'vmf-engine-abc'
        $r.safetyCopies | Should -Be 3
        Test-Path (Join-Path $script:fx.Run 'plan.json') | Should -BeTrue -Because 'the engine removes the records, after the copies'
        $start = @(DeEvents $script:fx.Run 'discard' | Where-Object outcome -EQ 'start')
        $start.Count | Should -Be 1 -Because 'the page shows the delete from this line'
        $start[0].detail | Should -Match 'operator@example\.com'
        $start[0].detail | Should -Match 'first attempt abandoned'
    }

    It 'STEP-LOG-6: a start that did not work is reported with its own error when the line that ends the delete cannot be written' {
        $script:fx = DeRun
        Mock -ModuleName FacadeCore Invoke-VmfFacadeStartEngine { throw '400: the engine job is being updated' }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'discard' -and $Outcome -eq 'fail' } { throw 'The store did not answer.' }
        { Invoke-VmfFacadeDiscardRun -Principal $script:operator -StorePath $script:fx.Run -RunId 'run-x' -Note 'n' -DeleteSafetyCopies -WarningAction SilentlyContinue } |
            Should -Throw '400: the engine job is being updated'
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'discard' -and $Outcome -eq 'fail' } -Times 1 -Exactly
        Test-Path (Join-Path $script:fx.Run 'plan.json') | Should -BeTrue -Because 'nothing was deleted'
    }

    It 'STEP-LOG-6: the start line of a delete stays a throwing write - nothing is started when it cannot be written' {
        $script:fx = DeRun
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'discard' -and $Outcome -eq 'start' } { throw 'The store did not answer.' }
        { Invoke-VmfFacadeDiscardRun -Principal $script:operator -StorePath $script:fx.Run -RunId 'run-x' -Note 'n' -DeleteSafetyCopies } |
            Should -Throw '*The store did not answer.*'
        $global:DeStarts.Count | Should -Be 0 -Because 'the page shows the delete from that line, so no delete starts without it'
    }

    It 'STEP-LOG-6: the "discarded by" line stays a throwing write - nothing is removed when it cannot be written' {
        $script:fx = DeRun
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'run' -and $Outcome -eq 'ok' } { throw 'The store did not answer.' }
        { Invoke-VmfFacadeDiscardRun -Principal $script:operator -StorePath $script:fx.Run -RunId 'run-x' -Note 'n' } |
            Should -Throw '*The store did not answer.*'
        Test-Path (Join-Path $script:fx.Run 'plan.json') | Should -BeTrue -Because 'the line is written before a record is removed, so a lost line removes nothing'
    }

    It 'refuses a second delete while one is running, and starts nothing' {
        $script:fx = DeRun
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $Operation -eq 'discard' -and $RunId -eq 'run-x' }
        { Invoke-VmfFacadeDiscardRun -Principal $script:operator -StorePath $script:fx.Run -RunId 'run-x' -Note 'n' -DeleteSafetyCopies } |
            Should -Throw '400: *already being deleted*'
        $global:DeStarts.Count | Should -Be 0
    }

    It 'still refuses before it starts anything: <Case>' -ForEach @(
        @{ Case = 'a machine part-way through a move'; State = 'CONVERTING'; Expect = '400: This migration works on machines now*' }) {
        $script:fx = DeRun -State $State
        { Invoke-VmfFacadeDiscardRun -Principal $script:operator -StorePath $script:fx.Run -RunId 'run-x' -Note 'n' -DeleteSafetyCopies } |
            Should -Throw $Expect
        $global:DeStarts.Count | Should -Be 0
    }

    # UNWAVED-MACHINES-UNDERWAY-1 (final lab, 2026-11-16): a migration whose
    # every wave had finished, with planned machines in no wave, refused Delete
    # with "This migration works on machines now: under way: ..." and pointed
    # to Stop this migration, which the page does not show. Nothing ran.
    Context 'UNWAVED-MACHINES-UNDERWAY-1: planned machines in no wave' {
        BeforeAll {
            # Adds machines to the plan of a DeRun migration, in no wave and
            # with no state document: one under 'unscheduled', one with none.
            function Global:DeAddUnwaved([string]$RunPath) {
                InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath } {
                    $plan = Read-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 12
                    $more = @(
                        [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm8'; wave = 'unscheduled'; path = 'A' }
                        [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm9'; wave = $null; path = 'A' })
                    Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 12 -Document ([ordered]@{
                        schemaVersion = 8; entries = @(@($plan.entries) + $more) })
                }
            }
        }
        AfterAll { Remove-Item 'function:\DeAddUnwaved' -ErrorAction SilentlyContinue }

        It 'every wave finished: Delete goes ahead and keeps the copies, at once' {
            $script:fx = DeRun
            DeAddUnwaved $script:fx.Run
            $r = Invoke-VmfFacadeDiscardRun -Principal $script:operator -StorePath $script:fx.Run -RunId 'run-x' -Note 'n'
            $r.Removed | Should -BeTrue
            Test-Path $script:fx.Run | Should -BeFalse
        }

        It 'every wave finished: Delete the copies as well starts the discard operation' {
            $script:fx = DeRun
            DeAddUnwaved $script:fx.Run
            $r = Invoke-VmfFacadeDiscardRun -Principal $script:operator -StorePath $script:fx.Run -RunId 'run-x' -Note 'n' -DeleteSafetyCopies
            $global:DeStarts.Count | Should -Be 1
            $global:DeStarts[0].Operation | Should -Be 'discard'
            $r.safetyCopies | Should -Be 3 -Because 'the machines in no wave never ran, so they have no copies'
        }

        It 'still refuses while a machine in a wave is part-way through a move' {
            $script:fx = DeRun -State 'CONVERTING'
            DeAddUnwaved $script:fx.Run
            { Invoke-VmfFacadeDiscardRun -Principal $script:operator -StorePath $script:fx.Run -RunId 'run-x' -Note 'n' -DeleteSafetyCopies } |
                Should -Throw '400: This migration works on machines now*'
            $global:DeStarts.Count | Should -Be 0
            Test-Path (Join-Path $script:fx.Run 'plan.json') | Should -BeTrue
        }

        It 'still refuses while a wave runs for this migration' {
            # A machine waiting for a slot has no state document: only Azure
            # knows the wave runs.
            $script:fx = DeRun
            DeAddUnwaved $script:fx.Run
            Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { (@($Operation) -contains 'wave') -and $RunId -eq 'run-x' }
            { Invoke-VmfFacadeDiscardRun -Principal $script:operator -StorePath $script:fx.Run -RunId 'run-x' -Note 'n' } |
                Should -Throw '400: The engine works on this migration now. Delete it when that job ends.'
            $global:DeStarts.Count | Should -Be 0
            Test-Path (Join-Path $script:fx.Run 'plan.json') | Should -BeTrue
        }
    }

    It 'still refuses a reservation that bills before it starts anything' {
        $script:fx = DeRun
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run } {
            Write-VmfStoreJson -RunPath $rp -RelPath 'capacity/w1-d2ds.json' -Depth 12 -Document ([ordered]@{
                schemaVersion = 8; wave = 'w1'; region = 'centralus'; size = 'Standard_D2ds_v6'; count = 1; state = 'RESERVED' })
        }
        { Invoke-VmfFacadeDiscardRun -Principal $script:operator -StorePath $script:fx.Run -RunId 'run-x' -Note 'n' -DeleteSafetyCopies } |
            Should -Throw '400: Wave w1 has an on-demand capacity reservation in Azure (RESERVED)*'
        $global:DeStarts.Count | Should -Be 0
        @(DeEvents $script:fx.Run 'discard').Count | Should -Be 0 -Because 'no line says a delete started that did not'
    }

    It 'keeping the copies is still done here, at once, with no engine' {
        $script:fx = DeRun
        $r = Invoke-VmfFacadeDiscardRun -Principal $script:operator -StorePath $script:fx.Run -RunId 'run-x' -Note 'n'
        $global:DeStarts.Count | Should -Be 0
        $r.Removed | Should -BeTrue
        $r.SafetyCopiesKept | Should -Be 3
        Test-Path $script:fx.Run | Should -BeFalse
    }

    It 'ROLLBACK-DISKS-FIRST-1 review: no copy left but a rollback disk that nothing used: starts the engine, which can delete it' {
        $script:fx = DeRun
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run; vm = $script:fx.Vm } {
            param($rp, $vm)
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $vm
            $disk = [pscustomobject]@{ lun = $null; name = 'vm1-os'; diskId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/disks/vm1-os-asitwas-202610110700'
                diskName = 'vm1-os-asitwas-202610110700'; madeUtc = '2026-10-11T07:00:00Z'; usedUtc = $null; deletedUtc = $null }
            $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{ rollbackDisksBeforeMove = [pscustomobject]@{
                        stamp = '202610110700'; pristineSnapshotId = '/s/p'; complete = $true; disks = @($disk) } }) -Force
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        $r = Invoke-VmfFacadeDiscardRun -Principal $script:operator -StorePath $script:fx.Run -RunId 'run-x' -Note 'n' -DeleteSafetyCopies
        $global:DeStarts.Count | Should -Be 1 -Because 'the service holds no right to delete a disk, and the run must not be refused or kept for it'
        $global:DeStarts[0].Operation | Should -Be 'discard'
        $r.safetyCopies | Should -Be 0
        $r.rollbackDisksBeforeMove | Should -Be 1
        Test-Path (Join-Path $script:fx.Run 'plan.json') | Should -BeTrue -Because 'the engine removes the records, after the disk'
        @(DeEvents $script:fx.Run 'discard' | Where-Object outcome -EQ 'start')[0].detail | Should -Match '1 rollback disks'
    }

    It 'asked to delete copies when there are none: done here, with no engine' {
        $script:fx = DeRun
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run; vm = $script:fx.Vm } {
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $vm
            $doc.PSObject.Properties.Remove('safety')
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        $r = Invoke-VmfFacadeDiscardRun -Principal $script:operator -StorePath $script:fx.Run -RunId 'run-x' -Note 'n' -DeleteSafetyCopies
        $global:DeStarts.Count | Should -Be 0
        $r.Removed | Should -BeTrue
        Test-Path $script:fx.Run | Should -BeFalse
    }

    It 'review 2 item 3: refuses a delete while a <Busy> job runs for this migration (<Copies>)' -ForEach @(
        # REBUILD-REMOVE-RECOVER-1: no engine operation rebuild is started any more.
        @{ Busy = 'wave'; Copies = 'delete' }, @{ Busy = 'restore'; Copies = 'delete' }
        @{ Busy = 'wave'; Copies = 'keep' }, @{ Busy = 'restore'; Copies = 'keep' }
        # RESTORE-EARLIER-DELETE-1: Delete these disks writes restore.earlierDisksDeleted into the record.
        @{ Busy = 'deleteearlier'; Copies = 'delete' }, @{ Busy = 'deleteearlier'; Copies = 'keep' }
        # MADE-DISK-DELETE-1: Delete these disks now marks each disk it deletes in the record.
        @{ Busy = 'deletemade'; Copies = 'delete' }, @{ Busy = 'deletemade'; Copies = 'keep' }) {
        $script:fx = DeRun
        $global:DeBusy = $Busy
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { (@($Operation) -contains $global:DeBusy) -and $RunId -eq 'run-x' }
        { Invoke-VmfFacadeDiscardRun -Principal $script:operator -StorePath $script:fx.Run -RunId 'run-x' -Note 'n' -DeleteSafetyCopies:($Copies -eq 'delete') } |
            Should -Throw '400: The engine works on this migration now*'
        # MANUAL-REVIEW-1: one sentence for every job, so it lists none of them.
        { Invoke-VmfFacadeDiscardRun -Principal $script:operator -StorePath $script:fx.Run -RunId 'run-x' -Note 'n' -DeleteSafetyCopies:($Copies -eq 'delete') } |
            Should -Throw '400: The engine works on this migration now. Delete it when that job ends.'
        $global:DeStarts.Count | Should -Be 0
        Test-Path (Join-Path $script:fx.Run 'plan.json') | Should -BeTrue
        Remove-Variable -Name DeBusy -Scope Global -ErrorAction SilentlyContinue
    }
    It 'S3: an engine that does not start ends the delete in the log, so nothing says deleting for an hour' {
        $script:fx = DeRun
        Mock -ModuleName FacadeCore Invoke-VmfFacadeStartEngine { throw 'Engine start failed: HTTP 409 conflict' }
        { Invoke-VmfFacadeDiscardRun -Principal $script:operator -StorePath $script:fx.Run -RunId 'run-x' -Note 'n' -DeleteSafetyCopies } |
            Should -Throw '*409*'
        $events = @(DeEvents $script:fx.Run 'discard')
        $events[-1].outcome | Should -Be 'fail' -Because 'the last discard line ends the one that started'
        $events[-1].detail | Should -Match '409'
        Test-Path (Join-Path $script:fx.Run 'plan.json') | Should -BeTrue
    }
}

Describe 'DISCARD-ENGINE-1: the engine is started only through the delete' {
    BeforeAll {
        $script:op = [pscustomobject]@{ Identity = 'operator@example.com'; Roles = @('Vmf.Operator') }
    }
    BeforeEach {
        Mock -ModuleName FacadeCore Get-VmfFacadeEngineJob {
            [pscustomobject]@{ properties = [pscustomobject]@{ template = [pscustomobject]@{ containers = @([pscustomobject]@{
                name = 'engine'; image = 'acr/vmf-engine:dev'; resources = [pscustomobject]@{ cpu = 1; memory = '2Gi' }; env = @() }) } } }
        }
        $global:DeBody = $null
        Mock -ModuleName FacadeCore Invoke-AzRestMethod {
            $global:DeBody = $Payload
            [pscustomobject]@{ StatusCode = 202; Content = (@{ name = 'vmf-engine-d1' } | ConvertTo-Json) }
        }
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $false }
        [Environment]::SetEnvironmentVariable('VMF_ENGINE_JOB_ID', '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.App/jobs/engine')
    }
    AfterEach {
        if ($script:fx -and (Test-Path $script:fx.Store)) { Remove-Item $script:fx.Store -Recurse -Force }
        [Environment]::SetEnvironmentVariable('VMF_ENGINE_JOB_ID', $null)
        [Environment]::SetEnvironmentVariable('VMF_STORE_PATH', $null)
        Remove-Variable -Name DeBody -Scope Global -ErrorAction SilentlyContinue
    }

    It 'S1: the generic engine route refuses discard, and starts nothing' {
        # POST runs/{id}/engine/{operation} calls exactly this.
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'discard' -RunId 'run-x' -Note 'n' } |
            Should -Throw '400: *Delete this migration*'
        $global:DeBody | Should -BeNullOrEmpty
    }

    It 'through the delete, it carries the operation, who asked, why and the project' {
        $script:fx = DeRun
        [Environment]::SetEnvironmentVariable('VMF_STORE_PATH', $script:fx.Store)
        $claims = @(@{ typ = 'preferred_username'; val = 'operator@example.com' }, @{ typ = 'roles'; val = 'Vmf.Operator' })
        $principal = ConvertFrom-VmfClientPrincipal -Header ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((@{ auth_typ = 'aad'; claims = $claims } | ConvertTo-Json -Depth 5))))
        Invoke-VmfFacadeDiscardRun -Principal $principal -StorePath $script:fx.Run -RunId 'run-x' -Note 'tidy' -DeleteSafetyCopies | Out-Null
        $envs = @(($global:DeBody | ConvertFrom-Json -Depth 10).containers[0].env)
        ($envs | Where-Object name -EQ 'VMF_OPERATION').value | Should -Be 'discard'
        ($envs | Where-Object name -EQ 'VMF_RUN_ID').value | Should -Be 'run-x'
        ($envs | Where-Object name -EQ 'VMF_RESTORED_BY').value | Should -Be 'operator@example.com'
        ($envs | Where-Object name -EQ 'VMF_NOTE').value | Should -Be 'tidy'
    }

    It 'a discard start with no note is refused even from the delete, and an approver is refused' {
        InModuleScope FacadeCore -Parameters @{ op = $script:op } {
            $script:VmfDiscardDispatch = $true
            try { { Invoke-VmfFacadeStartEngine -Principal $op -Operation 'discard' -RunId 'run-x' } | Should -Throw '400: *note*' }
            finally { $script:VmfDiscardDispatch = $false }
        }
        $approver = [pscustomobject]@{ Identity = 'approver@example.com'; Roles = @('Vmf.Approver') }
        { Invoke-VmfFacadeStartEngine -Principal $approver -Operation 'discard' -RunId 'run-x' -Note 'n' } | Should -Throw '*403*'
    }
}

Describe 'DISCARD-ENGINE-1 S2: nothing else starts on a migration the engine is deleting' {
    BeforeAll {
        $script:op = [pscustomobject]@{ Identity = 'operator@example.com'; Roles = @('Vmf.Operator') }
    }
    BeforeEach {
        $script:fx = DeRun
        [Environment]::SetEnvironmentVariable('VMF_STORE_PATH', $script:fx.Store)
        [Environment]::SetEnvironmentVariable('VMF_ENGINE_JOB_ID', '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.App/jobs/engine')
        # The check comes after the job is read and before anything starts.
        Mock -ModuleName FacadeCore Get-VmfFacadeEngineJob {
            [pscustomobject]@{ properties = [pscustomobject]@{ template = [pscustomobject]@{ containers = @([pscustomobject]@{
                name = 'engine'; image = 'acr/vmf-engine:dev'; resources = [pscustomobject]@{ cpu = 1; memory = '2Gi' }; env = @() }) } } }
        }
        Mock -ModuleName FacadeCore Get-VmfFacadeWaveContainers { throw 'reached the engine start' }
        Mock -ModuleName FacadeCore Invoke-AzRestMethod { throw 'reached the engine start' }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run } {
            Write-VmfEvent -RunPath $rp -Step 'discard' -Outcome start -Detail 'operator@example.com started to delete this migration'
        }
    }
    AfterEach {
        if ($script:fx -and (Test-Path $script:fx.Store)) { Remove-Item $script:fx.Store -Recurse -Force }
        [Environment]::SetEnvironmentVariable('VMF_ENGINE_JOB_ID', $null)
        [Environment]::SetEnvironmentVariable('VMF_STORE_PATH', $null)
    }

    It 'refuses a <Operation> while the delete runs' -ForEach @(
        @{ Operation = 'restore'; Extra = @{ VmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1' } }
        @{ Operation = 'wave'; Extra = @{ Wave = 'w1' } }
        @{ Operation = 'reserve'; Extra = @{ Wave = 'w1' } }) {
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { (@($Operation) -contains 'discard') -and $RunId -eq 'run-x' }
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation $Operation -RunId 'run-x' -Note 'n' @Extra } |
            Should -Throw '400: *being deleted*'
    }

    It 'review 2 item 1: after one copy fails, the delete is still open and a restore is still refused' {
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { (@($Operation) -contains 'discard') -and $RunId -eq 'run-x' }
        $global:DeDuring = @{ Op = $script:op; Refused = $null; Open = $null; Run = $script:fx.Run }
        DeAzure -RunPath $script:fx.Run -Refuse @('s1') -OnRemove {
            param($id)
            if ($id -notlike '*/s2') { return }
            # s1 was refused just before this: the engine is still deleting.
            try {
                Invoke-VmfFacadeStartEngine -Principal $global:DeDuring.Op -Operation 'restore' -RunId 'run-x' -Note 'n' `
                    -VmId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1' | Out-Null
                $global:DeDuring.Refused = 'not refused'
            }
            catch { $global:DeDuring.Refused = $_.Exception.Message }
            $global:DeDuring.Open = InModuleScope FacadeCore -Parameters @{ rp = $global:DeDuring.Run } {
                $events = InModuleScope VmMigrationFactory -Parameters @{ r = $rp } { Read-VmfEvents -RunPath $r }
                [bool](Get-VmfFacadeOpenDiscard -Events $events)
            }
        }
        { Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -RemovedBy 'operator@example.com' -DeleteSafetyCopies -Confirm:$false } | Should -Throw '*s1*'
        $global:DeDuring.Refused | Should -BeLike '400: *being deleted*'
        $global:DeDuring.Open | Should -BeTrue
        Remove-Variable -Name DeDuring -Scope Global -ErrorAction SilentlyContinue
    }
    It 'refuses a retry while the delete runs' {
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $true }
        Mock -ModuleName FacadeCore Resolve-VmfDecision { throw 'reached the retry' }
        { Invoke-VmfFacadeResolve -Principal $script:op -StorePath $script:fx.Run -VmId $script:fx.Vm -Note 'n' } |
            Should -Throw '400: *being deleted*'
    }

    It 'lets them through once the delete has ended in the log' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run } {
            Write-VmfEvent -RunPath $rp -Step 'engine:discard' -Outcome fail -Detail '1 of 3 safety copies were not deleted'
        }
        # ENGINE-START-PART-1: a wave start asks Azure whether its wave runs;
        # only the question about the delete is not asked.
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { if (@($Operation) -contains 'discard') { throw 'no need to ask Azure' }; $false }
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'wave' -RunId 'run-x' -Note 'n' -Wave 'w1' } |
            Should -Throw 'reached the engine start'
    }

    It 'and when Azure says no delete job is running (one the platform stopped)' {
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $false }
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'wave' -RunId 'run-x' -Note 'n' -Wave 'w1' } |
            Should -Throw 'reached the engine start'
    }
}

Describe 'DISCARD-ENGINE-1 S4: is a delete job running?' {
    BeforeEach {
        [Environment]::SetEnvironmentVariable('VMF_ENGINE_JOB_ID', '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.App/jobs/engine')
        function Global:DeExec([string]$Status, [string]$Op = 'discard', [string]$Run = 'run-x', [string]$Project) {
            $envs = @(@{ name = 'VMF_OPERATION'; value = $Op }, @{ name = 'VMF_RUN_ID'; value = $Run })
            if ($Project) { $envs += @{ name = 'VMF_PROJECT'; value = $Project } }
            @{ properties = @{ status = $Status; template = @{ containers = @(@{ env = $envs }) } } }
        }
        $global:DePages = @{}
        # Not exported: asked inside the service module, as the service asks it.
        function Global:DeRunning([string]$Project) {
            InModuleScope FacadeCore -Parameters @{ pr = $Project } { Test-VmfFacadeEngineRunning -Operation 'discard' -RunId 'run-x' -Project $pr }
        }
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod {
            $key = if ($Uri) { [string]$Uri } else { 'first' }
            [pscustomobject]@{ StatusCode = 200; Content = ($global:DePages[$key] | ConvertTo-Json -Depth 12) }
        }
    }
    AfterEach {
        [Environment]::SetEnvironmentVariable('VMF_ENGINE_JOB_ID', $null)
        Remove-Variable -Name DePages -Scope Global -ErrorAction SilentlyContinue
        Remove-Item 'function:\DeExec', 'function:\DeRunning' -ErrorAction SilentlyContinue
    }

    It 'a new execution, still Processing, counts' {
        $global:DePages['first'] = @{ value = @((DeExec 'Processing')) }
        (DeRunning) | Should -BeTrue
    }

    It 'a finished one does not' {
        $global:DePages['first'] = @{ value = @((DeExec 'Succeeded'), (DeExec 'Failed')) }
        (DeRunning) | Should -BeFalse
    }

    It 'another operation, another run or another project does not' {
        $global:DePages['first'] = @{ value = @((DeExec 'Running' -Op 'wave'), (DeExec 'Running' -Run 'run-y'), (DeExec 'Running' -Project 'other')) }
        (DeRunning) | Should -BeFalse
        (DeRunning 'other') | Should -BeTrue
    }

    It 'several operations are asked in one listing' {
        $global:DePages['first'] = @{ value = @((DeExec 'Running' -Op 'restore')) }
        InModuleScope FacadeCore { Test-VmfFacadeEngineRunning -Operation @('wave', 'restore', 'rebuild') -RunId 'run-x' } | Should -BeTrue
        InModuleScope FacadeCore { Test-VmfFacadeEngineRunning -Operation @('wave', 'rebuild') -RunId 'run-x' } | Should -BeFalse
    }

    It 'one on the second page is found' {
        $global:DePages['first'] = @{ value = @((DeExec 'Succeeded')); nextLink = 'https://management.azure.com/page2' }
        $global:DePages['https://management.azure.com/page2'] = @{ value = @((DeExec 'Running')) }
        (DeRunning) | Should -BeTrue
    }
}

Describe 'DISCARD-ENGINE-1: the engine operation' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $script:entry = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'docker' 'entrypoint.ps1')
        $script:http = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'app' 'PostDiscardRun' 'run.ps1')
    }

    It 'the entrypoint deletes the run WITH its copies, as the person who asked, and asks nothing' {
        $branch = [regex]::Match($script:entry, "(?s)'discard' \{.*?\n    \}").Value
        $branch.Length | Should -BeGreaterThan 50 -Because 'the discard operation must exist'
        $branch | Should -Match 'Remove-VmfRun @discardParams'
        $branch | Should -Match 'DeleteSafetyCopies\s+=\s+\$true'
        $branch | Should -Match 'RemovedBy\s+=.*VMF_RESTORED_BY'
        $branch | Should -Match 'Reason\s+=.*VMF_NOTE'
        $branch | Should -Match 'Confirm\s+=\s+\$false'
    }

    It 'S4: a discard whose run is gone writes nothing back under it - no ghost run' {
        # Both writes - the version line before the operation, and the failure
        # line in the catch - ask first whether the run is still there.
        $script:entry | Should -Match "function Find-VmfEngineRun \{[^}]*VMF_OPERATION -ne 'discard'"
        $script:entry | Should -Match '\$runThere = Find-VmfEngineRun'
        $script:entry | Should -Match 'param\(\$rp, \$step, \$v, \$op, \$there\) if \(-not \$there\) \{ return \}' -Because 'the version line is written only while the run is there'
        $script:entry | Should -Match '\$env:VMF_OPERATION \$runThere' -Because 'and the module block is told whether it is'
        ([regex]::Matches($script:entry, 'if \(Find-VmfEngineRun\) \{')).Count | Should -Be 1 -Because 'the failure line asks again, at the time it fails'
    }

    It 'the endpoint passes the run and the project, so the engine finds the run' {
        $script:http | Should -Match '-RunId \$runId'
        $script:http | Should -Match '-Project \$project'
    }
}
