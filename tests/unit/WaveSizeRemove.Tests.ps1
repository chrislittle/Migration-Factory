#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# WAVE-SIZE-REMOVE-1: one wave per group, of any size.
#
# Decided 2026-11-08, on the wizard's step "How to group them": "Most machines
# in one wave" is not needed. The wave settings already hold the concurrency
# tiers, and a wave of 40 machines is a fair choice.
#
# THE RULE NOW. Grouping by tag or by resource group makes exactly one wave for
# each group, whatever its size. How many machines move at the same time is the
# wave's own setting (How many machines at once: Pilot 5, Standard 15, Large 30,
# Maximum 60), so a cap on the wave only split a group that belongs together.
# Nothing carries a wave size any more: not the wizard, not the request body,
# not the service, not the engine's settings, not New-VmfPlan. A page loaded
# before the update that still sends waveSize is refused by name, never dropped.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:mkv = {
        param($name, $app, $rg, $avset = '')
        [pscustomobject]@{ vmId = "/vm/$name"; ring = 'x'; appGroup = $app
                           resourceGroup = $rg; availabilitySetId = $avset }
    }
}

Describe 'WAVE-SIZE-REMOVE-1: a group is one wave, whatever its size' {
    It 'a resource group of <n> machines is ONE wave' -ForEach @(@{ n = 26 }, @{ n = 40 }, @{ n = 200 }) {
        InModuleScope VmMigrationFactory -Parameters @{ mk = $script:mkv; n = $n } {
            param($mk, $n)
            $entries = 1..$n | ForEach-Object { & $mk "vm$_" "app$_" 'rg-big' }
            $w = Get-VmfWaveAssignments -Entries $entries -Strategy 'resourceGroup'
            $w.Count | Should -Be $n -Because 'every machine is placed'
            @($w.Values | Sort-Object -Unique) | Should -Be @('wave-1') -Because 'a resource group moves together, at any size'
        }
    }

    It 'a tag value on 40 machines is ONE wave' {
        InModuleScope VmMigrationFactory -Parameters @{ mk = $script:mkv } {
            param($mk)
            $entries = 1..40 | ForEach-Object { & $mk "vm$_" 'billing' "rg$_" }
            $w = Get-VmfWaveAssignments -Entries $entries -Strategy 'tags'
            @($w.Values | Sort-Object -Unique) | Should -Be @('wave-1') -Because 'machines that share a tag value move together, at any size'
        }
    }

    It 'two large groups are still two waves, one group in each' {
        InModuleScope VmMigrationFactory -Parameters @{ mk = $script:mkv } {
            param($mk)
            $entries = @(
                1..30 | ForEach-Object { & $mk "a$_" "app$_" 'rg-alpha' }
                1..45 | ForEach-Object { & $mk "b$_" "app$_" 'rg-bravo' })
            $w = Get-VmfWaveAssignments -Entries $entries -Strategy 'resourceGroup'
            @($w.Values | Sort-Object -Unique).Count | Should -Be 2
            @(1..30 | ForEach-Object { $w["/vm/a$_"] } | Sort-Object -Unique) | Should -Be @('wave-1')
            @(1..45 | ForEach-Object { $w["/vm/b$_"] } | Sort-Object -Unique) | Should -Be @('wave-2')
        }
    }

    It 'neither the planner nor New-VmfPlan takes a wave size' {
        $planner = InModuleScope VmMigrationFactory { Get-Command Get-VmfWaveAssignments }
        $planner.Parameters.Keys | Should -Contain 'Strategy' -Because 'otherwise this reads nothing'
        $planner.Parameters.Keys | Should -Not -Contain 'WaveSize'
        $plan = Get-Command New-VmfPlan
        $plan.Parameters.Keys | Should -Contain 'WaveStrategy' -Because 'otherwise this reads nothing'
        $plan.Parameters.Keys | Should -Not -Contain 'WaveSize'
    }

    It 'the engine entry point reads no wave size' {
        $entry = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'docker' 'entrypoint.ps1')
        $entry | Should -Match 'VMF_WAVE_STRATEGY' -Because 'otherwise this reads nothing'
        $entry | Should -Not -Match 'VMF_WAVE_SIZE|WaveSize'
        # The help at the top of the file is a comment, which the line above
        # does not read: it must not list the setting either.
        (Get-Content (Join-Path $script:repoRoot 'docker' 'entrypoint.ps1') -Raw) | Should -Not -Match 'VMF_WAVE_SIZE'
    }
}

Describe 'WAVE-SIZE-REMOVE-1: the service takes no wave size' {
    It 'the start of the engine has no WaveSize parameter and sets no VMF_WAVE_SIZE' {
        $cmd = Get-Command Invoke-VmfFacadeStartEngine
        $cmd.Parameters.Keys | Should -Contain 'WaveStrategy' -Because 'otherwise this reads nothing'
        $cmd.Parameters.Keys | Should -Not -Contain 'WaveSize'
        $core = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1')
        $core | Should -Match 'VMF_WAVE_STRATEGY' -Because 'otherwise this reads nothing'
        $core | Should -Not -Match 'VMF_WAVE_SIZE'
    }

    It 'the start route reads no wave size from the body' {
        $route = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'app' 'PostStartEngine' 'run.ps1')
        $route | Should -Match '\$body\.waveStrategy' -Because 'otherwise this reads nothing'
        $route | Should -Not -Match '\$body\.waveSize|\$params\.WaveSize'
    }

    It 'OLD-VERSION-READERS-REMOVE-3: the service names no field that only an earlier page sent' {
        $core = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1')
        $core | Should -Not -Match 'Assert-VmfFacadeNoRemovedField'
        $route = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'app' 'PostStartEngine' 'run.ps1')
        $route | Should -Not -Match 'Assert-VmfFacadeNoRemovedField|waveSize'
        foreach ($file in Get-ChildItem (Join-Path $script:repoRoot 'src' 'facade') -Recurse -Include '*.ps1', '*.psm1') {
            (Get-VmfCodeOnly -Path $file.FullName) | Should -Not -Match 'Assert-VmfFacadeNoRemovedField' -Because $file.Name
        }
    }
}
Describe 'WAVE-SIZE-REMOVE-1: the wizard asks for no wave size' {
    It 'wizard.js has no wave size field, string or body field' {
        $wiz = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.js')
        $wiz | Should -Match 'waveStrategy' -Because 'otherwise this reads nothing'
        $wiz | Should -Not -Match 'waveSize|f-size|g-size|Most machines in one wave'
    }
}
