#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# STEP-LOG-2: a run history line that cannot be written, outside one machine's
# move, never decides what the engine did.
#
# STEP-LOG-1 put every line written after a change inside one machine's move
# through Write-VmfStepLine. Outside the move, a line written after the store
# or Azure changed something still threw: the halt that was in force was
# reported as failed, an availability set lock stayed held, the removal of
# stale approvals stopped part way, the start of the next wave was reported as
# failed, a decision stopped after its plan was saved, and a delete of the
# safety copies stopped trying the copies after one. Each test below makes the
# one line fail and shows the work is done. The restores are tested beside
# their own tests (RestoreRebuild.Tests.ps1, RecoverShell.Tests.ps1).

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'steplog2'

    function Global:SlEntry([string]$Name, [string]$AvSet = '', [int]$Days = 7) {
        [pscustomobject]@{
            schemaVersion = (Get-VmfTestPlanEntryVersion)
            vmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-w/providers/Microsoft.Compute/virtualMachines/$Name"
            wave = 'w1'; ring = 'lab'; appGroup = $Name
            assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'
                sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; platformManaged = $false; availabilitySetId = $AvSet }
            target = [pscustomobject]@{ size = 'Standard_D2s_v6'; diskArch = 'diskless'; controller = 'NVMe' }
            path = 'A'
            policy = [pscustomobject]@{ capacityGate = 'BestEffort'; keepSnapshotDays = $Days }
        }
    }
}
AfterAll {
    Remove-Item 'function:\SlEntry' -ErrorAction SilentlyContinue
    Remove-VmfTestTemp
}

Describe 'STEP-LOG-2: a line that cannot be written, outside one machine''s move' {
    BeforeEach {
        $script:rp = Join-Path $script:temp "sl-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Initialize-VmfRun -RunPath $rp -RunId 'sl' | Out-Null }
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'the wave halt is in force and the list shows it, with no error, when its line cannot be written' {
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'wave' } { throw 'The store did not answer.' }
        Mock -ModuleName VmMigrationFactory Update-VmfRunSummary { $true }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } {
            { Set-VmfWaveHalt -RunPath $rp -Reason 'operator halt' -WarningAction SilentlyContinue } | Should -Not -Throw
            Test-VmfWaveHalted -RunPath $rp | Should -BeTrue
        }
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'wave' } -Times 1 -Exactly
        Should -Invoke -ModuleName VmMigrationFactory Update-VmfRunSummary -Times 1 -Exactly -Because 'the list on the Migrations page shows the pause'
    }

    It 'a machine another run holds: the availability set lock is given back when the claim line cannot be written' {
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'claim' } { throw 'The store did not answer.' }
        Mock -ModuleName VmMigrationFactory New-VmfVmClaim { [pscustomobject]@{ Granted = $false; Detail = 'Another run holds this machine.' } }
        $set = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/availabilitySets/as1'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; plan = [pscustomobject]@{ schemaVersion = 1; entries = @((SlEntry 'vm1' $set)) }; set = $set } {
            Get-VmfNextWaveVm -RunPath $rp -Plan $plan -Wave 'w1' -WorkerId 'w1' -WarningAction SilentlyContinue | Should -BeNullOrEmpty
            $lockId = 'group-avset/' + $set.Trim('/').ToLowerInvariant()
            Get-VmfLeaseInfo -RunPath $rp -VmId $lockId |
                Should -BeNullOrEmpty -Because 'a lock kept here stops every worker taking another machine of the set'
            # And the lock was taken, so the check above can fail.
            New-VmfLease -RunPath $rp -VmId $lockId -WorkerId 'w2' | Should -Not -BeNullOrEmpty
        }
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'claim' } -Times 1 -Exactly
    }

    It 'stale approvals: an approval that cannot be read and cannot be said does not stop the removal of the next' {
        [System.IO.File]::WriteAllText((Join-Path $script:rp 'plan.json'), ([pscustomobject]@{ schemaVersion = 1; entries = @((SlEntry 'vm1')) } | ConvertTo-Json -Depth 12), [System.Text.UTF8Encoding]::new($false))
        New-Item -ItemType Directory -Path (Join-Path $script:rp 'approvals') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $script:rp 'approvals' 'a-wave.json'), '{"wave":"a-wave"}', [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText((Join-Path $script:rp 'approvals' 'b-wave.json'), '', [System.Text.UTF8Encoding]::new($false))
        Mock -ModuleName VmMigrationFactory Read-VmfStoreText -ParameterFilter { $RelPath -ceq 'approvals/a-wave.json' } { throw 'Store read failed: HTTP 503' }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'approval' } { throw 'The store did not answer.' }
        $gone = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } {
            @(Remove-VmfStaleWaveApprovals -RunPath $rp -PlanPath (Join-Path $rp 'plan.json') -WarningAction SilentlyContinue)
        }
        @($gone) | Should -Be @('b-wave')
        Test-Path (Join-Path $script:rp 'approvals' 'b-wave.json') | Should -BeFalse
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'approval' } -Times 1 -Exactly
    }

    It 'the plan run: a wave the timer started is not reported as failed when its line cannot be written' {
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'planrun' } { throw 'The store did not answer.' }
        $r = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } {
            Set-VmfPlanRunStatus -RunPath $rp -Decision ([pscustomobject]@{ Reason = 'start'; Wave = 'w1'; Detail = 'wave w1 starts' }) -Execution 'exec-1' -WarningAction SilentlyContinue
            Write-VmfStepLine -RunPath $rp -Step 'planrun' -Outcome ok -Detail 'wave w1 starts' -WarningAction SilentlyContinue -WarningVariable lostLine
            $global:slLost = @($lostLine | ForEach-Object { [string]$_ })
        }
        ($global:slLost -join ' ') | Should -BeLike '*could not be written*The line said: wave w1 starts' -Because 'review: the line''s words are in the engine output'
        Remove-Variable slLost -Scope Global
        $r | Should -BeTrue
        $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Read-VmfStoreJson -RunPath $rp -RelPath 'plan-run.json' }
        $doc.execution | Should -Be 'exec-1'
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'planrun' } -Times 2 -Exactly
    }

    It 'the refusal for changed settings: a line that cannot be written does not replace the refusal, and is written at the next one' {
        $script:refusals = 0
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'acceptance' -and ++$script:refusals -eq 1 } { throw 'The store did not answer.' }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } {
            Write-VmfOptionsChangedRefusal -RunPath $rp -Wave 'w1' -Detail 'The settings of wave w1 changed.' -WarningAction SilentlyContinue |
                Should -BeFalse -Because 'review: it says whether the line was written'
        }
        $script:refusals | Should -Be 1
        $again = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } {
            Write-VmfOptionsChangedRefusal -RunPath $rp -Wave 'w1' -Detail 'The settings of wave w1 changed.'
        }
        $again | Should -BeTrue -Because 'the lost line is not in the run history, so the next refusal writes it'
        $lines = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { @(Read-VmfEvents -RunPath $rp -Step 'acceptance') }
        @($lines).Count | Should -Be 1
    }

    It 'a released claim: the history is kept and the caller goes on when the note cannot be written' {
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'capacity' } { throw 'The store did not answer.' }
        $claim = [pscustomobject]@{ schemaVersion = 8; runId = 'sl'; wave = 'w1'; subscriptionId = '00000000-0000-0000-0000-000000000000'
            region = 'centralus'; zone = $null; size = 'Standard_D4ds_v6'; vmFamily = 'StandardDdsv6Family'; state = 'RELEASED'
            reservation = [pscustomobject]@{ groupId = 'g'; reservationId = '/rg/crg/g1/capacityReservations/r1'; createdUtc = '2026-11-01T14:00:00Z'; releasedUtc = '2026-11-02T03:00:00Z' }
            associatedVmIds = @(); notes = @() }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; c = $claim } {
            { Write-VmfReleasedClaimNote -RunPath $rp -Claim $c -WarningAction SilentlyContinue } | Should -Not -Throw
            @(Get-VmfStoreNames -RunPath $rp -Folder 'capacity-history' -Extension '.json').Count | Should -Be 1
        }
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'capacity' } -Times 1 -Exactly
    }

    It 'a decision: the sign-off is carried and the decision goes on when its line cannot be written' {
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'decision' } { throw 'The store did not answer.' }
        $beforeText = [pscustomobject]@{ schemaVersion = 1; entries = @((SlEntry 'vm1' '' 7)) } | ConvertTo-Json -Depth 12
        $afterText = [pscustomobject]@{ schemaVersion = 1; entries = @((SlEntry 'vm1' '' 21)) } | ConvertTo-Json -Depth 12
        $r = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; bt = $beforeText; at = $afterText } {
            $before = Get-VmfDecisionSnapshot -Text $bt -Wave 'w1'
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan-approval.json' -Document ([ordered]@{ schemaVersion = 3; planHash = $before.PlanVersion; approvedBy = @{ identity = 'approver@example.com' } })
            # MIGRATIONS-PAGE-OLD-READERS-1: a v3 sign-off moves with the wave approval.
            Invoke-VmfDecisionCarryForward -RunPath $rp -PlanPath (Join-Path $rp 'plan.json') -Before $before -AfterText $at `
                -VmId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-w/providers/Microsoft.Compute/virtualMachines/vm1' `
                -Change 'keepSnapshotDays=21' -ResolvedBy 'approver@example.com' -CarryWaveApproval -WarningAction SilentlyContinue
        }
        $r.SignOff | Should -BeTrue
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'decision' } -Times 1 -Exactly
    }

    It 'the delete of the safety copies tries every copy when the line for one that failed cannot be written' {
        $one = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/snapshots/copy-1'
        $two = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/snapshots/copy-2'
        $script:gone = @{}
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { -not $script:gone.ContainsKey($SnapshotId) }
        Mock -ModuleName VmMigrationFactory Unlock-VmfSnapshot { if ($SnapshotId -like '*copy-1') { throw 'Azure refused the lock removal' } }
        Mock -ModuleName VmMigrationFactory Lock-VmfSnapshot { }
        Mock -ModuleName VmMigrationFactory Remove-VmfSnapshot { $script:gone[$SnapshotId] = $true }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'discardCopy' -and $Outcome -eq 'fail' } { throw 'The store did not answer.' }
        $r = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; ids = @($one, $two) } {
            Remove-VmfRunSafetyCopies -RunPath $rp -SnapshotIds $ids -ConfirmReads 1 -ConfirmDelaySec 0 -WarningAction SilentlyContinue
        }
        @($r.Failed | ForEach-Object Name) | Should -Be @('copy-1')
        @($r.Deleted) | Should -Be @($two)
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'discardCopy' -and $Outcome -eq 'fail' } -Times 1 -Exactly
    }

    It 'the line before a copy''s lock comes off stays a throwing write: when it cannot be written, the lock stays on' {
        $one = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/snapshots/copy-1'
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { $true }
        Mock -ModuleName VmMigrationFactory Unlock-VmfSnapshot { }
        Mock -ModuleName VmMigrationFactory Remove-VmfSnapshot { }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'discardCopy' -and $Outcome -eq 'info' } { throw 'The store did not answer.' }
        $r = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; ids = @($one) } {
            Remove-VmfRunSafetyCopies -RunPath $rp -SnapshotIds $ids -ConfirmReads 1 -ConfirmDelaySec 0
        }
        @($r.Failed | ForEach-Object Name) | Should -Be @('copy-1')
        Should -Invoke -ModuleName VmMigrationFactory Unlock-VmfSnapshot -Times 0 -Exactly
    }

    It 'review: a copy whose lock did not go back says so in the result, not only in a line that may be lost' {
        $one = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/snapshots/copy-1'
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { $true }
        Mock -ModuleName VmMigrationFactory Unlock-VmfSnapshot { }
        Mock -ModuleName VmMigrationFactory Remove-VmfSnapshot { throw 'Azure refused the delete' }
        Mock -ModuleName VmMigrationFactory Lock-VmfSnapshot { throw 'Azure refused the lock' }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'discardCopy' -and $Outcome -eq 'fail' } { throw 'The store did not answer.' }
        $r = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; ids = @($one) } {
            Remove-VmfRunSafetyCopies -RunPath $rp -SnapshotIds $ids -ConfirmReads 1 -ConfirmDelaySec 0 -WarningAction SilentlyContinue
        }
        @($r.Failed)[0].Reason | Should -BeLike '*Azure refused the delete*The copy has no lock. The product could not put the lock back*'
    }
}