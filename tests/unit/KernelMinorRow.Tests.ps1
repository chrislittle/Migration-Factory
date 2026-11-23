#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# KERNEL-MINOR-ROW-1 (2026-11-21): an interim Ubuntu release was judged by the
# kernel row of the LTS release below it.
#
# Microsoft's MANA table (Accelerated Networking overview, pinned in
# docs/upstream-docs) lists Ubuntu 22.04, 24.04 and 26.04 only - each an LTS
# release with its own kernel series. Find-VmfManaTableEntry took the row of
# the same major with the highest minor at or below the machine's, for every
# distribution: Ubuntu 24.10 got the 24.04 row, so the product said Microsoft
# lists it, and compared its kernel with 6.8.0-1041.47. An Ubuntu version is
# YY.MM, not major.minor: 24.10 is a release of its own, not an update of
# 24.04.
#
# The rule now: a later minor release is covered by an earlier row only on a
# distribution named in coveredByEarlierRow (data/driver-floors.json): Red Hat
# and its rebuilds (Red Hat 9.8 by the 9.6 row - measured, it got MANA), and
# SUSE service packs (the rule as it was). Any other distribution takes a row
# only for its exact release. An Ubuntu release with no row is a release
# Microsoft does not list, as Ubuntu 20.04 is.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    $script:floorsPath = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'driver-floors.json'
}

Describe 'KERNEL-MINOR-ROW-1: the MANA table row of a release' {

    It 'an interim Ubuntu release <Version> has no row (Microsoft lists LTS releases only)' -ForEach @(
        @{ Version = '24.10' }
        @{ Version = '22.10' }
        @{ Version = '26.10' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ v = $Version } {
            Find-VmfManaTableEntry -DistroId 'ubuntu' -DistroVersion $v -Kernel '6.11.0-1015-azure' | Should -BeNullOrEmpty
        }
    }

    It 'an Ubuntu release the table names keeps its own row' {
        InModuleScope VmMigrationFactory {
            (Find-VmfManaTableEntry -DistroId 'ubuntu' -DistroVersion '24.04' -Kernel '6.8.0-1041-azure').minKernel | Should -Be '6.8.0-1041.47'
            (Find-VmfManaTableEntry -DistroId 'ubuntu' -DistroVersion '22.04' -Kernel '5.15.0-1096-azure').versionId | Should -Be '22.04'
            (Find-VmfManaTableEntry -DistroId 'ubuntu' -DistroVersion '26.04' -Kernel '7.0.0-14-azure').versionId | Should -Be '26.04'
        }
    }

    It 'Red Hat and its rebuilds keep the covering row, and the row reached by an update' {
        InModuleScope VmMigrationFactory {
            (Find-VmfManaTableEntry -DistroId 'rhel' -DistroVersion '9.8' -Kernel '5.14.0-687.30.1.el9_8.x86_64').versionId | Should -Be '9.6'
            (Find-VmfManaTableEntry -DistroId 'rhel' -DistroVersion '9.7' -Kernel '5.14.0-611.5.1.el9_7.x86_64').versionId | Should -Be '9.6'
            (Find-VmfManaTableEntry -DistroId 'rocky' -DistroVersion '9.7' -Kernel '5.14.0-611.5.1.el9_7.x86_64').versionId | Should -Be '9.6'
            (Find-VmfManaTableEntry -DistroId 'almalinux' -DistroVersion '10.1' -Kernel '6.12.0-124.el10.x86_64').versionId | Should -Be '10.0'
            (Find-VmfManaTableEntry -DistroId 'rhel' -DistroVersion '9.5' -Kernel '5.14.0-503.11.1.el9_5.x86_64').versionId | Should -Be '9.6' -Because 'minorReachedByUpdate: the lowest row of its major above it'
        }
    }

    It 'a later SUSE service pack keeps the covering row, as before' {
        InModuleScope VmMigrationFactory {
            (Find-VmfManaTableEntry -DistroId 'sles' -DistroVersion '15.8' -Kernel '6.4.0-150800.1').versionId | Should -Be '15.7'
        }
    }

    It 'a distribution not named in coveredByEarlierRow takes a row only for its exact release' {
        InModuleScope VmMigrationFactory -Parameters @{ path = $script:floorsPath } {
            $f = Get-Content $path -Raw | ConvertFrom-Json
            $f.mana.linux.distros = @(@($f.mana.linux.distros) + [pscustomobject]@{ id = 'newdistro'; versionId = '5.2'; kernelSeries = '6.6'; minKernel = '6.6.10' })
            (Find-VmfManaTableEntry -DistroId 'newdistro' -DistroVersion '5.2' -Kernel '6.6.20' -Floors $f).versionId | Should -Be '5.2'
            Find-VmfManaTableEntry -DistroId 'newdistro' -DistroVersion '5.4' -Kernel '6.6.20' -Floors $f | Should -BeNullOrEmpty
            # And the same table with the distribution named: covered.
            $f.mana.linux.coveredByEarlierRow.ids = @(@($f.mana.linux.coveredByEarlierRow.ids) + 'newdistro')
            (Find-VmfManaTableEntry -DistroId 'newdistro' -DistroVersion '5.4' -Kernel '6.6.20' -Floors $f).versionId | Should -Be '5.2'
        }
    }

    It 'the data names Red Hat, its rebuilds and SUSE, and not Ubuntu' {
        $f = Get-Content $script:floorsPath -Raw | ConvertFrom-Json
        $ids = @($f.mana.linux.coveredByEarlierRow.ids)
        $ids | Should -Contain 'rhel'
        $ids | Should -Contain 'rocky'
        $ids | Should -Contain 'almalinux'
        $ids | Should -Contain 'sles'
        $ids | Should -Not -Contain 'ubuntu'
        [string]$f.mana.linux.coveredByEarlierRow.note | Should -Match 'KERNEL-MINOR-ROW-1'
    }
}

Describe 'KERNEL-MINOR-ROW-1: what the product does with Ubuntu 24.10' {

    It 'the judgement is UNKNOWN (no floor to compare with), not a pass against the 24.04 row' {
        InModuleScope VmMigrationFactory {
            $facts = [pscustomobject]@{ os = 'Linux'; distroId = 'ubuntu'; distroVersion = '24.10'; kernelVersion = '6.11.0-1015-azure' }
            $j = Get-VmfDriverJudgement -Facts $facts
            $j.Status | Should -Be 'UNKNOWN'
            $j.Detail | Should -Match 'not listed'
        }
    }

    It 'a kernel with the module is unlisted, as on Ubuntu 20.04' {
        InModuleScope VmMigrationFactory {
            $out = [pscustomobject]@{ checks = @([pscustomobject]@{ name = 'mana module available'; status = 'PASS' }) }
            Get-VmfManaDriverPresence -GuestOutput $out -Os 'Linux' -Facts ([pscustomobject]@{ distroId = 'ubuntu'; distroVersion = '24.10'; kernelVersion = '6.11.0-1015-azure' }) | Should -Be 'unlisted'
        }
    }

    It 'the release the VM agent reports is unlisted, and the upgrade it names is 26.04' {
        $vm = [pscustomobject]@{
            vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/m'
            name = 'm'; os = 'Linux'; osVersion = 'server'; imagePublisher = 'Canonical'; imageOffer = 'ubuntu-24_04-lts'; imageId = ''
            runningOsName = 'ubuntu'; runningOsVersion = '24.10'
        }
        InModuleScope VmMigrationFactory -Parameters @{ v = $vm } {
            $r = Get-VmfLinuxRelease -Vm $v
            $r.source | Should -Be 'agent'
            $r.version | Should -Be '24.10'
            Get-VmfManaReleaseListing -Release $r | Should -Be 'unlisted'
            Test-VmfReleaseKnownUnlisted -Vm $v | Should -BeTrue
            (Get-VmfManaUpgradeRelease -Release $r).version | Should -Be '26.04'
        }
    }

    It 'Ubuntu 24.04 from the agent is still listed' {
        InModuleScope VmMigrationFactory {
            Get-VmfManaReleaseListing -Release @{ distroId = 'ubuntu'; version = '24.04'; source = 'agent' } | Should -Be 'listed'
        }
    }
}
