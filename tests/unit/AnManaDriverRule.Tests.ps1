#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# AN-MANA-DRIVER-RULE-1 (2026-11-06): a target that MIGHT give MANA
# needs a machine with a MANA driver. Might give MANA: every v6 and v7 size,
# Intel and AMD, Intel v5 and Bsv2. Does not: AMD v5.
#
# Before: an Intel Linux machine whose release Microsoft does not list for
# MANA was offered its Intel v7 size with accelerated networking turned OFF
# (ensureOff) or an AMD v5 size; a machine with it off today started on v7 and
# kept it off; and the engine kept a primary that was off as it was on any v7
# or Bsv2 size ('preserve'). Measured 2026-11-06 (centralus, Ubuntu 22.04, one
# region, one day): with the interface's accelerated networking set to false,
# Azure still attached the virtual function on Intel v5, Bsv2, AMD v6, Intel
# v6 and v7 and AMD v7. So off is not off there, and the machine ran on the
# synthetic interface. The rule: never use NetVSC.
#
# One row per machine of the design is in tests/fixtures/an-mana-driver-rule.json,
# which tests/js/an-mana-driver-rule.test.js holds the page to.

BeforeDiscovery {
    $fixtureFile = Join-Path $PSScriptRoot '..' 'fixtures' 'an-mana-driver-rule.json'
    $amrCases = @((Get-Content $fixtureFile -Raw | ConvertFrom-Json).cases | ForEach-Object { @{ name = $_.name; case = $_ } })
}

BeforeAll {
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:fixture = Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' 'an-mana-driver-rule.json') -Raw | ConvertFrom-Json
    $script:adviceSchema = Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json'
    $script:entrySchema = Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json'

    function Global:AmrSku([string]$Name, [int]$Vcpus = 2, [int]$MemoryGb = 8) {
        $gens = if ($Name -like '*_v5') { 'V1,V2' } else { 'V2' }
        [pscustomobject]@{ Name = $Name; Family = 'standardX'; ResourceType = 'virtualMachines'; Restrictions = @()
            Capabilities = @(
                [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = '0' }
                [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '4' }
                [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '8' }
                [pscustomobject]@{ Name = 'vCPUs'; Value = [string]$Vcpus }
                [pscustomobject]@{ Name = 'MemoryGB'; Value = [string]$MemoryGb }
                [pscustomobject]@{ Name = 'HyperVGenerations'; Value = $gens }) }
    }
    function Global:AmrCatalogD {
        $c = @{}
        foreach ($n in 'Standard_D2s_v4', 'Standard_D2as_v4', 'Standard_D2s_v5', 'Standard_D2as_v5', 'Standard_D2s_v6', 'Standard_D2as_v6', 'Standard_D2s_v7', 'Standard_D2as_v7') {
            $c[$n] = AmrSku $n
        }
        $c
    }
    function Global:AmrCatalogB {
        $c = @{}
        foreach ($f in 'old-size-catalog-centralus.json', 'bsv2-catalog-centralus.json') {
            $doc = Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' $f) -Raw | ConvertFrom-Json
            foreach ($s in @($doc.sizes)) {
                $caps = @(foreach ($cap in $s.capabilities.PSObject.Properties) { [pscustomobject]@{ Name = $cap.Name; Value = [string]$cap.Value } })
                $c[[string]$s.name] = [pscustomobject]@{ Name = $s.name; ResourceType = 'virtualMachines'; Capabilities = $caps
                    Family = $(if ($s.PSObject.Properties['family']) { [string]$s.family } else { 'standardX' })
                    Restrictions = @(); LocationInfo = @([pscustomobject]@{ Location = 'centralus'; Zones = @($s.zones) }) }
            }
        }
        $c
    }
    function Global:AmrVm($Spec, [string]$Name = 'm') {
        [pscustomobject]@{
            vmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/$Name"
            name = $Name; location = 'centralus'; classification = 'ReadyAfterPrep'; gen = 'V2'; os = [string]$Spec.os
            osVersion = [string]$Spec.image[2]; imagePublisher = [string]$Spec.image[0]; imageOffer = [string]$Spec.image[1]; imageId = ''
            runningOsName = [string]$Spec.agent[0]; runningOsVersion = [string]$Spec.agent[1]
            sourceSize = [string]$Spec.size; sourceDiskArch = 'diskless'; sourceTempDisks = 0; diskController = 'SCSI'
            dataDiskCount = 0; nicCount = 1; acceleratedNicCount = $(if ($Spec.primary) { 1 } else { 0 }); primaryNicAccelerated = [bool]$Spec.primary
            platformManaged = $false; blockers = @(); prepNeeded = @(); identityType = 'None'
        }
    }
    function Global:AmrAdvice($Vm, [string]$Catalog = 'd') {
        $cat = if ($Catalog -eq 'b') { AmrCatalogB } else { AmrCatalogD }
        $doc = [pscustomobject]@{ schemaVersion = 17; runId = 'scan-1'; vms = @($Vm) }
        InModuleScope VmMigrationFactory -Parameters @{ d = $doc; c = @{ centralus = $cat } } {
            Get-VmfTargetAdvice -Assessment $d -CatalogByLocation $c
        }
    }
    # A plan entry as the engine reads it.
    function Global:AmrEntry([string]$Size, [string]$Controller, [hashtable]$Policy = @{}, [string]$Os = 'Linux') {
        [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion);
            vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/m'
            path = 'A'
            assessment = [pscustomobject]@{ os = $Os; sourceSize = 'Standard_D2s_v4' }
            target = [pscustomobject]@{ size = $Size; controller = $Controller }
            policy = [pscustomobject]$Policy
        }
    }
    function Global:AmrNic([bool]$On) {
        @([pscustomobject]@{ id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Network/networkInterfaces/n1'; primary = $true; acceleratedNetworking = $On })
    }
}
AfterAll {
    Remove-Item 'function:\AmrSku', 'function:\AmrCatalogD', 'function:\AmrCatalogB', 'function:\AmrVm', 'function:\AmrAdvice', 'function:\AmrEntry', 'function:\AmrNic' -ErrorAction SilentlyContinue
}

Describe 'AN-MANA-DRIVER-RULE-1: where each machine goes (the shared fixture)' {

    It '<name>' -ForEach $amrCases {
        $advice = AmrAdvice (AmrVm $case.vm) $case.catalog
        $m = @($advice.machines)[0]
        @(@($m.options) | Where-Object { $_.supported } | ForEach-Object { [string]$_.option }) | Should -Be @($case.expect.offered)
        foreach ($p in $case.expect.refused.PSObject.Properties) {
            $o = @($m.options) | Where-Object { $_.option -eq $p.Name } | Select-Object -First 1
            @($o.notSupported) | Should -Contain ([string]$p.Value) -Because "$($p.Name) is refused for this machine"
        }
        $m.start.current | Should -Be $case.expect.start.current
        $m.start.extended | Should -Be $case.expect.start.extended
        # The one exception to the processor rule is gone: nothing waits for a
        # choice between the processor and accelerated networking.
        if ($m.decide) { [string]$m.decide.reason | Should -Not -Be 'processor-or-an' }
        # Never another processor maker.
        foreach ($o in @($m.options | Where-Object { $_.supported })) {
            $o.processorChange | Should -Be $false -Because "$($o.option) keeps the processor"
            foreach ($c in @($o.sizeChoices)) {
                InModuleScope VmMigrationFactory -Parameters @{ s = [string]$c.size; src = [string]$m.sourceSize } {
                    Get-VmfSizeProcessor -SizeName $s | Should -Be (Get-VmfSizeProcessor -SizeName $src)
                }
            }
        }
        if ($null -eq $case.expect.listing) { $m.linuxRelease | Should -BeNullOrEmpty }
        else {
            $m.linuxRelease.mana | Should -Be $case.expect.listing
            if ($null -eq $case.expect.manaUpgrade) { $m.linuxRelease.manaUpgrade | Should -BeNullOrEmpty }
            else {
                $m.linuxRelease.manaUpgrade.distroId | Should -Be $case.expect.manaUpgrade.distroId
                $m.linuxRelease.manaUpgrade.version | Should -Be $case.expect.manaUpgrade.version
            }
        }
        $advice | ConvertTo-Json -Depth 30 | Test-Json -SchemaFile $script:adviceSchema | Should -BeTrue
    }

    It 'the refusal on a target size names the release and the release to upgrade to' {
        $t = InModuleScope VmMigrationFactory -Parameters @{ vm = (AmrVm $script:fixture.cases[5].vm); c = (AmrCatalogD) } {
            Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v7'
        }
        $t.Mapping.Target | Should -BeNullOrEmpty
        $t.Mapping.Code | Should -Be 'no-mana-driver'
        $t.Path | Should -Be 'MANUAL'
        $t.Mapping.Reason | Should -Match 'ubuntu 18\.04'
        $t.Mapping.Reason | Should -Match 'ubuntu 22\.04'
        $t.Mapping.Reason | Should -Match 'assess'
    }

    It 'review: an old size refused this way has no size list either - <Gen>' -ForEach @(@{ Gen = 'v5' }, @{ Gen = 'v6' }, @{ Gen = 'v7' }) {
        # A D v2 size gets a list of sizes of the series by shape
        # (Get-VmfShapeSizeChoices). A list kept beside the refusal would let
        # the targets step pick a size the rule refuses.
        $spec = $script:fixture.cases[5].vm | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        $spec.size = 'Standard_DS2_v2'
        $t = InModuleScope VmMigrationFactory -Parameters @{ vm = (AmrVm $spec); c = (AmrCatalogB); g = $Gen } {
            Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration $g
        }
        $t.Mapping.Code | Should -Be 'no-mana-driver'
        @($t.SizeChoices).Count | Should -Be 0
    }

    It 'an AMD machine on AMD v5 has accelerated networking turned on, and the size never gives MANA' {
        $m = @((AmrAdvice (AmrVm $script:fixture.cases[11].vm)).machines)[0]
        $v5 = @($m.options) | Where-Object { $_.option -eq 'v5' }
        $v5.targetSize | Should -Be 'Standard_D2as_v5'
        $v5.acceleratedNetworking.mayUseMana | Should -BeFalse
        $v5.acceleratedNetworking.turnsOn | Should -BeTrue
    }
}

Describe 'AN-MANA-DRIVER-RULE-1: the rule, from target-families.json' {

    It 'a size that can give MANA needs a MANA driver: <Size> -> <Needs>' -ForEach @(
        @{ Size = 'Standard_D2s_v6'; Needs = $true }, @{ Size = 'Standard_D2as_v6'; Needs = $true }
        @{ Size = 'Standard_D2s_v7'; Needs = $true }, @{ Size = 'Standard_D2as_v7'; Needs = $true }
        @{ Size = 'Standard_E2ds_v7'; Needs = $true }, @{ Size = 'Standard_F2as_v7'; Needs = $true }
        @{ Size = 'Standard_D2s_v5'; Needs = $true }, @{ Size = 'Standard_E2s_v5'; Needs = $true }
        @{ Size = 'Standard_B2s_v2'; Needs = $true }, @{ Size = 'Standard_B2ls_v2'; Needs = $true }
        @{ Size = 'Standard_D2as_v5'; Needs = $false }, @{ Size = 'Standard_E2ads_v5'; Needs = $false }
        # A name that cannot be read might give MANA: unknown is never a no.
        @{ Size = 'Standard_Unknown'; Needs = $true }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ s = $Size; want = $Needs } {
            Test-VmfTargetNeedsManaDriver -SizeName $s | Should -Be $want
        }
    }

    # Replaces DRIFT-11-OTHER-OPTIONS-1's data test (Drift11OtherOptions.Tests.ps1,
    # removed with its rule): every generation, series and maker, from the data.
    It 'from target-families.json: <Size> needs a MANA driver exactly when its generation names its maker in manaProcessors' -ForEach @(
        foreach ($gen in 'v5', 'v6', 'v7') {
            foreach ($series in 'D', 'E') {
                foreach ($maker in 'Intel', 'AMD') {
                    $letter = if ($maker -eq 'AMD') { 'a' } else { '' }
                    @{ Gen = $gen; Maker = $maker; Size = "Standard_$($series)2$($letter)s_$gen" }
                }
            }
        }
    ) {
        $families = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'target-families.json') -Raw | ConvertFrom-Json
        $expected = @($families.generations.$Gen.manaProcessors) -contains $Maker
        InModuleScope VmMigrationFactory -Parameters @{ s = $Size; e = $expected } {
            Test-VmfTargetNeedsManaDriver -SizeName $s | Should -Be $e -Because $s
        }
    }

    It 'the release to upgrade to is the first release of the same distribution that Microsoft lists, above this one' -ForEach @(
        @{ Id = 'ubuntu'; Version = '18.04'; Want = '22.04' }, @{ Id = 'ubuntu'; Version = '20.04'; Want = '22.04' }
        @{ Id = 'rhel'; Version = '8.10'; Want = '9.6' }, @{ Id = 'debian'; Version = '11'; Want = '12' }
        @{ Id = 'sles'; Version = '15.4'; Want = '15.5' }, @{ Id = 'centos'; Version = '7.9'; Want = $null }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ id = $Id; v = $Version; want = $Want } {
            $u = Get-VmfManaUpgradeRelease -Release @{ distroId = $id; version = $v; source = 'agent' }
            if ($null -eq $want) { $u | Should -BeNullOrEmpty }
            else { $u.distroId | Should -Be $id; $u.version | Should -Be $want }
        }
    }

    It 'the functions of the Intel exception and of the keep-off rule are gone: <Name>' -ForEach @(
        @{ Name = 'Test-VmfAnMakerException' }, @{ Name = 'Select-VmfOwnMakerOption' }, @{ Name = 'Get-VmfAnMakerPolicy' }
        @{ Name = 'Get-VmfAmdTwinSize' }, @{ Name = 'Test-VmfSizeKeepsAnOffWithoutMana' }, @{ Name = 'Test-VmfAnRequiredWithoutMana' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ n = $Name } {
            Get-Command -Name $n -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }
    }

    # OLD-VERSION-READERS-REMOVE-3: ensureOff left the plan contract at v33,
    # and no reader takes it either (Get-VmfNicAnPlan changes nothing for it).
    It 'no plan writer writes ensureOff' {
        foreach ($f in 'Public/New-VmfPlan.ps1', 'Public/Set-VmfMachineTarget.ps1', 'Public/Resolve-VmfDecision.ps1', 'Public/Set-VmfTargetChoice.ps1', 'Private/plan/AdviceAn.ps1') {
            $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' $f)
            $code | Should -Not -Match "'ensureOff'" -Because "$f writes no ensureOff"
        }
    }
}

Describe 'AN-MANA-DRIVER-RULE-1: Red Hat 9.4 reaches 9.6 by a normal update' {

    It 'Microsoft''s table covers <Id> <Version> with its <Row> row' -ForEach @(
        @{ Id = 'rhel'; Version = '9.4'; Row = '9.6' }, @{ Id = 'rhel'; Version = '9.0'; Row = '9.6' }
        @{ Id = 'rocky'; Version = '9.2'; Row = '9.6' }, @{ Id = 'almalinux'; Version = '9.4'; Row = '9.6' }
        @{ Id = 'rhel'; Version = '9.8'; Row = '9.6' }, @{ Id = 'rhel'; Version = '10.0'; Row = '10.0' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ id = $Id; v = $Version; row = $Row } {
            (Find-VmfManaTableEntry -DistroId $id -DistroVersion $v -Kernel '5.14.0-427.13.1.el9_4.x86_64').versionId | Should -Be $row
        }
    }

    It 'a release whose minor is not reached by a normal update stays unlisted: <Id> <Version>' -ForEach @(
        @{ Id = 'rhel'; Version = '8.10' }, @{ Id = 'sles'; Version = '15.4' }, @{ Id = 'ubuntu'; Version = '20.04' }, @{ Id = 'debian'; Version = '11' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ id = $Id; v = $Version } {
            Find-VmfManaTableEntry -DistroId $id -DistroVersion $v -Kernel '5.4.0-1' | Should -BeNullOrEmpty
        }
    }

    It 'the agent reading Red Hat 9.4 is listed, so Update the kernel is offered on v6' {
        $vm = AmrVm $script:fixture.cases[3].vm
        InModuleScope VmMigrationFactory -Parameters @{ vm = $vm } {
            Get-VmfManaReleaseListing -Release (Get-VmfLinuxRelease -Vm $vm) | Should -Be 'listed'
            Test-VmfReleaseKnownUnlisted -Vm $vm | Should -BeFalse
            $entry = [pscustomobject]@{ assessment = $vm; target = [pscustomobject]@{ size = 'Standard_D2s_v6'; controller = 'NVMe' } }
            Test-VmfKernelUpdateOfferedForEntry -PlanEntry $entry | Should -BeTrue
        }
    }

    It 'Preparing: a 9.4 kernel is below the floor, the update goes ahead, and a 9.6 kernel on 9.4 has the driver' {
        InModuleScope VmMigrationFactory {
            $before = [pscustomobject]@{ os = 'Linux'; distroId = 'rhel'; distroVersion = '9.4'; kernelVersion = '5.14.0-427.13.1.el9_4.x86_64' }
            (Get-VmfDriverJudgement -Facts $before -TargetIsBoost $true).Status | Should -Be 'FAIL'
            (Resolve-VmfKernelUpdate -Os 'Linux' -Facts $before).Update | Should -BeTrue
            $after = [pscustomobject]@{ os = 'Linux'; distroId = 'rhel'; distroVersion = '9.4'; kernelVersion = '5.14.0-611.5.1.el9_7.x86_64' }
            (Get-VmfDriverJudgement -Facts $after -TargetIsBoost $true).Status | Should -Be 'PASS'
            $out = [pscustomobject]@{ checks = @([pscustomobject]@{ name = 'mana module available'; status = 'PASS'; detail = 'yes' }) }
            Get-VmfManaDriverPresence -GuestOutput $out -Os 'Linux' -Facts $after | Should -Be 'present'
        }
    }

    It 'a Red Hat 8 kernel update is still refused' {
        InModuleScope VmMigrationFactory {
            $facts = [pscustomobject]@{ os = 'Linux'; distroId = 'rhel'; distroVersion = '8.10'; kernelVersion = '4.18.0-553.el8_10.x86_64' }
            (Resolve-VmfKernelUpdate -Os 'Linux' -Facts $facts).Update | Should -BeFalse
        }
    }
}

Describe 'AN-MANA-DRIVER-RULE-1: accelerated networking is always on where the size can give MANA' {

    It 'a plan entry that turns it off on <Size> is refused in Checking, before any change' -ForEach @(
        @{ Size = 'Standard_D2s_v7'; Controller = 'NVMe' }, @{ Size = 'Standard_D2as_v7'; Controller = 'NVMe' }
        @{ Size = 'Standard_D2s_v6'; Controller = 'NVMe' }, @{ Size = 'Standard_D2as_v6'; Controller = 'NVMe' }
        @{ Size = 'Standard_B2s_v2'; Controller = 'SCSI' }, @{ Size = 'Standard_D2s_v5'; Controller = 'SCSI' }
    ) {
        foreach ($set in @('preserve')) {
            $entry = AmrEntry $Size $Controller @{ acceleratedNetworking = $set }
            InModuleScope VmMigrationFactory -Parameters @{ e = $entry; n = (AmrNic $false); s = $Size; set = $set } {
                $r = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry $e -CapturedNics $n
                $r.Stop | Should -BeTrue -Because "$set on $s"
                $r.Reason | Should -Be 'acceleratedNetworkingRequired'
                $r.Detail | Should -Match ([regex]::Escape($s))
            }
        }
    }

    It 'on AMD v5 a plan entry may still keep it off (preserve on a primary that is off)' {
        $entry = AmrEntry 'Standard_D2as_v5' 'SCSI' @{ acceleratedNetworking = 'preserve' }
        InModuleScope VmMigrationFactory -Parameters @{ e = $entry; n = (AmrNic $false) } {
            $r = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry $e -CapturedNics $n -ManaDriver 'absent'
            $r.Stop | Should -BeFalse
            $r.OnAfter | Should -BeFalse
        }
    }

    It 'off today on v7, no MANA driver: the move stops in Preparing; it never keeps it off (no preserve)' {
        $entry = AmrEntry 'Standard_D2s_v7' 'NVMe' @{ onDriverBelowFloor = 'stop' }
        foreach ($driver in 'absent', 'unlisted') {
            InModuleScope VmMigrationFactory -Parameters @{ e = $entry; n = (AmrNic $false); d = $driver } {
                $r = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry $e -CapturedNics $n -ManaDriver $d
                $r.Policy | Should -Not -Be 'preserve'
                $r.Stop | Should -BeTrue
                $r.Reason | Should -Be 'driverBelowFloor'
            }
        }
    }

    It 'off today on Bsv2, no MANA driver: the same' {
        $entry = AmrEntry 'Standard_B2ls_v2' 'SCSI' @{ onDriverBelowFloor = 'stop' }
        InModuleScope VmMigrationFactory -Parameters @{ e = $entry; n = (AmrNic $false) } {
            $r = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry $e -CapturedNics $n -ManaDriver 'absent'
            $r.Stop | Should -BeTrue
            $r.Reason | Should -Be 'driverBelowFloor'
        }
    }

    It 'off today on v7, with a MANA driver: the move turns it on' {
        $entry = AmrEntry 'Standard_D2s_v7' 'NVMe'
        InModuleScope VmMigrationFactory -Parameters @{ e = $entry; n = (AmrNic $false) } {
            $r = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry $e -CapturedNics $n -ManaDriver 'present'
            $r.Stop | Should -BeFalse
            $r.OnAfter | Should -BeTrue
            $r.ExpectFabric | Should -BeTrue
        }
    }

    It 'the target advice says a Linux machine with it off has it turned on on v7' {
        $m = @((AmrAdvice (AmrVm $script:fixture.cases[4].vm)).machines)[0]
        (@($m.options) | Where-Object { $_.option -eq 'v7' }).acceleratedNetworking.turnsOn | Should -BeTrue
    }

    It 'the plan entry contract refuses ensureOff on every target (v33)' {
        $sample = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'plan-entry.sample.json') -Raw | ConvertFrom-Json
        $sample.policy | Add-Member -NotePropertyName acceleratedNetworking -NotePropertyValue 'ensureOff' -Force
        $sample | ConvertTo-Json -Depth 30 | Test-Json -SchemaFile $script:entrySchema -ErrorAction SilentlyContinue | Should -BeFalse
        $sample.target.controller = 'SCSI'
        $sample.target.size = 'Standard_E8ads_v5'
        $sample | ConvertTo-Json -Depth 30 | Test-Json -SchemaFile $script:entrySchema -ErrorAction SilentlyContinue | Should -BeFalse
    }
}

# AN-PROCEED-NETVSC-1, folded in (2026-11-06: a move is not allowed if the
# network will not work with AN). An approver's Continue on driverBelowFloor
# moved a machine with no driver for its target's adapter, and on a MANA host it
# ran on the synthetic interface (NetVSC). There is no Continue now: the stop
# is a stop before any change, and only a fix gets past it - Update the kernel
# where the table allows, or leave the machine out.
Describe 'AN-PROCEED-NETVSC-1: no machine moves onto NetVSC' {

    It 'a value no writer gives (proceed) stops for a missing driver, like stop: driver <D>' -ForEach @(@{ D = 'absent' }, @{ D = 'unlisted' }) {
        $entry = AmrEntry 'Standard_D2s_v7' 'NVMe' @{ onDriverBelowFloor = 'proceed' }
        InModuleScope VmMigrationFactory -Parameters @{ e = $entry; n = (AmrNic $true); d = $D } {
            $r = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry $e -CapturedNics $n -ManaDriver $d
            $r.Stop | Should -BeTrue
            $r.Reason | Should -Be 'driverBelowFloor'
            $r.ExpectFabric | Should -BeFalse
        }
    }

    It 'no wave save and no decision can write Continue: the setting takes Stop and ask only' {
        InModuleScope VmMigrationFactory {
            @((Get-VmfPolicyLevers)['onDriverBelowFloor']) | Should -Be @('stop')
            (Test-VmfPolicyOverride -Override @{ onDriverBelowFloor = 'proceed' }).Ok | Should -BeFalse
            (Test-VmfPolicyOverride -Override @{ onDriverBelowFloor = 'stop' }).Ok | Should -BeTrue
        }
    }

    It 'nothing can write ensureOff either, so no machine is moved with accelerated networking turned off' {
        InModuleScope VmMigrationFactory {
            @((Get-VmfPolicyLevers)['acceleratedNetworking']) | Should -Not -Contain 'ensureOff'
            (Test-VmfPolicyOverride -Override @{ acceleratedNetworking = 'ensureOff' }).Ok | Should -BeFalse
        }
    }

    It 'the stop offers no acceptance: its fix is the kernel, or leaving the machine out' {
        $reasons = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json
        $r = @($reasons.reasons | Where-Object code -EQ 'driverBelowFloor')[0]
        $r.PSObject.Properties['decide'] | Should -BeNullOrEmpty
        $r.retry | Should -Be 'afterFix'
        $r.whatToDo | Should -Not -Match '(?i)approver accepts'
        $r.whatToDo | Should -Match 'Update the kernel'
    }

    It 'the code says nothing of a move that works without its driver' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'validate' 'DriverReadiness.ps1')
        $code | Should -Not -Match "An approver accepted the risk"
    }
}