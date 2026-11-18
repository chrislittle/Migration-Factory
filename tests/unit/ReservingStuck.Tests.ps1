#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# RESERVING-STUCK-1: a reservation whose state Azure never reported can be
# released.
#
# Two cases, one cause. The product learned a reservation's name only when
# Azure answered, so it could not look one up when Azure did not:
#   1. an engine that stopped between "RESERVING" and Azure's answer left the
#      claim at RESERVING for ever, with no Release;
#   2. a create whose wait timed out was written BLOCKED - "nothing is held" -
#      while the reservation could still provision and bill.
# Now the names are recorded BEFORE Azure is asked, a timeout stays a claim
# that bills and says it was not confirmed, and both are released by name.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    $script:sub = '00000000-0000-0000-0000-000000000000'
    function Global:NewStuckClaim {
        param($RunPath, $Name, $State = 'QUOTA_VERIFIED', $Extra = @{})
        $claim = [ordered]@{
            schemaVersion = 9; runId = 'r1'; wave = 'w1'; subscriptionId = '00000000-0000-0000-0000-000000000000'
            resourceGroup = 'rg-app'; region = 'centralus'; zone = $null
            size = 'Standard_D2s_v6'; vmFamily = 'StandardDsv6Family'; state = $State; blockReason = $null
            demand = @{ instances = 2; reservableInstances = 2; ownGroupVmIds = @(); vcpus = 4; familyVcpus = 4; regionalVcpus = 0; regionalAdds = 0 }
            quota = @{ limit = 10; used = 0; requestId = $null; requestedUtc = $null }
            notes = @()
        }
        foreach ($k in $Extra.Keys) { $claim[$k] = $Extra[$k] }
        # OLD-VERSION-READERS-REMOVE-5: a RESERVING claim holds what it asked
        # for, as New-VmfWaveReservation records it before it asks.
        if ($State -eq 'RESERVING' -and -not $claim.Contains('reservationAsked')) {
            $g = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/capacityReservationGroups/vmf-r1-w1-00000000'
            $claim['reservationAsked'] = [ordered]@{ groupId = $g; reservationId = "$g/capacityReservations/$(([string]$claim['size'] -replace '^Standard_', '').ToLowerInvariant())"; askedUtc = '2026-09-28T10:00:00.0000000Z' }
        }
        $dir = Join-Path $RunPath 'capacity'
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $claim | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $dir "$Name.json")
    }
    function Global:ReadStuckClaim { param($RunPath, $Name) Get-Content (Join-Path $RunPath 'capacity' "$Name.json") -Raw | ConvertFrom-Json }

    # The sentence the REAL wait throws on a timeout, so the tests below
    # drive the engine with what Azure's silence actually produces.
    $script:timeoutMessage = InModuleScope VmMigrationFactory {
        Mock Get-AzCapacityReservation { [pscustomobject]@{ ProvisioningState = 'Creating' } }
        try { Wait-VmfReservationProvisioned -ResourceGroupName 'rg' -ReservationGroupName 'g' -Name 'd2s_v6' -TimeoutSeconds 0 -PollSeconds 0; '' }
        catch { $_.Exception.Message }
    }
}

AfterAll {
    Remove-Item -Path 'function:\NewStuckClaim', 'function:\ReadStuckClaim' -ErrorAction SilentlyContinue
}

Describe 'RESERVING-STUCK-1: the names are known before Azure is asked' {
    It 'one rule names the group and the reservation of a new ask' {
        InModuleScope VmMigrationFactory {
            $c = [pscustomobject]@{ runId = 'r1'; wave = 'w1'; subscriptionId = '00000000-0000-0000-0000-000000000000'
                                    resourceGroup = 'rg-app'; region = 'centralus'; zone = '2'; size = 'Standard_D2s_v6' }
            $n = Get-VmfReservationNames -Claim $c -ForNewAsk
            $n.GroupName | Should -Match '^vmf-r1-w1-00000000-az2-[0-9a-f]{8}$'
            $n.ReservationName | Should -Be 'd2s_v6'
            $n.GroupId | Should -Be "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/capacityReservationGroups/$($n.GroupName)"
            $n.ReservationId | Should -Be "$($n.GroupId)/capacityReservations/d2s_v6"
        }
    }

    It 'a claim that recorded the names is released by what it recorded, not by a rule that may have changed' {
        InModuleScope VmMigrationFactory {
            $c = [pscustomobject]@{ runId = 'r1'; wave = 'w1'; subscriptionId = '00000000-0000-0000-0000-000000000000'
                                    resourceGroup = 'rg-app'; zone = $null; size = 'Standard_D2s_v6'
                                    reservationAsked = [pscustomobject]@{
                                        groupId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-other/providers/Microsoft.Compute/capacityReservationGroups/vmf-old'
                                        reservationId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-other/providers/Microsoft.Compute/capacityReservationGroups/vmf-old/capacityReservations/d2s_v6'
                                        askedUtc = '2026-09-28T10:00:00.0000000Z' } }
            $n = Get-VmfReservationNames -Claim $c
            $n.GroupName | Should -Be 'vmf-old'
            $n.ResourceGroup | Should -Be 'rg-other'
            $n.SubscriptionId | Should -Be '00000000-0000-0000-0000-000000000000' -Because 'the subscription comes from the resource id, never from a name'
        }
    }

    Context 'reserving' {
        BeforeEach {
            $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-stuck-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Initialize-VmfRun -RunPath $rp -RunId 'stuck-test' | Out-Null }
        }
        AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

        It 'the claim holds the names, and says RESERVING, BEFORE the create is asked' {
            NewStuckClaim -RunPath $script:runPath -Name 'c1'
            $script:seen = $null
            $rp = $script:runPath
            Mock -ModuleName VmMigrationFactory New-VmfCapacityReservation {
                $script:seen = Get-Content (Join-Path $rp 'capacity' 'c1.json') -Raw | ConvertFrom-Json
                @{ GroupId = '/g'; ReservationId = '/g/r' }
            }
            New-VmfWaveReservation -OutPath $script:runPath -Wave 'w1' | Out-Null
            $script:seen.state | Should -Be 'RESERVING'
            # CLAIM-NAME-1: a new ask carries a code after the old name, so two waves
            # whose names differ only in punctuation never share a group. The exact
            # name, so a code made from the wrong parts fails here.
            $script:seen.reservationAsked.groupId | Should -BeLike '*/capacityReservationGroups/vmf-r1-w1-00000000-236250ca'
            $script:seen.reservationAsked.reservationId | Should -Match '/capacityReservations/d2s_v6$'
            $script:seen.reservationAsked.askedUtc | Should -Not -BeNullOrEmpty
        }

        It 'the create is asked for by the names it recorded' {
            NewStuckClaim -RunPath $script:runPath -Name 'c1'
            Mock -ModuleName VmMigrationFactory New-VmfCapacityReservation { @{ GroupId = '/g'; ReservationId = '/g/r' } }
            New-VmfWaveReservation -OutPath $script:runPath -Wave 'w1' | Out-Null
            Should -Invoke -ModuleName VmMigrationFactory New-VmfCapacityReservation -Times 1 -Exactly `
                -ParameterFilter { $GroupName -eq 'vmf-r1-w1-00000000-236250ca' -and $ResourceGroupName -eq 'rg-app' }   # CLAIM-NAME-1: a new ask's code
        }

        It 'a wait that ran out is NOT blocked: the claim still bills, and says it was not confirmed' {
            $script:timeoutMessage | Should -Not -BeNullOrEmpty
            NewStuckClaim -RunPath $script:runPath -Name 'c1'
            $msg = $script:timeoutMessage
            Mock -ModuleName VmMigrationFactory New-VmfCapacityReservation { throw $msg }
            Mock -ModuleName VmMigrationFactory Remove-VmfCapacityReservation { }
            $r = New-VmfWaveReservation -OutPath $script:runPath -Wave 'w1'
            $c = ReadStuckClaim -RunPath $script:runPath -Name 'c1'
            $c.state | Should -Not -Be 'BLOCKED'
            $c.reservationUnconfirmedUtc | Should -Not -BeNullOrEmpty
            @($r.Unconfirmed).Count | Should -Be 1
            $r.AllOrNothing | Should -BeTrue -Because 'a wave with a cell nobody confirmed cannot run as planned'
        }

        It 'a timeout is never retried as a passing fault: the create is asked once' {
            # RESTORE-POWER-READ-1: not $msg - Invoke-VmfAzOperation holds a $msg of its own.
            InModuleScope VmMigrationFactory -Parameters @{ timeoutWords = $script:timeoutMessage } {
                $script:calls = 0
                { Invoke-VmfAzOperation -Name 'odcr' -BaseDelayMs 0 -Operation { $script:calls++; throw $timeoutWords } } | Should -Throw
                $script:calls | Should -Be 1
            }
        }

        It 'Azure answering Failed is still BLOCKED: that answer means nothing is held' {
            NewStuckClaim -RunPath $script:runPath -Name 'c1'
            Mock -ModuleName VmMigrationFactory New-VmfCapacityReservation {
                throw "Azure did not provision the capacity reservation 'd2s_v6' in 'g': provisioningState is Failed. The capacity was not held."
            }
            New-VmfWaveReservation -OutPath $script:runPath -Wave 'w1' | Out-Null
            $c = ReadStuckClaim -RunPath $script:runPath -Name 'c1'
            $c.state | Should -Be 'BLOCKED'
            $c.PSObject.Properties['reservationUnconfirmedUtc'] | Should -BeNullOrEmpty
        }

        It 'a release during a long create is not undone when the create returns' {
            NewStuckClaim -RunPath $script:runPath -Name 'c1'
            $rp = $script:runPath
            Mock -ModuleName VmMigrationFactory New-VmfCapacityReservation {
                # The operator released it while Azure was still building it.
                $c = Get-Content (Join-Path $rp 'capacity' 'c1.json') -Raw | ConvertFrom-Json
                $c.state = 'RELEASED'
                $c | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $rp 'capacity' 'c1.json')
                @{ GroupId = '/g'; ReservationId = '/g/r' }
            }
            Mock -ModuleName VmMigrationFactory Remove-VmfCapacityReservation { }
            New-VmfWaveReservation -OutPath $script:runPath -Wave 'w1' | Out-Null
            (ReadStuckClaim -RunPath $script:runPath -Name 'c1').state | Should -Be 'RELEASED'
            Should -Invoke -ModuleName VmMigrationFactory Remove-VmfCapacityReservation -Times 1 -Exactly `
                -ParameterFilter { $GroupName -eq 'vmf-r1-w1-00000000-236250ca' -and $ReservationName -eq 'd2s_v6' } `
                -Because 'what Azure made after the release must go too, or it bills with no record'
        }
    }
}

Describe 'RESERVING-STUCK-1: which RESERVING claims can be released' {
    It 'one still inside the time a create can take is left alone; one past it, or not confirmed, can go' {
        InModuleScope VmMigrationFactory {
            $now = [datetime]::Parse('2026-09-28T12:00:00Z').ToUniversalTime()
            $at = { param($mins) $now.AddMinutes(-$mins).ToString('o') }
            Test-VmfClaimReservingStuck -NowUtc $now -Claim ([pscustomobject]@{ state = 'RESERVING'; reservingSinceUtc = (& $at 5) }) | Should -BeFalse
            Test-VmfClaimReservingStuck -NowUtc $now -Claim ([pscustomobject]@{ state = 'RESERVING'; reservingSinceUtc = (& $at 59) }) | Should -BeFalse
            Test-VmfClaimReservingStuck -NowUtc $now -Claim ([pscustomobject]@{ state = 'RESERVING'; reservingSinceUtc = (& $at 61) }) | Should -BeTrue
            Test-VmfClaimReservingStuck -NowUtc $now -Claim ([pscustomobject]@{ state = 'RESERVING'; reservingSinceUtc = (& $at 1); reservationUnconfirmedUtc = (& $at 0) }) | Should -BeTrue
            Test-VmfClaimReservingStuck -NowUtc $now -Claim ([pscustomobject]@{ state = 'RESERVING' }) | Should -BeTrue -Because 'a claim that cannot say when it started cannot say it is still going'
            Test-VmfClaimReservingStuck -NowUtc $now -Claim ([pscustomobject]@{ state = 'RESERVED'; reservingSinceUtc = (& $at 90) }) | Should -BeFalse
        }
    }

    It 'the limit is longer than the wait the engine itself sets' {
        # The create call can block longer than its wait; an overlap with a
        # live engine is made safe by the versioned writes below, not by this.
        InModuleScope VmMigrationFactory {
            (Get-Command Wait-VmfReservationProvisioned).Parameters['TimeoutSeconds'] | Should -Not -BeNullOrEmpty
            $script:VmfReservingStuckMinutes * 60 | Should -BeGreaterThan 600
        }
    }
}

Describe 'RESERVING-STUCK-1: the release takes a stuck claim, by name' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-stuck-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Initialize-VmfRun -RunPath $rp -RunId 'stuck-test' | Out-Null }
        $script:old = (Get-Date).ToUniversalTime().AddHours(-3).ToString('o')
        $script:fresh = (Get-Date).ToUniversalTime().AddMinutes(-2).ToString('o')
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'a claim an engine left at RESERVING is released by its names, and recorded RELEASED' {
        NewStuckClaim -RunPath $script:runPath -Name 'c1' -State 'RESERVING' -Extra @{ reservingSinceUtc = $script:old }
        Mock -ModuleName VmMigrationFactory Remove-VmfCapacityReservation { }
        Mock -ModuleName VmMigrationFactory Test-VmfCapacityReservationPresent { $false }
        Mock -ModuleName VmMigrationFactory Set-VmfCapacityReservationQuantity { }
        $r = Remove-VmfCapacityReservations -OutPath $script:runPath -Wave 'w1'
        Should -Invoke -ModuleName VmMigrationFactory Remove-VmfCapacityReservation -Times 1 -Exactly -ParameterFilter {
            $ResourceGroupName -eq 'rg-app' -and $GroupName -eq 'vmf-r1-w1-00000000' -and $ReservationName -eq 'd2s_v6' -and $SubscriptionId -eq '00000000-0000-0000-0000-000000000000' }
        $c = ReadStuckClaim -RunPath $script:runPath -Name 'c1'
        $c.state | Should -Be 'RELEASED'
        $c.reservation.releasedUtc | Should -Not -BeNullOrEmpty
        $c.reservation.createdUtc | Should -BeNullOrEmpty -Because 'nobody saw it made; a made-up start time is a made-up bill'
        @($r.Released).Count | Should -Be 1
    }

    It 'the release goes to the subscription and resource group in the recorded resource id, whatever the name' {
        $other = '11111111-2222-3333-4444-555555555555'
        $gid = "/subscriptions/$other/resourceGroups/rg-elsewhere/providers/Microsoft.Compute/capacityReservationGroups/vmf-r1-w1-00000000"
        NewStuckClaim -RunPath $script:runPath -Name 'c1' -State 'RESERVING' -Extra @{
            subscriptionId = $other; reservingSinceUtc = $script:old
            reservationAsked = @{ groupId = $gid; reservationId = "$gid/capacityReservations/d2s_v6"; askedUtc = $script:old } }
        Mock -ModuleName VmMigrationFactory Remove-VmfCapacityReservation { }
        Mock -ModuleName VmMigrationFactory Test-VmfCapacityReservationPresent { $false }
        Remove-VmfCapacityReservations -OutPath $script:runPath -Wave 'w1' | Out-Null
        Should -Invoke -ModuleName VmMigrationFactory Remove-VmfCapacityReservation -Times 1 -Exactly -ParameterFilter {
            $SubscriptionId -eq '11111111-2222-3333-4444-555555555555' -and $ResourceGroupName -eq 'rg-elsewhere' }
    }

    It 'a recorded resource id in another subscription than the claim is refused, not guessed at' {
        $gid = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-app/providers/Microsoft.Compute/capacityReservationGroups/vmf-r1-w1-00000000'
        NewStuckClaim -RunPath $script:runPath -Name 'c1' -State 'RESERVING' -Extra @{
            reservingSinceUtc = $script:old
            reservationAsked = @{ groupId = $gid; reservationId = "$gid/capacityReservations/d2s_v6"; askedUtc = $script:old } }
        Mock -ModuleName VmMigrationFactory Remove-VmfCapacityReservation { }
        $r = Remove-VmfCapacityReservations -OutPath $script:runPath -Wave 'w1'
        Should -Invoke -ModuleName VmMigrationFactory Remove-VmfCapacityReservation -Times 0 -Exactly
        (ReadStuckClaim -RunPath $script:runPath -Name 'c1').state | Should -Be 'RESERVING'
        @($r.NotReleased).Count | Should -Be 1
    }

    It 'a create that is still inside its time is left alone' {
        NewStuckClaim -RunPath $script:runPath -Name 'c1' -State 'RESERVING' -Extra @{ reservingSinceUtc = $script:fresh }
        Mock -ModuleName VmMigrationFactory Remove-VmfCapacityReservation { }
        Remove-VmfCapacityReservations -OutPath $script:runPath -Wave 'w1' | Out-Null
        Should -Invoke -ModuleName VmMigrationFactory Remove-VmfCapacityReservation -Times 0 -Exactly
        (ReadStuckClaim -RunPath $script:runPath -Name 'c1').state | Should -Be 'RESERVING'
    }

    It 'a stuck release Azure refuses stays billing, is said, and does not stop the others' {
        NewStuckClaim -RunPath $script:runPath -Name 'a-stuck' -State 'RESERVING' -Extra @{ reservingSinceUtc = $script:old; reservationUnconfirmedUtc = $script:old }
        NewStuckClaim -RunPath $script:runPath -Name 'b-held' -State 'RESERVED' -Extra @{
            size = 'Standard_E2s_v6'
            reservation = @{ groupId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/capacityReservationGroups/vmf-r1-w1-00000000'
                             reservationId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/capacityReservationGroups/vmf-r1-w1-00000000/capacityReservations/e2s_v6'
                             createdUtc = $script:old; releasedUtc = $null; consumedInstances = 0 } }
        Mock -ModuleName VmMigrationFactory Remove-VmfCapacityReservation { throw 'OperationNotAllowed: the reservation is being created' } -ParameterFilter { $ReservationName -eq 'd2s_v6' }
        Mock -ModuleName VmMigrationFactory Remove-VmfCapacityReservation { } -ParameterFilter { $ReservationName -eq 'e2s_v6' }
        Mock -ModuleName VmMigrationFactory Set-VmfCapacityReservationQuantity { }
        $r = Remove-VmfCapacityReservations -OutPath $script:runPath -Wave 'w1'
        (ReadStuckClaim -RunPath $script:runPath -Name 'a-stuck').state | Should -Be 'RESERVING'
        (ReadStuckClaim -RunPath $script:runPath -Name 'b-held').state | Should -Be 'RELEASED'
        @($r.NotReleased).Count | Should -Be 1
        $events = Get-Content (Join-Path $script:runPath 'logs' 'events.jsonl') -Raw
        $events | Should -Match 'can still bill'
    }
}

Describe 'RESERVING-STUCK-1: what a person is told' {
    It 'the start check does not say "wait" for a claim that nobody is making any more' {
        InModuleScope VmMigrationFactory {
            $now = (Get-Date).ToUniversalTime()
            $said = Get-VmfReservedCapacityRefusal -Wave 'w1' -NowUtc $now -Claims @(
                [pscustomobject]@{ state = 'RESERVING'; reservingSinceUtc = $now.AddHours(-3).ToString('o') })
            $said | Should -Not -Match 'Wait for the wave'
            $said | Should -Match 'not confirmed'
            $said | Should -Match 'Release'
        }
    }

    It 'the start check still says wait while a create is running' {
        InModuleScope VmMigrationFactory {
            $now = (Get-Date).ToUniversalTime()
            Get-VmfReservedCapacityRefusal -Wave 'w1' -NowUtc $now -Claims @(
                [pscustomobject]@{ state = 'RESERVING'; reservingSinceUtc = $now.AddMinutes(-3).ToString('o') }) | Should -Match 'Wait for the wave'
        }
    }

    It 'the refusal to change a wave names the way out for a claim that shows Not confirmed' {
        InModuleScope VmMigrationFactory {
            Get-VmfBillingClaimRefusal -Wave 'w1' -States @('RESERVING') -Action 'save again' | Should -Match 'Not confirmed.*Release'
        }
    }

    It 'the activity log does not print an empty time for a reservation nobody saw made' {
        InModuleScope VmMigrationFactory {
            Mock Save-VmfReleasedClaimHistory { }
            Mock Write-VmfEvent { }
            $c = [pscustomobject]@{ wave = 'w1'; size = 'Standard_D2s_v6'; region = 'centralus'
                                    reservation = [pscustomobject]@{ createdUtc = $null; releasedUtc = '2026-09-28T12:00:00.0000000Z' } }
            Write-VmfReleasedClaimNote -RunPath (Join-Path ([System.IO.Path]::GetTempPath()) 'vmf-stuck-note') -Claim $c
            Should -Invoke Write-VmfEvent -Times 1 -Exactly -ParameterFilter { $Detail -notmatch 'reserved\s+and' -and $Detail -match 'not confirmed' }
        }
    }

    # MANUAL-REVIEW-1: the dates are read before the sentence; the sentence
    # is as it was, with both times in ISO UTC.
    It 'the activity log gives both times of a released reservation, and the release time of one Azure had not confirmed' {
        InModuleScope VmMigrationFactory {
            Mock Save-VmfReleasedClaimHistory { }
            Mock Write-VmfEvent { }
            $rp = Join-Path ([System.IO.Path]::GetTempPath()) 'vmf-stuck-note'
            $made = [pscustomobject]@{ wave = 'w1'; size = 'Standard_D2s_v6'; region = 'centralus'
                                       reservation = [pscustomobject]@{ createdUtc = '2026-09-28T10:00:00Z'; releasedUtc = '2026-09-28T12:00:00Z' } }
            Write-VmfReleasedClaimNote -RunPath $rp -Claim $made
            Should -Invoke Write-VmfEvent -Times 1 -Exactly -ParameterFilter {
                $Detail -eq 'Wave w1 changed, so the record of its released on-demand capacity reservation (Standard_D2s_v6 in centralus) was removed. It was reserved 2026-09-28T10:00:00Z and released 2026-09-28T12:00:00Z.' }
            $unseen = [pscustomobject]@{ wave = 'w1'; size = 'Standard_D2s_v6'; region = 'centralus'
                                         reservation = [pscustomobject]@{ createdUtc = $null; releasedUtc = '2026-09-28T12:00:00Z' } }
            Write-VmfReleasedClaimNote -RunPath $rp -Claim $unseen
            Should -Invoke Write-VmfEvent -Times 1 -Exactly -ParameterFilter {
                $Detail -eq 'Wave w1 changed, so the record of its released on-demand capacity reservation (Standard_D2s_v6 in centralus) was removed. Azure had not confirmed it, and it was released 2026-09-28T12:00:00Z.' }
        }
    }
}

Describe 'RESERVING-STUCK-1: the contract and the page' {
    It 'a claim with the new fields is valid, and the fields are declared' {
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'capacity-claim.schema.json') -Raw
        $s = $schema | ConvertFrom-Json
        foreach ($f in 'reservingSinceUtc', 'reservationAsked', 'reservationUnconfirmedUtc') {
            $s.properties.PSObject.Properties.Name | Should -Contain $f
        }
        $claim = [ordered]@{
            schemaVersion = $s.properties.schemaVersion.const; runId = 'r1'; wave = 'w1'; subscriptionId = $script:sub
            resourceGroup = 'rg-app'; region = 'centralus'; zone = $null; size = 'Standard_D2s_v6'; vmFamily = $null
            state = 'RESERVING'; blockReason = $null; notes = @()
            demand = [ordered]@{ instances = 2; reservableInstances = 2; ownGroupVmIds = @(); vcpus = 4; familyVcpus = 4; regionalVcpus = 0; regionalAdds = 0 }
            reservingSinceUtc = '2026-09-28T10:00:00.0000000Z'
            reservationUnconfirmedUtc = '2026-09-28T10:10:00.0000000Z'
            reservationAsked = [ordered]@{ groupId = '/g'; reservationId = '/g/r'; askedUtc = '2026-09-28T10:00:00.0000000Z' }
        }
        ($claim | ConvertTo-Json -Depth 8) | Test-Json -Schema $schema -ErrorAction SilentlyContinue | Should -BeTrue
    }

    It 'the page uses one rule for "not confirmed", with the engine''s limit' {
        $help = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js')
        $help | Should -Match 'function claimReservingStuck'
        $help | Should -Match 'RESERVING_STUCK_MINUTES = 60'
        $engine = InModuleScope VmMigrationFactory { $script:VmfReservingStuckMinutes }
        $engine | Should -Be 60
    }

    It 'the wave shows Not confirmed, with Release beside it' {
        $page = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'waves.html')
        $page | Should -Match 'VmfHelp\.claimReservingStuck\(d'
        $page | Should -Match "if \(stuck\) \{ claims\.set\(d\.wave, 'unconfirmed'\); \}"
        # Not confirmed outranks Not reserved: it is the one that may bill.
        # AVSET-RESERVE-1: "blocked" here is now blockedHere - a blocked claim
        # that has something to reserve, or whose reservation failed. A quota
        # block on availability-set machines only is not a failed reservation.
        $page | Should -Match "else if \(blockedHere && claims\.get\(d\.wave\) !== 'unconfirmed'\)"
        $page | Should -Match "const blockedHere = VmfHelp\.claimBlocked\(st\) && "
        $page | Should -Match "if \(st === 'unconfirmed'\)"
        # billing: a stuck claim offers Release
        $page | Should -Match 'if \(stuck\) \{ billingWaves\.add\(d\.wave\); \}'
    }
}

Describe 'RESERVING-STUCK-1 review: a timeout is never retried, whatever the names hold' {
    It 'a group name holding 429 and 503 does not make the timeout a passing fault' {
        InModuleScope VmMigrationFactory {
            Mock Get-AzCapacityReservation { [pscustomobject]@{ ProvisioningState = 'Creating' } }
            $timeoutWords = try { Wait-VmfReservationProvisioned -ResourceGroupName 'rg' -ReservationGroupName 'vmf-run429-w500-50300000' -Name 'd2s_v6' -TimeoutSeconds 0 -PollSeconds 0; '' } catch { $_.Exception.Message }
            $timeoutWords | Should -Match '429'
            $script:calls = 0
            { Invoke-VmfAzOperation -Name 'odcr' -BaseDelayMs 0 -Operation { $script:calls++; throw $timeoutWords } } | Should -Throw
            $script:calls | Should -Be 1
        }
    }
}

Describe 'RESERVING-STUCK-1 review: two writers never overwrite each other' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-stuck-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Initialize-VmfRun -RunPath $rp -RunId 'stuck-test' | Out-Null }
        $script:old = (Get-Date).ToUniversalTime().AddHours(-3).ToString('o')
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'a claim another reserve run took first is not asked for twice' {
        NewStuckClaim -RunPath $script:runPath -Name 'c1'
        Mock -ModuleName VmMigrationFactory Write-VmfTextDocumentIfVersion { throw '409: changed' }
        Mock -ModuleName VmMigrationFactory New-VmfCapacityReservation { @{ GroupId = '/g'; ReservationId = '/g/r' } }
        New-VmfWaveReservation -OutPath $script:runPath -Wave 'w1' | Out-Null
        Should -Invoke -ModuleName VmMigrationFactory New-VmfCapacityReservation -Times 0 -Exactly -Because 'a second press pays twice for one guarantee'
    }

    It 'a stuck release whose claim changed meanwhile is not written RELEASED' {
        NewStuckClaim -RunPath $script:runPath -Name 'c1' -State 'RESERVING' -Extra @{ reservingSinceUtc = $script:old }
        Mock -ModuleName VmMigrationFactory Remove-VmfCapacityReservation { }
        Mock -ModuleName VmMigrationFactory Test-VmfCapacityReservationPresent { $false }
        Mock -ModuleName VmMigrationFactory Write-VmfTextDocumentIfVersion { throw '409: changed' }
        $r = Remove-VmfCapacityReservations -OutPath $script:runPath -Wave 'w1'
        (ReadStuckClaim -RunPath $script:runPath -Name 'c1').state | Should -Be 'RESERVING'
        @($r.NotReleased).Count | Should -Be 1
    }

    It 'a claim the reserve run rewrites carries the version it now meets' {
        NewStuckClaim -RunPath $script:runPath -Name 'c1' -Extra @{ schemaVersion = 8 }
        Mock -ModuleName VmMigrationFactory New-VmfCapacityReservation { @{ GroupId = '/g'; ReservationId = '/g/r' } }
        New-VmfWaveReservation -OutPath $script:runPath -Wave 'w1' | Out-Null
        (ReadStuckClaim -RunPath $script:runPath -Name 'c1').schemaVersion | Should -Be (InModuleScope VmMigrationFactory { $script:VmfCapacityClaimSchemaVersion })
    }
}

Describe 'RESERVING-STUCK-1 review: RELEASED only when Azure shows it gone' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-stuck-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Initialize-VmfRun -RunPath $rp -RunId 'stuck-test' | Out-Null }
        $script:old = (Get-Date).ToUniversalTime().AddHours(-3).ToString('o')
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'a delete that skipped a reservation it could not read is not a release' {
        NewStuckClaim -RunPath $script:runPath -Name 'c1' -State 'RESERVING' -Extra @{ reservingSinceUtc = $script:old }
        Mock -ModuleName VmMigrationFactory Remove-VmfCapacityReservation { }
        Mock -ModuleName VmMigrationFactory Test-VmfCapacityReservationPresent { $true }
        $r = Remove-VmfCapacityReservations -OutPath $script:runPath -Wave 'w1'
        (ReadStuckClaim -RunPath $script:runPath -Name 'c1').state | Should -Be 'RESERVING'
        @($r.NotReleased).Count | Should -Be 1
    }

    It 'a check that cannot read Azure is not "gone"' {
        NewStuckClaim -RunPath $script:runPath -Name 'c1' -State 'RESERVING' -Extra @{ reservingSinceUtc = $script:old }
        Mock -ModuleName VmMigrationFactory Remove-VmfCapacityReservation { }
        Mock -ModuleName VmMigrationFactory Test-VmfCapacityReservationPresent { throw 'TooManyRequests' }
        $r = Remove-VmfCapacityReservations -OutPath $script:runPath -Wave 'w1'
        (ReadStuckClaim -RunPath $script:runPath -Name 'c1').state | Should -Be 'RESERVING'
        @($r.NotReleased).Count | Should -Be 1
    }

    It 'the presence check reads only NotFound as absent' {
        InModuleScope VmMigrationFactory {
            Mock Get-VmfAzContextForSubscription { $null }
            Mock Get-AzCapacityReservation { throw 'ResourceNotFound: The Resource was not found.' }
            Test-VmfCapacityReservationPresent -ResourceGroupName 'rg' -GroupName 'g' -ReservationName 'r' -SubscriptionId '00000000-0000-0000-0000-000000000000' | Should -BeFalse
            Mock Get-AzCapacityReservation { throw 'ParentResourceNotFound: the group was not found.' }
            Test-VmfCapacityReservationPresent -ResourceGroupName 'rg' -GroupName 'g' -ReservationName 'r' -SubscriptionId '00000000-0000-0000-0000-000000000000' | Should -BeFalse
            Mock Get-AzCapacityReservation { throw 'TooManyRequests' }
            { Test-VmfCapacityReservationPresent -ResourceGroupName 'rg' -GroupName 'g' -ReservationName 'r' -SubscriptionId '00000000-0000-0000-0000-000000000000' } | Should -Throw
            Mock Get-AzCapacityReservation { [pscustomobject]@{ Id = '/g/r' } }
            Test-VmfCapacityReservationPresent -ResourceGroupName 'rg' -GroupName 'g' -ReservationName 'r' -SubscriptionId '00000000-0000-0000-0000-000000000000' | Should -BeTrue
        }
    }
}

Describe 'RESERVING-STUCK-1 review: a held reservation is released by its own resource id' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-stuck-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Initialize-VmfRun -RunPath $rp -RunId 'stuck-test' | Out-Null }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'subscription and resource group come from the reservation''s id, and one that disagrees is refused' {
        $gid = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-other/providers/Microsoft.Compute/capacityReservationGroups/vmf-r1-w1-11111111'
        NewStuckClaim -RunPath $script:runPath -Name 'c1' -State 'RESERVED' -Extra @{
            reservation = @{ groupId = $gid; reservationId = "$gid/capacityReservations/d2s_v6"; createdUtc = '2026-09-28T10:00:00.0000000Z'; releasedUtc = $null; consumedInstances = 0 } }
        Mock -ModuleName VmMigrationFactory Set-VmfCapacityReservationQuantity { }
        Mock -ModuleName VmMigrationFactory Remove-VmfCapacityReservation { }
        $r = Remove-VmfCapacityReservations -OutPath $script:runPath -Wave 'w1'
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfCapacityReservationQuantity -Times 0 -Exactly
        Should -Invoke -ModuleName VmMigrationFactory Remove-VmfCapacityReservation -Times 0 -Exactly
        (ReadStuckClaim -RunPath $script:runPath -Name 'c1').state | Should -Be 'RESERVED'
        @($r.NotReleased).Count | Should -Be 1
    }

    It 'a matching id is released in the subscription and resource group it names' {
        $gid = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-other/providers/Microsoft.Compute/capacityReservationGroups/vmf-r1-w1-00000000'
        NewStuckClaim -RunPath $script:runPath -Name 'c1' -State 'RESERVED' -Extra @{
            reservation = @{ groupId = $gid; reservationId = "$gid/capacityReservations/d2s_v6"; createdUtc = '2026-09-28T10:00:00.0000000Z'; releasedUtc = $null; consumedInstances = 0 } }
        Mock -ModuleName VmMigrationFactory Set-VmfCapacityReservationQuantity { }
        Mock -ModuleName VmMigrationFactory Remove-VmfCapacityReservation { }
        Remove-VmfCapacityReservations -OutPath $script:runPath -Wave 'w1' | Out-Null
        Should -Invoke -ModuleName VmMigrationFactory Remove-VmfCapacityReservation -Times 1 -Exactly -ParameterFilter {
            $ResourceGroupName -eq 'rg-other' -and $SubscriptionId -eq '00000000-0000-0000-0000-000000000000' -and $GroupName -eq 'vmf-r1-w1-00000000' -and $ReservationName -eq 'd2s_v6' }
    }
}

Describe 'RESERVING-STUCK-1 review: what people and records are told' {
    It 'the start check refuses a wave with a held cell and a stuck one' {
        InModuleScope VmMigrationFactory {
            $now = (Get-Date).ToUniversalTime()
            $said = Get-VmfReservedCapacityRefusal -Wave 'w1' -NowUtc $now -Claims @(
                [pscustomobject]@{ state = 'RESERVED' },
                [pscustomobject]@{ state = 'RESERVING'; reservingSinceUtc = $now.AddHours(-3).ToString('o') })
            $said | Should -Match 'has not confirmed'
            $said | Should -Not -Match 'no capacity reservation' -Because 'a wave with a claim that bills cannot be saved to another setting'
        }
    }

    It 'two releases of one cell that Azure never confirmed are kept as two history records' {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-stuck-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } {
                Initialize-VmfRun -RunPath $rp -RunId 'h' | Out-Null
                $mk = { param($at) [pscustomobject]@{ schemaVersion = 9; wave = 'w1'; region = 'centralus'; size = 'Standard_D2s_v6'; zone = $null; state = 'RELEASED'
                        reservation = [pscustomobject]@{ reservationId = '/g/r'; createdUtc = $null; releasedUtc = $at; consumedInstances = 0 } } }
                Save-VmfReleasedClaimHistory -RunPath $rp -Claim (& $mk '2026-09-28T10:00:00.0000000Z')
                Save-VmfReleasedClaimHistory -RunPath $rp -Claim (& $mk '2026-09-28T12:00:00.0000000Z')
                @(Get-VmfStoreNames -RunPath $rp -Folder 'capacity-history' -Extension '.json').Count | Should -Be 2
            }
        } finally { if (Test-Path $rp) { Remove-Item $rp -Recurse -Force } }
    }

    It 'the Reports page does not count a reservation Azure never confirmed' {
        $page = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'reports.html')
        $page | Should -Match "!\(c\.state === 'RELEASED' && !c\.reservation\.createdUtc\)"
    }

    It 'close-out does not say "stopped billing" when one could not be released' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Invoke-VmfWaveCloseOut.ps1')
        $code | Should -Match '\.NotReleased'
    }
}
