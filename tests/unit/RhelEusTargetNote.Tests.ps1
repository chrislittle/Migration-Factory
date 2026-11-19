#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# RHEL-EUS-TARGET-NOTE-1: the targets step says which Red Hat machine was made
# from an image on the EUS repositories.
#
# Microsoft, Red Hat Update Infrastructure
# (https://learn.microsoft.com/en-us/azure/virtual-machines/workloads/redhat/redhat-rhui):
# "Images connected to EUS repositories contain a minor version number in the
# SKU", images connected to non-EUS repositories do not (X-LVM, X-RAW), and
# RHUI is for pay-as-you-go images only. A machine on the EUS repositories gets
# no later minor release by an update. MEASURED 2026-11-08 (RHEL-PINNED-
# KERNEL-ADVICE-1): RedHat:RHEL:94_gen2 found no kernel newer than its 9.4
# kernel, and the move stopped with kernelNotInRepositories.
#
# The advice knows the image (publisher, offer, SKU), the licence type and the
# release the VM agent reports - never the repositories the machine uses now,
# which Microsoft's page switches both ways. So the advice records only what
# it read (eusImage), the page says so, and Update the kernel stays offered.
#
# The cases are one fixture, tests/fixtures/rhel-eus-target-note.json; the
# page is held to its words by tests/js/rhel-eus-target-note.test.js.

BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:fixture = Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' 'rhel-eus-target-note.json') -Raw | ConvertFrom-Json -Depth 10

    function Global:ReVm($Case, [string]$Name = 'rh-01') {
        [pscustomobject]@{
            vmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/$Name"
            name = $Name; location = 'centralus'; classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'
            osVersion = [string]$Case.sku; imagePublisher = [string]$Case.publisher; imageOffer = [string]$Case.offer; imageId = ''
            runningOsName = [string]$Case.runningName; runningOsVersion = [string]$Case.runningVersion
            licenseType = $Case.licenseType
            sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; sourceTempDisks = 0; diskController = 'SCSI'
            dataDiskCount = 0; nicCount = 1; acceleratedNicCount = 1; primaryNicAccelerated = $true
            platformManaged = $false; blockers = @(); prepNeeded = @()
        }
    }
    function Global:ReEus($Vm) {
        InModuleScope VmMigrationFactory -Parameters @{ v = $Vm } { Get-VmfEusImage -Vm $v }
    }
    function Global:ReSku([string]$Name, [string]$Gens = 'V2') {
        [pscustomobject]@{ Name = $Name; Family = 'standardX'; ResourceType = 'virtualMachines'; Restrictions = @()
            Capabilities = @(
                [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = '0' }
                [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '4' }
                [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '8' }
                [pscustomobject]@{ Name = 'vCPUs'; Value = '2' }
                [pscustomobject]@{ Name = 'MemoryGB'; Value = '8' }
                [pscustomobject]@{ Name = 'HyperVGenerations'; Value = $Gens }) }
    }
    function Global:ReAdvise([object[]]$Vms) {
        $cat = @{}
        foreach ($n in @('Standard_D2s_v5', 'Standard_D2as_v5', 'Standard_D2s_v6', 'Standard_D2as_v6', 'Standard_D2s_v7')) {
            $cat[$n] = ReSku $n $(if ($n -like '*_v5') { 'V1,V2' } else { 'V2' })
        }
        $doc = [pscustomobject]@{ schemaVersion = 3; runId = 'scan-1'; vms = @($Vms) }
        InModuleScope VmMigrationFactory -Parameters @{ d = $doc; c = @{ centralus = $cat } } {
            Get-VmfTargetAdvice -Assessment $d -CatalogByLocation $c
        }
    }
}

AfterAll {
    foreach ($f in 'ReVm', 'ReEus', 'ReSku', 'ReAdvise') { Remove-Item "Function:\$f" -ErrorAction SilentlyContinue }
}

Describe 'RHEL-EUS-TARGET-NOTE-1: a machine made from a RHEL image on the EUS repositories' {

    It 'the fixture has cases that are marked and cases that are not' {
        @($script:fixture.cases | Where-Object { $null -ne $_.expect }).Count | Should -BeGreaterThan 1
        @($script:fixture.cases | Where-Object { $null -eq $_.expect }).Count | Should -BeGreaterThan 5
    }

    It '<name>' -ForEach @(
        (Get-Content (Join-Path $PSScriptRoot '..' 'fixtures' 'rhel-eus-target-note.json') -Raw | ConvertFrom-Json -Depth 10).cases | ForEach-Object {
            @{ name = $_.name; case = $_ }
        }
    ) {
        $got = ReEus (ReVm $case.vm)
        if ($null -eq $case.expect) {
            $got | Should -BeNullOrEmpty
        } else {
            $got | Should -Not -BeNullOrEmpty
            $got.image | Should -BeExactly $case.expect.image
            $got.release | Should -BeExactly $case.expect.release
            $got.listedFrom | Should -BeExactly $case.expect.listedFrom
        }
    }

    It 'a Windows machine is never marked' {
        $vm = ReVm ([pscustomobject]@{ publisher = 'RedHat'; offer = 'RHEL'; sku = '94_gen2'; runningName = ''; runningVersion = ''; licenseType = $null })
        $vm.os = 'Windows'
        ReEus $vm | Should -BeNullOrEmpty
    }

    It 'the image must be publisher RedHat: another publisher is not marked, whatever its image reads as' {
        Mock -ModuleName VmMigrationFactory Get-VmfImageRelease { @{ distroId = 'rhel'; version = '9.4' } }
        $vm = ReVm ([pscustomobject]@{ publisher = 'contoso'; offer = 'RHEL'; sku = '9_4'; runningName = ''; runningVersion = ''; licenseType = $null })
        ReEus $vm | Should -BeNullOrEmpty
        $vm.imagePublisher = 'RedHat'
        (ReEus $vm).image | Should -BeExactly 'RedHat:RHEL:9_4' -Because 'the same machine from Red Hat is marked'
    }

    It 'the lowest listed release is read from the MANA table, not written into the rule' {
        $floors = InModuleScope VmMigrationFactory { Get-VmfDriverFloors } | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
        foreach ($row in @($floors.mana.linux.distros | Where-Object { $_.id -eq 'rhel' -and $_.versionId -eq '9.6' })) { $row.versionId = '9.8' }
        $vm = ReVm ([pscustomobject]@{ publisher = 'RedHat'; offer = 'RHEL'; sku = '9_6'; runningName = ''; runningVersion = ''; licenseType = $null })
        $got = InModuleScope VmMigrationFactory -Parameters @{ v = $vm; f = $floors } { Get-VmfEusImage -Vm $v -Floors $f }
        $got.release | Should -BeExactly '9.6'
        $got.listedFrom | Should -BeExactly '9.8'
    }

    It 'a MANA row with no minor release covers every minor of it: not marked' {
        $floors = InModuleScope VmMigrationFactory { Get-VmfDriverFloors } | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
        foreach ($row in @($floors.mana.linux.distros | Where-Object { $_.id -eq 'rhel' -and $_.versionId -eq '9.6' })) { $row.versionId = '9' }
        $vm = ReVm ([pscustomobject]@{ publisher = 'RedHat'; offer = 'RHEL'; sku = '94_gen2'; runningName = ''; runningVersion = ''; licenseType = $null })
        InModuleScope VmMigrationFactory -Parameters @{ v = $vm; f = $floors } { Get-VmfEusImage -Vm $v -Floors $f } | Should -BeNullOrEmpty
    }

    It 'the target advice carries it on each machine, and null where it does not apply' {
        $marked = ReVm ($script:fixture.cases[0].vm) 'rh-eus'
        $plain = ReVm ($script:fixture.cases[5].vm) 'rh-lvm'
        $advice = ReAdvise @($marked, $plain)
        $m1 = @($advice.machines) | Where-Object { $_.name -eq 'rh-eus' }
        $m2 = @($advice.machines) | Where-Object { $_.name -eq 'rh-lvm' }
        $m1.eusImage.image | Should -BeExactly 'RedHat:RHEL:94_gen2'
        $m1.eusImage.listedFrom | Should -BeExactly '9.6'
        $m2.Contains('eusImage') | Should -BeTrue
        $m2.eusImage | Should -BeNullOrEmpty
    }

    It 'the advice is not changed in any other way: Update the kernel stays offered' {
        $marked = ReVm ($script:fixture.cases[0].vm) 'rh-eus'
        $advice = ReAdvise @($marked)
        $m = @($advice.machines)[0]
        @($m.options | Where-Object { $_.supported }).Count | Should -BeGreaterThan 0
        $m.linuxRelease.mana | Should -Not -Be 'unlisted'
    }

    It 'the document validates against the schema' {
        $advice = ReAdvise @((ReVm ($script:fixture.cases[0].vm) 'rh-eus'), (ReVm ($script:fixture.cases[5].vm) 'rh-lvm'))
        $advice | ConvertTo-Json -Depth 20 | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json') | Should -BeTrue
    }

    It 'the schema refuses a machine with no eusImage, and an eusImage with a field it does not name' {
        $advice = ReAdvise @((ReVm ($script:fixture.cases[0].vm) 'rh-eus'))
        $schema = Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json'
        $json = $advice | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
        $json.machines[0].eusImage | Add-Member -NotePropertyName repositories -NotePropertyValue 'eus'
        $json | ConvertTo-Json -Depth 20 | Test-Json -SchemaFile $schema -ErrorAction SilentlyContinue | Should -BeFalse
        $json.machines[0].PSObject.Properties.Remove('eusImage')
        $json | ConvertTo-Json -Depth 20 | Test-Json -SchemaFile $schema -ErrorAction SilentlyContinue | Should -BeFalse
    }

    It 'the version is 31: a v30 file has no eusImage, so it is refused and made again' {
        InModuleScope VmMigrationFactory { Get-VmfTargetAdviceSchemaVersion | Should -Be 33 }
        $s = Get-Content (Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json') -Raw | ConvertFrom-Json -Depth 30
        $s.properties.schemaVersion.const | Should -Be 33
        (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.html')) | Should -Match 'const TARGET_ADVICE_VERSION = 33;'
        (Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw) | Should -Match 'target-advice v30 -> v31'
    }
}
