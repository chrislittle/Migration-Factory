#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# DRIFT-11: every v6 size the product targets now REQUIRES accelerated
# networking.
#
# Microsoft commit 6c2b128 (MicrosoftDocs/azure-compute-docs, 2026-10-27)
# changed the Accelerated Networking row from "Supported" to "Required" on the
# Dsv6, Ddsv6, Dlsv6, Dldsv6, Dasv6, Dadsv6, Dalsv6, Daldsv6, Esv6, Edsv6,
# Easv6, Eadsv6, Ebsv6, Ebdsv6, Ensv6 and Endsv6 pages. Nothing else on those
# pages changed. The v7 pages (Ddsv7, Dasv7, Edsv7, Fasv7 and the rest) and the
# AMD v5 pages still say "Supported".
#
# What follows for a machine, in the same shape as Intel D and E v5 (GEN-V5-1,
# DRIFT-5): a machine with accelerated networking off stops untouched before a
# move to v6, or the accepted wave settings turn it on. On v7 nothing stops.
#
# And two consequences for where a machine STARTS (ADVISE-AN-1), because v6 was
# the place a Linux machine with no MANA driver could keep accelerated
# networking off (AN-KEEP-1):
#   - a machine with it off, whose VM agent reports a Linux release Microsoft
#     does not list for MANA, starts on an option that lets it stay off (v7,
#     or AMD v5 for an AMD machine), not on v6, where turning it on gives it
#     no driver and the move stops again in Preparing;
#   - a machine with it ON and such a release keeps its processor maker on an
#     option where the plan can turn it off (v7) - on v6 the plan cannot, so
#     that card stopped every time in Preparing.
# AN-MANA-DRIVER-RULE-1 (2026-11-06) replaced both: such a machine is
# offered no size that can give MANA (v7 included), so an Intel one has no
# target and an AMD one starts on AMD v5. The tests below say so.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:doc = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'target-families.json') -Raw | ConvertFrom-Json

    function Global:D11Nics([bool]$PrimaryOn) {
        , @([pscustomobject]@{ id = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Network/networkInterfaces/nic0'; primary = $true; acceleratedNetworking = $PrimaryOn })
    }
    function Global:D11Plan([string]$Size, [string]$An = '', [string]$Os = 'Linux') {
        $controller = if ($Size -match '_v5$') { 'SCSI' } else { 'NVMe' }
        $policy = [ordered]@{ onDriverBelowFloor = 'stop'; onDDataFound = 'stop' }
        if ($An) { $policy.acceleratedNetworking = $An }
        [pscustomobject]@{
            schemaVersion = (Get-VmfTestPlanEntryVersion)
            vmId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/d11vm'
            wave = 'w1'
            assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = $Os
                sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; platformManaged = $false }
            target = [pscustomobject]@{ size = $Size; diskArch = 'diskless'; controller = $controller }
            path = 'A'
            policy = [pscustomobject]$policy
        }
    }
    function Global:D11Sku([string]$Name) {
        $gens = if ($Name -like '*_v5') { 'V1,V2' } else { 'V2' }
        [pscustomobject]@{ Name = $Name; Family = 'standardX'; ResourceType = 'virtualMachines'; Restrictions = @()
            Capabilities = @(
                [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = '0' }
                [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '4' }
                [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '8' }
                [pscustomobject]@{ Name = 'vCPUs'; Value = '2' }
                [pscustomobject]@{ Name = 'MemoryGB'; Value = '8' }
                [pscustomobject]@{ Name = 'HyperVGenerations'; Value = $gens }) }
    }
    function Global:D11Catalog([switch]$NoV7) {
        $c = @{}
        $names = @('Standard_D2s_v5', 'Standard_D2as_v5', 'Standard_D2s_v6', 'Standard_D2as_v6')
        if (-not $NoV7) { $names += 'Standard_D2s_v7', 'Standard_D2as_v7' }
        foreach ($n in $names) { $c[$n] = D11Sku $n }
        $c
    }
    function Global:D11Vm {
        param([string]$Size = 'Standard_D2s_v4', [string]$Os = 'Linux', [string]$RunningName = '', [string]$RunningVersion = '',
              [string]$Offer = 'UbuntuServer', [string]$Sku = '18.04-LTS', [string]$Publisher = 'Canonical', [object]$Primary = $false)
        [pscustomobject]@{
            vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/m'
            name = 'm'; location = 'centralus'; classification = 'ReadyAfterPrep'; gen = 'V2'; os = $Os
            osVersion = $Sku; imagePublisher = $Publisher; imageOffer = $Offer; imageId = ''
            runningOsName = $RunningName; runningOsVersion = $RunningVersion
            sourceSize = $Size; sourceDiskArch = 'diskless'; sourceTempDisks = 0; diskController = 'SCSI'
            dataDiskCount = 0; nicCount = 1; acceleratedNicCount = $(if ($Primary) { 1 } else { 0 }); primaryNicAccelerated = $Primary
            platformManaged = $false; blockers = @(); prepNeeded = @()
        }
    }
    function Global:D11Advise($Vm, [hashtable]$Catalog = (D11Catalog)) {
        $doc = [pscustomobject]@{ schemaVersion = 17; runId = 'scan-1'; vms = @($Vm) }
        $r = InModuleScope VmMigrationFactory -Parameters @{ d = $doc; c = @{ centralus = $Catalog } } {
            Get-VmfTargetAdvice -Assessment $d -CatalogByLocation $c
        }
        @($r.machines)[0]
    }
    function Global:D11Opt($Machine, [string]$Option) { @($Machine.options) | Where-Object { $_.option -eq $Option } | Select-Object -First 1 }
}
AfterAll {
    Remove-Item 'function:\D11Nics', 'function:\D11Plan', 'function:\D11Sku', 'function:\D11Catalog', 'function:\D11Vm',
        'function:\D11Advise', 'function:\D11Opt' -ErrorAction SilentlyContinue
}

Describe 'DRIFT-11: the data says what the v6 pages say' {

    It 'v6 requires accelerated networking on Intel and AMD, D and E - every v6 series the product targets' {
        $rules = @($script:doc.generations.v6.acceleratedNetworkingRequired |
            ForEach-Object { "$($_.series)/$($_.processor)" } | Sort-Object)
        $rules | Should -Be @('D/AMD', 'D/Intel', 'E/AMD', 'E/Intel')
        @($script:doc.seriesByGeneration.v6) | Should -Be @('D', 'E') -Because 'a new v6 series needs its own page read first'
    }

    It 'v7 requires it nowhere: its pages still say Supported' {
        @($script:doc.generations.v7.acceleratedNetworkingRequired).Count | Should -Be 0
    }

    It 'v5 is as DRIFT-5 left it: Intel D and Intel E only' {
        $rules = @($script:doc.generations.v5.acceleratedNetworkingRequired |
            ForEach-Object { "$($_.series)/$($_.processor)" } | Sort-Object)
        $rules | Should -Be @('D/Intel', 'E/Intel')
    }

    It 'the v6 rule names its pages and Microsoft''s commit, read on or after the change' {
        $src = @($script:doc.sources | Where-Object { $_.says -match 'DRIFT-11' })
        $src.Count | Should -BeGreaterOrEqual 1
        foreach ($s in $src) { [datetime]$s.readUtc | Should -BeGreaterOrEqual ([datetime]'2026-10-27') }
        $says = ($src.says -join ' ')
        $says | Should -Match '6c2b128'
        foreach ($page in 'Dsv6', 'Ddsv6', 'Dlsv6', 'Dldsv6', 'Dasv6', 'Dadsv6', 'Dalsv6', 'Daldsv6',
                          'Esv6', 'Edsv6', 'Easv6', 'Eadsv6', 'Ebsv6', 'Ebdsv6', 'Ensv6', 'Endsv6') {
            $says | Should -Match "(^|[^A-Za-z])$page([^A-Za-z0-9]|$)" -Because "the $page page is one the rule comes from"
        }
        $says | Should -Match 'v7'
    }
}

Describe 'DRIFT-11: which target sizes require it' {

    It '<Size> requires it: <Expected>' -ForEach @(
        @{ Size = 'Standard_D2s_v6';    Expected = $true }
        @{ Size = 'Standard_D2ds_v6';   Expected = $true }
        @{ Size = 'Standard_D2ls_v6';   Expected = $true }
        @{ Size = 'Standard_D2lds_v6';  Expected = $true }
        @{ Size = 'Standard_D2as_v6';   Expected = $true }
        @{ Size = 'Standard_D2ads_v6';  Expected = $true }
        @{ Size = 'Standard_D2als_v6';  Expected = $true }
        @{ Size = 'Standard_D2alds_v6'; Expected = $true }
        @{ Size = 'Standard_E2s_v6';    Expected = $true }
        @{ Size = 'Standard_E2ds_v6';   Expected = $true }
        @{ Size = 'Standard_E2as_v6';   Expected = $true }
        @{ Size = 'Standard_E2ads_v6';  Expected = $true }
        @{ Size = 'Standard_E2bs_v6';   Expected = $true }
        @{ Size = 'Standard_E2bds_v6';  Expected = $true }
        @{ Size = 'Standard_E2ns_v6';   Expected = $true }
        @{ Size = 'Standard_E2nds_v6';  Expected = $true }
        @{ Size = 'Standard_D2s_v7';    Expected = $false }
        @{ Size = 'Standard_D2ds_v7';   Expected = $false }
        @{ Size = 'Standard_D2as_v7';   Expected = $false }
        @{ Size = 'Standard_E2ds_v7';   Expected = $false }
        @{ Size = 'Standard_F2as_v7';   Expected = $false }
        @{ Size = 'Standard_D2as_v5';   Expected = $false }
        @{ Size = 'Standard_E2ads_v5';  Expected = $false }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ size = $Size; expected = $Expected } {
            Test-VmfTargetRequiresAcceleratedNetworking -SizeName $size | Should -Be $expected
        }
    }

    # AN-MANA-DRIVER-RULE-1 (2026-11-06): rewritten. A kernel with no
    # MANA driver kept it off on v7; no size keeps it off now. Every v6 and v7
    # size needs a MANA driver (it can give MANA), and accelerated networking
    # is always on there.
    It 'every v6 and v7 size needs a MANA driver; none keeps it off' {
        InModuleScope VmMigrationFactory {
            foreach ($s in 'Standard_D2ds_v6', 'Standard_D2as_v6', 'Standard_E2s_v6', 'Standard_D2ls_v6', 'Standard_D2ds_v7', 'Standard_D2as_v7', 'Standard_E2s_v7', 'Standard_F2as_v7') {
                Test-VmfTargetNeedsManaDriver -SizeName $s | Should -BeTrue -Because $s
            }
        }
    }
}

Describe 'DRIFT-11: the engine on a move to v6 with accelerated networking off' {

    It '<Size>, driver <Driver>: stops before the machine is touched' -ForEach @(
        foreach ($size in 'Standard_D2s_v6', 'Standard_D2ds_v6', 'Standard_D2ls_v6', 'Standard_D2as_v6', 'Standard_D2alds_v6',
                          'Standard_E2s_v6', 'Standard_E2ads_v6', 'Standard_E2bds_v6', 'Standard_E2ns_v6') {
            foreach ($driver in '', 'present', 'absent', 'unlisted', 'unknown') { @{ Size = $size; Driver = $driver } }
        }
    ) {
        # Driver '' is Checking's call: it has no reading from inside the machine.
        InModuleScope VmMigrationFactory -Parameters @{ size = $Size; driver = $Driver } {
            $r = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry (Global:D11Plan $size) -CapturedNics (Global:D11Nics $false) -ManaDriver $driver
            $r.Stop | Should -BeTrue
            $r.Reason | Should -Be 'acceleratedNetworkingRequired'
            $r.Detail | Should -Match ([regex]::Escape($size))
        }
    }

    It 'Windows too: stops untouched, and an accepted wave setting turns it on with no stop' {
        InModuleScope VmMigrationFactory {
            $r = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry (Global:D11Plan 'Standard_D2as_v6' -Os 'Windows') -CapturedNics (Global:D11Nics $false) -ManaDriver 'unknown'
            $r.Reason | Should -Be 'acceleratedNetworkingRequired'
            $r = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry (Global:D11Plan 'Standard_D2as_v6' -An 'ensureOn' -Os 'Windows') -CapturedNics (Global:D11Nics $false) -ManaDriver 'unknown'
            $r.Stop | Should -BeFalse
            $r.Policy | Should -Be 'ensureOn'
            $r.OnAfter | Should -BeTrue
        }
    }

    It 'accepted wave settings (ensureOn), driver present: it moves and the move turns it on' {
        InModuleScope VmMigrationFactory {
            foreach ($size in 'Standard_D2s_v6', 'Standard_E2as_v6') {
                $r = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry (Global:D11Plan $size -An 'ensureOn') -CapturedNics (Global:D11Nics $false) -ManaDriver 'present'
                $r.Stop | Should -BeFalse -Because $size
                $r.Policy | Should -Be 'ensureOn'
                $r.ExpectFabric | Should -BeTrue
            }
        }
    }

    It 'a wave that keeps it OFF on v6 stops: Microsoft requires it there' {
        InModuleScope VmMigrationFactory {
            $r = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry (Global:D11Plan 'Standard_D2ds_v6' -An 'preserve') -CapturedNics (Global:D11Nics $false) -ManaDriver 'present'
            $r.Stop | Should -BeTrue
            $r.Reason | Should -Be 'acceleratedNetworkingRequired'
        }
    }

    It 'the plan turns it on for a machine with it off on v6, so the accepted wave settings name it' {
        InModuleScope VmMigrationFactory {
            Get-VmfPlannedAcceleratedNetworking -Vm ([pscustomobject]@{ acceleratedNicCount = 0 }) -TargetSize 'Standard_D2s_v6' | Should -Be 'ensureOn'
            Get-VmfPlannedAcceleratedNetworking -Vm ([pscustomobject]@{ primaryNicAccelerated = $false; acceleratedNicCount = 0 }) -TargetSize 'Standard_E2as_v6' | Should -Be 'ensureOn'
            Get-VmfPlannedAcceleratedNetworking -Vm ([pscustomobject]@{ acceleratedNicCount = 0 }) -TargetSize 'Standard_D2s_v7' | Should -BeNullOrEmpty
        }
    }

    # AN-MANA-DRIVER-RULE-1: rewritten. It stayed off on v7 (preserve). Now
    # Checking lets it on (the move turns it on), and Preparing stops for the
    # missing driver, untouched.
    It 'v7, off before, no MANA driver: Checking goes on, Preparing stops for the driver - it never stays off' {
        InModuleScope VmMigrationFactory {
            foreach ($size in 'Standard_D2ds_v7', 'Standard_E2as_v7', 'Standard_F2as_v7') {
                $early = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry (Global:D11Plan $size) -CapturedNics (Global:D11Nics $false) -ManaDriver ''
                $early.Stop | Should -BeFalse -Because "$size in Checking"
                $early.OnAfter | Should -BeTrue
                $r = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry (Global:D11Plan $size) -CapturedNics (Global:D11Nics $false) -ManaDriver 'absent'
                $r.Policy | Should -Not -Be 'preserve'
                $r.Stop | Should -BeTrue -Because $size
                $r.Reason | Should -Be 'driverBelowFloor'
            }
        }
    }
}

Describe 'DRIFT-11: the option a machine with accelerated networking off starts on' {

    It 'every v6 option of a machine with it off carries the approval stop' {
        $m = D11Advise (D11Vm -Os 'Windows' -Publisher 'MicrosoftWindowsServer' -Offer 'WindowsServer' -Sku '2022-datacenter-g2')
        (D11Opt $m 'v6').acceleratedNetworking.required | Should -BeTrue
        (D11Opt $m 'v6').acceleratedNetworking.turnsOn | Should -BeTrue
        @((D11Opt $m 'v6').stops) | Should -Be @('acceleratedNetworkingRequired')
        @((D11Opt $m 'v7').stops) | Should -Not -Contain 'acceleratedNetworkingRequired'
    }

    It 'Windows with it off still starts on v6: the approval turns it on, and Windows drives MANA' {
        $m = D11Advise (D11Vm -Os 'Windows' -Publisher 'MicrosoftWindowsServer' -Offer 'WindowsServer' -Sku '2022-datacenter-g2')
        $m.start.current | Should -Be 'v6'
    }

    It 'Linux, the agent says a release Microsoft lists (Ubuntu 22.04): v6, where turning it on gives it a driver' {
        $m = D11Advise (D11Vm -RunningName 'ubuntu' -RunningVersion '22.04' -Offer '0001-com-ubuntu-server-jammy' -Sku '22_04-lts-gen2')
        $m.start.current | Should -Be 'v6'
    }

    # AN-MANA-DRIVER-RULE-1: rewritten. It started on v7 with it kept off; it
    # has no target now - no size that can give MANA, and no AMD size.
    It 'Intel Linux, the agent says Ubuntu 18.04, it is off: no target - v7 is not offered either' {
        $m = D11Advise (D11Vm -RunningName 'ubuntu' -RunningVersion '18.04')
        $null -eq $m.start.current | Should -BeTrue
        $null -eq $m.start.extended | Should -BeTrue
        $null -eq $m.decide | Should -BeTrue
        foreach ($s in 'v5', 'v6', 'v7') { @((D11Opt $m $s).notSupported) | Should -Be @('no-mana-driver') }
    }

    It 'AMD Linux, the agent says Ubuntu 18.04, it is off: AMD v5 under both defaults, where Mellanox needs no MANA driver' {
        $m = D11Advise (D11Vm -Size 'Standard_D2as_v4' -RunningName 'ubuntu' -RunningVersion '18.04')
        $m.start.current | Should -Be 'v5'
        $m.start.extended | Should -Be 'v5'
        @((D11Opt $m 'v7').notSupported) | Should -Be @('no-mana-driver')
    }

    It 'only the IMAGE says Ubuntu 18.04: the start stays on v6 - the machine may run a listed release now' {
        $m = D11Advise (D11Vm)
        $m.start.current | Should -Be 'v6'
    }

    It 'no v7 size in the region: no start - no size that can give MANA is offered' {
        $m = D11Advise (D11Vm -RunningName 'ubuntu' -RunningVersion '18.04') -Catalog (D11Catalog -NoV7)
        $null -eq $m.start.current | Should -BeTrue
        @((D11Opt $m 'v6').notSupported) | Should -Be @('no-mana-driver')
    }

    # AN-MANA-DRIVER-RULE-1: rewritten. Select-VmfAnKeepingStart moved a
    # machine with it off whose release has no driver to the next option that
    # does not require it (v7), where it stayed off. That rule is gone with its
    # -Vm parameter: such a machine is offered no size that can give MANA.
    It 'the start rule no longer asks the machine' {
        InModuleScope VmMigrationFactory {
            (Get-Command Select-VmfAnKeepingStart).Parameters.ContainsKey('Vm') | Should -BeFalse
            $opts = @([ordered]@{ option = 'v6'; supported = $true; processorChange = $false
                    acceleratedNetworking = [ordered]@{ required = $true; mayUseMana = $true; keptOn = $null } })
            Select-VmfAnKeepingStart -Start 'v6' -Options $opts -Order @('v6') | Should -Be 'v6'
        }
    }
}

# AN-MANA-DRIVER-RULE-1 (2026-11-06): rewritten. This Describe held the
# card that kept the processor maker - Intel v7 with accelerated networking
# turned off (Select-VmfOwnMakerOption, Get-VmfAnMakerPolicy). That choice is
# gone: a machine that uses it with no MANA driver possible has no target.
Describe 'AN-MANA-DRIVER-RULE-1: a machine that uses it with no MANA driver has no card and no target' {

    It 'Intel, the agent says Ubuntu 18.04, it is on: no choice, no target' {
        $m = D11Advise (D11Vm -RunningName 'ubuntu' -RunningVersion '18.04' -Primary $true)
        $null -eq $m.decide | Should -BeTrue
        @($m.options | Where-Object supported).Count | Should -Be 0
    }

    It 'the functions of the card are gone' {
        InModuleScope VmMigrationFactory {
            foreach ($n in 'Get-VmfAnMakerPolicy', 'Select-VmfOwnMakerOption') { Get-Command $n -ErrorAction SilentlyContinue | Should -BeNullOrEmpty -Because $n }
        }
    }
}
