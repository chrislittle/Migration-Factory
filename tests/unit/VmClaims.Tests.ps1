#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# RUN-CLAIM-1. Did the product check whether a VM is added to more than one
# run? It did not - and it was worse than a missing
# warning. Leases are written UNDER the run path, so exclusive-create fenced
# workers within one run and not at all between runs. Two runs could lease,
# deallocate and convert the SAME machine at once, each believing it held it
# exclusively, inside the deallocated window.
#
# The fix puts the claim BESIDE the runs rather than inside one: runs are
# prefixes in a single container, so a claim namespace at container level is
# reachable with the same primitive. The lease-time check is the real gate;
# the plan-time check exists only to tell somebody early.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:vm1 = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
    $script:vm2 = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm2'

    function Script:NewStore {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-claims-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $root
    }
}

Describe 'RUN-CLAIM-1: the claim lives beside the runs, not inside one' {
    It 'two runs in the same store resolve to the SAME claim scope' {
        InModuleScope VmMigrationFactory {
            $a = Get-VmfClaimScopePath -RunPath 'azblob://acct/vmf-runs/run-a'
            $b = Get-VmfClaimScopePath -RunPath 'azblob://acct/vmf-runs/run-b'
            $a | Should -Be $b -Because 'a claim that lives inside a run cannot fence another run'
            $a | Should -Match 'azblob://acct/vmf-runs/'
        }
    }

    It 'works for a local store too' {
        InModuleScope VmMigrationFactory {
            $a = Get-VmfClaimScopePath -RunPath 'C:\runs\run-a'
            $b = Get-VmfClaimScopePath -RunPath 'C:\runs\run-b'
            $a | Should -Be $b
        }
    }
}

Describe 'RUN-CLAIM-1: one machine, one run' {
    BeforeEach {
        $script:store = Script:NewStore
        $script:runA = Join-Path $script:store 'run-a'
        $script:runB = Join-Path $script:store 'run-b'
        foreach ($r in $script:runA, $script:runB) {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $r } { Initialize-VmfRun -RunPath $rp -RunId (Split-Path $rp -Leaf) | Out-Null }
        }
    }
    AfterEach { if (Test-Path $script:store) { Remove-Item $script:store -Recurse -Force } }

    It 'the first run claims a machine and the second is refused, by name' {
        InModuleScope VmMigrationFactory -Parameters @{ a = $script:runA; b = $script:runB; vm = $script:vm1 } {
            (New-VmfVmClaim -RunPath $a -VmId $vm -RunId 'run-a').Granted | Should -BeTrue
            $second = New-VmfVmClaim -RunPath $b -VmId $vm -RunId 'run-b'
            $second.Granted | Should -BeFalse
            $second.HeldBy | Should -Be 'run-a' -Because 'the refusal must say WHICH run holds it'
        }
    }

    It 'a run re-claiming its own machine is fine - claiming is idempotent' {
        InModuleScope VmMigrationFactory -Parameters @{ a = $script:runA; vm = $script:vm1 } {
            New-VmfVmClaim -RunPath $a -VmId $vm -RunId 'run-a' | Out-Null
            (New-VmfVmClaim -RunPath $a -VmId $vm -RunId 'run-a').Granted | Should -BeTrue
        }
    }

    It 'releasing lets another run have it' {
        InModuleScope VmMigrationFactory -Parameters @{ a = $script:runA; b = $script:runB; vm = $script:vm1 } {
            New-VmfVmClaim -RunPath $a -VmId $vm -RunId 'run-a' | Out-Null
            Remove-VmfVmClaim -RunPath $a -VmId $vm -RunId 'run-a' | Out-Null
            (New-VmfVmClaim -RunPath $b -VmId $vm -RunId 'run-b').Granted | Should -BeTrue
        }
    }

    It 'a run cannot release a claim it does not hold' {
        # Otherwise "release everything" in run B quietly unfences run A.
        InModuleScope VmMigrationFactory -Parameters @{ a = $script:runA; b = $script:runB; vm = $script:vm1 } {
            New-VmfVmClaim -RunPath $a -VmId $vm -RunId 'run-a' | Out-Null
            (Remove-VmfVmClaim -RunPath $b -VmId $vm -RunId 'run-b').Released | Should -BeFalse
            (Get-VmfVmClaim -RunPath $b -VmId $vm).runId | Should -Be 'run-a'
        }
    }

    It 'an operator CAN take it deliberately, and the taking is recorded' {
        # Without this an abandoned run holds machines hostage - the exact
        # risk named for discard.
        InModuleScope VmMigrationFactory -Parameters @{ a = $script:runA; b = $script:runB; vm = $script:vm1 } {
            New-VmfVmClaim -RunPath $a -VmId $vm -RunId 'run-a' | Out-Null
            $stolen = New-VmfVmClaim -RunPath $b -VmId $vm -RunId 'run-b' -Force -TakenBy 'operator'
            $stolen.Granted | Should -BeTrue
            $claim = Get-VmfVmClaim -RunPath $b -VmId $vm
            $claim.runId | Should -Be 'run-b'
            $claim.takenFrom | Should -Be 'run-a'
            $claim.takenBy | Should -Be 'operator'
        }
    }
}

Describe 'RUN-CLAIM-1: planning tells you early, leasing is the gate' {
    BeforeEach {
        $script:store = Script:NewStore
        $script:runA = Join-Path $script:store 'run-a'
        $script:runB = Join-Path $script:store 'run-b'
        foreach ($r in $script:runA, $script:runB) {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $r } { Initialize-VmfRun -RunPath $rp -RunId (Split-Path $rp -Leaf) | Out-Null }
        }
    }
    AfterEach { if (Test-Path $script:store) { Remove-Item $script:store -Recurse -Force } }

    It 'a plan-time check names every machine another run already holds' {
        InModuleScope VmMigrationFactory -Parameters @{ a = $script:runA; b = $script:runB; vm1 = $script:vm1; vm2 = $script:vm2 } {
            New-VmfVmClaim -RunPath $a -VmId $vm1 -RunId 'run-a' | Out-Null
            $entries = @([pscustomobject]@{ vmId = $vm1 }, [pscustomobject]@{ vmId = $vm2 })
            $r = Test-VmfVmClaims -RunPath $b -Entries $entries -RunId 'run-b'
            $r.Pass | Should -BeFalse
            @($r.Conflicts).Count | Should -Be 1
            @($r.Conflicts)[0].HeldBy | Should -Be 'run-a'
            $r.Detail | Should -Match 'vm1'
            $r.Detail | Should -Match 'run-a'
        }
    }

    It 'the worker refuses to lease a machine another run holds - the real gate' {
        InModuleScope VmMigrationFactory -Parameters @{ a = $script:runA; b = $script:runB; vm = $script:vm1 } {
            New-VmfVmClaim -RunPath $a -VmId $vm -RunId 'run-a' | Out-Null
            $plan = [pscustomobject]@{ entries = @([pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $vm; wave = 'w1'; path = 'A' }) }
            New-VmfStateDoc -RunPath $b -RunId 'run-b' -VmId $vm -Wave 'w1' | Out-Null
            $claim = Get-VmfNextWaveVm -RunPath $b -Plan $plan -Wave 'w1' -WorkerId 'w'
            $claim | Should -BeNullOrEmpty -Because 'a wizard-level check is not a gate; this is where two runs would collide'
        }
    }

    It 'and it DOES lease a machine no other run holds' {
        InModuleScope VmMigrationFactory -Parameters @{ b = $script:runB; vm = $script:vm2 } {
            $plan = [pscustomobject]@{ entries = @([pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $vm; wave = 'w1'; path = 'A' }) }
            New-VmfStateDoc -RunPath $b -RunId 'run-b' -VmId $vm -Wave 'w1' | Out-Null
            $claim = Get-VmfNextWaveVm -RunPath $b -Plan $plan -Wave 'w1' -WorkerId 'w'
            $claim | Should -Not -BeNullOrEmpty
            $claim.Entry.vmId | Should -Be $vm
        }
    }
}

Describe 'RUN-CLAIM-1: a deleted run does not keep its machines forever' {
    It 'a claim whose run no longer exists is reclaimed, and the taking is recorded' {
        # Found by the multi-process worker test: claims live BESIDE the runs,
        # so deleting a run leaves its claims behind. Without this the machine
        # is held by something that cannot possibly still be migrating it -
        # the hostage problem named for discard, in its purest form.
        $store = Script:NewStore
        try {
            $runA = Join-Path $store 'run-a'
            $runB = Join-Path $store 'run-b'
            foreach ($r in $runA, $runB) {
                InModuleScope VmMigrationFactory -Parameters @{ rp = $r } { Initialize-VmfRun -RunPath $rp -RunId (Split-Path $rp -Leaf) | Out-Null }
            }
            InModuleScope VmMigrationFactory -Parameters @{ a = $runA; vm = $script:vm1 } {
                New-VmfVmClaim -RunPath $a -VmId $vm -RunId 'run-a' | Out-Null
            }
            Remove-Item $runA -Recurse -Force        # the run is gone; its claim is not

            InModuleScope VmMigrationFactory -Parameters @{ b = $runB; vm = $script:vm1 } {
                $r = New-VmfVmClaim -RunPath $b -VmId $vm -RunId 'run-b'
                $r.Granted | Should -BeTrue
                $r.Detail | Should -Match 'no longer exists'
                (Get-VmfVmClaim -RunPath $b -VmId $vm).takenFrom | Should -Be 'run-a'
            }
        }
        finally { if (Test-Path $store) { Remove-Item $store -Recurse -Force } }
    }

    It 'but a LIVE run still holds its machines' {
        $store = Script:NewStore
        try {
            $runA = Join-Path $store 'run-a'; $runB = Join-Path $store 'run-b'
            foreach ($r in $runA, $runB) {
                InModuleScope VmMigrationFactory -Parameters @{ rp = $r } { Initialize-VmfRun -RunPath $rp -RunId (Split-Path $rp -Leaf) | Out-Null }
            }
            InModuleScope VmMigrationFactory -Parameters @{ a = $runA; b = $runB; vm = $script:vm1 } {
                New-VmfVmClaim -RunPath $a -VmId $vm -RunId 'run-a' | Out-Null
                (New-VmfVmClaim -RunPath $b -VmId $vm -RunId 'run-b').Granted | Should -BeFalse
            }
        }
        finally { if (Test-Path $store) { Remove-Item $store -Recurse -Force } }
    }
}

Describe 'RUN-CLAIM-1: the two checks never disagree' {
    It 'a dead holder is not a plan-time conflict either' {
        # If planning refused where leasing would grant, an operator would go
        # hunting for a run that no longer exists.
        $store = Script:NewStore
        try {
            $runA = Join-Path $store 'run-a'; $runB = Join-Path $store 'run-b'
            foreach ($r in $runA, $runB) {
                InModuleScope VmMigrationFactory -Parameters @{ rp = $r } { Initialize-VmfRun -RunPath $rp -RunId (Split-Path $rp -Leaf) | Out-Null }
            }
            InModuleScope VmMigrationFactory -Parameters @{ a = $runA; vm = $script:vm1 } {
                New-VmfVmClaim -RunPath $a -VmId $vm -RunId 'run-a' | Out-Null
            }
            Remove-Item $runA -Recurse -Force
            InModuleScope VmMigrationFactory -Parameters @{ b = $runB; vm = $script:vm1 } {
                $r = Test-VmfVmClaims -RunPath $b -Entries @([pscustomobject]@{ vmId = $vm }) -RunId 'run-b'
                $r.Pass | Should -BeTrue
            }
        }
        finally { if (Test-Path $store) { Remove-Item $store -Recurse -Force } }
    }

    It 'a claim with no recorded path is treated as LIVE - unknown never opens the gate' {
        $store = Script:NewStore
        try {
            $runB = Join-Path $store 'run-b'
            InModuleScope VmMigrationFactory -Parameters @{ rp = $runB } { Initialize-VmfRun -RunPath $rp -RunId 'run-b' | Out-Null }
            InModuleScope VmMigrationFactory -Parameters @{ b = $runB; vm = $script:vm1 } {
                $scope = Get-VmfClaimScopePath -RunPath $b
                Write-VmfStoreJson -RunPath $scope -RelPath (Get-VmfClaimRelPath -VmId $vm) -Depth 6 `
                    -Document ([ordered]@{ schemaVersion = 1; vmId = $vm; runId = 'legacy-run' })
                (New-VmfVmClaim -RunPath $b -VmId $vm -RunId 'run-b').Granted | Should -BeFalse
            }
        }
        finally { if (Test-Path $store) { Remove-Item $store -Recurse -Force } }
    }
}
