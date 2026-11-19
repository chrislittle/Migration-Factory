#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# CRG-MOVE-ZONE-1: a zonal capacity reservation group can reserve the target
# size in another zone only.
#
# CRG-MOVE-1 asked one thing at Checking: does the machine's own group have a
# capacity reservation for the target size? It compared the size only. A
# capacity reservation in a zonal group is for one availability zone, so a
# machine in zone 1, in a group that reserves the target size in zone 2 only,
# passed - and the refusal could come after the machine stopped.
#
# DECIDED 2026-11-02, option 2 (compare the zone too): the same read
# (Get-VmfCapacityReservationSizes, one Get-AzCapacityReservation, no new role
# action) also returns each reservation's zones, and the check asks for the
# target size IN THE MACHINE'S OWN ZONE, on the same reservation. A reservation
# only in another zone stops the machine untouched and names the zone. A
# regional reservation (no zones) and a machine with no zone pass, as before.
# A zone that cannot be read is never a pass.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'crgzone'

    $script:subId = '00000000-0000-0000-0000-000000000000'
    $script:sub = "/subscriptions/$script:subId"
    $script:vmId = "$script:sub/resourceGroups/rg-lab/providers/Microsoft.Compute/virtualMachines/vm1"
    $script:theirs = "$script:sub/resourceGroups/rg-capacity/providers/Microsoft.Compute/capacityReservationGroups/contoso-crg"
    $script:target = 'Standard_D2ds_v6'
    $script:source = 'Standard_D2ds_v4'

    # A run with this machine in the customer's group. -Zone is the zone this
    # attempt's capture recorded: a zone number, 'none' (a regional machine,
    # as Azure gives it: a list with no zone) or 'unknown' (no field).
    function Global:CzNewRun {
        param([string]$Zone = 'none')
        $rp = Join-Path $script:temp "run-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; z = $Zone; g = $script:theirs; sub = $script:subId; src = $script:source } {
            param($rp, $id, $z, $g, $sub, $src)
            Initialize-VmfRun -RunPath $rp -RunId 'crgzone' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'crgzone' -VmId $id -Wave 'w1' | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $vmConfig = [ordered]@{ size = $src; controller = 'SCSI'; location = 'centralus'; name = 'vm1'; osType = 'Linux'
                osDisk = [ordered]@{ name = 'vm1-osdisk'; skuName = 'Premium_LRS'; managedDiskId = "/subscriptions/$sub/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/vm1-osdisk" }
                dataDisks = @(); nics = @(); capacityReservationGroupId = $g }
            if ($z -eq 'none') { $vmConfig.zones = @($null) }
            elseif ($z -ne 'unknown') { $vmConfig.zones = @($z) }
            $doc | Add-Member -NotePropertyName captured -NotePropertyValue ([pscustomobject]@{ vmConfig = [pscustomobject]$vmConfig }) -Force
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        $rp
    }
    function Global:CzGate([string]$Rp) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $Rp; id = $script:vmId; tgt = $script:target; src = $script:source } {
            param($rp, $id, $tgt, $src)
            $plan = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; path = 'A'; wave = 'w1'; ring = 'prod'
                assessment = [pscustomobject]@{ location = 'centralus'; os = 'Linux'; gen = 'V2'; sourceSize = $src }
                target = [pscustomobject]@{ size = $tgt; controller = 'NVMe'; zone = $null }
                policy = [pscustomobject]@{ acceleratedNetworking = 'preserve' } }
            $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'crgzone'
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            Test-VmfMoveReservationGroup -Context $ctx -Capture $doc.captured.vmConfig -TargetSize $tgt
        }
    }
    # The capture as PRECHECK passes it: Get-VmfVmCapture returns a HASHTABLE
    # (an ordered dictionary), never the object a state document is read back
    # as. -Zone: a zone number, 'none' (zones = @()), 'nullzone' (zones =
    # @($null), as Azure gives a regional machine) or 'unknown' (no key).
    function Global:CzGateLive([string]$Rp, [string]$Zone) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $Rp; id = $script:vmId; tgt = $script:target; src = $script:source; z = $Zone; g = $script:theirs } {
            param($rp, $id, $tgt, $src, $z, $g)
            $plan = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; path = 'A'; wave = 'w1'; ring = 'prod'
                assessment = [pscustomobject]@{ location = 'centralus'; os = 'Linux'; gen = 'V2'; sourceSize = $src }
                target = [pscustomobject]@{ size = $tgt; controller = 'NVMe'; zone = $null }
                policy = [pscustomobject]@{ acceleratedNetworking = 'preserve' } }
            $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'crgzone'
            $capture = [ordered]@{ size = $src; name = 'vm1'; capacityReservationGroupId = $g }
            switch ($z) {
                'unknown' { }
                'none' { $capture.zones = @() }
                'nullzone' { $capture.zones = @($null) }
                default { $capture.zones = @($z) }
            }
            Test-VmfMoveReservationGroup -Context $ctx -Capture $capture -TargetSize $tgt
        }
    }    function Global:CzLines([string]$Rp) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $Rp } { param($rp) @(Read-VmfEvents -RunPath $rp) }
    }
    # One capacity reservation, as the read gives it: its size and its zones.
    function Global:CzRes([string]$Size, [string[]]$Zones = @()) {
        [pscustomobject]@{ size = $Size; zones = @($Zones) }
    }
}
AfterAll {
    Remove-Item 'function:\CzNewRun', 'function:\CzGate', 'function:\CzGateLive', 'function:\CzLines', 'function:\CzRes' -ErrorAction SilentlyContinue
    Remove-VmfTestTemp
}

Describe 'CRG-MOVE-ZONE-1: the zone rule (pure)' {

    It 'the target size in the zone of the machine fits' {
        InModuleScope VmMigrationFactory -Parameters @{ r = @((Global:CzRes 'Standard_D2ds_v6' @('1'))) } {
            param($r)
            $fit = Get-VmfReservationZoneFit -Reservations $r -Size 'Standard_D2ds_v6' -Zone '1' -ZoneKnown $true
            $fit.Fits | Should -BeTrue
        }
    }

    It 'the target size only in another zone does not fit, and names the zones it is in' {
        InModuleScope VmMigrationFactory -Parameters @{ r = @((Global:CzRes 'Standard_D2ds_v6' @('3')), (Global:CzRes 'Standard_D2ds_v6' @('2'))) } {
            param($r)
            $fit = Get-VmfReservationZoneFit -Reservations $r -Size 'Standard_D2ds_v6' -Zone '1' -ZoneKnown $true
            $fit.Fits | Should -BeFalse
            $fit.Why | Should -Be 'otherZone'
            @($fit.Zones) | Should -Be @('2', '3')
        }
    }

    It 'size and zone must be on the SAME reservation: another size in the zone and the target size in another zone do not fit' {
        InModuleScope VmMigrationFactory -Parameters @{ r = @((Global:CzRes 'Standard_D2ds_v4' @('1')), (Global:CzRes 'Standard_D2ds_v6' @('2'))) } {
            param($r)
            (Get-VmfReservationZoneFit -Reservations $r -Size 'Standard_D2ds_v6' -Zone '1' -ZoneKnown $true).Fits | Should -BeFalse
        }
    }

    It 'no reservation for the size is noSize, whatever the zone' {
        InModuleScope VmMigrationFactory -Parameters @{ r = @((Global:CzRes 'Standard_D2ds_v4' @('1'))) } {
            param($r)
            $fit = Get-VmfReservationZoneFit -Reservations $r -Size 'Standard_D2ds_v6' -Zone '1' -ZoneKnown $true
            $fit.Fits | Should -BeFalse
            $fit.Why | Should -Be 'noSize'
            (Get-VmfReservationZoneFit -Reservations @() -Size 'Standard_D2ds_v6' -Zone '' -ZoneKnown $true).Why | Should -Be 'noSize'
        }
    }

    It 'a regional reservation (no zones) fits a regional machine and a zonal machine' {
        InModuleScope VmMigrationFactory -Parameters @{ r = @((Global:CzRes 'Standard_D2ds_v6' @())) } {
            param($r)
            (Get-VmfReservationZoneFit -Reservations $r -Size 'Standard_D2ds_v6' -Zone '' -ZoneKnown $true).Fits | Should -BeTrue
            (Get-VmfReservationZoneFit -Reservations $r -Size 'Standard_D2ds_v6' -Zone '2' -ZoneKnown $true).Fits | Should -BeTrue
        }
    }

    It 'a machine with no zone passes a zonal reservation of the size, as before' {
        InModuleScope VmMigrationFactory -Parameters @{ r = @((Global:CzRes 'Standard_D2ds_v6' @('2'))) } {
            param($r)
            (Get-VmfReservationZoneFit -Reservations $r -Size 'Standard_D2ds_v6' -Zone '' -ZoneKnown $true).Fits | Should -BeTrue
        }
    }

    It 'a machine zone that is not known is never a pass for a zonal reservation - but a regional one still fits' {
        InModuleScope VmMigrationFactory -Parameters @{ z = @((Global:CzRes 'Standard_D2ds_v6' @('1'))); g = @((Global:CzRes 'Standard_D2ds_v6' @())) } {
            param($z, $g)
            $fit = Get-VmfReservationZoneFit -Reservations $z -Size 'Standard_D2ds_v6' -Zone '' -ZoneKnown $false
            $fit.Fits | Should -BeFalse
            $fit.Why | Should -Be 'zoneUnknown'
            (Get-VmfReservationZoneFit -Reservations $g -Size 'Standard_D2ds_v6' -Zone '' -ZoneKnown $false).Fits | Should -BeTrue
        }
    }

    It 'a reservation whose zones were not read is never regional, and never a pass' {
        InModuleScope VmMigrationFactory {
            $r = @([pscustomobject]@{ size = 'Standard_D2ds_v6' })
            $fit = Get-VmfReservationZoneFit -Reservations $r -Size 'Standard_D2ds_v6' -Zone '1' -ZoneKnown $true
            $fit.Fits | Should -BeFalse
            $fit.Why | Should -Be 'zoneUnknown'
            (Get-VmfReservationZoneFit -Reservations $r -Size 'Standard_D2ds_v6' -Zone '' -ZoneKnown $true).Fits | Should -BeFalse
        }
    }

    It 'sizes are compared without letter case, and zones as text' {
        InModuleScope VmMigrationFactory {
            $r = @([pscustomobject]@{ size = 'standard_d2ds_v6'; zones = @(1) })
            (Get-VmfReservationZoneFit -Reservations $r -Size 'Standard_D2ds_v6' -Zone '1' -ZoneKnown $true).Fits | Should -BeTrue
        }
    }
}

Describe 'CRG-MOVE-ZONE-1: the check at Checking' {

    BeforeEach {
        $script:res = @()
        Mock -ModuleName VmMigrationFactory Get-VmfCapacityReservationSizes { @($script:res) }
        Mock -ModuleName VmMigrationFactory Set-VmfVmCapacityReservationGroup { throw 'the check changed the group' }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { throw 'the check resized the machine' }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { throw 'the check stopped the machine' }
    }

    It 'THE CHECK: a reservation for the target size only in another zone stops untouched, and names both zones' {
        $script:res = @((Global:CzRes $script:target @('2')))
        $r = Global:CzGate (Global:CzNewRun -Zone '1')
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'reservationGroupNoTargetSize'
        $r.MachineState | Should -Be 'untouched'
        $r.Detail | Should -Match "'contoso-crg'"
        $r.Detail | Should -Match 'in availability zone 1\b'
        $r.Detail | Should -Match "capacity reservation for $([regex]::Escape($script:target)) only in availability zone 2\b"
        $r.Detail | Should -Match 'stopped before it changed the machine'
        $r.Detail | Should -Match "Create a capacity reservation for $([regex]::Escape($script:target)) in availability zone 1 in the group"
        $r.Detail | Should -Match 'reserved quantity of 0'
        $r.Detail | Should -Match 'remove the machine from the group'
        $r.Detail | Should -Match 'try the machine again'
    }

    It 'a reservation for the target size in the zone of the machine passes, and the line names the zone' {
        $script:res = @((Global:CzRes $script:target @('2')), (Global:CzRes $script:target @('1')))
        $rp = Global:CzNewRun -Zone '1'
        Global:CzGate $rp | Should -BeNullOrEmpty
        $line = @(Global:CzLines $rp | Where-Object { $_.step -eq 'precheck' -and $_.detail -match 'contoso-crg' })
        $line.Count | Should -Be 1
        $line[0].detail | Should -Match 'keeps the machine in this group'
    }

    It 'a regional group passes a regional machine, as before' {
        $script:res = @((Global:CzRes $script:target @()))
        Global:CzGate (Global:CzNewRun -Zone 'none') | Should -BeNullOrEmpty
    }

    It 'a regional group passes a zonal machine' {
        $script:res = @((Global:CzRes $script:target @()))
        Global:CzGate (Global:CzNewRun -Zone '3') | Should -BeNullOrEmpty
    }

    It 'a machine with no zone passes a zonal reservation of the target size, as before' {
        $script:res = @((Global:CzRes $script:target @('2')))
        Global:CzGate (Global:CzNewRun -Zone 'none') | Should -BeNullOrEmpty
    }

    It 'a capture that does not give the zone of the machine is not a pass against a zonal reservation' {
        $script:res = @((Global:CzRes $script:target @('1')))
        $r = Global:CzGate (Global:CzNewRun -Zone 'unknown')
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'reservationGroupNoTargetSize'
        $r.MachineState | Should -Be 'untouched'
        $r.Detail | Should -Match 'cannot confirm'
        $r.Detail | Should -Match 'availability zone'
    }

    It 'a reservation whose zones the read did not give is not a pass' {
        $script:res = @([pscustomobject]@{ size = $script:target })
        $r = Global:CzGate (Global:CzNewRun -Zone '1')
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.MachineState | Should -Be 'untouched'
        $r.Detail | Should -Match 'cannot confirm'
    }

    It 'a failed read (the zones included) stops untouched - unknown is never a yes' {
        Mock -ModuleName VmMigrationFactory Get-VmfCapacityReservationSizes { throw "Azure did not give the zones of the capacity reservation 'r1'." }
        $r = Global:CzGate (Global:CzNewRun -Zone '1')
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'reservationGroupNotRead'
        $r.MachineState | Should -Be 'untouched'
        $r.Detail | Should -Match 'did not give the zones'
    }
}

Describe 'CRG-MOVE-ZONE-1: the capture as PRECHECK passes it (a hashtable)' {

    BeforeEach {
        $script:res = @()
        Mock -ModuleName VmMigrationFactory Get-VmfCapacityReservationSizes { @($script:res) }
    }

    It 'a zonal reservation in the zone of the machine passes' {
        $script:res = @((Global:CzRes $script:target @('1')))
        Global:CzGateLive (Global:CzNewRun) '1' | Should -BeNullOrEmpty
    }

    It 'a zonal reservation only in another zone stops untouched, and names both zones' {
        $script:res = @((Global:CzRes $script:target @('2')))
        $r = Global:CzGateLive (Global:CzNewRun) '1'
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.MachineState | Should -Be 'untouched'
        $r.Detail | Should -Match 'in availability zone 1\b'
        $r.Detail | Should -Match 'only in availability zone 2\b'
        $r.Detail | Should -Not -Match 'cannot read'
    }

    It 'a regional machine (no zone, either way Azure gives it) passes a zonal reservation, as before' {
        $script:res = @((Global:CzRes $script:target @('2')))
        Global:CzGateLive (Global:CzNewRun) 'none' | Should -BeNullOrEmpty
        Global:CzGateLive (Global:CzNewRun) 'nullzone' | Should -BeNullOrEmpty
    }

    It 'a regional reservation passes a zonal machine' {
        $script:res = @((Global:CzRes $script:target @()))
        Global:CzGateLive (Global:CzNewRun) '3' | Should -BeNullOrEmpty
    }

    It 'a capture with no zones key is unknown - never a pass against a zonal reservation' {
        $script:res = @((Global:CzRes $script:target @('1')))
        $r = Global:CzGateLive (Global:CzNewRun) 'unknown'
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Detail | Should -Match 'cannot confirm'
    }

    It 'the rule reads a reservation given as a hashtable as well' {
        InModuleScope VmMigrationFactory {
            $r = @(@{ size = 'Standard_D2ds_v6'; zones = @('1') })
            (Get-VmfReservationZoneFit -Reservations $r -Size 'Standard_D2ds_v6' -Zone '1' -ZoneKnown $true).Fits | Should -BeTrue
            (Get-VmfReservationZoneFit -Reservations $r -Size 'Standard_D2ds_v6' -Zone '2' -ZoneKnown $true).Why | Should -Be 'otherZone'
        }
    }
}
Describe 'CRG-MOVE-ZONE-1: the read gives each reservation''s zones, from the same call' {

    BeforeEach {
        Mock -ModuleName VmMigrationFactory Get-VmfAzContextForSubscription { $null }
    }

    It 'returns the size and the zones of each capacity reservation, one entry for each size and zones' {
        Mock -ModuleName VmMigrationFactory Get-AzCapacityReservation {
            @([pscustomobject]@{ Name = 'r1'; Sku = [pscustomobject]@{ Name = 'Standard_D2ds_v6'; Capacity = 1 }; Zones = [System.Collections.Generic.List[string]]@('2') }
                [pscustomobject]@{ Name = 'r2'; Sku = [pscustomobject]@{ Name = 'Standard_D2ds_v6'; Capacity = 1 }; Zones = [System.Collections.Generic.List[string]]@('2') }
                [pscustomobject]@{ Name = 'r3'; Sku = [pscustomobject]@{ Name = 'Standard_D4ds_v6'; Capacity = 1 }; Zones = $null }
                [pscustomobject]@{ Name = 'r4'; Sku = [pscustomobject]@{ Name = 'standard_d2ds_v6'; Capacity = 1 }; Zones = [System.Collections.Generic.List[string]]@('1') })
        }
        $res = InModuleScope VmMigrationFactory -Parameters @{ g = $script:theirs } { param($g) @(Get-VmfCapacityReservationSizes -GroupId $g) }
        $res.Count | Should -Be 3
        $d2 = @($res | Where-Object size -eq 'Standard_D2ds_v6' | Sort-Object { @($_.zones)[0] })
        $d2.Count | Should -Be 2
        @($d2[0].zones) | Should -Be @('1')
        @($d2[1].zones) | Should -Be @('2')
        $d4 = @($res | Where-Object size -eq 'Standard_D4ds_v6')
        $d4.Count | Should -Be 1
        @($d4[0].zones).Count | Should -Be 0
        Should -Invoke -ModuleName VmMigrationFactory Get-AzCapacityReservation -Times 1 -Exactly
    }

    It 'a reservation Azure gives with no zones field throws - it is never read as regional' {
        Mock -ModuleName VmMigrationFactory Get-AzCapacityReservation {
            @([pscustomobject]@{ Name = 'r1'; Sku = [pscustomobject]@{ Name = 'Standard_D2ds_v6'; Capacity = 1 } })
        }
        InModuleScope VmMigrationFactory -Parameters @{ g = $script:theirs } {
            param($g) { Get-VmfCapacityReservationSizes -GroupId $g } | Should -Throw '*zones*r1*'
        }
    }

    It 'the check makes no other Azure call: the zone comes from the same read, and the capture' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'ReservationMove.ps1')
        $code | Should -Not -Match '(?i)Get-VmfCapacityReservationGroup|Get-AzCapacityReservationGroup|Get-VmfVm\b'
        $code | Should -Match 'Get-VmfMachineZone -Machine \$Capture'
    }
}
