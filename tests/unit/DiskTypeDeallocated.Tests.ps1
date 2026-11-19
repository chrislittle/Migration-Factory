#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# DISK-TYPE-DEALLOCATED-1: a machine that is DEALLOCATED when its move starts.
#
# MEASURED in the lab, 2026-11-05: for a deallocated machine, Azure's model of
# the machine gives each disk's managedDisk with ONLY its id - no
# storageAccountType - and no diskSizeGB on any disk (az vm show, Get-AzVM and
# four REST api versions all agree). The same machine read while running gave
# StandardSSD_LRS. The disk resource always has sku.name and diskSizeGB.
# The capture recorded an empty type for every disk, and the first disk made
# for the way back went to Azure with no sku: "Required property 'name' not
# found in 'sku'" - the same refusal UX-STUCK-1 fixed by recording the type at
# capture, which is exactly the read that comes back empty here.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    . (Join-Path $PSScriptRoot '_RecordShape.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # CLUSTER-DETECT-1: the cluster check at Checking is not under test here.
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }
    # PRECHECK-WORKLOAD-1: Checking reads the maxShares of each data disk; none is shared here.
    Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { 1 }
    Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { throw "TEST-1: Invoke-AzRestMethod reached the real Azure ($Method $Path). Mock the azureops function." }
    Mock -ModuleName VmMigrationFactory Start-Sleep { }

    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute'
    $script:vmId = "$($script:sub)/virtualMachines/vm1"

    # What each disk resource says, by name: its type and its size. Every
    # disk differs, so a value read for the wrong disk shows.
    function Global:DtdTruth {
        @{ 'vm1-osdisk' = @('StandardSSD_LRS', 64); 'vm1-data0' = @('Premium_LRS', 128); 'vm1-data1' = @('Standard_LRS', 1024)
           'vm1-data2' = @('PremiumV2_LRS', 256) }
    }
    function Global:DtdFacts($DiskId, [hashtable]$Truth) {
        $name = ($DiskId -split '/')[-1]
        $t = if ($Truth.ContainsKey($name)) { $Truth[$name] } else { @($null, $null) }
        [pscustomobject]@{ id = $DiskId; skuName = [string]$t[0]; diskSizeGB = $t[1]; encryptionType = 'EncryptionAtRestWithPlatformKey'
            diskEncryptionSetId = $null; zones = @('1'); maxShares = 1; completionPercent = 100
            diskIOPSReadWrite = 3000; diskMBpsReadWrite = 125; logicalSectorSize = 4096; purchasePlan = $null; provisioningState = 'Succeeded' }
    }
    # The machine as Azure's model gives it. -Deallocated: each disk's
    # managedDisk holds only its id, and no disk has a size - as measured.
    function Global:DtdVm([switch]$Deallocated, [int[]]$Luns = @(0, 1)) {
        $md = { param($name, $type)
            if ($Deallocated) { [pscustomobject]@{ Id = "$($script:sub)/disks/$name" } }
            else { [pscustomobject]@{ Id = "$($script:sub)/disks/$name"; StorageAccountType = $type } } }
        $truth = DtdTruth
        [pscustomobject]@{
            Id = $script:vmId; Name = 'vm1'; ResourceGroupName = 'rg-app'; Location = 'centralus'
            HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_D2s_v4' }
            StorageProfile = [pscustomobject]@{ DiskControllerType = 'SCSI'
                OsDisk = [pscustomobject]@{ OsType = 'Linux'; Name = 'vm1-osdisk'; DeleteOption = 'Delete'; ManagedDisk = (& $md 'vm1-osdisk' 'StandardSSD_LRS') }
                DataDisks = @(foreach ($l in $Luns) {
                        [pscustomobject]@{ Lun = $l; Name = "vm1-data$l"; Caching = 'None'; DeleteOption = 'Detach'
                            DiskSizeGB = $(if ($Deallocated) { $null } else { $truth["vm1-data$l"][1] })
                            ManagedDisk = (& $md "vm1-data$l" $truth["vm1-data$l"][0]) } })
                ImageReference = $null }
            NetworkProfile = [pscustomobject]@{ NetworkInterfaces = @([pscustomobject]@{ Id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Network/networkInterfaces/nic0'; Primary = $true }) }
            Zones = @('1'); Tags = @{}; LicenseType = $null; AvailabilitySetReference = $null; ProximityPlacementGroup = $null
            Priority = $null; Identity = $null; AdditionalCapabilities = $null; DiagnosticsProfile = $null; SecurityProfile = $null
        }
    }
    function Global:DtdCapture($vm) {
        InModuleScope VmMigrationFactory -Parameters @{ vm = $vm } { param($vm) Get-VmfVmCapture -Vm $vm }
    }
}
AfterAll {
    Remove-Item function:DtdTruth, function:DtdFacts, function:DtdVm, function:DtdCapture -ErrorAction SilentlyContinue
}

Describe 'DISK-TYPE-DEALLOCATED-1: the capture reads the type and size of each disk from the disk' {
    BeforeEach {
        $global:dtdReads = [System.Collections.Generic.List[string]]::new()
        $global:dtdTruth = DtdTruth
        Mock -ModuleName VmMigrationFactory Get-AzNetworkInterface { [pscustomobject]@{ EnableAcceleratedNetworking = $true } }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { $global:dtdReads.Add(($DiskId -split '/')[-1]); DtdFacts $DiskId $global:dtdTruth }
    }
    AfterEach { Remove-Variable dtdReads, dtdTruth -Scope Global -ErrorAction SilentlyContinue }

    It 'a DEALLOCATED machine (each managedDisk only an id, no size): the type and size of every disk come from the disk itself, by its id' {
        $cap = DtdCapture (DtdVm -Deallocated)
        $cap.osDisk.skuName | Should -Be 'StandardSSD_LRS'
        @($cap.dataDisks)[0].skuName | Should -Be 'Premium_LRS'
        @($cap.dataDisks)[0].sizeGB | Should -Be 128
        @($cap.dataDisks)[1].skuName | Should -Be 'Standard_LRS'
        @($cap.dataDisks)[1].sizeGB | Should -Be 1024
        @($global:dtdReads) | Should -Be @('vm1-osdisk', 'vm1-data0', 'vm1-data1') -Because 'each disk is read once, by the id the machine records for it'
    }

    It 'a RUNNING machine: the model gives the type and size, and no disk is read' {
        $cap = DtdCapture (DtdVm)
        $cap.osDisk.skuName | Should -Be 'StandardSSD_LRS'
        @($cap.dataDisks)[1].skuName | Should -Be 'Standard_LRS'
        @($cap.dataDisks)[1].sizeGB | Should -Be 1024
        $global:dtdReads.Count | Should -Be 0
    }

    It 'a data disk whose model has its type and no size is read for the size' {
        $vm = DtdVm
        $vm.StorageProfile.DataDisks[0].DiskSizeGB = $null
        $cap = DtdCapture $vm
        @($cap.dataDisks)[0].sizeGB | Should -Be 128
        @($cap.dataDisks)[0].skuName | Should -Be 'Premium_LRS'
        @($global:dtdReads) | Should -Be @('vm1-data0')
    }

    It 'a read that fails leaves the type empty - never a guess - and the capture still completes' {
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { if ($DiskId -match 'data1') { throw 'AuthorizationFailed' }; DtdFacts $DiskId $global:dtdTruth }
        $cap = DtdCapture (DtdVm -Deallocated)
        @($cap.dataDisks)[1].skuName | Should -Be ''
        $null -eq @($cap.dataDisks)[1].sizeGB | Should -BeTrue
        $cap.osDisk.skuName | Should -Be 'StandardSSD_LRS'
    }

    It 'review: a read that fails is kept, by disk id, in -DiskReadErrors - never in the capture' {
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { if ($DiskId -match 'data1') { throw 'AuthorizationFailed: no disks/read' }; DtdFacts $DiskId $global:dtdTruth }
        $errs = @{}
        $cap = InModuleScope VmMigrationFactory -Parameters @{ vm = (DtdVm -Deallocated); errs = $errs } { param($vm, $errs) Get-VmfVmCapture -Vm $vm -DiskReadErrors $errs }
        @($errs.Keys) | Should -Be @("$($script:sub)/disks/vm1-data1")
        $errs["$($script:sub)/disks/vm1-data1"] | Should -Match 'AuthorizationFailed'
        ($cap | ConvertTo-Json -Depth 10) | Should -Not -Match 'AuthorizationFailed'
    }

    It 'a worker that lost its lease stops at once' {
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { throw 'Lease lost - abandon this VM' }
        { DtdCapture (DtdVm -Deallocated) } | Should -Throw '*abandon this VM*'
    }
}

Describe 'DISK-TYPE-DEALLOCATED-1: a disk whose type is not known stops the move before anything changes' {
    It 'names each disk with no type, and the machine is untouched' {
        $cap = [ordered]@{ name = 'vm1'
            osDisk = [ordered]@{ name = 'vm1-osdisk'; managedDiskId = "$($script:sub)/disks/vm1-osdisk"; skuName = '' }
            dataDisks = @(
                [ordered]@{ name = 'vm1-data0'; lun = 0; managedDiskId = "$($script:sub)/disks/vm1-data0"; skuName = 'Premium_LRS'; sizeGB = 128 }
                [ordered]@{ name = 'vm1-data1'; lun = 1; managedDiskId = "$($script:sub)/disks/vm1-data1"; skuName = $null; sizeGB = 1024 }) }
        $r = InModuleScope VmMigrationFactory -Parameters @{ cap = $cap } { param($cap) Get-VmfDiskTypeUnknownStop -Capture $cap }
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'diskTypeNotKnown'
        $r.MachineState | Should -Be 'untouched'
        $r.Detail | Should -Match "the OS disk 'vm1-osdisk'"
        $r.Detail | Should -Match "the data disk 'vm1-data1' on LUN 1"
        $r.Detail | Should -Not -Match 'vm1-data0' -Because 'its type and size are known'
        $r.Detail | Should -Match 'Nothing on the machine changed\.$'
    }

    It 'review: a data disk with its type and NO size stops too - every rebuild attaches it with its size' {
        $cap = [ordered]@{ osDisk = [ordered]@{ name = 'vm1-osdisk'; skuName = 'Premium_LRS' }
            dataDisks = @([ordered]@{ name = 'vm1-data0'; lun = 0; managedDiskId = "$($script:sub)/disks/vm1-data0"; skuName = 'Standard_LRS'; sizeGB = $null }) }
        $r = InModuleScope VmMigrationFactory -Parameters @{ cap = $cap } { param($cap) Get-VmfDiskTypeUnknownStop -Capture $cap }
        $r.Reason | Should -Be 'diskTypeNotKnown'
        $r.MachineState | Should -Be 'untouched'
        $r.Detail | Should -Match "the data disk 'vm1-data0' on LUN 0 has no size \(Azure returned no value\)"
    }

    It 'review: each disk says what Azure said when the read failed, and "returned no value" when it did not fail' {
        $cap = [ordered]@{ osDisk = [ordered]@{ name = 'vm1-osdisk'; managedDiskId = "$($script:sub)/disks/vm1-osdisk"; skuName = '' }
            dataDisks = @([ordered]@{ name = 'vm1-data1'; lun = 1; managedDiskId = "$($script:sub)/disks/vm1-data1"; skuName = ''; sizeGB = $null }) }
        $errs = @{ "$($script:sub)/disks/vm1-osdisk" = 'AuthorizationFailed: no disks/read on <placeholder>' }
        $r = InModuleScope VmMigrationFactory -Parameters @{ cap = $cap; errs = $errs } { param($cap, $errs) Get-VmfDiskTypeUnknownStop -Capture $cap -ReadErrors $errs }
        $r.Detail | Should -Match "the OS disk 'vm1-osdisk' has no disk type \(Azure did not answer the read: AuthorizationFailed: no disks/read on <placeholder>\)"
        $r.Detail | Should -Match "the data disk 'vm1-data1' on LUN 1 has no disk type and no size \(Azure returned no value\)"
    }

    It 'every type known: no stop' {
        $cap = [ordered]@{ osDisk = [ordered]@{ name = 'vm1-osdisk'; skuName = 'Premium_LRS' }
            dataDisks = @([ordered]@{ name = 'vm1-data0'; lun = 0; skuName = 'Standard_LRS'; sizeGB = 0 }) }
        InModuleScope VmMigrationFactory -Parameters @{ cap = $cap } { param($cap) Get-VmfDiskTypeUnknownStop -Capture $cap } | Should -BeNullOrEmpty
    }

    It 'the stop has its words, a machine state and a retry kind' {
        $reasons = (Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json).reasons
        $r = $reasons | Where-Object code -EQ 'diskTypeNotKnown'
        $r | Should -Not -BeNullOrEmpty
        $r.machine | Should -Be 'untouched'
        $r.retry | Should -Be 'afterFix'
    }
}

Describe 'DISK-TYPE-DEALLOCATED-1: no disk is ever made with no type' {
    BeforeEach {
        Mock -ModuleName VmMigrationFactory Get-AzDisk { $null }
        Mock -ModuleName VmMigrationFactory New-AzDiskConfig { [pscustomobject]@{} }
        Mock -ModuleName VmMigrationFactory New-AzDisk { [pscustomobject]@{ Id = "$($script:sub)/disks/made" } }
    }

    It 'New-VmfDiskFromSnapshot refuses an empty type before it asks Azure for anything' {
        { InModuleScope VmMigrationFactory -Parameters @{ sub = $script:sub } { param($sub)
                New-VmfDiskFromSnapshot -ResourceGroupName 'rg-app' -DiskName 'vm1-osdisk-asitwas' -SnapshotId "$sub/snapshots/s1" -Location 'centralus' -SkuName '' } } |
            Should -Throw "*disk 'vm1-osdisk-asitwas': no disk type*"
        Should -Invoke -ModuleName VmMigrationFactory New-AzDisk -Times 0 -Exactly
        Should -Invoke -ModuleName VmMigrationFactory Get-AzDisk -Times 0 -Exactly
    }

    It 'the OS disk for the way back, with no type on record, is never sent to Azure (the lab stop of 2026-11-05)' {
        { InModuleScope VmMigrationFactory -Parameters @{ sub = $script:sub; id = $script:vmId } { param($sub, $id)
                $ctx = [pscustomobject]@{ RunPath = (Join-Path ([System.IO.Path]::GetTempPath()) 'vmf-dtd-nowrite'); VmId = $id }
                New-VmfOsDiskFromCopy -Context $ctx -OpName 'putBack:createDisk' -ResourceGroupName 'rg-app' -DiskName 'vm1-osdisk-asitwas' `
                    -SnapshotId "$sub/snapshots/s1" -Location 'centralus' -SkuName '' -Zone '1' `
                    -Disk ([pscustomobject]@{ name = 'vm1-osdisk'; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null }) } } |
            Should -Throw '*no disk type*'
        Should -Invoke -ModuleName VmMigrationFactory New-AzDisk -Times 0 -Exactly
    }

    It 'a type given is made as before' {
        $id = InModuleScope VmMigrationFactory -Parameters @{ sub = $script:sub } { param($sub)
            New-VmfDiskFromSnapshot -ResourceGroupName 'rg-app' -DiskName 'vm1-osdisk-asitwas' -SnapshotId "$sub/snapshots/s1" -Location 'centralus' -SkuName 'StandardSSD_LRS' }
        $id | Should -Be "$($script:sub)/disks/made"
        Should -Invoke -ModuleName VmMigrationFactory New-AzDiskConfig -Times 1 -Exactly -ParameterFilter { $SkuName -eq 'StandardSSD_LRS' }
    }
}

Describe 'DISK-TYPE-DEALLOCATED-1: through PRECHECK, on a deallocated machine' {
    BeforeAll {
        function Global:DtdPrecheckMocks {
            $writes = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops') -Filter '*.ps1' |
                ForEach-Object { Select-String -Path $_.FullName -Pattern '^function\s+([\w-]+)' | ForEach-Object { $_.Matches[0].Groups[1].Value } } |
                Where-Object { $_ -match '^(Stop|Start|Set|New|Remove|Lock|Unlock|Request)-' -or $_ -eq 'Invoke-VmfRunCommand' })
            foreach ($n in $writes) { Mock -ModuleName VmMigrationFactory -CommandName $n -MockWith { throw 'nothing in Azure may change' } }
            Mock -ModuleName VmMigrationFactory Test-VmfAdeExtension { $false }
            Mock -ModuleName VmMigrationFactory Get-VmfVmResourceLocks { , @() }
            Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { @([pscustomobject]@{ actions = @('*'); notActions = @() }) }
            Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/deallocated' }
            Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions { @() }
            Mock -ModuleName VmMigrationFactory Get-AzNetworkInterface { [pscustomobject]@{ EnableAcceleratedNetworking = $true } }
            # TARGET-CAPABILITY-PRECHECK-1: Checking asks the target size for Premium Storage for the
            # Premium SSD v2 disk - a catalog that does not say would stop the machine.
            Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @([pscustomobject]@{ Name = 'Standard_D2s_v6'; ResourceType = 'virtualMachines'; Restrictions = @()
                        Capabilities = @([pscustomobject]@{ Name = 'PremiumIO'; Value = 'True' }) }) }
            Mock -ModuleName VmMigrationFactory Get-VmfNetworkInterfaceById { [pscustomobject]@{ Id = 'nic0' } }
            Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { $global:dtdLive }
        }
        function Global:DtdRunPrecheck($rp) {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } {
                param($rp, $id)
                Initialize-VmfRun -RunPath $rp -RunId 'dtd' | Out-Null
                $plan = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; wave = 'w1'; ring = 'lab'; path = 'A'
                    assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'; sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'
                        platformManaged = $false; location = 'centralus'; dataDiskCount = 2 }
                    target = [pscustomobject]@{ size = 'Standard_D2s_v6'; diskArch = 'diskless'; controller = 'NVMe'; zone = '1' }
                    policy = [pscustomobject]@{ onDDataFound = 'proceed'; targetGeneration = 'v6'; acceleratedNetworking = 'preserve' } }
                $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'dtd'
                New-VmfStateDoc -RunPath $rp -RunId 'dtd' -VmId $ctx.VmId | Out-Null
                Invoke-VmfStepPrecheck -Context $ctx
            }
        }
        function Global:DtdDoc($rp) { InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id } }
    }
    AfterAll { Remove-Item function:DtdPrecheckMocks, function:DtdRunPrecheck, function:DtdDoc -ErrorAction SilentlyContinue }
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-dtd-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:rp | Out-Null
        $global:dtdReads = [System.Collections.Generic.List[string]]::new()
        $global:dtdTruth = DtdTruth
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { $global:dtdReads.Add(($DiskId -split '/')[-1]); DtdFacts $DiskId $global:dtdTruth }
        DtdPrecheckMocks
    }
    AfterEach {
        if ($script:rp -and (Test-Path $script:rp)) { [System.IO.Directory]::Delete($script:rp, $true) }
        Remove-Variable dtdReads, dtdTruth, dtdLive -Scope Global -ErrorAction SilentlyContinue
    }

    It 'records the real type and size of every disk, in this capture and in the first capture' {
        $global:dtdLive = DtdVm -Deallocated
        $r = DtdRunPrecheck $script:rp
        $r.Next | Should -Be 'SAFETY_PRISTINE' -Because "PRECHECK passes ($($r.Detail))"
        $doc = DtdDoc $script:rp
        $doc.captured.vmConfig.osDisk.skuName | Should -Be 'StandardSSD_LRS'
        @($doc.captured.vmConfig.dataDisks)[0].skuName | Should -Be 'Premium_LRS'
        @($doc.captured.vmConfig.dataDisks)[1].skuName | Should -Be 'Standard_LRS'
        @($doc.captured.vmConfig.dataDisks)[1].sizeGB | Should -Be 1024
        $doc.captured.original.vmConfig.osDisk.skuName | Should -Be 'StandardSSD_LRS' -Because 'a put-back makes the OS disk on the type of the first capture'
    }

    It 'a Premium SSD v2 data disk is known as one, so its IOPS and throughput are recorded for the way back' {
        $global:dtdLive = DtdVm -Deallocated -Luns @(2)
        $r = DtdRunPrecheck $script:rp
        $r.Next | Should -Be 'SAFETY_PRISTINE' -Because "PRECHECK passes ($($r.Detail))"
        $dd = @((DtdDoc $script:rp).captured.vmConfig.dataDisks)[0]
        $dd.skuName | Should -Be 'PremiumV2_LRS'
        $dd.diskIOPSReadWrite | Should -Be 3000 -Because 'Add-VmfInstantAccessDiskFacts reads a disk by the type the capture holds'
    }

    It 'a disk whose type Azure does not return stops PRECHECK, UNTOUCHED, naming the disk' {
        $global:dtdTruth['vm1-osdisk'] = @($null, 64)
        $global:dtdLive = DtdVm -Deallocated
        $r = DtdRunPrecheck $script:rp
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'diskTypeNotKnown'
        $r.MachineState | Should -Be 'untouched'
        $r.Detail | Should -Match "the OS disk 'vm1-osdisk'"
    }

    It 'review: a data disk with its type, no size, and a read Azure refuses stops PRECHECK untouched, with what Azure said' {
        $vm = DtdVm
        $vm.StorageProfile.DataDisks[1].DiskSizeGB = $null
        $global:dtdLive = $vm
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { if ($DiskId -match 'data1') { throw 'AuthorizationFailed: no disks/read' }; DtdFacts $DiskId $global:dtdTruth }
        $r = DtdRunPrecheck $script:rp
        $r.Reason | Should -Be 'diskTypeNotKnown'
        $r.MachineState | Should -Be 'untouched'
        $r.Detail | Should -Match "the data disk 'vm1-data1' on LUN 1 has no size \(Azure did not answer the read: AuthorizationFailed: no disks/read"
    }
}
