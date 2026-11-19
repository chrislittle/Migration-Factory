#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# RESERVE-COVER-2, 2026-10-09. A wave with no capacity reservation (BestEffort,
# "None" on screen) is judged by the MACHINES it moves, not by the
# quota records that happen to exist - RESERVE-COVER-1's rule, on the quota
# rung.
#
# The defect: the start ran the quota check only when the wave had NO records,
# and the gate asked "is every record that exists QUOTA_VERIFIED?". A quota
# check is written cell by cell, so one that stopped half way (Azure failed on
# one cell), or a second container reading while the first still wrote, left a
# PARTIAL set. Every record of it passed, and the machines of the missing cell
# moved with their quota never checked - a shortfall then met them inside the
# stopped window.
#
# The rule now: every machine of the wave that moves (path A or B, and not left
# out by Get-VmfLeftOutVmIds) needs a record of its own cell - subscription,
# region, zone and size - at QUOTA_VERIFIED or above. The start checks the
# quota of the wave when any machine has none, and a machine still without one
# refuses the start with GATE-WORDS-1's two sentences, naming it and its size.
#
# THESE TESTS RUN THE FUNCTIONS, with a partial set of records and each kind
# of machine.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    # A plan entry of a BestEffort wave. Names and sizes differ, so a test can
    # see the wrong machine being matched. -Source puts a machine outside the
    # scope of this tool (a GPU size, GPU-SCOPE-1).
    function Global:BcEntry {
        param([string]$Name, [string]$Size = 'Standard_D2s_v6', [switch]$Avset, [string]$Source = 'Standard_D2s_v4',
              [string]$Wave = 'wave-1', [string]$Path = 'A')
        [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion);
            vmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$Name"
            wave = $Wave; path = $Path
            assessment = [pscustomobject]@{ location = 'centralus'; sourceSize = $Source
                                            availabilitySetId = $(if ($Avset) { '/avsets/pair' } else { '' }) }
            target = [pscustomobject]@{ size = $Size }
            policy = [pscustomobject]@{ capacityGate = 'BestEffort'; requireApproval = $false }
        }
    }

    # A quota record, in the shape Test-VmfQuota writes.
    function Global:BcClaim {
        param([string]$Size = 'Standard_D2s_v6', [string]$State = 'QUOTA_VERIFIED', [int]$Reservable = 1, [string]$Wave = 'wave-1')
        $claim = [ordered]@{
            schemaVersion = 10; runId = 'r1'; wave = $Wave
            subscriptionId = '00000000-0000-0000-0000-000000000000'; resourceGroup = 'rg-app'
            region = 'centralus'; zone = $null; size = $Size; vmFamily = 'StandardDsv6Family'
            state = $State; blockReason = $(if ($State -eq 'BLOCKED') { 'quota-shortfall' } else { $null })
            demand = [ordered]@{ instances = 1; reservableInstances = $Reservable; vcpus = 2; overlapWithSource = $false }
            quota = [ordered]@{ limit = 100; used = 0; requestId = $null; requestedUtc = $null }
            notes = @()
        }
        if ($State -in @('RESERVED', 'CONSUMED')) {
            $claim.reservation = [ordered]@{ groupId = '/subscriptions/00000000-0000-0000-0000-000000000000/g'
                                             reservationId = '/subscriptions/00000000-0000-0000-0000-000000000000/g/r'
                                             createdUtc = 'x'; releasedUtc = $null; consumedInstances = 0 }
        }
        [pscustomobject]$claim
    }

    function Global:BcStoreClaim {
        param($RunPath, [string]$Name, $Claim)
        $dir = Join-Path $RunPath 'capacity'
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $Claim | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $dir "$Name.json") -Encoding utf8NoBOM
    }

    function Global:BcWritePlan {
        param($RunPath, $Entries)
        $planPath = Join-Path $RunPath 'plan.json'
        @{ schemaVersion = 1; assessmentRunId = 'bcover'; entries = @($Entries) } |
            ConvertTo-Json -Depth 10 | Set-Content $planPath -Encoding utf8NoBOM
        $planPath
    }

    function Global:BcWriteState {
        param($RunPath, $Entry, [string]$State, [switch]$Started, [string]$Checkpoint, [string]$MovePath = 'A', [switch]$Leased)
        $doc = [ordered]@{ schemaVersion = 3; vmId = $Entry.vmId; state = $State }
        if ($Started) { $doc.captured = [ordered]@{ startedTarget = [ordered]@{ path = $MovePath; target = [ordered]@{ size = $Entry.target.size } } } }
        if ($Checkpoint) { $doc.pathCheckpoint = $Checkpoint }
        if ($Leased) { $doc.lease = [ordered]@{ workerId = 'worker-1'; acquiredUtc = '2026-10-16T10:00:00Z' } }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath; id = $Entry.vmId; d = $doc } {
            Write-VmfStoreJson -RunPath $rp -RelPath ("state/" + (Get-VmfVmKey -VmId $id) + '.json') -Document $d -Depth 8
        }
    }

    function Global:BcNewRun {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-bcov-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { Initialize-VmfRun -RunPath $rp -RunId 'bcover' | Out-Null }
        $rp
    }

    function Global:BcEvents {
        param($RunPath, [string]$Outcome)
        InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath; o = $Outcome } {
            @(Read-VmfEvents -RunPath $rp -Step 'capacity' | Where-Object { -not $o -or $_.outcome -eq $o })
        }
    }
}
AfterAll {
    foreach ($f in 'BcEntry', 'BcClaim', 'BcStoreClaim', 'BcWritePlan', 'BcWriteState', 'BcNewRun', 'BcEvents') {
        Remove-Item "function:\$f" -ErrorAction SilentlyContinue
    }
}

Describe 'RESERVE-COVER-2: which machines a set of records covers on the quota rung' {

    It 'a PARTIAL set: the machines of the missing cells have no record, of either kind' {
        $e = @(
            BcEntry -Name 'app-1'
            BcEntry -Name 'app-2' -Size 'Standard_E2s_v6'
            BcEntry -Name 'ha-1' -Size 'Standard_D4s_v6' -Avset)
        InModuleScope VmMigrationFactory -Parameters @{ e = $e; c = @(BcClaim) } {
            $gaps = @(Get-VmfReservedCoverageGaps -Gate BestEffort -Claims $c -Entries $e)
            @($gaps.Name) -join ',' | Should -Be 'app-2,ha-1'
            @($gaps | Where-Object Kind -ne 'noRecord').Count | Should -Be 0
            ($gaps | Where-Object Name -eq 'app-2').Size | Should -Be 'Standard_E2s_v6'
        }
    }

    It 'any machine is covered by QUOTA_VERIFIED, RESERVED or CONSUMED - a reservation is not asked for' {
        InModuleScope VmMigrationFactory -Parameters @{ e = @(BcEntry -Name 'app-1') } {
            foreach ($s in 'QUOTA_VERIFIED', 'RESERVED', 'CONSUMED') {
                @(Get-VmfReservedCoverageGaps -Gate BestEffort -Entries $e -Claims @(BcClaim -State $s)).Count | Should -Be 0 -Because $s
            }
            (Get-VmfReservedCoverageGaps -Gate BestEffort -Entries $e -Claims @(BcClaim -State 'BLOCKED')).Kind | Should -Be 'quota'
            (Get-VmfReservedCoverageGaps -Gate BestEffort -Entries $e -Claims @()).Kind | Should -Be 'noRecord'
            # The Reserved rung is unchanged: the same record is not a reservation.
            (Get-VmfReservedCoverageGaps -Entries $e -Claims @(BcClaim)).Kind | Should -Be 'notReserved'
        }
    }

    It 'a record that counts no machine a reservation can hold still covers an ordinary machine - its quota was checked' {
        InModuleScope VmMigrationFactory -Parameters @{ e = @(BcEntry -Name 'app-1') } {
            @(Get-VmfReservedCoverageGaps -Gate BestEffort -Entries $e -Claims @(BcClaim -Reservable 0)).Count | Should -Be 0
        }
    }

    It 'a machine left out (MIGRATED, SKIPPED, or outside the scope of this tool) needs no record' {
        $done = BcEntry -Name 'app-1'
        $out = BcEntry -Name 'gpu-1' -Size 'Standard_E8ds_v5' -Source 'Standard_NC8as_T4_v3'
        InModuleScope VmMigrationFactory -Parameters @{ e = @($done, $out); ids = @($done.vmId, $out.vmId) } {
            @(Get-VmfReservedCoverageGaps -Gate BestEffort -Entries $e -FinishedVmIds $ids -Claims @()).Count | Should -Be 0
        }
    }

    It 'a machine with no record is named for a check of the quota and a start - never for a reservation' {
        $e = @(BcEntry -Name 'app-1'; BcEntry -Name 'app-2' -Size 'Standard_E2s_v6')
        $r = InModuleScope VmMigrationFactory -Parameters @{ e = $e } {
            $gaps = @(Get-VmfReservedCoverageGaps -Gate BestEffort -Entries $e -Claims @(BcClaim) | Where-Object Kind -eq 'noRecord')
            Get-VmfReservedCoverRefusal -Gate BestEffort -Wave 'wave-1' -Gaps $gaps
        }
        $r.Code | Should -Be 'noQuotaRecordGeneral'
        $r.Gate | Should -Be 'capacity'
        $r.Detail | Should -Match "^Wave wave-1 has no quota record for machine 'app-2' \(Standard_E2s_v6\)\."
        $r.Detail | Should -Match 'select Check the quota at the top, then select Start this wave'
        $r.Detail | Should -Not -Match 'Reserve capacity'
    }
}

Describe 'RESERVE-COVER-2: the BestEffort capacity gate judges the machines' {
    BeforeEach { $script:runPath = BcNewRun }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'THE DEFECT: a partial set of QUOTA_VERIFIED records FAILS, and names the machine with no record' {
        BcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (BcClaim)
        $e = @(BcEntry -Name 'app-1'; BcEntry -Name 'app-2' -Size 'Standard_E2s_v6')
        $r = Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'wave-1' -Gate 'BestEffort' -Entries $e
        $r.Pass | Should -BeFalse -Because 'every record that existed was QUOTA_VERIFIED, so it passed'
        $r.Detail | Should -Match 'app-2'
        $r.Detail | Should -Match 'check the quota again'
        @($r.Uncovered).Count | Should -Be 1
        $r.Uncovered[0].Name | Should -Be 'app-2'
        $r.Uncovered[0].Size | Should -Be 'Standard_E2s_v6'
    }

    It 'an availability-set machine with no record fails it too' {
        BcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (BcClaim)
        $e = @(BcEntry -Name 'app-1'; BcEntry -Name 'ha-1' -Avset -Size 'Standard_D4s_v6')
        $r = Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'wave-1' -Gate 'BestEffort' -Entries $e
        $r.Pass | Should -BeFalse
        $r.Uncovered[0].Name | Should -Be 'ha-1'
    }

    It 'every machine covered: passes, as before' {
        BcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (BcClaim)
        BcStoreClaim -RunPath $script:runPath -Name 'b' -Claim (BcClaim -Size 'Standard_D4s_v6' -Reservable 0)
        $e = @(BcEntry -Name 'app-1'; BcEntry -Name 'ha-1' -Avset -Size 'Standard_D4s_v6')
        $r = Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'wave-1' -Gate 'BestEffort' -Entries $e
        $r.Pass | Should -BeTrue -Because $r.Detail
        @($r.Uncovered).Count | Should -Be 0
    }

    It 'a blocked record still fails on its state, as before' {
        BcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (BcClaim -State 'BLOCKED')
        $r = Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'wave-1' -Gate 'BestEffort' -Entries @(BcEntry -Name 'app-1')
        $r.Pass | Should -BeFalse
        $r.Detail | Should -Match 'BLOCKED'
    }

    It 'with no entries given it reads the plan and the state documents of the run' {
        BcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (BcClaim)
        $done = BcEntry -Name 'app-2' -Size 'Standard_E2s_v6'
        BcWritePlan -RunPath $script:runPath -Entries @((BcEntry -Name 'app-1'), $done) | Out-Null
        (Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'wave-1' -Gate 'BestEffort').Pass | Should -BeFalse
        BcWriteState -RunPath $script:runPath -Entry $done -State 'MIGRATED'
        $r = Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'wave-1' -Gate 'BestEffort'
        $r.Pass | Should -BeTrue -Because "a MIGRATED machine needs no record: $($r.Detail)"
    }

    It 'a gate with no plan to read is not a pass - unknown is not covered' {
        BcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (BcClaim)
        $r = Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'wave-1' -Gate 'BestEffort'
        $r.Pass | Should -BeFalse
        $r.Detail | Should -Match 'plan could not be read'
    }

    It 'a record that counts no reservable machine covers an ordinary machine on BestEffort, and not on Reserved' {
        # Independent review: without this, judging BestEffort on the Reserved
        # rung at the call sites survived every test. The record was written
        # for a plan in which the machine was in an availability set: its
        # quota was checked, and nothing was reserved for it.
        BcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (BcClaim -Reservable 0)
        $e = @(BcEntry -Name 'app-1')
        $r = Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'wave-1' -Gate 'BestEffort' -Entries $e
        $r.Pass | Should -BeTrue -Because $r.Detail
        @($r.Uncovered).Count | Should -Be 0
        $r = Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'wave-1' -Gate 'Reserved' -Entries $e
        $r.Pass | Should -BeFalse
        $r.Uncovered[0].Name | Should -Be 'app-1'
    }

    It 'a blocked record of a cell whose machines are done does not refuse the rest of the wave' {
        # RESERVE-COVER-1 review finding 1, on this rung: no quota check
        # replaces a record of a cell with no machine left to move, so judged,
        # it would refuse every restart of the wave for ever.
        $done = BcEntry -Name 'app-1'
        $open = BcEntry -Name 'app-2' -Size 'Standard_E2s_v6'
        BcWritePlan -RunPath $script:runPath -Entries @($done, $open) | Out-Null
        BcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (BcClaim -State 'BLOCKED')
        BcStoreClaim -RunPath $script:runPath -Name 'b' -Claim (BcClaim -Size 'Standard_E2s_v6')
        (Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'wave-1' -Gate 'BestEffort').Pass | Should -BeFalse -Because 'app-1 still moves'
        BcWriteState -RunPath $script:runPath -Entry $done -State 'MIGRATED'
        $r = Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'wave-1' -Gate 'BestEffort'
        $r.Pass | Should -BeTrue -Because $r.Detail
    }

    It 'a MIXED wave: the machine outside the scope of this tool needs no record, the one that moves does' {
        $gpu = BcEntry -Name 'gpu-1' -Size 'Standard_E8ds_v5' -Source 'Standard_NC8as_T4_v3'
        $app = BcEntry -Name 'app-1'
        BcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (BcClaim)
        (Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'wave-1' -Gate 'BestEffort' -Entries @($gpu, $app)).Pass |
            Should -BeTrue
        # A machine outside the scope whose move HAS started finishes it, and uses quota.
        BcWriteState -RunPath $script:runPath -Entry $gpu -State 'CONVERTING' -Started
        $r = Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'wave-1' -Gate 'BestEffort' -Entries @($gpu, $app)
        $r.Pass | Should -BeFalse
        $r.Uncovered[0].Name | Should -Be 'gpu-1'
    }
}

Describe 'RESERVE-COVER-2: Start-VmfWave on a BestEffort wave' {
    BeforeEach {
        $script:runPath = BcNewRun
        $script:app1 = BcEntry -Name 'app-1'
        $script:app2 = BcEntry -Name 'app-2' -Size 'Standard_E2s_v6'
        $script:ha1 = BcEntry -Name 'ha-1' -Avset -Size 'Standard_D4s_v6'
        $script:planPath = BcWritePlan -RunPath $script:runPath -Entries @($script:app1, $script:app2, $script:ha1)

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

    It 'THE DEFECT: two of three cells on record - checks the quota of the wave, then REFUSES naming the machine, when the check adds nothing' {
        BcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (BcClaim)
        BcStoreClaim -RunPath $script:runPath -Name 'c' -Claim (BcClaim -Size 'Standard_D4s_v6' -Reservable 0)
        # Azure still fails on the missing cell: the check writes nothing.
        Mock -ModuleName VmMigrationFactory Test-VmfQuota { }
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw "Wave wave-1 has no quota record for machine 'app-2' (Standard_E2s_v6). In the wave editor, select Check the quota at the top, then select Start this wave*"
        Should -Invoke -ModuleName VmMigrationFactory Test-VmfQuota -Times 1 -Exactly -ParameterFilter { $Wave -eq 'wave-1' }
        $said = @(BcEvents -RunPath $script:runPath -Outcome 'refused')
        @($said).Count | Should -Be 1
        $said[0].detail | Should -Match "'app-2'"
        # GATE-WORDS-1: the code and the wave travel in the event.
        $said[0].code | Should -Be 'noQuotaRecordGeneral'
        $said[0].wave | Should -Be 'wave-1'
        # The check is said before it runs, with how many machines it is for.
        (@(BcEvents -RunPath $script:runPath -Outcome 'info').detail -join ' ') | Should -Match '1 machine of wave ''wave-1'' has no quota record\. The product checks the quota now\.'
    }

    It 'when the check writes the missing cell, the wave starts' {
        BcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (BcClaim)
        BcStoreClaim -RunPath $script:runPath -Name 'c' -Claim (BcClaim -Size 'Standard_D4s_v6' -Reservable 0)
        Mock -ModuleName VmMigrationFactory Test-VmfQuota {
            BcStoreClaim -RunPath $script:runPath -Name 'b' -Claim (BcClaim -Size 'Standard_E2s_v6')
        }
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw '*PAST-THE-CAPACITY-GATE*'
        Should -Invoke -ModuleName VmMigrationFactory Test-VmfQuota -Times 1 -Exactly -ParameterFilter { $Wave -eq 'wave-1' }
    }

    It 'when the check writes the missing cell BLOCKED, it is refused on the quota, naming the machine' {
        BcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (BcClaim)
        BcStoreClaim -RunPath $script:runPath -Name 'c' -Claim (BcClaim -Size 'Standard_D4s_v6' -Reservable 0)
        Mock -ModuleName VmMigrationFactory Test-VmfQuota {
            BcStoreClaim -RunPath $script:runPath -Name 'b' -Claim (BcClaim -Size 'Standard_E2s_v6' -State 'BLOCKED')
        }
        # RESERVE-RECHECK-1: GATE-WORDS-1's two sentences, which say quota -
        # not the gate's raw detail, which said "Capacity gate".
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw "The quota is not enough for machine 'app-2' (Standard_E2s_v6) in wave wave-1.*"
    }

    It 'a missing AVAILABILITY-SET cell is checked, and named when the check writes nothing' {
        BcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (BcClaim)
        BcStoreClaim -RunPath $script:runPath -Name 'b' -Claim (BcClaim -Size 'Standard_E2s_v6')
        Mock -ModuleName VmMigrationFactory Test-VmfQuota { }
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw "*no quota record for machine 'ha-1' (Standard_D4s_v6)*"
        Should -Invoke -ModuleName VmMigrationFactory Test-VmfQuota -Times 1 -Exactly
    }

    It 'every machine covered: the quota is checked again (RESERVE-RECHECK-1), and the wave starts' {
        BcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (BcClaim)
        BcStoreClaim -RunPath $script:runPath -Name 'b' -Claim (BcClaim -Size 'Standard_E2s_v6')
        BcStoreClaim -RunPath $script:runPath -Name 'c' -Claim (BcClaim -Size 'Standard_D4s_v6' -Reservable 0)
        Mock -ModuleName VmMigrationFactory Test-VmfQuota { }
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw '*PAST-THE-CAPACITY-GATE*'
        Should -Invoke -ModuleName VmMigrationFactory Test-VmfQuota -Times 1 -Exactly -ParameterFilter { $Wave -eq 'wave-1' }
    }

    It 'a record that counts no reservable machine covers an ordinary machine: the wave starts' {
        # Independent review: the start asks the BestEffort rung, never the
        # Reserved one - on the Reserved rung this record covers nothing.
        BcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (BcClaim -Reservable 0)
        BcStoreClaim -RunPath $script:runPath -Name 'b' -Claim (BcClaim -Size 'Standard_E2s_v6' -Reservable 0)
        BcStoreClaim -RunPath $script:runPath -Name 'c' -Claim (BcClaim -Size 'Standard_D4s_v6' -Reservable 0)
        Mock -ModuleName VmMigrationFactory Test-VmfQuota { }
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw '*PAST-THE-CAPACITY-GATE*'
    }

    It 'no record at all: the quota is checked and the wave starts on what it writes, as before' {
        Mock -ModuleName VmMigrationFactory Test-VmfQuota {
            BcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (BcClaim)
            BcStoreClaim -RunPath $script:runPath -Name 'b' -Claim (BcClaim -Size 'Standard_E2s_v6')
            BcStoreClaim -RunPath $script:runPath -Name 'c' -Claim (BcClaim -Size 'Standard_D4s_v6' -Reservable 0)
        }
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw '*PAST-THE-CAPACITY-GATE*'
        Should -Invoke -ModuleName VmMigrationFactory Test-VmfQuota -Times 1 -Exactly -ParameterFilter { $Wave -eq 'wave-1' }
    }

    It 'a SECOND CONTAINER that reads while the first is still writing checks the quota itself, rather than start or refuse' {
        BcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (BcClaim)
        BcStoreClaim -RunPath $script:runPath -Name 'b' -Claim (BcClaim -Size 'Standard_E2s_v6')
        Mock -ModuleName VmMigrationFactory Test-VmfQuota {
            BcStoreClaim -RunPath $script:runPath -Name 'c' -Claim (BcClaim -Size 'Standard_D4s_v6' -Reservable 0)
        }
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath -Container '2/2' } |
            Should -Throw '*PAST-THE-CAPACITY-GATE*'
        Should -Invoke -ModuleName VmMigrationFactory Test-VmfQuota -Times 1 -Exactly -ParameterFilter { $Wave -eq 'wave-1' }
    }

    It 'a restart after machines MIGRATED and SKIPPED asks a record only for the machine left to move' {
        BcWriteState -RunPath $script:runPath -Entry $script:app1 -State 'MIGRATED'
        BcWriteState -RunPath $script:runPath -Entry $script:app2 -State 'SKIPPED'
        BcStoreClaim -RunPath $script:runPath -Name 'c' -Claim (BcClaim -Size 'Standard_D4s_v6' -Reservable 0)
        Mock -ModuleName VmMigrationFactory Test-VmfQuota { }
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw '*PAST-THE-CAPACITY-GATE*'
    }

    It 'a MIXED wave with a machine outside the scope of this tool starts on the record of the machine that moves' {
        $gpu = BcEntry -Name 'gpu-1' -Size 'Standard_E8ds_v5' -Source 'Standard_NC8as_T4_v3'
        $plan = BcWritePlan -RunPath $script:runPath -Entries @($gpu, $script:app1)
        BcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (BcClaim)
        Mock -ModuleName VmMigrationFactory Test-VmfQuota { }
        { Start-VmfWave -PlanPath $plan -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw '*PAST-THE-CAPACITY-GATE*'
    }

    It 'and a wave of ONLY machines outside the scope of this tool still skips the capacity gate' {
        $plan = BcWritePlan -RunPath $script:runPath -Entries @(BcEntry -Name 'gpu-1' -Size 'Standard_E8ds_v5' -Source 'Standard_NC8as_T4_v3')
        Mock -ModuleName VmMigrationFactory Test-VmfQuota { throw 'NOT-EXPECTED' }
        { Start-VmfWave -PlanPath $plan -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw '*PAST-THE-CAPACITY-GATE*'
    }

    It 'a machine outside the scope whose move HAS STARTED is not judged by the start - it finishes the move it started' {
        # QUOTA-STARTED-TWICE-1: this test asked a record for it and refused
        # the start without one. A refused start left it stopped mid-move.
        $gpu = BcEntry -Name 'gpu-1' -Size 'Standard_E8ds_v5' -Source 'Standard_NC8as_T4_v3'
        $plan = BcWritePlan -RunPath $script:runPath -Entries @($gpu, $script:app1)
        BcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (BcClaim)
        BcWriteState -RunPath $script:runPath -Entry $gpu -State 'CONVERTING' -Started
        Mock -ModuleName VmMigrationFactory Test-VmfQuota { }
        { Start-VmfWave -PlanPath $plan -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw '*PAST-THE-CAPACITY-GATE*'
        Should -Invoke -ModuleName VmMigrationFactory Test-VmfQuota -Times 1 -Exactly -ParameterFilter { $LeaveOutStarted }
    }
}

# RESERVE-RECHECK-1, 2026-10-16. A start used to trust the quota records when
# every machine of the wave had one, so a resumed wave started on a record that
# could be weeks old - and something else may have taken the quota since. The
# decision: check the quota again at every start. A shortfall it finds
# refuses the start with GATE-WORDS-1's two sentences, which say quota.
Describe 'RESERVE-RECHECK-1: every start checks the quota of the wave again' {
    BeforeEach {
        $script:runPath = BcNewRun
        $script:app1 = BcEntry -Name 'app-1'
        $script:app2 = BcEntry -Name 'app-2' -Size 'Standard_E2s_v6'
        $script:planPath = BcWritePlan -RunPath $script:runPath -Entries @($script:app1, $script:app2)
        BcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (BcClaim)
        BcStoreClaim -RunPath $script:runPath -Name 'b' -Claim (BcClaim -Size 'Standard_E2s_v6')

        Mock -ModuleName VmMigrationFactory Test-VmfRunAcknowledged { [pscustomobject]@{ Pass = $true } }
        Mock -ModuleName VmMigrationFactory Test-VmfWaveOptionsAccepted { [pscustomobject]@{ Pass = $true } }
        Mock -ModuleName VmMigrationFactory Test-VmfVmClaims { [pscustomobject]@{ Pass = $true } }
        Mock -ModuleName VmMigrationFactory Test-VmfWaveSubscriptions { [pscustomobject]@{ Pass = $true } }
        Mock -ModuleName VmMigrationFactory Test-VmfWaveApproval { [pscustomobject]@{ Pass = $true } }
        # STEP-LOG-5: the launch of the workers, not the wave's start line,
        # which no longer stops a start when it cannot be written.
        Mock -ModuleName VmMigrationFactory Start-Process { throw 'PAST-THE-CAPACITY-GATE' }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'THE DECISION: every machine has a record, and the start still checks the quota of THIS wave, and says so' {
        Mock -ModuleName VmMigrationFactory Test-VmfQuota { }
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw '*PAST-THE-CAPACITY-GATE*'
        Should -Invoke -ModuleName VmMigrationFactory Test-VmfQuota -Times 1 -Exactly -ParameterFilter { $Wave -eq 'wave-1' }
        (@(BcEvents -RunPath $script:runPath -Outcome 'info').detail -join ' ') |
            Should -Match "checks the quota of wave 'wave-1' again"
    }

    It 'THE DEFECT: quota taken since the last check - the check writes BLOCKED, and the start is refused on the quota' {
        Mock -ModuleName VmMigrationFactory Test-VmfQuota {
            BcStoreClaim -RunPath $script:runPath -Name 'b' -Claim (BcClaim -Size 'Standard_E2s_v6' -State 'BLOCKED')
        }
        $err = $null
        try { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } catch { $err = $_.Exception.Message }
        $err | Should -Not -BeNullOrEmpty
        $err | Should -Not -Match 'PAST-THE-CAPACITY-GATE' -Because 'the records were good when they were written, and are not now'
        $err | Should -BeExactly ("The quota is not enough for machine 'app-2' (Standard_E2s_v6) in wave wave-1. " +
                                  'In the wave editor, select Request an increase, then select Check the quota again.')
        # QUOTA-NOT-CAPACITY-1: a quota shortfall is said as quota.
        $err | Should -Not -Match 'capacity'
        $said = @(BcEvents -RunPath $script:runPath -Outcome 'refused')
        @($said).Count | Should -Be 1
        $said[0].code | Should -Be 'quotaShortGeneral'
        $said[0].wave | Should -Be 'wave-1'
    }

    It 'a size Azure no longer offers there is refused with its own instruction' {
        Mock -ModuleName VmMigrationFactory Test-VmfQuota {
            $c = BcClaim -Size 'Standard_E2s_v6' -State 'BLOCKED'; $c.blockReason = 'sku-restricted'
            BcStoreClaim -RunPath $script:runPath -Name 'b' -Claim $c
        }
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw "Azure does not offer the size of machine 'app-2' (Standard_E2s_v6) in wave wave-1.*Change target*"
        (@(BcEvents -RunPath $script:runPath -Outcome 'refused'))[0].code | Should -Be 'sizeBlockedGeneral'
    }

    It 'a blocked record with no reason is refused as blocked' {
        Mock -ModuleName VmMigrationFactory Test-VmfQuota {
            $c = BcClaim -Size 'Standard_E2s_v6' -State 'BLOCKED'; $c.blockReason = $null
            BcStoreClaim -RunPath $script:runPath -Name 'b' -Claim $c
        }
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw "The quota check of wave wave-1 is blocked for machine 'app-2' (Standard_E2s_v6)*"
        (@(BcEvents -RunPath $script:runPath -Outcome 'refused'))[0].code | Should -Be 'quotaBlockedGeneral'
    }

    It 'a check Azure does not answer stops the start - the old records are not a pass' {
        Mock -ModuleName VmMigrationFactory Test-VmfQuota { throw 'AZURE-DID-NOT-ANSWER' }
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw "The quota check of wave wave-1 did not finish for machines 'app-1' (Standard_D2s_v6) and 'app-2' (Standard_E2s_v6).*"
    }

    It 'a machine already MIGRATED is not judged on a blocked record of its cell' {
        BcWriteState -RunPath $script:runPath -Entry $script:app2 -State 'MIGRATED'
        Mock -ModuleName VmMigrationFactory Test-VmfQuota { }
        BcStoreClaim -RunPath $script:runPath -Name 'b' -Claim (BcClaim -Size 'Standard_E2s_v6' -State 'BLOCKED')
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw '*PAST-THE-CAPACITY-GATE*'
    }

    It 'a Reserved wave with every record held checks the quota again too, and starts on its reservations' {
        foreach ($e in $script:app1, $script:app2) { $e.policy.capacityGate = 'Reserved' }
        $plan = BcWritePlan -RunPath $script:runPath -Entries @($script:app1, $script:app2)
        BcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (BcClaim -State 'RESERVED')
        BcStoreClaim -RunPath $script:runPath -Name 'b' -Claim (BcClaim -Size 'Standard_E2s_v6' -State 'RESERVED')
        Mock -ModuleName VmMigrationFactory Test-VmfQuota { }
        { Start-VmfWave -PlanPath $plan -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw '*PAST-THE-CAPACITY-GATE*'
        Should -Invoke -ModuleName VmMigrationFactory Test-VmfQuota -Times 1 -Exactly -ParameterFilter { $Wave -eq 'wave-1' }
    }

    It 'a Reserved wave: an availability-set machine whose quota check is now blocked is refused on the quota' {
        foreach ($e in $script:app1) { $e.policy.capacityGate = 'Reserved' }
        $ha = BcEntry -Name 'ha-1' -Avset -Size 'Standard_D4s_v6'
        $ha.policy.capacityGate = 'Reserved'
        $plan = BcWritePlan -RunPath $script:runPath -Entries @($script:app1, $ha)
        BcStoreClaim -RunPath $script:runPath -Name 'a' -Claim (BcClaim -State 'RESERVED')
        Remove-Item (Join-Path $script:runPath 'capacity' 'b.json')
        BcStoreClaim -RunPath $script:runPath -Name 'c' -Claim (BcClaim -Size 'Standard_D4s_v6' -Reservable 0)
        Mock -ModuleName VmMigrationFactory Test-VmfQuota {
            BcStoreClaim -RunPath $script:runPath -Name 'c' -Claim (BcClaim -Size 'Standard_D4s_v6' -Reservable 0 -State 'BLOCKED')
        }
        { Start-VmfWave -PlanPath $plan -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw "The quota is not enough for machine 'ha-1' (Standard_D4s_v6) in wave wave-1.*"
    }
}

# QUOTA-STARTED-TWICE-1, 2026-10-16, fixed with RESERVE-RECHECK-1. Every start
# checks the quota again, and the check counted a machine whose move has
# started: Azure's usage figure already counts it once its size changed, so
# its vCPUs were asked for twice. A restart of a part-run wave could then be
# refused, and the machine stopped mid-move stayed stopped - against one change
# window. The start now counts and judges only the machines whose move has not
# started. A started machine finishes its move, or fails at its resize and
# rolls back. THESE TESTS RUN THE REAL QUOTA CHECK, with Azure's answers mocked.
Describe 'QUOTA-STARTED-TWICE-1: the start never refuses a wave for a machine whose move has started' {
    BeforeEach {
        $script:runPath = BcNewRun
        $script:moving = BcEntry -Name 'app-1'
        $script:waiting = BcEntry -Name 'app-2'
        $script:planPath = BcWritePlan -RunPath $script:runPath -Entries @($script:moving, $script:waiting)
        $script:limit = 4
        $script:used = 0
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
            @([pscustomobject]@{ Name = 'Standard_D2s_v6'; ResourceType = 'virtualMachines'; Family = 'StandardDSv6Family'; Restrictions = @()
                                 Capabilities = @([pscustomobject]@{ Name = 'vCPUs'; Value = '2' }) })
        }
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @([pscustomobject]@{ Name = [pscustomobject]@{ Value = 'StandardDSv6Family' }; CurrentValue = $script:used; Limit = $script:limit })
        }
        Mock -ModuleName VmMigrationFactory Get-VmfRetailPrice { $null }
        # The records of the first check, before anything moved: both fit.
        Test-VmfQuota -PlanPath $script:planPath -OutPath $script:runPath -Wave 'wave-1' | Out-Null
        # app-1 is mid-move and already on its target size (VALIDATING): Azure
        # counts its 2 vCPUs.
        BcWriteState -RunPath $script:runPath -Entry $script:moving -State 'VALIDATING' -Started
        $script:used = 2

        Mock -ModuleName VmMigrationFactory Test-VmfRunAcknowledged { [pscustomobject]@{ Pass = $true } }
        Mock -ModuleName VmMigrationFactory Test-VmfWaveOptionsAccepted { [pscustomobject]@{ Pass = $true } }
        Mock -ModuleName VmMigrationFactory Test-VmfVmClaims { [pscustomobject]@{ Pass = $true } }
        Mock -ModuleName VmMigrationFactory Test-VmfWaveSubscriptions { [pscustomobject]@{ Pass = $true } }
        Mock -ModuleName VmMigrationFactory Test-VmfWaveApproval { [pscustomobject]@{ Pass = $true } }
        # STEP-LOG-5: the launch of the workers, not the wave's start line,
        # which no longer stops a start when it cannot be written.
        Mock -ModuleName VmMigrationFactory Start-Process { throw 'PAST-THE-CAPACITY-GATE' }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'THE DEFECT: quota for exactly the machine still to start - the restart is NOT refused, and the started machine is taken' {
        # Headroom 2, and app-2 asks for 2. Counted with app-1 the ask was 4.
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw '*PAST-THE-CAPACITY-GATE*'
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfVmUsage -Times 2 -Exactly -Because 'the quota was checked again, after the first check'
        @(BcEvents -RunPath $script:runPath -Outcome 'refused').Count | Should -Be 0
    }

    It 'the record the start writes asks only for the machine still to start' {
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw '*PAST-THE-CAPACITY-GATE*'
        $rec = @(InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Get-VmfStoreNames -RunPath $rp -Folder 'capacity' -Extension '.json' |
                ForEach-Object { Read-VmfStoreJson -RunPath $rp -RelPath "capacity/$_" -Depth 12 } |
                Where-Object { $_.wave -eq 'wave-1' } })
        @($rec | Where-Object state -eq 'QUOTA_VERIFIED').Count | Should -BeGreaterThan 0
        @($rec | Where-Object { $_.demand.instances -eq 2 }).Count | Should -Be 0 -Because 'app-1 is in the usage figure already'
    }

    It 'a machine NOT started, with too little quota, is still refused as RESERVE-RECHECK-1 built it' {
        $script:limit = 3
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw "The quota is not enough for machine 'app-2' (Standard_D2s_v6) in wave wave-1.*"
    }

    It 'the refusal never names the started machine' {
        $script:limit = 2
        $err = $null
        try { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } catch { $err = $_.Exception.Message }
        $err | Should -Match "'app-2'"
        $err | Should -Not -Match "'app-1'"
    }

    It 'every machine left has started: no quota refusal at all, and no quota check' {
        BcWriteState -RunPath $script:runPath -Entry $script:waiting -State 'STOPPED' -Started
        $script:limit = 0
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw '*PAST-THE-CAPACITY-GATE*'
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfVmUsage -Times 1 -Exactly -Because 'only the first check asked Azure'
        (@(BcEvents -RunPath $script:runPath -Outcome 'info').detail -join ' ') | Should -Match 'has started its move'
    }

    It 'every machine left has started, with no record and a BLOCKED one: not refused either' {
        Get-ChildItem (Join-Path $script:runPath 'capacity') -Filter '*.json' | Remove-Item
        BcWriteState -RunPath $script:runPath -Entry $script:waiting -State 'STOPPED' -Started
        BcStoreClaim -RunPath $script:runPath -Name 'b' -Claim (BcClaim -State 'BLOCKED')
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw '*PAST-THE-CAPACITY-GATE*'
    }

    It 'the only other machine is outside the scope of this tool and not started: still no quota check' {
        # PRECHECK stops it untouched, so it uses no quota: the started machine
        # is all the wave has left to move.
        $gpu = BcEntry -Name 'gpu-1' -Size 'Standard_E8ds_v5' -Source 'Standard_NC8as_T4_v3'
        $plan = BcWritePlan -RunPath $script:runPath -Entries @($script:moving, $gpu)
        Mock -ModuleName VmMigrationFactory Test-VmfQuota { throw 'NOT-EXPECTED' }
        { Start-VmfWave -PlanPath $plan -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw '*PAST-THE-CAPACITY-GATE*'
        (@(BcEvents -RunPath $script:runPath -Outcome 'info').detail -join ' ') | Should -Match 'has started its move'
    }

    It 'a wave whose every machine is MIGRATED or SKIPPED is not said to have machines mid-move' {
        BcWriteState -RunPath $script:runPath -Entry $script:moving -State 'MIGRATED' -Started
        BcWriteState -RunPath $script:runPath -Entry $script:waiting -State 'SKIPPED'
        Mock -ModuleName VmMigrationFactory Test-VmfQuota { }
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw '*PAST-THE-CAPACITY-GATE*'
        Should -Invoke -ModuleName VmMigrationFactory Test-VmfQuota -Times 1 -Exactly
        (@(BcEvents -RunPath $script:runPath -Outcome 'info').detail -join ' ') | Should -Not -Match 'has started its move'
    }
    It 'STARTING may not hold its new size yet: its need is counted first, the safe side for it' {
        BcWriteState -RunPath $script:runPath -Entry $script:moving -State 'STARTING' -Started
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw "The quota is not enough for machine 'app-2'*"
        $script:limit = 6
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw '*PAST-THE-CAPACITY-GATE*'
    }

    It 'the started machines alone need more than is free: the start is not refused for them, only for the machine not started' {
        BcWriteState -RunPath $script:runPath -Entry $script:moving -State 'STOPPED' -Started
        $script:used = 0
        $script:limit = 1
        $err = $null
        try { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } catch { $err = $_.Exception.Message }
        $err | Should -Match "^The quota is not enough for machine 'app-2'"
        $err | Should -Not -Match "'app-1'"
        BcWriteState -RunPath $script:runPath -Entry $script:waiting -State 'SAFETY_COPY' -Started
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw '*PAST-THE-CAPACITY-GATE*'
    }

    It 'a started machine whose size the size list does not show: not refused, and the log says its quota was not counted' {
        $odd = BcEntry -Name 'app-1' -Size 'Standard_Z9s_v9'
        BcWriteState -RunPath $script:runPath -Entry $odd -State 'STOPPED' -Started
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw '*PAST-THE-CAPACITY-GATE*'
        $warn = @(BcEvents -RunPath $script:runPath -Outcome 'warn' | Where-Object { $_.detail -match 'app-1' })
        @($warn).Count | Should -Be 1
        $warn[0].detail | Should -Match 'Standard_Z9s_v9'
        $warn[0].detail | Should -Match 'not counted'
    }

    It 'two regions, and Azure gives no usage for the second: no record is written, the first region''s included' {
        $east = BcEntry -Name 'app-4'
        $east.assessment.location = 'eastus'
        $plan = BcWritePlan -RunPath $script:runPath -Entries @((BcEntry -Name 'app-3'), $east)
        Get-ChildItem (Join-Path $script:runPath 'capacity') -Filter '*.json' | Remove-Item
        $script:used = 0
        Test-VmfQuota -PlanPath $plan -OutPath $script:runPath -Wave 'wave-1' | Out-Null
        $script:used = 1
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage -ParameterFilter { $Location -eq 'eastus' } { @() }
        { Start-VmfWave -PlanPath $plan -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw 'The quota check of wave wave-1 did not finish*'
        $rec = @(InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Get-VmfStoreNames -RunPath $rp -Folder 'capacity' -Extension '.json' |
                ForEach-Object { Read-VmfStoreJson -RunPath $rp -RelPath "capacity/$_" -Depth 12 } })
        @($rec).Count | Should -Be 2
        @($rec | Where-Object { [int]$_.quota.used -ne 0 }).Count | Should -Be 0 -Because 'a record written by the second check reads used 1'
    }
    It 'REBUILD-REMOVE-ENGINE-1: Path B after the rebuild (B:recreated) is no longer read as resized - its need is counted, the safe side' {
        # A machine an earlier version rebuilt is stopped, never continued, so
        # the checkpoint no longer says anything the quota check acts on.
        BcWriteState -RunPath $script:runPath -Entry $script:moving -State 'CONVERTING' -Started -MovePath 'B' -Checkpoint 'B:recreated'
        $err = $null
        try { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } catch { $err = $_.Exception.Message }
        $err | Should -Match "^The quota is not enough for machine 'app-2'"
    }

    It 'Path A with only the disk patched: the resize is not known, so its need is counted first - and it is never named' {
        BcWriteState -RunPath $script:runPath -Entry $script:moving -State 'CONVERTING' -Started -Checkpoint 'A:diskPatched'
        $err = $null
        try { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } catch { $err = $_.Exception.Message }
        $err | Should -Match "^The quota is not enough for machine 'app-2'" -Because 'free 2, less 2 for app-1, leaves 0 for app-2'
        $script:limit = 6
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw '*PAST-THE-CAPACITY-GATE*'
    }

    It 'STOPPED before its resize: Azure does not count it on its target size, so its need is counted first' {
        BcWriteState -RunPath $script:runPath -Entry $script:moving -State 'STOPPED' -Started
        $script:used = 0
        $script:limit = 3
        $err = $null
        try { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } catch { $err = $_.Exception.Message }
        $err | Should -Match "^The quota is not enough for machine 'app-2'" -Because 'free 3, less 2 for app-1, leaves 1 for app-2'
        $err | Should -Not -Match "'app-1'"
        $script:limit = 4
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw '*PAST-THE-CAPACITY-GATE*'
    }

    It '<State>: the next run starts a new attempt, so the machine is counted and judged like one not started' -ForEach @(
        @{ State = 'FAILED_ROLLED_BACK' }, @{ State = 'NEEDS_DECISION' }, @{ State = 'FAILED_NEEDS_ATTENTION' }) {
        BcWriteState -RunPath $script:runPath -Entry $script:moving -State $State -Started
        $script:used = 0
        $script:limit = 3
        $err = $null
        try { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } catch { $err = $_.Exception.Message }
        $err | Should -Match "^The quota is not enough for machines 'app-1' \(Standard_D2s_v6\) and 'app-2'"
        @(BcEvents -RunPath $script:runPath -Outcome 'info' | Where-Object { $_.detail -match 'has started its move' }).Count | Should -Be 0
    }

    It 'PLANNED with a lease and no move started: counted like one not started' {
        BcWriteState -RunPath $script:runPath -Entry $script:moving -State 'PLANNED' -Leased
        $script:used = 0
        $script:limit = 3
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw "The quota is not enough for machines 'app-1' (Standard_D2s_v6) and 'app-2'*"
    }

    It 'Azure does not answer the quota check: the start is refused with its own words, and the record is kept' {
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage { throw 'AZURE-DID-NOT-ANSWER' }
        $err = $null
        try { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } catch { $err = $_.Exception.Message }
        $err | Should -Match "^The quota check of wave wave-1 did not finish for machine 'app-2' \(Standard_D2s_v6\)\."
        $err | Should -Not -Match 'AZURE-DID-NOT-ANSWER'
        $said = @(BcEvents -RunPath $script:runPath -Outcome 'refused')
        @($said).Count | Should -Be 1
        $said[0].code | Should -Be 'quotaCheckFailed'
        $said[0].wave | Should -Be 'wave-1'
        $said[0].error | Should -Match 'AZURE-DID-NOT-ANSWER' -Because 'the log keeps what Azure said'
    }

    It '<Case>: never "size missing", never written over the good record - the start says the check did not finish' -ForEach @(
        @{ Case = 'an empty size list'; Which = 'catalog' }, @{ Case = 'an empty usage list'; Which = 'usage' }) {
        if ($Which -eq 'catalog') { Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @() } }
        else { Mock -ModuleName VmMigrationFactory Get-VmfVmUsage { @() } }
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw 'The quota check of wave wave-1 did not finish*'
        $rec = @(InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Get-VmfStoreNames -RunPath $rp -Folder 'capacity' -Extension '.json' |
                ForEach-Object { Read-VmfStoreJson -RunPath $rp -RelPath "capacity/$_" -Depth 12 } })
        @($rec | Where-Object state -ne 'QUOTA_VERIFIED').Count | Should -Be 0 -Because 'the record of the first check stays'
    }
    It 'a machine that is MIGRATED is not counted as started, and nothing changes for it' {
        BcWriteState -RunPath $script:runPath -Entry $script:moving -State 'MIGRATED' -Started
        $script:limit = 3
        { Start-VmfWave -PlanPath $script:planPath -Wave 'wave-1' -RunPath $script:runPath } |
            Should -Throw "The quota is not enough for machine 'app-2'*"
    }
}

Describe 'RESERVE-RECHECK-1 review: an empty size list from Azure is not kept' {
    It 'the next read asks Azure again, rather than see no sizes for the rest of the session' {
        $script:skuCalls = 0
        Mock -ModuleName VmMigrationFactory Get-AzComputeResourceSku {
            $script:skuCalls++
            if ($script:skuCalls -gt 1) { [pscustomobject]@{ Name = 'Standard_D2s_v6'; ResourceType = 'virtualMachines' } }
        }
        InModuleScope VmMigrationFactory { $script:VmfSkuCache = @{} }
        $first = @(InModuleScope VmMigrationFactory { Get-VmfSkuCatalog -Location 'emptyregion1' })
        $first.Count | Should -Be 0
        $second = @(InModuleScope VmMigrationFactory { Get-VmfSkuCatalog -Location 'emptyregion1' })
        $second.Count | Should -Be 1
        $script:skuCalls | Should -Be 2
        InModuleScope VmMigrationFactory { $script:VmfSkuCache = @{} }
    }
}
Describe 'RESERVE-RECHECK-1: the words for a machine whose quota check is blocked' {
    It '<Reason>: gives <Code>, the file''s two sentences, which say quota and name the machine' -ForEach @(
        @{ Reason = 'quota-shortfall'; Code = 'quotaShortGeneral' }
        @{ Reason = 'sku-restricted'; Code = 'sizeBlockedGeneral' }
        @{ Reason = 'size-missing'; Code = 'sizeBlockedGeneral' }
        @{ Reason = $null; Code = 'quotaBlockedGeneral' }) {
        $words = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'start-gates.json') -Raw | ConvertFrom-Json
        $c = BcClaim -Size 'Standard_E2s_v6' -State 'BLOCKED'; $c.blockReason = $Reason
        $r = InModuleScope VmMigrationFactory -Parameters @{ e = @(BcEntry -Name 'app-2' -Size 'Standard_E2s_v6'); c = @($c) } {
            $gaps = @(Get-VmfReservedCoverageGaps -Gate BestEffort -Entries $e -Claims $c)
            Get-VmfReservedCoverRefusal -Gate BestEffort -Wave 'wave-1' -Gaps $gaps
        }
        $r.Code | Should -Be $Code
        $r.Gate | Should -Be 'capacity'
        $w = $words.reasons.$Code
        $r.Detail | Should -BeExactly ("$($w.missing) $($w.toDo)".Replace('{wave}', 'wave-1').Replace('{machines}', "machine 'app-2' (Standard_E2s_v6)"))
        $r.Detail | Should -Not -Match 'capacity|Reserve'
        $r.Detail | Should -Not -Match 'quota-shortfall|sku-restricted|size-missing'
        [string]$w.toDo | Should -Match '^In the wave editor, select '
    }

    It 'a record below the quota rung that is NOT blocked gives no blocked words - the gate says what it is' {
        $c = BcClaim -Size 'Standard_E2s_v6' -State 'FORECAST'
        $r = InModuleScope VmMigrationFactory -Parameters @{ e = @(BcEntry -Name 'app-2' -Size 'Standard_E2s_v6'); c = @($c) } {
            $gaps = @(Get-VmfReservedCoverageGaps -Gate BestEffort -Entries $e -Claims $c)
            @($gaps).Count | Should -Be 1
            $gaps[0].Kind | Should -Be 'quota'
            Get-VmfReservedCoverRefusal -Gate BestEffort -Wave 'wave-1' -Gaps $gaps
        }
        $r | Should -BeNullOrEmpty
    }
}
