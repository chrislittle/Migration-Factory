#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# REBUILD-PROPS-1 (1.0): a rebuild drops the patch settings and other settings.
#
# Every rebuild from a capture - the Path B move, its automatic rollback, a
# restore that rebuilds, and Rebuild this machine - creates the machine again
# with New-VmfVmFromCapture, from what Get-VmfVmCapture recorded. What the
# capture did not record, or the rebuild did not send, was gone with the old
# definition. MEASURED in the lab on 2026-11-01:
#   - a machine from a Marketplace image with a purchase plan: Azure refuses
#     the create without the plan (VMMarketplaceInvalidInput) AFTER the old
#     definition is deleted, and leaves a Failed definition holding the disk.
#     The plan is on the OS disk too (purchasePlan) and survives a snapshot
#     and a new disk from it. NO-PLAN-SCOPE-1 (2026-11-03) took the plan out:
#     a machine with one is outside the scope of this tool, Checking stops it,
#     and no rebuild sends one (NoPlanScope.Tests.ps1).
#   - patch settings (osProfile.*Configuration.patchSettings): an Attach
#     create has no osProfile, so they are lost and Azure Update Manager
#     stops patching the machine. A PATCH of them on the rebuilt machine is
#     accepted and reads back.
# Read from the code: user data, the dedicated host and host group, Spot
# eviction policy and maximum price, hibernation, the boot diagnostics storage
# account, each delete option, Write Accelerator and the OS disk caching were
# not recorded or not sent. And two failed reads read as "none": the
# extension list and the resource locks.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    # The user-data test mocks Get-AzVM and reads $UserData, so the mock must
    # have a -UserData parameter. Pester builds the mock from the command it
    # finds first, and a global Get-AzVM stand-in left by an earlier file in
    # the same run (with no -UserData) gave the mock that shape: $UserData was
    # $null and the test failed only in some file orders. This file brings its
    # own stand-in, with the parameters the read uses, BEFORE the guard.
    function Global:Get-AzVM { [CmdletBinding()] param($ResourceGroupName, $Name, [switch]$UserData, [switch]$Status) throw 'stub' }
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }

    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers'
    $script:vmId = "$($script:sub)/Microsoft.Compute/virtualMachines/vm1"
    $script:osId = "$($script:sub)/Microsoft.Compute/disks/vm1-os"
    $script:d0Id = "$($script:sub)/Microsoft.Compute/disks/vm1-d0"
    $script:nicId = "$($script:sub)/Microsoft.Network/networkInterfaces/vm1-nic"
    $script:hostId = "$($script:sub)/Microsoft.Compute/hostGroups/hg1/hosts/host1"
    $script:hostGroupId = "$($script:sub)/Microsoft.Compute/hostGroups/hg1"

    # A machine as Get-AzVM returns it, with every setting this item covers.
    function Global:RpVm {
        # REBUILD-PATCH-MODE-1: -PatchMode, for a machine whose patch mode a rebuild can set again.
        param([string]$Os = 'Windows', [switch]$Bare, [string]$PatchMode = 'AutomaticByPlatform')
        $patch = [pscustomobject]@{ PatchMode = $PatchMode; AssessmentMode = 'AutomaticByPlatform'; EnableHotpatching = $false
            AutomaticByPlatformSettings = [pscustomobject]@{ RebootSetting = 'IfRequired'; BypassPlatformSafetyChecksOnUserSchedule = $true } }
        $osProfile = if ($Bare) { $null }
                     elseif ($Os -eq 'Windows') { [pscustomobject]@{ WindowsConfiguration = [pscustomobject]@{ PatchSettings = $patch }; LinuxConfiguration = $null } }
                     else { [pscustomobject]@{ WindowsConfiguration = $null; LinuxConfiguration = [pscustomobject]@{ PatchSettings = [pscustomobject]@{ PatchMode = $(if ($PatchMode -eq 'AutomaticByOS') { 'ImageDefault' } else { $PatchMode }); AssessmentMode = 'ImageDefault'
                                AutomaticByPlatformSettings = [pscustomobject]@{ RebootSetting = 'Never'; BypassPlatformSafetyChecksOnUserSchedule = $true } } } } }
        [pscustomobject]@{
            Id = $script:vmId; Name = 'vm1'; Location = 'centralus'
            HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_D4s_v4' }
            StorageProfile = [pscustomobject]@{
                DiskControllerType = 'SCSI'
                OsDisk = [pscustomobject]@{ Name = 'vm1-os'; OsType = $Os; Caching = $(if ($Bare) { $null } else { 'ReadOnly' }); DeleteOption = $(if ($Bare) { $null } else { 'Delete' })
                    WriteAcceleratorEnabled = $false; ManagedDisk = [pscustomobject]@{ Id = $script:osId; StorageAccountType = 'Premium_LRS' } }
                DataDisks = @([pscustomobject]@{ Name = 'vm1-d0'; Lun = 0; Caching = 'None'; DiskSizeGB = 64; DeleteOption = $(if ($Bare) { $null } else { 'Delete' })
                        WriteAcceleratorEnabled = $false; ManagedDisk = [pscustomobject]@{ Id = $script:d0Id; StorageAccountType = 'Premium_LRS' } })
                ImageReference = $null }
            NetworkProfile = [pscustomobject]@{ NetworkInterfaces = @([pscustomobject]@{ Id = $script:nicId; Primary = $true; DeleteOption = $(if ($Bare) { $null } else { 'Delete' }) }) }
            Plan = $(if ($Bare) { $null } else { [pscustomobject]@{ Name = 'appliance-sku'; Publisher = 'contoso'; Product = 'contoso-appliance'; PromotionCode = $null } })
            OSProfile = $osProfile
            UserData = $(if ($Bare) { $null } else { 'aGVsbG8=' })
            Host = $(if ($Bare) { $null } else { [pscustomobject]@{ Id = $script:hostId } })
            HostGroup = $null
            Priority = $(if ($Bare) { $null } else { 'Spot' })
            EvictionPolicy = $(if ($Bare) { $null } else { 'Delete' })
            BillingProfile = $(if ($Bare) { $null } else { [pscustomobject]@{ MaxPrice = 0.05 } })
            AdditionalCapabilities = [pscustomobject]@{ UltraSSDEnabled = $false; HibernationEnabled = (-not $Bare) }
            Identity = $null; SecurityProfile = $null
            DiagnosticsProfile = [pscustomobject]@{ BootDiagnostics = [pscustomobject]@{ Enabled = $true; StorageUri = $(if ($Bare) { $null } else { 'https://contosodiag.blob.core.windows.net/' }) } }
            Zones = @(); Tags = @{}
        }
    }
    function Global:RpCapture([switch]$Bare, [string]$Os = 'Windows', [string]$PatchMode = 'AutomaticByPlatform') {
        $vm = RpVm -Bare:$Bare -Os $Os -PatchMode $PatchMode
        InModuleScope VmMigrationFactory -Parameters @{ vm = $vm } { param($vm) [pscustomobject](Get-VmfVmCapture -Vm $vm) | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20 }
    }
}
AfterAll { Remove-Item function:RpVm, function:RpCapture, 'function:\Get-AzVM' -ErrorAction SilentlyContinue }

Describe 'REBUILD-PROPS-1: the capture records every setting a rebuild puts back' {
    It 'NO-PLAN-SCOPE-1: records no purchase plan, even of a machine that has one' {
        $c = RpCapture
        $c.PSObject.Properties.Name | Should -Not -Contain 'purchasePlan'
    }

    It 'records the patch settings, Windows and Linux' {
        $w = (RpCapture).patchSettings
        $w.os | Should -Be 'Windows'
        $w.patchMode | Should -Be 'AutomaticByPlatform'
        $w.assessmentMode | Should -Be 'AutomaticByPlatform'
        $w.rebootSetting | Should -Be 'IfRequired'
        $w.bypassPlatformSafetyChecksOnUserSchedule | Should -BeTrue
        $l = (RpCapture -Os Linux).patchSettings
        $l.os | Should -Be 'Linux'
        $l.assessmentMode | Should -Be 'ImageDefault'
        $l.rebootSetting | Should -Be 'Never'
    }

    It 'records the Spot and user data settings' {
        $c = RpCapture
        $c.priority | Should -Be 'Spot'
        $c.evictionPolicy | Should -Be 'Delete'
        $c.maxPrice | Should -Be 0.05
        # Only THAT the machine has user data: the value is never written to
        # the run store, where every reader of the dashboard can read it.
        $c.userDataPresent | Should -BeTrue
        ($c | ConvertTo-Json -Depth 20) | Should -Not -Match 'aGVsbG8='
    }

    It 'records the OS disk caching and Write Accelerator, and each delete option' {
        $c = RpCapture
        $c.osDisk.caching | Should -Be 'ReadOnly'
        $c.osDisk.deleteOption | Should -Be 'Delete'
        $c.osDisk.writeAcceleratorEnabled | Should -BeFalse
        @($c.dataDisks)[0].writeAcceleratorEnabled | Should -BeFalse
        @($c.dataDisks)[0].deleteOption | Should -Be 'Delete'
        @($c.nics)[0].deleteOption | Should -Be 'Delete'
        $vm = RpVm
        $vm.StorageProfile.OsDisk.WriteAcceleratorEnabled = $true
        $vm.StorageProfile.DataDisks[0].WriteAcceleratorEnabled = $true
        $wa = InModuleScope VmMigrationFactory -Parameters @{ vm = $vm } { param($vm) Get-VmfVmCapture -Vm $vm }
        $wa.osDisk.writeAcceleratorEnabled | Should -BeTrue
        @($wa.dataDisks)[0].writeAcceleratorEnabled | Should -BeTrue
    }

    It 'a machine with none of them records none' {
        $c = RpCapture -Bare
        $c.patchSettings | Should -BeNullOrEmpty
        $c.userDataPresent | Should -BeFalse
        $c.evictionPolicy | Should -BeNullOrEmpty
        $c.maxPrice | Should -BeNullOrEmpty
        # Present and empty is "none"; absent is a capture from before this.
        $c.PSObject.Properties.Name | Should -Contain 'patchSettings'
    }

    It 'the machine read asks Azure for user data, or "none" could not be told from "not read"' {
        InModuleScope VmMigrationFactory {
            Mock Get-AzVM { [pscustomobject]@{ ud = [bool]$UserData } }
            (Get-VmfVmConfig -ResourceGroupName 'rg-app' -Name 'vm1').ud | Should -BeTrue
            (Get-VmfVmConfig -ResourceGroupName 'rg-app' -Name 'vm1' -AllowMissing).ud | Should -BeTrue
        }
    }
}

Describe 'NO-PLAN-SCOPE-1: the disk read still returns the disk''s purchase plan, for the stop at Checking' {
    It 'the disk read returns the disk''s purchase plan, and none when the disk has none' {
        InModuleScope VmMigrationFactory -Parameters @{ os = $script:osId } {
            param($os)
            Mock Invoke-AzRestMethod {
                [pscustomobject]@{ StatusCode = 200; Content = (@{ id = $os; sku = @{ name = 'Premium_LRS' }
                            properties = @{ provisioningState = 'Succeeded'; purchasePlan = @{ name = 'appliance-sku'; publisher = 'contoso'; product = 'contoso-appliance' } } } | ConvertTo-Json -Depth 6) } }
            $f = Get-VmfManagedDiskFacts -DiskId $os
            $f.purchasePlan.name | Should -Be 'appliance-sku'
            $f.purchasePlan.product | Should -Be 'contoso-appliance'
            Mock Invoke-AzRestMethod {
                [pscustomobject]@{ StatusCode = 200; Content = (@{ id = $os; sku = @{ name = 'Premium_LRS' }; properties = @{ provisioningState = 'Succeeded' } } | ConvertTo-Json -Depth 6) } }
            (Get-VmfManagedDiskFacts -DiskId $os).purchasePlan | Should -BeNullOrEmpty
        }
    }
}

# REBUILD-REMOVE-ROLE-1: the rebuild's create (New-VmfVmFromCapture, Get-VmfRebuildConfigExtras)
# and the patch settings after it (Set-VmfVmPatchSettings, Invoke-VmfRebuildPatchSettings)
# are gone with the last rebuild. Their tests were here. The capture and Verifying stay.

# REBUILD-REMOVE-ENGINE-1: the refusal at Checking of what a rebuild move could not keep went with the rebuild (Test-VmfCaptureReproducible, Get-VmfMoveRefusedSettings, Get-VmfCaptureFieldPolicy). Its tests were here.

# REBUILD-REMOVE-ENGINE-1: the move has no rebuild, so it sets no patch settings after one. Its tests were here.

Describe 'REBUILD-PROPS-1: Verifying compares every setting the rebuild put back' {
    It 'a machine that came back with every setting passes' {
        $cap = RpCapture
        $r = InModuleScope VmMigrationFactory -Parameters @{ cap = $cap; vm = (RpVm) } {
            param($cap, $vm) Test-VmfRebuildSettingsFidelity -Captured $cap -Live (Get-VmfRebuildSettingsFromVm -Vm $vm) }
        $r.Verdict | Should -Be 'MATCH'
        $r.Ok | Should -BeTrue
    }

    It 'reports <Name> that did not come back' -ForEach @(
        @{ Name = 'the patch settings'; Break = { param($v) $v.OSProfile = $null }; Words = 'patch' }
        @{ Name = 'the eviction policy'; Break = { param($v) $v.EvictionPolicy = 'Deallocate' }; Words = 'eviction policy' }
        @{ Name = 'the maximum price'; Break = { param($v) $v.BillingProfile = [pscustomobject]@{ MaxPrice = -1 } }; Words = 'maximum price' }
        @{ Name = 'the boot diagnostics storage account'; Break = { param($v) $v.DiagnosticsProfile.BootDiagnostics.StorageUri = $null }; Words = 'boot diagnostics' }
        @{ Name = 'the OS disk caching'; Break = { param($v) $v.StorageProfile.OsDisk.Caching = 'None' }; Words = 'caching' }
        @{ Name = 'the OS disk delete option'; Break = { param($v) $v.StorageProfile.OsDisk.DeleteOption = 'Detach' }; Words = 'delete option' }
        @{ Name = 'a data disk delete option'; Break = { param($v) $v.StorageProfile.DataDisks[0].DeleteOption = 'Detach' }; Words = 'LUN 0' }
        @{ Name = 'an interface delete option'; Break = { param($v) $v.NetworkProfile.NetworkInterfaces[0].DeleteOption = 'Detach' }; Words = 'vm1-nic' }
    ) {
        $cap = RpCapture
        $live = RpVm
        & $Break $live
        $r = InModuleScope VmMigrationFactory -Parameters @{ cap = $cap; vm = $live } {
            param($cap, $vm) Test-VmfRebuildSettingsFidelity -Captured $cap -Live (Get-VmfRebuildSettingsFromVm -Vm $vm) }
        $r.Ok | Should -BeFalse
        $r.Verdict | Should -Be 'MISMATCH'
        $r.Detail | Should -Match ([regex]::Escape($Words))
    }

    It 'reports lost encryption at host and lost Write Accelerator' {
        $cap = RpCapture
        $cap | Add-Member -NotePropertyName securityProfile -NotePropertyValue ([pscustomobject]@{ securityType = 'Standard'; encryptionAtHost = $true }) -Force
        $cap.osDisk.writeAcceleratorEnabled = $true
        $r = InModuleScope VmMigrationFactory -Parameters @{ cap = $cap; vm = (RpVm) } {
            param($cap, $vm) Test-VmfRebuildSettingsFidelity -Captured $cap -Live (Get-VmfRebuildSettingsFromVm -Vm $vm) }
        $r.Ok | Should -BeFalse
        $r.Detail | Should -Match 'encryption at host'
        $r.Detail | Should -Match 'Write Accelerator'
    }

    It 'NO-PLAN-SCOPE-1: a plan is not compared - a v31 to v33 capture that holds one still matches a machine without it' {
        $cap = RpCapture
        $cap | Add-Member -NotePropertyName purchasePlan -NotePropertyValue ([pscustomobject]@{ name = 'appliance-sku'; publisher = 'contoso'; product = 'contoso-appliance' }) -Force
        $live = RpVm
        $live.Plan = $null
        $r = InModuleScope VmMigrationFactory -Parameters @{ cap = $cap; vm = $live } {
            param($cap, $vm) Test-VmfRebuildSettingsFidelity -Captured $cap -Live (Get-VmfRebuildSettingsFromVm -Vm $vm) }
        $r.Verdict | Should -Be 'MATCH'
        $r.Detail | Should -Not -Match 'purchase plan'
    }

    # OLD-VERSION-READERS-REMOVE-4: every capture holds the fields, so a capture
    # without them fails the compare - never UNKNOWN, never a pass.
    It 'a capture with every field but no patch settings fails the compare' {
        $cap = RpCapture
        $cap.PSObject.Properties.Remove('patchSettings')
        $r = InModuleScope VmMigrationFactory -Parameters @{ cap = $cap; vm = (RpVm) } {
            param($cap, $vm) Test-VmfRebuildSettingsFidelity -Captured $cap -Live (Get-VmfRebuildSettingsFromVm -Vm $vm) }
        $r.Verdict | Should -Be 'MISMATCH'
        $r.Ok | Should -BeFalse
    }
    It 'a capture without these fields fails the compare' {
        $r = InModuleScope VmMigrationFactory -Parameters @{ vm = (RpVm) } {
            param($vm) Test-VmfRebuildSettingsFidelity -Captured ([pscustomobject]@{ name = 'vm1' }) -Live (Get-VmfRebuildSettingsFromVm -Vm $vm) }
        $r.Verdict | Should -Be 'MISMATCH'
        $r.Ok | Should -BeFalse
    }

    It 'Verifying asks it, and a mismatch fails the step' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1')
        $validating = [regex]::Match($code, '(?s)function Invoke-VmfStepValidating.*?\n\}').Value
        $validating | Should -Match 'Test-VmfRebuildSettingsFidelity'
        $validating | Should -Match 'if \(-not \$settingsCheck\.Ok\) \{ throw'
    }
}

Describe 'REBUILD-PROPS-1: a failed read is unknown, never "none"' {
    It 'a failed extension read throws, so the comparison is never skipped' {
        InModuleScope VmMigrationFactory {
            Mock Get-AzVMExtension { throw 'HTTP 503 Service Unavailable' }
            { Get-VmfVmExtensions -ResourceGroupName 'rg-app' -Name 'vm1' } | Should -Throw '*503*'
        }
    }

    It 'a machine with no extensions is still an empty list' {
        InModuleScope VmMigrationFactory {
            Mock Get-AzVMExtension { }
            $r = Get-VmfVmExtensions -ResourceGroupName 'rg-app' -Name 'vm1'
            @($r).Count | Should -Be 0
        }
    }

    It 'a failed lock read throws at Checking and at a restore, never "no locks"' {
        InModuleScope VmMigrationFactory {
            Mock Get-AzResourceLock { throw 'HTTP 429 Too Many Requests' }
            { Get-VmfVmResourceLocks -ResourceGroupName 'rg-app' -Name 'vm1' } | Should -Throw '*429*'
            { Get-VmfDeleteBlockingLocks -ResourceGroupName 'rg-app' -DiskName 'vm1-os' } | Should -Throw '*429*'
        }
    }

    It 'no read in these three functions swallows its error' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops' 'AzureOpsVm.ps1')
        foreach ($fn in 'Get-VmfVmExtensions', 'Get-VmfVmResourceLocks', 'Get-VmfDeleteBlockingLocks') {
            $body = [regex]::Match($code, "(?s)function $fn .*?\n\}").Value
            $body | Should -Not -BeNullOrEmpty -Because $fn
            $body | Should -Not -Match 'SilentlyContinue' -Because $fn
        }
    }
}

# REBUILD-REMOVE-RECOVER-1: the Describe of the restore that rebuilds is gone with it.
Describe 'REBUILD-PROPS-1: vm-state v31, the contract' {
    BeforeAll {
        $script:schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json') -Raw | ConvertFrom-Json
        $script:sample = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'vm-state.sample.json') -Raw | ConvertFrom-Json
    }

    It 'the schema, the writer and the sample are on the current version' {
        $script:schema.properties.schemaVersion.const | Should -Be 51
        InModuleScope VmMigrationFactory { $script:VmfStateDocSchemaVersion | Should -Be 51 }
        $script:sample.schemaVersion | Should -Be 51
    }

    It 'the schema describes every field the capture writes for this item' {
        $vmc = $script:schema.properties.captured.properties.vmConfig.properties
        foreach ($f in 'patchSettings', 'userDataPresent', 'evictionPolicy', 'maxPrice') {
            $vmc.PSObject.Properties.Name | Should -Contain $f
            [string]$vmc.$f.description | Should -Match 'REBUILD-PROPS-1 \(v31\)'
        }
        $os = $script:schema.'$defs'.capturedOsDisk.properties
        foreach ($f in 'caching', 'writeAcceleratorEnabled') { $os.PSObject.Properties.Name | Should -Contain $f }
        $os.PSObject.Properties.Name | Should -Not -Contain 'purchasePlan' -Because 'OLD-STATE-READERS-FINISH-1'
        $script:schema.'$defs'.capturedDataDisk.properties.PSObject.Properties.Name | Should -Contain 'writeAcceleratorEnabled'
    }

    It 'the sample shows the patch settings, and no purchase plan (NO-PLAN-SCOPE-1)' {
        $c = $script:sample.captured.vmConfig
        $c.patchSettings.patchMode | Should -Be 'AutomaticByPlatform'
        $c.osDisk.PSObject.Properties.Name | Should -Not -Contain 'purchasePlan'
    }

    It 'a document written now carries the current version' {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rp-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            $v = InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } {
                param($rp, $id)
                Initialize-VmfRun -RunPath $rp -RunId 'rp' | Out-Null
                New-VmfStateDoc -RunPath $rp -RunId 'rp' -VmId $id | Out-Null
                (Read-VmfStateDoc -RunPath $rp -VmId $id).schemaVersion
            }
            $v | Should -Be 51
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# VERIFY-HOST-HIBERNATION-UNUSED-1: a machine on a dedicated host, or with
# hibernation enabled, is outside the scope of this tool. Checking stops it
# untouched before the capture (Get-VmfHostHibernationStop,
# HostHibernationScope.Tests.ps1). So the capture does not record the host,
# the host group or hibernation, and Verifying does not compare them.
Describe 'VERIFY-HOST-HIBERNATION-UNUSED-1: no dedicated host, host group or hibernation in the capture or in Verifying' {
    BeforeAll {
        $script:vhSchema = Get-Content (Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json') -Raw | ConvertFrom-Json
        $script:vhSample = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'vm-state.sample.json') -Raw | ConvertFrom-Json
    }

    It 'the capture of a machine on a host, in a host group, with hibernation enabled records none of the three' {
        $vm = RpVm
        $vm.HostGroup = [pscustomobject]@{ Id = $script:hostGroupId }
        $c = InModuleScope VmMigrationFactory -Parameters @{ vm = $vm } { param($vm) [pscustomobject](Get-VmfVmCapture -Vm $vm) }
        foreach ($n in 'hostId', 'hostGroupId', 'hibernationEnabled') { $c.PSObject.Properties.Name | Should -Not -Contain $n }
    }

    It 'a machine off its host and with hibernation off after the move still matches' {
        $cap = RpCapture
        $live = RpVm
        $live.Host = $null
        $live.AdditionalCapabilities.HibernationEnabled = $false
        $r = InModuleScope VmMigrationFactory -Parameters @{ cap = $cap; vm = $live } {
            param($cap, $vm) Test-VmfRebuildSettingsFidelity -Captured $cap -Live (Get-VmfRebuildSettingsFromVm -Vm $vm) }
        $r.Verdict | Should -Be 'MATCH'
        $r.Detail | Should -Not -Match 'dedicated host|host group|hibernation'
    }

    It 'the comparison reads no host, host group or hibernation field' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'validate' 'RebuildSettings.ps1')
        $body = [regex]::Match($code, '(?s)function Test-VmfRebuildSettingsFidelity .*?\n\}').Value
        $body | Should -Not -BeNullOrEmpty
        $body | Should -Not -Match 'hostId|hostGroupId|hibernationEnabled'
    }

    It 'the words of a match name what Verifying compares, and say no placement' {
        $cap = RpCapture
        $r = InModuleScope VmMigrationFactory -Parameters @{ cap = $cap; vm = (RpVm) } {
            param($cap, $vm) Test-VmfRebuildSettingsFidelity -Captured $cap -Live (Get-VmfRebuildSettingsFromVm -Vm $vm) }
        $r.Detail | Should -Be 'No machine setting changed.'
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'validate' 'RebuildSettings.ps1')
        $code | Should -Not -Match 'placement'
    }

    It 'the schema holds none of the three fields, and the sample shows none' {
        $vmc = $script:vhSchema.properties.captured.properties.vmConfig.properties.PSObject.Properties.Name
        $have = $script:vhSample.captured.vmConfig.PSObject.Properties.Name
        foreach ($n in 'hostId', 'hostGroupId', 'hibernationEnabled') {
            $vmc | Should -Not -Contain $n
            $have | Should -Not -Contain $n
        }
    }

    It 'the Checking stop still reads the host, the host group and hibernation from the machine' {
        $vm = RpVm
        $s = InModuleScope VmMigrationFactory -Parameters @{ vm = $vm } { param($vm) Get-VmfHostHibernationStop -Vm $vm }
        $s.Reason | Should -Be 'dedicatedHost'
        $vm.Host = $null
        $s = InModuleScope VmMigrationFactory -Parameters @{ vm = $vm } { param($vm) Get-VmfHostHibernationStop -Vm $vm }
        $s.Reason | Should -Be 'hibernationEnabled'
    }
}
