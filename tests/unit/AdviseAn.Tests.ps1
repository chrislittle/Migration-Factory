#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# ADVISE-AN-1: the option a machine starts on keeps the accelerated networking
# it uses today.
#
# Since 2026-10-10, the advice recommends a size that keeps accelerated
# networking, even a v5 rather than a v6. The target advice picked v6 by
# default whatever its facts said, so an Ubuntu 18.04 machine started on a v6
# size, where its kernel has no MANA driver: the move stops at GUEST_PREP, or
# goes on and loses the accelerated path.
#
# What the advice can know, and from where (it reads Azure, never the guest):
#   - the RUNNING Linux release, from the VM agent (Resource Graph's
#     instanceView osName and osVersion; empty when the machine is
#     deallocated). The scan records them from assessment v3.
#   - else the release of the IMAGE the machine was made from. A release only
#     goes up in place, so the image is the lowest release the machine can run.
#   - never the kernel: that is read from inside the machine, in the run.
# Microsoft's MANA table (data/driver-floors.json) lists releases. A release it
# lists can get MANA (with "Update the kernel" if its kernel is old -
# KERNEL-UX-1). A release it does not list cannot (RHEL8-MANA-1).
#
# The rule for the pick: a machine that uses accelerated networking today does
# not START on an option where it certainly stops working, when another
# supported option certainly keeps it. Unknown is never read as yes or no: an
# unknown option is neither avoided nor chosen for it. Windows always keeps it
# (AN-KEEP-1: Windows installs its in-box driver, and MANA-WIN-1 adds one).
# An Intel v5 size is never picked on the strength of Mellanox: its host can
# give MANA.

BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_MachineList.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:AaSku([string]$Name, [string]$TempMb = '0', [string]$Gens = 'V2', [string]$Vcpus = '2', [string]$Memory = '8') {
        [pscustomobject]@{ Name = $Name; Family = 'standardX'; ResourceType = 'virtualMachines'; Restrictions = @()
            Capabilities = @(
                [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = $TempMb }
                [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '4' }
                [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '8' }
                [pscustomobject]@{ Name = 'vCPUs'; Value = $Vcpus }
                [pscustomobject]@{ Name = 'MemoryGB'; Value = $Memory }
                [pscustomobject]@{ Name = 'HyperVGenerations'; Value = $Gens }) }
    }
    # Intel and AMD, v5 and v6, no temporary disk anywhere: only the network differs.
    function Global:AaCatalog([switch]$NoAmdV5) {
        $c = @{}
        $names = @('Standard_D2s_v5', 'Standard_D2s_v6', 'Standard_D2as_v6', 'Standard_D2s_v7')
        if (-not $NoAmdV5) { $names += 'Standard_D2as_v5' }
        foreach ($n in $names) { $c[$n] = AaSku $n '0' $(if ($n -like '*_v5') { 'V1,V2' } else { 'V2' }) }
        $c
    }
    function Global:AaVm {
        param([string]$Name = 'm', [string]$Size = 'Standard_D2s_v4', [string]$Os = 'Linux',
              [string]$Publisher = 'Canonical', [string]$Offer = 'UbuntuServer', [string]$Sku = '18.04-LTS',
              [string]$RunningName = '', [string]$RunningVersion = '',
              [object]$Primary = $true, [object]$AnCount = 1, [int]$Nics = 1, [string]$Gen = 'V2')
        [pscustomobject]@{
            vmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/$Name"
            name = $Name; location = 'centralus'; classification = 'ReadyAfterPrep'; gen = $Gen; os = $Os
            osVersion = $Sku; imagePublisher = $Publisher; imageOffer = $Offer; imageId = ''
            runningOsName = $RunningName; runningOsVersion = $RunningVersion
            sourceSize = $Size; sourceDiskArch = 'diskless'; sourceTempDisks = 0; diskController = 'SCSI'
            dataDiskCount = 0; nicCount = $Nics; acceleratedNicCount = $AnCount; primaryNicAccelerated = $Primary
            platformManaged = $false; blockers = @(); prepNeeded = @()
        }
    }
    function Global:AaAdvise([object[]]$Vms, [hashtable]$Catalog = (AaCatalog)) {
        $doc = [pscustomobject]@{ schemaVersion = 17; runId = 'scan-1'; vms = @($Vms) }
        InModuleScope VmMigrationFactory -Parameters @{ d = $doc; c = @{ centralus = $Catalog } } {
            Get-VmfTargetAdvice -Assessment $d -CatalogByLocation $c
        }
    }
    function Global:AaOpt($Machine, [string]$Option) { @($Machine.options) | Where-Object { $_.option -eq $Option } | Select-Object -First 1 }
    function Global:AaRelease([pscustomobject]$Vm) {
        InModuleScope VmMigrationFactory -Parameters @{ v = $Vm } { Get-VmfLinuxRelease -Vm $v }
    }
}
AfterAll { Remove-Item 'function:\AaSku', 'function:\AaCatalog', 'function:\AaVm', 'function:\AaAdvise', 'function:\AaOpt', 'function:\AaRelease' -ErrorAction SilentlyContinue }

Describe 'ADVISE-AN-1: the Linux release, from the VM agent first, then the image' {

    It 'the image <Publisher> <Offer> <Sku> is <Id> <Version>' -ForEach @(
        @{ Publisher = 'Canonical'; Offer = 'UbuntuServer'; Sku = '18.04-LTS'; Id = 'ubuntu'; Version = '18.04' }
        @{ Publisher = 'Canonical'; Offer = 'UbuntuServer'; Sku = '18_04-lts-gen2'; Id = 'ubuntu'; Version = '18.04' }
        @{ Publisher = 'Canonical'; Offer = '0001-com-ubuntu-server-focal'; Sku = '20_04-lts-gen2'; Id = 'ubuntu'; Version = '20.04' }
        @{ Publisher = 'Canonical'; Offer = '0001-com-ubuntu-server-jammy'; Sku = '22_04-lts-gen2'; Id = 'ubuntu'; Version = '22.04' }
        @{ Publisher = 'Canonical'; Offer = 'ubuntu-24_04-lts'; Sku = 'server'; Id = 'ubuntu'; Version = '24.04' }
        @{ Publisher = 'Canonical'; Offer = '0001-com-ubuntu-pro-bionic'; Sku = 'pro-18_04-lts'; Id = 'ubuntu'; Version = '18.04' }
        @{ Publisher = 'RedHat'; Offer = 'RHEL'; Sku = '8_10'; Id = 'rhel'; Version = '8.10' }
        @{ Publisher = 'RedHat'; Offer = 'RHEL'; Sku = '8.2'; Id = 'rhel'; Version = '8.2' }
        @{ Publisher = 'RedHat'; Offer = 'RHEL'; Sku = '94_gen2'; Id = 'rhel'; Version = '9.4' }
        @{ Publisher = 'RedHat'; Offer = 'RHEL'; Sku = '9-lvm-gen2'; Id = 'rhel'; Version = '9' }
        @{ Publisher = 'SUSE'; Offer = 'sles-15-sp5'; Sku = 'gen2'; Id = 'sles'; Version = '15.5' }
        @{ Publisher = 'SUSE'; Offer = 'sles-sap-15-sp4'; Sku = 'gen2'; Id = 'sles'; Version = '15.4' }
        @{ Publisher = 'Debian'; Offer = 'debian-12'; Sku = '12-gen2'; Id = 'debian'; Version = '12' }
        @{ Publisher = 'Debian'; Offer = 'debian-11'; Sku = '11'; Id = 'debian'; Version = '11' }
        @{ Publisher = 'Oracle'; Offer = 'Oracle-Linux'; Sku = 'ol810-lvm-gen2'; Id = 'ol'; Version = '8.10' }
        @{ Publisher = 'Oracle'; Offer = 'Oracle-Linux'; Sku = 'ol94-lvm-gen2'; Id = 'ol'; Version = '9.4' }
        @{ Publisher = 'MicrosoftCBLMariner'; Offer = 'azure-linux-3'; Sku = 'azure-linux-3-gen2'; Id = 'azurelinux'; Version = '3' }
        @{ Publisher = 'MicrosoftCBLMariner'; Offer = 'cbl-mariner'; Sku = 'cbl-mariner-2-gen2'; Id = 'azurelinux'; Version = '2' }
    ) {
        $r = AaRelease (AaVm -Publisher $Publisher -Offer $Offer -Sku $Sku)
        $r.distroId | Should -Be $Id
        $r.version | Should -Be $Version
        $r.source | Should -Be 'image'
    }

    It 'the VM agent decides when it reported the release: <Name> <Version> is <Id> <Expected>' -ForEach @(
        @{ Name = 'ubuntu'; Version = '22.04'; Id = 'ubuntu'; Expected = '22.04' }
        @{ Name = 'Ubuntu'; Version = '18.04'; Id = 'ubuntu'; Expected = '18.04' }
        @{ Name = 'rhel'; Version = '8.10'; Id = 'rhel'; Expected = '8.10' }
        @{ Name = 'redhat'; Version = '9.6'; Id = 'rhel'; Expected = '9.6' }
        @{ Name = 'sles'; Version = '15.5'; Id = 'sles'; Expected = '15.5' }
        @{ Name = 'debian'; Version = '12'; Id = 'debian'; Expected = '12' }
        @{ Name = 'ol'; Version = '9.4'; Id = 'ol'; Expected = '9.4' }
    ) {
        # The image says 18.04; an in-place upgrade does not change the image.
        $r = AaRelease (AaVm -RunningName $Name -RunningVersion $Version)
        $r.distroId | Should -Be $Id
        $r.version | Should -Be $Expected
        $r.source | Should -Be 'agent'
    }

    It 'a running name or version it cannot read is not a release: the image decides' -ForEach @(
        @{ Name = 'someos'; Version = '1.0' }, @{ Name = 'ubuntu'; Version = '' }, @{ Name = 'ubuntu'; Version = 'jammy' }, @{ Name = ''; Version = '22.04' }
    ) {
        $r = AaRelease (AaVm -RunningName $Name -RunningVersion $Version)
        $r.source | Should -Be 'image'
        $r.version | Should -Be '18.04'
    }

    It 'a custom image with no agent reading has no release - never a guess' {
        AaRelease (AaVm -Publisher '' -Offer '' -Sku '') | Should -BeNullOrEmpty
    }

    It 'an image it does not know has no release: <Publisher> <Offer> <Sku>' -ForEach @(
        @{ Publisher = 'contoso'; Offer = 'appliance'; Sku = '7' }
        @{ Publisher = 'RedHat'; Offer = 'RHEL'; Sku = 'rhel-raw' }
    ) {
        AaRelease (AaVm -Publisher $Publisher -Offer $Offer -Sku $Sku) | Should -BeNullOrEmpty
    }

    It 'a Windows machine has no Linux release' {
        AaRelease (AaVm -Os 'Windows' -Publisher 'MicrosoftWindowsServer' -Offer 'WindowsServer' -Sku '2022-datacenter-g2') | Should -BeNullOrEmpty
    }
}

Describe 'ADVISE-AN-1: does Microsoft list the release for MANA?' {

    It '<Id> <Version> from the <Source>: <Expected>' -ForEach @(
        @{ Id = 'ubuntu'; Version = '22.04'; Source = 'agent'; Expected = 'listed' }
        @{ Id = 'ubuntu'; Version = '24.04'; Source = 'image'; Expected = 'listed' }
        @{ Id = 'ubuntu'; Version = '18.04'; Source = 'image'; Expected = 'unlisted' }
        @{ Id = 'ubuntu'; Version = '20.04'; Source = 'agent'; Expected = 'unlisted' }
        @{ Id = 'rhel'; Version = '8.10'; Source = 'image'; Expected = 'unlisted' }
        @{ Id = 'rhel'; Version = '9.8'; Source = 'agent'; Expected = 'listed' }
        # AN-MANA-DRIVER-RULE-1: a running 9.4 is judged by the 9.6 row - a
        # normal update within 9 reaches it (minorReachedByUpdate).
        @{ Id = 'rhel'; Version = '9.4'; Source = 'agent'; Expected = 'listed' }
        @{ Id = 'rhel'; Version = '9.4'; Source = 'image'; Expected = 'listed' }
        @{ Id = 'rhel'; Version = '9'; Source = 'image'; Expected = 'unknown' }
        @{ Id = 'sles'; Version = '15.4'; Source = 'image'; Expected = 'unknown' }
        @{ Id = 'sles'; Version = '15.4'; Source = 'agent'; Expected = 'unlisted' }
        @{ Id = 'debian'; Version = '12'; Source = 'image'; Expected = 'listed' }
        @{ Id = 'debian'; Version = '11'; Source = 'image'; Expected = 'unlisted' }
        @{ Id = 'azurelinux'; Version = '3'; Source = 'image'; Expected = 'listed' }
        @{ Id = 'azurelinux'; Version = '2'; Source = 'image'; Expected = 'unlisted' }
        @{ Id = 'ol'; Version = '9.4'; Source = 'agent'; Expected = 'listed' }
        # Oracle Linux 8 on UEK R8 is listed on any release, and the kernel is
        # read only from inside the machine: unknown, never a no.
        @{ Id = 'ol'; Version = '8.10'; Source = 'agent'; Expected = 'unknown' }
        @{ Id = 'centos'; Version = '7'; Source = 'agent'; Expected = 'unlisted' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ r = @{ distroId = $Id; version = $Version; source = $Source }; e = $Expected } {
            Get-VmfManaReleaseListing -Release $r | Should -Be $e
        }
    }

    It 'no release is unknown' {
        InModuleScope VmMigrationFactory { Get-VmfManaReleaseListing -Release $null | Should -Be 'unknown' }
    }
}

Describe 'ADVISE-AN-1: does accelerated networking stay on, per option' {

    It '<Case>' -ForEach @(
        @{ Case = 'AMD v5 on Linux of any release: on, on Mellanox'; Os = 'Linux'; Move = 'scsi-resize'; Mana = $false; Listing = 'unlisted'; Kept = $true; Why = $null }
        @{ Case = 'v6 on a release Microsoft lists: on'; Os = 'Linux'; Move = 'nvme-conversion'; Mana = $true; Listing = 'listed'; Kept = $true; Why = $null }
        @{ Case = 'v6 on a release Microsoft does not list: off'; Os = 'Linux'; Move = 'nvme-conversion'; Mana = $true; Listing = 'unlisted'; Kept = $false; Why = 'unlisted' }
        @{ Case = 'Intel v5 on a release Microsoft does not list: unknown, the host decides'; Os = 'Linux'; Move = 'scsi-resize'; Mana = $true; Listing = 'unlisted'; Kept = $null; Why = 'host' }
        @{ Case = 'Intel v5 on a release Microsoft lists: on'; Os = 'Linux'; Move = 'scsi-resize'; Mana = $true; Listing = 'listed'; Kept = $true; Why = $null }
        @{ Case = 'v6 on a release nobody could read: unknown'; Os = 'Linux'; Move = 'nvme-conversion'; Mana = $true; Listing = 'unknown'; Kept = $null; Why = 'release-unknown' }
        @{ Case = 'Windows on v6: on - never "cannot drive MANA" (AN-KEEP-1)'; Os = 'Windows'; Move = 'nvme-conversion'; Mana = $true; Listing = 'unknown'; Kept = $true; Why = $null }
        @{ Case = 'Windows on Intel v5: on'; Os = 'Windows'; Move = 'scsi-resize'; Mana = $true; Listing = 'unknown'; Kept = $true; Why = $null }
        @{ Case = 'a v5 size whose name cannot be read: unknown'; Os = 'Linux'; Move = 'scsi-resize'; Mana = $null; Listing = 'listed'; Kept = $null; Why = 'size-unreadable' }
        @{ Case = 'v6 on a release only the image gives, unlisted: unknown, never a no (review finding 1)'; Os = 'Linux'; Move = 'nvme-conversion'; Mana = $true; Listing = 'unlisted'; Source = 'image'; Kept = $null; Why = 'image-unlisted' }
        @{ Case = 'AMD v5 on the same: on'; Os = 'Linux'; Move = 'scsi-resize'; Mana = $false; Listing = 'unlisted'; Source = 'image'; Kept = $true; Why = $null }
    ) {
        $src = if ($Source) { $Source } else { 'agent' }
        InModuleScope VmMigrationFactory -Parameters @{ o = $Os; mv = $Move; mn = $Mana; l = $Listing; k = $Kept; w = $Why; s = $src } {
            $r = Get-VmfAnKeptOn -Os $o -UsesAn $true -Move $mv -MayUseMana $mn -Listing $l -ReleaseSource $s
            $r.KeptOn | Should -Be $k
            $r.Why | Should -Be $w
        }
    }

    It 'a machine that does not use it today, or whose scan did not say, gets no answer' -ForEach @(@{ Uses = $false }, @{ Uses = $null }) {
        InModuleScope VmMigrationFactory -Parameters @{ u = $Uses } {
            $r = Get-VmfAnKeptOn -Os 'Linux' -UsesAn $u -Move 'nvme-conversion' -MayUseMana $true -Listing 'unlisted'
            $null -eq $r.KeptOn | Should -BeTrue
            $null -eq $r.Why | Should -BeTrue
        }
    }

    It 'uses it today: <Case>' -ForEach @(
        @{ Case = 'the primary interface has it'; Primary = $true; Count = 1; Nics = 2; Expected = $true }
        @{ Case = 'the primary interface does not'; Primary = $false; Count = 1; Nics = 2; Expected = $false }
        @{ Case = 'no primary reading, one interface, on'; Primary = $null; Count = 1; Nics = 1; Expected = $true }
        @{ Case = 'no primary reading, none on'; Primary = $null; Count = 0; Nics = 2; Expected = $false }
        @{ Case = 'no primary reading, two interfaces, one on: unknown'; Primary = $null; Count = 1; Nics = 2; Expected = $null }
        @{ Case = 'nothing read'; Primary = $null; Count = $null; Nics = 1; Expected = $null }
    ) {
        $vm = AaVm -Primary $Primary -AnCount $Count -Nics $Nics
        InModuleScope VmMigrationFactory -Parameters @{ v = $vm; e = $Expected } {
            $u = Test-VmfUsesAcceleratedNetworking -Vm $v
            if ($null -eq $e) { $null -eq $u | Should -BeTrue } else { $u | Should -Be $e }
        }
    }
}

Describe 'ADVISE-AN-1: the option a machine starts on keeps accelerated networking' {
    # Review finding 1: only a release the VM agent reports - the release that
    # RUNS - may move a start or open a choice. An image release cannot prove
    # the machine still runs it, so it only marks the size (keptOn null,
    # keptOnWhy image-unlisted) and the start stays where it was.

    # AN-MANA-DRIVER-RULE-1 (2026-11-06): rewritten. The Intel machine
    # below had a choice between its Intel v7 size with accelerated networking
    # off and an AMD v5 size (processor-or-an). No size that can give MANA is
    # offered to it now, and never an AMD size, so it has no target. The AMD
    # machine keeps its AMD v5 size; v6 and v7 are refused with no-mana-driver.
    It 'AMD D2as_v4, the agent says Ubuntu 18.04, accelerated networking on: starts on AMD v5, and v6 and v7 are not offered' {
        $m = @((AaAdvise @(AaVm -Size 'Standard_D2as_v4' -RunningName 'ubuntu' -RunningVersion '18.04')).machines)[0]
        $m.start.current | Should -Be 'v5'
        $m.start.extended | Should -Be 'v5'
        $null -eq $m.decide | Should -BeTrue
        (AaOpt $m 'v5').targetSize | Should -Be 'Standard_D2as_v5'
        (AaOpt $m 'v5').acceleratedNetworking.keptOn | Should -BeTrue
        @((AaOpt $m 'v6').notSupported) | Should -Be @('no-mana-driver')
        (AaOpt $m 'v7').supported | Should -BeFalse -Because 'the catalog here has no AMD v7 size; AnManaDriverRule.Tests.ps1 holds no-mana-driver for it'
        $m.linuxRelease.source | Should -Be 'agent'
        $m.linuxRelease.mana | Should -Be 'unlisted'
        $m.linuxRelease.manaUpgrade.version | Should -Be '22.04'
    }

    It 'AMD D2as_v4, only the IMAGE says Ubuntu 18.04: the start stays on v6, marked - an upgraded machine may run a listed release' {
        $m = @((AaAdvise @(AaVm -Size 'Standard_D2as_v4')).machines)[0]
        $m.start.current | Should -Be 'v6'
        $null -eq $m.decide | Should -BeTrue
        $null -eq (AaOpt $m 'v6').acceleratedNetworking.keptOn | Should -BeTrue
        (AaOpt $m 'v6').acceleratedNetworking.keptOnWhy | Should -Be 'image-unlisted'
        (AaOpt $m 'v5').acceleratedNetworking.keptOn | Should -BeTrue -Because 'AMD v5 gives Mellanox, whatever the release'
        $m.linuxRelease.source | Should -Be 'image'
        $null -eq $m.linuxRelease.manaUpgrade | Should -BeTrue
    }

    It 'Intel D2s_v4, the agent says Ubuntu 18.04: no target, no choice, never an AMD size' {
        $m = @((AaAdvise @(AaVm -Size 'Standard_D2s_v4' -RunningName 'ubuntu' -RunningVersion '18.04')).machines)[0]
        $null -eq $m.start.current | Should -BeTrue
        $null -eq $m.start.extended | Should -BeTrue
        $null -eq $m.decide | Should -BeTrue
        foreach ($s in 'v5', 'v6', 'v7') {
            (AaOpt $m $s).supported | Should -BeFalse -Because $s
            @((AaOpt $m $s).notSupported) | Should -Be @('no-mana-driver')
            @((AaOpt $m $s).sizeChoices).Count | Should -Be 0
        }
    }

    It 'Intel D2s_v4, only the IMAGE says Ubuntu 18.04: no AMD size - v6 stays, marked' {
        $m = @((AaAdvise @(AaVm -Size 'Standard_D2s_v4')).machines)[0]
        $m.start.current | Should -Be 'v6'
        $m.start.extended | Should -Be 'v5'
        $null -eq $m.decide | Should -BeTrue
        @(@((AaOpt $m 'v5').sizeChoices) | Where-Object { $_.processorChange }).Count | Should -Be 0
        (AaOpt $m 'v6').acceleratedNetworking.keptOnWhy | Should -Be 'image-unlisted'
    }

    It 'no machine waits for a choice of processor, and no option changes it: <Case>' -ForEach @(
        @{ Case = 'accelerated networking off today'; Size = 'Standard_D2s_v4'; Os = 'Linux'; Primary = $false; Count = 0; Name = 'ubuntu'; Ver = '18.04'; Start = $null }
        @{ Case = 'a release Microsoft lists'; Size = 'Standard_D2s_v4'; Os = 'Linux'; Primary = $true; Count = 1; Name = 'ubuntu'; Ver = '22.04'; Start = 'v6' }
        @{ Case = 'Windows'; Size = 'Standard_D2s_v4'; Os = 'Windows'; Primary = $true; Count = 1; Name = 'Windows Server 2022 Datacenter'; Ver = '10.0.20348'; Start = 'v6' }
        @{ Case = 'an AMD machine'; Size = 'Standard_D2as_v4'; Os = 'Linux'; Primary = $true; Count = 1; Name = 'ubuntu'; Ver = '18.04'; Start = 'v5' }
        @{ Case = 'the scan did not say whether it uses it'; Size = 'Standard_D2s_v4'; Os = 'Linux'; Primary = $null; Count = $null; Name = 'ubuntu'; Ver = '18.04'; Start = $null }
    ) {
        $vm = AaVm -Size $Size -Os $Os -Primary $Primary -AnCount $Count -RunningName $Name -RunningVersion $Ver
        $m = @((AaAdvise @($vm)).machines)[0]
        $null -eq $m.decide | Should -BeTrue
        foreach ($o in @($m.options | Where-Object supported)) { $o.processorChange | Should -BeFalse }
        $m.start.current | Should -Be $Start
    }

    It 'Intel, the agent says Ubuntu 18.04, with no AMD v5 size in the region or a smaller one: still no target, never a bigger size' {
        $small = AaCatalog
        $small['Standard_D2as_v5'] = AaSku 'Standard_D2as_v5' '0' 'V1,V2' '2' '4'
        foreach ($cat in @((AaCatalog -NoAmdV5), $small)) {
            $m = @((AaAdvise @(AaVm -Size 'Standard_D2s_v4' -RunningName 'ubuntu' -RunningVersion '18.04') -Catalog $cat).machines)[0]
            $null -eq $m.decide | Should -BeTrue
            @($m.options | Where-Object supported).Count | Should -Be 0
            @((AaOpt $m 'v5').notSupported) | Should -Be @('no-mana-driver')
        }
    }


    It 'Intel D2s_v4, Ubuntu 22.04: v6, where an old kernel can be updated (KERNEL-UX-1) - the pick does not fight that choice' {
        $m = @((AaAdvise @(AaVm -Size 'Standard_D2s_v4' -Offer '0001-com-ubuntu-server-jammy' -Sku '22_04-lts-gen2')).machines)[0]
        $m.start.current | Should -Be 'v6'
        (AaOpt $m 'v6').acceleratedNetworking.keptOn | Should -BeTrue
        $m.linuxRelease.mana | Should -Be 'listed'
    }

    It 'the VM agent says the machine runs 22.04 while its image says 18.04: AMD stays on v6' {
        $m = @((AaAdvise @(AaVm -Size 'Standard_D2as_v4' -RunningName 'ubuntu' -RunningVersion '22.04')).machines)[0]
        $m.start.current | Should -Be 'v6'
        $m.linuxRelease.source | Should -Be 'agent'
    }

    It 'AMD, the release unknown (custom image, deallocated): today''s default, and why is recorded' {
        $m = @((AaAdvise @(AaVm -Size 'Standard_D2as_v4' -Publisher '' -Offer '' -Sku '')).machines)[0]
        $m.start.current | Should -Be 'v6'
        $null -eq (AaOpt $m 'v6').acceleratedNetworking.keptOn | Should -BeTrue
        (AaOpt $m 'v6').acceleratedNetworking.keptOnWhy | Should -Be 'release-unknown'
        $m.linuxRelease.mana | Should -Be 'unknown'
    }

    It 'AMD Windows Server 2022: v6 - Windows drives MANA after the move' {
        $vm = AaVm -Size 'Standard_D2as_v4' -Os 'Windows' -Publisher 'MicrosoftWindowsServer' -Offer 'WindowsServer' -Sku '2022-datacenter-g2'
        $m = @((AaAdvise @($vm)).machines)[0]
        $m.start.current | Should -Be 'v6'
        (AaOpt $m 'v6').acceleratedNetworking.keptOn | Should -BeTrue
        $null -eq $m.linuxRelease | Should -BeTrue
    }

    # AN-MANA-DRIVER-RULE-1: rewritten. A Generation 1 Intel machine sized by
    # shape got the AMD size of its best choice, as a choice of one card. It
    # has no target now: every Intel v5 size can give MANA.
    It 'a Generation 1 Intel machine sized by shape, the agent says Ubuntu 18.04: no target, no AMD size' {
        $vm = AaVm -Size 'Standard_DS2_v2' -Gen 'V1' -RunningName 'ubuntu' -RunningVersion '18.04'
        $cat = AaCatalog
        $cat['Standard_DS2_v2'] = AaSku 'Standard_DS2_v2' '0' 'V1,V2'
        $m = @((AaAdvise @($vm) -Catalog $cat).machines)[0]
        $o = AaOpt $m 'v5'
        $o.supported | Should -BeFalse
        @($o.notSupported) | Should -Be @('no-mana-driver')
        @($o.sizeChoices).Count | Should -Be 0
        $null -eq $m.decide | Should -BeTrue
        $null -eq $m.start.current | Should -BeTrue
        $null -eq $m.start.extended | Should -BeTrue
    }

    It 'the target rules refuse an AMD size for an Intel machine by name, and give such a release no size that can give MANA' {
        $cat = AaCatalog
        $agent = AaVm -Size 'Standard_D2s_v4' -RunningName 'ubuntu' -RunningVersion '18.04'
        $image = AaVm -Size 'Standard_D2s_v4'
        InModuleScope VmMigrationFactory -Parameters @{ a = $agent; i = $image; c = $cat } {
            (Resolve-VmfEntryTarget -Assessment $a -CatalogBySize $c -TargetGeneration 'v5' -ChosenSize 'Standard_D2as_v5').Mapping.Code | Should -Be 'chosen-size-gone'
            (Resolve-VmfEntryTarget -Assessment $i -CatalogBySize $c -TargetGeneration 'v5' -ChosenSize 'Standard_D2as_v5').Mapping.Code | Should -Be 'chosen-size-gone'
            foreach ($g in 'v5', 'v6', 'v7') {
                $t = Resolve-VmfEntryTarget -Assessment $a -CatalogBySize $c -TargetGeneration $g
                $t.Mapping.Code | Should -Be 'no-mana-driver' -Because $g
                $null -eq $t.Mapping.Target | Should -BeTrue
            }
        }
    }


    It 'an option that keeps it but is not supported is never a start' {
        # A size the region has, refused for this machine (a blocker, a
        # rebuild of an encrypted machine): its keptOn is still worked out,
        # and it must not become the start.
        $opts = @(
            [ordered]@{ option = 'v5'; supported = $false; acceleratedNetworking = @{ keptOn = $true } }
            [ordered]@{ option = 'v6'; supported = $true; acceleratedNetworking = @{ keptOn = $false } }
            [ordered]@{ option = 'v7'; supported = $true; acceleratedNetworking = @{ keptOn = $null } })
        InModuleScope VmMigrationFactory -Parameters @{ o = $opts } {
            Select-VmfAnKeepingStart -Start 'v6' -Options $o -Order @('v6', 'v7', 'v5') | Should -Be 'v6'
            Select-VmfAnKeepingStart -Start $null -Options $o -Order @('v6', 'v7', 'v5') | Should -BeNullOrEmpty
        }
    }

    It 'the document validates against the schema' {
        $cat = AaCatalog
        $cat['Standard_DS2_v2'] = AaSku 'Standard_DS2_v2' '0' 'V1,V2'
        $advice = AaAdvise @((AaVm -Name 'a' -Size 'Standard_D2as_v4'), (AaVm -Name 'b' -Size 'Standard_DS2_v2' -Gen 'V1'),
            (AaVm -Name 'd' -Size 'Standard_D2s_v4' -RunningName 'ubuntu' -RunningVersion '18.04'),
            (AaVm -Name 'c' -Os 'Windows' -Publisher 'MicrosoftWindowsServer' -Offer 'WindowsServer' -Sku '2022-datacenter-g2')) -Catalog $cat
        $advice | ConvertTo-Json -Depth 20 | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json') | Should -BeTrue
    }

    It 'the version is 21 (18 was this rule; 19 is DETECT-PATTERNS-1; 20 is HDD-OS-1; 21 is IDENTITY-LOSS-1): a v17 file picks without this rule, so it is refused and made again' {
        InModuleScope VmMigrationFactory { Get-VmfTargetAdviceSchemaVersion | Should -Be 33 }
        $s = Get-Content (Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json') -Raw | ConvertFrom-Json -Depth 30
        $s.properties.schemaVersion.const | Should -Be 33
        ((Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.html'))) | Should -Match 'const TARGET_ADVICE_VERSION = 33;'
    }
}

Describe 'ADVISE-AN-1: the scan records the running release (assessment v3)' {

    It 'Resource Graph is asked for the running OS version beside its name' {
        $code = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'assess' 'Discovery.ps1') -Raw
        $code | Should -Match 'osVersionRunning = tostring\(properties\.extended\.instanceView\.osVersion\)'
        $code | Should -Match '(?m)^\s*\| project id, .*osName, osVersionRunning,'
    }

    It 'the record carries both, empty when the agent reported nothing' {
        $vm = [pscustomobject]@{
            id = '/s/rg/vm/a'; name = 'a'; resourceGroup = 'rg'; location = 'centralus'; sku = 'Standard_D2s_v4'; os = 'Linux'; gen = 'V2'
            diskController = 'SCSI'; osDiskManagedId = '/s/rg/disks/a'; nicCount = 1; osName = 'ubuntu'; osVersionRunning = '18.04'
            imagePublisher = 'Canonical'; imageOffer = 'UbuntuServer'; imageSku = '18.04-LTS'
        }
        $r = InModuleScope VmMigrationFactory -Parameters @{ v = $vm } { Get-VmfAssessmentRecord -Vm $v }
        $r.runningOsName | Should -Be 'ubuntu'
        $r.runningOsVersion | Should -Be '18.04'
        $vm.osName = ''; $vm.osVersionRunning = ''
        $r = InModuleScope VmMigrationFactory -Parameters @{ v = $vm } { Get-VmfAssessmentRecord -Vm $v }
        $r.runningOsName | Should -Be ''
        $r.runningOsVersion | Should -Be ''
    }

    It 'the version is 8 (REBUILD-PATCH-MODE-1; 7 was REBUILD-ACCEPT-1; 6 was CLUSTER-DETECT-1; 5 was HDD-OS-1; 4 was DETECT-PATTERNS-1; 3 was this item); 1 and 2 are still read, and their machines have no running release' {
        InModuleScope VmMigrationFactory {
            Get-VmfAssessmentSchemaVersion | Should -Be 17
            { Assert-VmfSupportedAssessment -Assessment ([pscustomobject]@{ schemaVersion = 2 }) } | Should -Throw '*reads only version 17*'
            { Assert-VmfSupportedAssessment -Assessment ([pscustomobject]@{ schemaVersion = 18 }) } | Should -Throw '*understands up to 17*'
        }
        $s = Get-Content (Join-Path $script:repoRoot 'schemas' 'assessment.schema.json') -Raw | ConvertFrom-Json -Depth 30
        $s.properties.schemaVersion.const | Should -Be 17
        $s.properties.vms.items.properties.runningOsName | Should -Not -BeNullOrEmpty
        $s.properties.vms.items.properties.runningOsVersion | Should -Not -BeNullOrEmpty
        # A v2 machine: the image decides.
        $old = AaVm
        $old.PSObject.Properties.Remove('runningOsName'); $old.PSObject.Properties.Remove('runningOsVersion')
        (AaRelease $old).source | Should -Be 'image'
    }
}

Describe 'AN-MANA-DRIVER-RULE-1: a machine with no MANA driver possible is not moved, on the real save and plan' {
    # Rewritten (2026-11-06). This Describe held ADVISE-AN-1's choice
    # between the processor and accelerated networking (OWNER-QUESTIONS-1 row
    # 33): the save and the plan refused until api-03 had a choice, the Intel
    # v7 card planned ensureOff, and the AMD card planned the AMD size. Both
    # cards are gone: api-03 (Intel, the VM agent reports Ubuntu 18.04) is
    # offered no size that can give MANA and never an AMD size, so it has no
    # target, nothing waits for a choice, and the plan says what to do.

    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-aa-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:mig = "$($script:rp)-mig"
        $one = AaVm -Name 'api-03' -Size 'Standard_D2s_v4' -RunningName 'ubuntu' -RunningVersion '18.04'
        $two = AaVm -Name 'app-01' -Size 'Standard_D2s_v4' -Offer '0001-com-ubuntu-server-jammy' -Sku '22_04-lts-gen2'
        $vms = foreach ($v in @($one, $two)) {
            $h = [ordered]@{}; foreach ($pr in $v.PSObject.Properties) { $h[$pr.Name] = $pr.Value }
            $h.resourceGroup = 'rg'; $h.zones = @(); $h.iacManaged = $false; $h.hibernationEnabled = $false; $h.availabilitySetId = ''
            $h.identityType = 'None'; $h.tags = @{ app = $h.name }; $h }
        $doc = [ordered]@{ schemaVersion = 17; runId = (Split-Path $script:rp -Leaf); generatedUtc = '2026-10-11T00:00:00Z'
            scope = @{ subscriptions = @() }; summary = @{}; vms = @($vms) }
        InModuleScope VmMigrationFactory -Parameters @{ r = $script:rp; d = $doc } {
            Initialize-VmfRun -RunPath $r -RunId (Split-Path $r -Leaf) -Kind 'assessment' | Out-Null
            Write-VmfStoreJson -RunPath $r -RelPath 'assessment.json' -Document $d -Depth 24
        }
        $script:catalogList = @((AaCatalog).Values)
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { $script:catalogList }
        Approve-VmfAssessment -RunPath $script:rp -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } | Out-Null
        New-VmfTargetAdvice -AssessmentPath (Join-Path $script:rp 'assessment.json') | Out-Null
        $script:version = InModuleScope VmMigrationFactory -Parameters @{ r = $script:rp } {
            Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $r -RelPath 'target-advice.json')) }
        $script:id = { param([string]$Name) "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/$Name" }
        # AN-MANA-DRIVER-RULE-1: api-03 has no target, so it cannot be chosen
        # (Set-VmfMachineChoice refuses it); app-01 is chosen, as the wizard does it.
        Set-VmfMachineChoice -RunPath $script:rp -Machines @((& $script:id 'app-01')) -ExpectedAdviceVersion $script:version `
            -OnBehalfOf @{ Identity = 'operator@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } | Out-Null
        $script:machines = InModuleScope VmMigrationFactory -Parameters @{ r = $script:rp } {
            Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $r -RelPath 'machine-choices.json')) }
        $script:save = { param($Choices)
            Set-VmfTestTargetChoice -RunPath $script:rp -Choices $Choices -Default 'current' -ExpectedAdviceVersion $script:version `
                -ExpectedChoicesVersion '' -ExpectedMachinesVersion $script:machines -OnBehalfOf @{ Identity = 'operator@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } }
    }
    AfterEach { foreach ($d in @($script:rp, $script:mig)) { if (Test-Path $d) { Remove-Item $d -Recurse -Force } } }

    It 'it cannot be chosen for a migration, the save needs no choice for it, and a target for it is refused' {
        { Set-VmfMachineChoice -RunPath $script:rp -Machines @((& $script:id 'api-03'), (& $script:id 'app-01')) -ExpectedAdviceVersion $script:version `
            -ExpectedChoiceVersion $script:machines -OnBehalfOf @{ Identity = 'operator@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } } |
            Should -Throw "400: The machine 'api-03' cannot move on any size series*"
        { & $script:save @(@{ vmId = (& $script:id 'app-01'); option = 'v6' }, @{ vmId = (& $script:id 'api-03'); option = 'v5'; size = 'Standard_D2as_v5' }) } |
            Should -Throw '400:*'
        { & $script:save @(@{ vmId = (& $script:id 'app-01'); option = 'v6' }) } | Should -Not -Throw
    }

    It 'the advice counts it as a machine with no target' {
        $r = New-VmfTargetAdvice -AssessmentPath (Join-Path $script:rp 'assessment.json')
        $r.WithTarget | Should -Be 1
    }

    It 'a plan with no saved targets does not move it on any series, and says what to do' {
        foreach ($g in 'v5', 'v6', 'v7') {
            if (Test-Path $script:mig) { Remove-Item $script:mig -Recurse -Force }
            New-VmfPlan -AssessmentPath (Join-Path $script:rp 'assessment.json') -OutPath $script:mig -TargetGeneration $g | Out-Null
            # It is not chosen for the migration (it cannot be), so the plan
            # holds it as not moved with the reason, or not at all.
            $entry = @((Get-Content (Join-Path $script:mig 'plan.json') -Raw | ConvertFrom-Json -Depth 30).entries) | Where-Object { $_.vmId -like '*/api-03' }
            if ($entry) {
                $entry.path | Should -Be 'MANUAL' -Because $g
                $null -eq $entry.target.size | Should -BeTrue
                ($entry.planNotes -join ' ') | Should -Match 'Upgrade the operating system to ubuntu 22\.04'
            }
            @((Get-Content (Join-Path $script:mig 'plan.json') -Raw | ConvertFrom-Json -Depth 30).entries | Where-Object { $_.path -in @('A', 'B') -and $_.vmId -like '*/api-03' }).Count | Should -Be 0
        }
    }

    It 'the engine refuses a plan entry for it that keeps accelerated networking off on Intel v7, in Checking' {
        $entry = [pscustomobject]@{ assessment = (AaVm -Name 'api-03' -Size 'Standard_D2s_v4' -RunningName 'ubuntu' -RunningVersion '18.04')
            target = [pscustomobject]@{ size = 'Standard_D2s_v7'; controller = 'NVMe' }; path = 'A'
            policy = [pscustomobject]@{ onDriverBelowFloor = 'stop'; acceleratedNetworking = 'preserve' } }
        $nics = @([pscustomobject]@{ id = '/nic/a'; primary = $true; acceleratedNetworking = $false })
        InModuleScope VmMigrationFactory -Parameters @{ e = $entry; n = $nics } {
            $an = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry $e -CapturedNics $n
            $an.Stop | Should -BeTrue
            $an.Reason | Should -Be 'acceleratedNetworkingRequired'
        }
    }

    It 'the wave editor offers it no series: there is nothing to plan it on' {
        InModuleScope VmMigrationFactory -Parameters @{ v = (AaVm -Name 'api-03' -Size 'Standard_D2s_v4' -RunningName 'ubuntu' -RunningVersion '18.04'); c = (AaCatalog) } {
            foreach ($g in 'v5', 'v6', 'v7') {
                $null -eq (Resolve-VmfEntryTarget -Assessment $v -CatalogBySize $c -TargetGeneration $g).Mapping.Target | Should -BeTrue -Because $g
            }
        }
    }

    It 'the save and the plan go on without it' {
        # MACHINE-PICK-1: a machine not chosen in the first step gets no target,
        # so it must never hold the save or the plan - or it is a dead end.
        Set-VmfMachineChoice -RunPath $script:rp -Machines @((& $script:id 'app-01')) -ExpectedAdviceVersion $script:version `
            -ExpectedChoiceVersion $script:machines -OnBehalfOf @{ Identity = 'operator@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } | Out-Null
        $script:machines = InModuleScope VmMigrationFactory -Parameters @{ r = $script:rp } {
            Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $r -RelPath 'machine-choices.json')) }
        { & $script:save @(@{ vmId = (& $script:id 'app-01'); option = 'v6' }) } | Should -Not -Throw
        { New-VmfPlan -AssessmentPath (Join-Path $script:rp 'assessment.json') -OutPath $script:mig -RequireTargets } | Should -Not -Throw
        @((Get-Content (Join-Path $script:mig 'plan.json') -Raw | ConvertFrom-Json -Depth 30).entries).vmId | Should -Not -Contain (& $script:id 'api-03')
    }

    It 'since 2026-10-12: the offer itself, for a plan entry and for the advice' {
        $agent = AaVm -Size 'Standard_D2s_v4' -RunningName 'ubuntu' -RunningVersion '18.04'
        $image = AaVm -Size 'Standard_D2s_v4'
        $listed = AaVm -Size 'Standard_D2s_v4' -RunningName 'ubuntu' -RunningVersion '22.04'
        InModuleScope VmMigrationFactory -Parameters @{ a = $agent; i = $image; l = $listed } {
            $entry = { param($v) [pscustomobject]@{ assessment = $v; target = [pscustomobject]@{ size = 'Standard_D2s_v6'; controller = 'NVMe' } } }
            Test-VmfKernelUpdateOfferedForEntry -PlanEntry (& $entry $a) | Should -BeFalse
            Test-VmfKernelUpdateOfferedForEntry -PlanEntry (& $entry $i) | Should -BeTrue -Because 'only the image says 18.04: today''s behaviour'
            Test-VmfKernelUpdateOfferedForEntry -PlanEntry (& $entry $l) | Should -BeTrue
            Test-VmfReleaseKnownUnlisted -Vm $a | Should -BeTrue
            Test-VmfReleaseKnownUnlisted -Vm $i | Should -BeFalse
            Test-VmfReleaseKnownUnlisted -Vm $l | Should -BeFalse
        }
    }
}

Describe 'ADVISE-AN-1: the values Azure gives, MEASURED 2026-10-11' {
    # Five lab machines in centralus, VM agent Ready. Azure's instanceView and
    # Resource Graph's properties.extended.instanceView gave the same values on
    # all four reads over seven minutes, the first about four minutes after
    # create. Note 'redhat', not 'rhel'; SLES as 15.5; Ubuntu with no point
    # release.

    It 'measured: <Image> runs <Name> <Version> - read as <Id> <Expected>, <Listing> for MANA' -ForEach @(
        @{ Image = 'Canonical:UbuntuServer:18.04-LTS'; Name = 'ubuntu'; Version = '18.04'; Id = 'ubuntu'; Expected = '18.04'; Listing = 'unlisted' }
        @{ Image = 'Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2'; Name = 'ubuntu'; Version = '22.04'; Id = 'ubuntu'; Expected = '22.04'; Listing = 'listed' }
        @{ Image = 'RedHat:RHEL:8_10'; Name = 'redhat'; Version = '8.10'; Id = 'rhel'; Expected = '8.10'; Listing = 'unlisted' }
        @{ Image = 'SUSE:sles-15-sp5:gen2'; Name = 'sles'; Version = '15.5'; Id = 'sles'; Expected = '15.5'; Listing = 'listed' }
        @{ Image = 'Debian:debian-12:12-gen2'; Name = 'debian'; Version = '12'; Id = 'debian'; Expected = '12'; Listing = 'listed' }
    ) {
        $pub, $off, $sku = $Image -split ':'
        # The running release, as the agent reports it.
        $r = AaRelease (AaVm -Publisher $pub -Offer $off -Sku $sku -RunningName $Name -RunningVersion $Version)
        $r.source | Should -Be 'agent'
        $r.distroId | Should -Be $Id
        $r.version | Should -Be $Expected
        InModuleScope VmMigrationFactory -Parameters @{ r = $r; l = $Listing } { Get-VmfManaReleaseListing -Release $r | Should -Be $l }
        # And the image alone (a deallocated machine) gives the same release.
        $i = AaRelease (AaVm -Publisher $pub -Offer $off -Sku $sku)
        $i.source | Should -Be 'image'
        $i.distroId | Should -Be $Id
        $i.version | Should -Be $Expected
    }
}
