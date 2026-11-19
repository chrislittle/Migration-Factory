#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# ROLLBACK-RETRY-CAPTURE-2: a retry is refused when the size a put-back returns
# to can no longer hold the machine.
#
# ROLLBACK-RETRY-CAPTURE-1 keeps the FIRST capture of a machine, and every
# rollback and restore returns the machine to that capture's size - with the
# network interfaces and data disks it has NOW. Between two attempts somebody
# can add an interface or a disk (a retry after Restore this machine). If the first size cannot hold them, Azure
# refuses the put-back, and it does so inside the stopped window: NIC-1
# (MaxNetworkInterfaces, and accelerated networking on one interface only on a
# 2-vCPU size) and DISK-3 (MaxDataDiskCount).
#
# Decided 2026-10-05 as recommended (OWNER-QUESTIONS-1 row 8): PRECHECK
# refuses such a retry, untouched.
#
# What the machine has proven is not asked again: the first capture ran on that
# size with its interfaces and disks, and a machine on that size now holds what
# it has. Only what is more than both is asked of the size catalog, and a limit
# the catalog does not give is "cannot verify" - never "fits".

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    . (Join-Path $PSScriptRoot '_RecordShape.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # CLUSTER-DETECT-1: the cluster check at Checking is not under test here;
    # ClusterDetect.Tests.ps1 and StateMachine.Tests.ps1 test it.
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }
    # LINUX-TEMP-DISK-FILES-1: the temporary disk check at Checking, now asked of a Linux
    # machine too, is not under test here; LinuxTempDiskFiles.Tests.ps1 tests it.
    Mock -ModuleName VmMigrationFactory Get-VmfTempDiskContentStop { $null }
    # PRECHECK-WORKLOAD-1: Checking reads the maxShares of each data disk; none is shared here.
    Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { 1 }

    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers'
    $script:vmId = "$($script:sub)/Microsoft.Compute/virtualMachines/vm1"

    function Global:PbNicId([int]$i) { "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Network/networkInterfaces/nic$i" }
    # A capture as Get-VmfVmCapture writes it. -An gives each interface its
    # accelerated networking reading, in order; $null is "could not be read".
    function Global:PbCapture([string]$Size, [int]$Nics = 1, [int]$Disks = 0, [object[]]$An = @()) {
        [ordered]@{
            name = 'vm1'; size = $Size; controller = 'SCSI'; location = 'centralus'; osType = 'Linux'; zones = @()
            osDisk = [ordered]@{ name = 'vm1-os'; skuName = 'Premium_LRS' }
            dataDisks = @(for ($d = 0; $d -lt $Disks; $d++) { [ordered]@{ name = "vm1-data$d"; lun = $d; skuName = 'Premium_LRS' } })
            nics = @(for ($i = 0; $i -lt $Nics; $i++) {
                $value = if ($i -lt $An.Count) { $An[$i] } else { $true }
                [ordered]@{ id = (Global:PbNicId $i); primary = ($i -eq 0); acceleratedNetworking = $value }
            })
        }
    }
    # A state document whose first capture is -First. -Touched adds the record
    # of a restore, so the product has touched the machine.
    function Global:PbDoc($First, [switch]$Touched) {
        $doc = [ordered]@{ vmId = $script:vmId; state = 'PRECHECK'; history = @()
            captured = [ordered]@{ vmConfig = $First; original = [ordered]@{ vmConfig = $First; extensions = @(); sourceAcceleratedNetworking = $true } } }
        if ($Touched) { $doc.restore = [ordered]@{ restoredUtc = '2026-10-08T10:00:00Z' } }
        $doc
    }
    # One catalog row. A capability left out is one the catalog does not give.
    function Global:PbSku([string]$Name, $MaxNics = 2, $MaxDisks = 4, $Vcpus = 2, $Available = $null, $TakesAn = 'True') {
        $caps = @()
        if ($null -ne $MaxNics) { $caps += [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = [string]$MaxNics } }
        if ($null -ne $MaxDisks) { $caps += [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = [string]$MaxDisks } }
        if ($null -ne $Vcpus) { $caps += [pscustomobject]@{ Name = 'vCPUs'; Value = [string]$Vcpus } }
        if ($null -ne $Available) { $caps += [pscustomobject]@{ Name = 'vCPUsAvailable'; Value = [string]$Available } }
        if ($null -ne $TakesAn) { $caps += [pscustomobject]@{ Name = 'AcceleratedNetworkingEnabled'; Value = [string]$TakesAn } }
        $caps += [pscustomobject]@{ Name = 'MemoryGB'; Value = '8' }
        $caps += [pscustomobject]@{ Name = 'HyperVGenerations'; Value = 'V1,V2' }
        [pscustomobject]@{ Name = $Name; ResourceType = 'virtualMachines'; Restrictions = @(); Capabilities = $caps }
    }
    function Global:PbJudge($Doc, $Capture, $Sku) {
        InModuleScope VmMigrationFactory -Parameters @{ d = $Doc; c = $Capture; s = $Sku } {
            param($d, $c, $s)
            $q = Get-VmfPutBackFitQuestion -Doc $d -Capture $c
            if (-not $q) { return $null }
            Get-VmfPutBackFitRefusal -Question $q -SkuEntry $s
        }
    }
}

Describe 'ROLLBACK-RETRY-CAPTURE-2: what is asked of the first size' {
    It 'a machine the product never touched is not asked: its first capture is the machine as it is' {
        $doc = Global:PbDoc (Global:PbCapture 'Standard_D2ds_v4' -Nics 1)
        InModuleScope VmMigrationFactory -Parameters @{ d = $doc; c = (Global:PbCapture 'Standard_D2ds_v6' -Nics 3 -Disks 9) } {
            param($d, $c)
            Get-VmfPutBackFitQuestion -Doc $d -Capture $c | Should -BeNullOrEmpty
        }
    }

    It 'OLD-VERSION-READERS-REMOVE-4: a touched machine with no first capture is not asked about its one capture - PRECHECK refuses it' {
        $doc = [ordered]@{ vmId = $script:vmId; history = @(); rollback = [ordered]@{ rolledBackUtc = '2026-10-01T00:00:00Z' }
            captured = [ordered]@{ vmConfig = (Global:PbCapture 'Standard_D2ds_v4') } }
        InModuleScope VmMigrationFactory -Parameters @{ d = $doc; c = (Global:PbCapture 'Standard_D2ds_v6' -Nics 3) } {
            param($d, $c)
            Get-VmfPutBackFitQuestion -Doc $d -Capture $c | Should -BeNullOrEmpty -Because 'the size it would ask about is this attempt''s, never the first'
            { New-VmfOriginalCaptureRecord -Doc $d -Capture $c } | Should -Throw '*holds no first capture*'
        }
    }

    It 'no more interfaces or disks than the first capture had: nothing to ask, the size held them' {
        $doc = Global:PbDoc (Global:PbCapture 'Standard_D2ds_v4' -Nics 3 -Disks 4) -Touched
        InModuleScope VmMigrationFactory -Parameters @{ d = $doc; c = (Global:PbCapture 'Standard_D2ds_v6' -Nics 3 -Disks 2) } {
            param($d, $c)
            Get-VmfPutBackFitQuestion -Doc $d -Capture $c | Should -BeNullOrEmpty
        }
    }

    It 'a machine on its first size now: nothing to ask, Azure holds what it has' {
        # A retry after a rollback: the machine is back on its first size, and
        # an interface added since is one that size already holds.
        $doc = Global:PbDoc (Global:PbCapture 'Standard_D2ds_v4' -Nics 1) -Touched
        InModuleScope VmMigrationFactory -Parameters @{ d = $doc; c = (Global:PbCapture 'standard_d2ds_v4' -Nics 3 -Disks 6) } {
            param($d, $c)
            Get-VmfPutBackFitQuestion -Doc $d -Capture $c | Should -BeNullOrEmpty
        }
    }

    It 'more interfaces than the first capture, on another size: the first size is asked' {
        $doc = Global:PbDoc (Global:PbCapture 'Standard_D2ds_v4' -Nics 1) -Touched
        InModuleScope VmMigrationFactory -Parameters @{ d = $doc; c = (Global:PbCapture 'Standard_D2ds_v6' -Nics 3) } {
            param($d, $c)
            $q = Get-VmfPutBackFitQuestion -Doc $d -Capture $c
            $q.Size | Should -Be 'Standard_D2ds_v4'
            $q.NicsAsk | Should -BeTrue
            $q.NicsNow | Should -Be 3
            $q.DisksAsk | Should -BeFalse
        }
    }
}

Describe 'ROLLBACK-RETRY-CAPTURE-2: the answer' {
    BeforeAll {
        $script:first = Global:PbCapture 'Standard_D2ds_v4' -Nics 1 -Disks 2
        $script:doc = Global:PbDoc $script:first -Touched
    }

    It '<Case>' -ForEach @(
        @{ Case = 'interfaces: the first size holds fewer - refused'; Nics = 3; Disks = 2; Sku = @{ MaxNics = 2 }; Reason = 'putBackSizeTooSmall'; Says = 'holds 2 network interfaces, and the machine has 3' }
        @{ Case = 'interfaces: the first size holds them - goes on'; Nics = 3; Disks = 2; Sku = @{ MaxNics = 4; Vcpus = 4 }; Reason = $null }
        @{ Case = 'interfaces: the catalog gives no limit - cannot verify'; Nics = 3; Disks = 2; Sku = @{ MaxNics = $null; Vcpus = 4 }; Reason = 'putBackSizeUnknown'; Says = 'how many network interfaces Standard_D2ds_v4 holds' }
        @{ Case = 'data disks: the first size holds fewer - refused'; Nics = 1; Disks = 5; Sku = @{ MaxDisks = 4 }; Reason = 'putBackSizeTooSmall'; Says = 'holds 4 data disks, and the machine has 5' }
        @{ Case = 'data disks: the first size holds them - goes on'; Nics = 1; Disks = 5; Sku = @{ MaxDisks = 8 }; Reason = $null }
        @{ Case = 'data disks: the catalog gives no limit - cannot verify'; Nics = 1; Disks = 5; Sku = @{ MaxDisks = $null }; Reason = 'putBackSizeUnknown'; Says = 'how many data disks Standard_D2ds_v4 holds' }
    ) {
        $skuArgs = @{ Name = 'Standard_D2ds_v4' } + $Sku
        $r = Global:PbJudge $script:doc (Global:PbCapture 'Standard_D2ds_v6' -Nics $Nics -Disks $Disks) (Global:PbSku @skuArgs)
        if (-not $Reason) { $r | Should -BeNullOrEmpty; return }
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be $Reason
        $r.Detail | Should -Match ([regex]::Escape($Says))
        $r.Detail | Should -Match 'Standard_D2ds_v4'
        $r.Detail | Should -Match 'Nothing on the machine changed'
    }

    It 'a size the catalog does not list is cannot verify, never a fit' {
        $r = Global:PbJudge $script:doc (Global:PbCapture 'Standard_D2ds_v6' -Nics 3 -Disks 2) $null
        $r.Reason | Should -Be 'putBackSizeUnknown'
    }

    It 'both too few interfaces and too few disks are named in one stop' {
        $r = Global:PbJudge $script:doc (Global:PbCapture 'Standard_D2ds_v6' -Nics 3 -Disks 5) (Global:PbSku 'Standard_D2ds_v4' -MaxNics 2 -MaxDisks 4)
        $r.Reason | Should -Be 'putBackSizeTooSmall'
        $r.Detail | Should -Match 'network interfaces'
        $r.Detail | Should -Match 'data disks'
    }

    It 'a limit that is known to be too small wins over one that is not known' {
        $r = Global:PbJudge $script:doc (Global:PbCapture 'Standard_D2ds_v6' -Nics 3 -Disks 5) (Global:PbSku 'Standard_D2ds_v4' -MaxNics 2 -MaxDisks $null)
        $r.Reason | Should -Be 'putBackSizeTooSmall'
    }
}

Describe 'ROLLBACK-RETRY-CAPTURE-2: accelerated networking on the first size (NIC-1)' {
    It '<Case>' -ForEach @(
        @{ Case = 'a 2-vCPU size, a second interface with it on - refused'; Then = @($true, $false); Now = @($true, $true); Sku = @{ Vcpus = 2 }; Reason = 'putBackSizeTooSmall'; Says = 'on one network interface only' }
        @{ Case = 'a 4-vCPU size, a second interface with it on - goes on'; Then = @($true, $false); Now = @($true, $true); Sku = @{ Vcpus = 4 }; Reason = $null }
        @{ Case = 'a 2-vCPU size, still one interface with it on - goes on'; Then = @($true, $false); Now = @($true, $false); Sku = @{ Vcpus = 2 }; Reason = $null }
        @{ Case = 'the catalog gives no vCPUs - cannot verify'; Then = @($true, $false); Now = @($true, $true); Sku = @{ Vcpus = $null }; Reason = 'putBackSizeUnknown'; Says = 'vCPUs' }
        @{ Case = 'a constrained size with 2 active vCPUs - cannot verify'; Then = @($true, $false); Now = @($true, $true); Sku = @{ Vcpus = 4; Available = 2 }; Reason = 'putBackSizeUnknown'; Says = 'active vCPUs' }
        @{ Case = 'a 2-vCPU size, the second interface could not be read - cannot verify'; Then = @($true, $false); Now = @($true, $null); Sku = @{ Vcpus = 2 }; Reason = 'putBackSizeUnknown'; Says = 'accelerated networking' }
    ) {
        $doc = Global:PbDoc (Global:PbCapture 'Standard_D2ds_v4' -Nics 2 -An $Then) -Touched
        $skuArgs = @{ Name = 'Standard_D2ds_v4'; MaxNics = 4 } + $Sku
        $r = Global:PbJudge $doc (Global:PbCapture 'Standard_D2ds_v6' -Nics 2 -An $Now) (Global:PbSku @skuArgs)
        if (-not $Reason) { $r | Should -BeNullOrEmpty; return }
        $r.Reason | Should -Be $Reason
        $r.Detail | Should -Match ([regex]::Escape($Says))
    }

    It 'the move turns it on for the primary interface: Path A counts it, because the size goes back first' {
        # Review finding 1. The first size held two interfaces with it off; a
        # person turned it on for the second between the attempts.
        $doc = Global:PbDoc (Global:PbCapture 'Standard_D2ds_v4' -Nics 2 -An @($false, $false)) -Touched
        $now = Global:PbCapture 'Standard_D2ds_v6' -Nics 2 -An @($false, $true)
        InModuleScope VmMigrationFactory -Parameters @{ d = $doc; c = $now; s = (Global:PbSku 'Standard_D2ds_v4' -MaxNics 4 -Vcpus 2) } {
            param($d, $c, $s)
            $q = Get-VmfPutBackFitQuestion -Doc $d -Capture $c -PrimaryOnAfter $true
            (Get-VmfPutBackFitRefusal -Question $q -SkuEntry $s).Reason | Should -Be 'putBackSizeTooSmall'
            # The move leaves the primary interface off: one interface has it.
            $q = Get-VmfPutBackFitQuestion -Doc $d -Capture $c -PrimaryOnAfter $false
            if ($q) { Get-VmfPutBackFitRefusal -Question $q -SkuEntry $s | Should -BeNullOrEmpty }
        }
    }

    # REBUILD-REMOVE-ENGINE-1: there is no Path B rollback, so no question has a Path B variant.
    It 'on its first size now, an interface Azure could not read is not asked about: Azure holds the machine as it is' {
        # Review finding 5: a plain retry after a rollback.
        $doc = Global:PbDoc (Global:PbCapture 'Standard_D2ds_v4' -Nics 2 -An @($true, $false)) -Touched
        $now = Global:PbCapture 'Standard_D2ds_v4' -Nics 2 -An @($true, $null)
        InModuleScope VmMigrationFactory -Parameters @{ d = $doc; c = $now } {
            param($d, $c)
            Get-VmfPutBackFitQuestion -Doc $d -Capture $c -PrimaryOnAfter $true | Should -BeNullOrEmpty
        }
    }

    It 'a size that takes no accelerated networking, and an interface the first capture never saw has it on - refused' {
        # OLD-FAM-1: every way back turns it off on the interfaces the first
        # capture knew. An interface that was replaced keeps what it has, and
        # Azure refuses the size with it.
        $then = Global:PbCapture 'Standard_B2s' -Nics 1 -An @($false)
        $now = Global:PbCapture 'Standard_D2ds_v6' -Nics 1 -An @($true)
        $now.nics[0].id = (Global:PbNicId 7)
        $r = Global:PbJudge (Global:PbDoc $then -Touched) $now (Global:PbSku 'Standard_B2s' -MaxNics 3 -TakesAn 'False')
        $r.Reason | Should -Be 'putBackSizeTooSmall'
        $r.Detail | Should -Match 'does not take accelerated networking'
    }

    It 'a size that takes none, and the interface the first capture knew is on after the move - goes on: every way back turns it off first' {
        $then = Global:PbCapture 'Standard_B2s' -Nics 1 -An @($false)
        $now = Global:PbCapture 'Standard_D2ds_v6' -Nics 1 -An @($true)
        Global:PbJudge (Global:PbDoc $then -Touched) $now (Global:PbSku 'Standard_B2s' -MaxNics 3 -TakesAn 'False') | Should -BeNullOrEmpty
    }
}

Describe 'ROLLBACK-RETRY-CAPTURE-2: PRECHECK refuses the retry untouched' {
    BeforeAll {
        function Global:PbVm([string]$Size, [int]$Nics, [int]$Disks = 0) {
            [pscustomobject]@{
                Id = $script:vmId; Name = 'vm1'; ResourceGroupName = 'rg-app'; Location = 'centralus'
                HardwareProfile = [pscustomobject]@{ VmSize = $Size }
                StorageProfile = [pscustomobject]@{
                    DiskControllerType = 'NVMe'
                    OsDisk = [pscustomobject]@{ OsType = 'Linux'; Name = 'vm1-os'; DeleteOption = 'Delete'
                        ManagedDisk = [pscustomobject]@{ Id = "$($script:sub)/Microsoft.Compute/disks/vm1-os"; StorageAccountType = 'Premium_LRS' } }
                    DataDisks = @(for ($d = 0; $d -lt $Disks; $d++) {
                        [pscustomobject]@{ Name = "vm1-data$d"; Lun = $d; Caching = 'None'; DiskSizeGB = 32; DeleteOption = 'Detach'
                            ManagedDisk = [pscustomobject]@{ Id = "$($script:sub)/Microsoft.Compute/disks/vm1-data$d"; StorageAccountType = 'Premium_LRS' } } })
                    ImageReference = $null
                }
                NetworkProfile = [pscustomobject]@{ NetworkInterfaces = @(for ($i = 0; $i -lt $Nics; $i++) { [pscustomobject]@{ Id = (Global:PbNicId $i); Primary = ($i -eq 0) } }) }
                Zones = @(); Tags = @{}
                LicenseType = $null; AvailabilitySetReference = $null; ProximityPlacementGroup = $null
                Priority = $null; Identity = $null; AdditionalCapabilities = $null; DiagnosticsProfile = $null
            }
        }
        function Global:PbPlanEntry {
            [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vmId; wave = 'w1'; ring = 'lab'; path = 'A'
                assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'; sourceSize = 'Standard_D2ds_v4'; sourceDiskArch = 'scsi-temp'; platformManaged = $false; location = 'centralus' }
                target = [pscustomobject]@{ size = 'Standard_D2ds_v6'; diskArch = 'nvme-temp'; controller = 'NVMe'; zone = $null }
                policy = [pscustomobject]@{ onDDataFound = 'proceed' } }
        }
        Mock -ModuleName VmMigrationFactory Get-VmfEngineSubscriptionId { '00000000-0000-0000-0000-000000000000' }
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { 'previous-context' }
    }
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-pbf-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Initialize-VmfRun -RunPath $rp -RunId 'pbf' | Out-Null }
        $Global:PbLiveVm = Global:PbVm 'Standard_D2ds_v6' 3
        $Global:PbFirstMaxNics = 2
        $Global:PbFirstVcpus = 4
        $Global:PbFirstAn = @($true)
        Mock -ModuleName VmMigrationFactory Test-VmfAdeExtension { $false }
        # SAFETY-CMK-1: PRECHECK reads each disk's encryption by its id.
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }
        Mock -ModuleName VmMigrationFactory Get-VmfVmResourceLocks { , @() }
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { @([pscustomobject]@{ actions = @('*'); notActions = @() }) }
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/running' }
        Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions { @() }
        Mock -ModuleName VmMigrationFactory Get-AzNetworkInterface { [pscustomobject]@{ EnableAcceleratedNetworking = $true } }
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { $Global:PbLiveVm }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
            Global:PbSku 'Standard_D2ds_v6' -MaxNics 4 -MaxDisks 8 -Vcpus 4
            Global:PbSku 'Standard_D2ds_v4' -MaxNics $Global:PbFirstMaxNics -MaxDisks 4 -Vcpus $Global:PbFirstVcpus
        }
        # Nothing may change the machine: every one of these is a write.
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { throw 'the machine must not be stopped' }
        Mock -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot { throw 'no safety copy may be taken' }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { throw 'no interface may be changed' }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { throw 'the size must not be changed' }
    }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

    # The case of row 8: moved once, restored, an interface
    # added, then a retry. Its first capture was one interface on D2ds_v4.
    function Global:PbRetry([switch]$Untouched) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; plan = (Global:PbPlanEntry); first = (Global:PbCapture 'Standard_D2ds_v4' -Nics @($Global:PbFirstAn).Count -An $Global:PbFirstAn); untouched = [bool]$Untouched } {
            param($rp, $plan, $first, $untouched)
            $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'pbf'
            if (-not (Read-VmfStateDoc -RunPath $rp -VmId $ctx.VmId)) { New-VmfStateDoc -RunPath $rp -RunId 'pbf' -VmId $ctx.VmId | Out-Null }
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $ctx.VmId
            if (-not ($doc.PSObject.Properties['captured'] -and $doc.captured)) {
                Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = $first; original = [ordered]@{ vmConfig = $first; extensions = @(); sourceAcceleratedNetworking = $true; capturedUtc = '2026-10-07T09:00:00Z' } }
                $doc = Read-VmfStateDoc -RunPath $rp -VmId $ctx.VmId
                if (-not $untouched) {
                    $doc | Add-Member -NotePropertyName restore -Force -NotePropertyValue ([pscustomobject]@{ restoredUtc = '2026-10-08T10:00:00Z' })
                    $null = Complete-VmfTestCapture $doc
                    Write-VmfStateDoc -RunPath $rp -Document $doc
                }
            }
            Invoke-VmfStepPrecheck -Context $ctx
        }
    }

    It 'an interface added after the first attempt, more than the first size holds: refused, untouched, and the first capture kept' {
        $r = Global:PbRetry
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'putBackSizeTooSmall'
        $r.Detail | Should -Match 'Standard_D2ds_v4 holds 2 network interfaces, and the machine has 3'
        # Review finding 3: a hashtable has no PSObject property for its keys.
        $r.ContainsKey('MachineState') | Should -BeFalse -Because 'PRECHECK changes nothing, so the runner records untouched'
        $kept = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id) (Read-VmfStateDoc -RunPath $rp -VmId $id).captured.original.vmConfig }
        $kept.size | Should -Be 'Standard_D2ds_v4'
        @($kept.nics).Count | Should -Be 1
        Should -Invoke Stop-VmfVmDeallocated -ModuleName VmMigrationFactory -Times 0 -Exactly
        Should -Invoke Set-VmfNicAcceleratedNetworking -ModuleName VmMigrationFactory -Times 0 -Exactly
        Should -Invoke Set-VmfVmSizeAndController -ModuleName VmMigrationFactory -Times 0 -Exactly
    }

    It 'the first size holds them: the retry goes on' {
        $Global:PbFirstMaxNics = 4
        (Global:PbRetry).Next | Should -Be 'SAFETY_PRISTINE'
    }

    It 'the catalog gives no interface limit for the first size: refused as cannot verify' {
        $Global:PbFirstMaxNics = $null
        $r = Global:PbRetry
        $r.Reason | Should -Be 'putBackSizeUnknown'
        $r.Detail | Should -Match 'Nothing on the machine changed'
    }

    It 'data disks added after the first attempt, more than the first size holds: refused' {
        $Global:PbLiveVm = Global:PbVm 'Standard_D2ds_v6' 1 -Disks 6
        $r = Global:PbRetry
        $r.Reason | Should -Be 'putBackSizeTooSmall'
        $r.Detail | Should -Match 'holds 4 data disks, and the machine has 6'
    }

    It 'the person removes the added interface, and the retry goes on - the stop is one a person can correct' {
        (Global:PbRetry).Reason | Should -Be 'putBackSizeTooSmall'
        $Global:PbLiveVm = Global:PbVm 'Standard_D2ds_v6' 2
        (Global:PbRetry).Next | Should -Be 'SAFETY_PRISTINE'
    }

    It 'a first attempt is not asked - the machine as it is is the size a put-back returns to' {
        # Review finding 2: on another size than the stored capture, with more
        # interfaces than D2ds_v4 holds, so only the untouched rule keeps it going.
        $Global:PbLiveVm = Global:PbVm 'Standard_D2ds_v6' 3
        $Global:PbFirstMaxNics = 2
        (Global:PbRetry -Untouched).Next | Should -Be 'SAFETY_PRISTINE'
    }

    It 'the move turns accelerated networking on for the primary interface, and a second interface has it: refused on a 2-vCPU first size' {
        # Review finding 1: a Path A rollback changes the size back while the
        # interfaces are as the move left them, and the move turns it on for
        # the primary interface (ensureOn, the default for this plan).
        $Global:PbFirstVcpus = 2
        $Global:PbFirstAn = @($false, $false)
        $Global:PbLiveVm = Global:PbVm 'Standard_D2ds_v6' 2
        Mock -ModuleName VmMigrationFactory Get-AzNetworkInterface { [pscustomobject]@{ EnableAcceleratedNetworking = ($Name -ne 'nic0') } }
        $r = Global:PbRetry
        $r.Reason | Should -Be 'putBackSizeTooSmall'
        $r.Detail | Should -Match 'on one network interface only, and 2 interfaces have it'
    }
}

Describe 'ROLLBACK-RETRY-CAPTURE-2: the two stops have guidance' {
    BeforeAll {
        $script:table = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json
    }
    It '<Code> leaves the machine untouched, and a person can correct it' -ForEach @(
        @{ Code = 'putBackSizeTooSmall' }
        @{ Code = 'putBackSizeUnknown' }
    ) {
        $r = @($script:table.reasons | Where-Object code -eq $Code)
        $r.Count | Should -Be 1
        $r[0].machine | Should -Be 'untouched'
        $r[0].retry | Should -Be 'afterFix'
        $r[0].whatToDo | Should -Match 'network interfaces or data disks'
    }
}
