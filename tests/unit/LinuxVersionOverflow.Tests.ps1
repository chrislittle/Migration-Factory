#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# LINUX-VERSION-OVERFLOW-1: a version number with too many digits no longer
# stops the assessment, or the target advice, of every machine in scope.
#
# The VM agent reports the release of a Linux machine, and Resource Graph
# returns it as osVersionRunning. Root inside the machine controls it. Before
# this, Get-VmfLinuxRelease took any run of digits, and four readers cast the
# parts with [int]: '22.99999999999' threw "Value was either too large or too
# small for an Int32", and with ErrorActionPreference Stop the whole scan ended
# with no assessment saved (a supported image), or the advise operation ended
# for every machine (a custom image).
#
# What these tests hold:
#   - a number that does not fit is not read: unknown, never a pass and never
#     a fail, in every reader of a version or a guest-reported number;
#   - Test-VmfReleaseKnownUnlisted and minorReachedByUpdate do not flip;
#   - one machine whose record cannot be made does not stop the others, in the
#     scan and in the target advice: it is held with the blocker
#     machine-not-read, and the reason has words.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:sub = '00000000-0000-0000-0000-000000000000'
    $script:long = '22.99999999999'

    # A machine as Resource Graph gives it to the scan. A supported image by
    # default; -Custom gives a machine made from a custom image.
    function Global:LvoRow {
        param([string]$Name = 'vm-l', [string]$OsName = 'ubuntu', [string]$OsVersion = '22.04', [switch]$Custom)
        [pscustomobject]@{
            id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$Name"
            name = $Name; resourceGroup = 'rg-app'; location = 'centralus'; zones = $null
            sku = 'Standard_D2s_v4'; os = 'Linux'; gen = 'V2'; diskController = 'SCSI'; osName = $OsName; osVersionRunning = $OsVersion
            imagePublisher = $(if ($Custom) { '' } else { 'Canonical' }); imageOffer = $(if ($Custom) { '' } else { '0001-com-ubuntu-server-jammy' })
            imageSku = $(if ($Custom) { '' } else { '22_04-lts-gen2' })
            imageId = $(if ($Custom) { '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-img/providers/Microsoft.Compute/galleries/g/images/i/versions/1.0.0' } else { '' })
            communityGalleryImageId = ''; sharedGalleryImageId = ''; planPublisher = ''; planProduct = ''
            vmssId = ''; hibernationEnabled = $false; securityType = ''; dataDiskCount = 0; dataDisks = @()
            tags = $null; identityType = 'None'; identityPrincipalId = ''; adeOsDiskEnabled = ''; licenseType = ''
            osDiskManagedId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/disks/$Name-os"
        }
    }
    function Global:LvoSku([string]$Name = 'Standard_D2s_v4') {
        [pscustomobject]@{ Name = $Name; ResourceType = 'virtualMachines'; Restrictions = @()
            Capabilities = @([pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = '16384' }) }
    }
    # The scan, with every read but the inventory answered. -Throw names the
    # machines whose record throws, to prove the scan goes on without them.
    function Global:LvoScan([object[]]$Rows, [string[]]$Throw = @()) {
        $out = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-lvo-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $text = InModuleScope VmMigrationFactory -Parameters @{ rows = $Rows; out = $out; throwFor = $Throw } {
            param($rows, $out, $throwFor)
            Mock Get-VmfFleetInventory { , @($rows) }
            Mock Get-VmfSkuCatalog { , @((LvoSku)) }
            Mock Get-VmfMachineImageNvme { @{ Nvme = $null; Note = $null } }
            Mock Get-VmfNicFacts { @{ Accelerated = @{}; ClusterHints = @{} } }
            Mock Get-VmfSqlIaaSAgentVmIds { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfAvdSessionHostIds { @{ Ids = @{}; PoolTypes = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfSapSystemVmIds { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfManagedPlatformGroups { @{ Groups = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfSqlVirtualMachines { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfDiskShareMap { @{ Disks = @{}; Types = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfResourceGroupOwners { @{ Groups = @{}; Verified = $true; Detail = 'mocked' } }
            if (@($throwFor).Count) {
                $global:lvoThrowFor = @($throwFor)
                Mock Get-VmfAssessmentRecord { throw 'Value was either too large or too small for an Int32.' } -ParameterFilter { $global:lvoThrowFor -contains [string]$Vm.name }
            }
            Invoke-VmfAssessment -Scope @{ Subscriptions = @('00000000-0000-0000-0000-000000000000') } -OutPath $out | Out-Null
            Get-Content (Join-Path $out 'assessment.json') -Raw
        }
        $log = (Get-ChildItem $out -Recurse -File | Where-Object Name -Match 'event' | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"
        Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Variable -Name lvoThrowFor -Scope Global -ErrorAction SilentlyContinue
        @{ Text = $text; Doc = ($text | ConvertFrom-Json -Depth 30); Log = $log }
    }
    # An assessment record, as the target advice reads it.
    function Global:LvoRecord {
        param([string]$Name = 'vm-l', [string]$OsVersion = '22.04', [switch]$Custom, [string[]]$Blockers = @())
        [pscustomobject]@{
            vmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$Name"
            name = $Name; location = 'centralus'; classification = $(if (@($Blockers).Count) { 'Blocked' } else { 'ReadyAfterPrep' }); gen = 'V2'; os = 'Linux'
            osVersion = $(if ($Custom) { '' } else { '22_04-lts-gen2' })
            imagePublisher = $(if ($Custom) { '' } else { 'Canonical' }); imageOffer = $(if ($Custom) { '' } else { '0001-com-ubuntu-server-jammy' })
            runningOsName = 'ubuntu'; runningOsVersion = $OsVersion
            sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; sourceTempDisks = 0; diskController = 'SCSI'; dataDiskCount = 0
            nicCount = 1; acceleratedNicCount = 1; primaryNicAccelerated = $true; platformManaged = $false; blockers = @($Blockers); prepNeeded = @('linux-nvme-prep')
        }
    }
    function Global:LvoCatalog {
        @{ centralus = @{ 'Standard_D2s_v5' = (LvoSku 'Standard_D2s_v5'); 'Standard_D2s_v6' = (LvoSku 'Standard_D2s_v6'); 'Standard_D2s_v7' = (LvoSku 'Standard_D2s_v7') } }
    }
}
AfterAll {
    Remove-Item function:LvoRow, function:LvoSku, function:LvoScan, function:LvoRecord, function:LvoCatalog -ErrorAction SilentlyContinue
}

Describe 'LINUX-VERSION-OVERFLOW-1: a number is read only when it fits' {
    It 'digits that fit are a number; anything else is not read' {
        InModuleScope VmMigrationFactory {
            ConvertTo-VmfBoundedNumber -Text '22' | Should -Be 22
            ConvertTo-VmfBoundedNumber -Text '2147483647' | Should -Be 2147483647
            ConvertTo-VmfBoundedNumber -Text '2147483648' | Should -BeNullOrEmpty
            ConvertTo-VmfBoundedNumber -Text '99999999999' | Should -BeNullOrEmpty
            ConvertTo-VmfBoundedNumber -Text '' | Should -BeNullOrEmpty
            ConvertTo-VmfBoundedNumber -Text '-1' | Should -BeNullOrEmpty
            ConvertTo-VmfBoundedNumber -Text ' 4' | Should -BeNullOrEmpty
            ConvertTo-VmfBoundedNumber -Text '99999999999' -Long | Should -Be 99999999999
            ConvertTo-VmfBoundedNumber -Text '99999999999999999999' -Long | Should -BeNullOrEmpty
        }
    }
    It 'a version is in range only when every run of digits fits' {
        InModuleScope VmMigrationFactory {
            Test-VmfVersionInRange -Version '22.04' | Should -BeTrue
            Test-VmfVersionInRange -Version '22.99999999999' | Should -BeFalse
            Test-VmfVersionInRange -Version '99999999999.04' | Should -BeFalse
            Test-VmfVersionInRange -Version '22.04.99999999999' | Should -BeFalse
            Test-VmfVersionInRange -Version '' | Should -BeFalse
        }
    }
}

Describe 'LINUX-VERSION-OVERFLOW-1: the release the VM agent reports' {
    It 'a release that does not fit is not the release: the image decides, as for any reading the product cannot read' {
        $r = InModuleScope VmMigrationFactory -Parameters @{ v = (LvoRecord -OsVersion '22.99999999999') } { param($v) Get-VmfLinuxRelease -Vm $v }
        $r.source | Should -Be 'image'
        $r.version | Should -Be '22.04'
    }
    It 'each part counts: a long major and a long third part are not read either' {
        foreach ($ver in '99999999999.04', '22.04.99999999999') {
            $r = InModuleScope VmMigrationFactory -Parameters @{ v = (LvoRecord -OsVersion $ver) } { param($v) Get-VmfLinuxRelease -Vm $v }
            $r.source | Should -Be 'image' -Because "$ver does not fit"
        }
    }
    It 'on a custom image there is no release at all - never a guess' {
        InModuleScope VmMigrationFactory -Parameters @{ v = (LvoRecord -OsVersion '22.99999999999' -Custom) } { param($v) Get-VmfLinuxRelease -Vm $v } | Should -BeNullOrEmpty
    }
    It 'a release that fits is read as before' {
        $r = InModuleScope VmMigrationFactory -Parameters @{ v = (LvoRecord -OsVersion '22.04') } { param($v) Get-VmfLinuxRelease -Vm $v }
        $r.source | Should -Be 'agent'
        $r.version | Should -Be '22.04'
    }
}

Describe 'LINUX-VERSION-OVERFLOW-1: every reader says unknown, and never throws' {
    BeforeAll {
        $script:bad = @(
            @{ distroId = 'ubuntu'; version = '22.99999999999'; source = 'agent' }
            @{ distroId = 'ubuntu'; version = '99999999999.04'; source = 'agent' }
            @{ distroId = 'rhel'; version = '9.99999999999'; source = 'agent' }
            @{ distroId = 'ubuntu'; version = '18.99999999999'; source = 'agent' }
        )
    }
    It 'the NVMe list (Get-VmfNvmeLinuxListing)' {
        foreach ($rel in $script:bad) {
            InModuleScope VmMigrationFactory -Parameters @{ rel = $rel } { param($rel) Get-VmfNvmeLinuxListing -Release $rel } | Should -Be 'unknown' -Because $rel.version
        }
    }
    It 'the end of standard support (Get-VmfLinuxReleaseEol)' {
        foreach ($rel in $script:bad) {
            (InModuleScope VmMigrationFactory -Parameters @{ rel = $rel } { param($rel) Get-VmfLinuxReleaseEol -Release $rel }).Status | Should -Be 'unknown' -Because $rel.version
        }
    }
    It 'the MANA table (Find-VmfManaTableEntry): no row covers a release nobody can read' {
        foreach ($rel in $script:bad) {
            InModuleScope VmMigrationFactory -Parameters @{ rel = $rel } { param($rel) Find-VmfManaTableEntry -DistroId $rel.distroId -DistroVersion $rel.version } | Should -BeNullOrEmpty -Because $rel.version
        }
        # minorReachedByUpdate does not reach a row from a minor nobody can read.
        InModuleScope VmMigrationFactory { Find-VmfManaTableEntry -DistroId 'rhel' -DistroVersion '9.4' } | Should -Not -BeNullOrEmpty -Because 'a minor that fits still reaches its row'
    }
    It 'the MANA listing is unknown, so Test-VmfReleaseKnownUnlisted does not flip' {
        foreach ($rel in $script:bad) {
            InModuleScope VmMigrationFactory -Parameters @{ rel = $rel } { param($rel) Get-VmfManaReleaseListing -Release $rel } | Should -Be 'unknown' -Because $rel.version
        }
        $vm = LvoRecord -OsVersion '18.99999999999' -Custom
        InModuleScope VmMigrationFactory -Parameters @{ v = $vm } { param($v) Test-VmfReleaseKnownUnlisted -Vm $v } | Should -BeFalse
        InModuleScope VmMigrationFactory -Parameters @{ v = (LvoRecord -OsVersion '18.04' -Custom) } { param($v) Test-VmfReleaseKnownUnlisted -Vm $v } | Should -BeTrue -Because 'a release that fits is judged as before'
    }
    It 'the driver judgement in the run is UNKNOWN, never a pass and never a fail' {
        foreach ($ver in '9.99999999999', '22.99999999999') {
            $j = InModuleScope VmMigrationFactory -Parameters @{ ver = $ver } {
                param($ver) Get-VmfDriverJudgement -Facts ([pscustomobject]@{ os = 'Linux'; distroId = 'rhel'; distroVersion = $ver; kernelVersion = '5.14.0-427.13.1.el9_4.x86_64'; fabric = 'mlx5' })
            }
            $j.Status | Should -Be 'UNKNOWN' -Because $ver
        }
    }
    It 'a kernel number that does not fit cannot be compared' {
        InModuleScope VmMigrationFactory {
            Compare-VmfKernelVersion -Running '5.15.0-99999999999999999999-azure' -Floor '5.15.0-1096' | Should -BeNullOrEmpty
            Compare-VmfKernelVersion -Running '5.15.0-1096-azure' -Floor '5.15.0-99999999999999999999' | Should -BeNullOrEmpty
            Compare-VmfKernelVersion -Running '5.15.0-1097-azure' -Floor '5.15.0-1096' | Should -Be 1
            Test-VmfKernelVersionPrefix -Running '5.15.0-99999999999999999999' -Floor '5.15.0-99999999999999999999.105' | Should -BeFalse
            $j = Get-VmfDriverJudgement -Facts ([pscustomobject]@{ os = 'Linux'; distroId = 'ubuntu'; distroVersion = '22.04'; kernelVersion = '5.15.0-99999999999999999999-azure'; fabric = 'mlx5' })
            $j.Status | Should -Be 'UNKNOWN'
        }
    }
    It 'the release upgrade named for MANA is none for a release nobody can read' {
        InModuleScope VmMigrationFactory { Get-VmfManaUpgradeRelease -Release @{ distroId = 'ubuntu'; version = '18.99999999999'; source = 'agent' } } | Should -BeNullOrEmpty
    }
}

Describe 'LINUX-VERSION-OVERFLOW-1: the run never calls a release it cannot read unlisted' {
    BeforeAll {
        $script:modOk = [pscustomobject]@{ checks = @([pscustomobject]@{ name = 'mana module available'; status = 'PASS'; detail = 'x' }) }
    }
    It 'a release version that does not fit: an old kernel is unknown, never unlisted' {
        InModuleScope VmMigrationFactory -Parameters @{ g = $script:modOk } {
            param($g) Get-VmfManaDriverPresence -GuestOutput $g -Os 'Linux' -Facts ([pscustomobject]@{ distroId = 'rhel'; distroVersion = '9.99999999999'; kernelVersion = '5.14.0-427.13.1.el9_4.x86_64' })
        } | Should -Be 'unknown'
    }
    It 'a release version that does not fit: a kernel of 6.14 or later is present - that rule does not depend on the release' {
        InModuleScope VmMigrationFactory -Parameters @{ g = $script:modOk } {
            param($g) Get-VmfManaDriverPresence -GuestOutput $g -Os 'Linux' -Facts ([pscustomobject]@{ distroId = 'rhel'; distroVersion = '9.99999999999'; kernelVersion = '6.14.0-1.x86_64' })
        } | Should -Be 'present'
    }
    It 'a release with no version, and a UEK kernel, are read as before' {
        InModuleScope VmMigrationFactory -Parameters @{ g = $script:modOk } {
            param($g) Get-VmfManaDriverPresence -GuestOutput $g -Os 'Linux' -Facts ([pscustomobject]@{ distroId = 'rhel'; distroVersion = ''; kernelVersion = '5.14.0-427.13.1.el9_4.x86_64' })
        } | Should -Be 'unlisted'
        InModuleScope VmMigrationFactory -Parameters @{ g = $script:modOk } {
            param($g) Get-VmfManaDriverPresence -GuestOutput $g -Os 'Linux' -Facts ([pscustomobject]@{ distroId = 'rhel'; distroVersion = '8.10'; kernelVersion = '4.18.0-553.el8_10.x86_64' })
        } | Should -Be 'unlisted' -Because 'a release that fits and is not listed is still unlisted'
    }
    It 'the kernel update says it cannot read the release, never that Microsoft does not list it' {
        $r = InModuleScope VmMigrationFactory {
            Resolve-VmfKernelUpdate -Os 'Linux' -Facts ([pscustomobject]@{ distroId = 'rhel'; distroVersion = '9.99999999999'; kernelVersion = '5.14.0-427.13.1.el9_4.x86_64' })
        }
        $r.Update | Should -BeFalse
        $r.Unlisted | Should -Not -BeTrue
        $r.Detail | Should -Not -Match 'does not list'
        $r.Detail | Should -Be 'The product cannot read the release version that the machine reported. The product did not update the kernel.'
        $s = InModuleScope VmMigrationFactory {
            Resolve-VmfKernelUpdate -Os 'Linux' -Facts ([pscustomobject]@{ distroId = 'rhel'; distroVersion = '8.10'; kernelVersion = '4.18.0-553.el8_10.x86_64' })
        }
        $s.Unlisted | Should -BeTrue -Because 'a release that fits and is not listed keeps its own words'
    }
}

Describe 'LINUX-VERSION-OVERFLOW-1: other numbers a guest reports' {
    It 'the LVM devices file: a count that does not fit is unknown' {
        $f = InModuleScope VmMigrationFactory {
            Get-VmfLvmDevicesFileFact -GuestOutput ([pscustomobject]@{ checks = @([pscustomobject]@{ name = 'lvm devices file'; detail = 'in use (/etc/lvm/devices/system.devices): 99999999999 physical volume(s), every one found' }) })
        }
        $f.State | Should -Be 'unknown'
        $f.Total | Should -BeNullOrEmpty
        $g = InModuleScope VmMigrationFactory {
            Get-VmfLvmDevicesFileFact -GuestOutput ([pscustomobject]@{ checks = @([pscustomobject]@{ name = 'lvm devices file'; detail = 'in use (/etc/lvm/devices/system.devices): 3 physical volume(s), 99999999999 not found' }) })
        }
        $g.State | Should -Be 'unknown' -Because 'a count of volumes not found that does not fit is unknown too'
        $h = InModuleScope VmMigrationFactory {
            Get-VmfLvmDevicesFileFact -GuestOutput ([pscustomobject]@{ checks = @([pscustomobject]@{ name = 'lvm devices file'; detail = 'in use (/etc/lvm/devices/system.devices): 3 physical volume(s), 1 not found' }) })
        }
        $h.State | Should -Be 'inUse'
        $h.Total | Should -Be 3
        $h.NotFound | Should -Be 1
    }
    It 'a Windows data disk whose number does not fit is not read' {
        $rows = InModuleScope VmMigrationFactory {
            Get-VmfDataDiskStates -GuestOutput ([pscustomobject]@{ checks = @([pscustomobject]@{ name = 'data disks'
                            detail = 'mbr:0a1b2c3d=99999999999:online:writable; mbr:0a1b2c3e=2:offline:writable' }) })
        }
        @($rows).Count | Should -Be 1
        @($rows)[0].Number | Should -Be 2
    }
    It 'an LVM topology whose counts do not fit leaves the counts unknown' {
        $f = InModuleScope VmMigrationFactory {
            Get-VmfStorageFacts -GuestOutput ([pscustomobject]@{ checks = @([pscustomobject]@{ name = 'lvm topology'; detail = '99999999999 volume group(s), 99999999999 logical volume(s)' }) })
        }
        $f.Groups | Should -BeNullOrEmpty
        $f.Volumes | Should -BeNullOrEmpty
        $f.Reported | Should -BeTrue
    }
    It 'a releasever lock that does not fit refuses nothing - the update runs and the reading after it judges' {
        $reach = InModuleScope VmMigrationFactory {
            Get-VmfKernelUpdateReach -Facts ([pscustomobject]@{ distroId = 'rhel'; distroVersion = '9.4'; kernelVersion = '5.14.0-427.13.1.el9_4.x86_64'; releaseverLock = '9.99999999999' })
        }
        $reach | Should -BeNullOrEmpty
    }
    It 'a cloud-init version that does not fit is not 23.2 or later' {
        InModuleScope VmMigrationFactory {
            Test-VmfCloudInitAppliesSriov -Version '99999999999.1' | Should -BeFalse
            Test-VmfCloudInitAppliesSriov -Version '23.99999999999' | Should -BeFalse
            Test-VmfCloudInitAppliesSriov -Version '24.99999999999' | Should -BeFalse -Because 'a version it cannot read is not, even when its major is above 23'
            Test-VmfCloudInitAppliesSriov -Version '23.2' | Should -BeTrue
        }
    }
    It 'a count of driver packages that does not fit is not read as a count' {
        $o = InModuleScope VmMigrationFactory {
            Get-VmfManaDriverInstallOutcome -GuestOutput ([pscustomobject]@{ result = 'FIXED'; checks = @([pscustomobject]@{ name = 'packages added'; detail = '99999999999' }) })
        }
        $o.Added | Should -Be 0
    }
}

Describe 'LINUX-VERSION-OVERFLOW-1: the scan finishes (F10 and F11)' {
    It 'F10: a long release on a supported image - the assessment is saved, and every machine is in it' {
        $r = LvoScan @((LvoRow -Name 'vm-long' -OsVersion $script:long), (LvoRow -Name 'vm-ok'))
        $r.Text | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'assessment.schema.json') | Should -BeTrue
        @($r.Doc.vms).Count | Should -Be 2
        $long = @($r.Doc.vms | Where-Object name -eq 'vm-long')[0]
        @($long.blockers) | Should -Not -Contain 'machine-not-read' -Because 'the reader no longer throws, so the record is made'
        @($long.blockers) | Should -Not -Contain 'linux-release-not-on-nvme-list' -Because 'a release nobody can read is never unlisted'
    }
    It 'F11: a long release on a custom image - the scan is saved, and the target advice is made for every machine' {
        $r = LvoScan @((LvoRow -Name 'vm-long' -OsVersion $script:long -Custom), (LvoRow -Name 'vm-ok'))
        @($r.Doc.vms).Count | Should -Be 2
        $long = @($r.Doc.vms | Where-Object name -eq 'vm-long')[0]
        $long.runningOsVersion | Should -Be $script:long -Because 'the scan records what the agent said'
        $advice = InModuleScope VmMigrationFactory -Parameters @{ d = $r.Doc; c = (LvoCatalog) } { param($d, $c) Get-VmfTargetAdvice -Assessment $d -CatalogByLocation $c }
        @($advice.machines).Count | Should -Be 2
        $m = @($advice.machines | Where-Object name -eq 'vm-long')[0]
        $m.linuxRelease.mana | Should -Be 'unknown'
        $m.linuxRelease.manaUpgrade | Should -BeNullOrEmpty
        ($advice | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json') | Should -BeTrue
    }
    It 'the advice reads a long release on a supported image too' {
        $advice = InModuleScope VmMigrationFactory -Parameters @{ d = [pscustomobject]@{ schemaVersion = 17; runId = 'scan-1'; vms = @((LvoRecord -OsVersion '22.99999999999')) }; c = (LvoCatalog) } {
            param($d, $c) Get-VmfTargetAdvice -Assessment $d -CatalogByLocation $c
        }
        $m = @($advice.machines)[0]
        $m.linuxRelease.source | Should -Be 'image'
        @($m.options | ForEach-Object { @($_.notSupported) }) | Should -Not -Contain 'machine-not-read'
    }
}

Describe 'LINUX-VERSION-OVERFLOW-1: one machine does not stop the others' {
    It 'the scan: a machine whose record cannot be made is held, and the others are judged' {
        $r = LvoScan @((LvoRow -Name 'vm-bad'), (LvoRow -Name 'vm-ok')) -Throw 'vm-bad'
        $r.Text | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'assessment.schema.json') | Should -BeTrue
        @($r.Doc.vms).Count | Should -Be 2 -Because 'no machine is dropped'
        $bad = @($r.Doc.vms | Where-Object name -eq 'vm-bad')[0]
        $bad.classification | Should -Be 'Blocked'
        @($bad.blockers) | Should -Be @('machine-not-read')
        $bad.vmId | Should -Match '/virtualMachines/vm-bad$'
        $bad.sourceSize | Should -Be 'Standard_D2s_v4'
        (@($bad.notes) -join ' ') | Should -Match 'too large or too small' -Because 'the note says what the product said'
        $ok = @($r.Doc.vms | Where-Object name -eq 'vm-ok')[0]
        $ok.classification | Should -Be 'ReadyAfterPrep'
        $r.Doc.summary.Blocked | Should -Be 1
        $r.Log | Should -Match 'vm-bad'
        $r.Log | Should -Match '"outcome":\s*"warn"'
    }
    It 'the scan names the machine under what it could not read, with what the product said' {
        $r = LvoScan @((LvoRow -Name 'vm-bad'), (LvoRow -Name 'vm-ok')) -Throw 'vm-bad'
        $e = @($r.Doc.notRead | Where-Object { $_.subject -eq 'machine' })
        $e.Count | Should -Be 1
        $e[0].scope | Should -Match '/virtualMachines/vm-bad$'
        $e[0].detail | Should -Match 'too large or too small'
        $e[0].machineCount | Should -Be 1
    }
    It 'the customer report names the machine, what the product said, and a new assessment' {
        InModuleScope VmMigrationFactory {
            $html = ConvertTo-VmfNotReadReportHtml -NotRead @([pscustomobject]@{ subject = 'machine'; machineCount = 1; detail = 'too <large>'
                    scope = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm-bad' })
            $html | Should -Match 'Machine vm-bad\.'
            $html | Should -Match 'so the machine is held'
            $html | Should -Match 'The product said: too &lt;large&gt;'
            $html | Should -Match 'Start a new assessment\.'
            $html | Should -Match 'A machine in this list is held until a new assessment reads it\.'
            $html | Should -Not -Match 'Everything else here is not affected'
        }
    }
    It 'the held record is made from the facts Azure gives, never from what the VM agent reported' {
        $rec = InModuleScope VmMigrationFactory -Parameters @{ v = (LvoRow -Name 'vm-bad' -OsVersion $script:long) } { param($v) Get-VmfMachineNotReadRecord -Vm $v -Detail 'x' }
        $rec.runningOsVersion | Should -Be ''
        $rec.runningOsName | Should -Be ''
        $rec.os | Should -Be 'Linux'
        $rec.gen | Should -Be 'V2'
        @($rec.warnings).Count | Should -Be 0
        @($rec.prepNeeded).Count | Should -Be 0
    }
    It 'the target advice: a held record gets no supported option, and the reason says why' {
        $rec = InModuleScope VmMigrationFactory -Parameters @{ v = (LvoRow -Name 'vm-bad') } { param($v) Get-VmfMachineNotReadRecord -Vm $v -Detail 'x' }
        $advice = InModuleScope VmMigrationFactory -Parameters @{ d = [pscustomobject]@{ schemaVersion = 17; runId = 'scan-1'; vms = @($rec) }; c = (LvoCatalog) } {
            param($d, $c) Get-VmfTargetAdvice -Assessment $d -CatalogByLocation $c
        }
        $m = @($advice.machines)[0]
        foreach ($o in @($m.options)) {
            $o.supported | Should -BeFalse
            @($o.notSupported) | Should -Contain 'machine-not-read' -Because "option $($o.option)"
        }
        ($advice | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json') | Should -BeTrue
    }
    It 'the target advice: a machine whose options cannot be made is held, and the others get theirs' {
        $d = [pscustomobject]@{ schemaVersion = 17; runId = 'scan-1'; vms = @((LvoRecord -Name 'vm-bad'), (LvoRecord -Name 'vm-ok')) }
        $advice = InModuleScope VmMigrationFactory -Parameters @{ d = $d; c = (LvoCatalog) } {
            param($d, $c)
            Mock Get-VmfAdviceOption { throw 'Value was either too large or too small for an Int32.' } -ParameterFilter { [string]$Vm.name -eq 'vm-bad' }
            Get-VmfTargetAdvice -Assessment $d -CatalogByLocation $c -WarningAction SilentlyContinue
        }
        @($advice.machines).Count | Should -Be 2
        $bad = @($advice.machines | Where-Object name -eq 'vm-bad')[0]
        @($bad.options).Count | Should -Be 3
        foreach ($o in @($bad.options)) {
            $o.supported | Should -BeFalse
            @($o.notSupported) | Should -Be @('machine-not-read')
        }
        $bad.start.current | Should -BeNullOrEmpty
        $bad.start.extended | Should -BeNullOrEmpty
        $bad.linuxRelease.mana | Should -Be 'unknown'
        $ok = @($advice.machines | Where-Object name -eq 'vm-ok')[0]
        @($ok.options | Where-Object { $_.supported }).Count | Should -BeGreaterThan 0
        ($advice | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json') | Should -BeTrue
    }
    It 'the advise operation writes the options and names the machine it could not read in its run log' {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-lvo-adv-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            $rec = InModuleScope VmMigrationFactory -Parameters @{ v = (LvoRow -Name 'vm-bad') } { param($v) Get-VmfMachineNotReadRecord -Vm $v -Detail 'x' }
            $doc = [ordered]@{ schemaVersion = 17; runId = (Split-Path $rp -Leaf); vms = @($rec, (LvoRecord -Name 'vm-ok')) }
            InModuleScope VmMigrationFactory -Parameters @{ p = $rp; d = $doc } {
                param($p, $d)
                Initialize-VmfRun -RunPath $p -RunId (Split-Path $p -Leaf) -Kind 'assessment' | Out-Null
                Write-VmfStoreJson -RunPath $p -RelPath 'assessment.json' -Document $d -Depth 24
            }
            Approve-VmfAssessment -RunPath $rp -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } | Out-Null
            $script:lvoCat = @((LvoCatalog).centralus.Values)
            Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { $script:lvoCat }
            $r = New-VmfTargetAdvice -AssessmentPath (Join-Path $rp 'assessment.json')
            $r.Machines | Should -Be 2
            $log = (Get-ChildItem $rp -Recurse -File | Where-Object Name -Match 'event' | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"
            $log | Should -Match 'The facts of vm-bad could not be read'
            $log | Should -Not -Match 'The facts of vm-ok'
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'the target advice says which machine it could not read' {
        $d = [pscustomobject]@{ schemaVersion = 17; runId = 'scan-1'; vms = @((LvoRecord -Name 'vm-bad')) }
        $warn = InModuleScope VmMigrationFactory -Parameters @{ d = $d; c = (LvoCatalog) } {
            param($d, $c)
            Mock Get-VmfAdviceOption { throw 'boom' } -ParameterFilter { [string]$Vm.name -eq 'vm-bad' }
            $null = Get-VmfTargetAdvice -Assessment $d -CatalogByLocation $c -WarningVariable w -WarningAction SilentlyContinue
            @($w | ForEach-Object { [string]$_ })
        }
        ($warn -join ' ') | Should -Match 'vm-bad'
        ($warn -join ' ') | Should -Match 'boom'
    }
}

Describe 'LINUX-VERSION-OVERFLOW-1: the contract and the words' {
    It 'target-advice v34 has the reason machine-not-read, in one place' {
        $s = Get-Content (Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json') -Raw | ConvertFrom-Json -Depth 30
        $s.properties.schemaVersion.const | Should -Be 34
        @($s.'$defs'.reason.enum) | Should -Contain 'machine-not-read'
        InModuleScope VmMigrationFactory { Get-VmfTargetAdviceSchemaVersion | Should -Be 34 }
        (Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'target-advice.sample.json') -Raw | ConvertFrom-Json).schemaVersion | Should -Be 34
        (Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw) | Should -Match 'target-advice v33 -> v34 \(2026-11-22, LINUX-VERSION-OVERFLOW-1\)'
    }
    It 'the blocker has words on every series, and its fix is a new assessment' {
        $reasons = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'assessment-reasons.json') -Raw | ConvertFrom-Json
        $b = $reasons.blockers.'machine-not-read'
        $b | Should -Not -BeNullOrEmpty
        $b.whatToDo | Should -Match 'new assessment'
        @($b.appliesTo) | Should -Be @('v5', 'v6', 'v7')
    }
}
