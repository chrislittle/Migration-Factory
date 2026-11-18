#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# EVAL-C1 (critical) and EVAL-H2 (high), from the 2026-08-28 self-evaluation.
#
# The Path B rebuild replays a hand-maintained list of properties from the
# capture. Managed identity was captured and never read - one write, zero reads
# - so a rebuilt machine came back with none, and nothing compared. That loss
# is IRREVERSIBLE: deleting the VM destroys its system-assigned service
# principal, and re-enabling identity mints a new principal id, orphaning every
# role assignment and Key Vault policy that named the old one. Ultra Disk was
# the same defect in a different property, and it fails the PUT after the shell
# is already deleted.
#
# Ruled: fix both, AND refuse to start a Path B machine carrying a
# property the rebuild cannot put back.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
}

Describe 'EVAL-C1: the capture records enough to put an identity back' {
    It 'records the type AND the assigned identity ids' {
        # The type alone can never rebuild a user-assigned identity.
        InModuleScope VmMigrationFactory {
            $vm = [pscustomobject]@{
                Id = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
                Name = 'vm1'; Location = 'centralus'
                HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_D2ds_v4' }
                StorageProfile = [pscustomobject]@{
                    DiskControllerType = 'SCSI'
                    OsDisk = [pscustomobject]@{ Name = 'osdisk'; OsType = 'Linux'
                        ManagedDisk = [pscustomobject]@{ Id = '/disks/osdisk'; StorageAccountType = 'Premium_LRS' } }
                    DataDisks = @(); ImageReference = $null }
                NetworkProfile = [pscustomobject]@{ NetworkInterfaces = @() }
                Identity = [pscustomobject]@{
                    Type = 'SystemAssignedUserAssigned'
                    UserAssignedIdentities = @{ '/subscriptions/s/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/mi-app' = @{} }
                }
                AdditionalCapabilities = [pscustomobject]@{ UltraSSDEnabled = $true }
                Zones = @(); Tags = @{}
            }
            $cap = Get-VmfVmCapture -Vm $vm
            $cap.identity.type | Should -Be 'SystemAssignedUserAssigned'
            @($cap.identity.userAssignedIds).Count | Should -Be 1
            @($cap.identity.userAssignedIds)[0] | Should -Match 'mi-app'
            $cap.ultraSsdEnabled | Should -BeTrue
        }
    }

    It 'a machine with no identity records none, rather than an empty shape' {
        InModuleScope VmMigrationFactory {
            $vm = [pscustomobject]@{
                Id = '/x'; Name = 'vm2'; Location = 'centralus'
                HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_D2s_v4' }
                StorageProfile = [pscustomobject]@{ DiskControllerType = 'SCSI'
                    OsDisk = [pscustomobject]@{ Name = 'd'; OsType = 'Linux'; ManagedDisk = [pscustomobject]@{ Id = '/disks/d'; StorageAccountType = 'Premium_LRS' } }
                    DataDisks = @(); ImageReference = $null }
                NetworkProfile = [pscustomobject]@{ NetworkInterfaces = @() }
                Identity = $null; AdditionalCapabilities = $null; Zones = @(); Tags = @{}
            }
            $cap = Get-VmfVmCapture -Vm $vm
            $cap.identity | Should -BeNullOrEmpty
            $cap.ultraSsdEnabled | Should -BeFalse
        }
    }
}

# REBUILD-REMOVE-ROLE-1: the rebuild's create and its extras (Get-VmfRebuildConfigExtras)
# are gone. The capture and the comparison in Verifying stay.

Describe 'EVAL-C1/H2: the next dropped property fails validation instead of passing' {
    It 'reports a lost identity in words an operator can act on' {
        InModuleScope VmMigrationFactory {
            $captured = [pscustomobject]@{ identity = [pscustomobject]@{ type = 'SystemAssigned'; userAssignedIds = @() }; ultraSsdEnabled = $false }
            $live = [pscustomobject]@{ identityType = ''; userAssignedIds = @(); ultraSsdEnabled = $false }
            $r = Test-VmfRebuildFidelity -Captured $captured -Live $live
            $r.Ok | Should -BeFalse
            $r.Verdict | Should -Be 'MISMATCH'
            $r.Detail | Should -Match "was 'SystemAssigned' before the move"
        }
    }

    It 'reports a lost user-assigned identity by name' {
        InModuleScope VmMigrationFactory {
            $captured = [pscustomobject]@{ identity = [pscustomobject]@{ type = 'UserAssigned'
                userAssignedIds = @('/subscriptions/s/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/mi-app') }; ultraSsdEnabled = $false }
            $live = [pscustomobject]@{ identityType = 'UserAssigned'; userAssignedIds = @(); ultraSsdEnabled = $false }
            $r = Test-VmfRebuildFidelity -Captured $captured -Live $live
            $r.Ok | Should -BeFalse
            $r.Detail | Should -Match 'mi-app'
        }
    }

    It 'reports lost Ultra Disk capability' {
        InModuleScope VmMigrationFactory {
            $r = Test-VmfRebuildFidelity `
                -Captured ([pscustomobject]@{ identityType = $null; ultraSsdEnabled = $true }) `
                -Live ([pscustomobject]@{ identityType = ''; ultraSsdEnabled = $false })
            $r.Ok | Should -BeFalse
            $r.Detail | Should -Match '(?i)ultra'
        }
    }

    It 'a machine that came back whole passes' {
        # IDENTITY-2: the capture and the live read now carry the PRINCIPAL, so
        # this fixture states the same one on both sides. Before, comparing the
        # type alone made this pass for a rebuilt machine whose identity really
        # had changed - which was the defect.
        InModuleScope VmMigrationFactory {
            $captured = [pscustomobject]@{
                identity = [pscustomobject]@{ type = 'SystemAssigned'; userAssignedIds = @(); principalId = 'aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb' }
                ultraSsdEnabled = $true }
            $live = [pscustomobject]@{ identityType = 'SystemAssigned'; userAssignedIds = @()
                identityPrincipalId = 'aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb'; ultraSsdEnabled = $true }
            $r = Test-VmfRebuildFidelity -Captured $captured -Live $live
            $r.Ok | Should -BeTrue
            $r.Verdict | Should -Be 'MATCH'
        }
    }

    It 'IDENTITY-2: a rebuilt system-assigned identity is a MISMATCH, not a match' {
        # The whole point. Same type, different principal - which is exactly
        # what a Path B rebuild produces, and what used to report MATCH.
        InModuleScope VmMigrationFactory {
            $captured = [pscustomobject]@{
                identity = [pscustomobject]@{ type = 'SystemAssigned'; userAssignedIds = @(); principalId = 'old-1111-2222-3333-444444444444' }
                ultraSsdEnabled = $false }
            $live = [pscustomobject]@{ identityType = 'SystemAssigned'; userAssignedIds = @()
                identityPrincipalId = 'new-9999-8888-7777-666666666666'; ultraSsdEnabled = $false }
            $r = Test-VmfRebuildFidelity -Captured $captured -Live $live
            $r.Verdict | Should -Be 'MISMATCH'
            $r.Ok | Should -BeFalse
            $r.Detail | Should -Match 'NEW one'
            $r.Detail | Should -Match 'old-1111'
            $r.Detail | Should -Match 'no longer trusts'
        }
    }

    It 'IDENTITY-2: an unrecorded principal is UNKNOWN, never a pass' {
        InModuleScope VmMigrationFactory {
            $captured = [pscustomobject]@{ identity = [pscustomobject]@{ type = 'SystemAssigned'; userAssignedIds = @() }; ultraSsdEnabled = $false }
            $live = [pscustomobject]@{ identityType = 'SystemAssigned'; userAssignedIds = @(); ultraSsdEnabled = $false }
            $r = Test-VmfRebuildFidelity -Captured $captured -Live $live
            $r.Verdict | Should -Be 'UNKNOWN'
            $r.Detail | Should -Match 'kept the same identity'
        }
    }

    It 'IDENTITY-2: a USER-assigned identity is genuinely reproduced and still matches' {
        InModuleScope VmMigrationFactory {
            $uid = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/mi1'
            $captured = [pscustomobject]@{ identity = [pscustomobject]@{ type = 'UserAssigned'; userAssignedIds = @($uid) }; ultraSsdEnabled = $false }
            $live = [pscustomobject]@{ identityType = 'UserAssigned'; userAssignedIds = @($uid); ultraSsdEnabled = $false }
            (Test-VmfRebuildFidelity -Captured $captured -Live $live).Verdict | Should -Be 'MATCH'
        }
    }
}

# REBUILD-REMOVE-ENGINE-1: the refusal of what a rebuild could not put back went with the rebuild (Test-VmfIdentityReproducible, Test-VmfCaptureReproducible, Get-VmfCaptureFieldPolicy). Its tests were here.
