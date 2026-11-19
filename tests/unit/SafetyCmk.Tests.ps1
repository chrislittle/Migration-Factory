#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SAFETY-CMK-1: a disk made from a safety copy keeps the key of the disk it
# replaces.
#
# Until this item no disk the product made from a copy - a put-back, a restore,
# a rebuild - named a disk encryption set or an encryption type, for any disk
# type, and no safety copy did either. Since 2026-10-10 the rule is that a
# machine can always go back to its safety copies, fully. A disk with a customer-managed key
# could come back on a platform key, and the product would report success.
# What Azure does with a copy that has a set and a request that names none is
# not documented; these tests pin that the product never leaves it to Azure.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    . (Join-Path $PSScriptRoot '_RecordShape.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # RESTORE-PERM-CHECK-1: the permission check of Restore this machine is not under test here (RestorePermCheck.Tests.ps1).
    Mock -ModuleName VmMigrationFactory Get-VmfRestorePermissionStop { $null }
    # CLUSTER-DETECT-1: the cluster check at Checking is not under test here;
    # ClusterDetect.Tests.ps1 and StateMachine.Tests.ps1 test it.
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }
    # PRECHECK-WORKLOAD-1: Checking reads the maxShares of each data disk; none is shared here.
    Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { 1 }
    # This file mocks Invoke-AzRestMethod and Start-Sleep inside some tests,
    # which turns the shared guard off for them in the WHOLE file. So every
    # test starts from a mock that refuses to reach Azure and does not wait.
    Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { throw "TEST-1: Invoke-AzRestMethod reached the real Azure ($Method $Path). Mock the azureops function." }
    Mock -ModuleName VmMigrationFactory Start-Sleep { }

    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute'
    $script:vmId = "$($script:sub)/virtualMachines/vm1"
    # Two disk encryption sets in ANOTHER resource group, as a customer's key
    # team often keeps them: one for a customer-managed key, one for double
    # encryption.
    $script:desCmk = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-keys/providers/Microsoft.Compute/diskEncryptionSets/des-contoso'
    $script:desDbl = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-keys/providers/Microsoft.Compute/diskEncryptionSets/des-contoso-double'
    $script:cmk = 'EncryptionAtRestWithCustomerKey'
    $script:dbl = 'EncryptionAtRestWithPlatformAndCustomerKeys'
    $script:pmk = 'EncryptionAtRestWithPlatformKey'

    # One machine in zone 1: an OS disk with a customer-managed key, a data
    # disk with a customer-managed key (LUN 0), one with double encryption
    # (LUN 1) and one on a platform key (LUN 2). Every first copy on record.
    function Global:CmkNewRun([switch]$NoRecord, [string]$State = 'CONVERTING') {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-cmk-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; sub = $script:sub; noRec = [bool]$NoRecord; st = $State
            dc = $script:desCmk; dd = $script:desDbl; cmk = $script:cmk; dbl = $script:dbl; pmk = $script:pmk } {
            param($rp, $id, $sub, $noRec, $st, $dc, $dd, $cmk, $dbl, $pmk)
            $enc = { param($t, $s) if ($noRec) { @{} } else { @{ encryptionType = $t; diskEncryptionSetId = $s } } }
            Initialize-VmfRun -RunPath $rp -RunId 'cmk' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'cmk' -VmId $id -Wave 'w1' | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $doc.state = $st
            $doc | Add-Member -NotePropertyName captured -NotePropertyValue ([pscustomobject]@{
                    vmConfig = [pscustomobject]@{ name = 'vm1'; size = 'Standard_D2s_v4'; controller = 'SCSI'; location = 'centralus'; osType = 'Linux'; zones = @('1')
                        osDisk = [pscustomobject](@{ name = 'vm1-osdisk'; skuName = 'Premium_LRS'; managedDiskId = "$sub/disks/vm1-osdisk" } + (& $enc $cmk $dc))
                        dataDisks = @(
                            [pscustomobject](@{ name = 'vm1-data0'; lun = 0; managedDiskId = "$sub/disks/vm1-data0"; caching = 'ReadOnly'; sizeGB = 64; skuName = 'Premium_LRS' } + (& $enc $cmk $dc))
                            [pscustomobject](@{ name = 'vm1-data1'; lun = 1; managedDiskId = "$sub/disks/vm1-data1"; caching = 'None'; sizeGB = 32; skuName = 'Premium_LRS' } + (& $enc $dbl $dd))
                            [pscustomobject](@{ name = 'vm1-data2'; lun = 2; managedDiskId = "$sub/disks/vm1-data2"; caching = 'None'; sizeGB = 16; skuName = 'StandardSSD_LRS' } + (& $enc $pmk $null)))
                        nics = @(); tags = @{} } }) -Force
            $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{ snapshotId = $null; cloneVmId = $null; locksAllowed = $true
                    pristineSnapshotId = "$sub/snapshots/vm1-pristine"; pristineSnapshotLocked = $true
                    pristineDataCopies = @(foreach ($l in 0, 1, 2) { [pscustomobject]@{ lun = $l; diskId = "$sub/disks/vm1-data$l"; snapshotId = "$sub/snapshots/vm1-pristine-d$l"; locked = $true } }) }) -Force
            $null = Complete-VmfTestCapture $doc
            # -NoRecord: no disk's key on record - not a record this version writes.
            if ($noRec) {
                foreach ($c in @($doc.captured.vmConfig, $doc.captured.original.vmConfig)) {
                    foreach ($d in @(@($c.osDisk) + @($c.dataDisks))) { $d.PSObject.Properties.Remove('encryptionType'); $d.PSObject.Properties.Remove('diskEncryptionSetId') }
                }
            }
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        $rp
    }
    function Global:CmkCtx($rp, [string]$Path = 'A') {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; path = $Path } {
            param($rp, $id, $path)
            $plan = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; path = $path; wave = 'w1'; assessment = [pscustomobject]@{ os = 'Linux'; location = 'centralus' }
                target = [pscustomobject]@{ size = 'Standard_D2s_v6'; controller = 'NVMe' }; policy = [pscustomobject]@{ safetyCopy = 'pristine' } }
            New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'cmk'
        }
    }
    function Global:CmkDoc($rp) { InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id } }
    function Global:CmkLog($rp) { (Get-ChildItem $rp -Recurse -File | Where-Object Name -Match 'event' | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n" }
    function Global:CmkDrop($rp) { if ($rp -and (Test-Path $rp)) { [System.IO.Directory]::Delete($rp, $true) } }
    # The encryption Azure has for each disk, by name; a disk made from a copy
    # of data<N> or the OS disk answers with the encryption of that disk,
    # unless a test changes it.
    function Global:CmkTruth {
        @{ 'vm1-osdisk' = @($script:cmk, $script:desCmk); 'vm1-data0' = @($script:cmk, $script:desCmk)
           'vm1-data1' = @($script:dbl, $script:desDbl); 'vm1-data2' = @($script:pmk, $null) }
    }
    function Global:CmkFacts($DiskId, [hashtable]$Truth = (CmkTruth)) {
        $name = ($DiskId -split '/')[-1]
        $key = @($Truth.Keys | Where-Object { $name -like "$_*" } | Sort-Object Length -Descending)[0]
        $t = if ($key) { $Truth[$key] } else { @($null, $null) }
        [pscustomobject]@{ id = $DiskId; skuName = 'Premium_LRS'; encryptionType = $t[0]; diskEncryptionSetId = $t[1]; zones = @('1'); maxShares = 1; completionPercent = 100 }
    }
}
AfterAll {
    Remove-Item function:CmkNewRun, function:CmkCtx, function:CmkDoc, function:CmkLog, function:CmkDrop, function:CmkTruth, function:CmkFacts -ErrorAction SilentlyContinue
}

Describe 'SAFETY-CMK-1: the Azure boundary' {
    BeforeEach { $global:cmkRec = [System.Collections.Generic.List[object]]::new() }
    AfterEach { Remove-Variable cmkRec -Scope Global -ErrorAction SilentlyContinue }

    It 'reads a disk''s encryption type and disk encryption set by its id; one Azure did not return is null, never "platform key"' {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod {
            $body = if ($Path -match 'withset') { @{ id = 'd'; sku = @{ name = 'Premium_LRS' }; properties = @{ encryption = @{ type = 'EncryptionAtRestWithCustomerKey'; diskEncryptionSetId = '/des/x' } } } }
                    else { @{ id = 'd'; sku = @{ name = 'Premium_LRS' }; properties = @{ diskSizeGB = 8 } } }
            [pscustomobject]@{ StatusCode = 200; Content = ($body | ConvertTo-Json -Depth 6) }
        }
        $f = InModuleScope VmMigrationFactory -Parameters @{ id = "$($script:sub)/disks/withset" } { param($id) Get-VmfManagedDiskFacts -DiskId $id }
        $f.encryptionType | Should -Be 'EncryptionAtRestWithCustomerKey'
        $f.diskEncryptionSetId | Should -Be '/des/x'
        $n = InModuleScope VmMigrationFactory -Parameters @{ id = "$($script:sub)/disks/none" } { param($id) Get-VmfManagedDiskFacts -DiskId $id }
        $n.encryptionType | Should -BeNullOrEmpty
        $n.diskEncryptionSetId | Should -BeNullOrEmpty
    }

    It 'a disk is made from a copy with the encryption type and disk encryption set given - and with neither when none is on record' {
        Mock -ModuleName VmMigrationFactory Get-AzDisk { $null }
        Mock -ModuleName VmMigrationFactory New-AzDiskConfig { $global:cmkRec.Add($PesterBoundParameters); [pscustomobject]@{} }
        Mock -ModuleName VmMigrationFactory New-AzDisk { [pscustomobject]@{ Id = "/disks/$DiskName" } }
        InModuleScope VmMigrationFactory -Parameters @{ des = $script:desCmk } {
            param($des)
            New-VmfDiskFromSnapshot -ResourceGroupName 'rg' -DiskName 'a' -SnapshotId '/s' -Location 'centralus' -SkuName 'Premium_LRS' -EncryptionType 'EncryptionAtRestWithCustomerKey' -DiskEncryptionSetId $des | Out-Null
            New-VmfDiskFromSnapshot -ResourceGroupName 'rg' -DiskName 'b' -SnapshotId '/s' -Location 'centralus' -SkuName 'Premium_LRS' -EncryptionType 'EncryptionAtRestWithPlatformKey' | Out-Null
            New-VmfDiskFromSnapshot -ResourceGroupName 'rg' -DiskName 'c' -SnapshotId '/s' -Location 'centralus' -SkuName 'Premium_LRS' | Out-Null
        }
        $global:cmkRec[0].EncryptionType | Should -Be 'EncryptionAtRestWithCustomerKey'
        $global:cmkRec[0].DiskEncryptionSetId | Should -Be $script:desCmk
        $global:cmkRec[1].EncryptionType | Should -Be 'EncryptionAtRestWithPlatformKey' -Because 'a platform key is said too: the request is exact'
        $global:cmkRec[1].ContainsKey('DiskEncryptionSetId') | Should -BeFalse
        $global:cmkRec[2].ContainsKey('EncryptionType') | Should -BeFalse -Because 'the azureops call sends only what it is given; its callers refuse a disk with no key on record'
    }

    It 'STOP AND RESUME: a disk of that name on another key is refused; the same key, the set in another letter case, is the same disk' {
        $global:cmkHave = [pscustomobject]@{ Id = '/disks/a'; CreationData = [pscustomobject]@{ SourceResourceId = '/s' }; Zones = @()
            Encryption = [pscustomobject]@{ Type = 'EncryptionAtRestWithPlatformKey'; DiskEncryptionSetId = $null } }
        Mock -ModuleName VmMigrationFactory Get-AzDisk { $global:cmkHave }
        Mock -ModuleName VmMigrationFactory New-AzDisk { throw 'must not make a second disk' }
        { InModuleScope VmMigrationFactory -Parameters @{ des = $script:desCmk } {
                param($des) New-VmfDiskFromSnapshot -ResourceGroupName 'rg' -DiskName 'a' -SnapshotId '/s' -Location 'centralus' -EncryptionType 'EncryptionAtRestWithCustomerKey' -DiskEncryptionSetId $des } } |
            Should -Throw "*Disk 'a' exists, and its encryption is EncryptionAtRestWithPlatformKey with no disk encryption set, not EncryptionAtRestWithCustomerKey with the disk encryption set '$($script:desCmk)'*"
        $global:cmkHave.Encryption = [pscustomobject]@{ Type = 'EncryptionAtRestWithCustomerKey'; DiskEncryptionSetId = $script:desCmk.ToUpperInvariant() }
        InModuleScope VmMigrationFactory -Parameters @{ des = $script:desCmk } {
            param($des) New-VmfDiskFromSnapshot -ResourceGroupName 'rg' -DiskName 'a' -SnapshotId '/s' -Location 'centralus' -EncryptionType 'EncryptionAtRestWithCustomerKey' -DiskEncryptionSetId $des } | Should -Be '/disks/a'
        Remove-Variable cmkHave -Scope Global
    }

    It 'the safety copy asks for the disk''s own set, and a copy Azure made on another key is never used' {
        Mock -ModuleName VmMigrationFactory Get-AzSnapshot { $null }
        Mock -ModuleName VmMigrationFactory New-AzSnapshotConfig { $global:cmkRec.Add($PesterBoundParameters); [pscustomobject]@{ Tags = $null } }
        $global:cmkGot = [pscustomobject]@{ Type = 'EncryptionAtRestWithCustomerKey'; DiskEncryptionSetId = $script:desCmk }
        Mock -ModuleName VmMigrationFactory New-AzSnapshot { [pscustomobject]@{ Id = "/snapshots/$SnapshotName"; Tags = $null; Encryption = $global:cmkGot } }
        InModuleScope VmMigrationFactory -Parameters @{ des = $script:desCmk } {
            param($des) New-VmfOsDiskSnapshot -ResourceGroupName 'rg' -SnapshotName 's1' -OsDiskId '/disks/os' -Location 'centralus' -EncryptionType 'EncryptionAtRestWithCustomerKey' -DiskEncryptionSetId $des } | Should -Be '/snapshots/s1'
        $global:cmkRec[0].EncryptionType | Should -Be 'EncryptionAtRestWithCustomerKey'
        $global:cmkRec[0].DiskEncryptionSetId | Should -Be $script:desCmk
        $global:cmkRec[0].Incremental | Should -BeTrue -Because 'the copy is still incremental (SAFETY-2)'
        $global:cmkGot = [pscustomobject]@{ Type = 'EncryptionAtRestWithPlatformKey'; DiskEncryptionSetId = $null }
        { InModuleScope VmMigrationFactory -Parameters @{ des = $script:desCmk } {
                param($des) New-VmfOsDiskSnapshot -ResourceGroupName 'rg' -SnapshotName 's2' -OsDiskId '/disks/os' -Location 'centralus' -EncryptionType 'EncryptionAtRestWithCustomerKey' -DiskEncryptionSetId $des } } |
            Should -Throw "*Azure made the safety copy 's2', but its encryption is EncryptionAtRestWithPlatformKey with no disk encryption set*The product does not use it*"
        Remove-Variable cmkGot -Scope Global
    }

    It 'STOP AND RESUME: a copy of that name on another key is refused, never used as the way back' {
        Mock -ModuleName VmMigrationFactory Get-AzSnapshot { [pscustomobject]@{ Id = '/snapshots/s1'; Encryption = [pscustomobject]@{ Type = 'EncryptionAtRestWithPlatformKey'; DiskEncryptionSetId = $null } } }
        { InModuleScope VmMigrationFactory -Parameters @{ des = $script:desCmk } {
                param($des) New-VmfOsDiskSnapshot -ResourceGroupName 'rg' -SnapshotName 's1' -OsDiskId '/disks/os' -Location 'centralus' -EncryptionType 'EncryptionAtRestWithCustomerKey' -DiskEncryptionSetId $des } } |
            Should -Throw "*The safety copy 's1' exists, and its encryption is EncryptionAtRestWithPlatformKey*"
        # A copy taken with no record (a v20 capture) is returned as before.
        InModuleScope VmMigrationFactory { New-VmfOsDiskSnapshot -ResourceGroupName 'rg' -SnapshotName 's1' -OsDiskId '/disks/os' -Location 'centralus' } | Should -Be '/snapshots/s1'
    }

    It 'the instant access copy asks for the set in its body, and one that landed on another key throws' {
        $global:cmkLanded = @{ type = 'EncryptionAtRestWithCustomerKey'; diskEncryptionSetId = $script:desCmk }
        $global:cmkGets = 0
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod {
            $global:cmkRec.Add([pscustomobject]@{ Method = $Method; Payload = $Payload })
            if ($Method -eq 'PUT') { return [pscustomobject]@{ StatusCode = 202; Content = '' } }
            $global:cmkGets++
            if ($global:cmkGets -eq 1) { return [pscustomobject]@{ StatusCode = 404; Content = '' } }
            [pscustomobject]@{ StatusCode = 200; Content = (@{ id = 'x'; properties = @{ provisioningState = 'Succeeded'; encryption = $global:cmkLanded } } | ConvertTo-Json -Depth 5) }
        }
        InModuleScope VmMigrationFactory -Parameters @{ d = "$($script:sub)/disks/vm1-data0"; des = $script:desCmk } {
            param($d, $des) New-VmfInstantAccessSnapshot -ResourceGroupName 'rg-app' -SnapshotName 'c1' -DiskId $d -Location 'centralus' -PollSeconds 0 -EncryptionType 'EncryptionAtRestWithCustomerKey' -DiskEncryptionSetId $des } | Should -Match '/snapshots/c1$'
        $body = (@($global:cmkRec | Where-Object Method -EQ 'PUT')[0]).Payload | ConvertFrom-Json
        $body.properties.encryption.type | Should -Be 'EncryptionAtRestWithCustomerKey'
        $body.properties.encryption.diskEncryptionSetId | Should -Be $script:desCmk
        $global:cmkGets = 0
        $global:cmkLanded = @{ type = 'EncryptionAtRestWithPlatformKey' }
        { InModuleScope VmMigrationFactory -Parameters @{ d = "$($script:sub)/disks/vm1-data0"; des = $script:desCmk } {
                param($d, $des) New-VmfInstantAccessSnapshot -ResourceGroupName 'rg-app' -SnapshotName 'c2' -DiskId $d -Location 'centralus' -PollSeconds 0 -EncryptionType 'EncryptionAtRestWithCustomerKey' -DiskEncryptionSetId $des } } |
            Should -Throw "*Azure made the safety copy 'c2', but its encryption is EncryptionAtRestWithPlatformKey with no disk encryption set*"
        Remove-Variable cmkLanded, cmkGets -Scope Global
    }
}

Describe 'SAFETY-CMK-1: what counts as the same key' {
    It 'the same type and set match, the set compared as a resource id - without regard to letter case' {
        InModuleScope VmMigrationFactory -Parameters @{ des = $script:desCmk } {
            param($des)
            Get-VmfEncryptionDifference -WantType 'EncryptionAtRestWithCustomerKey' -WantSetId $des -GotType 'EncryptionAtRestWithCustomerKey' -GotSetId $des.ToUpperInvariant() | Should -BeNullOrEmpty
            Get-VmfEncryptionDifference -WantType 'EncryptionAtRestWithPlatformKey' -WantSetId '' -GotType 'EncryptionAtRestWithPlatformKey' -GotSetId $null | Should -BeNullOrEmpty
        }
    }
    It 'a type Azure did not return is a difference - never read as a platform key' {
        InModuleScope VmMigrationFactory {
            Get-VmfEncryptionDifference -WantType 'EncryptionAtRestWithPlatformKey' -GotType '' | Should -Be 'its encryption is no encryption type, not EncryptionAtRestWithPlatformKey with no disk encryption set'
        }
    }
    It 'DOUBLE ENCRYPTION is not a customer-managed key: the same set with the other type is a difference' {
        InModuleScope VmMigrationFactory -Parameters @{ des = $script:desCmk } {
            param($des)
            Get-VmfEncryptionDifference -WantType 'EncryptionAtRestWithPlatformAndCustomerKeys' -WantSetId $des -GotType 'EncryptionAtRestWithCustomerKey' -GotSetId $des |
                Should -Match "^its encryption is EncryptionAtRestWithCustomerKey with the disk encryption set '.*', not EncryptionAtRestWithPlatformAndCustomerKeys"
        }
    }
    It 'another set is a difference' {
        InModuleScope VmMigrationFactory -Parameters @{ a = $script:desCmk; b = $script:desDbl } {
            param($a, $b) Get-VmfEncryptionDifference -WantType 'EncryptionAtRestWithCustomerKey' -WantSetId $a -GotType 'EncryptionAtRestWithCustomerKey' -GotSetId $b | Should -Not -BeNullOrEmpty
        }
    }
    It 'a reading that cannot be given back exactly says why; the three documented types with the right set pass' {
        InModuleScope VmMigrationFactory {
            Get-VmfDiskEncryptionProblem -Type '' | Should -Be 'Azure returned no encryption type for it'
            Get-VmfDiskEncryptionProblem -Type 'EncryptionAtRestWithAFutureKind' -SetId '/des/x' | Should -Be 'its encryption type is EncryptionAtRestWithAFutureKind, which the product does not know'
            Get-VmfDiskEncryptionProblem -Type 'EncryptionAtRestWithCustomerKey' | Should -Match 'returned no disk encryption set'
            Get-VmfDiskEncryptionProblem -Type 'EncryptionAtRestWithPlatformAndCustomerKeys' | Should -Match 'returned no disk encryption set'
            Get-VmfDiskEncryptionProblem -Type 'EncryptionAtRestWithPlatformKey' -SetId '/des/x' | Should -Match "also returned the disk encryption set '/des/x'"
            Get-VmfDiskEncryptionProblem -Type 'EncryptionAtRestWithPlatformKey' | Should -BeNullOrEmpty
            Get-VmfDiskEncryptionProblem -Type 'EncryptionAtRestWithCustomerKey' -SetId '/des/x' | Should -BeNullOrEmpty
            Get-VmfDiskEncryptionProblem -Type 'EncryptionAtRestWithPlatformAndCustomerKeys' -SetId '/des/x' | Should -BeNullOrEmpty
        }
    }
}

Describe 'SAFETY-CMK-1: PRECHECK records the key of every disk' {
    BeforeAll {
        function Global:CmkPrecheckMocks {
            $writes = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops') -Filter '*.ps1' |
                ForEach-Object { Select-String -Path $_.FullName -Pattern '^function\s+([\w-]+)' | ForEach-Object { $_.Matches[0].Groups[1].Value } } |
                Where-Object { $_ -match '^(Stop|Start|Set|New|Remove|Lock|Unlock|Request)-' -or $_ -eq 'Invoke-VmfRunCommand' })
            foreach ($n in $writes) { Mock -ModuleName VmMigrationFactory -CommandName $n -MockWith { throw 'nothing in Azure may change' } }
            $global:cmkScopes = [System.Collections.Generic.List[string]]::new()
            Mock -ModuleName VmMigrationFactory Test-VmfAdeExtension { $false }
            Mock -ModuleName VmMigrationFactory Get-VmfVmResourceLocks { , @() }
            Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { $global:cmkScopes.Add($Scope); @([pscustomobject]@{ actions = @('*'); notActions = @() }) }
            Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/deallocated' }
            Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions { @() }
            Mock -ModuleName VmMigrationFactory Get-AzNetworkInterface { [pscustomobject]@{ EnableAcceleratedNetworking = $true } }
            Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @() }
            Mock -ModuleName VmMigrationFactory Get-VmfNetworkInterfaceById { [pscustomobject]@{ Id = 'nic0' } }
            $global:cmkLive = [pscustomobject]@{
                Id = $script:vmId; Name = 'vm1'; ResourceGroupName = 'rg-app'; Location = 'centralus'
                HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_D2s_v4' }
                StorageProfile = [pscustomobject]@{ DiskControllerType = 'SCSI'
                    OsDisk = [pscustomobject]@{ OsType = 'Linux'; Name = 'vm1-osdisk'; DeleteOption = 'Delete'; ManagedDisk = [pscustomobject]@{ Id = "$($script:sub)/disks/vm1-osdisk"; StorageAccountType = 'Premium_LRS' } }
                    DataDisks = @([pscustomobject]@{ Lun = 1; Name = 'vm1-data1'; Caching = 'None'; DiskSizeGB = 32; DeleteOption = 'Detach'
                            ManagedDisk = [pscustomobject]@{ Id = "$($script:sub)/disks/vm1-data1"; StorageAccountType = 'Premium_LRS' } })
                    ImageReference = $null }
                NetworkProfile = [pscustomobject]@{ NetworkInterfaces = @([pscustomobject]@{ Id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Network/networkInterfaces/nic0'; Primary = $true }) }
                Zones = @('1'); Tags = @{}; LicenseType = $null; AvailabilitySetReference = $null; ProximityPlacementGroup = $null
                Priority = $null; Identity = $null; AdditionalCapabilities = $null; DiagnosticsProfile = $null; SecurityProfile = $null
            }
            Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { $global:cmkLive }
        }
        function Global:CmkRunPrecheck($rp) {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } {
                param($rp, $id)
                Initialize-VmfRun -RunPath $rp -RunId 'cmkp' | Out-Null
                $plan = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; wave = 'w1'; ring = 'lab'; path = 'A'
                    assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'; sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'
                        platformManaged = $false; location = 'centralus'; dataDiskCount = 1 }
                    target = [pscustomobject]@{ size = 'Standard_D2s_v6'; diskArch = 'diskless'; controller = 'NVMe'; zone = '1' }
                    policy = [pscustomobject]@{ onDDataFound = 'proceed'; targetGeneration = 'v6'; acceleratedNetworking = 'preserve' } }
                $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'cmkp'
                New-VmfStateDoc -RunPath $rp -RunId 'cmkp' -VmId $ctx.VmId | Out-Null
                Invoke-VmfStepPrecheck -Context $ctx
            }
        }
    }
    AfterAll { Remove-Item function:CmkPrecheckMocks, function:CmkRunPrecheck -ErrorAction SilentlyContinue }
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-cmkp-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:rp | Out-Null
        $global:cmkReads = [System.Collections.Generic.List[string]]::new()
        $global:cmkTruth = CmkTruth
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { $global:cmkReads.Add(($DiskId -split '/')[-1]); CmkFacts $DiskId $global:cmkTruth }
        # The capture as Get-VmfVmCapture writes it: ordered hashtables.
        $global:cmkCapture = [ordered]@{ name = 'vm1'
            osDisk = [ordered]@{ name = 'vm1-osdisk'; managedDiskId = "$($script:sub)/disks/vm1-osdisk"; skuName = 'Premium_LRS' }
            dataDisks = @(
                [ordered]@{ name = 'vm1-data0'; lun = 0; managedDiskId = "$($script:sub)/disks/vm1-data0"; skuName = 'Premium_LRS' }
                [ordered]@{ name = 'vm1-data1'; lun = 1; managedDiskId = "$($script:sub)/disks/vm1-data1"; skuName = 'Premium_LRS' }
                [ordered]@{ name = 'vm1-data2'; lun = 2; managedDiskId = "$($script:sub)/disks/vm1-data2"; skuName = 'StandardSSD_LRS' }) }
    }
    AfterEach { CmkDrop $script:rp; Remove-Variable cmkReads, cmkTruth, cmkCapture -Scope Global -ErrorAction SilentlyContinue }

    It 'reads the OS disk and every data disk by its id, and records each type and set - double encryption as its own type' {
        $r = InModuleScope VmMigrationFactory -Parameters @{ c = [pscustomobject]@{ RunPath = $script:rp; VmId = $script:vmId }; cap = $global:cmkCapture } {
            param($c, $cap) Add-VmfDiskEncryptionFacts -Context $c -Capture $cap
        }
        $r | Should -BeNullOrEmpty
        @($global:cmkReads) | Should -Be @('vm1-osdisk', 'vm1-data0', 'vm1-data1', 'vm1-data2')
        $global:cmkCapture.osDisk.encryptionType | Should -Be $script:cmk
        $global:cmkCapture.osDisk.diskEncryptionSetId | Should -Be $script:desCmk
        $global:cmkCapture.dataDisks[1].encryptionType | Should -Be $script:dbl
        $global:cmkCapture.dataDisks[1].diskEncryptionSetId | Should -Be $script:desDbl
        $global:cmkCapture.dataDisks[2].encryptionType | Should -Be $script:pmk
        $global:cmkCapture.dataDisks[2].diskEncryptionSetId | Should -BeNullOrEmpty
    }

    It 'a disk Azure did not answer for, or answered in a way this tool does not know, is refused UNTOUCHED - each disk named, with why' {
        $global:cmkTruth['vm1-data0'] = @($script:cmk, $null)
        $global:cmkTruth['vm1-data2'] = @('EncryptionAtRestWithAFutureKind', $script:desCmk)
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { if ($DiskId -match 'data1') { throw 'AuthorizationFailed' }; CmkFacts $DiskId $global:cmkTruth }
        $r = InModuleScope VmMigrationFactory -Parameters @{ c = [pscustomobject]@{ RunPath = $script:rp; VmId = $script:vmId }; cap = $global:cmkCapture } {
            param($c, $cap) Add-VmfDiskEncryptionFacts -Context $c -Capture $cap
        }
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'diskEncryptionNotKnown'
        $r.MachineState | Should -Be 'untouched'
        $r.Detail | Should -Match "the data disk 'vm1-data0' on LUN 0: its encryption type is EncryptionAtRestWithCustomerKey, and Azure returned no disk encryption set for it"
        $r.Detail | Should -Match "the data disk 'vm1-data1' on LUN 1: Azure did not answer the read \(.*AuthorizationFailed"
        $r.Detail | Should -Match "the data disk 'vm1-data2' on LUN 2: its encryption type is EncryptionAtRestWithAFutureKind, which the product does not know"
        $r.Detail | Should -Match 'Nothing on the machine changed\.$'
        $r.Detail | Should -Not -Match 'vm1-osdisk' -Because 'the OS disk was read exactly'
    }

    It 'a disk with no managed disk id is refused, and Azure is not asked about it' {
        $global:cmkCapture.dataDisks[0].managedDiskId = $null
        $r = InModuleScope VmMigrationFactory -Parameters @{ c = [pscustomobject]@{ RunPath = $script:rp; VmId = $script:vmId }; cap = $global:cmkCapture } {
            param($c, $cap) Add-VmfDiskEncryptionFacts -Context $c -Capture $cap
        }
        $r.Reason | Should -Be 'diskEncryptionNotKnown'
        $r.Detail | Should -Match "the data disk 'vm1-data0' on LUN 0: it has no managed disk id"
        $global:cmkReads | Should -Not -Contain 'vm1-data0'
    }

    It 'a worker that lost its lease stops at once, never parked as "not known"' {
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { throw 'Lease lost - abandon this VM' }
        { InModuleScope VmMigrationFactory -Parameters @{ c = [pscustomobject]@{ RunPath = $script:rp; VmId = $script:vmId }; cap = $global:cmkCapture } {
                param($c, $cap) Add-VmfDiskEncryptionFacts -Context $c -Capture $cap } } | Should -Throw '*abandon this VM*'
    }

    It 'PRECHECK itself saves the keys with the capture, in the first capture too, at v21 - and changes nothing in Azure' {
        CmkPrecheckMocks
        try {
            $r = CmkRunPrecheck $script:rp
            $r.Next | Should -Be 'SAFETY_PRISTINE' -Because "PRECHECK passes ($($r.Detail))"
            $doc = CmkDoc $script:rp
            $doc.captured.vmConfig.osDisk.encryptionType | Should -Be $script:cmk
            $doc.captured.vmConfig.osDisk.diskEncryptionSetId | Should -Be $script:desCmk
            @($doc.captured.vmConfig.dataDisks)[0].encryptionType | Should -Be $script:dbl
            $doc.captured.original.vmConfig.osDisk.diskEncryptionSetId | Should -Be $script:desCmk -Because 'the first capture keeps it too'
            $doc.schemaVersion | Should -Be 51   # v21 added the encryption; ROLLBACK-DISKS-FIRST-1 took v22, RECOVER-ALL-DISKS-1 v23, ROLLBACK-CRG-1 v24, SWAP-REFUSED-AFTER-STOP-1 v25, MADE-DISK-RECORD-1 v26, RESTORE-END-JOB-1 v27, FINISH-EMPTY-LUN-PROOF-1 v28, FINISH-KEPT-DISKS-1 v29, RESTORE-EARLIER-DELETE-1 v40
            # NIC-JOIN-1's way: each set is asked about at its OWN scope.
            @($global:cmkScopes) | Should -Contain $script:desCmk
            @($global:cmkScopes) | Should -Contain $script:desDbl
        }
        finally { Remove-Variable cmkLive, cmkScopes -Scope Global -ErrorAction SilentlyContinue }
    }

    It 'through PRECHECK: a disk whose key cannot be read stops the machine there, UNTOUCHED, before any set is asked about' {
        CmkPrecheckMocks
        $global:cmkTruth['vm1-data1'] = @($null, $null)
        try {
            $r = CmkRunPrecheck $script:rp
            $r.Next | Should -Be 'NEEDS_DECISION'
            $r.Reason | Should -Be 'diskEncryptionNotKnown'
            $r.MachineState | Should -Be 'untouched'
            $r.Detail | Should -Match "the data disk 'vm1-data1' on LUN 1: Azure returned no encryption type for it"
            @($global:cmkScopes | Where-Object { $_ -match 'diskEncryptionSets' }) | Should -BeNullOrEmpty
        }
        finally { Remove-Variable cmkLive, cmkScopes -Scope Global -ErrorAction SilentlyContinue }
    }

    It 'through PRECHECK: a set this identity cannot read stops the machine there, untouched, naming the set' {
        CmkPrecheckMocks
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions {
            $global:cmkScopes.Add($Scope)
            if ($Scope -match 'des-contoso$') { return @([pscustomobject]@{ actions = @('Microsoft.Compute/disks/*'); notActions = @() }) }
            @([pscustomobject]@{ actions = @('*'); notActions = @() }) }
        try {
            $r = CmkRunPrecheck $script:rp
            $r.Next | Should -Be 'NEEDS_DECISION'
            $r.Reason | Should -Be 'permissionMissingDiskEncryptionSet'
            $r.Detail | Should -Match ([regex]::Escape("Microsoft.Compute/diskEncryptionSets/read on $($script:desCmk)"))
        }
        finally { Remove-Variable cmkLive, cmkScopes -Scope Global -ErrorAction SilentlyContinue }
    }
}

Describe 'SAFETY-CMK-1: the permission Azure checks on each disk encryption set' {
    BeforeAll {
        function Global:CmkCapture([string[]]$Sets) {
            [pscustomobject]@{
                osDisk = [pscustomobject]@{ name = 'os'; encryptionType = $(if ($Sets[0]) { 'EncryptionAtRestWithCustomerKey' } else { 'EncryptionAtRestWithPlatformKey' }); diskEncryptionSetId = $Sets[0] }
                dataDisks = @(for ($i = 1; $i -lt $Sets.Count; $i++) { [pscustomobject]@{ lun = $i; encryptionType = $(if ($Sets[$i]) { 'EncryptionAtRestWithCustomerKey' } else { 'EncryptionAtRestWithPlatformKey' }); diskEncryptionSetId = $Sets[$i] } })
            }
        }
    }
    AfterAll { Remove-Item function:CmkCapture -ErrorAction SilentlyContinue }
    BeforeEach {
        $global:cmkAsked = [System.Collections.Generic.List[string]]::new()
        $global:cmkGrants = @{}
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { $global:cmkAsked.Add($Scope); @([pscustomobject]@{ actions = @($global:cmkGrants[$Scope]); notActions = @() }) }
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-cmkr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:rp | Out-Null
    }
    AfterEach { CmkDrop $script:rp; Remove-Variable cmkAsked, cmkGrants -Scope Global -ErrorAction SilentlyContinue }

    It 'a machine with no disk encryption set asks nothing' {
        InModuleScope VmMigrationFactory -Parameters @{ c = [pscustomobject]@{ RunPath = $script:rp; VmId = $script:vmId }; cap = (CmkCapture @($null, $null)) } {
            param($c, $cap) Test-VmfDiskEncryptionSetPermissions -Context $c -Capture $cap } | Should -BeNullOrEmpty
        $global:cmkAsked.Count | Should -Be 0
    }

    It 'a set this identity cannot read stops PRECHECK, naming the set and the action - asked once per set, at the SET' {
        $global:cmkGrants[$script:desCmk] = @('Microsoft.Compute/disks/*')
        $global:cmkGrants[$script:desDbl] = @('Microsoft.Compute/diskEncryptionSets/read')
        $r = InModuleScope VmMigrationFactory -Parameters @{ c = [pscustomobject]@{ RunPath = $script:rp; VmId = $script:vmId }; cap = (CmkCapture @($script:desCmk, $script:desCmk.ToUpperInvariant(), $script:desDbl)) } {
            param($c, $cap) Test-VmfDiskEncryptionSetPermissions -Context $c -Capture $cap }
        @($global:cmkAsked) | Should -Be @($script:desCmk, $script:desDbl) -Because 'one set named in two letter cases is one set'
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'permissionMissingDiskEncryptionSet'
        $r.Detail | Should -Match ([regex]::Escape("Microsoft.Compute/diskEncryptionSets/read on $($script:desCmk)"))
        $r.Detail | Should -Not -Match ([regex]::Escape($script:desDbl)) -Because 'that set is readable'
        $r.Detail | Should -Match 'The run stopped before touching the machine\.'
    }

    It 'a wildcard grant on the provider covers it' {
        $global:cmkGrants[$script:desCmk] = @('Microsoft.Compute/*')
        InModuleScope VmMigrationFactory -Parameters @{ c = [pscustomobject]@{ RunPath = $script:rp; VmId = $script:vmId }; cap = (CmkCapture @($script:desCmk)) } {
            param($c, $cap) Test-VmfDiskEncryptionSetPermissions -Context $c -Capture $cap } | Should -BeNullOrEmpty
    }

    It 'the role carries the action on every call that makes a disk or a copy with a set - the check cannot demand what the role lacks' {
        $map = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'rbac-actions.json') -Raw | ConvertFrom-Json
        $action = InModuleScope VmMigrationFactory { $script:VmfDiskEncryptionSetAction }
        $action | Should -Be 'Microsoft.Compute/diskEncryptionSets/read'
        foreach ($c in 'New-AzDisk', 'New-AzSnapshot') {
            $op = @($map.operations | Where-Object cmdlet -EQ $c)[0]
            $op.role | Should -Be 'execute'
            @($op.actions) | Should -Contain $action
            $op.why | Should -Match 'SAFETY-CMK-1'
        }
        @($map.operations | Where-Object { $_.cmdlet -eq 'Invoke-AzRestMethod' -and @($_.actions) -contains 'Microsoft.Compute/snapshots/write' })[0].actions | Should -Contain $action
    }
}

Describe 'SAFETY-CMK-1: every safety copy asks for its disk''s key' {
    BeforeEach {
        # ROLLBACK-DISKS-FIRST-1: the rollback disks, made at the end of
        # SAFETY_PRISTINE, are the subject of RollbackDisksBeforeMove.Tests.ps1; here the copies are.
        Mock -ModuleName VmMigrationFactory New-VmfRollbackDisksBeforeMove { $null }
        $global:cmkSnaps = @{}
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { }
        Mock -ModuleName VmMigrationFactory Get-VmfSafetyCopyTags { @{ vmfSafetyCopy = 'true' } }
        Mock -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot { $global:cmkSnaps[$SnapshotName] = @($EncryptionType, $DiskEncryptionSetId); "$($script:sub)/snapshots/$SnapshotName" }
        Mock -ModuleName VmMigrationFactory Lock-VmfSnapshot { }
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/deallocated' }
    }
    AfterEach { CmkDrop $script:rp; Remove-Variable cmkSnaps -Scope Global -ErrorAction SilentlyContinue }

    It 'the first copies: the OS disk and each data disk with its own type and set' {
        $script:rp = CmkNewRun -State 'SAFETY_PRISTINE'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id)
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $doc.safety = [pscustomobject]@{ snapshotId = $null; cloneVmId = $null; locksAllowed = $true }
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        $r = InModuleScope VmMigrationFactory -Parameters @{ c = (CmkCtx $script:rp) } { param($c) Invoke-VmfStepSafetyPristine -Context $c }
        $r.Next | Should -Be 'GUEST_PREP'
        $os = $global:cmkSnaps.Keys | Where-Object { $_ -match 'pristine$' }
        $global:cmkSnaps[$os] | Should -Be @($script:cmk, $script:desCmk)
        $global:cmkSnaps[($global:cmkSnaps.Keys | Where-Object { $_ -match 'd0$' })] | Should -Be @($script:cmk, $script:desCmk)
        $global:cmkSnaps[($global:cmkSnaps.Keys | Where-Object { $_ -match 'd1$' })] | Should -Be @($script:dbl, $script:desDbl)
        $global:cmkSnaps[($global:cmkSnaps.Keys | Where-Object { $_ -match 'd2$' })][0] | Should -Be $script:pmk
    }

    It 'the second copies the same way' {
        $script:rp = CmkNewRun -State 'SAFETY_COPY'
        $r = InModuleScope VmMigrationFactory -Parameters @{ c = (CmkCtx $script:rp) } { param($c) Invoke-VmfStepSafetyCopy -Context $c }
        $os = $global:cmkSnaps.Keys | Where-Object { $_ -notmatch '-d\d+$' } | Select-Object -First 1
        $os | Should -Not -BeNullOrEmpty -Because "the second OS copy was taken ($($global:cmkSnaps.Keys -join ', '))"
        $global:cmkSnaps[$os] | Should -Be @($script:cmk, $script:desCmk)
        $global:cmkSnaps[($global:cmkSnaps.Keys | Where-Object { $_ -match 'd1$' })] | Should -Be @($script:dbl, $script:desDbl)
    }

    It 'a Premium SSD v2 copy (instant access) asks for the set too' {
        $script:rp = CmkNewRun -State 'SAFETY_PRISTINE'
        $global:cmkIa = @{}
        Mock -ModuleName VmMigrationFactory New-VmfInstantAccessSnapshot { $global:cmkIa[$SnapshotName] = @($EncryptionType, $DiskEncryptionSetId); "$($script:sub)/snapshots/$SnapshotName" }
        Mock -ModuleName VmMigrationFactory Get-VmfSnapshotAccess { [pscustomobject]@{ snapshotAccessState = 'InstantAccess'; instantAccessDurationMinutes = 300; timeCreated = (Get-Date).ToUniversalTime().ToString('o') } }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id)
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $doc.safety = [pscustomobject]@{ snapshotId = $null; cloneVmId = $null; locksAllowed = $true; pristineSnapshotId = '/snapshots/os'; pristineSnapshotLocked = $true }
            (@($doc.captured.vmConfig.dataDisks) | Where-Object lun -EQ 0).skuName = 'PremiumV2_LRS'
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        $n = InModuleScope VmMigrationFactory -Parameters @{ c = (CmkCtx $script:rp) } { param($c) Invoke-VmfDataDiskCopies -Context $c -Kind 'pristine' }
        $n | Should -Be 3
        $global:cmkIa[($global:cmkIa.Keys | Where-Object { $_ -match 'd0$' })] | Should -Be @($script:cmk, $script:desCmk)
        Remove-Variable cmkIa -Scope Global
    }
}

Describe 'SAFETY-CMK-1: every way back makes each disk with its key, and reads it back' {
    BeforeEach {
        $global:cmk = @{ calls = [System.Collections.Generic.List[string]]::new(); made = @{}; truth = (CmkTruth); swaps = [System.Collections.Generic.List[object]]::new() }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:cmk.calls.Add('stop') }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { $global:cmk.calls.Add('start') }
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { $null }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { $global:cmk.calls.Add('size') }
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo { [pscustomobject]@{ name = 'vm1-osdisk'; resourceGroup = 'rg-app'; location = 'centralus'; skuName = 'Premium_LRS'; controller = 'NVMe' } }
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { 1 }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot {
            $global:cmk.made[$DiskName] = @($EncryptionType, $DiskEncryptionSetId); $global:cmk.calls.Add("create:$DiskName"); "$($script:sub)/disks/$DiskName" }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { $global:cmk.calls.Add("read:$(($DiskId -split '/')[-1])"); CmkFacts $DiskId $global:cmk.truth }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:cmk.calls.Add('os') }
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks { $global:cmk.calls.Add("data:$(@($Swaps | ForEach-Object lun) -join ',')"); $global:cmk.swaps.Add(@($Swaps)); @{ Applied = $true } }
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { [pscustomobject]@{ Name = 'vm1' } }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @() }
    }
    AfterEach { CmkDrop $script:rp; Remove-Variable cmk -Scope Global -ErrorAction SilentlyContinue }

    It 'Path A rollback: the OS disk and every data disk are made with the key of the disk each replaces, and each is read back before any swap' {
        $script:rp = CmkNewRun
        InModuleScope VmMigrationFactory -Parameters @{ c = (CmkCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c }
        $m = $global:cmk.made
        $m[($m.Keys | Where-Object { $_ -like 'vm1-osdisk-asitwas-*' })] | Should -Be @($script:cmk, $script:desCmk)
        $m[($m.Keys | Where-Object { $_ -like 'vm1-data0-d0-asitwas-*' })] | Should -Be @($script:cmk, $script:desCmk)
        $m[($m.Keys | Where-Object { $_ -like 'vm1-data1-d1-asitwas-*' })] | Should -Be @($script:dbl, $script:desDbl) -Because 'double encryption keeps its own type, apart from a customer-managed key'
        $m[($m.Keys | Where-Object { $_ -like 'vm1-data2-d2-asitwas-*' })][0] | Should -Be $script:pmk
        $calls = @($global:cmk.calls)
        @($calls | Where-Object { $_ -like 'read:*asitwas*' }).Count | Should -Be 4 -Because 'every disk made from a copy is read back - every type'
        [array]::LastIndexOf($calls, ($calls | Where-Object { $_ -like 'read:*' } | Select-Object -Last 1)) | Should -BeLessThan ([array]::IndexOf($calls, 'os'))
        @((CmkDoc $script:rp).rollback.dataDisks | ForEach-Object lun) | Should -Be @(0, 1, 2)
        $calls[-1] | Should -Be 'start'
    }

    # REBUILD-REMOVE-ENGINE-1: the Path B case is gone with its step.
    It 'the disks-only rollback before the move: the same' {
        $script:rp = CmkNewRun
        InModuleScope VmMigrationFactory -Parameters @{ c = (CmkCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c -GuestOnly }
        $m = $global:cmk.made
        $m[($m.Keys | Where-Object { $_ -like 'vm1-osdisk-asitwas-*' })] | Should -Be @($script:cmk, $script:desCmk)
        $m[($m.Keys | Where-Object { $_ -like 'vm1-data0-d0-asitwas-*' })] | Should -Be @($script:cmk, $script:desCmk)
    }

    It 'an OS disk Azure made on another key NEVER goes on the machine: the rollback stops, names the disk and both keys, and the disk is on record' {
        $script:rp = CmkNewRun
        $global:cmk.truth['vm1-osdisk'] = @($script:pmk, $null)
        { InModuleScope VmMigrationFactory -Parameters @{ c = (CmkCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c } } |
            Should -Throw "*Azure made the disk 'vm1-osdisk-asitwas-*', but its encryption is EncryptionAtRestWithPlatformKey with no disk encryption set, not EncryptionAtRestWithCustomerKey with the disk encryption set '$($script:desCmk)'. The product did not put it on the machine, and the new disk is kept.*"
        $global:cmk.calls | Should -Not -Contain 'os'
        @($global:cmk.calls | Where-Object { $_ -like 'data:*' }) | Should -BeNullOrEmpty
        @((CmkDoc $script:rp).rollbackDisksDuringRollback | ForEach-Object diskName | Where-Object { $_ -like 'vm1-osdisk-asitwas-*' }).Count | Should -Be 1 -Because 'a disk Azure made bills; it is on record the moment it exists'
    }

    It 'a data disk Azure made on another key is NOT swapped: the rollback stops before the stop, and why names both keys (SAFETY-ULTRA-MARGIN-1)' {
        $script:rp = CmkNewRun
        $global:cmk.truth['vm1-data1-d1'] = @($script:cmk, $script:desDbl)
        { InModuleScope VmMigrationFactory -Parameters @{ c = (CmkCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c } } |
            Should -Throw "*'vm1-data1' on LUN 1*Azure made the disk 'vm1-data1-d1-asitwas-*', but its encryption is EncryptionAtRestWithCustomerKey with the disk encryption set '*des-contoso-double', not EncryptionAtRestWithPlatformAndCustomerKeys*"
        $global:cmk.calls | Should -Not -Contain 'stop'
    }

    It 'a Premium SSD v2 data disk is made with its key and its values, and one on another key is not used - compared in the same read' {
        $script:rp = CmkNewRun
        $global:cmkGot = @{ encryptionType = $script:pmk; diskEncryptionSetId = $null }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts {
            [pscustomobject]@{ id = $DiskId; skuName = 'PremiumV2_LRS'; diskSizeGB = 16; diskIOPSReadWrite = 5000; diskMBpsReadWrite = 200; logicalSectorSize = 512
                zones = @('1'); encryptionType = $global:cmkGot.encryptionType; diskEncryptionSetId = $global:cmkGot.diskEncryptionSetId } }
        $row = [pscustomobject]@{ lun = 0; name = 'vm1-data0'; snapshotId = "$($script:sub)/snapshots/vm1-pristine-d0"; skuName = 'PremiumV2_LRS'
            instantAccess = $true; diskIOPSReadWrite = 5000; diskMBpsReadWrite = 200; logicalSectorSize = 512; sizeGB = 16; diskZones = @('1')
            encryption = [pscustomobject]@{ type = $script:cmk; diskEncryptionSetId = $script:desCmk } }
        $made = InModuleScope VmMigrationFactory -Parameters @{ c = (CmkCtx $script:rp); r = $row } {
            param($c, $r) New-VmfDataDiskFromCopy -Context $c -Row $r -DiskName 'vm1-data0-d0-asitwas-s' -ResourceGroupName 'rg-app' -Location 'centralus' -Zone '1' -OpName 'rollback:createDataDisk' }
        $global:cmk.made['vm1-data0-d0-asitwas-s'] | Should -Be @($script:cmk, $script:desCmk)
        $made.Why | Should -Match "Azure made the disk 'vm1-data0-d0-asitwas-s', but it differs from the record: its encryption is EncryptionAtRestWithPlatformKey with no disk encryption set, not EncryptionAtRestWithCustomerKey"
        $global:cmkGot = @{ encryptionType = $script:cmk; diskEncryptionSetId = $script:desCmk }
        $ok = InModuleScope VmMigrationFactory -Parameters @{ c = (CmkCtx $script:rp); r = $row } {
            param($c, $r) New-VmfDataDiskFromCopy -Context $c -Row $r -DiskName 'vm1-data0-d0-asitwas-t' -ResourceGroupName 'rg-app' -Location 'centralus' -Zone '1' -OpName 'rollback:createDataDisk' }
        $ok.Why | Should -BeNullOrEmpty
        Remove-Variable cmkGot -Scope Global
    }

    It 'a disk that cannot be read back is not used either: the rollback stops before the stop (SAFETY-ULTRA-MARGIN-1)' {
        $script:rp = CmkNewRun
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { if ($DiskId -match 'data0') { throw 'ResourceNotFound' }; CmkFacts $DiskId $global:cmk.truth }
        { InModuleScope VmMigrationFactory -Parameters @{ c = (CmkCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c } } |
            Should -Throw "*'vm1-data0' on LUN 0*could not read it back to compare its encryption with the record: ResourceNotFound*"
        $global:cmk.calls | Should -Not -Contain 'stop'
    }

    It 'OLD-VERSION-READERS-REMOVE-4: no key on record - no disk is made from a copy, and the rollback stops before the stop' {
        $script:rp = CmkNewRun -NoRecord
        { InModuleScope VmMigrationFactory -Parameters @{ c = (CmkCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c } } |
            Should -Throw "*The encryption of the disk that the copy '*' was taken of is not on record, so the product did not make the disk*"
        @($global:cmk.made.Keys).Count | Should -Be 0 -Because 'a disk with Azure''s default key would differ from the disk it replaces'
        $global:cmk.calls | Should -Not -Contain 'stop'
    }

    It 'Restore all (every data disk, keeping the names or new names) carries the key onto each disk it makes' {
        $script:rp = CmkNewRun -State 'MIGRATED'
        $live = @(foreach ($l in 0, 1, 2) { [pscustomobject]@{ lun = $l; id = "$($script:sub)/disks/vm1-data$l"; name = "vm1-data$l"; resourceGroup = 'rg-app'; skuName = 'Premium_LRS' } })
        foreach ($naming in 'new', 'preserve') {
            $p = InModuleScope VmMigrationFactory -Parameters @{ d = (CmkDoc $script:rp); live = $live; n = $naming } {
                param($d, $live, $n) Get-VmfOperatorDataRestorePlan -Doc $d -Kind 'pristine' -Live $live -Stamp 's' -Naming $n }
            (@($p.Restore) | Where-Object lun -EQ 1).encryption.type | Should -Be $script:dbl
            (@($p.Restore) | Where-Object lun -EQ 1).encryption.diskEncryptionSetId | Should -Be $script:desDbl
        }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk { }
        $res = InModuleScope VmMigrationFactory -Parameters @{ c = ([pscustomobject]@{ RunPath = $script:rp; VmId = $script:vmId; Rg = 'rg-app' }); d = (CmkDoc $script:rp); live = $live } {
            param($c, $d, $live)
            $plan = Get-VmfOperatorDataRestorePlan -Doc $d -Kind 'pristine' -Live $live -Stamp 's' -Naming 'preserve'
            # RESTORE-INLOOP-TEMP-1: the temporary disks are made before the
            # stop, as Restore this machine makes them.
            $pre = New-VmfOperatorTempDataDisks -Context $c -Plan $plan -Location 'centralus' -Zone '1'
            @($pre.Kept).Count | Should -Be 0
            Invoke-VmfOperatorDataRestore -Context $c -VmName 'vm1' -Plan $plan -Naming 'preserve' -Location 'centralus' -Zone '1' -TempMade $pre.Temp
        }
        $global:cmk.made['vm1-data0-d0-rtmp-s'] | Should -Be @($script:cmk, $script:desCmk)
        $global:cmk.made['vm1-data0'] | Should -Be @($script:cmk, $script:desCmk) -Because 'the disk under the old name is made the same way'
        $global:cmk.made['vm1-data1'] | Should -Be @($script:dbl, $script:desDbl)
        @($res.Kept).Count | Should -Be 0
    }

    It 'Restore all keeping the names: a temporary disk on another key stops the restore before the stop, and NOTHING is deleted' {
        $script:rp = CmkNewRun -State 'MIGRATED'
        $global:cmk.truth['vm1-data0-d0-rtmp'] = @($script:pmk, $null)
        $global:cmkDeleted = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk { $global:cmkDeleted.Add($DiskName) }
        $live = @(foreach ($l in 0, 1, 2) { [pscustomobject]@{ lun = $l; id = "$($script:sub)/disks/vm1-data$l"; name = "vm1-data$l"; resourceGroup = 'rg-app'; skuName = 'Premium_LRS' } })
        $res = InModuleScope VmMigrationFactory -Parameters @{ c = ([pscustomobject]@{ RunPath = $script:rp; VmId = $script:vmId; Rg = 'rg-app' }); d = (CmkDoc $script:rp); live = $live } {
            param($c, $d, $live)
            $plan = Get-VmfOperatorDataRestorePlan -Doc $d -Kind 'pristine' -Live $live -Stamp 's' -Naming 'preserve'
            # RESTORE-INLOOP-TEMP-1: made before the stop, as Restore this
            # machine makes them; a disk refused there stops the restore.
            $pre = New-VmfOperatorTempDataDisks -Context $c -Plan $plan -Location 'centralus' -Zone '1'
            $stop = $null
            try { Assert-VmfDataDisksAllBack -Kept @($pre.Kept) } catch { $stop = $_.Exception.Message }
            @{ Kept = @($pre.Kept); Stop = $stop }
        }
        $global:cmkDeleted | Should -BeNullOrEmpty -Because 'its temporary disk is on another key, so the restore stops before the stop and deletes nothing'
        (@($res.Kept) | Where-Object lun -EQ 0).why | Should -Match 'its encryption is EncryptionAtRestWithPlatformKey'
        $res.Stop | Should -Match "'vm1-data0' on LUN 0"
        Remove-Variable cmkDeleted -Scope Global
    }
}

Describe 'SAFETY-CMK-1: Restore this machine, and a rebuild when the machine is gone' {
    BeforeEach {
        $global:cmkR = @{ made = @{}; truth = (CmkTruth); calls = [System.Collections.Generic.List[string]]::new() }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { $global:cmkR.made[$DiskName] = @($EncryptionType, $DiskEncryptionSetId); $global:cmkR.calls.Add("create:$DiskName"); "$($script:sub)/disks/$DiskName" }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { CmkFacts $DiskId $global:cmkR.truth }
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { 'previous-context' }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:cmkR.calls.Add("swap:$DiskName") }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk { $global:cmkR.calls.Add("delete:$DiskName") }
        Mock -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks { , @() }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @() }
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { $null }
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo {
            [pscustomobject]@{ name = 'vm1-osdisk'; id = "$($script:sub)/disks/vm1-osdisk"; resourceGroup = 'rg-app'; location = 'centralus'; skuName = 'Premium_LRS'; sizeGB = 64; controller = 'SCSI' } }
        Mock -ModuleName VmMigrationFactory Get-VmfVmSize { 'Standard_D2s_v4' }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { }
    }
    AfterEach { CmkDrop $script:rp; Remove-Variable cmkR -Scope Global -ErrorAction SilentlyContinue }

    It 'new names: the OS disk is made with its key and read back' {
        $script:rp = CmkNewRun -State 'MIGRATED'
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false | Out-Null
        $m = $global:cmkR.made
        $m[($m.Keys | Where-Object { $_ -like 'vm1-osdisk-restored-*' })] | Should -Be @($script:cmk, $script:desCmk)
    }

    It 'keeping the names: the temporary disk on another key stops the restore BEFORE the original is deleted or any disk is swapped' {
        $script:rp = CmkNewRun -State 'MIGRATED'
        $global:cmkR.truth['vm1-osdisk-rtmp'] = @($script:pmk, $null)
        { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -DiskNaming preserve -AcceptPreserveRisk -Confirm:$false } |
            Should -Throw "*but its encryption is EncryptionAtRestWithPlatformKey*"
        @($global:cmkR.calls | Where-Object { $_ -like 'delete:*' -or $_ -like 'swap:*' }) | Should -BeNullOrEmpty
    }

    It 'keeping the names: both disks are made with the key, the one under the old name too' {
        $script:rp = CmkNewRun -State 'MIGRATED'
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -DiskNaming preserve -AcceptPreserveRisk -Confirm:$false | Out-Null
        $global:cmkR.made['vm1-osdisk'] | Should -Be @($script:cmk, $script:desCmk)
        $m = $global:cmkR.made
        $m[($m.Keys | Where-Object { $_ -like 'vm1-osdisk-rtmp-*' })] | Should -Be @($script:cmk, $script:desCmk)
    }

    # REBUILD-REMOVE-RECOVER-1: removed with Rebuild this machine and the restore that rebuilds.

    # REBUILD-REMOVE-RECOVER-1: removed with Rebuild this machine and the restore that rebuilds.
}

Describe 'SAFETY-CMK-1: the contract, v21' {
    It 'the store writes the current version (v23 since RECOVER-ALL-DISKS-1), and the sample shows a customer-managed key, double encryption and a platform key' {
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json') -Raw | ConvertFrom-Json
        $schema.properties.schemaVersion.const | Should -Be 51
        InModuleScope VmMigrationFactory { $script:VmfStateDocSchemaVersion | Should -Be 51 }
        @($schema.'$defs'.diskEncryptionType.enum) | Should -Be @('EncryptionAtRestWithPlatformKey', 'EncryptionAtRestWithCustomerKey', 'EncryptionAtRestWithPlatformAndCustomerKeys')
        $known = InModuleScope VmMigrationFactory { @($script:VmfDiskEncryptionTypes.Keys) }
        @($known) | Should -Be @($schema.'$defs'.diskEncryptionType.enum) -Because 'the engine and the contract know the same types'
        $sample = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'vm-state.sample.json') -Raw | ConvertFrom-Json
        $sample.schemaVersion | Should -Be 51
        $sample.captured.vmConfig.osDisk.encryptionType | Should -Be 'EncryptionAtRestWithCustomerKey'
        @($sample.captured.vmConfig.dataDisks.encryptionType) | Should -Contain 'EncryptionAtRestWithPlatformAndCustomerKeys'
        @($sample.captured.vmConfig.dataDisks.encryptionType) | Should -Contain 'EncryptionAtRestWithPlatformKey'
    }

    It 'the migration note says what changed, why, and what an older document does' {
        $notes = Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw
        $notes | Should -Match '## vm-state v20 -> v21 \(\d{4}-\d{2}-\d{2}, SAFETY-CMK-1\)'
    }

    It 'the stop at PRECHECK has its words, a machine state and a retry kind' {
        $sr = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json
        $e = @($sr.reasons | Where-Object code -EQ 'diskEncryptionNotKnown')
        $e.Count | Should -Be 1
        $e[0].machine | Should -Be 'untouched'
        $e[0].retry | Should -Be 'afterFix'
    }
}
