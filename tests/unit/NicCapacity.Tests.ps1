#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# NIC-1: multi-NIC machines. Capture/recreate already replayed
# every NIC, but NOTHING checked that the TARGET SIZE can hold them - and a
# size that cannot is discovered during the recreate, after the machine is
# deallocated and its disks detached. That is the one failure that lands past
# the point of no return, so it is gated twice: at plan time (pick a size that
# fits) and at PRECHECK (refuse while the machine is still untouched).
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    # TEST-1: anything this file forgets to mock must fail as a TEST error,
    # not quietly reach real Azure. Placed before the file's own mocks so
    # those still win where they exist.
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # CLUSTER-DETECT-1: the cluster check at Checking is not under test here;
    # ClusterDetect.Tests.ps1 and StateMachine.Tests.ps1 test it.
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }

    function Global:NicSku {
        param([string]$Name, $MaxNics, [int]$ResourceMb = 0)
        $caps = [System.Collections.Generic.List[object]]::new()
        $caps.Add([pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = "$ResourceMb" })
        if ($null -ne $MaxNics) { $caps.Add([pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = "$MaxNics" }) }
        [pscustomobject]@{ Name = $Name; ResourceType = 'virtualMachines'; Family = 'StandardDSv6Family'; Capabilities = @($caps) }
    }

    # a VM object with N NICs, shaped like Get-AzVM returns
    function Global:NicVm {
        param([int]$Count = 1)
        [pscustomobject]@{
            Name = 'nicvm'; ResourceGroupName = 'rg'; Location = 'centralus'
            HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_D2s_v4' }
            StorageProfile = [pscustomobject]@{
                DiskControllerType = 'SCSI'
                OsDisk = [pscustomobject]@{
                    OsType = 'Linux'; Name = 'nicvm-os'
                    ManagedDisk = [pscustomobject]@{ Id = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/disks/nicvm-os'; StorageAccountType = 'Premium_LRS' }
                    DeleteOption = 'Delete'
                }
                DataDisks = @(); ImageReference = $null
            }
            NetworkProfile = [pscustomobject]@{
                NetworkInterfaces = @(0..($Count - 1) | ForEach-Object {
                    [pscustomobject]@{ Id = "/subscriptions/s/resourceGroups/rg/providers/Microsoft.Network/networkInterfaces/nic$_"; Primary = ($_ -eq 0) }
                })
            }
            Zones = @(); Tags = @{}
            LicenseType = $null; AvailabilitySetReference = $null; ProximityPlacementGroup = $null
            Priority = $null; Identity = $null; AdditionalCapabilities = $null; DiagnosticsProfile = $null
        }
    }
    # ENGINE-SUB-1: these fixtures build machines in 00000000-0000-0000-0000-000000000000.
    # Pin the engine to the same subscription so the cross-subscription
    # guard is not the thing under test here - EngineSubscription.Tests.ps1
    # is where that behaviour is asserted.
    Mock -ModuleName VmMigrationFactory Get-VmfEngineSubscriptionId { '00000000-0000-0000-0000-000000000000' }
    # ENGINE-SUB-1: the state machine now points the PROCESS at each machine's
    # own subscription before doing anything. These fixtures use an invented
    # subscription id, so the switch has to be mocked - these tests are about
    # what the engine DOES, not about whether Azure has heard of the id.
    # EngineSubscription.Tests.ps1 and the cross-subscription lab drill are
    # where the switch itself is proved.
    Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { $null }
    Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
}
AfterAll { Remove-Item 'function:\NicSku', 'function:\NicVm' -ErrorAction SilentlyContinue }

Describe 'NIC-1: reading the NIC limit off a size' {
    It 'reads MaxNetworkInterfaces from the SKU catalog' {
        InModuleScope VmMigrationFactory {
            Get-VmfSkuMaxNics -SkuEntry (Global:NicSku 'Standard_D8s_v6' 4) | Should -Be 4
        }
    }

    It 'reports UNKNOWN rather than guessing when the capability is absent' {
        # Azure occasionally omits a capability. Guessing a number here would
        # be worse than admitting we do not know - the engine treats unknown
        # as "cannot verify", never as "fits".
        InModuleScope VmMigrationFactory {
            Get-VmfSkuMaxNics -SkuEntry (Global:NicSku 'Standard_D2s_v6' $null) | Should -BeNullOrEmpty
            Get-VmfSkuMaxNics -SkuEntry $null | Should -BeNullOrEmpty
        }
    }
}

Describe 'NIC-1: the plan picks a size that can actually hold the NICs' {
    It 'refuses a named size that is too small, and takes one that fits' {
        # SIZEMAP-REMOVE-1: a named size (a chosen one) has no alternates.
        InModuleScope VmMigrationFactory {
            $catalog = @{
                'Standard_D2s_v6' = (Global:NicSku 'Standard_D2s_v6' 2)
                'Standard_D8s_v6' = (Global:NicSku 'Standard_D8s_v6' 4)
            }
            $r = Get-VmfTargetSize -SourceSize 'Standard_D2s_v4' -Size 'Standard_D2s_v6' -CatalogBySize $catalog -RequiredNics 4
            $r.Target | Should -BeNullOrEmpty -Because 'D2s_v6 holds only 2 NICs'
            $r.Code | Should -Be 'too-few-nics'
            (Get-VmfTargetSize -SourceSize 'Standard_D2s_v4' -Size 'Standard_D8s_v6' -CatalogBySize $catalog -RequiredNics 4).Target |
                Should -Be 'Standard_D8s_v6'
        }
    }

    It 'refuses to name a target when nothing can hold them, and says both numbers' {
        InModuleScope VmMigrationFactory {
            $catalog = @{ 'Standard_D2s_v6' = (Global:NicSku 'Standard_D2s_v6' 2) }
            $r = Get-VmfTargetSize -SourceSize 'Standard_D2s_v4' -CatalogBySize $catalog -RequiredNics 8
            $r.Target | Should -BeNullOrEmpty
            $r.Reason | Should -Match '8'
            $r.Reason | Should -Match '2'
            $r.Reason | Should -Match '(?i)network interface'
        }
    }

    It 'names a size that WOULD fit instead of just refusing' {
        # The real case, with the numbers Azure reports in centralus:
        # D2ds_v4 holds 3 NICs but its default target D2ds_v6 holds only 2.
        # A refusal that does not say what to use instead is a puzzle.
        InModuleScope VmMigrationFactory {
            $catalog = @{
                'Standard_D2ds_v6'  = (Global:NicSku 'Standard_D2ds_v6' 2)
                'Standard_D4ds_v6'  = (Global:NicSku 'Standard_D4ds_v6' 4)
                'Standard_D16ds_v6' = (Global:NicSku 'Standard_D16ds_v6' 8)
                'Standard_E4ds_v6'  = (Global:NicSku 'Standard_E4ds_v6' 4)
            }
            $r = Get-VmfTargetSize -SourceSize 'Standard_D2ds_v4' -CatalogBySize $catalog -RequiredNics 3
            $r.Target | Should -BeNullOrEmpty
            $r.Reason | Should -Match 'Standard_D4ds_v6' -Because 'the smallest that fits is the cheapest that fits'
            $r.Reason | Should -Not -Match 'Standard_D16ds_v6'
            $r.Reason | Should -Not -Match 'Standard_E4ds_v6' -Because 'a suggestion must stay in the same series'
        }
    }

    It 'leaves single-NIC machines exactly as they were' {
        # the overwhelmingly common case must not change behaviour at all
        InModuleScope VmMigrationFactory {
            $catalog = @{ 'Standard_D2s_v6' = (Global:NicSku 'Standard_D2s_v6' 2) }
            (Get-VmfTargetSize -SourceSize 'Standard_D2s_v4' -CatalogBySize $catalog -RequiredNics 1).Target |
                Should -Be 'Standard_D2s_v6'
            (Get-VmfTargetSize -SourceSize 'Standard_D2s_v4' -CatalogBySize $catalog).Target |
                Should -Be 'Standard_D2s_v6' -Because 'callers that never pass a NIC count keep working'
        }
    }

    It 'does not block a multi-NIC machine when the limit is unknown - it says so instead' {
        InModuleScope VmMigrationFactory {
            $catalog = @{ 'Standard_D2s_v6' = (Global:NicSku 'Standard_D2s_v6' $null) }
            $r = Get-VmfTargetSize -SourceSize 'Standard_D2s_v4' -CatalogBySize $catalog -RequiredNics 4
            $r.Target | Should -Be 'Standard_D2s_v6'
            $r.Reason | Should -Match '(?i)could not be verified'
        }
    }
}

Describe 'NIC-1: the fact travels from discovery into the plan' {
    It 'the inventory query asks Azure for the NIC count' {
        $q = InModuleScope VmMigrationFactory { $script:VmfArgQuery }
        $q | Should -Match 'networkInterfaces'
        $q | Should -Match 'nicCount'
    }

    It 'the assessment record carries nicCount' {
        InModuleScope VmMigrationFactory {
            $row = [pscustomobject]@{
                id = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/multi'
                name = 'multi'; resourceGroup = 'rg'; location = 'centralus'; zones = @()
                sku = 'Standard_D2s_v4'; os = 'Linux'; gen = 'V2'; diskController = 'SCSI'
                imagePublisher = 'Canonical'; imageSku = '22_04-lts'; vmssId = ''
                hibernationEnabled = $false; securityType = ''; dataDiskCount = 0
                availabilitySetId = ''; nicCount = 3; tags = $null
            }
            (Get-VmfAssessmentRecord -Vm $row).nicCount | Should -Be 3
        }
    }

    It 'an assessment written before NIC-1 still plans - a missing count is not a crash' {
        InModuleScope VmMigrationFactory {
            $row = [pscustomobject]@{
                id = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/old'
                name = 'old'; resourceGroup = 'rg'; location = 'centralus'; zones = @()
                sku = 'Standard_D2s_v4'; os = 'Linux'; gen = 'V2'; diskController = 'SCSI'
                imagePublisher = 'Canonical'; imageSku = '22_04-lts'; vmssId = ''
                hibernationEnabled = $false; securityType = ''; dataDiskCount = 0
                availabilitySetId = ''; tags = $null
            }
            (Get-VmfAssessmentRecord -Vm $row).nicCount | Should -Be 1
        }
    }
}

Describe 'NIC-1: PRECHECK refuses while the machine is still untouched' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-nic-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Initialize-VmfRun -RunPath $rp -RunId 'nic-test' | Out-Null
        }
        Mock -ModuleName VmMigrationFactory Test-VmfAdeExtension { $false }
        # SAFETY-CMK-1: PRECHECK reads each disk's encryption by its id.
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }
        # PERM-3: PRECHECK now asks Azure what this identity may do before it
        # touches anything. Without a mock these tests reach REAL ARM (they got
        # HTTP 404s), which unit tests must never do. A fully privileged identity
        # is the right default here - the refusal itself is covered in
        # PermissionPreflight.Tests.ps1.
        # LOCK-1: PRECHECK now reads resource locks before anything is touched.
        Mock -ModuleName VmMigrationFactory Get-VmfVmResourceLocks { , @() }
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions {
            @([pscustomobject]@{ actions = @('*'); notActions = @() })
        }
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/running' }
        Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions { @() }
        Mock -ModuleName VmMigrationFactory Get-AzNetworkInterface {
            [pscustomobject]@{ EnableAcceleratedNetworking = $true }
        }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'parks a machine whose NICs the target size cannot hold - BEFORE anything is mutated' {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @(Global:NicSku 'Standard_D2s_v6' 2) }
        Mock -ModuleName VmMigrationFactory Get-AzVM { Global:NicVm -Count 4 }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $plan = [pscustomobject]@{
                schemaVersion = (Get-VmfTestPlanEntryVersion)
                vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/nicvm'
                wave = 'w1'; ring = 'lab'
                assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'; sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; platformManaged = $false; location = 'centralus' }
                target = [pscustomobject]@{ size = 'Standard_D2s_v6'; diskArch = 'diskless'; controller = 'NVMe' }
                path = 'A'
                policy = [pscustomobject]@{ onDDataFound = 'proceed' }
            }
            $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'nic-test'
            New-VmfStateDoc -RunPath $rp -RunId 'nic-test' -VmId $ctx.VmId | Out-Null
            $r = Invoke-VmfStepPrecheck -Context $ctx
            $r.Next | Should -Be 'NEEDS_DECISION'
            $r.Detail | Should -Match '4'
            $r.Detail | Should -Match '2'
            $r.Detail | Should -Match '(?i)network interface'
        }
    }

    It 'lets a machine through when the target size holds them all' {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @(Global:NicSku 'Standard_D2s_v6' 8) }
        Mock -ModuleName VmMigrationFactory Get-AzVM { Global:NicVm -Count 4 }
        # AN-ONE-NIC-1: accelerated networking off on every interface, so the
        # move leaves it on the primary only. With it on all four (the
        # BeforeEach default), a 2-vCPU size cannot hold the end state - and
        # this catalog row gives no vCPU count, so PRECHECK stops as "cannot
        # verify" (AnOneNic.Tests.ps1). This test is about the interface count.
        Mock -ModuleName VmMigrationFactory Get-AzNetworkInterface { [pscustomobject]@{ EnableAcceleratedNetworking = $false } }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $plan = [pscustomobject]@{
                schemaVersion = (Get-VmfTestPlanEntryVersion)
                vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/nicvm'
                wave = 'w1'; ring = 'lab'
                assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'; sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; platformManaged = $false; location = 'centralus' }
                target = [pscustomobject]@{ size = 'Standard_D2s_v6'; diskArch = 'diskless'; controller = 'NVMe' }
                path = 'A'
                # DRIFT-11: every v6 size requires accelerated networking, and it is off
                # here, so the plan turns it on as the accepted wave settings do.
                policy = [pscustomobject]@{ onDDataFound = 'proceed'; acceleratedNetworking = 'ensureOn' }
            }
            $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'nic-test'
            New-VmfStateDoc -RunPath $rp -RunId 'nic-test' -VmId $ctx.VmId | Out-Null
            # SAFETY-2 reordered the flow: PRECHECK now proceeds to the pristine
            # safety copy. The intent here is unchanged - it must NOT park.
            (Invoke-VmfStepPrecheck -Context $ctx).Next | Should -Be 'SAFETY_PRISTINE'
        }
    }

    It 'a single-NIC machine is never gated, even when the catalog says nothing' {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @() }
        Mock -ModuleName VmMigrationFactory Get-AzVM { Global:NicVm -Count 1 }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $plan = [pscustomobject]@{
                schemaVersion = (Get-VmfTestPlanEntryVersion)
                vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/nicvm'
                wave = 'w1'; ring = 'lab'
                assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'; sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; platformManaged = $false; location = 'centralus' }
                target = [pscustomobject]@{ size = 'Standard_D2s_v6'; diskArch = 'diskless'; controller = 'NVMe' }
                path = 'A'
                policy = [pscustomobject]@{ onDDataFound = 'proceed' }
            }
            $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'nic-test'
            New-VmfStateDoc -RunPath $rp -RunId 'nic-test' -VmId $ctx.VmId | Out-Null
            # SAFETY-2 reordered the flow: PRECHECK now proceeds to the pristine
            # safety copy. The intent here is unchanged - it must NOT park.
            (Invoke-VmfStepPrecheck -Context $ctx).Next | Should -Be 'SAFETY_PRISTINE'
        }
    }
}

Describe 'NIC-1: validation proves every NIC came back, in order' {
    It 'fails when a NIC is missing after the move' {
        InModuleScope VmMigrationFactory {
            $captured = @(
                [pscustomobject]@{ id = '/n/nic0'; primary = $true }
                [pscustomobject]@{ id = '/n/nic1'; primary = $false }
            )
            $live = @([pscustomobject]@{ id = '/n/nic0'; primary = $true })
            $r = Test-VmfNicFidelity -Captured $captured -Live $live
            $r.Ok | Should -BeFalse
            $r.Detail | Should -Match '2'
            $r.Detail | Should -Match '1'
        }
    }

    It 'fails when the primary NIC moved - guest routing depends on it' {
        InModuleScope VmMigrationFactory {
            $captured = @(
                [pscustomobject]@{ id = '/n/nic0'; primary = $true }
                [pscustomobject]@{ id = '/n/nic1'; primary = $false }
            )
            $live = @(
                [pscustomobject]@{ id = '/n/nic0'; primary = $false }
                [pscustomobject]@{ id = '/n/nic1'; primary = $true }
            )
            (Test-VmfNicFidelity -Captured $captured -Live $live).Ok | Should -BeFalse
        }
    }

    It 'fails when the adapter ORDER changed, even with the same NICs attached' {
        InModuleScope VmMigrationFactory {
            $captured = @(
                [pscustomobject]@{ id = '/n/nic0'; primary = $true }
                [pscustomobject]@{ id = '/n/nic1'; primary = $false }
            )
            $live = @(
                [pscustomobject]@{ id = '/n/nic1'; primary = $false }
                [pscustomobject]@{ id = '/n/nic0'; primary = $true }
            )
            (Test-VmfNicFidelity -Captured $captured -Live $live).Ok | Should -BeFalse
        }
    }

    It 'passes when every NIC came back in the same order with the same primary' {
        InModuleScope VmMigrationFactory {
            $nics = @(
                [pscustomobject]@{ id = '/n/nic0'; primary = $true }
                [pscustomobject]@{ id = '/n/nic1'; primary = $false }
            )
            (Test-VmfNicFidelity -Captured $nics -Live $nics).Ok | Should -BeTrue
        }
    }
}

Describe 'NIC-1: accelerated networking is capped per SIZE, not per NIC' {
    # Found by the NIC-1 drill, from Azure itself: creating a 2-NIC D2s_v4
    # with accelerated networking on both NICs is REFUSED -
    # "VmSizeRestrictedToSingleNicWithAcceleratedNetworkingEnable".
    # The engine's ensureOn policy tried to turn AN on for EVERY captured NIC,
    # which on such a machine is an ARM rejection inside the deallocated
    # window - past the point of no return. ensureOn means the PRIMARY NIC
    # carries accelerated networking (that is what MANA needs); every other
    # NIC keeps exactly what it had.
    BeforeAll {
        function Global:Nic {
            param([string]$Id, [bool]$Primary, $An)
            [pscustomobject]@{ id = $Id; primary = $Primary; acceleratedNetworking = $An }
        }
    }
    AfterAll { Remove-Item 'function:\Nic' -ErrorAction SilentlyContinue }

    It 'ensureOn never tries to enable AN on a secondary NIC that did not have it' {
        InModuleScope VmMigrationFactory {
            $captured = @((Global:Nic '/n/nic0' $true $false), (Global:Nic '/n/nic1' $false $false))
            $changes = @(Get-VmfNicAnPlan -CapturedNics $captured -Policy 'ensureOn')
            @($changes).Count | Should -Be 1 -Because 'only the primary may be switched on'
            $changes[0].id | Should -Be '/n/nic0'
            $changes[0].enabled | Should -BeTrue
        }
    }

    It 'ensureOn leaves a secondary NIC that ALREADY had AN alone' {
        InModuleScope VmMigrationFactory {
            $captured = @((Global:Nic '/n/nic0' $true $true), (Global:Nic '/n/nic1' $false $true))
            @(Get-VmfNicAnPlan -CapturedNics $captured -Policy 'ensureOn').Count | Should -Be 0
        }
    }

    It 'a single-NIC machine still gets AN turned on, primary flag or not' {
        InModuleScope VmMigrationFactory {
            # ARM reports Primary=$false on a single-NIC VM; it is primary anyway
            $captured = @((Global:Nic '/n/only' $false $false))
            $changes = @(Get-VmfNicAnPlan -CapturedNics $captured -Policy 'ensureOn')
            @($changes).Count | Should -Be 1
            $changes[0].id | Should -Be '/n/only'
        }
    }

    It 'preserve changes nothing at all' {
        InModuleScope VmMigrationFactory {
            $captured = @((Global:Nic '/n/nic0' $true $false), (Global:Nic '/n/nic1' $false $true))
            @(Get-VmfNicAnPlan -CapturedNics $captured -Policy 'preserve').Count | Should -Be 0
        }
    }

    It 'OLD-VERSION-READERS-REMOVE-3: any value but ensureOn changes no NIC (ensureOff left the contract at v33)' {
        InModuleScope VmMigrationFactory {
            # The primary is off, so ensureOn would turn it on: any other value changes nothing.
            $captured = @((Global:Nic '/n/nic0' $true $false), (Global:Nic '/n/nic1' $false $true))
            @(Get-VmfNicAnPlan -CapturedNics $captured -Policy 'ensureOn').Count | Should -Be 1
            foreach ($v in 'ensureOff', 'off', 'EnsureOn ') {
                @(Get-VmfNicAnPlan -CapturedNics $captured -Policy $v).Count | Should -Be 0 -Because "'$v' is not ensureOn"
            }
        }
    }

    It 'validation accepts a multi-NIC machine where only the primary has AN' {
        InModuleScope VmMigrationFactory {
            $captured = @((Global:Nic '/n/nic0' $true $true), (Global:Nic '/n/nic1' $false $false))
            $live = @((Global:Nic '/n/nic0' $true $true), (Global:Nic '/n/nic1' $false $false))
            (Test-VmfNicAcceleratedNetworking -Captured $captured -Live $live -Policy 'ensureOn').Ok |
                Should -BeTrue -Because 'Azure will not permit AN on the second NIC of a 2-vCPU size'
        }
    }

    It 'validation still fails when the PRIMARY lost accelerated networking' {
        InModuleScope VmMigrationFactory {
            $captured = @((Global:Nic '/n/nic0' $true $true), (Global:Nic '/n/nic1' $false $false))
            $live = @((Global:Nic '/n/nic0' $true $false), (Global:Nic '/n/nic1' $false $false))
            $r = Test-VmfNicAcceleratedNetworking -Captured $captured -Live $live -Policy 'ensureOn'
            $r.Ok | Should -BeFalse
            $r.Detail | Should -Match '(?i)nic0'
        }
    }

    It 'validation fails when a secondary NIC silently LOST the AN it had' {
        InModuleScope VmMigrationFactory {
            $captured = @((Global:Nic '/n/nic0' $true $true), (Global:Nic '/n/nic1' $false $true))
            $live = @((Global:Nic '/n/nic0' $true $true), (Global:Nic '/n/nic1' $false $false))
            (Test-VmfNicAcceleratedNetworking -Captured $captured -Live $live -Policy 'ensureOn').Ok |
                Should -BeFalse -Because 'losing a capability the machine had is a regression'
        }
    }
}

# The azureops-boundary guard now covers the WHOLE module and lives in
# AssessAndPlan.Tests.ps1 (BOUNDARY-1) - it subsumes the engine-only check
# that was here, so there is one guard rather than two saying the same thing.

Describe 'AVSET-1: PRECHECK says what it knows about the availability set' {
    # Upstream's 2026082514 warning: availability-set members share a cluster,
    # and a conversion can fail while others are still allocated. We serialise
    # one conversion per set, which leaves the others RUNNING.
    #
    # AVSET-NOTE-1 settled WHEN: Microsoft's resize page makes it conditional on
    # the set's current hardware not offering the new size. The note used to
    # warn every member of every set, and warned against the product's own
    # one-at-a-time strategy. Now the engine asks the set's available sizes and
    # the note - a pure function - says only what that answer supports. It
    # still ADVISES rather than parks: silence is what is not acceptable,
    # because a failure lands inside the stopped window.
    BeforeAll {
        $script:smSrc = Get-Content (Join-Path ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))) 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1') -Raw
        $script:AvsetNote = { param($Offered, [string]$Target = 'Standard_D2ds_v6')
            InModuleScope VmMigrationFactory -Parameters @{ o = $Offered; t = $Target } {
                Get-VmfAvailabilitySetNote -Others 1 -Names 'vm-b' -Running 1 -TargetSize $t -OfferedSizes $o
            }
        }
    }

    It 'asks who else is in the set, and which sizes its hardware offers' {
        $script:smSrc | Should -Match 'Get-VmfAvailabilitySetMembers'
        $script:smSrc | Should -Match "Invoke-VmfAzOperation -Name 'avsetMembers'"
        $script:smSrc | Should -Match "Invoke-VmfAzOperation -Name 'avsetSizes'"
        $script:smSrc | Should -Match 'Get-VmfAvailabilitySetNote -Others \$others\.Count'
        $script:smSrc | Should -Match '-Outcome \$avsetNote\.Outcome'
        # A lookup that failed is UNKNOWN. An empty list would read as "the
        # hardware offers nothing", which is a claim nobody measured.
        $script:smSrc | Should -Match 'catch \{ \$offered = \$null \}'
    }

    It 'advises rather than parking, except when Azure is definite on both (AVSET-NOT-OFFERED-STOP-1)' {
        # The one stop in the availability set block is the note's own 'stop'
        # outcome; AvsetNotOfferedStop.Tests.ps1 tests when the note gives it.
        $block = [regex]::Match($script:smSrc, "(?s)Invoke-VmfAzOperation -Name 'avsetMembers'.*?-Outcome \`$avsetNote\.Outcome").Value
        $block | Should -Not -BeNullOrEmpty
        @([regex]::Matches($block, "Next = 'NEEDS_DECISION'")).Count | Should -Be 1
        $block | Should -Match "(?s)if \(\`$avsetNote\.Outcome -eq 'stop'\) \{\s*return @\{ Next = 'NEEDS_DECISION'; Reason = 'availabilitySetSizeNotOffered'"
    }

    It 'counts a machine it could not check as still running, never as stopped' {
        # "Stopped" is the reassuring answer and the one we cannot support. This
        # is the DRIVER-1 rule applied again: unknown is not a pass.
        $script:smSrc | Should -Match '\$_\.Allocated -ne \$false'
    }

    It 'RUN: the size IS offered - no warning, and it says what the product does' {
        # The lab run, 2026-09-23: this is the case that measured fine.
        $n = & $script:AvsetNote @('Standard_D2ds_v6', 'Standard_D4ds_v6')
        $n.Outcome | Should -Be 'info'
        $n.Detail | Should -Match 'shares an availability set with 1 other machine: vm-b'
        $n.Detail | Should -Match 'move one at a time and the others keep running'
        $n.Detail | Should -Not -Match 'until every machine in the set is stopped' -Because 'that is not true here'
    }

    It 'RUN: the size is NOT offered - a warning, with the count still running' {
        $n = & $script:AvsetNote @('Standard_D2s_v4')
        $n.Outcome | Should -Be 'warn'
        $n.Detail | Should -Match 'does not offer Standard_D2ds_v6'
        $n.Detail | Should -Match 'until every machine in the set is stopped, and 1 of them'
    }

    It 'RUN: Azure could not be asked - it says so, and does not guess either way' {
        $n = & $script:AvsetNote $null
        $n.Outcome | Should -Be 'warn'
        $n.Detail | Should -Match 'Azure did not say'
        $n.Detail | Should -Match '^This machine shares' -Because 'the note still names the set'
    }

    It 'RUN: an empty list is an answer, not unknown' {
        (& $script:AvsetNote @(, @())).Detail | Should -Match 'does not offer'
    }

    It 'the probe reports unknown power state as unknown' {
        $ops = Get-Content (Join-Path ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))) 'src' 'VmMigrationFactory' 'Private' 'azureops' 'AzureOpsVm.ps1') -Raw
        $ops | Should -Match '\$allocated = \$null'
        $ops | Should -Match 'must never be reported as "stopped"'
    }
}

Describe 'AVSET-1: the planner keeps a set together' {
    It 'members of one availability set never straddle waves, even above the size cap' {
        # Already true (WAVE-1), and load-bearing for AVSET-1: whatever the rule
        # turns out to be, a set split across waves could never satisfy it.
        InModuleScope VmMigrationFactory {
            $entries = @(
                [pscustomobject]@{ vmId = '/vm/a'; ring = 'prod'; appGroup = 'x'; resourceGroup = 'rg'; availabilitySetId = '/avs/1' },
                [pscustomobject]@{ vmId = '/vm/b'; ring = 'prod'; appGroup = 'y'; resourceGroup = 'rg2'; availabilitySetId = '/avs/1' },
                [pscustomobject]@{ vmId = '/vm/c'; ring = 'prod'; appGroup = 'z'; resourceGroup = 'rg3'; availabilitySetId = '/avs/1' }
            )
            $a = Get-VmfWaveAssignments -Entries $entries -Strategy 'tags'
            @($a['/vm/a'], $a['/vm/b'], $a['/vm/c']) | Select-Object -Unique | Should -HaveCount 1
        }
    }
}
