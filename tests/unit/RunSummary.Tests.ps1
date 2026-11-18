#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
APPROVE-GROUP-1: the summary of the WHOLE migration, in run-status.json.

WHAT WAS WRONG. run-status.json was a snapshot of the wave that was running,
written only by Start-VmfWave. A migration waiting for a person to approve a
wave had no document, so the list on the Migrations page called it Planned. One
whose wave 1 finished and whose wave 2 waited counted wave 1 only - every
machine MIGRATED - and the list called it Completed.

The rule now: the engine keeps a summary of the whole migration - every wave,
and what the next wave waits for - written by ONE compare-and-swap writer at
every change the list shows, and the action that triggers it never fails
because of it.
#>
BeforeAll {
    $script:repo = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repo 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:schema = Join-Path $script:repo 'schemas' 'run-status.schema.json'
    $script:vm = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/'
    # Two waves of two, in plan order w1 then w2 - the reverse of the alphabet
    # in the machine names, so an order taken from the machines would be wrong.
    $script:NewPlan = {
        [pscustomobject]@{
            schemaVersion = 16; assessmentRunId = 'r1'; waveOrder = @('w1', 'w2')
            entries = @(
                foreach ($pair in @(@('w2', 'a'), @('w2', 'b'), @('w1', 'y'), @('w1', 'z'))) {
                    [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$($script:vm)$($pair[1])"; wave = $pair[0]; path = 'A'
                                       policy = [pscustomobject]@{ requireApproval = $true; throttle = 5 } }
                }
                [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$($script:vm)manual"; wave = 'w1'; path = 'MANUAL'; policy = [pscustomobject]@{} }
            )
        }
    }
    $script:NewRun = {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rsum-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { Initialize-VmfRun -RunPath $rp -RunId 'rsum' | Out-Null }
        (& $script:NewPlan) | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $rp 'plan.json') -Encoding utf8NoBOM
        $rp
    }
    $script:Status = { param($rp) Get-Content (Join-Path $rp 'run-status.json') -Raw | ConvertFrom-Json -Depth 24 }
    $script:SetState = { param($rp, $name, $state)
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = "$($script:vm)$name"; s = $state } {
            if (-not (Read-VmfStateDoc -RunPath $rp -VmId $id)) { New-VmfStateDoc -RunPath $rp -RunId 'rsum' -VmId $id | Out-Null }
            Add-VmfStateTransition -RunPath $rp -VmId $id -NewState $s -Outcome ok | Out-Null
        }
    }
    $script:Who = @{ Identity = 'approver@example.com'; TenantId = $null }
}

Describe 'APPROVE-GROUP-1: the summary, as pure logic' {
    BeforeAll {
        $script:Sum = { param([hashtable]$States, $Gate = $null, [bool]$Halted = $false)
            InModuleScope VmMigrationFactory -Parameters @{ p = (& $script:NewPlan); s = $States; g = $Gate; h = $Halted } {
                $gateOf = { param($w) $g }
                Get-VmfRunSummary -Plan $p -States $s -GateOf $gateOf -Reason 'planSaved' -Halted $h
            }
        }
        $script:Done = { param([string[]]$Names) $h = @{}; foreach ($n in $Names) { $h["$($script:vm)$n"] = 'MIGRATED' }; $h }
    }

    It 'lists the waves in the order they run, with the machines the plan moves' {
        $s = & $script:Sum @{}
        @($s.waves | ForEach-Object { $_.wave }) -join ',' | Should -Be 'w1,w2' -Because 'waveOrder decides, not the machine names'
        $s.machines | Should -Be 4 -Because 'a MANUAL machine is not moved'
        $s.stateCounts['PLANNED'] | Should -Be 4
        $s.next.wave | Should -Be 'w1'
    }

    It 'THE REGRESSION: wave 1 finished, wave 2 waits for approval - the counts are the whole migration' {
        $s = & $script:Sum (& $script:Done 'y', 'z') 'approval'
        $s.stateCounts['MIGRATED'] | Should -Be 2
        $s.stateCounts['PLANNED'] | Should -Be 2 -Because 'wave 2 has not run, and the counts say so'
        $s.next.wave | Should -Be 'w2'
        $s.next.waitsFor | Should -Be 'approval'
    }

    It 'names each gate the next wave waits for, and start when there is none' {
        foreach ($gate in 'acknowledgement', 'acceptance', 'approval', 'unknown') {
            (& $script:Sum @{} $gate).next.waitsFor | Should -Be $gate
        }
        (& $script:Sum @{} $null).next.waitsFor | Should -Be 'start'
    }

    It 'a machine on its way is running, whatever the gates say' {
        $st = & $script:Done 'y'; $st["$($script:vm)z"] = 'CONVERTING'
        $s = & $script:Sum $st 'approval'
        $s.next.waitsFor | Should -Be 'running'
        $s.next.wave | Should -Be 'w1'
    }

    It 'a machine waiting for a person holds the run before any gate' {
        foreach ($held in 'NEEDS_DECISION', 'FAILED_NEEDS_ATTENTION') {
            $st = & $script:Done 'y'; $st["$($script:vm)z"] = $held
            (& $script:Sum $st 'approval').next.waitsFor | Should -Be 'decision'
        }
    }

    It 'every wave run is none, with no next wave' {
        $s = & $script:Sum (& $script:Done 'y', 'z', 'a', 'b') 'approval'
        $s.next.waitsFor | Should -Be 'none'
        $s.next.wave | Should -BeNullOrEmpty
    }

    It 'records the pause' {
        (& $script:Sum @{} $null $true).halted | Should -BeTrue
        (& $script:Sum @{} $null $false).halted | Should -BeFalse
    }

    It 'the wave''s ten-second write changes its own wave only, and says running' {
        $patched = InModuleScope VmMigrationFactory -Parameters @{ p = (& $script:NewPlan) } {
            $full = Get-VmfRunSummary -Plan $p -States @{} -GateOf { param($w) $null } -Reason 'planSaved'
            $stored = $full | ConvertTo-Json -Depth 12 | ConvertFrom-Json -Depth 12
            Update-VmfRunSummaryWave -Summary $stored -Wave 'w2' -Counts @{ CONVERTING = 1; MIGRATED = 1 } -Reason 'waveRunning'
        }
        $patched.next.waitsFor | Should -Be 'running'
        $patched.next.wave | Should -Be 'w2'
        ($patched.waves | Where-Object { $_.wave -eq 'w1' }).stateCounts['PLANNED'] | Should -Be 2 -Because 'wave 1 is untouched'
        $patched.stateCounts['CONVERTING'] | Should -Be 1
        $patched.stateCounts['PLANNED'] | Should -Be 2
        $patched.machines | Should -Be 4
    }

    It 'a stored summary that cannot be patched is refused, so the caller reads the store' {
        InModuleScope VmMigrationFactory {
            Update-VmfRunSummaryWave -Summary $null -Wave 'w1' -Counts @{} -Reason 'waveRunning' | Should -BeNullOrEmpty
            $other = [pscustomobject]@{ waves = @([pscustomobject]@{ wave = 'w9'; machines = 1; stateCounts = @{} }); next = [pscustomobject]@{ waitsFor = 'start' }; stateCounts = @{} }
            Update-VmfRunSummaryWave -Summary $other -Wave 'w1' -Counts @{} -Reason 'waveRunning' | Should -BeNullOrEmpty
        }
    }
}

Describe 'APPROVE-GROUP-1: every action the list shows writes the summary' {
    BeforeEach { $script:rp = & $script:NewRun; $script:pp = Join-Path $script:rp 'plan.json' }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'walks the gates of a fresh migration in the engine''s order, one action at a time' {
        Confirm-VmfRunAcknowledgement -RunPath $script:rp -AcknowledgedBy 'operator@example.com' -Confirm:$false | Out-Null
        (& $script:Status $script:rp).summary.next.waitsFor | Should -Be 'acceptance' -Because 'the note is accepted; the settings are not'
        (& $script:Status $script:rp).summary.reason | Should -Be 'acknowledged'

        Confirm-VmfWaveOptions -RunPath $script:rp -PlanPath $script:pp -Wave 'w1' -AcceptedBy 'operator@example.com' -Confirm:$false | Out-Null
        (& $script:Status $script:rp).summary.next.waitsFor | Should -Be 'approval'

        Approve-VmfWave -RunPath $script:rp -PlanPath $script:pp -Wave 'w1' -Note 'reviewed' -OnBehalfOf $script:Who | Out-Null
        $s = & $script:Status $script:rp
        $s.summary.next.waitsFor | Should -Be 'start'
        $s.summary.reason | Should -Be 'waveApproved'
        Get-Content (Join-Path $script:rp 'run-status.json') -Raw | Test-Json -SchemaFile $script:schema | Should -BeTrue
    }

    It 'with nothing accepted, the first gate is the note about machines defined in code' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Update-VmfRunSummary -RunPath $rp -Reason 'planSaved' } | Should -BeTrue
        (& $script:Status $script:rp).summary.next.waitsFor | Should -Be 'acknowledgement'
    }

    It 'the plan sign-off passes the approval gate' {
        Confirm-VmfRunAcknowledgement -RunPath $script:rp -AcknowledgedBy 'operator@example.com' -Confirm:$false | Out-Null
        Confirm-VmfWaveOptions -RunPath $script:rp -PlanPath $script:pp -Wave 'w1' -AcceptedBy 'operator@example.com' -Confirm:$false | Out-Null
        Approve-VmfPlan -RunPath $script:rp -PlanPath $script:pp -Note 'reviewed' -OnBehalfOf $script:Who | Out-Null
        $s = & $script:Status $script:rp
        $s.summary.next.waitsFor | Should -Be 'start'
        $s.summary.reason | Should -Be 'planSignedOff'
    }

    It 'when a wave ends, the summary says what the NEXT wave waits for' {
        Confirm-VmfRunAcknowledgement -RunPath $script:rp -AcknowledgedBy 'operator@example.com' -Confirm:$false | Out-Null
        foreach ($n in 'y', 'z') { & $script:SetState $script:rp $n 'MIGRATED' }
        $plan = & $script:NewPlan
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; p = $plan; pp = $script:pp } {
            Write-VmfRunStatus -RunPath $rp -Plan $p -Wave 'w1' -RunId 'rsum' -ThrottleLimit 2 -PlanPath $pp -WaveEnded | Out-Null
        }
        $s = & $script:Status $script:rp
        $s.wave | Should -Be 'w1'
        $s.stateCounts.MIGRATED | Should -Be 2 -Because 'the live counts are still the wave that ran'
        $s.summary.reason | Should -Be 'waveEnded'
        $s.summary.next.wave | Should -Be 'w2'
        $s.summary.next.waitsFor | Should -Be 'acceptance'
        $s.summary.stateCounts.PLANNED | Should -Be 2
        Get-Content (Join-Path $script:rp 'run-status.json') -Raw | Test-Json -SchemaFile $script:schema | Should -BeTrue
    }

    It 'while a wave runs, its write says running and keeps the other waves' {
        & $script:SetState $script:rp 'y' 'CONVERTING'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Update-VmfRunSummary -RunPath $rp -Reason 'planSaved' | Out-Null }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; p = (& $script:NewPlan); pp = $script:pp } {
            Write-VmfRunStatus -RunPath $rp -Plan $p -Wave 'w1' -RunId 'rsum' -ThrottleLimit 2 -PlanPath $pp | Out-Null
        }
        $s = & $script:Status $script:rp
        $s.summary.reason | Should -Be 'waveRunning'
        $s.summary.next.waitsFor | Should -Be 'running'
        ($s.summary.waves | Where-Object wave -eq 'w2').stateCounts.PLANNED | Should -Be 2
    }

    It 'leaving a machine out, a decision and a stop each write it' {
        & $script:SetState $script:rp 'y' 'NEEDS_DECISION'
        Skip-VmfVm -RunPath $script:rp -VmId "$($script:vm)z" -Reason 'not needed' -SkippedBy 'operator@example.com' -Confirm:$false | Out-Null
        $s = & $script:Status $script:rp
        $s.summary.reason | Should -Be 'machineSkipped'
        $s.summary.stateCounts.SKIPPED | Should -Be 1
        $s.summary.next.waitsFor | Should -Be 'decision'

        Stop-VmfRun -RunPath $script:rp -Reason 'done here' -StoppedBy 'operator@example.com' -Force -Confirm:$false | Out-Null
        $s = & $script:Status $script:rp
        $s.summary.reason | Should -Be 'runStopped'
        $s.summary.halted | Should -BeTrue -Because 'a stopped migration is paused, and the list says Other'
    }

    It 'a run with no plan is left alone - no document, and no warning' {
        Remove-Item $script:pp
        Confirm-VmfRunAcknowledgement -RunPath $script:rp -AcknowledgedBy 'operator@example.com' -Confirm:$false | Out-Null
        Test-Path (Join-Path $script:rp 'run-status.json') | Should -BeFalse
        Get-Content (Join-Path $script:rp 'logs' 'events.jsonl') -Raw | Should -Not -Match '"step":\s*"status"'
    }
}

Describe 'APPROVE-GROUP-1: the one writer' {
    BeforeEach { $script:rp = & $script:NewRun; $script:pp = Join-Path $script:rp 'plan.json' }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'a summary write keeps the live fields of the wave that ran last, and their time' {
        $v2 = [ordered]@{ schemaVersion = 2; runId = 'rsum'; wave = 'w1'; updatedUtc = '2026-10-01T10:00:00.0000000Z'
                          stateCounts = @{ MIGRATED = 2 }; running = @(); breaker = @{ halted = $false; consecutiveFailures = 0; recentFailureRate = 0 }
                          throttle = @{ limit = 7; containers = 1; recent429s = 0 }; etaUtc = $null }
        $v2 | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:rp 'run-status.json') -Encoding utf8NoBOM
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Update-VmfRunSummary -RunPath $rp -Reason 'dailyCheck' } | Should -BeTrue
        $s = & $script:Status $script:rp
        $s.schemaVersion | Should -Be 8
        $s.throttle.limit | Should -Be 7 -Because 'the resume watchdog restarts a wave with this'
        $s.stateCounts.MIGRATED | Should -Be 2
        ([datetime]$s.updatedUtc).ToUniversalTime().ToString('o') | Should -Be '2026-10-01T10:00:00.0000000Z' -Because 'a summary is not wave activity - the list would call it In progress'
        Get-Content (Join-Path $script:rp 'run-status.json') -Raw | Test-Json -SchemaFile $script:schema | Should -BeTrue
    }

    It 'a summary-only document has no wave time, and validates' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Update-VmfRunSummary -RunPath $rp -Reason 'planSaved' | Out-Null }
        $s = & $script:Status $script:rp
        $s.PSObject.Properties['updatedUtc'] | Should -BeNullOrEmpty
        Get-Content (Join-Path $script:rp 'run-status.json') -Raw | Test-Json -SchemaFile $script:schema | Should -BeTrue
    }

    It 'writes nothing when the summary would not change - the daily check touches nothing current' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Update-VmfRunSummary -RunPath $rp -Reason 'planSaved' | Out-Null }
        $before = Get-Content (Join-Path $script:rp 'run-status.json') -Raw
        Start-Sleep -Milliseconds 20
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Update-VmfRunSummary -RunPath $rp -Reason 'dailyCheck' } | Should -BeTrue
        Get-Content (Join-Path $script:rp 'run-status.json') -Raw | Should -BeExactly $before
        & $script:SetState $script:rp 'y' 'MIGRATED'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Update-VmfRunSummary -RunPath $rp -Reason 'dailyCheck' | Out-Null }
        (& $script:Status $script:rp).summary.stateCounts.MIGRATED | Should -Be 1 -Because 'a change no trigger caught is written'
    }

    It 'a write somebody else made in between is read again and built again, never overwritten' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Update-VmfRunSummary -RunPath $rp -Reason 'planSaved' | Out-Null }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } {
            $script:raced = 0
            $script:builds = 0
            Mock Get-VmfRunSummaryFromStore { $script:builds++; [ordered]@{ writtenUtc = (Get-Date).ToUniversalTime().ToString('o'); reason = 'waveApproved'; halted = $false
                machines = 4; stateCounts = [ordered]@{ PLANNED = 4 }; waves = @(); next = [ordered]@{ wave = 'w1'; waitsFor = "start$($script:builds)" } } }
            Mock Write-VmfTextDocumentIfVersion {
                $script:raced++
                if ($script:raced -eq 1) { throw '409: Somebody changed the plan at the same time, so the product did not save this change.' }
                Set-Content -LiteralPath $Path -Value $Content -NoNewline -Encoding utf8NoBOM
            }
            Mock Start-Sleep { }
            $doc = Write-VmfRunStatusDocument -RunPath $rp -PlanPath (Join-Path $rp 'plan.json') -Reason 'waveApproved'
            $script:raced | Should -Be 2
            $script:builds | Should -Be 2 -Because 'the summary is built again from the store after the conflict, not re-sent'
            $doc.summary.next.waitsFor | Should -Be 'start2'
        }
    }

    It 'gives up after its attempts with a 409, which the action never sees' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Update-VmfRunSummary -RunPath $rp -Reason 'planSaved' | Out-Null }
        # A change, so there is something to write.
        & $script:SetState $script:rp 'y' 'MIGRATED'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } {
            Mock Write-VmfTextDocumentIfVersion { throw '409: changed' }
            Mock Start-Sleep { }
            { Write-VmfRunStatusDocument -RunPath $rp -PlanPath (Join-Path $rp 'plan.json') -Reason 'dailyCheck' -Attempts 3 } | Should -Throw '409:*'
        }
    }

    It 'two first writers: one creates the document, the other reads it and builds again' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } {
            $script:creates = 0
            Mock Write-VmfStoreJsonExclusive {
                $script:creates++
                if ($script:creates -eq 1) {
                    # Another writer got there first.
                    '{"schemaVersion":2,"runId":"rsum","wave":"w1","updatedUtc":"2026-10-01T10:00:00Z","stateCounts":{"PLANNED":2},"throttle":{"limit":5}}' |
                        Set-Content (Join-Path $RunPath 'run-status.json') -NoNewline -Encoding utf8NoBOM
                    return $false
                }
                $true
            }
            $doc = Write-VmfRunStatusDocument -RunPath $rp -PlanPath (Join-Path $rp 'plan.json') -Reason 'planSaved'
            $doc.throttle.limit | Should -Be 5 -Because 'the second build kept what the first writer wrote'
            $doc.schemaVersion | Should -Be 8
        }
    }
}

Describe 'APPROVE-GROUP-1: what a write costs - only what changed is read' {
    # A state document changed BEHIND the summary's back is the probe: a write
    # that reads it shows the change, a write that does not keeps the old count.
    BeforeEach {
        $script:rp = & $script:NewRun; $script:pp = Join-Path $script:rp 'plan.json'
        foreach ($n in 'y', 'z') { & $script:SetState $script:rp $n 'MIGRATED' }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Update-VmfRunSummary -RunPath $rp -Reason 'dailyCheck' | Out-Null }
        $script:Behind = { param($name, $state)
            $file = InModuleScope VmMigrationFactory -Parameters @{ id = "$($script:vm)$name" } { (Get-VmfVmKey -VmId $id) + '.json' }
            $docPath = Join-Path $script:rp 'state' $file
            $doc = Get-Content $docPath -Raw | ConvertFrom-Json -Depth 24
            $doc.state = $state
            $doc | ConvertTo-Json -Depth 24 | Set-Content $docPath -Encoding utf8NoBOM
        }
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'a gate passed reads no machine of a settled, unchanged wave' {
        & $script:Behind 'y' 'FAILED_NEEDS_ATTENTION'
        Confirm-VmfRunAcknowledgement -RunPath $script:rp -AcknowledgedBy 'operator@example.com' -Confirm:$false | Out-Null
        $s = & $script:Status $script:rp
        $s.summary.reason | Should -Be 'acknowledged'
        $s.summary.next.waitsFor | Should -Be 'acceptance'
        $s.summary.stateCounts.MIGRATED | Should -Be 2 -Because 'wave 1 kept its counts - none of its machines was read'
        ($s.summary.waves | Where-Object wave -eq 'w1').members | Should -Match '^[0-9a-f]{64}$'
    }

    It 'the daily check reads every machine, and finds what nothing reported' {
        & $script:Behind 'y' 'FAILED_NEEDS_ATTENTION'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Update-VmfRunSummary -RunPath $rp -Reason 'dailyCheck' | Out-Null }
        (& $script:Status $script:rp).summary.stateCounts.FAILED_NEEDS_ATTENTION | Should -Be 1
    }

    It 'a change to one wave reads that wave again' {
        & $script:Behind 'y' 'FAILED_NEEDS_ATTENTION'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Update-VmfRunSummary -RunPath $rp -Reason 'decision' -Wave 'w1' | Out-Null }
        (& $script:Status $script:rp).summary.stateCounts.FAILED_NEEDS_ATTENTION | Should -Be 1
    }

    It 'a wave whose machines changed is read again, even for a plan save' {
        & $script:Behind 'y' 'FAILED_NEEDS_ATTENTION'
        $plan = Get-Content $script:pp -Raw | ConvertFrom-Json -Depth 24
        ($plan.entries | Where-Object { $_.vmId -like '*/a' }).wave = 'w1'
        $plan | ConvertTo-Json -Depth 24 | Set-Content $script:pp -Encoding utf8NoBOM
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Update-VmfRunSummary -RunPath $rp -Reason 'planSaved' | Out-Null }
        $s = & $script:Status $script:rp
        ($s.summary.waves | Where-Object wave -eq 'w1').machines | Should -Be 3
        $s.summary.stateCounts.FAILED_NEEDS_ATTENTION | Should -Be 1 -Because 'wave 1 holds other machines now, so its counts were read again'
    }

    It 'a wave with a machine on its way is always read again' {
        & $script:SetState $script:rp 'a' 'CONVERTING'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Update-VmfRunSummary -RunPath $rp -Reason 'dailyCheck' | Out-Null }
        & $script:Behind 'a' 'MIGRATED'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Update-VmfRunSummary -RunPath $rp -Reason 'planSaved' | Out-Null }
        $s = & $script:Status $script:rp
        $s.summary.stateCounts.PSObject.Properties['CONVERTING'] | Should -BeNullOrEmpty
        $s.summary.stateCounts.MIGRATED | Should -Be 3
    }

    It 'the wave''s ten-second write keeps the fingerprint of every wave' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; p = (& $script:NewPlan); pp = $script:pp } {
            Write-VmfRunStatus -RunPath $rp -Plan $p -Wave 'w2' -RunId 'rsum' -ThrottleLimit 2 -PlanPath $pp | Out-Null
        }
        $s = & $script:Status $script:rp
        @($s.summary.waves | Where-Object { $_.members -match '^[0-9a-f]{64}$' }).Count | Should -Be 2
        Get-Content (Join-Path $script:rp 'run-status.json') -Raw | Test-Json -SchemaFile $script:schema | Should -BeTrue
    }
}

Describe 'APPROVE-GROUP-1: the independent review''s findings' {
    BeforeEach { $script:rp = & $script:NewRun; $script:pp = Join-Path $script:rp 'plan.json' }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'F1: a machine a decision re-armed, with no worker on it, waits for the gate its wave fails - not running for ever' {
        & $script:SetState $script:rp 'y' 'MIGRATED'
        & $script:SetState $script:rp 'z' 'PRECHECK'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Update-VmfRunSummary -RunPath $rp -Reason 'decision' -Wave 'w1' | Out-Null }
        $s = & $script:Status $script:rp
        $s.summary.next.wave | Should -Be 'w1'
        $s.summary.next.waitsFor | Should -Be 'acknowledgement' -Because 'the watchdog restarts the wave only once its gates pass'
        # With a worker holding a machine, it is running.
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = "$($script:vm)z" } {
            New-VmfLease -RunPath $rp -VmId $id -WorkerId 'worker-1' | Out-Null
            Update-VmfRunSummary -RunPath $rp -Reason 'dailyCheck' | Out-Null
        }
        (& $script:Status $script:rp).summary.next.waitsFor | Should -Be 'running'
    }

    It 'F1: with its gates passed, a re-armed wave with no worker is running - the watchdog starts it' {
        $s = InModuleScope VmMigrationFactory -Parameters @{ p = (& $script:NewPlan); vm = $script:vm } {
            Get-VmfRunSummary -Plan $p -States @{ "${vm}z" = 'PRECHECK' } -GateOf { param($w) $null } -Reason 'decision' -Leased $false
        }
        $s.next.waitsFor | Should -Be 'running'
    }

    It 'F2: a conflict with the wave''s own write keeps the costly summary, with that wave''s counts from the newer write' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Update-VmfRunSummary -RunPath $rp -Reason 'dailyCheck' | Out-Null }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } {
            $script:fixed = Get-VmfRunSummaryFromStore -RunPath $rp -PlanPath (Join-Path $rp 'plan.json') -Reason 'waveApproved'
            $script:fixed.next.waitsFor = 'approval'
            $script:builds = 0
            $script:writes = 0
            Mock Get-VmfRunSummaryFromStore { $script:builds++; $script:fixed }
            Mock Start-Sleep { }
            Mock Write-VmfTextDocumentIfVersion {
                $script:writes++
                if ($script:writes -eq 1) {
                    # The wave's ten-second write lands first: wave w1 now has a machine converting.
                    $doc = Get-Content (Join-Path $rp 'run-status.json') -Raw | ConvertFrom-Json -Depth 24
                    $doc.summary = Update-VmfRunSummaryWave -Summary $doc.summary -Wave 'w1' -Counts @{ CONVERTING = 1; PLANNED = 1 } -Reason 'waveRunning'
                    $doc | ConvertTo-Json -Depth 24 | Set-Content (Join-Path $rp 'run-status.json') -NoNewline -Encoding utf8NoBOM
                    throw '409: changed'
                }
                Set-Content -LiteralPath $Path -Value $Content -NoNewline -Encoding utf8NoBOM
            }
            $out = Write-VmfRunStatusDocument -RunPath $rp -PlanPath (Join-Path $rp 'plan.json') -Reason 'waveApproved'
            $script:builds | Should -Be 1 -Because 'the summary was not built again for a write that only changed the running wave'
            $out.summary.next.waitsFor | Should -Be 'running'
            ($out.summary.waves | Where-Object { $_.wave -eq 'w1' }).stateCounts.CONVERTING | Should -Be 1
        }
    }

    It 'F2: a conflict with any other write builds again' {
        InModuleScope VmMigrationFactory {
            $mine = [ordered]@{ writtenUtc = 'x'; reason = 'waveApproved'; halted = $false; machines = 1; stateCounts = @{ PLANNED = 1 }
                                waves = @([ordered]@{ wave = 'w1'; machines = 1; members = ('a' * 64); stateCounts = @{ PLANNED = 1 } }); next = [ordered]@{ wave = 'w1'; waitsFor = 'approval' } }
            $approval = [pscustomobject]@{ reason = 'optionsAccepted'; halted = $false; stateCounts = @{}; next = [pscustomobject]@{ wave = 'w1'; waitsFor = 'approval' }
                                           waves = @([pscustomobject]@{ wave = 'w1'; members = ('a' * 64); stateCounts = [pscustomobject]@{ PLANNED = 1 } }) }
            Merge-VmfRunSummaryPatch -Mine $mine -Theirs $approval | Should -BeNullOrEmpty
            $moved = [pscustomobject]@{ reason = 'waveRunning'; halted = $false; stateCounts = @{}; next = [pscustomobject]@{ wave = 'w1'; waitsFor = 'running' }
                                        waves = @([pscustomobject]@{ wave = 'w1'; members = ('b' * 64); stateCounts = [pscustomobject]@{ PLANNED = 1 } }) }
            Merge-VmfRunSummaryPatch -Mine $mine -Theirs $moved | Should -BeNullOrEmpty -Because 'the wave holds other machines'
        }
    }

    It 'F6: a document that exists and is empty is written over' {
        New-Item -ItemType File -Path (Join-Path $script:rp 'run-status.json') -Force | Out-Null
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Update-VmfRunSummary -RunPath $rp -Reason 'planSaved' } | Should -BeTrue
        (& $script:Status $script:rp).summary.reason | Should -Be 'planSaved'
    }

    It 'F8: a pause and a resume write it, and the safety brake field follows' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; p = (& $script:NewPlan); pp = $script:pp } {
            Write-VmfRunStatus -RunPath $rp -Plan $p -Wave 'w1' -RunId 'rsum' -ThrottleLimit 2 -PlanPath $pp -WaveEnded | Out-Null
            Set-VmfWaveHalt -RunPath $rp -Reason 'operator halt'
        }
        $s = & $script:Status $script:rp
        $s.summary.halted | Should -BeTrue
        $s.breaker.halted | Should -BeTrue
        Clear-VmfWaveHalt -RunPath $script:rp -Note 'cause dealt with' -ClearedBy 'operator@example.com' | Out-Null
        $s = & $script:Status $script:rp
        $s.summary.reason | Should -Be 'resumed'
        $s.summary.halted | Should -BeFalse
        $s.breaker.halted | Should -BeFalse -Because 'the run page reads this field, and it said paused after a resume'
    }

    # REBUILD-REMOVE-RECOVER-1: F3's writer was the restore that rebuilt, which is gone.
    It 'F5: a wave whose workers all failed writes it' {
        (Get-VmfCodeOnly -Path (Join-Path $script:repo 'src' 'VmMigrationFactory' 'Public' 'Start-VmfWave.ps1')) |
            Should -Match "Update-VmfRunSummary -RunPath \`$RunPath -PlanPath \`$PlanPath -Reason 'waveEnded' \| Out-Null\s+throw \(`"Wave '\`$Wave' migrated nothing"
    }
}

Describe 'APPROVE-GROUP-1: the action never fails because of the summary' {
    BeforeEach { $script:rp = & $script:NewRun; $script:pp = Join-Path $script:rp 'plan.json' }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'an approval stands when the summary cannot be written, and the history says so' {
        Mock -ModuleName VmMigrationFactory Write-VmfRunStatusDocument { throw 'HTTP 503 the store is busy' }
        $r = Approve-VmfWave -RunPath $script:rp -PlanPath $script:pp -Wave 'w1' -Note 'reviewed' -OnBehalfOf $script:Who
        $r.Wave | Should -Be 'w1'
        Test-Path (Join-Path $script:rp 'approvals' 'w1.json') | Should -BeTrue
        $warn = Get-Content (Join-Path $script:rp 'logs' 'events.jsonl') | ConvertFrom-Json | Where-Object { $_.step -eq 'status' }
        @($warn).Count | Should -Be 1
        $warn.outcome | Should -Be 'warn'
        $warn.detail | Should -Match 'HTTP 503 the store is busy'
        $warn.detail | Should -Match 'and so does the daily check'
    }

    It 'a wave goes on when its status cannot be written' {
        Mock -ModuleName VmMigrationFactory Write-VmfRunStatusDocument { throw 'HTTP 503 the store is busy' }
        $s = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; p = (& $script:NewPlan); pp = $script:pp } {
            Write-VmfRunStatus -RunPath $rp -Plan $p -Wave 'w1' -RunId 'rsum' -ThrottleLimit 2 -PlanPath $pp -WarningAction SilentlyContinue
        }
        $s.stateCounts['PLANNED'] | Should -Be 2 -Because 'the snapshot is still returned to the loop'
    }
}

Describe 'APPROVE-GROUP-1: the writers, as written' {
    It '<_.Name> writes the summary with reason <_.Reason>' -ForEach @(
        @{ Name = 'New-VmfPlan'; Reason = 'planSaved' }
        @{ Name = 'Set-VmfWavePlan'; Reason = 'planSaved' }
        @{ Name = 'Set-VmfMachineTarget'; Reason = 'planSaved' }
        @{ Name = 'Approve-VmfWave'; Reason = 'waveApproved' }
        @{ Name = 'Approve-VmfPlan'; Reason = 'planSignedOff' }
        @{ Name = 'Confirm-VmfWaveOptions'; Reason = 'optionsAccepted' }
        @{ Name = 'Confirm-VmfRunAcknowledgement'; Reason = 'acknowledged' }
        @{ Name = 'Resolve-VmfDecision'; Reason = 'decision' }
        @{ Name = 'Skip-VmfVm'; Reason = 'machineSkipped' }
        @{ Name = 'Stop-VmfRun'; Reason = 'runStopped' }
        @{ Name = 'Clear-VmfWaveHalt'; Reason = 'resumed' }
    ) {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repo 'src' 'VmMigrationFactory' 'Public' "$($_.Name).ps1")
        $code | Should -Match "Update-VmfRunSummary -RunPath \`$(RunPath|OutPath)( -PlanPath \`$PlanPath)? -Reason '$($_.Reason)'( -Wave [^|]+)? \| Out-Null"
    }

    It 'a pause writes it, and the wave''s last write builds it from the store' {
        $orch = Get-VmfCodeOnly -Path (Join-Path $script:repo 'src' 'VmMigrationFactory' 'Private' 'engine' 'Orchestrator.ps1')
        $orch | Should -Match "Update-VmfRunSummary -RunPath \`$RunPath -Reason 'paused'"
        $wave = Get-VmfCodeOnly -Path (Join-Path $script:repo 'src' 'VmMigrationFactory' 'Public' 'Start-VmfWave.ps1')
        $wave | Should -Match '\$final = Write-VmfRunStatus [^\n]*-PlanPath \$PlanPath -WaveEnded'
    }

    It 'the daily check writes it for every migration' {
        $daily = Get-VmfCodeOnly -Path (Join-Path $script:repo 'src' 'facade' 'app' 'RetentionRunner' 'run.ps1')
        $daily | Should -Match "Update-VmfRunSummary -RunPath \`$rp -Reason 'dailyCheck'"
    }

    It 'nothing else writes run-status.json' {
        # RunSummary.ps1 holds the one writer.
        $writers = @(Get-ChildItem (Join-Path $script:repo 'src') -Recurse -Include '*.ps1', '*.psm1' | Where-Object Name -ne 'RunSummary.ps1' | Where-Object {
            (Get-VmfCodeOnly -Path $_.FullName) -match "Write-VmfStore(Json|Text)[^\n]*'run-status\.json'"
        } | ForEach-Object Name)
        $writers | Should -BeNullOrEmpty -Because 'every write goes through Write-VmfRunStatusDocument, which is a compare-and-swap'
    }

    It 'the reasons the schema allows are the reasons the writers take' {
        $enum = @((Get-Content $script:schema -Raw | ConvertFrom-Json).properties.summary.properties.reason.enum) | Sort-Object
        foreach ($fn in 'Update-VmfRunSummary', 'Write-VmfRunStatusDocument') {
            $set = InModuleScope VmMigrationFactory -Parameters @{ fn = $fn } {
                (Get-Command $fn).Parameters['Reason'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
                    ForEach-Object { $_.ValidValues }
            }
            (@($set) | Sort-Object) -join ',' | Should -Be ($enum -join ',') -Because $fn
        }
    }

    It 'what the next wave waits for: the schema and the engine agree' {
        $enum = @((Get-Content $script:schema -Raw | ConvertFrom-Json).properties.summary.properties.next.properties.waitsFor.enum) | Sort-Object
        ($enum -join ',') | Should -Be ((@('acceptance', 'acknowledgement', 'approval', 'decision', 'none', 'running', 'signOffOutOfDate', 'start', 'unknown') | Sort-Object) -join ',')
    }
}
