#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# AVSET-NOT-OFFERED-STOP-1 (decided 2026-11-14).
#
# At Checking, a machine whose availability set's hardware does not offer the
# target size got a warning (AVSET-NOTE-1), and the move went on. While another
# machine of the set runs, Azure then refuses the new size at Moving or at
# Starting up - inside the change window - and the machine is rolled back.
# Microsoft's resize page (docs/upstream-docs/azure/virtual-machines/sizes/
# resize-vm.md, "Use PowerShell to resize a VM in an availability set"): "then
# you need to deallocate all VMs in the availability set to resize the VM."
#
# So when Azure DEFINITELY says both - the size is not offered, and another
# machine of the set runs - Checking stops the machine untouched, before
# Backing up, with the words of the warning. Every case the product cannot tell
# keeps the behaviour of before exactly: the sizes not read, the members not
# read, a power state not read, no other machine running.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # CLUSTER-DETECT-1: the cluster check at Checking is not under test here.
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }

    $script:target = 'Standard_D4ds_v6'
    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers'
    $script:selfId = "$($script:sub)/Microsoft.Compute/virtualMachines/vm1"
    $script:otherId = "$($script:sub)/Microsoft.Compute/virtualMachines/vm2"
    $script:avsetId = "$($script:sub)/Microsoft.Compute/availabilitySets/avs-app"

    function Global:AvsNote([int]$Running, [int]$DefinitelyRunning, $Offered, [string]$Target = $script:target) {
        InModuleScope VmMigrationFactory -Parameters @{ r = $Running; d = $DefinitelyRunning; o = $Offered; t = $Target } {
            param($r, $d, $o, $t)
            Get-VmfAvailabilitySetNote -Others 1 -Names 'vm2' -Running $r -DefinitelyRunning $d -TargetSize $t -OfferedSizes $o
        }
    }
    function Global:AvsPlanEntry {
        [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:selfId; wave = 'w1'; ring = 'lab'; path = 'A'
            assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'; sourceSize = 'Standard_D4s_v4'; sourceDiskArch = 'diskless'
                platformManaged = $false; location = 'centralus'; dataDiskCount = 0; availabilitySetId = $script:avsetId }
            target = [pscustomobject]@{ size = $script:target; diskArch = 'nvme-temp'; controller = 'NVMe'; zone = $null }
            policy = [pscustomobject]@{ onDDataFound = 'proceed'; targetGeneration = 'v6' } }
    }
    # The members Azure gives: this machine, and vm2 with the power state given.
    function Global:AvsMembers($OtherAllocated) {
        @([pscustomobject]@{ Name = 'vm1'; Id = $script:selfId; Allocated = $true },
          [pscustomobject]@{ Name = 'vm2'; Id = $script:otherId; Allocated = $OtherAllocated })
    }
    # Runs Checking and gives what it returned. Get-VmfVmConfig is the read of
    # the machine that comes right after the availability set; it throws a
    # marker, so a run that went past the availability set says so.
    function Global:AvsPrecheck([string]$RunPath) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath; plan = (AvsPlanEntry) } {
            param($rp, $plan)
            $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'avs'
            New-VmfStateDoc -RunPath $rp -RunId 'avs' -VmId $ctx.VmId | Out-Null
            try { Invoke-VmfStepPrecheck -Context $ctx } catch { @{ Next = 'went-past'; Reason = $_.Exception.Message } }
        }
    }
    function Global:AvsDropDir([string]$Dir) { if ($Dir -and (Test-Path $Dir)) { [System.IO.Directory]::Delete($Dir, $true) } }
}
AfterAll {
    Remove-Item function:AvsNote, function:AvsPlanEntry, function:AvsMembers, function:AvsPrecheck, function:AvsDropDir -ErrorAction SilentlyContinue
}

Describe 'AVSET-NOT-OFFERED-STOP-1: the note says stop only when Azure is definite on both' {

    It 'not offered, and another machine definitely runs: stop, with the words of the warning' {
        $warn = AvsNote -Running 1 -DefinitelyRunning 0 -Offered @('Standard_D4ds_v5')
        $n = AvsNote -Running 1 -DefinitelyRunning 1 -Offered @('Standard_D4ds_v5')
        $n.Outcome | Should -Be 'stop'
        $n.Detail | Should -Be $warn.Detail -Because 'no new words: the stop uses the warning'
        $n.Detail | Should -Match 'does not offer Standard_D4ds_v6'
    }

    It 'not offered, and an empty list is still an answer: stop' {
        (AvsNote -Running 1 -DefinitelyRunning 1 -Offered @(, @())).Outcome | Should -Be 'stop'
    }

    It 'the size compare ignores case, as before' {
        (AvsNote -Running 1 -DefinitelyRunning 1 -Offered @('standard_d4ds_v6')).Outcome | Should -Be 'info'
    }

    It 'not offered, but a power state was not read and none definitely runs: the warning of before' {
        (AvsNote -Running 1 -DefinitelyRunning 0 -Offered @('Standard_D4ds_v5')).Outcome | Should -Be 'warn'
    }

    It 'not offered, and no other machine runs: the warning of before' {
        (AvsNote -Running 0 -DefinitelyRunning 0 -Offered @('Standard_D4ds_v5')).Outcome | Should -Be 'warn'
    }

    It 'the sizes were not read, and another machine runs: the warning of before' {
        $n = AvsNote -Running 1 -DefinitelyRunning 1 -Offered $null
        $n.Outcome | Should -Be 'warn'
        $n.Detail | Should -Match 'Azure did not say'
    }

    It 'no target size, and another machine runs: the warning of before' {
        (AvsNote -Running 1 -DefinitelyRunning 1 -Offered @('Standard_D4ds_v5') -Target '').Outcome | Should -Be 'warn'
    }

    It 'offered, and another machine runs: the information line of before' {
        (AvsNote -Running 1 -DefinitelyRunning 1 -Offered @($script:target)).Outcome | Should -Be 'info'
    }

    It 'without the new parameter, the note is the note of before (no stop)' {
        $n = InModuleScope VmMigrationFactory -Parameters @{ t = $script:target } {
            param($t) Get-VmfAvailabilitySetNote -Others 1 -Names 'vm2' -Running 1 -TargetSize $t -OfferedSizes @('Standard_D4ds_v5')
        }
        $n.Outcome | Should -Be 'warn'
    }

    It 'the members not read: the unknown note never stops' {
        $n = InModuleScope VmMigrationFactory -Parameters @{ t = $script:target } {
            param($t) Get-VmfAvailabilitySetUnknownNote -TargetSize $t -OfferedSizes @('Standard_D4ds_v5')
        }
        $n.Outcome | Should -Be 'warn'
    }
}

Describe 'AVSET-NOT-OFFERED-STOP-1: Checking stops the machine untouched, before any change' {
    BeforeAll {
        # Every function in the Azure boundary that changes something.
        $script:writes = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops') -Filter '*.ps1' |
            ForEach-Object { Select-String -Path $_.FullName -Pattern '^function\s+([\w-]+)' | ForEach-Object { $_.Matches[0].Groups[1].Value } } |
            Where-Object { $_ -match '^(Stop|Start|Set|New|Remove|Lock|Unlock|Request)-' -or $_ -in @('Invoke-VmfRunCommand', 'Clear-VmfDiskPerfProperties') })
    }
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-avs-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Initialize-VmfRun -RunPath $rp -RunId 'avs' | Out-Null }
        foreach ($n in $script:writes) { Mock -ModuleName VmMigrationFactory -CommandName $n -MockWith { throw 'nothing in Azure may change' } }
        Mock -ModuleName VmMigrationFactory Test-VmfAdeExtension { $false }
        Mock -ModuleName VmMigrationFactory Get-VmfVmResourceLocks { , @() }
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { @([pscustomobject]@{ actions = @('*'); notActions = @() }) }
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/running' }
        Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions { @() }
        Mock -ModuleName VmMigrationFactory Get-AzNetworkInterface { [pscustomobject]@{ EnableAcceleratedNetworking = $true } }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @() }
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { throw 'reached the read of the machine' }
    }
    AfterEach {
        foreach ($n in $script:writes) { Should -Invoke -ModuleName VmMigrationFactory -CommandName $n -Times 0 -Exactly -Because "$n changes Azure" }
        AvsDropDir $script:rp
    }

    It 'the boundary has write functions to watch' {
        $script:writes | Should -Contain 'Stop-VmfVmDeallocated'
        $script:writes | Should -Contain 'Set-VmfVmSizeAndController'
    }

    It 'not offered, and the other machine runs: NEEDS_DECISION, untouched, with the words of the warning' {
        Mock -ModuleName VmMigrationFactory Get-VmfAvailabilitySetMembers { AvsMembers $true }
        Mock -ModuleName VmMigrationFactory Get-VmfAvailabilitySetSizes { @('Standard_D4ds_v5', 'Standard_D8ds_v5') }
        $r = AvsPrecheck $script:rp
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'availabilitySetSizeNotOffered'
        $r.MachineState | Should -Be 'untouched'
        $r.Detail | Should -Match ([regex]::Escape('This machine shares an availability set with 1 other machine: vm2.'))
        $r.Detail | Should -Match ([regex]::Escape("The hardware that hosts the set does not offer $($script:target)."))
        $r.Detail | Should -Match ([regex]::Escape('Azure can refuse to start this machine until every machine in the set is stopped, and 1 of them is running or could not be checked.'))
        $r.Detail | Should -Match 'Nothing on the machine changed\.$'
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfVmConfig -Times 0 -Exactly -Because 'the stop comes before the capture and before Backing up'
    }

    It 'the stop writes no warning line of its own: the stop says it once' {
        Mock -ModuleName VmMigrationFactory Get-VmfAvailabilitySetMembers { AvsMembers $true }
        Mock -ModuleName VmMigrationFactory Get-VmfAvailabilitySetSizes { @('Standard_D4ds_v5') }
        AvsPrecheck $script:rp | Out-Null
        $events = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) @(Read-VmfEvents -RunPath $rp) }
        @($events | Where-Object { [string]$_.detail -match 'does not offer' -and [string]$_.outcome -eq 'warn' }).Count | Should -Be 0
    }

    It '<How>: the warning of before, and Checking goes on' -ForEach @(
        @{ How = 'the power state of the other machine was not read'; Allocated = $null; Sizes = 'notOffered'; Outcome = 'warn' }
        @{ How = 'the other machine is stopped (deallocated)'; Allocated = $false; Sizes = 'notOffered'; Outcome = 'warn' }
        @{ How = 'the sizes of the set were not read'; Allocated = $true; Sizes = 'throw'; Outcome = 'warn' }
        @{ How = 'the hardware of the set offers the target size'; Allocated = $true; Sizes = 'offered'; Outcome = 'info' }
    ) {
        $script:allocated = $Allocated
        Mock -ModuleName VmMigrationFactory Get-VmfAvailabilitySetMembers { AvsMembers $script:allocated }
        switch ($Sizes) {
            'notOffered' { Mock -ModuleName VmMigrationFactory Get-VmfAvailabilitySetSizes { @('Standard_D4ds_v5') } }
            'offered' { Mock -ModuleName VmMigrationFactory Get-VmfAvailabilitySetSizes { @('Standard_D4ds_v6') } }
            'throw' { Mock -ModuleName VmMigrationFactory Get-VmfAvailabilitySetSizes { throw 'ServiceUnavailable' } }
        }
        $r = AvsPrecheck $script:rp
        $r.Reason | Should -Not -Be 'availabilitySetSizeNotOffered'
        $r.Next | Should -Be 'went-past' -Because 'Checking goes on to read the machine'
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfVmConfig -Times 1 -Exactly
        $events = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) @(Read-VmfEvents -RunPath $rp) }
        @($events | Where-Object { [string]$_.detail -match '^This machine shares an availability set' -and [string]$_.outcome -eq $Outcome }).Count |
            Should -Be 1 -Because 'the line of before is written as before'
    }

    It 'the members of the set were not read: the unknown note of before, and Checking goes on' {
        Mock -ModuleName VmMigrationFactory Get-VmfAvailabilitySetMembers { throw 'ServiceUnavailable' }
        Mock -ModuleName VmMigrationFactory Get-VmfAvailabilitySetSizes { @('Standard_D4ds_v5') }
        $r = AvsPrecheck $script:rp
        $r.Next | Should -Be 'went-past'
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfVmConfig -Times 1 -Exactly
    }
}

Describe 'AVSET-NOT-OFFERED-STOP-1: the stop reason' {
    BeforeAll {
        $all = @((Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json).reasons)
        $script:reason = $all | Where-Object code -EQ 'availabilitySetSizeNotOffered'
    }

    It 'is in the stop list: untouched, and a retry after a fix' {
        $script:reason | Should -Not -BeNullOrEmpty
        $script:reason.machine | Should -Be 'untouched'
        $script:reason.retry | Should -Be 'afterFix'
    }

    It 'says what Microsoft says to do: stop every other machine in the set' {
        $script:reason.whatToDo | Should -Match 'Stopped \(deallocated\)'
        $script:reason.meaning | Should -Match 'The product read these facts from Azure before any change\.'
        # The engine counts PowerState/running and PowerState/starting: Azure's statuses Running and Starting.
        $script:reason.meaning | Should -Match 'Azure reports that another machine in the set has the power state Running or Starting\.'
    }

    It 'says that a machine of the set with the power state Running before its move has it after the move (each member stops while another runs)' {
        # Review of 2026-11-14: every member of the set stops at Checking while
        # the others run, and a member that has moved is started again - so
        # the next one stops again unless it is stopped again.
        # STE100 rewrite 2026-11-15: POWER-AFTER-MOVE-1 returns a machine that
        # Checking found stopped to that power state, so only one that ran
        # before its move runs again after it.
        $again = 'If a machine had the power state Running before its move, it has the power state Running after the move. Stop that machine again before you try the next machine in the set.'
        $script:reason.whatToDo | Should -Match ([regex]::Escape($again))
        $page = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'docs' 'manual' 'understand' 'how-a-machine-moves.md'))
        $para = @(($page -split "`n") | Where-Object { $_.StartsWith('**When Azure refuses the new size.**') })
        $para.Count | Should -Be 1
        $para[0] | Should -Match ([regex]::Escape($again))
    }

    It 'the engine stops on the outcome of the note, and only on it' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1')
        $code | Should -Match "if \(\`$avsetNote\.Outcome -eq 'stop'\)"
        $code | Should -Match "Reason = 'availabilitySetSizeNotOffered'"
    }
}
