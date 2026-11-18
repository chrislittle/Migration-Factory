#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# GEN-V5-1 C6: v5 is a size series the plan can hold, everywhere a series is
# written, read, checked or chosen.
#
# The plan format moves to v14: policy.targetGeneration accepts v5. Nothing
# else in the document changes, and a v13 plan still reads - it can only hold
# v6 or v7, which v14 also accepts.
#
# The series is stored per machine, and the engine moves each machine on its
# own. A wave may hold machines of more than one series (2026-09-26);
# showing and choosing that per machine is WAVE-MIX-1.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json') -Raw | ConvertFrom-Json
}

Describe 'GEN-V5-1 C6: the plan format holds v5' {

    # ADVISOR-1 moved the format to v15 (target.choice); v5 arrived in v14 and
    # is still held, which is what this Describe is about.
    # WAVE-LEVER-OVERRIDE-1 moved it to 17 (an entry records the settings a
    # decision gave that one machine), V3-RETIRE-1 to 18 (target.rollbackSize),
    # MANA-LINUX-KERNEL-1 to 19 (onDriverBelowFloor 'updateKernel', and
    # 'clean' and osDiskData removed), and WAVE-AN-NAMES-1 to 20
    # (acceleratedNetworkingOutcome), and HDD-OS-1 to 21 (os-standard-ssd and
    # assessment.osDiskType), and IDENTITY-LOSS-1 to 22 (decisions principalId);
    # the two must still agree.
    It 'the schema and the module agree on the version, 24 since REBUILD-ACCEPT-1' {
        $script:schema.properties.schemaVersion.const | Should -Be 37
        InModuleScope VmMigrationFactory { Get-VmfPlanSchemaVersion | Should -Be 37 }
    }

    It 'the schema accepts v5, v6 and v7 as a wave''s size series' {
        @($script:schema.properties.policy.properties.targetGeneration.enum) | Should -Be @('v5', 'v6', 'v7')
    }

    It 'and so does the lever table the engine checks a change against' {
        InModuleScope VmMigrationFactory {
            @((Get-VmfPolicyLevers)['targetGeneration']) | Should -Be @('v5', 'v6', 'v7')
            # STATE-TARGET-1: a decision may not change the series at all - it
            # would change it without the size, controller and path that follow.
            # A machine that has started keeps its series; plan it again to change it.
            $r = Test-VmfPolicyOverride -Override @{ targetGeneration = 'v5' }
            $r.Ok | Should -BeFalse
            $r.Detail | Should -Match 'plan the machine again'
            (Test-VmfPolicyOverride -Override @{ targetGeneration = 'v4' }).Ok | Should -BeFalse
        }
    }

    It 'a v13 plan still reads' {
        InModuleScope VmMigrationFactory {
            $old = [pscustomobject]@{ entries = @([pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = 'x'; policy = [pscustomobject]@{ targetGeneration = 'v6' } }) }
            { ConvertTo-VmfSupportedPlan -Plan $old } | Should -Not -Throw
        }
    }

    It 'the migration note is written' {
        $notes = Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw
        $notes | Should -Match 'plan-entry v13 -> v14'
    }
}

Describe 'GEN-V5-1 C6: every place that takes a size series takes v5' {

    It '<Where> accepts v5' -ForEach @(
        @{ Where = 'New-VmfPlan';            File = 'src/VmMigrationFactory/Public/New-VmfPlan.ps1' }
        @{ Where = 'the service';            File = 'src/facade/FacadeCore/FacadeCore.psm1' }
    ) {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot $File)
        $code | Should -Not -Match "(?<!'v5', )'v6', 'v7'\)" -Because "$Where must not list only v6 and v7"
        $code | Should -Match "'v5', 'v6', 'v7'"
    }

    It 'the cmdlets really bind v5' {
        (Get-Command New-VmfPlan).Parameters['TargetGeneration'].Attributes.ValidValues | Should -Contain 'v5'
    }
}

Describe 'GEN-V5-1 C6: the size series belongs to the machine' {

    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-v5plan-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/'
        $mk = {
            param($name, $wave, $gen, $size)
            [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$sub$name"; wave = $wave; appGroup = $name
                assessment = [ordered]@{ classification = 'ReadyAfterPrep'; os = 'Linux'; sourceSize = 'Standard_D2ds_v4'; location = 'centralus'; availabilitySetId = '' }
                target = [ordered]@{ size = $size; controller = $(if ($gen -eq 'v5') { 'SCSI' } else { 'NVMe' }) }
                path = 'A'; policy = [ordered]@{ targetGeneration = $gen; requireApproval = $true } }
        }
        $plan = [ordered]@{ schemaVersion = 4; entries = @(
                (& $mk 'a' 'five' 'v5' 'Standard_D2ds_v5'), (& $mk 'b' 'six' 'v6' 'Standard_D2ds_v6'), (& $mk 'c' 'six' 'v6' 'Standard_D2ds_v6')) }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; plan = $plan } {
            Initialize-VmfRun -RunPath $rp -RunId 'v5plan' | Out-Null
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document $plan
        }
        $script:sub = $sub
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'a machine moved into a wave of another series keeps its own series and target size' {
        # Decided 2026-09-26: a complex estate has mixed needs in one wave, and
        # Microsoft groups waves by application. The series is the MACHINE's;
        # the wave's is only its default. So a move carries the machine's own
        # pair, which stays consistent, rather than being refused.
        $waves = @(@{ name = 'five'; vmIds = @("$($script:sub)a", "$($script:sub)b") }, @{ name = 'six'; vmIds = @("$($script:sub)c") })
        Set-VmfWavePlan -RunPath $script:rp -PlanPath (Join-Path $script:rp 'plan.json') -Layout @{ waves = $waves } -Confirm:$false | Out-Null
        $plan = Get-Content (Join-Path $script:rp 'plan.json') -Raw | ConvertFrom-Json
        $b = @($plan.entries | Where-Object { $_.vmId -like '*/b' })[0]
        $b.wave | Should -Be 'five'
        $b.policy.targetGeneration | Should -Be 'v6'
        $b.target.size | Should -Be 'Standard_D2ds_v6'
        $b.target.controller | Should -Be 'NVMe'
    }

    It 'moving between two waves of the same series is allowed, as before' {
        $waves = @(@{ name = 'five'; vmIds = @("$($script:sub)a") }, @{ name = 'six'; vmIds = @("$($script:sub)b", "$($script:sub)c") })
        { Set-VmfWavePlan -RunPath $script:rp -PlanPath (Join-Path $script:rp 'plan.json') -Layout @{ waves = $waves } -Confirm:$false } | Should -Not -Throw
    }
}
