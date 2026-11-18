#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# WAVE-1 phase 2: hand-composed wave layouts. The planner's grouping is a
# starting point; the migration lead composes the real runbook. These tests
# pin the safety properties that must survive hand editing.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    # TEST-1: anything this file forgets to mock must fail as a TEST error,
    # not quietly reach real Azure. Placed before the file's own mocks so
    # those still win where they exist.
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Script:NewRun {
        param([hashtable[]]$Vms)
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-wp-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { Initialize-VmfRun -RunPath $rp -RunId 'wp-test' | Out-Null }
        $entries = foreach ($v in $Vms) {
            [ordered]@{
                schemaVersion = (Get-VmfTestPlanEntryVersion)
                vmId = "/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/$($v.name)"
                wave = $v.wave; appGroup = $v.name
                assessment = [ordered]@{ availabilitySetId = [string]$v.avset; location = 'centralus' }
                target = [ordered]@{ size = 'Standard_D2s_v6' }
                path = 'A'
                policy = [ordered]@{ capacityGate = 'BestEffort'; requireApproval = $false }
            }
        }
        $doc = [ordered]@{ schemaVersion = 1; entries = @($entries)
                           waveSummary = @($entries | Group-Object { $_['wave'] } | ForEach-Object { @{ wave = $_.Name; count = $_.Count } }) }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; doc = $doc } {
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document $doc -Depth 24
        }
        $rp
    }
    function Script:PlanOf {
        param([string]$RunPath)
        InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath } {
            Read-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24
        }
    }
    function Script:VmId { param($Name) "/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/$Name" }
}

Describe 'Set-VmfWavePlan - composing the runbook by hand' {
    BeforeEach {
        $script:run = Script:NewRun -Vms @(
            @{ name = 'web1'; wave = 'lab-1' }, @{ name = 'web2'; wave = 'lab-1' },
            @{ name = 'db1';  wave = 'lab-2' }, @{ name = 'db2';  wave = 'lab-2' })
        $script:planPath = Join-Path $script:run 'plan.json'
    }
    AfterEach { if (Test-Path $script:run) { Remove-Item $script:run -Recurse -Force } }

    It 'creates a new wave, names it, and moves machines into it' {
        $r = Set-VmfWavePlan -RunPath $script:run -PlanPath $script:planPath -ChangedBy 'lead@example.com' -Layout @{
            # WAVE-REMOVE-NOT-SAVED-1: a layout is the complete set of waves, so
            # the waves that keep their other machines are named too.
            waves = @(@{ name = 'go-live-friday'; vmIds = @((Script:VmId 'web1'), (Script:VmId 'db1')) },
                      @{ name = 'lab-1'; vmIds = @((Script:VmId 'web2')) }, @{ name = 'lab-2'; vmIds = @((Script:VmId 'db2')) })
        }
        $r.MovedCount | Should -Be 2
        $plan = Script:PlanOf $script:run
        ($plan.entries | Where-Object { $_.vmId -eq (Script:VmId 'web1') }).wave | Should -Be 'go-live-friday'
        ($plan.entries | Where-Object { $_.vmId -eq (Script:VmId 'db1') }).wave | Should -Be 'go-live-friday'
        # machines named in their own wave keep it
        ($plan.entries | Where-Object { $_.vmId -eq (Script:VmId 'web2') }).wave | Should -Be 'lab-1'
    }

    It 'renames a wave by naming the same machines, and empties one by moving them all out' {
        Set-VmfWavePlan -RunPath $script:run -PlanPath $script:planPath -Layout @{
            waves = @(@{ name = 'first-batch'; vmIds = @((Script:VmId 'web1'), (Script:VmId 'web2')) })
        } | Out-Null
        $plan = Script:PlanOf $script:run
        @($plan.entries | Where-Object { $_.wave -eq 'lab-1' }).Count | Should -Be 0 -Because 'the old wave is gone once empty'
        @($plan.entries | Where-Object { $_.wave -eq 'first-batch' }).Count | Should -Be 2
        @($plan.waveSummary | ForEach-Object { $_.wave }) | Should -Contain 'first-batch'
        @($plan.waveSummary | ForEach-Object { $_.wave }) | Should -Not -Contain 'lab-1'
    }

    It 'gives each wave its own capacity choice and sign-off rule - and any NAME the customer types' {
        # WAVE-2: no ring field exists. The wave name is the customer's word,
        # and the levers ride on the wave itself.
        Set-VmfWavePlan -RunPath $script:run -PlanPath $script:planPath -Layout @{
            waves = @(
                @{ name = 'pilot'; capacityGate = 'BestEffort'; requireApproval = $false
                   vmIds = @((Script:VmId 'web1')) }
                @{ name = 'the-big-one'; capacityGate = 'Reserved'; requireApproval = $true
                   vmIds = @((Script:VmId 'db1'), (Script:VmId 'db2')) })
        } | Out-Null
        $plan = Script:PlanOf $script:run
        $pilot = $plan.entries | Where-Object { $_.wave -eq 'pilot' }
        $pilot.policy.capacityGate | Should -Be 'BestEffort'
        $big = @($plan.entries | Where-Object { $_.wave -eq 'the-big-one' })
        $big.Count | Should -Be 2
        @($big | ForEach-Object { $_.policy.capacityGate } | Sort-Object -Unique) | Should -Be @('Reserved')
        @($big | ForEach-Object { [bool]$_.policy.requireApproval } | Sort-Object -Unique) | Should -Be @($true)
    }

    It 'refuses to put one machine in two waves' {
        { Set-VmfWavePlan -RunPath $script:run -PlanPath $script:planPath -Layout @{
            waves = @(
                @{ name = 'a'; vmIds = @((Script:VmId 'web1')) }
                @{ name = 'b'; vmIds = @((Script:VmId 'web1')) })
        } } | Should -Throw '*more than one wave*'
    }

    It 'refuses a machine that is not in the plan, and a nonsense wave name' {
        { Set-VmfWavePlan -RunPath $script:run -PlanPath $script:planPath -Layout @{
            waves = @(@{ name = 'a'; vmIds = @((Script:VmId 'ghost')) }) } } | Should -Throw '*not part of this plan*'
        { Set-VmfWavePlan -RunPath $script:run -PlanPath $script:planPath -Layout @{
            waves = @(@{ name = 'bad name/slash'; vmIds = @() }) } } | Should -Throw '*not usable*'
    }

    It 'never lets an availability set be split across waves' {
        $run2 = Script:NewRun -Vms @(
            @{ name = 'pair1'; wave = 'lab-1'; avset = '/avsets/set1' },
            @{ name = 'pair2'; wave = 'lab-1'; avset = '/avsets/set1' })
        try {
            { Set-VmfWavePlan -RunPath $run2 -PlanPath (Join-Path $run2 'plan.json') -Layout @{
                waves = @(
                    @{ name = 'w1'; vmIds = @((Script:VmId 'pair1')) }
                    @{ name = 'w2'; vmIds = @((Script:VmId 'pair2')) })
            } } | Should -Throw '*must stay in one wave*'
        }
        finally { Remove-Item $run2 -Recurse -Force }
    }

    It 'refuses to re-wave a machine that has already started migrating' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; id = (Script:VmId 'web1') } {
            New-VmfStateDoc -RunPath $rp -RunId 'wp-test' -VmId $id -Wave 'lab-1' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'CONVERTING' -Outcome ok | Out-Null
        }
        { Set-VmfWavePlan -RunPath $script:run -PlanPath $script:planPath -Layout @{
            waves = @(@{ name = 'somewhere-else'; vmIds = @((Script:VmId 'web1')) }) } } |
            Should -Throw '*already started migrating*'
    }

    It 'clears the approval of any wave it changes - sign-off binds to the plan it approved' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run } {
            Write-VmfStoreJson -RunPath $rp -RelPath 'approvals/lab-1.json' -Document @{
                schemaVersion = 1; wave = 'lab-1'; approvedBy = @{ identity = 'boss@example.com' } }
        }
        $r = Set-VmfWavePlan -RunPath $script:run -PlanPath $script:planPath -ChangedBy 'lead@example.com' -Layout @{
            waves = @(@{ name = 'lab-1'; vmIds = @((Script:VmId 'web1'), (Script:VmId 'web2'), (Script:VmId 'db1')) })
        }
        $r.ApprovalsInvalidated | Should -Contain 'lab-1'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run } {
            Test-VmfStoreItem -RunPath $rp -RelPath 'approvals/lab-1.json' | Should -BeFalse
        }
    }

    It 'records who changed the layout in the run history' {
        Set-VmfWavePlan -RunPath $script:run -PlanPath $script:planPath -ChangedBy 'lead@example.com' -Note 'app owners asked' -Layout @{
            waves = @(@{ name = 'lab-1'; vmIds = @((Script:VmId 'db1')) }) } | Out-Null
        $events = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run } { Read-VmfEvents -RunPath $rp }
        ($events | Where-Object { $_.detail -match 'wave layout changed by lead@example.com' }) | Should -Not -BeNullOrEmpty
        ($events | Where-Object { $_.detail -match 'app owners asked' }) | Should -Not -BeNullOrEmpty
    }
}

Describe 'WAVE-2 phase C: every ruled lever is adjustable per wave' {
    # The customer must be able to adjust every lever here; the values are only
    # defaults. The editor started with two levers;
    # the ruling covers five a wave can change and one that it cannot.
    BeforeEach {
        $script:run = Script:NewRun -Vms @(
            @{ name = 'vm1'; wave = 'first-five' }, @{ name = 'vm2'; wave = 'first-five' })
        $script:planPath = Join-Path $script:run 'plan.json'
    }
    AfterEach { if (Test-Path $script:run) { Remove-Item $script:run -Recurse -Force } }

    It 'writes the whole ruled set onto every machine in the wave' {
        Set-VmfWavePlan -RunPath $script:run -PlanPath $script:planPath -Layout @{
            waves = @(@{
                name = 'first-five'; vmIds = @((Script:VmId 'vm1'), (Script:VmId 'vm2'))
                capacityGate = 'Reserved'; requireApproval = $true
                onDDataFound = 'proceed'; onSystemAssignedIdentity = 'proceed'; keepSnapshotDays = 30
            })
        } | Out-Null
        foreach ($e in (Script:PlanOf $script:run).entries) {
            $e.policy.capacityGate | Should -Be 'Reserved'
            $e.policy.requireApproval | Should -BeTrue
            $e.policy.onDDataFound | Should -Be 'proceed'
            # WAVE-KERNEL-LINE-1: the kernel choice is no wave setting; the
            # machine keeps the value its plan entry holds.
            ($e.policy.onDriverBelowFloor ?? 'stop') | Should -Be 'stop'
            # REBUILD-REMOVE-ACCEPT-1: the identity setting is no wave setting any
            # more, so a layout that still sends it writes nothing for it.
            $e.policy.PSObject.Properties['onSystemAssignedIdentity'] | Should -BeNullOrEmpty
            $e.policy.keepSnapshotDays | Should -Be 30
        }
    }

    It 'refuses a lever value that is not a setting, naming what it may be' {
        { Set-VmfWavePlan -RunPath $script:run -PlanPath $script:planPath -Layout @{
            waves = @(@{ name = 'first-five'; vmIds = @((Script:VmId 'vm1')); onDDataFound = 'ignore' }) } } |
            Should -Throw '*must be one of: stop, proceed*'
    }

    It 'AN-PROCEED-NETVSC-1 / WAVE-KERNEL-LINE-1: refuses any kernel setting on a wave - Continue included' {
        { Set-VmfWavePlan -RunPath $script:run -PlanPath $script:planPath -Layout @{
            waves = @(@{ name = 'first-five'; vmIds = @((Script:VmId 'vm1')); onDriverBelowFloor = 'proceed' }) } } |
            Should -Throw '*A wave has no kernel choice*Choose each target step*'
    }

    It 'refuses a retention outside the range the contract allows' {
        { Set-VmfWavePlan -RunPath $script:run -PlanPath $script:planPath -Layout @{
            waves = @(@{ name = 'first-five'; vmIds = @((Script:VmId 'vm1')); keepSnapshotDays = 400 }) } } |
            Should -Throw '*between 0 and 90*'
    }

    It 'refuses to change the size series here, and says where to change it' {
        # It decides every target SIZE, and this editor cannot recompute sizes -
        # accepting it would write a plan whose policy says v7 and whose sizes
        # still say v6.
        #
        # WAVE-SERIES-GONE-1: the series belongs to each machine, chosen on
        # the assessment's targets step - the refusal says where.
        { Set-VmfWavePlan -RunPath $script:run -PlanPath $script:planPath -Layout @{
            waves = @(@{ name = 'first-five'; vmIds = @((Script:VmId 'vm1')); targetGeneration = 'v7' }) } } |
            Should -Throw "*targets step*"
    }

    It 'the wave editor really offers them - not just the API' {
        # A lever the engine honours but no screen exposes is not adjustable by
        # the customer, which is what the ruling asked for.
        $html = (Get-VmfPageSource -Path (Join-Path $repoRoot 'src' 'dashboard' 'waves.html'))
        # AN-PROCEED-NETVSC-1: the driver floor is shown, with no control - its
        # only value is Stop and ask (the kernel update is chosen per machine).
        foreach ($hook in 'data-cap', 'data-appr', 'data-data', 'data-keep') {
            $html | Should -Match ([regex]::Escape($hook))
        }
        $html | Should -Match 'onDDataFound: w\.onDDataFound'
        $html | Should -Match 'keepSnapshotDays: w\.keepSnapshotDays'
    }
}

Describe 'SCALE-UX-1: how many machines at once is a lever of the wave' {
    # The number belongs in the wave editor. Accepted with the wave,
    # written by the same boundary as the other levers, validated there.
    BeforeEach {
        $script:run = Script:NewRun -Vms @(
            @{ name = 'web1'; wave = 'lab-1' }, @{ name = 'web2'; wave = 'lab-1' },
            @{ name = 'db1';  wave = 'lab-2' })
        $script:planPath = Join-Path $script:run 'plan.json'
    }
    AfterEach { if (Test-Path $script:run) { Remove-Item $script:run -Recurse -Force } }

    It 'writes the number onto every machine of the wave' {
        Set-VmfWavePlan -RunPath $script:run -PlanPath $script:planPath -Layout @{
            waves = @(@{ name = 'lab-1'; throttle = 30; vmIds = @((Script:VmId 'web1'), (Script:VmId 'web2')) })
        } | Out-Null
        $plan = Script:PlanOf $script:run
        foreach ($n in 'web1', 'web2') { ($plan.entries | Where-Object { $_.vmId -eq (Script:VmId $n) }).policy.throttle | Should -Be 30 }
        ($plan.entries | Where-Object { $_.vmId -eq (Script:VmId 'db1') }).policy.PSObject.Properties['throttle'] | Should -BeNullOrEmpty -Because 'the other wave was not named'
    }

    It 'refuses a number one engine container cannot run, a number below one, and a number that is not a choice' {
        foreach ($bad in 61, 0, 'many', 7) {
            { Set-VmfWavePlan -RunPath $script:run -PlanPath $script:planPath -Layout @{
                waves = @(@{ name = 'lab-1'; throttle = $bad; vmIds = @((Script:VmId 'web1')) }) } } |
                Should -Throw '*one of the choices, 5, 15, 30 or 60*' -Because "$bad"
        }
    }

    # MACHINES-AT-ONCE-RANGE-1 (2026-11-06): Standard, 15. It was 3.
    It 'the default wave policy carries 15, Standard' {
        $policy = InModuleScope VmMigrationFactory { Get-VmfDefaultWavePolicy }
        $policy.throttle | Should -Be 15
    }

    It 'the contract knows the lever and its range' {
        (InModuleScope VmMigrationFactory { Get-VmfPolicyLevers })['throttle'] | Should -Be 'machines'
        (InModuleScope VmMigrationFactory { Test-VmfPolicyOverride -Override @{ throttle = 61 } }).Ok | Should -BeFalse
        (InModuleScope VmMigrationFactory { Test-VmfPolicyOverride -Override @{ throttle = 30 } }).Ok | Should -BeTrue -Because 'Large: 30 is two containers'
        (InModuleScope VmMigrationFactory { Test-VmfPolicyOverride -Override @{ throttle = 5 } }).Ok | Should -BeTrue
    }
}
