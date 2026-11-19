#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# TARGET-CAPABILITY-PRECHECK-1 (plan approved in full, 2026-11-14):
# a target size that does not support a feature the machine uses is
# not offered, and Checking stops the machine untouched before any change.
#
# Before it, the capture recorded encryption at host and Ultra Disk
# compatibility, and only Verifying compared them - after the move. Nothing
# read the target size's EncryptionAtHostSupported or UltraSSDAvailable, so
# Azure refused the resize in Moving, after the stop, and the rollback put the
# machine back and discarded every write since the first copy.
#
# Microsoft, disks-enable-ultra-ssd.md, "Determine VM size and region
# availability": a machine in a zone reads the size's ZoneDetails ("If there
# was no response from the command, then the selected VM size is not supported
# with Ultra Disks in the selected region"); a machine with no zone reads the
# size's UltraSSDAvailable capability. disks-deploy-premium-v2.md: a Premium
# SSD v2 disk goes on "a VM in the same region and availability zone that
# supports Premium Storage" (PremiumIO).
#
# A capability the catalog does not give is "cannot verify", never "fits"
# (CLAUDE.md, NIC-1).

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    . (Join-Path $PSScriptRoot '_RecordShape.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }

    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers'
    $script:vmId = "$($script:sub)/Microsoft.Compute/virtualMachines/vm1"

    # One size, shaped as Get-AzComputeResourceSku gives it. $Eah, $Ultra and
    # $Premium: 'True', 'False', or $null for a capability the entry does not
    # give. $ZoneUltra: the zones whose ZoneDetails say UltraSSDAvailable True;
    # $NoZoneDetails leaves ZoneDetails out ($null), which is not a no.
    function Global:TcSku {
        param([string]$Name = 'Standard_D2s_v6', $Eah = 'True', $Ultra = $null, $Premium = 'True',
              [string[]]$Zones = @('1', '2', '3'), [string[]]$ZoneUltra = @(), [switch]$NoZoneDetails, [switch]$NoLocationInfo,
              [string]$TempMb = '0', [string]$Gens = 'V1,V2')
        $caps = @(
            [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = $TempMb }
            [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '4' }
            [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '8' }
            [pscustomobject]@{ Name = 'HyperVGenerations'; Value = $Gens })
        if ($null -ne $Eah) { $caps += [pscustomobject]@{ Name = 'EncryptionAtHostSupported'; Value = $Eah } }
        if ($null -ne $Ultra) { $caps += [pscustomobject]@{ Name = 'UltraSSDAvailable'; Value = $Ultra } }
        if ($null -ne $Premium) { $caps += [pscustomobject]@{ Name = 'PremiumIO'; Value = $Premium } }
        $entry = [ordered]@{ Name = $Name; ResourceType = 'virtualMachines'; Family = 'standardX'; Restrictions = @(); Capabilities = $caps }
        if (-not $NoLocationInfo) {
            $details = if ($NoZoneDetails) { $null } else {
                , @(if ($ZoneUltra.Count) { [pscustomobject]@{ Name = [string[]]$ZoneUltra; Capabilities = @([pscustomobject]@{ Name = 'UltraSSDAvailable'; Value = 'True' }) } }) }
            $entry.LocationInfo = @([pscustomobject]@{ Location = 'centralus'; Zones = [string[]]$Zones; ZoneDetails = $details })
        }
        [pscustomobject]$entry
    }

    # An assessed machine, as the scan records it.
    function Global:TcVm {
        param([string]$Size = 'Standard_D2s_v4', $Eah, $Ultra, [string[]]$Zones = @())
        $vm = [ordered]@{
            vmId = "$($script:sub)/Microsoft.Compute/virtualMachines/tc"
            name = 'tc'; location = 'centralus'; zones = @($Zones); classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'
            osVersion = '22_04-lts-gen2'; sourceSize = $Size; sourceDiskArch = 'diskless'; sourceTempDisks = 0
            diskController = 'SCSI'; dataDiskCount = 0; nicCount = 1; acceleratedNicCount = 1; primaryNicAccelerated = $true
            platformManaged = $false; blockers = @(); prepNeeded = @()
        }
        if ($PSBoundParameters.ContainsKey('Eah')) { $vm.encryptionAtHost = $Eah }
        if ($PSBoundParameters.ContainsKey('Ultra')) { $vm.ultraSsdEnabled = $Ultra }
        [pscustomobject]$vm
    }
    function Global:TcCatalog([object[]]$Skus) { $c = @{}; foreach ($s in $Skus) { $c[$s.Name] = $s }; $c }
    function Global:TcAdvise($Vm, [hashtable]$Catalog) {
        $doc = [pscustomobject]@{ schemaVersion = 17; runId = 'scan-1'; vms = @($Vm) }
        InModuleScope VmMigrationFactory -Parameters @{ d = $doc; c = @{ centralus = $Catalog } } {
            param($d, $c) Get-VmfTargetAdvice -Assessment $d -CatalogByLocation $c
        }
    }
    function Global:TcOpt($Advice, [string]$Option) { @($Advice.machines[0].options) | Where-Object { $_.option -eq $Option } | Select-Object -First 1 }

    # A machine shaped like Get-AzVM returns, single interface, no data disks.
    function Global:TcAzVm {
        param([string[]]$Zones = @(), $Eah, [bool]$Ultra = $false)
        [pscustomobject]@{
            Name = 'vm1'; ResourceGroupName = 'rg-app'; Location = 'centralus'
            HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_D2s_v4' }
            StorageProfile = [pscustomobject]@{
                DiskControllerType = 'SCSI'
                OsDisk = [pscustomobject]@{ OsType = 'Linux'; Name = 'vm1-os'; DeleteOption = 'Delete'
                    ManagedDisk = [pscustomobject]@{ Id = "$($script:sub)/Microsoft.Compute/disks/vm1-os"; StorageAccountType = 'Premium_LRS' } }
                DataDisks = @(); ImageReference = $null
            }
            NetworkProfile = [pscustomobject]@{ NetworkInterfaces = @([pscustomobject]@{ Id = "$($script:sub)/Microsoft.Network/networkInterfaces/nic0"; Primary = $true }) }
            Zones = $Zones; Tags = @{}
            LicenseType = $null; AvailabilitySetReference = $null; ProximityPlacementGroup = $null
            Priority = $null; Identity = $null
            SecurityProfile = $(if ($null -ne $Eah) { [pscustomobject]@{ SecurityType = $null; UefiSettings = $null; EncryptionAtHost = $Eah } } else { $null })
            AdditionalCapabilities = [pscustomobject]@{ UltraSSDEnabled = $Ultra; HibernationEnabled = $false }
            DiagnosticsProfile = $null
        }
    }
    function Global:TcPlan([string]$Zone) {
        [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vmId; wave = 'w1'; ring = 'lab'; path = 'A'
            assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'; sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; platformManaged = $false; location = 'centralus' }
            target = [pscustomobject]@{ size = 'Standard_D2s_v6'; diskArch = 'diskless'; controller = 'NVMe'; zone = $(if ($Zone) { $Zone } else { $null }) }
            policy = [pscustomobject]@{ onDDataFound = 'proceed' } }
    }
    # A capture, as PRECHECK passes it, for the direct tests of the gate.
    function Global:TcCapture {
        param($Eah = $null, [bool]$Ultra = $false, [string[]]$Zones = @(), [string[]]$DataTypes = @())
        $i = 0
        [pscustomobject]@{ name = 'vm1'; size = 'Standard_D2s_v4'; location = 'centralus'; zones = @($Zones); osType = 'Linux'
            securityProfile = $(if ($null -ne $Eah) { [pscustomobject]@{ securityType = ''; encryptionAtHost = $Eah } } else { $null })
            ultraSsdEnabled = $Ultra
            osDisk = [pscustomobject]@{ name = 'vm1-os'; skuName = 'Premium_LRS'; managedDiskId = "$($script:sub)/Microsoft.Compute/disks/vm1-os" }
            dataDisks = @(foreach ($t in $DataTypes) {
                    [pscustomobject]@{ name = "vm1-data$i"; lun = $i; skuName = $t; managedDiskId = "$($script:sub)/Microsoft.Compute/disks/vm1-data$i"; caching = 'None'; sizeGB = 64 }
                    $i++ })
            nics = @([pscustomobject]@{ id = "$($script:sub)/Microsoft.Network/networkInterfaces/nic0"; primary = $true; acceleratedNetworking = $true }) }
    }
    function Global:TcGate($Capture, [string]$Zone) {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-tcp-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; plan = (TcPlan $Zone); cap = $Capture } {
                param($rp, $plan, $cap)
                Initialize-VmfRun -RunPath $rp -RunId 'tcp' | Out-Null
                $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'tcp'
                New-VmfStateDoc -RunPath $rp -RunId 'tcp' -VmId $ctx.VmId | Out-Null
                Test-VmfTargetFeaturesReady -Context $ctx -PlanEntry $plan -Capture $cap
            }
        }
        finally { if (Test-Path $rp) { Remove-Item $rp -Recurse -Force } }
    }
}
AfterAll {
    Remove-Item 'function:\TcSku', 'function:\TcVm', 'function:\TcCatalog', 'function:\TcAdvise', 'function:\TcOpt', 'function:\TcAzVm',
        'function:\TcPlan', 'function:\TcCapture', 'function:\TcGate' -ErrorAction SilentlyContinue
}

Describe 'TARGET-CAPABILITY-PRECHECK-1: what the catalog says about a size' {
    It 'encryption at host: True is yes, False is no, a capability the entry does not give is unknown' {
        InModuleScope VmMigrationFactory {
            Test-VmfSkuEncryptionAtHost -SkuEntry (TcSku -Eah 'True') | Should -BeTrue
            Test-VmfSkuEncryptionAtHost -SkuEntry (TcSku -Eah 'False') | Should -BeFalse
            $null -eq (Test-VmfSkuEncryptionAtHost -SkuEntry (TcSku -Eah $null)) | Should -BeTrue -Because 'absent is "cannot verify", never "fits" and never "no"'
            $null -eq (Test-VmfSkuEncryptionAtHost -SkuEntry $null) | Should -BeTrue
        }
    }

    It 'Ultra Disk in a zone: the ZoneDetails of that zone say it' {
        InModuleScope VmMigrationFactory {
            Test-VmfSkuUltraDisk -SkuEntry (TcSku -ZoneUltra @('2', '3')) -Zone '2' -Location 'centralus' | Should -BeTrue
            Test-VmfSkuUltraDisk -SkuEntry (TcSku -ZoneUltra @('1', '3')) -Zone '2' -Location 'centralus' | Should -BeFalse -Because 'another zone of the region is not the zone of the machine'
            Test-VmfSkuUltraDisk -SkuEntry (TcSku) -Zone '2' -Location 'centralus' | Should -BeFalse -Because 'Microsoft: no ZoneDetails is not supported'
            # The regional capability does not answer for a zone.
            Test-VmfSkuUltraDisk -SkuEntry (TcSku -Ultra 'True') -Zone '2' -Location 'centralus' | Should -BeFalse
        }
    }

    It 'Ultra Disk in a zone: no location entry, or ZoneDetails not given, is unknown; another region''s entry is not read' {
        InModuleScope VmMigrationFactory {
            $null -eq (Test-VmfSkuUltraDisk -SkuEntry (TcSku -NoLocationInfo) -Zone '2' -Location 'centralus') | Should -BeTrue
            $null -eq (Test-VmfSkuUltraDisk -SkuEntry (TcSku -NoZoneDetails) -Zone '2' -Location 'centralus') | Should -BeTrue
            $null -eq (Test-VmfSkuUltraDisk -SkuEntry $null -Zone '2' -Location 'centralus') | Should -BeTrue
            $null -eq (Test-VmfSkuUltraDisk -SkuEntry (TcSku -ZoneUltra @('2')) -Zone '2' -Location 'eastus2') | Should -BeTrue -Because 'the entry is for centralus'
        }
    }

    It 'Ultra Disk with no zone: the UltraSSDAvailable capability says it, absent is unknown' {
        InModuleScope VmMigrationFactory {
            Test-VmfSkuUltraDisk -SkuEntry (TcSku -Ultra 'True') -Zone '' -Location 'centralus' | Should -BeTrue
            Test-VmfSkuUltraDisk -SkuEntry (TcSku -Ultra 'False') -Zone '' -Location 'centralus' | Should -BeFalse
            $null -eq (Test-VmfSkuUltraDisk -SkuEntry (TcSku -ZoneUltra @('1', '2', '3')) -Zone '' -Location 'centralus') | Should -BeTrue -Because 'zone details do not answer for a machine with no zone'
        }
    }
}

Describe 'TARGET-CAPABILITY-PRECHECK-1: which features of the machine a size does not support' {
    It 'a machine that uses nothing has no gap, whatever the size says' {
        InModuleScope VmMigrationFactory {
            @(Get-VmfTargetFeatureGaps -EncryptionAtHost $false -UltraSsdEnabled $false -SkuEntry (TcSku -Eah 'False' -Premium 'False') -Location 'centralus') |
                Should -BeNullOrEmpty
            @(Get-VmfTargetFeatureGaps -SkuEntry $null -Location 'centralus') | Should -BeNullOrEmpty
        }
    }

    It 'each feature the machine uses and the size does not support, or the catalog does not say, is a gap' {
        InModuleScope VmMigrationFactory {
            $g = @(Get-VmfTargetFeatureGaps -EncryptionAtHost $true -UltraSsdEnabled $true -Zone '2' -SkuEntry (TcSku -Eah 'False') -Location 'centralus')
            @($g.feature) | Should -Be @('encryptionAtHost', 'ultraDisk')
            $g[0].supported | Should -BeFalse
            $g[1].supported | Should -BeFalse
            $u = @(Get-VmfTargetFeatureGaps -EncryptionAtHost $true -SkuEntry (TcSku -Eah $null) -Location 'centralus')
            $u.Count | Should -Be 1
            $null -eq $u[0].supported | Should -BeTrue
            @(Get-VmfTargetFeatureGaps -EncryptionAtHost $true -UltraSsdEnabled $true -Zone '2' -SkuEntry (TcSku -ZoneUltra '2') -Location 'centralus') |
                Should -BeNullOrEmpty
        }
    }

    It 'Ultra Disk compatibility on a size whose catalog entry does not say is a gap too - unknown is not a yes' {
        InModuleScope VmMigrationFactory {
            $z = @(Get-VmfTargetFeatureGaps -UltraSsdEnabled $true -Zone '2' -SkuEntry (TcSku -NoZoneDetails) -Location 'centralus')
            @($z.feature) | Should -Be @('ultraDisk')
            $null -eq $z[0].supported | Should -BeTrue
            $r = @(Get-VmfTargetFeatureGaps -UltraSsdEnabled $true -Zone '' -SkuEntry (TcSku) -Location 'centralus')
            @($r.feature) | Should -Be @('ultraDisk') -Because 'a machine with no zone, and no UltraSSDAvailable on the size'
        }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @(TcSku) }
        $g = TcGate (TcCapture -Ultra $true)
        $g.Reason | Should -Be 'targetFeatureNotSupported'
        $g.Detail | Should -Match 'Azure does not say whether the size Standard_D2s_v6 supports Ultra Disks in centralus'
    }

    It 'a Premium SSD v2 or Ultra Disk needs a size that supports Premium Storage (PremiumIO)' {
        InModuleScope VmMigrationFactory {
            $disks = @([pscustomobject]@{ name = 'd0'; skuName = 'PremiumV2_LRS' }, [pscustomobject]@{ name = 'd1'; skuName = 'UltraSSD_LRS' },
                [pscustomobject]@{ name = 'd2'; skuName = 'StandardSSD_LRS' })
            $g = @(Get-VmfTargetFeatureGaps -Disks $disks -SkuEntry (TcSku -Premium 'False') -Location 'centralus')
            @($g.feature) | Should -Be @('premiumStorage', 'premiumStorage')
            @($g.disk) | Should -Be @('d0', 'd1')
            $u = @(Get-VmfTargetFeatureGaps -Disks $disks -SkuEntry (TcSku -Premium $null) -Location 'centralus')
            $u.Count | Should -Be 2
            $null -eq $u[0].supported | Should -BeTrue
            @(Get-VmfTargetFeatureGaps -Disks $disks -SkuEntry (TcSku -Premium 'True') -Location 'centralus') | Should -BeNullOrEmpty
        }
    }
}

Describe 'TARGET-CAPABILITY-PRECHECK-1: the target advice does not offer such a size' {
    It 'THE CASE: a machine with encryption at host is not offered a size that does not support it' {
        $cat = TcCatalog @((TcSku 'Standard_D2s_v5' -Eah 'False'), (TcSku 'Standard_D2s_v6' -Eah 'False'))
        $a = TcAdvise (TcVm -Eah $true) $cat
        foreach ($s in 'v5', 'v6') {
            $o = TcOpt $a $s
            $o.supported | Should -BeFalse -Because $s
            @($o.notSupported) | Should -Contain 'no-encryption-at-host'
        }
        $a.machines[0].start.current | Should -BeNullOrEmpty
        $a.machines[0].start.extended | Should -BeNullOrEmpty
    }

    It 'a size whose catalog entry does not say is not offered either - unknown is not a yes' {
        $cat = TcCatalog @((TcSku 'Standard_D2s_v6' -Eah $null))
        @((TcOpt (TcAdvise (TcVm -Eah $true) $cat) 'v6').notSupported) | Should -Contain 'no-encryption-at-host'
    }

    It 'a size that supports encryption at host is offered' {
        $cat = TcCatalog @((TcSku 'Standard_D2s_v5'), (TcSku 'Standard_D2s_v6'))
        $a = TcAdvise (TcVm -Eah $true) $cat
        (TcOpt $a 'v6').supported | Should -BeTrue
        $a.machines[0].start.current | Should -Be 'v6'
    }

    It 'a machine without the feature is offered the size as before, whatever the catalog says' {
        $cat = TcCatalog @((TcSku 'Standard_D2s_v6' -Eah 'False'))
        (TcOpt (TcAdvise (TcVm -Eah $false) $cat) 'v6').supported | Should -BeTrue
        (TcOpt (TcAdvise (TcVm) $cat) 'v6').supported | Should -BeTrue -Because 'a record with no field is not a machine that uses it'
    }

    It 'a machine in zone 2 with Ultra Disk compatibility enabled: offered only where zone 2 supports Ultra Disks' {
        $no = TcCatalog @((TcSku 'Standard_D2s_v6' -ZoneUltra @('1')))
        @((TcOpt (TcAdvise (TcVm -Ultra $true -Zones @('2')) $no) 'v6').notSupported) | Should -Contain 'no-ultra-disk'
        $yes = TcCatalog @((TcSku 'Standard_D2s_v6' -ZoneUltra @('2')))
        (TcOpt (TcAdvise (TcVm -Ultra $true -Zones @('2')) $yes) 'v6').supported | Should -BeTrue
    }

    It 'the plan gets no target and the reason in words, naming the feature and the size' {
        $cat = TcCatalog @((TcSku 'Standard_D2s_v6' -Eah 'False'))
        $t = InModuleScope VmMigrationFactory -Parameters @{ v = (TcVm -Eah $true); c = $cat } {
            param($v, $c) Resolve-VmfEntryTarget -Assessment $v -CatalogBySize $c -TargetGeneration 'v6'
        }
        $t.Mapping.Target | Should -BeNullOrEmpty
        $t.Mapping.Code | Should -Be 'no-encryption-at-host'
        $t.Path | Should -Be 'MANUAL'
        $t.Mapping.Reason | Should -Match 'encryption at host'
        $t.Mapping.Reason | Should -Match 'Standard_D2s_v6'
        $u = InModuleScope VmMigrationFactory -Parameters @{ v = (TcVm -Ultra $true -Zones @('2')); c = (TcCatalog @((TcSku 'Standard_D2s_v6'))) } {
            param($v, $c) Resolve-VmfEntryTarget -Assessment $v -CatalogBySize $c -TargetGeneration 'v6'
        }
        $u.Mapping.Code | Should -Be 'no-ultra-disk'
        $u.Mapping.Reason | Should -Match 'Ultra Disk'
        $u.Mapping.Reason | Should -Match 'zone 2 of centralus'
    }

    It 'the advice schema lists both codes, and the targets step has words for both' {
        $s = Get-Content (Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json') -Raw | ConvertFrom-Json -Depth 40
        $s.'$defs'.reason.enum | Should -Contain 'no-encryption-at-host'
        $s.'$defs'.reason.enum | Should -Contain 'no-ultra-disk'
        $s.properties.schemaVersion.const | Should -Be 33
        InModuleScope VmMigrationFactory { Get-VmfTargetAdviceSchemaVersion | Should -Be 33 }
        $js = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.js') -Raw
        $js | Should -Match "'no-encryption-at-host': '"
        $js | Should -Match "'no-ultra-disk': '"
    }
}

Describe 'TARGET-CAPABILITY-PRECHECK-1: the scan records both features' {
    It 'the Resource Graph query reads encryption at host and Ultra Disk compatibility' {
        $q = InModuleScope VmMigrationFactory { $script:VmfArgQuery }
        $q | Should -Match 'encryptionAtHost = tobool\(properties\.securityProfile\.encryptionAtHost\)'
        $q | Should -Match 'ultraSsdEnabled = tobool\(properties\.additionalCapabilities\.ultraSSDEnabled\)'
        $q | Should -Match '(?s)\| project [^|]*encryptionAtHost'
        $q | Should -Match '(?s)\| project [^|]*ultraSsdEnabled'
    }

    It 'the record says each one; a row that does not say leaves it out' {
        $base = @{ id = "$($script:sub)/Microsoft.Compute/virtualMachines/a"; name = 'a'; resourceGroup = 'rg-app'; location = 'centralus'
            sku = 'Standard_D2s_v4'; os = 'Linux'; gen = 'V2'; diskController = 'SCSI'; osDiskManagedId = '/s/rg/disks/a'; nicCount = 1 }
        $records = InModuleScope VmMigrationFactory -Parameters @{ b = $base } {
            param($b)
            $on = [pscustomobject]($b + @{ encryptionAtHost = $true; ultraSsdEnabled = $true })
            # Azure leaves the property out when it is not set, and Resource
            # Graph gives null for it: that is off.
            $off = [pscustomobject]($b + @{ encryptionAtHost = $null; ultraSsdEnabled = $false })
            $old = [pscustomobject]$b
            @((Get-VmfAssessmentRecord -Vm $on), (Get-VmfAssessmentRecord -Vm $off), (Get-VmfAssessmentRecord -Vm $old))
        }
        $records[0].encryptionAtHost | Should -BeTrue
        $records[0].ultraSsdEnabled | Should -BeTrue
        $records[1].encryptionAtHost | Should -BeFalse
        $records[1].ultraSsdEnabled | Should -BeFalse
        $null -eq $records[2].PSObject.Properties['encryptionAtHost'] | Should -BeTrue -Because 'a row that does not say is unknown, never "off"'
        $null -eq $records[2].PSObject.Properties['ultraSsdEnabled'] | Should -BeTrue
    }

    It 'the assessment is version 17, and its schema holds both fields' {
        InModuleScope VmMigrationFactory {
            Get-VmfAssessmentSchemaVersion | Should -Be 17
            { Assert-VmfSupportedAssessment -Assessment ([pscustomobject]@{ schemaVersion = 16 }) } | Should -Throw '*reads only version 17*'
        }
        $s = Get-Content (Join-Path $script:repoRoot 'schemas' 'assessment.schema.json') -Raw | ConvertFrom-Json -Depth 40
        $s.properties.schemaVersion.const | Should -Be 17
        $s.properties.vms.items.properties.encryptionAtHost | Should -Not -BeNullOrEmpty
        $s.properties.vms.items.properties.ultraSsdEnabled | Should -Not -BeNullOrEmpty
    }
}

Describe 'TARGET-CAPABILITY-PRECHECK-1: Checking asks the catalog again, before any change' {
    It 'encryption at host on a size that does not support it: stopped, naming the feature and the size' {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @(TcSku -Eah 'False') }
        $r = TcGate (TcCapture -Eah $true)
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'targetFeatureNotSupported'
        $r.Detail | Should -Match 'encryption at host'
        $r.Detail | Should -Match 'Standard_D2s_v6 does not support'
    }

    It 'a catalog that does not say stops it too, and says that Azure does not say' {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @(TcSku -Eah $null) }
        $r = TcGate (TcCapture -Eah $true)
        $r.Reason | Should -Be 'targetFeatureNotSupported'
        $r.Detail | Should -Match 'Azure does not say whether the size Standard_D2s_v6 supports'
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @() }
        (TcGate (TcCapture -Eah $true)).Reason | Should -Be 'targetFeatureNotSupported' -Because 'a size the catalog does not list cannot be verified'
    }

    It 'Ultra Disk compatibility in zone 2 on a size that does not support it there: stopped, naming the zone' {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @(TcSku -ZoneUltra @('1')) }
        $r = TcGate (TcCapture -Ultra $true -Zones @('2')) '2'
        $r.Reason | Should -Be 'targetFeatureNotSupported'
        $r.Detail | Should -Match 'Ultra Disk'
        $r.Detail | Should -Match 'zone 2 of centralus'
    }

    It 'a Premium SSD v2 data disk on a size that does not support Premium Storage: stopped, naming the disk' {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @(TcSku -Premium 'False') }
        $r = TcGate (TcCapture -DataTypes @('PremiumV2_LRS'))
        $r.Reason | Should -Be 'targetFeatureNotSupported'
        $r.Detail | Should -Match "'vm1-data0'"
        $r.Detail | Should -Match 'Premium SSD v2'
        $r.Detail | Should -Match 'Premium Storage'
    }

    It 'every feature supported: go on' {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @(TcSku -ZoneUltra @('2')) }
        TcGate (TcCapture -Eah $true -Ultra $true -Zones @('2') -DataTypes @('PremiumV2_LRS', 'UltraSSD_LRS')) '2' | Should -BeNullOrEmpty
    }

    It 'a machine that uses none of them: no catalog read at all' {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @(TcSku -Eah 'False' -Premium 'False') }
        TcGate (TcCapture -Eah $false -DataTypes @('StandardSSD_LRS')) | Should -BeNullOrEmpty
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfSkuCatalog -Times 0 -Exactly
    }

    It 'the catalog is read as the machine''s own subscription' {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @(TcSku) }
        TcGate (TcCapture -Eah $true) | Should -BeNullOrEmpty
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfSkuCatalog -ParameterFilter { $SubscriptionId -eq '00000000-0000-0000-0000-000000000000' -and $Location -eq 'centralus' }
    }
}

Describe 'TARGET-CAPABILITY-PRECHECK-1: PRECHECK stops the machine untouched' {
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-tcpre-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Initialize-VmfRun -RunPath $rp -RunId 'tcpre' | Out-Null }
        Mock -ModuleName VmMigrationFactory Test-VmfAdeExtension { $false }
        Mock -ModuleName VmMigrationFactory Get-VmfVmResourceLocks { , @() }
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { @([pscustomobject]@{ actions = @('*'); notActions = @() }) }
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/running' }
        Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions { @() }
        Mock -ModuleName VmMigrationFactory Get-AzNetworkInterface { [pscustomobject]@{ EnableAcceleratedNetworking = $true } }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { throw 'the machine must not be touched' }
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'THE CASE: encryption at host, a target size that does not support it - stopped at Checking, and again on a resume' {
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { Global:TcAzVm -Eah $true }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @(Global:TcSku -Eah 'False') }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; plan = (TcPlan) } {
            param($rp, $plan)
            $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'tcpre'
            New-VmfStateDoc -RunPath $rp -RunId 'tcpre' -VmId $ctx.VmId | Out-Null
            $r = Invoke-VmfStepPrecheck -Context $ctx
            $r.Next | Should -Be 'NEEDS_DECISION'
            $r.Reason | Should -Be 'targetFeatureNotSupported'
            $r.Detail | Should -Match 'Standard_D2s_v6'
            # Kill-resume: Checking runs again from the top and gives the same answer.
            $again = Invoke-VmfStepPrecheck -Context $ctx
            $again.Reason | Should -Be 'targetFeatureNotSupported'
            $again.Detail | Should -Be $r.Detail
        }
        Should -Invoke -ModuleName VmMigrationFactory Stop-VmfVmDeallocated -Times 0 -Exactly
    }

    It 'a target size that supports it goes on to the first safety copy' {
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { Global:TcAzVm -Eah $true -Ultra $true -Zones @('2') }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @(Global:TcSku -ZoneUltra @('2')) }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; plan = (TcPlan '2') } {
            param($rp, $plan)
            $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'tcpre'
            New-VmfStateDoc -RunPath $rp -RunId 'tcpre' -VmId $ctx.VmId | Out-Null
            (Invoke-VmfStepPrecheck -Context $ctx).Next | Should -Be 'SAFETY_PRISTINE'
        }
    }

    It 'Ultra Disk compatibility in zone 2, a size without Ultra Disks in zone 2 - stopped at Checking' {
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { Global:TcAzVm -Ultra $true -Zones @('2') }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @(Global:TcSku -ZoneUltra @('1', '3')) }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; plan = (TcPlan '2') } {
            param($rp, $plan)
            $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'tcpre'
            New-VmfStateDoc -RunPath $rp -RunId 'tcpre' -VmId $ctx.VmId | Out-Null
            $r = Invoke-VmfStepPrecheck -Context $ctx
            $r.Reason | Should -Be 'targetFeatureNotSupported'
            $r.Detail | Should -Match 'zone 2'
        }
    }

    It 'the stop is declared: the machine is untouched, and another target or turning the feature off fixes it' {
        $reason = @((Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json).reasons) |
            Where-Object code -EQ 'targetFeatureNotSupported'
        $reason | Should -Not -BeNullOrEmpty
        $reason.machine | Should -Be 'untouched'
        $reason.retry | Should -Be 'afterFix'
        # Review: a Premium SSD v2 or Ultra Disk is a disk type, not a feature a person turns off.
        $reason.whatToDo | Should -Match 'To move this machine to another size, select Leave this machine out\. Then assess the machines again, and plan this machine in a new migration\.'
        $reason.whatToDo | Should -Match 'To keep this size, turn off the feature, or change the type of the disk that the stop names\.$'
    }
}
