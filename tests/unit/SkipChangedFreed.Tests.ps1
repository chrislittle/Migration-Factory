#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SKIP-CHANGED-FREED-1, 2026-10-31. Leave this machine out (Skip-VmfVm)
# released the run's claim whatever the stop left. A machine whose rollback did
# not finish (machineState 'changed', or a data disk swap that is left) was then
# free for another migration, whose PRECHECK and first safety copy took the
# changed machine as "as it was". A later rollback of that migration puts the
# changed machine back: the original is lost (the full rollback rule).
#
# Inside one run a retry is refused until a restore mends it
# (SAFETY-RETRY-1, Test-VmfRetryHeld). Another migration asks only the claim
# (Get-VmfOtherRunClaimRefusal). So the claim is the guard, and it stays:
#   - Skip-VmfVm keeps the claim of a machine left changed, records SKIPPED,
#     and returns ClaimReleased = $false;
#   - a machine left out untouched, or as it was, is released as before;
#   - the settled-claim release (Remove-VmfSettledVmClaim: the worker, the end
#     of the wave, and any timer that calls it) leaves a changed SKIPPED
#     machine claimed;
#   - Restore this machine and Finish the restore release it once the record
#     says it is mended; Rebuild this machine parks it for a decision in this
#     run, and Leave this machine out then releases it;
#   - Stop this migration keeps the claim of every machine it leaves changed.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    . (Join-Path $PSScriptRoot '_RecordShape.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # RESTORE-PERM-CHECK-1: the permission check of Restore this machine is not under test here (RestorePermCheck.Tests.ps1).
    Mock -ModuleName VmMigrationFactory Get-VmfRestorePermissionStop { $null }
    # OLD-VERSION-READERS-REMOVE-4: every disk made from a copy is read back and its key compared, so the fake Azure answers the read.
    Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    $script:SUB = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-lab/providers/Microsoft.Compute'
    $global:ScVm = "$script:SUB/virtualMachines/app01"

    function Global:ScModule([scriptblock]$Block, [object[]]$Arguments = @()) { & (Get-Module VmMigrationFactory) $Block @Arguments }

    # One store, two migrations: run-1 holds the machine, run-2 is the next
    # migration that would take it. The machine stopped in run-1 with the
    # machine state given, and run-1 holds its claim.
    #   changed    - the rollback did not finish
    #   restored   - the product rolled it back
    #   untouched  - a stop at PRECHECK
    #   swapLeft   - a data disk swap of a restore is left
    #   stranded   - the rollback deleted the definition and did not rebuild it
    function Global:ScNewStore {
        param([ValidateSet('changed', 'restored', 'untouched', 'swapLeft', 'stranded')][string]$Shape = 'changed')
        $store = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-sc-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $store | Out-Null
        $global:ScStore = $store
        $global:ScRun1 = Join-Path $store 'run-1'
        $global:ScRun2 = Join-Path $store 'run-2'
        ScModule { param($r1, $r2, $vmId, $sub, $shape)
            Initialize-VmfRun -RunPath $r1 -RunId 'run-1' -Kind 'migration' | Out-Null
            Initialize-VmfRun -RunPath $r2 -RunId 'run-2' -Kind 'migration' | Out-Null
            $plan = [ordered]@{ schemaVersion = 1; entries = @([ordered]@{
                schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $vmId; wave = 'lab-1'; ring = 'lab'
                assessment = [ordered]@{ location = 'centralus'; classification = 'ReadyNow' }
                target = [ordered]@{ size = 'Standard_D2s_v6' }; path = 'A'; policy = [ordered]@{ requireApproval = $false } }) }
            Write-VmfStoreJson -RunPath $r1 -RelPath 'plan.json' -Document $plan -Depth 24
            New-VmfStateDoc -RunPath $r1 -RunId 'run-1' -VmId $vmId -Wave 'lab-1' | Out-Null
            Add-VmfStateTransition -RunPath $r1 -VmId $vmId -NewState 'PRECHECK' -Outcome ok -Detail 'test' | Out-Null
            $doc = Read-VmfStateDoc -RunPath $r1 -VmId $vmId
            $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{
                snapshotId = "$sub/snapshots/app01-snap"; cloneVmId = $null }) -Force
            if ($shape -eq 'stranded') {
                $doc | Add-Member -NotePropertyName captured -NotePropertyValue ([pscustomobject]@{
                    vmConfig = [pscustomobject]@{
                        name = 'app01'; osType = 'Windows'; location = 'centralus'
                        size = 'Standard_D2ds_v4'; controller = 'SCSI'
                        osDisk = [pscustomobject]@{ name = 'app01-osdisk'; managedDiskId = "$sub/disks/app01-osdisk"; deleteOption = 'Delete'; skuName = 'Premium_LRS' }
                        dataDisks = @(); nics = @()
                    } }) -Force
            }
            if ($shape -eq 'swapLeft') {
                $doc | Add-Member -NotePropertyName swapPending -NotePropertyValue ([pscustomobject]@{ kept = @();
                    kind = 'restore'; leftUtc = '2026-10-31T10:00:00Z'; error = 'OperationNotAllowed: the disk is in use'; usedBy = ''
                    swaps = @([pscustomobject]@{ lun = 0; name = 'app01-data0'; oldDiskId = "$sub/disks/app01-data0"; diskId = "$sub/disks/app01-data0-new"; diskName = 'app01-data0-new'; caching = 'None'; instantAccess = $false })
                    swapped = @() }) -Force
            }
            $null = Add-VmfTestMachineCapture $doc 'app01' "$sub/disks/app01-osdisk"
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $r1 -Document $doc
            if ($shape -eq 'untouched') {
                Add-VmfStateTransition -RunPath $r1 -VmId $vmId -NewState 'NEEDS_DECISION' -Outcome fail -ReasonCode 'targetTooFewNics' -MachineState 'untouched' -Detail 'test' | Out-Null
            }
            elseif ($shape -eq 'restored') {
                Add-VmfStateTransition -RunPath $r1 -VmId $vmId -NewState 'GUEST_PREP' -Outcome ok -Detail 'test' | Out-Null
                Add-VmfStateTransition -RunPath $r1 -VmId $vmId -NewState 'FAILED_ROLLED_BACK' -Outcome fail -ReasonCode 'bootFailedAfterConversion' -MachineState 'restored' -Detail 'test' | Out-Null
            }
            else {
                Add-VmfStateTransition -RunPath $r1 -VmId $vmId -NewState 'GUEST_PREP' -Outcome ok -Detail 'test' | Out-Null
                Add-VmfStateTransition -RunPath $r1 -VmId $vmId -NewState 'FAILED_NEEDS_ATTENTION' -Outcome fail -ReasonCode 'rollbackFailed' -MachineState 'changed' -Detail 'test' | Out-Null
            }
            $c = New-VmfVmClaim -RunPath $r1 -VmId $vmId -RunId 'run-1'
            if (-not $c.Granted) { throw "the test could not claim the machine: $($c.Detail)" }
        } @($global:ScRun1, $global:ScRun2, $global:ScVm, $script:SUB, $Shape)
    }
    function Global:ScHolder {
        $c = ScModule { param($r, $v) Get-VmfVmClaim -RunPath $r -VmId $v } @($global:ScRun1, $global:ScVm)
        if ($c) { [string]$c.runId } else { '' }
    }
    function Global:ScOtherTakes {
        ScModule { param($r, $v) New-VmfVmClaim -RunPath $r -VmId $v -RunId 'run-2' } @($global:ScRun2, $global:ScVm)
    }
    function Global:ScDoc { ScModule { param($r, $v) Read-VmfStateDoc -RunPath $r -VmId $v } @($global:ScRun1, $global:ScVm) }
    function Global:ScSkip {
        Skip-VmfVm -RunPath $global:ScRun1 -VmId $global:ScVm -Reason 'later' -SkippedBy 'operator@example.com' -Confirm:$false
    }
    function Global:ScSettle { ScModule { param($r, $v) Remove-VmfSettledVmClaim -RunPath $r -VmId $v } @($global:ScRun1, $global:ScVm) }
    function Global:ScCleanUp {
        ScModule { $script:VmfMachineLeaseToken = $null; $script:VmfOpHeartbeat = $null }
        if ($global:ScStore -and (Test-Path $global:ScStore)) { Remove-Item $global:ScStore -Recurse -Force }
    }

    function Script:MockRestoreOps {
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo {
            [pscustomobject]@{ name = 'app01-osdisk'; id = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/app01-osdisk'
                               resourceGroup = 'rg-lab'; location = 'centralus'; skuName = 'Premium_LRS'; sizeGB = 128 }
        }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @() }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot {
            "/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/$DiskName"
        }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk { }
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { 'previous-context' }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks { , @() }
        Mock -ModuleName VmMigrationFactory Get-VmfVmSize { 'Standard_D2s_v6' }
    }
    function Script:MockRebuildOps {
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { 'previous-context' }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory Test-VmfVmExists { $false }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory Get-VmfVmSize { 'Standard_D2ds_v4' }
        Mock -ModuleName VmMigrationFactory Restore-VmfCapturedAcceleratedNetworking { }
        Mock -ModuleName VmMigrationFactory Restore-VmfCapturedDiskTypes { @() }
        Mock -ModuleName VmMigrationFactory Assert-VmfSizeTakesKeptDisks { }
        Mock -ModuleName VmMigrationFactory Get-VmfPutBackRetirementCheck { $null }
    }
    function Script:MockFinishOps {
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { 'previous-context' }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        # The disk made from the copy is on LUN 0 already: Azure took it, and
        # the job stopped before the record said so. Finish records it and
        # starts the machine.
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo {
            @([pscustomobject]@{ lun = 0; id = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/app01-data0-new'; name = 'app01-data0-new' })
        }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
    }
}

AfterAll {
    Remove-Variable ScVm, ScStore, ScRun1, ScRun2 -Scope Global -ErrorAction SilentlyContinue
    Remove-Item 'function:\ScModule', 'function:\ScNewStore', 'function:\ScHolder', 'function:\ScOtherTakes', 'function:\ScDoc',
        'function:\ScSkip', 'function:\ScSettle', 'function:\ScCleanUp' -ErrorAction SilentlyContinue
}

Describe 'SKIP-CHANGED-FREED-1: the rule - is this machine left changed, with nothing that mended it since?' {
    # Pure. For a machine not left out it is Get-VmfSkipMachineState's answer.
    # For a SKIPPED machine it is the same answer, read as the machine stood
    # when it was left out: the stop before the SKIPPED lines, and any restore
    # or rebuild since.
    BeforeAll {
        $script:changedStop = @{ tsUtc = '2026-10-31T10:08:00Z'; state = 'FAILED_NEEDS_ATTENTION'; outcome = 'fail'; reasonCode = 'rollbackFailed'; machineState = 'changed' }
        $script:restoredStop = @{ tsUtc = '2026-10-31T10:08:00Z'; state = 'FAILED_ROLLED_BACK'; outcome = 'fail'; reasonCode = 'bootFailedAfterConversion'; machineState = 'restored' }
        $script:skipLine = @{ tsUtc = '2026-10-31T10:30:00Z'; state = 'SKIPPED'; outcome = 'skip' }
        function script:LeftChanged($doc) {
            ScModule { param($d) Test-VmfMachineLeftChanged -Doc $d } @(($doc | ConvertTo-Json -Depth 10 | ConvertFrom-Json -Depth 10))
        }
    }

    It 'a machine left out after a rollback that did not finish: changed' {
        LeftChanged @{ state = 'SKIPPED'; history = @($script:changedStop, $script:skipLine) } | Should -BeTrue
    }
    It 'left out twice: still changed' {
        LeftChanged @{ state = 'SKIPPED'; history = @($script:changedStop, $script:skipLine, $script:skipLine) } | Should -BeTrue
    }
    It 'left out after the product rolled it back: not changed' {
        LeftChanged @{ state = 'SKIPPED'; history = @($script:restoredStop, $script:skipLine) } | Should -BeFalse
    }
    It 'left out before it started: not changed' {
        LeftChanged @{ state = 'SKIPPED'; history = @(@{ tsUtc = '2026-10-31T10:00:00Z'; state = 'PLANNED'; outcome = 'ok' }, $script:skipLine) } | Should -BeFalse
    }
    It 'left out changed, then restored: mended, not changed' {
        LeftChanged @{ state = 'SKIPPED'; restore = @{ restoredUtc = '2026-10-31T11:00:00Z' }; history = @($script:changedStop, $script:skipLine) } | Should -BeFalse
    }
    It 'left out changed, and a restore EARLIER than the stop: still changed' {
        LeftChanged @{ state = 'SKIPPED'; restore = @{ restoredUtc = '2026-10-31T09:00:00Z' }; history = @($script:changedStop, $script:skipLine) } | Should -BeTrue
    }
    It 'left out with a data disk swap that is left: changed, whatever the stop says' {
        LeftChanged @{ state = 'SKIPPED'; swapPending = @{ kind = 'restore' }; restore = @{ restoredUtc = '2026-10-31T11:00:00Z' }; history = @($script:restoredStop, $script:skipLine) } | Should -BeTrue
    }
    It 'a stopped machine that is not left out: the answer Leave this machine out reads' {
        LeftChanged @{ state = 'FAILED_NEEDS_ATTENTION'; history = @($script:changedStop) } | Should -BeTrue
        LeftChanged @{ state = 'FAILED_ROLLED_BACK'; history = @($script:restoredStop) } | Should -BeFalse
    }
    It 'left out changed, rebuilt (which parks it for a decision): mended' {
        LeftChanged @{ state = 'NEEDS_DECISION'; recovery = @{ recoveredUtc = '2026-10-31T11:00:00Z' }; history = @($script:changedStop, $script:skipLine) } | Should -BeFalse
    }
    It 'left out by Stop with machineState changed on the SKIPPED line: changed until a restore' {
        $stopLine = @{ tsUtc = '2026-10-31T10:30:00Z'; state = 'SKIPPED'; outcome = 'skip'; machineState = 'changed' }
        $mid = @{ tsUtc = '2026-10-31T10:05:00Z'; state = 'CONVERTING'; outcome = 'ok' }
        LeftChanged @{ state = 'SKIPPED'; history = @($mid, $stopLine) } | Should -BeTrue
        LeftChanged @{ state = 'SKIPPED'; restore = @{ restoredUtc = '2026-10-31T11:00:00Z' }; history = @($mid, $stopLine) } | Should -BeFalse
        LeftChanged @{ state = 'SKIPPED'; history = @($mid, @{ tsUtc = '2026-10-31T10:30:00Z'; state = 'SKIPPED'; outcome = 'skip'; machineState = 'untouched' }) } | Should -BeFalse
    }
    It 'a machine that migrated, or has no record: not changed' {
        LeftChanged @{ state = 'MIGRATED'; history = @(@{ tsUtc = '2026-10-31T10:00:00Z'; state = 'MIGRATED'; outcome = 'ok' }) } | Should -BeFalse
        ScModule { Test-VmfMachineLeftChanged -Doc $null } | Should -BeFalse
    }
}

Describe 'SKIP-CHANGED-FREED-1: Leave this machine out keeps the claim of a machine left changed' {
    AfterEach { ScCleanUp }

    It 'a changed machine: SKIPPED, the claim stays with this migration, and another migration is refused it' {
        ScNewStore -Shape changed
        $r = ScSkip
        $r.MachineState | Should -Be 'changed'
        $r.ClaimReleased | Should -BeFalse
        (ScDoc).state | Should -Be 'SKIPPED' -Because 'the wave still goes on without it'
        ScHolder | Should -Be 'run-1'
        $other = ScOtherTakes
        $other.Granted | Should -BeFalse
        $other.HeldBy | Should -Be 'run-1'
    }

    It 'a machine with a data disk swap that is left: the claim stays' {
        ScNewStore -Shape swapLeft
        (ScSkip).ClaimReleased | Should -BeFalse
        ScHolder | Should -Be 'run-1'
        (ScOtherTakes).Granted | Should -BeFalse
    }

    It 'a machine with nothing changed is released as before, and another migration can take it' {
        ScNewStore -Shape untouched
        $r = ScSkip
        $r.MachineState | Should -Be 'untouched'
        $r.ClaimReleased | Should -BeTrue
        ScHolder | Should -Be ''
        (ScOtherTakes).Granted | Should -BeTrue
    }

    It 'a machine the product rolled back is released as before' {
        ScNewStore -Shape restored
        $r = ScSkip
        $r.MachineState | Should -Be 'restored'
        $r.ClaimReleased | Should -BeTrue
        (ScOtherTakes).Granted | Should -BeTrue
    }

    It 'touches nothing in Azure' {
        ScNewStore -Shape changed
        ScSkip | Out-Null
        # The guard makes any Azure call fail the test; this says why it matters.
        (ScDoc).state | Should -Be 'SKIPPED'
    }
}

Describe 'SKIP-CHANGED-FREED-1: the settled-claim release leaves a changed machine that was left out' {
    AfterEach { ScCleanUp }

    It 'Remove-VmfSettledVmClaim releases nothing for it, also when it runs again' {
        ScNewStore -Shape changed
        ScSkip | Out-Null
        $r = ScSettle
        $r.Released | Should -Not -BeTrue
        ScSettle | Out-Null
        ScHolder | Should -Be 'run-1'
        (ScOtherTakes).Granted | Should -BeFalse
    }

    It 'releases it once a restore later than the stop is on its record' {
        ScNewStore -Shape changed
        ScSkip | Out-Null
        ScModule { param($r, $v)
            $d = Read-VmfStateDoc -RunPath $r -VmId $v
            $d | Add-Member -NotePropertyName restore -NotePropertyValue ([pscustomobject]@{ restoredUtc = (Get-Date).ToUniversalTime().AddMinutes(1).ToString('o') }) -Force
            $null = Complete-VmfTestCapture $d
            Write-VmfStateDoc -RunPath $r -Document $d } @($global:ScRun1, $global:ScVm)
        (ScSettle).Released | Should -BeTrue
        ScHolder | Should -Be ''
    }

    It 'still releases a machine left out untouched (CLAIM-KEPT-AFTER-WAVE-1)' {
        ScNewStore -Shape untouched
        ScSkip | Out-Null
        ScModule { param($r, $v) New-VmfVmClaim -RunPath $r -VmId $v -RunId 'run-1' | Out-Null } @($global:ScRun1, $global:ScVm)
        (ScSettle).Released | Should -BeTrue
    }
}

Describe 'SKIP-CHANGED-FREED-1: Restore this machine releases the claim it kept' {
    BeforeEach { ScNewStore -Shape changed; ScSkip | Out-Null; Script:MockRestoreOps }
    AfterEach { ScCleanUp }

    It 'after the restore, the machine is free for another migration' {
        ScHolder | Should -Be 'run-1'
        $r = Restore-VmfVm -RunPath $global:ScRun1 -VmId $global:ScVm -CorrelationId 'op-1' -Confirm:$false
        $r.RestoredFromSnapshotId | Should -Match 'app01-snap'
        (ScDoc).state | Should -Be 'SKIPPED'
        ScHolder | Should -Be ''
        (ScOtherTakes).Granted | Should -BeTrue
    }

    It 'the release the restore asks keeps the claim while the record holds a data disk swap that is left' {
        # Write the swap a restore would leave, then ask the same release
        # the restore asks: the record says the machine is still changed.
        ScModule { param($r, $v)
            $d = Read-VmfStateDoc -RunPath $r -VmId $v
            $d | Add-Member -NotePropertyName restore -NotePropertyValue ([pscustomobject]@{ restoredUtc = (Get-Date).ToUniversalTime().AddMinutes(1).ToString('o') }) -Force
            $d | Add-Member -NotePropertyName swapPending -NotePropertyValue ([pscustomobject]@{ kind = 'restore'; swaps = @() }) -Force
            $null = Complete-VmfTestCapture $d
            Write-VmfStateDoc -RunPath $r -Document $d } @($global:ScRun1, $global:ScVm)
        (ScSettle).Released | Should -Not -BeTrue
        ScHolder | Should -Be 'run-1'
    }
}

Describe 'SKIP-CHANGED-FREED-1: Finish the restore releases the claim it kept' {
    AfterEach { ScCleanUp }

    It 'a machine left out with a restore swap left, then restored and finished, is free' {
        ScNewStore -Shape swapLeft
        ScModule { param($r, $v)
            $d = Read-VmfStateDoc -RunPath $r -VmId $v
            $d | Add-Member -NotePropertyName restore -NotePropertyValue ([pscustomobject]@{ restoredUtc = (Get-Date).ToUniversalTime().AddMinutes(1).ToString('o'); dataDisksKept = @() }) -Force
            $null = Complete-VmfTestCapture $d
            Write-VmfStateDoc -RunPath $r -Document $d } @($global:ScRun1, $global:ScVm)
        ScSkip | Out-Null
        ScHolder | Should -Be 'run-1'
        Script:MockFinishOps
        $r = Complete-VmfDataDiskSwap -RunPath $global:ScRun1 -VmId $global:ScVm -FinishedBy 'operator@example.com' -CorrelationId 'op-1' -Confirm:$false
        $r.Started | Should -BeTrue
        (ScDoc).state | Should -Be 'SKIPPED'
        ScHolder | Should -Be ''
        (ScOtherTakes).Granted | Should -BeTrue
    }
}

# REBUILD-REMOVE-RECOVER-1: removed with Rebuild this machine and the restore that rebuilds.

Describe 'SKIP-CHANGED-FREED-1: Stop this migration keeps the claim of a machine it leaves changed' {
    AfterEach { ScCleanUp }

    It 'a machine whose rollback did not finish keeps its claim; the result counts it' {
        ScNewStore -Shape changed
        $r = Stop-VmfRun -RunPath $global:ScRun1 -Reason 'closing' -StoppedBy 'operator@example.com' -Confirm:$false
        $r.MachinesReleased | Should -Be 0
        $r.MachinesKept | Should -Be 1
        ScHolder | Should -Be 'run-1'
        (ScOtherTakes).Granted | Should -BeFalse
    }

    It 'a changed machine that was left out keeps its claim' {
        ScNewStore -Shape changed
        ScSkip | Out-Null
        $r = Stop-VmfRun -RunPath $global:ScRun1 -Reason 'closing' -StoppedBy 'operator@example.com' -Confirm:$false
        $r.MachinesKept | Should -Be 1
        ScHolder | Should -Be 'run-1'
    }

    It 'a rollback a worker did not finish is closed as changed, and keeps its claim' {
        ScNewStore -Shape untouched
        ScModule { param($r, $v)
            Add-VmfStateTransition -RunPath $r -VmId $v -NewState 'PRECHECK' -Outcome ok -Detail 'retry' | Out-Null
            $d = Read-VmfStateDoc -RunPath $r -VmId $v
            $d | Add-Member -NotePropertyName rollbackPending -NotePropertyValue ([pscustomobject]@{ startedUtc = '2026-10-31T10:00:00Z' }) -Force
            $null = Complete-VmfTestCapture $d
            Write-VmfStateDoc -RunPath $r -Document $d } @($global:ScRun1, $global:ScVm)
        $r = Stop-VmfRun -RunPath $global:ScRun1 -Reason 'closing' -StoppedBy 'operator@example.com' -Force -Confirm:$false
        (ScDoc).state | Should -Be 'FAILED_NEEDS_ATTENTION'
        $r.MachinesKept | Should -Be 1
        ScHolder | Should -Be 'run-1'
    }

    It 'a machine with nothing changed is released as before' {
        ScNewStore -Shape untouched
        $r = Stop-VmfRun -RunPath $global:ScRun1 -Reason 'closing' -StoppedBy 'operator@example.com' -Confirm:$false
        $r.MachinesReleased | Should -Be 1
        $r.MachinesKept | Should -Be 0
        (ScOtherTakes).Granted | Should -BeTrue
    }
}

Describe 'SKIP-CHANGED-FREED-1 review: Stop keeps a changed machine; Restore, then Leave this machine out releases it' {
    # The claim of a FAILED machine is kept by the existing rule, and a restore
    # does not change its state. So after Stop this migration and Restore this
    # machine the claim stays until Leave this machine out - the manual says
    # both steps.
    AfterEach { ScCleanUp }

    It 'the claim stays after the restore, and goes with Leave this machine out' {
        ScNewStore -Shape changed
        (Stop-VmfRun -RunPath $global:ScRun1 -Reason 'closing' -StoppedBy 'operator@example.com' -Confirm:$false).MachinesKept | Should -Be 1
        Script:MockRestoreOps
        Restore-VmfVm -RunPath $global:ScRun1 -VmId $global:ScVm -CorrelationId 'op-1' -Confirm:$false | Out-Null
        (ScDoc).state | Should -Be 'FAILED_NEEDS_ATTENTION'
        ScHolder | Should -Be 'run-1' -Because 'a failed machine stays part of its migration'
        $r = ScSkip
        $r.MachineState | Should -BeNullOrEmpty -Because 'the restore is newer than the stop'
        $r.ClaimReleased | Should -BeTrue
        (ScOtherTakes).Granted | Should -BeTrue
    }
}

Describe 'STOP-MIDMOVE-FREED-1: Stop this migration records where it leaves a machine part way through its move' {
    # A machine whose worker died part way through the move was closed as
    # SKIPPED with nothing on record, read as not changed, and freed. Stop
    # now records machineState on that line by the rule the engine uses for a
    # stop in a step (Get-VmfStateLeftMachineState): untouched for a state
    # that cannot change the machine, the audit trail for GUEST_PREP, changed
    # for the rest.
    AfterEach { ScCleanUp }
    BeforeAll {
        function script:ScAtState([string]$State, [object[]]$GuestRuns = @()) {
            ScNewStore -Shape untouched
            ScModule { param($r, $v, $s, $g)
                Add-VmfStateTransition -RunPath $r -VmId $v -NewState 'PRECHECK' -Outcome ok -Detail 'retry' | Out-Null
                if ($s -ne 'PRECHECK') { Add-VmfStateTransition -RunPath $r -VmId $v -NewState $s -Outcome ok -Detail 'test' | Out-Null }
                if (@($g).Count) {
                    $d = Read-VmfStateDoc -RunPath $r -VmId $v
                    $d | Add-Member -NotePropertyName guestExecutions -NotePropertyValue @($g) -Force
                    $null = Complete-VmfTestCapture $d
                    Write-VmfStateDoc -RunPath $r -Document $d
                }
            } @($global:ScRun1, $global:ScVm, $State, $GuestRuns)
        }
        function script:ScStop { Stop-VmfRun -RunPath $global:ScRun1 -Reason 'closing' -StoppedBy 'operator@example.com' -Force -Confirm:$false }
        function script:ScLastLine { @((ScDoc).history)[-1] }
    }

    It 'a machine at CONVERTING is left out as changed, keeps its claim, and another migration is refused it' {
        ScAtState 'CONVERTING'
        $r = ScStop
        (ScDoc).state | Should -Be 'SKIPPED'
        (ScLastLine).machineState | Should -Be 'changed'
        $r.MachinesKept | Should -Be 1
        ScHolder | Should -Be 'run-1'
        (ScOtherTakes).Granted | Should -BeFalse
    }

    It 'a machine at STOPPED (power only) is changed by the same rule as a stop in that step' {
        ScAtState 'STOPPED'
        ScStop | Out-Null
        (ScLastLine).machineState | Should -Be 'changed'
        ScHolder | Should -Be 'run-1'
    }

    It 'then Restore this machine frees it' {
        ScAtState 'CONVERTING'
        ScStop | Out-Null
        Script:MockRestoreOps
        Restore-VmfVm -RunPath $global:ScRun1 -VmId $global:ScVm -CorrelationId 'op-1' -Confirm:$false | Out-Null
        ScHolder | Should -Be ''
        (ScOtherTakes).Granted | Should -BeTrue
    }

    It 'a machine at PRECHECK is left out untouched and released' {
        ScAtState 'PRECHECK'
        $r = ScStop
        (ScLastLine).machineState | Should -Be 'untouched'
        $r.MachinesReleased | Should -Be 1
        (ScOtherTakes).Granted | Should -BeTrue
    }

    It 'a machine at GUEST_PREP that no script changed is untouched; one a script changed is changed' {
        ScAtState 'GUEST_PREP'
        ScStop | Out-Null
        (ScLastLine).machineState | Should -Be 'untouched'
        ScHolder | Should -Be ''
        ScCleanUp
        ScAtState 'GUEST_PREP' @([pscustomobject]@{ tsUtc = (Get-Date).ToUniversalTime().AddMinutes(1).ToString('o'); script = 'nvme-fix.sh'; version = '1'; result = 'FIXED' })
        ScStop | Out-Null
        (ScLastLine).machineState | Should -Be 'changed'
        ScHolder | Should -Be 'run-1'
    }

    It 'the engine and Stop use one rule' {
        $base = Join-Path $script:repoRoot 'src' 'VmMigrationFactory'
        (Get-VmfCodeOnly -Path (Join-Path $base 'Public' 'Stop-VmfRun.ps1')) | Should -Match 'Get-VmfStateLeftMachineState'
        (Get-VmfCodeOnly -Path (Join-Path $base 'Private' 'engine' 'StateMachine.ps1')) | Should -Match 'Get-VmfStateLeftMachineState'
    }
}
Describe 'SKIP-CHANGED-FREED-1: one rule in every release' {
    It 'Skip-VmfVm, Stop-VmfRun and Remove-VmfSettledVmClaim ask Test-VmfMachineLeftChanged; Restore and Finish release through Remove-VmfSettledVmClaim' {
        $base = Join-Path $script:repoRoot 'src' 'VmMigrationFactory'
        (Get-VmfCodeOnly -Path (Join-Path $base 'Public' 'Stop-VmfRun.ps1')) | Should -Match 'Test-VmfMachineLeftChanged'
        (Get-VmfCodeOnly -Path (Join-Path $base 'Private' 'state' 'VmClaims.ps1')) | Should -Match 'Test-VmfMachineLeftChanged'
        (Get-VmfCodeOnly -Path (Join-Path $base 'Public' 'Restore-VmfVm.ps1')) | Should -Match 'Remove-VmfSettledVmClaim'
        (Get-VmfCodeOnly -Path (Join-Path $base 'Public' 'Complete-VmfDataDiskSwap.ps1')) | Should -Match 'Remove-VmfSettledVmClaim'
    }
}
