#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# REACH-1 - reserving and releasing capacity from the app, and what happens to
# a wave's reservations when the wave ends.
#
# Ruled 2026-08-30: reserving is an explicit button (it bills from the
# moment the reservation exists, used or not); releasing is automatic at
# close-out, with a button for what that deliberately will not cover.
#
# The decision that needed care is WHICH waves release. "The wave stopped
# running" is not the same as "nothing in it needs capacity again": a machine
# parked on a decision, or rolled back awaiting a retry, still intends to
# migrate, and handing its guarantee back gives scarce capacity to somebody
# else and leaves the retry to chance.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:NewCloseOutClaim {
        param($RunPath, $Name, $State = 'RESERVED', $Wave = 'prod-1', $Sub = '00000000-0000-0000-0000-000000000000')
        $claim = [ordered]@{
            schemaVersion = 6; runId = 'r1'; wave = $Wave; subscriptionId = $Sub; resourceGroup = 'rg-app'
            region = 'centralus'; zone = $null; size = 'Standard_D2s_v6'
            vmFamily = 'StandardDsv6Family'; state = $State; blockReason = $null
            demand = @{ instances = 2; reservableInstances = 2; vcpus = 4; overlapWithSource = $false }
            quota = @{ limit = 10; used = 0; requestId = $null; requestedUtc = $null }
            reservation = @{ groupId = '/subs/s/rg/crg/g1'; reservationId = '/subs/s/rg/crg/g1/res/r1'
                             createdUtc = '2026-08-30T00:00:00Z'; releasedUtc = $null; consumedInstances = 0 }
            notes = @()
        }
        $dir = Join-Path $RunPath 'capacity'
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $claim | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $dir "$Name.json")
    }
    # Pure - no store, no Azure, no container.
    function Global:Finished {
        param($Counts, [bool]$Halted = $false)
        InModuleScope VmMigrationFactory -Parameters @{ c = [pscustomobject]$Counts; h = $Halted } {
            Test-VmfWaveFinished -StateCounts $c -Halted $h
        }
    }
    function Global:PickRg {
        param([string[]]$Ids)
        InModuleScope VmMigrationFactory -Parameters @{ ids = $Ids } {
            Select-VmfCellResourceGroup -VmIds $ids }
    }
    function Global:VmId {
        param($Rg, $Name)
        "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/$Rg/providers/Microsoft.Compute/virtualMachines/$Name"
    }
    function Global:WaveResult {
        param($Counts, [bool]$Halted = $false)
        [pscustomobject]@{ StateCounts = [pscustomobject]$Counts; Halted = $Halted }
    }
}
AfterAll {
    Remove-Item 'function:\NewCloseOutClaim', 'function:\WaveResult', 'function:\Finished', 'function:\PickRg', 'function:\VmId' -ErrorAction SilentlyContinue
}

Describe 'REACH-1: is the wave actually finished?' {
    It 'every machine migrated: finished' {
        (Finished @{ MIGRATED = 5 }).Finished | Should -BeTrue
    }

    It 'migrated and skipped together: finished' {
        # A skipped machine was never going to need the capacity.
        (Finished @{ MIGRATED = 3; SKIPPED = 2 }).Finished | Should -BeTrue
    }

    It 'a machine parked on a decision: NOT finished, and says which' {
        # This is the case that makes the whole check worth having. The wave
        # run ended, every worker went home, and one machine is waiting for a
        # person - it still intends to migrate.
        $v = Finished @{ MIGRATED = 4; NEEDS_DECISION = 1 }
        $v.Finished | Should -BeFalse
        $v.Reason | Should -Match 'NEEDS_DECISION'
    }

    It 'a machine rolled back: NOT finished' {
        # It is back on its original hardware and somebody will decide whether
        # to retry. Releasing now means the retry takes its chances.
        (Finished @{ MIGRATED = 4; FAILED_ROLLED_BACK = 1 }).Finished | Should -BeFalse
    }

    It 'a machine needing attention: NOT finished' {
        (Finished @{ MIGRATED = 4; FAILED_NEEDS_ATTENTION = 1 }).Finished | Should -BeFalse
    }

    It 'a halted wave is never finished, whatever the counts say' {
        $v = Finished @{ MIGRATED = 5 } $true
        $v.Finished | Should -BeFalse
        $v.Reason | Should -Match 'halted'
    }

    It 'a state with a count of zero does not count as unfinished' {
        # Status documents carry the whole state list, most of them at zero.
        (Finished @{ MIGRATED = 5; NEEDS_DECISION = 0; PRECHECK = 0 }).Finished | Should -BeTrue
    }

    It 'and the states it treats as settled come from the engine, not a copy' {
        # If a state is added to the machine, this must be a deliberate
        # decision about it rather than a list that quietly fell behind.
        InModuleScope VmMigrationFactory {
            $states = Get-VmfEngineStates
            foreach ($s in $script:VmfSettledStates) {
                $s | Should -BeIn $states.Terminal -Because 'a settled state must be a terminal state'
            }
        }
    }
}

Describe 'REACH-1: close-out gives finished waves their capacity back' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-close-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Initialize-VmfRun -RunPath $rp -RunId 'close-test' | Out-Null
        }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'a finished wave releases, and the event says Azure accepted the release' {
        NewCloseOutClaim -RunPath $script:runPath -Name 'c1'
        # The shape Remove-VmfCapacityReservations really returns. A list of
        # rows here hid that close-out counted the wrapper, not what it held.
        Mock -ModuleName VmMigrationFactory Remove-VmfCapacityReservations {
            [pscustomobject]@{ Released = @([pscustomobject]@{ Size = 'Standard_D2s_v6' }, [pscustomobject]@{ Size = 'Standard_E2s_v6' }); NotReleased = @() }
        }
        $r = Invoke-VmfWaveCloseOut -RunPath $script:runPath -Wave 'prod-1' `
            -Result (WaveResult @{ MIGRATED = 2 })
        $r.Action | Should -Be 'released'
        $r.Released | Should -Be 2
        Should -Invoke -ModuleName VmMigrationFactory Remove-VmfCapacityReservations -Times 1 -Exactly
        (Get-Content (Join-Path $script:runPath 'logs' 'events.jsonl') -Raw) | Should -Match "Wave 'prod-1' finished. The product released 2 on-demand capacity reservations, and Azure accepted the release."
    }

    It 'an unfinished wave HOLDS, and says so - held capacity must never be silent' {
        NewCloseOutClaim -RunPath $script:runPath -Name 'c1'
        Mock -ModuleName VmMigrationFactory Remove-VmfCapacityReservations { throw 'must not be called' }
        $r = Invoke-VmfWaveCloseOut -RunPath $script:runPath -Wave 'prod-1' `
            -Result (WaveResult @{ MIGRATED = 1; NEEDS_DECISION = 1 })
        $r.Action | Should -Be 'held'
        Should -Invoke -ModuleName VmMigrationFactory Remove-VmfCapacityReservations -Times 0 -Exactly
        $events = Get-Content (Join-Path $script:runPath 'logs' 'events.jsonl') -Raw
        # MANUAL-REVIEW-1 (2026-11-13): when it bills - until every machine of the wave has ended, or Release.
        $events | Should -Match 'keeps its 1 on-demand capacity reservation, and Azure bills them'
        $events | Should -Match 'The product releases them when every machine of the wave has ended. To release them now, select Release on the wave.'
    }

    It 'a wave that reserved nothing does nothing' {
        # A BestEffort wave never reserved. There is nothing to give back.
        $r = Invoke-VmfWaveCloseOut -RunPath $script:runPath -Wave 'prod-1' `
            -Result (WaveResult @{ MIGRATED = 2 })
        $r.Action | Should -Be 'none'
    }

    It 'a release that FAILS does not fail the wave, but is recorded loudly' {
        # The machines migrated. Close-out is cost hygiene, not the migration -
        # but this is the case that silently bills, so it is said as loudly as
        # the run store allows.
        NewCloseOutClaim -RunPath $script:runPath -Name 'c1'
        Mock -ModuleName VmMigrationFactory Remove-VmfCapacityReservations { throw 'ARM said no' }
        $r = Invoke-VmfWaveCloseOut -RunPath $script:runPath -Wave 'prod-1' `
            -Result (WaveResult @{ MIGRATED = 2 })
        $r.Action | Should -Be 'held'
        $events = Get-Content (Join-Path $script:runPath 'logs' 'events.jsonl') -Raw
        # MANUAL-REVIEW-1: a sentence that names the control, not capitals and a hand release.
        $events | Should -Match 'did not release its on-demand capacity reservations, and Azure bills them: ARM said no. Select Release on the wave.'
        $events | Should -Match 'ARM said no'
    }

    It 'only this wave is considered' {
        NewCloseOutClaim -RunPath $script:runPath -Name 'other' -Wave 'prod-2'
        $r = Invoke-VmfWaveCloseOut -RunPath $script:runPath -Wave 'prod-1' `
            -Result (WaveResult @{ MIGRATED = 2 })
        $r.Action | Should -Be 'none'
    }
}

Describe 'CAPRG-1: a reservation goes where its machines already are' {
    # The first version of this asked an operator to nominate ONE resource
    # group name that had to exist in every subscription being migrated. No
    # real estate can promise that, nothing in the app helped anybody set it
    # up, and it was a question that did not need asking: a VM attaches to a
    # reservation by its full resource id, so the reservation only has to share
    # the machines' subscription and region. The machines are already in a
    # resource group that exists. Use that one.
    It 'reads the resource group out of a machine id' {
        InModuleScope VmMigrationFactory {
            Get-VmfResourceGroupName -ResourceId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm1' |
                Should -Be 'rg-app'
        }
    }

    It 'an id with no resource group gives null, never a guess' {
        InModuleScope VmMigrationFactory {
            Get-VmfResourceGroupName -ResourceId '/subscriptions/00000000-0000-0000-0000-000000000000' | Should -BeNullOrEmpty
        }
    }

    It 'the ordinary case: every machine in one group' {
        (PickRg @((VmId 'rg-app' 'a'), (VmId 'rg-app' 'b'))) | Should -Be 'rg-app'
    }

    It 'machines spanning groups: the one holding the most of them wins' {
        (PickRg @((VmId 'rg-a' '1'), (VmId 'rg-b' '2'), (VmId 'rg-b' '3'))) | Should -Be 'rg-b'
    }

    It 'an exact tie is broken by name, so two runs choose the same group' {
        # Either would work - the reservation is usable from anywhere in the
        # subscription. This is about being predictable, not about being right.
        $ids = @((VmId 'rg-zebra' '1'), (VmId 'rg-alpha' '2'))
        (PickRg $ids) | Should -Be 'rg-alpha'
        (PickRg ($ids | Sort-Object -Descending)) | Should -Be 'rg-alpha'
    }

    It 'no usable id gives null rather than inventing a group' {
        (PickRg @('', $null)) | Should -BeNullOrEmpty
    }

    It 'the claim records which group it chose, so it is never a mystery' {
        InModuleScope VmMigrationFactory {
            $c = New-VmfCapacityClaim -RunId 'r1' -Wave 'w1' `
                -SubscriptionId '00000000-0000-0000-0000-000000000000' -ResourceGroup 'rg-app' `
                -Region 'centralus' -Size 'Standard_D2s_v6' -State 'PLANNED' `
                -Instances 2 -ReservableInstances 2 -Vcpus 4
            $c.resourceGroup | Should -Be 'rg-app'
            # Derived, so a bump is not a chore here. Pinning the number made
            # this a thing to edit rather than a thing that checks.
            $c.schemaVersion | Should -Be (Get-VmfCapacityClaimSchemaVersion)
        }
    }

    It 'and a claim with no resource group cannot be reserved from - it says so' {
        # Guessing one would put a reservation somewhere nobody would look for
        # it when it is billing. OLD-VERSION-READERS-REMOVE-5: the refusal no
        # longer says an earlier version wrote it.
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-old-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            InModuleScope VmMigrationFactory -Parameters @{ p = $rp } { Initialize-VmfRun -RunPath $p -RunId 'old' | Out-Null }
            NewCloseOutClaim -RunPath $rp -Name 'c1' -State 'QUOTA_VERIFIED'
            $f = Join-Path $rp 'capacity' 'c1.json'
            $doc = Get-Content $f -Raw | ConvertFrom-Json
            $doc.PSObject.Properties.Remove('resourceGroup')
            $doc | ConvertTo-Json -Depth 8 | Set-Content $f
            { New-VmfWaveReservation -OutPath $rp -Wave 'prod-1' } |
                Should -Throw '*does not say which resource group*so none was asked for. Check the quota of the wave again, then reserve.'
        }
        finally { if (Test-Path $rp) { Remove-Item $rp -Recurse -Force } }
    }
}

Describe 'REACH-1: the engine and the facade agree on the new operations' {
    BeforeAll {
        $script:entry = Get-Content (Join-Path $script:repoRoot 'docker' 'entrypoint.ps1') -Raw
        $script:core = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1') -Raw
    }

    It 'every operation the facade will dispatch, the engine can run' {
        # Two lists that must agree is one list too many - so compare them.
        $vs = [regex]::Match($script:core, "ValidateSet\('assess'(?s).*?\)\]\[string\]").Value
        $declared = @([regex]::Matches($vs, "'(\w+)'") | ForEach-Object { $_.Groups[1].Value })
        @($declared).Count | Should -BeGreaterThan 5
        $handled = @([regex]::Matches($script:entry, "(?m)^    '(\w+)' \{") | ForEach-Object { $_.Groups[1].Value })
        $missing = @($declared | Where-Object { $_ -notin $handled })
        $missing -join ', ' | Should -BeNullOrEmpty -Because 'the facade would start a job the engine throws on'
    }

    It 'the wave operation closes out its own capacity' {
        $waveBranch = [regex]::Match($script:entry, "(?s)'wave'\s*\{.*?\n    \}").Value
        $waveBranch | Should -Match 'Invoke-VmfWaveCloseOut'
    }

    It 'reserve and release both require a note, and the reserve reason names the cost' {
        $script:core | Should -Match "Operation -in @\('reserve', 'release'\)"
        $script:core | Should -Match 'bills from the moment it is reserved'
    }

    It 'CAPRG-1: nothing anywhere asks where reservations should go' {
        # The first version made this a setting - one resource group name that
        # had to exist in every subscription being migrated, which no real
        # estate can promise. A reservation goes in the resource group its own
        # machines are already in, so there is nothing to configure and this
        # test exists to keep it that way.
        $script:core | Should -Not -Match 'VMF_CAPACITY_RG'
        $script:entry | Should -Not -Match 'VMF_CAPACITY_RG'
        $script:entry | Should -Not -Match 'CapacityResourceGroup'
    }

    # REPORT-AUTO-1 REWROTE this. It held the report operation's sign-off to
    # the name on the token. That operation was removed on 2026-10-02:
    # the engine writes the report by itself and nobody signs it, so nothing
    # from a request can put a name into it at all.
    It 'nothing a caller sends can sign the report: there is no report operation and no sign-off field' {
        $script:core | Should -Not -Match "Operation -eq 'report'"
        $script:core | Should -Not -Match 'VMF_SIGNOFF_BY|VMF_SIGNOFF_NOTE|\$SignOffBy|\$SignOffNote'
    }
}
