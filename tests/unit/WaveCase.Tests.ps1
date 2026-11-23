#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
WAVE-CASE-1: two waves whose names differ only in letter case.

The engine compares wave names without letter case: Start-VmfWave picks a
wave's machines with -eq, and Group-Object, -in and the plan run do the same.
Blob names keep letter case, so approvals/Wave1.json and approvals/wave1.json
are two files, while the file store on Windows holds one. A plan with waves
Wave1 and wave1 is therefore one wave to the engine and two to the store.

So the wave editor and Set-VmfWavePlan refuse such names, by ONE rule held to
ONE fixture (tests/fixtures/wave-name-clash.json): Find-VmfWaveNameClash here,
findWaveNameClash in waves.js (tests/js/wave-case.test.js).
#>
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:cases = (Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' 'wave-name-clash.json') -Raw | ConvertFrom-Json).cases
    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/'
}

Describe 'Find-VmfWaveNameClash: the one rule' {

    It 'has cases to answer' {
        $script:cases.Count | Should -BeGreaterThan 8
    }

    It 'answers every case of the shared fixture' {
        foreach ($case in $script:cases) {
            $got = InModuleScope VmMigrationFactory -Parameters @{ c = $case } {
                Find-VmfWaveNameClash -Names @($c.layout) -StoredNames @($c.stored)
            }
            if ($null -eq $case.clash) {
                $got | Should -BeNullOrEmpty -Because $case.why
            }
            else {
                $got | Should -Not -BeNullOrEmpty -Because $case.why
                $got.Name | Should -BeExactly $case.clash.name -Because $case.why
                $got.Other | Should -BeExactly $case.clash.other -Because $case.why
                $got.Kind | Should -BeExactly $case.clash.kind -Because $case.why
            }
        }
    }

    It 'never meets a clash in the names the planner gives' {
        # The planner names every wave wave-<n>, so it cannot make two names
        # that differ only in letter case - even from tags that do.
        $names = InModuleScope VmMigrationFactory {
            $entries = @(
                [pscustomobject]@{ vmId = 'a'; appGroup = 'App'; resourceGroup = 'RG'; availabilitySetId = '' }
                [pscustomobject]@{ vmId = 'b'; appGroup = 'app'; resourceGroup = 'rg'; availabilitySetId = '' }
                [pscustomobject]@{ vmId = 'c'; appGroup = 'Other'; resourceGroup = 'rg2'; availabilitySetId = '' }
            )
            foreach ($s in 'tags', 'resourceGroup', 'singleWave') {
                , @((Get-VmfWaveAssignments -Entries $entries -Strategy $s).Values | Sort-Object -Unique)
            }
        }
        foreach ($set in $names) {
            foreach ($n in $set) { $n | Should -Match '^wave-\d+$' }
            InModuleScope VmMigrationFactory -Parameters @{ n = $set } { Find-VmfWaveNameClash -Names $n -StoredNames @() } |
                Should -BeNullOrEmpty
        }
    }
}

Describe 'Set-VmfWavePlan refuses wave names that differ only in letter case' {
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-wavecase-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $mk = { param($name, $wave)
            [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$($script:sub)$name"; wave = $wave; appGroup = $name
                assessment = [ordered]@{ classification = 'ReadyAfterPrep'; os = 'Linux'; sourceSize = 'Standard_D2ds_v4'; location = 'centralus'; availabilitySetId = '' }
                target = [ordered]@{ size = 'Standard_D2ds_v6'; controller = 'NVMe' }
                path = 'A'; policy = [ordered]@{ targetGeneration = 'v6'; requireApproval = $true } } }
        $plan = [ordered]@{ schemaVersion = 4; waveOrder = @('wave-1', 'wave-2')
            entries = @((& $mk 'a' 'wave-1'), (& $mk 'b' 'wave-1'), (& $mk 'c' 'wave-2')) }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; plan = $plan } {
            Initialize-VmfRun -RunPath $rp -RunId 'wavecase' | Out-Null
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document $plan
        }
        $script:planPath = Join-Path $script:rp 'plan.json'
        $script:before = Get-Content $script:planPath -Raw
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'refuses two waves whose names differ only in letter case, and changes nothing' {
        $waves = @(
            @{ name = 'Prod'; vmIds = @("$($script:sub)a", "$($script:sub)b") }
            @{ name = 'prod'; vmIds = @("$($script:sub)c") }
        )
        { Set-VmfWavePlan -RunPath $script:rp -PlanPath $script:planPath -Layout @{ waves = $waves } -Confirm:$false } |
            Should -Throw "Wave names 'Prod' and 'prod' are different only in letter case. The engine reads them as one wave. Give each wave a different name."
        Get-Content $script:planPath -Raw | Should -Be $script:before
    }

    It 'refuses two waves with one name, and changes nothing' {
        $waves = @(
            @{ name = 'wave-1'; vmIds = @("$($script:sub)a", "$($script:sub)b") }
            @{ name = 'wave-1'; vmIds = @("$($script:sub)c") }
        )
        { Set-VmfWavePlan -RunPath $script:rp -PlanPath $script:planPath -Layout @{ waves = $waves } -Confirm:$false } |
            Should -Throw "Two waves have the name 'wave-1'. Give each wave a different name."
        Get-Content $script:planPath -Raw | Should -Be $script:before
    }

    It 'refuses a rename that changes only the letter case, and changes nothing' {
        # Without the refusal, -ne kept the stored name on every machine and the
        # save still wrote a new wave order holding both names.
        $waves = @(
            @{ name = 'Wave-1'; vmIds = @("$($script:sub)a", "$($script:sub)b") }
            @{ name = 'wave-2'; vmIds = @("$($script:sub)c") }
        )
        { Set-VmfWavePlan -RunPath $script:rp -PlanPath $script:planPath -Layout @{ waves = $waves } -Confirm:$false } |
            Should -Throw "Wave name 'Wave-1' is different from the saved wave 'wave-1' only in letter case. The product cannot change only the letter case of a wave name. Use a different name."
        Get-Content $script:planPath -Raw | Should -Be $script:before
    }

    It 'still saves a rename to a different name' {
        $waves = @(
            @{ name = 'prod'; vmIds = @("$($script:sub)a", "$($script:sub)b") }
            @{ name = 'wave-2'; vmIds = @("$($script:sub)c") }
        )
        Set-VmfWavePlan -RunPath $script:rp -PlanPath $script:planPath -Layout @{ waves = $waves } -Confirm:$false | Out-Null
        $saved = Get-Content $script:planPath -Raw | ConvertFrom-Json
        @($saved.entries | Where-Object { $_.wave -ceq 'prod' }).Count | Should -Be 2
        @($saved.waveOrder) | Should -Be @('prod', 'wave-2')
    }

    It 'asks the rule before the save writes anything' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Set-VmfWavePlan.ps1')
        $ask = $code.IndexOf('Find-VmfWaveNameClash')
        $ask | Should -BeGreaterThan 0
        $ask | Should -BeLessThan $code.IndexOf('$PSCmdlet.ShouldProcess(') -Because 'the refusal must come before any write'
    }
}

Describe 'The wave editor asks the rule where a name is made' {
    # tests/js/wave-case.test.js runs the rule and its words. These hold that
    # the two places a wave name is made on the page ask it.
    BeforeAll {
        $script:page = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'waves.js')
        $at = $script:page.IndexOf("querySelectorAll('[data-rename]')")
        $script:rename = $script:page.Substring($at, $script:page.IndexOf('const rebuilt = new Map();', $at) - $at)
    }

    It 'a rename asks the rule against the other waves and the saved plan, and keeps the old name' {
        $script:rename | Should -Match ([regex]::Escape('waveNameClashFor(to, [...layout.keys()].filter(n => n !== from), entries.map(e => e.wave))'))
        $script:rename | Should -Match '(?s)if \(clash\) \{\s*i\.value = from;\s*render\(\);\s*\$\(''#warnbar''\)\.textContent = waveNameClashNote\(clash, to\);'
        $script:rename | Should -Not -Match 'layout\.has\(to\)' -Because 'a Map asks with letter case'
    }

    It 'a new wave never takes a name the rule refuses' {
        $script:page | Should -Match ([regex]::Escape('while (waveNameClashFor(n, [...layout.keys()], storedNames))'))
        $script:page | Should -Match ([regex]::Escape('const storedNames = entries.map(e => e.wave);'))
    }
}
