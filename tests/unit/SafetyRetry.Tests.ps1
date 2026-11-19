#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SAFETY-RETRY-1: a new attempt takes new safety copies.
#
# Found by the independent review of RETRY-SERIES-1. A person's retry sends a
# machine back to PRECHECK, but its state document kept the FIRST attempt's
# copy ids: SAFETY_PRISTINE skipped because a pristine copy was on record, and
# SAFETY_COPY asked for a copy by the same name, which returns the old one. So
# a second attempt - days later, on a machine that ran in between - that failed
# was rolled back to the system disk from BEFORE THE FIRST ATTEMPT, and every
# write since was lost.
#
# Now a retry from the first step moves the earlier copies to
# `safety.earlierCopies` (so retention and run deletion still find them), and
# the new attempt takes new ones under new names. A resume of the same attempt,
# and a retry that only validates again, keep the copies they have.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    . (Join-Path $PSScriptRoot '_RecordShape.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # OLD-VERSION-READERS-REMOVE-4: every disk made from a copy is read back and its key compared, so the fake Azure answers the read.
    Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }
    . (Join-Path $PSScriptRoot '_WaveGate.ps1')
    $script:schemaFile = Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json'
    $script:sub = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg/providers/Microsoft.Compute'

    function Global:SrPlan {
        [pscustomobject]@{
            schemaVersion = (Get-VmfTestPlanEntryVersion)
            vmId = "$script:sub/virtualMachines/srvm"
            wave = 'w1'; ring = 'lab'
            assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'
                sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; platformManaged = $false; location = 'centralus' }
            target = [pscustomobject]@{ size = 'Standard_D2s_v6'; diskArch = 'diskless'; controller = 'NVMe' }
            path = 'A'
            policy = [pscustomobject]@{ safetyCopy = 'pristine' }
        }
    }
    # A machine whose first attempt took both copies and then rolled back.
    function Global:SrRolledBack($rp) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; sub = $script:sub } {
            $vm = "$sub/virtualMachines/srvm"
            $doc = New-VmfStateDoc -RunPath $rp -RunId 'sr-test' -VmId $vm -Wave 'w1'
            $doc | Add-Member -NotePropertyName safety -Force -NotePropertyValue ([pscustomobject]@{
                    snapshotId = "$sub/snapshots/srvm-vmf-sr-test"; snapshotLocked = $true
                    pristineSnapshotId = "$sub/snapshots/srvm-vmf-sr-test-pristine"; pristineSnapshotLocked = $true
                    cloneVmId = $null; locksAllowed = $true })
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
            Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'FAILED_ROLLED_BACK' -Outcome fail -ReasonCode 'bootFailedAfterConversion' `
                -MachineState 'restored' -Detail 'STARTING failed; the machine was rolled back to how it was.' | Out-Null
        }
    }
    function Global:SrDoc($rp) { InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; sub = $script:sub } { Read-VmfStateDoc -RunPath $rp -VmId "$sub/virtualMachines/srvm" } }
}
AfterAll { Remove-Item 'function:\SrPlan', 'function:\SrRolledBack', 'function:\SrDoc' -ErrorAction SilentlyContinue }

Describe 'SAFETY-RETRY-1: a retry from the first step keeps the earlier copies on record, and clears them for the new attempt' {
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-sr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Initialize-VmfRun -RunPath $rp -RunId 'sr-test' | Out-Null }
        SrRolledBack $script:rp
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'the earlier copies move to earlierCopies, with their locks, and the current ones are cleared' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; sub = $script:sub } {
            Clear-VmfRetryState -RunPath $rp -VmId "$sub/virtualMachines/srvm" -From 'PRECHECK' -NewAttempt
        }
        $doc = SrDoc $script:rp
        $doc.safety.pristineSnapshotId | Should -BeNullOrEmpty
        $doc.safety.snapshotId | Should -BeNullOrEmpty
        $doc.safety.locksAllowed | Should -BeTrue -Because 'PRECHECK''s answer about locks is not a copy'
        @($doc.safety.earlierCopies).Count | Should -Be 1
        $e = @($doc.safety.earlierCopies)[0]
        $e.pristineSnapshotId | Should -Match 'srvm-vmf-sr-test-pristine$'
        $e.pristineSnapshotLocked | Should -BeTrue
        $e.snapshotId | Should -Match 'srvm-vmf-sr-test$'
        $e.snapshotLocked | Should -BeTrue
        $e.keptUtc | Should -Not -BeNullOrEmpty
    }

    It 'the activity log says the earlier copies are kept and this attempt takes new ones' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; sub = $script:sub } {
            Clear-VmfRetryState -RunPath $rp -VmId "$sub/virtualMachines/srvm" -From 'PRECHECK' -NewAttempt
            @(Read-VmfEvents -RunPath $rp | Where-Object { $_.step -eq 'safetyCopy' -and $_.detail -match 'earlier attempt are kept' -and $_.detail -match 'new ones' }).Count | Should -Be 1
        }
    }

    It 'a second retry adds to the list; nothing earlier is lost' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; sub = $script:sub } {
            $vm = "$sub/virtualMachines/srvm"
            Clear-VmfRetryState -RunPath $rp -VmId $vm -From 'PRECHECK' -NewAttempt
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $vm
            $doc.safety.pristineSnapshotId = "$sub/snapshots/srvm-vmf-sr-test-pristine-a2"
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
            Clear-VmfRetryState -RunPath $rp -VmId $vm -From 'PRECHECK' -NewAttempt
        }
        $doc = SrDoc $script:rp
        @($doc.safety.earlierCopies).Count | Should -Be 2
        @($doc.safety.earlierCopies)[1].pristineSnapshotId | Should -Match 'pristine-a2$'
    }

    It 'a retry that only validates again keeps the copies: the conversion it checks is theirs' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; sub = $script:sub } {
            Clear-VmfRetryState -RunPath $rp -VmId "$sub/virtualMachines/srvm" -From 'VALIDATING' -NewAttempt
        }
        $doc = SrDoc $script:rp
        $doc.safety.pristineSnapshotId | Should -Match 'pristine$'
        $doc.safety.PSObject.Properties['earlierCopies'] | Should -BeNullOrEmpty
    }

    It 'a machine with no copies yet gets no list' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; sub = $script:sub } {
            $vm = "$sub/virtualMachines/srvm"
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $vm
            $doc.safety = [pscustomobject]@{ snapshotId = $null; cloneVmId = $null; locksAllowed = $true }
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
            Clear-VmfRetryState -RunPath $rp -VmId $vm -From 'PRECHECK' -NewAttempt
        }
        (SrDoc $script:rp).safety.PSObject.Properties['earlierCopies'] | Should -BeNullOrEmpty
    }

    It 'Try this machine again does it: the retry of a rolled-back machine' {
        $plan = Join-Path $script:rp 'plan.json'
        @{ schemaVersion = 1; assessmentRunId = 'sr-test'; entries = @((SrPlan)) } | ConvertTo-Json -Depth 10 | Set-Content $plan
        Open-VmfTestWaveGate -RunPath $script:rp -PlanPath $plan   # RETRY-GATE-1
        Resolve-VmfDecision -RunPath $script:rp -PlanPath $plan -VmId "$script:sub/virtualMachines/srvm" -Note 'fixed the boot setting' -ResolvedBy 'operator@example.com' | Out-Null
        $doc = SrDoc $script:rp
        $doc.state | Should -Be 'PRECHECK'
        $doc.safety.pristineSnapshotId | Should -BeNullOrEmpty
        @($doc.safety.earlierCopies).Count | Should -Be 1
    }

    It 'the document with earlier copies is valid against the state contract' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; sub = $script:sub } {
            $vm = "$sub/virtualMachines/srvm"
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $vm
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
            Clear-VmfRetryState -RunPath $rp -VmId $vm -From 'PRECHECK' -NewAttempt
        }
        $schema = Get-Content $script:schemaFile -Raw | ConvertFrom-Json
        # Derived, not pinned: VERIFY-FP-1 part 3 raised the contract to v10.
        $current = InModuleScope VmMigrationFactory { $script:VmfStateDocSchemaVersion }
        $schema.properties.schemaVersion.const | Should -Be $current
        (SrDoc $script:rp).schemaVersion | Should -Be $current
        { Test-Json -Json ((SrDoc $script:rp) | ConvertTo-Json -Depth 30) -SchemaFile $script:schemaFile -ErrorAction Stop } | Should -Not -Throw
    }

    It 'the lock flags go with their copies' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; sub = $script:sub } {
            Clear-VmfRetryState -RunPath $rp -VmId "$sub/virtualMachines/srvm" -From 'PRECHECK' -NewAttempt
        }
        $doc = SrDoc $script:rp
        $doc.safety.pristineSnapshotLocked | Should -BeNullOrEmpty
        $doc.safety.snapshotLocked | Should -BeNullOrEmpty
    }

    It 'the AUTOMATIC rollback does not move them - there the copies are the way back, and no new attempt exists' {
        # The review's first finding: Invoke-VmfRollback calls Clear-VmfRetryState
        # too. Run a real Path A rollback and look.
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { }
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { $null }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { }
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo { [pscustomobject]@{ name = 'srvm-osdisk'; location = 'centralus'; skuName = 'Premium_LRS' } }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { "/disks/$DiskName" }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; sub = $script:sub } {
            $vm = "$sub/virtualMachines/srvm"
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $vm
            $doc | Add-Member -NotePropertyName captured -Force -NotePropertyValue ([pscustomobject]@{ vmConfig = [pscustomobject]@{
                        size = 'Standard_D2s_v4'; controller = 'SCSI'; location = 'centralus'
                        osDisk = [pscustomobject]@{ name = 'srvm-osdisk'; skuName = 'Premium_LRS'; managedDiskId = '/disks/srvm-osdisk' } } })
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
            Invoke-VmfRollback -Context (New-VmfContext -PlanEntry (Global:SrPlan) -RunPath $rp -RunId 'sr-test')
        }
        $doc = SrDoc $script:rp
        $doc.safety.pristineSnapshotId | Should -Match 'pristine$'
        $doc.safety.snapshotId | Should -Match 'sr-test$'
        $doc.safety.PSObject.Properties['earlierCopies'] | Should -BeNullOrEmpty
    }

    It 'EVERY retry takes new copies - also after a stop during guest preparation (owner: a retry is a complete run end to end)' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; sub = $script:sub } {
            $vm = "$sub/virtualMachines/srvm"
            foreach ($s in 'PRECHECK', 'SAFETY_PRISTINE', 'GUEST_PREP') { Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState $s -Outcome ok | Out-Null }
            Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'NEEDS_DECISION' -Outcome ok -ReasonCode 'dataOnTempDrive' -Detail 'files on the temporary disk' | Out-Null
            Clear-VmfRetryState -RunPath $rp -VmId $vm -From 'PRECHECK' -NewAttempt
        }
        $doc = SrDoc $script:rp
        $doc.safety.pristineSnapshotId | Should -BeNullOrEmpty
        $doc.safety.snapshotId | Should -BeNullOrEmpty
        @($doc.safety.earlierCopies)[0].pristineSnapshotId | Should -Match 'pristine$'
    }

    It 'a machine that went through guest preparation and was ROLLED BACK is as it was: both copies are taken again' {
        # The mutation run found no test with guest preparation in the attempt
        # and a completed rollback - the common case this item is for.
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; sub = $script:sub } {
            $vm = "$sub/virtualMachines/srvm"
            foreach ($s in 'PRECHECK', 'SAFETY_PRISTINE', 'GUEST_PREP', 'STOPPED', 'SAFETY_COPY', 'CONVERTING', 'STARTING') { Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState $s -Outcome ok | Out-Null }
            Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'FAILED_ROLLED_BACK' -Outcome fail -ReasonCode 'bootFailedAfterConversion' -MachineState 'restored' -Detail 'rolled back' | Out-Null
            Clear-VmfRetryState -RunPath $rp -VmId $vm -From 'PRECHECK' -NewAttempt
        }
        $doc = SrDoc $script:rp
        $doc.safety.pristineSnapshotId | Should -BeNullOrEmpty
        @($doc.safety.earlierCopies)[0].pristineSnapshotId | Should -Match 'pristine$'
    }

    It 'a machine a stop left CHANGED is not tried again until it is restored' {
        # A new "as it was" copy of a changed machine would be wrong.
        $plan = Join-Path $script:rp 'plan.json'
        @{ schemaVersion = 1; assessmentRunId = 'sr-test'; entries = @((SrPlan)) } | ConvertTo-Json -Depth 10 | Set-Content $plan
        Open-VmfTestWaveGate -RunPath $script:rp -PlanPath $plan   # RETRY-GATE-1
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; sub = $script:sub } {
            $vm = "$sub/virtualMachines/srvm"
            foreach ($s in 'PRECHECK', 'SAFETY_PRISTINE', 'GUEST_PREP', 'STOPPED', 'SAFETY_COPY', 'CONVERTING', 'STARTING') { Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState $s -Outcome ok | Out-Null }
            Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'FAILED_NEEDS_ATTENTION' -Outcome fail -ReasonCode 'rollbackFailed' -MachineState 'changed' -Detail 'rollback failed' | Out-Null
        }
        { Resolve-VmfDecision -RunPath $script:rp -PlanPath $plan -VmId "$script:sub/virtualMachines/srvm" -ReturnTo PRECHECK -Note 'again' -ResolvedBy 'operator@example.com' } |
            Should -Throw '400: The last stop left srvm changed*Restore it first*'
        (SrDoc $script:rp).safety.pristineSnapshotId | Should -Match 'pristine$' -Because 'nothing moved: the restore still needs it'

        # After a restore, it may be tried again - a complete new run.
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; sub = $script:sub } {
            $vm = "$sub/virtualMachines/srvm"
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $vm
            $doc | Add-Member -NotePropertyName restore -NotePropertyValue ([pscustomobject]@{ restoredUtc = (Get-Date).ToUniversalTime().AddMinutes(5).ToString('o') }) -Force
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        (Resolve-VmfDecision -RunPath $script:rp -PlanPath $plan -VmId "$script:sub/virtualMachines/srvm" -ReturnTo PRECHECK -Note 'restored' -ResolvedBy 'operator@example.com').NewState | Should -Be 'PRECHECK'
    }
}

Describe 'SAFETY-RETRY-1: the new attempt takes new copies, under new names' {
    BeforeEach {
        # ROLLBACK-DISKS-FIRST-1: the rollback disks, made at the end of
        # SAFETY_PRISTINE, are the subject of RollbackDisksBeforeMove.Tests.ps1; here the copies are.
        Mock -ModuleName VmMigrationFactory New-VmfRollbackDisksBeforeMove { $null }
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-sr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Initialize-VmfRun -RunPath $rp -RunId 'sr-test' | Out-Null }
        SrRolledBack $script:rp
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; sub = $script:sub } {
            $vm = "$sub/virtualMachines/srvm"
            Clear-VmfRetryState -RunPath $rp -VmId $vm -From 'PRECHECK' -NewAttempt
            $ctx = New-VmfContext -PlanEntry (Global:SrPlan) -RunPath $rp -RunId 'sr-test'
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{ osDisk = @{ managedDiskId = '/disks/os' }; location = 'centralus' } }
        }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { }
        # Like Azure: a snapshot asked for by an existing name comes back as the
        # existing one - which is why the name must change.
        Mock -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot { "$script:sub/snapshots/$SnapshotName" }
        Mock -ModuleName VmMigrationFactory Lock-VmfSnapshot { "$SnapshotId/providers/Microsoft.Authorization/locks/vmf-safety-copy" }
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'SAFETY_PRISTINE takes a new pristine copy, named for the second attempt' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } {
            $ctx = New-VmfContext -PlanEntry (Global:SrPlan) -RunPath $rp -RunId 'sr-test'
            (Invoke-VmfStepSafetyPristine -Context $ctx).Next | Should -Be 'GUEST_PREP'
        }
        Should -Invoke -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot -Times 1 -Exactly -ParameterFilter { $SnapshotName -eq 'srvm-vmf-sr-test-pristine-a2' }
        (SrDoc $script:rp).safety.pristineSnapshotId | Should -Match 'srvm-vmf-sr-test-pristine-a2$'
        @((SrDoc $script:rp).safety.earlierCopies)[0].pristineSnapshotId | Should -Match 'srvm-vmf-sr-test-pristine$' -Because 'the earlier one is kept on record'
    }

    It 'SAFETY_COPY takes a new prepared copy, named for the second attempt' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } {
            $ctx = New-VmfContext -PlanEntry (Global:SrPlan) -RunPath $rp -RunId 'sr-test'
            Invoke-VmfStepSafetyPristine -Context $ctx | Out-Null
            (Invoke-VmfStepSafetyCopy -Context $ctx).Next | Should -Be 'CONVERTING'
        }
        Should -Invoke -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot -Times 1 -Exactly -ParameterFilter { $SnapshotName -eq 'srvm-vmf-sr-test-a2' }
    }

    It 'a copy is on record BEFORE it is locked, so a lock that fails cannot hide it from the next attempt' {
        # The review's fourth finding: the id was written after the lock, so a
        # failed lock left a copy nothing recorded - and the same name next time.
        Mock -ModuleName VmMigrationFactory Lock-VmfSnapshot { throw 'the lock was refused' }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } {
            $ctx = New-VmfContext -PlanEntry (Global:SrPlan) -RunPath $rp -RunId 'sr-test'
            try { Invoke-VmfStepSafetyPristine -Context $ctx | Out-Null } catch { }
        }
        (SrDoc $script:rp).safety.pristineSnapshotId | Should -Match 'pristine-a2$'
    }

    It 'a long machine name still ends with the attempt, never cut off' {
        InModuleScope VmMigrationFactory {
            $n = Get-VmfSafetyCopyName -VmName ('v' * 80) -RunId 'run-2026-09-28' -Kind 'pristine' -Attempt 3
            $n.Length | Should -BeLessOrEqual 75
            $n | Should -Match '-pristine-a3$'
            (Get-VmfSafetyCopyName -VmName 'srvm' -RunId 'sr-test' -Kind 'prepared' -Attempt 1) | Should -Be 'srvm-vmf-sr-test' -Because 'the first attempt keeps the names it always had'
        }
    }
}

Describe 'SAFETY-RETRY-1: whatever finds a machine''s copies finds the earlier ones too' {
    BeforeAll {
        $script:docWithEarlier = [pscustomobject]@{
            schemaVersion = (Get-VmfTestStateVersion); runId = 'r'; vmId = "$script:sub/virtualMachines/srvm"; state = 'MIGRATED'
            history = @([pscustomobject]@{ tsUtc = '2026-09-01T00:00:00Z'; state = 'MIGRATED'; outcome = 'ok' })
            safety = [pscustomobject]@{ pristineSnapshotId = '/snap/p2'; snapshotId = '/snap/s2'
                earlierCopies = @([pscustomobject]@{ pristineSnapshotId = '/snap/p1'; snapshotId = '/snap/s1'; keptUtc = '2026-08-20T00:00:00Z' }) }
        }
    }

    It 'one rule lists them: Get-VmfSafetyCopyIds' {
        InModuleScope VmMigrationFactory -Parameters @{ d = $script:docWithEarlier } {
            @(Get-VmfSafetyCopyIds -StateDoc $d) | Should -Be @('/snap/p2', '/snap/s2', '/snap/p1', '/snap/s1')
        }
    }

    It 'retention deletes the earlier copies with the current ones' {
        InModuleScope VmMigrationFactory -Parameters @{ d = $script:docWithEarlier } {
            $r = Get-VmfExpiredSafetyCopies -StateDocs @($d) -PlanEntries @([pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $d.vmId; policy = [pscustomobject]@{ keepSnapshotDays = 7 } }) -NowUtc ([datetime]'2026-09-28')
            @($r.Eligible[0].SnapshotIds) | Should -Be @('/snap/p2', '/snap/s2', '/snap/p1', '/snap/s1')
        }
    }

    It 'deleting the run counts them as copies it would leave behind' {
        $code = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'state' 'RunLifecycle.ps1') -Raw
        $code | Should -Match 'Get-VmfSafetyCopyIds -StateDoc \$d'
    }
}
