#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# WAVE-2 lever 7 (ruled): the default is 7 days, and it is enforced.
#
# This is the only code in the tool that deletes the last copy of a machine as
# it was before migration, so these tests are mostly about what it must REFUSE
# to delete. A retention feature that is slightly too eager is worse than none:
# nobody notices until the day somebody needs the copy.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:now = [datetime]::Parse('2026-08-28T12:00:00Z').ToUniversalTime()
    $script:snapA = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/snapshots/snap-1'
    $script:vm = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'

    function Script:Doc($state, $migratedDaysAgo, $snapId = $script:snapA, $retention = $null) {
        $history = @([pscustomobject]@{ state = 'PRECHECK'; tsUtc = $script:now.AddDays(-30).ToString('o'); outcome = 'ok' })
        if ($null -ne $migratedDaysAgo) {
            $history += [pscustomobject]@{ state = $state; tsUtc = $script:now.AddDays(-$migratedDaysAgo).ToString('o'); outcome = 'ok' }
        }
        $d = [pscustomobject]@{
            vmId    = $script:vm
            state   = $state
            history = $history
            safety  = [pscustomobject]@{ pristineSnapshotId = $snapId; snapshotId = $null; cloneVmId = $null }
        }
        if ($retention) { $d | Add-Member -NotePropertyName retention -NotePropertyValue $retention }
        $d
    }
    function Script:Entry($keepDays) {
        $pol = [pscustomobject]@{ safetyCopy = 'pristine' }
        if ($null -ne $keepDays) { $pol | Add-Member -NotePropertyName keepSnapshotDays -NotePropertyValue $keepDays }
        [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vm; wave = 'first-five'; policy = $pol }
    }
    function Script:Pick($doc, $entry) {
        InModuleScope VmMigrationFactory -Parameters @{ d = $doc; e = $entry; n = $script:now } {
            Get-VmfExpiredSafetyCopies -StateDocs @($d) -PlanEntries @($e) -NowUtc $n
        }
    }
}

Describe 'WAVE-2 lever 7: what may be deleted' {
    It 'deletes the copies of a machine migrated longer ago than its wave keeps them' {
        $r = Script:Pick (Script:Doc 'MIGRATED' 8) (Script:Entry 7)
        @($r.Eligible).Count | Should -Be 1
        @($r.Eligible)[0].KeepDays | Should -Be 7
        @($r.Eligible)[0].AgeDays | Should -BeGreaterThan 7
    }

    It 'keeps them while the machine is still inside the retention it accepted' {
        (Script:Pick (Script:Doc 'MIGRATED' 3) (Script:Entry 7)).Eligible | Should -BeNullOrEmpty
    }

    It 'reads the retention from the machine OWN wave, not one answer for the whole run' {
        # Two waves in one run may have accepted different answers.
        (Script:Pick (Script:Doc 'MIGRATED' 20) (Script:Entry 30)).Eligible | Should -BeNullOrEmpty
        @((Script:Pick (Script:Doc 'MIGRATED' 20) (Script:Entry 14)).Eligible).Count | Should -Be 1
    }

    It 'falls back to the accepted default when the entry says nothing' {
        $r = Script:Pick (Script:Doc 'MIGRATED' 8) (Script:Entry $null)
        @($r.Eligible)[0].KeepDays | Should -Be 7 -Because 'the default set is the promise the acceptance screen shows'
    }
}

Describe 'WAVE-2 lever 7: what must NEVER be deleted' {
    It 'keeps the copies of a machine that stopped for a person, at any age' {
        # A stopped machine is precisely the machine somebody may still put back.
        (Script:Pick (Script:Doc 'NEEDS_DECISION' 400) (Script:Entry 7)).Eligible | Should -BeNullOrEmpty
    }

    It 'keeps the copies of a failed machine, at any age' {
        (Script:Pick (Script:Doc 'FAILED_NEEDS_ATTENTION' 400) (Script:Entry 7)).Eligible | Should -BeNullOrEmpty
        (Script:Pick (Script:Doc 'FAILED_ROLLED_BACK' 400) (Script:Entry 7)).Eligible | Should -BeNullOrEmpty
    }

    It 'keeps the copies of a machine still in flight' {
        (Script:Pick (Script:Doc 'CONVERTING' 400) (Script:Entry 7)).Eligible | Should -BeNullOrEmpty
    }

    It 'keeps them - and SAYS so - when the retention setting is unreadable' {
        $r = Script:Pick (Script:Doc 'MIGRATED' 400) (Script:Entry 'soon')
        $r.Eligible | Should -BeNullOrEmpty
        @($r.Skipped).Count | Should -Be 1
        @($r.Skipped)[0].Reason | Should -Match 'unreadable retention'
    }

    It 'never revisits a machine whose copies are already gone' {
        $doc = Script:Doc 'MIGRATED' 400 $script:snapA ([pscustomobject]@{ deletedUtc = '2026-08-01T00:00:00Z'; keepDays = 7 })
        (Script:Pick $doc (Script:Entry 7)).Eligible | Should -BeNullOrEmpty
    }

    It 'a machine with no copies recorded is simply not a candidate' {
        (Script:Pick (Script:Doc 'MIGRATED' 400 $null) (Script:Entry 7)).Eligible | Should -BeNullOrEmpty
    }
}

Describe 'WAVE-2 lever 7: the cmdlet' {
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-ret-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; vm = $script:vm } {
            Initialize-VmfRun -RunPath $rp -RunId 'ret' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'ret' -VmId $vm -Wave 'first-five' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'MIGRATED' -Outcome ok | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $vm
            $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{
                    pristineSnapshotId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/snapshots/snap-pristine'
                    snapshotId         = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/snapshots/snap-prepared'
                    cloneVmId          = $null
                }) -Force
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        $script:pp = Join-Path $script:rp 'plan.json'
        @{ schemaVersion = 6; entries = @(@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vm; wave = 'first-five'; policy = @{ keepSnapshotDays = 7 } }) } |
            ConvertTo-Json -Depth 10 | Set-Content $script:pp -Encoding utf8NoBOM
        # RETENTION-LOCK-PUTBACK-1: the cleanup deletes through Remove-VmfRunSafetyCopies,
        # which reads each copy before and after its delete.
        $global:RetGone = @{}
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { -not $global:RetGone.ContainsKey($SnapshotId) }
        Mock -ModuleName VmMigrationFactory Remove-VmfSnapshot { $global:RetGone[$SnapshotId] = $true }
        Mock -ModuleName VmMigrationFactory Unlock-VmfSnapshot { }
        Mock -ModuleName VmMigrationFactory Get-VmfSignedInIdentity { @{ Identity = 'operator@contoso.com'; TenantId = 't' } }
        $script:later = [datetime]::UtcNow.AddDays(30)
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'deletes both copies, records who and when, and is safe to run twice' {
        $r = Remove-VmfExpiredSafetyCopies -RunPath $script:rp -PlanPath $script:pp -AsOfUtc $script:later -Confirm:$false
        @($r.Deleted).Count | Should -Be 1
        Should -Invoke Remove-VmfSnapshot -ModuleName VmMigrationFactory -Times 2 -Exactly
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; vm = $script:vm } {
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $vm
            $doc.retention.deletedBy | Should -Be 'operator@contoso.com'
            @($doc.retention.deletedSnapshotIds).Count | Should -Be 2
        }
        $again = Remove-VmfExpiredSafetyCopies -RunPath $script:rp -PlanPath $script:pp -AsOfUtc $script:later -Confirm:$false
        @($again.Deleted).Count | Should -Be 0 -Because 'a second run has nothing left to do'
        Should -Invoke Remove-VmfSnapshot -ModuleName VmMigrationFactory -Times 2 -Exactly
    }

    It 'RETAIN-SHOW-1: the activity log says it in words - who, how many, and after how long' {
        Remove-VmfExpiredSafetyCopies -RunPath $script:rp -PlanPath $script:pp -AsOfUtc $script:later -Confirm:$false | Out-Null
        $said = @(Get-Content (Join-Path $script:rp 'logs' 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object { $_.step -eq 'retention' -and $_.outcome -eq 'ok' })
        $said.Count | Should -Be 1
        $said[0].detail | Should -Be 'operator@contoso.com deleted the 2 safety copies of this machine. It was migrated 30 days ago, and its wave keeps copies for 7 days.'
    }

    It 'RETAIN-SHOW-1: the daily cleanup is named as the daily cleanup, not by its account' {
        Mock -ModuleName VmMigrationFactory Get-VmfSignedInIdentity { @{ Identity = 'retention (scheduled)'; TenantId = 't' } }
        Remove-VmfExpiredSafetyCopies -RunPath $script:rp -PlanPath $script:pp -AsOfUtc $script:later -Confirm:$false | Out-Null
        $line = Get-Content (Join-Path $script:rp 'logs' 'events.jsonl') -Raw
        $line | Should -Match 'The daily cleanup deleted the 2 safety copies'
        $line | Should -Not -Match 'retention \(scheduled\) deleted'
    }
    It 'SAFETY-3: takes its own lock off each copy BEFORE deleting it' {
        $script:order = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName VmMigrationFactory Unlock-VmfSnapshot { $script:order.Add("unlock:$SnapshotId") }
        Mock -ModuleName VmMigrationFactory Remove-VmfSnapshot { $script:order.Add("remove:$SnapshotId"); $global:RetGone[$SnapshotId] = $true }
        Remove-VmfExpiredSafetyCopies -RunPath $script:rp -PlanPath $script:pp -AsOfUtc $script:later -Confirm:$false | Out-Null
        $script:order.Count | Should -Be 4
        for ($k = 0; $k -lt 4; $k += 2) {
            $script:order[$k] | Should -Match '^unlock:' -Because 'the lock is the one thing that would refuse the delete'
            $script:order[$k + 1] | Should -Be ($script:order[$k] -replace '^unlock:', 'remove:')
        }
    }

    It 'WhatIf deletes NOTHING and leaves the record untouched' {
        Remove-VmfExpiredSafetyCopies -RunPath $script:rp -PlanPath $script:pp -AsOfUtc $script:later -WhatIf
        Should -Invoke Remove-VmfSnapshot -ModuleName VmMigrationFactory -Times 0 -Exactly
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; vm = $script:vm } {
            (Read-VmfStateDoc -RunPath $rp -VmId $vm).PSObject.Properties['retention'] | Should -BeNullOrEmpty
        }
    }

    It 'a restore after cleanup SAYS the copies were deleted, and why' {
        Remove-VmfExpiredSafetyCopies -RunPath $script:rp -PlanPath $script:pp -AsOfUtc $script:later -Confirm:$false | Out-Null
        { Restore-VmfVm -RunPath $script:rp -VmId $script:vm -From 'pristine' } |
            Should -Throw '*were deleted*7 days its wave was set to keep them*'
    }

    It 'the written document still conforms to the state contract' {
        Remove-VmfExpiredSafetyCopies -RunPath $script:rp -PlanPath $script:pp -AsOfUtc $script:later -Confirm:$false | Out-Null
        $docPath = Get-ChildItem (Join-Path $script:rp 'state') -Filter '*.json' | Select-Object -First 1
        $docPath | Should -Not -BeNullOrEmpty
        (Get-Content $docPath.FullName -Raw | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json')) | Should -BeTrue
    }

    It 'STEP-LOG-4: a line that cannot be written after one machine''s copies are deleted - the next machine''s copies are deleted too' {
        $vm2 = $script:vm -replace 'vm1$', 'vm2'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; vm = $vm2 } {
            New-VmfStateDoc -RunPath $rp -RunId 'ret' -VmId $vm -Wave 'first-five' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'MIGRATED' -Outcome ok | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $vm
            $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{
                    pristineSnapshotId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/snapshots/snap2-pristine'
                    snapshotId = $null; cloneVmId = $null }) -Force
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        @{ schemaVersion = 6; entries = @(@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vm; wave = 'first-five'; policy = @{ keepSnapshotDays = 7 } },
                                         @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $vm2; wave = 'first-five'; policy = @{ keepSnapshotDays = 7 } }) } |
            ConvertTo-Json -Depth 10 | Set-Content $script:pp -Encoding utf8NoBOM
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'retention' -and $Outcome -eq 'ok' } { throw 'The store did not answer.' }
        $r = Remove-VmfExpiredSafetyCopies -RunPath $script:rp -PlanPath $script:pp -AsOfUtc $script:later -Confirm:$false -WarningVariable w -WarningAction SilentlyContinue
        @($r.Deleted).Count | Should -Be 2 -Because 'a lost line for the first machine never stops the second'
        Should -Invoke Remove-VmfSnapshot -ModuleName VmMigrationFactory -Times 3 -Exactly
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; vm = $vm2 } { (Read-VmfStateDoc -RunPath $rp -VmId $vm).retention.deletedBy | Should -Be 'operator@contoso.com' }
        (@($w | ForEach-Object { [string]$_ }) -join ' ') | Should -BeLike "*'retention ok' for $script:vm could not be written*"
    }

    It 'STEP-LOG-4: the line for a machine whose copies are kept cannot be written - the cleanup goes on and returns' {
        @{ schemaVersion = 6; entries = @(@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vm; wave = 'first-five'; policy = @{ keepSnapshotDays = 'soon' } }) } |
            ConvertTo-Json -Depth 10 | Set-Content $script:pp -Encoding utf8NoBOM
        Mock -ModuleName VmMigrationFactory Get-VmfDueRollbackDisksBeforeMove { }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'retention' -and $Outcome -eq 'warn' } { throw 'The store did not answer.' }
        $r = Remove-VmfExpiredSafetyCopies -RunPath $script:rp -PlanPath $script:pp -AsOfUtc $script:later -Confirm:$false -WarningAction SilentlyContinue
        @($r.Skipped).Count | Should -Be 1
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfDueRollbackDisksBeforeMove -Times 1 -Exactly -Because 'the rollback disks are still looked at'
    }

    It 'STEP-LOG-4: the lines after the rollback disks are deleted cannot be written - the cleanup returns what it deleted' {
        @{ schemaVersion = 6; entries = @(@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vm; wave = 'first-five'; policy = @{ keepSnapshotDays = 90 } }) } |
            ConvertTo-Json -Depth 10 | Set-Content $script:pp -Encoding utf8NoBOM
        Mock -ModuleName VmMigrationFactory Get-VmfDueRollbackDisksBeforeMove { @([pscustomobject]@{ VmId = $script:vm; Disks = @('a', 'b') }) }
        Mock -ModuleName VmMigrationFactory Remove-VmfRollbackDisksBeforeMoveEntries { [pscustomobject]@{ Deleted = @('disk-a'); Failed = @([pscustomobject]@{ name = 'disk-b'; why = 'attached' }) } }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'retention' } { throw 'The store did not answer.' }
        $r = Remove-VmfExpiredSafetyCopies -RunPath $script:rp -PlanPath $script:pp -AsOfUtc $script:later -Confirm:$false -WarningAction SilentlyContinue
        @($r.RollbackDisksBeforeMoveDeleted).Count | Should -Be 1
        @($r.RollbackDisksBeforeMoveDeleted)[0].Disks | Should -Be @('disk-a')
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'retention' -and $Outcome -eq 'ok' } -Times 1 -Exactly
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'retention' -and $Outcome -eq 'warn' } -Times 1 -Exactly
    }
}
