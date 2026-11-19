#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# RHEL-EUS-SKU-LIST-1: Get-VmfImageRelease reads every SKU of the RedHat RHEL
# marketplace offer that Azure listed on 2026-11-11 (az vm image list --offer
# RHEL --all -p RedHat, docs/research/rhel-image-skus.md). The table there is
# the one source: each row is a SKU and the release the reader must give - the
# minor release where the SKU has one (Microsoft: an image on the EUS
# repositories has a minor version in its SKU), the major only for an LVM SKU.
# The image versions of each SKU (<major>.<minor>.<date>) are the proof of the
# expected release. Before this item, 100-gen2 read as 1.00, 101-gen2 as 1.01,
# and 7lvm-gen2 as no release.

BeforeDiscovery {
    $script:tablePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' 'docs' 'research' 'rhel-image-skus.md'))
    $script:rows = @(Get-Content $script:tablePath | Where-Object { $_ -match '^\| `([^`]+)` \| ([0-9., ]+) \| ([0-9.]+) \|$' } | ForEach-Object {
            @{ Sku = $Matches[1]; Versions = $Matches[2]; Expected = $Matches[3] }
        })
}

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    function Global:RisRead([string]$Sku) {
        InModuleScope VmMigrationFactory -Parameters @{ s = $Sku } { Get-VmfImageRelease -Publisher 'RedHat' -Offer 'RHEL' -Sku $s }
    }
}

AfterAll { Remove-Item 'Function:\RisRead' -ErrorAction SilentlyContinue }

Describe 'RHEL-EUS-SKU-LIST-1: every SKU of RedHat RHEL that Azure lists' {

    It 'the table holds the 50 SKUs of the list' -ForEach @(@{ Count = $script:rows.Count }) {
        $Count | Should -Be 50
    }

    It 'the expected release of <Sku> agrees with its image versions (<Versions>)' -ForEach $script:rows {
        $versions = @($Versions -split ',\s*')
        if ($Sku -match '(?i)lvm') {
            $Expected | Should -Not -Match '\.' -Because 'an LVM SKU holds several minor releases'
            @($versions | Where-Object { ($_ -split '\.')[0] -ne $Expected }).Count | Should -Be 0
        } else {
            $versions | Should -HaveCount 1 -Because 'a SKU with a minor version holds one minor release'
            $Expected | Should -BeExactly $versions[0]
        }
    }

    It 'the SKU <Sku> reads as RHEL <Expected>' -ForEach $script:rows {
        $r = RisRead $Sku
        $r | Should -Not -BeNullOrEmpty -Because "Azure lists RedHat:RHEL:$Sku"
        $r.distroId | Should -BeExactly 'rhel'
        $r.version | Should -BeExactly $Expected
    }

    It 'a SKU that is not a release still reads as none: <Sku>' -ForEach @(
        @{ Sku = 'rhel-raw' }, @{ Sku = 'gen2' }, @{ Sku = '' }
    ) {
        RisRead $Sku | Should -BeNullOrEmpty
    }
}
