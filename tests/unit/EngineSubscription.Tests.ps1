#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# ENGINE-SUB-1 - the engine addresses machines by a name that is not unique.
#
# New-VmfContext parsed the subscription out of the plan's vmId and threw it
# away, keeping only the resource group and the machine name. Every azureops
# call then addressed the machine by those two against whatever subscription
# the engine happened to be signed in to.
#
# Discovery accepts several subscriptions or a whole management group
# (Discovery.ps1: "One of Subscriptions or ManagementGroup is required"), so a
# plan can legitimately span them. And a resource group called 'rg-app01' with
# a machine called 'web01' existing in two subscriptions is an ordinary
# enterprise shape - a per-business-unit or dev/prod split - not an exotic one.
#
# So the failure was not merely "it will not find the machine". It was that it
# might find a DIFFERENT one and act on it: deallocate it, snapshot it, convert
# it, and on Path B delete and rebuild it. A machine nobody planned to touch.
#
# The engine is not subscription-aware yet. Until it is, it refuses - at the
# wave, so a whole wave stops at once, and again at PRECHECK, before anything
# on any individual machine is touched.
BeforeAll {
    # A run path under TEMP, never a relative one. `RunPath = 'x'` here wrote
    # `./x/logs/events.jsonl` into whatever directory the runner started in -
    # the repository - and that litter was committed by accident (99da035).
    $script:scratch = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-scratch-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $script:scratch -Force | Out-Null
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # CLUSTER-DETECT-1: the cluster check at Checking is not under test here;
    # ClusterDetect.Tests.ps1 and StateMachine.Tests.ps1 test it.
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }

    $script:subA = '11111111-1111-1111-1111-111111111111'
    $script:subB = '22222222-2222-2222-2222-222222222222'
    function Script:VmIn([string]$Sub, [string]$Rg = 'rg-app01', [string]$Name = 'web01') {
        "/subscriptions/$Sub/resourceGroups/$Rg/providers/Microsoft.Compute/virtualMachines/$Name"
    }
    function Script:Entry([string]$Sub, [string]$Rg = 'rg-app01', [string]$Name = 'web01') {
        [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = (Script:VmIn $Sub $Rg $Name); wave = 'w1'; path = 'A' }
    }
}

AfterAll {
    if ($script:scratch -and (Test-Path $script:scratch)) { Remove-Item $script:scratch -Recurse -Force }
}

Describe 'ENGINE-SUB-1: the context keeps the subscription it used to discard' {
    It 'carries it alongside the resource group and name' {
        $plan = [pscustomobject]@{ vmId = (Script:VmIn $script:subA); wave = 'w1' }
        $ctx = InModuleScope VmMigrationFactory -Parameters @{ p = $plan; rp = $script:scratch } {
            New-VmfContext -PlanEntry $p -RunPath $rp -RunId 'r1'
        }
        $ctx.SubscriptionId | Should -Be $script:subA
        $ctx.Rg | Should -Be 'rg-app01'
        $ctx.VmName | Should -Be 'web01'
    }

    It 'and is null - never a guess - when the id does not carry one' {
        $plan = [pscustomobject]@{ vmId = 'not-a-resource-id'; wave = 'w1' }
        $ctx = InModuleScope VmMigrationFactory -Parameters @{ p = $plan; rp = $script:scratch } {
            New-VmfContext -PlanEntry $p -RunPath $rp -RunId 'r1'
        }
        $ctx.SubscriptionId | Should -BeNullOrEmpty
    }
}

Describe 'ENGINE-SUB-1 FIXED: a wave may span subscriptions it can reach' {
    It 'passes when every subscription is reachable - including several' {
        # This USED to be refused. Since each machine points the process at its
        # own subscription for the duration of its run, a wave spanning them is
        # no longer unsafe - only an UNREACHABLE one is.
        $r = InModuleScope VmMigrationFactory -Parameters @{ e = @((Script:Entry $script:subA), (Script:Entry $script:subB)) } {
            Test-VmfWaveSubscriptions -Entries $e -Reach { param($s) $true } }
        $r.Pass | Should -BeTrue
        @($r.Subscriptions).Count | Should -Be 2
        $r.Detail | Should -Match 'can reach'
    }

    It 'REFUSES when one of them cannot be reached, and names it' {
        $r = InModuleScope VmMigrationFactory -Parameters @{ e = @((Script:Entry $script:subA), (Script:Entry $script:subB)); bad = $script:subB } {
            Test-VmfWaveSubscriptions -Entries $e -Reach { param($s) if ($s -eq $bad) { throw 'no access' }; $true } }
        $r.Pass | Should -BeFalse
        $r.Detail | Should -Match $script:subB
        $r.Detail | Should -Match 'no access'
        $r.Detail | Should -Match 'cannot reach 1 of the 2'
    }

    It 'checks reachability ONCE, before anything starts' {
        # Per machine would mean finding out after some of the wave had moved.
        $calls = 0
        $r = InModuleScope VmMigrationFactory -Parameters @{ e = @((Script:Entry $script:subA), (Script:Entry $script:subA), (Script:Entry $script:subB)) } {
            $script:reachCalls = 0
            $res = Test-VmfWaveSubscriptions -Entries $e -Reach { param($s) $script:reachCalls++; $true }
            [pscustomobject]@{ Result = $res; Calls = $script:reachCalls }
        }
        $r.Calls | Should -Be 2 -Because 'three machines across two subscriptions is two questions, not three'
        $r.Result.Pass | Should -BeTrue
    }

    It 'REFUSES when a machine id does not say which subscription it is in' {
        $bad = [pscustomobject]@{ vmId = '/resourceGroups/rg-app01/providers/Microsoft.Compute/virtualMachines/web01'; wave = 'w1' }
        $r = InModuleScope VmMigrationFactory -Parameters @{ e = @($bad) } {
            Test-VmfWaveSubscriptions -Entries $e -Reach { param($s) $true } }
        $r.Pass | Should -BeFalse
        $r.Detail | Should -Match 'does not say which subscription'
    }

    It 'the wave runner actually calls it, and fails the wave loudly' {
        $sw = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Start-VmfWave.ps1') -Raw
        $sw | Should -Match 'Test-VmfWaveSubscriptions'
        # WAVE-RESUME-PLANNED-1: the line names its wave, so it ends that wave's start.
        $sw | Should -Match "-Step 'wave' -Outcome fail -Data @\{ wave = \`$Wave \} -Detail \`$subGate\.Detail"
    }
}

Describe 'ENGINE-SUB-1 FIXED: the process is pointed at each machine own subscription' {
    BeforeAll { $script:sm = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1') -Raw }

    It 'the state machine switches context per machine' {
        $script:sm | Should -Match 'Use-VmfSubscriptionContext -SubscriptionId \$ctx\.SubscriptionId'
    }

    It 'and restores it in the finally, so the next machine starts clean' {
        $fin = [regex]::Match($script:sm, '(?s)finally \{.*?Restore-VmfSubscriptionContext[^
]*').Value
        $fin | Should -Not -BeNullOrEmpty
        $script:sm | Should -Match 'Restore-VmfSubscriptionContext -Context \$previousAzContext'
    }

    It 'a subscription it cannot reach parks the machine, untouched' {
        $script:sm | Should -Match "ReasonCode 'subscriptionNotReachable' -MachineState 'untouched'"
    }

    It 'the switch is Process-scoped, so it cannot leak between workers or into a human session' {
        $cap = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops' 'AzureOpsCapacity.ps1') -Raw
        $cap | Should -Match 'Set-AzContext -Subscription \$SubscriptionId -Scope Process'
        $cap | Should -Match 'Set-AzContext -Context \$Context -Scope Process'
    }

    It 'restoring never throws, so it cannot mask the machine outcome' {
        $cap = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops' 'AzureOpsCapacity.ps1') -Raw
        $fn = [regex]::Match($cap, '(?s)function Restore-VmfSubscriptionContext \{.*?
\}').Value
        $fn | Should -Match 'catch \{'
    }

    It 'ONE MACHINE PER PROCESS - the property the whole approach rests on' {
        # If workers ever become threads, or a process ever drives two machines
        # at once, a process-scoped context becomes a race and the subscription
        # has to be threaded through azureops instead. This is the tripwire.
        $worker = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Workers' 'worker.ps1') -Raw
        $worker | Should -Match 'while \(\$true\)'
        $worker | Should -Not -Match 'Start-ThreadJob|ForEach-Object -Parallel|Start-Job'
        $wave = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Start-VmfWave.ps1') -Raw
        $wave | Should -Match 'Start-Process' -Because 'concurrency is one PROCESS per worker, which is what makes the context switch safe'
    }
}

Describe 'ENGINE-SUB-1: and PRECHECK refuses the individual machine too' {
    BeforeEach {
        $script:run = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-sub-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run } {
            Initialize-VmfRun -RunPath $rp -RunId 'sub-test' | Out-Null
        }
    }
    AfterEach { if (Test-Path $script:run) { Remove-Item $script:run -Recurse -Force } }

    It 'parks a machine from another subscription before touching anything' {
        # Belt and braces: the wave gate is the early stop, but a machine can
        # also be driven directly (a resumed worker, a single-machine retry),
        # and that path must not be the one that acts on the wrong VM.
        # The context switch FAILS for a subscription the tool cannot reach,
        # which is now where an unreachable machine is caught - earlier than
        # PRECHECK, and before any Azure call at all.
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { throw 'no access to that subscription' }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory Get-VmfEngineSubscriptionId { $script:subA }
        $plan = [pscustomobject]@{
            schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = (Script:VmIn $script:subB); wave = 'w1'; path = 'A'
            assessment = [pscustomobject]@{ classification = 'ReadyNow'; gen = 'V2'; os = 'Linux'
                sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; platformManaged = $false }
            target = [pscustomobject]@{ size = 'Standard_D2s_v6'; diskArch = 'diskless'; controller = 'NVMe' }
            policy = [pscustomobject]@{}
        }
        $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; p = $plan } {
            Invoke-VmfStateMachine -PlanEntry $p -RunPath $rp -RunId 'sub-test'
        }
        $doc.state | Should -Be 'NEEDS_DECISION'
        $last = @($doc.history)[-1]
        $last.reasonCode | Should -Be 'subscriptionNotReachable'
        $last.machineState | Should -Be 'untouched' -Because 'the refusal happens before any Azure work'
    }

    It 'and the stop says what to do about it' {
        InModuleScope VmMigrationFactory {
            $g = Get-VmfStopGuidance -Code 'subscriptionNotReachable'
            $g | Should -Not -BeNullOrEmpty
            $g.machine | Should -Be 'untouched'
            $g.meaning | Should -Match '(?i)different machine'
            # The substance, not one phrasing of it. MANUAL-REVIEW-1: the engine
            # changes to the machine's own subscription (Use-VmfSubscriptionContext),
            # so no wave runs "from" a subscription. The fix is a role there.
            $g.whatToDo | Should -Match '(?i)subscription'
            $g.whatToDo | Should -Match 'Assess and migrate'
            $g.whatToDo | Should -Not -Match '(?i)run this wave'
        }
    }

    It 'a machine in the engine subscription is NOT parked by this gate' {
        Mock -ModuleName VmMigrationFactory Get-VmfEngineSubscriptionId { $script:subA }
        # The state machine now points the process at the machine's own
        # subscription before anything else. These fixtures use invented
        # subscription ids, so the switch itself has to be mocked - this test is
        # about the PRECHECK gate, not about whether Azure knows the id.
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { $null }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory Invoke-VmfAzOperation { throw 'reached Azure - the gate let it through, which is the point of this test' }
        $plan = [pscustomobject]@{
            schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = (Script:VmIn $script:subA); wave = 'w1'; path = 'A'
            assessment = [pscustomobject]@{ classification = 'ReadyNow'; gen = 'V2'; os = 'Linux'
                sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; platformManaged = $false }
            target = [pscustomobject]@{ size = 'Standard_D2s_v6'; diskArch = 'diskless'; controller = 'NVMe' }
            policy = [pscustomobject]@{}
        }
        $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; p = $plan } {
            Invoke-VmfStateMachine -PlanEntry $p -RunPath $rp -RunId 'sub-test'
        }
        # It got past the subscription gate and failed on the mocked Azure call
        # instead - which is exactly the behaviour being asserted.
        @($doc.history | Where-Object { $_.reasonCode -eq 'subscriptionNotReachable' }).Count |
            Should -Be 0
    }
}
