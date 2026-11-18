#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# AN-ONE-NIC-1: a 2-vCPU target size cannot hold two interfaces with
# accelerated networking.
#
# NIC-1 measured that Azure allows accelerated networking on ONE network
# interface of a 2-vCPU size (VmSizeRestrictedToSingleNicWithAcceleratedNetworkingEnable).
# The move's default policy is ensureOn: the PRIMARY interface carries it
# (Get-VmfNicAnPlan), and every other interface keeps what it had - the engine
# never turns one off. So a machine with it off on the primary and on for a
# second interface ends the move with two, and on D2s_v6 (the default target of
# D2s_v4) Azure refuses it. Measured 2026-10-10 on D2s_v4: the interface update
# while deallocated is accepted, and every VM update after it is refused - after
# the stop and the safety copies, on every attempt.
#
# Decided 2026-10-10, option 1: refuse at PRECHECK, untouched, and say it on the
# targets step. Unknown is never a fit: a size with no vCPU count, a
# constrained size with 2 active vCPUs, or an interface Azure could not read is
# "cannot verify" (the ROLLBACK-RETRY-CAPTURE-2 rule).

BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
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

    # One catalog row. A capability passed as $null is one the catalog does not give.
    function Global:AoSku([string]$Name, $Vcpus = 2, $Available = $null, $MaxNics = 4, $MemoryGB = 8, $TempMb = '0', $Gens = 'V1,V2') {
        $caps = @()
        if ($null -ne $Vcpus) { $caps += [pscustomobject]@{ Name = 'vCPUs'; Value = [string]$Vcpus } }
        if ($null -ne $Available) { $caps += [pscustomobject]@{ Name = 'vCPUsAvailable'; Value = [string]$Available } }
        if ($null -ne $MaxNics) { $caps += [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = [string]$MaxNics } }
        $caps += [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '16' }
        $caps += [pscustomobject]@{ Name = 'MemoryGB'; Value = [string]$MemoryGB }
        $caps += [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = $TempMb }
        $caps += [pscustomobject]@{ Name = 'HyperVGenerations'; Value = $Gens }
        $caps += [pscustomobject]@{ Name = 'AcceleratedNetworkingEnabled'; Value = 'True' }
        [pscustomobject]@{ Name = $Name; Family = 'standardX'; ResourceType = 'virtualMachines'; Restrictions = @(); Capabilities = $caps }
    }
    # centralus as these tests need it: D2s and D4s on v4, v5 and v6.
    function Global:AoCatalog([hashtable]$Override = @{}) {
        $c = @{}
        foreach ($s in @(
                (AoSku 'Standard_D2s_v4' 2), (AoSku 'Standard_D4s_v4' 4 -MemoryGB 16),
                (AoSku 'Standard_D2s_v5' 2), (AoSku 'Standard_D4s_v5' 4 -MemoryGB 16), (AoSku 'Standard_D8s_v5' 8 -MemoryGB 32),
                (AoSku 'Standard_D2s_v6' 2 -MaxNics 2), (AoSku 'Standard_D4s_v6' 4 -MemoryGB 16), (AoSku 'Standard_D8s_v6' 8 -MemoryGB 32))) { $c[$s.Name] = $s }
        foreach ($k in $Override.Keys) { $c[$k] = $Override[$k] }
        $c
    }
    # An assessed machine as the scan writes it (AN-PRIMARY-1 fields).
    function Global:AoVm([string]$Size = 'Standard_D2s_v4', [int]$Nics = 2, $AnCount = 1, $PrimaryOn = $false, [string]$Gen = 'V2') {
        [pscustomobject]@{
            vmId = $script:vmId; name = 'vm1'; location = 'centralus'; classification = 'ReadyAfterPrep'; gen = $Gen; os = 'Linux'
            osVersion = '22_04-lts-gen2'; sourceSize = $Size; sourceDiskArch = 'diskless'; sourceTempDisks = 0; diskController = 'SCSI'
            dataDiskCount = 0; nicCount = $Nics; acceleratedNicCount = $AnCount; primaryNicAccelerated = $PrimaryOn
            platformManaged = $false; blockers = @(); prepNeeded = @()
        }
    }
}
AfterAll { Remove-Item 'function:\AoSku', 'function:\AoCatalog', 'function:\AoVm', 'function:\AoVmLive', 'function:\AoPlan', 'function:\AoPrecheck' -ErrorAction SilentlyContinue }

Describe 'AN-ONE-NIC-1: how many interfaces have accelerated networking after the move, from the scan' {
    # ensureOn is the policy of every move this tool plans (Get-VmfPolicy): the
    # primary carries it, every other interface keeps what it had.
    It '<Case>' -ForEach @(
        @{ Case = 'primary off, second on: two after the move';            Nics = 2; Count = 1; Primary = $false; Expected = 2 }
        @{ Case = 'primary on, second on: still two';                     Nics = 2; Count = 2; Primary = $true;  Expected = 2 }
        @{ Case = 'primary on, second off: one';                          Nics = 2; Count = 1; Primary = $true;  Expected = 1 }
        @{ Case = 'none on: the primary only';                            Nics = 2; Count = 0; Primary = $false; Expected = 1 }
        @{ Case = 'one interface: never more than one';                   Nics = 1; Count = 1; Primary = $true;  Expected = 1 }
        @{ Case = 'the count was not read: unknown';                      Nics = 2; Count = $null; Primary = $false; Expected = $null }
        @{ Case = 'one on and the primary not read: unknown';             Nics = 2; Count = 1; Primary = $null; Expected = $null }
        @{ Case = 'two on and the primary not read: at least two';        Nics = 3; Count = 2; Primary = $null; Expected = 2 }
        @{ Case = 'none on and the primary not read: the primary only';   Nics = 3; Count = 0; Primary = $null; Expected = 1 }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ vm = (AoVm -Nics $Nics -AnCount $Count -PrimaryOn $Primary); e = $Expected } {
            param($vm, $e)
            $n = Get-VmfAcceleratedNicsAfterMove -Assessment $vm
            if ($null -eq $e) { $n | Should -BeNullOrEmpty } else { $n | Should -Be $e }
        }
    }
}

Describe 'AN-ONE-NIC-1: does a size allow accelerated networking on this many interfaces' {
    It '<Case>' -ForEach @(
        @{ Case = 'one interface: every size';                    Count = 1; Vcpus = 2; Available = $null; Expected = 'fits' }
        @{ Case = 'two on 2 vCPUs: too small';                    Count = 2; Vcpus = 2; Available = $null; Expected = 'tooSmall' }
        @{ Case = 'two on 4 vCPUs: fits';                         Count = 2; Vcpus = 4; Available = $null; Expected = 'fits' }
        @{ Case = 'two, no vCPU count: unknown';                  Count = 2; Vcpus = $null; Available = $null; Expected = 'unknown' }
        @{ Case = 'two on 4 vCPUs with 2 active: unknown';        Count = 2; Vcpus = 4; Available = 2; Expected = 'unknown' }
        @{ Case = 'two on 8 vCPUs with 4 active: fits';           Count = 2; Vcpus = 8; Available = 4; Expected = 'fits' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ s = (AoSku 'Standard_X' $Vcpus $Available); n = $Count; e = $Expected } {
            param($s, $n, $e)
            (Test-VmfSizeAllowsAcceleratedNics -SkuEntry $s -Count $n).Verdict | Should -Be $e
        }
    }

    It 'no catalog row at all: unknown, never a fit' {
        InModuleScope VmMigrationFactory {
            (Test-VmfSizeAllowsAcceleratedNics -SkuEntry $null -Count 2).Verdict | Should -Be 'unknown'
        }
    }
}

Describe 'AN-ONE-NIC-1: the planner does not choose a 2-vCPU size for two accelerated interfaces' {
    # Decided 2026-10-10 (OWNER-QUESTIONS-1 row 31, option 2): a bigger size is
    # NEVER offered for this - not as the target, and not as the fix a reason
    # names. It doubles the price. The fix is to turn accelerated networking off
    # on the other interface. This test held "the reason offers D4s_v6" before.
    It 'D2s_v4 with two after the move: D2s_v6 is refused, and the reason says to turn it off on the other interface - never a bigger size' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (AoCatalog) } {
            param($c)
            $r = Get-VmfTargetSize -SourceSize 'Standard_D2s_v4' -CatalogBySize $c -TargetGeneration 'v6' -RequiredNics 2 -AcceleratedNicsAfter 2
            $r.Target | Should -BeNullOrEmpty
            $r.Code | Should -Be 'one-accelerated-nic'
            $r.Reason | Should -Match 'Standard_D2s_v6 has 2 vCPUs'
            $r.Reason | Should -Match 'turn off accelerated networking on the other network interfaces'
            $r.Reason | Should -Not -Match 'Standard_D4s_v6|Standard_D8s_v6|4 or more vCPUs'
        }
    }

    It 'one interface with accelerated networking after the move: D2s_v6, as before' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (AoCatalog) } {
            param($c)
            $r = Get-VmfTargetSize -SourceSize 'Standard_D2s_v4' -CatalogBySize $c -TargetGeneration 'v6' -RequiredNics 2 -AcceleratedNicsAfter 1
            $r.Target | Should -Be 'Standard_D2s_v6'
            $r.Code | Should -Be 'mapped'
        }
    }

    It 'a 4-vCPU machine: its D4s_v6 takes both' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (AoCatalog) } {
            param($c)
            $r = Get-VmfTargetSize -SourceSize 'Standard_D4s_v4' -CatalogBySize $c -TargetGeneration 'v6' -RequiredNics 2 -AcceleratedNicsAfter 2
            $r.Target | Should -Be 'Standard_D4s_v6'
            $r.Code | Should -Be 'mapped'
        }
    }

    It 'a caller that does not ask (one interface by default) gets what it always got' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (AoCatalog) } {
            param($c)
            (Get-VmfTargetSize -SourceSize 'Standard_D2s_v4' -CatalogBySize $c -TargetGeneration 'v6' -RequiredNics 2).Target | Should -Be 'Standard_D2s_v6'
        }
    }

    It 'the scan did not say how many: planned, but as unverified - never a plain fit' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (AoCatalog) } {
            param($c)
            $r = Get-VmfTargetSize -SourceSize 'Standard_D2s_v4' -CatalogBySize $c -TargetGeneration 'v6' -RequiredNics 2 -AcceleratedNicsAfter $null
            $r.Target | Should -Be 'Standard_D2s_v6'
            $r.Code | Should -Be 'mapped-unverified'
            $r.Reason | Should -Match 'accelerated networking could not be verified'
        }
    }

    It 'the catalog gives no vCPU count for the size: planned as unverified' {
        $cat = AoCatalog @{ 'Standard_D2s_v6' = (AoSku 'Standard_D2s_v6' $null -MaxNics 2) }
        InModuleScope VmMigrationFactory -Parameters @{ c = $cat } {
            param($c)
            $r = Get-VmfTargetSize -SourceSize 'Standard_D2s_v4' -CatalogBySize $c -TargetGeneration 'v6' -RequiredNics 2 -AcceleratedNicsAfter 2
            $r.Target | Should -Be 'Standard_D2s_v6'
            $r.Code | Should -Be 'mapped-unverified'
        }
    }

    # The test of the size suggestion (Get-VmfSmallestSizeForAcceleratedNics)
    # went with it: row 31, option 2, names no bigger size.
    It 'the shape choices of a machine sized by shape never climb to a bigger size for it' {
        # DS2_v2 (2 vCPUs, 7 GiB) on v6: D2s_v6 is its size by shape. Before row
        # 31 the 2-vCPU size was passed over for D4s_v6.
        $cat = AoCatalog @{ 'Standard_DS2_v2' = (AoSku 'Standard_DS2_v2' 2 -MemoryGB 7) }
        InModuleScope VmMigrationFactory -Parameters @{ c = $cat } {
            param($c)
            $two = @(Get-VmfShapeSizeChoices -SourceSize 'Standard_DS2_v2' -CatalogBySize $c -RequiredNics 2 -HyperVGeneration 'V2' -TargetGeneration 'v6' -AcceleratedNicsAfter 2)
            $two.Count | Should -Be 0
            $one = @(Get-VmfShapeSizeChoices -SourceSize 'Standard_DS2_v2' -CatalogBySize $c -RequiredNics 2 -HyperVGeneration 'V2' -TargetGeneration 'v6' -AcceleratedNicsAfter 1)
            @($one | Where-Object { $_.best } | ForEach-Object { $_.size }) | Should -Be @('Standard_D2s_v6')
        }
    }
}

Describe 'AN-ONE-NIC-1: the targets step says it before planning' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        function Global:AoAdvise($Vm, [hashtable]$Catalog = (AoCatalog)) {
            $doc = [pscustomobject]@{ schemaVersion = 17; runId = 'scan-1'; vms = @($Vm) }
            InModuleScope VmMigrationFactory -Parameters @{ d = $doc; c = @{ centralus = $Catalog } } {
                param($d, $c)
                Get-VmfTargetAdvice -Assessment $d -CatalogByLocation $c
            }
        }
    }
    AfterAll { Remove-Item 'function:\AoAdvise' -ErrorAction SilentlyContinue }

    It 'primary off and second on: every 2-vCPU option is not supported, with the reason code' {
        $m = (AoAdvise (AoVm -AnCount 1 -PrimaryOn $false)).machines[0]
        foreach ($s in 'v5', 'v6') {
            $o = @($m.options | Where-Object option -eq $s)[0]
            $o.supported | Should -BeFalse
            @($o.notSupported) | Should -Contain 'one-accelerated-nic'
        }
        $m.start.current | Should -BeNullOrEmpty
    }

    It 'primary on and second on: the same' {
        $m = (AoAdvise (AoVm -AnCount 2 -PrimaryOn $true)).machines[0]
        @(@($m.options | Where-Object option -eq 'v6')[0].notSupported) | Should -Contain 'one-accelerated-nic'
    }

    It 'only one interface with accelerated networking after the move: supported, as before' {
        $m = (AoAdvise (AoVm -AnCount 0 -PrimaryOn $false)).machines[0]
        $o = @($m.options | Where-Object option -eq 'v6')[0]
        $o.supported | Should -BeTrue
        $o.targetSize | Should -Be 'Standard_D2s_v6'
    }

    # Row 31, option 2: one rule everywhere. This test held "a machine chosen
    # by shape is offered the 4-vCPU size instead" before - a price doubled
    # with no person choosing it.
    It 'a Generation 1 machine chosen by shape gets no target either, and no bigger size' {
        $m = (AoAdvise (AoVm -AnCount 1 -PrimaryOn $false -Gen 'V1')).machines[0]
        $o = @($m.options | Where-Object option -eq 'v5')[0]
        $o.supported | Should -BeFalse
        @($o.notSupported) | Should -Contain 'one-accelerated-nic'
        $o.targetSize | Should -BeNullOrEmpty
        @($o.sizeChoices).Count | Should -Be 0
    }

    It 'a Generation 2 machine on an older size, chosen by shape: no target, with the reason code' {
        $cat = AoCatalog @{ 'Standard_DS2_v2' = (AoSku 'Standard_DS2_v2' 2 -MemoryGB 7) }
        $m = (AoAdvise (AoVm -Size 'Standard_DS2_v2' -AnCount 1 -PrimaryOn $false) $cat).machines[0]
        $o = @($m.options | Where-Object option -eq 'v6')[0]
        $o.supported | Should -BeFalse
        @($o.notSupported) | Should -Contain 'one-accelerated-nic'
        @($o.sizeChoices).Count | Should -Be 0
        # The same machine with one interface after the move: D2s_v6, so the data can disagree.
        $one = @((AoAdvise (AoVm -Size 'Standard_DS2_v2' -AnCount 0 -PrimaryOn $false) $cat).machines[0].options | Where-Object option -eq 'v6')[0]
        $one.supported | Should -BeTrue
        $one.targetSize | Should -Be 'Standard_D2s_v6'
    }

    It 'no silent best choice: when the best size by shape has 2 vCPUs, a 4-vCPU size of another family is not made the target' {
        # DS2_v2 on v5: D2s_v5 is the best (2 vCPUs, 8 GiB); the Dl family needs
        # D4ls_v5 for the 7 GiB. With two after the move, the best is refused,
        # and the 4-vCPU Dl size must not take its place.
        $cat = AoCatalog @{
            'Standard_DS2_v2' = (AoSku 'Standard_DS2_v2' 2 -MemoryGB 7)
            'Standard_D2ls_v5' = (AoSku 'Standard_D2ls_v5' 2 -MemoryGB 4)
            'Standard_D4ls_v5' = (AoSku 'Standard_D4ls_v5' 4 -MemoryGB 8)
        }
        $o = @((AoAdvise (AoVm -Size 'Standard_DS2_v2' -AnCount 1 -PrimaryOn $false) $cat).machines[0].options | Where-Object option -eq 'v5')[0]
        $o.supported | Should -BeFalse
        @($o.notSupported) | Should -Contain 'one-accelerated-nic'
        $o.targetSize | Should -BeNullOrEmpty
        # And with one after the move, the best is D2s_v5 and D4ls_v5 is a choice.
        $one = @((AoAdvise (AoVm -Size 'Standard_DS2_v2' -AnCount 0 -PrimaryOn $false) $cat).machines[0].options | Where-Object option -eq 'v5')[0]
        $one.targetSize | Should -Be 'Standard_D2s_v5'
        @($one.sizeChoices | ForEach-Object { $_.size }) | Should -Contain 'Standard_D4ls_v5'
    }

    It 'the advice still matches its schema, with the new reason' {
        $json = AoAdvise (AoVm -AnCount 1 -PrimaryOn $false) | ConvertTo-Json -Depth 12
        $json | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json') | Should -BeTrue
    }

    It 'the targets step has words for the reason' {
        $page = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.html'))
        $page | Should -Match "'one-accelerated-nic': '"
    }
}

Describe 'AN-ONE-NIC-1: the end state the move leaves, from the capture' {
    It '<Case>' -ForEach @(
        @{ Case = 'primary turned on, second on: two';            An = @($false, $true); OnAfter = $true;  On = 2; Unknown = 0 }
        @{ Case = 'primary on, second on: two';                   An = @($true, $true);  OnAfter = $true;  On = 2; Unknown = 0 }
        @{ Case = 'primary turned on, second off: one';           An = @($false, $false); OnAfter = $true; On = 1; Unknown = 0 }
        @{ Case = 'primary off after the move, second kept';      An = @($true, $true);  OnAfter = $false; On = 1; Unknown = 0 }
        @{ Case = 'second interface not read: unknown';           An = @($false, $null); OnAfter = $true;  On = 1; Unknown = 1 }
        # Review finding: preserve changes only an interface read
        # as on (Get-VmfNicAnPlan), so an unread primary stays unknown - never off.
        @{ Case = 'preserve, primary not read, second on: unknown, never a fit'; An = @($null, $true); OnAfter = $false; On = 1; Unknown = 1 }
        @{ Case = 'ensureOn, primary not read: turned on whatever it reads';     An = @($null, $true); OnAfter = $true;  On = 2; Unknown = 0 }
        # OLD-VERSION-READERS-REMOVE-3: ensureOff, which turned every interface
        # off, left the contract at v33 - every other interface is kept.
        @{ Case = 'primary off, two others on: both kept';           An = @($false, $true, $true); OnAfter = $false; On = 2; Unknown = 0 }
    ) {
        $nics = @(for ($i = 0; $i -lt $An.Count; $i++) { [ordered]@{ id = "nic$i"; primary = ($i -eq 0); acceleratedNetworking = $An[$i] } })
        InModuleScope VmMigrationFactory -Parameters @{ n = $nics; a = $OnAfter; on = $On; u = $Unknown } {
            param($n, $a, $on, $u)
            $r = Get-VmfAcceleratedNicsAfter -CapturedNics $n -PrimaryOnAfter $a
            $r.On | Should -Be $on
            $r.Unknown | Should -Be $u
        }
    }
}

Describe 'AN-ONE-NIC-1: PRECHECK stops the move untouched' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        function Global:AoVmLive([string]$Size, [int]$Nics) {
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
        # -AnPolicy, never -Policy: names ignore case, and $policy below would
        # overwrite it (AGENTS.md, section 1, item 5).
        # DRIFT-11: v7 here. Every v6 size requires accelerated networking since 2026-10-27, so a machine with it off would stop in Checking for that, before the count this Describe tests.
        function Global:AoPlan([string]$Target = 'Standard_D2s_v7', $AnPolicy = $null) {
            $levers = [ordered]@{ onDDataFound = 'proceed' }
            if ($AnPolicy) { $levers.acceleratedNetworking = $AnPolicy }
            [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vmId; wave = 'w1'; ring = 'lab'; path = 'A'
                assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'; sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; platformManaged = $false; location = 'centralus' }
                target = [pscustomobject]@{ size = $Target; diskArch = 'diskless'; controller = 'NVMe'; zone = $null }
                policy = [pscustomobject]$levers }
        }
        function Global:AoPrecheck($Plan = (AoPlan)) {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; plan = $Plan } {
                param($rp, $plan)
                $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'aon'
                if (-not (Read-VmfStateDoc -RunPath $rp -VmId $ctx.VmId)) { New-VmfStateDoc -RunPath $rp -RunId 'aon' -VmId $ctx.VmId | Out-Null }
                Invoke-VmfStepPrecheck -Context $ctx
            }
        }
        Mock -ModuleName VmMigrationFactory Get-VmfEngineSubscriptionId { '00000000-0000-0000-0000-000000000000' }
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { 'previous-context' }
    }
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-aon-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Initialize-VmfRun -RunPath $rp -RunId 'aon' | Out-Null }
        $Global:AoLive = Global:AoVmLive 'Standard_D2s_v4' 2
        # Each interface's reading, by name; a name left out cannot be read.
        $Global:AoAn = @{ nic0 = $false; nic1 = $true }
        $Global:AoTargetSku = Global:AoSku 'Standard_D2s_v7' 2 -MaxNics 2
        Mock -ModuleName VmMigrationFactory Test-VmfAdeExtension { $false }
        # SAFETY-CMK-1: PRECHECK reads each disk's encryption by its id.
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }
        Mock -ModuleName VmMigrationFactory Get-VmfVmResourceLocks { , @() }
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { @([pscustomobject]@{ actions = @('*'); notActions = @() }) }
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/deallocated' }
        Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions { @() }
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { $Global:AoLive }
        Mock -ModuleName VmMigrationFactory Get-AzNetworkInterface {
            if (-not $Global:AoAn.ContainsKey($Name)) { throw 'not read' }
            [pscustomobject]@{ EnableAcceleratedNetworking = $Global:AoAn[$Name] }
        }
        Mock -ModuleName VmMigrationFactory Get-VmfNetworkInterfaceById { [pscustomobject]@{ Id = $NicId; IpConfigurations = @() } }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { $Global:AoTargetSku; Global:AoSku 'Standard_D2s_v4' 2 -MaxNics 3 }
        # Nothing may change the machine: every one of these is a write.
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { throw 'the machine must not be stopped' }
        Mock -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot { throw 'no safety copy may be taken' }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { throw 'no interface may be changed' }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { throw 'the size must not be changed' }
    }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

    It '2-vCPU target, primary off and second on: refused untouched, and the words say what to do' {
        $r = Global:AoPrecheck
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'targetOneAcceleratedNic'
        $r.Detail | Should -Match 'Standard_D2s_v7 has 2 vCPUs'
        $r.Detail | Should -Match 'After the move, 2 network interfaces of this machine have it'
        $r.Detail | Should -Match 'Nothing on the machine changed'
        $r.ContainsKey('MachineState') | Should -BeFalse -Because 'PRECHECK changes nothing, so the runner records untouched'
        Should -Invoke Stop-VmfVmDeallocated -ModuleName VmMigrationFactory -Times 0 -Exactly
        Should -Invoke New-VmfOsDiskSnapshot -ModuleName VmMigrationFactory -Times 0 -Exactly
        Should -Invoke Set-VmfNicAcceleratedNetworking -ModuleName VmMigrationFactory -Times 0 -Exactly
        Should -Invoke Set-VmfVmSizeAndController -ModuleName VmMigrationFactory -Times 0 -Exactly
    }

    It '2-vCPU target, primary already on and second on: the end state is still two, refused' {
        $Global:AoAn = @{ nic0 = $true; nic1 = $true }
        (Global:AoPrecheck).Reason | Should -Be 'targetOneAcceleratedNic'
    }

    It 'only one interface with accelerated networking after the move: the move goes on' {
        $Global:AoAn = @{ nic0 = $false; nic1 = $false }
        (Global:AoPrecheck).Next | Should -Be 'SAFETY_PRISTINE'
    }

    It 'a 4-vCPU target: the move goes on' {
        $Global:AoTargetSku = Global:AoSku 'Standard_D4s_v7' 4
        (Global:AoPrecheck (AoPlan 'Standard_D4s_v7')).Next | Should -Be 'SAFETY_PRISTINE'
    }

    # OLD-VERSION-READERS-REMOVE-3: ensureOff left the plan contract at v33.
    # A plan that holds it is refused untouched, before the count.
    It 'a plan that holds ensureOff on v7: refused untouched, before the count' {
        $r = Global:AoPrecheck (AoPlan -AnPolicy 'ensureOff')
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'policyNotKnown'
    }

    # AN-MANA-DRIVER-RULE-1: held on AMD v5, where preserve may still keep it off.
    It 'preserve on AMD v5, the primary interface not read and the second on: refused as cannot verify, never a fit' {
        $Global:AoAn = @{ nic1 = $true }
        $Global:AoTargetSku = Global:AoSku 'Standard_D2as_v5' 2 -MaxNics 2
        $plan = AoPlan 'Standard_D2as_v5' -AnPolicy 'preserve'
        $plan.target.controller = 'SCSI'
        (Global:AoPrecheck $plan).Reason | Should -Be 'targetAcceleratedNicsUnknown'
        # On v7 it is refused too, untouched: by the count, which Checking asks first.
        (Global:AoPrecheck (AoPlan -AnPolicy 'preserve')).Next | Should -Be 'NEEDS_DECISION'
    }

    It 'the catalog gives no vCPU count for the target: refused as cannot verify' {
        $Global:AoTargetSku = Global:AoSku 'Standard_D2s_v7' $null -MaxNics 2
        $r = Global:AoPrecheck
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'targetAcceleratedNicsUnknown'
        $r.Detail | Should -Match 'how many vCPUs Standard_D2s_v7 has'
        $r.Detail | Should -Match 'Nothing on the machine changed'
    }

    It 'a constrained target with 2 active vCPUs: refused as cannot verify' {
        $Global:AoTargetSku = Global:AoSku 'Standard_D2s_v7' 4 -Available 2 -MaxNics 2
        (Global:AoPrecheck).Reason | Should -Be 'targetAcceleratedNicsUnknown'
    }

    It 'Azure could not read the second interface: refused as cannot verify' {
        $Global:AoAn = @{ nic0 = $false }
        $r = Global:AoPrecheck
        $r.Reason | Should -Be 'targetAcceleratedNicsUnknown'
        $r.Detail | Should -Match 'could not read'
    }

    It 'the person turns it off on the second interface, and the move goes on - the stop is one a person can correct' {
        (Global:AoPrecheck).Reason | Should -Be 'targetOneAcceleratedNic'
        $Global:AoAn = @{ nic0 = $false; nic1 = $false }
        (Global:AoPrecheck).Next | Should -Be 'SAFETY_PRISTINE'
    }
}

Describe 'AN-ONE-NIC-1: the two stops have guidance' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:table = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json
    }
    It '<Code> leaves the machine untouched, and a person can correct it' -ForEach @(
        @{ Code = 'targetOneAcceleratedNic' }
        @{ Code = 'targetAcceleratedNicsUnknown' }
    ) {
        $r = @($script:table.reasons | Where-Object code -eq $Code)
        $r.Count | Should -Be 1
        $r[0].machine | Should -Be 'untouched'
        $r[0].retry | Should -Be 'afterFix'
        # Row 31, option 2: the fix is the interface, never a bigger size.
        $r[0].whatToDo | Should -Match 'Turn off accelerated networking on the other network interfaces'
        $r[0].whatToDo | Should -Not -Match '4 or more vCPUs|bigger|larger'
    }
}
