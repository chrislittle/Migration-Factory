#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# DRIFT-13 (upstream drift issue 976): seven Microsoft pages changed.
#
# What a rule here reads from them, proven against the pinned text in
# docs/upstream-docs/ (re-pinned 2026-11-20):
#
# - The Azure Linux page no longer says Azure Linux 4.0 is in preview, and the
#   endorsed distributions page now lists Azure Linux. The support list said
#   "Microsoft says that Azure Linux 4.0 is in preview", which is now false.
#   The product still does not move the machine: nvme-fix.sh has no branch for
#   the os-release ID azurelinux (AZURE-LINUX-3-SUPPORT-1 owns that work). So
#   the reason now says the fact that holds the machine, and support stays
#   unsupported.
# - The D and E family pages gained the Arm64 Cobalt 200 v7 series (Dpsv7,
#   Dpdsv7, Dplsv7, Dpldsv7, Epsv7, Epdsv7). Arm is outside the scope: no such
#   size is ever a target, and the size list Microsoft names is not asked about
#   them (it covers Intel and AMD only).
# - The Eb v6 pages lowered the remote disk throughput (14,000 to 12,500 MBps).
#   No rule reads it.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    $script:pages = Join-Path $script:repoRoot 'docs' 'upstream-docs' 'azure'
    $script:matrix = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'supported-images.json') -Raw | ConvertFrom-Json
    $script:al = @($script:matrix.publishers | Where-Object { $_.publisher -eq 'microsoftazurelinux' })
}

Describe 'DRIFT-13: the Azure Linux reason says the fact that holds the machine, not a preview' {
    It 'the pinned Azure Linux page no longer says preview, and says Azure Linux 4.0 only supports Generation 2' {
        $text = Get-Content (Join-Path $script:pages 'azure-linux' 'azure-linux-vm-vmss-overview.md') -Raw
        $text | Should -Not -Match '(?i)preview'
        $text | Should -Match 'Azure Linux 4\.0 only supports Generation 2 VMs'
        $text | Should -Match 'microsoftazurelinux:azurelinux-4:4:latest'
    }

    It 'the pinned endorsed distributions page lists Azure Linux with the azurelinux-4 offer' {
        $text = Get-Content (Join-Path $script:pages 'virtual-machines' 'linux' 'endorsed-distros.md') -Raw
        $text | Should -Match '\| \*\*Azure Linux\*\* \| \[Azure Linux\]\([^)]*microsoftazurelinux\.azurelinux-4'
    }

    It 'the entry no longer says preview' {
        $script:al.Count | Should -Be 1
        $script:al[0].note | Should -Not -Match '(?i)preview'
        $script:al[0].why | Should -Not -Match '(?i)is in preview'
    }

    It 'the entry says the scripts the product runs in the machine do not support Azure Linux 4.0' {
        $script:al[0].note | Should -BeExactly 'The scripts that the product runs in the machine do not support Azure Linux 4.0. The product does not move this machine.'
    }

    It 'the entry stays not supported: AZURE-LINUX-3-SUPPORT-1 owns the move' {
        $script:al[0].support | Should -Be 'unsupported'
        $script:al[0].why | Should -Match 'AZURE-LINUX-3-SUPPORT-1'
    }

    It 'the entry names the date its source was read' {
        $script:al[0].source | Should -Be 'https://learn.microsoft.com/azure/azure-linux/azure-linux-vm-vmss-overview'
        $script:al[0].readUtc | Should -Be '2026-11-20'
        $script:matrix.updatedUtc | Should -Be '2026-11-20'
    }

    It 'the guest script really has no branch for azurelinux, so the reason is true' {
        $code = Get-Content (Join-Path $script:repoRoot 'src' 'guest' 'linux' 'nvme-fix.sh') -Raw
        $code | Should -Not -Match 'azurelinux'
        $code | Should -Match "unsupported distro"
    }

    It 'the scan reason for an Azure Linux 4 machine is those words' {
        InModuleScope VmMigrationFactory {
            $r = Get-VmfImageSupport -Publisher 'microsoftazurelinux' -Offer 'azurelinux-4' -Sku '4'
            $r.Supported | Should -BeFalse
            $r.Status | Should -Be 'unsupported'
            $r.Reason | Should -Match 'do not support Azure Linux 4\.0'
        }
    }

    It 'the support matrix page names Azure Linux 4.0 with no preview label' {
        $text = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'reference' 'support-matrix.md') -Raw
        $text | Should -Match '\| Azure Linux 4\.0 \| microsoftazurelinux \| Not supported \|'
        $text | Should -Not -Match 'Azure Linux 4\.0 \(preview\)'
    }
}

Describe 'DRIFT-13: the Arm64 Cobalt 200 v7 series are never a target' {
    BeforeAll {
        $script:dFamily = Get-Content (Join-Path $script:pages 'virtual-machines' 'sizes' 'general-purpose' 'd-family.md') -Raw
        $script:eFamily = Get-Content (Join-Path $script:pages 'virtual-machines' 'sizes' 'memory-optimized' 'e-family.md') -Raw
    }

    It 'the pinned family pages list <Series> on Cobalt 200 [Arm64]' -ForEach @(
        @{ Series = 'Dpsv7'; Page = 'd' }, @{ Series = 'Dpdsv7'; Page = 'd' }
        @{ Series = 'Dplsv7'; Page = 'd' }, @{ Series = 'Dpldsv7'; Page = 'd' }
        @{ Series = 'Epsv7'; Page = 'e' }, @{ Series = 'Epdsv7'; Page = 'e' }
    ) {
        $text = if ($Page -eq 'd') { $script:dFamily } else { $script:eFamily }
        $text | Should -Match ("# \[$Series-series\]")
        $text | Should -Match 'Azure Cobalt 200 \[Arm64\]'
    }

    It '<Size> reads as an Arm64 size and is refused as a v7 target for its processor' -ForEach @(
        @{ Size = 'Standard_D4ps_v7' }, @{ Size = 'Standard_D4pds_v7' }
        @{ Size = 'Standard_D4pls_v7' }, @{ Size = 'Standard_D4plds_v7' }
        @{ Size = 'Standard_E4ps_v7' }, @{ Size = 'Standard_E4pds_v7' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ size = $Size } {
            param($size)
            Get-VmfSizeProcessor -SizeName $size | Should -Be 'Arm64'
            $r = Test-VmfSizeApprovedTarget -SizeName $size -TargetGeneration 'v7'
            $r.Approved | Should -BeFalse
            $r.Why | Should -Match '^processor: '
        }
    }

    It 'a machine on <Size> gets no target: it stops as an Arm64 machine' -ForEach @(
        @{ Size = 'Standard_D4ps_v7' }, @{ Size = 'Standard_E4pds_v7' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ size = $Size } {
            param($size)
            $r = Get-VmfTargetSize -SourceSize $size -TargetGeneration 'v7'
            $r.Target | Should -BeNullOrEmpty
            $r.Code | Should -Be 'processor-not-approved'
        }
    }

    It 'the list of size names Microsoft gives covers no Arm64 size, so it says nothing about <Size>' -ForEach @(
        @{ Size = 'Standard_D4ps_v7' }, @{ Size = 'Standard_E4ps_v7' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ size = $Size } {
            param($size)
            (Get-VmfMicrosoftSizeListing -SizeName $size).Listed | Should -BeNullOrEmpty
        }
    }
}

Describe 'DRIFT-13: the Eb v6 throughput change is a number no rule reads' {
    It 'the pinned Eb v6 pages say 12,500 MBps, and the size names are unchanged' {
        foreach ($n in 'ebsv6-series', 'ebdsv6-series', 'eb-family') {
            $text = Get-Content (Join-Path $script:pages 'virtual-machines' 'sizes' 'memory-optimized' "$n.md") -Raw
            $text | Should -Match '253 - 12500 MBps'
            $text | Should -Not -Match '253 - 14000 MBps'
        }
        $fam = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'target-families.json') -Raw | ConvertFrom-Json
        $pg = @($fam.microsoftSizes.pages | Where-Object { $_.page -eq 'ebdsv6-series' })
        @($pg[0].sizes) | Should -Contain 'E192ibds_v6'
    }

    It 'no data file or dashboard script holds a remote disk throughput of 14000 or 12500 MBps' {
        $files = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data') -Filter *.json) +
            @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'dashboard') -Filter *.js)
        foreach ($f in $files) {
            (Get-Content $f.FullName -Raw) | Should -Not -Match '\b1(4000|2500) ?MBps' -Because $f.Name
        }
    }
}
