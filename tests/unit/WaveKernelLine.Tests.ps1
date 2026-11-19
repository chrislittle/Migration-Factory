#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# WAVE-KERNEL-LINE-1 (2026-11-14): no wave has a kernel setting.
#
# KERNEL-UX-1 put the kernel choice on each machine (the Choose each target
# step) and rejected a wave-level setting. The wave settings still showed one,
# "If the kernel is below the minimum version that Microsoft lists for MANA",
# that could only be Stop and ask, and the wave layout still carried
# onDriverBelowFloor - accepted by the engine only as 'stop'. A machine that
# chose Update the kernel then read as a machine that "does not follow" its
# wave. The wave layout no longer carries the setting at all: the page does not
# send it, the service passes it on as sent (never dropped in silence), and
# the engine refuses a layout that names it. Each machine's own policy.onDriverBelowFloor (stop or
# updateKernel, from the targets step) stays, and a wave save never writes it.
#
# tests/js/wave-kernel-line.test.js holds the three pages to one row.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines'
    function Script:WklEntry([string]$Name, [string]$Wave, [string]$Floor, [switch]$Decided) {
        $e = [pscustomobject]@{ vmId = "$script:sub/$Name"; wave = $Wave; path = 'A'
            policy = [pscustomobject]@{ onDDataFound = 'stop'; onDriverBelowFloor = $Floor; keepSnapshotDays = 7 } }
        if ($Decided) {
            $e | Add-Member -NotePropertyName decisions -NotePropertyValue @([pscustomobject]@{ setting = 'onDriverBelowFloor'; by = 'operator@example.com'; utc = '2026-11-14T09:00:00Z' })
        }
        $e
    }
    function Script:WklManual([string]$Page) {
        [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'docs' 'manual' $Page))
    }
}

Describe 'WAVE-KERNEL-LINE-1: no wave has a kernel setting' {
    It 'the settings of a wave do not include onDriverBelowFloor' {
        InModuleScope VmMigrationFactory {
            @(Get-VmfWaveSettingFields) | Should -Not -Contain 'onDriverBelowFloor'
        }
    }

    It 'a wave layout that names a kernel setting is refused, by name, for every value' -ForEach @(
        @{ Value = 'stop' }, @{ Value = 'updateKernel' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ v = $Value } {
            param($v)
            { ConvertTo-VmfWaveLayout -Layout @{ waves = @(@{ name = 'w1'; vmIds = @(); onDriverBelowFloor = $v }) } } |
                Should -Throw '*kernel*belongs to each machine*keeps the kernel choice of its plan*Choose each target step*Delete this migration*plan a new migration*'
        }
    }

    It 'a wave layout with no kernel setting is read, and holds none' {
        InModuleScope VmMigrationFactory {
            $w = @(ConvertTo-VmfWaveLayout -Layout @{ waves = @(@{ name = 'w1'; vmIds = @(); onDDataFound = 'stop'; keepSnapshotDays = 7 }) })
            $w.Count | Should -Be 1
            $w[0].Settings.Contains('onDriverBelowFloor') | Should -BeFalse
        }
    }

    It 'a wave save never writes a kernel choice: a machine joining a wave keeps its own, Update the kernel or Stop and ask' {
        InModuleScope VmMigrationFactory -Parameters @{ e = @((WklEntry 'lin-01' 'a' 'updateKernel' -Decided), (WklEntry 'lin-02' 'a' 'stop'), (WklEntry 'lin-03' 'b' 'stop')) } {
            param($e)
            $sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines'
            # lin-01 and lin-02 join wave b, whose card says Continue for files on the temporary disk.
            $waves = @(ConvertTo-VmfWaveLayout -Layout @{ waves = @(
                @{ name = 'b'; vmIds = @("$sub/lin-01", "$sub/lin-02", "$sub/lin-03"); onDDataFound = 'proceed'; keepSnapshotDays = 7 }) })
            $judged = Get-VmfWaveSettingWrites -Entries $e -Waves $waves
            @($judged.Writes | Where-Object { $_.Field -eq 'onDriverBelowFloor' }) | Should -BeNullOrEmpty
            @($judged.Kept | Where-Object { $_.Field -eq 'onDriverBelowFloor' }) | Should -BeNullOrEmpty
            # The save still writes what the card names: joining a wave takes its settings.
            @($judged.Writes | Where-Object { $_.Field -eq 'onDDataFound' -and $_.Joining }).Machine | Sort-Object | Should -Be @('lin-01', 'lin-02')
        }
    }

    It 'a reset of the kernel setting is refused: it is not a setting of a wave' {
        InModuleScope VmMigrationFactory {
            { ConvertTo-VmfWaveLayout -Layout @{ waves = @(@{ name = 'w1'; vmIds = @('/s/a'); onDDataFound = 'stop'; reset = @{ onDriverBelowFloor = @('/s/a') } }) } } |
                Should -Throw "*'onDriverBelowFloor' is not a setting of a wave*"
            { ConvertTo-VmfWaveLayout -Layout @{ waves = @(@{ name = 'w1'; vmIds = @('/s/a'); onDDataFound = 'stop'; changed = @{ onDriverBelowFloor = 'stop' } }) } } |
                Should -Throw "*'onDriverBelowFloor' is not a setting of a wave*"
        }
    }

    It 'the engine still reads each machine''s own choice: the state machine reads onDriverBelowFloor from the plan entry' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1')
        $code | Should -Match "Get-VmfPolicy -PlanEntry \`$plan -Name 'onDriverBelowFloor'"
    }

    It 'the service judges no kernel setting of a wave (DecisionGate.Tests.ps1 proves it passes one on, to be refused)' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1')
        $code | Should -Not -Match "'onDDataFound', 'onDriverBelowFloor'"
        $code | Should -Not -Match "\`$wr\.Field -(eq|in) [^\r\n]*onDriverBelowFloor"
    }

    It 'the activity has no words for a kernel setting of a wave' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Set-VmfWavePlan.ps1')
        $code | Should -Not -Match 'onDriverBelowFloor'
    }

    It 'the manual shows no kernel setting of a wave, and names the row of the machines' {
        $row = 'Machines whose kernel the product updates if it has no MANA driver'
        foreach ($page in 'use/wave-settings.md', 'use/plan.md') {
            (WklManual $page) | Should -Not -Match ([regex]::Escape('If the kernel is below the minimum version that Microsoft lists for MANA')) -Because $page
        }
        (WklManual 'use/wave-settings.md') | Should -Match ([regex]::Escape($row))
        (WklManual 'use/wave-settings.md') | Should -Match ([regex]::Escape('You change the choice on the **Choose each target** step. The new choice applies only to a new migration from the assessment. A migration that has a plan keeps the kernel choice of its plan. To use the new choice, select **Delete this migration** on the Migrations page. Then plan a new migration from the assessment.'))
    }
}
