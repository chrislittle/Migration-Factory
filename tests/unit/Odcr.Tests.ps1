#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    # TEST-1: anything this file forgets to mock must fail as a TEST error,
    # not quietly reach real Azure. Placed before the file's own mocks so
    # those still win where they exist.
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:NewOdcrClaim {
        param($RunPath, $Name, $State = 'QUOTA_VERIFIED', $Zone = $null, $Extra = @{})
        $claim = [ordered]@{
            schemaVersion = 7; runId = 'r1'; wave = 'prod-1'; subscriptionId = '00000000-0000-0000-0000-000000000000'; resourceGroup = 'rg-app'; region = 'centralus'; zone = $Zone
            size = 'Standard_D2s_v6'; vmFamily = 'StandardDsv6Family'; state = $State
            blockReason = $null
            demand = @{ instances = 3; reservableInstances = 3; vcpus = 6; overlapWithSource = $false }
            quota = @{ limit = 10; used = 0; requestId = $null; requestedUtc = $null }
            notes = @()
        }
        foreach ($k in $Extra.Keys) { $claim[$k] = $Extra[$k] }
        $dir = Join-Path $RunPath 'capacity'
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $claim | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $dir "$Name.json")
        Join-Path $dir "$Name.json"
    }
}

AfterAll {
    Remove-Item -Path 'function:\NewOdcrClaim' -ErrorAction SilentlyContinue
}

Describe 'ODCR lifecycle' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-odcr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Initialize-VmfRun -RunPath $rp -RunId 'odcr-test' | Out-Null
        }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'runway reserves QUOTA_VERIFIED claims and records ids' {
        NewOdcrClaim -RunPath $script:runPath -Name 'c1' | Out-Null
        NewOdcrClaim -RunPath $script:runPath -Name 'other-wave' -Extra @{ wave = 'prod-2' } | Out-Null
        Mock -ModuleName VmMigrationFactory New-VmfCapacityReservation {
            @{ GroupId = '/subs/s/rg/crg/g1'; ReservationId = '/subs/s/rg/crg/g1/res/r1' }
        }

        $result = New-VmfWaveReservation -OutPath $script:runPath -Wave 'prod-1'
        @($result.Reserved).Count | Should -Be 1
        $claim = Get-Content (Join-Path $script:runPath 'capacity' 'c1.json') -Raw | ConvertFrom-Json
        $claim.state | Should -Be 'RESERVED'
        $claim.reservation.groupId | Should -Be '/subs/s/rg/crg/g1'
        $claim.reservation.createdUtc | Should -Not -BeNullOrEmpty
        # other wave untouched
        (Get-Content (Join-Path $script:runPath 'capacity' 'other-wave.json') -Raw | ConvertFrom-Json).state |
            Should -Be 'QUOTA_VERIFIED'
        Should -Invoke -ModuleName VmMigrationFactory New-VmfCapacityReservation -ParameterFilter { $Quantity -eq 3 } -Times 1 -Exactly
    }

    It 'ODCR-SUB-1: reserves in the CLAIM''s subscription, not the ambient one' {
        NewOdcrClaim -RunPath $script:runPath -Name 'c1' | Out-Null
        NewOdcrClaim -RunPath $script:runPath -Name 'c2' -Extra @{ subscriptionId = '11111111-1111-1111-1111-111111111111'; size = 'Standard_E2ds_v6' } | Out-Null
        Mock -ModuleName VmMigrationFactory New-VmfCapacityReservation {
            @{ GroupId = "/g/$SubscriptionId"; ReservationId = "/g/$SubscriptionId/r" }
        }
        New-VmfWaveReservation -OutPath $script:runPath -Wave 'prod-1' | Out-Null
        Should -Invoke -ModuleName VmMigrationFactory New-VmfCapacityReservation `
            -ParameterFilter { $SubscriptionId -eq '00000000-0000-0000-0000-000000000000' } -Times 1 -Exactly
        Should -Invoke -ModuleName VmMigrationFactory New-VmfCapacityReservation `
            -ParameterFilter { $SubscriptionId -eq '11111111-1111-1111-1111-111111111111' } -Times 1 -Exactly
    }

    It 'ODCR-SUB-1: the reservation GROUP name differs per subscription' {
        # Two cells of one wave in two subscriptions used to compute the same
        # group name, so the second silently reused the first''s group - in the
        # wrong subscription.
        NewOdcrClaim -RunPath $script:runPath -Name 'c1' | Out-Null
        NewOdcrClaim -RunPath $script:runPath -Name 'c2' -Extra @{ subscriptionId = '11111111-1111-1111-1111-111111111111'; size = 'Standard_E2ds_v6' } | Out-Null
        $names = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName VmMigrationFactory New-VmfCapacityReservation {
            $names.Add($GroupName); @{ GroupId = '/g'; ReservationId = '/g/r' }
        }
        New-VmfWaveReservation -OutPath $script:runPath -Wave 'prod-1' | Out-Null
        @($names).Count | Should -Be 2
        $names[0] | Should -Not -Be $names[1]
    }

    It 'ODCR-SUB-1: refuses a pre-v4 claim that cannot say which subscription' {
        NewOdcrClaim -RunPath $script:runPath -Name 'old' -Extra @{ subscriptionId = $null } | Out-Null
        Mock -ModuleName VmMigrationFactory New-VmfCapacityReservation { @{ GroupId = '/g'; ReservationId = '/g/r' } }
        { New-VmfWaveReservation -OutPath $script:runPath -Wave 'prod-1' } |
            Should -Throw '*does not say which subscription*'
    }

    It 'ODCR-FAIL-1: a partial failure releases what succeeded and reserves nothing' {
        # Ruled 2026-08-29: ALL OR NOTHING. A partly reserved wave cannot
        # run as planned, and holding the successful reservations bills for
        # capacity nothing can use - possibly for ever, since release is a
        # close-out step a wave that never starts never reaches.
        NewOdcrClaim -RunPath $script:runPath -Name 'ok1' | Out-Null
        NewOdcrClaim -RunPath $script:runPath -Name 'bad1' -Extra @{ size = 'Standard_E2ds_v6' } | Out-Null
        Mock -ModuleName VmMigrationFactory New-VmfCapacityReservation {
            if ($Size -eq 'Standard_E2ds_v6') { throw 'AllocationFailed' }
            @{ GroupId = '/g1'; ReservationId = '/g1/r1' }
        }
        Mock -ModuleName VmMigrationFactory Remove-VmfCapacityReservations { }

        $r = New-VmfWaveReservation -OutPath $script:runPath -Wave 'prod-1'
        $r.AllOrNothing | Should -BeTrue
        @($r.Reserved).Count | Should -Be 0 -Because 'nothing is left reserved when the wave cannot run as planned'
        @($r.Released).Count | Should -Be 1
        @($r.Blocked).Count | Should -Be 1
        Should -Invoke -ModuleName VmMigrationFactory Remove-VmfCapacityReservations -Times 1 -Exactly
    }

    It 'ODCR-FAIL-1: and says loudly when the release itself fails, because that is what bills' {
        NewOdcrClaim -RunPath $script:runPath -Name 'ok1' | Out-Null
        NewOdcrClaim -RunPath $script:runPath -Name 'bad1' -Extra @{ size = 'Standard_E2ds_v6' } | Out-Null
        Mock -ModuleName VmMigrationFactory New-VmfCapacityReservation {
            if ($Size -eq 'Standard_E2ds_v6') { throw 'AllocationFailed' }
            @{ GroupId = '/g1'; ReservationId = '/g1/r1' }
        }
        Mock -ModuleName VmMigrationFactory Remove-VmfCapacityReservations { throw 'release blew up' }

        { New-VmfWaveReservation -OutPath $script:runPath -Wave 'prod-1' } |
            Should -Throw '*were not released. Azure bills them.*'
        $events = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            @(Read-VmfEvents -RunPath $rp -Step 'odcr' | Where-Object { $_.outcome -eq 'fail' })
        }
        # MANUAL-REVIEW-1: a sentence, with the Azure name and the control that releases them.
        (@($events).detail -join ' ') | Should -Match 'The on-demand capacity reservations were not released, and Azure bills them'
    }

    It 'ODCR-FAIL-1: an all-succeed run keeps its reservations, as before' {
        NewOdcrClaim -RunPath $script:runPath -Name 'ok1' | Out-Null
        NewOdcrClaim -RunPath $script:runPath -Name 'ok2' -Extra @{ size = 'Standard_E2ds_v6' } | Out-Null
        Mock -ModuleName VmMigrationFactory New-VmfCapacityReservation { @{ GroupId = '/g'; ReservationId = '/g/r' } }
        Mock -ModuleName VmMigrationFactory Remove-VmfCapacityReservations { throw 'must not release on a clean run' }

        $r = New-VmfWaveReservation -OutPath $script:runPath -Wave 'prod-1'
        $r.AllOrNothing | Should -BeFalse
        @($r.Reserved).Count | Should -Be 2
        @($r.Released).Count | Should -Be 0
    }

    It 'runway reserves only reservableInstances, never AvSet demand (CAP-2)' {
        NewOdcrClaim -RunPath $script:runPath -Name 'mixed' -Extra @{
            demand = @{ instances = 4; reservableInstances = 2; vcpus = 8; overlapWithSource = $false }
        } | Out-Null
        Mock -ModuleName VmMigrationFactory New-VmfCapacityReservation {
            @{ GroupId = '/subs/s/rg/crg/g1'; ReservationId = '/subs/s/rg/crg/g1/res/r1' }
        }
        $result = New-VmfWaveReservation -OutPath $script:runPath -Wave 'prod-1'
        @($result.Reserved).Count | Should -Be 1
        Should -Invoke -ModuleName VmMigrationFactory New-VmfCapacityReservation -ParameterFilter { $Quantity -eq 2 } -Times 1 -Exactly
    }

    It 'runway SKIPS a cell whose demand is entirely AvSet members (reservableInstances 0)' {
        NewOdcrClaim -RunPath $script:runPath -Name 'allavset' -Extra @{
            demand = @{ instances = 2; reservableInstances = 0; vcpus = 4; overlapWithSource = $false }
        } | Out-Null
        Mock -ModuleName VmMigrationFactory New-VmfCapacityReservation {
            @{ GroupId = 'g'; ReservationId = 'r' }
        }
        $result = New-VmfWaveReservation -OutPath $script:runPath -Wave 'prod-1'
        @($result.Reserved).Count | Should -Be 0
        @($result.Blocked).Count | Should -Be 0
        Should -Invoke -ModuleName VmMigrationFactory New-VmfCapacityReservation -Times 0 -Exactly
        # stays QUOTA_VERIFIED (BestEffort passes; a Reserved-gated ring
        # surfaces the honest fact that AvSet members get no ODCR guarantee)
        $claim = Get-Content (Join-Path $script:runPath 'capacity' 'allavset.json') -Raw | ConvertFrom-Json
        $claim.state | Should -Be 'QUOTA_VERIFIED'
        ($claim.notes -join ' ') | Should -Match 'availability set'
    }

    It 'runway failure blocks the claim with reservation-failed' {
        NewOdcrClaim -RunPath $script:runPath -Name 'c1' | Out-Null
        Mock -ModuleName VmMigrationFactory New-VmfCapacityReservation { throw 'AllocationFailed: zone exhausted' }
        $result = New-VmfWaveReservation -OutPath $script:runPath -Wave 'prod-1'
        @($result.Blocked).Count | Should -Be 1
        $claim = Get-Content (Join-Path $script:runPath 'capacity' 'c1.json') -Raw | ConvertFrom-Json
        $claim.state | Should -Be 'BLOCKED'
        $claim.blockReason | Should -Be 'reservation-failed'
        ($claim.notes -join ' ') | Should -Match 'AllocationFailed'
    }

    It 'release disassociates recorded VMs, deletes the reservation, marks RELEASED' {
        NewOdcrClaim -RunPath $script:runPath -Name 'c1' -State 'RESERVED' -Extra @{
            # RESERVING-STUCK-1 review: a release reads subscription, resource
            # group and names from the reservation's whole resource id.
            reservation = @{ groupId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/capacityReservationGroups/g1'
                             reservationId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/capacityReservationGroups/g1/capacityReservations/r1'
                             createdUtc = 'x'; releasedUtc = $null; consumedInstances = 2 }
            associatedVmIds = @(
                '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-a/providers/Microsoft.Compute/virtualMachines/vm1',
                '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-a/providers/Microsoft.Compute/virtualMachines/vm2'
            )
        } | Out-Null
        # Record call ORDER: quantity-zero must come strictly before any
        # disassociation (the power-back-up trap; MS option 2).
        $script:callOrder = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName VmMigrationFactory Set-VmfCapacityReservationQuantity { $script:callOrder.Add("quantity:$Quantity") }
        # SEC-1 / F10: the release pins each machine's own subscription, and
        # switching the context is an Azure call like any other.
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { 'previous-context' }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory Set-VmfVmCapacityReservationGroup { $script:callOrder.Add('disassociate') }
        Mock -ModuleName VmMigrationFactory Remove-VmfCapacityReservation { $script:callOrder.Add('delete') }

        $result = Remove-VmfCapacityReservations -OutPath $script:runPath -Wave 'prod-1'
        @($result.Released).Count | Should -Be 1
        $script:callOrder[0] | Should -Be 'quantity:0' -Because 'quantity must hit zero BEFORE disassociating running VMs'
        @($script:callOrder) | Should -Be @('quantity:0', 'disassociate', 'disassociate', 'delete')
        (Get-Content (Join-Path $script:runPath 'capacity' 'c1.json') -Raw | ConvertFrom-Json).state | Should -Be 'RELEASED'
    }

    It 'Get-VmfClaimForEntry matches wave+region+zone+size and only RESERVED' {
        NewOdcrClaim -RunPath $script:runPath -Name 'reserved' -State 'RESERVED' -Zone '1' -Extra @{
            # ID-ADDRESS-1: a whole group ID, in the claim's subscription.
            reservation = @{ groupId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/capacityReservationGroups/g'
                             reservationId = 'r'; createdUtc = 'x'; releasedUtc = $null; consumedInstances = 0 }
        } | Out-Null
        NewOdcrClaim -RunPath $script:runPath -Name 'verifiedOnly' -Zone '2' | Out-Null
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $mkEntry = { param($zone) [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion);
                vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm1'
                wave = 'prod-1'
                assessment = [pscustomobject]@{ location = 'centralus' }
                target = [pscustomobject]@{ size = 'Standard_D2s_v6'; zone = $zone }
            } }
            (Get-VmfClaimForEntry -RunPath $rp -Entry (& $mkEntry '1')).Claim.state | Should -Be 'RESERVED'
            Get-VmfClaimForEntry -RunPath $rp -Entry (& $mkEntry '2') | Should -BeNullOrEmpty   # only QUOTA_VERIFIED
            Get-VmfClaimForEntry -RunPath $rp -Entry (& $mkEntry '3') | Should -BeNullOrEmpty   # no such cell
        }
    }

    It 'engine associates the VM with a RESERVED claim during Path A CONVERTING' {
        NewOdcrClaim -RunPath $script:runPath -Name 'match' -State 'RESERVED' -Zone $null -Extra @{
            reservation = @{ groupId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/capacityReservationGroups/gA'; reservationId = 'r'; createdUtc = 'x'; releasedUtc = $null; consumedInstances = 0 }
        } | Out-Null
        # ORDER is load-bearing (REH-1): Azure validates the VM's CURRENT size
        # against the group at association time, so resize must come first.
        $script:aOrder = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { $script:aOrder.Add('resize') }
        Mock -ModuleName VmMigrationFactory Set-VmfVmCapacityReservationGroup { $script:aOrder.Add('associate') }

        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $entry = [pscustomobject]@{
                schemaVersion = (Get-VmfTestPlanEntryVersion)
                vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-a/providers/Microsoft.Compute/virtualMachines/vmA'
                wave = 'prod-1'; ring = 'prod'
                assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'
                    sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; platformManaged = $false; location = 'centralus' }
                target = [pscustomobject]@{ size = 'Standard_D2s_v6'; diskArch = 'diskless'; controller = 'NVMe'; zone = $null }
                path = 'A'
                policy = [pscustomobject]@{ acceleratedNetworking = 'preserve' }
            }
            New-VmfStateDoc -RunPath $rp -RunId 'odcr-test' -VmId $entry.vmId | Out-Null
            $ctx = New-VmfContext -PlanEntry $entry -RunPath $rp -RunId 'odcr-test'
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{
                size = 'Standard_D2s_v4'; controller = 'SCSI'
                osDisk = @{ name = 'd'; managedDiskId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-a/providers/Microsoft.Compute/disks/d' }
                nics = @()
            } }
            Add-VmfStateTransition -RunPath $rp -VmId $entry.vmId -NewState 'CONVERTING' -Outcome ok | Out-Null
            Set-VmfTestAnDecision -RunPath $rp -VmId ([string]$entry.vmId) -PlanEntry $entry
            $result = Invoke-VmfStepConverting -Context $ctx
            $result.Next | Should -Be 'STARTING'
        }
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmCapacityReservationGroup -ParameterFilter { $GroupId -eq '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/capacityReservationGroups/gA' } -Times 1 -Exactly
        @($script:aOrder) | Should -Be @('resize', 'associate') -Because 'association validates the CURRENT VM size against the group (REH-1)'
        # association recorded on the claim
        $claim = Get-Content (Join-Path $script:runPath 'capacity' 'match.json') -Raw | ConvertFrom-Json
        @($claim.associatedVmIds).Count | Should -Be 1
        $claim.reservation.consumedInstances | Should -Be 1
    }

    It 'engine SKIPS ODCR association for availability-set members (Azure platform limitation)' {
        # Azure rejects capacity-reservation association for VMs in availability
        # sets (confirmed, REH-1). The conversion must proceed on general
        # capacity with the claim left unconsumed - not fail the association call.
        NewOdcrClaim -RunPath $script:runPath -Name 'match' -State 'RESERVED' -Zone $null -Extra @{
            reservation = @{ groupId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/capacityReservationGroups/gA'; reservationId = 'r'; createdUtc = 'x'; releasedUtc = $null; consumedInstances = 0 }
        } | Out-Null
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { }
        Mock -ModuleName VmMigrationFactory Set-VmfVmCapacityReservationGroup { }

        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $entry = [pscustomobject]@{
                schemaVersion = (Get-VmfTestPlanEntryVersion)
                vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-a/providers/Microsoft.Compute/virtualMachines/vmAvs'
                wave = 'prod-1'; ring = 'prod'
                assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'
                    sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; platformManaged = $false; location = 'centralus'
                    availabilitySetId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-a/providers/Microsoft.Compute/availabilitySets/avs1' }
                target = [pscustomobject]@{ size = 'Standard_D2s_v6'; diskArch = 'diskless'; controller = 'NVMe'; zone = $null }
                path = 'A'
                policy = [pscustomobject]@{ acceleratedNetworking = 'preserve' }
            }
            New-VmfStateDoc -RunPath $rp -RunId 'odcr-test' -VmId $entry.vmId | Out-Null
            $ctx = New-VmfContext -PlanEntry $entry -RunPath $rp -RunId 'odcr-test'
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{
                size = 'Standard_D2s_v4'; controller = 'SCSI'
                osDisk = @{ name = 'd'; managedDiskId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-a/providers/Microsoft.Compute/disks/d' }
                nics = @()
            } }
            Add-VmfStateTransition -RunPath $rp -VmId $entry.vmId -NewState 'CONVERTING' -Outcome ok | Out-Null
            Set-VmfTestAnDecision -RunPath $rp -VmId ([string]$entry.vmId) -PlanEntry $entry
            $result = Invoke-VmfStepConverting -Context $ctx
            $result.Next | Should -Be 'STARTING'
        }
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmCapacityReservationGroup -Times 0 -Exactly
        $claim = Get-Content (Join-Path $script:runPath 'capacity' 'match.json') -Raw | ConvertFrom-Json
        @($claim.PSObject.Properties['associatedVmIds'] ? $claim.associatedVmIds : @()).Count | Should -Be 0
        $claim.reservation.consumedInstances | Should -Be 0
    }
}
