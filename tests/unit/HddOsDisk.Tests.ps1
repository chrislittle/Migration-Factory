#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# HDD-OS-1: a Standard HDD OS disk, and Standard SSD for it during the move.
#
# Microsoft retires Standard HDD as the type of an OS disk on 8 September 2028,
# and then converts each one that is left to Standard SSD (disks-hdd-os-retirement,
# read 2026-10-25). Since 2026-10-23: a machine that moves anyway can change
# its OS disk type during the size move, which saves a separate change later.
# In 1.0.
#
# What these tests hold:
#   - the assessment reads the OS disk's type from the DISK resource (sku.name,
#     the field Microsoft's own list uses), names a Standard HDD OS disk, and
#     reads a disk it could not see as unknown - never a yes, never a no;
#   - the targets step offers "Standard SSD: OS disk" for every machine whose
#     OS disk is Standard HDD, on ANY size: Standard SSD needs no Premium SSD
#     size. Keep the disk types stays the default;
#   - the move reuses the OLD-SKU-1C change: while stopped, by the disk's
#     resource id, recorded first, safe to run again; and every put-back sets
#     the type back before the size;
#   - a Standard SSD disk that did not go back does not stop a put-back to an
#     old size that takes no Premium SSD: that size takes Standard SSD.
#
# MEASURED 2026-10-25 (one B2s Ubuntu machine, westus3, deleted): a running
# machine is refused a disk type change; on a deallocated one, six changes in a
# few minutes were all accepted. Microsoft's page still says twice a day, so
# the 24-hour rule of OLD-SKU-1C stays as it is.

BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_MachineList.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    . (Join-Path $PSScriptRoot '_RecordShape.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # OLD-VERSION-READERS-REMOVE-4: every disk made from a copy is read back and its key compared, so the fake Azure answers the read.
    Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }

    $script:subId = '00000000-0000-0000-0000-000000000000'
    $script:sub = "/subscriptions/$($script:subId)/resourceGroups/rg-app/providers"
    $script:vmId = "$($script:sub)/Microsoft.Compute/virtualMachines/vm1"
    $script:os = "$($script:sub)/Microsoft.Compute/disks/vm1-os"
    $script:d0 = "$($script:sub)/Microsoft.Compute/disks/vm1-data0"
    $script:retirementUrl = 'https://learn.microsoft.com/en-us/azure/virtual-machines/disks-hdd-os-retirement'

    # ---- the assessment: one inventory row, as the discovery query projects it
    function Global:HdRow([string]$Name = 'vm1') {
        [pscustomobject]@{
            id = "$($script:sub)/Microsoft.Compute/virtualMachines/$Name"; name = $Name; resourceGroup = 'rg-app'; location = 'centralus'; zones = $null
            sku = 'Standard_D2s_v4'; os = 'Linux'; gen = 'V2'; diskController = 'SCSI'; osName = 'ubuntu'; osVersionRunning = '22.04'
            imagePublisher = 'Canonical'; imageOffer = '0001-com-ubuntu-server-jammy'; imageSku = '22_04-lts-gen2'; imageId = ''
            communityGalleryImageId = ''; sharedGalleryImageId = ''; planPublisher = ''; planProduct = ''
            vmssId = ''; hibernationEnabled = $false; securityType = ''; dataDiskCount = 0; dataDisks = @()
            tags = $null; identityType = 'None'; identityPrincipalId = ''; adeOsDiskEnabled = ''; licenseType = ''
            osDiskManagedId = "$($script:sub)/Microsoft.Compute/disks/$Name-os"
        }
    }
    function Global:HdFacts([hashtable]$Types) {
        @{ SapSystemVms = @{}; AvdSessionHosts = @{}; AvdPoolTypes = @{}; ManagedPlatformGroups = @{}; SqlVms = @{}; DiskShares = @{}
           DiskTypes = $Types; ResourceGroupOwners = @{ "$($script:subId)/rg-app" = '' } }
    }
    function Global:HdRecord([hashtable]$Types) {
        InModuleScope VmMigrationFactory -Parameters @{ v = (HdRow); f = (HdFacts $Types) } {
            param($v, $f) Get-VmfAssessmentRecord -Vm $v -SkuEntry $null @f
        }
    }

    # ---- the move: a machine on Standard HDD, as the capture records it
    function Global:HdCapture([string]$OsSku = 'Standard_LRS') {
        [pscustomobject]@{ name = 'vm1'; size = 'Standard_D4_v2'; controller = ''; location = 'centralus'; osType = 'Linux'; zones = @()
            osDisk = [pscustomobject]@{ name = 'vm1-os'; skuName = $OsSku; managedDiskId = $script:os }
            dataDisks = @([pscustomobject]@{ name = 'vm1-data0'; lun = 0; skuName = 'Standard_LRS'; managedDiskId = $script:d0; caching = 'None'; sizeGB = 64 })
            nics = @([pscustomobject]@{ id = "$($script:sub)/Microsoft.Network/networkInterfaces/vm1-nic0"; primary = $true; acceleratedNetworking = $false })
            tags = @{} }
    }
    function Global:HdPlan([string]$Path = 'A', [string]$Upgrade = 'os-standard-ssd') {
        $policy = [ordered]@{ safetyCopy = 'pristine' }
        if ($Upgrade) { $policy.diskUpgrade = $Upgrade }
        [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vmId; path = $Path; wave = 'w1'
            assessment = [pscustomobject]@{ location = 'centralus'; os = 'Linux'; gen = 'V1'; sourceSize = 'Standard_D4_v2' }
            target = [pscustomobject]@{ size = 'Standard_D8d_v5'; controller = '' }; policy = [pscustomobject]$policy }
    }
    function Global:HdRun([string]$Path = 'A', [object[]]$Changes = @(), [string]$OsSku = 'Standard_LRS') {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-hd-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; cap = (HdCapture $OsSku); ch = $Changes; sub = $script:sub } {
            param($rp, $id, $cap, $ch, $sub)
            Initialize-VmfRun -RunPath $rp -RunId 'hd' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'hd' -VmId $id | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $doc | Add-Member -NotePropertyName captured -NotePropertyValue ([pscustomobject]@{ vmConfig = $cap }) -Force
            $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{
                    snapshotId = "$sub/Microsoft.Compute/snapshots/vm1"; cloneVmId = $null; locksAllowed = $true
                    pristineSnapshotId = "$sub/Microsoft.Compute/snapshots/vm1-pristine"; pristineSnapshotLocked = $true }) -Force
            if ($ch.Count) { $doc | Add-Member -NotePropertyName diskTypeChanges -NotePropertyValue @($ch) -Force }
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        $rp
    }
    function Global:HdCtx($rp, $plan) {
        Set-VmfTestAnDecision -RunPath $rp -VmId ([string]$plan.vmId) -PlanEntry $plan
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; plan = $plan } { param($rp, $plan) New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'hd' }
    }
    function Global:HdDoc($rp) { InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id } }
    function Global:HdLog($rp) { (Get-ChildItem $rp -Recurse -File | Where-Object Name -Match 'event' | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n" }
    function Global:HdAgo([double]$Hours) { (Get-Date).ToUniversalTime().AddHours(-$Hours).ToString('o') }
    function Global:HdMockDisks {
        $global:hd = @{ calls = [System.Collections.Generic.List[string]]::new()
            sku = @{ $script:os = 'Standard_LRS'; $script:d0 = 'Standard_LRS' } }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskSku { @{ SkuName = $global:hd.sku[$DiskId]; MaxShares = 1; ProvisioningState = 'Succeeded' } }
        Mock -ModuleName VmMigrationFactory Set-VmfManagedDiskSku {
            $global:hd.calls.Add("sku:$(($DiskId -split '/')[-1])=$SkuName"); $global:hd.sku[$DiskId] = $SkuName; $true
        }
    }
}
AfterAll {
    Remove-Item function:HdRow, function:HdFacts, function:HdRecord, function:HdCapture, function:HdPlan, function:HdRun, function:HdCtx,
        function:HdDoc, function:HdLog, function:HdAgo, function:HdMockDisks -ErrorAction SilentlyContinue
}

Describe 'HDD-OS-1: the assessment names a Standard HDD OS disk' {
    It 'the disk read gives each attached disk its type, from the disk resource - the field Microsoft''s own list uses' {
        InModuleScope VmMigrationFactory {
            Mock Invoke-VmfResourceGraphQuery {
                [pscustomobject]@{ data = @(
                    [pscustomobject]@{ id = '/subscriptions/S/resourceGroups/R/providers/Microsoft.Compute/disks/VM1-OS'; maxShares = $null; sku = 'Standard_LRS' },
                    [pscustomobject]@{ id = '/subscriptions/S/resourceGroups/R/providers/Microsoft.Compute/disks/data1'; maxShares = 2; sku = 'Premium_LRS' },
                    [pscustomobject]@{ id = '/subscriptions/S/resourceGroups/R/providers/Microsoft.Compute/disks/data2'; maxShares = $null; sku = '' }
                ) }
            }
            $r = Get-VmfDiskShareMap -Subscriptions @('S')
            $r.Verified | Should -BeTrue
            $r.Types['/subscriptions/s/resourcegroups/r/providers/microsoft.compute/disks/vm1-os'] | Should -Be 'Standard_LRS'
            $r.Types['/subscriptions/s/resourcegroups/r/providers/microsoft.compute/disks/data1'] | Should -Be 'Premium_LRS'
            $r.Types.ContainsKey('/subscriptions/s/resourcegroups/r/providers/microsoft.compute/disks/data2') | Should -BeFalse -Because 'a disk with no type read is unknown, not a type'
            $r.Disks['/subscriptions/s/resourcegroups/r/providers/microsoft.compute/disks/data1'] | Should -Be 2 -Because 'the shared disk read is unchanged'
            Should -Invoke Invoke-VmfResourceGraphQuery -ParameterFilter { $Body.query -match 'sku = tostring\(sku\.name\)' -and $Body.query -match '\| project id, maxShares = toint\(properties\.maxShares\), sku' }
        }
    }

    It 'a Standard HDD OS disk: the record says its type, and the machine gets the retirement warning' {
        $rec = HdRecord @{ "$($script:sub)/Microsoft.Compute/disks/vm1-os".ToLowerInvariant() = 'Standard_LRS' }
        $rec.osDiskType | Should -Be 'Standard_LRS'
        @($rec.warnings) | Should -Contain 'os-disk-standard-hdd'
        @($rec.blockers) | Should -Not -Contain 'os-disk-standard-hdd' -Because 'the machine can still move'
    }

    It 'a Standard SSD or Premium SSD OS disk: its type, and no warning' {
        foreach ($t in 'StandardSSD_LRS', 'Premium_LRS', 'StandardSSD_ZRS') {
            $rec = HdRecord @{ "$($script:sub)/Microsoft.Compute/disks/vm1-os".ToLowerInvariant() = $t }
            $rec.osDiskType | Should -Be $t
            @($rec.warnings) | Should -Not -Contain 'os-disk-standard-hdd' -Because $t
        }
    }

    It 'UNKNOWN IS NOT A YES AND NOT A NO: a disk the scan could not read, or no read at all, gives no type and no warning' {
        foreach ($types in @(@{}, $null)) {
            $rec = HdRecord $types
            $rec.PSObject.Properties['osDiskType'] | Should -Not -BeNullOrEmpty -Because 'the field is always there'
            $rec.osDiskType | Should -BeNullOrEmpty
            @($rec.warnings) | Should -Not -Contain 'os-disk-standard-hdd'
        }
    }

    It 'a scan carries the types through to the saved assessment, at version 6 (CLUSTER-DETECT-1; 5 was this item), and it matches its schema' {
        $doc = InModuleScope VmMigrationFactory -Parameters @{ row = (HdRow); osKey = "$($script:sub)/Microsoft.Compute/disks/vm1-os".ToLowerInvariant() } {
            param($row, $osKey)
            Mock Get-VmfFleetInventory { , @($row) }
            Mock Get-VmfSkuCatalog { , @() }
            Mock Get-VmfMachineImageNvme { @{ Nvme = $null; Note = $null } }
            # CLUSTER-DETECT-1: one read of the interfaces gives accelerated networking and the cluster hints.
            Mock Get-VmfNicFacts { @{ Accelerated = @{}; ClusterHints = @{} } }
            Mock Get-VmfSqlIaaSAgentVmIds { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfAvdSessionHostIds { @{ Ids = @{}; PoolTypes = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfSapSystemVmIds { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfManagedPlatformGroups { @{ Groups = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfSqlVirtualMachines { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfDiskShareMap { @{ Disks = @{ $osKey = 1 }; Types = @{ $osKey = 'Standard_LRS' }; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfResourceGroupOwners { @{ Groups = @{ '00000000-0000-0000-0000-000000000000/rg-app' = '' }; Verified = $true; Detail = 'mocked' } }
            $out = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-hda-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            try {
                Invoke-VmfAssessment -Scope @{ Subscriptions = @('00000000-0000-0000-0000-000000000000') } -OutPath $out | Out-Null
                Get-Content (Join-Path $out 'assessment.json') -Raw
            }
            finally { if (Test-Path $out) { Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue } }
        }
        # The WHOLE saved document, as written (SCAN-SCOPE-NULL-1).
        $doc | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'assessment.schema.json') | Should -BeTrue
        $a = $doc | ConvertFrom-Json -Depth 20
        $a.schemaVersion | Should -Be 17
        $a.vms[0].osDiskType | Should -Be 'Standard_LRS'
        @($a.vms[0].warnings) | Should -Contain 'os-disk-standard-hdd'
    }

    It 'the version is 8 (REBUILD-PATCH-MODE-1; 7 was REBUILD-ACCEPT-1; 6 was CLUSTER-DETECT-1; 5 was this item), and an older assessment is still read' {
        InModuleScope VmMigrationFactory { Get-VmfAssessmentSchemaVersion | Should -Be 17 }
        $s = Get-Content (Join-Path $script:repoRoot 'schemas' 'assessment.schema.json') -Raw | ConvertFrom-Json -Depth 30
        $s.properties.schemaVersion.const | Should -Be 17
        $s.properties.vms.items.properties.osDiskType | Should -Not -BeNullOrEmpty
    }

    It 'the warning says the date and what Azure does, links Microsoft''s page, and says what to do on the targets step' {
        $w = (Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'assessment-reasons.json') -Raw | ConvertFrom-Json).warnings.'os-disk-standard-hdd'
        $w | Should -Not -BeNullOrEmpty
        $w.title | Should -Match 'Standard HDD'
        $w.meaning | Should -Match '8 September 2028'
        $w.meaning | Should -Match 'Standard SSD'
        $w.whatToDo | Should -Match 'Standard SSD: OS disk'
        $w.docs.url | Should -Be $script:retirementUrl
        @($w.appliesTo) | Should -Be @('v5', 'v6', 'v7')
    }
}

Describe 'HDD-OS-1: the drift check watches Microsoft''s retirement page' {
    It 'the page is pinned, its text is kept, and the pin is the hash of that text' {
        $baseline = Get-Content (Join-Path $script:repoRoot 'docs' 'upstream-docs.json') -Raw | ConvertFrom-Json -Depth 10
        $folder = @($baseline.folders | Where-Object { $_.path -eq 'azure/virtual-machines' })[0]
        'disks-hdd-os-retirement' | Should -Match $folder.include
        $pin = @($folder.pages | Where-Object { $_.name -eq 'disks-hdd-os-retirement' })[0]
        $pin | Should -Not -BeNullOrEmpty
        $text = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'docs' $baseline.textFolder 'azure' 'virtual-machines' 'disks-hdd-os-retirement.md'))
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $hash = -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes(($text -replace "`r`n", "`n"))) | ForEach-Object { $_.ToString('x2') }) }
        finally { $sha.Dispose() }
        $pin.sha256 | Should -Be $hash
        $text | Should -Match 'September 8, 2028'
        @($folder.localDerivatives) -join ' ' | Should -Match 'HDD-OS-1'
    }
}

# HDD-OS-ASR-1: Microsoft's retirement page, Scope section (read 2026-11-03):
# "Standard HDD OS disks created by Azure Site Recovery will continue to be
# supported." The scan reads no fact that says Site Recovery made a disk: the
# Site Recovery extension is installed on the machine that Site Recovery
# REPLICATES (azure-to-azure-architecture, Replication process, step 1), and
# that machine's OS disk is the customer's own disk, which IS retired. The
# replica disk's -ASRReplica name and ASR-ReplicaDisk tag are Microsoft's
# defaults for the copy in the target region, and nothing measured says a
# machine after failover keeps them. So the warning stayed for every Standard HDD
# OS disk, and its words say the exception. HDD-OS-ASR-PROBE-1 (below) found the
# fact: the tag, not the name. The words keep the exception for a disk whose tag
# a person removed.
Describe 'HDD-OS-ASR-1: the warning says that Azure keeps support for an OS disk that Azure Site Recovery made' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        function script:AsrRecord([string]$OsDiskName = 'vm1-os') {
            $row = HdRow
            $row.osDiskManagedId = "$($script:sub)/Microsoft.Compute/disks/$OsDiskName"
            $facts = HdFacts @{ $row.osDiskManagedId.ToLowerInvariant() = 'Standard_LRS' }
            InModuleScope VmMigrationFactory -Parameters @{ v = $row; f = $facts } {
                param($v, $f) Get-VmfAssessmentRecord -Vm $v -SkuEntry $null @f
            }
        }
    }

    It 'the words of the warning say the Site Recovery exception from Microsoft''s page' {
        $w = (Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'assessment-reasons.json') -Raw | ConvertFrom-Json).warnings.'os-disk-standard-hdd'
        $w.meaning | Should -Match 'Azure Site Recovery made'
        $w.meaning | Should -Match 'does not apply'
    }

    It 'Microsoft''s pinned page still says the exception, so a change to it is a drift finding' {
        $text = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'docs' 'upstream-docs' 'azure' 'virtual-machines' 'disks-hdd-os-retirement.md'))
        $text | Should -Match ([regex]::Escape('Standard HDD OS disks created by Azure Site Recovery will continue to be supported.'))
    }

    It 'an OS disk named with the -ASRReplica suffix and no Site Recovery tag still gets the warning: the name does not mark the disk (HDD-OS-ASR-PROBE-1)' {
        $rec = AsrRecord -OsDiskName 'vm1-os-ASRReplica'
        @($rec.warnings) | Should -Contain 'os-disk-standard-hdd'
    }

    It 'the manual pages that name the retirement say the exception' {
        foreach ($rel in @('use/plan.md', 'use/read-an-assessment.md', 'reference/assessment-findings.md')) {
            $text = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'docs' 'manual' $rel))
            $text | Should -Match 'Azure Site Recovery made' -Because $rel
        }
    }
}

# HDD-OS-ASR-PROBE-1: the probe of 2026-11-09 (one Ubuntu 22.04 machine on a
# Standard HDD OS disk, Site Recovery to another region, a test failover and a
# failover, all deleted) read each OS disk. The disk that Site Recovery made
# carries the tag ASR-ReplicaDisk (the replica) or ASR-FODisk (the disk a test
# failover or a failover runs on). The NAME does not mark it: the failover disk
# has exactly the source disk's name. createOption Restore does not mark it
# either: any disk made from a snapshot has it. The fixtures below are the four
# records of the probe, with every name and value replaced (rule 13).
Describe 'HDD-OS-ASR-PROBE-1: a Standard HDD OS disk that Azure Site Recovery made gets no retirement warning' {
    BeforeAll {
        $script:asrSub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups'
        # The probe's four disks, as Resource Graph gives them. The source
        # machine's own tags (copied onto the failover disks) are an example.
        $script:asrRows = @(
            # 1. the replica, protected: the -ASRReplica name and the ASR-ReplicaDisk tag (a GUID).
            [pscustomobject]@{ id = "$($script:asrSub)/rg-target/providers/Microsoft.Compute/disks/src-os-ASRReplica"; maxShares = $null; sku = 'Standard_LRS'
                tags = [pscustomobject]@{ 'ASR-ReplicaDisk' = '00000000-0000-0000-0000-000000000000' } }
            # 2. the test failover disk: -ASRtest, ASR-FODisk, and the source machine's tags.
            [pscustomobject]@{ id = "$($script:asrSub)/rg-target/providers/Microsoft.Compute/disks/src-os-ASRtest"; maxShares = $null; sku = 'Standard_LRS'
                tags = [pscustomobject]@{ 'ASR-FODisk' = 'Created by Azure Site Recovery.'; app = 'web' } }
            # 3. the failover disk: EXACTLY the source disk's name, ASR-FODisk, and the source machine's tags.
            [pscustomobject]@{ id = "$($script:asrSub)/rg-target/providers/Microsoft.Compute/disks/src-os"; maxShares = $null; sku = 'Standard_LRS'
                tags = [pscustomobject]@{ app = 'web'; 'ASR-FODisk' = 'Created by Azure Site Recovery.' } }
            # 4. the source machine's own OS disk: the same name, the customer's tags, no Site Recovery tag. Azure retires it.
            [pscustomobject]@{ id = "$($script:asrSub)/rg-source/providers/Microsoft.Compute/disks/src-os"; maxShares = $null; sku = 'Standard_LRS'
                tags = [pscustomobject]@{ app = 'web' } }
            # Not from the probe: no tags at all, a tag VALUE that names Site
            # Recovery under another key, and a key in another case (Azure tag
            # names are case-insensitive: Microsoft's tag-resources page, Limitations).
            [pscustomobject]@{ id = "$($script:asrSub)/rg-app/providers/Microsoft.Compute/disks/plain-os"; maxShares = $null; sku = 'Standard_LRS'; tags = $null }
            [pscustomobject]@{ id = "$($script:asrSub)/rg-app/providers/Microsoft.Compute/disks/value-os"; maxShares = $null; sku = 'Standard_LRS'
                tags = [pscustomobject]@{ note = 'ASR-FODisk' } }
            [pscustomobject]@{ id = "$($script:asrSub)/rg-app/providers/Microsoft.Compute/disks/lower-os"; maxShares = $null; sku = 'Standard_LRS'
                tags = [pscustomobject]@{ 'asr-fodisk' = 'x' } }
        )
        function script:AsrMap {
            InModuleScope VmMigrationFactory -Parameters @{ rows = $script:asrRows } {
                param($rows)
                Mock Invoke-VmfResourceGraphQuery { [pscustomobject]@{ data = $rows } }
                Get-VmfDiskShareMap -Subscriptions @('S')
            }
        }
        function script:AsrProbeRecord([hashtable]$SiteRecovery, [switch]$NoSiteRecoveryArg) {
            $row = HdRow
            $key = $row.osDiskManagedId.ToLowerInvariant()
            $facts = HdFacts @{ $key = 'Standard_LRS' }
            if (-not $NoSiteRecoveryArg) { $facts.SiteRecoveryDisks = $SiteRecovery }
            InModuleScope VmMigrationFactory -Parameters @{ v = $row; f = $facts } {
                param($v, $f) Get-VmfAssessmentRecord -Vm $v -SkuEntry $null @f
            }
        }
    }

    It 'the disk read asks Resource Graph for each disk''s tags, in the same query' {
        InModuleScope VmMigrationFactory {
            Mock Invoke-VmfResourceGraphQuery { [pscustomobject]@{ data = @() } }
            Get-VmfDiskShareMap -Subscriptions @('S') | Out-Null
            Should -Invoke Invoke-VmfResourceGraphQuery -Times 1 -Exactly -ParameterFilter {
                $Body.query -match '\| project id, maxShares = toint\(properties\.maxShares\), sku = tostring\(sku\.name\), tags\s*$'
            }
        }
    }

    It 'the probe''s records: the replica, the test failover disk and the failover disk are marked; the source machine''s own disk is not' {
        $r = AsrMap
        $r.Verified | Should -BeTrue
        $sr = $r.SiteRecovery
        $sr | Should -Not -BeNullOrEmpty
        $sr.ContainsKey("$($script:asrSub)/rg-target/providers/Microsoft.Compute/disks/src-os-ASRReplica".ToLowerInvariant()) | Should -BeTrue -Because 'the ASR-ReplicaDisk tag'
        $sr.ContainsKey("$($script:asrSub)/rg-target/providers/Microsoft.Compute/disks/src-os-ASRtest".ToLowerInvariant()) | Should -BeTrue -Because 'the ASR-FODisk tag, test failover'
        $sr.ContainsKey("$($script:asrSub)/rg-target/providers/Microsoft.Compute/disks/src-os".ToLowerInvariant()) | Should -BeTrue -Because 'the ASR-FODisk tag, failover, with the source disk''s name'
        $sr.ContainsKey("$($script:asrSub)/rg-source/providers/Microsoft.Compute/disks/src-os".ToLowerInvariant()) | Should -BeFalse -Because 'the same name with no Site Recovery tag is the customer''s disk, and Azure retires it'
    }

    It 'only the tag NAME marks a disk: no tags, or a tag value that says ASR-FODisk, is not marked; a name in another case is' {
        $sr = (AsrMap).SiteRecovery
        $sr.ContainsKey("$($script:asrSub)/rg-app/providers/Microsoft.Compute/disks/plain-os".ToLowerInvariant()) | Should -BeFalse
        $sr.ContainsKey("$($script:asrSub)/rg-app/providers/Microsoft.Compute/disks/value-os".ToLowerInvariant()) | Should -BeFalse
        $sr.ContainsKey("$($script:asrSub)/rg-app/providers/Microsoft.Compute/disks/lower-os".ToLowerInvariant()) | Should -BeTrue
    }

    It 'the tags also read when they come as a hashtable' {
        InModuleScope VmMigrationFactory {
            Mock Invoke-VmfResourceGraphQuery { [pscustomobject]@{ data = @(
                [pscustomobject]@{ id = '/subscriptions/S/resourceGroups/R/providers/Microsoft.Compute/disks/A'; maxShares = $null; sku = 'Standard_LRS'; tags = @{ 'ASR-FODisk' = 'x' } }) } }
            (Get-VmfDiskShareMap -Subscriptions @('S')).SiteRecovery.ContainsKey('/subscriptions/s/resourcegroups/r/providers/microsoft.compute/disks/a') | Should -BeTrue
        }
    }

    It 'a read that fails gives no marked disk, and the scan refuses as before' {
        InModuleScope VmMigrationFactory {
            Mock Invoke-VmfResourceGraphQuery { throw 'HTTP 403' }
            $r = Get-VmfDiskShareMap -Subscriptions @('S')
            $r.Verified | Should -BeFalse
            $r.SiteRecovery.Count | Should -Be 0
        }
    }

    It 'THE CASE: a Standard HDD OS disk that Site Recovery made - the record still says Standard HDD, and no retirement warning' {
        $key = (HdRow).osDiskManagedId.ToLowerInvariant()
        $rec = AsrProbeRecord -SiteRecovery @{ $key = $true }
        $rec.osDiskType | Should -Be 'Standard_LRS' -Because 'the type is a fact, and the targets step still offers Standard SSD'
        @($rec.warnings) | Should -Not -Contain 'os-disk-standard-hdd'
    }

    It 'every other Standard HDD OS disk keeps the warning: no marked disk, another disk marked, or no read' {
        $other = "$($script:sub)/Microsoft.Compute/disks/vm1-data0".ToLowerInvariant()
        @((AsrProbeRecord -SiteRecovery @{}).warnings) | Should -Contain 'os-disk-standard-hdd'
        @((AsrProbeRecord -SiteRecovery @{ $other = $true }).warnings) | Should -Contain 'os-disk-standard-hdd' -Because 'a data disk Site Recovery made says nothing about the OS disk'
        @((AsrProbeRecord -SiteRecovery $null).warnings) | Should -Contain 'os-disk-standard-hdd' -Because 'not read is not a yes'
        @((AsrProbeRecord -NoSiteRecoveryArg).warnings) | Should -Contain 'os-disk-standard-hdd'
    }

    It 'a scan carries the mark from the disk read to the saved assessment, and the document matches its schema' {
        $doc = InModuleScope VmMigrationFactory -Parameters @{ row = (HdRow); osKey = (HdRow).osDiskManagedId.ToLowerInvariant() } {
            param($row, $osKey)
            Mock Get-VmfFleetInventory { , @($row) }
            Mock Get-VmfSkuCatalog { , @() }
            Mock Get-VmfMachineImageNvme { @{ Nvme = $null; Note = $null } }
            Mock Get-VmfNicFacts { @{ Accelerated = @{}; ClusterHints = @{} } }
            Mock Get-VmfSqlIaaSAgentVmIds { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfAvdSessionHostIds { @{ Ids = @{}; PoolTypes = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfSapSystemVmIds { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfManagedPlatformGroups { @{ Groups = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfSqlVirtualMachines { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfDiskShareMap { @{ Disks = @{ $osKey = 1 }; Types = @{ $osKey = 'Standard_LRS' }; SiteRecovery = @{ $osKey = $true }; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfResourceGroupOwners { @{ Groups = @{ '00000000-0000-0000-0000-000000000000/rg-app' = '' }; Verified = $true; Detail = 'mocked' } }
            $out = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-hdasr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            try {
                Invoke-VmfAssessment -Scope @{ Subscriptions = @('00000000-0000-0000-0000-000000000000') } -OutPath $out | Out-Null
                Get-Content (Join-Path $out 'assessment.json') -Raw
            }
            finally { if (Test-Path $out) { Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue } }
        }
        $doc | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'assessment.schema.json') | Should -BeTrue
        $a = $doc | ConvertFrom-Json -Depth 20
        $a.vms[0].osDiskType | Should -Be 'Standard_LRS'
        @($a.vms[0].warnings) | Should -Not -Contain 'os-disk-standard-hdd'
    }

    It 'the manual names the two tags where it names the exception' {
        foreach ($rel in @('use/read-an-assessment.md', 'use/plan.md')) {
            $text = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'docs' 'manual' $rel))
            $text | Should -Match 'ASR-FODisk' -Because $rel
            $text | Should -Match 'ASR-ReplicaDisk' -Because $rel
        }
    }
}

Describe 'HDD-OS-1: the targets step offers Standard SSD for the OS disk' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        function script:HdId([string]$Name) { "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$Name" }
        function script:HdVersion($rp, [string]$Name) {
            InModuleScope VmMigrationFactory -Parameters @{ p0 = $rp; n = $Name } {
                if (-not (Test-VmfStoreItem -RunPath $p0 -RelPath $n)) { return '' }
                Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $p0 -RelPath $n))
            }
        }
        function script:HdPrincipal {
            $claims = @(@{ typ = 'preferred_username'; val = 'person@example.com' }, @{ typ = 'roles'; val = 'Vmf.Operator' })
            $doc = @{ auth_typ = 'aad'; claims = $claims } | ConvertTo-Json -Depth 5
            ConvertFrom-VmfClientPrincipal -Header ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($doc)))
        }
        function script:HdSave($rp, [string]$Name, [string]$Option, [string]$Disks) {
            $one = [pscustomobject]@{ vmId = (HdId $Name); option = $Option }
            if ($Disks) { $one | Add-Member -NotePropertyName disks -NotePropertyValue $Disks }
            Invoke-VmfTestFacadeSetTargets -Principal (HdPrincipal) -StorePath $rp -Default 'current' -Choices @($one) `
                -AdviceVersion (HdVersion $rp 'target-advice.json') -ChoicesVersion (HdVersion $rp 'target-choices.json')
        }
        function script:HdEntry($mig, [string]$Name) {
            @((Get-Content (Join-Path $mig 'plan.json') -Raw | ConvertFrom-Json -Depth 30).entries) | Where-Object vmId -EQ (HdId $Name)
        }
        # Azure's figures for the sizes these machines are offered.
        function script:HdSku([string]$Name, [double]$Vcpus, [double]$MemoryGB, [string]$TempMb = '0', [string]$Gens = 'V1,V2') {
            [pscustomobject]@{ Name = $Name; Family = 'x'; ResourceType = 'virtualMachines'; Restrictions = @(); Capabilities = @(
                    [pscustomobject]@{ Name = 'vCPUs'; Value = [string]$Vcpus }
                    [pscustomobject]@{ Name = 'MemoryGB'; Value = [string]$MemoryGB }
                    [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = $TempMb }
                    [pscustomobject]@{ Name = 'HyperVGenerations'; Value = $Gens }
                    [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '4' }
                    [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '32' }
                    [pscustomobject]@{ Name = 'PremiumIO'; Value = $(if ($Name -match 's[a-z]*_v\d+$|^Standard_DS') { 'True' } else { 'False' }) }) }
        }
    }

    BeforeEach {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
            @((HdSku 'Standard_D4_v2' 8 28 '409600' 'V1'), (HdSku 'Standard_D2s_v4' 2 8 '0'),
              (HdSku 'Standard_D8ds_v5' 8 32 '307200'), (HdSku 'Standard_D8d_v5' 8 32 '307200'), (HdSku 'Standard_E8ds_v5' 8 64 '307200'),
              (HdSku 'Standard_D8lds_v5' 8 16 '307200'), (HdSku 'Standard_D2s_v5' 2 8 '0'), (HdSku 'Standard_D2ds_v5' 2 8 '76800'),
              (HdSku 'Standard_D2s_v6' 2 8 '0' 'V2'), (HdSku 'Standard_D2ds_v6' 2 8 '0' 'V2'), (HdSku 'Standard_D2s_v7' 2 8 '0' 'V2'),
              (HdSku 'Standard_D8ds_v6' 8 32 '0' 'V2'), (HdSku 'Standard_D8s_v6' 8 32 '0' 'V2'))
        }
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-hdt-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:mig = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-hdm-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        # The second area: Generation 1 on D4_v2. The first area: Generation 2
        # on D2s_v4. And a machine whose OS disk is already Standard SSD.
        $old = [ordered]@{ vmId = (HdId 'old-01'); name = 'old-01'; resourceGroup = 'rg-app'; location = 'centralus'; zones = @()
            classification = 'Blocked'; gen = 'V1'; os = 'Linux'; osVersion = '18.04-LTS'; sourceSize = 'Standard_D4_v2'
            sourceDiskArch = 'scsi-temp'; sourceTempDisks = 1; diskController = ''; dataDiskCount = 0; nicCount = 1; acceleratedNicCount = 0
            platformManaged = $false; iacManaged = $false; hibernationEnabled = $false; availabilitySetId = ''; identityType = 'None'
            tags = @{ app = 'old-01' }; blockers = @('gen1-requires-redeploy'); prepNeeded = @(); osDiskType = 'Standard_LRS' }
        $new = [ordered]@{} + $old
        $new.vmId = (HdId 'new-01'); $new.name = 'new-01'; $new.gen = 'V2'; $new.sourceSize = 'Standard_D2s_v4'; $new.sourceDiskArch = 'diskless'
        $new.sourceTempDisks = 0; $new.classification = 'ReadyAfterPrep'; $new.blockers = @(); $new.diskController = 'SCSI'; $new.tags = @{ app = 'new-01' }
        $ssd = [ordered]@{} + $new
        $ssd.vmId = (HdId 'ssd-01'); $ssd.name = 'ssd-01'; $ssd.osDiskType = 'StandardSSD_LRS'; $ssd.tags = @{ app = 'ssd-01' }
        $unread = [ordered]@{} + $new
        $unread.vmId = (HdId 'unread-01'); $unread.name = 'unread-01'; $unread.osDiskType = $null; $unread.tags = @{ app = 'unread-01' }
        $doc = [ordered]@{ schemaVersion = 17; runId = (Split-Path $script:rp -Leaf); generatedUtc = '2026-10-25T00:00:00Z'
            scope = @{ subscriptions = @() }; summary = @{}; vms = @($old, $new, $ssd, $unread) }
        InModuleScope VmMigrationFactory -Parameters @{ p0 = $script:rp; d = $doc } {
            Initialize-VmfRun -RunPath $p0 -RunId (Split-Path $p0 -Leaf) -Kind 'assessment' | Out-Null
            Write-VmfStoreJson -RunPath $p0 -RelPath 'assessment.json' -Document $d -Depth 24
        }
        Approve-VmfAssessment -RunPath $script:rp -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } | Out-Null
        New-VmfTargetAdvice -AssessmentPath (Join-Path $script:rp 'assessment.json') | Out-Null
    }
    AfterEach { foreach ($d in $script:rp, $script:mig) { if ($d -and (Test-Path $d)) { Remove-Item $d -Recurse -Force } } }

    It 'the target options carry each machine''s OS disk type, at version 21 (IDENTITY-LOSS-1 came after HDD-OS-1), and match their schema' {
        $raw = Get-Content (Join-Path $script:rp 'target-advice.json') -Raw
        $raw | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json') | Should -BeTrue
        $a = $raw | ConvertFrom-Json -Depth 30
        $a.schemaVersion | Should -Be 33
        (@($a.machines) | Where-Object name -EQ 'old-01').osDiskType | Should -Be 'Standard_LRS'
        (@($a.machines) | Where-Object name -EQ 'ssd-01').osDiskType | Should -Be 'StandardSSD_LRS'
        (@($a.machines) | Where-Object name -EQ 'unread-01').osDiskType | Should -BeNullOrEmpty
        InModuleScope VmMigrationFactory { Get-VmfTargetAdviceSchemaVersion | Should -Be 33 }
    }

    It 'THE CASE, first area: Standard SSD for the OS disk is saved, planned into the policy, and the plan says the type now' {
        HdSave $script:rp 'new-01' 'v5' 'os-standard-ssd' | Out-Null
        $saved = Get-Content (Join-Path $script:rp 'target-choices.json') -Raw
        $saved | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'target-choices.schema.json') | Should -BeTrue
        ($saved | ConvertFrom-Json -Depth 20).schemaVersion | Should -Be 9 -Because 'TARGETS-NO-LIST-1 made the targets v9'
        $c = @(($saved | ConvertFrom-Json -Depth 20).choices) | Where-Object vmId -EQ (HdId 'new-01')
        $c.disks | Should -Be 'os-standard-ssd'
        $c.source | Should -Be 'person' -Because 'the disk type is a person''s change'
        New-VmfPlan -AssessmentPath (Join-Path $script:rp 'assessment.json') -OutPath $script:mig -RequireTargets | Out-Null
        $entry = HdEntry $script:mig 'new-01'
        $entry.policy.diskUpgrade | Should -Be 'os-standard-ssd'
        $entry.assessment.osDiskType | Should -Be 'Standard_LRS'
        $entry.schemaVersion | Should -Be 37
        # ROLLBACK-CAPACITY-1 (v35): from data - D2s_v4 is not in a series with
        # restricted capacity.
        $entry.assessment.sourceCapacityRestricted | Should -BeFalse
        $entry.assessment.PSObject.Properties['sourceCapacityRestricted'] | Should -Not -BeNullOrEmpty
        ($entry | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json') | Should -BeTrue
    }

    It 'the second area too, and on a size that takes no Premium SSD - Standard SSD needs none' {
        $file = Join-Path $script:rp 'target-advice.json'
        $advice = Get-Content $file -Raw | ConvertFrom-Json -Depth 30
        $o = @(@($advice.machines | Where-Object name -EQ 'old-01')[0].options | Where-Object option -EQ 'v5')[0]
        $o.premiumDisks = $false
        foreach ($sc in @($o.sizeChoices)) { $sc.premiumDisks = $false }
        [IO.File]::WriteAllText($file, ($advice | ConvertTo-Json -Depth 30))
        HdSave $script:rp 'old-01' 'v5' 'os-standard-ssd' | Out-Null
        (@((Get-Content (Join-Path $script:rp 'target-choices.json') -Raw | ConvertFrom-Json -Depth 20).choices) | Where-Object vmId -EQ (HdId 'old-01')).disks |
            Should -Be 'os-standard-ssd'
        { HdSave $script:rp 'old-01' 'v5' 'os' } | Should -Throw '400*does not take Premium SSD*' -Because 'the Premium SSD rule is unchanged'
        # ROLLBACK-CAPACITY-1 (v35): D4_v2 is Dv2, a series whose capacity
        # growth Microsoft restricts - from data, on the plan entry.
        New-VmfPlan -AssessmentPath (Join-Path $script:rp 'assessment.json') -OutPath $script:mig -RequireTargets | Out-Null
        $old = HdEntry $script:mig 'old-01'
        $old.assessment.sourceCapacityRestricted | Should -BeTrue
        ($old | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json') | Should -BeTrue
    }

    It 'refused where the OS disk is not Standard HDD, or its type is not known - nothing to change, and unknown is not a yes' {
        { HdSave $script:rp 'ssd-01' 'v5' 'os-standard-ssd' } | Should -Throw "400*ssd-01*not Standard HDD*"
        { HdSave $script:rp 'unread-01' 'v5' 'os-standard-ssd' } | Should -Throw "400*did not read the type of the OS disk of 'unread-01'*"
        Test-Path (Join-Path $script:rp 'target-choices.json') | Should -BeFalse
    }

    It 'an unknown disk choice is still refused, and its words name the new choice' {
        { HdSave $script:rp 'new-01' 'v5' 'hdd' } | Should -Throw '400*unknown disk choice*os-standard-ssd*'
    }

    It 'the wave editor keeps Standard SSD when it moves a machine to a size that takes no Premium SSD' {
        HdSave $script:rp 'new-01' 'v6' 'os-standard-ssd' | Out-Null
        New-VmfPlan -AssessmentPath (Join-Path $script:rp 'assessment.json') -OutPath $script:mig -RequireTargets | Out-Null
        $file = Join-Path $script:mig 'target-advice.json'
        $advice = Get-Content $file -Raw | ConvertFrom-Json -Depth 30
        (@(@($advice.machines | Where-Object name -EQ 'new-01')[0].options | Where-Object option -EQ 'v5'))[0].premiumDisks = $false
        [IO.File]::WriteAllText($file, ($advice | ConvertTo-Json -Depth 30))
        $r = Set-VmfMachineTarget -RunPath $script:mig -VmId (HdId 'new-01') -Option v5 -ChangedBy 'operator@example.com' -Confirm:$false
        $r.Applied | Should -BeTrue
        $r.DiskChoiceCleared | Should -BeNullOrEmpty
        (HdEntry $script:mig 'new-01').policy.diskUpgrade | Should -Be 'os-standard-ssd'
        # ROLLBACK-CAPACITY-1: a target change keeps the assessment, so the fact stays.
        (HdEntry $script:mig 'new-01').assessment.PSObject.Properties['sourceCapacityRestricted'] | Should -Not -BeNullOrEmpty
    }

    It 'the version 21 plan entry says what it added, and an older plan is still read (24 since REBUILD-ACCEPT-1)' {
        $s = Get-Content (Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json') -Raw | ConvertFrom-Json -Depth 40
        $s.properties.schemaVersion.const | Should -Be 37
        $s.properties.schemaVersion.description | Should -Match '21 \(HDD-OS-1'
        @($s.properties.policy.properties.diskUpgrade.enum) | Should -Contain 'os-standard-ssd'
        InModuleScope VmMigrationFactory { Get-VmfPlanSchemaVersion | Should -Be 37 }
        (Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw) | Should -Match 'HDD-OS-1'
    }
}

Describe 'HDD-OS-1: which disk changes, to what' {
    It 'Standard SSD: the OS disk only, Standard HDD to Standard SSD - never a data disk' {
        $plan = InModuleScope VmMigrationFactory -Parameters @{ c = (HdCapture) } { param($c) @(Get-VmfDiskTypeUpgradePlan -Capture $c -Upgrade 'os-standard-ssd') }
        @($plan).Count | Should -Be 1
        $plan[0].name | Should -Be 'vm1-os'
        $plan[0].role | Should -Be 'os'
        $plan[0].from | Should -Be 'Standard_LRS'
        $plan[0].to | Should -Be 'StandardSSD_LRS'
    }

    It 'an OS disk that is not Standard HDD is left: there is nothing to retire' {
        foreach ($t in 'StandardSSD_LRS', 'StandardSSD_ZRS', 'Premium_LRS', 'PremiumV2_LRS', '') {
            InModuleScope VmMigrationFactory -Parameters @{ c = (HdCapture $t) } { param($c) @(Get-VmfDiskTypeUpgradePlan -Capture $c -Upgrade 'os-standard-ssd') } |
                Should -BeNullOrEmpty -Because "an OS disk on '$t'"
        }
    }

    It 'the choice reads from a plan entry of either shape' {
        InModuleScope VmMigrationFactory {
            Get-VmfDiskUpgradeValue -PlanEntry @{ policy = @{ diskUpgrade = 'os-standard-ssd' } } | Should -Be 'os-standard-ssd'
            Get-VmfDiskUpgradeValue -PlanEntry ([pscustomobject]@{ policy = [pscustomobject]@{ diskUpgrade = 'os-standard-ssd' } }) | Should -Be 'os-standard-ssd'
        }
    }
}

Describe 'HDD-OS-1: the checks before the machine is touched' {
    BeforeEach {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
            @([pscustomobject]@{ Name = 'Standard_D8d_v5'; Capabilities = @([pscustomobject]@{ Name = 'PremiumIO'; Value = 'False' }) })
        }
    }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

    It 'a target size that takes no Premium SSD goes on: Standard SSD needs no Premium SSD size' {
        $script:rp = HdRun
        InModuleScope VmMigrationFactory -Parameters @{ c = (HdCtx $script:rp (HdPlan)); cap = (HdCapture); pe = (HdPlan) } {
            param($c, $cap, $pe) Test-VmfDiskUpgradeReady -Context $c -PlanEntry $pe -Capture $cap
        } | Should -BeNullOrEmpty
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfSkuCatalog -Times 0 -Because 'the size is not asked about Premium SSD'
    }

    It 'the daily limit still applies: a recent change on the OS disk stops the move before it starts, with the time' {
        $script:rp = HdRun -Changes @([pscustomobject]@{ diskId = $script:os; from = 'Standard_LRS'; to = 'StandardSSD_LRS'; by = 'move'; utc = (HdAgo 2) })
        $r = InModuleScope VmMigrationFactory -Parameters @{ c = (HdCtx $script:rp (HdPlan)); cap = (HdCapture); pe = (HdPlan) } {
            param($c, $cap, $pe) Test-VmfDiskUpgradeReady -Context $c -PlanEntry $pe -Capture $cap
        }
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'diskTypeChangeLimit'
        $r.Detail | Should -Match "The disk 'vm1-os' had a type change in the last 24 hours"
    }
}

Describe 'HDD-OS-1: the change, while the machine is stopped' {
    BeforeEach {
        HdMockDisks
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { $true }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { $false }
        Mock -ModuleName VmMigrationFactory Get-VmfClaimForEntry { $null }
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { $global:hd.calls.Add('controller') }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { $global:hd.calls.Add('resize') }
    }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force }; Remove-Variable hd -Scope Global -ErrorAction SilentlyContinue }

    It 'Path A: after the resize, the OS disk only, recorded first - the Standard HDD data disk keeps its type' {
        $script:rp = HdRun
        InModuleScope VmMigrationFactory -Parameters @{ c = (HdCtx $script:rp (HdPlan 'A')) } { param($c) Invoke-VmfStepConverting -Context $c } | Out-Null
        @($global:hd.calls) | Should -Be @('resize', 'sku:vm1-os=StandardSSD_LRS')
        $rec = @((HdDoc $script:rp).diskTypeChanges)
        $rec.Count | Should -Be 1
        $rec[0].diskId | Should -Be $script:os
        $rec[0].from | Should -Be 'Standard_LRS'
        $rec[0].to | Should -Be 'StandardSSD_LRS'
        $rec[0].by | Should -Be 'move'
        HdLog $script:rp | Should -Match "The disk types are changed: 'vm1-os' Standard HDD to Standard SSD\."
    }

    It 'DISK-TYPE-WORDS-1: the Azure line of the change names the type it sets, and the summary uses Azure''s names' {
        # The run page names the type from this field. It said "Premium SSD"
        # for every change, also this one to Standard SSD (lab, 2026-10-26).
        $script:rp = HdRun
        InModuleScope VmMigrationFactory -Parameters @{ c = (HdCtx $script:rp (HdPlan 'A')) } { param($c) Invoke-VmfStepConverting -Context $c } | Out-Null
        $events = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) @(Read-VmfEvents -RunPath $rp) }
        $set = @($events | Where-Object { $_.step -eq 'azureops:diskType' -and $_.outcome -eq 'ok' })
        $set.Count | Should -Be 1
        $set[0].skuName | Should -Be 'StandardSSD_LRS'
        $read = @($events | Where-Object { $_.step -eq 'azureops:diskTypeRead' })
        $read.Count | Should -BeGreaterThan 0
        @($read | Where-Object { $_.PSObject.Properties['skuName'] }).Count | Should -Be 0 -Because 'a read sets no type'
        $sum = @($events | Where-Object { $_.step -eq 'diskType' -and $_.outcome -eq 'ok' })
        $sum[0].detail | Should -Be "The disk types are changed: 'vm1-os' Standard HDD to Standard SSD."
    }
    # REBUILD-REMOVE-ENGINE-1: the Path B case is gone with its step.
    It 'KILL-RESUME: killed after the record and before Azure changed it - changed, and recorded once' {
        $script:rp = HdRun 'A' -Changes @([pscustomobject]@{ diskId = $script:os; from = 'Standard_LRS'; to = 'StandardSSD_LRS'; by = 'move'; utc = (HdAgo 0.1) })
        InModuleScope VmMigrationFactory -Parameters @{ c = (HdCtx $script:rp (HdPlan 'A')) } { param($c) Invoke-VmfStepConverting -Context $c } | Out-Null
        @($global:hd.calls) | Should -Contain 'sku:vm1-os=StandardSSD_LRS'
        @((HdDoc $script:rp).diskTypeChanges).Count | Should -Be 1
    }

}

Describe 'HDD-OS-1: every put-back sets the type back before the size' {
    BeforeEach {
        HdMockDisks
        $global:hd.sku[$script:os] = 'StandardSSD_LRS'
        $script:moved = @([pscustomobject]@{ diskId = $script:os; from = 'Standard_LRS'; to = 'StandardSSD_LRS'; by = 'move'; utc = (HdAgo 1) })
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:hd.calls.Add('stop') }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { $global:hd.calls.Add('start') }
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { $null }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { $global:hd.calls.Add("size:$Size") }
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo { [pscustomobject]@{ name = 'vm1-os'; id = $script:os; resourceGroup = 'rg-app'; location = 'centralus'; skuName = 'StandardSSD_LRS'; sizeGB = 128; controller = '' } }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @([pscustomobject]@{ lun = 0; id = $script:d0; name = 'vm1-data0'; resourceGroup = 'rg-app'; skuName = 'Standard_LRS' }) }
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { 1 }
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks { @{ Applied = $true; Reason = '' } }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { $global:hd.calls.Add("newDisk:$SkuName"); "/disks/$DiskName" }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:hd.calls.Add('osdisk') }
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { [pscustomobject]@{ Name = 'vm1' } }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { $false }
        # D4_v2 takes no Premium SSD - and takes Standard SSD, as every size does.
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
            @([pscustomobject]@{ Name = 'Standard_D4_v2'; Capabilities = @([pscustomobject]@{ Name = 'PremiumIO'; Value = 'False' }) })
        }
    }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force }; Remove-Variable hd -Scope Global -ErrorAction SilentlyContinue }

    It 'Path A: the OS disk goes back to Standard HDD before the size, and its copy comes back on Standard HDD' {
        $script:rp = HdRun 'A' -Changes $script:moved
        InModuleScope VmMigrationFactory -Parameters @{ c = (HdCtx $script:rp (HdPlan 'A')) } { param($c) Invoke-VmfRollback -Context $c }
        $calls = @($global:hd.calls)
        [array]::IndexOf($calls, 'sku:vm1-os=Standard_LRS') | Should -BeLessThan ([array]::IndexOf($calls, 'size:Standard_D4_v2'))
        $calls | Should -Contain 'newDisk:Standard_LRS'
        $calls | Should -Not -Contain 'newDisk:StandardSSD_LRS'
    }

    It 'DISK-TYPE-WORDS-1: the Azure line of the set-back names the type it sets back, and the rollback line uses Azure''s names' {
        $script:rp = HdRun 'A' -Changes $script:moved
        InModuleScope VmMigrationFactory -Parameters @{ c = (HdCtx $script:rp (HdPlan 'A')) } { param($c) Invoke-VmfRollback -Context $c }
        $events = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) @(Read-VmfEvents -RunPath $rp) }
        $set = @($events | Where-Object { $_.step -eq 'azureops:rollback:diskType' -and $_.outcome -eq 'ok' })
        $set.Count | Should -Be 1
        $set[0].skuName | Should -Be 'Standard_LRS'
        HdLog $script:rp | Should -Match "The disk 'vm1-os' has its type Standard HDD again\."
    }
    It 'a Standard SSD disk Azure will not set back does not stop the put-back on a size that takes no Premium SSD - it is said, and the machine runs' {
        $script:rp = HdRun 'A' -Changes $script:moved
        Mock -ModuleName VmMigrationFactory Set-VmfManagedDiskSku { throw 'OperationNotAllowed' }
        InModuleScope VmMigrationFactory -Parameters @{ c = (HdCtx $script:rp (HdPlan 'A')) } { param($c) Invoke-VmfRollback -Context $c }
        $global:hd.calls | Should -Contain 'size:Standard_D4_v2'
        $global:hd.calls | Should -Contain 'start'
        HdLog $script:rp | Should -Match "The disk 'vm1-os' keeps the type Standard SSD\. Azure did not set Standard HDD back"
        HdLog $script:rp | Should -Match 'except the type of 1 disk'
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfSkuCatalog -Times 0 -Because 'no disk kept a Premium SSD type, so the size is not asked'
    }

    It 'the kept types are told to the size check: <why>' -TestCases @(
        @{ why = 'Standard SSD passes, unasked'; kept = @('StandardSSD_LRS'); asks = 0 }
        @{ why = 'a Premium SSD disk among them is asked about'; kept = @('StandardSSD_LRS', 'Premium_LRS'); asks = 1 }
        @{ why = 'a zone-redundant Premium SSD disk is asked about'; kept = @('Premium_ZRS'); asks = 1 }
        @{ why = 'a type not known is asked about - unknown is not a pass'; kept = @(''); asks = 1 }
        @{ why = 'no kept types told: asked, as before'; kept = $null; asks = 1 }
        @{ why = 'fewer kept types than disks not back: asked - a disk it was not told about is not known'; kept = @('StandardSSD_LRS'); notBack = 2; asks = 1 }
    ) {
        if (-not $notBack) { $notBack = if ($kept) { @($kept).Count } else { 1 } }
        $script:rp = HdRun 'A'
        $thrown = $null
        try {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId; k = $kept; nb = $notBack } {
                param($rp, $id, $k, $nb)
                $common = @{ RunPath = $rp; VmId = $id; Size = 'Standard_D4_v2'; Location = 'centralus'; Kind = 'rollback'; Then = 'x' }
                if ($null -eq $k) { Assert-VmfSizeTakesKeptDisks @common -NotBack 1; return }
                $list = [System.Collections.Generic.List[string]]::new()
                foreach ($t in $k) { $list.Add($t) }
                Assert-VmfSizeTakesKeptDisks @common -NotBack $nb -KeptTypes $list
            }
        }
        catch { $thrown = $_ }
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfSkuCatalog -Times $asks -Exactly
        if ($asks) { "$thrown" | Should -Match 'takes no Premium SSD' } else { $thrown | Should -BeNullOrEmpty }
    }

    It 'every caller of the set-back tells the size check which types were kept' {
        $files = @('Private/engine/StateMachine.ps1', 'Private/engine/DiskType.ps1') |
            ForEach-Object { Join-Path $script:repoRoot 'src' 'VmMigrationFactory' $_ }
        $calls = 0
        foreach ($f in $files) {
            $lines = @((Get-VmfCodeOnly -Path $f) -split "`r?`n")
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -notmatch 'Assert-VmfSizeTakesKeptDisks\s' -or $lines[$i] -match 'function\s+Assert-') { continue }
                # The whole call: each line that ends with a backtick goes on.
                $call = $lines[$i]
                $j = $i
                while ($lines[$j].TrimEnd().EndsWith('`') -and $j + 1 -lt $lines.Count) { $j++; $call += ' ' + $lines[$j].Trim() }
                $calls++
                $call | Should -Match '-KeptTypes \$' -Because "$f passes the kept types: $call"
            }
        }
        # REBUILD-REMOVE-ENGINE-1: the Path B rollback's call is gone with it.
        # REBUILD-REMOVE-RECOVER-1: Rebuild this machine was the fourth caller.
        $calls | Should -Be 2
    }
}

Describe 'HDD-OS-1: a resume, the report and the words' {
    It 'a resume names the Standard SSD choice it started with' {
        $started = InModuleScope VmMigrationFactory -Parameters @{ pe = (HdPlan 'A' 'os-standard-ssd') } { param($pe) Get-VmfStartedTarget -PlanEntry $pe }
        $r = InModuleScope VmMigrationFactory -Parameters @{ pe = (HdPlan 'A' ''); s = ([pscustomobject]$started) } { param($pe, $s) Resolve-VmfStartedTarget -PlanEntry $pe -Started $s }
        $r.Entry.policy.diskUpgrade | Should -Be 'os-standard-ssd'
        ($r.Changed -join ' ') | Should -Match 'where it started with Standard SSD for the OS disk'
    }

    It 'the report says the OS disk went from Standard HDD to Standard SSD' {
        $doc = [pscustomobject]@{ vmId = $script:vmId; state = 'MIGRATED'; history = @([pscustomobject]@{ state = 'MIGRATED' })
            captured = [pscustomobject]@{ vmConfig = (HdCapture) }
            diskTypeChanges = @([pscustomobject]@{ diskId = $script:os; from = 'Standard_LRS'; to = 'StandardSSD_LRS'; by = 'move'; utc = (HdAgo 1) }) }
        $null = Complete-VmfTestCapture $doc
        $rows = InModuleScope VmMigrationFactory -Parameters @{ d = $doc } {
            param($d)
            # FINISH-COUNT-1: the table asks where the machine runs, not the count.
            Mock Get-VmfMachineMoveOutcome { 'migrated' }
            @(Get-VmfIacChangeRows -StateDocs @($d))
        }
        $rows[0].disks | Should -Match 'vm1-os: Standard HDD to Standard SSD'
    }

    It 'the statement a person accepts says a move can change a disk to Standard SSD, on every page that shows it' {
        $statement = InModuleScope VmMigrationFactory { Get-VmfIacStatement }
        $sentence = 'A move can change the disk type to Standard SSD or Premium SSD.'
        $statement.Contains($sentence) | Should -BeTrue
        # IAC-NOTE-LIST-1: each page shows it as one item of the list.
        foreach ($page in 'wizard.html', 'migrations.html') {
            ((Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' $page))).Contains("'$sentence'") | Should -BeTrue -Because $page
        }
    }
}

Describe 'DISK-TYPE-WORDS-1: an Azure operation can carry fields for its lines' {
    BeforeEach { $script:rp = HdRun }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

    It 'the ok line carries the fields, and a field may not take the place of the step or the outcome' {
        $events = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id)
            $null = Invoke-VmfAzOperation -Name 'diskType' -RunPath $rp -VmId $id -Operation { $true } -EventData @{ skuName = 'Premium_LRS'; step = 'other'; outcome = 'fail' }
            @(Read-VmfEvents -RunPath $rp)
        }
        $line = @($events | Where-Object { $_.step -eq 'azureops:diskType' })
        $line.Count | Should -Be 1
        $line[0].outcome | Should -Be 'ok'
        $line[0].skuName | Should -Be 'Premium_LRS'
        $line[0].attempt | Should -Be 1
    }

    It 'the fail line carries them too, and its own fields stay' {
        $events = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id)
            try { $null = Invoke-VmfAzOperation -Name 'diskType' -RunPath $rp -VmId $id -Operation { throw 'OperationNotAllowed' } -EventData @{ skuName = 'StandardSSD_LRS'; attempt = 99 } } catch { }
            @(Read-VmfEvents -RunPath $rp)
        }
        $line = @($events | Where-Object { $_.step -eq 'azureops:diskType' })
        $line.Count | Should -Be 1
        $line[0].outcome | Should -Be 'fail'
        $line[0].skuName | Should -Be 'StandardSSD_LRS'
        $line[0].attempt | Should -Be 1 -Because 'the operation''s own count is not replaced'
    }

    It 'a retry line carries them, and so does the ok line after it' {
        $events = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id)
            $script:hdCalls = 0
            $null = Invoke-VmfAzOperation -Name 'diskType' -RunPath $rp -VmId $id -BaseDelayMs 1 -EventData @{ skuName = 'Premium_ZRS' } -Operation {
                $script:hdCalls++
                if ($script:hdCalls -lt 2) { throw '429 throttled' }
                $true
            }
            @(Read-VmfEvents -RunPath $rp)
        }
        $retry = @($events | Where-Object { $_.step -eq 'azureops:diskType' -and $_.outcome -eq 'retry' })
        $retry.Count | Should -Be 1
        $retry[0].skuName | Should -Be 'Premium_ZRS'
        @($events | Where-Object { $_.step -eq 'azureops:diskType' -and $_.outcome -eq 'ok' })[0].skuName | Should -Be 'Premium_ZRS'
    }
    It 'with no fields, the lines are as they were' {
        $events = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id)
            $null = Invoke-VmfAzOperation -Name 'diskTypeRead' -RunPath $rp -VmId $id -Operation { $true }
            @(Read-VmfEvents -RunPath $rp)
        }
        $line = @($events | Where-Object { $_.step -eq 'azureops:diskTypeRead' })
        $line[0].PSObject.Properties['skuName'] | Should -BeNullOrEmpty
    }
}
