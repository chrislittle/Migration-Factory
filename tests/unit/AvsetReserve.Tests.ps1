#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# AVSET-RESERVE-1, 2026-10-03. Capacity reservations and availability sets.
#
# Azure cannot put a machine in an availability set on a capacity reservation,
# and CAP-2 already reserves only the other machines of a cell. Three defects
# came from the parts of the product that did not know that:
#
#   A. A wave set to Reserved with one ordinary cell and one cell of only
#      availability-set machines could never start. The ordinary cell became
#      RESERVED and billed; the other stayed QUOTA_VERIFIED, and the gate
#      wanted EVERY claim RESERVED.
#   B. A Reserved wave of only availability-set machines was a dead end: the
#      refusal said "reserve capacity", and Reserve did nothing.
#   C. The wave editor looked for a phrase that only the claim note carried,
#      so it said "still running" for an answer that had already come.
#
# The rule now: a claim with nothing reservable is judged as BestEffort judges
# it (its quota check stays), and its machines move on general capacity, said
# in the log. Only claims with reservable demand need RESERVED.
#
# THESE TESTS RUN THE FUNCTIONS. The page half is held to the same events by
# tests/fixtures/reserve-nothing-events.json.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    # A claim as the engine judges it. -Reservable $null leaves the field out,
    # the shape of a schemaVersion 1 claim written before CAP-2.
    function Global:AvClaim {
        param([string]$State = 'QUOTA_VERIFIED', [int]$Instances = 2, $Reservable = 2,
              [string]$Size = 'Standard_D2s_v6', [string]$Wave = 'wave-1', [string]$BlockReason)
        $demand = [ordered]@{ instances = $Instances; vcpus = 2 * $Instances }
        if ($null -ne $Reservable) { $demand.reservableInstances = [int]$Reservable }
        $c = [pscustomobject]@{ wave = $Wave; size = $Size; region = 'centralus'; state = $State
                                demand = [pscustomobject]$demand; notes = @() }
        if ($BlockReason) { $c | Add-Member blockReason $BlockReason }
        $c
    }

    # A claim on disk, in the shape New-VmfWaveReservation reads.
    function Global:AvStoreClaim {
        param($RunPath, $Name, [int]$Instances, [int]$Reservable, [string]$State = 'QUOTA_VERIFIED',
              [string]$Wave = 'wave-1', [string]$Size = 'Standard_D2s_v6')
        $claim = [ordered]@{
            schemaVersion = 10; runId = 'r1'; wave = $Wave
            subscriptionId = '00000000-0000-0000-0000-000000000000'; resourceGroup = 'rg-app'
            region = 'centralus'; zone = $null; size = $Size; vmFamily = 'StandardDsv6Family'
            state = $State; blockReason = $null
            demand = @{ instances = $Instances; reservableInstances = $Reservable; vcpus = 2 * $Instances; overlapWithSource = $false }
            quota = @{ limit = 100; used = 0; requestId = $null; requestedUtc = $null }
            notes = @()
        }
        if ($State -eq 'RESERVED') {
            $claim.reservation = @{ groupId = '/g'; reservationId = '/g/r'; createdUtc = 'x'; releasedUtc = $null; consumedInstances = 0 }
        }
        $dir = Join-Path $RunPath 'capacity'
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $claim | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $dir "$Name.json")
    }

    # A plan entry of wave-1: in an availability set with -Avset, else not.
    function Global:AvEntry {
        param([switch]$Avset, [string]$Name = "vm-$([guid]::NewGuid().ToString('N').Substring(0,6))", [string]$Size = 'Standard_D2s_v6')
        [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion);
            vmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$Name"
            wave = 'wave-1'; path = 'A'
            assessment = [pscustomobject]@{ location = 'centralus'; availabilitySetId = $(if ($Avset) { '/avsets/pair' } else { '' }) }
            target = [pscustomobject]@{ size = $Size }
            policy = [pscustomobject]@{ capacityGate = 'Reserved'; requireApproval = $false }
        }
    }
    function Global:AvWritePlan {
        param($RunPath, $Entries)
        $planPath = Join-Path $RunPath 'plan.json'
        @{ schemaVersion = 1; assessmentRunId = 'avres'; entries = @($Entries) } |
            ConvertTo-Json -Depth 10 | Set-Content $planPath -Encoding utf8NoBOM
        $planPath
    }

    $script:fixture = Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' 'reserve-nothing-events.json') -Raw |
        ConvertFrom-Json
}
AfterAll {
    Remove-Item 'function:\AvClaim' -ErrorAction SilentlyContinue
    Remove-Item 'function:\AvStoreClaim' -ErrorAction SilentlyContinue
    Remove-Item 'function:\AvEntry' -ErrorAction SilentlyContinue
    Remove-Item 'function:\AvWritePlan' -ErrorAction SilentlyContinue
}

Describe 'AVSET-RESERVE-1: which claims need a reservation' {

    It 'a claim that says it has no reservable machine does not' {
        InModuleScope VmMigrationFactory {
            Test-VmfClaimReservable -Claim (AvClaim -Instances 2 -Reservable 0) | Should -BeFalse
        }
    }

    It 'a claim with any reservable machine does' {
        InModuleScope VmMigrationFactory {
            Test-VmfClaimReservable -Claim (AvClaim -Instances 3 -Reservable 1) | Should -BeTrue
        }
    }

    It 'rule case <value>: reservable = <reservable> (the same cases the page is held to)' -ForEach @(
        (Get-Content (Join-Path $PSScriptRoot '..' 'fixtures' 'reserve-nothing-events.json') -Raw | ConvertFrom-Json).rules |
            ForEach-Object { @{ value = $(if ($null -eq $_.reservableInstances) { 'null' } else { "$($_.reservableInstances)" }); rule = $_; reservable = [bool]$_.reservable } }
    ) {
        $demand = [ordered]@{ instances = 2 }
        if (-not ($rule.reservableInstances -is [string] -and $rule.reservableInstances -eq 'missing')) {
            $demand.reservableInstances = $rule.reservableInstances
        }
        $claim = [pscustomobject]@{ wave = 'w'; state = 'QUOTA_VERIFIED'; demand = [pscustomobject]$demand }
        InModuleScope VmMigrationFactory -Parameters @{ c = $claim; want = [bool]$rule.reservable } {
            Test-VmfClaimReservable -Claim $c | Should -Be $want
        }
    }

    It 'the rule cases were read, so the cases above are not an empty list' {
        @($script:fixture.rules).Count | Should -BeGreaterThan 10
    }

    It 'a claim that does not say - written before CAP-2, or with no demand - does, because unknown is not a no' {
        InModuleScope VmMigrationFactory {
            Test-VmfClaimReservable -Claim (AvClaim -Reservable $null) | Should -BeTrue
            Test-VmfClaimReservable -Claim ([pscustomobject]@{ wave = 'w'; state = 'QUOTA_VERIFIED' }) | Should -BeTrue
        }
    }
}

Describe 'AVSET-RESERVE-1 (A): the Reserved gate judges only claims with reservable demand' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-avres-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Initialize-VmfRun -RunPath $rp -RunId 'avres' | Out-Null }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'a reserved cell beside an availability-set-only cell PASSES - the defect: it never could' {
        AvStoreClaim -RunPath $script:runPath -Name 'a-avset' -Instances 2 -Reservable 0
        AvStoreClaim -RunPath $script:runPath -Name 'b-open' -Instances 1 -Reservable 1 -State 'RESERVED'
        # RESERVE-COVER-1: a Reserved gate judges the plan's machines too, so it
        # is given them; with no plan to read it is not a pass.
        $r = Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'wave-1' -Gate 'Reserved' -Entries @(AvEntry -Avset; AvEntry)
        $r.Pass | Should -BeTrue -Because $r.Detail
        $r.Detail | Should -Match 'no capacity reservation'
    }

    It 'an ordinary cell that is NOT reserved still fails, and the detail names only that cell' {
        AvStoreClaim -RunPath $script:runPath -Name 'a-avset' -Instances 2 -Reservable 0 -Size 'Standard_E2s_v6'
        AvStoreClaim -RunPath $script:runPath -Name 'b-open' -Instances 1 -Reservable 1
        # RESERVE-COVER-1: given the plan's machines, as the start gives them.
        $r = Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'wave-1' -Gate 'Reserved' `
            -Entries @(AvEntry -Avset -Size 'Standard_E2s_v6'; AvEntry)
        $r.Pass | Should -BeFalse
        $r.Detail | Should -Match 'Standard_D2s_v6'
        $r.Detail | Should -Not -Match 'Standard_E2s_v6'
    }

    It 'a wave of only availability-set cells passes on its quota checks, when the plan agrees' {
        AvStoreClaim -RunPath $script:runPath -Name 'a-avset' -Instances 2 -Reservable 0
        AvStoreClaim -RunPath $script:runPath -Name 'b-avset' -Instances 1 -Reservable 0 -Size 'Standard_E2s_v6'
        # RESERVE-COVER-1: a record is judged only while its cell holds a machine
        # that will move, so the plan holds a machine of each size.
        $r = Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'wave-1' -Gate 'Reserved' `
            -Entries @(AvEntry -Avset; AvEntry -Avset -Size 'Standard_E2s_v6')
        $r.Pass | Should -BeTrue -Because $r.Detail
        $r.GeneralCapacityClaims | Should -Be 2
    }

    It 'but not when the plan has a machine outside an availability set with no claim (review finding 1)' {
        AvStoreClaim -RunPath $script:runPath -Name 'a-avset' -Instances 2 -Reservable 0
        $r = Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'wave-1' -Gate 'Reserved' -Entries @(AvEntry -Avset; AvEntry)
        $r.Pass | Should -BeFalse
        # RESERVE-COVER-1 took this check over: the machine with no record is
        # named, with its size, for any wave - not only an all-availability-set one.
        $r.Detail | Should -Match 'no quota record'
        $r.Uncovered[0].Size | Should -Be 'Standard_D2s_v6'
    }

    It 'a plan that cannot be read - not a plan this build reads - is not a pass either' {
        AvStoreClaim -RunPath $script:runPath -Name 'a-avset' -Instances 2 -Reservable 0
        Set-Content -Path (Join-Path $script:runPath 'plan.json') -Value '{ "schemaVersion": 1, "entries": [ broken' -Encoding utf8NoBOM
        $r = Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'wave-1' -Gate 'Reserved'
        $r.Pass | Should -BeFalse -Because $r.Detail
        $r.Detail | Should -Match 'could not be read'
    }

    It 'with no entries given it reads the plan of the run, and an unread plan is not a pass' {
        AvStoreClaim -RunPath $script:runPath -Name 'a-avset' -Instances 2 -Reservable 0
        $r = Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'wave-1' -Gate 'Reserved'
        $r.Pass | Should -BeFalse -Because 'there is no plan in this run to confirm it'
        AvWritePlan -RunPath $script:runPath -Entries @(AvEntry -Avset)
        (Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'wave-1' -Gate 'Reserved').Pass | Should -BeTrue
        AvWritePlan -RunPath $script:runPath -Entries @(AvEntry -Avset; AvEntry)
        (Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'wave-1' -Gate 'Reserved').Pass | Should -BeFalse
    }

    It 'but the quota check for those machines stays: a blocked availability-set cell still fails' {
        AvStoreClaim -RunPath $script:runPath -Name 'a-avset' -Instances 2 -Reservable 0 -State 'BLOCKED' -Size 'Standard_E2s_v6'
        AvStoreClaim -RunPath $script:runPath -Name 'b-open' -Instances 1 -Reservable 1 -State 'RESERVED'
        $r = Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'wave-1' -Gate 'Reserved' `
            -Entries @(AvEntry -Avset -Size 'Standard_E2s_v6'; AvEntry)
        $r.Pass | Should -BeFalse
        $r.Detail | Should -Match 'BLOCKED'
    }

    It 'BestEffort judges every machine on its quota check, an availability-set machine like any other' {
        # RESERVE-COVER-2 rewrote this test. It gave the gate two records of
        # ONE cell and no plan, and passed because BestEffort judged only the
        # records. BestEffort now asks the plan which machines move - a gate
        # with no plan to read is not a pass - so the machines are given, each
        # with a record of its own cell.
        AvStoreClaim -RunPath $script:runPath -Name 'a-avset' -Instances 2 -Reservable 0 -Size 'Standard_E2s_v6'
        AvStoreClaim -RunPath $script:runPath -Name 'b-open' -Instances 1 -Reservable 1
        $e = @(AvEntry -Avset -Size 'Standard_E2s_v6'; AvEntry -Avset -Size 'Standard_E2s_v6'; AvEntry)
        $r = Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'wave-1' -Gate 'BestEffort' -Entries $e
        $r.Pass | Should -BeTrue -Because $r.Detail
        $r.GeneralCapacityClaims | Should -Be 0 -Because 'BestEffort reserves nothing, so no claim is set apart as general capacity'
    }
}

Describe 'AVSET-RESERVE-1 (B): the refusal is never a dead end' {

    It 'a wave of only availability-set claims is not refused - it starts on general capacity' {
        InModuleScope VmMigrationFactory {
            Get-VmfReservedCapacityRefusal -Wave 'wave-1' -ReservableMachines 0 -Claims @(
                AvClaim -Instances 2 -Reservable 0
                AvClaim -Instances 1 -Reservable 0 -Size 'Standard_E2s_v6') | Should -BeNullOrEmpty
        }
    }

    It 'but NOT when the plan has a machine outside an availability set - the claims can be a partial set (review finding 1)' {
        # A quota check stopped half way, or another container still writing:
        # only the availability-set cell exists yet. Judging from it alone
        # would start the ordinary machines with no reservation.
        InModuleScope VmMigrationFactory {
            Get-VmfReservedCapacityRefusal -Wave 'wave-1' -ReservableMachines 1 -Claims @(
                AvClaim -Instances 2 -Reservable 0) | Should -Match 'no capacity has been reserved'
        }
    }

    It 'and not when the plan was not asked - unknown is not general capacity' {
        InModuleScope VmMigrationFactory {
            Get-VmfReservedCapacityRefusal -Wave 'wave-1' -Claims @(
                AvClaim -Instances 2 -Reservable 0) | Should -Match 'no capacity has been reserved'
        }
    }

    It 'a wave with an ordinary claim nobody reserved is still told to reserve' {
        InModuleScope VmMigrationFactory {
            $said = Get-VmfReservedCapacityRefusal -Wave 'wave-1' -Claims @(
                AvClaim -Instances 2 -Reservable 0
                AvClaim -Instances 1 -Reservable 1)
            $said | Should -Match 'no capacity has been reserved'
        }
    }

    It 'a blocked availability-set claim is not reported as a reservation that failed' {
        # It never asked for one. Its quota answer is the BestEffort gate's to give.
        InModuleScope VmMigrationFactory {
            $said = Get-VmfReservedCapacityRefusal -Wave 'wave-1' -Claims @(
                AvClaim -Instances 2 -Reservable 0 -State 'BLOCKED' -BlockReason 'quota-shortfall'
                AvClaim -Instances 1 -Reservable 1)
            $said | Should -Not -Match 'did not work'
            $said | Should -Match 'no capacity has been reserved'
        }
    }

    It 'no claims at all is still "nobody asked" - unknown is not general capacity' {
        InModuleScope VmMigrationFactory {
            Get-VmfReservedCapacityRefusal -Wave 'wave-1' -Claims @() | Should -Match 'no capacity has been reserved'
        }
    }
}

Describe 'AVSET-RESERVE-1: the start says which machines move on general capacity' {

    It 'every machine in an availability set: says so, and that the wave starts without a reservation' {
        InModuleScope VmMigrationFactory {
            $note = Get-VmfReservedGeneralNote -Wave 'wave-1' -ReservableMachines 0 -Claims @(
                AvClaim -Instances 2 -Reservable 0
                AvClaim -Instances 1 -Reservable 0)
            $note | Should -Match 'every machine'
            $note | Should -Match 'no on-demand capacity reservation'
            # Said of every machine only when the plan says so.
            Get-VmfReservedGeneralNote -Wave 'wave-1' -ReservableMachines 1 -Claims @(AvClaim -Instances 2 -Reservable 0) |
                Should -Not -Match 'every machine'
        }
    }

    It 'a mixed wave counts the machines that move on general capacity' {
        InModuleScope VmMigrationFactory {
            $note = Get-VmfReservedGeneralNote -Wave 'wave-1' -Claims @(
                AvClaim -Instances 2 -Reservable 0
                AvClaim -Instances 3 -Reservable 2 -State 'RESERVED')
            $note | Should -Match '\b3\b'
            $note | Should -Match 'no on-demand capacity reservation'
            $note | Should -Not -Match 'every machine'
        }
    }

    It 'a wave with no availability-set machine says nothing' {
        InModuleScope VmMigrationFactory {
            Get-VmfReservedGeneralNote -Wave 'wave-1' -Claims @(AvClaim -Instances 2 -Reservable 2 -State 'RESERVED') |
                Should -BeNullOrEmpty
            Get-VmfReservedGeneralNote -Wave 'wave-1' -Claims @(AvClaim -Reservable $null) | Should -BeNullOrEmpty
        }
    }
}

Describe 'AVSET-RESERVE-1: Reserve on availability-set cells' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-avres-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Initialize-VmfRun -RunPath $rp -RunId 'avres' | Out-Null }
        Mock -ModuleName VmMigrationFactory New-VmfCapacityReservation { @{ GroupId = '/g'; ReservationId = '/g/r' } }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'the note goes on the claim ONCE however often Reserve is pressed' {
        AvStoreClaim -RunPath $script:runPath -Name 'a-avset' -Instances 2 -Reservable 0
        1..3 | ForEach-Object { New-VmfWaveReservation -OutPath $script:runPath -Wave 'wave-1' | Out-Null }
        $claim = Get-Content (Join-Path $script:runPath 'capacity' 'a-avset.json') -Raw | ConvertFrom-Json
        @($claim.notes | Where-Object { $_ -match 'availability set' }).Count | Should -Be 1
        $claim.state | Should -Be 'QUOTA_VERIFIED'
    }

    It 'says in its result that the wave had nothing to reserve' {
        AvStoreClaim -RunPath $script:runPath -Name 'a-avset' -Instances 2 -Reservable 0
        (New-VmfWaveReservation -OutPath $script:runPath -Wave 'wave-1').NothingReservable | Should -BeTrue
    }

    It 'and does not say it of a wave that also has a reservable cell' {
        AvStoreClaim -RunPath $script:runPath -Name 'a-avset' -Instances 2 -Reservable 0
        AvStoreClaim -RunPath $script:runPath -Name 'b-open' -Instances 1 -Reservable 1
        (New-VmfWaveReservation -OutPath $script:runPath -Wave 'wave-1').NothingReservable | Should -BeFalse
    }

    It 'a wave with no records is checked even when ANOTHER wave has records (review finding 2)' {
        # Choosing Reserved clears only this wave's records. Deriving only when
        # the whole run had none left this wave with nothing done and nothing
        # said, and the page waited five minutes for an answer.
        AvStoreClaim -RunPath $script:runPath -Name 'z-other' -Instances 1 -Reservable 1 -Wave 'wave-2'
        Mock -ModuleName VmMigrationFactory Test-VmfQuota {
            AvStoreClaim -RunPath $script:runPath -Name 'a-avset' -Instances 2 -Reservable 0
        }
        $r = New-VmfWaveReservation -OutPath $script:runPath -Wave 'wave-1'
        Should -Invoke -ModuleName VmMigrationFactory Test-VmfQuota -Times 1 -Exactly -ParameterFilter { $Wave -eq 'wave-1' }
        $r.NothingReservable | Should -BeTrue
    }

    It 'and a wave that still has no records after the check says there is nothing to reserve' {
        AvStoreClaim -RunPath $script:runPath -Name 'z-other' -Instances 1 -Reservable 1 -Wave 'wave-2'
        Mock -ModuleName VmMigrationFactory Test-VmfQuota { }
        { New-VmfWaveReservation -OutPath $script:runPath -Wave 'wave-1' } | Should -Throw "*wave 'wave-1'*nothing*to reserve*"
        Should -Invoke -ModuleName VmMigrationFactory New-VmfCapacityReservation -Times 0 -Exactly
    }

    It 'a cell blocked on QUOTA stops the whole wave being reserved - it cannot start, so a reservation bills for nothing (review finding 4)' {
        AvStoreClaim -RunPath $script:runPath -Name 'a-avset' -Instances 2 -Reservable 0 -State 'BLOCKED'
        AvStoreClaim -RunPath $script:runPath -Name 'b-open' -Instances 1 -Reservable 1
        $r = New-VmfWaveReservation -OutPath $script:runPath -Wave 'wave-1'
        Should -Invoke -ModuleName VmMigrationFactory New-VmfCapacityReservation -Times 0 -Exactly
        $r.Refused | Should -Match 'quota check is blocked'
        $r.NothingReservable | Should -BeFalse
        $said = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            @(Read-VmfEvents -RunPath $rp -Step 'odcr' | Where-Object { $_.outcome -eq 'refused' })
        }
        @($said).Count | Should -Be 1
        $said[0].wave | Should -Be 'wave-1'
        (Get-Content (Join-Path $script:runPath 'capacity' 'b-open.json') -Raw | ConvertFrom-Json).state | Should -Be 'QUOTA_VERIFIED'
    }

    It 'a record that does not say how many machines it holds stops the wave BEFORE anything is reserved' {
        # Found in review of this change: a throw inside the loop would have
        # stopped after the first cell was reserved, skipping all-or-nothing.
        AvStoreClaim -RunPath $script:runPath -Name 'a-open' -Instances 1 -Reservable 1
        AvStoreClaim -RunPath $script:runPath -Name 'b-uncounted' -Instances 1 -Reservable 1 -Size 'Standard_E2s_v6'
        $path = Join-Path $script:runPath 'capacity' 'b-uncounted.json'
        $doc = Get-Content $path -Raw | ConvertFrom-Json
        $doc.demand = [pscustomobject]@{ vcpus = 2 }
        $doc | ConvertTo-Json -Depth 8 | Set-Content $path
        $r = New-VmfWaveReservation -OutPath $script:runPath -Wave 'wave-1'
        $r.Refused | Should -Match 'does not say how many machines'
        Should -Invoke -ModuleName VmMigrationFactory New-VmfCapacityReservation -Times 0 -Exactly
    }

    It 'but a cell blocked by a reservation that failed is left to the all-or-nothing rule, as before' {
        AvStoreClaim -RunPath $script:runPath -Name 'a-failed' -Instances 1 -Reservable 1 -State 'BLOCKED' -Size 'Standard_E2s_v6'
        $path = Join-Path $script:runPath 'capacity' 'a-failed.json'
        $doc = Get-Content $path -Raw | ConvertFrom-Json
        $doc.blockReason = 'reservation-failed'
        $doc | ConvertTo-Json -Depth 8 | Set-Content $path
        AvStoreClaim -RunPath $script:runPath -Name 'b-open' -Instances 1 -Reservable 1
        $r = New-VmfWaveReservation -OutPath $script:runPath -Wave 'wave-1'
        $r.Refused | Should -BeNullOrEmpty
        Should -Invoke -ModuleName VmMigrationFactory New-VmfCapacityReservation -Times 1 -Exactly
    }

    It 'a reservable cell of ANOTHER wave does not change this wave''s answer' {
        AvStoreClaim -RunPath $script:runPath -Name 'a-avset' -Instances 2 -Reservable 0
        AvStoreClaim -RunPath $script:runPath -Name 'z-other' -Instances 1 -Reservable 1 -Wave 'wave-2'
        (New-VmfWaveReservation -OutPath $script:runPath -Wave 'wave-1').NothingReservable | Should -BeTrue
        Should -Invoke -ModuleName VmMigrationFactory New-VmfCapacityReservation -Times 0 -Exactly
    }
}

Describe 'AVSET-RESERVE-1 (C): the events the engine REALLY writes, held to the shared fixture' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-avres-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Initialize-VmfRun -RunPath $rp -RunId 'avres' | Out-Null }
        Mock -ModuleName VmMigrationFactory New-VmfCapacityReservation { @{ GroupId = '/g'; ReservationId = '/g/r' } }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'the fixture was read and has cases, so nothing below passes on an empty list' {
        @($script:fixture.cases).Count | Should -BeGreaterThan 3
    }

    It 'case: <why>' -ForEach @(
        (Get-Content (Join-Path $PSScriptRoot '..' 'fixtures' 'reserve-nothing-events.json') -Raw | ConvertFrom-Json).cases |
            ForEach-Object { @{ why = $_.why; case = $_ } }
    ) {
        $wave = [string]$script:fixture.wave
        foreach ($cell in @($case.cells)) {
            $state = if ($cell.PSObject.Properties['state']) { [string]$cell.state } else { 'QUOTA_VERIFIED' }
            AvStoreClaim -RunPath $script:runPath -Name $cell.name -Instances $cell.instances -Reservable $cell.reservable `
                -State $state -Wave $wave -Size "Standard_D$($cell.instances)s_v6_$($cell.name)"
        }
        $result = New-VmfWaveReservation -OutPath $script:runPath -Wave $wave
        $result.NothingReservable | Should -Be ([bool]$case.nothingReservable)
        $written = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            @(Read-VmfEvents -RunPath $rp -Step 'odcr')
        }
        $got = @($written | ForEach-Object {
            $code = if ($_.PSObject.Properties['code']) { [string]$_.code } else { $null }
            $w = if ($_.PSObject.Properties['wave']) { [string]$_.wave } else { $null }
            "$($_.step)|$($_.outcome)|$code|$w" })
        $want = @($case.events | ForEach-Object { "$($_.step)|$($_.outcome)|$([string]$_.code)|$([string]$_.wave)" })
        ($got -join "`n") | Should -Be ($want -join "`n")
    }
}

Describe 'AVSET-RESERVE-1: Start-VmfWave on a Reserved wave with availability-set cells' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-avres-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Initialize-VmfRun -RunPath $rp -RunId 'avres' | Out-Null }
        $sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines'
        $plan = @{
            schemaVersion = 1; assessmentRunId = 'avres'
            entries = @(
                @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$sub/ha-1"; wave = 'wave-1'; path = 'A'
                   assessment = @{ location = 'centralus'; availabilitySetId = '/avsets/pair' }
                   target = @{ size = 'Standard_D2s_v6' }; policy = @{ capacityGate = 'Reserved'; requireApproval = $false } }
            )
        }
        $script:planPath = Join-Path $script:runPath 'plan.json'
        $plan | ConvertTo-Json -Depth 10 | Set-Content $script:planPath -Encoding utf8NoBOM

        # The gates in front of capacity are other tests' business.
        Mock -ModuleName VmMigrationFactory Test-VmfRunAcknowledged { [pscustomobject]@{ Pass = $true } }
        Mock -ModuleName VmMigrationFactory Test-VmfWaveOptionsAccepted { [pscustomobject]@{ Pass = $true } }
        Mock -ModuleName VmMigrationFactory Test-VmfVmClaims { [pscustomobject]@{ Pass = $true } }
        Mock -ModuleName VmMigrationFactory Test-VmfWaveSubscriptions { [pscustomobject]@{ Pass = $true } }
        Mock -ModuleName VmMigrationFactory Test-VmfWaveApproval { [pscustomobject]@{ Pass = $true } }
        # RESERVE-RECHECK-1: every start checks the quota again. These records
        # are the answer the check gives here, so the mocked check writes nothing.
        Mock -ModuleName VmMigrationFactory Test-VmfQuota { }
        # The first line after the capacity gate. Reaching it means the gate let
        # the wave through; nothing is spawned.
        # STEP-LOG-5: the launch of the workers, not the wave's start line,
        # which no longer stops a start when it cannot be written.
        Mock -ModuleName VmMigrationFactory Start-Process { throw 'PAST-THE-CAPACITY-GATE' }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'a reserved cell and an availability-set cell: the wave starts' {
        # The plan holds both kinds of machine, as the claims say.
        AvWritePlan -RunPath $script:runPath -Entries @(AvEntry -Avset -Name 'ha-1'; AvEntry -Name 'app-1') | Out-Null
        AvStoreClaim -RunPath $script:runPath -Name 'a-avset' -Instances 2 -Reservable 0 -Size 'Standard_E2s_v6'
        AvStoreClaim -RunPath $script:runPath -Name 'b-open' -Instances 1 -Reservable 1 -State 'RESERVED'
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw '*PAST-THE-CAPACITY-GATE*'
    }

    It 'only availability-set cells: the wave starts, and the log says it is on general capacity' {
        AvStoreClaim -RunPath $script:runPath -Name 'a-avset' -Instances 2 -Reservable 0
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw '*PAST-THE-CAPACITY-GATE*'
        $said = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            @(Read-VmfEvents -RunPath $rp -Step 'capacity' | Where-Object { $_.wave -eq 'wave-1' })
        }
        ($said.detail -join ' ') | Should -Match 'no on-demand capacity reservation'
    }

    It 'no quota records yet: it checks quota (which reserves nothing) and then judges, rather than send a person to Reserve' {
        # Choosing Reserved is a change to the wave, and a change clears the
        # records. Refusing here would tell a wave of availability-set machines
        # to reserve capacity it cannot use.
        Mock -ModuleName VmMigrationFactory Test-VmfQuota {
            AvStoreClaim -RunPath $script:runPath -Name 'a-avset' -Instances 2 -Reservable 0
        }
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw '*PAST-THE-CAPACITY-GATE*'
        Should -Invoke -ModuleName VmMigrationFactory Test-VmfQuota -Times 1 -Exactly -ParameterFilter { $Wave -eq 'wave-1' }
    }

    It 'only the availability-set records exist yet, but the plan has an ordinary machine: REFUSED (review finding 1)' {
        # A quota check that stopped half way, or another container still
        # writing the records. The ordinary machine must not start unreserved.
        AvWritePlan -RunPath $script:runPath -Entries @(AvEntry -Avset -Name 'ha-1'; AvEntry -Name 'app-1' -Size 'Standard_E2s_v6') | Out-Null
        AvStoreClaim -RunPath $script:runPath -Name 'a-avset' -Instances 1 -Reservable 0
        # RESERVE-COVER-1: the start now checks the quota for a machine with no
        # record before it judges, and names the machine when the check still
        # writes none. It said "no capacity has been reserved" before.
        Mock -ModuleName VmMigrationFactory Test-VmfQuota { }
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw "*no quota record for machine 'app-1'*"
    }

    It 'and when the quota check it runs writes only part of the records, the same' {
        AvWritePlan -RunPath $script:runPath -Entries @(AvEntry -Avset -Name 'ha-1'; AvEntry -Name 'app-1') | Out-Null
        Mock -ModuleName VmMigrationFactory Test-VmfQuota {
            AvStoreClaim -RunPath $script:runPath -Name 'a-avset' -Instances 1 -Reservable 0
        }
        # RESERVE-COVER-1: refused by name, rather than "no capacity reserved".
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw "*no quota record for machine 'app-1'*"
    }

    It 'the general-capacity line is written once, by the first container only' {
        AvStoreClaim -RunPath $script:runPath -Name 'a-avset' -Instances 2 -Reservable 0
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath -Container '2/2' } |
            Should -Throw '*PAST-THE-CAPACITY-GATE*'
        $said = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            @(Read-VmfEvents -RunPath $rp -Step 'capacity' | Where-Object { $_.wave -eq 'wave-1' })
        }
        @($said).Count | Should -Be 0
    }

    It 'an ordinary cell nobody reserved is still refused' {
        AvWritePlan -RunPath $script:runPath -Entries @(AvEntry -Avset -Name 'ha-1'; AvEntry -Name 'app-1') | Out-Null
        AvStoreClaim -RunPath $script:runPath -Name 'a-avset' -Instances 2 -Reservable 0 -Size 'Standard_E2s_v6'
        AvStoreClaim -RunPath $script:runPath -Name 'b-open' -Instances 1 -Reservable 1
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw '*no capacity has been reserved*'
    }
}
