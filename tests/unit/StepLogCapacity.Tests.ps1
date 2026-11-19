#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# STEP-LOG-5: a run history line that cannot be written, in the capacity and
# wave start commands and in the worker, never decides what the command did.
#
# STEP-LOG-2 and STEP-LOG-4 put every line written after a change through
# Write-VmfStepLine. These seven files still wrote each line with
# Write-VmfEvent, which throws when the store refuses the line:
# New-VmfWaveReservation, Remove-VmfCapacityReservations,
# Invoke-VmfWaveCloseOut, Request-VmfQuota, Test-VmfQuota, Start-VmfWave and
# worker.ps1. So a reservation that Azure made could be recorded as not made,
# a release could stop part way and leave reservations that bill, a wave that
# ran could be reported as failed, and a worker could stop with a machine
# leased. Each test below makes ONE line fail and shows the work is done, the
# command returns its own answer, and nothing is left held.
#
# The worker is a separate process, which no mock reaches. Its tests make the
# store refuse EVERY line: the run history document is a folder, so a write to
# it fails the way a store that does not answer fails.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'steplog5'
    $script:sub = '00000000-0000-0000-0000-000000000000'
    $script:vmBase = "/subscriptions/$($script:sub)/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/"
    $script:crg = "/subscriptions/$($script:sub)/resourceGroups/rg-app/providers/Microsoft.Compute/capacityReservationGroups"
    $script:workerPath = [System.IO.Path]::GetFullPath((Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Workers' 'worker.ps1'))

    function script:New-SlRun {
        $rp = Join-Path $script:temp "sl5-$([guid]::NewGuid().ToString('N').Substring(0,8))" 'runs' 'sl5'
        New-Item -ItemType Directory -Path $rp -Force | Out-Null
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { Initialize-VmfRun -RunPath $rp -RunId 'sl5' | Out-Null }
        $rp
    }
    # A quota record, in the shape Test-VmfQuota writes.
    function script:Write-SlClaim {
        param($RunPath, [string]$Name, [string]$Size = 'Standard_D2s_v6', [string]$State = 'QUOTA_VERIFIED', [int]$Reservable = 2,
              [string]$Wave = 'wave-1', [string]$BlockReason = $null, [hashtable]$Extra = @{})
        $claim = [ordered]@{
            schemaVersion = 10; runId = 'sl5'; wave = $Wave; subscriptionId = $script:sub; resourceGroup = 'rg-app'
            region = 'centralus'; zone = $null; size = $Size; vmFamily = 'StandardDsv6Family'; state = $State
            blockReason = $BlockReason
            demand = [ordered]@{ instances = 2; reservableInstances = $Reservable; vcpus = 4; overlapWithSource = $false }
            quota = [ordered]@{ limit = 100; used = 0; requestId = $null; requestedUtc = $null }
            notes = @()
        }
        if ($State -in @('RESERVED', 'CONSUMED')) {
            $claim.reservation = [ordered]@{ groupId = "$($script:crg)/g-$Name"; reservationId = "$($script:crg)/g-$Name/capacityReservations/r-$Name"
                                             createdUtc = '2026-10-01T00:00:00Z'; releasedUtc = $null; consumedInstances = 0 }
        }
        foreach ($k in $Extra.Keys) { $claim[$k] = $Extra[$k] }
        $dir = Join-Path $RunPath 'capacity'
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $claim | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $dir "$Name.json") -Encoding utf8NoBOM
    }
    function script:Read-SlClaim([string]$RunPath, [string]$Name) {
        Get-Content (Join-Path $RunPath 'capacity' "$Name.json") -Raw | ConvertFrom-Json
    }
    # The warning a lost line gives, read back as one string.
    $script:Said = { param($w) (@($w | ForEach-Object { [string]$_ }) -join "`n") }
    # The message of what a command threw.
    $script:Thrown = { param([scriptblock]$Block) try { & $Block | Out-Null; '' } catch { [string]$_.Exception.Message } }
}
AfterAll { Remove-VmfTestTemp }

Describe 'STEP-LOG-5: Reserve capacity, when a line cannot be written' {
    BeforeEach {
        $script:rp = New-SlRun
        Mock -ModuleName VmMigrationFactory New-VmfCapacityReservation {
            @{ GroupId = "/g/$Size"; ReservationId = "/g/$Size/r" }
        }
    }

    It 'the line before the quota check is lost: the quota is checked and the wave is reserved' {
        Mock -ModuleName VmMigrationFactory Test-VmfQuota { Write-SlClaim -RunPath $script:rp -Name 'a1' }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'capacity' -and $Outcome -eq 'info' } { throw 'The store did not answer.' }
        $r = New-VmfWaveReservation -OutPath $script:rp -Wave 'wave-1' -WarningVariable w -WarningAction SilentlyContinue
        @($r.Reserved).Count | Should -Be 1
        (Read-SlClaim $script:rp 'a1').state | Should -Be 'RESERVED'
        (& $script:Said $w) | Should -BeLike "*'capacity info' could not be written*The product checks the quota now*"
    }

    It 'the refusal line is lost: the refusal is returned, with its own words' {
        Write-SlClaim -RunPath $script:rp -Name 'a1' -State 'BLOCKED' -BlockReason 'quota-shortfall'
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'odcr' -and $Outcome -eq 'refused' } { throw 'The store did not answer.' }
        $r = New-VmfWaveReservation -OutPath $script:rp -Wave 'wave-1' -WarningAction SilentlyContinue
        $r.Refused | Should -BeLike "Wave 'wave-1' was not reserved, because the quota check is blocked*"
        Should -Invoke -ModuleName VmMigrationFactory New-VmfCapacityReservation -Times 0 -Exactly
    }

    It 'the availability set line is lost: the next cell of the wave is still reserved' {
        Write-SlClaim -RunPath $script:rp -Name 'a1' -Reservable 0
        Write-SlClaim -RunPath $script:rp -Name 'b2' -Size 'Standard_E2ds_v6'
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'odcr' -and $Outcome -eq 'warn' } { throw 'The store did not answer.' }
        $r = New-VmfWaveReservation -OutPath $script:rp -Wave 'wave-1' -WarningAction SilentlyContinue
        (Read-SlClaim $script:rp 'b2').state | Should -Be 'RESERVED'
        @($r.Reserved).Count | Should -Be 1
    }

    It 'the line for a claim another run changed first is lost: the next cell is reserved, and the all or nothing rule still runs' {
        Write-SlClaim -RunPath $script:rp -Name 'a1'
        Write-SlClaim -RunPath $script:rp -Name 'b2' -Size 'Standard_E2ds_v6'
        Mock -ModuleName VmMigrationFactory Write-VmfClaimIfVersion -ParameterFilter { $Claim.size -eq 'Standard_D2s_v6' -and $Claim.state -eq 'RESERVING' } { throw '409: the claim changed' }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'odcr' -and $Outcome -eq 'warn' } { throw 'The store did not answer.' }
        New-VmfWaveReservation -OutPath $script:rp -Wave 'wave-1' -WarningAction SilentlyContinue | Out-Null
        (Read-SlClaim $script:rp 'b2').state | Should -Be 'RESERVED'
        Should -Invoke -ModuleName VmMigrationFactory New-VmfCapacityReservation -ParameterFilter { $Size -eq 'Standard_E2ds_v6' } -Times 1 -Exactly
    }

    It 'the start line is lost after the claim says RESERVING: the claim is reserved, not left RESERVING' {
        Write-SlClaim -RunPath $script:rp -Name 'a1'
        Write-SlClaim -RunPath $script:rp -Name 'b2' -Size 'Standard_E2ds_v6'
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'odcr' -and $Outcome -eq 'start' } { throw 'The store did not answer.' }
        $r = New-VmfWaveReservation -OutPath $script:rp -Wave 'wave-1' -WarningAction SilentlyContinue
        (Read-SlClaim $script:rp 'a1').state | Should -Be 'RESERVED'
        (Read-SlClaim $script:rp 'b2').state | Should -Be 'RESERVED'
        @($r.Reserved).Count | Should -Be 2
    }

    It 'the RESERVED line is lost: a reservation Azure made is recorded as made, not as BLOCKED' {
        Write-SlClaim -RunPath $script:rp -Name 'a1'
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'odcr' -and $Outcome -eq 'ok' } { throw 'The store did not answer.' }
        $r = New-VmfWaveReservation -OutPath $script:rp -Wave 'wave-1' -WarningVariable w -WarningAction SilentlyContinue
        $claim = Read-SlClaim $script:rp 'a1'
        $claim.state | Should -Be 'RESERVED'
        $claim.reservation.reservationId | Should -Be '/g/Standard_D2s_v6/r'
        @($r.Reserved).Count | Should -Be 1
        @($r.Blocked).Count | Should -Be 0
        (& $script:Said $w) | Should -BeLike "*'odcr ok' could not be written*Azure holds an on-demand capacity reservation for 2 machines of Standard_D2s_v6 in centralus.*"
    }

    # MANUAL-REVIEW-1: the hover line in the approved words - one machine, and a zone.
    It 'the line for one machine in a zone says 1 machine and the availability zone' {
        Write-SlClaim -RunPath $script:rp -Name 'a1' -Reservable 1 -Extra @{ zone = '1' }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent { }
        New-VmfWaveReservation -OutPath $script:rp -Wave 'wave-1' -WarningAction SilentlyContinue | Out-Null
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -Times 1 -Exactly -ParameterFilter {
            $Step -eq 'odcr' -and $Outcome -eq 'ok' -and
            $Detail -ceq 'Azure holds an on-demand capacity reservation for 1 machine of Standard_D2s_v6 in centralus, in availability zone 1.' }
    }

    It 'the line for a reservation Azure did not confirm is lost: the claim is saved as not confirmed' {
        Write-SlClaim -RunPath $script:rp -Name 'a1'
        Mock -ModuleName VmMigrationFactory New-VmfCapacityReservation { throw 'Azure did not answer in time, so it was not confirmed as held.' }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'odcr' -and $Outcome -eq 'warn' } { throw 'The store did not answer.' }
        $r = New-VmfWaveReservation -OutPath $script:rp -Wave 'wave-1' -WarningAction SilentlyContinue
        (Read-SlClaim $script:rp 'a1').reservationUnconfirmedUtc | Should -Not -BeNullOrEmpty
        @($r.Unconfirmed).Count | Should -Be 1
    }

    It 'the line for a reservation Azure refused is lost: the claim is saved BLOCKED' {
        Write-SlClaim -RunPath $script:rp -Name 'a1'
        Mock -ModuleName VmMigrationFactory New-VmfCapacityReservation { throw 'AllocationFailed' }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'odcr' -and $Outcome -eq 'fail' } { throw 'The store did not answer.' }
        $r = New-VmfWaveReservation -OutPath $script:rp -Wave 'wave-1' -WarningAction SilentlyContinue
        $claim = Read-SlClaim $script:rp 'a1'
        $claim.state | Should -Be 'BLOCKED'
        $claim.blockReason | Should -Be 'reservation-failed'
        @($r.Blocked).Count | Should -Be 1
    }

    It 'the line for a claim released while Azure made it is lost: what Azure made is released' {
        Write-SlClaim -RunPath $script:rp -Name 'a1'
        Mock -ModuleName VmMigrationFactory Write-VmfClaimIfVersion -ParameterFilter { $Claim.state -eq 'RESERVED' } { throw '409: the claim changed' }
        Mock -ModuleName VmMigrationFactory Remove-VmfCapacityReservation { }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'odcr' -and $Outcome -eq 'warn' } { throw 'The store did not answer.' }
        New-VmfWaveReservation -OutPath $script:rp -Wave 'wave-1' -WarningAction SilentlyContinue | Out-Null
        Should -Invoke -ModuleName VmMigrationFactory Remove-VmfCapacityReservation -Times 1 -Exactly
    }

    It 'the line for a reservation that could not be released is lost: the other reservations of the wave are released' {
        Write-SlClaim -RunPath $script:rp -Name 'a1'
        Write-SlClaim -RunPath $script:rp -Name 'b2' -Size 'Standard_E2ds_v6'
        Mock -ModuleName VmMigrationFactory Write-VmfClaimIfVersion -ParameterFilter { $Claim.state -eq 'RESERVED' -and $Claim.size -eq 'Standard_D2s_v6' } { throw '409: the claim changed' }
        Mock -ModuleName VmMigrationFactory Remove-VmfCapacityReservation { throw 'Azure refused the delete' }
        Mock -ModuleName VmMigrationFactory Remove-VmfCapacityReservations { }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'odcr' -and $Outcome -eq 'fail' } { throw 'The store did not answer.' }
        $r = New-VmfWaveReservation -OutPath $script:rp -Wave 'wave-1' -WarningAction SilentlyContinue
        $r.AllOrNothing | Should -BeTrue
        Should -Invoke -ModuleName VmMigrationFactory Remove-VmfCapacityReservations -Times 1 -Exactly
    }

    It 'the line that says the wave has nothing to reserve is lost: the answer is still returned' {
        Write-SlClaim -RunPath $script:rp -Name 'a1' -Reservable 0
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'odcr' -and $Outcome -eq 'info' } { throw 'The store did not answer.' }
        $r = New-VmfWaveReservation -OutPath $script:rp -Wave 'wave-1' -WarningAction SilentlyContinue
        $r.NothingReservable | Should -BeTrue
    }

    It 'the line before the all or nothing release is lost: the reservations that were made are released' {
        Write-SlClaim -RunPath $script:rp -Name 'a1'
        Write-SlClaim -RunPath $script:rp -Name 'b2' -Size 'Standard_E2ds_v6'
        Mock -ModuleName VmMigrationFactory New-VmfCapacityReservation {
            if ($Size -eq 'Standard_E2ds_v6') { throw 'AllocationFailed' }
            @{ GroupId = '/g'; ReservationId = '/g/r' }
        }
        Mock -ModuleName VmMigrationFactory Remove-VmfCapacityReservations { }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'odcr' -and $Outcome -eq 'warn' } { throw 'The store did not answer.' }
        $r = New-VmfWaveReservation -OutPath $script:rp -Wave 'wave-1' -WarningAction SilentlyContinue
        $r.AllOrNothing | Should -BeTrue
        @($r.Released).Count | Should -Be 1
        Should -Invoke -ModuleName VmMigrationFactory Remove-VmfCapacityReservations -Times 1 -Exactly
    }

    It 'the line for a release that failed is lost: the error still says the reservations are still billing' {
        Write-SlClaim -RunPath $script:rp -Name 'a1'
        Write-SlClaim -RunPath $script:rp -Name 'b2' -Size 'Standard_E2ds_v6'
        Mock -ModuleName VmMigrationFactory New-VmfCapacityReservation {
            if ($Size -eq 'Standard_E2ds_v6') { throw 'AllocationFailed' }
            @{ GroupId = '/g'; ReservationId = '/g/r' }
        }
        Mock -ModuleName VmMigrationFactory Remove-VmfCapacityReservations { throw 'release blew up' }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'odcr' -and $Outcome -eq 'fail' -and $Detail -like 'THE CAPACITY*' } { throw 'The store did not answer.' }
        $said = & $script:Thrown { New-VmfWaveReservation -OutPath $script:rp -Wave 'wave-1' -WarningAction SilentlyContinue }
        $said | Should -BeLike "Wave 'wave-1' was not fully reserved, and the on-demand capacity reservations already made were not released. Azure bills them. release blew up"
    }
}

Describe 'STEP-LOG-5: Release capacity, when a line cannot be written' {
    BeforeEach {
        $script:rp = New-SlRun
        Mock -ModuleName VmMigrationFactory Set-VmfCapacityReservationQuantity { }
        Mock -ModuleName VmMigrationFactory Remove-VmfCapacityReservation { }
        Mock -ModuleName VmMigrationFactory Test-VmfCapacityReservationPresent { $false }
    }

    It 'the line for a claim that cannot be released is lost: the next reservation is released' {
        Write-SlClaim -RunPath $script:rp -Name 'a1' -State 'RESERVED'
        $bad = Read-SlClaim $script:rp 'a1'
        $bad.reservation.reservationId = 'not-a-resource-id'
        $bad.reservation.groupId = 'not-a-resource-id'
        $bad | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $script:rp 'capacity' 'a1.json') -Encoding utf8NoBOM
        Write-SlClaim -RunPath $script:rp -Name 'b2' -Size 'Standard_E2ds_v6' -State 'RESERVED'
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'odcr' -and $Outcome -eq 'fail' } { throw 'The store did not answer.' }
        $r = Remove-VmfCapacityReservations -OutPath $script:rp -Wave 'wave-1' -WarningAction SilentlyContinue
        (Read-SlClaim $script:rp 'b2').state | Should -Be 'RELEASED'
        @($r.Released).Count | Should -Be 1
        @($r.NotReleased).Count | Should -Be 1
    }

    It 'the line for a reservation Azure had not confirmed is lost: it and the next one are released' {
        Write-SlClaim -RunPath $script:rp -Name 'a1' -State 'RESERVING' -Extra @{
            reservingSinceUtc = '2026-10-01T00:00:00Z'; reservationUnconfirmedUtc = '2026-10-01T00:10:00Z'
            reservationAsked = [ordered]@{ groupId = "$($script:crg)/g-a1"; reservationId = "$($script:crg)/g-a1/capacityReservations/r-a1"; askedUtc = '2026-10-01T00:00:00Z' } }
        Write-SlClaim -RunPath $script:rp -Name 'b2' -Size 'Standard_E2ds_v6' -State 'RESERVED'
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'odcr' -and $Outcome -eq 'ok' -and $Detail -like '*had not confirmed*' } { throw 'The store did not answer.' }
        $r = Remove-VmfCapacityReservations -OutPath $script:rp -Wave 'wave-1' -WarningAction SilentlyContinue
        (Read-SlClaim $script:rp 'a1').state | Should -Be 'RELEASED'
        (Read-SlClaim $script:rp 'b2').state | Should -Be 'RELEASED'
        @($r.Released).Count | Should -Be 2
    }

    It 'the RELEASED line is lost: the loop goes on, and the next reservation stops billing' {
        Write-SlClaim -RunPath $script:rp -Name 'a1' -State 'RESERVED'
        Write-SlClaim -RunPath $script:rp -Name 'b2' -Size 'Standard_E2ds_v6' -State 'RESERVED'
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'odcr' -and $Detail -eq 'RELEASED Standard_D2s_v6@centralus' } { throw 'The store did not answer.' }
        $r = Remove-VmfCapacityReservations -OutPath $script:rp -Wave 'wave-1' -WarningVariable w -WarningAction SilentlyContinue
        (Read-SlClaim $script:rp 'a1').state | Should -Be 'RELEASED'
        (Read-SlClaim $script:rp 'b2').state | Should -Be 'RELEASED'
        @($r.Released).Count | Should -Be 2
        Should -Invoke -ModuleName VmMigrationFactory Remove-VmfCapacityReservation -Times 2 -Exactly
        (& $script:Said $w) | Should -BeLike "*'odcr ok' could not be written*RELEASED Standard_D2s_v6@centralus*"
    }
}

Describe 'STEP-LOG-5: the close-out of a wave, when a line cannot be written' {
    BeforeEach {
        $script:rp = New-SlRun
        Write-SlClaim -RunPath $script:rp -Name 'a1' -State 'RESERVED'
        $script:done = [pscustomobject]@{ StateCounts = [pscustomobject]@{ MIGRATED = 2 }; Halted = $false }
    }

    It 'the line that says the reservations are held is lost: the close-out still says held' {
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'odcr' } { throw 'The store did not answer.' }
        $result = [pscustomobject]@{ StateCounts = [pscustomobject]@{ MIGRATED = 1; NEEDS_DECISION = 1 }; Halted = $false }
        $r = Invoke-VmfWaveCloseOut -RunPath $script:rp -Wave 'wave-1' -Result $result -WarningAction SilentlyContinue
        $r.Action | Should -Be 'held'
    }

    It 'the line for a release with some reservations left is lost: the close-out says released, not failed' {
        Mock -ModuleName VmMigrationFactory Remove-VmfCapacityReservations {
            [pscustomobject]@{ Released = @([pscustomobject]@{ Size = 'a' }); NotReleased = @([pscustomobject]@{ Size = 'b' }) } }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'odcr' -and $Outcome -eq 'warn' } { throw 'The store did not answer.' }
        $r = Invoke-VmfWaveCloseOut -RunPath $script:rp -Wave 'wave-1' -Result $script:done -WarningAction SilentlyContinue
        $r.Action | Should -Be 'released'
        $r.Released | Should -Be 1
    }

    It 'the line for a release is lost: the close-out says released, not still billing' {
        Mock -ModuleName VmMigrationFactory Remove-VmfCapacityReservations {
            [pscustomobject]@{ Released = @([pscustomobject]@{ Size = 'a' }); NotReleased = @() } }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'odcr' -and $Outcome -eq 'ok' } { throw 'The store did not answer.' }
        $r = Invoke-VmfWaveCloseOut -RunPath $script:rp -Wave 'wave-1' -Result $script:done -WarningAction SilentlyContinue
        $r.Action | Should -Be 'released'
        $r.Released | Should -Be 1
    }

    It 'the line for a release that failed is lost: the close-out returns held with the reason, and does not fail the wave' {
        Mock -ModuleName VmMigrationFactory Remove-VmfCapacityReservations { throw 'release blew up' }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'odcr' -and $Outcome -eq 'fail' } { throw 'The store did not answer.' }
        $r = Invoke-VmfWaveCloseOut -RunPath $script:rp -Wave 'wave-1' -Result $script:done -WarningAction SilentlyContinue
        $r.Action | Should -Be 'held'
        $r.Reason | Should -Be 'release failed: release blew up'
    }
}

Describe 'STEP-LOG-5: Request a quota increase, when a line cannot be written' {
    BeforeEach {
        $script:rp = New-SlRun
        Write-SlClaim -RunPath $script:rp -Name 'a1' -State 'BLOCKED' -BlockReason 'quota-shortfall'
        Write-SlClaim -RunPath $script:rp -Name 'b2' -Size 'Standard_E2ds_v6' -State 'BLOCKED' -BlockReason 'quota-shortfall' -Extra @{ vmFamily = 'StandardEDSv6Family' }
        Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease { [pscustomobject]@{ StatusCode = 202; Content = '{"id":"/quota-requests/abc"}' } }
    }

    It 'the line for a record with no subscription is lost: the next family is still requested' {
        $a = Read-SlClaim $script:rp 'a1'
        $a.subscriptionId = ''
        $a | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $script:rp 'capacity' 'a1.json') -Encoding utf8NoBOM
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'quotaRequest' -and $Outcome -eq 'fail' } { throw 'The store did not answer.' }
        $r = Request-VmfQuota -OutPath $script:rp -WarningAction SilentlyContinue
        @($r.Submitted).Count | Should -Be 1
        @($r.Failed).Count | Should -Be 1
        (Read-SlClaim $script:rp 'b2').state | Should -Be 'QUOTA_REQUESTED'
    }

    It 'the line for a quota the tool may not request is lost: the next family is still requested' {
        $a = Read-SlClaim $script:rp 'a1'
        $a.quota | Add-Member -NotePropertyName requestAccess -NotePropertyValue 'missing' -Force
        $a | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $script:rp 'capacity' 'a1.json') -Encoding utf8NoBOM
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'quotaRequest' -and $Outcome -eq 'fail' } { throw 'The store did not answer.' }
        $r = Request-VmfQuota -OutPath $script:rp -WarningAction SilentlyContinue
        @($r.Submitted).Count | Should -Be 1
        (Read-SlClaim $script:rp 'b2').state | Should -Be 'QUOTA_REQUESTED'
    }

    It 'the line for a request Azure refused is lost: the next family is still requested' {
        Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease -ParameterFilter { $Family -eq 'StandardDsv6Family' } { [pscustomobject]@{ StatusCode = 500; Content = 'server error' } }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'quotaRequest' -and $Outcome -eq 'fail' } { throw 'The store did not answer.' }
        $r = Request-VmfQuota -OutPath $script:rp -WarningAction SilentlyContinue
        @($r.Submitted).Count | Should -Be 1
        (Read-SlClaim $script:rp 'b2').state | Should -Be 'QUOTA_REQUESTED'
    }

    It 'the line for a request that was filed is lost: the next family is still requested, and both are recorded' {
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'quotaRequest' -and $Outcome -eq 'ok' -and $Detail -like 'family=StandardDsv6Family*' } { throw 'The store did not answer.' }
        $r = Request-VmfQuota -OutPath $script:rp -WarningAction SilentlyContinue
        @($r.Submitted).Count | Should -Be 2
        (Read-SlClaim $script:rp 'a1').state | Should -Be 'QUOTA_REQUESTED'
        (Read-SlClaim $script:rp 'b2').state | Should -Be 'QUOTA_REQUESTED'
    }

    It 'KEPT: the preview line is the only answer of a preview, so a preview whose line is lost fails, with nothing filed' {
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'quotaPreview' } { throw 'The store did not answer.' }
        { Request-VmfQuota -OutPath $script:rp -WhatIfOnly } | Should -Throw 'The store did not answer.'
        Should -Invoke -ModuleName VmMigrationFactory Request-VmfQuotaIncrease -Times 0 -Exactly
        (Read-SlClaim $script:rp 'a1').state | Should -Be 'BLOCKED'
    }
}

Describe 'STEP-LOG-5: Check the quota, when a line cannot be written' {
    BeforeEach {
        $script:rp = New-SlRun
        @{ schemaVersion = 1; assessmentRunId = 'sl5'; entries = @(
            @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$($script:vmBase)a"; wave = 'wave-1'; path = 'A'; assessment = @{ location = 'centralus' }; target = @{ size = 'Standard_D2ds_v6' } },
            @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$($script:vmBase)b"; wave = 'wave-2'; path = 'A'; assessment = @{ location = 'centralus' }; target = @{ size = 'Standard_D2ds_v6' } })
        } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:rp 'plan.json')
        $script:pp = Join-Path $script:rp 'plan.json'
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
            @([pscustomobject]@{ Name = 'Standard_D2ds_v6'; ResourceType = 'virtualMachines'; Family = 'StandardDdsv6Family'; Restrictions = @()
                                 Capabilities = @([pscustomobject]@{ Name = 'vCPUs'; Value = '2' }, [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = '0' }) })
        }
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @([pscustomobject]@{ Name = [pscustomobject]@{ Value = 'StandardDdsv6Family' }; CurrentValue = 0; Limit = 10 })
        }
        Mock -ModuleName VmMigrationFactory Get-VmfRetailPrice { $null }
        $script:recordOf = { param($w) @(Get-ChildItem (Join-Path $script:rp 'capacity') -Filter "$w-*.json" -ErrorAction SilentlyContinue) }
    }

    It 'the line for a continuing machine on a size the list does not show is lost: the check finishes and writes its records' {
        Mock -ModuleName VmMigrationFactory Get-VmfContinuingMoves { @([pscustomobject]@{ VmId = "$($script:vmBase)b"; Resized = $false; Size = 'Standard_Z9s_v9' }) }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'capacity' -and $Outcome -eq 'warn' } { throw 'The store did not answer.' }
        $r = Test-VmfQuota -PlanPath $script:pp -OutPath $script:rp -LeaveOutStarted -WarningAction SilentlyContinue
        @($r.Claims).Count | Should -Be 1
        @(& $script:recordOf 'wave-1').Count | Should -Be 1
    }

    It 'the line for a record of a reservation that is kept is lost: the check finishes, and the other wave is checked' {
        Test-VmfQuota -PlanPath $script:pp -OutPath $script:rp | Out-Null
        $file = @(& $script:recordOf 'wave-1')[0].FullName
        $doc = Get-Content $file -Raw | ConvertFrom-Json
        $doc.state = 'RESERVED'
        $doc | ConvertTo-Json -Depth 12 | Set-Content $file
        Remove-Item @(& $script:recordOf 'wave-2')[0].FullName
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'capacity' -and $Detail -like 'kept the RESERVED record*' } { throw 'The store did not answer.' }
        $r = Test-VmfQuota -PlanPath $script:pp -OutPath $script:rp -WarningAction SilentlyContinue
        @($r.Claims).Count | Should -Be 2
        @(& $script:recordOf 'wave-2').Count | Should -Be 1
        (Get-Content $file -Raw | ConvertFrom-Json).state | Should -Be 'RESERVED'
    }

    It 'the line for a record that became a reservation during the check is lost: the check finishes' {
        Test-VmfQuota -PlanPath $script:pp -OutPath $script:rp | Out-Null
        $script:raceFile = @(& $script:recordOf 'wave-1')[0].FullName
        Mock -ModuleName VmMigrationFactory Write-VmfClaimIfVersion -ParameterFilter { $Claim.wave -eq 'wave-1' } {
            $d = Get-Content $script:raceFile -Raw | ConvertFrom-Json
            $d.state = 'RESERVED'
            $d | ConvertTo-Json -Depth 12 | Set-Content $script:raceFile
            throw '409: the claim changed'
        }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'capacity' -and $Detail -like '*became an on-demand capacity reservation while*' } { throw 'The store did not answer.' }
        $r = Test-VmfQuota -PlanPath $script:pp -OutPath $script:rp -WarningAction SilentlyContinue
        @($r.Claims).Count | Should -Be 2
        (Get-Content $script:raceFile -Raw | ConvertFrom-Json).state | Should -Be 'RESERVED'
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'capacity' -and $Detail -like '*became an on-demand capacity reservation while*' } -Times 1 -Exactly
    }

    It 'the summary line is lost: the check returns its records, and they are saved' {
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'capacity' -and $Detail -like 'claims=*' } { throw 'The store did not answer.' }
        $r = Test-VmfQuota -PlanPath $script:pp -OutPath $script:rp -Wave 'wave-1' -WarningVariable w -WarningAction SilentlyContinue
        @($r.Claims).Count | Should -Be 1
        @(& $script:recordOf 'wave-1').Count | Should -Be 1
        (& $script:Said $w) | Should -BeLike "*'capacity ok' could not be written*claims=1 blocked=0 wave=wave-1*"
    }
}

Describe 'STEP-LOG-5: the start of a wave, when a line cannot be written' {
    BeforeEach {
        $script:rp = New-SlRun
        $script:gate = 'BestEffort'
        $script:NewEntry = {
            param([string]$Name, [string]$Size = 'Standard_D2s_v6', [switch]$Avset)
            [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion);
                vmId = "$($script:vmBase)$Name"; wave = 'wave-1'; path = 'A'
                assessment = [pscustomobject]@{ location = 'centralus'; sourceSize = 'Standard_D2s_v4'
                                                availabilitySetId = $(if ($Avset) { '/avsets/pair' } else { '' }) }
                target = [pscustomobject]@{ size = $Size }
                policy = [pscustomobject]@{ capacityGate = $script:gate; requireApproval = $false }
            }
        }
        $script:WritePlan = {
            param($Entries)
            @{ schemaVersion = 1; assessmentRunId = 'sl5'; entries = @($Entries) } | ConvertTo-Json -Depth 10 |
                Set-Content (Join-Path $script:rp 'plan.json') -Encoding utf8NoBOM
            Join-Path $script:rp 'plan.json'
        }
        $script:pp = & $script:WritePlan @((& $script:NewEntry 'app-1'), (& $script:NewEntry 'app-2' -Size 'Standard_E2s_v6'))
        Mock -ModuleName VmMigrationFactory Test-VmfRunAcknowledged { [pscustomobject]@{ Pass = $true } }
        Mock -ModuleName VmMigrationFactory Test-VmfWaveOptionsAccepted { [pscustomobject]@{ Pass = $true } }
        Mock -ModuleName VmMigrationFactory Test-VmfVmClaims { [pscustomobject]@{ Pass = $true } }
        Mock -ModuleName VmMigrationFactory Test-VmfWaveSubscriptions { [pscustomobject]@{ Pass = $true } }
        Mock -ModuleName VmMigrationFactory Test-VmfWaveApproval { [pscustomobject]@{ Pass = $true } }
        Mock -ModuleName VmMigrationFactory Test-VmfQuota { }
        # Reaching the launch of the workers means the start went on.
        Mock -ModuleName VmMigrationFactory Start-Process { throw 'WORKERS-STARTED' }
        $script:Start = { param([hashtable]$More = @{})
            & $script:Thrown { Start-VmfWave -PlanPath $script:pp -Wave 'wave-1' -RunPath $script:rp -WarningAction SilentlyContinue @More } }
        $script:CoverAll = {
            Write-SlClaim -RunPath $script:rp -Name 'a1' -Reservable 1
            Write-SlClaim -RunPath $script:rp -Name 'b2' -Size 'Standard_E2s_v6' -Reservable 1
        }
    }

    It 'the refusal line for a machine in another subscription is lost: the refusal keeps its own words' {
        Mock -ModuleName VmMigrationFactory Test-VmfWaveSubscriptions { [pscustomobject]@{ Pass = $false; Detail = 'machine app-2 is in another subscription.' } }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'wave' -and $Outcome -eq 'fail' } { throw 'The store did not answer.' }
        (& $script:Start) | Should -Be "Wave 'wave-1' cannot start: machine app-2 is in another subscription."
    }

    It 'the line for a wave that needs no capacity is lost: the wave starts' {
        Mock -ModuleName VmMigrationFactory Resolve-VmfWaveNeedsNoCapacity { $true }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'capacity' -and $Outcome -eq 'info' } { throw 'The store did not answer.' }
        (& $script:Start) | Should -Be 'WORKERS-STARTED'
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'capacity' -and $Detail -like '*outside the scope of this tool*' } -Times 1 -Exactly
    }

    It 'the line for a wave whose every machine has started its move is lost: the wave starts' {
        Mock -ModuleName VmMigrationFactory Get-VmfContinuingMoves { @([pscustomobject]@{ VmId = "$($script:vmBase)app-1" }, [pscustomobject]@{ VmId = "$($script:vmBase)app-2" }) }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'capacity' -and $Outcome -eq 'info' } { throw 'The store did not answer.' }
        (& $script:Start) | Should -Be 'WORKERS-STARTED'
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'capacity' -and $Detail -like '*has started its move*' } -Times 1 -Exactly
    }

    It 'the line before the quota check is lost: the quota is checked and the wave starts' {
        & $script:CoverAll
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'capacity' -and $Outcome -eq 'info' } { throw 'The store did not answer.' }
        (& $script:Start) | Should -Be 'WORKERS-STARTED'
        Should -Invoke -ModuleName VmMigrationFactory Test-VmfQuota -Times 1 -Exactly
    }

    It 'the refusal line for a quota check that did not finish is lost: the refusal keeps its own words' {
        Mock -ModuleName VmMigrationFactory Test-VmfQuota { throw 'Azure did not answer.' }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'capacity' -and $Outcome -eq 'refused' } { throw 'The store did not answer.' }
        $said = & $script:Start
        $said | Should -Not -BeLike '*store*'
        $expected = InModuleScope VmMigrationFactory -Parameters @{ m = "machines 'app-1' (Standard_D2s_v6) and 'app-2' (Standard_E2s_v6)" } {
            (New-VmfStartGateRefusal -Code 'quotaCheckFailed' -Wave 'wave-1' -Machines $m).Detail }
        $said | Should -Be ([string]$expected)
    }

    It 'the refusal line for a machine with no quota record is lost: the refusal keeps its own words' {
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'capacity' -and $Outcome -eq 'refused' } { throw 'The store did not answer.' }
        (& $script:Start) | Should -BeLike "Wave wave-1 has no quota record for machine*"
    }

    It 'the refusal line of a Reserved wave is lost: the refusal keeps its own words' {
        $script:gate = 'Reserved'
        $script:pp = & $script:WritePlan @((& $script:NewEntry 'app-1'), (& $script:NewEntry 'app-2' -Size 'Standard_E2s_v6'))
        & $script:CoverAll
        Mock -ModuleName VmMigrationFactory Get-VmfReservedCapacityRefusal { @{ Detail = 'Wave wave-1 has no capacity reservation.'; Code = 'notReserved' } }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'capacity' -and $Outcome -eq 'refused' } { throw 'The store did not answer.' }
        (& $script:Start) | Should -Be 'Wave wave-1 has no capacity reservation.'
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'capacity' -and $Outcome -eq 'refused' -and $Data.code -eq 'notReserved' -and $Data.wave -eq 'wave-1' } -Times 1 -Exactly
    }

    It 'the refusal line for a quota that is not enough is lost: the refusal keeps its own words' {
        Write-SlClaim -RunPath $script:rp -Name 'a1' -Reservable 1
        Write-SlClaim -RunPath $script:rp -Name 'b2' -Size 'Standard_E2s_v6' -Reservable 1 -State 'BLOCKED' -BlockReason 'quota-shortfall'
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'capacity' -and $Outcome -eq 'refused' } { throw 'The store did not answer.' }
        (& $script:Start) | Should -BeLike "The quota is not enough for machine 'app-2' (Standard_E2s_v6) in wave wave-1.*"
    }

    It 'the line about machines on general capacity is lost: the wave starts' {
        $script:gate = 'Reserved'
        $script:pp = & $script:WritePlan @((& $script:NewEntry 'app-1'), (& $script:NewEntry 'app-2' -Size 'Standard_E2s_v6'))
        & $script:CoverAll
        Mock -ModuleName VmMigrationFactory Get-VmfReservedCapacityRefusal { $null }
        Mock -ModuleName VmMigrationFactory Get-VmfReservedGeneralNote { 'Some machines of wave wave-1 move on general capacity.' }
        Mock -ModuleName VmMigrationFactory Test-VmfQuotaAndReservation { [pscustomobject]@{ Pass = $true; Detail = '' } }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'capacity' -and $Detail -like '*general capacity*' } { throw 'The store did not answer.' }
        (& $script:Start) | Should -Be 'WORKERS-STARTED'
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'capacity' -and $Detail -like '*general capacity*' } -Times 1 -Exactly
    }

    It 'the line that says the wave starts is lost: the workers start' {
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'wave' -and $Outcome -eq 'start' } { throw 'The store did not answer.' }
        (& $script:Start @{ SkipCapacityGate = $true }) | Should -Be 'WORKERS-STARTED'
    }
}

Describe 'STEP-LOG-5: the watch loop of a wave, when a line cannot be written' {
    BeforeEach {
        $script:rp = New-SlRun
        $entries = @(foreach ($n in 'app-1', 'app-2') {
                [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$($script:vmBase)$n"; wave = 'wave-1'; path = 'A'
                                   assessment = [pscustomobject]@{ location = 'centralus' }; target = [pscustomobject]@{ size = 'Standard_D2s_v6' }
                                   policy = [pscustomobject]@{ capacityGate = 'BestEffort'; requireApproval = $false } } })
        @{ schemaVersion = 1; assessmentRunId = 'sl5'; entries = $entries } | ConvertTo-Json -Depth 10 |
            Set-Content (Join-Path $script:rp 'plan.json') -Encoding utf8NoBOM
        $script:pp = Join-Path $script:rp 'plan.json'
        foreach ($gate in 'Test-VmfRunAcknowledged', 'Test-VmfWaveOptionsAccepted', 'Test-VmfVmClaims', 'Test-VmfWaveSubscriptions', 'Test-VmfWaveApproval') {
            Mock -ModuleName VmMigrationFactory $gate { [pscustomobject]@{ Pass = $true } }
        }
        # The workers are not started: each "process" has already ended.
        $script:exitCode = 0
        Mock -ModuleName VmMigrationFactory Start-Process { [pscustomobject]@{ HasExited = $true; ExitCode = $script:exitCode; Id = 1 } }
        Mock -ModuleName VmMigrationFactory Get-VmfWorkerMemorySample {
            [pscustomobject]@{ alive = 1; minMB = 100; avgMB = 100; maxMB = 100; containerMB = $null; cgroup = $null } }
        Mock -ModuleName VmMigrationFactory Update-VmfMemoryPeak {
            [pscustomobject]@{ samples = 1; workerMB = 100; workersAtPeak = 1; containerMB = $null } }
        Mock -ModuleName VmMigrationFactory Get-VmfExpiredLeases { @() }
        Mock -ModuleName VmMigrationFactory Test-VmfWaveHalted { $false }
        Mock -ModuleName VmMigrationFactory Test-VmfCapacityExhausted { [pscustomobject]@{ Exhausted = $false } }
        Mock -ModuleName VmMigrationFactory Test-VmfCircuitBreaker { [pscustomobject]@{ Tripped = $false } }
        Mock -ModuleName VmMigrationFactory Write-VmfRunStatus { [pscustomobject]@{ stateCounts = @{ MIGRATED = 2 }; breaker = [pscustomobject]@{ halted = $false } } }
        Mock -ModuleName VmMigrationFactory Test-VmfWavePending { $false }
        Mock -ModuleName VmMigrationFactory Remove-VmfSettledVmClaim { $true }
        Mock -ModuleName VmMigrationFactory Update-VmfRunSummary { $true }
        Mock -ModuleName VmMigrationFactory Write-Host { }
        $script:Run = { param([hashtable]$More = @{})
            Start-VmfWave -PlanPath $script:pp -Wave 'wave-1' -RunPath $script:rp -SkipCapacityGate -WarningAction SilentlyContinue @More }
        # The wave ended as it should: every claim given back, and the final status written.
        $script:Ended = {
            param($r)
            $r.Wave | Should -Be 'wave-1'
            $r.StateCounts.MIGRATED | Should -Be 2
            Should -Invoke -ModuleName VmMigrationFactory Remove-VmfSettledVmClaim -Times 2 -Exactly
            Should -Invoke -ModuleName VmMigrationFactory Write-VmfRunStatus -ParameterFilter { $WaveEnded } -Times 1 -Exactly
        }
    }

    It 'the memory line is lost: the watch loop goes on, and the wave ends with its claims given back' {
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'engine:memory' -and $Detail -like 'Workers:*' } { throw 'The store did not answer.' }
        & $script:Ended (& $script:Run)
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfExpiredLeases -Times 1 -Exactly
    }

    It 'the watchdog line is lost after a lease was removed: the wave ends with its claims given back' {
        Mock -ModuleName VmMigrationFactory Get-VmfExpiredLeases { @([pscustomobject]@{ vmId = "$($script:vmBase)app-1"; workerId = 'worker-1' }) }
        Mock -ModuleName VmMigrationFactory Remove-VmfExpiredLease { $true }
        Mock -ModuleName VmMigrationFactory Get-VmfReapedLeaseWords { 'The lease of worker-1 ran out.' }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'watchdog' } { throw 'The store did not answer.' }
        & $script:Ended (& $script:Run)
    }

    It 'the capacity line after the halt is lost: the wave ends with its claims given back' {
        Mock -ModuleName VmMigrationFactory Test-VmfCapacityExhausted { [pscustomobject]@{ Exhausted = $true; Detail = 'Azure has no capacity for Standard_D2s_v6.'; Evidence = @('AllocationFailed') } }
        Mock -ModuleName VmMigrationFactory Set-VmfWaveHalt { }
        # Every other line is counted, not written.
        Mock -ModuleName VmMigrationFactory Write-VmfEvent { }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'capacity' -and $Outcome -eq 'refused' } { throw 'The store did not answer.' }
        & $script:Ended (& $script:Run)
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfWaveHalt -Times 1 -Exactly
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'capacity' -and $Detail -eq 'Azure said: AllocationFailed' } -Times 1 -Exactly
    }

    It 'the line with what Azure said is lost: the wave ends with its claims given back' {
        Mock -ModuleName VmMigrationFactory Test-VmfCapacityExhausted { [pscustomobject]@{ Exhausted = $true; Detail = 'Azure has no capacity for Standard_D2s_v6.'; Evidence = @('AllocationFailed') } }
        Mock -ModuleName VmMigrationFactory Set-VmfWaveHalt { }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'capacity' -and $Outcome -eq 'info' } { throw 'The store did not answer.' }
        & $script:Ended (& $script:Run)
    }

    It 'the line for a container that finished its share is lost: the container ends its share as finished' {
        Mock -ModuleName VmMigrationFactory Test-VmfWavePending { $true }
        Mock -ModuleName VmMigrationFactory Test-VmfOtherContainersWorking { [pscustomobject]@{ Working = $true; Machines = @('app-2') } }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'wave' -and $Outcome -eq 'info' } { throw 'The store did not answer.' }
        $r = & $script:Run @{ Container = '1/2' }
        $r.FinishedShare | Should -BeTrue
        $r.Container | Should -Be '1/2'
    }

    It 'the line for workers that all stopped is lost: the list is told the wave ended, and the error says why' {
        $script:exitCode = 1
        Mock -ModuleName VmMigrationFactory Test-VmfWavePending { $true }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'wave' -and $Outcome -eq 'fail' } { throw 'The store did not answer.' }
        $said = & $script:Thrown { & $script:Run }
        $said | Should -BeLike "Wave 'wave-1' migrated nothing: all 2 workers exited without doing any work.*"
        Should -Invoke -ModuleName VmMigrationFactory Update-VmfRunSummary -ParameterFilter { $Reason -eq 'waveEnded' } -Times 1 -Exactly
    }

    It 'the peak memory line is lost: the wave ends with its final status' {
        # Every other line is counted, not written.
        Mock -ModuleName VmMigrationFactory Write-VmfEvent { }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'engine:memory' -and $Detail -like 'Peak memory*' } { throw 'The store did not answer.' }
        & $script:Ended (& $script:Run)
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'wave' -and $Outcome -eq 'ok' } -Times 1 -Exactly
    }

    It 'the last line is lost: a wave that ran returns its result, not a failure' {
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'wave' -and $Outcome -eq 'ok' } { throw 'The store did not answer.' }
        $r = & $script:Run
        & $script:Ended $r
    }
}

Describe 'STEP-LOG-5: a real worker, when the store refuses every line' {
    BeforeEach {
        $script:rp = New-SlRun
        $script:m1 = "$($script:vmBase)wk1"
        $script:m2 = "$($script:vmBase)wk2"
        $plan = [pscustomobject]@{ schemaVersion = 1; entries = @(foreach ($id in $script:m1, $script:m2) {
                    [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; wave = 'w1'; ring = 'lab'; appGroup = ($id -split '/')[-1]
                        assessment = [pscustomobject]@{ classification = 'ReadyNow'; gen = 'V2'; os = 'Linux'; sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; platformManaged = $false }
                        target = [pscustomobject]@{ size = 'Standard_D2s_v6'; diskArch = 'diskless'; controller = 'NVMe' }
                        path = 'A'; policy = [pscustomobject]@{ requireApproval = $false } } }) }
        $script:pp = Join-Path $script:rp 'plan.json'
        $plan | ConvertTo-Json -Depth 24 | Set-Content $script:pp
        # The engine stand-in. SL_THROW_ON names a machine it ends FAILED and
        # then throws for; SL_EDIT_PLAN makes it change the second machine's
        # target in the plan file while the worker runs.
        $script:engine = Join-Path (Split-Path $script:rp) 'fake-engine.ps1'
        @'
param($EntryJson, $RunPath, $RunId)
$entry = $EntryJson | ConvertFrom-Json -Depth 24
$end = if ($env:SL_THROW_ON -and $entry.vmId -like "*$($env:SL_THROW_ON)") { 'FAILED_ROLLED_BACK' } else { 'MIGRATED' }
& (Get-Module VmMigrationFactory) {
    param($id, $rp, $rid, $s)
    New-VmfStateDoc -RunPath $rp -RunId $rid -VmId $id | Out-Null
    Add-VmfStateTransition -RunPath $rp -VmId $id -NewState $s -Outcome ok | Out-Null
} $entry.vmId $RunPath $RunId $end
if ($env:SL_EDIT_PLAN) {
    $file = Join-Path $RunPath 'plan.json'
    $doc = Get-Content $file -Raw | ConvertFrom-Json -Depth 24
    $doc.entries[1].target.size = 'Standard_D4s_v6'
    $doc | ConvertTo-Json -Depth 24 | Set-Content $file
}
if ($end -eq 'FAILED_ROLLED_BACK') { throw 'the engine stopped on this machine' }
'@ | Set-Content $script:engine
        # The store refuses every line: the run history document is a folder.
        $log = Join-Path $script:rp 'logs' 'events.jsonl'
        if (Test-Path $log) { Remove-Item $log -Force }
        New-Item -ItemType Directory -Path $log -Force | Out-Null
        $script:RunWorker = {
            param([string[]]$More = @())
            $env:VMF_TEST_ENGINE = $script:engine
            try {
                $proc = Start-Process pwsh -PassThru -WindowStyle Hidden -RedirectStandardError (Join-Path (Split-Path $script:rp) 'worker.err.log') `
                    -RedirectStandardOutput (Join-Path (Split-Path $script:rp) 'worker.out.log') -ArgumentList (@(
                    '-NoProfile', '-File', $script:workerPath, '-RunPath', $script:rp, '-PlanPath', $script:pp,
                    '-Wave', 'w1', '-RunId', 'sl5', '-WorkerId', 'sl5-w1', '-IdleWaitSeconds', '1') + $More)
                $proc.WaitForExit(120000) | Should -BeTrue -Because 'the worker drains its machines and exits'
                $proc.ExitCode
            }
            finally { Remove-Item Env:\VMF_TEST_ENGINE, Env:\SL_THROW_ON, Env:\SL_EDIT_PLAN -ErrorAction SilentlyContinue }
        }
        $script:StateOf = { param($id) $d = InModuleScope VmMigrationFactory -Parameters @{ r = $script:rp; v = $id } { Read-VmfStateDoc -RunPath $r -VmId $v }; if ($d) { [string]$d.state } else { '' } }
        $script:LeaseOf = { param($id) InModuleScope VmMigrationFactory -Parameters @{ r = $script:rp; v = $id } { Test-VmfStoreItem -RunPath $r -RelPath ('leases/' + (Get-VmfVmKey -VmId $v) + '.lease') } }
        $script:ClaimOf = { param($id) InModuleScope VmMigrationFactory -Parameters @{ r = $script:rp; v = $id } { Get-VmfVmClaim -RunPath $r -VmId $v } }
    }

    It 'the "leased by" line is lost: the worker moves every machine and exits cleanly' {
        (& $script:RunWorker) | Should -Be 0
        (& $script:StateOf $script:m1) | Should -Be 'MIGRATED'
        (& $script:StateOf $script:m2) | Should -Be 'MIGRATED'
    }

    It 'the line for a machine the engine stopped on is lost: the worker goes on to the next machine' {
        $env:SL_THROW_ON = 'wk1'
        (& $script:RunWorker) | Should -Be 0
        (& $script:StateOf $script:m1) | Should -Be 'FAILED_ROLLED_BACK'
        (& $script:StateOf $script:m2) | Should -Be 'MIGRATED'
    }

    It 'the line for a machine whose plan changed is lost: its lease and its claim are given back, and it is not touched' {
        $env:SL_EDIT_PLAN = '1'
        (& $script:RunWorker) | Should -Be 0
        (& $script:StateOf $script:m1) | Should -Be 'MIGRATED'
        (& $script:StateOf $script:m2) | Should -Be '' -Because 'a machine whose plan changed is never touched'
        (& $script:LeaseOf $script:m2) | Should -BeFalse
        & $script:ClaimOf $script:m2 | Should -BeNullOrEmpty
    }

    It 'the line for a plan that changed after the start checks is lost: the worker takes no machine, and says why' {
        (& $script:RunWorker @('-WaveVersion', 'not-this-version')) | Should -Be 3
        (Get-Content (Join-Path (Split-Path $script:rp) 'worker.err.log') -Raw) | Should -BeLike '*The plan changed after wave w1 passed its start checks. No machine was taken.*'
        (& $script:StateOf $script:m1) | Should -Be ''
        (& $script:LeaseOf $script:m1) | Should -BeFalse
    }
}
