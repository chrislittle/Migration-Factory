#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# ODCR-STATE-1, 2026-09-19. Owner, reading the refusal a wave gives when its
# reserved capacity is not held yet:
#
#   "why would it say that if ODCR is pending deployment in azure? it makes no
#    sense. that is messaging saying the options not what you did"
#
# He is right. A quota record sits at RESERVING for the WHOLE time Azure is
# building the reservation - minutes - and lands on BLOCKED when Azure
# refuses. The gate accepted only RESERVED or CONSUMED, so every one of those
# produced the same sentence:
#
#   "no capacity has been reserved for it. Reserving is a separate action that
#    spends money - use Reserve capacity on the wave..."
#
# To somebody who pressed Reserve four minutes ago that is an instruction to do
# what they just did. To somebody whose reservation Azure REFUSED it hides the
# failure completely, and invites a second attempt without saying the first one
# failed.
#
# The irony is on the record. RESERVING exists because "for that whole window
# the claim used to sit at its previous state and nothing anywhere said a job
# was running" - added to stop a person paying twice. This gate was never
# taught to read the state that fix created.
#
# THESE TESTS DRIVE THE FUNCTION, not the source text. An earlier version of
# this file asserted that phrases appeared in Start-VmfWave.ps1, which is the
# "matching the message rather than the guard" hole - the sentence can sit in
# the file while the branch that reaches it is dead.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:OdcrClaim {
        param([string]$State, [string]$SinceUtc, [string]$BlockReason, $Notes)
        $c = [pscustomobject]@{ wave = 'billing-apps'; state = $State }
        if ($SinceUtc)    { $c | Add-Member reservingSinceUtc $SinceUtc }
        if ($BlockReason) { $c | Add-Member blockReason $BlockReason }
        if ($Notes)       { $c | Add-Member notes $Notes }
        $c
    }
    $script:now = [datetime]::Parse('2026-09-19T18:00:00Z', $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}
AfterAll { Remove-Item 'function:\OdcrClaim' -ErrorAction SilentlyContinue }

Describe 'ODCR-STATE-1: capacity that IS held lets the wave start' {

    It 'a reserved claim returns no refusal at all' {
        InModuleScope VmMigrationFactory {
            Get-VmfReservedCapacityRefusal -Claims @(OdcrClaim -State 'RESERVED') -Wave 'billing-apps' |
                Should -BeNullOrEmpty
        }
    }

    It 'and so does one already being consumed' {
        InModuleScope VmMigrationFactory {
            Get-VmfReservedCapacityRefusal -Claims @(OdcrClaim -State 'CONSUMED') -Wave 'billing-apps' |
                Should -BeNullOrEmpty
        }
    }

    It 'even when another claim for the wave is still working' {
        # Held is held. One claim mid-flight must not refuse a wave whose
        # capacity is already there.
        # RESERVING-STUCK-1: "still working" means it says when it started,
        # and that was minutes ago. One with no start time, or one nobody is
        # making any more, is Not confirmed and does refuse (ReservingStuck).
        InModuleScope VmMigrationFactory {
            $since = (Get-Date).ToUniversalTime().AddMinutes(-2).ToString('o')
            Get-VmfReservedCapacityRefusal -Wave 'billing-apps' -Claims @(
                (OdcrClaim -State 'RESERVING' -SinceUtc $since), (OdcrClaim -State 'RESERVED')) |
                Should -BeNullOrEmpty
        }
    }
}

Describe 'ODCR-STATE-1: the refusal says what the capacity is DOING' {

    It 'while Azure is building it, it says so and says how long' {
        InModuleScope VmMigrationFactory -Parameters @{ Now = $script:now } {
            param($Now)
            $msg = Get-VmfReservedCapacityRefusal -Wave 'billing-apps' -NowUtc $Now -Claims @(
                OdcrClaim -State 'RESERVING' -SinceUtc '2026-09-19T17:56:00Z')
            $msg | Should -Match 'is having its capacity reserved now'
            $msg | Should -Match 'It started 4 minute\(s\) ago'
            $msg | Should -Match 'Do not reserve again'
            # The defect itself: it must NOT tell them to do what they did.
            $msg | Should -Not -Match 'use Reserve capacity'
            $msg | Should -Not -Match 'no capacity has been reserved'
        }
    }

    It 'and says nothing about elapsed time when the claim does not record it' {
        # A claim written before reservingSinceUtc existed. Inventing a
        # duration would be worse than leaving it out.
        InModuleScope VmMigrationFactory -Parameters @{ Now = $script:now } {
            param($Now)
            $msg = Get-VmfReservedCapacityRefusal -Wave 'billing-apps' -NowUtc $Now -Claims @(
                OdcrClaim -State 'RESERVING')
            # RESERVING-STUCK-1 changed the answer: a claim that cannot say
            # when it started cannot say anybody is still making it, so "wait"
            # is not true of it. It is not confirmed, and it offers Release.
            $msg | Should -Match 'has not confirmed'
            $msg | Should -Not -Match 'minute\(s\) ago'
        }
    }

    It 'when Azure refused, it says the reservation FAILED and what Azure said' {
        InModuleScope VmMigrationFactory {
            $msg = Get-VmfReservedCapacityRefusal -Wave 'billing-apps' -Claims @(
                OdcrClaim -State 'BLOCKED' -BlockReason 'reservation-failed' `
                          -Notes @('ODCR creation failed: SkuNotAvailable'))
            $msg | Should -Match 'did not work'
            $msg | Should -Match 'reservation-failed'
            $msg | Should -Match 'SkuNotAvailable'
            $msg | Should -Match 'Nothing is held and nothing is billing'
            $msg | Should -Not -Match 'no capacity has been reserved'
        }
    }

    It 'and a blocked claim with nothing recorded still says it did not work' {
        InModuleScope VmMigrationFactory {
            $msg = Get-VmfReservedCapacityRefusal -Wave 'billing-apps' -Claims @(
                OdcrClaim -State 'BLOCKED')
            $msg | Should -Match 'did not work'
            $msg | Should -Not -Match 'Azure said'
        }
    }

    It 'when it was released, it says that rather than pretending none was asked for' {
        InModuleScope VmMigrationFactory {
            $msg = Get-VmfReservedCapacityRefusal -Wave 'billing-apps' -Claims @(
                OdcrClaim -State 'RELEASED')
            $msg | Should -Match 'was released, so nothing is held for it now'
            $msg | Should -Not -Match 'no capacity has been reserved'
        }
    }

    It 'a claim still working outranks an earlier failure, because a job is in flight' {
        InModuleScope VmMigrationFactory -Parameters @{ Now = $script:now } {
            param($Now)
            $msg = Get-VmfReservedCapacityRefusal -Wave 'billing-apps' -NowUtc $Now -Claims @(
                (OdcrClaim -State 'BLOCKED' -BlockReason 'reservation-failed'),
                (OdcrClaim -State 'RESERVING' -SinceUtc '2026-09-19T17:56:00Z'))
            # RESERVING wins here on purpose: something is still running, and
            # telling somebody to correct a cause while a job is in flight
            # invites the double-spend RESERVING was added to prevent.
            $msg | Should -Match 'is having its capacity reserved now'
        }
    }
}

Describe 'ODCR-STATE-1: only a wave that never asked is told how to ask' {

    It 'no claims at all gets the original sentence, which is right for it' {
        InModuleScope VmMigrationFactory {
            $msg = Get-VmfReservedCapacityRefusal -Claims @() -Wave 'billing-apps'
            $msg | Should -Match 'no capacity has been reserved for it'
            $msg | Should -Match 'Reserving is a separate action that spends money'
        }
    }

    It 'and so do the states that come before anybody asked' {
        InModuleScope VmMigrationFactory {
            $checked = 0
            foreach ($s in @('FORECAST', 'QUOTA_VERIFIED', 'QUOTA_REQUESTED')) {
                $msg = Get-VmfReservedCapacityRefusal -Claims @(OdcrClaim -State $s) -Wave 'billing-apps'
                $msg | Should -Match 'no capacity has been reserved for it' -Because "$s is before anybody pressed Reserve"
                $checked++
            }
            $checked | Should -Be 3 -Because 'a loop that ran no cases proves nothing'
        }
    }

    It 'every state the contract allows produces an answer, and they are not all the same' {
        # The rule, not the instance. A new claim state must not fall silently
        # into "you never asked" the way RESERVING did.
        $schema = Get-Content -LiteralPath (
            Join-Path $script:repoRoot 'schemas' 'capacity-claim.schema.json') -Raw | ConvertFrom-Json
        $states = @($schema.properties.state.enum)
        $states.Count | Should -BeGreaterThan 5 -Because 'the schema was read, not an empty object'

        InModuleScope VmMigrationFactory -Parameters @{ States = $states } {
            param($States)
            $answers = @{}
            foreach ($s in $States) {
                $answers[$s] = Get-VmfReservedCapacityRefusal -Claims @(OdcrClaim -State $s) -Wave 'w'
            }
            $answers.Keys.Count | Should -Be $States.Count
            # Held states say nothing; the rest must not collapse to one line.
            $refusals = @($answers.Values | Where-Object { $_ } | Sort-Object -Unique)
            $refusals.Count | Should -BeGreaterOrEqual 4 -Because 'reserving, blocked, released and never-asked are four different facts'
        }
    }
}

Describe 'ODCR-STATE-1: the gate uses it, and the comment does not outlive the gap' {

    It 'Start-VmfWave asks the function rather than judging states itself' {
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $src = Get-VmfCodeOnly -Path (
            Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Start-VmfWave.ps1')
        $src | Should -Match 'Get-VmfReservedCapacityRefusal -Claims \$waveClaims -Wave \$Wave'
        # The old inline test for held states must not linger beside it.
        $src | Should -Not -Match "state -in @\('RESERVED', 'CONSUMED'\)"
    }

    It 'nothing claims the product has no way to create a reservation' {
        # ODCR-GAP-1 was real and is closed: the wave editor has a Reserve
        # capacity control, the facade dispatches it, the engine runs it. The
        # comment saying otherwise survived the fix and was still read as
        # current - the same defect as the refusal, one layer up.
        $src = Get-Content -LiteralPath (
            Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Start-VmfWave.ps1') -Raw
        $src | Should -Not -Match 'which nothing in the product calls'
        $src | Should -Not -Match 'no control anywhere that would create the'
    }

    It 'and the control it says exists really does' {
        $waves = (Get-VmfPageSource -Path (
            Join-Path $script:repoRoot 'src' 'dashboard' 'waves.html'))
        $waves | Should -Match "reserveBtn:\s*'Reserve capacity'"
        $waves | Should -Match 'engine/reserve'
        (Get-Content -LiteralPath (Join-Path $script:repoRoot 'docker' 'entrypoint.ps1') -Raw) |
            Should -Match 'New-VmfWaveReservation'
    }
}
