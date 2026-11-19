#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
DELETE-UNSTARTED-WAVE-1 (lab install, 2026-11-16; option (a) chosen).

Wave s1 finished and wave s2 had not started: its machine was Queued, with no
state document. The Migrations page showed no Stop this migration (only Pause
new work and Delete this migration), and Delete refused: "This migration works
on machines now: under way: 1 of 2 machines settled. Select Stop this
migration first." A dead end.

The choice: show Stop this migration between waves. Stop leaves out
the machines of the waves that did not start - they end Skipped, untouched,
with no safety copy - and changes nothing in Azure. Then Delete works.

So the page asks the service's own question (Get-VmfRunStage, and its twin
VmfHelp.runStage, held to tests/fixtures/run-stage.json). And Stop between
waves must not race a wave that starts now: Stop pauses the run BEFORE it
looks for a live worker, and a worker asks for the pause again AFTER it holds
a machine. One of the two always sees the other.
#>
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:cases = (Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' 'run-stage.json') -Raw | ConvertFrom-Json).cases
    $script:vm1 = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
    $script:vm2 = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm2'

    # The lab case: wave s1 (vm1) migrated, and its claim given back as the
    # worker does; wave s2 (vm2) not started - no state document, no claim.
    function Global:DuwRun([string]$FirstState = 'MIGRATED') {
        $run = Join-Path $TestDrive "run-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $run; a = $script:vm1; b = $script:vm2; st = $FirstState } {
            Initialize-VmfRun -RunPath $rp -RunId 'run-x' | Out-Null
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 12 -Document ([ordered]@{
                schemaVersion = 8; entries = @(
                    [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $a; wave = 's1'; path = 'A' },
                    [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $b; wave = 's2'; path = 'A' }) })
            New-VmfStateDoc -RunPath $rp -RunId 'run-x' -VmId $a -Wave 's1' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $a -NewState $st -Outcome ok | Out-Null
        }
        $run
    }
}
AfterAll { Remove-Item 'function:\DuwRun' -ErrorAction SilentlyContinue }

Describe 'Get-VmfRunStage: the one answer the page asks too (run-stage.json)' {
    It 'gives every shared case the answer VmfHelp.runStage gives' {
        @($script:cases).Count | Should -BeGreaterOrEqual 14 -Because 'the fixture loaded'
        foreach ($c in $script:cases) {
            $plan = if ($null -eq $c.entries) { $null } else { [pscustomobject]@{ entries = @($c.entries) } }
            $r = InModuleScope VmMigrationFactory -Parameters @{ p = $plan; d = @($c.docs) } { Get-VmfRunStage -Plan $p -StateDocs $d }
            $r.Stage | Should -Be $c.stage -Because $c.name
            $r.Machines | Should -Be $c.machines -Because $c.name
            $r.Settled | Should -Be $c.settled -Because $c.name
        }
    }
}

Describe 'Stop this migration between waves, then Delete this migration' {
    BeforeEach {
        Mock -ModuleName VmMigrationFactory Get-VmfSignedInIdentity { @{ Identity = 'operator@example.com' } }
        $claims = @(@{ typ = 'preferred_username'; val = 'operator@example.com' }, @{ typ = 'roles'; val = 'Vmf.Operator' })
        $doc = @{ auth_typ = 'aad'; claims = $claims } | ConvertTo-Json -Depth 5
        $script:operator = ConvertFrom-VmfClientPrincipal -Header ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($doc)))
        $global:DuwStarts = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName FacadeCore Invoke-VmfFacadeStartEngine {
            $global:DuwStarts.Add($Operation)
            [pscustomobject]@{ operation = $Operation; runId = $RunId; execution = 'vmf-engine-abc'; executions = @('vmf-engine-abc') }
        }
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $false }
    }
    AfterEach { Remove-Variable -Name DuwStarts -Scope Global -ErrorAction SilentlyContinue }

    It 'between waves the service reads the migration as running, so Delete is refused' {
        $run = DuwRun
        { Invoke-VmfFacadeDiscardRun -Principal $script:operator -StorePath $run -RunId 'run-x' -Note 'n' } |
            Should -Throw '400: *Select Stop this migration first*'
        Test-Path (Join-Path $run 'plan.json') | Should -BeTrue
    }

    It 'the refusal between waves says that machines did not start, not that the migration works on them' {
        $run = DuwRun
        $said = try { Invoke-VmfFacadeDiscardRun -Principal $script:operator -StorePath $run -RunId 'run-x' -Note 'n'; '' } catch { "$_" }
        $said | Should -BeExactly '400: Some machines of this migration did not start. Select Stop this migration first. It leaves out those machines and does not change them.'
    }

    It 'a machine the next wave just took, at PLANNED, does not work yet: the same words' {
        $run = DuwRun
        InModuleScope VmMigrationFactory -Parameters @{ rp = $run; b = $script:vm2 } {
            New-VmfStateDoc -RunPath $rp -RunId 'run-x' -VmId $b -Wave 's2' | Out-Null
        }
        { Invoke-VmfFacadeDiscardRun -Principal $script:operator -StorePath $run -RunId 'run-x' -Note 'n' } |
            Should -Throw '400: Some machines of this migration did not start.*'
    }

    It 'the refusal while a machine works keeps its words' {
        $run = DuwRun -FirstState 'CONVERTING'
        { Invoke-VmfFacadeDiscardRun -Principal $script:operator -StorePath $run -RunId 'run-x' -Note 'n' } |
            Should -Throw '400: This migration works on machines now: under way: 0 of 2 machines settled. Select Stop this migration first.'
    }

    It 'Stop leaves the machine of the wave that did not start out: Skipped, untouched, no safety copy, no claim' {
        $run = DuwRun
        $r = Invoke-VmfFacadeStopRun -Principal $script:operator -StorePath $run -RunId 'run-x' -Note 'the next wave is not needed'
        $r.Stopped | Should -BeTrue
        $r.MachinesClosedOut | Should -Be 1
        $r.PowerOwed.Count | Should -Be 0 -Because 'nothing changed the power state of a machine that never started'
        $global:DuwStarts.Count | Should -Be 0 -Because 'nothing changes in Azure, so no engine operation starts'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $run; a = $script:vm1; b = $script:vm2 } {
            $two = Read-VmfStateDoc -RunPath $rp -VmId $b
            $two.state | Should -Be 'SKIPPED'
            @($two.history)[-1].machineState | Should -Be 'untouched'
            $two.PSObject.Properties['safety'] | Should -BeNullOrEmpty
            @(Get-VmfSafetyCopyIds -StateDoc $two | Where-Object { $_ }).Count | Should -Be 0
            Get-VmfVmClaim -RunPath $rp -VmId $b | Should -BeNullOrEmpty
            (Read-VmfStateDoc -RunPath $rp -VmId $a).state | Should -Be 'MIGRATED' -Because 'a machine that finished keeps its result'
        }
    }

    It 'after Stop, Delete this migration goes ahead' {
        $run = DuwRun
        Invoke-VmfFacadeStopRun -Principal $script:operator -StorePath $run -RunId 'run-x' -Note 'n' | Out-Null
        $r = Invoke-VmfFacadeDiscardRun -Principal $script:operator -StorePath $run -RunId 'run-x' -Note 'n'
        $r.Removed | Should -BeTrue
        Test-Path $run | Should -BeFalse
    }
}

Describe 'Stop this migration cannot race a wave that starts now, and a refused Stop changes no working wave' {
    BeforeEach {
        Mock -ModuleName VmMigrationFactory Get-VmfSignedInIdentity { @{ Identity = 'operator@example.com' } }
        $global:DuwLeaseReads = [System.Collections.Generic.List[object]]::new()
        $global:DuwPauseWrites = 0
    }
    AfterEach { Remove-Variable -Name DuwLeaseReads, DuwPauseWrites, DuwSecondRead -Scope Global -ErrorAction SilentlyContinue }

    It 'looks for a live worker, then pauses, then looks again' {
        # A worker asks for the pause again after it holds a machine. So the
        # pause must be on the store before Stop's SECOND look: then a hold
        # that look does not see belongs to a worker that sees the pause. The
        # FIRST look writes nothing, so a hold already there refuses with no
        # pause at all.
        $run = DuwRun
        # The watchdog's list reads the same folder; one look is one listing here.
        Mock -ModuleName VmMigrationFactory Get-VmfExpiredLeases { @() }
        Mock -ModuleName VmMigrationFactory Get-VmfStoreNames -ParameterFilter { $Folder -eq 'leases' } {
            $global:DuwLeaseReads.Add((& (Get-Module VmMigrationFactory) { param($rp) Test-VmfWaveHalted -RunPath $rp } $RunPath))
            @()
        }
        Stop-VmfRun -RunPath $run -Reason 'x' -Confirm:$false | Out-Null
        # The two looks come first; the record and the summary read the folder later.
        @($global:DuwLeaseReads)[0..1] | Should -Be @($false, $true)
    }

    It 'a worker that holds a machine before Stop: refused, and no pause is ever written' {
        $run = DuwRun
        InModuleScope VmMigrationFactory -Parameters @{ rp = $run; b = $script:vm2 } {
            New-VmfLease -RunPath $rp -VmId $b -WorkerId 'worker-1' | Out-Null
        }
        Mock -ModuleName VmMigrationFactory Write-VmfStoreTextExclusive -ParameterFilter { $RelPath -eq 'halt.flag' } { $global:DuwPauseWrites++; $true }
        Mock -ModuleName VmMigrationFactory Set-VmfWaveHalt { $global:DuwPauseWrites++ }
        Mock -ModuleName VmMigrationFactory Write-VmfStoreJson -ParameterFilter { $RelPath -eq 'halt.flag' } { $global:DuwPauseWrites++ }
        { Stop-VmfRun -RunPath $run -Reason 'x' -Confirm:$false } | Should -Throw '*still holds 1 machine(s)*'
        $global:DuwPauseWrites | Should -Be 0 -Because 'a pause, even for a moment, ends a working wave early'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $run; b = $script:vm2 } {
            Test-VmfWaveHalted -RunPath $rp | Should -BeFalse -Because 'a refused stop leaves the run as it was'
            Read-VmfStateDoc -RunPath $rp -VmId $b | Should -BeNullOrEmpty -Because 'nothing was closed out'
        }
    }

    It 'after a refused Stop, the wave workers take their next machines as before' {
        # vm1 is held (live), vm2 waits for a slot in wave s2.
        $run = DuwRun
        InModuleScope VmMigrationFactory -Parameters @{ rp = $run; a = $script:vm1 } {
            New-VmfLease -RunPath $rp -VmId $a -WorkerId 'worker-1' | Out-Null
        }
        { Stop-VmfRun -RunPath $run -Reason 'x' -Confirm:$false } | Should -Throw '*still holds*'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $run; b = $script:vm2 } {
            $plan = Read-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 12
            Test-VmfWavePending -RunPath $rp -Plan $plan -Wave 's2' | Should -BeTrue
            (Get-VmfNextWaveVm -RunPath $rp -Plan $plan -Wave 's2' -WorkerId 'worker-2').Entry.vmId | Should -Be $b
        }
    }

    It 'a hold that appears between the two looks: refused, and the pause this Stop wrote is removed' {
        $run = DuwRun
        $global:DuwSecondRead = 0
        Mock -ModuleName VmMigrationFactory Get-VmfExpiredLeases { @() }
        Mock -ModuleName VmMigrationFactory Get-VmfStoreNames -ParameterFilter { $Folder -eq 'leases' } {
            $global:DuwSecondRead++
            if ($global:DuwSecondRead -eq 1) { @() } else { @('worker-hold.lease') }
        }
        { Stop-VmfRun -RunPath $run -Reason 'x' -Confirm:$false } | Should -Throw '*still holds 1 machine(s)*'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $run; b = $script:vm2 } {
            Test-VmfWaveHalted -RunPath $rp | Should -BeFalse
            Read-VmfStateDoc -RunPath $rp -VmId $b | Should -BeNullOrEmpty
        }
    }

    It 'a store that fails during the second look: the error surfaces, and no pause remains' {
        $run = DuwRun
        $global:DuwSecondRead = 0
        Mock -ModuleName VmMigrationFactory Get-VmfStoreNames -ParameterFilter { $Folder -eq 'leases' } {
            $global:DuwSecondRead++
            if ($global:DuwSecondRead -eq 1) { @() } else { throw 'Store list leases failed: HTTP 503' }
        }
        { Stop-VmfRun -RunPath $run -Reason 'x' -Confirm:$false } | Should -Throw '*HTTP 503*'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $run; b = $script:vm2 } {
            Test-VmfWaveHalted -RunPath $rp | Should -BeFalse
            Read-VmfStateDoc -RunPath $rp -VmId $b | Should -BeNullOrEmpty
        }
    }

    It 'a stop that goes ahead says the stop in the activity, once, and no HALTED line; a refused one says nothing' {
        # STOP-STATE-SHOWN-1: a HALTED line reads on the page as the wave
        # safety brake after repeated failures. The 'run' line says the stop.
        $run = DuwRun
        Stop-VmfRun -RunPath $run -Reason 'not needed' -Confirm:$false | Out-Null
        @(InModuleScope VmMigrationFactory -Parameters @{ rp = $run } { Read-VmfEvents -RunPath $rp } |
            Where-Object { $_.detail -like 'HALTED:*' }).Count | Should -Be 0
        $said = @(InModuleScope VmMigrationFactory -Parameters @{ rp = $run } { Read-VmfEvents -RunPath $rp -Step 'run' })
        $said.Count | Should -Be 1
        $said[0].detail | Should -Be 'run stopped by operator@example.com: not needed (the migration of 1 machine ended)'

        $refused = DuwRun
        $global:DuwSecondRead = 0
        Mock -ModuleName VmMigrationFactory Get-VmfExpiredLeases { @() }
        Mock -ModuleName VmMigrationFactory Get-VmfStoreNames -ParameterFilter { $Folder -eq 'leases' } {
            $global:DuwSecondRead++
            if ($global:DuwSecondRead -eq 1) { @() } else { @('worker-hold.lease') }
        }
        { Stop-VmfRun -RunPath $refused -Reason 'x' -Confirm:$false } | Should -Throw '*still holds*'
        @(InModuleScope VmMigrationFactory -Parameters @{ rp = $refused } { Read-VmfEvents -RunPath $rp -Step 'wave' } |
            Where-Object { $_.detail -like 'HALTED:*' }).Count | Should -Be 0
    }

    It 'a refused stop keeps a pause that was there before it' {
        $run = DuwRun
        InModuleScope VmMigrationFactory -Parameters @{ rp = $run } { Set-VmfWaveHalt -RunPath $rp -Reason 'operator halt' }
        $global:DuwSecondRead = 0
        Mock -ModuleName VmMigrationFactory Get-VmfExpiredLeases { @() }
        Mock -ModuleName VmMigrationFactory Get-VmfStoreNames -ParameterFilter { $Folder -eq 'leases' } {
            $global:DuwSecondRead++
            if ($global:DuwSecondRead -eq 1) { @() } else { @('worker-hold.lease') }
        }
        { Stop-VmfRun -RunPath $run -Reason 'x' -Confirm:$false } | Should -Throw '*still holds*'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $run } {
            Test-VmfWaveHalted -RunPath $rp | Should -BeTrue
            (Read-VmfStoreJson -RunPath $rp -RelPath 'halt.flag' -Depth 4).reason | Should -Be 'operator halt'
        }
    }

    It 'a refused stop keeps a pause another writer made after the stop paused the run' {
        # The breaker or a person can pause the run between the two looks.
        # Stop removes only the pause it wrote, as it wrote it.
        $run = DuwRun
        $global:DuwSecondRead = 0
        Mock -ModuleName VmMigrationFactory Get-VmfExpiredLeases { @() }
        Mock -ModuleName VmMigrationFactory Get-VmfStoreNames -ParameterFilter { $Folder -eq 'leases' } {
            $global:DuwSecondRead++
            if ($global:DuwSecondRead -eq 1) { return @() }
            & (Get-Module VmMigrationFactory) { param($rp) Write-VmfStoreJson -RunPath $rp -RelPath 'halt.flag' -Document ([ordered]@{ haltedUtc = '2026-11-16T00:00:00Z'; reason = 'circuit breaker: 3 failures' }) } $RunPath
            @('worker-hold.lease')
        }
        { Stop-VmfRun -RunPath $run -Reason 'x' -Confirm:$false } | Should -Throw '*still holds*'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $run } {
            (Read-VmfStoreJson -RunPath $rp -RelPath 'halt.flag' -Depth 4).reason | Should -Be 'circuit breaker: 3 failures'
        }
    }
}

Describe 'New-VmfVmClaim says whether this call took the claim' {
    It 'Taken on the first grant, not on a grant the run held already' {
        $run = DuwRun
        InModuleScope VmMigrationFactory -Parameters @{ rp = $run; b = $script:vm2 } {
            $first = New-VmfVmClaim -RunPath $rp -VmId $b -RunId 'run-x'
            $first.Granted | Should -BeTrue
            $first.Taken | Should -BeTrue
            $again = New-VmfVmClaim -RunPath $rp -VmId $b -RunId 'run-x'
            $again.Granted | Should -BeTrue
            $again.Taken | Should -BeFalse
        }
    }
}

Describe 'Get-VmfNextWaveVm: a worker asks for the pause again once it holds a machine' {
    BeforeEach {
        $script:run = DuwRun
        $global:DuwHaltCalls = 0
        # The pause arrives after the worker's first look and before its hold.
        Mock -ModuleName VmMigrationFactory Test-VmfWaveHalted { $global:DuwHaltCalls++; $global:DuwHaltCalls -gt 1 }
    }
    AfterEach { Remove-Variable -Name DuwHaltCalls -Scope Global -ErrorAction SilentlyContinue }

    It 'gives the machine back - its hold and the claim it took - and takes nothing' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; b = $script:vm2 } {
            $plan = Read-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 12
            Get-VmfNextWaveVm -RunPath $rp -Plan $plan -Wave 's2' -WorkerId 'worker-1' | Should -BeNullOrEmpty
            @(Get-VmfStoreNames -RunPath $rp -Folder 'leases' -Extension '.lease').Count | Should -Be 0
            Get-VmfVmClaim -RunPath $rp -VmId $b | Should -BeNullOrEmpty -Because 'Stop gave the claim back, and the worker must not keep it'
            Read-VmfStateDoc -RunPath $rp -VmId $b | Should -BeNullOrEmpty
        }
        $global:DuwHaltCalls | Should -Be 2 -Because 'it asked once before the hold and once after'
    }

    It 'keeps a claim the run held before, because Stop keeps the claim of a machine part-way through its move' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; b = $script:vm2 } {
            New-VmfVmClaim -RunPath $rp -VmId $b -RunId 'run-x' | Out-Null
            $plan = Read-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 12
            Get-VmfNextWaveVm -RunPath $rp -Plan $plan -Wave 's2' -WorkerId 'worker-1' | Should -BeNullOrEmpty
            @(Get-VmfStoreNames -RunPath $rp -Folder 'leases' -Extension '.lease').Count | Should -Be 0
            (Get-VmfVmClaim -RunPath $rp -VmId $b).runId | Should -Be 'run-x'
        }
    }

    It 'still takes a machine whose rollback a worker did not finish' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; b = $script:vm2 } {
            New-VmfStateDoc -RunPath $rp -RunId 'run-x' -VmId $b -Wave 's2' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $b -NewState 'CONVERTING' -Outcome ok | Out-Null
            Set-VmfRollbackPending -Context @{ RunPath = $rp; VmId = $b } -Kind 'full' -State 'CONVERTING' -ReasonCode 'rolledBack' -Detail 'x'
            $plan = Read-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 12
            (Get-VmfNextWaveVm -RunPath $rp -Plan $plan -Wave 's2' -WorkerId 'worker-1').Entry.vmId | Should -Be $b
        }
    }

    It 'with no pause, takes the machine as before' {
        Mock -ModuleName VmMigrationFactory Test-VmfWaveHalted { $false }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; b = $script:vm2 } {
            $plan = Read-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 12
            (Get-VmfNextWaveVm -RunPath $rp -Plan $plan -Wave 's2' -WorkerId 'worker-1').Entry.vmId | Should -Be $b
            @(Get-VmfStoreNames -RunPath $rp -Folder 'leases' -Extension '.lease').Count | Should -Be 1
            (Get-VmfVmClaim -RunPath $rp -VmId $b).runId | Should -Be 'run-x'
        }
    }
}
