#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# APPR-LEVER-1: the sign-off requirement belongs to the APPROVER.
#
# A wave deallocates, converts and recreates customer machines, and the only
# separation of duties over that work is the sign-off. Invoke-VmfFacadeApprove
# takes Vmf.Approver or Vmf.Admin and refuses an Operator on purpose - whoever
# runs a wave must not also be the one who signs it off.
#
# But the engine's gate reads ONE field - policy.requireApproval on each plan
# entry (Test-VmfWaveApproval, which passes with "this wave was set not to need
# a separate approval" when no entry requires it) - and TWO Operator-gated
# endpoints wrote that field:
#
#   POST /runs/{runId}/plan/waves  -> Invoke-VmfFacadeSetWaves -> Set-VmfWavePlan
#   POST /runs/{runId}/vms/resolve -> Invoke-VmfFacadeResolve  -> Resolve-VmfDecision
#
# So an Operator could clear the requirement for a whole wave, or for one
# machine at a time, then accept the options and start it - production machines
# rebuilt with no approver ever involved and no approval artifact written. The
# architecture document says approvals are enforced "with no bypass switch";
# this file is what makes that sentence true.
#
# THE RULE, in one sentence: an Operator may put the requirement ON, and only
# an Approver may take it OFF. A machine whose policy says NOTHING about it is
# read as REQUIRING it - the same fail-safe reading the engine's gate uses, so
# a plan that lost the key cannot lose the gate with it.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    # TEST-1: anything this file forgets to mock must fail as a TEST error,
    # not quietly reach real Azure. Placed before the file's own mocks so
    # those still win where they exist.
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_WaveGate.ps1')

    # A principal exactly as an endpoint builds one, through the real parser -
    # the roles a token carries are the whole subject of this file.
    function Global:LeverPrincipal {
        param([string]$Identity, [string[]]$Roles)
        $claims = @(@{ typ = 'preferred_username'; val = $Identity }) +
                  @($Roles | ForEach-Object { @{ typ = 'roles'; val = $_ } })
        $doc = @{ auth_typ = 'aad'; claims = $claims } | ConvertTo-Json -Depth 5
        ConvertFrom-VmfClientPrincipal -Header ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($doc)))
    }

    function Global:LeverVmId { param([string]$Name) "/s/rg/vm/$Name" }

    # prod-1 needs sign-off (two machines); pilot does not (one machine). One
    # machine is parked, so the resolve path has something to resolve.
    function Global:NewLeverRun {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-lever-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } {
            Initialize-VmfRun -RunPath $rp -RunId 'lever-test' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'lever-test' -VmId '/s/rg/vm/vm1' -Wave 'prod-1' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId '/s/rg/vm/vm1' -NewState 'NEEDS_DECISION' -Outcome ok -Detail 'parked' | Out-Null
        }
        @{ schemaVersion = 1; assessmentRunId = 'lever-test'; entries = @(
            @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/s/rg/vm/vm1'; wave = 'prod-1'; ring = 'prod'; path = 'A'; assessment = @{}; target = @{ size = 's' }
               policy = @{ requireApproval = $true; onDDataFound = 'stop' } },
            @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/s/rg/vm/vm2'; wave = 'prod-1'; ring = 'prod'; path = 'A'; assessment = @{}; target = @{ size = 's' }
               policy = @{ requireApproval = $true; onDDataFound = 'stop' } },
            @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/s/rg/vm/vm3'; wave = 'pilot'; ring = 'pilot'; path = 'A'; assessment = @{}; target = @{ size = 's' }
               policy = @{ requireApproval = $false; onDDataFound = 'stop' } }
        ) } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $rp 'plan.json')
        $rp
    }

    function Global:LeverEntry {
        param([string]$RunPath, [string]$Name)
        $plan = Get-Content (Join-Path $RunPath 'plan.json') -Raw | ConvertFrom-Json
        @($plan.entries) | Where-Object { $_.vmId -eq (LeverVmId $Name) } | Select-Object -First 1
    }
}
AfterAll {
    foreach ($fn in 'LeverPrincipal', 'LeverVmId', 'NewLeverRun', 'LeverEntry') {
        Remove-Item "function:\$fn" -ErrorAction SilentlyContinue
    }
}

Describe 'APPR-LEVER-1: an Operator cannot take the sign-off requirement off a wave' {
    BeforeEach {
        $script:run      = NewLeverRun
        $script:operator = LeverPrincipal -Identity 'oper@example.com' -Roles @('Vmf.Operator')
        $script:both     = LeverPrincipal -Identity 'lead@example.com' -Roles @('Vmf.Operator', 'Vmf.Approver')
        $script:admin    = LeverPrincipal -Identity 'root@example.com' -Roles @('Vmf.Admin')
    }
    AfterEach { if (Test-Path $script:run) { Remove-Item $script:run -Recurse -Force } }

    It 'refuses the Operator who clears the tick on a wave that needs sign-off' {
        # The finding's own request body, with the role it was found with.
        { Invoke-VmfFacadeSetWaves -Principal $script:operator -StorePath $script:run -Note 'go faster' -Waves @(
            @{ name = 'prod-1'; vmIds = @((LeverVmId 'vm1'), (LeverVmId 'vm2')); requireApproval = $false })
        } | Should -Throw '*403*'
        (LeverEntry $script:run 'vm1').policy.requireApproval | Should -BeTrue -Because 'a refused save writes nothing'
        (LeverEntry $script:run 'vm2').policy.requireApproval | Should -BeTrue
    }

    It 'and refuses the same Operator moving a machine INTO a wave that needs none' {
        # The second shape of the same act: the tick never moves, the machine
        # does, and it lands under a policy that has no gate.
        { Invoke-VmfFacadeSetWaves -Principal $script:operator -StorePath $script:run -Note 'regroup' -Waves @(
            @{ name = 'pilot'; vmIds = @((LeverVmId 'vm3'), (LeverVmId 'vm1')); requireApproval = $false })
        } | Should -Throw '*403*'
        (LeverEntry $script:run 'vm1').wave | Should -Be 'prod-1' -Because 'the machine must not move either'
        (LeverEntry $script:run 'vm1').policy.requireApproval | Should -BeTrue
    }

    It 'and refuses it for a machine whose policy never mentioned the requirement' {
        # Absent means REQUIRED, exactly as Test-VmfWaveApproval reads it. If
        # this end read absence as "not required", a plan that lost the key
        # would hand the gate to whoever asked first.
        $plan = Get-Content (Join-Path $script:run 'plan.json') -Raw | ConvertFrom-Json
        foreach ($e in @($plan.entries)) { $e.policy = [pscustomobject]@{ onDDataFound = 'stop' } }
        $plan | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $script:run 'plan.json')

        { Invoke-VmfFacadeSetWaves -Principal $script:operator -StorePath $script:run -Note 'x' -Waves @(
            @{ name = 'prod-1'; vmIds = @((LeverVmId 'vm1')); requireApproval = $false })
        } | Should -Throw '*403*'
    }

    It 'lets the Operator put the requirement ON, which adds a control rather than removing one' {
        Invoke-VmfFacadeSetWaves -Principal $script:operator -StorePath $script:run -Note 'this wave is production' -Waves @(
            @{ name = 'pilot'; vmIds = @((LeverVmId 'vm3')); requireApproval = $true },
            # WAVE-REMOVE-NOT-SAVED-1: a layout is the complete set of waves.
            @{ name = 'prod-1'; vmIds = @((LeverVmId 'vm1'), (LeverVmId 'vm2')) }) | Out-Null
        (LeverEntry $script:run 'vm3').policy.requireApproval | Should -BeTrue
    }

    It 'lets the Operator save every other lever, and a layout that leaves this one alone' {
        # The regression that matters: the wave editor sends ALL the levers for
        # EVERY wave on every save, changed or not. Only a true->false move is
        # the approver's business.
        #
        # DECIDE-2 took onDDataFound out of this list. It used to stand here as
        # "a lever that is theirs", and it is not one any more: moving a
        # stop-and-ask gate to Continue accepts a loss for every machine in the
        # wave, and since 2026-09-11 all three of those belong to the approver:
        # every such lever is the approver's. The levers left here
        # are the ones that take nothing away.
        Invoke-VmfFacadeSetWaves -Principal $script:operator -StorePath $script:run -Note 'settings pass' -Waves @(
            @{ name = 'prod-1'; vmIds = @((LeverVmId 'vm1'), (LeverVmId 'vm2')); requireApproval = $true
               capacityGate = 'Reserved'; onDDataFound = 'stop'; keepSnapshotDays = 14; throttle = 5 },
            @{ name = 'pilot'; vmIds = @((LeverVmId 'vm3')); requireApproval = $false; capacityGate = 'BestEffort' }
        ) | Out-Null
        (LeverEntry $script:run 'vm1').policy.requireApproval | Should -BeTrue
        (LeverEntry $script:run 'vm1').policy.capacityGate | Should -Be 'Reserved'
        (LeverEntry $script:run 'vm1').policy.keepSnapshotDays | Should -Be 14
        (LeverEntry $script:run 'vm3').policy.requireApproval | Should -BeFalse -Because 'saying false to a wave that is already false changes nothing'
    }

    It 'lets an Approver who is also an Operator take it off, and writes who did it' {
        Invoke-VmfFacadeSetWaves -Principal $script:both -StorePath $script:run -Waves @(
            @{ name = 'prod-1'; vmIds = @((LeverVmId 'vm1'), (LeverVmId 'vm2')); requireApproval = $false }) `
            -Note 'lab rehearsal, signed off in advance' | Out-Null
        (LeverEntry $script:run 'vm1').policy.requireApproval | Should -BeFalse

        $said = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run } {
            @(Read-VmfEvents -RunPath $rp -Step 'plan' | Where-Object { $_.detail -match 'sign-off requirement' })
        }
        @($said).Count | Should -BeGreaterThan 0 -Because 'removing the only separation of duties is an event, not a silence'
        ($said[0].detail) | Should -Match 'lead@example\.com'
        ($said[0].detail) | Should -Match 'prod-1'
    }

    It 'and an Administrator can too, because Administrator holds both halves' {
        Invoke-VmfFacadeSetWaves -Principal $script:admin -StorePath $script:run -Note 'lab run' -Waves @(
            @{ name = 'prod-1'; vmIds = @((LeverVmId 'vm1')); requireApproval = $false }) | Out-Null
        (LeverEntry $script:run 'vm1').policy.requireApproval | Should -BeFalse
    }
}

Describe 'APPR-LEVER-1: the same lever, one machine at a time, through resolve' {
    BeforeEach {
        $script:run      = NewLeverRun
        # RETRY-GATE-1: a retry is refused while its wave cannot start.
        Open-VmfTestWaveGate -RunPath $script:run -PlanPath (Join-Path $script:run 'plan.json')
        $script:operator = LeverPrincipal -Identity 'oper@example.com' -Roles @('Vmf.Operator')
        $script:both     = LeverPrincipal -Identity 'lead@example.com' -Roles @('Vmf.Operator', 'Vmf.Approver')
    }
    AfterEach { if (Test-Path $script:run) { Remove-Item $script:run -Recurse -Force } }

    It 'refuses an Operator who sends requireApproval as a policy override' {
        # -PolicyOverride writes any lever onto one machine's plan entry, and
        # requireApproval is one of them (Get-VmfPolicyLevers). A wave can be
        # emptied of its gate one parked machine at a time.
        { Invoke-VmfFacadeResolve -Principal $script:operator -StorePath $script:run -VmId (LeverVmId 'vm1') `
            -Note 'letting this one through' -PolicyOverride @{ requireApproval = $false } } | Should -Throw '*403*'
        (LeverEntry $script:run 'vm1').policy.requireApproval | Should -BeTrue

        $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run } {
            Read-VmfStateDoc -RunPath $rp -VmId '/s/rg/vm/vm1'
        }
        $doc.state | Should -Be 'NEEDS_DECISION' -Because 'a refused resolve must not re-arm the machine either'
    }

    It 'still lets the Operator resolve a parked machine, and keeps the sign-off on' {
        # DECIDE-2: this used to send onDDataFound = 'proceed' as the example of
        # "a lever that is theirs". Accepting the loss of files on the temporary
        # disk is now the approver's, like the other two gates - see
        # DecisionGate.Tests.ps1. A PLAIN resolve is still the operator's, which
        # is what this test is really for.
        $r = Invoke-VmfFacadeResolve -Principal $script:operator -StorePath $script:run -VmId (LeverVmId 'vm1') `
            -Note 'the files have been moved, try it again'
        $r.NewState | Should -Be 'PRECHECK'
        (LeverEntry $script:run 'vm1').policy.requireApproval | Should -BeTrue
    }

    It 'and lets an Approver take the requirement off that one machine' {
        # WAVE-APPROVE-1 (the rule, 2026-10-10): the change is allowed
        # and saved. It is not the decision the machine waits for, so it does
        # not carry the wave approval or the plan sign-off: the wave asks again
        # for its approval, and the machine is not re-armed until it has one.
        { Invoke-VmfFacadeResolve -Principal $script:both -StorePath $script:run -VmId (LeverVmId 'vm1') `
            -Note 'signed off with the customer on the call' -PolicyOverride @{ requireApproval = $false } } |
            Should -Throw '400:*cannot start now*'
        (LeverEntry $script:run 'vm1').policy.requireApproval | Should -BeFalse
        (InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run } { Read-VmfStateDoc -RunPath $rp -VmId '/s/rg/vm/vm1' }).state |
            Should -Be 'NEEDS_DECISION'
    }
}

Describe 'APPR-LEVER-1: the page does not offer what the facade refuses' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:waves = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'waves.html'))
        $script:core  = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1') -Raw
    }

    It 'the wave editor reads the approver role from the same token it reads the operator role from' {
        $script:waves | Should -Match "canSignOff = roles\.includes\('Vmf\.Approver'\) \|\| roles\.includes\('Vmf\.Admin'\)"
    }

    It 'and the tick that is already on cannot be cleared by somebody who is not an approver' {
        $script:waves | Should -Match 'const apprLocked = w\.requireApproval && !canSignOff'
        # WAVE-EDIT-RUNNING-1: editable is canEdit on a wave that is not running.
        $script:waves | Should -Match 'const editable = canEdit && !running;'
        $script:waves | Should -Match 'editable && !apprLocked'
    }

    It 'and it reads an absent setting the way the engine does, so the tick it draws is true' {
        # The page read absence as "not required" while the engine and the
        # facade read it as required. On a plan with no such key that drew an
        # EMPTY tick for a wave that does need sign-off - and saving that empty
        # tick is now refused, which is a control nobody could comply with.
        # WAVE-LEVER-OVERRIDE-1: every setting is read through leverValue now,
        # and the tick is the engine's reading for the wave (any machine that
        # requires it). tests/js/wave-lever-override.test.js runs both on a
        # machine with no such key (the fixture case "a missing value").
        # SIGNOFF-NULL-1: by the one rule in help.js, which tests/js/signoff-null.test.js runs.
        # ACCEPT-FIRST-MACHINE-1: leverValue and the wave's reading are in help.js.
        $help = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js') -Raw
        $help | Should -Match ([regex]::Escape("if (field === 'requireApproval') { return approvalRequired(e); }"))
        $help | Should -Match ([regex]::Escape("if (field === 'requireApproval') { return members.some(e => leverValue(e, field) === true); }"))
        $script:waves | Should -Match ([regex]::Escape('const { leverValue, ownDecision, keepsOwn, waveCard } = VmfHelp;'))
    }

    It 'and it says why, rather than showing a control that does nothing' {
        # CLAUDE.md rule 11: a control that can only be looked at is a trap.
        # This one explains itself and names the role to ask for.
        $script:waves | Should -Match "approvalLocked: 'Only an Approver can remove the sign-off requirement"
        $script:waves | Should -Match 'UX\.approvalLocked'
    }

    It 'both facade writers of the lever ask the same question before they write' {
        # The drift guard. A third writer, or one of these two losing the
        # check, is the whole defect coming back.
        foreach ($fn in 'Invoke-VmfFacadeSetWaves', 'Invoke-VmfFacadeResolve') {
            $body = [regex]::Match($script:core, "(?s)function $fn \{.*?\n\}").Value
            $body | Should -Not -BeNullOrEmpty -Because "$fn must be findable, or this test proves nothing"
            $body | Should -Match 'Get-VmfFacadeApprovalRemovals' -Because "$fn writes requireApproval into the plan"
        }
    }

    It 'requireApproval is still a policy lever, which is why the check has to exist' {
        InModuleScope VmMigrationFactory { (Get-VmfPolicyLevers).Contains('requireApproval') | Should -BeTrue }
    }
}
