#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
COUNT-TRUTH-1: one definition of what happened to a machine.

After a six-machine run with one machine put back, the Reports page showed
"Migrated 4", a wave table totalling 6, and "Restored 0" - three wrong numbers
with three causes. A machine put back keeps the state MIGRATED and gains a
`restore` marker, so every "is it MIGRATED" counted it as a success; a machine
LEFT OUT (SKIPPED) was counted as migrated too; and the run row read the
engine's feed for ONE wave as if it were the run.

Get-VmfMachineOutcome is the one definition. help.js has its twin, and both are
held to tests/fixtures/machine-outcomes.json.
#>
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:cases = (Get-Content (Join-Path $PSScriptRoot '..' 'fixtures' 'machine-outcomes.json') -Raw |
        ConvertFrom-Json).cases
}

Describe 'Get-VmfMachineOutcome' {
    It 'gives every shared case the outcome the dashboard gives' {
        @($script:cases).Count | Should -BeGreaterOrEqual 15 -Because 'the fixture loaded'
        foreach ($c in $script:cases) {
            $got = InModuleScope VmMigrationFactory -Parameters @{ d = $c.doc } { Get-VmfMachineOutcome -StateDoc $d }
            $got | Should -Be $c.outcome -Because $c.why
        }
    }

    It 'reads a hashtable the same way as a JSON object' {
        # The facade gets hashtables from Azure Functions (BODY-HASH-1).
        InModuleScope VmMigrationFactory {
            Get-VmfMachineOutcome -StateDoc @{ state = 'MIGRATED'; restore = @{ restoredUtc = 'x' } } | Should -Be 'putBack'
            Get-VmfMachineOutcome -StateDoc @{ state = 'MIGRATED' } | Should -Be 'migrated'
            # FINISH-COUNT-1: the swap record, as a hashtable and as the
            # ordered dictionary New-VmfSwapPendingRecord builds.
            Get-VmfMachineOutcome -StateDoc @{ state = 'MIGRATED'; restore = @{ restoredUtc = 'x' }; swapPending = @{ kind = 'restore'; swaps = @(@{ lun = 1 }) } } | Should -Be 'attention'
            Get-VmfMachineOutcome -StateDoc @{ state = 'MIGRATED'; swapPending = (New-VmfSwapPendingRecord -Kind 'restore' -Swaps @(@{ lun = 1 }) -Reason 'x') } | Should -Be 'attention'
            Get-VmfMachineOutcome -StateDoc @{ state = 'MIGRATED'; restore = @{ restoredUtc = 'x' }; swapPending = @{} } | Should -Be 'putBack'
            Get-VmfMachineOutcome -StateDoc @{ state = 'MIGRATED'; restore = @{ restoredUtc = 'x' }; swapPending = $null } | Should -Be 'putBack'
            Get-VmfMachineOutcome -StateDoc @{ state = 'CONVERTING'; swapPending = @{ kind = 'rollback'; swaps = @(@{ lun = 1 }) } } | Should -Be 'working'
        }
    }

    It 'counts every outcome, at zero when nothing has it' {
        $c = InModuleScope VmMigrationFactory { Get-VmfOutcomeCounts -StateDocs @() }
        @($c.PSObject.Properties.Name | Sort-Object) -join ',' |
            Should -Be 'attention,leftOut,migrated,notStarted,putBack,rolledBack,unknown,working'
        @($c.PSObject.Properties.Value | Where-Object { $_ -ne 0 }).Count | Should -Be 0
    }

    It 'counts a machine with no record as not started, not as nothing' {
        $c = InModuleScope VmMigrationFactory {
            Get-VmfOutcomeCounts -StateDocs @([pscustomobject]@{ state = 'MIGRATED' }, $null)
        }
        $c.migrated | Should -Be 1
        $c.notStarted | Should -Be 1
    }
}

Describe 'the run summary the Reports page reads' {
    BeforeEach {
        $script:storeRoot = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-outcome-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:runPath = Join-Path $script:storeRoot 'run-a'
        # A lab run, 2026-09-23: six machines in three waves, one put back.
        $vms = @(
            @{ n = 'a'; w = 'w1' }, @{ n = 'b'; w = 'w1' }, @{ n = 'c'; w = 'w2' },
            @{ n = 'd'; w = 'w2' }, @{ n = 'e'; w = 'w3' }, @{ n = 'f'; w = 'w3' })
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; vms = $vms } {
            Initialize-VmfRun -RunPath $rp -RunId 'run-a' | Out-Null
            foreach ($v in $vms) {
                $id = "/s/rg/vm/$($v.n)"
                New-VmfStateDoc -RunPath $rp -RunId 'run-a' -VmId $id -Wave $v.w | Out-Null
                Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'MIGRATED' -Outcome ok | Out-Null
            }
            # A put-back is exactly this: MIGRATED stays, `restore` arrives.
            $doc = Read-VmfStateDoc -RunPath $rp -VmId '/s/rg/vm/d'
            # STATUS-WORDS-1: after the move it restores - a restore older than
            # the migration it undoes would be a migration after a restore.
            $doc | Add-Member -NotePropertyName restore -NotePropertyValue ([pscustomobject]@{
                restoredUtc = (Get-Date).ToUniversalTime().AddMinutes(5).ToString('o'); restoredBy = 'operator@example.com' }) -Force
            Write-VmfStateDoc -RunPath $rp -Document $doc | Out-Null
        }
        # So the summary's wave feed says what the engine's does: only the LAST
        # wave, two machines - the "Migrated 2" the summary showed.
        @{ schemaVersion = 1; assessmentRunId = 'run-a'; entries = @($vms | ForEach-Object {
            @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "/s/rg/vm/$($_.n)"; wave = $_.w; ring = 'r'; path = 'A'; assessment = @{}; target = @{ size = 's' } } })
        } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $script:runPath 'plan.json')
    }
    AfterEach { if (Test-Path $script:storeRoot) { Remove-Item $script:storeRoot -Recurse -Force } }

    It 'counts the whole run by outcome: 5 migrated, 1 put back' {
        $s = Get-VmfFacadeRunSummary -StorePath $script:runPath
        $s.total | Should -Be 6
        $s.outcomes.migrated | Should -Be 5 -Because 'not 6, and not the last wave alone'
        $s.outcomes.putBack | Should -Be 1
        $s.outcomes.rolledBack | Should -Be 0 -Because 'a put-back a person chose is not the engine rolling back'
    }

    It 'and each wave by the same definition' {
        $s = Get-VmfFacadeRunSummary -StorePath $script:runPath
        $w2 = @($s.waves) | Where-Object wave -EQ 'w2'
        $w2.outcomes.migrated | Should -Be 1
        $w2.outcomes.putBack | Should -Be 1
        $w2.stateCounts.MIGRATED | Should -Be 2 -Because 'the state is unchanged - which is why states are not outcomes'
    }

    It 'FINISH-COUNT-1: counts a machine a restore left stopped as waiting for a person, not as put back' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Set-VmfSwapPending -RunPath $rp -VmId '/s/rg/vm/d' -Record (New-VmfSwapPendingRecord -Kind 'restore' -Reason 'refused' `
                -Swaps @([ordered]@{ lun = 1; name = 'd-d1'; diskId = '/s/rg/disks/d-d1-r'; diskName = 'd-d1-r' }))
        }
        $s = Get-VmfFacadeRunSummary -StorePath $script:runPath
        $s.outcomes.putBack | Should -Be 0
        $s.outcomes.attention | Should -Be 1
        $s.outcomes.migrated | Should -Be 5
        ((@($s.waves) | Where-Object wave -EQ 'w2').outcomes.attention) | Should -Be 1
    }

    It 'counts a planned machine with no record as not started' {
        $plan = Get-Content (Join-Path $script:runPath 'plan.json') -Raw | ConvertFrom-Json
        $plan.entries += [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/s/rg/vm/g'; wave = 'w4'; ring = 'r'; path = 'A'; assessment = @{}; target = @{ size = 's' } }
        $plan | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $script:runPath 'plan.json')
        $s = Get-VmfFacadeRunSummary -StorePath $script:runPath
        $s.total | Should -Be 7
        $s.outcomes.notStarted | Should -Be 1
    }

    # LAB-UX-1: a migration of one machine read "In progress: 1 rolled back,
    # 3 not started" on the Reports page. The three were the assessment's
    # machines given no target: in the plan as MANUAL, never moved, never given
    # a state. A machine the plan does not move has no outcome to count.
    It 'does not count a machine the plan does not move as not started' {
        $plan = Get-Content (Join-Path $script:runPath 'plan.json') -Raw | ConvertFrom-Json
        foreach ($n in 'x', 'y', 'z') {
            $plan.entries += [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "/s/rg/vm/$n"; wave = 'unscheduled'; ring = 'r'; path = 'MANUAL'; assessment = @{}; target = @{} }
        }
        $plan.entries += [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/s/rg/vm/e2'; wave = 'w3'; ring = 'r'; path = 'EXCLUDED'; assessment = @{}; target = @{} }
        $plan | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $script:runPath 'plan.json')
        $s = Get-VmfFacadeRunSummary -StorePath $script:runPath
        $s.outcomes.notStarted | Should -Be 0 -Because 'none of the four is moved, so none of them waits to start'
        $s.outcomes.migrated | Should -Be 5
        $s.outcomes.putBack | Should -Be 1
        ((@($s.waves) | Where-Object wave -EQ 'unscheduled').outcomes.notStarted) | Should -Be 0
        ((@($s.waves) | Where-Object wave -EQ 'w3').outcomes.notStarted) | Should -Be 0 -Because 'an EXCLUDED machine in a real wave is not counted either'
        $s.total | Should -Be 10 -Because 'the plan still holds them, and the total says what the plan holds'
    }
}

Describe 'the customer report' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-outrpt-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path (Join-Path $script:runPath 'state') -Force | Out-Null
        @{ schemaVersion = 9; kind = 'migration'; runId = 'r1'; createdUtc = '2026-09-23T19:00:00Z' } | ConvertTo-Json | Set-Content (Join-Path $script:runPath 'run.json')
        @{ schemaVersion = 1; generatedUtc = 'x'; assessmentRunId = 'r1'
           entries = @(
               @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/s/rg/vm/kept'; wave = 'w1'; path = 'A'; assessment = @{ sourceSize = 'Standard_D2s_v4' }; target = @{ size = 'Standard_D2s_v6' }; planNotes = @() },
               @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/s/rg/vm/returned'; wave = 'w1'; path = 'A'; assessment = @{ sourceSize = 'Standard_D2s_v4' }; target = @{ size = 'Standard_D2s_v6' }; planNotes = @() })
        } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:runPath 'plan.json')
        foreach ($n in 'kept', 'returned') {
            $doc = @{ schemaVersion = (Get-VmfTestStateVersion); runId = 'r1'; vmId = "/s/rg/vm/$n"; state = 'MIGRATED'; guestExecutions = @()
                      history = @(@{ tsUtc = '2026-09-23T20:00:00Z'; state = 'PRECHECK'; outcome = 'ok' },
                                  @{ tsUtc = '2026-09-23T20:20:00Z'; state = 'MIGRATED'; outcome = 'ok' }) }
            if ($n -eq 'returned') {
                $doc.restore = @{ restoredUtc = '2026-09-23T22:00:00Z'; restoredBy = 'operator@example.com'
                                  note = '<script>alert(1)</script>'; sizeAfter = 'Standard_D2s_v4' }
            }
            $doc | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:runPath 'state' "$n.json")
        }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'does not count a machine put back as migrated, or show it as verified' {
        $html = Get-Content (New-VmfReport -OutPath $script:runPath) -Raw
        # VERIFY-FP-1 part 3b: the Results section of the chosen report.
        $html | Should -Match '<b>1</b><span>Migrated</span>'
        $html | Should -Match '<b>1</b><span>Restored</span>'
        $machines = [regex]::Match($html, '(?s)3</span> Machines.*?</section>').Value
        [regex]::Match($machines, '(?s)kept</div>.*?</tr>').Value | Should -Match 'Migrated</span>'
        [regex]::Match($machines, '(?s)returned</div>.*?</tr>').Value | Should -Match 'Restored</span>' -Because 'it is not on the hardware the move put it on'
    }

    It 'lists the put-back with who, when, why and the size it runs on now - escaped' {
        $html = Get-Content (New-VmfReport -OutPath $script:runPath) -Raw
        $exceptions = [regex]::Match($html, '(?s)4</span> Exceptions.*?</section>').Value
        $exceptions | Should -Match 'returned</td><td><span class="pill quiet">Restored</span>'
        $exceptions | Should -Match 'operator@example\.com'
        $exceptions | Should -Match '23 Sep 2026 22:00'
        [regex]::Match($html, '(?s)returned</div>.*?</tr>').Value | Should -Match '>D2s_v4<' -Because 'the size it runs on now'
        $html | Should -Not -Match '<script>alert' -Because 'a note is typed by a person'
        $html | Should -Match '&lt;script&gt;alert'
    }
}
