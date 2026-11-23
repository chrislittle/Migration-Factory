#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# WAVE-SAVE-NO-PLAN-1: a wave save sent while the plan is first written could
# turn off a wave's sign-off without the Approver role.
#
# APPR-LEVER-1 lets only an approver take the sign-off requirement off. The
# service asks Get-VmfWaveLayoutWrites which writes a save makes, and checks
# the role on them. With no plan.json yet, that function judged an empty list
# of entries - no writes, so no role check - and gave back the version ''.
# The service passed '' to Set-VmfWavePlan as -ExpectedPlanVersion, whose
# check is skipped for an empty value, so a save whose judgement read before
# the plan operation wrote plan.json, and whose write read after it, wrote
# requireApproval=false with no approver.
#
# Now the judgement refuses (400) when there is no plan, never gives back an
# empty version, and Set-VmfWavePlan refuses an empty version it was given.
# A caller that gives no version at all (the command line, the lab drills)
# still has its save checked against its own read (PLAN-WRITE-RACE-1).
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:WsnpPrincipal {
        param([string]$Identity, [string[]]$Roles)
        $claims = @(@{ typ = 'preferred_username'; val = $Identity }) +
                  @($Roles | ForEach-Object { @{ typ = 'roles'; val = $_ } })
        $doc = @{ auth_typ = 'aad'; claims = $claims } | ConvertTo-Json -Depth 5
        ConvertFrom-VmfClientPrincipal -Header ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($doc)))
    }

    # One wave that needs sign-off. Text only: the race test writes it at the
    # moment the plan operation would.
    function Global:WsnpPlanText {
        @{ schemaVersion = 1; assessmentRunId = 'wsnp'; entries = @(
                @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/s/rg/vm/vm1'; wave = 'prod-1'; ring = 'prod'; path = 'A'; assessment = @{}; target = @{ size = 's' }
                    policy = @{ requireApproval = $true; onDDataFound = 'stop' } }
            ) } | ConvertTo-Json -Depth 8
    }

    function Global:WsnpNewRun {
        param([switch]$WithPlan)
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-wsnp-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { Initialize-VmfRun -RunPath $rp -RunId 'wsnp' | Out-Null }
        if ($WithPlan) { [System.IO.File]::WriteAllText((Join-Path $rp 'plan.json'), (WsnpPlanText), [System.Text.UTF8Encoding]::new($false)) }
        $rp
    }

    $script:offLayout = @{ waves = @(@{ name = 'prod-1'; vmIds = @('/s/rg/vm/vm1'); requireApproval = $false }) }
}
AfterAll {
    foreach ($fn in 'WsnpPrincipal', 'WsnpPlanText', 'WsnpNewRun') {
        Remove-Item "Function:\$fn" -ErrorAction SilentlyContinue
    }
}

Describe 'WAVE-SAVE-NO-PLAN-1: the judgement of a save refuses when there is no plan' {
    AfterEach { if ($script:run -and (Test-Path $script:run)) { Remove-Item $script:run -Recurse -Force } }

    It 'refuses with 400 on the file backend' {
        $script:run = WsnpNewRun
        { InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; l = $script:offLayout } {
                Get-VmfWaveLayoutWrites -RunPath $rp -Layout $l } } |
            Should -Throw '400: There is no plan in this migration yet.*'
    }

    It 'refuses with 400, not a file error, when the caller stops on every error as the service does' {
        # The service runs with errors that stop. A read of a missing file
        # there is "Cannot find path", which the page shows as a fault.
        $script:run = WsnpNewRun
        { InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; l = $script:offLayout } {
                Get-VmfWaveLayoutWrites -RunPath $rp -Layout $l -ErrorAction Stop } } |
            Should -Throw '400: There is no plan in this migration yet.*'
    }

    It 'refuses with 400 when the read finds no plan' {
        # The plan was there when it was looked for, and gone when it was read.
        $script:run = WsnpNewRun -WithPlan
        Mock -ModuleName VmMigrationFactory Read-VmfPlanFileVersioned { $null }
        { InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; l = $script:offLayout } {
                Get-VmfWaveLayoutWrites -RunPath $rp -Layout $l } } |
            Should -Throw '400: There is no plan in this migration yet.*'
    }

    It 'never gives back an empty version: a read with none is refused' {
        $script:run = WsnpNewRun -WithPlan
        Mock -ModuleName VmMigrationFactory Read-VmfPlanFileVersioned {
            [pscustomobject]@{ Text = '{}'; Version = ''; Plan = [pscustomobject]@{ entries = @() } }
        }
        { InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; l = $script:offLayout } {
                Get-VmfWaveLayoutWrites -RunPath $rp -Layout $l } } |
            Should -Throw '400: There is no plan in this migration yet.*'
    }

    It 'with a plan, judges it and gives back the version of the text it read' {
        $script:run = WsnpNewRun -WithPlan
        $judged = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; l = $script:offLayout } {
            Get-VmfWaveLayoutWrites -RunPath $rp -Layout $l
        }
        $expected = InModuleScope VmMigrationFactory -Parameters @{ f = (Join-Path $script:run 'plan.json') } {
            Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path $f)
        }
        $judged.Version | Should -Be $expected
        $judged.Version | Should -Not -BeNullOrEmpty
        @($judged.Writes | Where-Object { $_.Field -eq 'requireApproval' -and -not $_.To }).Count | Should -Be 1
    }

    Context 'on blob storage, where a missing plan reads as nothing' {
        BeforeEach {
            $script:run = $null
            $script:blobRun = 'azblob://acct/cont/run-1'
            $script:headCode = 404
            $script:getCode = 404
            Mock -ModuleName VmMigrationFactory Invoke-VmfStorageRequest {
                if ($Method -eq 'HEAD') { return [pscustomobject]@{ StatusCode = $script:headCode; Content = ''; Headers = @{} } }
                [pscustomobject]@{ StatusCode = $script:getCode; Content = ''; Headers = @{} }
            }
        }

        It 'refuses with 400 when there is no plan' {
            { InModuleScope VmMigrationFactory -Parameters @{ rp = $script:blobRun; l = $script:offLayout } {
                    Get-VmfWaveLayoutWrites -RunPath $rp -Layout $l } } |
                Should -Throw '400: There is no plan in this migration yet.*'
        }

        It 'refuses with 400 when the plan is gone between the look and the read' {
            $script:headCode = 200
            { InModuleScope VmMigrationFactory -Parameters @{ rp = $script:blobRun; l = $script:offLayout } {
                    Get-VmfWaveLayoutWrites -RunPath $rp -Layout $l } } |
                Should -Throw '400: There is no plan in this migration yet.*'
        }

        It 'an answer that is not "not found" is an error, never "no plan"' {
            $script:headCode = 403
            { InModuleScope VmMigrationFactory -Parameters @{ rp = $script:blobRun; l = $script:offLayout } {
                    Get-VmfWaveLayoutWrites -RunPath $rp -Layout $l } } |
                Should -Throw '*HTTP 403*'
        }
    }
}

Describe 'WAVE-SAVE-NO-PLAN-1: the service refuses a save before the plan exists' {
    BeforeEach {
        $script:operator = WsnpPrincipal -Identity 'oper@example.com' -Roles @('Vmf.Operator')
    }
    AfterEach { if ($script:run -and (Test-Path $script:run)) { Remove-Item $script:run -Recurse -Force } }

    It 'an Operator''s save with no plan is a 400, and nothing is written' {
        $script:run = WsnpNewRun
        Mock -ModuleName FacadeCore Set-VmfWavePlan { throw 'the writer must not be reached' }
        { Invoke-VmfFacadeSetWaves -Principal $script:operator -StorePath $script:run -Note 'go faster' -Waves @(
                [pscustomobject]@{ name = 'prod-1'; vmIds = @('/s/rg/vm/vm1'); requireApproval = $false }) } |
            Should -Throw '400: There is no plan in this migration yet.*'
        Should -Invoke -ModuleName FacadeCore Set-VmfWavePlan -Times 0 -Exactly
    }

    It 'the race: a plan written just after the judgement looked does not get sign-off turned off' {
        # The finding's attack. The plan operation writes plan.json at the
        # moment the judgement reads it: the judgement sees no plan, and the
        # writer, which reads again, sees one. The judgement must refuse, or
        # the write takes the sign-off off with no role check.
        $script:run = WsnpNewRun
        $script:planFile = Join-Path $script:run 'plan.json'
        $script:planText = WsnpPlanText
        $script:reads = 0
        Mock -ModuleName VmMigrationFactory Read-VmfPlanFileVersioned {
            $script:reads++
            if ($script:reads -eq 1 -and -not [System.IO.File]::Exists($script:planFile)) {
                [System.IO.File]::WriteAllText($script:planFile, $script:planText, [System.Text.UTF8Encoding]::new($false))
                return $null
            }
            $text = [System.IO.File]::ReadAllText($Path)
            $version = & (Get-Module VmMigrationFactory) { param($t) Get-VmfDocumentVersion -Text $t } $text
            [pscustomobject]@{ Text = $text; Version = $version; Plan = ($text | ConvertFrom-Json -Depth 24) }
        }
        Mock -ModuleName VmMigrationFactory Test-VmfStoreItem {
            # The look happens before the plan operation writes.
            if ($RelPath -eq 'plan.json' -and $script:reads -eq 0) {
                [System.IO.File]::WriteAllText($script:planFile, $script:planText, [System.Text.UTF8Encoding]::new($false))
                return $false
            }
            [System.IO.File]::Exists((Join-Path $RunPath $RelPath))
        }
        { Invoke-VmfFacadeSetWaves -Principal $script:operator -StorePath $script:run -Note 'go faster' -Waves @(
                [pscustomobject]@{ name = 'prod-1'; vmIds = @('/s/rg/vm/vm1'); requireApproval = $false }) } |
            Should -Throw '400: There is no plan in this migration yet.*'
        $plan = Get-Content $script:planFile -Raw | ConvertFrom-Json
        @($plan.entries)[0].policy.requireApproval | Should -BeTrue -Because 'an Operator never takes the sign-off off'
    }
}

Describe 'WAVE-SAVE-NO-PLAN-1: Set-VmfWavePlan refuses an empty version it was given' {
    BeforeEach { $script:run = WsnpNewRun -WithPlan }
    AfterEach { if ($script:run -and (Test-Path $script:run)) { Remove-Item $script:run -Recurse -Force } }

    It 'refuses an empty -ExpectedPlanVersion with 400, and writes nothing' {
        $before = Get-Content (Join-Path $script:run 'plan.json') -Raw
        { Set-VmfWavePlan -RunPath $script:run -PlanPath (Join-Path $script:run 'plan.json') -Layout $script:offLayout `
                -ChangedBy 'oper@example.com' -ExpectedPlanVersion '' -Confirm:$false } |
            Should -Throw '400: The save did not give the version of the plan it read.*'
        Get-Content (Join-Path $script:run 'plan.json') -Raw | Should -Be $before
    }

    It 'refuses a version that is only spaces too' {
        { Set-VmfWavePlan -RunPath $script:run -PlanPath (Join-Path $script:run 'plan.json') -Layout $script:offLayout `
                -ChangedBy 'oper@example.com' -ExpectedPlanVersion '   ' -Confirm:$false } |
            Should -Throw '400: The save did not give the version of the plan it read.*'
    }

    It 'a caller that gives no version (the command line) still saves, checked against its own read' {
        $r = Set-VmfWavePlan -RunPath $script:run -PlanPath (Join-Path $script:run 'plan.json') -Layout $script:offLayout `
            -ChangedBy 'lead@example.com' -Confirm:$false
        $r.Unchanged | Should -BeFalse
        $plan = Get-Content (Join-Path $script:run 'plan.json') -Raw | ConvertFrom-Json
        @($plan.entries)[0].policy.requireApproval | Should -BeFalse
    }

    It 'the version the plan holds now is accepted' {
        $now = InModuleScope VmMigrationFactory -Parameters @{ f = (Join-Path $script:run 'plan.json') } {
            Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path $f)
        }
        { Set-VmfWavePlan -RunPath $script:run -PlanPath (Join-Path $script:run 'plan.json') -Layout $script:offLayout `
                -ChangedBy 'lead@example.com' -ExpectedPlanVersion $now -Confirm:$false } | Should -Not -Throw
    }
}
