#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SKIP-ONE-1, 2026-09-23. There is no way to leave ONE machine out.
#
# At a machine parked below the MANA kernel floor, with the wave unable to
# finish past it, the page had no way to skip that machine in the wave.
#
# `SKIPPED` exists as a state, and the only thing that ever set it was
# `Stop-VmfRun` - which closes out the WHOLE run. So the choices at a parked
# machine were rebuild it, accept the risk, or retry; "leave this one out and
# let the rest finish" was not among them, in the engine, the service or the
# app.
#
# WHAT THIS IS NOT. It is not "nothing happened to this machine". By the time
# a machine parks at a decision the safety copy is taken and the guest may
# already be prepared - his had been. Skipping leaves it exactly as it is,
# which is a thing to SAY, not a thing to hide.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    # TEST-1: the floor, before anything else. A file that loads the module
    # and does not turn this on would send an unmocked Azure call to the
    # network instead of failing. `Skip-VmfVm` touches nothing in Azure - and
    # "it should not" is exactly the claim this proves rather than assumes.
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    function New-SkipStore {
        param([string]$State = 'NEEDS_DECISION')
        $root = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-skip-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $vmA = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm-a'
        $vmB = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm-b'
        & (Get-Module VmMigrationFactory) { param($rp, $a, $b, $st)
            Initialize-VmfRun -RunPath $rp -RunId 'run-1' -Kind 'migration' | Out-Null
            $entry = { param($id) @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; wave = 'wave-1'
                assessment = @{ classification = 'ReadyNow' }; target = @{}; path = 'A'
                policy = @{ requireApproval = $false } } }
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document @{
                schemaVersion = 14; entries = @((& $entry $a), (& $entry $b)) } -Depth 24
            foreach ($id in @($a, $b)) { New-VmfStateDoc -RunPath $rp -RunId 'run-1' -VmId $id -Wave 'wave-1' | Out-Null }
            # `fail` is in the outcome set; `warn` is not. The set is
            # ok/retry/fail/skip.
            Add-VmfStateTransition -RunPath $rp -VmId $a -NewState $st -Outcome fail -Detail 'parked' | Out-Null
        } $root $vmA $vmB $State
        [pscustomobject]@{ Path = $root; VmA = $vmA; VmB = $vmB }
    }
    function Get-SkipState {
        param($Store, [string]$VmId)
        [string](& (Get-Module VmMigrationFactory) { param($rp, $id)
            (Read-VmfStateDoc -RunPath $rp -VmId $id).state } $Store.Path $VmId)
    }
}

Describe 'SKIP-ONE-1: leave ONE machine out' {

    It 'marks the machine skipped and leaves the others alone' {
        $store = New-SkipStore
        try {
            Skip-VmfVm -RunPath $store.Path -VmId $store.VmA -Reason 'kernel below the floor; migrating it later' -SkippedBy 'someone@example.com' -Confirm:$false
            Get-SkipState -Store $store -VmId $store.VmA | Should -Be 'SKIPPED'
            # THE WHOLE POINT. Stop-VmfRun closed out everything; this must not.
            Get-SkipState -Store $store -VmId $store.VmB | Should -Be 'PLANNED'
        }
        finally { Remove-Item $store.Path -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'records WHO and WHY, because a machine that did not migrate is a decision' {
        $store = New-SkipStore
        try {
            Skip-VmfVm -RunPath $store.Path -VmId $store.VmA -Reason 'accepted by the service owner' -SkippedBy 'someone@example.com' -Confirm:$false
            $doc = & (Get-Module VmMigrationFactory) { param($rp, $id)
                Read-VmfStateDoc -RunPath $rp -VmId $id } $store.Path $store.VmA
            $last = @($doc.history)[-1]
            $last.state | Should -Be 'SKIPPED'
            "$($last.detail)" | Should -Match 'someone@example\.com'
            "$($last.detail)" | Should -Match 'accepted by the service owner'
        }
        finally { Remove-Item $store.Path -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'is safe to run twice, like every other step' {
        # Hard rule 4. A second skip is not an error and does not add noise.
        $store = New-SkipStore
        try {
            Skip-VmfVm -RunPath $store.Path -VmId $store.VmA -Reason 'first' -SkippedBy 'a@example.com' -Confirm:$false
            $again = Skip-VmfVm -RunPath $store.Path -VmId $store.VmA -Reason 'second' -SkippedBy 'a@example.com' -Confirm:$false
            $again.AlreadySkipped | Should -BeTrue
            Get-SkipState -Store $store -VmId $store.VmA | Should -Be 'SKIPPED'
        }
        finally { Remove-Item $store.Path -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'REFUSES a machine that is working right now' {
        # A live worker is driving it. Marking it skipped underneath would
        # leave two things believing they own one machine - the same reason
        # Stop-VmfRun refuses a live lease.
        $store = New-SkipStore -State 'CONVERTING'
        try {
            { Skip-VmfVm -RunPath $store.Path -VmId $store.VmA -Reason 'no' -SkippedBy 'a@example.com' -Confirm:$false } |
                Should -Throw '*still working*'
            Get-SkipState -Store $store -VmId $store.VmA | Should -Be 'CONVERTING'
        }
        finally { Remove-Item $store.Path -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'refuses a machine that already finished' {
        # Migrated is not something to skip, and saying "skipped" of a machine
        # that moved would be a false record.
        $store = New-SkipStore -State 'MIGRATED'
        try {
            { Skip-VmfVm -RunPath $store.Path -VmId $store.VmA -Reason 'no' -SkippedBy 'a@example.com' -Confirm:$false } |
                Should -Throw '*already*'
        }
        finally { Remove-Item $store.Path -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'refuses a machine this run does not hold' {
        $store = New-SkipStore
        try {
            { Skip-VmfVm -RunPath $store.Path -VmId '/x/not-in-the-plan' -Reason 'no' -SkippedBy 'a@example.com' -Confirm:$false } |
                Should -Throw '*not in this*'
        }
        finally { Remove-Item $store.Path -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'frees the machine for another migration' {
        # The claim is what stops a second run touching it. A machine this run
        # has given up on must not stay held by it.
        $store = New-SkipStore
        try {
            & (Get-Module VmMigrationFactory) { param($rp, $id)
                New-VmfVmClaim -RunPath $rp -VmId $id -RunId 'run-1' | Out-Null } $store.Path $store.VmA
            $r = Skip-VmfVm -RunPath $store.Path -VmId $store.VmA -Reason 'later' -SkippedBy 'a@example.com' -Confirm:$false
            $r.ClaimReleased | Should -BeTrue
        }
        finally { Remove-Item $store.Path -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'SKIP-ONE-1: reachable from the app' {

    It 'the service offers it' {
        $core = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1')
        $core | Should -Match 'function Invoke-VmfFacadeSkipVm'
        $core | Should -Match 'Skip-VmfVm'
    }

    It 'behind the operator role, like every other action that changes something' {
        $core = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1')
        $at = $core.IndexOf('function Invoke-VmfFacadeSkipVm')
        $core.Substring($at, 900) | Should -Match "Assert-VmfFacadeRole"
    }

    It 'has a route' {
        $run = Join-Path $script:repoRoot 'src' 'facade' 'app' 'PostSkipVm' 'run.ps1'
        Test-Path $run | Should -BeTrue
        (Get-VmfCodeOnly -Path $run) | Should -Match 'Invoke-VmfFacadeSkipVm'
        $fn = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'app' 'PostSkipVm' 'function.json') -Raw | ConvertFrom-Json
        $fn.bindings[0].route | Should -Match 'vms/skip'
    }

    It 'and a control on the page, because a command line is not an answer' {
        # Hard rule 12. This was met at a parked machine, in the app.
        $page = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'migrations.html')
        $page | Should -Match 'vms/skip'
        $page | Should -Match 'askSkipVm'
        # AND IT MUST BE DRAWN. Mutation removed the button from the row and
        # this passed, because the function and the route were still in the
        # file - the sixth time in one day that a check matched a definition
        # while nothing painted it.
        $page | Should -Match '\$\{restoreBtn\}\$\{skipBtn\}'
        $page | Should -Match 'const skipBtn ='
    }
}

Describe 'SKIP-PREPARED-WORDS-1: where the stop left the machine, held to the fixture the run page uses' {
    # The dialog and Skip-VmfVm said "prepared" whenever the history held
    # GUEST_PREP. A rollback puts the first safety copy back, so on a machine
    # that rolled back that was false (lab walk 2026-10-31). The
    # engine records where each stop left the machine (machineState, FAIL-1);
    # both sides read that, and both are held to one list.
    BeforeAll {
        $script:cases = (Get-Content (Join-Path $PSScriptRoot '..' 'fixtures' 'skip-machine-state.json') -Raw | ConvertFrom-Json -Depth 20).cases
    }

    It 'the fixture loaded' { @($script:cases).Count | Should -BeGreaterOrEqual 12 }

    It 'every case: the engine gives the answer the fixture gives' {
        foreach ($c in @($script:cases)) {
            $got = InModuleScope VmMigrationFactory -Parameters @{ d = $c.doc } { Get-VmfSkipMachineState -Doc $d }
            $got | Should -Be $c.expected -Because $c.why
        }
    }

    It 'Skip-VmfVm says a machine that rolled back after its preparation is restored, not prepared' {
        $store = New-SkipStore -State 'GUEST_PREP'
        try {
            & (Get-Module VmMigrationFactory) { param($rp, $id)
                Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'FAILED_ROLLED_BACK' -Outcome fail -Detail 'rolled back' `
                    -ReasonCode 'bootFailedAfterConversion' -MachineState 'restored' | Out-Null } $store.Path $store.VmA
            $r = Skip-VmfVm -RunPath $store.Path -VmId $store.VmA -Reason 'later' -SkippedBy 'a@example.com' -Confirm:$false
            $r.MachineState | Should -Be 'restored'
            $r.PSObject.Properties.Name | Should -Not -Contain 'Prepared'
        }
        finally { Remove-Item $store.Path -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Skip-VmfVm says a machine whose rollback failed is changed' {
        $store = New-SkipStore -State 'GUEST_PREP'
        try {
            & (Get-Module VmMigrationFactory) { param($rp, $id)
                Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'FAILED_NEEDS_ATTENTION' -Outcome fail -Detail 'rollback failed' `
                    -ReasonCode 'rollbackFailed' -MachineState 'changed' | Out-Null } $store.Path $store.VmA
            (Skip-VmfVm -RunPath $store.Path -VmId $store.VmA -Reason 'later' -SkippedBy 'a@example.com' -Confirm:$false).MachineState |
                Should -Be 'changed'
        }
        finally { Remove-Item $store.Path -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Skip-VmfVm says a machine that has not started is untouched' {
        $store = New-SkipStore
        try {
            (Skip-VmfVm -RunPath $store.Path -VmId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm-b' `
                -Reason 'later' -SkippedBy 'a@example.com' -Confirm:$false).MachineState | Should -Be 'untouched'
        }
        finally { Remove-Item $store.Path -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
