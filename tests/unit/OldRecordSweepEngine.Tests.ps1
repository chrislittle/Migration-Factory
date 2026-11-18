#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# The engine half of the old-record sweep (2026-11-12): OLD-VERSION-
# READERS-REMOVE-7, OLD-VERSION-READERS-REMOVE-8, RUN-STATUS-OLD-SUMMARY-1,
# TARGETS-NO-LIST-1 and OLD-STATE-READERS-FINISH-1.
#
# Nothing is public before 1.0 (2026-11-11), so no store holds a record
# an earlier version wrote. Each reader of such a record is gone, and each
# test below holds one rule: the reader takes what this version writes, and a
# record of another shape is refused - on a rollback, a restore or Finish,
# before anything changes, never read as "nothing to do".

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    . (Join-Path $PSScriptRoot '_RecordShape.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'oldsweep'
    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute'
    $script:vmId = "$($script:sub)/virtualMachines/vm1"
}

AfterAll { Remove-VmfTestTemp }

Describe 'OLD-VERSION-READERS-REMOVE-7: the plan reader takes the current version only' {

    It 'reads a plan whose every entry is of the current version' {
        InModuleScope VmMigrationFactory {
            $v = Get-VmfPlanSchemaVersion
            $plan = [pscustomobject]@{ entries = @([pscustomobject]@{ schemaVersion = $v; vmId = 'a' }) }
            (ConvertTo-VmfSupportedPlan -Plan $plan).entries[0].vmId | Should -Be 'a'
        }
    }

    It 'refuses an entry of an earlier version, by name' {
        InModuleScope VmMigrationFactory {
            $v = Get-VmfPlanSchemaVersion
            $plan = [pscustomobject]@{ entries = @([pscustomobject]@{ schemaVersion = $v; vmId = 'a' }, [pscustomobject]@{ schemaVersion = $v - 1; vmId = 'b' }) }
            { ConvertTo-VmfSupportedPlan -Plan $plan -Source 'plan.json' } | Should -Throw '*plan.json*earlier contract version*make the plan again with this version*'
        }
    }

    It 'refuses an entry with no version, and one whose version is null' {
        InModuleScope VmMigrationFactory {
            { ConvertTo-VmfSupportedPlan -Plan ([pscustomobject]@{ entries = @([pscustomobject]@{ vmId = 'a' }) }) } | Should -Throw '*earlier contract version*'
            { ConvertTo-VmfSupportedPlan -Plan ([pscustomobject]@{ entries = @([pscustomobject]@{ vmId = 'a'; schemaVersion = $null }) }) } | Should -Throw '*earlier contract version*'
        }
    }

    It 'still refuses a newer entry, and still reads a plan with no entries' {
        InModuleScope VmMigrationFactory {
            $v = Get-VmfPlanSchemaVersion
            { ConvertTo-VmfSupportedPlan -Plan ([pscustomobject]@{ entries = @([pscustomobject]@{ schemaVersion = $v + 1 }) }) } | Should -Throw '*newer version*'
            (ConvertTo-VmfSupportedPlan -Plan ([pscustomobject]@{ entries = @() })) | Should -Not -BeNullOrEmpty
        }
    }

    It 'every read of a plan from the store goes through the refusal' {
        $rp = Join-Path $script:temp "plan-$([guid]::NewGuid().ToString('N').Substring(0,6))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } {
            param($rp)
            Initialize-VmfRun -RunPath $rp -RunId 'p' | Out-Null
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document @{ entries = @(@{ schemaVersion = 1; vmId = 'a' }) }
            { Read-VmfPlanDocument -RunPath $rp } | Should -Throw '*earlier contract version*'
            { Read-VmfPlanFile -Path (Join-Path $rp 'plan.json') } | Should -Throw '*earlier contract version*'
            { Read-VmfPlanFileVersioned -Path (Join-Path $rp 'plan.json') } | Should -Throw '*earlier contract version*'
        }
    }

    It 'the shared fixture helper gives the version the engine writes' {
        Get-VmfTestPlanEntryVersion | Should -Be (InModuleScope VmMigrationFactory { Get-VmfPlanSchemaVersion })
    }
}

Describe 'OLD-STATE-READERS-FINISH-1: the state reader takes the current version only' {

    It 'reads a document of the current version, and refuses any other' {
        $rp = Join-Path $script:temp "state-$([guid]::NewGuid().ToString('N').Substring(0,6))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } {
            param($rp, $id)
            Initialize-VmfRun -RunPath $rp -RunId 's' | Out-Null
            $doc = New-VmfStateDoc -RunPath $rp -RunId 's' -VmId $id
            $doc.schemaVersion | Should -Be $script:VmfStateDocSchemaVersion
            foreach ($older in @(1, ($script:VmfStateDocSchemaVersion - 1))) {
                $doc.schemaVersion = $older
                Write-VmfStateDoc -RunPath $rp -Document $doc
                { Read-VmfStateDoc -RunPath $rp -VmId $id } | Should -Throw "*unsupported schemaVersion '$older'*reads only $($script:VmfStateDocSchemaVersion)*"
            }
        }
    }

    It 'no writer raises a document''s version field by field' {
        $offenders = foreach ($file in Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory') -Recurse -Filter '*.ps1') {
            $code = Get-VmfCodeOnly -Path $file.FullName
            if ($code -match '\.schemaVersion\s*=\s*\$script:VmfStateDocSchemaVersion') { $file.Name }
        }
        @($offenders) | Should -BeNullOrEmpty
    }

    It 'the shared fixture helper gives the version the engine writes' {
        Get-VmfTestStateVersion | Should -Be (InModuleScope VmMigrationFactory { $script:VmfStateDocSchemaVersion })
    }
}

Describe 'RUN-STATUS-OLD-SUMMARY-1: the wave''s write patches only a summary that holds both counts' {

    BeforeAll {
        $script:Summary = {
            [pscustomobject]@{ reason = 'dailyCheck'; halted = $false; machines = 2; restoredStops = 0; waitsOnPerson = 1
                stateCounts = [pscustomobject]@{ NEEDS_DECISION = 1; PLANNED = 1 }
                waves = @([pscustomobject]@{ wave = 'w1'; machines = 1; members = ('a' * 64); restoredStops = 1; waitsOnPerson = 0; stateCounts = [pscustomobject]@{ FAILED_ROLLED_BACK = 1 } }
                          [pscustomobject]@{ wave = 'w2'; machines = 1; members = ('b' * 64); restoredStops = 0; waitsOnPerson = 1; stateCounts = [pscustomobject]@{ NEEDS_DECISION = 1 } })
                next = [pscustomobject]@{ wave = 'w2'; waitsFor = 'running' } }
        }
    }

    It 'patches a summary that holds both counts, and keeps the other waves'' counts' {
        $patched = InModuleScope VmMigrationFactory -Parameters @{ s = (& $script:Summary) } {
            param($s) Update-VmfRunSummaryWave -Summary $s -Wave 'w2' -Counts @{ CONVERTING = 1 } -Reason 'waveRunning'
        }
        $patched | Should -Not -BeNullOrEmpty
        ($patched.waves | Where-Object { $_.wave -eq 'w1' }).restoredStops | Should -Be 1
        $patched.restoredStops | Should -Be 1
        $patched.waitsOnPerson | Should -Be 0 -Because 'the running wave''s decision was made, and wave 1 waits for no person'
    }

    It 'returns nothing for a summary with no <Field>, so the caller builds it from the store' -ForEach @(
        @{ Field = 'waitsOnPerson'; Where = 'summary' }
        @{ Field = 'restoredStops'; Where = 'summary' }
        @{ Field = 'waitsOnPerson'; Where = 'wave' }
        @{ Field = 'restoredStops'; Where = 'wave' }
    ) {
        $s = & $script:Summary
        if ($Where -eq 'summary') { $s.PSObject.Properties.Remove($Field) } else { $s.waves[0].PSObject.Properties.Remove($Field) }
        $patched = InModuleScope VmMigrationFactory -Parameters @{ s = $s } {
            param($s) Update-VmfRunSummaryWave -Summary $s -Wave 'w2' -Counts @{ CONVERTING = 1 } -Reason 'waveRunning'
        }
        $patched | Should -BeNullOrEmpty
    }

    It 'the empty summary of a status write holds both counts, and the contract requires them' {
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'run-status.schema.json') -Raw | ConvertFrom-Json
        @($schema.properties.summary.required) | Should -Contain 'waitsOnPerson'
        @($schema.properties.summary.required) | Should -Contain 'restoredStops'
        @($schema.properties.summary.properties.waves.items.required) | Should -Contain 'waitsOnPerson'
        @($schema.properties.summary.properties.waves.items.required) | Should -Contain 'restoredStops'
        $schema.properties.schemaVersion.const | Should -Be (InModuleScope VmMigrationFactory { $script:VmfRunStatusSchemaVersion })
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'RunSummary.ps1')
        $code | Should -Match 'machines = 0; stateCounts = \[ordered\]@\{\}; restoredStops = 0; waitsOnPerson = 0'
        $code | Should -Not -Match 'haveWaiting'
    }
}

Describe 'OLD-VERSION-READERS-REMOVE-8: the quota record readers take what this version writes' {

    It 'BLOCKED is blocked, whatever the case; the name before BLOCKED-NAME-1 is not' {
        InModuleScope VmMigrationFactory {
            Test-VmfClaimBlocked -Claim ([pscustomobject]@{ state = 'BLOCKED' }) | Should -BeTrue
            Test-VmfClaimBlocked -Claim ' blocked ' | Should -BeTrue
            Test-VmfClaimBlocked -Claim ([pscustomobject]@{ state = 'CAPACITY_BLOCKED' }) | Should -BeFalse
        }
    }

    It 'no reader normalises a state name any more' {
        InModuleScope VmMigrationFactory { Get-Command Get-VmfClaimStateName -ErrorAction SilentlyContinue } | Should -BeNullOrEmpty
    }

    It 'a record with no reservable count is reservable - the safe side for a Reserved wave' {
        InModuleScope VmMigrationFactory {
            Test-VmfClaimReservable -Claim ([pscustomobject]@{ demand = [pscustomobject]@{ instances = 3 } }) | Should -BeTrue
            Test-VmfClaimReservable -Claim ([pscustomobject]@{ demand = [pscustomobject]@{ instances = 3; reservableInstances = 0 } }) | Should -BeFalse
        }
    }

    It 'and a reservation is never made for all of its machines: the reservation refuses such a record, and asks Azure nothing' {
        $rp = Join-Path $script:temp "res-$([guid]::NewGuid().ToString('N').Substring(0,6))"
        $entry = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vmId; wave = 'w1'; path = 'A'
            target = [pscustomobject]@{ size = 'Standard_D2ds_v6' }; assessment = [pscustomobject]@{ location = 'centralus'; availabilitySetId = '' }
            policy = [pscustomobject]@{ capacityGate = 'Reserved'; requireApproval = $false } }
        $claim = [ordered]@{ schemaVersion = 15; runId = 'res'; wave = 'w1'; subscriptionId = '00000000-0000-0000-0000-000000000000'; resourceGroup = 'rg-app'
            region = 'centralus'; zone = $null; size = 'Standard_D2ds_v6'; vmFamily = 'standardDDSv6Family'; state = 'QUOTA_VERIFIED'; blockReason = $null
            demand = [ordered]@{ instances = 3; vcpus = 6 }; quota = [ordered]@{ limit = 100; used = 0 }; notes = @() }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; e = $entry; c = $claim } {
            param($rp, $e, $c)
            Initialize-VmfRun -RunPath $rp -RunId 'res' | Out-Null
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document @{ schemaVersion = 1; entries = @($e) } -Depth 12
            Write-VmfStoreJson -RunPath $rp -RelPath 'capacity/w1-d2ds.json' -Document $c -Depth 12
        }
        Mock -ModuleName VmMigrationFactory Get-VmfReservedCoverageGaps { @() }
        Mock -ModuleName VmMigrationFactory New-VmfCapacityReservation { throw 'a reservation was asked of Azure' }
        $r = New-VmfWaveReservation -OutPath $rp -Wave 'w1'
        $r.Refused | Should -Match 'does not say how many machines it holds'
        @($r.Reserved).Count | Should -Be 0
        Should -Invoke -ModuleName VmMigrationFactory New-VmfCapacityReservation -Times 0 -Exactly
    }
    It 'no file of the module, the pages, the schemas or the unit test fixtures names CAPACITY_BLOCKED' {
        $roots = @((Join-Path $script:repoRoot 'src'), (Join-Path $script:repoRoot 'schemas'), (Join-Path $script:repoRoot 'tests' 'fixtures'))
        $found = foreach ($r in $roots) {
            Get-ChildItem $r -Recurse -File -Include '*.ps1', '*.psm1', '*.js', '*.html', '*.json' |
                Where-Object { [System.IO.File]::ReadAllText($_.FullName) -match 'CAPACITY_BLOCKED' } | ForEach-Object Name
        }
        @($found) | Should -BeNullOrEmpty
    }
}

Describe 'TARGETS-NO-LIST-1: the target choices file is of this version' {

    It 'the writer and the contract agree on the version, and the contract requires the list' {
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'target-choices.schema.json') -Raw | ConvertFrom-Json
        $schema.properties.schemaVersion.const | Should -Be (InModuleScope VmMigrationFactory { Get-VmfTargetChoicesSchemaVersion })
        @($schema.required) | Should -Contain 'machinesVersion'
        @($schema.properties.machinesVersion.type) | Should -Not -Contain 'null'
        @($schema.properties.choices.items.properties.method.enum) | Should -Not -Contain 'rebuild'
    }
}

Describe 'OLD-STATE-READERS-FINISH-1: Finish and the accelerated networking decision' {

    It 'the empty LUN proof needs the copy the record names, and asks Azure nothing without it' {
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment { throw 'Azure was asked' }
        $r = InModuleScope VmMigrationFactory -Parameters @{ id = $script:vmId } {
            param($id)
            Test-VmfEmptyLunWant -Context ([pscustomobject]@{ RunPath = (Join-Path ([System.IO.Path]::GetTempPath()) 'vmf-oldsweep-none'); VmId = $id }) -ReadOpName 'rollback:readDataDisk' -Lun 2 `
                -Want @{ id = '/d/new2'; name = 'new2'; snapshotId = '' } -HadName 'old2'
        }
        $r | Should -Not -BeNullOrEmpty
        $r.Outcome | Should -Be 'unproven'
        $r.Why | Should -Match "names no copy that the disk 'new2' was made from"
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment -Times 0 -Exactly
    }

    It 'with the copy named, a disk made from it is proven, and one made from another copy is not' {
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment { [pscustomobject]@{ Exists = $true; ManagedBy = ''; SourceResourceId = '/s/copy2' } }
        InModuleScope VmMigrationFactory -Parameters @{ id = $script:vmId } {
            param($id)
            $ctx = [pscustomobject]@{ RunPath = (Join-Path ([System.IO.Path]::GetTempPath()) 'vmf-oldsweep-none'); VmId = $id }
            Test-VmfEmptyLunWant -Context $ctx -ReadOpName 'r' -Lun 2 -Want @{ id = '/d/new2'; name = 'new2'; snapshotId = '/s/copy2' } | Should -BeNullOrEmpty
            (Test-VmfEmptyLunWant -Context $ctx -ReadOpName 'r' -Lun 2 -Want @{ id = '/d/new2'; name = 'new2'; snapshotId = '/s/other' }).Foreign | Should -BeTrue
        }
    }

    It 'Finish stops before any change on a swap record with no list of kept disks' {
        $rp = Join-Path $script:temp "finish-$([guid]::NewGuid().ToString('N').Substring(0,6))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; sub = $script:sub } {
            param($rp, $id, $sub)
            Initialize-VmfRun -RunPath $rp -RunId 'f' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'f' -VmId $id | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $doc | Add-Member -NotePropertyName captured -NotePropertyValue ([pscustomobject]@{ vmConfig = [pscustomobject]@{ name = 'vm1'; size = 'Standard_D2ds_v4'
                        osDisk = [pscustomobject]@{ name = 'vm1-os'; managedDiskId = "$sub/disks/vm1-os" }
                        dataDisks = @([pscustomobject]@{ name = 'vm1-d0'; lun = 0; managedDiskId = "$sub/disks/vm1-d0" }) } }) -Force
            $doc | Add-Member -NotePropertyName swapPending -NotePropertyValue ([pscustomobject]@{ kind = 'restore'; leftUtc = '2026-11-12T00:00:00Z'; error = 'refused'
                    swaps = @([pscustomobject]@{ lun = 0; name = 'vm1-d0'; oldDiskId = "$sub/disks/vm1-d0"; diskId = "$sub/disks/vm1-d0-r"; diskName = 'vm1-d0-r'; snapshotId = "$sub/snapshots/c0"; lunHolds = 'had' })
                    swapped = @() }) -Force
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { throw 'Azure was asked' }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { throw 'Azure was asked' }
        { Complete-VmfDataDiskSwap -RunPath $rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Confirm:$false } |
            Should -Throw "*does not list the data disks it keeps*does not change the machine*"
        Should -Invoke -ModuleName VmMigrationFactory Use-VmfSubscriptionContext -Times 0 -Exactly
        $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id }
        $doc.PSObject.Properties['putBackJob'] | Should -BeNullOrEmpty -Because 'no checkpoint is written: nothing started'
    }

    It 'and counts only the swap record''s own kept list, never the rollback''s or the restore''s' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Complete-VmfDataDiskSwap.ps1')
        $code | Should -Not -Match "-Name 'dataDisksKept'"
        $code | Should -Not -Match "-Name 'keptDataDisks'"
        $code | Should -Not -Match 'before it recorded each copy'
    }

    It 'the accelerated networking decision is the one Preparing saved, and a record with none throws' {
        InModuleScope VmMigrationFactory {
            $saved = [pscustomobject]@{ captured = [pscustomobject]@{ acceleratedNetworking = [pscustomobject]@{ policy = 'preserve'; expectFabric = $true } } }
            $d = Get-VmfAcceleratedNetworkingDecision -Doc $saved
            $d.Policy | Should -Be 'preserve'
            $d.ExpectFabric | Should -BeTrue
            { Get-VmfAcceleratedNetworkingDecision -Doc ([pscustomobject]@{ captured = [pscustomobject]@{} }) } | Should -Throw '*no accelerated networking decision from Preparing*'
            { Get-VmfAcceleratedNetworkingDecision -Doc ([pscustomobject]@{ captured = [pscustomobject]@{ acceleratedNetworking = [pscustomobject]@{ policy = '' } } }) } | Should -Throw '*no accelerated networking decision*'
            (Get-Command Get-VmfAcceleratedNetworkingDecision).Parameters.ContainsKey('PlanEntry') | Should -BeFalse
        }
    }

    It 'the infrastructure-as-code report reads no plan entry: a decision with no policy is not recorded' {
        $doc = [pscustomobject]@{ schemaVersion = (Get-VmfTestStateVersion); vmId = $script:vmId; state = 'MIGRATED'
            history = @([pscustomobject]@{ state = 'MIGRATED'; outcome = 'ok'; tsUtc = '2026-11-12T00:00:00Z' })
            captured = [pscustomobject]@{ vmConfig = [pscustomobject]@{ name = 'vm1'; size = 'Standard_D2ds_v4'; controller = 'SCSI'
                    nics = @([pscustomobject]@{ id = '/n/1'; primary = $true; acceleratedNetworking = $false }) }
                startedTarget = [pscustomobject]@{ size = 'Standard_D2ds_v6'; controller = 'NVMe' }
                acceleratedNetworking = [pscustomobject]@{ expectFabric = $true } } }
        $null = Complete-VmfTestCapture $doc
        $row = InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) @(Get-VmfIacChangeRows -StateDocs @($d))[0] }
        $row.acceleratedNetworking | Should -Be 'Not recorded'
        $row.size | Should -Be 'Standard_D2ds_v4 to Standard_D2ds_v6'
        (InModuleScope VmMigrationFactory { Get-Command Get-VmfIacChangeRows }).Parameters.ContainsKey('EntryByVmId') | Should -BeFalse
    }

    It 'the contract holds the shapes Finish reads' {
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json') -Raw | ConvertFrom-Json
        $schema.properties.schemaVersion.const | Should -Be (InModuleScope VmMigrationFactory { $script:VmfStateDocSchemaVersion })
        @($schema.properties.swapPending.required) | Should -Contain 'kept'
        @($schema.properties.swapPending.properties.swaps.items.required) | Should -Contain 'snapshotId'
        @($schema.properties.swapPending.properties.swaps.items.required) | Should -Contain 'lunHolds'
        @($schema.properties.swapPending.properties.swaps.items.properties.lunHolds.enum) | Should -Not -Contain $null
        $schema.properties.captured.properties.putBackRetirement.additionalProperties | Should -BeFalse
        @($schema.properties.captured.properties.putBackRetirement.properties.PSObject.Properties.Name) | Sort-Object | Should -Be @('retiresUtc', 'size', 'warnFromUtc')
        $schema.'$defs'.PSObject.Properties['purchasePlan'] | Should -BeNullOrEmpty
    }
}

Describe 'Security note: the delete of an assessment reads a run with no kind as a migration' {

    BeforeAll {
        $script:store = Join-Path $script:temp "store-$([guid]::NewGuid().ToString('N').Substring(0,6))"
        InModuleScope VmMigrationFactory -Parameters @{ root = $script:store } {
            param($root)
            Initialize-VmfRun -RunPath "$root/scan-1" -RunId 'scan-1' -Kind 'assessment' | Out-Null
            Initialize-VmfRun -RunPath "$root/mig-1" -RunId 'mig-1' -Kind 'migration' -FromAssessment 'scan-1' | Out-Null
        }
    }

    It 'a run whose manifest names no kind, planned from the assessment, stops the delete' {
        InModuleScope VmMigrationFactory -Parameters @{ root = $script:store } {
            param($root)
            $m = Read-VmfStoreJson -RunPath "$root/mig-1" -RelPath 'run.json'
            $m.PSObject.Properties.Remove('kind')
            Write-VmfStoreJson -RunPath "$root/mig-1" -RelPath 'run.json' -Document $m
            $assessment = Read-VmfStoreJson -RunPath "$root/scan-1" -RelPath 'run.json'
            @(Get-VmfMigrationsPlannedFrom -RunPath "$root/scan-1" -Manifest $assessment) | Should -Be @('mig-1')
            { Assert-VmfAssessmentUnused -RunPath "$root/scan-1" -Manifest $assessment } | Should -Throw '*still holds 1 migration*mig-1*'
        }
    }

    It 'a run whose manifest says assessment is passed over, and a run with no manifest names nothing' {
        InModuleScope VmMigrationFactory -Parameters @{ root = $script:store } {
            param($root)
            $m = Read-VmfStoreJson -RunPath "$root/mig-1" -RelPath 'run.json'
            $m | Add-Member -NotePropertyName kind -NotePropertyValue 'assessment' -Force
            Write-VmfStoreJson -RunPath "$root/mig-1" -RelPath 'run.json' -Document $m
            New-Item -ItemType Directory -Path "$root/empty-run" -Force | Out-Null
            $assessment = Read-VmfStoreJson -RunPath "$root/scan-1" -RelPath 'run.json'
            @(Get-VmfMigrationsPlannedFrom -RunPath "$root/scan-1" -Manifest $assessment) | Should -BeNullOrEmpty
        }
    }
}
