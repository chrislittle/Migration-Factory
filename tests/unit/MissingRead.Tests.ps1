#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# MISSING-READ-1: a failed read of a machine or a disk was taken as "it is not
# there".
#
# Five reads used -ErrorAction SilentlyContinue, so a throttle, a 5xx or a
# reset socket read the same as "not there":
#   - Get-VmfVmConfig -AllowMissing: the rollback's getVmForRollback. A failed
#     read was "no definition", so the rollback did not delete the machine and
#     rebuilt it with New-AzVM over a definition that was still there.
#   - Test-VmfVmExists: a failed read was $false ("gone").
#   - Get-VmfVmSize: a failed read was an empty size.
#   - Get-VmfManagedDiskState: a failed read was "the disk no longer exists",
#     which Rebuild this machine said to the person as a fact. It went with
#     Rebuild this machine (REBUILD-REMOVE-ROLE-1 removed the read).
#   - New-VmfDiskFromSnapshot: the read of a disk of that name before it makes
#     one - a failed read made a disk over one it could not see.
#
# THE RULE (the shape Test-VmfAdeExtension and Get-VmfManagedDiskAttachment
# already had): "not there" only for a real NotFound, and a throw for any other
# failure. Test-VmfAzNotFound is that one test, moved out of the encryption
# read unchanged.
#
# The stand-ins below fail the way an Az cmdlet does: a NON-terminating error
# (Write-Error), which -ErrorAction SilentlyContinue swallows and -ErrorAction
# Stop turns into a throw. A stand-in that used `throw` would test nothing - a
# terminating error passes through SilentlyContinue whatever the read asked.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    # CI has no Az modules: stand-ins with the parameters the reads use, so the
    # mocks below have a command to replace.
    function Global:Get-AzVM { [CmdletBinding()] param($ResourceGroupName, $Name, [switch]$UserData, [switch]$Status) throw 'stub' }
    function Global:Get-AzDisk { [CmdletBinding()] param($ResourceGroupName, $DiskName) throw 'stub' }
    function Global:New-AzDiskConfig { [CmdletBinding()] param($Location, $CreateOption, $SourceResourceId, $SkuName, $Zone, $DiskIOPSReadWrite, $DiskMBpsReadWrite, $EncryptionType, $DiskEncryptionSetId) throw 'stub' }
    function Global:New-AzDisk { [CmdletBinding()] param($ResourceGroupName, $DiskName, $Disk) throw 'stub' }
    # TEST-AZURE-GUARD-1: the guard comes AFTER the stand-ins above.
    Block-VmfAzureCalls -TestFile $PSCommandPath

    # Azure's words for each answer. Redacted: names are placeholders.
    $script:notFoundVm = "The Resource 'Microsoft.Compute/virtualMachines/vm1' under resource group 'rg-app' was not found. ErrorCode: ResourceNotFound"
    $script:notFoundDisk = "Resource 'vm1-os' was not found. ErrorCode: ResourceNotFound"
    $script:noGroup = "Resource group 'rg-app' could not be found. ErrorCode: ResourceGroupNotFound"
    $script:unavailable = "Operation returned an invalid status code 'ServiceUnavailable'. StatusCode: 503"
    $script:throttled = "Operation returned an invalid status code 'TooManyRequests'. StatusCode: 429"
    $script:refused = "The client does not have authorization to perform action 'Microsoft.Compute/virtualMachines/read'. ErrorCode: AuthorizationFailed"

    $script:diskId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/disks/vm1-os'
    $script:snapId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/snapshots/vm1-pristine'
}
AfterAll {
    Remove-Item 'function:\Get-AzVM', 'function:\Get-AzDisk', 'function:\New-AzDiskConfig', 'function:\New-AzDisk' -ErrorAction SilentlyContinue
}

Describe 'MISSING-READ-1: one test of "Azure says it is not there"' {
    It 'a NotFound is "not there"' {
        InModuleScope VmMigrationFactory -Parameters @{ m = $script:notFoundVm } {
            param($m)
            $e = $null; try { throw $m } catch { $e = $_ }
            Test-VmfAzNotFound -ErrorRecord $e | Should -BeTrue
        }
    }

    It 'a missing resource group is "not there" too' {
        InModuleScope VmMigrationFactory -Parameters @{ m = $script:noGroup } {
            param($m)
            $e = $null; try { throw $m } catch { $e = $_ }
            Test-VmfAzNotFound -ErrorRecord $e | Should -BeTrue
        }
    }

    It 'a 503, a throttle and a refused permission are not an answer' {
        InModuleScope VmMigrationFactory -Parameters @{ ms = @($script:unavailable, $script:throttled, $script:refused) } {
            param($ms)
            foreach ($m in $ms) {
                $e = $null; try { throw $m } catch { $e = $_ }
                Test-VmfAzNotFound -ErrorRecord $e | Should -BeFalse -Because $m
            }
        }
    }

    It 'the encryption check has no read of its own: it reads the extension list, which throws on any failure' {
        # ADE-DETECT-ANY-NAME-1: Test-VmfAdeExtension reads the list Checking
        # already read (Read-VmfPrecheckExtensions stops on a failed read), so
        # no "not found" is ever taken as "not encrypted".
        $ops = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops' 'AzureOpsVm.ps1')
        $ops | Should -Not -Match 'function Test-VmfAdeExtension'
        $list = [regex]::Match($ops, '(?s)function Get-VmfVmExtensions \{.*?\n\}').Value
        $list | Should -Match 'ErrorAction Stop'
        $list | Should -Not -Match 'SilentlyContinue'
        $eng = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'PrecheckExtensions.ps1')
        $ade = [regex]::Match($eng, '(?s)function Test-VmfAdeExtension \{.*?\n\}').Value
        $ade | Should -Not -BeNullOrEmpty
        $ade | Should -Not -Match 'Get-AzVMExtension|not \?found'
    }
}

Describe 'MISSING-READ-1: each read says "not there" only for a NotFound, and throws on any other failure' {
    It 'no read named in the item asks Azure with SilentlyContinue' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops' 'AzureOpsVm.ps1')
        foreach ($fn in 'Get-VmfVmConfig', 'Test-VmfVmExists', 'Get-VmfVmSize', 'New-VmfDiskFromSnapshot') {
            $body = [regex]::Match($code, "(?s)function $fn \{.*?\n\}").Value
            $body | Should -Not -BeNullOrEmpty -Because "$fn is in the file"
            $body | Should -Not -Match 'SilentlyContinue' -Because "$fn must tell a NotFound from no answer"
        }
    }

    Context 'Get-VmfVmConfig -AllowMissing (the rollback asks it whether the definition is there)' {
        It 'a NotFound is no definition' {
            InModuleScope VmMigrationFactory -Parameters @{ m = $script:notFoundVm } {
                param($m)
                Mock Get-AzVM { Write-Error -Message $m }
                Get-VmfVmConfig -ResourceGroupName 'rg-app' -Name 'vm1' -AllowMissing | Should -BeNullOrEmpty
            }
        }
        It 'a 503 throws' {
            InModuleScope VmMigrationFactory -Parameters @{ m = $script:unavailable } {
                param($m)
                Mock Get-AzVM { Write-Error -Message $m }
                { Get-VmfVmConfig -ResourceGroupName 'rg-app' -Name 'vm1' -AllowMissing } | Should -Throw '*ServiceUnavailable*'
            }
        }
        It 'a machine that is there is returned' {
            InModuleScope VmMigrationFactory {
                Mock Get-AzVM { [pscustomobject]@{ Name = 'vm1' } }
                (Get-VmfVmConfig -ResourceGroupName 'rg-app' -Name 'vm1' -AllowMissing).Name | Should -Be 'vm1'
            }
        }
    }

    Context 'Test-VmfVmExists' {
        It 'a NotFound is $false' {
            InModuleScope VmMigrationFactory -Parameters @{ m = $script:notFoundVm } {
                param($m)
                Mock Get-AzVM { Write-Error -Message $m }
                Test-VmfVmExists -ResourceGroupName 'rg-app' -Name 'vm1' | Should -BeFalse
            }
        }
        It 'a 503 throws' {
            InModuleScope VmMigrationFactory -Parameters @{ m = $script:unavailable } {
                param($m)
                Mock Get-AzVM { Write-Error -Message $m }
                { Test-VmfVmExists -ResourceGroupName 'rg-app' -Name 'vm1' } | Should -Throw '*ServiceUnavailable*'
            }
        }
        It 'a machine that is there is $true' {
            InModuleScope VmMigrationFactory {
                Mock Get-AzVM { [pscustomobject]@{ Name = 'vm1' } }
                Test-VmfVmExists -ResourceGroupName 'rg-app' -Name 'vm1' | Should -BeTrue
            }
        }
    }

    Context 'Get-VmfVmSize' {
        It 'a NotFound is no size' {
            InModuleScope VmMigrationFactory -Parameters @{ m = $script:notFoundVm } {
                param($m)
                Mock Get-AzVM { Write-Error -Message $m }
                Get-VmfVmSize -ResourceGroupName 'rg-app' -Name 'vm1' | Should -BeNullOrEmpty
            }
        }
        It 'a 503 throws' {
            InModuleScope VmMigrationFactory -Parameters @{ m = $script:unavailable } {
                param($m)
                Mock Get-AzVM { Write-Error -Message $m }
                { Get-VmfVmSize -ResourceGroupName 'rg-app' -Name 'vm1' } | Should -Throw '*ServiceUnavailable*'
            }
        }
        It 'a machine that is there gives its size' {
            InModuleScope VmMigrationFactory {
                Mock Get-AzVM { [pscustomobject]@{ HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_D2s_v4' } } }
                Get-VmfVmSize -ResourceGroupName 'rg-app' -Name 'vm1' | Should -Be 'Standard_D2s_v4'
            }
        }
    }

    Context 'New-VmfDiskFromSnapshot (the read of a disk of that name before it makes one)' {
        It 'a NotFound makes the disk' {
            InModuleScope VmMigrationFactory -Parameters @{ m = $script:notFoundDisk; snap = $script:snapId } {
                param($m, $snap)
                Mock Get-AzDisk { Write-Error -Message $m }
                Mock New-AzDiskConfig { [pscustomobject]@{} }
                Mock New-AzDisk { [pscustomobject]@{ Id = '/disks/vm1-os-r' } }
                New-VmfDiskFromSnapshot -ResourceGroupName 'rg-app' -DiskName 'vm1-os-r' -SnapshotId $snap -Location 'centralus' | Should -Be '/disks/vm1-os-r'
                Should -Invoke New-AzDisk -Times 1 -Exactly
            }
        }
        It 'a 503 throws, and makes no disk' {
            InModuleScope VmMigrationFactory -Parameters @{ m = $script:unavailable; snap = $script:snapId } {
                param($m, $snap)
                Mock Get-AzDisk { Write-Error -Message $m }
                Mock New-AzDiskConfig { [pscustomobject]@{} }
                Mock New-AzDisk { [pscustomobject]@{ Id = '/disks/vm1-os-r' } }
                { New-VmfDiskFromSnapshot -ResourceGroupName 'rg-app' -DiskName 'vm1-os-r' -SnapshotId $snap -Location 'centralus' } | Should -Throw '*ServiceUnavailable*'
                Should -Invoke New-AzDisk -Times 0 -Exactly
            }
        }
        It 'a disk of that name made from this copy is returned, and none is made' {
            InModuleScope VmMigrationFactory -Parameters @{ snap = $script:snapId } {
                param($snap)
                Mock Get-AzDisk { [pscustomobject]@{ Id = '/disks/vm1-os-r'; CreationData = [pscustomobject]@{ SourceResourceId = $snap }; Zones = @() } }
                Mock New-AzDisk { throw 'must not be called' }
                New-VmfDiskFromSnapshot -ResourceGroupName 'rg-app' -DiskName 'vm1-os-r' -SnapshotId $snap -Location 'centralus' | Should -Be '/disks/vm1-os-r'
            }
        }
    }
}
