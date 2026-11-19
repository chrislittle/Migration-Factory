#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# CRG-MOVE-1: a move took a machine out of its own capacity reservation group,
# or failed its start in it.
#
# ROLLBACK-CRG-1 records the group at PRECHECK and returns the machine to it on
# every put-back. The move itself did not ask about it: with a wave
# reservation, CONVERTING put the machine in the wave's group (and the release
# later took it out of that group, into none); a Path B rebuild without one put
# it in no group; and a Path A resize kept it in a group that holds no
# reservation for the new size, so Azure refused the start (SAFETY-2) and the
# change window was spent.
#
# THE RULE (2026-10-19): check exactly what Microsoft's "Modify a
# capacity reservation" page says to check before a resize - "Resize VMs
# associated to a capacity reservation group". At PRECHECK, before any change,
# a machine in a group this migration did not make has the group's capacity
# reservations read. No reservation for the TARGET size: refuse untouched, and
# name Microsoft's two options (create one for that size - a reserved quantity
# of 0 needs no more quota - or remove the machine from the group). One for the
# target size: the move keeps the machine in the group on both paths, and a
# wave reservation does not replace it. The reserved quantity is never read:
# Azure allows overallocation, so a quantity is not a limit.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'crgmove'

    $script:subId = '00000000-0000-0000-0000-000000000000'
    $script:sub = "/subscriptions/$script:subId"
    $script:vmId = "$script:sub/resourceGroups/rg-lab/providers/Microsoft.Compute/virtualMachines/vm1"
    # The product's group, made for the wave.
    $script:ours = "$script:sub/resourceGroups/rg-lab/providers/Microsoft.Compute/capacityReservationGroups/vmf-crg-w1"
    # The customer's own group.
    $script:theirs = "$script:sub/resourceGroups/rg-capacity/providers/Microsoft.Compute/capacityReservationGroups/contoso-crg"
    $script:target = 'Standard_D2ds_v6'
    $script:source = 'Standard_D2ds_v4'

    # A run with this machine. -Group is what this attempt's capture recorded:
    # a group id, 'none', or 'unknown' (no field). -Claim writes a RESERVED
    # quota record of the wave for the target size, in the product's group.
    function Global:CmNewRun {
        param([string]$Group = 'none', [switch]$Claim, [string]$Checkpoint = '')
        $rp = Join-Path $script:temp "run-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; g = $Group; claim = [bool]$Claim; ours = $script:ours; sub = $script:subId; cp = $Checkpoint; src = $script:source; tgt = $script:target } {
            param($rp, $id, $g, $claim, $ours, $sub, $cp, $src, $tgt)
            Initialize-VmfRun -RunPath $rp -RunId 'crgmove' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'crgmove' -VmId $id -Wave 'w1' | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $vmConfig = [ordered]@{ size = $src; controller = 'SCSI'; location = 'centralus'; name = 'vm1'; osType = 'Linux'
                osDisk = [ordered]@{ name = 'vm1-osdisk'; skuName = 'Premium_LRS'; managedDiskId = "/subscriptions/$sub/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/vm1-osdisk" }
                dataDisks = @(); nics = @() }
            if ($g -ne 'unknown') { $vmConfig.capacityReservationGroupId = $(if ($g -eq 'none') { $null } else { $g }) }
            $doc | Add-Member -NotePropertyName captured -NotePropertyValue ([pscustomobject]@{ vmConfig = [pscustomobject]$vmConfig }) -Force
            if ($cp) { $doc | Add-Member -NotePropertyName pathCheckpoint -NotePropertyValue $cp -Force }
            Write-VmfStateDoc -RunPath $rp -Document $doc
            if ($claim) {
                Write-VmfStoreJson -RunPath $rp -RelPath 'capacity/w1-d2dsv6.json' -Document ([pscustomobject]@{
                        schemaVersion = 7; runId = 'crgmove'; wave = 'w1'; subscriptionId = $sub; resourceGroup = 'rg-lab'
                        region = 'centralus'; zone = $null; size = $tgt; state = 'RESERVED'
                        reservation = [pscustomobject]@{ groupId = $ours; reservationId = "$ours/capacityReservations/d2dsv6"; consumedInstances = 0 }
                        associatedVmIds = @() })
            }
        }
        $rp
    }
    function Global:CmPlan([string]$Path = 'A') {
        [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vmId; path = $Path; wave = 'w1'; ring = 'prod'
            assessment = [pscustomobject]@{ location = 'centralus'; os = 'Linux'; gen = 'V2'; sourceSize = $script:source }
            target = [pscustomobject]@{ size = $script:target; controller = 'NVMe'; zone = $null }
            policy = [pscustomobject]@{ acceleratedNetworking = 'preserve' } }
    }
    function Global:CmGate([string]$Rp) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $Rp; p = (Global:CmPlan) } {
            param($rp, $p)
            $ctx = New-VmfContext -PlanEntry $p -RunPath $rp -RunId 'crgmove'
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $p.vmId
            Test-VmfMoveReservationGroup -Context $ctx -Capture $doc.captured.vmConfig -TargetSize ([string]$p.target.size)
        }
    }
    function Global:CmConvert([string]$Rp, [string]$Path = 'A') {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $Rp; p = (Global:CmPlan $Path) } {
            param($rp, $p)
            $ctx = New-VmfContext -PlanEntry $p -RunPath $rp -RunId 'crgmove'
            Set-VmfTestAnDecision -RunPath $rp -VmId ([string]$p.vmId) -PlanEntry $p
            Invoke-VmfStepConverting -Context $ctx
        }
    }
    function Global:CmLines([string]$Rp) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $Rp } { param($rp) @(Read-VmfEvents -RunPath $rp) }
    }
    function Global:CmClaim([string]$Rp) {
        Get-Content (Join-Path $Rp 'capacity' 'w1-d2dsv6.json') -Raw | ConvertFrom-Json
    }

    # The fake of Azure's rules, as the drills measured them: a machine joins a
    # group only when the group has a reservation for its CURRENT size (REH-1),
    # and a resize or a create in a group needs a reservation for the new size
    # (Microsoft's capacity-reservation-modify page).
    function Global:CmMockAzure {
        $global:cm = @{
            size = $script:source; group = $null
            holds = @{ $script:ours = @($script:target); $script:theirs = @($script:target) }
            calls = [System.Collections.Generic.List[string]]::new()
        }
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { $true }
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { $global:cm.calls.Add('diskPatch') }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController {
            $g = $global:cm.group
            if ($g -and $Size -notin @($global:cm.holds[$g])) { throw "Capacity Reservation with VM size $Size does not exist in the group." }
            $global:cm.size = $Size; $global:cm.calls.Add("resize:$Size")
        }
        Mock -ModuleName VmMigrationFactory Set-VmfVmCapacityReservationGroup {
            if ($GroupId) {
                if ($global:cm.size -notin @($global:cm.holds[$GroupId])) { throw "Capacity Reservation with VM size $($global:cm.size) does not exist in the group." }
                $global:cm.group = $GroupId; $global:cm.calls.Add("join:$(($GroupId -split '/')[-1])")
            }
            else { $global:cm.group = $null; $global:cm.calls.Add('leave') }
        }
    }
}
AfterAll {
    Remove-Item 'function:\CmNewRun', 'function:\CmPlan', 'function:\CmGate', 'function:\CmConvert', 'function:\CmLines',
        'function:\CmClaim', 'function:\CmMockAzure' -ErrorAction SilentlyContinue
    Remove-Variable cm -Scope Global -ErrorAction SilentlyContinue
    Remove-VmfTestTemp
}

Describe 'CRG-MOVE-1: which group the move asks about' {

    It 'a machine in a group of its owner: that group' {
        InModuleScope VmMigrationFactory -Parameters @{ t = $script:theirs; o = $script:ours } {
            param($t, $o)
            Get-VmfOwnReservationGroup -Capture ([pscustomobject]@{ capacityReservationGroupId = $t }) -ProductGroupIds @($o) | Should -Be $t
        }
    }

    It 'a group of this migration is not asked about, whatever the letter case' {
        InModuleScope VmMigrationFactory -Parameters @{ o = $script:ours } {
            param($o)
            Get-VmfOwnReservationGroup -Capture ([pscustomobject]@{ capacityReservationGroupId = $o.ToUpperInvariant() }) -ProductGroupIds @($o) | Should -BeNullOrEmpty
        }
    }

    It 'a machine in no group, or a record that does not say, is not asked about' {
        InModuleScope VmMigrationFactory -Parameters @{ o = $script:ours } {
            param($o)
            Get-VmfOwnReservationGroup -Capture ([pscustomobject]@{ capacityReservationGroupId = $null }) -ProductGroupIds @($o) | Should -BeNullOrEmpty
            Get-VmfOwnReservationGroup -Capture ([pscustomobject]@{ size = 'x' }) -ProductGroupIds @($o) | Should -BeNullOrEmpty
            Get-VmfOwnReservationGroup -Capture $null -ProductGroupIds @() | Should -BeNullOrEmpty
        }
    }

    It 'the sizes are compared without letter case, as Azure gives them both ways' {
        InModuleScope VmMigrationFactory {
            $held = { param([string[]]$sizes) @($sizes | ForEach-Object { [pscustomobject]@{ size = $_; zones = @() } }) }
            (Get-VmfReservationZoneFit -Reservations (& $held 'standard_d2ds_v6', 'Standard_D4ds_v4') -Size 'Standard_D2ds_v6' -ZoneKnown $true).Fits | Should -BeTrue
            (Get-VmfReservationZoneFit -Reservations (& $held 'Standard_D2ds_v4') -Size 'Standard_D2ds_v6' -ZoneKnown $true).Fits | Should -BeFalse
            (Get-VmfReservationZoneFit -Reservations @() -Size 'Standard_D2ds_v6' -ZoneKnown $true).Fits | Should -BeFalse
            (Get-VmfReservationZoneFit -Reservations (& $held 'Standard_D2ds_v6') -Size '' -ZoneKnown $true).Fits | Should -BeFalse
        }
    }
}

Describe 'CRG-MOVE-1: the check at Checking, before any change' {

    BeforeEach {
        $script:sizes = @()
        # CRG-MOVE-ZONE-1: the read gives { size; zones }; these are regional.
        Mock -ModuleName VmMigrationFactory Get-VmfCapacityReservationSizes { @($script:sizes | ForEach-Object { [pscustomobject]@{ size = $_; zones = @() } }) }
        # Nothing here may change the machine.
        Mock -ModuleName VmMigrationFactory Set-VmfVmCapacityReservationGroup { throw 'the check changed the group' }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { throw 'the check resized the machine' }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { throw 'the check stopped the machine' }
    }

    It 'THE CHECK: a group with no capacity reservation for the target size stops untouched, and names both of Microsoft''s options' {
        $script:sizes = @($script:source)
        $rp = Global:CmNewRun -Group $script:theirs
        $r = Global:CmGate $rp
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'reservationGroupNoTargetSize'
        $r.MachineState | Should -Be 'untouched'
        $r.Detail | Should -Match "'contoso-crg'"
        $r.Detail | Should -Match ([regex]::Escape($script:target))
        $r.Detail | Should -Match 'stopped before it changed the machine'
        # Microsoft's two options, both named.
        $r.Detail | Should -Match "Create a capacity reservation for $([regex]::Escape($script:target)) in the group"
        $r.Detail | Should -Match 'reserved quantity of 0'
        $r.Detail | Should -Match 'remove the machine from the group'
        $r.Detail | Should -Match 'try the machine again'
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfCapacityReservationSizes -Times 1 -Exactly -ParameterFilter { $GroupId -eq $script:theirs }
    }

    It 'an empty group (no capacity reservation at all) stops the same way' {
        $script:sizes = @()
        $r = Global:CmGate (Global:CmNewRun -Group $script:theirs)
        $r.Reason | Should -Be 'reservationGroupNoTargetSize'
    }

    It 'a group with a capacity reservation for the target size passes, and says the move keeps the machine in it' {
        $script:sizes = @($script:source, $script:target)
        $rp = Global:CmNewRun -Group $script:theirs
        Global:CmGate $rp | Should -BeNullOrEmpty
        $line = @(Global:CmLines $rp | Where-Object { $_.step -eq 'precheck' -and $_.detail -match 'contoso-crg' })
        $line.Count | Should -Be 1
        $line[0].detail | Should -Match 'keeps the machine in this group'
    }

    It 'a group of this migration is not asked about' {
        $rp = Global:CmNewRun -Group $script:ours -Claim
        Global:CmGate $rp | Should -BeNullOrEmpty
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfCapacityReservationSizes -Times 0 -Exactly
    }

    It 'a machine in no group, or a record that does not say, is not asked about' {
        Global:CmGate (Global:CmNewRun -Group 'none') | Should -BeNullOrEmpty
        Global:CmGate (Global:CmNewRun -Group 'unknown') | Should -BeNullOrEmpty
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfCapacityReservationSizes -Times 0 -Exactly
    }

    It 'a group Azure does not give the reservations of stops untouched too - unknown is never a yes' {
        Mock -ModuleName VmMigrationFactory Get-VmfCapacityReservationSizes { throw 'AuthorizationFailed: no read access.' }
        $r = Global:CmGate (Global:CmNewRun -Group $script:theirs)
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'reservationGroupNotRead'
        $r.MachineState | Should -Be 'untouched'
        $r.Detail | Should -Match 'AuthorizationFailed'
        $r.Detail | Should -Match 'VMF Assessment role'
    }

    It 'a lost lease during the read stops the worker, never said as a group without the size' {
        Mock -ModuleName VmMigrationFactory Get-VmfCapacityReservationSizes { throw 'The lease was lost - abandon this VM.' }
        { Global:CmGate (Global:CmNewRun -Group $script:theirs) } | Should -Throw '*abandon this VM*'
    }

    It 'Checking asks it after the capture is saved, before the workload check that can start the machine, and before the target is recorded' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1')
        $pre = [regex]::Match($code, '(?s)function Invoke-VmfStepPrecheck \{.*?\nfunction ').Value
        $at = $pre.IndexOf('Test-VmfMoveReservationGroup -Context $Context -Capture $capturedConfig -TargetSize ([string]$plan.target.size)')
        $at | Should -BeGreaterThan 0
        $pre.IndexOf('Save-VmfCapturedFacts -Context $Context -Facts $facts') | Should -BeLessThan $at
        $at | Should -BeLessThan $pre.IndexOf('Get-VmfWorkloadCheckStop -Context $Context')
        $at | Should -BeLessThan $pre.IndexOf('startedTarget = (Get-VmfStartedTarget')
        # And its stop is the step's result: a check whose answer is dropped
        # stops nothing.
        $pre | Should -Match '\$crgMoveGate = Test-VmfMoveReservationGroup [^\n]*\n\s*if \(\$crgMoveGate\) \{ return \$crgMoveGate \}'
    }
}

Describe 'CRG-MOVE-1: the read is by the group''s resource id, and never reads the quantity' {

    BeforeEach {
        # The profile type cannot be faked (DefaultProfile is typed); the call that makes it names the subscription.
        Mock -ModuleName VmMigrationFactory Get-VmfAzContextForSubscription { $null }
    }

    It 'reads the reservations of the group in its own subscription, resource group and name' {
        Mock -ModuleName VmMigrationFactory Get-AzCapacityReservation {
            @([pscustomobject]@{ Name = 'r1'; Sku = [pscustomobject]@{ Name = 'Standard_D2ds_v6'; Capacity = 2 }; Zones = $null })
        }
        $sizes = InModuleScope VmMigrationFactory -Parameters @{ g = $script:theirs } { param($g) @(Get-VmfCapacityReservationSizes -GroupId $g) }
        @($sizes.size) | Should -Be @('Standard_D2ds_v6')
        Should -Invoke -ModuleName VmMigrationFactory Get-AzCapacityReservation -Times 1 -Exactly -ParameterFilter {
            $ResourceGroupName -eq 'rg-capacity' -and $ReservationGroupName -eq 'contoso-crg'
        }
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfAzContextForSubscription -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $script:subId }
    }

    It 'refuses a value that is not a capacity reservation group resource id' {
        Mock -ModuleName VmMigrationFactory Get-AzCapacityReservation { throw 'must not be read' }
        InModuleScope VmMigrationFactory -Parameters @{ v = $script:vmId } {
            param($v)
            { Get-VmfCapacityReservationSizes -GroupId 'contoso-crg' } | Should -Throw '*resource id*'
            { Get-VmfCapacityReservationSizes -GroupId $v } | Should -Throw '*capacity reservation group*'
        }
    }

    It 'a read Azure refuses throws - it is never an empty group' {
        Mock -ModuleName VmMigrationFactory Get-AzCapacityReservation { throw 'AuthorizationFailed' }
        InModuleScope VmMigrationFactory -Parameters @{ g = $script:theirs } {
            param($g) { Get-VmfCapacityReservationSizes -GroupId $g } | Should -Throw '*AuthorizationFailed*'
        }
    }

    It 'a reserved quantity of 0 passes the check: the quantity is not a limit' {
        Mock -ModuleName VmMigrationFactory Get-AzCapacityReservation {
            @([pscustomobject]@{ Name = 'r0'; Sku = [pscustomobject]@{ Name = 'Standard_D2ds_v6'; Capacity = 0 }; VirtualMachinesAssociated = @(); Zones = $null })
        }
        Global:CmGate (Global:CmNewRun -Group $script:theirs) | Should -BeNullOrEmpty
    }

    It 'an overallocated group (more machines than the reserved quantity) passes the check' {
        Mock -ModuleName VmMigrationFactory Get-AzCapacityReservation {
            @([pscustomobject]@{ Name = 'r1'; Sku = [pscustomobject]@{ Name = 'Standard_D2ds_v6'; Capacity = 1 }; Zones = $null
                VirtualMachinesAssociated = @([pscustomobject]@{ Id = 'a' }, [pscustomobject]@{ Id = 'b' }, [pscustomobject]@{ Id = 'c' }) })
        }
        Global:CmGate (Global:CmNewRun -Group $script:theirs) | Should -BeNullOrEmpty
    }

    It 'the check never reads a quantity or a count of machines' {
        $file = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'ReservationMove.ps1'
        $code = Get-VmfCodeOnly -Path $file
        $code | Should -Match 'Get-VmfCapacityReservationSizes'
        $code | Should -Not -Match '(?i)\.Capacity\b|VirtualMachinesAssociated|consumedInstances|\.quantity\b'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops' 'AzureOpsCapacity.ps1'), [ref]$null, [ref]$null)
        $fn = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Get-VmfCapacityReservationSizes' }, $true) | Select-Object -First 1
        $fn | Should -Not -BeNullOrEmpty
        (Get-VmfCodeOnly -Language PowerShell -Text $fn.Body.Extent.Text) | Should -Not -Match '(?i)Sku\.Capacity|VirtualMachinesAssociated'
    }

    It 'the read it makes is one the migration role holds - the map lists it' {
        $map = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'rbac-actions.json') -Raw | ConvertFrom-Json
        $op = @($map.operations | Where-Object cmdlet -eq 'Get-AzCapacityReservation')[0]
        @($op.actions) | Should -Contain 'Microsoft.Compute/capacityReservationGroups/capacityReservations/read'
        $op.why | Should -Match 'CRG-MOVE-1'
    }
}

Describe 'CRG-MOVE-1: the move keeps the machine in its own group' {

    BeforeEach { Global:CmMockAzure }

    It 'Path A: the machine stays in its group through the resize, and is not put in the wave''s group' {
        $rp = Global:CmNewRun -Group $script:theirs -Claim
        $global:cm.group = $script:theirs
        (Global:CmConvert $rp 'A').Next | Should -Be 'STARTING'
        $global:cm.group | Should -Be $script:theirs
        $global:cm.size | Should -Be $script:target
        @($global:cm.calls | Where-Object { $_ -like 'join:*' -or $_ -eq 'leave' }).Count | Should -Be 0
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmCapacityReservationGroup -Times 0 -Exactly
    }

    It 'Path A: the wave''s reservation is not used for the machine, and the activity says so' {
        $rp = Global:CmNewRun -Group $script:theirs -Claim
        $global:cm.group = $script:theirs
        Global:CmConvert $rp 'A' | Out-Null
        @((Global:CmClaim $rp).associatedVmIds | Where-Object { $_ }).Count | Should -Be 0
        $line = @(Global:CmLines $rp | Where-Object { $_.step -eq 'odcr' })
        $line.Count | Should -Be 1
        $line[0].detail | Should -Match "stays in its capacity reservation group 'contoso-crg'"
        $line[0].detail | Should -Match 'capacity reservation of the wave is not used'
        $line[0].outcome | Should -Be 'info'
    }

    It 'Path A with no wave reservation: the line names the group and nothing of a wave' {
        $rp = Global:CmNewRun -Group $script:theirs
        $global:cm.group = $script:theirs
        Global:CmConvert $rp 'A' | Out-Null
        $line = @(Global:CmLines $rp | Where-Object { $_.step -eq 'odcr' })
        $line.Count | Should -Be 1
        $line[0].detail | Should -Not -Match 'wave'
    }

    # REBUILD-REMOVE-ENGINE-1: the Path B rebuild that named the group is gone with its step.

    It 'a machine in no group still takes the wave''s reservation, as before (Path <Path>)' -ForEach @(@{ Path = 'A' }) {
        $rp = Global:CmNewRun -Group 'none' -Claim
        Global:CmConvert $rp $Path | Out-Null
        $global:cm.group | Should -Be $script:ours
        @((Global:CmClaim $rp).associatedVmIds) | Should -Contain $script:vmId
    }

    It 'a machine whose record does not say still takes the wave''s reservation, as before (Path <Path>)' -ForEach @(@{ Path = 'A' }) {
        $rp = Global:CmNewRun -Group 'unknown' -Claim
        Global:CmConvert $rp $Path | Out-Null
        $global:cm.group | Should -Be $script:ours
    }

    It 'a machine already in a group of this migration is treated as before: the wave''s reservation' {
        $rp = Global:CmNewRun -Group $script:ours -Claim
        $global:cm.group = $null
        Global:CmConvert $rp 'A' | Out-Null
        $global:cm.group | Should -Be $script:ours
    }
}

Describe 'CRG-MOVE-1: the stop reason' {

    BeforeAll {
        $script:stops = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json
    }

    It 'is declared, leaves the machine untouched, and works after a fix' {
        $r = @($script:stops.reasons | Where-Object code -eq 'reservationGroupNoTargetSize')
        $r.Count | Should -Be 1
        $r[0].machine | Should -Be 'untouched'
        $r[0].retry | Should -Be 'afterFix'
    }

    It 'names both of Microsoft''s options, and never asks for more reserved quantity' {
        $r = @($script:stops.reasons | Where-Object code -eq 'reservationGroupNoTargetSize')[0]
        $r.whatToDo | Should -Match 'Create a capacity reservation for the target size in the group'
        $r.whatToDo | Should -Match 'reserved quantity of 0'
        $r.whatToDo | Should -Match 'remove the machine from the group'
        "$($r.meaning) $($r.whatToDo)" | Should -Not -Match '(?i)increase the (reserved )?quantity|more instances'
    }
}
