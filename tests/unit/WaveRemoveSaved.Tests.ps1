#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
WAVE-REMOVE-NOT-SAVED-1: a saved wave layout is the complete set of waves.

The wave editor's Remove and Delete put machines on its left side, and its save
sends only the waves on the right. Set-VmfWavePlan wrote a wave only for each
machine a layout named, so a machine the person removed kept its old wave in
the saved plan - and that wave would still move it. Now every plan machine on a
moving path that no wave of the layout names goes to no wave ('unscheduled'),
through every guard a move between waves already passes.
#>
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines'
    # wave-1: vm1, vm2; wave-2: vm3; manual in no wave (MANUAL); old in no wave (A);
    # manual2 a MANUAL entry that a wave holds.
    # avA and avB are one availability set in wave-3.
    function Global:WrRun([hashtable]$States = @{}) {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-wr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; sub = $script:sub; states = $States } {
            Initialize-VmfRun -RunPath $rp -RunId 'wr-test' | Out-Null
            $e = { param($n, $w, $p = 'A', $av = '') [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$sub/$n"; wave = $w; path = $p
                    assessment = [ordered]@{ location = 'centralus'; availabilitySetId = $av }; target = [ordered]@{ size = 'Standard_D2ds_v6' }
                    policy = [ordered]@{ capacityGate = 'BestEffort'; requireApproval = $true; onDDataFound = 'stop' } } }
            $set = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/availabilitySets/as-1'
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24 -Document ([ordered]@{
                schemaVersion = 8; assessmentRunId = 'wr-test'; waveOrder = @('wave-1', 'wave-2', 'wave-3')
                entries = @((& $e 'vm1' 'wave-1'), (& $e 'vm2' 'wave-1'), (& $e 'vm3' 'wave-2'),
                            (& $e 'manual' 'unscheduled' 'MANUAL'), (& $e 'old' 'unscheduled'), (& $e 'manual2' 'wave-2' 'MANUAL'),
                            (& $e 'avA' 'wave-3' 'A' $set), (& $e 'avB' 'wave-3' 'A' $set)) })
            foreach ($k in @($states.Keys)) {
                $doc = New-VmfStateDoc -RunPath $rp -RunId 'wr-test' -VmId "$sub/$k" -Wave 'wave-1'
                $doc.state = $states[$k]
                Write-VmfStateDoc -RunPath $rp -Document $doc | Out-Null
            }
            Write-VmfStoreJson -RunPath $rp -RelPath 'acceptances/wave-options-wave-1.json' -Document ([ordered]@{ wave = 'wave-1'; acceptedBy = 'operator@example.com' })
            Write-VmfStoreJson -RunPath $rp -RelPath 'acceptances/wave-options-wave-2.json' -Document ([ordered]@{ wave = 'wave-2'; acceptedBy = 'operator@example.com' })
        }
        $rp
    }
    function Global:WrSave($rp, [hashtable[]]$Waves) {
        Set-VmfWavePlan -RunPath $rp -PlanPath (Join-Path $rp 'plan.json') -ChangedBy 'operator@example.com' -Confirm:$false -Layout @{ waves = $Waves }
    }
    function Global:WrW([string]$Name, [string[]]$Vms) {
        @{ name = $Name; vmIds = @($Vms | ForEach-Object { "$script:sub/$_" }); capacityGate = 'BestEffort'; requireApproval = $true; onDDataFound = 'stop' }
    }
    function Global:WrWaves($rp) {
        $out = @{}
        foreach ($e in @((Get-Content (Join-Path $rp 'plan.json') -Raw | ConvertFrom-Json).entries)) { $out[([string]$e.vmId -split '/')[-1]] = [string]$e.wave }
        $out
    }
}
AfterAll { Remove-Item 'function:\WrRun', 'function:\WrSave', 'function:\WrW', 'function:\WrWaves' -ErrorAction SilentlyContinue }

Describe 'WAVE-REMOVE-NOT-SAVED-1: a saved layout is the complete set of waves' {
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

    It 'a machine removed from its wave goes to no wave, and the settings acceptance of that wave is cleared' {
        $script:rp = WrRun
        $r = WrSave $script:rp @((WrW 'wave-1' 'vm1'), (WrW 'wave-2' 'vm3'), (WrW 'wave-3' 'avA', 'avB'))
        $w = WrWaves $script:rp
        $w['vm2'] | Should -BeExactly 'unscheduled'
        $w['vm1'] | Should -BeExactly 'wave-1'
        $r.MovedCount | Should -Be 1
        $r.AcceptancesCleared | Should -Contain 'wave-1'
        $r.AcceptancesCleared | Should -Not -Contain 'wave-2' -Because 'a wave that lost nothing keeps its acceptance'
        Test-Path (Join-Path $script:rp 'acceptances/wave-options-wave-1.json') | Should -BeFalse
        Test-Path (Join-Path $script:rp 'acceptances/wave-options-wave-2.json') | Should -BeTrue
    }

    It 'the activity says the machine moved to the machines not in a wave' {
        $script:rp = WrRun
        WrSave $script:rp @((WrW 'wave-1' 'vm1'), (WrW 'wave-2' 'vm3'), (WrW 'wave-3' 'avA', 'avB')) | Out-Null
        $log = Get-ChildItem (Join-Path $script:rp 'logs') -File -Recurse | Get-Content -Raw
        $log | Should -Match 'In wave wave-1, machine vm2 moved to the machines not in a wave\.'
    }

    It 'deleting a wave puts every machine of it in no wave, and the wave leaves the order' {
        $script:rp = WrRun
        WrSave $script:rp @((WrW 'wave-2' 'vm3'), (WrW 'wave-3' 'avA', 'avB')) | Out-Null
        $w = WrWaves $script:rp
        $w['vm1'] | Should -BeExactly 'unscheduled'
        $w['vm2'] | Should -BeExactly 'unscheduled'
        @((Get-Content (Join-Path $script:rp 'plan.json') -Raw | ConvertFrom-Json).waveOrder) | Should -Not -Contain 'wave-1'
    }

    It 'a MANUAL machine is never touched, and a machine already in no wave stays as it is' {
        $script:rp = WrRun
        WrSave $script:rp @((WrW 'wave-1' 'vm1'), (WrW 'wave-2' 'vm3'), (WrW 'wave-3' 'avA', 'avB')) | Out-Null
        $w = WrWaves $script:rp
        $w['manual'] | Should -BeExactly 'unscheduled'
        $w['manual2'] | Should -BeExactly 'wave-2' -Because 'a MANUAL entry is never touched, even when no wave names it'
        $w['old'] | Should -BeExactly 'unscheduled'
    }

    It 'a layout that names every machine where it is changes nothing' {
        $script:rp = WrRun
        $before = Get-Content (Join-Path $script:rp 'plan.json') -Raw
        $r = WrSave $script:rp @((WrW 'wave-1' 'vm1', 'vm2'), (WrW 'wave-2' 'vm3'), (WrW 'wave-3' 'avA', 'avB'))
        $r.Unchanged | Should -BeTrue
        Get-Content (Join-Path $script:rp 'plan.json') -Raw | Should -BeExactly $before
    }

    It 'a machine that started cannot be dropped to no wave - the same refusal as a move - and nothing is written' {
        $script:rp = WrRun @{ vm2 = 'MIGRATED' }
        $before = Get-Content (Join-Path $script:rp 'plan.json') -Raw
        { WrSave $script:rp @((WrW 'wave-1' 'vm1'), (WrW 'wave-2' 'vm3'), (WrW 'wave-3' 'avA', 'avB')) } |
            Should -Throw "'vm2' has already started migrating - it cannot be moved to another wave."
        Get-Content (Join-Path $script:rp 'plan.json') -Raw | Should -BeExactly $before
    }

    It 'a machine removed from a running wave is refused, and nothing is written' {
        $script:rp = WrRun @{ vm1 = 'PLANNED' }
        $before = Get-Content (Join-Path $script:rp 'plan.json') -Raw
        { WrSave $script:rp @((WrW 'wave-1' 'vm1'), (WrW 'wave-2' 'vm3'), (WrW 'wave-3' 'avA', 'avB')) } |
            Should -Throw '400: Wave wave-1 is running (vm1 is PLANNED)*'
        Get-Content (Join-Path $script:rp 'plan.json') -Raw | Should -BeExactly $before
    }

    It 'half of an availability set taken out of its wave is refused' {
        $script:rp = WrRun
        $before = Get-Content (Join-Path $script:rp 'plan.json') -Raw
        { WrSave $script:rp @((WrW 'wave-1' 'vm1', 'vm2'), (WrW 'wave-2' 'vm3'), (WrW 'wave-3' 'avA')) } |
            Should -Throw "Machines in the availability set 'as-1' must stay in one wave*"
        Get-Content (Join-Path $script:rp 'plan.json') -Raw | Should -BeExactly $before
    }

    It 'a whole availability set taken out of its wave goes to no wave' {
        $script:rp = WrRun
        WrSave $script:rp @((WrW 'wave-1' 'vm1', 'vm2'), (WrW 'wave-2' 'vm3')) | Out-Null
        $w = WrWaves $script:rp
        $w['avA'] | Should -BeExactly 'unscheduled'
        $w['avB'] | Should -BeExactly 'unscheduled'
    }
}

Describe 'WAVE-REMOVE-NOT-SAVED-1: Delete on the last wave is saved too' {
    BeforeAll {
        function Global:WrOperator {
            $claims = @(@{ typ = 'preferred_username'; val = 'operator@example.com' }, @{ typ = 'roles'; val = 'Vmf.Operator' })
            $doc = @{ auth_typ = 'aad'; claims = $claims } | ConvertTo-Json -Depth 5
            ConvertFrom-VmfClientPrincipal -Header ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($doc)))
        }
    }
    AfterAll { Remove-Item 'function:\WrOperator' -ErrorAction SilentlyContinue }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

    It 'an empty list of waves puts every moving machine in no wave, and a MANUAL machine stays where it is' {
        $script:rp = WrRun
        $r = WrSave $script:rp @()
        $w = WrWaves $script:rp
        foreach ($n in 'vm1', 'vm2', 'vm3', 'avA', 'avB', 'old') { $w[$n] | Should -BeExactly 'unscheduled' -Because $n }
        $w['manual2'] | Should -BeExactly 'wave-2' -Because 'a MANUAL entry is never touched'
        $r.MovedCount | Should -Be 5
        @((Get-Content (Join-Path $script:rp 'plan.json') -Raw | ConvertFrom-Json).waveOrder | Where-Object { $_ -in 'wave-1', 'wave-3' }) | Should -BeNullOrEmpty
    }

    It 'an empty list is refused when a machine has started, and nothing is written' {
        $script:rp = WrRun @{ vm3 = 'MIGRATED' }
        $before = Get-Content (Join-Path $script:rp 'plan.json') -Raw
        { WrSave $script:rp @() } | Should -Throw "'vm3' has already started migrating - it cannot be moved to another wave."
        Get-Content (Join-Path $script:rp 'plan.json') -Raw | Should -BeExactly $before
    }

    It 'a layout with no list of waves at all is still refused' {
        $script:rp = WrRun
        { Set-VmfWavePlan -RunPath $script:rp -PlanPath (Join-Path $script:rp 'plan.json') -Confirm:$false -Layout @{} } | Should -Throw 'Layout.waves is required.'
        { Set-VmfWavePlan -RunPath $script:rp -PlanPath (Join-Path $script:rp 'plan.json') -Confirm:$false -Layout @{ waves = $null } } | Should -Throw 'Layout.waves is required.'
    }

    It 'the service takes an empty list of waves from the page' {
        $script:rp = WrRun
        Invoke-VmfFacadeSetWaves -Principal (WrOperator) -StorePath $script:rp -Waves @() -Note 'every wave deleted' | Out-Null
        (WrWaves $script:rp)['vm1'] | Should -BeExactly 'unscheduled'
    }

    It 'the service takes an empty list as the page body sends it, and refuses a body with no list' {
        $script:rp = WrRun
        $body = '{"waves":[],"note":"x"}' | ConvertFrom-Json -AsHashtable
        Invoke-VmfFacadeSetWaves -Principal (WrOperator) -StorePath $script:rp -Waves $body.waves -Note 'x' | Out-Null
        (WrWaves $script:rp)['vm2'] | Should -BeExactly 'unscheduled'
        $none = '{"note":"x"}' | ConvertFrom-Json -AsHashtable
        { Invoke-VmfFacadeSetWaves -Principal (WrOperator) -StorePath $script:rp -Waves $none.waves -Note 'x' } | Should -Throw '400: a wave layout is required'
    }
}