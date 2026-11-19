#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# CRG-MOVE-DEMAND-1, 2026-11-07. A wave reserves no place for a machine that
# stays in its own capacity reservation group.
#
# CRG-MOVE-1 keeps a machine in a capacity reservation group this migration did
# not make: the move does not put it in the wave's group. But Check the quota
# and Reserve capacity counted every machine of the cell except availability
# set members, so the wave reserved - and billed for - a place the machine
# never used.
#
# The rule now, ONE rule (Test-VmfEntryReservable, which asks CRG-MOVE-1's
# Get-VmfOwnReservationGroup): a machine the assessment found in a group this
# migration did not make is not reservable. The quota check leaves it out of
# the reserved count and names it on the record (capacity-claim v15,
# demand.ownGroupVmIds); the Reserved gate judges it on its quota check, as an
# availability set member; and CONVERTING takes the wave's reservation only for
# a machine that rule counted. So the reserved count is never LOWER than the
# machines that join the wave's group (a machine the assessment found in its
# own group, and which is in none at the move, moves with no reservation and
# says so), and, when nothing changed between the assessment and the move,
# never HIGHER either.
#
# The fact comes from the scan: assessment v13 records
# capacityReservationGroupId, and the plan entry carries it (plan-entry v30).
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'crgdemand'

    $script:subId = '00000000-0000-0000-0000-000000000000'
    $script:sub = "/subscriptions/$script:subId"
    $script:rgVm = "$script:sub/resourceGroups/rg-lab/providers/Microsoft.Compute/virtualMachines"
    # A group of this migration, made for an earlier wave - so it is a product
    # group when the quota of wave w1 is checked.
    $script:ours = "$script:sub/resourceGroups/rg-lab/providers/Microsoft.Compute/capacityReservationGroups/vmf-crg-w0"
    # The group made for wave w1 by Reserve capacity.
    $script:oursW1 = "$script:sub/resourceGroups/rg-lab/providers/Microsoft.Compute/capacityReservationGroups/vmf-crg-w1"
    # The customer's own group.
    $script:theirs = "$script:sub/resourceGroups/rg-capacity/providers/Microsoft.Compute/capacityReservationGroups/contoso-crg"
    $script:target = 'Standard_D2ds_v6'
    $script:source = 'Standard_D2ds_v4'

    # The group a record says: 'absent' (no field - unknown), 'none' (in no
    # group), 'own' (the customer's), 'ours' (this migration's).
    function Global:CdGroupValue([string]$Kind) {
        switch ($Kind) { 'none' { $null } 'own' { $script:theirs } 'ours' { $script:ours } default { throw "kind $Kind" } }
    }

    # A plan entry of wave w1, in the shape New-VmfPlan writes.
    function Global:CdEntry {
        param([string]$Name, [string]$Group = 'absent', [switch]$Avset, [string]$Wave = 'w1')
        $a = [ordered]@{ location = 'centralus'; os = 'Linux'; gen = 'V2'; sourceSize = $script:source; classification = 'ReadyAfterPrep'
            sourceDiskArch = 'scsi-temp'; availabilitySetId = $(if ($Avset) { "$script:sub/resourceGroups/rg-lab/providers/Microsoft.Compute/availabilitySets/pair" } else { '' }) }
        if ($Group -ne 'absent') { $a.capacityReservationGroupId = (Global:CdGroupValue $Group) }
        [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$script:rgVm/$Name"; path = 'A'; wave = $Wave; ring = 'prod'
            assessment = [pscustomobject]$a
            target = [pscustomobject]@{ size = $script:target; controller = 'NVMe'; zone = $null }
            policy = [pscustomobject]@{ acceleratedNetworking = 'preserve'; capacityGate = 'Reserved' } }
    }

    # A run whose store already holds a reservation of this migration, for
    # wave w0 (so $script:ours is a product group), and the plan.
    function Global:CdNewRun([object[]]$Entries) {
        $rp = Join-Path $script:temp "run-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; ours = $script:ours; sub = $script:subId; e = @($Entries) } {
            param($rp, $ours, $sub, $e)
            Initialize-VmfRun -RunPath $rp -RunId 'crgdemand' | Out-Null
            Write-VmfStoreJson -RunPath $rp -RelPath 'capacity/w0-old.json' -Document ([pscustomobject]@{
                    schemaVersion = 14; runId = 'crgdemand'; wave = 'w0'; subscriptionId = $sub; resourceGroup = 'rg-lab'
                    region = 'centralus'; zone = $null; size = 'Standard_D4ds_v6'; state = 'RESERVED'
                    demand = [pscustomobject]@{ instances = 1; reservableInstances = 1; vcpus = 4 }
                    reservation = [pscustomobject]@{ groupId = $ours; reservationId = "$ours/capacityReservations/d4"; consumedInstances = 0 }
                    associatedVmIds = @() })
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document ([pscustomobject]@{
                    schemaVersion = 30; assessmentRunId = 'crgdemand'; entries = @($e) }) -Depth 20
        }
        $rp
    }

    function Global:CdSku([string]$Name, [int]$Vcpus) {
        [pscustomobject]@{ Name = $Name; ResourceType = 'virtualMachines'; Family = 'standardDDSv6Family'; Restrictions = @()
            Capabilities = @([pscustomobject]@{ Name = 'vCPUs'; Value = "$Vcpus" },
                             [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = '0' }) }
    }
    function Global:CdMockQuota {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
            @((Global:CdSku 'Standard_D2ds_v6' 2), (Global:CdSku 'Standard_D2ds_v4' 2), (Global:CdSku 'Standard_D4ds_v6' 4))
        }
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @([pscustomobject]@{ Name = [pscustomobject]@{ Value = 'standardDDSv6Family' }; CurrentValue = 0; Limit = 500 },
              [pscustomobject]@{ Name = [pscustomobject]@{ Value = 'cores' }; CurrentValue = 0; Limit = 1000 })
        }
        Mock -ModuleName VmMigrationFactory Get-VmfRetailPrice { 0.1 }
    }
    function Global:CdQuota([string]$Rp) {
        Test-VmfQuota -PlanPath (Join-Path $Rp 'plan.json') -OutPath $Rp -Wave 'w1' | Out-Null
        $file = @(Get-ChildItem (Join-Path $Rp 'capacity') -Filter 'w1-*.json')
        $file.Count | Should -Be 1 -Because 'one cell: wave, subscription, region, zone and size are the same for every machine'
        Get-Content $file[0].FullName -Raw | ConvertFrom-Json
    }

    # What Reserve capacity leaves: the record of wave w1 RESERVED in the group
    # made for it.
    function Global:CdReserve([string]$Rp) {
        $file = @(Get-ChildItem (Join-Path $Rp 'capacity') -Filter 'w1-*.json')[0]
        $c = Get-Content $file.FullName -Raw | ConvertFrom-Json
        $c.state = 'RESERVED'
        $c | Add-Member -NotePropertyName reservation -Force -NotePropertyValue ([pscustomobject]@{
                groupId = $script:oursW1; reservationId = "$script:oursW1/capacityReservations/d2"; consumedInstances = 0 })
        $c | Add-Member -NotePropertyName associatedVmIds -NotePropertyValue @() -Force
        $c | ConvertTo-Json -Depth 12 | Set-Content $file.FullName -Encoding utf8NoBOM
        $file.FullName
    }

    # One machine's CONVERTING step, with the group this attempt's capture
    # recorded, against a fake of Azure's group rules (CrgMove's).
    function Global:CdConvert([string]$Rp, $Entry, [string]$Captured) {
        $capGroup = if ($Captured -eq 'absent') { 'absent' } else { Global:CdGroupValue $Captured }
        $global:cd = @{ size = $script:source; group = $(if ($capGroup -eq 'absent') { $null } else { $capGroup })
            holds = @{ $script:ours = @($script:target); $script:oursW1 = @($script:target); $script:theirs = @($script:target) }
            joins = [System.Collections.Generic.List[string]]::new() }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $Rp; p = $Entry; g = $capGroup; sub = $script:subId; src = $script:source } {
            param($rp, $p, $g, $sub, $src)
            $name = ($p.vmId -split '/')[-1]
            New-VmfStateDoc -RunPath $rp -RunId 'crgdemand' -VmId $p.vmId -Wave 'w1' | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $p.vmId
            $vmConfig = [ordered]@{ size = $src; controller = 'SCSI'; location = 'centralus'; name = $name; osType = 'Linux'
                osDisk = [ordered]@{ name = "$name-osdisk"; skuName = 'Premium_LRS'; managedDiskId = "/subscriptions/$sub/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/$name-osdisk" }
                dataDisks = @(); nics = @() }
            if ($g -ne 'absent') { $vmConfig.capacityReservationGroupId = $g }
            $doc | Add-Member -NotePropertyName captured -NotePropertyValue ([pscustomobject]@{ vmConfig = [pscustomobject]$vmConfig }) -Force
            Write-VmfStateDoc -RunPath $rp -Document $doc
            $ctx = New-VmfContext -PlanEntry $p -RunPath $rp -RunId 'crgdemand'
            Set-VmfTestAnDecision -RunPath $rp -VmId ([string]$p.vmId) -PlanEntry $p
            Invoke-VmfStepConverting -Context $ctx
        }
    }
    function Global:CdMockAzure {
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { $true }
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController {
            $g = $global:cd.group
            if ($g -and $Size -notin @($global:cd.holds[$g])) { throw "Capacity Reservation with VM size $Size does not exist in the group." }
            $global:cd.size = $Size
        }
        Mock -ModuleName VmMigrationFactory Set-VmfVmCapacityReservationGroup {
            if ($GroupId) {
                if ($global:cd.size -notin @($global:cd.holds[$GroupId])) { throw "Capacity Reservation with VM size $($global:cd.size) does not exist in the group." }
                $global:cd.group = $GroupId; $global:cd.joins.Add($GroupId)
            }
            else { $global:cd.group = $null }
        }
    }
    function Global:CdLines([string]$Rp, [string]$VmId) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $Rp } { param($rp) @(Read-VmfEvents -RunPath $rp) } |
            Where-Object { $_.step -eq 'odcr' -and $_.vmId -eq $VmId }
    }
}
AfterAll {
    Remove-Item 'function:\CdGroupValue', 'function:\CdEntry', 'function:\CdNewRun', 'function:\CdSku', 'function:\CdMockQuota',
        'function:\CdQuota', 'function:\CdReserve', 'function:\CdConvert', 'function:\CdMockAzure', 'function:\CdLines' -ErrorAction SilentlyContinue
    Remove-Variable cd -Scope Global -ErrorAction SilentlyContinue
    Remove-VmfTestTemp
}

Describe 'CRG-MOVE-DEMAND-1: one rule says which machine a reservation holds' {

    It 'a machine the assessment found in a group this migration did not make: not reservable' {
        InModuleScope VmMigrationFactory -Parameters @{ e = (Global:CdEntry 'a' 'own') } {
            param($e) Test-VmfEntryReservable -Entry $e -ProductGroupIds @() | Should -BeFalse
        }
    }

    It 'a machine in no group, or a record that does not say (unknown, never a no): reservable' {
        foreach ($k in 'none', 'absent') {
            InModuleScope VmMigrationFactory -Parameters @{ e = (Global:CdEntry 'a' $k) } {
                param($e) Test-VmfEntryReservable -Entry $e -ProductGroupIds @() | Should -BeTrue
            }
        }
    }

    It 'a group of this migration is not the machine''s own, whatever the letter case: reservable' {
        InModuleScope VmMigrationFactory -Parameters @{ e = (Global:CdEntry 'a' 'ours'); ours = $script:ours } {
            param($e, $ours)
            Test-VmfEntryReservable -Entry $e -ProductGroupIds @($ours.ToUpperInvariant()) | Should -BeTrue
        }
    }

    It 'an availability set member is still not reservable, with or without a group' {
        foreach ($k in 'none', 'absent', 'own') {
            InModuleScope VmMigrationFactory -Parameters @{ e = (Global:CdEntry 'a' $k -Avset) } {
                param($e) Test-VmfEntryReservable -Entry $e -ProductGroupIds @() | Should -BeFalse
            }
        }
    }

    It 'it asks CRG-MOVE-1''s rule, the one the move asks - no second rule for "its own group"' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'capacity' 'ReservedCover.ps1')
        $code | Should -Match 'Get-VmfOwnReservationGroup -Capture \$Entry\.assessment -ProductGroupIds'
        $code | Should -Not -Match 'capacityReservationGroupId' -Because 'the field is read only by Get-VmfCapturedReservationGroup'
    }

    It 'every caller in the module says which groups are this migration''s' {
        $hits = foreach ($f in Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory') -Recurse -Filter '*.ps1') {
            $code = Get-VmfCodeOnly -Path $f.FullName
            foreach ($m in [regex]::Matches($code, '(?<!function )(Test-VmfEntryReservable|Get-VmfReservableEntryCount|Get-VmfReservedCoverageGaps)\s[^\r\n]*')) {
                if ($m.Value -notmatch '-ProductGroupIds') { "$($f.Name): $($m.Value)" }
            }
        }
        @($hits) | Should -BeNullOrEmpty
    }
}

Describe 'CRG-MOVE-DEMAND-1: Check the quota reserves no place for a machine in its own group' {

    BeforeEach { Global:CdMockQuota }

    It 'a wave with one such machine reserves one place fewer, and the record names the machine' {
        $rp = Global:CdNewRun @((Global:CdEntry 'vm-own' 'own'), (Global:CdEntry 'vm-none' 'none'), (Global:CdEntry 'vm-old'))
        $c = Global:CdQuota $rp
        $c.demand.instances | Should -Be 3 -Because 'every machine still draws on the quota'
        $c.demand.reservableInstances | Should -Be 2
        @($c.demand.ownGroupVmIds) | Should -Be @("$script:rgVm/vm-own")
        $c.estimatedHourly.total | Should -Be 0.2 -Because 'the price is for the places reserved, so the machine in its own group adds nothing'
        @($c.notes) -join ' ' | Should -Match 'vm-own'
        @($c.notes) -join ' ' | Should -Match 'own capacity reservation group'
    }

    # MANUAL-REVIEW-1: the two notes in Azure's names - no ODCR, no AvSet,
    # no VMs, and no reservation alone.
    It 'the notes say the availability set and the own group in Azure''s names' {
        $rp = Global:CdNewRun @((Global:CdEntry 'vm-own' 'own'), (Global:CdEntry 'vm-av' 'none' -Avset), (Global:CdEntry 'vm-none' 'none'))
        $c = Global:CdQuota $rp
        @($c.notes) | Should -Contain '1 of 3 machines is in an availability set. Azure does not allow an on-demand capacity reservation for it, so it moves without one.'
        @($c.notes) | Should -Contain '1 of 3 machines stays in its own capacity reservation group (vm-own). The move keeps it in its group. The on-demand capacity reservation of the wave holds no place for it.'
        (@($c.notes) -join ' ') | Should -Not -MatchExactly 'ODCR|AvSet|VMs|instance\(s\)|machine\(s\)'
    }

    It 'the notes for two machines use the plural forms' {
        $rp = Global:CdNewRun @((Global:CdEntry 'vm-own1' 'own'), (Global:CdEntry 'vm-own2' 'own'),
            (Global:CdEntry 'vm-av1' 'none' -Avset), (Global:CdEntry 'vm-av2' 'none' -Avset), (Global:CdEntry 'vm-none' 'none'))
        $c = Global:CdQuota $rp
        @($c.notes) | Should -Contain '2 of 5 machines are in an availability set. Azure does not allow an on-demand capacity reservation for them, so they move without one.'
        @($c.notes) | Should -Contain '2 of 5 machines stay in their own capacity reservation group (vm-own1, vm-own2). The move keeps each one in its group. The on-demand capacity reservation of the wave holds no place for them.'
    }

    It 'a machine in no group is counted as before' {
        $rp = Global:CdNewRun @((Global:CdEntry 'vm-1' 'none'), (Global:CdEntry 'vm-2' 'none'))
        $c = Global:CdQuota $rp
        $c.demand.reservableInstances | Should -Be 2
        @($c.demand.ownGroupVmIds).Count | Should -Be 0
    }

    It 'a plan from before the field (unknown) is counted - unknown is never a no' {
        $rp = Global:CdNewRun @((Global:CdEntry 'vm-1'), (Global:CdEntry 'vm-2'))
        (Global:CdQuota $rp).demand.reservableInstances | Should -Be 2
    }

    It 'a machine in a group of this migration is counted' {
        $rp = Global:CdNewRun @((Global:CdEntry 'vm-1' 'ours'), (Global:CdEntry 'vm-2' 'none'))
        $c = Global:CdQuota $rp
        $c.demand.reservableInstances | Should -Be 2
        @($c.demand.ownGroupVmIds).Count | Should -Be 0
    }

    It 'an availability set member in its own group is counted once, as an availability set member' {
        $rp = Global:CdNewRun @((Global:CdEntry 'vm-1' 'own' -Avset), (Global:CdEntry 'vm-2' 'own'), (Global:CdEntry 'vm-3' 'none'))
        $c = Global:CdQuota $rp
        $c.demand.reservableInstances | Should -Be 1
        @($c.demand.ownGroupVmIds) | Should -Be @("$script:rgVm/vm-2")
    }

    It 'the record matches its schema, at version 15' {
        $rp = Global:CdNewRun @((Global:CdEntry 'vm-own' 'own'), (Global:CdEntry 'vm-none' 'none'))
        $c = Global:CdQuota $rp
        $c.schemaVersion | Should -Be 15
        ($c | ConvertTo-Json -Depth 20) | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'capacity-claim.schema.json') | Should -BeTrue
    }

    It 'a wave set to Reserved: the machine in its own group gives back its old vCPUs to the regional quota, as an availability set member does' {
        $rp = Global:CdNewRun @((Global:CdEntry 'vm-own' 'own'), (Global:CdEntry 'vm-none' 'none'))
        (Global:CdQuota $rp).demand.regionalAdds | Should -Be 2 -Because 'vm-none asks for its whole new size (2) while it is reserved; vm-own adds 2 - 2 = 0'
    }
}

Describe 'CRG-MOVE-DEMAND-1: the reserved count is never lower than the machines that join the wave''s group' {

    BeforeEach { Global:CdMockQuota; Global:CdMockAzure }

    It 'THE MONEY RULE, both ways, over every kind of machine: what the assessment found, and what the move finds' {
        # Each machine: the group the assessment found, the group this
        # attempt's capture found, and an availability set or not.
        $kinds = @('absent', 'none', 'own', 'ours')
        $cases = foreach ($planned in $kinds) { foreach ($found in $kinds) { foreach ($avset in $false, $true) {
                    [pscustomobject]@{ Name = "vm-$planned-$found-$([int]$avset)"; Planned = $planned; Found = $found; Avset = $avset } } } }
        $entries = @($cases | ForEach-Object { Global:CdEntry $_.Name $_.Planned -Avset:$_.Avset })
        $rp = Global:CdNewRun $entries
        $c = Global:CdQuota $rp
        Global:CdReserve $rp | Out-Null
        $joined = 0
        $joinedAgreeing = 0
        foreach ($case in $cases) {
            $entry = $entries | Where-Object { $_.vmId -like "*/$($case.Name)" }
            (Global:CdConvert $rp $entry $case.Found).Next | Should -Be 'STARTING' -Because $case.Name
            $intoWave = @($global:cd.joins | Where-Object { $_ -eq $script:oursW1 }).Count
            $joined += $intoWave
            if ($case.Planned -eq $case.Found -or ($case.Planned -eq 'absent')) { $joinedAgreeing += $intoWave }
            # A machine the move keeps in its own group never joins the wave's.
            if ($case.Found -eq 'own') { $intoWave | Should -Be 0 -Because $case.Name }
        }
        $joined | Should -BeLessOrEqual ([int]$c.demand.reservableInstances) -Because 'a machine that joins with no place reserved for it has no capacity guarantee'
        (Get-Content (@(Get-ChildItem (Join-Path $rp 'capacity') -Filter 'w1-*.json')[0].FullName) -Raw | ConvertFrom-Json).reservation.consumedInstances |
            Should -BeLessOrEqual ([int]$c.demand.reservableInstances)
    }

    It 'when nothing changed between the assessment and the move, every place reserved is used - none bills for nothing' {
        $kinds = @('none', 'own', 'ours')
        $cases = foreach ($k in $kinds) { foreach ($avset in $false, $true) { [pscustomobject]@{ Name = "vm-$k-$([int]$avset)"; Kind = $k; Avset = $avset } } }
        $entries = @($cases | ForEach-Object { Global:CdEntry $_.Name $_.Kind -Avset:$_.Avset })
        $rp = Global:CdNewRun $entries
        $c = Global:CdQuota $rp
        Global:CdReserve $rp | Out-Null
        $joined = 0
        foreach ($case in $cases) {
            $entry = $entries | Where-Object { $_.vmId -like "*/$($case.Name)" }
            Global:CdConvert $rp $entry $case.Kind | Out-Null
            $joined += @($global:cd.joins | Where-Object { $_ -eq $script:oursW1 }).Count
        }
        [int]$c.demand.reservableInstances | Should -Be 2 -Because 'none and ours, outside an availability set'
        $joined | Should -Be ([int]$c.demand.reservableInstances)
    }

    It 'a machine the assessment found in its own group, and which is in none at the move, moves with no reservation and says why' {
        $e = Global:CdEntry 'vm-left' 'own'
        $rp = Global:CdNewRun @($e, (Global:CdEntry 'vm-x' 'none'))
        Global:CdQuota $rp | Out-Null
        Global:CdReserve $rp | Out-Null
        (Global:CdConvert $rp $e 'none').Next | Should -Be 'STARTING'
        @($global:cd.joins).Count | Should -Be 0
        $global:cd.size | Should -Be $script:target
        $line = @(Global:CdLines $rp $e.vmId)
        $line.Count | Should -Be 1
        $line[0].outcome | Should -Be 'warn'
        $line[0].detail | Should -Match "assessment found the machine in the capacity reservation group 'contoso-crg'"
        $line[0].detail | Should -Match 'moves with no capacity reservation'
    }

    It 'a machine the assessment found in its own group, and which is still in it: stays, with CRG-MOVE-1''s line' {
        $e = Global:CdEntry 'vm-own' 'own'
        $rp = Global:CdNewRun @($e, (Global:CdEntry 'vm-x' 'none'))
        Global:CdQuota $rp | Out-Null
        Global:CdReserve $rp | Out-Null
        Global:CdConvert $rp $e 'own' | Out-Null
        $global:cd.group | Should -Be $script:theirs
        $line = @(Global:CdLines $rp $e.vmId)
        $line[0].detail | Should -Match "stays in its capacity reservation group 'contoso-crg'"
        $line[0].detail | Should -Match 'capacity reservation of the wave is not used'
    }

    It 'a machine the assessment found in no group still takes the wave''s reservation' {
        $e = Global:CdEntry 'vm-none' 'none'
        $rp = Global:CdNewRun @($e)
        Global:CdQuota $rp | Out-Null
        Global:CdReserve $rp | Out-Null
        Global:CdConvert $rp $e 'none' | Out-Null
        @($global:cd.joins) | Should -Be @($script:oursW1)
    }
}

Describe 'CRG-MOVE-DEMAND-1 review: a machine that left its own group after the scan, on a wave set to Reserved, stops untouched at Checking' {

    BeforeEach { Global:CdMockQuota; Global:CdMockAzure }

    # PRECHECK's check, with this attempt's capture and the plan entry.
    BeforeAll {
    function Global:CdGate($Rp, $Entry, [string]$Captured) {
        $capGroup = if ($Captured -eq 'absent') { 'absent' } else { Global:CdGroupValue $Captured }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $Rp; p = $Entry; g = $capGroup } {
            param($rp, $p, $g)
            $cap = [ordered]@{ size = 'Standard_D2ds_v4'; location = 'centralus'; zones = @() }
            if ($g -ne 'absent') { $cap.capacityReservationGroupId = $g }
            $ctx = New-VmfContext -PlanEntry $p -RunPath $rp -RunId 'crgdemand'
            Test-VmfMoveReservationGroup -Context $ctx -Capture ([pscustomobject]$cap) -TargetSize ([string]$p.target.size)
        }
    }
    }
    AfterAll { Remove-Item 'function:\CdGate' -ErrorAction SilentlyContinue }


    It 'THE CASE: Reserved wave, the assessment found it in its own group, it is in no group now - stops untouched, names the machine and what to do' {
        $e = Global:CdEntry 'vm-left' 'own'
        $rp = Global:CdNewRun @($e)
        $r = Global:CdGate $rp $e 'none'
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'reservationGroupLeftAfterScan'
        $r.MachineState | Should -Be 'untouched'
        $r.Detail | Should -Match 'vm-left'
        $r.Detail | Should -Match "capacity reservation group 'contoso-crg'"
        $r.Detail | Should -Match 'after the assessment'
        $r.Detail | Should -Match 'stopped before it changed the machine'
        $r.Detail | Should -Match 'Add the machine to the group ''contoso-crg'' again'
        $r.Detail | Should -Match 'plan again'
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmSizeAndController -Times 0 -Exactly
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmCapacityReservationGroup -Times 0 -Exactly
    }

    It 'the same when it is now in a group of this migration - the wave holds no place for it either way' {
        $e = Global:CdEntry 'vm-left' 'own'
        $rp = Global:CdNewRun @($e)
        (Global:CdGate $rp $e 'ours').Reason | Should -Be 'reservationGroupLeftAfterScan'
    }

    It 'asked again (a kill and a resume of Checking), it gives the same stop and changes nothing' {
        $e = Global:CdEntry 'vm-left' 'own'
        $rp = Global:CdNewRun @($e)
        $first = Global:CdGate $rp $e 'none'
        $second = Global:CdGate $rp $e 'none'
        $second.Reason | Should -Be $first.Reason
        $second.Detail | Should -Be $first.Detail
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmSizeAndController -Times 0 -Exactly
    }

    It 'a wave NOT set to Reserved: no stop - moving with no reservation is what its setting means' {
        $e = Global:CdEntry 'vm-left' 'own'
        $e.policy.capacityGate = 'BestEffort'
        $rp = Global:CdNewRun @($e)
        Global:CdGate $rp $e 'none' | Should -BeNullOrEmpty
        # An entry that says no setting reads as None, as the planner and the editor read it.
        $quiet = Global:CdEntry 'vm-quiet' 'own'
        $quiet.policy = [pscustomobject]@{ acceleratedNetworking = 'preserve' }
        Global:CdGate $rp $quiet 'none' | Should -BeNullOrEmpty
        # And CONVERTING moves it with no reservation, with the warning line.
        (Global:CdConvert $rp $e 'none').Next | Should -Be 'STARTING'
        @($global:cd.joins).Count | Should -Be 0
        @(Global:CdLines $rp $e.vmId)[0].outcome | Should -Be 'warn'
    }

    It 'no stop when nothing changed, when the assessment did not say, or for an availability set member' {
        $own = Global:CdEntry 'vm-own' 'own'
        $none = Global:CdEntry 'vm-none' 'none'
        $old = Global:CdEntry 'vm-old'
        $avset = Global:CdEntry 'vm-av' 'own' -Avset
        $ours = Global:CdEntry 'vm-ours' 'ours'
        $rp = Global:CdNewRun @($own, $none, $old, $avset, $ours)
        Global:CdGate $rp $none 'none' | Should -BeNullOrEmpty
        Global:CdGate $rp $ours 'none' | Should -BeNullOrEmpty -Because 'a group of this migration was never its own: the wave counted it'
        Global:CdGate $rp $old 'none' | Should -BeNullOrEmpty
        Global:CdGate $rp $avset 'none' | Should -BeNullOrEmpty
        # Still in its own group: CRG-MOVE-1's check of the group, which passes here.
        Mock -ModuleName VmMigrationFactory Get-VmfCapacityReservationSizes { @([pscustomobject]@{ size = 'Standard_D2ds_v6'; zones = @() }) }
        Global:CdGate $rp $own 'own' | Should -BeNullOrEmpty
    }

    It 'the stop reason is declared, leaves the machine untouched, and is retried after a fix' {
        $r = @((Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json).reasons |
            Where-Object code -EQ 'reservationGroupLeftAfterScan')
        $r.Count | Should -Be 1
        $r[0].machine | Should -Be 'untouched'
        $r[0].retry | Should -Be 'afterFix'
    }
}
Describe 'CRG-MOVE-DEMAND-1: the Reserved gate judges such a machine on its quota check' {

    It 'a wave whose one machine stays in its own group needs no reservation, only its quota check' {
        $e = Global:CdEntry 'vm-own' 'own'
        $claim = [pscustomobject]@{ wave = 'w1'; subscriptionId = $script:subId; region = 'centralus'; zone = $null; size = $script:target
            state = 'QUOTA_VERIFIED'; demand = [pscustomobject]@{ instances = 1; reservableInstances = 0; vcpus = 2; ownGroupVmIds = @($e.vmId) } }
        InModuleScope VmMigrationFactory -Parameters @{ e = $e; c = $claim } {
            param($e, $c)
            @(Get-VmfReservedCoverageGaps -Claims @($c) -Entries @($e) -ProductGroupIds @()).Count | Should -Be 0
            Get-VmfReservableEntryCount -Entries @($e) -ProductGroupIds @() | Should -Be 0
        }
    }

    It 'but a machine in a group of this migration still needs the reservation' {
        $e = Global:CdEntry 'vm-1' 'ours'
        $claim = [pscustomobject]@{ wave = 'w1'; subscriptionId = $script:subId; region = 'centralus'; zone = $null; size = $script:target
            state = 'QUOTA_VERIFIED'; demand = [pscustomobject]@{ instances = 1; reservableInstances = 1; vcpus = 2 } }
        InModuleScope VmMigrationFactory -Parameters @{ e = $e; c = $claim; ours = $script:ours } {
            param($e, $c, $ours)
            @(Get-VmfReservedCoverageGaps -Claims @($c) -Entries @($e) -ProductGroupIds @($ours))[0].Kind | Should -Be 'notReserved'
            Get-VmfReservableEntryCount -Entries @($e) -ProductGroupIds @($ours) | Should -Be 1
        }
    }

    It 'the start and Reserve capacity pass this run''s groups to the gate' {
        foreach ($f in 'Start-VmfWave.ps1', 'New-VmfWaveReservation.ps1', 'Test-VmfQuotaAndReservation.ps1', 'Test-VmfQuota.ps1') {
            $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' $f)
            $code | Should -Match 'Get-VmfProductReservationGroupIds -RunPath' -Because $f
        }
    }
}

Describe 'CRG-MOVE-DEMAND-1: the words say both causes' {

    It 'the start''s line names the machines in their own group, and does not call them availability set members' {
        $claim = [pscustomobject]@{ wave = 'w1'; size = $script:target; region = 'centralus'; state = 'RESERVED'
            demand = [pscustomobject]@{ instances = 3; reservableInstances = 1; vcpus = 6; ownGroupVmIds = @("$script:rgVm/vm-a", "$script:rgVm/vm-b") } }
        $said = InModuleScope VmMigrationFactory -Parameters @{ c = $claim } { param($c) Get-VmfReservedGeneralNote -Claims @($c) -Wave 'w1' -ReservableMachines 1 }
        $said | Should -Match 'vm-a, vm-b'
        $said | Should -Match 'own capacity reservation group'
        $said | Should -Not -Match 'availability set'
    }

    It 'both causes in one wave: each is said with its own count' {
        $claim = [pscustomobject]@{ wave = 'w1'; size = $script:target; region = 'centralus'; state = 'RESERVED'
            demand = [pscustomobject]@{ instances = 4; reservableInstances = 1; vcpus = 8; ownGroupVmIds = @("$script:rgVm/vm-a") } }
        $said = InModuleScope VmMigrationFactory -Parameters @{ c = $claim } { param($c) Get-VmfReservedGeneralNote -Claims @($c) -Wave 'w1' -ReservableMachines 1 }
        $said | Should -Match '2 machine\(s\) in an availability set'
        $said | Should -Match 'vm-a'
    }

    It 'a record before version 15 says nothing of own groups: every machine left out is an availability set member, as before' {
        $claim = [pscustomobject]@{ wave = 'w1'; size = $script:target; region = 'centralus'; state = 'RESERVED'
            demand = [pscustomobject]@{ instances = 3; reservableInstances = 1; vcpus = 6 } }
        $said = InModuleScope VmMigrationFactory -Parameters @{ c = $claim } { param($c) Get-VmfReservedGeneralNote -Claims @($c) -Wave 'w1' -ReservableMachines 1 }
        $said | Should -Match '2 machine\(s\) in an availability set'
        $said | Should -Not -Match 'own capacity reservation group'
    }

    It 'the general count of a record leaves out its machines in their own group' {
        $claim = [pscustomobject]@{ demand = [pscustomobject]@{ instances = 4; reservableInstances = 1; ownGroupVmIds = @('/x/a') } }
        InModuleScope VmMigrationFactory -Parameters @{ c = $claim } {
            param($c)
            Get-VmfClaimGeneralInstances -Claim $c | Should -Be 2
            @(Get-VmfClaimOwnGroupVmIds -Claim $c) | Should -Be @('/x/a')
        }
    }
}

Describe 'CRG-MOVE-DEMAND-1: Reserve capacity, the gate''s detail and the report say both causes' {

    BeforeEach {
        $script:rp = Join-Path $script:temp "words-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Initialize-VmfRun -RunPath $rp -RunId 'crgdemand' | Out-Null }
        Mock -ModuleName VmMigrationFactory New-VmfCapacityReservation { @{ GroupId = '/g'; ReservationId = '/g/r' } }
        $script:writeClaim = {
            param([string]$State = 'QUOTA_VERIFIED', [int]$Instances = 2, [int]$Reservable = 0, [string[]]$Own = @(), [switch]$Held)
            $c = [ordered]@{ schemaVersion = 15; runId = 'crgdemand'; wave = 'w1'; subscriptionId = $script:subId; resourceGroup = 'rg-lab'
                region = 'centralus'; zone = $null; size = $script:target; vmFamily = 'standardDDSv6Family'; state = $State; blockReason = $null
                demand = [ordered]@{ instances = $Instances; reservableInstances = $Reservable; ownGroupVmIds = @($Own); vcpus = 2 * $Instances }
                quota = [ordered]@{ limit = 100; used = 0 }; notes = @() }
            if ($Held) { $c.reservation = [ordered]@{ groupId = $script:oursW1; reservationId = "$script:oursW1/capacityReservations/d2"; createdUtc = '2026-11-07T00:00:00Z'; releasedUtc = $null; consumedInstances = 1 } }
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; c = [pscustomobject]$c } { param($rp, $c) Write-VmfStoreJson -RunPath $rp -RelPath 'capacity/w1-d2.json' -Document $c -Depth 12 }
        }
    }

    It 'Reserve capacity on a cell of machines in their own group: makes nothing, and says where the machines go' {
        & $script:writeClaim -Own @("$script:rgVm/vm-a", "$script:rgVm/vm-b")
        $r = New-VmfWaveReservation -OutPath $script:rp -Wave 'w1'
        $r.NothingReservable | Should -BeTrue
        Should -Invoke -ModuleName VmMigrationFactory New-VmfCapacityReservation -Times 0 -Exactly
        $lines = @(InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) @(Read-VmfEvents -RunPath $rp) } | Where-Object step -EQ 'odcr')
        $cell = @($lines | Where-Object outcome -EQ 'warn')[0].detail
        $cell | Should -Match 'vm-a, vm-b stay in their own capacity reservation group'
        $cell | Should -Not -Match 'availability set'
        $nothing = @($lines | Where-Object code -EQ 'nothingReservable')[0].detail
        $nothing | Should -Match 'own capacity reservation group'
        (Get-Content (Join-Path $script:rp 'capacity' 'w1-d2.json') -Raw | ConvertFrom-Json).notes -join ' ' | Should -Match 'own capacity reservation group'
    }

    It 'a cell of one machine in its own group and one in an availability set says both' {
        & $script:writeClaim -Own @("$script:rgVm/vm-a")
        New-VmfWaveReservation -OutPath $script:rp -Wave 'w1' | Out-Null
        $cell = @(InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) @(Read-VmfEvents -RunPath $rp) } |
            Where-Object { $_.step -eq 'odcr' -and $_.outcome -eq 'warn' })[0].detail
        $cell | Should -Match 'vm-a stay'
        $cell | Should -Match 'The other machines are in an availability set'
    }

    It 'the gate''s detail names both causes' {
        & $script:writeClaim -Own @("$script:rgVm/vm-a", "$script:rgVm/vm-b")
        $r = Test-VmfQuotaAndReservation -OutPath $script:rp -Wave 'w1' -Gate 'Reserved' -Entries @((Global:CdEntry 'vm-a' 'own'), (Global:CdEntry 'vm-b' 'own'))
        $r.Pass | Should -BeTrue -Because 'a machine in its own group needs only its quota check'
        $r.Detail | Should -Match 'own capacity reservation group'
    }

    It 'the report counts only the others as in an availability set, and names the machine in its own group' {
        & $script:writeClaim -State 'RESERVED' -Instances 3 -Reservable 1 -Own @("$script:rgVm/vm-a") -Held
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; e = @((Global:CdEntry 'vm-a' 'own')) } {
            param($rp, $e) Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document ([pscustomobject]@{ schemaVersion = 30; assessmentRunId = 'crgdemand'; entries = @($e) }) -Depth 20
        }
        $file = New-VmfReport -OutPath $script:rp
        $html = Get-Content ([string]$file) -Raw
        $html | Should -Match '<td>Standard_D2ds_v6 @ centralus</td><td>1</td><td>1</td>' -Because '3 machines: 1 reserved, 1 in its own group, so 1 in an availability set'
        $html | Should -Match 'stayed in their own capacity reservation group[^<]*vm-a'
    }
}
Describe 'CRG-MOVE-DEMAND-1: the scan records the group, and the plan carries it' {

    It 'the Resource Graph query reads the machine''s capacity reservation group' {
        $q = InModuleScope VmMigrationFactory { $script:VmfArgQuery }
        $q | Should -Match 'capacityReservationGroupId = tostring\(properties\.capacityReservation\.capacityReservationGroup\.id\)'
        $q | Should -Match '(?s)\| project [^|]*capacityReservationGroupId'
    }

    It 'the record says the group, $null for none, and leaves the field out when the row does not say' {
        $base = @{ id = "$script:rgVm/a"; name = 'a'; resourceGroup = 'rg-lab'; location = 'centralus'
            sku = 'Standard_D2s_v4'; os = 'Linux'; gen = 'V2'; diskController = 'SCSI'; osDiskManagedId = '/s/rg/disks/a'; nicCount = 1 }
        $records = InModuleScope VmMigrationFactory -Parameters @{ b = $base; theirs = $script:theirs } {
            param($b, $theirs)
            $in = [pscustomobject]($b + @{ capacityReservationGroupId = $theirs })
            $none = [pscustomobject]($b + @{ capacityReservationGroupId = '' })
            $old = [pscustomobject]$b
            @((Get-VmfAssessmentRecord -Vm $in), (Get-VmfAssessmentRecord -Vm $none), (Get-VmfAssessmentRecord -Vm $old))
        }
        $records[0].capacityReservationGroupId | Should -Be $script:theirs
        $null -ne $records[1].PSObject.Properties['capacityReservationGroupId'] | Should -BeTrue
        $null -eq $records[1].capacityReservationGroupId | Should -BeTrue
        $null -eq $records[2].PSObject.Properties['capacityReservationGroupId'] | Should -BeTrue -Because 'a row that does not say is unknown, never "in no group"'
    }

    It 'the assessment is version 13, its schema holds the field, and a version 12 assessment still reads' {
        InModuleScope VmMigrationFactory {
            Get-VmfAssessmentSchemaVersion | Should -Be 17
            { Assert-VmfSupportedAssessment -Assessment ([pscustomobject]@{ schemaVersion = 12 }) } | Should -Throw '*reads only version 17*'
        }
        $s = Get-Content (Join-Path $script:repoRoot 'schemas' 'assessment.schema.json') -Raw | ConvertFrom-Json -Depth 40
        $s.properties.schemaVersion.const | Should -Be 17
        $s.properties.vms.items.properties.capacityReservationGroupId | Should -Not -BeNullOrEmpty
        # The sample, written as v13 with one machine in a group and one in none.
        $doc = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'assessment.sample.json') -Raw | ConvertFrom-Json -Depth 40
        $doc.schemaVersion = 17
        @($doc.vms)[0] | Add-Member -NotePropertyName capacityReservationGroupId -NotePropertyValue $script:theirs -Force
        if (@($doc.vms).Count -gt 1) { @($doc.vms)[1] | Add-Member -NotePropertyName capacityReservationGroupId -NotePropertyValue $null -Force }
        ($doc | ConvertTo-Json -Depth 40) | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'assessment.schema.json') | Should -BeTrue
        @($doc.vms)[0].capacityReservationGroupId = 42
        ($doc | ConvertTo-Json -Depth 40) | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'assessment.schema.json') -ErrorAction SilentlyContinue | Should -BeFalse
    }

    It 'the plan entry carries it when the record has it, and leaves it out when the record does not say' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'New-VmfPlan.ps1')
        $code | Should -Match 'Add-VmfPlanReservationGroup -Assessment \$entry\.assessment -Record \$p\.vm'
        InModuleScope VmMigrationFactory -Parameters @{ theirs = $script:theirs } {
            param($theirs)
            $with = [pscustomobject]@{ capacityReservationGroupId = $theirs }
            $none = [pscustomobject]@{ capacityReservationGroupId = $null }
            $without = [pscustomobject]@{ name = 'x' }
            $a = [ordered]@{}; Add-VmfPlanReservationGroup -Assessment $a -Record $with; $a.capacityReservationGroupId | Should -Be $theirs
            $b = [ordered]@{}; Add-VmfPlanReservationGroup -Assessment $b -Record $none; $b.Contains('capacityReservationGroupId') | Should -BeTrue
            $null -eq $b.capacityReservationGroupId | Should -BeTrue
            $c = [ordered]@{}; Add-VmfPlanReservationGroup -Assessment $c -Record $without; $c.Contains('capacityReservationGroupId') | Should -BeFalse
        }
    }

    It 'the plan entry is version 30, and its schema says the field' {
        InModuleScope VmMigrationFactory { Get-VmfPlanSchemaVersion | Should -Be 37 }
        $s = Get-Content (Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json') -Raw | ConvertFrom-Json -Depth 40
        $s.properties.schemaVersion.const | Should -Be 37
        $s.properties.assessment.properties.capacityReservationGroupId | Should -Not -BeNullOrEmpty
        $sample = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'plan-entry.sample.json') -Raw | ConvertFrom-Json -Depth 40
        $sample.schemaVersion | Should -Be 37
        foreach ($v in $script:theirs, $null) {
            $sample.assessment | Add-Member -NotePropertyName capacityReservationGroupId -NotePropertyValue $v -Force
            ($sample | ConvertTo-Json -Depth 40) | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json') | Should -BeTrue
        }
        $sample.assessment.capacityReservationGroupId = 42
        ($sample | ConvertTo-Json -Depth 40) | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json') -ErrorAction SilentlyContinue | Should -BeFalse
        $notes = Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw
        $notes | Should -Match 'CRG-MOVE-DEMAND-1'
    }
}
