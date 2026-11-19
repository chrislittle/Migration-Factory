#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# AN-ONE-NIC-2 counted ONE interface with accelerated networking after the move
# for a Linux machine whose running release has no MANA driver, because the
# move kept its primary interface off (AN-KEEP-1), and so offered it a 2-vCPU
# size and let Checking pass it.
#
# AN-MANA-DRIVER-RULE-1 (2026-11-06) removed the keep-off: measured on
# 2026-11-06, with the setting off Azure still attaches the virtual function on
# a size that can give MANA, so off is not off. Accelerated networking is
# always on there, and such a release is offered no such size at all. So this
# file is rewritten to the rule that replaced it: no size keeps the primary
# off, the count is one count on every size, the targets step and Checking
# count the primary as on, and GUEST_PREP has nothing to ask again.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # CLUSTER-DETECT-1: the cluster check at Checking is not under test here;
    # ClusterDetect.Tests.ps1 and StateMachine.Tests.ps1 test it.
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }

    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers'
    $script:vmId = "$($script:sub)/Microsoft.Compute/virtualMachines/vm1"

    function Global:A2Sku([string]$Name, $Vcpus = 2, $MaxNics = 4, $MemoryGB = 8, $TempMb = '0') {
        $caps = @()
        if ($null -ne $Vcpus) { $caps += [pscustomobject]@{ Name = 'vCPUs'; Value = [string]$Vcpus } }
        $caps += [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = [string]$MaxNics }
        $caps += [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '16' }
        $caps += [pscustomobject]@{ Name = 'MemoryGB'; Value = [string]$MemoryGB }
        $caps += [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = $TempMb }
        $caps += [pscustomobject]@{ Name = 'HyperVGenerations'; Value = 'V1,V2' }
        $caps += [pscustomobject]@{ Name = 'AcceleratedNetworkingEnabled'; Value = 'True' }
        [pscustomobject]@{ Name = $Name; Family = 'standardX'; ResourceType = 'virtualMachines'; Restrictions = @(); Capabilities = $caps }
    }
    function Global:A2Catalog([hashtable]$Override = @{}) {
        $c = @{}
        foreach ($s in @(
                (A2Sku 'Standard_D2s_v4' 2), (A2Sku 'Standard_D4s_v4' 4 -MemoryGB 16),
                (A2Sku 'Standard_D2s_v5' 2), (A2Sku 'Standard_D4s_v5' 4 -MemoryGB 16),
                (A2Sku 'Standard_D2as_v5' 2), (A2Sku 'Standard_D4as_v5' 4 -MemoryGB 16),
                (A2Sku 'Standard_D2s_v7' 2 -MaxNics 2), (A2Sku 'Standard_D4s_v7' 4 -MemoryGB 16))) { $c[$s.Name] = $s }
        foreach ($k in $Override.Keys) { $c[$k] = $Override[$k] }
        $c
    }
    # The release the VM agent reports: 'ubuntu' '18.04' is the measured form
    # (ADVISE-AN-1). -Image puts it on the image only, with no agent reading.
    function Global:A2Release([string]$Release = '18.04', [switch]$Image) {
        $r = [ordered]@{ runningOsName = ''; runningOsVersion = ''; imagePublisher = ''; imageOffer = ''; osVersion = '' }
        if (-not $Release) { return $r }
        if ($Image) { $r.imagePublisher = 'Canonical'; $r.imageOffer = 'UbuntuServer'; $r.osVersion = "$Release-LTS" }
        else { $r.runningOsName = 'ubuntu'; $r.runningOsVersion = $Release }
        $r
    }
    function Global:A2Vm([string]$Size = 'Standard_D2s_v4', [int]$Nics = 2, $AnCount = 1, $PrimaryOn = $false, [string]$Release = '18.04', [switch]$Image, [string]$Os = 'Linux') {
        $o = [ordered]@{
            vmId = $script:vmId; name = 'vm1'; location = 'centralus'; classification = 'ReadyAfterPrep'; gen = 'V2'; os = $Os
            sourceSize = $Size; sourceDiskArch = 'diskless'; sourceTempDisks = 0; diskController = 'SCSI'
            dataDiskCount = 0; nicCount = $Nics; acceleratedNicCount = $AnCount; primaryNicAccelerated = $PrimaryOn
            platformManaged = $false; blockers = @(); prepNeeded = @()
        }
        $rel = Global:A2Release $Release -Image:$Image
        foreach ($k in $rel.Keys) { $o[$k] = $rel[$k] }
        [pscustomobject]$o
    }
}
AfterAll {
    Remove-Item 'function:\A2Sku', 'function:\A2Catalog', 'function:\A2Release', 'function:\A2Vm', 'function:\A2VmLive', 'function:\A2Plan',
        'function:\A2Precheck', 'function:\A2Advise', 'function:\A2ManaCheck' -ErrorAction SilentlyContinue
}

Describe 'AN-MANA-DRIVER-RULE-1: no size keeps the primary interface off for a missing MANA driver' {
    It 'the move never keeps it off, on any target size: <_>' -ForEach @(
        'Standard_D2s_v6', 'Standard_D2as_v6', 'Standard_D2ls_v6', 'Standard_E2s_v6', 'Standard_D2s_v7', 'Standard_D2as_v7', 'Standard_D2ls_v7',
        'Standard_E2s_v7', 'Standard_F2as_v7', 'Standard_D2s_v5', 'Standard_D2as_v5', 'Standard_D2ls_v5', 'Standard_E2as_v5', 'Standard_B2s_v2', 'Standard_Unknown'
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ s = $_ } {
            param($s)
            $nics = @([pscustomobject]@{ id = 'nic0'; primary = $true; acceleratedNetworking = $false }
                      [pscustomobject]@{ id = 'nic1'; primary = $false; acceleratedNetworking = $true })
            $ctrl = if ($s -match '_v5$|^Standard_B') { 'SCSI' } else { 'NVMe' }
            $plan = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = 'x'; assessment = [pscustomobject]@{ os = 'Linux'; gen = 'V2'; sourceSize = 'Standard_D2s_v4' }
                target = [pscustomobject]@{ size = $s; controller = $ctrl }; policy = [pscustomobject]@{} }
            foreach ($d in 'unlisted', 'absent') {
                $r = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry $plan -CapturedNics $nics -ManaDriver $d
                ((-not $r.Stop) -and $r.OnAfter -eq $false) | Should -BeFalse -Because "$s, driver $d"
                $r.Policy | Should -Not -Be 'preserve'
            }
        }
    }
}

Describe 'AN-MANA-DRIVER-RULE-1: how many interfaces have accelerated networking after the move, from the scan' {
    It '<Case>' -ForEach @(
        @{ Case = 'running release with no MANA driver, primary off, second on: two, as for every machine'; Release = '18.04'; Image = $false; Count = 1; Primary = $false; Expected = 2 }
        @{ Case = 'two on now, primary off: three';                                Release = '18.04'; Image = $false; Count = 2; Primary = $false; Expected = 3 }
        @{ Case = 'a release Microsoft lists: the primary is turned on, two';      Release = '22.04'; Image = $false; Count = 1; Primary = $false; Expected = 2 }
        @{ Case = 'the release from the image only: two';                          Release = '18.04'; Image = $true;  Count = 1; Primary = $false; Expected = 2 }
        @{ Case = 'the count was not read: unknown';                               Release = '18.04'; Image = $false; Count = $null; Primary = $false; Expected = $null }
    ) {
        $vm = A2Vm -AnCount $Count -PrimaryOn $Primary -Release $Release -Image:$Image
        InModuleScope VmMigrationFactory -Parameters @{ vm = $vm; e = $Expected } {
            param($vm, $e)
            $n = Get-VmfAcceleratedNicsAfterMove -Assessment $vm
            if ($null -eq $e) { $n | Should -BeNullOrEmpty } else { $n | Should -Be $e }
        }
    }

    It 'the switch that counted fewer is gone' {
        InModuleScope VmMigrationFactory { (Get-Command Get-VmfAcceleratedNicsAfterMove).Parameters.ContainsKey('KeptOffWithoutMana') | Should -BeFalse }
        InModuleScope VmMigrationFactory { (Get-Command Get-VmfTargetSize).Parameters.ContainsKey('AcceleratedNicsAfterKeptOff') | Should -BeFalse }
    }
}

Describe 'AN-MANA-DRIVER-RULE-1: the targets step and the 2-vCPU size' {
    BeforeAll {
        function Global:A2Advise($Vm, [hashtable]$Catalog = (A2Catalog)) {
            $doc = [pscustomobject]@{ schemaVersion = 17; runId = 'scan-1'; vms = @($Vm) }
            InModuleScope VmMigrationFactory -Parameters @{ d = $doc; c = @{ centralus = $Catalog } } {
                param($d, $c)
                Get-VmfTargetAdvice -Assessment $d -CatalogByLocation $c
            }
        }
    }

    It 'no MANA driver possible, two interfaces: no size that can give MANA is offered - never the 2-vCPU v7 size kept off' {
        $m = (A2Advise (A2Vm)).machines[0]
        foreach ($s in 'v5', 'v7') {
            $o = @($m.options | Where-Object option -eq $s)[0]
            # Refused for its MANA driver, or first for its one accelerated
            # interface on 2 vCPUs - never offered with the primary kept off.
            $o.supported | Should -BeFalse -Because $s
            @(@($o.notSupported) | Where-Object { $_ -in @('no-mana-driver', 'one-accelerated-nic') }).Count | Should -BeGreaterThan 0
        }
        $null -eq $m.start.current | Should -BeTrue
    }

    It 'a release Microsoft lists, or one read from the image only, or none: refused on the 2-vCPU size, as before' {
        foreach ($vm in @((A2Vm -Release '22.04'), (A2Vm -Image), (A2Vm -Release ''))) {
            $o = @((A2Advise $vm).machines[0].options | Where-Object option -eq 'v7')[0]
            $o.supported | Should -BeFalse
            @($o.notSupported) | Should -Contain 'one-accelerated-nic'
        }
    }
}


Describe 'AN-MANA-DRIVER-RULE-1: Checking (PRECHECK) counts the primary as on' {
    BeforeAll {
        function Global:A2VmLive([string]$Size, [int]$Nics) {
            [pscustomobject]@{
                Id = $script:vmId; Name = 'vm1'; ResourceGroupName = 'rg-app'; Location = 'centralus'
                HardwareProfile = [pscustomobject]@{ VmSize = $Size }
                StorageProfile = [pscustomobject]@{
                    DiskControllerType = 'SCSI'
                    OsDisk = [pscustomobject]@{ OsType = 'Linux'; Name = 'vm1-os'; DeleteOption = 'Delete'
                        ManagedDisk = [pscustomobject]@{ Id = "$($script:sub)/Microsoft.Compute/disks/vm1-os"; StorageAccountType = 'Premium_LRS' } }
                    DataDisks = @()
                    ImageReference = $null
                }
                NetworkProfile = [pscustomobject]@{ NetworkInterfaces = @(for ($i = 0; $i -lt $Nics; $i++) {
                            [pscustomobject]@{ Id = "$($script:sub)/Microsoft.Network/networkInterfaces/nic$i"; Primary = ($i -eq 0) } }) }
                Zones = @(); Tags = @{}
                LicenseType = $null; AvailabilitySetReference = $null; ProximityPlacementGroup = $null
                Priority = $null; Identity = $null; AdditionalCapabilities = $null; DiagnosticsProfile = $null
            }
        }
        # -AnPolicy, never -Policy (AGENTS.md, section 1, item 5).
        function Global:A2Plan([string]$Release = '18.04', [switch]$Image, $AnPolicy = $null, [string]$Os = 'Linux') {
            # EOL-RELEASE-AN-1: Ubuntu 18.04 is past its standard support, so
            # an approver accepted it - these tests are about accelerated networking.
            $levers = [ordered]@{ onDDataFound = 'proceed'; onReleaseEndOfLife = 'proceed' }
            if ($AnPolicy) { $levers.acceleratedNetworking = $AnPolicy }
            $a = [ordered]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = $Os; sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; platformManaged = $false; location = 'centralus' }
            $rel = Global:A2Release $Release -Image:$Image
            foreach ($k in $rel.Keys) { $a[$k] = $rel[$k] }
            [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vmId; wave = 'w1'; ring = 'lab'; path = 'A'
                assessment = [pscustomobject]$a
                target = [pscustomobject]@{ size = 'Standard_D2s_v7'; diskArch = 'diskless'; controller = 'NVMe'; zone = $null }
                policy = [pscustomobject]$levers }
        }
        function Global:A2Precheck($Plan = (A2Plan)) {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; plan = $Plan } {
                param($rp, $plan)
                $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'a2'
                if (-not (Read-VmfStateDoc -RunPath $rp -VmId $ctx.VmId)) { New-VmfStateDoc -RunPath $rp -RunId 'a2' -VmId $ctx.VmId | Out-Null }
                Invoke-VmfStepPrecheck -Context $ctx
            }
        }
        Mock -ModuleName VmMigrationFactory Get-VmfEngineSubscriptionId { '00000000-0000-0000-0000-000000000000' }
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { 'previous-context' }
    }
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-a2-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Initialize-VmfRun -RunPath $rp -RunId 'a2' | Out-Null }
        $Global:A2Live = Global:A2VmLive 'Standard_D2s_v4' 2
        $Global:A2An = @{ nic0 = $false; nic1 = $true }
        Mock -ModuleName VmMigrationFactory Test-VmfAdeExtension { $false }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }
        Mock -ModuleName VmMigrationFactory Get-VmfVmResourceLocks { , @() }
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { @([pscustomobject]@{ actions = @('*'); notActions = @() }) }
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/deallocated' }
        Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions { @() }
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { $Global:A2Live }
        Mock -ModuleName VmMigrationFactory Get-AzNetworkInterface {
            if (-not $Global:A2An.ContainsKey($Name)) { throw 'not read' }
            [pscustomobject]@{ EnableAcceleratedNetworking = $Global:A2An[$Name] }
        }
        Mock -ModuleName VmMigrationFactory Get-VmfNetworkInterfaceById { [pscustomobject]@{ Id = $NicId; IpConfigurations = @() } }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { Global:A2Sku 'Standard_D2s_v7' 2 -MaxNics 2; Global:A2Sku 'Standard_D2s_v4' 2 -MaxNics 3 }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { throw 'the machine must not be stopped' }
        Mock -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot { throw 'no safety copy may be taken' }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { throw 'no interface may be changed' }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { throw 'the size must not be changed' }
    }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

    # Rewritten: AN-ONE-NIC-2 allowed it (one interface after the move). The
    # primary is turned on now, so two interfaces have it: refused untouched.
    It 'no MANA driver, two interfaces, 2-vCPU target: refused - the primary is turned on too' {
        $r = Global:A2Precheck
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'targetOneAcceleratedNic'
    }

    It 'a driver (a release Microsoft lists): refused as today' {
        $r = Global:A2Precheck (A2Plan -Release '22.04')
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'targetOneAcceleratedNic'
    }

    It 'unknown - the release from the image only: refused as today' {
        (Global:A2Precheck (A2Plan -Image)).Reason | Should -Be 'targetOneAcceleratedNic'
    }

    It 'unknown - no release read: refused as today' {
        (Global:A2Precheck (A2Plan -Release '')).Reason | Should -Be 'targetOneAcceleratedNic'
    }

    It 'a wave that asks for accelerated networking (ensureOn): the primary has it, so refused' {
        (Global:A2Precheck (A2Plan -AnPolicy 'ensureOn')).Reason | Should -Be 'targetOneAcceleratedNic'
    }

    It 'two other interfaces on: two after the move, refused' {
        $Global:A2Live = Global:A2VmLive 'Standard_D2s_v4' 3
        $Global:A2An = @{ nic0 = $false; nic1 = $true; nic2 = $true }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { Global:A2Sku 'Standard_D2s_v7' 2 -MaxNics 4; Global:A2Sku 'Standard_D2s_v4' 2 -MaxNics 4 }
        (Global:A2Precheck).Reason | Should -Be 'targetOneAcceleratedNic'
    }
}

Describe 'AN-MANA-DRIVER-RULE-1: GUEST_PREP has nothing to ask again' {
    BeforeAll {
        function Global:A2ManaCheck([string]$Module, [string]$Release) {
            $status = if ($Module -eq 'present') { 'PASS' } else { 'WARN' }
            [pscustomobject]@{ schema = 'vmf.guest/2'; script = 'mana-check.sh'; version = '1.1.0'; os = "Ubuntu $Release LTS"
                result = 'READY'; warnings = @()
                checks = @([pscustomobject]@{ name = 'mana module available'; status = $status; detail = 'modinfo mana' })
                facts = [pscustomobject]@{ os = 'Linux'; kernelVersion = $(if ($Release -eq '22.04') { '5.15.0-1100-azure' } else { '5.4.0-1109-azure' })
                    distroId = 'ubuntu'; distroVersion = $Release; fabric = 'none' } }
        }
        Mock -ModuleName VmMigrationFactory Get-VmfEngineSubscriptionId { '00000000-0000-0000-0000-000000000000' }
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { 'previous-context' }
    }
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-a2g-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Initialize-VmfRun -RunPath $rp -RunId 'a2g' | Out-Null }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { }
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
            if ($ScriptName -eq 'mana-check.sh') { return Global:A2ManaCheck $Global:A2Guest.Module $Global:A2Guest.Release }
            [pscustomobject]@{ schema = 'vmf.guest/2'; script = $ScriptName; version = '1'; os = 'Ubuntu'; result = 'READY'; warnings = @(); checks = @() }
        }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { Global:A2Sku 'Standard_D2s_v7' 2 -MaxNics 2 }
    }
    AfterEach {
        if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force }
        Remove-Variable A2Guest -Scope Global -ErrorAction SilentlyContinue
    }

    # Checking already counted the primary as on, so GUEST_PREP never reads
    # the size again: a kernel with no driver stops for it, untouched; a kernel
    # with one goes on.
    It '<Case>' -ForEach @(
        @{ Case = 'the kernel has no driver: the driver stop, untouched, and the size is not read again'; Plan = '18.04'; Module = 'absent';  Release = '18.04'; Next = 'NEEDS_DECISION'; Reason = 'driverBelowFloor' }
        @{ Case = 'the release was upgraded since the scan: the move goes on, the size is not read again'; Plan = '18.04'; Module = 'present'; Release = '22.04'; Next = 'STOPPED'; Reason = $null }
        @{ Case = 'a listed release with the driver: the move goes on';                                   Plan = '22.04'; Module = 'present'; Release = '22.04'; Next = 'STOPPED'; Reason = $null }
    ) {
        $Global:A2Guest = @{ Module = $Module; Release = $Release }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; plan = (A2Plan -Release $Plan); next = $Next; reason = $Reason } {
            param($rp, $plan, $next, $reason)
            $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'a2g'
            New-VmfStateDoc -RunPath $rp -RunId 'a2g' -VmId $ctx.VmId | Out-Null
            $nics = @([pscustomobject]@{ id = "/subscriptions/s/resourceGroups/rg/providers/Microsoft.Network/networkInterfaces/nic0"; primary = $true; acceleratedNetworking = $false }
                      [pscustomobject]@{ id = "/subscriptions/s/resourceGroups/rg/providers/Microsoft.Network/networkInterfaces/nic1"; primary = $false; acceleratedNetworking = $true })
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{ nics = $nics; location = 'centralus' } }
            $r = Invoke-VmfStepGuestPrep -Context $ctx
            $r.Next | Should -Be $next
            if ($reason) { $r.Reason | Should -Be $reason; $r.MachineState | Should -Be 'untouched' }
        }
        Should -Invoke Get-VmfSkuCatalog -ModuleName VmMigrationFactory -Times 0 -Exactly
    }
}


Describe 'AN-ONE-NIC-2: the 2-vCPU rule is in one place' {
    It 'the put-back fit check asks Test-VmfSizeAllowsAcceleratedNics, and reads no vCPU count itself' {
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'OriginalCapture.ps1')
        $fn = [regex]::Match($code, '(?s)function Get-VmfPutBackFitRefusal.*?\n\}').Value
        $fn | Should -Match 'Test-VmfSizeAllowsAcceleratedNics'
        $fn | Should -Not -Match "'vCPUs'|'vCPUsAvailable'"
    }
}
