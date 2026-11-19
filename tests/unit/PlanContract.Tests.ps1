#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# EVAL-H11: the plan was the ONE artifact read with no version gate. State
# documents refuse an unsupported version; assessments refuse; the plan - the
# contract that moved v3 to v8 in 36 hours - was parsed and returned.
#
# The live consequence on the day of the audit: renaming a lever value from
# 'park' to 'stop' left older plans saying 'park', every hash still matched, so
# a wave resumed cleanly and then did NOT stop when user data was found on the
# temporary disk - while both dashboards rendered 'park' as "Stop and ask".
# The screen showed the safe behaviour and the engine did the other thing.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Script:Plan([int]$version, [string]$dataLever) {
        [pscustomobject]@{
            schemaVersion = $version
            entries = @([pscustomobject]@{
                schemaVersion = $version
                vmId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
                wave = 'w1'; path = 'A'
                policy = [pscustomobject]@{ onDDataFound = $dataLever; onDriverBelowFloor = $dataLever }
            })
        }
    }
}

Describe 'EVAL-H11: the plan reader changes no value (OLD-VERSION-READERS-REMOVE-2: no rename on read)' {
    It 'leaves a current plan untouched and says nothing' {
        InModuleScope VmMigrationFactory -Parameters @{ p = (Script:Plan (Get-VmfTestPlanEntryVersion) 'stop') } {
            $out = ConvertTo-VmfSupportedPlan -Plan $p
            @($out.entries)[0].policy.onDDataFound | Should -Be 'stop'
            $out.PSObject.Properties['vmfMigrations'] | Should -BeNullOrEmpty
        }
    }

    It 'a value that was never renamed is left alone' {
        InModuleScope VmMigrationFactory {
            $p = [pscustomobject]@{ entries = @([pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion)
                vmId = '/x'; policy = [pscustomobject]@{ onDDataFound = 'proceed' } }) }
            (ConvertTo-VmfSupportedPlan -Plan $p).entries[0].policy.onDDataFound | Should -Be 'proceed'
        }
    }
}

Describe 'EVAL-H11: a plan this build cannot understand is refused by name' {
    It 'refuses a NEWER contract version and names it' {
        InModuleScope VmMigrationFactory -Parameters @{ p = (Script:Plan 99 'stop') } {
            { ConvertTo-VmfSupportedPlan -Plan $p } | Should -Throw '*version 99*'
        }
    }

    It 'the refusal says what to do about it' {
        InModuleScope VmMigrationFactory -Parameters @{ p = (Script:Plan 99 'stop') } {
            $msg = try { ConvertTo-VmfSupportedPlan -Plan $p } catch { $_.Exception.Message }
            $msg | Should -Match '(?i)upgrade the product'
        }
    }

    It 'an empty or missing plan is not an error - there is simply nothing to check' {
        InModuleScope VmMigrationFactory {
            ConvertTo-VmfSupportedPlan -Plan $null | Should -BeNullOrEmpty
        }
    }
}

Describe 'EVAL-H11: nothing walks around the gate' {
    It 'no code reads plan.json except the gated reader' {
        # A version gate half the callers bypass is not a gate.
        $offenders = foreach ($f in (Get-ChildItem (Join-Path $script:repoRoot 'src') -Recurse -Include '*.ps1','*.psm1') +
                                    @(Get-Item (Join-Path $script:repoRoot 'docker' 'entrypoint.ps1'))) {
            if ($f.Name -eq 'PlanContract.ps1') { continue }
            $t = Get-Content $f.FullName -Raw
            if ($t -match "Read-VmfStoreJson[^\r\n]*'plan\.json'") { "$($f.Name) reads plan.json directly" }
        }
        $offenders -join '; ' | Should -BeNullOrEmpty
    }

    It 'the gate is what Start-VmfWave uses, since nothing runs without it' {
        $sw = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Start-VmfWave.ps1') -Raw
        $sw | Should -Match 'Read-VmfPlan(Document|File)'
    }
}
