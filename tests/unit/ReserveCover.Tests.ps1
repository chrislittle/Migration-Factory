#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# RESERVE-COVER-1, 2026-10-04. A wave set to Reserved is judged by the
# MACHINES it moves, not by the quota records that happen to exist.
#
# The defect: the gate and the refusal read the records of the wave and asked
# "is every record RESERVED?". A quota check is written cell by cell, so one
# that stopped half way (Azure failed on the third cell), or a second container
# reading while the first still wrote, left a PARTIAL set. Reserve reserved
# the cells it had, the start passed, and the machines of the missing cell
# moved on general capacity with no word.
#
# The rule now: every machine of the wave that moves (path A or B, not yet
# MIGRATED or SKIPPED) needs a record for its subscription, region, zone and
# size. A machine a reservation can hold needs that record RESERVED (or
# CONSUMED); a machine in an availability set needs it quota-checked, as
# AVSET-RESERVE-1 ruled. A machine with no record refuses the start with a
# sentence that names it and its size and says to check the quota again.
#
# THESE TESTS RUN THE FUNCTIONS, with a partial set of records and each kind
# of machine.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:sub = '00000000-0000-0000-0000-000000000000'
    $script:otherSub = '11111111-1111-1111-1111-111111111111'

    # A plan entry. Names, sizes and zones differ, so a test can see the wrong
    # machine being matched.
    function Global:RcEntry {
        param([string]$Name, [string]$Size = 'Standard_D2s_v6', [switch]$Avset, [string]$Zone,
              [string]$Sub = '00000000-0000-0000-0000-000000000000', [string]$Wave = 'wave-1',
              [string]$Region = 'centralus', [string]$Path = 'A')
        $target = [ordered]@{ size = $Size }
        if ($Zone) { $target.zone = $Zone }
        [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion);
            vmId = "/subscriptions/$Sub/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$Name"
            wave = $Wave; path = $Path
            assessment = [pscustomobject]@{ location = $Region; availabilitySetId = $(if ($Avset) { '/avsets/pair' } else { '' }) }
            target = [pscustomobject]$target
            policy = [pscustomobject]@{ capacityGate = 'Reserved'; requireApproval = $false }
        }
    }

    # A quota record, in the shape Test-VmfQuota writes.
    function Global:RcClaim {
        param([string]$Size = 'Standard_D2s_v6', [string]$State = 'QUOTA_VERIFIED', [int]$Instances = 1,
              [int]$Reservable = 1, [string]$Zone, [string]$Sub = '00000000-0000-0000-0000-000000000000',
              [string]$Wave = 'wave-1', [string]$Region = 'centralus', [string]$Since)
        $claim = [ordered]@{
            schemaVersion = 10; runId = 'r1'; wave = $Wave
            subscriptionId = $Sub; resourceGroup = 'rg-app'
            region = $Region; zone = $(if ($Zone) { $Zone } else { $null }); size = $Size; vmFamily = 'StandardDsv6Family'
            state = $State; blockReason = $null
            demand = [ordered]@{ instances = $Instances; reservableInstances = $Reservable; vcpus = 2 * $Instances; overlapWithSource = $false }
            quota = [ordered]@{ limit = 100; used = 0; requestId = $null; requestedUtc = $null }
            notes = @()
        }
        if ($State -in @('RESERVED', 'CONSUMED')) {
            $claim.reservation = [ordered]@{ groupId = "/subscriptions/$Sub/g"; reservationId = "/subscriptions/$Sub/g/r"
                                             createdUtc = 'x'; releasedUtc = $null; consumedInstances = 0 }
        }
        if ($State -eq 'RESERVING') { $claim.reservingSinceUtc = $(if ($Since) { $Since } else { (Get-Date).ToUniversalTime().ToString('o') }) }
        [pscustomobject]$claim
    }

    function Global:RcStoreClaim {
        param($RunPath, [string]$Name, $Claim)
        $dir = Join-Path $RunPath 'capacity'
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $Claim | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $dir "$Name.json") -Encoding utf8NoBOM
    }

    function Global:RcWritePlan {
        param($RunPath, $Entries)
        $planPath = Join-Path $RunPath 'plan.json'
        @{ schemaVersion = 1; assessmentRunId = 'rcover'; entries = @($Entries) } |
            ConvertTo-Json -Depth 10 | Set-Content $planPath -Encoding utf8NoBOM
        $planPath
    }

    function Global:RcWriteState {
        param($RunPath, $Entry, [string]$State)
        InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath; id = $Entry.vmId; st = $State } {
            Write-VmfStoreJson -RunPath $rp -RelPath ("state/" + (Get-VmfVmKey -VmId $id) + '.json') `
                -Document ([ordered]@{ schemaVersion = 3; vmId = $id; state = $st }) -Depth 6
        }
    }

    function Global:RcNewRun {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rcov-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { Initialize-VmfRun -RunPath $rp -RunId 'rcover' | Out-Null }
        $rp
    }
}
AfterAll {
    foreach ($f in 'RcEntry', 'RcClaim', 'RcStoreClaim', 'RcWritePlan', 'RcWriteState', 'RcNewRun') {
        Remove-Item "function:\$f" -ErrorAction SilentlyContinue
    }
}

Describe 'RESERVE-COVER-1: which machines a set of records covers' {

    It 'a PARTIAL set: the machines of the missing cells have no record, of either kind' {
        $entries = @(
            RcEntry -Name 'app-1' -Size 'Standard_D2s_v6'
            RcEntry -Name 'app-2' -Size 'Standard_E2s_v6'
            RcEntry -Name 'ha-1' -Size 'Standard_D4s_v6' -Avset)
        $claims = @(RcClaim -Size 'Standard_D2s_v6' -State 'RESERVED')
        InModuleScope VmMigrationFactory -Parameters @{ c = $claims; e = $entries } {
            $gaps = @(Get-VmfReservedCoverageGaps -Claims $c -Entries $e)
            @($gaps.Name) -join ',' | Should -Be 'app-2,ha-1'
            @($gaps | Where-Object Kind -ne 'noRecord').Count | Should -Be 0
            ($gaps | Where-Object Name -eq 'app-2').Size | Should -Be 'Standard_E2s_v6'
            ($gaps | Where-Object Name -eq 'app-2').Reservable | Should -BeTrue
            ($gaps | Where-Object Name -eq 'ha-1').Reservable | Should -BeFalse
        }
    }

    It 'a machine a reservation can hold is covered by RESERVED or CONSUMED, and by nothing less' {
        $e = @(RcEntry -Name 'app-1')
        InModuleScope VmMigrationFactory -Parameters @{ e = $e } {
            foreach ($s in 'RESERVED', 'CONSUMED') {
                @(Get-VmfReservedCoverageGaps -Entries $e -Claims @(RcClaim -State $s)).Count | Should -Be 0 -Because $s
            }
            (Get-VmfReservedCoverageGaps -Entries $e -Claims @(RcClaim -State 'QUOTA_VERIFIED')).Kind | Should -Be 'notReserved'
            (Get-VmfReservedCoverageGaps -Entries $e -Claims @(RcClaim -State 'BLOCKED')).Kind | Should -Be 'notReserved'
            (Get-VmfReservedCoverageGaps -Entries $e -Claims @(RcClaim -State 'RESERVING')).Kind | Should -Be 'reserving'
        }
    }

    It 'a machine in an availability set is covered by a quota-checked record, and a blocked one is the gate''s to judge' {
        $e = @(RcEntry -Name 'ha-1' -Avset)
        InModuleScope VmMigrationFactory -Parameters @{ e = $e } {
            foreach ($s in 'QUOTA_VERIFIED', 'RESERVED', 'CONSUMED') {
                @(Get-VmfReservedCoverageGaps -Entries $e -Claims @(RcClaim -State $s -Reservable 0)).Count | Should -Be 0 -Because $s
            }
            (Get-VmfReservedCoverageGaps -Entries $e -Claims @(RcClaim -State 'BLOCKED' -Reservable 0)).Kind | Should -Be 'quota'
            (Get-VmfReservedCoverageGaps -Entries $e -Claims @()).Kind | Should -Be 'noRecord'
        }
    }

    It 'a record that counts NO reservable machine does not cover a machine the plan says a reservation can hold' {
        # The record and the plan disagree: the record was written for a plan in
        # which this machine was in an availability set. The gate judges such a
        # record on its quota alone, so without this the machine moves unreserved.
        $e = @(RcEntry -Name 'app-1')
        InModuleScope VmMigrationFactory -Parameters @{ e = $e } {
            (Get-VmfReservedCoverageGaps -Entries $e -Claims @(RcClaim -State 'QUOTA_VERIFIED' -Reservable 0)).Kind | Should -Be 'noRecord'
        }
    }

    It 'a record covers only its own cell: wave, subscription, region, zone and size each count' {
        $e = @(RcEntry -Name 'app-1' -Zone '1')
        $near = @(
            RcClaim -State 'RESERVED' -Zone '2'
            RcClaim -State 'RESERVED' -Zone '1' -Sub $script:otherSub
            RcClaim -State 'RESERVED' -Zone '1' -Region 'eastus'
            RcClaim -State 'RESERVED' -Zone '1' -Wave 'wave-2'
            RcClaim -State 'RESERVED' -Zone '1' -Size 'Standard_D4s_v6')
        InModuleScope VmMigrationFactory -Parameters @{ e = $e; near = $near } {
            foreach ($c in $near) {
                (Get-VmfReservedCoverageGaps -Entries $e -Claims @($c)).Kind | Should -Be 'noRecord' -Because ($c | ConvertTo-Json -Compress -Depth 2)
            }
            @(Get-VmfReservedCoverageGaps -Entries $e -Claims @(RcClaim -State 'RESERVED' -Zone '1')).Count | Should -Be 0
        }
    }

    It 'a regional machine is covered by a regional record (no zone on either side)' {
        $e = @(RcEntry -Name 'app-1')
        InModuleScope VmMigrationFactory -Parameters @{ e = $e } {
            @(Get-VmfReservedCoverageGaps -Entries $e -Claims @(RcClaim -State 'RESERVED')).Count | Should -Be 0
            (Get-VmfReservedCoverageGaps -Entries $e -Claims @(RcClaim -State 'RESERVED' -Zone '1')).Kind | Should -Be 'noRecord'
        }
    }

    It 'machines that are MIGRATED or SKIPPED are left out - the quota check leaves them out of the demand on purpose' {
        $done = RcEntry -Name 'app-1' -Size 'Standard_E2s_v6'
        $skip = RcEntry -Name 'app-2' -Size 'Standard_E4s_v6'
        $left = RcEntry -Name 'ha-1' -Avset
        InModuleScope VmMigrationFactory -Parameters @{ e = @($done, $skip, $left); ids = @($done.vmId, $skip.vmId) } {
            @(Get-VmfReservedCoverageGaps -Entries $e -FinishedVmIds $ids -Claims @(RcClaim -State 'QUOTA_VERIFIED' -Reservable 0)).Count |
                Should -Be 0
            @(Get-VmfReservedCoverageGaps -Entries $e -Claims @(RcClaim -State 'QUOTA_VERIFIED' -Reservable 0)).Count |
                Should -Be 2 -Because 'without the finished list they would be gaps'
        }
    }

    It 'the finished list is read from the state documents: MIGRATED and SKIPPED only' {
        $rp = RcNewRun
        try {
            $a = RcEntry -Name 'app-1'; $b = RcEntry -Name 'app-2'; $c = RcEntry -Name 'app-3'
            RcWriteState -RunPath $rp -Entry $a -State 'MIGRATED'
            RcWriteState -RunPath $rp -Entry $b -State 'SKIPPED'
            RcWriteState -RunPath $rp -Entry $c -State 'FAILED'
            $ids = InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { @(Get-VmfFinishedVmIds -RunPath $rp) }
            (@($ids) | Sort-Object) -join ',' | Should -Be ((@($a.vmId, $b.vmId) | Sort-Object) -join ',')
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'RESERVE-COVER-1: the refusal names the machine and its size' {

    It 'a partial set beside a RESERVED cell: refused, naming the reservable machine, its size, and to check the quota again' {
        $e = @(RcEntry -Name 'app-1'; RcEntry -Name 'app-2' -Size 'Standard_E2s_v6')
        InModuleScope VmMigrationFactory -Parameters @{ e = $e } {
            $said = Get-VmfReservedCapacityRefusal -Wave 'wave-1' -Entries $e -Claims @(RcClaim -State 'RESERVED')
            $said | Should -Match "'app-2'"
            $said | Should -Match 'Standard_E2s_v6'
            $said | Should -Match 'select Check the quota at the top, then select Reserve capacity'
            $said | Should -Not -Match "'app-1'"
        }
    }

    It 'and an availability-set machine with no record, beside a cell of only availability-set machines' {
        # AVSET-RESERVE-1 passed a wave whose records were all availability-set
        # cells when the plan agreed. A missing availability-set cell was not
        # its question; it is this one's.
        $e = @(RcEntry -Name 'ha-1' -Avset; RcEntry -Name 'ha-2' -Avset -Size 'Standard_D4s_v6')
        InModuleScope VmMigrationFactory -Parameters @{ e = $e } {
            $said = Get-VmfReservedCapacityRefusal -Wave 'wave-1' -Entries $e -Claims @(RcClaim -Reservable 0)
            $said | Should -Match "'ha-2'"
            $said | Should -Match 'Standard_D4s_v6'
            # Nothing to reserve for a machine in an availability set.
            $said | Should -Match 'select Check the quota at the top, then select Start this wave on the Migrations page'
            $said | Should -Not -Match 'Reserve capacity'
        }
    }

    It 'more than three machines: three are named and the rest are counted' {
        $e = @(1..5 | ForEach-Object { RcEntry -Name "app-$_" -Size "Standard_D$($_)s_v6" })
        InModuleScope VmMigrationFactory -Parameters @{ e = $e } {
            $said = Get-VmfReservedCapacityRefusal -Wave 'wave-1' -Entries $e -Claims @(RcClaim -State 'RESERVED' -Size 'Standard_D9s_v6')
            $said | Should -Match "'app-1'"
            $said | Should -Match "'app-3'"
            $said | Should -Not -Match "'app-4'"
            $said | Should -Match '2 more'
        }
    }

    It 'every machine covered: no refusal - a mixed wave starts' {
        $e = @(RcEntry -Name 'app-1'; RcEntry -Name 'ha-1' -Avset -Size 'Standard_D4s_v6')
        InModuleScope VmMigrationFactory -Parameters @{ e = $e } {
            Get-VmfReservedCapacityRefusal -Wave 'wave-1' -Entries $e -Claims @(
                RcClaim -State 'RESERVED'
                RcClaim -Size 'Standard_D4s_v6' -Reservable 0) | Should -BeNullOrEmpty
        }
    }

    It 'a reservable machine whose record is only quota-checked, beside a RESERVED cell, is named too' {
        # Before, any RESERVED record ended the refusal, and the gate threw its
        # raw detail. The machine now has a sentence.
        $e = @(RcEntry -Name 'app-1'; RcEntry -Name 'app-2' -Size 'Standard_E2s_v6')
        InModuleScope VmMigrationFactory -Parameters @{ e = $e } {
            $said = Get-VmfReservedCapacityRefusal -Wave 'wave-1' -Entries $e -Claims @(
                RcClaim -State 'RESERVED'
                RcClaim -State 'QUOTA_VERIFIED' -Size 'Standard_E2s_v6')
            $said | Should -Match "'app-2'"
            $said | Should -Match 'no capacity reservation'
            $said | Should -Match 'select Check the quota at the top, then select Reserve capacity'
        }
    }

    It 'a cell whose quota check is blocked, beside a RESERVED cell, is named as blocked (review finding 6)' {
        $e = @(RcEntry -Name 'app-1'; RcEntry -Name 'app-2' -Size 'Standard_E2s_v6')
        $blocked = RcClaim -State 'BLOCKED' -Size 'Standard_E2s_v6'
        $blocked.blockReason = 'quota-shortfall'
        InModuleScope VmMigrationFactory -Parameters @{ e = $e; b = $blocked } {
            $said = Get-VmfReservedCapacityRefusal -Wave 'wave-1' -Entries $e -Claims @((RcClaim -State 'RESERVED'), $b)
            $said | Should -Match "'app-2' \(Standard_E2s_v6\)"
            # The second review: the cause in words and the action for it, never
            # the raw reason code.
            $said | Should -Match 'because the quota is not enough'
            $said | Should -Match 'select Request an increase'
            $said | Should -Not -Match 'quota-shortfall'
        }
    }

    It 'a reservation Azure refused, beside a RESERVED cell, is said as that - not as a blocked quota check (second review)' {
        $e = @(RcEntry -Name 'app-1'; RcEntry -Name 'app-2' -Size 'Standard_E2s_v6')
        $failed = RcClaim -State 'BLOCKED' -Size 'Standard_E2s_v6'
        $failed.blockReason = 'reservation-failed'
        InModuleScope VmMigrationFactory -Parameters @{ e = $e; b = $failed } {
            $said = Get-VmfReservedCapacityRefusal -Wave 'wave-1' -Entries $e -Claims @((RcClaim -State 'RESERVED'), $b) -AsRecord
            $said.Code | Should -Be 'reservationFailedBesideHeld'
            $said.Detail | Should -Match "Azure did not reserve capacity for machine 'app-2'"
            $said.Detail | Should -Not -Match 'quota check'
            $said.Detail | Should -Not -Match 'reservation-failed'
        }
    }

    It 'but a cell Azure is still reserving says wait, never reserve again' {
        $e = @(RcEntry -Name 'app-1'; RcEntry -Name 'app-2' -Size 'Standard_E2s_v6')
        InModuleScope VmMigrationFactory -Parameters @{ e = $e } {
            $said = Get-VmfReservedCapacityRefusal -Wave 'wave-1' -Entries $e -Claims @(
                RcClaim -State 'RESERVED'
                RcClaim -State 'RESERVING' -Size 'Standard_E2s_v6')
            $said | Should -Match 'having its capacity reserved now'
            $said | Should -Not -Match 'Check the quota'
        }
    }

    It 'a restart of a part-finished wave is NOT refused for machines that are done' {
        # The ordinary machines MIGRATED and their record was cleared since; the
        # quota check left them out on purpose. Only the availability-set
        # machine is left, and its record is there.
        $done = RcEntry -Name 'app-1'
        $e = @($done; RcEntry -Name 'ha-1' -Avset)
        InModuleScope VmMigrationFactory -Parameters @{ e = $e; ids = @($done.vmId) } {
            Get-VmfReservedCapacityRefusal -Wave 'wave-1' -Entries $e -FinishedVmIds $ids -Claims @(
                RcClaim -Reservable 0) | Should -BeNullOrEmpty
            Get-VmfReservedCapacityRefusal -Wave 'wave-1' -Entries $e -Claims @(RcClaim -Reservable 0) |
                Should -Not -BeNullOrEmpty -Because 'without the finished list the machine would have no record'
        }
    }

    It 'a reservation Azure never confirmed still comes first - it may be billing' {
        $e = @(RcEntry -Name 'app-1'; RcEntry -Name 'app-2' -Size 'Standard_E2s_v6')
        InModuleScope VmMigrationFactory -Parameters @{ e = $e } {
            $said = Get-VmfReservedCapacityRefusal -Wave 'wave-1' -Entries $e -NowUtc ([datetime]'2026-10-04T12:00:00Z') -Claims @(
                RcClaim -State 'RESERVING' -Since '2026-10-03T12:00:00Z')
            $said | Should -Match 'Release'
        }
    }

    It 'no record at all and nobody asked: still told to reserve, as before' {
        $e = @(RcEntry -Name 'app-1')
        InModuleScope VmMigrationFactory -Parameters @{ e = $e } {
            Get-VmfReservedCapacityRefusal -Wave 'wave-1' -Entries $e -Claims @(RcClaim) | Should -Match 'no capacity has been reserved'
        }
    }
}

Describe 'RESERVE-COVER-1: the capacity gate judges the machines' {
    BeforeEach { $script:runPath = RcNewRun }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'a partial set of records FAILS the Reserved gate, and says which machine has no record' {
        RcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (RcClaim -State 'RESERVED')
        $e = @(RcEntry -Name 'app-1'; RcEntry -Name 'app-2' -Size 'Standard_E2s_v6')
        $r = Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'wave-1' -Gate 'Reserved' -Entries $e
        $r.Pass | Should -BeFalse -Because 'the defect: every record that existed was RESERVED, so it passed'
        $r.Detail | Should -Match 'app-2'
        $r.Detail | Should -Match 'check the quota again'
        @($r.Uncovered).Count | Should -Be 1
        $r.Uncovered[0].Name | Should -Be 'app-2'
        $r.Uncovered[0].Size | Should -Be 'Standard_E2s_v6'
    }

    It 'with each kind of machine missing: the availability-set machine with no record fails it too' {
        RcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (RcClaim -State 'RESERVED')
        $e = @(RcEntry -Name 'app-1'; RcEntry -Name 'ha-1' -Avset -Size 'Standard_D4s_v6')
        $r = Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'wave-1' -Gate 'Reserved' -Entries $e
        $r.Pass | Should -BeFalse
        $r.Uncovered[0].Name | Should -Be 'ha-1'
    }

    It 'every machine covered: passes' {
        RcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (RcClaim -State 'RESERVED')
        RcStoreClaim -RunPath $script:runPath -Name 'b' -Claim (RcClaim -Size 'Standard_D4s_v6' -Reservable 0)
        $e = @(RcEntry -Name 'app-1'; RcEntry -Name 'ha-1' -Avset -Size 'Standard_D4s_v6')
        $r = Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'wave-1' -Gate 'Reserved' -Entries $e
        $r.Pass | Should -BeTrue -Because $r.Detail
        @($r.Uncovered).Count | Should -Be 0
    }

    It 'with no entries given it reads the plan and the state documents of the run' {
        RcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (RcClaim -State 'RESERVED')
        $done = RcEntry -Name 'app-2' -Size 'Standard_E2s_v6'
        RcWritePlan -RunPath $script:runPath -Entries @((RcEntry -Name 'app-1'), $done) | Out-Null
        (Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'wave-1' -Gate 'Reserved').Pass | Should -BeFalse
        RcWriteState -RunPath $script:runPath -Entry $done -State 'MIGRATED'
        $r = Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'wave-1' -Gate 'Reserved'
        $r.Pass | Should -BeTrue -Because "a MIGRATED machine needs no record: $($r.Detail)"
    }

    It 'a machine that does not move needs no record' {
        RcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (RcClaim -State 'RESERVED')
        $e = @(RcEntry -Name 'app-1'; RcEntry -Name 'keep-1' -Size 'Standard_E2s_v6' -Path 'none')
        RcWritePlan -RunPath $script:runPath -Entries $e | Out-Null
        (Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'wave-1' -Gate 'Reserved').Pass | Should -BeTrue
    }

    It 'a Reserved gate with no plan to read is not a pass - unknown is not covered' {
        RcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (RcClaim -State 'RESERVED')
        $r = Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'wave-1' -Gate 'Reserved'
        $r.Pass | Should -BeFalse
        $r.Detail | Should -Match 'plan could not be read'
    }

    It 'a RELEASED record of a cell whose machines are done does not refuse the rest of the wave (review finding 1)' {
        # A machine rolled back, the wave was released, the quota of the wave
        # checked again and the open machine reserved. The finished cell keeps
        # its RELEASED record, which no quota check replaces.
        $done = RcEntry -Name 'app-1'
        $open = RcEntry -Name 'app-2' -Size 'Standard_E2s_v6'
        RcWritePlan -RunPath $script:runPath -Entries @($done, $open) | Out-Null
        RcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (RcClaim -State 'RELEASED')
        RcStoreClaim -RunPath $script:runPath -Name 'b' -Claim (RcClaim -State 'RESERVED' -Size 'Standard_E2s_v6')
        # While the machine is NOT done, its record still refuses.
        (Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'wave-1' -Gate 'Reserved').Pass | Should -BeFalse
        RcWriteState -RunPath $script:runPath -Entry $done -State 'MIGRATED'
        $r = Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'wave-1' -Gate 'Reserved'
        $r.Pass | Should -BeTrue -Because $r.Detail
        $claims = @(Get-ChildItem (Join-Path $script:runPath 'capacity') -Filter '*.json' | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json })
        InModuleScope VmMigrationFactory -Parameters @{ e = @($done, $open); ids = @($done.vmId); c = $claims } {
            Get-VmfReservedCapacityRefusal -Wave 'wave-1' -Claims $c -Entries $e -FinishedVmIds $ids | Should -BeNullOrEmpty
        }
    }

    It 'BestEffort asks a quota-checked record of each machine, and no reservation' {
        # RESERVE-COVER-2 rewrote this test. It pinned BestEffort to judging the
        # records alone, with no plan, which is the defect that item closed:
        # BestEffort now judges the machines too (tests/unit/BestEffortCover.Tests.ps1).
        RcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (RcClaim)
        $e = @(RcEntry -Name 'app-1')
        (Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'wave-1' -Gate 'BestEffort' -Entries $e).Pass | Should -BeTrue
        (Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'wave-1' -Gate 'Reserved' -Entries $e).Pass | Should -BeFalse
        $r = Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'wave-1' -Gate 'BestEffort' -Entries @($e; RcEntry -Name 'app-2' -Size 'Standard_E2s_v6')
        $r.Pass | Should -BeFalse -Because 'app-2 has no record'
        $r.Uncovered[0].Name | Should -Be 'app-2'
    }
}

Describe 'RESERVE-COVER-1: Start-VmfWave on a Reserved wave with a partial set of records' {
    BeforeEach {
        $script:runPath = RcNewRun
        $script:app1 = RcEntry -Name 'app-1'
        $script:app2 = RcEntry -Name 'app-2' -Size 'Standard_E2s_v6'
        $script:ha1 = RcEntry -Name 'ha-1' -Avset -Size 'Standard_D4s_v6'
        $script:planPath = RcWritePlan -RunPath $script:runPath -Entries @($script:app1, $script:app2, $script:ha1)

        Mock -ModuleName VmMigrationFactory Test-VmfRunAcknowledged { [pscustomobject]@{ Pass = $true } }
        Mock -ModuleName VmMigrationFactory Test-VmfWaveOptionsAccepted { [pscustomobject]@{ Pass = $true } }
        Mock -ModuleName VmMigrationFactory Test-VmfVmClaims { [pscustomobject]@{ Pass = $true } }
        Mock -ModuleName VmMigrationFactory Test-VmfWaveSubscriptions { [pscustomobject]@{ Pass = $true } }
        Mock -ModuleName VmMigrationFactory Test-VmfWaveApproval { [pscustomobject]@{ Pass = $true } }
        # Reaching the wave's start line means the capacity gate let it through.
        # STEP-LOG-5: the launch of the workers, not the wave's start line,
        # which no longer stops a start when it cannot be written.
        Mock -ModuleName VmMigrationFactory Start-Process { throw 'PAST-THE-CAPACITY-GATE' }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'THE DEFECT: two of three cells on record, both RESERVED - checks the quota, then REFUSES naming the machine, when the check adds nothing' {
        RcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (RcClaim -State 'RESERVED')
        RcStoreClaim -RunPath $script:runPath -Name 'c' -Claim (RcClaim -Size 'Standard_D4s_v6' -Reservable 0)
        # Azure still fails on the missing cell: the check writes nothing.
        Mock -ModuleName VmMigrationFactory Test-VmfQuota { }
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw "*'app-2'*Standard_E2s_v6*select Check the quota*"
        Should -Invoke -ModuleName VmMigrationFactory Test-VmfQuota -Times 1 -Exactly -ParameterFilter { $Wave -eq 'wave-1' }
        $said = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            @(Read-VmfEvents -RunPath $rp -Step 'capacity' | Where-Object { $_.outcome -eq 'refused' })
        }
        @($said).Count | Should -Be 1
        $said[0].detail | Should -Match 'app-2'
        # GATE-WORDS-1: the code and the wave travel in the event.
        $said[0].code | Should -Be 'noQuotaRecord'
        $said[0].wave | Should -Be 'wave-1'
    }

    It 'when the check writes the missing ordinary cell, it is refused as not reserved, still naming the machine' {
        RcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (RcClaim -State 'RESERVED')
        RcStoreClaim -RunPath $script:runPath -Name 'c' -Claim (RcClaim -Size 'Standard_D4s_v6' -Reservable 0)
        Mock -ModuleName VmMigrationFactory Test-VmfQuota {
            RcStoreClaim -RunPath $script:runPath -Name 'b' -Claim (RcClaim -Size 'Standard_E2s_v6')
        }
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw "*no capacity reservation for machine 'app-2'*"
    }

    It 'a missing AVAILABILITY-SET cell is checked and the wave starts - nothing to reserve for it' {
        RcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (RcClaim -State 'RESERVED')
        RcStoreClaim -RunPath $script:runPath -Name 'b' -Claim (RcClaim -State 'RESERVED' -Size 'Standard_E2s_v6')
        Mock -ModuleName VmMigrationFactory Test-VmfQuota {
            RcStoreClaim -RunPath $script:runPath -Name 'c' -Claim (RcClaim -Size 'Standard_D4s_v6' -Reservable 0)
        }
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw '*PAST-THE-CAPACITY-GATE*'
        Should -Invoke -ModuleName VmMigrationFactory Test-VmfQuota -Times 1 -Exactly
    }

    It 'every machine covered: the quota is checked again (RESERVE-RECHECK-1), and the wave starts' {
        RcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (RcClaim -State 'RESERVED')
        RcStoreClaim -RunPath $script:runPath -Name 'b' -Claim (RcClaim -State 'RESERVED' -Size 'Standard_E2s_v6')
        RcStoreClaim -RunPath $script:runPath -Name 'c' -Claim (RcClaim -Size 'Standard_D4s_v6' -Reservable 0)
        Mock -ModuleName VmMigrationFactory Test-VmfQuota { }
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw '*PAST-THE-CAPACITY-GATE*'
        Should -Invoke -ModuleName VmMigrationFactory Test-VmfQuota -Times 1 -Exactly -ParameterFilter { $Wave -eq 'wave-1' }
    }

    It 'a SECOND CONTAINER that reads while the first is still writing checks the quota itself, rather than start or refuse' {
        # Review finding 7: realistic records. The reservable cells were
        # reserved before the start; the first container is still writing the
        # availability-set cell, which is all a quota check can add here.
        RcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (RcClaim -State 'RESERVED')
        RcStoreClaim -RunPath $script:runPath -Name 'b' -Claim (RcClaim -State 'RESERVED' -Size 'Standard_E2s_v6')
        Mock -ModuleName VmMigrationFactory Test-VmfQuota {
            RcStoreClaim -RunPath $script:runPath -Name 'c' -Claim (RcClaim -Size 'Standard_D4s_v6' -Reservable 0)
        }
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath -Container '2/2' } |
            Should -Throw '*PAST-THE-CAPACITY-GATE*'
        Should -Invoke -ModuleName VmMigrationFactory Test-VmfQuota -Times 1 -Exactly -ParameterFilter { $Wave -eq 'wave-1' }
    }

    It 'a restart after the ordinary machines MIGRATED starts on the availability-set record alone' {
        RcWriteState -RunPath $script:runPath -Entry $script:app1 -State 'MIGRATED'
        RcWriteState -RunPath $script:runPath -Entry $script:app2 -State 'SKIPPED'
        # Review finding 1: the records of the finished cells STAY - the quota
        # check never replaces a record of a cell with no open machine. One was
        # released after a rollback, one is blocked. Neither decides this start.
        RcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (RcClaim -State 'RELEASED')
        RcStoreClaim -RunPath $script:runPath -Name 'b' -Claim (RcClaim -State 'BLOCKED' -Size 'Standard_E2s_v6')
        RcStoreClaim -RunPath $script:runPath -Name 'c' -Claim (RcClaim -Size 'Standard_D4s_v6' -Reservable 0)
        Mock -ModuleName VmMigrationFactory Test-VmfQuota { }
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw '*PAST-THE-CAPACITY-GATE*'
        # Every machine LEFT to move is in an availability set, and the log says so.
        $said = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            @(Read-VmfEvents -RunPath $rp -Step 'capacity' | Where-Object { $_.wave -eq 'wave-1' })
        }
        ($said.detail -join ' ') | Should -Match 'every machine in it is in an availability set'
    }
}

Describe 'RESERVE-COVER-1: Reserve does not reserve a partial set' {
    BeforeEach {
        $script:runPath = RcNewRun
        RcWritePlan -RunPath $script:runPath -Entries @(
            RcEntry -Name 'app-1'
            RcEntry -Name 'app-2' -Size 'Standard_E2s_v6') | Out-Null
        Mock -ModuleName VmMigrationFactory New-VmfCapacityReservation { @{ GroupId = '/g'; ReservationId = '/g/r' } }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'a machine of the plan with no record: the quota of the wave is checked first, then every cell is reserved' {
        RcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (RcClaim)
        Mock -ModuleName VmMigrationFactory Test-VmfQuota {
            RcStoreClaim -RunPath $script:runPath -Name 'b' -Claim (RcClaim -Size 'Standard_E2s_v6')
        }
        $r = New-VmfWaveReservation -OutPath $script:runPath -Wave 'wave-1'
        Should -Invoke -ModuleName VmMigrationFactory Test-VmfQuota -Times 1 -Exactly -ParameterFilter { $Wave -eq 'wave-1' }
        Should -Invoke -ModuleName VmMigrationFactory New-VmfCapacityReservation -Times 2 -Exactly
        $r.Refused | Should -BeNullOrEmpty
    }

    It 'and when the check still leaves a machine with no record, nothing is reserved and the refusal names it' {
        RcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (RcClaim)
        Mock -ModuleName VmMigrationFactory Test-VmfQuota { }
        $r = New-VmfWaveReservation -OutPath $script:runPath -Wave 'wave-1'
        Should -Invoke -ModuleName VmMigrationFactory New-VmfCapacityReservation -Times 0 -Exactly
        $r.Refused | Should -Match "'app-2'"
        $r.Refused | Should -Match 'Standard_E2s_v6'
        $said = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            @(Read-VmfEvents -RunPath $rp -Step 'odcr' | Where-Object { $_.outcome -eq 'refused' })
        }
        @($said).Count | Should -Be 1
        $said[0].wave | Should -Be 'wave-1'
    }

    It 'every machine on record: no extra quota check' {
        RcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (RcClaim)
        RcStoreClaim -RunPath $script:runPath -Name 'b' -Claim (RcClaim -Size 'Standard_E2s_v6')
        Mock -ModuleName VmMigrationFactory Test-VmfQuota { throw 'NOT-EXPECTED' }
        (New-VmfWaveReservation -OutPath $script:runPath -Wave 'wave-1').Refused | Should -BeNullOrEmpty
        Should -Invoke -ModuleName VmMigrationFactory New-VmfCapacityReservation -Times 2 -Exactly
    }
}

Describe 'RESERVE-COVER-1 review: a quota check and a Reserve at the same moment' {
    BeforeEach {
        $script:runPath = RcNewRun
        $script:planPath = RcWritePlan -RunPath $script:runPath -Entries @(
            RcEntry -Name 'app-1'
            RcEntry -Name 'app-2' -Size 'Standard_E2s_v6')
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
            foreach ($n in 'Standard_D2s_v6', 'Standard_E2s_v6') {
                [pscustomobject]@{ Name = $n; ResourceType = 'virtualMachines'; Family = 'StandardDsv6Family'; Restrictions = @()
                    Capabilities = @([pscustomobject]@{ Name = 'vCPUs'; Value = '2' }) }
            }
        }
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @([pscustomobject]@{ Name = [pscustomobject]@{ Value = 'StandardDsv6Family' }; CurrentValue = 0; Limit = 100 })
        }
        Mock -ModuleName VmMigrationFactory Get-VmfRetailPrice { $null }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'a record that becomes a reservation while the quota is checked is KEPT, not written over (review finding 2)' {
        Test-VmfQuota -PlanPath $script:planPath -OutPath $script:runPath -Wave 'wave-1' | Out-Null
        $script:file = @(Get-ChildItem (Join-Path $script:runPath 'capacity') -Filter '*D2s*')[0].FullName
        # Reserve writes RESERVING between the check's read and its write.
        Mock -ModuleName VmMigrationFactory Write-VmfClaimIfVersion -ParameterFilter { $Handle -like '*D2s*' } {
            $c = Get-Content $script:file -Raw | ConvertFrom-Json
            $c.state = 'RESERVING'
            $c | ConvertTo-Json -Depth 8 | Set-Content $script:file -Encoding utf8NoBOM
            throw '409: changed'
        }
        Test-VmfQuota -PlanPath $script:planPath -OutPath $script:runPath -Wave 'wave-1' | Out-Null
        (Get-Content $script:file -Raw | ConvertFrom-Json).state | Should -Be 'RESERVING'
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfClaimIfVersion -Times 1 -Exactly -ParameterFilter { $Handle -like '*D2s*' }
    }

    It 'a record another quota check rewrote in between is written with this answer' {
        Test-VmfQuota -PlanPath $script:planPath -OutPath $script:runPath -Wave 'wave-1' | Out-Null
        $file = @(Get-ChildItem (Join-Path $script:runPath 'capacity') -Filter '*D2s*')[0].FullName
        Mock -ModuleName VmMigrationFactory Write-VmfClaimIfVersion -ParameterFilter { $Handle -like '*D2s*' } { throw '409: changed' }
        $c = Get-Content $file -Raw | ConvertFrom-Json
        $c.state = 'BLOCKED'
        $c | ConvertTo-Json -Depth 8 | Set-Content $file -Encoding utf8NoBOM
        Test-VmfQuota -PlanPath $script:planPath -OutPath $script:runPath -Wave 'wave-1' | Out-Null
        (Get-Content $file -Raw | ConvertFrom-Json).state | Should -Be 'QUOTA_VERIFIED'
    }

    It 'a cell whose own save is lost while Azure makes it counts for all or nothing - the other cells are released (review finding 2)' {
        RcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (RcClaim)
        RcStoreClaim -RunPath $script:runPath -Name 'b' -Claim (RcClaim -Size 'Standard_E2s_v6')
        Mock -ModuleName VmMigrationFactory New-VmfCapacityReservation {
            if ($Size -eq 'Standard_E2s_v6') {
                # Somebody writes the record while Azure is making it.
                $claimFile = Join-Path $script:runPath 'capacity' 'b.json'
                $c = Get-Content $claimFile -Raw | ConvertFrom-Json
                $c.state = 'RELEASED'
                $c | ConvertTo-Json -Depth 8 | Set-Content $claimFile -Encoding utf8NoBOM
            }
            @{ GroupId = '/g'; ReservationId = '/g/r' }
        }
        Mock -ModuleName VmMigrationFactory Remove-VmfCapacityReservation { }
        Mock -ModuleName VmMigrationFactory Remove-VmfCapacityReservations { }
        $r = New-VmfWaveReservation -OutPath $script:runPath -Wave 'wave-1'
        $r.AllOrNothing | Should -BeTrue
        Should -Invoke -ModuleName VmMigrationFactory Remove-VmfCapacityReservations -Times 1 -Exactly
    }
}

Describe 'RESERVE-COVER-1: the refusals follow GATE-WORDS-1 - a code and two sentences from data/start-gates.json' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:words = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'start-gates.json') -Raw | ConvertFrom-Json
        # The second review: the instructions are held to the labels the pages
        # really show, read from the pages.
        $wavesText = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'waves.html'))
        $migText = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'migrations.html'))
        $label = { param($text, $key) $m = [regex]::Match($text, "(?m)^\s*$key\s*:\s*'([^']*)'"); if (-not $m.Success) { throw "no label $key" }; $m.Groups[1].Value }
        $check = & $label $wavesText 'capCheck'; $reserve = & $label $wavesText 'reserveBtn'
        $increase = & $label $wavesText 'quotaBtn'; $change = & $label $wavesText 'changeTarget'
        $startIt = & $label $migText 'startWave'
        $script:labels = @{
            noQuotaRecord = @($check, $reserve); noQuotaRecordGeneral = @($check, $startIt)
            notReservedBesideHeld = @($check, $reserve); quotaShortBesideHeld = @($increase, $check, $reserve)
            sizeBlockedBesideHeld = @($change, $check, $reserve); reservationFailedBesideHeld = @($check, $reserve)
            quotaBlockedBesideHeld = @($check, $reserve)
            regionalQuotaShortBesideHeld = @($increase, $check, $reserve); regionalQuotaShortGeneral = @($increase, $check)
            quotaShortGeneral = @($increase, $check); sizeBlockedGeneral = @($change, $check); quotaBlockedGeneral = @($check, $startIt); quotaCheckFailed = @($check, $startIt)
        }
        $held = RcClaim -State 'RESERVED'
        $app1 = RcEntry -Name 'app-1'; $app2 = RcEntry -Name 'app-2' -Size 'Standard_E2s_v6'
        $ha2 = RcEntry -Name 'ha-2' -Avset -Size 'Standard_D4s_v6'
        $blockedAs = { param($why) $c = RcClaim -State 'BLOCKED' -Size 'Standard_E2s_v6'; $c.blockReason = $why; $c }
        $one = "machine 'app-2' (Standard_E2s_v6)"
        # Each state that gives a code, and the machine list it names.
        $script:rcases = [ordered]@{
            noQuotaRecord               = @{ e = @($app1, $app2); c = @($held); m = $one }
            noQuotaRecordGeneral        = @{ e = @((RcEntry -Name 'ha-1' -Avset), $ha2); c = @(RcClaim -Reservable 0); m = "machine 'ha-2' (Standard_D4s_v6)" }
            notReservedBesideHeld       = @{ e = @($app1, $app2); c = @($held, (RcClaim -Size 'Standard_E2s_v6')); m = $one }
            quotaShortBesideHeld        = @{ e = @($app1, $app2); c = @($held, (& $blockedAs 'quota-shortfall')); m = $one }
            regionalQuotaShortBesideHeld = @{ e = @($app1, $app2); c = @($held, (& $blockedAs 'regional-quota-shortfall')); m = $one }
            sizeBlockedBesideHeld       = @{ e = @($app1, $app2); c = @($held, (& $blockedAs 'sku-restricted')); m = $one }
            reservationFailedBesideHeld = @{ e = @($app1, $app2); c = @($held, (& $blockedAs 'reservation-failed')); m = $one }
            quotaBlockedBesideHeld      = @{ e = @($app1, $app2); c = @($held, (& $blockedAs $null)); m = $one }
        }
        $script:rseen = @{}
        foreach ($k in $script:rcases.Keys) {
            $x = $script:rcases[$k]
            $script:rseen[$k] = InModuleScope VmMigrationFactory -Parameters @{ e = $x.e; c = $x.c } {
                Get-VmfReservedCapacityRefusal -Wave 'wave-1' -Entries $e -Claims $c -AsRecord
            }
        }
        # RESERVE-RECHECK-1: a machine judged on its quota check alone whose
        # record is blocked - what a start says after it checks the quota again.
        foreach ($g in @(
                @{ Code = 'quotaShortGeneral'; Why = 'quota-shortfall' }
                @{ Code = 'regionalQuotaShortGeneral'; Why = 'regional-quota-shortfall' }
                @{ Code = 'sizeBlockedGeneral'; Why = 'sku-restricted' }
                @{ Code = 'quotaBlockedGeneral'; Why = $null })) {
            $script:rcases[$g.Code] = @{ e = @($app2); c = @(& $blockedAs $g.Why); m = $one }
            $script:rseen[$g.Code] = InModuleScope VmMigrationFactory -Parameters @{ e = @($app2); c = @(& $blockedAs $g.Why) } {
                $gaps = @(Get-VmfReservedCoverageGaps -Gate BestEffort -Entries $e -Claims $c)
                Get-VmfReservedCoverRefusal -Gate BestEffort -Wave 'wave-1' -Gaps $gaps
            }
        }
        # RESERVE-RECHECK-1 review: a quota check that did not finish, named
        # for the machines that have not started their move.
        $script:rcases['quotaCheckFailed'] = @{ e = @($app2); c = @(); m = $one }
        $script:rseen['quotaCheckFailed'] = InModuleScope VmMigrationFactory -Parameters @{ m = $one } {
            New-VmfStartGateRefusal -Code 'quotaCheckFailed' -Wave 'wave-1' -Machines $m
        }
        $script:allCodes = @($script:rcases.Keys)
    }

    It '<_>: the refusal gives this code, of the capacity gate' -ForEach @('noQuotaRecord', 'noQuotaRecordGeneral', 'notReservedBesideHeld', 'quotaShortBesideHeld', 'regionalQuotaShortBesideHeld', 'sizeBlockedBesideHeld', 'reservationFailedBesideHeld', 'quotaBlockedBesideHeld', 'quotaShortGeneral', 'regionalQuotaShortGeneral', 'sizeBlockedGeneral', 'quotaBlockedGeneral', 'quotaCheckFailed') {
        $script:rseen[$_].Code | Should -Be $_
        $script:rseen[$_].Gate | Should -Be 'capacity'
        [string]$script:words.reasons.$_.gate | Should -Be 'capacity'
    }

    It 'the cases above are every capacity code in the file' {
        @($script:words.reasons.PSObject.Properties | Where-Object { [string]$_.Value.gate -eq 'capacity' } | ForEach-Object Name | Sort-Object) |
            Should -Be @($script:allCodes | Sort-Object)
    }

    It '<_>: the sentence is the file''s two sentences, filled in' -ForEach @('noQuotaRecord', 'noQuotaRecordGeneral', 'notReservedBesideHeld', 'quotaShortBesideHeld', 'regionalQuotaShortBesideHeld', 'sizeBlockedBesideHeld', 'reservationFailedBesideHeld', 'quotaBlockedBesideHeld', 'quotaShortGeneral', 'regionalQuotaShortGeneral', 'sizeBlockedGeneral', 'quotaBlockedGeneral', 'quotaCheckFailed') {
        $r = $script:words.reasons.$_
        $want = "$($r.missing) $($r.toDo)".Replace('{wave}', 'wave-1').Replace('{machines}', $script:rcases[$_].m)
        $script:rseen[$_].Detail | Should -BeExactly $want
    }

    It '<_>: two sentences, the first names the machine, no placeholder, command or raw reason code, each short' -ForEach @('noQuotaRecord', 'noQuotaRecordGeneral', 'notReservedBesideHeld', 'quotaShortBesideHeld', 'regionalQuotaShortBesideHeld', 'sizeBlockedBesideHeld', 'reservationFailedBesideHeld', 'quotaBlockedBesideHeld', 'quotaShortGeneral', 'regionalQuotaShortGeneral', 'sizeBlockedGeneral', 'quotaBlockedGeneral', 'quotaCheckFailed') {
        $d = [string]$script:rseen[$_].Detail
        $d | Should -Not -Match '[{}]'
        $d | Should -Not -Match '\b[A-Z][a-z]+-Vmf[A-Za-z]+'
        $d | Should -Not -Match 'quota-shortfall|sku-restricted|size-missing|reservation-failed'
        # Split after a full stop that ends a sentence, not one inside a size name.
        $sentences = @($d -split '(?<=\.)\s+(?=[A-Z])' | Where-Object { $_ })
        $sentences.Count | Should -Be 2
        $sentences[0] | Should -Match "'app-2'|'ha-2'" -Because 'the page shows only the first sentence of a refused start'
        @($sentences[0] -split '\s+').Count | Should -BeLessOrEqual 25
        @($sentences[1] -split '\s+').Count | Should -BeLessOrEqual 20
    }

    It '<_>: the instruction says "In the wave editor" and names the labels the pages show' -ForEach @('noQuotaRecord', 'noQuotaRecordGeneral', 'notReservedBesideHeld', 'quotaShortBesideHeld', 'regionalQuotaShortBesideHeld', 'sizeBlockedBesideHeld', 'reservationFailedBesideHeld', 'quotaBlockedBesideHeld', 'quotaShortGeneral', 'regionalQuotaShortGeneral', 'sizeBlockedGeneral', 'quotaBlockedGeneral', 'quotaCheckFailed') {
        $toDo = [string]$script:words.reasons.$_.toDo
        $toDo | Should -Match '^In the wave editor, select '
        foreach ($l in $script:labels[$_]) { $toDo | Should -Match ('\b' + [regex]::Escape($l) + '\b') -Because "the page label is '$l'" }
    }

    It 'five machines with two block reasons: the cause named first wins, three are named and the rest counted' {
        # Second review, item 5. A list filled in from data is not held to the
        # word count - the gate counts {machines} as one word, as it counts
        # {wave} - so the length rule is measured with the list as one word.
        $held = RcClaim -State 'RESERVED'
        $e = @(RcEntry -Name 'app-1'
               2..6 | ForEach-Object { RcEntry -Name "app-$_" -Size "Standard_E$($_)s_v6" })
        $c = @($held
               2..6 | ForEach-Object {
                   $b = RcClaim -State 'BLOCKED' -Size "Standard_E$($_)s_v6"
                   $b.blockReason = $(if ($_ -le 4) { 'sku-restricted' } else { 'quota-shortfall' })
                   $b })
        $r = InModuleScope VmMigrationFactory -Parameters @{ e = $e; c = $c } {
            Get-VmfReservedCapacityRefusal -Wave 'wave-1' -Entries $e -Claims $c -AsRecord
        }
        $r.Code | Should -Be 'quotaShortBesideHeld'
        $r.Detail | Should -Match "machines 'app-5' \(Standard_E5s_v6\) and 'app-6' \(Standard_E6s_v6\)"
        $r.Detail | Should -Not -Match "'app-2'"
        $r2 = InModuleScope VmMigrationFactory -Parameters @{ e = $e; c = @($c | Where-Object { $_.blockReason -ne 'quota-shortfall' }) } {
            Get-VmfReservedCapacityRefusal -Wave 'wave-1' -Entries $e -Claims $c -AsRecord
        }
        $r2.Code | Should -Be 'noQuotaRecord' -Because 'with the shortfall records gone, app-5 and app-6 have no record'
        $many = @(2..6 | ForEach-Object { [pscustomobject]@{ Name = "app-$_"; Size = "Standard_E$($_)s_v6" } })
        $list = InModuleScope VmMigrationFactory -Parameters @{ g = $many } { Get-VmfCoverMachineList -Gaps $g }
        $list | Should -BeExactly "machines 'app-2' (Standard_E2s_v6), 'app-3' (Standard_E3s_v6) and 'app-4' (Standard_E4s_v6) and 2 more"
        foreach ($code in $script:allCodes) {
            $first = [string]$script:words.reasons.$code.missing
            @($first -split '\s+').Count | Should -BeLessOrEqual 25 -Because "$code, with the list counted as one word"
        }
    }

    It 'without -AsRecord the refusal is the same sentence, as every other caller reads it' {
        $x = $script:rcases['noQuotaRecord']
        InModuleScope VmMigrationFactory -Parameters @{ e = $x.e; c = $x.c } {
            Get-VmfReservedCapacityRefusal -Wave 'wave-1' -Entries $e -Claims $c
        } | Should -BeExactly $script:rseen['noQuotaRecord'].Detail
    }

    It 'the older refusals stay sentences under -AsRecord too - only the ones for machines have a code' {
        $e = @(RcEntry -Name 'app-1')
        InModuleScope VmMigrationFactory -Parameters @{ e = $e } {
            Get-VmfReservedCapacityRefusal -Wave 'wave-1' -Entries $e -Claims @(RcClaim) -AsRecord
        } | Should -BeOfType [string]
    }

    It 'a wave whose name holds a placeholder is written as it is - placeholders are filled in one pass' {
        InModuleScope VmMigrationFactory {
            Format-VmfStartGateText -Text 'Wave {wave} has no quota record for {machines}.' -Wave '{machines}' -Machines "machine 'a' (S)" |
                Should -BeExactly "Wave {machines} has no quota record for machine 'a' (S)."
            Format-VmfStartGateText -Text 'by {by} for {wave}' -Wave 'w1' -By '{wave}' | Should -BeExactly 'by {wave} for w1'
        }
    }
}
