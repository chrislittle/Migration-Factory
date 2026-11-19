#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SCALE-1 - the failure the circuit breaker is worst at.
#
# At scale, the product must handle throttling when quota or capacity is not
# available, so that machines do not fail for it.
#
# Per-CALL throttling was already handled - Invoke-VmfAzOperation retries on
# 429/5xx/timeouts and Resource Graph was fixed to throw on 429 so the retry can
# see it. What was missing is fleet-level: nothing notices when a whole CELL has
# run out.
#
# The circuit breaker counts failures of any kind, on thresholds tuned for
# INDEPENDENT failures - a bad image here, a locked resource there. Capacity is
# not like that. When a region runs out of a size, every remaining machine of
# that size fails identically, and each one pays a deallocate, a convert attempt
# and a rollback to find out. Waiting for a generic rate threshold means paying
# that price several more times for information already in hand.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:sub = '00000000-0000-0000-0000-000000000000'
    function Script:NewWave {
        param([int]$Machines = 6)
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-cap-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $ids = 1..$Machines | ForEach-Object {
            "/subscriptions/$script:sub/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm$_" }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; ids = $ids } {
            Initialize-VmfRun -RunPath $rp -RunId 'cap-test' | Out-Null
            foreach ($id in $ids) { New-VmfStateDoc -RunPath $rp -RunId 'cap-test' -VmId $id -Wave 'w1' | Out-Null }
        }
        $plan = [pscustomobject]@{ entries = @($ids | ForEach-Object {
            [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $_; wave = 'w1'; path = 'A'
                assessment = [pscustomobject]@{ location = 'centralus' }
                target = [pscustomobject]@{ size = 'Standard_D2s_v6' } } }) }
        @{ Run = $rp; Plan = $plan; Ids = $ids }
    }
    function Script:FailWith {
        param($Fx, [int]$Index, [string]$Reason, [string]$Detail = 'something went wrong')
        InModuleScope VmMigrationFactory -Parameters @{ rp = $Fx.Run; id = $Fx.Ids[$Index]; r = $Reason; d = $Detail } {
            Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'FAILED_ROLLED_BACK' -Outcome fail `
                -Detail $d -ReasonCode $r -MachineState 'restored' | Out-Null
        }
    }
    function Script:Check($Fx) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $Fx.Run; p = $Fx.Plan } {
            Test-VmfCapacityExhausted -RunPath $rp -Plan $p -Wave 'w1' }
    }
}

Describe 'SCALE-1: a cell that has run out stops the wave' {
    BeforeEach { $script:fx = Script:NewWave }
    AfterEach { if (Test-Path $script:fx.Run) { Remove-Item $script:fx.Run -Recurse -Force } }

    It 'one capacity failure is not enough - it can be genuinely transient' {
        Script:FailWith $script:fx 0 'capacityUnavailable' 'AllocationFailed'
        $r = Script:Check $script:fx
        $r.Exhausted | Should -BeFalse
        $r.Count | Should -Be 1
    }

    It 'two in the same cell is not bad luck' {
        Script:FailWith $script:fx 0 'capacityUnavailable' 'AllocationFailed'
        Script:FailWith $script:fx 1 'capacityUnavailable' 'AllocationFailed'
        $r = Script:Check $script:fx
        $r.Exhausted | Should -BeTrue
        $r.Cells | Should -Contain 'Standard_D2s_v6@centralus'
    }

    It 'and says why stopping is cheaper than carrying on' {
        Script:FailWith $script:fx 0 'capacityUnavailable' 'AllocationFailed'
        Script:FailWith $script:fx 1 'capacityUnavailable' 'AllocationFailed'
        $d = (Script:Check $script:fx).Detail
        $d | Should -Match 'would fail the same way'
        $d | Should -Match 'would first stop and roll back'
    }

    It 'failures of OTHER kinds are left to the ordinary breaker' {
        # Two locked resources are two independent problems, not a wall.
        Script:FailWith $script:fx 0 'resourceLocked' 'ScopeLocked'
        Script:FailWith $script:fx 1 'guestPrepBlocked' 'the guest said no'
        (Script:Check $script:fx).Exhausted | Should -BeFalse
    }

    It 'a machine that failed capacity twice still counts once' {
        # Otherwise one machine retrying could halt a wave on its own.
        Script:FailWith $script:fx 0 'capacityUnavailable' 'AllocationFailed'
        Script:FailWith $script:fx 0 'capacityUnavailable' 'AllocationFailed again'
        $r = Script:Check $script:fx
        $r.Count | Should -Be 1
        $r.Exhausted | Should -BeFalse
    }

    It 'captures the quota family Azure named, because nothing else knows it' {
        # CLAUDE.md: the family cannot be inferred from the size name, and a
        # QuotaExceeded error names the real one. This is the only place that
        # mapping is ever stated by the authority on it.
        Script:FailWith $script:fx 0 'capacityUnavailable' 'QuotaExceeded: Operation could not be completed as it results in exceeding approved standardDDSv6Family quota'
        Script:FailWith $script:fx 1 'capacityUnavailable' 'QuotaExceeded: exceeding approved standardDDSv6Family quota'
        $r = Script:Check $script:fx
        $r.Detail | Should -Match 'standardDDSv6Family'
        @($r.Evidence).Count | Should -BeGreaterThan 0
    }

    It 'keeps the raw message as evidence, not just its own summary' {
        Script:FailWith $script:fx 0 'capacityUnavailable' 'ZonalAllocationFailed in zone 2'
        Script:FailWith $script:fx 1 'capacityUnavailable' 'ZonalAllocationFailed in zone 2'
        (Script:Check $script:fx).Evidence -join ' ' | Should -Match 'ZonalAllocationFailed'
    }

    It 'an untouched wave is not exhausted' {
        $r = Script:Check $script:fx
        $r.Exhausted | Should -BeFalse
        $r.Count | Should -Be 0
    }
}

Describe 'SCALE-1: the wave runner acts on it, before the generic breaker' {
    BeforeAll { $script:sw = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Start-VmfWave.ps1') -Raw }

    It 'the monitor loop checks capacity' {
        $script:sw | Should -Match 'Test-VmfCapacityExhausted -RunPath \$RunPath -Plan \$plan -Wave \$Wave'
    }

    It 'and halts the wave rather than letting the rest walk into it' {
        $script:sw | Should -Match 'Set-VmfWaveHalt -RunPath \$RunPath -Reason \$capacity\.Detail'
    }

    It 'capacity is checked BEFORE the generic breaker, not after' {
        # After would mean waiting for a rate threshold to be crossed by
        # failures that are already explained.
        $capAt = $script:sw.IndexOf('Test-VmfCapacityExhausted')
        $brkAt = $script:sw.IndexOf('Test-VmfCircuitBreaker -RunPath')
        $capAt | Should -BeGreaterThan 0
        $brkAt | Should -BeGreaterThan 0
        $capAt | Should -BeLessThan $brkAt
    }

    It 'the raw Azure message reaches the run log, where a person can read it' {
        $script:sw | Should -Match 'Azure said: \$e'
    }

    It 'the generic breaker still runs when capacity is not the problem' {
        $script:sw | Should -Match 'else \{\s*\r?\n\s*\$breaker = Test-VmfCircuitBreaker'
    }
}
