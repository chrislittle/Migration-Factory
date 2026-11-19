#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# DECIDE-1: a stop that is a CHOICE, and who is allowed to make it.
#
# THE DEFECT. stop-reasons.json had four retry kinds and all four describe a
# FAULT: correct the named thing (afterFix), wait (whenAvailable), retrying
# will not help (unlikely), this engine cannot do it (notSupported). There was
# no kind meaning "nothing is wrong and a person must choose", so the one stop
# that is purely a choice - a rebuild destroys a system-assigned identity -
# was filed under afterFix.
#
# The cost was not the label. RETRY-1's own question is: what could a
# customer fix before pressing retry? For this reason the honest
# answer is NOTHING. The manual said "Correct what the entry names, then try
# the machine again", the page offered "Try this machine again", and pressing
# it re-ran PRECHECK, which read the same plan lever, which still said stop.
# Same state, same reason, for ever. The one way through from the app was to
# change the setting for the WHOLE WAVE - which clears that wave's approval
# and its accepted options, and drops the same protection from every other
# machine in it. To accept one machine you re-opened all of them.
#
# REBUILD-REMOVE-ACCEPT-1: that stop is gone with the rebuild. The tests below
# use the decision that remains with no correction - accelerated networking a
# target requires (acceleratedNetworking = ensureOn) - and, for the wave
# editor, files on the temporary disk (onDDataFound = proceed). The rule is
# the same for every decision.
#
# THE ENGINE COULD ALWAYS DO THIS. `onSystemAssignedIdentity` was a plan lever,
# Resolve-VmfDecision takes -PolicyOverride, and the facade accepts one on
# POST /runs/{runId}/vms/resolve. The dashboard never sent one - so the choice
# was reachable from a command line and not from the product, which is hard
# rule 12 exactly.
#
# WHO DECIDES. Since 2026-09-11, the approver is the person who decides.
# Accepting the permanent loss of an identity is a risk acceptance, not an
# operational retry, so it takes Vmf.Approver - not the Vmf.Operator the rest
# of the resolve endpoint takes.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_WaveGate.ps1')

    function Global:DecidePrincipal {
        param([string]$Identity, [string[]]$Roles)
        $claims = @(@{ typ = 'preferred_username'; val = $Identity }) +
                  @($Roles | ForEach-Object { @{ typ = 'roles'; val = $_ } })
        $doc = @{ auth_typ = 'aad'; claims = $claims } | ConvertTo-Json -Depth 5
        ConvertFrom-VmfClientPrincipal -Header ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($doc)))
    }

    # Two machines in one wave, both parked by this stop. The sibling is the
    # point: the old way through decided for the whole wave at once.
    #
    # app03 has NOT started - no state document - and sits in a second wave.
    # The engine refuses to move a machine that has started ("'app02' has
    # already started migrating"), which is correct and which the first cut of
    # these tests walked straight into.
    function Global:NewDecideRun {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-decide-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } {
            Initialize-VmfRun -RunPath $rp -RunId 'decide-test' | Out-Null
            foreach ($name in 'app01', 'app02') {
                New-VmfStateDoc -RunPath $rp -RunId 'decide-test' -VmId "/s/rg/vm/$name" -Wave 'billing' | Out-Null
                Add-VmfStateTransition -RunPath $rp -VmId "/s/rg/vm/$name" -NewState 'NEEDS_DECISION' `
                    -Outcome ok -Detail 'parked' -ReasonCode 'acceleratedNetworkingRequired' | Out-Null
            }
        }
        @{ schemaVersion = 1; assessmentRunId = 'decide-test'; entries = @(
            @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/s/rg/vm/app01'; wave = 'billing'; ring = 'prod'; path = 'A'; assessment = @{}
               target = @{ size = 's' }; policy = @{ requireApproval = $true; acceleratedNetworking = 'preserve'; onDDataFound = 'stop' } },
            @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/s/rg/vm/app02'; wave = 'billing'; ring = 'prod'; path = 'A'; assessment = @{}
               target = @{ size = 's' }; policy = @{ requireApproval = $true; acceleratedNetworking = 'preserve'; onDDataFound = 'stop' } },
            @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/s/rg/vm/app03'; wave = 'later'; ring = 'prod'; path = 'A'; assessment = @{}
               target = @{ size = 's' }; policy = @{ requireApproval = $true; acceleratedNetworking = 'preserve'; onDDataFound = 'stop' } }
        ) } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $rp 'plan.json')
        # RETRY-GATE-1: a decision is refused while its wave cannot start.
        Open-VmfTestWaveGate -RunPath $rp -PlanPath (Join-Path $rp 'plan.json')
        $rp
    }

    function Global:DecideEntry {
        param([string]$RunPath, [string]$Name)
        $plan = Get-Content (Join-Path $RunPath 'plan.json') -Raw | ConvertFrom-Json
        @($plan.entries) | Where-Object { $_.vmId -eq "/s/rg/vm/$Name" } | Select-Object -First 1
    }

    function Global:DecideState {
        param([string]$RunPath, [string]$Name)
        InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath; n = $Name } {
            (Read-VmfStateDoc -RunPath $rp -VmId "/s/rg/vm/$n").state
        }
    }
}
AfterAll {
    foreach ($fn in 'DecidePrincipal', 'NewDecideRun', 'DecideEntry', 'DecideState') {
        Remove-Item "function:\$fn" -ErrorAction SilentlyContinue
    }
}

Describe 'DECIDE-1: the decision is read from the data, not written into code' {

    It 'the engine can name the lever for every decision, from stop-reasons.json' {
        $levers = InModuleScope VmMigrationFactory { Get-VmfDecisionLevers }
        $levers.Keys | Should -Contain 'acceleratedNetworking'
        $levers['acceleratedNetworking'].accept | Should -Be 'ensureOn'
        $levers['acceleratedNetworking'].approver | Should -BeTrue
        $levers['acceleratedNetworking'].code | Should -Be 'acceleratedNetworkingRequired'
    }

    It 'DECIDE-2: all THREE wave gates carry a choice, not just the identity' {
        # DECIDE-1 read the retry kind to find the choices, so it found one of
        # three. The other two have a real correction as well - move the files,
        # patch the kernel - and the correction made them look like faults.
        # They are both: a customer may correct it, or accept the loss.
        $levers = InModuleScope VmMigrationFactory { Get-VmfDecisionLevers }
        # REBUILD-ACCEPT-1 added 'rebuild', and IDENTITY-LOSS-1 kept the
        # identity: REBUILD-REMOVE-ACCEPT-1 took both away with the rebuild.
        # AN-PROCEED-NETVSC-1 (2026-11-06) took the driver floor OUT:
        # with no MANA driver the network does not work, so nobody accepts it.
        # EOL-RELEASE-AN-1 (2026-11-14) added onReleaseEndOfLife: an
        # approver accepts a Linux release past its vendor's end of standard support.
        # VF-UNMANAGED-CONFIG-1 added onSriovUnmanagedMissing: an approver
        # accepts the move of one Linux machine whose network settings do not
        # set the SR-IOV interface as unmanaged.
        @($levers.Keys | Sort-Object) | Should -Be @('acceleratedNetworking', 'onDDataFound', 'onReleaseEndOfLife', 'onSriovUnmanagedMissing')
        # GEN-V5-1 added the fourth: Intel D v5 requires accelerated networking,
        # and what an approver accepts there is turning it ON - so the accepting
        # value is the lever's own, not always 'proceed'. It must be one the
        # lever takes.
        foreach ($k in @($levers.Keys)) {
            (InModuleScope VmMigrationFactory -Parameters @{ k = $k; v = $levers[$k].accept } { param($k, $v)
                (Test-VmfPolicyOverride -Override @{ $k = $v }).Ok }) | Should -BeTrue -Because "$k accepts '$($levers[$k].accept)'"
            $levers[$k].approver | Should -BeTrue -Because 'every lever is an approver decision'
        }
        $levers['acceleratedNetworking'].accept | Should -Be 'ensureOn'
    }

    It 'and the sign-off requirement is NOT one of them' {
        # requireApproval is a lever too, and it is guarded by APPR-LEVER-1 in
        # its own way - putting it here would give it a second, different gate.
        $levers = InModuleScope VmMigrationFactory { Get-VmfDecisionLevers }
        $levers.Keys | Should -Not -Contain 'requireApproval'
        $levers.Keys | Should -Not -Contain 'keepSnapshotDays'
    }
}

Describe 'DECIDE-1: only an approver accepts the loss' {
    BeforeEach {
        $script:run      = NewDecideRun
        $script:operator = DecidePrincipal -Identity 'oper@example.com' -Roles @('Vmf.Operator')
        $script:approver = DecidePrincipal -Identity 'lead@example.com' -Roles @('Vmf.Operator', 'Vmf.Approver')
    }
    AfterEach { if (Test-Path $script:run) { Remove-Item $script:run -Recurse -Force } }

    It 'refuses an Operator, and tells them who can do it' {
        # THE MESSAGE, clause by clause. `Should -Throw '*403*Approver*'` was
        # the first version of this and it proved almost nothing: -Throw
        # matches case-insensitively, so the word "approver" in the FIRST
        # sentence satisfied it, and a mutation that replaced the guidance
        # with "Ask somebody else." passed. A refusal that does not say what
        # to do next is a dead end with a number on it.
        $err = $null
        try {
            Invoke-VmfFacadeResolve -Principal $script:operator -StorePath $script:run `
                -VmId '/s/rg/vm/app01' -Note 'nothing uses it' `
                -PolicyOverride @{ acceleratedNetworking = 'ensureOn' }
        }
        catch { $err = [string]$_.Exception.Message }
        $err | Should -Not -BeNullOrEmpty -Because 'it must refuse at all'
        $err | Should -BeLike '403:*'
        $err | Should -Match 'Approver role' -Because 'the way OUT of the refusal, not just the fact of it'
        $err | Should -Match 'oper@example\.com' -Because 'who was refused'
        $err | Should -Match 'Vmf\.Operator' -Because 'and what they actually hold'
        $err | Should -Match 'acceleratedNetworking' -Because 'and which setting was refused'
    }

    It 'and the refused machine stays parked, with its setting untouched' {
        # A refusal that re-armed the machine would send it round the loop
        # again; a refusal that wrote the lever anyway would be the whole
        # defect with an error message on top.
        try {
            Invoke-VmfFacadeResolve -Principal $script:operator -StorePath $script:run `
                -VmId '/s/rg/vm/app01' -Note 'nothing uses it' `
                -PolicyOverride @{ acceleratedNetworking = 'ensureOn' }
        } catch { }
        (DecideEntry $script:run 'app01').policy.acceleratedNetworking | Should -Be 'preserve'
        DecideState $script:run 'app01' | Should -Be 'NEEDS_DECISION'
    }

    It 'lets an Approver accept it, and the machine goes back to the checks' {
        $r = Invoke-VmfFacadeResolve -Principal $script:approver -StorePath $script:run `
            -VmId '/s/rg/vm/app01' -Note 'the report team accepted this on the call' `
            -PolicyOverride @{ acceleratedNetworking = 'ensureOn' }
        $r.NewState | Should -Be 'PRECHECK'
        (DecideEntry $script:run 'app01').policy.acceleratedNetworking | Should -Be 'ensureOn'
    }

    It 'ONE MACHINE. The sibling in the same wave keeps its gate' {
        # This is the reason the control exists. The only way through from the
        # app was the wave-wide setting, which drops the gate for every machine
        # in the wave and clears the wave's approval with it.
        Invoke-VmfFacadeResolve -Principal $script:approver -StorePath $script:run `
            -VmId '/s/rg/vm/app01' -Note 'accepted' `
            -PolicyOverride @{ acceleratedNetworking = 'ensureOn' } | Out-Null
        (DecideEntry $script:run 'app02').policy.acceleratedNetworking | Should -Be 'preserve' `
            -Because 'accepting one machine must not decide for its siblings'
        (DecideEntry $script:run 'app02').policy.requireApproval | Should -BeTrue
        DecideState $script:run 'app02' | Should -Be 'NEEDS_DECISION' `
            -Because 'and must not re-arm them either'
    }

    It 'an Operator may still put the gate BACK, because that takes nothing away' {
        # The guard holds back the ACCEPTING value only. Setting the lever the
        # other way parks the machine, and a guard that refused both would make
        # the safe direction need a signature.
        # WAVE-APPROVE-1 (the rule since 2026-10-10): the operator is not
        # refused for the role - but an operator's decision is not covered by
        # the plan sign-off, so the wave asks again for its approval and the
        # machine is not re-armed. Before, this went through at once.
        { Invoke-VmfFacadeResolve -Principal $script:operator -StorePath $script:run `
            -VmId '/s/rg/vm/app01' -Note 'leave this one parked' `
            -PolicyOverride @{ acceleratedNetworking = 'preserve' } } | Should -Throw '400:*wave billing cannot start now*Nobody approved wave billing*'
        (DecideEntry $script:run 'app01').policy.acceleratedNetworking | Should -Be 'preserve'
        DecideState $script:run 'app01' | Should -Be 'NEEDS_DECISION'
    }

    It 'and an ordinary retry is still the Operator action it always was' {
        # DECIDE-1 must not take the plain resolve away from an Operator.
        $r = Invoke-VmfFacadeResolve -Principal $script:operator -StorePath $script:run `
            -VmId '/s/rg/vm/app01' -Note 'trying again'
        $r.NewState | Should -Be 'PRECHECK'
    }
}

Describe 'DECIDE-ROLE-1: Accept this and continue is the approver''s alone' {
    # THE DEFECT. The page offered Accept this and continue to any approver,
    # and the service first asked for the operator role. So a user who held
    # the approver role alone saw the button and got a 403. Every principal
    # above called "approver" holds BOTH roles, so that case never ran.
    #
    # The answer (OWNER-QUESTIONS-1 row 26): the decision is the
    # approver's alone, and the service stops asking for the operator role
    # too. Only THAT action changes. Every other request through the same
    # endpoint keeps exactly the role rule it had - one test each below.
    BeforeEach {
        $script:run       = NewDecideRun
        $script:approver1 = DecidePrincipal -Identity 'approver@example.com' -Roles @('Vmf.Approver')
        $script:operator  = DecidePrincipal -Identity 'oper@example.com' -Roles @('Vmf.Operator')
        $script:admin     = DecidePrincipal -Identity 'admin@example.com' -Roles @('Vmf.Admin')
        $script:viewer    = DecidePrincipal -Identity 'viewer@example.com' -Roles @('Vmf.Viewer')
    }
    AfterEach { if (Test-Path $script:run) { Remove-Item $script:run -Recurse -Force } }

    It 'a user with the approver role ALONE accepts the decision, and the machine goes back to the checks' {
        $r = Invoke-VmfFacadeResolve -Principal $script:approver1 -StorePath $script:run `
            -VmId '/s/rg/vm/app01' -Note 'the report team accepted this' `
            -PolicyOverride @{ acceleratedNetworking = 'ensureOn' }
        $r.NewState | Should -Be 'PRECHECK'
        $r.ResolvedBy | Should -Be 'approver@example.com' -Because 'the record names the person who decided'
        (DecideEntry $script:run 'app01').policy.acceleratedNetworking | Should -Be 'ensureOn'
        (DecideEntry $script:run 'app02').policy.acceleratedNetworking | Should -Be 'preserve' `
            -Because 'still one machine, not the wave'
    }

    It 'every decision in the table, not only the identity' {
        # The levers come from stop-reasons.json, so a decision added there is
        # the approver's too without a change to the service.
        $levers = InModuleScope VmMigrationFactory { Get-VmfDecisionLevers }
        foreach ($k in @($levers.Keys)) {
            $rp = NewDecideRun
            try {
                # Parked by the stop that carries THIS decision - the engine
                # accepts only the decision the machine waits for.
                InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; code = $levers[$k].code } {
                    Add-VmfStateTransition -RunPath $rp -VmId '/s/rg/vm/app01' -NewState 'NEEDS_DECISION' `
                        -Outcome ok -Detail 'parked' -ReasonCode $code | Out-Null
                }
                $r = Invoke-VmfFacadeResolve -Principal $script:approver1 -StorePath $rp `
                    -VmId '/s/rg/vm/app01' -Note 'accepted' -PolicyOverride @{ $k = $levers[$k].accept }
                $r.NewState | Should -Be 'PRECHECK' -Because "$k is a decision"
            }
            finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'an administrator alone accepts it too, as with every approver action' {
        $r = Invoke-VmfFacadeResolve -Principal $script:admin -StorePath $script:run `
            -VmId '/s/rg/vm/app01' -Note 'accepted' -PolicyOverride @{ acceleratedNetworking = 'ensureOn' }
        $r.NewState | Should -Be 'PRECHECK'
    }

    It 'a viewer is refused, and nothing is written' {
        $err = $null
        try {
            Invoke-VmfFacadeResolve -Principal $script:viewer -StorePath $script:run `
                -VmId '/s/rg/vm/app01' -Note 'x' -PolicyOverride @{ acceleratedNetworking = 'ensureOn' }
        }
        catch { $err = [string]$_.Exception.Message }
        $err | Should -BeLike '403:*'
        $err | Should -Match 'Approver role'
        (DecideEntry $script:run 'app01').policy.acceleratedNetworking | Should -Be 'preserve'
        DecideState $script:run 'app01' | Should -Be 'NEEDS_DECISION'
    }

    It 'nobody signed in is refused as unauthenticated, not as a missing role' {
        { Invoke-VmfFacadeResolve -Principal $null -StorePath $script:run `
            -VmId '/s/rg/vm/app01' -Note 'x' -PolicyOverride @{ acceleratedNetworking = 'ensureOn' } } |
            Should -Throw '401:*'
    }

    It 'KEPT: a plain retry is still the operator''s, so the approver alone is refused' {
        { Invoke-VmfFacadeResolve -Principal $script:approver1 -StorePath $script:run `
            -VmId '/s/rg/vm/app01' -Note 'trying again' } | Should -Throw '403:*Vmf.Operator*'
        DecideState $script:run 'app01' | Should -Be 'NEEDS_DECISION'
    }

    It 'KEPT: putting a gate BACK is the operator''s, so the approver alone is refused' {
        { Invoke-VmfFacadeResolve -Principal $script:approver1 -StorePath $script:run `
            -VmId '/s/rg/vm/app01' -Note 'leave it parked' -PolicyOverride @{ acceleratedNetworking = 'preserve' } } |
            Should -Throw '403:*Vmf.Operator*'
    }

    It 'KEPT: any other setting is the operator''s, so the approver alone is refused' {
        { Invoke-VmfFacadeResolve -Principal $script:approver1 -StorePath $script:run `
            -VmId '/s/rg/vm/app01' -Note 'longer copies' -PolicyOverride @{ keepSnapshotDays = 14 } } |
            Should -Throw '403:*Vmf.Operator*'
        (DecideEntry $script:run 'app01').policy.PSObject.Properties['keepSnapshotDays'] | Should -BeNullOrEmpty
    }

    It 'KEPT: a decision sent WITH another setting is not the decision alone, so it needs the operator too' {
        # Otherwise the decision would carry any setting past the operator gate.
        { Invoke-VmfFacadeResolve -Principal $script:approver1 -StorePath $script:run `
            -VmId '/s/rg/vm/app01' -Note 'both' `
            -PolicyOverride @{ acceleratedNetworking = 'ensureOn'; keepSnapshotDays = 14 } } |
            Should -Throw '403:*Vmf.Operator*'
        (DecideEntry $script:run 'app01').policy.acceleratedNetworking | Should -Be 'preserve'
    }

    It 'KEPT: removing the sign-off requirement from one machine still needs the operator too' {
        { Invoke-VmfFacadeResolve -Principal $script:approver1 -StorePath $script:run `
            -VmId '/s/rg/vm/app01' -Note 'no sign-off' -PolicyOverride @{ requireApproval = $false } } |
            Should -Throw '403:*Vmf.Operator*'
        (DecideEntry $script:run 'app01').policy.requireApproval | Should -BeTrue
    }

    It 'KEPT: an engineer forcing where the machine re-enters is the operator''s' {
        { Invoke-VmfFacadeResolve -Principal $script:approver1 -StorePath $script:run `
            -VmId '/s/rg/vm/app01' -Note 'x' -ReturnTo PRECHECK `
            -PolicyOverride @{ acceleratedNetworking = 'ensureOn' } } |
            Should -Throw '403:*Vmf.Operator*'
    }

    It 'the approver alone accepts only a machine that WAITS for a decision, never a failed one' {
        # The engine re-arms a failed machine through the same call, with the
        # same setting - that is a new attempt with new safety copies, which is
        # the operator's Try this machine again. The page offers Accept this
        # and continue only on a parked machine, and so does the service.
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run } {
            Add-VmfStateTransition -RunPath $rp -VmId '/s/rg/vm/app01' -NewState 'FAILED_ROLLED_BACK' `
                -Outcome fail -Detail 'rolled back' -ReasonCode 'acceleratedNetworkingRequired' | Out-Null
        }
        $err = $null
        try {
            Invoke-VmfFacadeResolve -Principal $script:approver1 -StorePath $script:run `
                -VmId '/s/rg/vm/app01' -Note 'x' -PolicyOverride @{ acceleratedNetworking = 'ensureOn' }
        }
        catch { $err = [string]$_.Exception.Message }
        $err | Should -BeLike '400:*'
        $err | Should -Match 'app01'
        $err | Should -Match 'operator' -Because 'it says who can act on the machine'
        (DecideEntry $script:run 'app01').policy.acceleratedNetworking | Should -Be 'preserve' `
            -Because 'a refused decision writes nothing'
        DecideState $script:run 'app01' | Should -Be 'FAILED_ROLLED_BACK'
    }

    It 'REVIEW: the approver alone may accept only the decision the machine WAITS for, not another one' {
        # Measured by the independent review: on a machine parked for its
        # identity (now: for accelerated networking), onDDataFound = proceed was accepted and re-armed it - a
        # retry, which is the operator's, carried by an unrelated decision.
        $err = $null
        try {
            Invoke-VmfFacadeResolve -Principal $script:approver1 -StorePath $script:run `
                -VmId '/s/rg/vm/app01' -Note 'x' -PolicyOverride @{ onDDataFound = 'proceed' }
        }
        catch { $err = [string]$_.Exception.Message }
        $err | Should -BeLike '400:*'
        $err | Should -Match 'acceleratedNetworking set to ensureOn' -Because 'it names the one change this stop accepts'
        (DecideEntry $script:run 'app01').policy.onDDataFound | Should -Be 'stop' -Because 'nothing is written'
        DecideState $script:run 'app01' | Should -Be 'NEEDS_DECISION'
    }

    It 'REVIEW: a stop with NO decision cannot be retried by the approver alone through any decision' {
        # A machine with Azure Disk Encryption waits for a person too, and its only answer is
        # to correct it and try again - the operator's.
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run } {
            Add-VmfStateTransition -RunPath $rp -VmId '/s/rg/vm/app01' -NewState 'NEEDS_DECISION' `
                -Outcome ok -Detail 'parked' -ReasonCode 'diskEncryptionPresent' | Out-Null
        }
        foreach ($change in @(@{ acceleratedNetworking = 'ensureOn' }, @{ onDDataFound = 'proceed' })) {
            $err = $null
            try {
                Invoke-VmfFacadeResolve -Principal $script:approver1 -StorePath $script:run `
                    -VmId '/s/rg/vm/app01' -Note 'x' -PolicyOverride $change
            }
            catch { $err = [string]$_.Exception.Message }
            $err | Should -BeLike '400:*no decision to accept*'
        }
        (DecideEntry $script:run 'app01').policy.acceleratedNetworking | Should -Be 'preserve'
        (DecideEntry $script:run 'app01').policy.onDDataFound | Should -Be 'stop'
        DecideState $script:run 'app01' | Should -Be 'NEEDS_DECISION'
    }

    It 'REVIEW: several decisions at once are not Accept this and continue, so the approver alone is refused' {
        $all = @{ acceleratedNetworking = 'ensureOn'; onDDataFound = 'proceed'; onDriverBelowFloor = 'proceed' }
        { Invoke-VmfFacadeResolve -Principal $script:approver1 -StorePath $script:run `
            -VmId '/s/rg/vm/app01' -Note 'x' -PolicyOverride $all } | Should -Throw '403:*Vmf.Operator*'
        (DecideEntry $script:run 'app01').policy.acceleratedNetworking | Should -Be 'preserve'
        DecideState $script:run 'app01' | Should -Be 'NEEDS_DECISION'
    }

    It 'REVIEW: and the ENGINE refuses them too, whoever calls it with -DecisionOnly' {
        # The facade refuses early; the engine is the rule, on its own read.
        $plan = Join-Path $script:run 'plan.json'
        # Two changes: the decision, and one more. A table lists its keys in an
        # order of its own, and .NET picks a new order for each process, so no
        # one case can put the decision first. Many extra names, each refused,
        # cover both orders - and the count of changes is what refuses the ones
        # where the decision comes first. The engine refuses before it asks
        # whether the extra name is a setting at all.
        foreach ($i in 1..64) {
            $two = @{ acceleratedNetworking = 'ensureOn'; "x$i" = 'x' }
            { Resolve-VmfDecision -RunPath $script:run -PlanPath $plan -VmId '/s/rg/vm/app01' -Note 'x' `
                -ResolvedBy 'approver@example.com' -DecisionOnly -PolicyOverride $two } |
                Should -Throw '400:*accepts one change only*' -Because "the decision and x$i are two changes"
        }
        $cases = @(
            @{ acceleratedNetworking = 'ensureOn'; onDDataFound = 'proceed' },   # two decisions
            @{ AcceleratedNetworking = 'ensureOn' },                              # the setting in another case
            @{ ('accelerated' + [char]0x200B + 'Networking') = 'ensureOn' },      # the setting with a zero-width character
            @{ acceleratedNetworking = 'ENSUREON' },                              # the value in another case
            @{ acceleratedNetworking = @('ensureOn') },                           # a list
            @{ acceleratedNetworking = 'preserve' },                                 # not the accepting value
            @{ onDDataFound = 'proceed' }                                           # another decision
        )
        foreach ($c in $cases) {
            { Resolve-VmfDecision -RunPath $script:run -PlanPath $plan -VmId '/s/rg/vm/app01' -Note 'x' `
                -ResolvedBy 'approver@example.com' -DecisionOnly -PolicyOverride $c } |
                Should -Throw '400:*' -Because "$($c | ConvertTo-Json -Compress) is not the decision this machine waits for"
        }
        (DecideEntry $script:run 'app01').policy.acceleratedNetworking | Should -Be 'preserve'
        DecideState $script:run 'app01' | Should -Be 'NEEDS_DECISION'
        # and the one it waits for goes through - with the approver's role, as
        # the service passes it (WAVE-APPROVE-1: only then does the decision
        # carry the wave approval and the plan sign-off past its write).
        (Resolve-VmfDecision -RunPath $script:run -PlanPath $plan -VmId '/s/rg/vm/app01' -Note 'x' `
            -ResolvedBy 'approver@example.com' -ResolvedRoles @('Vmf.Approver') -DecisionOnly -PolicyOverride @{ acceleratedNetworking = 'ensureOn' }).NewState |
            Should -Be 'PRECHECK'
    }

    It 'WAVE-APPROVE-1: the same decision from PowerShell, with no roles, is saved and asks again for the wave approval' {
        # This side effect is accepted (2026-10-10): a call that names
        # no role is never an approver's, so it never carries the approval.
        { Resolve-VmfDecision -RunPath $script:run -PlanPath (Join-Path $script:run 'plan.json') -VmId '/s/rg/vm/app01' -Note 'x' `
            -ResolvedBy 'approver@example.com' -DecisionOnly -PolicyOverride @{ acceleratedNetworking = 'ensureOn' } } |
            Should -Throw '400:*wave billing cannot start now*Nobody approved wave billing*'
        (DecideEntry $script:run 'app01').policy.acceleratedNetworking | Should -Be 'ensureOn' -Because 'the change is saved'
        DecideState $script:run 'app01' | Should -Be 'NEEDS_DECISION'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run } {
            (Test-VmfWaveApproval -RunPath $rp -PlanPath (Join-Path $rp 'plan.json') -Wave 'billing').Pass | Should -BeFalse
            (Test-VmfWaveApproval -RunPath $rp -PlanPath (Join-Path $rp 'plan.json') -Wave 'later').Pass | Should -BeTrue
        }
    }

    It 'REVIEW: an accepting value in another case, or as a list, is not the decision, so the approver alone is refused' {
        foreach ($v in @('ENSUREON', 'EnsureOn')) {
            { Invoke-VmfFacadeResolve -Principal $script:approver1 -StorePath $script:run `
                -VmId '/s/rg/vm/app01' -Note 'x' -PolicyOverride @{ acceleratedNetworking = $v } } |
                Should -Throw '403:*Vmf.Operator*'
        }
        $list = @{ acceleratedNetworking = [object[]]@('ensureOn') }
        { Invoke-VmfFacadeResolve -Principal $script:approver1 -StorePath $script:run `
            -VmId '/s/rg/vm/app01' -Note 'x' -PolicyOverride $list } | Should -Throw '403:*Vmf.Operator*'
        (DecideEntry $script:run 'app01').policy.acceleratedNetworking | Should -Be 'preserve'
    }

    It 'SECOND REVIEW: a zero-width character or a soft hyphen in the value is not the decision, for the approver alone' {
        # PowerShell's -ceq compares by culture, which ignores these: an
        # approver alone sent 'pro' + U+200B + 'ceed', the machine went back to
        # PRECHECK and the plan stored the eight characters.
        foreach ($c in [char]0x200B, [char]0x00AD, [char]0x200D) {
            $v = 'ensure' + $c + 'On'
            { Invoke-VmfFacadeResolve -Principal $script:approver1 -StorePath $script:run `
                -VmId '/s/rg/vm/app01' -Note 'x' -PolicyOverride @{ acceleratedNetworking = $v } } |
                Should -Throw '403:*Vmf.Operator*' -Because "U+$(([int]$c).ToString('X4')) makes it another value"
            { Resolve-VmfDecision -RunPath $script:run -PlanPath (Join-Path $script:run 'plan.json') -VmId '/s/rg/vm/app01' `
                -Note 'x' -ResolvedBy 'approver@example.com' -DecisionOnly -PolicyOverride @{ acceleratedNetworking = $v } } |
                Should -Throw '400:*' -Because 'and the engine refuses it on its own'
        }
        (DecideEntry $script:run 'app01').policy.acceleratedNetworking | Should -Be 'preserve'
        DecideState $script:run 'app01' | Should -Be 'NEEDS_DECISION'
    }

    It 'SECOND REVIEW: and on the operator path the engine refuses it, so it cannot go round the approver check' {
        # Not accepting at the service means the approver check is skipped -
        # so the engine must refuse the value as one no setting takes, or an
        # operator could store and act on it as proceed.
        foreach ($c in [char]0x200B, [char]0x00AD, [char]0x200D) {
            $v = 'ensure' + $c + 'On'
            { Invoke-VmfFacadeResolve -Principal $script:operator -StorePath $script:run `
                -VmId '/s/rg/vm/app01' -Note 'x' -PolicyOverride @{ acceleratedNetworking = $v } } |
                Should -Throw '*cannot be applied*'
        }
        (DecideEntry $script:run 'app01').policy.acceleratedNetworking | Should -Be 'preserve'
        DecideState $script:run 'app01' | Should -Be 'NEEDS_DECISION'
    }

    It 'SECOND REVIEW: an old park is not the stop once the machine was rebuilt without a history entry' {
        # A rebuild of a machine with no shell sets NEEDS_DECISION and writes
        # no entry. Before, the newest entry with a reason code - here the
        # identity park, resolved long ago - read as the stop, and the approver
        # alone could accept it and re-arm the machine.
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run } {
            Add-VmfStateTransition -RunPath $rp -VmId '/s/rg/vm/app01' -NewState 'PRECHECK' -Outcome ok -Detail 'resolved' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId '/s/rg/vm/app01' -NewState 'SKIPPED' -Outcome skip -Detail 'left out' | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId '/s/rg/vm/app01'
            $doc | Add-Member -NotePropertyName restore -NotePropertyValue ([pscustomobject]@{ restoredUtc = (Get-Date).ToUniversalTime().AddMinutes(1).ToString('o') }) -Force
            $doc.state = 'NEEDS_DECISION'
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        { Invoke-VmfFacadeResolve -Principal $script:approver1 -StorePath $script:run `
            -VmId '/s/rg/vm/app01' -Note 'x' -PolicyOverride @{ acceleratedNetworking = 'ensureOn' } } |
            Should -Throw '400:*no decision to accept*'
        (DecideEntry $script:run 'app01').policy.acceleratedNetworking | Should -Be 'preserve'
        DecideState $script:run 'app01' | Should -Be 'NEEDS_DECISION'
    }

    It 'THIRD REVIEW: a park that IS the last entry is not the stop once a restore is newer than it' {
        # The case above makes SKIPPED the last entry, so it never reaches the
        # time comparison. Here the park is last and a restore came after it.
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run } {
            $doc = Read-VmfStateDoc -RunPath $rp -VmId '/s/rg/vm/app01'
            $doc | Add-Member -NotePropertyName restore -NotePropertyValue ([pscustomobject]@{ restoredUtc = (Get-Date).ToUniversalTime().AddMinutes(1).ToString('o') }) -Force
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        { Invoke-VmfFacadeResolve -Principal $script:approver1 -StorePath $script:run `
            -VmId '/s/rg/vm/app01' -Note 'x' -PolicyOverride @{ acceleratedNetworking = 'ensureOn' } } |
            Should -Throw '400:*no decision to accept*'
        (DecideEntry $script:run 'app01').policy.acceleratedNetworking | Should -Be 'preserve'
        DecideState $script:run 'app01' | Should -Be 'NEEDS_DECISION'
    }

    It 'THIRD REVIEW: a null last history entry is no park, and a 400, not a fault' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run } {
            $doc = Read-VmfStateDoc -RunPath $rp -VmId '/s/rg/vm/app01'
            $doc.history = @($doc.history) + @($null)
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        (InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run } {
            Get-VmfWaitingDecisionStop -Document (Read-VmfStateDoc -RunPath $rp -VmId '/s/rg/vm/app01') }) | Should -BeNullOrEmpty
        { Invoke-VmfFacadeResolve -Principal $script:approver1 -StorePath $script:run `
            -VmId '/s/rg/vm/app01' -Note 'x' -PolicyOverride @{ acceleratedNetworking = 'ensureOn' } } |
            Should -Throw '400:*no decision to accept*'
    }

    It 'REVIEW: the event names the roles that allowed the decision, beside the name' {
        Invoke-VmfFacadeResolve -Principal $script:approver1 -StorePath $script:run `
            -VmId '/s/rg/vm/app01' -Note 'accepted' -PolicyOverride @{ acceleratedNetworking = 'ensureOn' } | Out-Null
        $evt = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run } {
            @(Read-VmfEvents -RunPath $rp -Step 'decision') | Select-Object -Last 1
        }
        @($evt.resolvedRoles) | Should -Be @('Vmf.Approver')
        [string]$evt.detail | Should -Match 'approver@example\.com'
    }

    It 'REVIEW: a decision that needs no approver stays the operator''s, so the approver alone is refused' {
        # Fixture: a decision marked approver:false. It is not Accept this and
        # continue, so it keeps the operator gate - and the operator alone may
        # make it, because nothing asks for the approver.
        Mock -ModuleName FacadeCore Get-VmfDecisionLevers {
            @{ acceleratedNetworking = @{ accept = 'ensureOn'; approver = $false; code = 'acceleratedNetworkingRequired' } }
        }
        { Invoke-VmfFacadeResolve -Principal $script:approver1 -StorePath $script:run `
            -VmId '/s/rg/vm/app01' -Note 'x' -PolicyOverride @{ acceleratedNetworking = 'ensureOn' } } |
            Should -Throw '403:*Vmf.Operator*'
        # WAVE-APPROVE-1 (the rule since 2026-10-10): the operator passes the
        # role check, and the change is saved - but an operator's decision asks
        # again for the wave's approval, so the machine is not re-armed yet.
        { Invoke-VmfFacadeResolve -Principal $script:operator -StorePath $script:run `
            -VmId '/s/rg/vm/app01' -Note 'x' -PolicyOverride @{ acceleratedNetworking = 'ensureOn' } } |
            Should -Throw '400:*wave billing cannot start now*Nobody approved wave billing*'
        (DecideEntry $script:run 'app01').policy.acceleratedNetworking | Should -Be 'ensureOn'
        DecideState $script:run 'app01' | Should -Be 'NEEDS_DECISION'
    }
    It 'and that limit is for the approver alone: an operator who is also an approver keeps the old rule' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run } {
            Add-VmfStateTransition -RunPath $rp -VmId '/s/rg/vm/app01' -NewState 'FAILED_ROLLED_BACK' `
                -Outcome fail -Detail 'rolled back' -ReasonCode 'acceleratedNetworkingRequired' | Out-Null
        }
        $both = DecidePrincipal -Identity 'lead@example.com' -Roles @('Vmf.Operator', 'Vmf.Approver')
        # WAVE-APPROVE-1 (the rule since 2026-10-10): the role check passes
        # (no 403). A failed machine waits for no decision, so this is a retry
        # with a change, not an approver accepting a decision: the change is
        # saved and the wave asks again for its approval. Then the retry goes.
        { Invoke-VmfFacadeResolve -Principal $both -StorePath $script:run `
            -VmId '/s/rg/vm/app01' -Note 'x' -PolicyOverride @{ acceleratedNetworking = 'ensureOn' } } |
            Should -Throw '400:*wave billing cannot start now*Nobody approved wave billing*'
        Invoke-VmfFacadeApprove -Principal $both -StorePath $script:run -Wave 'billing' -Note 'read the change' `
            -PlanHash (InModuleScope VmMigrationFactory -Parameters @{ t = (Get-Content (Join-Path $script:run 'plan.json') -Raw) } { Get-VmfDocumentVersion -Text $t }) | Out-Null
        $r = Invoke-VmfFacadeResolve -Principal $both -StorePath $script:run -VmId '/s/rg/vm/app01' -Note 'x'
        $r.NewState | Should -Be 'PRECHECK'
    }
}

Describe 'DECIDE-ROLE-1 review: a setting takes ONE value, spelt exactly' {
    BeforeEach {
        $script:run  = NewDecideRun
        $script:both = DecidePrincipal -Identity 'lead@example.com' -Roles @('Vmf.Operator', 'Vmf.Approver')
    }
    AfterEach { if (Test-Path $script:run) { Remove-Item $script:run -Recurse -Force } }

    It 'the check refuses a list and another case, and keeps every plain value it took' {
        InModuleScope VmMigrationFactory {
            (Test-VmfPolicyOverride -Override @{ acceleratedNetworking = 'ensureOn' }).Ok | Should -BeTrue
            (Test-VmfPolicyOverride -Override @{ acceleratedNetworking = 'ENSUREON' }).Ok | Should -BeFalse
            (Test-VmfPolicyOverride -Override @{ acceleratedNetworking = @('ensureOn') }).Ok | Should -BeFalse
            (Test-VmfPolicyOverride -Override @{ acceleratedNetworking = @{ v = 'ensureOn' } }).Ok | Should -BeFalse
            (Test-VmfPolicyOverride -Override @{ keepSnapshotDays = 14 }).Ok | Should -BeTrue
            (Test-VmfPolicyOverride -Override @{ keepSnapshotDays = '14' }).Ok | Should -BeTrue
            (Test-VmfPolicyOverride -Override @{ keepSnapshotDays = @(14) }).Ok | Should -BeFalse
            (Test-VmfPolicyOverride -Override @{ requireApproval = $true }).Ok | Should -BeTrue
            (Test-VmfPolicyOverride -Override @{ requireApproval = @($true) }).Ok | Should -BeFalse
            (Test-VmfPolicyOverride -Override @{ throttle = 30 }).Ok | Should -BeTrue   # MACHINES-AT-ONCE-RANGE-1: one of the four choices
            # SECOND REVIEW: character for character, and the name too.
            (Test-VmfPolicyOverride -Override @{ acceleratedNetworking = ('ensure' + [char]0x200B + 'On') }).Ok | Should -BeFalse
            (Test-VmfPolicyOverride -Override @{ acceleratedNetworking = ('ensure' + [char]0x00AD + 'On') }).Ok | Should -BeFalse
            (Test-VmfPolicyOverride -Override @{ acceleratedNetworking = ('ensure' + [char]0x200D + 'On') }).Ok | Should -BeFalse
            (Test-VmfPolicyOverride -Override @{ AcceleratedNetworking = 'ensureOn' }).Ok | Should -BeFalse
            (Test-VmfPolicyOverride -Override @{ keepsnapshotdays = 14 }).Ok | Should -BeFalse
        }
    }

    It 'SECOND REVIEW: a setting name in another case is refused, and the plan keeps its own key' {
        { Invoke-VmfFacadeResolve -Principal $script:both -StorePath $script:run `
            -VmId '/s/rg/vm/app01' -Note 'x' -PolicyOverride @{ AcceleratedNetworking = 'ensureOn' } } | Should -Throw
        $entry = DecideEntry $script:run 'app01'
        @($entry.policy.PSObject.Properties.Name) | Should -Contain 'acceleratedNetworking'
        @($entry.policy.PSObject.Properties.Name) -ccontains 'AcceleratedNetworking' | Should -BeFalse
        $entry.policy.acceleratedNetworking | Should -Be 'preserve'
    }

    It 'ENSUREON is refused at the service, and nothing is written' {
        { Invoke-VmfFacadeResolve -Principal $script:both -StorePath $script:run `
            -VmId '/s/rg/vm/app01' -Note 'x' -PolicyOverride @{ acceleratedNetworking = 'ENSUREON' } } | Should -Throw
        (DecideEntry $script:run 'app01').policy.acceleratedNetworking | Should -Be 'preserve'
        DecideState $script:run 'app01' | Should -Be 'NEEDS_DECISION'
    }

    It 'a list is refused at the service, and the plan never holds one' {
        { Invoke-VmfFacadeResolve -Principal $script:both -StorePath $script:run `
            -VmId '/s/rg/vm/app01' -Note 'x' -PolicyOverride @{ acceleratedNetworking = @('ensureOn') } } | Should -Throw
        (DecideEntry $script:run 'app01').policy.acceleratedNetworking | Should -Be 'preserve'
        (DecideEntry $script:run 'app01').policy.acceleratedNetworking | Should -BeOfType [string]
    }

    It 'and an Operator cannot slip an accepting value past the approver check by its case' {
        # The service compares with case, so PROCEED is not an accepting
        # value there - and the engine refuses it as no value the setting takes.
        $op = DecidePrincipal -Identity 'oper@example.com' -Roles @('Vmf.Operator')
        { Invoke-VmfFacadeResolve -Principal $op -StorePath $script:run `
            -VmId '/s/rg/vm/app01' -Note 'x' -PolicyOverride @{ acceleratedNetworking = 'ENSUREON' } } | Should -Throw
        (DecideEntry $script:run 'app01').policy.acceleratedNetworking | Should -Be 'preserve'
    }
}
Describe 'DECIDE-ROLE-1: the park a machine waits at, held to the fixture the run page is held to' {
    It 'answers every case in tests/fixtures/decision-waiting.json' {
        $fx = Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' 'decision-waiting.json') -Raw | ConvertFrom-Json
        @($fx.cases).Count | Should -BeGreaterThan 5
        foreach ($c in @($fx.cases)) {
            $got = InModuleScope VmMigrationFactory -Parameters @{ d = $c.doc } { Get-VmfWaitingDecisionStop -Document $d }
            $code = if ($got) { [string]$got.reasonCode } else { $null }
            $code | Should -Be $c.expect -Because $c.name
        }
    }
}
Describe 'DECIDE-2: the wave editor cannot go round the machine gate' {
    BeforeEach {
        $script:run      = NewDecideRun
        $script:operator = DecidePrincipal -Identity 'oper@example.com' -Roles @('Vmf.Operator')
        $script:approver = DecidePrincipal -Identity 'lead@example.com' -Roles @('Vmf.Operator', 'Vmf.Approver')
    }
    AfterEach { if (Test-Path $script:run) { Remove-Item $script:run -Recurse -Force } }

    It 'the identity setting REACHES the plan at all, which it did not' {
        # This is the defect that was hiding behind the role question. The wave
        # editor has shown this control since WAVE-2 and the page sends it on
        # every save, Set-VmfWavePlan accepts it - and Invoke-VmfFacadeSetWaves
        # never copied it into the layout. It was dropped on the floor. So a
        # customer set the gate to Continue, the page said the wave was saved,
        # and every machine in it still parked. A control that reports success
        # and changes nothing is the defect class this product keeps finding.
        Invoke-VmfFacadeSetWaves -Principal $script:approver -StorePath $script:run -Note 'accepted for the wave' -Waves @(
            @{ name = 'billing'; vmIds = @('/s/rg/vm/app01', '/s/rg/vm/app02'); onDDataFound = 'proceed' }) | Out-Null
        (DecideEntry $script:run 'app01').policy.onDDataFound | Should -Be 'proceed'
        (DecideEntry $script:run 'app02').policy.onDDataFound | Should -Be 'proceed'
    }

    It 'and an Operator cannot accept it for a whole wave' {
        # Gating the machine's panel and leaving this open would make the WIDER
        # action the easy one: the per-machine control decides for one machine,
        # this decides for every machine the wave names.
        $err = $null
        try {
            Invoke-VmfFacadeSetWaves -Principal $script:operator -StorePath $script:run -Note 'letting them all through' -Waves @(
                @{ name = 'billing'; vmIds = @('/s/rg/vm/app01', '/s/rg/vm/app02'); onDDataFound = 'proceed' })
        }
        catch { $err = [string]$_.Exception.Message }
        $err | Should -BeLike '403:*'
        $err | Should -Match 'Approver role'
        $err | Should -Match 'onDDataFound'
        $err | Should -Match 'billing'
        (DecideEntry $script:run 'app01').policy.onDDataFound | Should -Be 'stop' `
            -Because 'a refused save must write nothing'
    }

    It 'the same for files on the temporary disk; and the driver floor has no Continue for anybody' {
        { Invoke-VmfFacadeSetWaves -Principal $script:operator -StorePath $script:run -Note 'through' -Waves @(
            @{ name = 'billing'; vmIds = @('/s/rg/vm/app01'); onDDataFound = 'proceed' }) } |
            Should -Throw '*403*' -Because 'onDDataFound accepts a loss too'
        # AN-PROCEED-NETVSC-1: not even an approver - the save refuses the value.
        # WAVE-KERNEL-LINE-1: no wave has a kernel setting at all, so the
        # service passes it on and the engine refuses it by name, any value.
        foreach ($who in $script:operator, $script:approver) {
            foreach ($v in 'proceed', 'stop') {
                { Invoke-VmfFacadeSetWaves -Principal $who -StorePath $script:run -Note 'through' -Waves @(
                    @{ name = 'billing'; vmIds = @('/s/rg/vm/app01'); onDriverBelowFloor = $v }) } |
                    Should -Throw '*A wave has no kernel choice*'
            }
        }
    }

    It 'SECOND REVIEW: a wave save takes the value character for character, from anybody' {
        # The wave check ignored case and, by culture, zero-width characters,
        # and stored the value as sent. The approver check beside it counts a
        # value as accepting the same ordinal way, so a value it does not
        # count must be refused by the save - for the operator above all.
        # The SAVE refuses it, in its own words, not the approver check: the
        # approver check does not count these values as accepting, and the save
        # is what keeps them out of the plan.
        foreach ($who in $script:operator, $script:approver) {
            foreach ($v in 'PROCEED', ('pro' + [char]0x200B + 'ceed'), ('pro' + [char]0x00AD + 'ceed')) {
                { Invoke-VmfFacadeSetWaves -Principal $who -StorePath $script:run -Note 'x' -Waves @(
                    @{ name = 'billing'; vmIds = @('/s/rg/vm/app01', '/s/rg/vm/app02'); onDDataFound = $v }) } |
                    Should -Throw '*is not a setting for onDDataFound*' -Because "'$v' is not proceed"
            }
        }
        (DecideEntry $script:run 'app01').policy.onDDataFound | Should -Be 'stop'
        (DecideEntry $script:run 'app02').policy.onDDataFound | Should -Be 'stop'
    }

    It 'SECOND REVIEW: the wave approver check counts a value as accepting character for character' {
        # The save above refuses these first, so through the endpoint this
        # check never sees them; asked directly, it must agree with the save
        # and the engine on what IS the accepting value.
        $rp = $script:run
        $got = InModuleScope FacadeCore -Parameters @{ rp = $rp } {
            foreach ($v in 'proceed', 'PROCEED', ('pro' + [char]0x200B + 'ceed'), ('pro' + [char]0x00AD + 'ceed')) {
                @(Get-VmfFacadeDecisionsTaken -StorePath $rp -Requested @{ '/s/rg/vm/app01' = @{ onDDataFound = $v } }).Count
            }
        }
        @($got) | Should -Be @(1, 0, 0, 0)
    }

    It 'THIRD REVIEW: and a machine already holding a value spelt another way is still decided for, by the approver' {
        # The value already stored is compared ordinally too: 'PROCEED' from
        # before is not the accepting value, so writing 'proceed' is a decision
        # and asks for the approver, rather than passing as "already accepted".
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run } {
            $plan = Get-Content (Join-Path $rp 'plan.json') -Raw | ConvertFrom-Json
            ($plan.entries | Where-Object { $_.vmId -eq '/s/rg/vm/app01' }).policy.onDDataFound = 'PROCEED'
            $plan | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $rp 'plan.json')
        }
        $n = InModuleScope FacadeCore -Parameters @{ rp = $script:run } {
            @(Get-VmfFacadeDecisionsTaken -StorePath $rp -Requested @{ '/s/rg/vm/app01' = @{ onDDataFound = 'proceed' } }).Count
        }
        $n | Should -Be 1
    }

    It 'an Operator may still put a gate BACK on, and move machines about' {
        # The guard holds back the ACCEPTING value only. Arranging waves is the
        # operator's whole job, and a guard that refused every save touching a
        # gated lever would take it away.
        Invoke-VmfFacadeSetWaves -Principal $script:operator -StorePath $script:run -Note 'regroup' -Waves @(
            @{ name = 'billing'; vmIds = @('/s/rg/vm/app01', '/s/rg/vm/app02'); onDDataFound = 'stop' },
            @{ name = 'second'; vmIds = @('/s/rg/vm/app03'); onDDataFound = 'stop' }) | Out-Null
        (DecideEntry $script:run 'app03').wave | Should -Be 'second'
        (DecideEntry $script:run 'app01').policy.onDDataFound | Should -Be 'stop'
    }

    It 'and a save that changes nothing about a gate is not a decision' {
        # A wave already on Continue is not being accepted again, so an
        # Operator can still rename it or move machines into it.
        Invoke-VmfFacadeSetWaves -Principal $script:approver -StorePath $script:run -Note 'accepted' -Waves @(
            @{ name = 'billing'; vmIds = @('/s/rg/vm/app01', '/s/rg/vm/app02'); onDDataFound = 'proceed' }) | Out-Null
        { Invoke-VmfFacadeSetWaves -Principal $script:operator -StorePath $script:run -Note 'rename only' -Waves @(
            @{ name = 'billing'; vmIds = @('/s/rg/vm/app01', '/s/rg/vm/app02'); onDDataFound = 'proceed' }) } |
            Should -Not -Throw
    }

    It 'and moving a machine INTO an accepted wave is a decision for that machine' {
        # The value lands on the machines the wave NAMES, so both ways to
        # accept a loss for a machine are covered - setting the gate on its
        # wave, and moving a machine into a wave whose gate is already
        # Continue. The sign-off guard learned this same lesson.
        Invoke-VmfFacadeSetWaves -Principal $script:approver -StorePath $script:run -Note 'accepted for billing' -Waves @(
            @{ name = 'billing'; vmIds = @('/s/rg/vm/app01', '/s/rg/vm/app02'); onDDataFound = 'proceed' },
            @{ name = 'later'; vmIds = @('/s/rg/vm/app03'); onDDataFound = 'stop' }) | Out-Null

        { Invoke-VmfFacadeSetWaves -Principal $script:operator -StorePath $script:run -Note 'move it over' -Waves @(
            @{ name = 'billing'; vmIds = @('/s/rg/vm/app01', '/s/rg/vm/app02', '/s/rg/vm/app03'); onDDataFound = 'proceed' }) } |
            Should -Throw '*403*' -Because 'app03 has not accepted this, and the move would accept it for them'
        (DecideEntry $script:run 'app03').policy.onDDataFound | Should -Be 'stop'
        (DecideEntry $script:run 'app03').wave | Should -Be 'later' -Because 'a refused save writes nothing'
    }
}

Describe 'DECIDE-2: the wave editor does not offer what the facade refuses' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:waves = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'waves.html'))
    }

    It 'the accepting option is locked for a person who cannot sign off' {
        $script:waves | Should -Match 'gateShut = !canSignOff'
        $script:waves | Should -Match "locked = gateShut && v === 'proceed'"
        $script:waves | Should -Match 'gateLocked'
    }

    It 'and a gate already on Continue is left alone' {
        # Disabling the whole select would make the safe direction need a
        # signature, which is the mistake the per-machine guard avoided too.
        $script:waves | Should -Match "\(cur \?\? 'stop'\) !== 'proceed'"
    }

    It 'and the page still SENDS the identity setting it has always sent' {
        # The page was never the broken half. If this ever stops being sent,
        # the facade guard has nothing to guard.
        $script:waves | Should -Match 'onDDataFound: w\.onDDataFound'
    }
}

Describe 'DECIDE-1: the page offers the decision, and not a retry' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:dash = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'migrations.html'))
    }

    It 'the rule that picks the controls is REACHABLE, so a test can run it' {
        # DECIDE-2. The rule lived inline in openDrill - a long async function
        # with a dozen dependencies - so nothing could call it and these tests
        # matched the page's source instead. A source match catches a control
        # that was deleted; it cannot catch one that is wired wrongly, which is
        # the defect this whole item is about.
        #
        # tests/js/stop-controls.test.js RUNS it, eight cases. This checks only
        # that it is still a function the harness can lift and that the page
        # uses its answer rather than working the rule out again.
        $script:dash | Should -Match 'function stopControls\('
        # POWER-ONLY-CHANGED-1: and a fifth argument, the power state a stop could not return the machine to.
        $script:dash | Should -Match 'const offer = stopControls\(doc\.state, lastGuidance, canOperate\(\), canApprove\(\), !!powerOwed\(doc\)\)'
        # ROLLBACK-RETRY-CAPTURE-1: both answers are still used, now also held back
        # where the engine refuses to re-arm the machine (retryHeld).
        # DECIDE-ROLE-1: and only for the park the machine waits at now.
        $script:dash | Should -Match 'decideBtn = \(offer\.decide && !held && decisionWaiting\(doc\) === lastStop\)'
        $script:dash | Should -Match 'resolveBtn = \(offer\.retry && !held\)'
    }

    It 'an operator who cannot decide is TOLD, rather than shown an empty panel' {
        $script:dash | Should -Match 'whyDecideWho'
        # Follows the CHOICE, not the retry kind - so it appears on all three.
        $script:dash | Should -Match '!!g\.decide && !canApprove\(\)'
    }

    It 'the page never names a lever of its own' {
        # The lever comes from the reason. tests/js/decision-gate.test.js RUNS
        # this function and proves it with a second lever; this catches the
        # name being typed back in.
        $decide = [regex]::Match($script:dash, '(?s)function askDecide\(.*?\n\}').Value
        $decide | Should -Not -BeNullOrEmpty
        $decide | Should -Not -Match 'onDDataFound'
        $decide | Should -Match '\[lever\]: accept'
    }

    It 'and the decision line reaches the stop card' {
        # LAB-UX-1: the lines moved to stop-reasons.json (retryLines), which the
        # page and the migration record both read. The page reads it by kind.
        $script:dash | Should -Match 'retryLines\[g\.retry\]'
        $table = Get-Content (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json
        [string]$table.retryLines.decision | Should -Match 'approver decides'
    }
}
