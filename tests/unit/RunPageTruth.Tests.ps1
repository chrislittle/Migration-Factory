#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# EVAL-H7, H8, H9, H14, M11, M12 - the run page and wave editor telling the
# truth about what they just did.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:idx = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'migrations.html'))
    $script:wav = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'waves.html'))

    function Script:NewPlanRun {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-wp-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $vm1 = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
        $vm2 = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm2'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; a = $vm1; b = $vm2 } {
            Initialize-VmfRun -RunPath $rp -RunId 'wp-test' | Out-Null
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24 -Document ([ordered]@{
                schemaVersion = 8; assessmentRunId = 'wp-test'; waveOrder = @('wave-1', 'wave-2')
                entries = @(
                    [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $a; wave = 'wave-1'; path = 'A'
                        assessment = [ordered]@{ location = 'centralus' }
                        target = [ordered]@{ size = 'Standard_D2ds_v6' }
                        policy = [ordered]@{ capacityGate = 'BestEffort'; requireApproval = $true; onDDataFound = 'stop' } }
                    [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $b; wave = 'wave-2'; path = 'A'
                        assessment = [ordered]@{ location = 'centralus' }
                        target = [ordered]@{ size = 'Standard_D2ds_v6' }
                        policy = [ordered]@{ capacityGate = 'BestEffort'; requireApproval = $true; onDDataFound = 'stop' } })
            })
            # both waves are approved, accepted, and have a quota check.
            # WAVE-SAVE-FALSE-1: each approval signs the plan as stored, as
            # Approve-VmfWave does - a made-up hash is an approval the gate
            # already refuses, and the save now removes it as such.
            $signed = Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $rp -RelPath 'plan.json'))
            foreach ($w in 'wave-1', 'wave-2') {
                Write-VmfStoreJson -RunPath $rp -RelPath "approvals/$w.json" -Depth 8 -Document ([ordered]@{
                    schemaVersion = 1; wave = $w; approvedBy = @{ identity = 'sam@contoso.com' }; planHash = $signed })
                Write-VmfStoreJson -RunPath $rp -RelPath "acceptances/wave-options-$w.json" -Depth 8 -Document ([ordered]@{
                    schemaVersion = 1; wave = $w; acceptedBy = 'sam@contoso.com'; optionsHash = ('b' * 64) })
                Write-VmfStoreJson -RunPath $rp -RelPath "capacity/$w-d2ds.json" -Depth 12 -Document ([ordered]@{
                    schemaVersion = 2; wave = $w; region = 'centralus'; size = 'Standard_D2ds_v6'; count = 1 })
            }
        }
        @{ Run = $rp; Plan = (Join-Path $rp 'plan.json'); Vm1 = $vm1; Vm2 = $vm2 }
    }
}

Describe 'EVAL-H7: editing one wave does not invalidate the others' {
    BeforeEach { $script:fx = Script:NewPlanRun }
    AfterEach { if (Test-Path $script:fx.Run) { Remove-Item $script:fx.Run -Recurse -Force } }

    It 'sending every lever unchanged for every wave changes nothing' {
        # This is exactly what the page does on every save: it posts all five
        # levers for all waves, changed or not.
        $r = Set-VmfWavePlan -RunPath $script:fx.Run -PlanPath $script:fx.Plan -ChangedBy 'operator' -Confirm:$false -Layout @{
            waves = @(
                @{ name = 'wave-1'; vmIds = @($script:fx.Vm1); capacityGate = 'BestEffort'; requireApproval = $true; onDDataFound = 'stop' }
                @{ name = 'wave-2'; vmIds = @($script:fx.Vm2); capacityGate = 'BestEffort'; requireApproval = $true; onDDataFound = 'stop' })
        }
        @($r.ApprovalsInvalidated).Count | Should -Be 0 -Because 'nothing actually changed'
        @($r.CapacityChecksCleared).Count | Should -Be 0 -Because 'deleting a quota check can orphan a paid reservation'
        @($r.AcceptancesCleared).Count | Should -Be 0
    }

    It 'changing one lever on one wave touches only that wave' {
        $r = Set-VmfWavePlan -RunPath $script:fx.Run -PlanPath $script:fx.Plan -ChangedBy 'operator' -Confirm:$false -Layout @{
            waves = @(
                @{ name = 'wave-1'; vmIds = @($script:fx.Vm1); capacityGate = 'Reserved'; requireApproval = $true; onDDataFound = 'stop' }
                @{ name = 'wave-2'; vmIds = @($script:fx.Vm2); capacityGate = 'BestEffort'; requireApproval = $true; onDDataFound = 'stop' })
        }
        @($r.CapacityChecksCleared) | Should -Be @('wave-1')
        @($r.AcceptancesCleared) | Should -Be @('wave-1')
        # WAVE-SAVE-FALSE-1 rewrote this: it pinned wave-2's APPROVAL as kept.
        # An approval signs the whole plan text (Test-VmfWaveApproval), so the
        # kept file could no longer pass the gate, and the page showed it as
        # approved with no way to approve again. It is removed and named; the
        # quota check and the acceptance bind only their own wave, and stay.
        @($r.ApprovalsInvalidated) | Should -Be @('wave-1', 'wave-2')
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run } {
            Test-VmfStoreItem -RunPath $rp -RelPath 'approvals/wave-2.json' | Should -BeFalse
            Test-VmfStoreItem -RunPath $rp -RelPath 'acceptances/wave-options-wave-2.json' | Should -BeTrue -Because 'wave-2 was not edited'
            Test-VmfStoreItem -RunPath $rp -RelPath 'capacity/wave-2-d2ds.json' | Should -BeTrue
        }
    }
}

Describe 'EVAL-H8: an edited wave cannot keep a green accepted chip' {
    BeforeEach { $script:fx = Script:NewPlanRun }
    AfterEach { if (Test-Path $script:fx.Run) { Remove-Item $script:fx.Run -Recurse -Force } }

    It 'clears the acceptance the way it already cleared the approval' {
        # The engine binds acceptance to a hash over vmIds and policy, so any
        # edit voids it - but both pages tested PRESENCE, so the chip stayed
        # green for a wave the engine would refuse, and because the accept
        # button renders only when the acceptance is absent, nothing on any
        # screen could re-accept it.
        $r = Set-VmfWavePlan -RunPath $script:fx.Run -PlanPath $script:fx.Plan -ChangedBy 'operator' -Confirm:$false -Layout @{
            waves = @(@{ name = 'wave-1'; vmIds = @($script:fx.Vm1); onDDataFound = 'proceed' })
        }
        @($r.AcceptancesCleared) | Should -Contain 'wave-1'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run } {
            @(Get-VmfStoreNames -RunPath $rp -Folder 'acceptances' -Extension '.json' |
                Where-Object { $_ -match 'wave-1' }).Count | Should -Be 0
        }
    }

    It 'the save tells the person what it invalidated' {
        $script:wav | Should -Match 'savedAcceptCleared'
        $script:wav | Should -Match 'savedCapacityCleared'
        $script:wav | Should -Match 'AcceptancesCleared'
        $script:wav | Should -Match 'CapacityChecksCleared'
    }
}

Describe 'EVAL-H9: the run page gates Start on what the engine gates on' {
    It 'the button requires acceptance, not just approval' {
        $script:idx | Should -Match 'startBlockedBy'
        $script:idx | Should -Match 'startNeedsAccept'
    }

    It 'and says why it is not there, rather than just hiding' {
        $script:idx | Should -Match 'Review and accept the settings before this wave can start'
    }
}

Describe 'EVAL-H14: every page that starts an engine job watches for a refusal' {
    It 'derives the requirement from the pages themselves' {
        # The old test hard-coded the wizard. The engine refuses AFTER the POST
        # returns 202, so any page that starts a job needs this.
        $offenders = foreach ($page in (Get-ChildItem (Join-Path $script:repoRoot 'src' 'dashboard') -Filter '*.html')) {
            $t = (Get-VmfPageSource -Path $page.FullName)
            if ($t -notmatch "engine/") { continue }
            if ($t -notmatch 'watchForRefusal|watchReservation') { "$($page.Name) starts an engine job and never checks whether it was refused" }
        }
        $offenders -join '; ' | Should -BeNullOrEmpty
    }
}

# REBUILD-REMOVE-RECOVER-1: removed with Rebuild this machine and the restore that rebuilds.

Describe 'EVAL-M11/M12: the page does not contradict itself' {
    It 'a scheduled wave is not told it is starting now' {
        $script:idx | Should -Match 'const handlerMessage = await onConfirm'
        $script:idx | Should -Match 'return UX_ACT\.doneScheduled'
    }

    It 'a keystroke cannot un-pause a halted run' {
        $script:idx | Should -Match 'let latestHalted'
        $script:idx | Should -Not -Match 'renderWaves\(false\)'
    }
}
