#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# ZONES-1: a machine in an availability zone takes only disks made in that
# zone, and runs only on a size Azure offers in that zone.
#
# A disk made from a copy has no zone unless it is given one. SAFETY-ALL-1
# found the automatic put-back making zoneless disks and fixed it; the
# operator's restore and rebuild still made them, so on a zonal machine both
# would fail at the swap or the rebuild - with the machine stopped. And a size
# can be in the region without being in every zone of it: PRECHECK now asks,
# while the machine is still untouched.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    . (Join-Path $PSScriptRoot '_RecordShape.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # RESTORE-PERM-CHECK-1: the permission check of Restore this machine is not under test here (RestorePermCheck.Tests.ps1).
    Mock -ModuleName VmMigrationFactory Get-VmfRestorePermissionStop { $null }
    # OLD-VERSION-READERS-REMOVE-4: every disk made from a copy is read back and its key compared, so the fake Azure answers the read.
    Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }
    # CLUSTER-DETECT-1: the cluster check at Checking is not under test here;
    # ClusterDetect.Tests.ps1 and StateMachine.Tests.ps1 test it.
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }

    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers'
    $script:vmId = "$($script:sub)/Microsoft.Compute/virtualMachines/vm1"

    function Global:ZnSku {
        param([string]$Name = 'Standard_D2s_v6', $Zones, $Restricted)
        $entry = [ordered]@{ Name = $Name; ResourceType = 'virtualMachines'; Family = 'StandardDSv6Family'
            Capabilities = @([pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '4' }); Restrictions = @() }
        if ($null -ne $Zones) { $entry.LocationInfo = @([pscustomobject]@{ Location = 'centralus'; Zones = [string[]]@($Zones) }) }
        if ($Restricted) {
            $entry.Restrictions = @([pscustomobject]@{ Type = 'Zone'; ReasonCode = 'NotAvailableForSubscription'
                RestrictionInfo = [pscustomobject]@{ Zones = @($Restricted) } })
        }
        [pscustomobject]$entry
    }

    # A zonal machine, shaped like Get-AzVM returns.
    function Global:ZnVm {
        param([string[]]$Zones = @('2'))
        [pscustomobject]@{
            Name = 'vm1'; ResourceGroupName = 'rg-app'; Location = 'centralus'
            HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_D2s_v4' }
            StorageProfile = [pscustomobject]@{
                DiskControllerType = 'SCSI'
                OsDisk = [pscustomobject]@{ OsType = 'Linux'; Name = 'vm1-os'; DeleteOption = 'Delete'
                    ManagedDisk = [pscustomobject]@{ Id = "$($script:sub)/Microsoft.Compute/disks/vm1-os"; StorageAccountType = 'Premium_LRS' } }
                DataDisks = @(); ImageReference = $null
            }
            NetworkProfile = [pscustomobject]@{ NetworkInterfaces = @([pscustomobject]@{ Id = "$($script:sub)/Microsoft.Network/networkInterfaces/nic0"; Primary = $true }) }
            Zones = $Zones; Tags = @{}
            LicenseType = $null; AvailabilitySetReference = $null; ProximityPlacementGroup = $null
            Priority = $null; Identity = $null; AdditionalCapabilities = $null; DiagnosticsProfile = $null
        }
    }

    # A migrated zonal machine with both copies, as the restore finds it.
    function Global:ZnRun {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-zn-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; sub = $script:sub } {
            param($rp, $id, $sub)
            Initialize-VmfRun -RunPath $rp -RunId 'zn' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'zn' -VmId $id -Wave 'w1' | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $doc | Add-Member -NotePropertyName captured -Force -NotePropertyValue ([pscustomobject]@{
                    vmConfig = [pscustomobject]@{ name = 'vm1'; size = 'Standard_D2s_v4'; controller = 'SCSI'; location = 'centralus'; osType = 'Linux'; zones = @('2')
                        osDisk = [pscustomobject]@{ name = 'vm1-os'; skuName = 'Premium_LRS'; managedDiskId = "$sub/Microsoft.Compute/disks/vm1-os"; deleteOption = 'Delete' }
                        dataDisks = @(); tags = @{}; nics = @() } })
            $doc | Add-Member -NotePropertyName safety -Force -NotePropertyValue ([pscustomobject]@{
                    snapshotId = "$sub/Microsoft.Compute/snapshots/vm1-prepared"; cloneVmId = $null; locksAllowed = $true
                    pristineSnapshotId = "$sub/Microsoft.Compute/snapshots/vm1-pristine"; pristineSnapshotLocked = $true })
            $doc.state = 'MIGRATED'
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
            $plan = [ordered]@{ schemaVersion = 1; entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; wave = 'w1'; ring = 'lab'
                        assessment = [ordered]@{ location = 'centralus'; os = 'Linux' }
                        target = [ordered]@{ size = 'Standard_D2s_v6'; controller = 'NVMe'; zone = '2' }; path = 'A'; policy = [ordered]@{} }) }
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document $plan -Depth 24
        }
        $rp
    }

    Mock -ModuleName VmMigrationFactory Get-VmfEngineSubscriptionId { '00000000-0000-0000-0000-000000000000' }
    Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { 'previous-context' }
    Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
}
AfterAll { Remove-Item function:ZnSku, function:ZnVm, function:ZnRun -ErrorAction SilentlyContinue }

Describe 'ZONES-1: the machine''s zone, read in one place' {
    It 'reads the zone from a capture, and from a live machine' {
        InModuleScope VmMigrationFactory {
            Get-VmfMachineZone -Machine ([pscustomobject]@{ zones = @('2') }) | Should -Be '2'
            Get-VmfMachineZone -Machine ([pscustomobject]@{ Zones = [string[]]@('3') }) | Should -Be '3'
        }
    }

    It 'a regional machine, or no machine at all, has no zone' {
        InModuleScope VmMigrationFactory {
            Get-VmfMachineZone -Machine ([pscustomobject]@{ zones = @() }) | Should -Be ''
            Get-VmfMachineZone -Machine ([pscustomobject]@{ zones = $null }) | Should -Be ''
            Get-VmfMachineZone -Machine $null | Should -Be ''
        }
    }
}

Describe 'ZONES-1: does Azure offer a size in a zone' {
    It 'a regional machine has no zone to match' {
        InModuleScope VmMigrationFactory {
            Test-VmfSizeInZone -SkuEntry (ZnSku -Zones @('1')) -Zone '' | Should -BeTrue
        }
    }

    It 'yes when the region offers it in that zone' {
        InModuleScope VmMigrationFactory {
            Test-VmfSizeInZone -SkuEntry (ZnSku -Zones @('1', '2', '3')) -Zone '2' | Should -BeTrue
        }
    }

    It 'no when the region offers it only in its other zones' {
        InModuleScope VmMigrationFactory {
            Test-VmfSizeInZone -SkuEntry (ZnSku -Zones @('1', '3')) -Zone '2' | Should -BeFalse
        }
    }

    It 'no when the zone is restricted for this subscription - any restriction, not the first' {
        InModuleScope VmMigrationFactory {
            Test-VmfSizeInZone -SkuEntry (ZnSku -Zones @('1', '2', '3') -Restricted @('2')) -Zone '2' | Should -BeFalse
            $entry = ZnSku -Zones @('1', '2', '3')
            $entry.Restrictions = @(
                [pscustomobject]@{ Type = 'Zone'; ReasonCode = 'first'; RestrictionInfo = [pscustomobject]@{ Zones = @('1') } },
                [pscustomobject]@{ Type = 'Zone'; ReasonCode = 'NotAvailableForSubscription'; RestrictionInfo = [pscustomobject]@{ Zones = @('2') } })
            Test-VmfSizeInZone -SkuEntry $entry -Zone '2' | Should -BeFalse
            Test-VmfSizeInZone -SkuEntry $entry -Zone '3' | Should -BeTrue
            # The code named is the one that covers THIS zone.
            Get-VmfZoneRestrictionCode -SkuEntry $entry -Zone '2' | Should -Be 'NotAvailableForSubscription'
            Get-VmfZoneRestrictionCode -SkuEntry $entry -Zone '3' | Should -Be ''
        }
    }

    It 'no when the size is restricted in the whole region for this subscription' {
        InModuleScope VmMigrationFactory {
            $entry = ZnSku -Zones @('1', '2', '3')
            $entry.Restrictions = @([pscustomobject]@{ Type = 'Location'; ReasonCode = 'NotAvailableForSubscription'; RestrictionInfo = [pscustomobject]@{ Zones = @() } })
            Test-VmfSizeInZone -SkuEntry $entry -Zone '2' | Should -BeFalse
            Get-VmfZoneRestrictionCode -SkuEntry $entry -Zone '2' | Should -Be 'NotAvailableForSubscription'
        }
    }

    It 'reads the entry for the region, not the first - an extended location carries one with no zones' {
        InModuleScope VmMigrationFactory {
            $entry = ZnSku
            $entry | Add-Member -NotePropertyName LocationInfo -Force -NotePropertyValue @(
                [pscustomobject]@{ Location = 'edgezone1'; Zones = [string[]]@() },
                [pscustomobject]@{ Location = 'centralus'; Zones = [string[]]@('1', '2') })
            Test-VmfSizeInZone -SkuEntry $entry -Zone '2' -Location 'Central US' | Should -BeTrue
            Test-VmfSizeInZone -SkuEntry $entry -Zone '2' -Location 'westus3' | Should -BeNullOrEmpty
        }
    }

    It 'a region entry with an EMPTY zone list is a no; one with NO list is unknown' {
        InModuleScope VmMigrationFactory {
            Test-VmfSizeInZone -SkuEntry (ZnSku -Zones @()) -Zone '2' -Location 'centralus' | Should -BeFalse
            $entry = ZnSku
            $entry | Add-Member -NotePropertyName LocationInfo -Force -NotePropertyValue @([pscustomobject]@{ Location = 'centralus'; Zones = $null })
            Test-VmfSizeInZone -SkuEntry $entry -Zone '2' -Location 'centralus' | Should -BeNullOrEmpty
        }
    }

    It 'unknown is not a yes and not a no: no entry, or an entry that does not say' {
        InModuleScope VmMigrationFactory {
            Test-VmfSizeInZone -SkuEntry $null -Zone '2' | Should -BeNullOrEmpty
            Test-VmfSizeInZone -SkuEntry (ZnSku) -Zone '2' | Should -BeNullOrEmpty
        }
    }
}

Describe 'ZONES-1: PRECHECK refuses a size the machine''s zone does not offer' {
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-znp-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Initialize-VmfRun -RunPath $rp -RunId 'znp' | Out-Null }
        Mock -ModuleName VmMigrationFactory Test-VmfAdeExtension { $false }
        # SAFETY-CMK-1: PRECHECK reads each disk's encryption by its id.
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }
        Mock -ModuleName VmMigrationFactory Get-VmfVmResourceLocks { , @() }
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { @([pscustomobject]@{ actions = @('*'); notActions = @() }) }
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/running' }
        Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions { @() }
        Mock -ModuleName VmMigrationFactory Get-AzNetworkInterface { [pscustomobject]@{ EnableAcceleratedNetworking = $true } }
        # Through the boundary, not Get-AzVM: a file that mocks an Az cmdlet anywhere
        # is exempt from the Azure guard for it everywhere, and the restore tests below
        # then reached real Azure (RESTORE-ALL-1's review).
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { Global:ZnVm }
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'THE CASE: a single-interface machine in zone 2, a size offered in zones 1 and 3 - stopped untouched' {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @(Global:ZnSku -Zones @('1', '3')) }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { throw 'the machine must not be touched' }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id)
            $plan = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; wave = 'w1'; ring = 'lab'; path = 'A'
                assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'; sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; platformManaged = $false; location = 'centralus' }
                target = [pscustomobject]@{ size = 'Standard_D2s_v6'; diskArch = 'diskless'; controller = 'NVMe'; zone = '2' }
                policy = [pscustomobject]@{ onDDataFound = 'proceed' } }
            $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'znp'
            New-VmfStateDoc -RunPath $rp -RunId 'znp' -VmId $ctx.VmId | Out-Null
            $r = Invoke-VmfStepPrecheck -Context $ctx
            $r.Next | Should -Be 'NEEDS_DECISION'
            $r.Reason | Should -Be 'targetNotInZone'
            $r.Detail | Should -Match 'Standard_D2s_v6'
            $r.Detail | Should -Match 'zone 2'
        }
    }

    It 'a size offered in the machine''s zone goes on' {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @(Global:ZnSku -Zones @('1', '2', '3')) }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id)
            $plan = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; wave = 'w1'; ring = 'lab'; path = 'A'
                assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'; sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; platformManaged = $false; location = 'centralus' }
                target = [pscustomobject]@{ size = 'Standard_D2s_v6'; diskArch = 'diskless'; controller = 'NVMe'; zone = '2' }
                policy = [pscustomobject]@{ onDDataFound = 'proceed' } }
            $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'znp'
            New-VmfStateDoc -RunPath $rp -RunId 'znp' -VmId $ctx.VmId | Out-Null
            (Invoke-VmfStepPrecheck -Context $ctx).Next | Should -Be 'SAFETY_PRISTINE'
        }
        # Zone restrictions and zone numbers belong to a subscription: the
        # catalog is read as the machine's own, never the worker's last one.
        Should -Invoke Get-VmfSkuCatalog -ModuleName VmMigrationFactory -ParameterFilter { $SubscriptionId -eq '00000000-0000-0000-0000-000000000000' }
    }

    It 'a catalog that does not say is not a refusal - and PRECHECK says it could not check' {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @(Global:ZnSku) }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id)
            $plan = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; wave = 'w1'; ring = 'lab'; path = 'A'
                assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'; sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; platformManaged = $false; location = 'centralus' }
                target = [pscustomobject]@{ size = 'Standard_D2s_v6'; diskArch = 'diskless'; controller = 'NVMe'; zone = '2' }
                policy = [pscustomobject]@{ onDDataFound = 'proceed' } }
            $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'znp'
            New-VmfStateDoc -RunPath $rp -RunId 'znp' -VmId $ctx.VmId | Out-Null
            (Invoke-VmfStepPrecheck -Context $ctx).Next | Should -Be 'SAFETY_PRISTINE'
            $events = Get-Content (Join-Path $rp 'logs' 'events.jsonl') -Raw
            $events | Should -Match 'cannot confirm zone 2'
        }
    }

    It 'the stop has guidance: the machine is untouched, and another size fixes it' {
        $reason = @((Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json).reasons) |
            Where-Object code -eq 'targetNotInZone'
        $reason | Should -Not -BeNullOrEmpty
        $reason.machine | Should -Be 'untouched'
        $reason.retry | Should -Be 'afterFix'
    }
}


Describe 'ZONES-1: the operator''s restore makes every disk in the machine''s zone' {
    BeforeEach {
        $global:zn = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { $global:zn.Add("$DiskName|$Zone"); "/disks/$DiskName" }
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo { [pscustomobject]@{ name = 'vm1-os'; id = '/d/vm1-os'; resourceGroup = 'rg-app'; location = 'centralus'; skuName = 'Premium_LRS'; sizeGB = 30; controller = 'NVMe' } }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @() }   # RESTORE-ALL-1: no data disks unless a test says so
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { $null }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { }
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk { }
        Mock -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks { , @() }
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { $true }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { $true }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @() }
        Mock -ModuleName VmMigrationFactory Get-VmfVmSize { 'Standard_D2s_v4' }
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { [pscustomobject]@{ Name = 'vm1' } }
        $script:rp = ZnRun
    }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force }; Remove-Variable zn -Scope Global -ErrorAction SilentlyContinue }

    It 'a new name, from each copy: the disk is made in zone 2' {
        foreach ($from in 'pristine', 'prepared') {
            $global:zn.Clear()
            Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From $from -Confirm:$false | Out-Null
            @($global:zn).Count | Should -Be 1 -Because $from
            @($global:zn | Where-Object { $_ -notmatch '\|2$' }) | Should -BeNullOrEmpty -Because $from
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
                param($rp, $id)
                $doc = Read-VmfStateDoc -RunPath $rp -VmId $id; $doc.state = 'MIGRATED'; Write-VmfStateDoc -RunPath $rp -Document $doc
            }
        }
    }

    It 'the original name: the temporary disk and the final disk are both made in zone 2' {
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From prepared -DiskNaming preserve -AcceptPreserveRisk -Confirm:$false | Out-Null
        @($global:zn).Count | Should -Be 2
        @($global:zn | Where-Object { $_ -notmatch '\|2$' }) | Should -BeNullOrEmpty
    }
}

# REBUILD-REMOVE-RECOVER-1: removed with Rebuild this machine (Restore-VmfVmShell).

# REBUILD-REMOVE-ROLE-1: removed with New-VmfVmFromCapture, the Path B create.

Describe 'ZONES-1: no disk is made from a copy without the machine''s zone' {
    # The class, not the instance: SAFETY-ALL-1 fixed the put-back and left
    # the restore and the rebuild. A new call site that forgets the zone fails
    # here, not on a zonal machine with its disks detached.
    It 'every call that makes a disk from a copy passes -Zone' {
        $srcRoot = Join-Path $script:repoRoot 'src' 'VmMigrationFactory'
        $calls = foreach ($file in Get-ChildItem $srcRoot -Recurse -Filter '*.ps1') {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            $ast.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -and
                    # SAFETY-CMK-1: every OS disk made from a copy goes through
                    # New-VmfOsDiskFromCopy, which passes -Zone on.
                    $n.GetCommandName() -in @('New-VmfDiskFromSnapshot', 'Invoke-VmfDataDiskRestore', 'New-VmfOsDiskFromCopy') }, $true) |
                ForEach-Object {
                    [pscustomobject]@{
                        Where = "$($file.Name):$($_.Extent.StartLineNumber)"
                        # The argument too: -Zone '' or -Zone $null passes the
                        # parameter and gives no zone.
                        HasZone = $(
                            $els = @($_.CommandElements)
                            $at = [array]::FindIndex([object[]]$els, [Predicate[object]] { param($e) $e -is [System.Management.Automation.Language.CommandParameterAst] -and $e.ParameterName -eq 'Zone' })
                            $at -ge 0 -and $at + 1 -lt $els.Count -and
                                ($els[$at + 1] -isnot [System.Management.Automation.Language.CommandParameterAst]) -and
                                ($els[$at + 1].Extent.Text -notin @("''", '""', '$null')))
                    }
                }
        }
        # SAFETY-CMK-1: eight OS disk calls moved into New-VmfOsDiskFromCopy,
        # which is now one call of New-VmfDiskFromSnapshot and eight of its own.
        # REBUILD-REMOVE-RECOVER-1: three went with Rebuild this machine and the
        # restore that rebuilt. REBUILD-REMOVE-ENGINE-1: two went with the Path B
        # rollback.
        @($calls).Count | Should -BeGreaterOrEqual 10
        @($calls | Where-Object { -not $_.HasZone } | ForEach-Object Where) | Should -BeNullOrEmpty
    }

    It 'no file picks the machine''s ONE zone with a line of its own' {
        # What it checks: the two ways a zone was picked by hand before this
        # item - filtering the list, or taking its first item. Copying the
        # machine's whole zone list (New-VmfVmFromCapture) is not picking one.
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $srcRoot = Join-Path $script:repoRoot 'src' 'VmMigrationFactory'
        $own = foreach ($file in Get-ChildItem $srcRoot -Recurse -Filter '*.ps1' | Where-Object Name -ne 'Zones.ps1') {
            $code = Get-VmfCodeOnly -Path $file.FullName
            if ($code -match '(?i)\.zones\s*\|\s*Where-Object|\.zones\)\s*\[0\]') { $file.Name }
        }
        @($own) | Should -BeNullOrEmpty
    }

    It 'a disk of that name already in another zone is refused, never reused' {
        InModuleScope VmMigrationFactory {
            Mock Get-AzDisk { [pscustomobject]@{ Id = '/d/x'; Zones = @('1'); CreationData = [pscustomobject]@{ SourceResourceId = '/s/copy' } } }
            { New-VmfDiskFromSnapshot -ResourceGroupName 'rg' -DiskName 'x' -SnapshotId '/s/copy' -Location 'centralus' -SkuName 'Premium_LRS' -Zone '2' } |
                Should -Throw -ExpectedMessage "*not in zone '2'*"
            New-VmfDiskFromSnapshot -ResourceGroupName 'rg' -DiskName 'x' -SnapshotId '/s/copy' -Location 'centralus' -SkuName 'Premium_LRS' -Zone '1' | Should -Be '/d/x'
            # Zone-redundant: no zone of its own, and any machine takes it.
            New-VmfDiskFromSnapshot -ResourceGroupName 'rg' -DiskName 'x' -SnapshotId '/s/copy' -Location 'centralus' -SkuName 'Premium_ZRS' -Zone '2' | Should -Be '/d/x'
        }
    }
}

Describe 'ZONES-1: the catalog is read, and cached, per subscription' {
    It 'two subscriptions in one region are two reads; the same one again is none' {
        InModuleScope VmMigrationFactory {
            $script:VmfSkuCache = @{}
            $global:znReads = [System.Collections.Generic.List[string]]::new()
            Mock Get-VmfAzContextForSubscription { "ctx-$SubscriptionId" }
            Mock Get-AzComputeResourceSku { $global:znReads.Add("$DefaultProfile"); @([pscustomobject]@{ Name = 'Standard_D2s_v6'; ResourceType = 'virtualMachines' }) } -RemoveParameterType DefaultProfile
            $null = Get-VmfSkuCatalog -Location 'centralus' -SubscriptionId 'aaaa'
            $null = Get-VmfSkuCatalog -Location 'centralus' -SubscriptionId 'bbbb'
            $null = Get-VmfSkuCatalog -Location 'centralus' -SubscriptionId 'aaaa'
            @($global:znReads) | Should -Be @('ctx-aaaa', 'ctx-bbbb')
            $script:VmfSkuCache = @{}
            Remove-Variable znReads -Scope Global -ErrorAction SilentlyContinue
        }
    }
}
