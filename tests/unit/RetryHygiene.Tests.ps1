#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# EVAL-H3, H12 and L1, from the 2026-08-28 self-evaluation.
#
# H3: pathCheckpoint had one writer, one reader, and nothing ever cleared it.
# A machine that converted, failed at STARTING, was correctly rolled back to
# its v4 size on the pristine disk, and was then retried still carried
# 'B:recreated' - so every gate in CONVERTING was skipped, no ARM work was
# done, and the handler returned "Path B recreation complete." into the
# operator's history and the customer's report, about a machine still on SCSI.
# Validation then failed by construction and triggered a SECOND rollback.
#
# L1: attempt counters were cumulative for the life of the document, so a
# retried machine could start with an exhausted budget and roll back on its
# FIRST validation hiccup while the message read "failed after 3 attempts".
#
# H12: -PolicyOverride copied any key into the plan unchecked, and the cmdlet's
# own example taught a lever that had been deleted by IAC-2.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_WaveGate.ps1')

    function Script:NewRun {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-retry-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $vm = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; vm = $vm } {
            Initialize-VmfRun -RunPath $rp -RunId 'retry-test' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'retry-test' -VmId $vm -Wave 'w1' | Out-Null
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 12 -Document ([ordered]@{
                schemaVersion = 8; assessmentRunId = 'retry-test'
                entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $vm; wave = 'w1'; path = 'A'
                    policy = [ordered]@{ onDDataFound = 'stop' } }) })
            # a machine that got most of the way through, then failed
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $vm
            $doc | Add-Member -NotePropertyName pathCheckpoint -NotePropertyValue 'B:recreated' -Force
            $doc | Add-Member -NotePropertyName attempts -NotePropertyValue ([pscustomobject]@{
                CONVERTING = 1; VALIDATING = 2; GUEST_PREP = 1 }) -Force
            Write-VmfStateDoc -RunPath $rp -Document $doc
            Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'NEEDS_DECISION' -Outcome ok -Detail 'parked' | Out-Null
        }
        # RETRY-GATE-1: a retry is refused while its wave cannot start.
        Open-VmfTestWaveGate -RunPath $rp -PlanPath (Join-Path $rp 'plan.json')
        @{ Run = $rp; Vm = $vm }
    }
}

Describe 'EVAL-H3/L1: a retry does not inherit the last attempt' {
    BeforeEach { $script:fx = Script:NewRun }
    AfterEach { if (Test-Path $script:fx.Run) { Remove-Item $script:fx.Run -Recurse -Force } }

    It 'forgets how far the failed conversion got, so the retry actually converts' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run; vm = $script:fx.Vm } {
            Clear-VmfRetryState -RunPath $rp -VmId $vm -From 'PRECHECK'
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $vm
            $doc.pathCheckpoint | Should -BeNullOrEmpty -Because 'B:recreated would make CONVERTING skip everything and report success'
        }
    }

    It 'resets the attempt budgets at and after the re-entry point' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run; vm = $script:fx.Vm } {
            Clear-VmfRetryState -RunPath $rp -VmId $vm -From 'CONVERTING'
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $vm
            [int]$doc.attempts.CONVERTING | Should -Be 0
            [int]$doc.attempts.VALIDATING | Should -Be 0
            [int]$doc.attempts.GUEST_PREP | Should -Be 1 -Because 'a state the machine is not going back through keeps its history'
        }
    }

    It 'says what it cleared, rather than doing it silently' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run; vm = $script:fx.Vm } {
            Clear-VmfRetryState -RunPath $rp -VmId $vm -From 'PRECHECK'
            $events = @(Read-VmfEvents -RunPath $rp -Step 'rearm')
            @($events).Count | Should -BeGreaterThan 0
            @($events)[-1].detail | Should -Be 'The next attempt starts again at Checking. Earlier attempts are not counted against it.'
        }
    }

    It 'resolving a parked machine re-arms it cleanly' {
        Mock -ModuleName VmMigrationFactory Get-VmfSignedInIdentity { @{ Identity = 'operator@contoso.com' } }
        Resolve-VmfDecision -RunPath $script:fx.Run -PlanPath (Join-Path $script:fx.Run 'plan.json') `
            -VmId $script:fx.Vm -Note 'looked at it' -ResolvedBy 'operator' | Out-Null
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run; vm = $script:fx.Vm } {
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $vm
            $doc.state | Should -Be 'PRECHECK'
            $doc.pathCheckpoint | Should -BeNullOrEmpty -Because 'the docstring promises a stale parked VM can never skip its checks'
        }
    }

    It 'the rollback clears it too - the machine is back at the beginning' {
        $sm = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1') -Raw
        $rollback = [regex]::Match($sm, '(?s)function Invoke-VmfRollback.*?\r?\n\}').Value
        $rollback | Should -Match 'Clear-VmfRetryState'
    }
}

Describe 'EVAL-H12: a policy change the engine cannot act on is refused by name' {
    BeforeEach { $script:fx = Script:NewRun }
    AfterEach { if (Test-Path $script:fx.Run) { Remove-Item $script:fx.Run -Recurse -Force } }

    It 'refuses an unknown lever and lists the real ones' {
        { Resolve-VmfDecision -RunPath $script:fx.Run -PlanPath (Join-Path $script:fx.Run 'plan.json') `
            -VmId $script:fx.Vm -Note 'x' -PolicyOverride @{ onIacManaged = 'proceed' } } |
            Should -Throw "*is not a setting the product has*"
    }

    It 'refuses a bad VALUE for a real lever' {
        { Resolve-VmfDecision -RunPath $script:fx.Run -PlanPath (Join-Path $script:fx.Run 'plan.json') `
            -VmId $script:fx.Vm -Note 'x' -PolicyOverride @{ onDDataFound = 'ignore' } } |
            Should -Throw "*not a setting for 'onDDataFound'*"
    }

    It 'accepts a real lever with a real value' {
        Mock -ModuleName VmMigrationFactory Get-VmfSignedInIdentity { @{ Identity = 'operator@contoso.com' } }
        # WAVE-APPROVE-1 (the rule, 2026-10-10): accepted and saved. A
        # call with no roles is not an approver's, so the wave asks again for
        # its approval and the machine is not re-armed - before, it re-armed.
        { Resolve-VmfDecision -RunPath $script:fx.Run -PlanPath (Join-Path $script:fx.Run 'plan.json') `
            -VmId $script:fx.Vm -Note 'accepted the risk' -PolicyOverride @{ onDDataFound = 'proceed' } } |
            Should -Throw '400: The change (onDDataFound=proceed) is saved*cannot start now*'
        $plan = Get-Content (Join-Path $script:fx.Run 'plan.json') -Raw | ConvertFrom-Json -Depth 12
        @($plan.entries)[0].policy.onDDataFound | Should -Be 'proceed'
    }

    It 'the cmdlet no longer teaches a lever that was deleted' {
        $text = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Resolve-VmfDecision.ps1') -Raw
        $text | Should -Not -Match 'onIacManaged'
    }

    It 'the wave editor and the override validate against the SAME declaration' {
        # They disagreed about what a policy is, which is how one of them
        # accepted a lever the other would have refused.
        $levers = InModuleScope VmMigrationFactory { @((Get-VmfPolicyLevers).Keys) }
        foreach ($l in 'capacityGate', 'requireApproval', 'onDDataFound', 'onDriverBelowFloor', 'keepSnapshotDays') {
            $levers | Should -Contain $l
        }
    }
}
