#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    # TEST-1: anything this file forgets to mock must fail as a TEST error,
    # not quietly reach real Azure. Placed before the file's own mocks so
    # those still win where they exist.
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:NewApprovalFixture {
        param($RunPath)
        InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath } {
            Initialize-VmfRun -RunPath $rp -RunId 'appr-test' | Out-Null
        }
        $plan = @{
            schemaVersion = 1; assessmentRunId = 'appr-test'
            entries = @(
                @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/p1'; wave = 'prod-1'; ring = 'prod'; path = 'A'
                   assessment = @{ location = 'centralus' }; target = @{ size = 'Standard_D2s_v6' }
                   policy = @{ requireApproval = $true } },
                @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/c1'; wave = 'canary-1'; ring = 'canary'; path = 'A'
                   assessment = @{ location = 'centralus' }; target = @{ size = 'Standard_D2s_v6' }
                   policy = @{ requireApproval = $false } }
            )
        }
        $planPath = Join-Path $RunPath 'plan.json'
        $plan | ConvertTo-Json -Depth 10 | Set-Content $planPath -Encoding utf8NoBOM
        $planPath
    }
    # ENGINE-SUB-1: these fixtures build machines in 00000000-0000-0000-0000-000000000000.
    # Pin the engine to the same subscription so the cross-subscription
    # guard is not the thing under test here - EngineSubscription.Tests.ps1
    # is where that behaviour is asserted.
    Mock -ModuleName VmMigrationFactory Get-VmfEngineSubscriptionId { '00000000-0000-0000-0000-000000000000' }
    # ENGINE-SUB-1: the state machine now points the PROCESS at each machine's
    # own subscription before doing anything. These fixtures use an invented
    # subscription id, so the switch has to be mocked - these tests are about
    # what the engine DOES, not about whether Azure has heard of the id.
    # EngineSubscription.Tests.ps1 and the cross-subscription lab drill are
    # where the switch itself is proved.
    Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { $null }
    Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
}
AfterAll { Remove-Item 'function:\NewApprovalFixture' -ErrorAction SilentlyContinue }

Describe 'Approve-VmfWave (APPR-1: approval is identity-bound and plan-bound)' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-appr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:planPath = NewApprovalFixture -RunPath $script:runPath
        Mock -ModuleName VmMigrationFactory Get-VmfSignedInIdentity {
            @{ Identity = 'approver@contoso.com'; TenantId = 't-1' }
        }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'writes the approval artifact with the SIGNED-IN identity and the plan hash' {
        $r = Approve-VmfWave -RunPath $script:runPath -PlanPath $script:planPath -Wave 'prod-1' `
            -Note 'canary report reviewed; approved'
        $r.ApprovedBy | Should -Be 'approver@contoso.com'
        $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Read-VmfStoreJson -RunPath $rp -RelPath 'approvals/prod-1.json'
        }
        $doc.approvedBy.identity | Should -Be 'approver@contoso.com'
        $doc.planHash | Should -Match '^[0-9a-f]{64}$'
        $doc.note | Should -Match 'canary report reviewed'
        $doc.wave | Should -Be 'prod-1'
    }

    It '-OnBehalfOf stamps a caller-supplied identity WITHOUT touching the Az context (S3-2 facade path)' {
        Mock -ModuleName VmMigrationFactory Get-VmfSignedInIdentity { throw 'must not be called with -OnBehalfOf' }
        $r = Approve-VmfWave -RunPath $script:runPath -PlanPath $script:planPath -Wave 'prod-1' `
            -Note 'approved from the dashboard' -OnBehalfOf @{ Identity = 'browser-user@contoso.com'; TenantId = 't-9' }
        $r.ApprovedBy | Should -Be 'browser-user@contoso.com'
        $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Read-VmfStoreJson -RunPath $rp -RelPath 'approvals/prod-1.json'
        }
        $doc.approvedBy.identity | Should -Be 'browser-user@contoso.com'
        $doc.approvedBy.tenantId | Should -Be 't-9'
    }

    It 'refuses to approve a wave that is not in the plan' {
        { Approve-VmfWave -RunPath $script:runPath -PlanPath $script:planPath -Wave 'nope-1' -Note 'x' } |
            Should -Throw '*not in the plan*'
    }
}

Describe 'Test-VmfWaveApproval + the Start-VmfWave gate (engine-enforced)' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-apprg-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:planPath = NewApprovalFixture -RunPath $script:runPath
        Mock -ModuleName VmMigrationFactory Get-VmfSignedInIdentity {
            @{ Identity = 'approver@contoso.com'; TenantId = 't-1' }
        }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'fails closed when a requireApproval wave has no approval' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; pp = $script:planPath } {
            $r = Test-VmfWaveApproval -RunPath $rp -PlanPath $pp -Wave 'prod-1'
            $r.Pass | Should -BeFalse
            # APPR-AGREE-1: the PROPERTY, not the sentence. This used to pin
            # 'no approval', which broke when the wording was changed to stop
            # naming a PowerShell cmdlet. What must hold is that the refusal
            # names the wave and points at the control in the app.
            $r.Detail | Should -Match "wave prod-1"
            $r.Detail | Should -Match '(?i)approve'
            $r.Detail | Should -Not -Match 'run [A-Z][a-z]+-Vmf'
        }
    }

    It 'passes with a valid approval and reports the approver' {
        Approve-VmfWave -RunPath $script:runPath -PlanPath $script:planPath -Wave 'prod-1' -Note 'ok' | Out-Null
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; pp = $script:planPath } {
            $r = Test-VmfWaveApproval -RunPath $rp -PlanPath $pp -Wave 'prod-1'
            $r.Pass | Should -BeTrue
            $r.Detail | Should -Match 'approver@contoso\.com'
        }
    }

    It 'a changed plan INVALIDATES an existing approval (hash binding)' {
        Approve-VmfWave -RunPath $script:runPath -PlanPath $script:planPath -Wave 'prod-1' -Note 'ok' | Out-Null
        $plan = Get-Content $script:planPath -Raw | ConvertFrom-Json -Depth 10
        $plan.entries[0].target.size = 'Standard_D4s_v6'
        $plan | ConvertTo-Json -Depth 10 | Set-Content $script:planPath -Encoding utf8NoBOM
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; pp = $script:planPath } {
            $r = Test-VmfWaveApproval -RunPath $rp -PlanPath $pp -Wave 'prod-1'
            $r.Pass | Should -BeFalse
            # The property: it says the PLAN moved, names the wave, and sends
            # the reader back to the control rather than to a cmdlet.
            $r.Detail | Should -Match '(?i)plan changed|plan has changed'
            $r.Detail | Should -Match "wave prod-1"
            $r.Detail | Should -Not -Match 'run [A-Z][a-z]+-Vmf'
        }
    }

    It 'only an EXPLICIT requireApproval=false switches the gate off' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; pp = $script:planPath } {
            (Test-VmfWaveApproval -RunPath $rp -PlanPath $pp -Wave 'canary-1').Pass | Should -BeTrue
        }
    }

    It 'a wave that says NOTHING about approval still requires it (WAVE-2 lever 2)' {
        # Approval defaults ON (ruled). The old reading - absent means
        # not required - meant a hand-written or half-migrated plan silently
        # lost the gate, which is the exact direction this gate protects.
        $plan = Get-Content $script:planPath -Raw | ConvertFrom-Json -Depth 10
        foreach ($e in $plan.entries) {
            $e.policy = [pscustomobject]@{ safetyCopy = 'pristine' }   # no requireApproval key at all
        }
        $plan | ConvertTo-Json -Depth 10 | Set-Content $script:planPath -Encoding utf8NoBOM
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; pp = $script:planPath } {
            $r = Test-VmfWaveApproval -RunPath $rp -PlanPath $pp -Wave 'canary-1'
            $r.Pass | Should -BeFalse
            $r.Detail | Should -Match "wave canary-1"
            $r.Detail | Should -Match '(?i)approve'
        }
    }

    It 'IAC-2: the run acknowledgement is required BEFORE any wave gate' {
        # Accepting the terms of the run comes before approving a wave within
        # it, so this fires first - and it fires for every wave, approved or not.
        { Start-VmfWave -PlanPath $script:planPath -Wave 'prod-1' -RunPath $script:runPath -SkipCapacityGate } |
            Should -Throw 'Nobody accepted the note about machines defined in code*'
    }

    It 'WAVE-2: the options gate fires after the acknowledgement and before approval' {
        # Defaults exist, but a default nobody looked at is a decision nobody
        # made - the wave refuses to start until its levers are accepted.
        Confirm-VmfRunAcknowledgement -RunPath $script:runPath -AcknowledgedBy 'test@contoso.com' -Confirm:$false | Out-Null
        { Start-VmfWave -PlanPath $script:planPath -Wave 'prod-1' -RunPath $script:runPath -SkipCapacityGate } |
            Should -Throw 'Nobody accepted the settings of wave*'
    }

    It 'Start-VmfWave refuses an unapproved requireApproval wave before doing ANYTHING' {
        # Acknowledge and accept options first, so this test still exercises
        # the APPROVAL gate rather than stopping at the ones in front of it.
        Confirm-VmfRunAcknowledgement -RunPath $script:runPath -AcknowledgedBy 'test@contoso.com' -Confirm:$false | Out-Null
        Confirm-VmfWaveOptions -RunPath $script:runPath -PlanPath $script:planPath -Wave 'prod-1' -AcceptedBy 'test@contoso.com' -Confirm:$false | Out-Null
        { Start-VmfWave -PlanPath $script:planPath -Wave 'prod-1' -RunPath $script:runPath -SkipCapacityGate } |
            Should -Throw 'Nobody approved wave*'
    }

    It 'requireApproval is a per-wave lever with an explicit default (WAVE-2)' {
        # There is no prod ring to hang "approval required" on any more - the
        # customer sets it per wave in the editor. The default set carries the
        # key explicitly (PROVISIONAL default pending a per-lever
        # review), and the GATE itself is what the rest of this file proves.
        InModuleScope VmMigrationFactory {
            (Get-VmfDefaultWavePolicy).ContainsKey('requireApproval') | Should -BeTrue
        }
    }

    It 'sample approval document validates against the schema' {
        $root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
        $ok = Get-Content (Join-Path $root 'schemas' 'samples' 'wave-approval.sample.json') -Raw |
            Test-Json -SchemaFile (Join-Path $root 'schemas' 'wave-approval.schema.json')
        $ok | Should -BeTrue
    }
}

Describe 'IAC-2: the acknowledgement is a gate, not a checkbox' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:root2 = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
        $script:facadeSrc = Get-Content (Join-Path $script:root2 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1') -Raw
        $script:wizardSrc = (Get-VmfPageSource -Path (Join-Path $script:root2 'src' 'dashboard' 'wizard.html'))
        $script:orch = Get-Content (Join-Path $script:root2 'src' 'VmMigrationFactory' 'Private' 'engine' 'Orchestrator.ps1') -Raw
    }

    It 'the ENGINE refuses, so the API path cannot skip it' {
        # A wizard-only gate is bypassed by anyone starting a run through the
        # facade - which is how the engine job actually runs.
        $sw = Get-Content (Join-Path $script:root2 'src' 'VmMigrationFactory' 'Public' 'Start-VmfWave.ps1') -Raw
        $sw | Should -Match 'Test-VmfRunAcknowledged'
        $script:orch | Should -Match 'function Test-VmfRunAcknowledged'
    }

    It 'one acknowledgement covers the RUN, not each wave' {
        # Asking per wave would train people to click it without reading.
        $script:orch | Should -Match "acknowledgements/infrastructure-as-code\.json"
        $script:orch | Should -Match '(?i)covers the run, not each wave'
    }

    It 'the identity comes from the signed-in principal, never the request body' {
        # An acknowledgement someone can attribute to a name they typed is not
        # an audit trail. Same rule as the wave approvals.
        $script:facadeSrc | Should -Match '\$identity = \[string\]\$Principal\.Identity'
        $script:facadeSrc | Should -Match '(?i)never from the request body|from the validated principal'
    }

    It 'the wording is defined ONCE and shared by every surface' {
        # A gate whose words drift between the wizard, the CLI and the engine's
        # refusal is a gate nobody can be held to.
        $script:orch | Should -Match 'function Get-VmfIacStatement'
        $cmd = Get-Content (Join-Path $script:root2 'src' 'VmMigrationFactory' 'Public' 'Confirm-VmfRunAcknowledgement.ps1') -Raw
        $cmd | Should -Match 'Get-VmfIacStatement'
    }

    It 'and the statement shown is STORED with the acceptance' {
        # If the wording changes later, the record still says what THIS person
        # agreed to.
        $schema = Get-Content (Join-Path $script:root2 'schemas' 'run-acknowledgement.schema.json') -Raw | ConvertFrom-Json
        @($schema.required) | Should -Contain 'statement'
        @($schema.required) | Should -Contain 'acknowledgedBy'
    }

    It 'the wizard asks before starting, rather than being refused afterwards' {
        $script:wizardSrc | Should -Match 'f-ack'
        $script:wizardSrc | Should -Match 'runs/\$\{runSeg\(\)\}/acknowledge'
        # IAC-NOTE-LIST-1: the note's closing line, in the approved words.
        $script:wizardSrc | Should -Match 'Reconcile your definitions after the migration\.'
    }

    It 'and it will not start the wave without it' {
        $script:wizardSrc | Should -Match "if \(!acknowledged && !\`$\('#f-ack'\)\?\.checked\) return fail"
    }
}

# APPR-2: the approval must be bound to the plan version the approver was
# SHOWN, not to whatever plan.json says when the POST lands. Scan finding F1,
# unanimous. Without this an operator can rewrite a wave while the approve
# dialog is open and have the approver's click sign machines they refused.
Describe 'Approve-VmfWave -ExpectedPlanHash (APPR-2: the signature is bound to what was on screen)' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-appr2-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:planPath = NewApprovalFixture -RunPath $script:runPath
        Mock -ModuleName VmMigrationFactory Get-VmfSignedInIdentity {
            @{ Identity = 'approver@contoso.com'; TenantId = 't-1' }
        }
        $script:planHashNow = {
            $bytes = [System.IO.File]::ReadAllBytes($script:planPath)
            $text = [System.Text.Encoding]::UTF8.GetString($bytes)
            if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try {
                ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text)) |
                    ForEach-Object { $_.ToString('x2') }) -join ''
            }
            finally { $sha.Dispose() }
        }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'approves when the hash matches the plan it is about to sign' {
        $hash = & $script:planHashNow
        $r = Approve-VmfWave -RunPath $script:runPath -PlanPath $script:planPath -Wave 'prod-1' `
            -Note 'reviewed with the app owners' -ExpectedPlanHash $hash
        $r.PlanHash | Should -Be $hash
        $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Read-VmfStoreJson -RunPath $rp -RelPath 'approvals/prod-1.json'
        }
        $doc.planHash | Should -Be $hash
    }

    It 'REFUSES with 409 when the plan changed since it was shown, and writes NO approval' {
        $stale = & $script:planHashNow
        # the operator rewrites the wave while the dialog is open
        $plan = Get-Content $script:planPath -Raw | ConvertFrom-Json -Depth 24
        $plan.entries[1].wave = 'prod-1'
        $plan | ConvertTo-Json -Depth 10 | Set-Content $script:planPath -Encoding utf8NoBOM
        (& $script:planHashNow) | Should -Not -Be $stale   # the fixture really did change

        $err = $null
        try {
            Approve-VmfWave -RunPath $script:runPath -PlanPath $script:planPath -Wave 'prod-1' `
                -Note 'reviewed with the app owners' -ExpectedPlanHash $stale
        }
        catch { $err = "$_" }

        $err | Should -Not -BeNullOrEmpty
        # Read the message clause by clause: -Throw matches case-insensitively
        # and a single wildcard passes on almost any wording (a weak assertion
        # of exactly this shape survived mutation once already).
        $err | Should -BeLike '409:*'
        $err | Should -BeLike '*plan*'
        $err | Should -BeLike '*changed*'
        $err | Should -BeLike '*approved*'

        $written = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Read-VmfStoreJson -RunPath $rp -RelPath 'approvals/prod-1.json'
        }
        $written | Should -BeNullOrEmpty
    }

    It 'still approves with no hash at all - the command line is not in this race' {
        $r = Approve-VmfWave -RunPath $script:runPath -PlanPath $script:planPath -Wave 'prod-1' `
            -Note 'approved at the terminal from the plan file I just read'
        $r.PlanHash | Should -Match '^[0-9a-f]{64}$'
    }

    It 'does not write an event for a refused approval' {
        $stale = 'f' * 64
        try {
            Approve-VmfWave -RunPath $script:runPath -PlanPath $script:planPath -Wave 'prod-1' `
                -Note 'x' -ExpectedPlanHash $stale
        }
        catch { }
        $events = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            @(Read-VmfEvents -RunPath $rp -Step 'approval')
        }
        $events.Count | Should -Be 0
    }
}

# APPR-2: the PowerShell half of the cross-language agreement.
# tests/js/plan-hash.test.js pins the BROWSER's sha256Hex to the same two
# constants. The two languages never meet in a test, so the shared constant is
# the only thing holding them together - if one side drifts, one of the two
# files fails and names the other.
Describe 'plan hash agreement (APPR-2: PowerShell and the browser must agree byte for byte)' {
    It 'hashes the shared constant to the value the browser produces' {
        # KEEP IN STEP with KNOWN_TEXT / KNOWN_HASH in tests/js/plan-hash.test.js.
        $knownPlanText = '{"schemaVersion":1,"entries":[]}'
        $knownPlanHash = 'e13d010a6007fa2889ca3ee584f5259a09ff8f9bf5f3ab62ff2f264eef882047'
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $got = ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($knownPlanText)) |
                ForEach-Object { $_.ToString('x2') }) -join ''
        }
        finally { $sha.Dispose() }
        $got | Should -Be $knownPlanHash
    }

    It 'and Approve-VmfWave writes exactly that hash for exactly that plan' {
        # The agreement above is about an algorithm. This is about the PRODUCT:
        # the hash the approval carries must be the hash of the plan file's own
        # bytes, not of a re-serialised object.
        $runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-apprh-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $runPath } {
                Initialize-VmfRun -RunPath $rp -RunId 'hash-test' | Out-Null
            }
            Mock -ModuleName VmMigrationFactory Get-VmfSignedInIdentity {
                @{ Identity = 'approver@contoso.com'; TenantId = 't-1' }
            }
            $planFile = Join-Path $runPath 'plan.json'
            $text = '{"schemaVersion":1,"assessmentRunId":"hash-test","entries":[{"schemaVersion":' + (Get-VmfTestPlanEntryVersion) + ',"vmId":"/s/rg/vm/v1","wave":"w-1"}]}'
            [System.IO.File]::WriteAllText($planFile, $text, (New-Object System.Text.UTF8Encoding($false)))

            $sha = [System.Security.Cryptography.SHA256]::Create()
            try {
                $expected = ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text)) |
                    ForEach-Object { $_.ToString('x2') }) -join ''
            }
            finally { $sha.Dispose() }

            $r = Approve-VmfWave -RunPath $runPath -PlanPath $planFile -Wave 'w-1' `
                -Note 'the bytes on disk are what gets signed' -ExpectedPlanHash $expected
            $r.PlanHash | Should -Be $expected
        }
        finally { if (Test-Path $runPath) { Remove-Item $runPath -Recurse -Force } }
    }
}

Describe 'ACCEPT-EVIDENCE-1: a refusal names what it compared' {
    # MEASURED on a real install, 2026-09-17. The flow drill sent a plan
    # version and the service answered:
    #
    #   409: the wave changed after its settings were shown, so nothing was
    #        accepted. Look at wave 'wave-1' again and accept it once you are
    #        content with it.
    #
    # TWO DIFFERENT THINGS PRODUCE THAT SENTENCE. The plan really moved under
    # the caller - look again, accept again, done. Or the two sides disagree
    # about how to READ the plan, and looking again will never help, because
    # the next attempt computes the same version and is refused the same way.
    # The message could not tell them apart, so a person meeting the second
    # one follows advice that cannot work.
    #
    # A plan version is not a secret: the caller computed one to get here.

    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
        $script:gates = @('Confirm-VmfWaveOptions.ps1', 'Approve-VmfWave.ps1') | ForEach-Object {
            [pscustomobject]@{
                Name = $_
                Code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' $_)
            }
        }
    }

    It 'both gates that bind an action to a plan version were found' {
        @($script:gates).Count | Should -Be 2
        foreach ($gate in $script:gates) {
            $gate.Code | Should -Match 'ExpectedPlanHash' -Because "$($gate.Name) must still carry the gate"
        }
    }

    It 'each refusal names the version it holds AND the one it was given' {
        foreach ($gate in $script:gates) {
            $gate.Code | Should -Match 'Get-VmfShortHash \$planHash' `
                -Because "$($gate.Name) must say what the plan reads now"
            $gate.Code | Should -Match 'Get-VmfShortHash \$ExpectedPlanHash' `
                -Because "$($gate.Name) must say what the caller sent"
        }
    }

    It 'and a missing half is SAID, never quietly dropped' {
        # A message that prints an empty string for one side of a comparison
        # names no evidence at all, which is the defect this closes.
        InModuleScope VmMigrationFactory {
            Get-VmfShortHash -Hash '' | Should -BeExactly 'nothing'
            Get-VmfShortHash -Hash $null | Should -BeExactly 'nothing'
            Get-VmfShortHash -Hash '0123456789abcdef0123' | Should -BeExactly '0123456789ab'
            # Shorter than the cut is returned whole rather than throwing on
            # Substring, which is how a diagnostic becomes the thing that fails.
            Get-VmfShortHash -Hash 'abc' | Should -BeExactly 'abc'
        }
    }

    It 'the refusal still REFUSES - the evidence is added, not swapped in' {
        foreach ($gate in $script:gates) {
            $gate.Code | Should -Match 'if \(\$ExpectedPlanHash -and \$ExpectedPlanHash -ne \$planHash\)' `
                -Because "$($gate.Name) must still compare before it writes anything"
            $gate.Code | Should -Match '409:' -Because "$($gate.Name) must still answer 409"
        }
    }
}

# PUBLIC-SYNC-1: the drills do not ship to the public repository.
Describe 'ACCEPT-HASH-1: the drill and the ENGINE agree on a plan version' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' 'lab'))) {
    # NARROWING A LIVE DEFECT WITHOUT AZURE, 2026-09-17. The flow drill sends a
    # plan version and the deployed service answers 409. There are only two
    # ways that happens:
    #
    #   1. the two sides compute the version DIFFERENTLY, or
    #   2. they are reading different TEXT.
    #
    # This settles (1) offline, so what remains is (2). The drill's function is
    # run against the ENGINE'S OWN GATE - the real Confirm-VmfWaveOptions, on a
    # real store on disk - rather than against a copy of the algorithm. Two
    # implementations agreeing in a test that restates both is worth nothing.
    #
    # It is also the gate every future change has to keep passing: the browser,
    # the drill and the engine all compute this, and any two of them drifting
    # is an acceptance nobody can complete.

    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        . (Join-Path $PSScriptRoot '..' 'lab' '_FacadeApi.ps1')

        $script:agreeRun = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-agree-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:agreeRun -Force | Out-Null
        $script:agreePlan = Join-Path $script:agreeRun 'plan.json'

        $plan = [ordered]@{
            schemaVersion = 1
            assessmentRunId = 'agree-assessment'
            entries       = @(
                [ordered]@{
                    schemaVersion  = (Get-VmfTestPlanEntryVersion)
                    vmName         = 'app01'; wave = 'wave-1'
                    resourceGroup  = 'rg-one'; subscriptionId = '00000000-0000-0000-0000-000000000000'
                    sourceSize     = 'Standard_D2ds_v4'; targetSize = 'Standard_D2ds_v6'
                    path           = 'A'; controller = 'NVMe'
                })
        }
        $plan | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:agreePlan -Encoding utf8NoBOM
        $script:wrongHash = 'a' * 64
        $script:otherHash = 'b' * 64
    }

    AfterAll {
        if ($script:agreeRun -and (Test-Path -LiteralPath $script:agreeRun)) {
            Remove-Item -LiteralPath $script:agreeRun -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'the store this runs against really holds a plan' {
        Test-Path -LiteralPath $script:agreePlan | Should -BeTrue
        (Get-Content -LiteralPath $script:agreePlan -Raw) | Should -Match 'app01'
    }

    It 'THE ENGINE ACCEPTS the version the drill computes, on the same text' {
        # The whole point. If these two disagreed, every acceptance from a
        # drill would answer 409 for ever, and no amount of looking at the wave
        # again would help.
        $text = Get-Content -LiteralPath $script:agreePlan -Raw
        $fromDrill = Get-VmfPlanVersion -PlanText $text
        { Confirm-VmfWaveOptions -RunPath $script:agreeRun -PlanPath $script:agreePlan `
                -Wave 'wave-1' -AcceptedBy 'drill@contoso.com' -ExpectedPlanHash $fromDrill -Confirm:$false } |
            Should -Not -Throw
    }

    It 'and REFUSES a version it does not hold, so the check above means something' {
        # Without this, a gate that accepted anything would pass the test above
        # and prove nothing at all.
        { Confirm-VmfWaveOptions -RunPath $script:agreeRun -PlanPath $script:agreePlan `
                -Wave 'wave-1' -AcceptedBy 'drill@contoso.com' -ExpectedPlanHash $script:wrongHash -Confirm:$false } |
            Should -Throw '*409*'
    }

    It 'and the refusal says WHAT it compared, so a mismatch can be diagnosed' {
        # ACCEPT-EVIDENCE-1, driven through the real gate rather than read off
        # the source: the message has to carry both versions.
        $threw = $null
        try {
            Confirm-VmfWaveOptions -RunPath $script:agreeRun -PlanPath $script:agreePlan `
                -Wave 'wave-1' -AcceptedBy 'drill@contoso.com' -ExpectedPlanHash $script:otherHash -Confirm:$false
        }
        catch { $threw = "$_" }
        $threw | Should -Not -BeNullOrEmpty
        # DOC-ADDRESS-1 added the address, so the message names WHERE as well
        # as WHAT. Both halves are required here, because the run that cost
        # five live attempts had the version and not the path.
        $threw | Should -Match "The plan at '.+' now reads [0-9a-f]{12}"
        $threw | Should -Match 'the caller sent bbbbbbbbbbbb'
    }

    It 'a mark or a trailing newline changes the version, which is why the text must be exact' {
        # Each is ONE character: invisible in the text, total in the hash. This
        # is what the drill prints as candidates when a live accept answers 409,
        # and it is driven here so those candidates are known to differ rather
        # than assumed to.
        $text = Get-Content -LiteralPath $script:agreePlan -Raw
        $plain = Get-VmfPlanVersion -PlanText $text
        $withMark = Get-VmfPlanVersion -PlanText ([char]0xFEFF + $text)
        $withNewline = Get-VmfPlanVersion -PlanText ($text + "`n")
        $plain | Should -Not -BeExactly $withMark
        $plain | Should -Not -BeExactly $withNewline
        $withMark | Should -Not -BeExactly $withNewline
    }
}


Describe 'DOC-ADDRESS-1: a refusal about a document NAMES the document' {
    # FOUND 2026-09-17, after five live runs to diagnose one 409: the refusal
    # did not carry the details needed to trace it, which made it fragile.
    #
    # The proof is two lines apart in one file:
    #
    #   line 55  "No plan found at '$PlanPath'."           names the document
    #   line 68  "the wave changed after its settings..."  names neither
    #
    # Same function. The document's address is in scope at both. The refusal
    # that actually fired threw it away, so five runs against a corporate
    # subscription went into rediscovering something the service knew at the
    # time and discarded.
    #
    # THE RULE ALREADY EXISTED FOR RESOURCES - the standing rule that
    # every action addresses the Azure resource id. It was never written down
    # for DOCUMENTS, so it was applied wherever somebody happened to think of
    # it: twice out of three times in this very file.
    #
    # A refusal that names no evidence cannot be acted on. A refusal that names
    # a version but not the document says WHAT differed and not WHERE, which is
    # the half that takes five runs to find.

    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
        # The gates that read a plan and can refuse over it, found by looking
        # for the parameter rather than by naming files.
        $script:planGates = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public') -Filter '*.ps1' |
            Where-Object { (Get-VmfCodeOnly -Path $_.FullName) -match '\$PlanPath' })
    }

    It 'found the gates that read a plan, or nothing below proves anything' {
        @($script:planGates).Count | Should -BeGreaterThan 2
        @($script:planGates.Name) | Should -Contain 'Confirm-VmfWaveOptions.ps1'
        @($script:planGates.Name) | Should -Contain 'Approve-VmfWave.ps1'
    }

    It 'every refusal that talks about the plan says WHERE the plan is' {
        # Read with the PARSER: a throw is a statement, and its message is an
        # expression. A text search cannot tell a throw from a sentence about
        # one, and this file has already paid for that twice today.
        $missing = foreach ($gate in $script:planGates) {
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $gate.FullName, [ref]$tokens, [ref]$parseErrors)
            if (@($parseErrors).Count -gt 0) { continue }
            foreach ($thrown in $ast.FindAll({ param($node)
                        $node -is [System.Management.Automation.Language.ThrowStatementAst] }, $true)) {
                $message = $thrown.Pipeline.Extent.Text
                # SCOPED TO THE CLASS WHERE "WHICH ONE?" IS THE MISSING HALF,
                # and the first version was not. It asked every message
                # mentioning a plan to name a path, and caught seven that have
                # no such ambiguity: a wave with no entries names the WAVE, a
                # machine with a broken resource id names the MACHINE, an
                # unreviewed assessment names the ASSESSMENT. Each already
                # names the thing a person would go and look at.
                #
                # A rule that demands a path from all of them is one nobody can
                # follow, and a rule nobody can follow gets worked around.
                #
                # The class is narrower: a refusal that reports the CONTENT of
                # a document - its version, or that it could not be read - is
                # useless without the document's address. That is the message
                # that cost five live runs.
                if ($message -notmatch 'planHash|ExpectedPlanHash|Get-VmfShortHash|No plan found') { continue }
                if ($message -notmatch '\$PlanPath') {
                    "$($gate.Name):$($thrown.Extent.StartLineNumber) - $($message.Trim() -replace '\s+', ' ')"
                }
            }
        }
        @($missing) | Should -BeNullOrEmpty `
            -Because 'a refusal that says what differed but not where takes five live runs to place'
    }

    It 'and the two that fired tonight carry it' {
        # Named on purpose, because these are the specimens. If the rule above
        # is ever loosened, this says which messages it was written for.
        foreach ($name in 'Confirm-VmfWaveOptions.ps1', 'Approve-VmfWave.ps1') {
            $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' $name)
            $code | Should -Match "The plan at '\`$PlanPath' now reads" -Because "$name refuses over a plan version"
        }
    }

    It 'the rule can tell a plan refusal from any other one' {
        # Driven on source text, so it keeps working when the messages change.
        # Without this the rule could be "every throw names a path", which
        # nothing could satisfy and everybody would work around.
        $rule = { param($text) $text -match 'plan' -and $text -notmatch '\$PlanPath' }
        (& $rule '"409: the plan changed"') | Should -BeTrue
        (& $rule '"409: the plan at ''$PlanPath'' changed"') | Should -BeFalse
        (& $rule '"401: the acceptance must name the signed-in person"') | Should -BeFalse
    }
}
