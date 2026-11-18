#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# ADE-DETECT-ANY-NAME-1 (2026-11-14): Azure Disk Encryption is found at
# Checking whatever the extension is called, and on every disk.
#
# Checking used to ask Azure for the extension by two fixed NAMES,
# 'AzureDiskEncryption' and 'AzureDiskEncryptionForLinux'. An ARM template can
# give it any name. The scan reads only the OS disk. So a Windows machine
# whose extension had another name, and whose data disks only were encrypted,
# passed every check and was moved to a v6 or v7 size, where Azure Disk
# Encryption is not available.
#
# Now: the extension is found by its publisher and type, from the list
# Checking already reads, and every managed disk's
# encryptionSettingsCollection.enabled is read from the disk read Checking
# already makes. Either one stops the machine untouched (diskEncryptionPresent).
# A disk read that gave no answer is never yes or no (EVAL-M6).

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # CLUSTER-DETECT-1: the cluster check at Checking is not under test here.
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }

    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers'
    $script:vmId = "$($script:sub)/Microsoft.Compute/virtualMachines/vm1"

    # One Windows machine, one interface, no zone; with -DataDisk, one data
    # disk on LUN 0. Shaped like Get-AzVM returns it.
    function Global:AdVm {
        param([switch]$DataDisk)
        $data = @(if ($DataDisk) {
                [pscustomobject]@{ Name = 'vm1-data0'; Lun = 0; Caching = 'None'; DiskSizeGB = 32; DeleteOption = 'Detach'; CreateOption = 'Attach'
                    ManagedDisk = [pscustomobject]@{ Id = "$($script:sub)/Microsoft.Compute/disks/vm1-data0"; StorageAccountType = 'Premium_LRS' } }
            })
        [pscustomobject]@{
            Name = 'vm1'; ResourceGroupName = 'rg-app'; Location = 'centralus'
            HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_D2s_v4' }
            StorageProfile = [pscustomobject]@{
                DiskControllerType = 'SCSI'
                OsDisk = [pscustomobject]@{ OsType = 'Windows'; Name = 'vm1-os'; DeleteOption = 'Delete'
                    ManagedDisk = [pscustomobject]@{ Id = "$($script:sub)/Microsoft.Compute/disks/vm1-os"; StorageAccountType = 'Premium_LRS' } }
                DataDisks = $data; ImageReference = $null
            }
            NetworkProfile = [pscustomobject]@{ NetworkInterfaces = @([pscustomobject]@{ Id = "$($script:sub)/Microsoft.Network/networkInterfaces/nic0"; Primary = $true }) }
            Zones = @(); Tags = @{}
            LicenseType = $null; AvailabilitySetReference = $null; ProximityPlacementGroup = $null
            Priority = $null; Identity = $null; AdditionalCapabilities = $null; DiagnosticsProfile = $null
        }
    }

    function Global:AdPlan {
        param([string]$Size = 'Standard_D2s_v6', [string]$Controller = 'NVMe')
        [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vmId; wave = 'w1'; ring = 'lab'; path = 'A'
            assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Windows'; sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; platformManaged = $false; location = 'centralus' }
            target = [pscustomobject]@{ size = $Size; diskArch = 'diskless'; controller = $Controller }
            policy = [pscustomobject]@{ onDDataFound = 'proceed' } }
    }

    function Global:AdPrecheck {
        param([string]$RunPath, $Plan = (Global:AdPlan))
        InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath; plan = $Plan } {
            param($rp, $plan)
            $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'ade'
            New-VmfStateDoc -RunPath $rp -RunId 'ade' -VmId $ctx.VmId | Out-Null
            Invoke-VmfStepPrecheck -Context $ctx
        }
    }

    # An extension as Get-VmfVmExtensions returns it.
    function Global:AdExt {
        param([string]$Name, [string]$Publisher = 'Microsoft.Azure.Security', [string]$Type = 'AzureDiskEncryption', [string]$State = 'Succeeded')
        [ordered]@{ name = $Name; publisher = $Publisher; type = $Type; provisioningState = $State }
    }

    # A disk read as Get-VmfManagedDiskFacts returns it.
    function Global:AdFacts {
        param([string]$Id, $Ade = $false)
        [pscustomobject]@{ id = $Id; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null; purchasePlan = $null; adeEnabled = $Ade }
    }
}

AfterAll {
    foreach ($fn in 'AdVm', 'AdPlan', 'AdPrecheck', 'AdExt', 'AdFacts') { Remove-Item "function:\$fn" -ErrorAction SilentlyContinue }
}

Describe 'ADE-DETECT-ANY-NAME-1: the extension is found by its publisher and type, never its name' {
    It 'an extension of the Windows type under a name of its own is found' {
        InModuleScope VmMigrationFactory -Parameters @{ x = @(Global:AdExt -Name 'encrypt-from-template') } {
            param($x)
            Test-VmfAdeExtension -Extensions $x | Should -BeTrue
        }
    }

    It 'an extension of the Linux type under a name of its own is found' {
        InModuleScope VmMigrationFactory -Parameters @{ x = @(Global:AdExt -Name 'disk-crypt' -Type 'AzureDiskEncryptionForLinux') } {
            param($x)
            Test-VmfAdeExtension -Extensions $x | Should -BeTrue
        }
    }

    It 'the publisher and the type are compared without regard to case, as Azure does' {
        InModuleScope VmMigrationFactory -Parameters @{ x = @(Global:AdExt -Name 'e' -Publisher 'microsoft.azure.security' -Type 'azurediskencryption') } {
            param($x)
            Test-VmfAdeExtension -Extensions $x | Should -BeTrue
        }
    }

    It 'the NAME alone is not Azure Disk Encryption: another publisher under the same name is not found' {
        InModuleScope VmMigrationFactory -Parameters @{ x = @(Global:AdExt -Name 'AzureDiskEncryption' -Publisher 'Contoso.Tools' -Type 'Backup') } {
            param($x)
            Test-VmfAdeExtension -Extensions $x | Should -BeFalse
        }
    }

    It 'the TYPE alone is not Azure Disk Encryption either: another publisher with the same type is not found' {
        InModuleScope VmMigrationFactory -Parameters @{ x = @(Global:AdExt -Name 'e' -Publisher 'Contoso.Tools' -Type 'AzureDiskEncryption') } {
            param($x)
            Test-VmfAdeExtension -Extensions $x | Should -BeFalse
        }
    }
    It 'another type from the same publisher is not found' {
        InModuleScope VmMigrationFactory -Parameters @{ x = @(Global:AdExt -Name 'av' -Type 'IaaSAntimalware') } {
            param($x)
            Test-VmfAdeExtension -Extensions $x | Should -BeFalse
        }
    }

    It 'the existing rule stays: an extension that is not Succeeded is not taken as encryption (the disks answer that)' {
        InModuleScope VmMigrationFactory -Parameters @{ x = @(Global:AdExt -Name 'e' -State 'Failed') } {
            param($x)
            Test-VmfAdeExtension -Extensions $x | Should -BeFalse
        }
    }

    It 'a machine with no extensions has none' {
        InModuleScope VmMigrationFactory {
            Test-VmfAdeExtension -Extensions @() | Should -BeFalse
        }
    }

    It 'the check asks Azure nothing: it reads the list Checking already read' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'PrecheckExtensions.ps1')
        $fn = [regex]::Match($code, '(?s)function Test-VmfAdeExtension \{.*?\n\}').Value
        $fn | Should -Not -BeNullOrEmpty
        $fn | Should -Not -Match 'Get-AzVMExtension|Invoke-AzRestMethod|Get-VmfVmExtensions'
        $ops = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops' 'AzureOpsVm.ps1')
        $ops | Should -Not -Match "-Name \`$extName" -Because 'no extension is looked up by a fixed name'
    }
}

Describe 'ADE-DETECT-ANY-NAME-1: each disk read gives the Azure Disk Encryption setting' {
    BeforeAll {
        function Global:AdDiskBody {
            param($Props)
            [pscustomobject]@{ StatusCode = 200; Content = (@{ id = 'd'; sku = @{ name = 'Premium_LRS' }; properties = $Props } | ConvertTo-Json -Depth 8) }
        }
    }
    AfterAll { Remove-Item 'function:\AdDiskBody' -ErrorAction SilentlyContinue }

    It 'enabled true is true' {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { Global:AdDiskBody @{ provisioningState = 'Succeeded'; encryptionSettingsCollection = @{ enabled = $true; encryptionSettings = @() } } }
        $f = InModuleScope VmMigrationFactory -Parameters @{ id = "$($script:sub)/Microsoft.Compute/disks/vm1-data0" } { param($id) Get-VmfManagedDiskFacts -DiskId $id }
        $f.adeEnabled | Should -BeTrue
    }

    It 'enabled false is false' {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { Global:AdDiskBody @{ provisioningState = 'Succeeded'; encryptionSettingsCollection = @{ enabled = $false } } }
        $f = InModuleScope VmMigrationFactory -Parameters @{ id = "$($script:sub)/Microsoft.Compute/disks/vm1-data0" } { param($id) Get-VmfManagedDiskFacts -DiskId $id }
        $f.adeEnabled | Should -BeFalse
        $null -eq $f.adeEnabled | Should -BeFalse -Because 'a definite false is an answer, not unknown'
    }

    It 'no setting on a disk Azure answered for is false: the read is an answer' {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { Global:AdDiskBody @{ provisioningState = 'Succeeded' } }
        $f = InModuleScope VmMigrationFactory -Parameters @{ id = "$($script:sub)/Microsoft.Compute/disks/vm1-data0" } { param($id) Get-VmfManagedDiskFacts -DiskId $id }
        $f.PSObject.Properties['adeEnabled'] | Should -Not -BeNullOrEmpty -Because 'every read returns the field'
        $f.adeEnabled | Should -BeFalse
        $null -eq $f.adeEnabled | Should -BeFalse
    }

    It 'a setting with no enabled value is unknown: never yes or no' {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { Global:AdDiskBody @{ provisioningState = 'Succeeded'; encryptionSettingsCollection = @{ encryptionSettingsVersion = '1.1' } } }
        $f = InModuleScope VmMigrationFactory -Parameters @{ id = "$($script:sub)/Microsoft.Compute/disks/vm1-data0" } { param($id) Get-VmfManagedDiskFacts -DiskId $id }
        $f.PSObject.Properties['adeEnabled'] | Should -Not -BeNullOrEmpty
        $null -eq $f.adeEnabled | Should -BeTrue
    }

    It 'a read that failed still throws: it is never taken as "not encrypted"' {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 503; Content = 'busy' } }
        { InModuleScope VmMigrationFactory -Parameters @{ id = "$($script:sub)/Microsoft.Compute/disks/vm1-data0" } { param($id) Get-VmfManagedDiskFacts -DiskId $id } } | Should -Throw '*503*'
    }
}

Describe 'ADE-DETECT-ANY-NAME-1: Checking stops the machine untouched on either signal' {
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-ade-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Initialize-VmfRun -RunPath $rp -RunId 'ade' | Out-Null }
        Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions { , @() }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { Global:AdFacts -Id $DiskId }
        Mock -ModuleName VmMigrationFactory Get-VmfVmResourceLocks { , @() }
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { @([pscustomobject]@{ actions = @('*'); notActions = @() }) }
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/running' }
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { Global:AdVm }
        Mock -ModuleName VmMigrationFactory Get-AzNetworkInterface { [pscustomobject]@{ EnableAcceleratedNetworking = $true } }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { throw 'the machine must not be touched' }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { throw 'the machine must not be touched' }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @() }
        # A data disk is read for how many machines share it; one here.
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { 1 }
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'the machine with nothing encrypted goes on (the harness reaches the end of Checking)' {
        (Global:AdPrecheck -RunPath $script:rp).Next | Should -Be 'SAFETY_PRISTINE'
    }

    It 'THE DEFECT, part 1: a Windows machine whose extension has a name of its own stops untouched' {
        Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions { , @(Global:AdExt -Name 'encrypt-from-template') }
        $r = Global:AdPrecheck -RunPath $script:rp
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'diskEncryptionPresent'
        $r.Detail | Should -Be 'Azure Disk Encryption is enabled on this machine.' -Because 'the existing words, unchanged'
        Should -Invoke Stop-VmfVmDeallocated -ModuleName VmMigrationFactory -Times 0 -Exactly
    }

    It 'the extension is read once: Checking adds no second extension read' {
        Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions { , @(Global:AdExt -Name 'encrypt-from-template') }
        $null = Global:AdPrecheck -RunPath $script:rp
        Should -Invoke Get-VmfVmExtensions -ModuleName VmMigrationFactory -Times 1 -Exactly
    }

    It 'THE DEFECT, part 2: a machine with only a DATA disk encrypted, and no extension, stops untouched' {
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { Global:AdVm -DataDisk }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { Global:AdFacts -Id $DiskId -Ade ($DiskId -like '*vm1-data0') }
        $r = Global:AdPrecheck -RunPath $script:rp
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'diskEncryptionPresent'
        $r.Detail | Should -Be 'Azure Disk Encryption is enabled on this machine.'
        $r.MachineState | Should -Be 'untouched'
        Should -Invoke Stop-VmfVmDeallocated -ModuleName VmMigrationFactory -Times 0 -Exactly
    }

    It 'and with only the OS disk encrypted' {
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { Global:AdFacts -Id $DiskId -Ade ($DiskId -like '*vm1-os') }
        (Global:AdPrecheck -RunPath $script:rp).Reason | Should -Be 'diskEncryptionPresent'
    }

    It 'a disk whose setting Azure gave no answer for stops on unknown, never yes or no' {
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { Global:AdFacts -Id $DiskId -Ade $null }
        $r = Global:AdPrecheck -RunPath $script:rp
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'diskEncryptionUnknown'
        $r.MachineState | Should -Be 'untouched'
        $r.Detail | Should -BeLike "The Azure Disk Encryption setting of the OS disk 'vm1-os' has no value. *" -Because 'the stop names the disk whose setting has no value'
    }

    It 'a definite yes on one disk wins over unknown on another' {
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { Global:AdVm -DataDisk }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts {
            if ($DiskId -like '*vm1-os') { Global:AdFacts -Id $DiskId -Ade $null } else { Global:AdFacts -Id $DiskId -Ade $true }
        }
        (Global:AdPrecheck -RunPath $script:rp).Reason | Should -Be 'diskEncryptionPresent'
    }

    It 'a disk Azure did not answer for still stops (diskEncryptionNotKnown), never read as "not encrypted"' {
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { throw 'HTTP 403 Forbidden' }
        $r = Global:AdPrecheck -RunPath $script:rp
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'diskEncryptionNotKnown'
    }

    It 'REBUILD-REMOVE-PLAN-1 stays: the in-place upgrade (Preview) to a v5 size on SCSI stops on an encrypted data disk too' {
        Mock -ModuleName VmMigrationFactory Get-VmfPreviewFeatureGate { $null }
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { Global:AdVm -DataDisk }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { Global:AdFacts -Id $DiskId -Ade ($DiskId -like '*vm1-data0') }
        $plan = Global:AdPlan -Size 'Standard_D2s_v5' -Controller 'SCSI'
        $plan.target | Add-Member -NotePropertyName choice -NotePropertyValue ([pscustomobject]@{ method = 'preview'; series = 'v5' })
        (Global:AdPrecheck -RunPath $script:rp -Plan $plan).Reason | Should -Be 'diskEncryptionPresent'
    }
    It 'GEN-V5-1 stays: a v5 resize on SCSI keeps Azure Disk Encryption, so an encrypted data disk does not stop it' {
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { Global:AdVm -DataDisk }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { Global:AdFacts -Id $DiskId -Ade ($DiskId -like '*vm1-data0') }
        Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions { , @(Global:AdExt -Name 'encrypt-from-template') }
        $r = Global:AdPrecheck -RunPath $script:rp -Plan (Global:AdPlan -Size 'Standard_D2s_v5' -Controller 'SCSI')
        $r.Reason | Should -Not -Be 'diskEncryptionPresent'
        $r.Reason | Should -Not -Be 'diskEncryptionUnknown'
    }
}
