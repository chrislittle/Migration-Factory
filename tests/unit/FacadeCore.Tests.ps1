#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    # COMMENT-TRAP-1: the one way this file reads code without its comments.
    #
    # Dot-sourced at the TOP, not inside a Describe. It lived in one Describe's
    # BeforeAll first, and every other Describe in the file could not see it -
    # which surfaced as a check on a completely unrelated rule failing with no
    # mention of a missing function.
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    # TEST-1: anything this file forgets to mock must fail as a TEST error,
    # not quietly reach real Azure. Placed before the file's own mocks so
    # those still win where they exist.
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    # Az is not installed in CI, so the facade tests mock a stand-in. TEST-AZURE-GUARD-1: it is
    # defined here, BEFORE the guard, so the guard mock and the tests' own mocks take one shape.
    function Global:Invoke-AzRestMethod { param($Method, $Path, $Payload) throw 'stub' }
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # ENGINE-START-PART-1: a wave start asks Azure whether an execution of its
    # wave runs (Test-VmfFacadeEngineRunning, through the module's ARM list).
    # Here none does, unless a test says otherwise with its own mock.
    Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod -ParameterFilter { [string]$Path -match '/executions\?' } {
        [pscustomobject]@{ StatusCode = 200; Content = '{"value":[]}' }
    }

    function Global:NewPrincipalHeader {
        param([string]$Identity = 'viewer@contoso.com', [string[]]$Roles = @('Vmf.Viewer'))
        $claims = @(
            @{ typ = 'preferred_username'; val = $Identity }
        ) + @($Roles | ForEach-Object { @{ typ = 'roles'; val = $_ } })
        $doc = @{ auth_typ = 'aad'; claims = $claims } | ConvertTo-Json -Depth 5
        [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($doc))
    }
    # APPR-2: the same hash the engine computes over plan.json, and the same
    # one the browser computes with crypto.subtle - SHA-256 over the UTF-8
    # text, hex, lower case.
    function Global:PlanHashOf {
        param([string]$PlanFile)
        $text = Get-Content $PlanFile -Raw
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text)) |
                ForEach-Object { $_.ToString('x2') }) -join ''
        }
        finally { $sha.Dispose() }
    }
}
AfterAll { Remove-Item 'function:\NewPrincipalHeader', 'function:\PlanHashOf', 'function:\Invoke-AzRestMethod' -ErrorAction SilentlyContinue }

Describe 'ConvertFrom-VmfClientPrincipal (Easy Auth header parsing)' {
    It 'extracts identity and roles from the x-ms-client-principal header' {
        $p = ConvertFrom-VmfClientPrincipal -Header (NewPrincipalHeader -Identity 'operator@contoso.com' -Roles @('Vmf.Approver', 'Vmf.Viewer'))
        $p.Identity | Should -Be 'operator@contoso.com'
        @($p.Roles) | Should -Contain 'Vmf.Approver'
        @($p.Roles) | Should -Contain 'Vmf.Viewer'
    }

    It 'returns null for a missing or garbage header (unauthenticated)' {
        ConvertFrom-VmfClientPrincipal -Header $null | Should -BeNullOrEmpty
        ConvertFrom-VmfClientPrincipal -Header 'not-base64!!' | Should -BeNullOrEmpty
    }
}

Describe 'Assert-VmfFacadeRole (role enforcement)' {
    It 'passes when the principal holds ANY of the required roles' {
        $p = ConvertFrom-VmfClientPrincipal -Header (NewPrincipalHeader -Roles @('Vmf.Operator'))
        { Assert-VmfFacadeRole -Principal $p -AnyOf @('Vmf.Admin', 'Vmf.Operator') } | Should -Not -Throw
    }

    It 'throws 403-shaped when the role is missing' {
        $p = ConvertFrom-VmfClientPrincipal -Header (NewPrincipalHeader -Roles @('Vmf.Viewer'))
        { Assert-VmfFacadeRole -Principal $p -AnyOf @('Vmf.Approver') } | Should -Throw '*403*'
    }

    It 'throws 401-shaped when unauthenticated' {
        { Assert-VmfFacadeRole -Principal $null -AnyOf @('Vmf.Viewer') } | Should -Throw '*401*'
    }
}

Describe 'Get-VmfFacadeStorePath' {
    It 'accepts an EMPTY run id for container-level operations (live-smoke regression)' {
        # A TestDrive folder, never a drive-root one (TEST-WRITES-OUTSIDE-TESTDRIVE-1).
        $store = Join-Path $TestDrive 'store'
        $env:VMF_STORE_PATH = $store
        try {
            Get-VmfFacadeStorePath -RunId '' | Should -Be $store
            Get-VmfFacadeStorePath -RunId 'run-1' | Should -Be (Join-Path $store 'run-1')
        }
        finally { Remove-Item Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue }
    }
}

Describe 'S3-2 action functions: role-enforced writes of contract artifacts' {
    BeforeEach {
        $script:storeRoot = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-fact-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:runPath = Join-Path $script:storeRoot 'run-a'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Initialize-VmfRun -RunPath $rp -RunId 'run-a' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'run-a' -VmId '/s/rg/vm/vm1' -Wave 'prod-1' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId '/s/rg/vm/vm1' -NewState 'NEEDS_DECISION' -Outcome ok -Detail 'parked' | Out-Null
        }
        @{ schemaVersion = 1; assessmentRunId = 'run-a'; entries = @(
            @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/s/rg/vm/vm1'; wave = 'prod-1'; ring = 'prod'; path = 'A'; assessment = @{}; target = @{ size = 's' }
               policy = @{ requireApproval = $true; onDDataFound = 'stop' } }
        ) } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $script:runPath 'plan.json')
        $script:approver = ConvertFrom-VmfClientPrincipal -Header (NewPrincipalHeader -Identity 'appr@example.com' -Roles @('Vmf.Approver'))
        $script:operator = ConvertFrom-VmfClientPrincipal -Header (NewPrincipalHeader -Identity 'oper@example.com' -Roles @('Vmf.Operator'))
        $script:viewer   = ConvertFrom-VmfClientPrincipal -Header (NewPrincipalHeader -Identity 'view@example.com' -Roles @('Vmf.Viewer'))
    }
    AfterEach { if (Test-Path $script:storeRoot) { Remove-Item $script:storeRoot -Recurse -Force } }

    It 'approve requires Vmf.Approver and stamps the ACTING user' {
        $hash = PlanHashOf (Join-Path $script:runPath 'plan.json')
        { Invoke-VmfFacadeApprove -Principal $script:viewer -StorePath $script:runPath -Wave 'prod-1' -Note 'x' -PlanHash $hash } |
            Should -Throw '*403*'
        $r = Invoke-VmfFacadeApprove -Principal $script:approver -StorePath $script:runPath -Wave 'prod-1' -Note 'reviewed' -PlanHash $hash
        $r.ApprovedBy | Should -Be 'appr@example.com'
        (InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Read-VmfStoreJson -RunPath $rp -RelPath 'approvals/prod-1.json'
        }).approvedBy.identity | Should -Be 'appr@example.com'
    }

    # APPR-2: the browser is the racing path, so the hash is MANDATORY here
    # even though the cmdlet lets a terminal caller omit it.
    It 'approve REFUSES a plan that changed while the approver was deciding' {
        $stale = PlanHashOf (Join-Path $script:runPath 'plan.json')
        # the operator adds a machine to the wave - no approver involved
        $planFile = Join-Path $script:runPath 'plan.json'
        $plan = Get-Content $planFile -Raw | ConvertFrom-Json -Depth 24
        $plan.entries += @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/s/rg/vm/sneaked-in'; wave = 'prod-1'; ring = 'prod'; path = 'A'
                            assessment = @{}; target = @{ size = 's' }; policy = @{ requireApproval = $true } }
        $plan | ConvertTo-Json -Depth 8 | Set-Content $planFile
        (PlanHashOf $planFile) | Should -Not -Be $stale

        $err = $null
        try {
            Invoke-VmfFacadeApprove -Principal $script:approver -StorePath $script:runPath `
                -Wave 'prod-1' -Note 'reviewed' -PlanHash $stale
        }
        catch { $err = "$_" }
        $err | Should -BeLike '409:*'
        $err | Should -BeLike '*plan*'
        $err | Should -BeLike '*changed*'
        # and the machine the approver never saw is NOT covered by an approval
        (InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Read-VmfStoreJson -RunPath $rp -RelPath 'approvals/prod-1.json'
        }) | Should -BeNullOrEmpty
    }

    # FOUND BY MUTATION. Dropping Mandatory from -PlanHash was MISSED by every
    # other test here: they all pass a hash, so making it optional broke
    # nothing they assert. An optional binding is the whole defect coming back
    # - a caller that omits it approves against whatever plan.json holds when
    # the request lands, which is exactly what F1 described.
    # Asserted on the parameter metadata rather than by calling without it: a
    # missing mandatory parameter PROMPTS on an interactive host, and a test
    # that can hang the suite is worse than the bug it catches.
    It 'the plan hash is MANDATORY on the facade path, not merely accepted' {
        $planHashParam = (Get-Command Invoke-VmfFacadeApprove).Parameters['PlanHash']
        $planHashParam | Should -Not -BeNullOrEmpty -Because 'the facade must take a plan hash at all'
        $mandatory = @($planHashParam.Attributes |
            Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
            ForEach-Object { $_.Mandatory })
        $mandatory | Should -Contain $true -Because 'the browser is the racing path and must say what it signed'
    }

    It 'and the HTTP route refuses a body with no plan hash, and answers 409 rather than 500' {
        # The route is a thin wrapper with no seam to call, so this reads it -
        # with the COMMENTS STRIPPED, because this file explains the rule in
        # prose right beside the code and a whole-file match would find its own
        # explanation and pass either way (COMMENT-TRAP-1).
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $route = Get-VmfCodeOnly -Path (Join-Path $PSScriptRoot '..' '..' 'src' 'facade' 'app' 'PostApprove' 'run.ps1')
        # Match the GUARD, not just the words. `$body.planHash` alone is
        # satisfied by the call line further down, so removing the check
        # entirely still passed - found by mutation, twice over.
        $route | Should -Match 'if \(-not \$body\.planHash\) \{ throw ''400:'
        $route | Should -Match '-PlanHash \$body\.planHash'
        $route | Should -Match "'\^409'"
        $route | Should -Match 'HttpStatusCode\]::Conflict'
    }

    It 'the role check runs BEFORE the plan-hash check, so a viewer learns nothing about the plan' {
        $err = $null
        try {
            Invoke-VmfFacadeApprove -Principal $script:viewer -StorePath $script:runPath `
                -Wave 'prod-1' -Note 'x' -PlanHash ('0' * 64)
        }
        catch { $err = "$_" }
        $err | Should -BeLike '*403*'
        $err | Should -Not -BeLike '409:*'
    }

    It 'halt + clear-halt require Vmf.Operator and record the acting user' {
        { Invoke-VmfFacadeHalt -Principal $script:approver -StorePath $script:runPath -Note 'x' } | Should -Throw '*403*'
        Invoke-VmfFacadeHalt -Principal $script:operator -StorePath $script:runPath -Note 'pausing for review' | Out-Null
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Test-VmfWaveHalted -RunPath $rp | Should -BeTrue
        }
        $r = Invoke-VmfFacadeClearHalt -Principal $script:operator -StorePath $script:runPath -Note 'resuming'
        $r.WasHalted | Should -BeTrue
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Test-VmfWaveHalted -RunPath $rp | Should -BeFalse
            $halts = @(Read-VmfEvents -RunPath $rp -Step 'wave' | Where-Object { $_.detail -match 'oper@example\.com' })
            $halts.Count | Should -BeGreaterThan 0
        }
    }

    It 'resolve-decision requires Vmf.Operator, applies overrides, re-arms the VM' {
        { Invoke-VmfFacadeResolve -Principal $script:viewer -StorePath $script:runPath -VmId '/s/rg/vm/vm1' -Note 'x' } |
            Should -Throw '*403*'
        # DECIDE-2: the override here was onDDataFound = 'proceed', which is now
        # the approver's - accepting it gives up files for good. keepSnapshotDays
        # keeps this test doing what it is for: an Operator resolves, and an
        # override they may make is applied.
        # RETRY-GATE-1: first refused, in the start gate's words, while the
        # wave cannot start - and the machine stays where it was.
        { Invoke-VmfFacadeResolve -Principal $script:operator -StorePath $script:runPath -VmId '/s/rg/vm/vm1' `
            -Note 'too soon' -PolicyOverride @{ keepSnapshotDays = 14 } } | Should -Throw '400: Nothing changed for vm1, because wave prod-1 cannot start.*'
        (InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Read-VmfStateDoc -RunPath $rp -VmId '/s/rg/vm/vm1' }).state |
            Should -Be 'NEEDS_DECISION'
        . (Join-Path $PSScriptRoot '_WaveGate.ps1')
        Open-VmfTestWaveGate -RunPath $script:runPath -PlanPath (Join-Path $script:runPath 'plan.json')
        # WAVE-APPROVE-1 (rule since 2026-10-10): the override is
        # applied, but an operator's decision is not covered by the plan
        # sign-off - the wave asks again for its approval. Before, it re-armed.
        { Invoke-VmfFacadeResolve -Principal $script:operator -StorePath $script:runPath -VmId '/s/rg/vm/vm1' `
            -Note 'reconciliation acknowledged' -PolicyOverride @{ keepSnapshotDays = 14 } } |
            Should -Throw '400: The change (keepSnapshotDays=14) is saved, but wave prod-1 cannot start now*'
        $planFile = Join-Path $script:runPath 'plan.json'
        @((Get-Content $planFile -Raw | ConvertFrom-Json -Depth 12).entries | Where-Object vmId -EQ '/s/rg/vm/vm1')[0].policy.keepSnapshotDays | Should -Be 14
        # An approver approves the wave again; the operator tries the machine again.
        Invoke-VmfFacadeApprove -Principal $script:approver -StorePath $script:runPath -Wave 'prod-1' -Note 'read the change' `
            -PlanHash (InModuleScope VmMigrationFactory -Parameters @{ t = (Get-Content $planFile -Raw) } { Get-VmfDocumentVersion -Text $t }) | Out-Null
        $r = Invoke-VmfFacadeResolve -Principal $script:operator -StorePath $script:runPath -VmId '/s/rg/vm/vm1' -Note 'reconciliation acknowledged'
        $r.NewState | Should -Be 'PRECHECK'
        $r.ResolvedBy | Should -Be 'oper@example.com'
    }
}

Describe 'S3-4: Invoke-VmfFacadeStartEngine (hosted execution trigger)' {
    BeforeEach {
        $env:VMF_ENGINE_JOB_ID = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.App/jobs/vmf-engine'
        $script:engineStore = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-eng-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $env:VMF_STORE_PATH = $script:engineStore
        New-Item -ItemType Directory -Path $script:engineStore -Force | Out-Null
        $script:operator = ConvertFrom-VmfClientPrincipal -Header (NewPrincipalHeader -Identity 'oper@example.com' -Roles @('Vmf.Operator'))
        $script:viewer = ConvertFrom-VmfClientPrincipal -Header (NewPrincipalHeader -Identity 'view@example.com' -Roles @('Vmf.Viewer'))
    }
    AfterEach {
        Remove-Item Env:\VMF_ENGINE_JOB_ID, Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue
        if (Test-Path $script:engineStore) { Remove-Item $script:engineStore -Recurse -Force }
    }

    It 'requires Vmf.Operator' {
        { Invoke-VmfFacadeStartEngine -Principal $script:viewer -Operation 'wave' -RunId 'r1' -Wave 'prod-1' -Note 'x' } |
            Should -Throw '*403*'
    }

    It 'starts the job with the operation and run parameters as env overrides' {
        Mock -ModuleName FacadeCore Invoke-AzRestMethod {
            if ($Method -eq 'GET') {
                return [pscustomobject]@{ StatusCode = 200; Content = (@{
                    properties = @{ template = @{ containers = @(@{
                        name = 'engine'; image = 'acr/vmf-engine:dev'
                        resources = @{ cpu = 1; memory = '2Gi' }
                        env = @(@{ name = 'VMF_STORE_ACCOUNT'; value = 'acct' }) }) } }
                } | ConvertTo-Json -Depth 10) }
            }
            $script:startBody = $Payload
            [pscustomobject]@{ StatusCode = 202; Content = (@{ id = '/exec/vmf-engine-abc123'; name = 'vmf-engine-abc123' } | ConvertTo-Json) }
        }
        $r = Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation 'wave' -RunId 'pilot-1' -Wave 'prod-1' -Note 'starting prod wave'
        $r.Operation | Should -Be 'wave'
        $r.StartedBy | Should -Be 'oper@example.com'
        $body = $script:startBody | ConvertFrom-Json -Depth 10
        $body.PSObject.Properties.Name | Should -Not -Contain 'template' -Because 'the start API takes containers at top level (live 400 otherwise)'
        $envs = @($body.containers[0].env)
        ($envs | Where-Object name -EQ 'VMF_OPERATION').value | Should -Be 'wave'
        ($envs | Where-Object name -EQ 'VMF_RUN_ID').value | Should -Be 'pilot-1'
        ($envs | Where-Object name -EQ 'VMF_WAVE').value | Should -Be 'prod-1'
        ($envs | Where-Object name -EQ 'VMF_STORE_ACCOUNT').value | Should -Be 'acct' -Because 'job-definition env must be preserved'
    }

    It 'WAVE-APPROVE-1 (review 4): a wave version goes to the engine as its own setting, and only when one is given' {
        Mock -ModuleName FacadeCore Invoke-AzRestMethod {
            if ($Method -eq 'GET') {
                return [pscustomobject]@{ StatusCode = 200; Content = (@{
                    properties = @{ template = @{ containers = @(@{
                        name = 'engine'; image = 'acr/vmf-engine:dev'
                        resources = @{ cpu = 1; memory = '2Gi' }
                        env = @() }) } }
                } | ConvertTo-Json -Depth 10) }
            }
            $script:startBody = $Payload
            [pscustomobject]@{ StatusCode = 202; Content = (@{ name = 'vmf-engine-wv' } | ConvertTo-Json) }
        }
        Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation 'wave' -RunId 'pilot-1' -Wave 'prod-1' -Note 'next wave' -WaveVersion ('a' * 64) | Out-Null
        $envs = @(($script:startBody | ConvertFrom-Json -Depth 10).containers[0].env)
        ($envs | Where-Object name -EQ 'VMF_WAVE_VERSION').value | Should -BeExactly ('a' * 64)
        Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation 'wave' -RunId 'pilot-1' -Wave 'prod-1' -Note 'by hand' | Out-Null
        $envs = @(($script:startBody | ConvertFrom-Json -Depth 10).containers[0].env)
        ($envs | Where-Object name -EQ 'VMF_WAVE_VERSION') | Should -BeNullOrEmpty -Because 'a person''s start is judged by the engine on its own read'
    }

    It 'refuses a wave operation without a wave name' {
        { Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation 'wave' -RunId 'r1' -Note 'x' } |
            Should -Throw '*wave*'
    }

    It 'passes the scan scope (SCOPE-1) and capacity choice (CAP-3) as env overrides' {
        Mock -ModuleName FacadeCore Invoke-AzRestMethod {
            if ($Method -eq 'GET') {
                return [pscustomobject]@{ StatusCode = 200; Content = (@{
                    properties = @{ template = @{ containers = @(@{
                        name = 'engine'; image = 'acr/vmf-engine:dev'
                        resources = @{ cpu = 1; memory = '2Gi' }
                        env = @() }) } }
                } | ConvertTo-Json -Depth 10) }
            }
            $script:startBody2 = $Payload
            [pscustomobject]@{ StatusCode = 202; Content = (@{ name = 'vmf-engine-xyz' } | ConvertTo-Json) }
        }
        Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation 'assess' -RunId 'r2' `
            -ScopeSubs @('00000000-0000-0000-0000-000000000000', '11111111-2222-3333-4444-555555555555') -ScopeMg 'mg-root' -Note 'scoped scan' | Out-Null
        $envs = @(($script:startBody2 | ConvertFrom-Json -Depth 10).containers[0].env)
        ($envs | Where-Object name -EQ 'VMF_SCOPE_SUBS').value | Should -Be '00000000-0000-0000-0000-000000000000,11111111-2222-3333-4444-555555555555'
        ($envs | Where-Object name -EQ 'VMF_SCOPE_MG').value | Should -Be 'mg-root'

        Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation 'plan' -RunId 'r2' `
            -CapacityGate 'Reserved' -Note 'reserved plan' | Out-Null
        $envs = @(($script:startBody2 | ConvertFrom-Json -Depth 10).containers[0].env)
        ($envs | Where-Object name -EQ 'VMF_CAPACITY_GATE').value | Should -Be 'Reserved'
    }

    It 'rejects an invalid capacity choice at the parameter boundary' {
        { Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation 'plan' -RunId 'r2' `
            -CapacityGate 'Cheapest' -Note 'x' } | Should -Throw
    }

    It 'the start line in the activity log reads cleanly with a note and without one' {
        # Seen live 2026-09-04 on a lab scan: "started by X:  (execution
        # ...)" - a colon and two spaces around a note nobody wrote.
        Mock -ModuleName FacadeCore Invoke-AzRestMethod {
            if ($Method -eq 'GET') {
                return [pscustomobject]@{ StatusCode = 200; Content = (@{
                    properties = @{ template = @{ containers = @(@{
                        name = 'engine'; image = 'acr/vmf-engine:dev'
                        resources = @{ cpu = 1; memory = '2Gi' }
                        env = @(@{ name = 'VMF_STORE_ACCOUNT'; value = 'acct' }) }) } }
                } | ConvertTo-Json -Depth 10) }
            }
            [pscustomobject]@{ StatusCode = 202; Content = (@{ name = 'vmf-engine-n1' } | ConvertTo-Json) }
        }
        Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation 'assess' -RunId 'r3' -Note 'scoped scan' | Out-Null
        Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation 'assess' -RunId 'r3' -Note '' | Out-Null
        $lines = @(InModuleScope VmMigrationFactory -Parameters @{ rp = (Join-Path $script:engineStore 'r3') } {
            Read-VmfEvents -RunPath $rp -Step 'engine' } | ForEach-Object { $_.detail })
        $lines.Count | Should -Be 2
        $lines[0] | Should -Be 'hosted assess started by oper@example.com: scoped scan (execution vmf-engine-n1)'
        $lines[1] | Should -Be 'hosted assess started by oper@example.com (execution vmf-engine-n1)'
    }
}

Describe 'SCOPE-1: Get-VmfFacadeScopeList' {
    It 'requires a signed-in role holder' {
        { Get-VmfFacadeScopeList -Principal $null } | Should -Throw '*401*'
    }

    It 'shapes subscriptions AND management groups for the scan dialog pickers' {
        Mock -ModuleName FacadeCore Invoke-AzRestMethod {
            if ($Path -like '*managementGroups*') {
                return [pscustomobject]@{ StatusCode = 200; Content = (@{ value = @(
                    @{ name = 'mg-root'; properties = @{ displayName = 'Tenant Root Group' } }
                ) } | ConvertTo-Json -Depth 6) }
            }
            [pscustomobject]@{ StatusCode = 200; Content = (@{ value = @(
                @{ subscriptionId = 'sub-1'; displayName = 'Production' }
                @{ subscriptionId = 'sub-2'; displayName = 'Development' }
            ) } | ConvertTo-Json -Depth 6) }
        }
        $viewer = ConvertFrom-VmfClientPrincipal -Header (NewPrincipalHeader -Identity 'v@example.com' -Roles @('Vmf.Viewer'))
        $d = Get-VmfFacadeScopeList -Principal $viewer
        @($d.subscriptions).Count | Should -Be 2
        @($d.subscriptions)[1].name | Should -Be 'Development'
        @($d.managementGroups)[0].id | Should -Be 'mg-root'
        @($d.managementGroups)[0].name | Should -Be 'Tenant Root Group'
    }

    It 'still returns subscriptions when management groups are not readable' {
        Mock -ModuleName FacadeCore Invoke-AzRestMethod {
            if ($Path -like '*managementGroups*') { throw 'AuthorizationFailed' }
            [pscustomobject]@{ StatusCode = 200; Content = (@{ value = @(
                @{ subscriptionId = 'sub-1'; displayName = 'Production' }) } | ConvertTo-Json -Depth 6) }
        }
        $viewer = ConvertFrom-VmfClientPrincipal -Header (NewPrincipalHeader -Identity 'v@example.com' -Roles @('Vmf.Viewer'))
        $d = Get-VmfFacadeScopeList -Principal $viewer
        @($d.subscriptions).Count | Should -Be 1
        @($d.managementGroups).Count | Should -Be 0
    }

    It 'lists resource groups for one subscription, rejecting a bad id' {
        Mock -ModuleName FacadeCore Invoke-AzRestMethod {
            [pscustomobject]@{ StatusCode = 200; Content = (@{ value = @(
                @{ name = 'rg-b'; location = 'eastus' }
                @{ name = 'rg-a'; location = 'centralus' }
            ) } | ConvertTo-Json -Depth 6) }
        }
        $viewer = ConvertFrom-VmfClientPrincipal -Header (NewPrincipalHeader -Identity 'v@example.com' -Roles @('Vmf.Viewer'))
        $rgs = @(Get-VmfFacadeResourceGroupList -Principal $viewer -SubscriptionId 'aaaa0a0a-bb1b-cc2c-dd3d-eeeeee4e4e4e')
        $rgs[0].name | Should -Be 'rg-a' -Because 'sorted for the picker'
        { Get-VmfFacadeResourceGroupList -Principal $viewer -SubscriptionId 'not-a-guid' } | Should -Throw '*400*'
    }
}

Describe 'SCHED-1: releasing scheduled waves' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        function Global:WritePlan {
            # -KeepSnapshotDays: the same wave with one setting changed.
            param([string]$Store, [bool]$RequireApproval, [int]$KeepSnapshotDays = 0)
            InModuleScope VmMigrationFactory -Parameters @{ rp = $Store; req = $RequireApproval; days = $KeepSnapshotDays } {
                $pol = [ordered]@{ requireApproval = $req }
                if ($days) { $pol.keepSnapshotDays = $days }
                Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24 -Document ([ordered]@{
                    schemaVersion = 1
                    entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/vm/a'; wave = 'prod-1'; ring = 'prod'; path = 'A'
                                            policy = $pol })
                })
            }
        }
        function Global:SignOffPlan {
            param([string]$Store)
            Approve-VmfPlan -RunPath $Store -PlanPath (Join-Path $Store 'plan.json') -Note 'every wave read' `
                -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = 't' } | Out-Null
        }
    }
    AfterAll { Remove-Item 'function:\WritePlan', 'function:\SignOffPlan' -ErrorAction SilentlyContinue }
    BeforeEach {
        $env:VMF_ENGINE_JOB_ID = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.App/jobs/vmf-engine'
        $script:schedStore = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-sch-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $env:VMF_STORE_PATH = $script:schedStore
        New-Item -ItemType Directory -Path $script:schedStore -Force | Out-Null
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:schedStore } {
            Initialize-VmfRun -RunPath $rp -RunId 'sched-run' | Out-Null
        }
        $script:oper = ConvertFrom-VmfClientPrincipal -Header (NewPrincipalHeader -Identity 'oper@example.com' -Roles @('Vmf.Operator'))
    }
    AfterEach {
        Remove-Item Env:\VMF_ENGINE_JOB_ID, Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue
        if (Test-Path $script:schedStore) { Remove-Item $script:schedStore -Recurse -Force }
    }

    It 'starts a wave whose time has come' {
        WritePlan -Store $script:schedStore -RequireApproval $false
        Mock -ModuleName FacadeCore Invoke-AzRestMethod {
            if ($Method -eq 'GET') {
                return [pscustomobject]@{ StatusCode = 200; Content = (@{ properties = @{ template = @{ containers = @(@{
                    name = 'engine'; image = 'i'; resources = @{ cpu = 1; memory = '2Gi' }; env = @() }) } } } | ConvertTo-Json -Depth 10) }
            }
            [pscustomobject]@{ StatusCode = 202; Content = (@{ name = 'vmf-engine-sched' } | ConvertTo-Json) }
        }
        Invoke-VmfFacadeSchedule -Principal $script:oper -StorePath $script:schedStore -Wave 'prod-1' `
            -RunAtUtc ((Get-Date).AddMinutes(30).ToString('o')) -Note 'tonight' | Out-Null
        $released = @(Invoke-VmfFacadeReleaseDueSchedules -StorePath $script:schedStore -RunId 'sched-run' `
            -AsOf (Get-Date).ToUniversalTime().AddHours(1))
        $released.Count | Should -Be 1
        $released[0].Wave | Should -Be 'prod-1'
        # SCHEDULE-WAVE-VERSION-1: the start is on record, so a later pass
        # cannot start it twice; the engine run removes it when it starts.
        $left = @(Get-VmfWaveSchedule -RunPath $script:schedStore)
        $left.Count | Should -Be 1
        [string]$left[0].state | Should -BeExactly 'started'
    }

    It 'a SCHEDULE IS NOT AN APPROVAL - a due wave needing sign-off is left alone' {
        WritePlan -Store $script:schedStore -RequireApproval $true
        Mock -ModuleName FacadeCore Invoke-AzRestMethod { throw 'the engine must not be started' }
        Invoke-VmfFacadeSchedule -Principal $script:oper -StorePath $script:schedStore -Wave 'prod-1' `
            -RunAtUtc ((Get-Date).AddMinutes(30).ToString('o')) -Note 'tonight' | Out-Null
        $released = @(Invoke-VmfFacadeReleaseDueSchedules -StorePath $script:schedStore -RunId 'sched-run' `
            -AsOf (Get-Date).ToUniversalTime().AddHours(1))
        $released.Count | Should -Be 0
        # and it stays scheduled, so approving later still lets it run
        @(Get-VmfWaveSchedule -RunPath $script:schedStore).Count | Should -Be 1
        $events = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:schedStore } { Read-VmfEvents -RunPath $rp }
        ($events | Where-Object { $_.detail -match 'has not been approved' }) | Should -Not -BeNullOrEmpty
    }

    It 'WAVE-APPROVE-1 (review 3): a wave set not to need a sign-off that changed after the plan sign-off does not start on its schedule' {
        # The same rule as the timer (Test-VmfPlanRunWaveSigned): a start
        # nobody presses rests on an approval an approver gave for the wave as
        # it is. The sign-off wrote the wave one; the change made it out of date.
        WritePlan -Store $script:schedStore -RequireApproval $false
        SignOffPlan -Store $script:schedStore
        WritePlan -Store $script:schedStore -RequireApproval $false -KeepSnapshotDays 14
        Mock -ModuleName FacadeCore Invoke-AzRestMethod { throw 'the engine must not be started' }
        Invoke-VmfFacadeSchedule -Principal $script:oper -StorePath $script:schedStore -Wave 'prod-1' `
            -RunAtUtc ((Get-Date).AddMinutes(30).ToString('o')) -Note 'tonight' | Out-Null
        $released = @(Invoke-VmfFacadeReleaseDueSchedules -StorePath $script:schedStore -RunId 'sched-run' `
            -AsOf (Get-Date).ToUniversalTime().AddHours(1))
        $released.Count | Should -Be 0
        @(Get-VmfWaveSchedule -RunPath $script:schedStore).Count | Should -Be 1 -Because 'it asks again, and stays scheduled'
        $events = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:schedStore } { Read-VmfEvents -RunPath $rp -Step 'schedule' }
        ($events | Where-Object { $_.detail -match 'changed after the plan was signed off' -and $_.detail -match 'does not start by itself' }) | Should -Not -BeNullOrEmpty
    }

    It 'WAVE-APPROVE-1 (review 3): and it starts on its schedule once an approver approves the wave again' {
        WritePlan -Store $script:schedStore -RequireApproval $false
        SignOffPlan -Store $script:schedStore
        WritePlan -Store $script:schedStore -RequireApproval $false -KeepSnapshotDays 14
        Approve-VmfWave -RunPath $script:schedStore -PlanPath (Join-Path $script:schedStore 'plan.json') -Wave 'prod-1' -Note 'read again' `
            -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = 't' } | Out-Null
        Mock -ModuleName FacadeCore Invoke-AzRestMethod {
            if ($Method -eq 'GET') {
                return [pscustomobject]@{ StatusCode = 200; Content = (@{ properties = @{ template = @{ containers = @(@{
                    name = 'engine'; image = 'i'; resources = @{ cpu = 1; memory = '2Gi' }; env = @() }) } } } | ConvertTo-Json -Depth 10) }
            }
            [pscustomobject]@{ StatusCode = 202; Content = (@{ name = 'vmf-engine-sched' } | ConvertTo-Json) }
        }
        Invoke-VmfFacadeSchedule -Principal $script:oper -StorePath $script:schedStore -Wave 'prod-1' `
            -RunAtUtc ((Get-Date).AddMinutes(30).ToString('o')) -Note 'tonight' | Out-Null
        @(Invoke-VmfFacadeReleaseDueSchedules -StorePath $script:schedStore -RunId 'sched-run' -AsOf (Get-Date).ToUniversalTime().AddHours(1)).Count |
            Should -Be 1
    }

    It 'WAVE-APPROVE-1 (review 3): with the sign-off of this exact plan, it starts on its schedule as before' {
        WritePlan -Store $script:schedStore -RequireApproval $false
        SignOffPlan -Store $script:schedStore
        [System.IO.File]::Delete((Join-Path $script:schedStore 'approvals' 'prod-1.json'))
        Mock -ModuleName FacadeCore Invoke-AzRestMethod {
            if ($Method -eq 'GET') {
                return [pscustomobject]@{ StatusCode = 200; Content = (@{ properties = @{ template = @{ containers = @(@{
                    name = 'engine'; image = 'i'; resources = @{ cpu = 1; memory = '2Gi' }; env = @() }) } } } | ConvertTo-Json -Depth 10) }
            }
            [pscustomobject]@{ StatusCode = 202; Content = (@{ name = 'vmf-engine-sched' } | ConvertTo-Json) }
        }
        Invoke-VmfFacadeSchedule -Principal $script:oper -StorePath $script:schedStore -Wave 'prod-1' `
            -RunAtUtc ((Get-Date).AddMinutes(30).ToString('o')) -Note 'tonight' | Out-Null
        @(Invoke-VmfFacadeReleaseDueSchedules -StorePath $script:schedStore -RunId 'sched-run' -AsOf (Get-Date).ToUniversalTime().AddHours(1)).Count |
            Should -Be 1
    }

    It 'leaves a wave alone until its time arrives' {
        WritePlan -Store $script:schedStore -RequireApproval $false
        Mock -ModuleName FacadeCore Invoke-AzRestMethod { throw 'the engine must not be started' }
        Invoke-VmfFacadeSchedule -Principal $script:oper -StorePath $script:schedStore -Wave 'prod-1' `
            -RunAtUtc ((Get-Date).AddHours(6).ToString('o')) -Note 'later' | Out-Null
        @(Invoke-VmfFacadeReleaseDueSchedules -StorePath $script:schedStore -RunId 'sched-run').Count | Should -Be 0
    }

    It 'requires Vmf.Operator to schedule, and a note' {
        $viewer = ConvertFrom-VmfClientPrincipal -Header (NewPrincipalHeader -Identity 'v@example.com' -Roles @('Vmf.Viewer'))
        { Invoke-VmfFacadeSchedule -Principal $viewer -StorePath $script:schedStore -Wave 'prod-1' `
            -RunAtUtc ((Get-Date).AddHours(2).ToString('o')) -Note 'x' } | Should -Throw '*403*'
        { Invoke-VmfFacadeSchedule -Principal $script:oper -StorePath $script:schedStore -Wave 'prod-1' `
            -RunAtUtc ((Get-Date).AddHours(2).ToString('o')) -Note '' } | Should -Throw '*requires a note*'
    }

    It 'cancels a scheduled wave' {
        Invoke-VmfFacadeSchedule -Principal $script:oper -StorePath $script:schedStore -Wave 'prod-1' `
            -RunAtUtc ((Get-Date).AddHours(2).ToString('o')) -Note 'x' | Out-Null
        Invoke-VmfFacadeSchedule -Principal $script:oper -StorePath $script:schedStore -Wave 'prod-1' -Cancel -Note 'moved' | Out-Null
        @(Get-VmfWaveSchedule -RunPath $script:schedStore).Count | Should -Be 0
    }
}

Describe 'Deploy-VmfFacade.ps1 hygiene (PKG-1: infrastructure lives in the template)' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
        # These "the script must not do X" checks name X in order to ban it,
        # and the script's own comments name X in order to explain why it
        # stopped doing it. Scanning raw text therefore fails on an accurate
        # comment - which is what NOFILES-1 hit, where the comment beside the
        # content-share retirement says the settings came from
        # `az functionapp create`. Same rule as ResourceIdTargeting.Tests.ps1:
        # read the CODE.
        $script:deployText = Get-VmfCodeOnly -Path (Join-Path $script:root 'tools' 'Deploy-VmfFacade.ps1')
        $script:templateText = Get-Content (Join-Path $script:root 'infra' 'platform.bicep') -Raw
    }

    It 'parses cleanly and stores no secrets' {
        $errs = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $script:root 'tools' 'Deploy-VmfFacade.ps1'), [ref]$null, [ref]$errs) | Out-Null
        @($errs).Count | Should -Be 0
        $script:deployText | Should -Not -Match 'client_secret|password|AccountKey='
    }

    It 'uses body FILES for Graph writes (the az.cmd shim mangles inline JSON)' {
        foreach ($m in [regex]::Matches($script:deployText, '--body\s+(\S+)')) {
            $m.Groups[1].Value | Should -BeLike '"@$*' -Because 'inline JSON gets mangled'
        }
    }

    It 'no longer creates infrastructure the template owns' {
        # PKG-1: the script publishes CODE and Entra objects. Anything that
        # creates or configures Azure resources belongs in platform.bicep, so
        # a customer gets it in one deployment.
        # EVAL-H13 refined this: the rule is that the script must not CONFIGURE
        # auth (the template owns it), not that it may never look at it. It now
        # READS the setting back and refuses to publish code to an app that is
        # not behind sign-in - which is the opposite failure mode, and only
        # possible by mentioning the same word.
        $script:deployText | Should -Not -Match "az webapp auth (update|set)"
        $script:deployText | Should -Not -Match "--method PUT[^
]*authsettingsV2"
        foreach ($banned in 'functionapp create', 'appsettings set', 'functionapp cors',
                            'monitor log-analytics workspace create', 'app-insights component create',
                            'identity assign', 'powershell-version') {
            $script:deployText | Should -Not -Match ([regex]::Escape($banned)) -Because "the template owns '$banned'"
        }
        # and it refuses to run against infrastructure that is not there
        $script:deployText | Should -Match 'Deploy the platform first'
    }

    It 'the template owns what the script gave up' {
        $script:templateText | Should -Match "avm/res/web/site"
        $script:templateText | Should -Match "avm/res/web/serverfarm"
        $script:templateText | Should -Match 'authsettingsV2'
        $script:templateText | Should -Match 'unauthenticatedClientAction'
        $script:templateText | Should -Match 'vmf-persistent'   # standing resources survive lab teardown
        $script:templateText | Should -Match "powerShellVersion: '7\.6'"
    }

    It 'pins the adoption traps that what-if caught, so a redeploy never breaks a running platform' {
        # each of these was a real finding, not a precaution
        $script:templateText | Should -Match 'requireInfrastructureEncryption: false'
        $script:templateText | Should -Match "defaultAction: 'Allow'"
        # STORE-READ-1: this pinned the STORE's corsRules, because the AVM
        # default is none and a browser read of the blob account would have
        # broken silently. Nothing in a browser reaches the account now, and
        # that block is gone.
        #
        # The trap did not go with it - it moved, and it got worse. EVERY store
        # read is now a cross-origin request from the dashboard's origin to the
        # facade, so losing THIS cors block does not degrade a page, it empties
        # every page at once with a browser-side error naming no file of ours.
        $script:templateText | Should -Match '(?s)cors: \{\s*allowedOrigins: \[ dashboardOrigin \]'
        $script:templateText | Should -Not -Match 'corsRules' -Because 'no browser reads the storage account'
        $script:templateText | Should -Match 'disableLocalAuth: false'
        # The runtime storage connection must be STATED, or a redeploy strips a
        # running app of the storage it boots from. SEC-1 moved it to its
        # identity form, so this pins that form rather than the bare word,
        # which a comment would satisfy.
        $script:templateText | Should -Match 'AzureWebJobsStorage__accountName: storeName'
    }

    It 'no shared key reaches the run store, in the template or in what it records (SEC-1)' {
        # Rule since 2026-09-06: no storage access key is used anywhere in
        # this solution. A key that is present is a defect; access goes by
        # identity.
        #
        # The run store holds every plan, approval, machine state and safety
        # copy record, so a key in an app setting is an unscoped, non-expiring
        # credential for all of it - and it landed in the deployment record too,
        # where a resource-group Reader could read it.
        $script:templateText | Should -Match "AzureWebJobsStorage__credential: 'managedidentity'"
        foreach ($service in 'blob', 'queue', 'table') {
            $script:templateText | Should -Match "AzureWebJobsStorage__${service}ServiceUri:"
        }
        # Scan the CODE, not the commentary: the comment beside the fix quotes
        # the call it removed, and an assertion that matched that would pass
        # only while somebody was still explaining the defect.
        $code = (Get-VmfCodeOnly -Language CStyle -Text $script:templateText)
        $code | Should -Not -Match 'AccountKey='
        $code | Should -Not -Match 'listKeys\('
        $script:templateText | Should -Match 'allowSharedKeyAccess: false'
        # The host signs in to the store as the facade now, so it needs to
        # manage its own containers and leases there.
        #
        # CD-2 STAGE A turned these from names into id variables, because a
        # condition can only name a role by id. So BOTH halves are asserted:
        # the variable holds the right role, and the template grants it. A
        # variable name on its own would pass while holding the wrong id.
        $wanted = @{
            roleBlobOwner        = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'  # Storage Blob Data Owner
            roleQueueContributor = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'  # Storage Queue Data Contributor
            roleTableContributor = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'  # Storage Table Data Contributor
        }
        foreach ($name in $wanted.Keys) {
            $script:templateText | Should -Match "var $name = '$($wanted[$name])'" -Because "$name must be the role it claims"
            $script:templateText | Should -Match "roleDefinitionIdOrName: $name" -Because "$name must actually be granted"
        }
    }

    It 'and the publish retires a key-based setting an older install left behind (SEC-1)' {
        # The site module MERGES app settings, so the old connection string
        # survives a redeploy - and a plain connection string wins over the
        # identity form, against an account that no longer accepts a key. A
        # template can state a setting and cannot unstate one, so the publish
        # removes it, once.
        $publish = Get-Content (Join-Path $script:root 'tools' 'Deploy-VmfFacade.ps1') -Raw
        $publish | Should -Match "appsettings delete .* --setting-names AzureWebJobsStorage"
        $publish | Should -Match "Where-Object \{ \`$_\.name -eq 'AzureWebJobsStorage' \}"
    }

    It 'the control plane sends its platform logs somewhere (DIAG-1)' {
        # The control plane had NO diagnostic settings at all, while the host
        # that serves static files had them. Application Insights carried the
        # application's telemetry, so the gap was invisible from inside the app
        # - what was missing is the platform view.
        #
        # Found by questioning the word "harmless" in the DRIFT-3
        # classification of a deleted log category.
        $facade = [regex]::Match($script:templateText, "(?s)module facade 'br/public:avm/res/web/site.*?
\}").Value
        $facade | Should -Not -BeNullOrEmpty
        $facade | Should -Match 'diagnosticSettings:' -Because 'the control plane must log to the workspace, not only to Application Insights'
        $facade | Should -Match 'workspaceResourceId: logsResourceId'
    }

    It 'and BOTH sites log the sign-in boundary, which is the audit trail (DIAG-1)' {
        # Sign-in is the security control for the whole product. Its log is the
        # only record outside Application Insights that somebody reached the
        # front door. It was present but DISABLED on the dashboard, and absent
        # on the facade.
        foreach ($site in @('facade', 'dashboard')) {
            $block = [regex]::Match($script:templateText, "(?s)module $site 'br/public:avm/res/web/site.*?
\}").Value
            $block | Should -Match 'AppServiceAuthenticationLogs' -Because "$site must record who reached its front door"
        }
    }

    It 'and does not collect the expensive pair twice, without a reason (DIAG-1)' {
        # AppServiceConsoleLogs and AppServiceAppLogs are the high-volume
        # categories, and Application Insights already carries application
        # telemetry. Collecting both would put ingestion on a customer's bill
        # for a second copy. This asserts the DECISION, so turning them on is a
        # deliberate act with a reason attached rather than a default drifting
        # back.
        $code = (Get-VmfCodeOnly -Language CStyle -Text $script:templateText)
        $code | Should -Not -Match 'AppServiceConsoleLogs'
        $code | Should -Not -Match 'AppServiceAppLogs'
    }

    It 'neither site leaves sticky sessions to a module default (DRIFT-3)' {
        # FOUND BY THE FIRST HONEST DRIFT PREVIEW, which is the whole argument
        # for fixing that job. The template did not state clientAffinityEnabled,
        # so the AVM module's default - TRUE - applied. The running facade has
        # it false, which is correct, so nothing had broken yet: the next
        # deploy of this template would have turned ARR affinity ON for the
        # migration control plane, pinning every caller to one instance and
        # working against scale-out on Consumption.
        #
        # Both sites state it now. The value is asserted rather than merely its
        # presence, because the defect WAS the default.
        $sites = [regex]::Matches($script:templateText, "(?s)module (facade|dashboard) 'br/public:avm/res/web/site.*?
\}")
        $sites.Count | Should -Be 2 -Because 'both web sites must be found, or this proves nothing'
        foreach ($site in $sites) {
            $site.Value | Should -Match 'clientAffinityEnabled: false' -Because "$($site.Groups[1].Value) must not inherit sticky sessions from a module default"
        }
    }

    It 'the facade keeps no Azure Files content share, so no key is needed at all (NOFILES-1)' {
        # The second half of the no-key rule, and the half that was nearly got
        # wrong. A Windows Consumption function app normally keeps its code on
        # an Azure Files share whose connection string carries an account key,
        # and Azure Files cannot be reached by the App Service worker with an
        # identity - MEASURED: with SMB OAuth enabled on the account and shared
        # keys refused, the zip deploy failed exactly as it did without it.
        #
        # So the app has no share. It runs from a package in blob storage,
        # which the host fetches with its own identity.
        $script:templateText | Should -Match 'WEBSITE_RUN_FROM_PACKAGE:'
        $script:templateText | Should -Match 'vmf-deploy/facade\.zip'
        # and the container that package lives in is really created
        $script:templateText | Should -Match "name: 'vmf-deploy'"
        # Scan the CODE: the comment above the setting names both of these
        # while explaining what was removed, so a text match on the whole file
        # would pass while the settings were still being set.
        $code = (Get-VmfCodeOnly -Language CStyle -Text $script:templateText)
        $code | Should -Not -Match 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
        $code | Should -Not -Match 'WEBSITE_CONTENTSHARE'
    }

    It 'the publish job can write the code package and STILL cannot read migration state (NOFILES-1)' {
        # Publishing writes a blob, so the identity that publishes needs a data
        # role on the store - which the store's own comment says it must never
        # have, because it would hand the thing that publishes code every
        # plan, approval, machine state and safety copy record in vmf-runs.
        #
        # Both are true only if the grant is scoped to the deployment
        # CONTAINER. This test is the reason that scoping cannot be quietly
        # widened to the account later.
        #
        # PIPELINE-LATER-1 rewrote it. It asked for 'deployPrincipalId' in the
        # container's TEXT, and since PUBLISH-IN-1 only a COMMENT there said
        # that name - so it passed on a comment. It now reads the code, and
        # names the identity that holds the grant: the publish job's.
        $store = [regex]::Match($script:templateText, "(?s)module store .*?
}
").Value
        $store | Should -Not -BeNullOrEmpty -Because 'the store module must be findable'
        $container = [regex]::Match($store, "(?s)name: 'vmf-deploy'.*?
        \}").Value
        $container = Get-VmfCodeOnly -Language CStyle -Text $container
        $container | Should -Match '(?s)principalId: publishIdentity\.outputs\.principalId\s+principalType: ''ServicePrincipal''\s+roleDefinitionIdOrName: roleBlobContributor' -Because 'the publish grant belongs on this container'
        $container | Should -Not -Match 'deployPrincipalId' -Because 'no pipeline identity holds a grant (PIPELINE-LATER-1)'
        # and NOT at the account level, where vmf-runs would come with it
        $accountRoles = [regex]::Match($store, "(?s)
    roleAssignments: \[.*?
    \]").Value
        $accountRoles | Should -Not -Match 'publishIdentity' -Because 'an account-wide data grant would expose every run record to the publish job'
    }

    It 'the publish puts the package in the store by identity, and re-reads the triggers after (NOFILES-1)' {
        $publish = Get-Content (Join-Path $script:root 'tools' 'Deploy-VmfFacade.ps1') -Raw
        $code = (Get-VmfCodeOnly -Language PowerShell -Text $publish)
        # zip deploy went through Kudu into the file share that no longer exists
        $code | Should -Not -Match 'deployment source config-zip'
        # PUBLISH-IN-1: nor does the upload happen HERE any more. A laptop
        # cannot reach a locked-down store and no perimeter rule can admit one,
        # so this builds an image carrying the package and runs it as a job
        # inside the subscription.
        $code | Should -Not -Match 'az storage blob upload' -Because 'a laptop is never admitted to a locked-down store'
        $code | Should -Match 'az acr build .*docker/publish/Dockerfile'
        $code | Should -Match 'containerapp job start'
        $job = Get-Content (Join-Path $script:root 'docker' 'publish' 'entrypoint.ps1') -Raw
        $job | Should -Match '-UseConnectedAccount' -Because 'the store refuses shared keys'
        $job | Should -Not -Match '(?i)accountkey|-StorageAccountKey|SharedKey'
        # WEBSITE_RUN_FROM_PACKAGE = <URL> needs both of these, and zip deploy
        # needed neither: the running host holds the package it started with,
        # and the platform keeps the old function list until told otherwise.
        $code | Should -Match 'functionapp restart'
        $code | Should -Match 'syncfunctiontriggers'
    }

    It 'and the package the image builds is the package the host expects (PUBLISH-IN-1)' {
        # The staging used to happen in the publish script, so the layout and
        # the thing that made it were one file. They are two now: get this
        # wrong and the app deploys, starts, and serves no functions.
        $docker = Get-Content (Join-Path $script:root 'docker' 'publish' 'Dockerfile') -Raw
        $docker | Should -Match 'COPY src/facade/app\s+/stage/'
        $docker | Should -Match 'COPY src/VmMigrationFactory\s+/stage/Modules/VmMigrationFactory'
        $docker | Should -Match 'COPY src/facade/FacadeCore\s+/stage/Modules/FacadeCore'
        # zipped at BUILD time: what the tests ran against is what reaches the
        # store, and the job has only the upload to do.
        $docker | Should -Match 'Compress-Archive -Path /stage/\* -DestinationPath /app/facade.zip'
        # the same pinned base as the engine, so this product trusts one base
        $engine = Get-Content (Join-Path $script:root 'docker' 'Dockerfile') -Raw
        $base = [regex]::Match($engine, 'FROM (\S+)').Groups[1].Value
        $docker | Should -Match ([regex]::Escape("FROM $base"))
    }

    It 'a person who installs needs NO data role on the store at all (PUBLISH-IN-1)' {
        # FOUND BEFORE MERGE: the publish uploaded a blob, and
        # subscription Owner does NOT carry data-plane blob access. NOFILES-1
        # answered that by granting the person Storage Blob Data Contributor on
        # the code container, from the publish script itself.
        #
        # That grant is gone, and this is the better answer to the same
        # question. The person does not upload anything: the publish job does,
        # with its own identity, from inside the subscription. A laptop holding
        # no data role is a laptop a locked-down store has no reason to admit -
        # which is the whole of why the install works now.
        $publish = Get-Content (Join-Path $script:root 'tools' 'Deploy-VmfFacade.ps1') -Raw
        $code = (Get-VmfCodeOnly -Language PowerShell -Text $publish)
        $code | Should -Not -Match "'Storage Blob Data Contributor'"
        $code | Should -Not -Match 'blobServices/default/containers/vmf-deploy'

        # The role did not disappear - it moved to the job's identity, granted
        # by the template on the CONTAINER, never the account. A removal that
        # left nothing holding it would mean nothing can publish.
        $store = [regex]::Match($script:templateText, "(?s)name: 'vmf-deploy'.*?\n        \}").Value
        $store | Should -Match 'publishIdentity\.outputs\.principalId'
        $store | Should -Match 'roleDefinitionIdOrName: roleBlobContributor'
        # and the account-wide list still must not carry it
        $accountRoles = [regex]::Match($script:templateText, '(?s)\n    roleAssignments: \[(.*?)\n    \]').Groups[1].Value
        $accountRoles | Should -Not -Match 'publishIdentity' -Because 'publishing code reads no migration record'
    }

    It 'and the publish identity is its own principal, not a second hat on the engine (PUBLISH-IN-1)' {
        # An identity that can both publish code and read every migration
        # record is a bigger thing than either job needs.
        $script:templateText | Should -Match "var publishIdentityName = 'vmf-publish-mi-"
        $publishJob = [regex]::Match($script:templateText, "(?s)module publishJob .*?\n\}").Value
        $publishJob | Should -Not -BeNullOrEmpty
        $publishJob | Should -Match 'publishIdentityResourceId'
        $publishJob | Should -Not -Match 'engineIdentity' -Because 'the engine reads and writes every run record'
        # no retry: the two causes are a permission that has not landed, which
        # the job waits for itself, and a network rule, which a second
        # execution meets in exactly the same way.
        $publishJob | Should -Match 'replicaRetryLimit: 0'
    }

    It 'the unused file share is deleted, because the template can never do it (NOFILES-1)' {
        # Found 2026-09-07: a stale Azure Files share was still present after
        # the template stopped using it, though the template was expected to
        # remove it.
        #
        # It cannot. ARM deploys incrementally and never removes a child
        # resource the template does not declare, so a share created outside the
        # template outlives every redeploy - holding a full copy of the app's
        # code and a 100 GiB quota.
        $publish = Get-Content (Join-Path $script:root 'tools' 'Deploy-VmfFacade.ps1') -Raw
        $code = (Get-VmfCodeOnly -Language PowerShell -Text $publish)
        $code | Should -Match 'share-rm delete'
        # matched on the app's own name, so no other share can be caught
        $code | Should -Match '\$FunctionAppName\*'
        # and never while the app might still be running from it
        $code | Should -Match 'if \(\$hasRunFromPackage\) \{'
    }

    It 'and it never retires the content share before the package setting exists (NOFILES-1)' {
        # Same order safety as the storage key above, and the same reason:
        # the publish script can run against sites the template has not
        # reached yet (the deploy workflow did, until WORKFLOWS-UNUSED-1
        # removed it on 2026-11-05). Removing the share
        # first would leave the app with nowhere to get its code from.
        $publish = Get-Content (Join-Path $script:root 'tools' 'Deploy-VmfFacade.ps1') -Raw
        $publish | Should -Match "\`$hasRunFromPackage = .*WEBSITE_RUN_FROM_PACKAGE"
        $publish | Should -Match "if \(\`$hasContentShare -and \`$hasRunFromPackage\)"
    }

    It 'and it never retires that setting before its replacement exists (SEC-1)' {
        # The publish script can run against sites whose template has not
        # caught up (the deploy workflow published CODE on every merge and
        # never deployed infra/platform.bicep, until WORKFLOWS-UNUSED-1
        # removed it). Removing the key-based setting before the identity form
        # is there would leave the host with no storage connection at all -
        # the control plane taken down by a publish.
        $publish = Get-Content (Join-Path $script:root 'tools' 'Deploy-VmfFacade.ps1') -Raw
        $publish | Should -Match "\`$hasIdentityForm = .*AzureWebJobsStorage__accountName"
        $publish | Should -Match "if \(\`$hasKeyForm -and \`$hasIdentityForm\)"
    }
}

Describe 'read endpoints shape the store into API responses' {
    BeforeEach {
        # file-backend run store: the SAME code paths the azblob backend uses
        $script:storeRoot = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-facade-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:runPath = Join-Path $script:storeRoot 'run-a'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Initialize-VmfRun -RunPath $rp -RunId 'run-a' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'run-a' -VmId '/s/rg/vm/vm1' -Wave 'prod-1' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId '/s/rg/vm/vm1' -NewState 'MIGRATED' -Outcome ok | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'run-a' -VmId '/s/rg/vm/vm2' -Wave 'prod-1' | Out-Null
        }
        @{ schemaVersion = 1; assessmentRunId = 'run-a'; entries = @(
            @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/s/rg/vm/vm1'; wave = 'prod-1'; ring = 'prod'; path = 'A'; assessment = @{}; target = @{ size = 's' }; policy = @{ requireApproval = $true } },
            @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/s/rg/vm/vm2'; wave = 'prod-1'; ring = 'prod'; path = 'A'; assessment = @{}; target = @{ size = 's' }; policy = @{ requireApproval = $true } }
        ) } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $script:runPath 'plan.json')
    }
    AfterEach { if (Test-Path $script:storeRoot) { Remove-Item $script:storeRoot -Recurse -Force } }

    It 'Get-VmfFacadeRunSummary rolls up waves with counts and approval state' {
        $s = Get-VmfFacadeRunSummary -StorePath $script:runPath
        $s.runId | Should -Be 'run-a'
        $wave = @($s.waves) | Where-Object wave -EQ 'prod-1'
        $wave.total | Should -Be 2
        $wave.stateCounts.MIGRATED | Should -Be 1
        $wave.requiresApproval | Should -BeTrue
        $wave.approval | Should -BeNullOrEmpty
    }

    It 'summary carries the approval once one exists' {
        Mock -ModuleName VmMigrationFactory Get-VmfSignedInIdentity { @{ Identity = 'a@example.com'; TenantId = 't' } }
        Approve-VmfWave -RunPath $script:runPath -PlanPath (Join-Path $script:runPath 'plan.json') -Wave 'prod-1' -Note 'ok' | Out-Null
        $s = Get-VmfFacadeRunSummary -StorePath $script:runPath
        (@($s.waves) | Where-Object wave -EQ 'prod-1').approval.approvedBy.identity | Should -Be 'a@example.com'
    }
}

Describe 'identity.bicep hygiene (PKG-1: the sign-in registrations are declared, not scripted)' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:idRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
        $script:identityText = Get-Content (Join-Path $script:idRoot 'infra' 'identity.bicep') -Raw
        $script:facadeDeploy = Get-Content (Join-Path $script:idRoot 'tools' 'Deploy-VmfFacade.ps1') -Raw
    }

    It 'every registration declaration carries a uniqueName, so a redeploy ADOPTS it instead of duplicating it' {
        # Found live: the existing apps had no uniqueName, and deploying
        # without setting one first would have created a second pair of
        # registrations and broken every issued token. INSTALL-0 piece 3
        # added a second declaration of the API registration; it reuses the
        # first's uniqueName, so it is the same registration, not a third.
        $apps = @([regex]::Matches($script:identityText, "resource \w+ 'Microsoft.Graph/applications@v1.0'")).Count
        $apps | Should -Be 3
        @([regex]::Matches($script:identityText, 'uniqueName:')).Count | Should -Be $apps
        $script:identityText | Should -Match 'uniqueName: apiApp\.uniqueName'
    }

    It 'the api:// identifier is set from the registration itself and is never empty' {
        # Applying declaratively means an omitted property is a REMOVED
        # property. Losing identifierUris invalidates every token in flight.
        # It used to come from a parameter pasted in on a second run
        # (INSTALL-0 piece 3 removed that); now the template sets it from the
        # registration's own id, and the value can never be empty.
        $script:identityText | Should -Not -Match 'param apiIdentifierUri'
        $script:identityText | Should -Match "identifierUris: \[ 'api://\$\{apiApp\.appId\}' \]"
    }

    It 'the role ids match the ones the deploy script knows' {
        # Drift here is silent: assignments would point at roles that no
        # longer exist and everyone would lose access.
        #
        # The script GRANTS only Vmf.Admin (ROLE-3) but still lists all four,
        # because this map is what holds the template honest. Deleting the
        # three it does not grant would delete the check.
        $inTemplate = @([regex]::Matches($script:identityText, "id: '(6f1c3a10-000\d-[0-9a-f-]+)'") |
            ForEach-Object { $_.Groups[1].Value }) | Sort-Object
        $inScript = @([regex]::Matches($script:facadeDeploy, "'(6f1c3a10-000\d-[0-9a-f-]+)'") |
            ForEach-Object { $_.Groups[1].Value }) | Sort-Object
        $inTemplate.Count | Should -Be 4
        ($inTemplate -join ',') | Should -Be ($inScript -join ',')
    }

    It 'only the dashboard and the CLI may ask for the scope without a consent prompt' {
        $script:identityText | Should -Match 'preAuthorizedApplications'
        $script:identityText | Should -Match '04b07795-8ddb-461a-bbee-02f9e1bf7b46'
        @([regex]::Matches($script:identityText, 'delegatedPermissionIds')).Count | Should -Be 2
    }

    It 'both registrations are SINGLE TENANT, so no outside account can consent' {
        # Question, 2026-09-02: can a user in another Azure tenant open the
        # app, sign in (even to reach the no-access panel) and accept the
        # Entra ID consent? No, and this is what makes it so. AzureADMyOrg means Entra turns
        # an account from any other tenant away AT THE AUTHORIZE ENDPOINT -
        # before a consent screen exists to accept. Change this one word to
        # AzureADMultipleOrgs and anybody in the world could sign in and
        # consent, reaching the no-access panel instead of a closed door. That
        # is a different product with a different threat model, so it should
        # never happen as a side effect of an edit.
        $audiences = [regex]::Matches($script:identityText, "signInAudience:\s*'([^']+)'")
        $apps = @([regex]::Matches($script:identityText, "resource \w+ 'Microsoft.Graph/applications@v1.0'")).Count
        @($audiences).Count | Should -Be $apps -Because 'every declaration of a registration states it'
        foreach ($m in $audiences) {
            $m.Groups[1].Value | Should -Be 'AzureADMyOrg'
        }
    }

    It 'and the dashboard signs in against the tenant, not /common' {
        # The other half. A tenant-specific authority means the sign-in is not
        # even OFFERED to another tenant; /common or /organizations would ask
        # Entra to accept anybody and lean entirely on the audience above.
        $pages = @(Get-ChildItem (Join-Path $script:idRoot 'src' 'dashboard') -Filter '*.html')
        $bad = foreach ($page in $pages) {
            $text = (Get-VmfPageSource -Path $page.FullName)
            if ($text -notmatch 'authority:') { continue }
            if ($text -notmatch 'login\.microsoftonline\.com/\$\{cfg\.tenantId\}') { $page.Name }
            if ($text -match 'login\.microsoftonline\.com/(common|organizations)') { "$($page.Name) (wildcard authority)" }
        }
        $bad -join ', ' | Should -BeNullOrEmpty
    }

    It 'holds no credential of any kind - the whole design is secretless' {
        $script:identityText | Should -Not -Match 'passwordCredentials|keyCredentials|client_secret'
    }

    It 'states the sign-in gate explicitly, so flipping it is a deliberate edit (GATE-1)' {
        # It used to be the LITERAL false while the live tenant was true. A
        # redeploy would have asserted false and silently re-opened sign-in to
        # the whole tenant, which is why it is now an input rather than a
        # constant - and why the test asks for the input, not either literal.
        $script:identityText | Should -Match 'param requireAssignedRole bool'
        $script:identityText | Should -Match 'appRoleAssignmentRequired: requireAssignedRole'
        $script:identityText | Should -Not -Match 'appRoleAssignmentRequired: (false|true)'
    }

    It 'and a redeploy preserves a gate somebody deliberately closed (GATE-1)' {
        # The half that makes the parameter worth having: the default is false,
        # so a deploy that did not look would still re-open it.
        $deploy = Get-Content (Join-Path $script:idRoot 'infra' 'identity-deploy.ps1') -Raw
        $deploy | Should -Match 'appRoleAssignmentRequired' -Because 'it has to read the live posture'
        $deploy | Should -Match 'requireAssignedRole='
        # The service principal is found by the registration's application id,
        # not by the first answer to a display-name lookup: the gate posture
        # has to be read from the registration this deployment updates.
        $deploy | Should -Match '(?s)Get-VmfEntraServicePrincipal.*?requireAssignedRole=' -Because 'read it BEFORE the deployment asserts it'
    }

    It 'the deploy script no longer creates Entra objects - it only grants and publishes' {
        foreach ($banned in 'ad app create', 'ad sp create', 'ad app update', 'identifier-uris') {
            $script:facadeDeploy | Should -Not -Match ([regex]::Escape($banned)) -Because "identity.bicep owns '$banned'"
        }
        $script:facadeDeploy | Should -Match 'infra/identity\.bicep' -Because 'it should say where the registration comes from'
    }

    It 'the Graph extension is GA, pinned to an exact version, and NOT experimental' {
        # Rule since 2026-09-08: no preview version when a GA one exists.
        #
        # This asserted a -preview pin until the extension went GA. The move is
        # a bicepconfig change and nothing else - but experimentalFeaturesEnabled
        # MUST GO WITH IT. With a GA extension, extensibility is no longer
        # experimental, and leaving the flag on breaks the appId read:
        #   InvalidDeployment ... property 'appId' doesn't exist
        # which is what stopped every install on 2026-09-08. Measured six ways;
        # the table is in identity.bicep's header.
        $cfg = Get-Content (Join-Path $script:idRoot 'bicepconfig.json') -Raw | ConvertFrom-Json
        $cfg.extensions.microsoftGraphV1 | Should -Match ':\d+\.\d+\.\d+$' -Because 'an exact version, never floating'
        $cfg.extensions.microsoftGraphV1 | Should -Not -Match 'preview' -Because 'GA exists, so preview is not a choice'
        $cfg.PSObject.Properties.Name | Should -Not -Contain 'experimentalFeaturesEnabled' -Because 'the flag and a GA extension together break the appId read'
    }
}

Describe 'HOST-1: the dashboard is served from a real web host' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:h1Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
        $script:platform = Get-Content (Join-Path $script:h1Root 'infra' 'platform.bicep') -Raw
        $script:dashDeploy = Get-Content (Join-Path $script:h1Root 'tools' 'Deploy-VmfDashboard.ps1') -Raw
        $script:webConfig = Get-Content (Join-Path $script:h1Root 'src' 'dashboard' 'web.config') -Raw
    }

    It 'the template owns the host, free unless the install was asked for warm' {
        $script:platform | Should -Match 'module dashboardPlan'
        # WARM-1: F1 is no longer unconditional. It is still what an install
        # gets by default, and B1 is the only other answer - Premium adds
        # scale, VNet and zones, which this product does not use.
        $script:platform | Should -Match "skuName: warm \? 'B1' : 'F1'"
        $script:platform | Should -Match 'module dashboard '
        $script:platform | Should -Match "kind: 'app'"
    }

    It 'does not ask F1 for something it cannot do' {
        # alwaysOn is unsupported on Free and FAILS THE DEPLOYMENT OUTRIGHT, so
        # it must never be true while the plan is F1. WARM-1 ties it to the
        # same variable the SKU comes from, which is what makes that
        # impossible - a literal true or false here could drift from the plan.
        $script:platform | Should -Match 'alwaysOn: warm'
        $script:platform | Should -Not -Match 'alwaysOn: true'
    }

    It 'the dashboard origin defaults to the host the template creates' {
        # Otherwise blob CORS and the facade CORS would still point at storage
        # and the page would silently fail to read anything.
        $script:platform | Should -Match "param dashboardOrigin string = 'https://vmf-dash-\$\{baseSuffix\}\.azurewebsites\.net'"
        $script:platform | Should -Match 'output dashboardUrl string'
    }

    It 'serves the response headers storage could never serve' {
        # This is the actual reason for HOST-1: a storage static website
        # cannot set a single response header, and the page holds an access
        # token in browser memory.
        $script:webConfig | Should -Match 'Content-Security-Policy'
        $script:webConfig | Should -Match "frame-ancestors 'none'"
        $script:webConfig | Should -Match 'Strict-Transport-Security'
        $script:webConfig | Should -Match 'X-Content-Type-Options'
    }

    It 'the policy still allows the places the page must talk to' {
        # A CSP that breaks the product is not a security win.
        #
        # blob.core.windows.net was one of them and is NOT any more. The
        # dashboard stopped reading the run store at STORE-READ-1; the policy
        # went on allowing it for four more changes, because nothing fails when
        # a permission is wider than the code. ScopeOnboarding.Tests.ps1 now
        # checks that direction too.
        $script:webConfig | Should -Match 'login\.microsoftonline\.com'
        # CSP-AZUREWEBSITES-1: the service is a marker the publish replaces
        # with the exact origin, never a wildcard on azurewebsites.net.
        $script:webConfig | Should -Match "connect-src 'self' \{vmf-service-origin\}"
        $script:webConfig | Should -Not -Match '\*\.azurewebsites\.net'
        $script:webConfig | Should -Match 'graph\.microsoft\.com'
        $script:webConfig | Should -Match 'management\.azure\.com'
        $script:webConfig | Should -Not -Match 'blob\.core\.windows\.net' -Because 'no page reaches the store, and the perimeter would refuse it anyway'
    }

    It 'web.config actually ships with the content' {
        $script:dashDeploy | Should -Match "'web\.config'"
    }

    It 'publishes to the web app, not to storage' {
        # Assert on the COMMANDS, not on prose - the script's header explains
        # what it used to do, and that explanation is worth keeping.
        $script:dashDeploy | Should -Match 'az webapp deploy'
        $script:dashDeploy | Should -Not -Match 'az storage blob'
        $script:dashDeploy | Should -Not -Match 'service-properties update'
    }

    It 'no longer fights identity.bicep over the registration' {
        # It used to PATCH the redirect URIs to the storage endpoint, which
        # would silently undo the template that now owns them.
        foreach ($banned in 'ad app create', 'spa = @{ redirectUris', 'oauth2PermissionGrants', 'storage cors') {
            $script:dashDeploy | Should -Not -Match ([regex]::Escape($banned)) -Because "a template owns '$banned' now"
        }
        $script:dashDeploy | Should -Match 'infra/identity\.bicep'
    }

    It 'refuses to run before the platform exists' {
        $script:dashDeploy | Should -Match 'does not exist. Deploy the platform first'
    }

    It 'the headers use the IIS attribute name, not the HTML one' {
        # This exact mistake cost a live debugging session: content= is the
        # HTML <meta> form, and IIS rejects the unknown attribute as a config
        # error - surfacing as HTTP 500 on EVERY request, static files
        # included, with nothing pointing at web.config.
        $script:webConfig | Should -Match '<add name="Content-Security-Policy"'
        ([regex]::Matches($script:webConfig, '<add name="[^"]+"\s+content=')).Count |
            Should -Be 0 -Because 'IIS customHeaders take value=, never content='
    }

    It 'maps .json, or the page cannot fetch its own configuration' {
        # Also found live: every HTML page returned 200 while
        # dashboard.config.json returned 404, because IIS 404s any extension
        # it has no MIME type for. The page loads and is then useless.
        $script:webConfig | Should -Match 'mimeMap fileExtension="\.json"'
        $script:webConfig | Should -Not -Match '<remove fileExtension' -Because 'removing an undefined mapping is itself a config error'
    }

    It 'nothing lets Azure auto-name a plan' {
        # An orphaned 'CentralUSPlan' was found in the lab: Azure's own default
        # name from the original `az functionapp create --consumption-plan-
        # location`, left behind when PKG-1 moved hosting into the template,
        # hosting nothing and tagged vmf-persistent so every teardown
        # preserved it. Off-convention names are a packaging problem: a
        # customer install must produce resources whose names it chose.
        foreach ($tool in Get-ChildItem (Join-Path $script:h1Root 'tools') -Filter *.ps1) {
            $text = Get-VmfCodeOnly -Path $tool.FullName
            $text | Should -Not -Match 'consumption-plan-location' -Because "$($tool.Name) would let Azure name a plan"
            $text | Should -Not -Match 'functionapp create' -Because "$($tool.Name) should leave hosting to the template"
        }
        # and every plan the template creates is named by the template. The
        # facade's plan name is a var since INSTALL-1 (a Basic facade has a
        # kind-named plan beside it), so both shapes count.
        # PREVIEW-1 made the dashboard's plan name a var too, the same shape
        # the facade's plan has had since INSTALL-1, so both are asserted the
        # same way: the name is declared here, and the module is given it.
        # WARM-1 split the dashboard's Free name into a var of its own. What
        # matters here is unchanged: the TEMPLATE names every plan.
        $script:platform | Should -Match "var dashboardFreePlanName = 'vmf-dash-plan-\$\{baseSuffix\}'"
        $script:platform | Should -Match "var dashboardPlanName = warm \? sharedPlanName : dashboardFreePlanName"
        $script:platform | Should -Match "var sharedPlanName = warm \? 'vmf-plan-b1-\$\{baseSuffix\}' : ''"
        $script:platform | Should -Match 'name: dashboardPlanName'
        $script:platform | Should -Match "var facadePlanName = 'vmf-facade-plan-\$\{baseSuffix\}'"
        $script:platform | Should -Match 'name: facadeHostingPlanName'
    }

    It 'the dashboard host has telemetry, like the facade' {
        # It was created with none. For a site of static files the useful
        # signal is the web server's own logs - when this host 500'd on every
        # request there was nothing to look at.
        # THE DIAGNOSTIC SETTINGS THIS USED TO ASSERT CANNOT EXIST, and asking
        # for them refused the whole deployment:
        #   BadRequest: Category 'AppServiceHTTPLogs' is not supported.
        # This plan is F1 - free - always, and a free App Service supports NO
        # diagnostic categories. MEASURED on the live sites: the categories
        # list comes back EMPTY and neither site carried a setting, so the
        # block had never deployed since DIAG-1 wrote it.
        #
        # THE NEED STANDS AND IS STILL MET. When this host 500'd on every
        # request there was nothing to look at - the answer to that is
        # the site's own logging below, read from the log stream. What is lost
        # is SHIPPING those logs to the workspace, which F1 cannot do at all.
        $script:platform | Should -Match 'detailedErrorLoggingEnabled: true'
        $script:platform | Should -Match 'httpLoggingEnabled: true'
        $script:platform | Should -Match 'requestTracingEnabled: true'
        $script:platform | Should -Not -Match 'vmf-dash-to-logs' -Because 'a free App Service refuses diagnostic settings, and the deployment fails'
        # The facade keeps them, on the plan that can carry them.
        $script:platform | Should -Match "diagnosticSettings: warm \?"
        # PREVIEW-1: the workspace's id is computed from its name rather than
        # taken from the module's output, so a preview can evaluate the site.
        # Same workspace, same wiring - what changed is only how it is named.
        $script:platform | Should -Match 'workspaceResourceId: logsResourceId'
        $script:platform | Should -Match "var logsResourceId = resourceId\('Microsoft\.OperationalInsights/workspaces', logsName\)"
    }
}

Describe 'NAME-3: every resource the template creates carries the install suffix' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:n3 = Get-Content (Join-Path ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))) 'infra' 'platform.bicep') -Raw
    }

    It 'no resource name is hard-coded without the suffix' {
        # Two installs in ONE resource group would otherwise collide, and
        # dev/test/prod sharing a group is a normal customer shape.
        # CHILD resources are exempt: their name is scoped to a parent that
        # already carries the suffix, so two installs cannot collide on them.
        # DIAG-1 added the facade's, for the same reason: two installs in one
        # group have different SITE names, so their diagnostic settings cannot
        # collide however they are named.
        # STORE-LOGS-1 added the store's, scoped to the store's blob service.
        # CODE-CONTAINER-WRITE-1 gave the records container a block of its
        # own (for its role assignments); a container is scoped to the store.
        $childScoped = @('vmf-dash-to-logs', 'vmf-facade-to-logs', 'vmf-store-to-logs', 'vmf-runs')
        $bare = [regex]::Matches($script:n3, "(?m)^\s+name: '(vmf-[a-z-]+)'\s*$") |
            ForEach-Object { $_.Groups[1].Value } |
            Where-Object { $_ -notmatch '-deploy$' -and $_ -notin $childScoped }
        $bare -join ', ' | Should -BeNullOrEmpty -Because 'every name should interpolate baseSuffix'
    }

    It 'the four that were missing it now have it' {
        foreach ($v in 'logsName', 'engineIdentityName', 'acaEnvName', 'engineJobName') {
            $script:n3 | Should -Match "var $v = 'vmf-[a-z-]+-\`$\{baseSuffix\}'"
        }
    }
}

Describe 'A deployed dashboard change actually reaches the browser' {
    It 'the page revalidates rather than being cached by heuristic' {
        # A fix was deployed and the browser kept serving the old page, so the
        # change looked like it had not worked. Without a Cache-Control header
        # IIS lets the browser decide, and it decides to keep the old one.
        $wc = Get-Content (Join-Path ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))) 'src' 'dashboard' 'web.config') -Raw
        $wc | Should -Match 'clientCache cacheControlMode="DisableCache"'
    }
}

Describe 'RESUME-1: a wave that stopped mid-flight is started again' {
    # The engine is resumable and nothing resumed it. An execution that died
    # left the wave where it stopped, for ever, until a person noticed. That
    # was too fragile.
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:rsStore = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rs-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:rsStore -Force | Out-Null
        # StartEngine resolves the store from this, exactly as the scheduler test does.
        $env:VMF_STORE_PATH = $script:rsStore
        $env:VMF_ENGINE_JOB_ID = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.App/jobs/vmf-engine'
        $script:vmA = '/subscriptions/s/resourceGroups/rg-lab/providers/Microsoft.Compute/virtualMachines/vm-a'
        $script:vmB = '/subscriptions/s/resourceGroups/rg-lab/providers/Microsoft.Compute/virtualMachines/vm-b'
        function Script:SeedRun {
            param([string]$StateA = 'CONVERTING', [string]$StateB = 'PLANNED', [bool]$Approved = $true, [bool]$Halted = $false, [int]$LeaseAgeSeconds = -1,
                  [bool]$Gates = $true)
            if (Test-Path $script:rsStore) { Remove-Item $script:rsStore -Recurse -Force }
            New-Item -ItemType Directory -Path $script:rsStore -Force | Out-Null
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rsStore; a = $script:vmA; b = $script:vmB; sa = $StateA; sb = $StateB; appr = $Approved; halt = $Halted; age = $LeaseAgeSeconds } {
                Initialize-VmfRun -RunPath $rp -RunId 'rs-run' | Out-Null
                Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24 -Document ([ordered]@{
                    schemaVersion = 9; runId = 'rs-run'; assessmentRunId = 'rs-run'
                    entries = @(
                        # MACHINES-AT-ONCE-RANGE-1: a resume reads the wave's own number - Pilot, one container.
                        [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $a; wave = 'w1'; path = 'A'; policy = [ordered]@{ throttle = 5 } }
                        [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $b; wave = 'w1'; path = 'A'; policy = [ordered]@{ throttle = 5 } }) })
                foreach ($pair in @(@($a, $sa), @($b, $sb))) {
                    $doc = New-VmfStateDoc -RunPath $rp -RunId 'rs-run' -VmId $pair[0] -Wave 'w1'
                    $doc.state = $pair[1]
                    Write-VmfStateDoc -RunPath $rp -Document $doc
                }
                if ($halt) { Set-VmfWaveHalt -RunPath $rp -Reason 'stop' }
                if ($age -ge 0) {
                    Write-VmfStoreJson -RunPath $rp -RelPath 'leases/vm-a.lease' -Depth 6 -Document ([ordered]@{
                        vmId = $a; workerId = 'worker-1'
                        heartbeatUtc = (Get-Date).ToUniversalTime().AddSeconds(-$age).ToString('o') })
                }
            }
            # RESUME-GATE-1: the gates the engine checks before it starts a wave -
            # a run without them is one the engine would refuse, not a stalled one.
            # RESUME-GATE-1: approved the way the product approves - bound to the
            # plan's version - because the restart now asks the engine's gate.
            if ($Approved) {
                Approve-VmfWave -RunPath $script:rsStore -PlanPath (Join-Path $script:rsStore 'plan.json') -Wave 'w1' -Note 'test' `
                    -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = 't' } | Out-Null
            }
            if ($Gates) {
                Confirm-VmfRunAcknowledgement -RunPath $script:rsStore -AcknowledgedBy 'operator@example.com' | Out-Null
                Confirm-VmfWaveOptions -RunPath $script:rsStore -PlanPath (Join-Path $script:rsStore 'plan.json') -Wave 'w1' -AcceptedBy 'operator@example.com' -Confirm:$false | Out-Null
            }
        }
        function Script:MockArm {
            param([string[]]$RunningWaves = @())
            $script:starts = 0
            # MACHINES-AT-ONCE-RANGE-1: the start reads the wave's own number from its plan; Pilot here, one container.
            Mock -ModuleName FacadeCore Get-VmfFacadeWaveThrottle { 5 }
            # A Mock body runs later, in its own scope: it cannot see this
            # function's parameter. Script scope is what survives.
            $script:runningWaves = @($RunningWaves)
            # ENGINE-START-PART-1 review: the pass and the start's guard ask
            # Test-VmfFacadeEngineRunning, which lists through the module.
            Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod -ParameterFilter { [string]$Path -match '/executions\?' } {
                $value = @($script:runningWaves | ForEach-Object {
                    @{ name = "exec-$_"; properties = @{ status = 'Running'; template = @{ containers = @(@{ env = @(
                        @{ name = 'VMF_OPERATION'; value = 'wave' }, @{ name = 'VMF_RUN_ID'; value = 'rs-run' }, @{ name = 'VMF_WAVE'; value = $_ }) }) } } }
                })
                [pscustomobject]@{ StatusCode = 200; Content = (@{ value = $value } | ConvertTo-Json -Depth 12) }
            }
            Mock -ModuleName FacadeCore Invoke-AzRestMethod {
                if ($Method -eq 'GET' -and $Path -match '\?api-version' -and $Path -notmatch '/executions') {
                    # StartEngine reads the job's template before it posts
                    return [pscustomobject]@{ StatusCode = 200; Content = (@{ properties = @{ template = @{ containers = @(@{
                        name = 'engine'; image = 'i'; resources = @{ cpu = 1; memory = '2Gi' }; env = @() }) } } } | ConvertTo-Json -Depth 10) }
                }
                if ($Method -eq 'GET' -and $Path -match '/executions\?') {
                    $value = @($script:runningWaves | ForEach-Object {
                        @{ name = "exec-$_"; properties = @{ status = 'Running'; template = @{ containers = @(@{ env = @(
                            @{ name = 'VMF_OPERATION'; value = 'wave' }, @{ name = 'VMF_RUN_ID'; value = 'rs-run' }, @{ name = 'VMF_WAVE'; value = $_ }) }) } } }
                    })
                    return [pscustomobject]@{ StatusCode = 200; Content = (@{ value = $value } | ConvertTo-Json -Depth 12) }
                }
                if ($Method -eq 'POST' -and $Path -match '/start\?') {
                    $script:starts++
                    return [pscustomobject]@{ StatusCode = 202; Content = (@{ name = 'exec-new'; id = 'x' } | ConvertTo-Json) }
                }
                [pscustomobject]@{ StatusCode = 200; Content = '{}' }
            }
        }
    }
    AfterAll { if (Test-Path $script:rsStore) { Remove-Item $script:rsStore -Recurse -Force }; Remove-Item Env:\VMF_ENGINE_JOB_ID, Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue }

    It 'RESUME-GATE-1: a wave whose settings changed after acceptance is not restarted, and the refusal is said once' {
        Script:SeedRun -StateA 'CONVERTING'
        Script:MockArm
        # A setting changed after the wave was accepted (the stuck gen1-wave of the first end-to-end run).
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rsStore } {
            $plan = Read-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24
            $plan.entries[0] | Add-Member -NotePropertyName policy -NotePropertyValue ([ordered]@{ acceleratedNetworking = 'ensureOn' }) -Force
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24 -Document $plan
        }
        @(Invoke-VmfFacadeResumeStalledWaves -StorePath $script:rsStore -RunId 'rs-run').Count | Should -Be 0
        @(Invoke-VmfFacadeResumeStalledWaves -StorePath $script:rsStore -RunId 'rs-run').Count | Should -Be 0
        $script:starts | Should -Be 0 -Because 'the engine would only refuse it'
        $ev = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rsStore } { Read-VmfEvents -RunPath $rp -Step 'acceptance' }
        @($ev | Where-Object { $_.outcome -eq 'refused' -and $_.code -eq 'optionsChanged' -and $_.wave -eq 'w1' }).Count |
            Should -Be 1 -Because 'said once, not every five minutes, so the page can offer the acceptance again'
    }

    It 'RESUME-GATE-1: a wave with no acknowledgement is not restarted either' {
        Script:SeedRun -StateA 'CONVERTING' -Gates $false
        Script:MockArm
        @(Invoke-VmfFacadeResumeStalledWaves -StorePath $script:rsStore -RunId 'rs-run').Count | Should -Be 0
        $script:starts | Should -Be 0
    }

    It 'RESUME-GATE-1: the restart line names the step each machine stopped at' {
        Script:SeedRun -StateA 'CONVERTING'
        Script:MockArm
        Invoke-VmfFacadeResumeStalledWaves -StorePath $script:rsStore -RunId 'rs-run' | Out-Null
        $ev = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rsStore } { Read-VmfEvents -RunPath $rp -Step 'resume' }
        @($ev)[-1].detail | Should -Match 'vm-a at CONVERTING'
    }
    It 'resumes a wave with a machine mid-flight, no worker alive, and no execution running' {
        Script:SeedRun -StateA 'CONVERTING'
        Script:MockArm
        $r = @(Invoke-VmfFacadeResumeStalledWaves -StorePath $script:rsStore -RunId 'rs-run')
        $r.Count | Should -Be 1
        $r[0].Wave | Should -Be 'w1'
        $script:starts | Should -Be 1
        $ev = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rsStore } { Read-VmfEvents -RunPath $rp }
        @($ev | Where-Object { $_.step -eq 'resume' -and $_.outcome -eq 'warn' -and $_.detail -match 'started again' }).Count | Should -Be 1
    }

    It 'a wave nobody started is WAITING, not stalled - all PLANNED is left alone' {
        Script:SeedRun -StateA 'PLANNED' -StateB 'PLANNED'
        Script:MockArm
        @(Invoke-VmfFacadeResumeStalledWaves -StorePath $script:rsStore -RunId 'rs-run').Count | Should -Be 0
        $script:starts | Should -Be 0
    }

    It 'a live worker means the run is being worked on - not resumed' {
        Script:SeedRun -StateA 'CONVERTING' -LeaseAgeSeconds 30
        Script:MockArm
        @(Invoke-VmfFacadeResumeStalledWaves -StorePath $script:rsStore -RunId 'rs-run').Count | Should -Be 0
        $script:starts | Should -Be 0
    }

    It 'but an EXPIRED lease is a dead worker, and the wave is resumed' {
        Script:SeedRun -StateA 'CONVERTING' -LeaseAgeSeconds 2000
        Script:MockArm
        @(Invoke-VmfFacadeResumeStalledWaves -StorePath $script:rsStore -RunId 'rs-run').Count | Should -Be 1
    }

    It 'an execution already Running for this wave is not started twice - the image-pull window' {
        Script:SeedRun -StateA 'CONVERTING'
        Script:MockArm -RunningWaves @('w1')
        @(Invoke-VmfFacadeResumeStalledWaves -StorePath $script:rsStore -RunId 'rs-run').Count | Should -Be 0
        $script:starts | Should -Be 0
    }

    It 'a halted run is a person saying stop, and is never argued with' {
        Script:SeedRun -StateA 'CONVERTING' -Halted $true
        Script:MockArm
        @(Invoke-VmfFacadeResumeStalledWaves -StorePath $script:rsStore -RunId 'rs-run').Count | Should -Be 0
        $script:starts | Should -Be 0
    }

    It 'RETRY-GATE-1: a wave set not to need approval is restarted - a retry the engine accepted does not wait for ever' {
        # The restart asked its own narrower question (an approval file, or the
        # plan sign-off) before the engine's gate, so a wave with approval
        # switched off was never restarted. A retry re-armed in it waited at
        # PRECHECK with nothing on the screen.
        Script:SeedRun -StateA 'PRECHECK' -Approved $false -Gates $false
        Script:MockArm
        $planFile = Join-Path $script:rsStore 'plan.json'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rsStore } {
            $plan = Read-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24
            foreach ($e in @($plan.entries)) { $e | Add-Member -NotePropertyName policy -NotePropertyValue ([ordered]@{ requireApproval = $false }) -Force }
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24 -Document $plan
        }
        Confirm-VmfRunAcknowledgement -RunPath $script:rsStore -AcknowledgedBy 'operator@example.com' | Out-Null
        Confirm-VmfWaveOptions -RunPath $script:rsStore -PlanPath $planFile -Wave 'w1' -AcceptedBy 'operator@example.com' -Confirm:$false | Out-Null
        $gate = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rsStore; pp = $planFile } {
            Get-VmfWaveStartGate -RunPath $rp -PlanPath $pp -Plan (Get-Content $pp -Raw | ConvertFrom-Json -Depth 24) -Wave 'w1' }
        $gate | Should -BeNullOrEmpty -Because 'the engine would start this wave, so a retry in it is accepted'
        @(Invoke-VmfFacadeResumeStalledWaves -StorePath $script:rsStore -RunId 'rs-run').Count | Should -Be 1
        $script:starts | Should -Be 1
    }

    It 'resuming is not approving - an unapproved wave is left alone' {
        Script:SeedRun -StateA 'CONVERTING' -Approved $false
        Script:MockArm
        @(Invoke-VmfFacadeResumeStalledWaves -StorePath $script:rsStore -RunId 'rs-run').Count | Should -Be 0
        $script:starts | Should -Be 0
    }

    It 'the timer calls it, every pass' {
        $runner = Get-Content (Join-Path $script:idRoot 'src' 'facade' 'app' 'ScheduleRunner' 'run.ps1') -Raw
        $runner | Should -Match 'Invoke-VmfFacadeResumeStalledWaves -StorePath \$store -RunId \$runId'
    }

    It 'and the run page has a sentence for the event' {
        $page = (Get-VmfPageSource -Path (Join-Path $script:idRoot 'src' 'dashboard' 'migrations.html'))
        $page | Should -Match "waveRestarted:\s*'The run stopped before this wave finished"
        $page | Should -Match "\[/\^resume\$/,\s*'waveRestarted'\]"
    }
}

Describe 'VERSION-1: the service says which build it is, and which engine image is deployed' {
    # Three parts deploy separately, and a deploy that stops halfway leaves
    # them on different builds. The dashboard asks rather than assumes.
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        function Script:MockEngineJob {
            param([string]$Image, [int]$Status = 200)
            # A Mock body runs later, in its own scope; script scope is what survives.
            $script:verImage = $Image
            $script:verStatus = $Status
            Mock -ModuleName FacadeCore Invoke-AzRestMethod {
                [pscustomobject]@{ StatusCode = $script:verStatus; Content = (@{ properties = @{ template = @{ containers = @(@{
                    name = 'engine'; image = $script:verImage }) } } } | ConvertTo-Json -Depth 10) }
            }
        }
        $script:viewer = ConvertFrom-VmfClientPrincipal -Header (NewPrincipalHeader -Roles @('Vmf.Viewer'))
        $script:verJob = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.App/jobs/vmf-engine'
    }
    AfterEach { Remove-Item Env:\VMF_ENGINE_JOB_ID -ErrorAction SilentlyContinue }

    It 'a viewer gets the module version - the same answer Get-VmfVersion gives' {
        $env:VMF_ENGINE_JOB_ID = $script:verJob
        Script:MockEngineJob -Image 'vmfacr.azurecr.io/vmf-engine@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
        $r = Get-VmfFacadeVersion -Principal $script:viewer
        $r.service.version | Should -Be (Get-VmfVersion).version
        $r.service.number | Should -Match '^\d+\.\d+\.\d+$'
    }

    It 'refuses without sign-in, and that is the only refusal' {
        { Get-VmfFacadeVersion -Principal $null } | Should -Throw '*401*'
    }

    It 'reports the engine DIGEST when the job is pinned to one, which is what CD does' {
        $env:VMF_ENGINE_JOB_ID = $script:verJob
        Script:MockEngineJob -Image 'vmfacr.azurecr.io/vmf-engine@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
        $r = Get-VmfFacadeVersion -Principal $script:viewer
        $r.engine.digest | Should -Be 'sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
        $r.engine.tag | Should -BeNullOrEmpty
        $r.engine.note | Should -BeNullOrEmpty
    }

    It 'says so when the job runs a moving tag, rather than calling the tag a build' {
        $env:VMF_ENGINE_JOB_ID = $script:verJob
        Script:MockEngineJob -Image 'vmfacr.azurecr.io/vmf-engine:dev'
        $r = Get-VmfFacadeVersion -Principal $script:viewer
        $r.engine.digest | Should -BeNullOrEmpty
        $r.engine.tag | Should -Be 'dev'
        $r.engine.note | Should -Match "'dev'"
    }

    It 'an engine that is not configured is unknown - never a version, never a failure of the whole answer' {
        $r = Get-VmfFacadeVersion -Principal $script:viewer
        $r.service.version | Should -Not -BeNullOrEmpty
        $r.engine.digest | Should -BeNullOrEmpty
        $r.engine.note | Should -Match 'not configured'
    }

    It 'and so is one Azure will not show' {
        $env:VMF_ENGINE_JOB_ID = $script:verJob
        Script:MockEngineJob -Image 'x' -Status 403
        $r = Get-VmfFacadeVersion -Principal $script:viewer
        $r.engine.digest | Should -BeNullOrEmpty
        $r.engine.note | Should -Match '403'
    }

    It 'says plainly when the job still runs the placeholder (INSTALL-0 piece 4)' {
        $env:VMF_ENGINE_JOB_ID = $script:verJob
        Script:MockEngineJob -Image 'mcr.microsoft.com/k8se/quickstart-jobs:latest'
        $r = Get-VmfFacadeVersion -Principal $script:viewer
        $r.engine.digest | Should -BeNullOrEmpty
        $r.engine.tag | Should -Be 'placeholder'
        $r.engine.note | Should -Match 'No engine image yet'
    }

    It 'says no update model, even on a site that still carries the old settings (PIPELINE-LATER-1)' {
        # INSTALL-0 piece 2 answered updatedBy from VMF_UPDATE_MODEL. A person
        # runs every update now, so the answer has no such part - and a site
        # deployed before the change, which still has the settings until its
        # next azd up, must not bring it back.
        try {
            $env:VMF_UPDATE_MODEL = 'pipeline'; $env:VMF_DEPLOY_PRINCIPAL = '11111111-2222-3333-4444-555555555555'
            $r = Get-VmfFacadeVersion -Principal $script:viewer
            @($r.PSObject.Properties.Name) | Should -Be @('service', 'engine')
        }
        finally { Remove-Item Env:\VMF_UPDATE_MODEL, Env:\VMF_DEPLOY_PRINCIPAL -ErrorAction SilentlyContinue }
    }
}

Describe 'SCALE-UX-1: the number the operator picks sizes the engine' {
    # The engine scales on one factor the user chooses: how many machines
    # run at once in a wave. Measured 2026-09-04 in the real container: 188 MB idle,
    # about 540 MB working, 2,410 MB for the container with five working.
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $env:VMF_ENGINE_JOB_ID = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.App/jobs/vmf-engine'
        $script:sizeStore = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-size-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:sizeStore -Force | Out-Null
        $env:VMF_STORE_PATH = $script:sizeStore
        $script:sizeOperator = ConvertFrom-VmfClientPrincipal -Header (NewPrincipalHeader -Identity 'oper@example.com' -Roles @('Vmf.Operator'))
        function Script:MockJobForSizing {
            param([switch]$ConsumptionOnly)
            # Script scope, not a local: the mock body runs elsewhere and a
            # local here is invisible to it (it read as null = legacy kind).
            $script:sizeProfileName = $(if ($ConsumptionOnly) { $null } else { 'Consumption' })
            Mock -ModuleName FacadeCore Invoke-AzRestMethod {
                if ($Method -eq 'GET' -and $Path -match '/usages\?') {
                    # SCALE-2: the environment has room, unless a test says otherwise.
                    return [pscustomobject]@{ StatusCode = 200; Content = (@{ value = @(@{ name = @{ value = 'ManagedEnvironmentConsumptionCores' }; currentValue = 0; limit = 100 }) } | ConvertTo-Json -Depth 6) }
                }
                if ($Method -eq 'GET') {
                    return [pscustomobject]@{ StatusCode = 200; Content = (@{ properties = @{ workloadProfileName = $script:sizeProfileName; environmentId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.App/managedEnvironments/env'; template = @{ containers = @(@{
                        name = 'engine'; image = 'acr/vmf-engine@sha256:abc'; resources = @{ cpu = 1; memory = '2Gi' }
                        env = @(@{ name = 'VMF_STORE_ACCOUNT'; value = 'acct' }) }) } } } | ConvertTo-Json -Depth 10) }
                }
                $script:sizeBody = $Payload
                if ($script:sizeBodies -is [System.Collections.Generic.List[string]]) { $script:sizeBodies.Add([string]$Payload) }
                [pscustomobject]@{ StatusCode = 202; Content = (@{ name = 'vmf-engine-sz' } | ConvertTo-Json) }
            }
        }
    }
    AfterAll {
        Remove-Item Env:\VMF_ENGINE_JOB_ID, Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue
        if (Test-Path $script:sizeStore) { Remove-Item $script:sizeStore -Recurse -Force }
    }

    It 'maps workers to the three container sizes at exactly the boundaries' {
        foreach ($case in @(@(1, '1', '2Gi'), @(3, '1', '2Gi'), @(4, '2', '4Gi'), @(7, '2', '4Gi'), @(8, '4', '8Gi'), @(15, '4', '8Gi'))) {
            $r = Get-VmfFacadeEngineResources -Workers $case[0]
            $r.cpu | Should -Be $case[1] -Because "$($case[0]) workers"
            $r.memory | Should -Be $case[2] -Because "$($case[0]) workers"
            $r.workers | Should -Be $case[0]
        }
    }

    It 'refuses above the cap, and below one, with a plain sentence' {
        { Get-VmfFacadeEngineResources -Workers 16 } | Should -Throw '*400: at most 15 machines at once*'
        { Get-VmfFacadeEngineResources -Workers 0 } | Should -Throw '*400*at least 1*'
    }

    It 'a wave start sends the sized container, not the job template size' {
        Script:MockJobForSizing
        Mock -ModuleName FacadeCore Get-VmfFacadeWaveThrottle { 12 }
        Invoke-VmfFacadeStartEngine -Principal $script:sizeOperator -Operation 'wave' -RunId 'sz-1' -Wave 'w1' -Note 'big wave' | Out-Null
        $c = ($script:sizeBody | ConvertFrom-Json -Depth 10).containers[0]
        $c.resources.cpu | Should -Be '4'
        $c.resources.memory | Should -Be '8Gi'
        (@($c.env) | Where-Object name -EQ 'VMF_THROTTLE').value | Should -Be '12'
    }

    It 'and every other operation keeps the job its own size' {
        Script:MockJobForSizing
        Invoke-VmfFacadeStartEngine -Principal $script:sizeOperator -Operation 'assess' -RunId 'sz-2' -Note 'scan' | Out-Null
        $c = ($script:sizeBody | ConvertFrom-Json -Depth 10).containers[0]
        "$($c.resources.cpu)" | Should -Be '1'
        $c.resources.memory | Should -Be '2Gi'
    }

    It 'a wave above the cap is refused at START, before anything is launched' {
        Script:MockJobForSizing
        $script:sizeBody = $null
        Mock -ModuleName FacadeCore Get-VmfFacadeWaveThrottle { 61 }
        { Invoke-VmfFacadeStartEngine -Principal $script:sizeOperator -Operation 'wave' -RunId 'sz-3' -Wave 'w1' -Note 'x' } |
            Should -Throw '*400: at most 60*'
        $script:sizeBody | Should -BeNullOrEmpty -Because 'nothing may be started for a number the engine cannot run'
    }

    It 'a start that names no number uses the number the wave editor accepted' {
        # The plan carries throttle 12 for w1; the request carries none.
        InModuleScope VmMigrationFactory -Parameters @{ rp = (Join-Path $script:sizeStore 'sz-4') } {
            Initialize-VmfRun -RunPath $rp -RunId 'sz-4' | Out-Null
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24 -Document ([ordered]@{
                schemaVersion = (Get-VmfPlanSchemaVersion); runId = 'sz-4'
                entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/a'; wave = 'w1'; path = 'A'; policy = [ordered]@{ throttle = 12 } }) })
        }
        Script:MockJobForSizing
        Invoke-VmfFacadeStartEngine -Principal $script:sizeOperator -Operation 'wave' -RunId 'sz-4' -Wave 'w1' -Note 'accepted number' | Out-Null
        $c = ($script:sizeBody | ConvertFrom-Json -Depth 10).containers[0]
        (@($c.env) | Where-Object name -EQ 'VMF_THROTTLE').value | Should -Be '12'
        $c.resources.cpu | Should -Be '4'
    }

    It 'and at SCHEDULING time, not when the schedule releases with nobody watching' {
        Mock -ModuleName FacadeCore Get-VmfFacadeWaveThrottle { 61 }
        { Invoke-VmfFacadeSchedule -Principal $script:sizeOperator -StorePath $script:sizeStore -Wave 'w1' `
            -RunAtUtc ((Get-Date).AddDays(1).ToString('o')) -Note 'late' } | Should -Throw '*400: at most 60*'
        Test-Path (Join-Path $script:sizeStore 'schedules') | Should -BeFalse -Because 'a refused schedule writes nothing'
    }

    Context 'the environment has a ceiling of its own (MEASURED 2026-09-04 by the scale drill)' {
        # Azure, on a Consumption-only environment: "must add up to one of the
        # following CPU - Memory combinations: ... [cpu: 2.0, memory: 4.0Gi]".
        It 'a Consumption-only environment tops out at 7 machines at once, said plainly' {
            $r = Get-VmfFacadeEngineResources -Workers 7 -ConsumptionOnly
            $r.cpu | Should -Be '2'
            $r.memory | Should -Be '4Gi'
            { Get-VmfFacadeEngineResources -Workers 8 -ConsumptionOnly } | Should -Throw '*400: at most 7 machines at once on this installation*'
            { Get-VmfFacadeEngineResources -Workers 16 -ConsumptionOnly } | Should -Throw '*400: at most 15*' -Because 'the general cap still comes first'
        }

        It 'the job says which kind of environment it runs in' {
            $none = [pscustomobject]@{ properties = [pscustomobject]@{ workloadProfileName = $null } }
            $absent = [pscustomobject]@{ properties = [pscustomobject]@{ } }
            $wp = [pscustomobject]@{ properties = [pscustomobject]@{ workloadProfileName = 'Consumption' } }
            Test-VmfFacadeConsumptionOnly -Job $none | Should -BeTrue
            Test-VmfFacadeConsumptionOnly -Job $absent | Should -BeTrue
            Test-VmfFacadeConsumptionOnly -Job $wp | Should -BeFalse
        }

        It 'SCALE-2: a wave of 12 on a Consumption-only job is TWO containers of 6, each at 2 CPU / 4 GiB' {
            Script:MockJobForSizing -ConsumptionOnly
            $script:sizeBodies = [System.Collections.Generic.List[string]]::new()
            Mock -ModuleName FacadeCore Get-VmfFacadeWaveThrottle { 12 }
            $r = Invoke-VmfFacadeStartEngine -Principal $script:sizeOperator -Operation 'wave' -RunId 'sz-5' -Wave 'w1' -Note 'x'
            $r.containers | Should -Be 2
            @($r.executions).Count | Should -Be 2
            $script:sizeBodies.Count | Should -Be 2
            foreach ($b in $script:sizeBodies) {
                $c = ($b | ConvertFrom-Json -Depth 10).containers[0]
                $c.resources.memory | Should -Be '4Gi'
                (@($c.env) | Where-Object name -EQ 'VMF_THROTTLE').value | Should -Be '6'
                (@($c.env) | Where-Object name -EQ 'VMF_THROTTLE_TOTAL').value | Should -Be '12'
            }
            (@(($script:sizeBodies[0] | ConvertFrom-Json -Depth 10).containers[0].env) | Where-Object name -EQ 'VMF_CONTAINER').value | Should -Be '1/2'
            (@(($script:sizeBodies[1] | ConvertFrom-Json -Depth 10).containers[0].env) | Where-Object name -EQ 'VMF_CONTAINER').value | Should -Be '2/2'
        }

        It 'and the same wave of 12 is ONE container of 12 at 4 CPU / 8 GiB on an environment with workload profiles' {
            Script:MockJobForSizing
            $script:sizeBodies = [System.Collections.Generic.List[string]]::new()
            Mock -ModuleName FacadeCore Get-VmfFacadeWaveThrottle { 12 }
            $r = Invoke-VmfFacadeStartEngine -Principal $script:sizeOperator -Operation 'wave' -RunId 'sz-6' -Wave 'w1' -Note 'x'
            $r.containers | Should -Be 1
            ($script:sizeBody | ConvertFrom-Json -Depth 10).containers[0].resources.memory | Should -Be '8Gi'
            (@(($script:sizeBody | ConvertFrom-Json -Depth 10).containers[0].env) | Where-Object name -EQ 'VMF_CONTAINER').value | Should -Be '1/1'
        }

        It 'SCALE-2: a wave of 40 is three containers of 14, 13 and 13, and the log names them all' {
            Script:MockJobForSizing
            $script:sizeBodies = [System.Collections.Generic.List[string]]::new()
            Mock -ModuleName FacadeCore Get-VmfFacadeWaveThrottle { 40 }
            $r = Invoke-VmfFacadeStartEngine -Principal $script:sizeOperator -Operation 'wave' -RunId 'sz-7' -Wave 'w1' -Note 'big'
            $r.containers | Should -Be 3
            @($script:sizeBodies | ForEach-Object { (@(($_ | ConvertFrom-Json -Depth 10).containers[0].env) | Where-Object name -EQ 'VMF_THROTTLE').value }) | Should -Be @('14', '13', '13')
            $ev = InModuleScope VmMigrationFactory -Parameters @{ rp = (Join-Path $script:sizeStore 'sz-7') } { @(Read-VmfEvents -RunPath $rp | Where-Object { $_.step -eq 'engine' }) }
            $ev[-1].detail | Should -Match '3 containers: executions vmf-engine-sz, vmf-engine-sz, vmf-engine-sz'
        }

        It 'a schedule of 61 is refused; a schedule of 15 on the Consumption-only kind is accepted as three containers' {
            Script:MockJobForSizing -ConsumptionOnly
            Mock -ModuleName FacadeCore Get-VmfFacadeWaveThrottle { 61 }
            { Invoke-VmfFacadeSchedule -Principal $script:sizeOperator -StorePath $script:sizeStore -Wave 'w1' `
                -RunAtUtc ((Get-Date).AddDays(1).ToString('o')) -Note 'late' } | Should -Throw '*400: at most 60*'
            Test-Path (Join-Path $script:sizeStore 'schedules') | Should -BeFalse
            Mock -ModuleName FacadeCore Get-VmfFacadeWaveThrottle { 15 }
            { Invoke-VmfFacadeSchedule -Principal $script:sizeOperator -StorePath $script:sizeStore -Wave 'w1' `
                -RunAtUtc ((Get-Date).AddDays(1).ToString('o')) -Note 'late' } | Should -Not -Throw
        }

        It 'SCALE-2: the environment must hold the containers - fits, does not fit, said with the numbers' {
            $script:sizeUsage = @{ current = 12; limit = 100 }
            Mock -ModuleName FacadeCore Invoke-AzRestMethod {
                if ($Method -eq 'GET' -and $Path -match '/usages\?') {
                    return [pscustomobject]@{ StatusCode = 200; Content = (@{ value = @(@{ name = @{ value = 'ManagedEnvironmentConsumptionCores' }; currentValue = $script:sizeUsage.current; limit = $script:sizeUsage.limit }) } | ConvertTo-Json -Depth 6) }
                }
                if ($Method -eq 'GET') {
                    return [pscustomobject]@{ StatusCode = 200; Content = (@{ properties = @{ workloadProfileName = 'Consumption'; environmentId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.App/managedEnvironments/env'; template = @{ containers = @(@{
                        name = 'engine'; image = 'acr/vmf-engine@sha256:abc'; resources = @{ cpu = 1; memory = '2Gi' }
                        env = @(@{ name = 'VMF_STORE_ACCOUNT'; value = 'acct' }) }) } } } | ConvertTo-Json -Depth 10) }
                }
                $script:sizeBody = $Payload
                [pscustomobject]@{ StatusCode = 202; Content = (@{ name = 'vmf-engine-sz' } | ConvertTo-Json) }
            }
            $job = Get-VmfFacadeEngineJob
            $c = Get-VmfFacadeEngineCapacity -Workers 40 -Job $job
            $c.containers | Should -Be 3
            $c.coresNeeded | Should -Be 12 -Because '14, 13 and 13 workers are three containers of 4 CPU'
            $c.coresFree | Should -Be 88
            $c.fits | Should -BeTrue
            $script:sizeUsage = @{ current = 92; limit = 100 }
            (Get-VmfFacadeEngineCapacity -Workers 40 -Job $job).fits | Should -BeFalse
            # WORDS-1: THE NUMBERS, NOT THE SENTENCE. This pinned the wording,
            # so renaming engine capacity to engine workers failed a test about
            # whether the refusal says how short the environment is. What must
            # hold is that all of the numbers are named.
            $said = { Assert-VmfFacadeEngineCapacity -Workers 40 -Job $job } | Should -Throw -PassThru
            $message = [string]$said.Exception.Message
            $message | Should -BeLike '*400:*'
            $message | Should -Match '\b12 cores\b'
            $message | Should -Match '\b3 engine containers'
            $message | Should -Match '8 of 100 Consumption cores free'
            $message | Should -Not -Match 'engine capacity'
            # And the start refuses with the same sentence, before anything is launched.
            $script:sizeBody = $null
            Mock -ModuleName FacadeCore Get-VmfFacadeWaveThrottle { 40 }
            { Invoke-VmfFacadeStartEngine -Principal $script:sizeOperator -Operation 'wave' -RunId 'sz-8' -Wave 'w1' -Note 'x' } | Should -Throw '*400: this wave needs 12 cores*'
            $script:sizeBody | Should -BeNullOrEmpty
            Mock -ModuleName FacadeCore Get-VmfFacadeWaveThrottle { 40 }
            { Invoke-VmfFacadeSchedule -Principal $script:sizeOperator -StorePath $script:sizeStore -Wave 'w1' `
                -RunAtUtc ((Get-Date).AddDays(1).ToString('o')) -Note 'late' } | Should -Throw '*400: this wave needs 12 cores*'
        }

        It 'the split itself: balanced shares, the per-container ceiling, the drill override' {
            $s = Get-VmfFacadeWaveContainers -Workers 40
            $s.containers | Should -Be 3
            $s.perContainer | Should -Be @(14, 13, 13)
            (Get-VmfFacadeWaveContainers -Workers 15).containers | Should -Be 1
            (Get-VmfFacadeWaveContainers -Workers 16).containers | Should -Be 2
            (Get-VmfFacadeWaveContainers -Workers 60).containers | Should -Be 4
            (Get-VmfFacadeWaveContainers -Workers 8 -ConsumptionOnly).perContainer | Should -Be @(4, 4)
            { Get-VmfFacadeWaveContainers -Workers 61 } | Should -Throw '*400: at most 60 machines at once*'
            $env:VMF_CONTAINER_MAX_WORKERS = '3'
            try { (Get-VmfFacadeWaveContainers -Workers 6).perContainer | Should -Be @(3, 3) }
            finally { Remove-Item Env:\VMF_CONTAINER_MAX_WORKERS -ErrorAction SilentlyContinue }
        }
    }
}

Describe 'STORE-READ-1: Resolve-VmfFacadeStoreKey refuses a path it would have to correct' {
    # The store endpoints take a path FROM THE BROWSER, and the facade reads with
    # its own managed identity, which can see the whole container. Without this
    # guard the lowest role could ask for any blob the facade can reach - a wider
    # right than that role is meant to carry.
    #
    # It refuses rather than sanitises: a path that had to be repaired before it
    # was safe is not a path this API should answer.

    It 'allows the shapes the dashboard actually asks for' {
        foreach ($ok in 'run-1/plan.json', 'run-1/state/vm1.json', 'retention-status.json',
                        'proj/run/assessment.json', 'a..b/c.json', 'run..1/plan.json') {
            Resolve-VmfFacadeStoreKey -Path $ok | Should -Be $ok -Because "$ok is a legitimate key"
        }
    }

    It 'REFUSES traversal, on segments so honest dots survive' {
        foreach ($bad in '../secrets.json', 'run/../../x', 'a/b/..', '..') {
            { Resolve-VmfFacadeStoreKey -Path $bad } | Should -Throw '*up a level*' -Because "$bad climbs out of the container"
        }
    }

    It 'REFUSES an absolute path, a drive, a scheme and a backslash' {
        { Resolve-VmfFacadeStoreKey -Path '/etc/passwd' }                  | Should -Throw '*must be relative*'
        { Resolve-VmfFacadeStoreKey -Path 'C:/windows/win.ini' }           | Should -Throw '*name a drive*'
        { Resolve-VmfFacadeStoreKey -Path 'https://elsewhere/x' }          | Should -Throw '*scheme*'
        { Resolve-VmfFacadeStoreKey -Path 'run\plan.json' }                | Should -Throw '*forward slashes*'
    }

    It 'REFUSES a control character, which can split a request' {
        # CR and LF have already cost this repository a regex and a test. In a
        # URL they are worse than useless.
        foreach ($code in 0, 10, 13, 31, 127) {
            $bad = 'run' + [char]$code + '/plan.json'
            { Resolve-VmfFacadeStoreKey -Path $bad } | Should -Throw '*control character*' -Because "char $code must never reach a request"
        }
    }

    It 'REFUSES an empty blob path, but ALLOWS an empty prefix' {
        # Listing the top of the container is a real request; reading "no blob"
        # is not.
        { Resolve-VmfFacadeStoreKey -Path '' } | Should -Throw '*a path is required*'
        Resolve-VmfFacadeStoreKey -Path '' -AllowEmpty | Should -Be ''
        Resolve-VmfFacadeStoreKey -Path $null -AllowEmpty | Should -Be ''
    }

    It 'REFUSES an absurdly long path' {
        { Resolve-VmfFacadeStoreKey -Path ('a' * 1025) } | Should -Throw '*too long*'
    }

    It 'every refusal begins 400, so the endpoints answer Bad Request' {
        # Not 500. A caller who sent a bad path should be told that, and it must
        # not read as the service being broken.
        foreach ($bad in '../x', '/x', 'C:/x', 'https://x/y', 'a\b', '') {
            $message = ''
            try { Resolve-VmfFacadeStoreKey -Path $bad } catch { $message = "$_" }
            $message | Should -Match '^400 ' -Because "'$bad' is the caller's mistake, not ours"
        }
    }
}

Describe 'STORE-READ-1: ConvertFrom-VmfFacadeBlobListing gives the shape the browser had' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:listing = @'
<?xml version="1.0" encoding="utf-8"?>
<EnumerationResults>
  <Blobs>
    <Blob><Name>run-1/plan.json</Name></Blob>
    <Blob><Name>run-1/state/vm1.json</Name></Blob>
    <BlobPrefix><Name>run-1/state/</Name></BlobPrefix>
  </Blobs>
  <NextMarker>2!MTk5</NextMarker>
</EnumerationResults>
'@
    }

    It 'names come from Blob, prefixes from BlobPrefix with the slash removed' {
        $r = ConvertFrom-VmfFacadeBlobListing -Xml $script:listing
        $r.names | Should -Be @('run-1/plan.json', 'run-1/state/vm1.json')
        $r.prefixes | Should -Be @('run-1/state')
    }

    It 'and it carries NextMarker out, because the browser never paged' {
        # A listing stops at 5,000 blobs. The browser did not page, so a large
        # enough run was silently short by whatever it held - no error, just
        # missing rows.
        (ConvertFrom-VmfFacadeBlobListing -Xml $script:listing).nextMarker | Should -Be '2!MTk5'
    }

    It 'an empty answer is empty arrays, never null' {
        $r = ConvertFrom-VmfFacadeBlobListing -Xml ''
        @($r.names).Count | Should -Be 0
        @($r.prefixes).Count | Should -Be 0
        $r.nextMarker | Should -Be ''
    }
}

Describe 'STORE-READ-4: the listing Azure really sends starts with a byte order mark' {
    # MEASURED on a work subscription, 2026-09-14, on the first page load of a
    # fresh install. The dashboard showed this instead of the Overview:
    #
    #   Cannot convert value "<?xml version="1.0" ...?><EnumerationResults ...>"
    #   to type "System.Xml.XmlDocument".
    #
    # THE FIXTURE ABOVE IS WHY IT SHIPPED. It is hand-written XML with no mark,
    # so every test passed against a string Azure never sends. The engine knew -
    # StoreApi.ps1 says "the BOM-safe way is regex over <Name> nodes" - and
    # STORE-READ-1 moved this parse from the browser, where a DOMParser had
    # tolerated it, into PowerShell, which does not.
    #
    # These drive the REAL shape: the mark, the declaration, and the empty
    # listing a fresh install returns.
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:bom = [char]0xFEFF
        # An empty store, exactly as a real install answered - <Blobs />
        # self-closed, and no NextMarker content.
        $script:emptyReal = $script:bom + '<?xml version="1.0" encoding="utf-8"?>' +
            '<EnumerationResults ServiceEndpoint="https://vmfstate.blob.core.windows.net/" ' +
            'ContainerName="vmf-runs"><Delimiter></Delimiter><Blobs /><NextMarker /></EnumerationResults>'
        $script:fullReal = $script:bom + '<?xml version="1.0" encoding="utf-8"?>' +
            '<EnumerationResults><Blobs>' +
            '<Blob><Name>run-1/plan.json</Name></Blob>' +
            '<BlobPrefix><Name>run-1/state/</Name></BlobPrefix>' +
            '</Blobs><NextMarker>2!MTk5</NextMarker></EnumerationResults>'
    }

    It 'the fixture really carries the mark, or this whole block proves nothing' {
        # Without this, a fixture that quietly lost the mark would make every
        # test below pass for the same reason the old ones did.
        [int][char]$script:emptyReal[0] | Should -Be 0xFEFF
        [int][char]$script:fullReal[0] | Should -Be 0xFEFF
    }

    It 'a fresh install reads as an empty listing instead of throwing' {
        # THE BUG: this threw, and the dashboard showed the exception.
        $r = ConvertFrom-VmfFacadeBlobListing -Xml $script:emptyReal
        @($r.names).Count | Should -Be 0
        @($r.prefixes).Count | Should -Be 0
        $r.nextMarker | Should -Be ''
    }

    It 'and a listing with content still reads correctly through the mark' {
        # Skipping the mark must not skip anything else.
        $r = ConvertFrom-VmfFacadeBlobListing -Xml $script:fullReal
        $r.names | Should -Be @('run-1/plan.json')
        $r.prefixes | Should -Be @('run-1/state')
        $r.nextMarker | Should -Be '2!MTk5'
    }

    It 'leading whitespace before the declaration is survived too' {
        $r = ConvertFrom-VmfFacadeBlobListing -Xml ("`r`n  " + $script:fullReal)
        $r.names | Should -Be @('run-1/plan.json')
    }

    It 'something that is not XML at all is refused by us, not by a cast' {
        # A storage error page or an HTML sign-in redirect must not surface as
        # "cannot convert value" with the whole body in it, which is what the
        # operator saw.
        { ConvertFrom-VmfFacadeBlobListing -Xml 'not xml at all' } |
            Should -Throw '*is not XML*'
    }
}
