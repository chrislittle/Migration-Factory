#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# IMAGE-SCRIPT-MATCH-1, part 2 (2026-11-14): is each of these releases
# supported by the migration guide the drift check tracks? The whole tool is
# based on that guide.
#
# Microsoft's page enable-nvme-interface ("Supported Linux OS images") lists
# the Linux releases that support NVMe. Windows followed its Windows list
# (windows-version-below-2019); Linux did not - the scan asked only the
# publisher and Azure's DiskControllerTypes, and IMAGE-1 itself says that
# capability is not support.
#
# Now the list is data (data/nvme-linux-releases.json), checked against the
# pinned page so it cannot go stale without a test failing. A Linux machine
# whose release is not on it gets no v6 or v7 target, and keeps v5. The
# release is the one the VM agent reports, else the image's (OSVER-1's order).
# Unknown is a warning: never a pass and never a fail.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:listPath = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'nvme-linux-releases.json'
    $script:list = Get-Content $script:listPath -Raw | ConvertFrom-Json
    $script:reasons = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'assessment-reasons.json') -Raw | ConvertFrom-Json

    # The bullets of one section of a pinned page, in order.
    function Global:Get-NlrSectionBullets {
        param([string]$Path, [string]$Heading)
        $lines = Get-Content $Path
        $in = $false
        foreach ($l in $lines) {
            if ($l -match '^#+\s') { $in = ($l -match ('^#+\s+' + [regex]::Escape($Heading) + '\s*$')); continue }
            if ($in -and $l -match '^\s*[-*]\s+(.+?)\s*$') { $Matches[1] }
        }
    }

    function Global:NlrRow {
        param([string]$Publisher = 'Canonical', [string]$Offer = '0001-com-ubuntu-server-jammy', [string]$Sku = '22_04-lts-gen2',
            [string]$OsName = '', [string]$OsVersion = '', [string]$Os = 'Linux')
        [pscustomobject]@{
            id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm-l'
            name = 'vm-l'; resourceGroup = 'rg'; location = 'centralus'; zones = @()
            sku = 'Standard_D2s_v4'; os = $Os; gen = 'V2'; diskController = 'SCSI'
            osName = $OsName; osVersionRunning = $OsVersion
            imagePublisher = $Publisher; imageOffer = $Offer; imageSku = $Sku; imageId = ''
            vmssId = ''; hibernationEnabled = $false; securityType = ''
            dataDiskCount = 0; nicCount = 1; availabilitySetId = ''; tags = $null
        }
    }
}

AfterAll { Remove-Item 'function:\Get-NlrSectionBullets', 'function:\NlrRow' -ErrorAction SilentlyContinue }

Describe 'IMAGE-SCRIPT-MATCH-1: Microsoft''s NVMe Linux list is data, and matches the pinned page' {
    It 'names the page, the pinned file, the section and the date it was read' {
        $script:list.schemaVersion | Should -Be 1
        $script:list.source | Should -Be 'https://learn.microsoft.com/azure/virtual-machines/enable-nvme-interface'
        $script:list.pinnedFile | Should -Be 'docs/upstream-docs/azure/virtual-machines/enable-nvme-interface.md'
        $script:list.section | Should -Be 'Supported Linux OS images'
        $script:list.readUtc | Should -Be '2026-11-14'
    }

    It 'holds every release of the pinned page, in its order, and nothing else' {
        $bullets = @(Get-NlrSectionBullets -Path (Join-Path $script:repoRoot $script:list.pinnedFile) -Heading $script:list.section)
        $bullets.Count | Should -BeGreaterThan 10 -Because 'the reader found the section'
        @($script:list.releases | ForEach-Object { [string]$_.label }) | Should -Be $bullets -Because 'a change to the page list must change this data (the drift check refreshes the pinned page)'
    }

    It 'each row says what its label says' {
        $ids = @{ 'Azure Linux' = 'azurelinux'; 'Almalinux' = 'almalinux'; 'Debian' = 'debian'; 'Oracle Linux' = 'ol'; 'RHEL' = 'rhel'
            'SLES' = 'sles'; 'SLES-for-SAP' = 'sles_sap'; 'Ubuntu' = 'ubuntu'; 'Rocky Linux' = 'rocky' }
        foreach ($r in @($script:list.releases)) {
            $label = [string]$r.label
            $m = [regex]::Match($label, '^(?<name>.+?) (?<major>\d+)(\.(?<minor>\d+|x)| SP(?<sp>\d+))?(?<newer> and newer)?$')
            $m.Success | Should -BeTrue -Because "the label '$label' has a form this test reads"
            $ids.ContainsKey($m.Groups['name'].Value) | Should -BeTrue -Because "'$($m.Groups['name'].Value)' has an os-release ID here"
            [string]$r.distroId | Should -Be $ids[$m.Groups['name'].Value] -Because $label
            [int]$r.major | Should -Be ([int]$m.Groups['major'].Value) -Because $label
            $minor = if ($m.Groups['sp'].Success) { [int]$m.Groups['sp'].Value } elseif ($m.Groups['minor'].Success -and $m.Groups['minor'].Value -ne 'x') { [int]$m.Groups['minor'].Value } else { $null }
            $r.minor | Should -Be $minor -Because $label
            [bool]$r.andNewer | Should -Be ([bool]$m.Groups['newer'].Success) -Because $label
        }
    }

    It 'the drift check names this data as made from the page' {
        $json = Get-Content (Join-Path $script:repoRoot 'docs' 'upstream-docs.json') -Raw | ConvertFrom-Json
        $group = @($json.folders | Where-Object { [string]$_.include -match 'enable-nvme-interface' })
        $group.Count | Should -Be 1
        (@($group[0].localDerivatives) -join ' ') | Should -Match 'data/nvme-linux-releases\.json'
    }
}

Describe 'IMAGE-SCRIPT-MATCH-1: the support matrix lists the releases' {
    It 'has a section with each release of the list, in its order' {
        $page = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'reference' 'support-matrix.md') -Raw
        $section = [regex]::Match($page, '(?s)## Linux releases for NVMe\s*\n(.*?)\n## ').Groups[1].Value
        $section | Should -Not -BeNullOrEmpty
        $rows = @([regex]::Matches($section, '(?m)^\| (?!Linux release|---)(.+?) \|\s*$') | ForEach-Object { $_.Groups[1].Value })
        # Our table spells AlmaLinux as its vendor does (review, 2026-11-15).
        $rows | Should -Be @($script:list.releases | ForEach-Object { ([string]$_.label) -creplace '^Almalinux\b', 'AlmaLinux' })
        $section | Should -Not -MatchExactly 'Almalinux'
        $section | Should -Match 'does not move a Linux machine on another release to v6 or v7'
        $section | Should -Match ([regex]::Escape($script:reasons.blockers.'linux-release-not-on-nvme-list'.docs.url))
    }
}

Describe 'IMAGE-SCRIPT-MATCH-1: is a release on the list' {
    It '<Id> <Version> from <Source> is <Expected>' -ForEach @(
        @{ Id = 'ubuntu'; Version = '22.04'; Source = 'agent'; Expected = 'listed' }
        @{ Id = 'ubuntu'; Version = '18.04'; Source = 'agent'; Expected = 'listed' }
        @{ Id = 'ubuntu'; Version = '16.04'; Source = 'agent'; Expected = 'unlisted' }
        @{ Id = 'ubuntu'; Version = '24.10'; Source = 'agent'; Expected = 'unlisted' }
        @{ Id = 'rhel'; Version = '8.10'; Source = 'agent'; Expected = 'listed' }
        @{ Id = 'rhel'; Version = '8.6'; Source = 'agent'; Expected = 'listed' }
        @{ Id = 'rhel'; Version = '8.4'; Source = 'agent'; Expected = 'unlisted' }
        @{ Id = 'rhel'; Version = '7.9'; Source = 'agent'; Expected = 'listed' }
        @{ Id = 'rhel'; Version = '7.7'; Source = 'agent'; Expected = 'unlisted' }
        @{ Id = 'rhel'; Version = '10.0'; Source = 'agent'; Expected = 'unlisted' }
        @{ Id = 'rhel'; Version = '9'; Source = 'image'; Expected = 'listed' }
        @{ Id = 'rhel'; Version = '8'; Source = 'image'; Expected = 'unknown' }
        @{ Id = 'rhel'; Version = '8'; Source = 'agent'; Expected = 'unknown' }
        @{ Id = 'rhel'; Version = '8.4'; Source = 'image'; Expected = 'unknown' }
        @{ Id = 'rhel'; Version = '7.7'; Source = 'image'; Expected = 'unknown' }
        @{ Id = 'rhel'; Version = '10.0'; Source = 'image'; Expected = 'unknown' }
        @{ Id = 'ubuntu'; Version = '16.04'; Source = 'image'; Expected = 'unknown' }
        @{ Id = 'debian'; Version = '10'; Source = 'image'; Expected = 'unknown' }
        @{ Id = 'rhel'; Version = '6.10'; Source = 'image'; Expected = 'unknown' }
        @{ Id = 'rhel'; Version = '6.10'; Source = 'agent'; Expected = 'unlisted' }
        @{ Id = 'ubuntu'; Version = '24.10'; Source = 'image'; Expected = 'unlisted' }
        @{ Id = 'debian'; Version = '12'; Source = 'agent'; Expected = 'listed' }
        @{ Id = 'debian'; Version = '11.9'; Source = 'agent'; Expected = 'listed' }
        @{ Id = 'debian'; Version = '10'; Source = 'agent'; Expected = 'unlisted' }
        @{ Id = 'sles'; Version = '15.4'; Source = 'agent'; Expected = 'listed' }
        @{ Id = 'sles'; Version = '15.7'; Source = 'agent'; Expected = 'listed' }
        @{ Id = 'sles'; Version = '15.3'; Source = 'agent'; Expected = 'unlisted' }
        @{ Id = 'sles'; Version = '12.5'; Source = 'agent'; Expected = 'unlisted' }
        @{ Id = 'ol'; Version = '8.5'; Source = 'agent'; Expected = 'listed' }
        @{ Id = 'ol'; Version = '8.4'; Source = 'agent'; Expected = 'unlisted' }
        @{ Id = 'ol'; Version = '9.4'; Source = 'agent'; Expected = 'listed' }
        @{ Id = 'almalinux'; Version = '8.3'; Source = 'agent'; Expected = 'listed' }
        @{ Id = 'rocky'; Version = '9.6'; Source = 'agent'; Expected = 'listed' }
        @{ Id = 'rocky'; Version = '9.5'; Source = 'agent'; Expected = 'unlisted' }
        @{ Id = 'centos'; Version = '7.9'; Source = 'agent'; Expected = 'unlisted' }
        @{ Id = 'ubuntu'; Version = ''; Source = 'agent'; Expected = 'unknown' }
        @{ Id = ''; Version = '22.04'; Source = 'agent'; Expected = 'unknown' }
        @{ Id = 'ubuntu'; Version = 'jammy'; Source = 'agent'; Expected = 'unknown' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ rel = @{ distroId = $Id; version = $Version; source = $Source }; want = $Expected } {
            param($rel, $want)
            Get-VmfNvmeLinuxListing -Release $rel | Should -Be $want
        }
    }

    It 'no release at all is unknown' {
        InModuleScope VmMigrationFactory { Get-VmfNvmeLinuxListing -Release $null | Should -Be 'unknown' }
    }
}

Describe 'IMAGE-SCRIPT-MATCH-1: the scan judges a Linux machine by the list' {
    It 'a machine whose VM agent reports a release not on the list is held from v6 and v7, and the note names the release' {
        InModuleScope VmMigrationFactory {
            $r = Get-VmfAssessmentRecord -Vm (NlrRow -Sku '16.04-LTS' -Offer 'UbuntuServer' -OsName 'ubuntu' -OsVersion '16.04')
            @($r.blockers) | Should -Contain 'linux-release-not-on-nvme-list'
            @($r.warnings) | Should -Not -Contain 'linux-release-nvme-not-read'
            (@($r.notes) -join ' ') | Should -Match ([regex]::Escape('This machine runs Ubuntu 16.04. Microsoft does not list this release among the Linux images that support NVMe.'))
            (@($r.notes) -join ' ') | Should -Match ([regex]::Escape('The Azure Linux Agent reports this release.'))
        }
    }

    It 'the release the VM agent reports wins over the image' {
        InModuleScope VmMigrationFactory {
            # Made from 22.04, upgraded in place... and the other way: made
            # from 16.04, now on 22.04.
            @((Get-VmfAssessmentRecord -Vm (NlrRow -Sku '22_04-lts-gen2' -OsName 'ubuntu' -OsVersion '20.04')).blockers) | Should -Not -Contain 'linux-release-not-on-nvme-list'
            @((Get-VmfAssessmentRecord -Vm (NlrRow -Offer 'UbuntuServer' -Sku '16.04-LTS' -OsName 'ubuntu' -OsVersion '22.04')).blockers) | Should -Not -Contain 'linux-release-not-on-nvme-list'
            @((Get-VmfAssessmentRecord -Vm (NlrRow -Publisher 'RedHat' -Offer 'RHEL' -Sku '8_10' -OsName 'redhat' -OsVersion '8.4')).blockers) | Should -Contain 'linux-release-not-on-nvme-list'
        }
    }

    It 'a stopped machine (no agent reading) is judged by its image, and the note says so' {
        # Ubuntu 24.10 has a row of its major (24.04) and none later, so the
        # image is unlisted even as the lowest release the machine can run.
        InModuleScope VmMigrationFactory {
            $r = Get-VmfAssessmentRecord -Vm (NlrRow -Offer 'ubuntu-24_10' -Sku 'server')
            @($r.blockers) | Should -Contain 'linux-release-not-on-nvme-list'
            (@($r.notes) -join ' ') | Should -Match ([regex]::Escape('The Azure Linux Agent reports no release. The product reads the release from the image of the machine.'))
            @((Get-VmfAssessmentRecord -Vm (NlrRow -Sku '22_04-lts-gen2')).blockers) | Should -Not -Contain 'linux-release-not-on-nvme-list'
        }
    }

    It 'an image release whose major has no row is a warning: the machine can run a later release (review, 2026-11-15)' {
        InModuleScope VmMigrationFactory {
            $r = Get-VmfAssessmentRecord -Vm (NlrRow -Offer 'UbuntuServer' -Sku '16.04-LTS')
            @($r.blockers) | Should -Not -Contain 'linux-release-not-on-nvme-list'
            @($r.warnings) | Should -Contain 'linux-release-nvme-not-read'
            (@($r.notes) -join ' ') | Should -Match ([regex]::Escape('The image of this machine is Ubuntu 16.04. Microsoft does not list this release among the Linux images that support NVMe. The Azure Linux Agent reports no release.'))
            $agent = Get-VmfAssessmentRecord -Vm (NlrRow -Offer 'UbuntuServer' -Sku '16.04-LTS' -OsName 'ubuntu' -OsVersion '16.04')
            @($agent.blockers) | Should -Contain 'linux-release-not-on-nvme-list'
        }
    }

    It 'only the warning says to start the machine; the blocker says to assess and plan again (review, 2026-11-15)' {
        # An image reading with no row is the warning now, so the blocker
        # comes from a machine that reports its release: starting it changes nothing.
        $script:reasons.warnings.'linux-release-nvme-not-read'.whatToDo | Should -Match ([regex]::Escape('Start the machine. Then assess it again.'))
        $script:reasons.blockers.'linux-release-not-on-nvme-list'.whatToDo | Should -Not -Match '(?i)start the machine'
        $script:reasons.blockers.'linux-release-not-on-nvme-list'.whatToDo | Should -Match ([regex]::Escape('upgrade Linux to a release on the list. Then run a new assessment and plan again.'))
    }

    It 'a release the scan cannot read is a warning, with a note: never a pass and never a fail' {
        InModuleScope VmMigrationFactory {
            $r = Get-VmfAssessmentRecord -Vm (NlrRow -Offer 'some-offer' -Sku 'some-sku')
            @($r.blockers) | Should -Not -Contain 'linux-release-not-on-nvme-list'
            @($r.warnings) | Should -Contain 'linux-release-nvme-not-read'
            (@($r.notes) -join ' ') | Should -Match ([regex]::Escape('The scan cannot read the Linux release of this machine.'))
        }
    }

    It 'an image release whose later minor release can be on the list is a warning, not a block' {
        InModuleScope VmMigrationFactory {
            $r = Get-VmfAssessmentRecord -Vm (NlrRow -Publisher 'RedHat' -Offer 'RHEL' -Sku '8_4')
            @($r.blockers) | Should -Not -Contain 'linux-release-not-on-nvme-list'
            @($r.warnings) | Should -Contain 'linux-release-nvme-not-read'
            (@($r.notes) -join ' ') | Should -Match ([regex]::Escape('The image of this machine is RHEL 8.4.'))
        }
    }

    It 'a release on the list gives no block and no warning' {
        InModuleScope VmMigrationFactory {
            $r = Get-VmfAssessmentRecord -Vm (NlrRow -OsName 'ubuntu' -OsVersion '22.04')
            @($r.blockers) | Should -Not -Contain 'linux-release-not-on-nvme-list'
            @($r.warnings) | Should -Not -Contain 'linux-release-nvme-not-read'
        }
    }

    It 'a machine the support list refuses gets neither: it does not move on any series' {
        InModuleScope VmMigrationFactory {
            $r = Get-VmfAssessmentRecord -Vm (NlrRow -Publisher 'OpenLogic' -Offer 'CentOS' -Sku '7_9-gen2' -OsName 'centos' -OsVersion '7.9')
            @($r.blockers) | Should -Contain 'image-not-supported'
            @($r.blockers) | Should -Not -Contain 'linux-release-not-on-nvme-list'
            @($r.warnings) | Should -Not -Contain 'linux-release-nvme-not-read'
        }
    }

    It 'a Windows machine is not judged by the Linux list' {
        InModuleScope VmMigrationFactory {
            $r = Get-VmfAssessmentRecord -Vm (NlrRow -Os 'Windows' -Publisher 'MicrosoftWindowsServer' -Offer 'WindowsServer' -Sku '2022-datacenter-g2' -OsName 'Windows Server 2022 Datacenter')
            @($r.blockers) | Should -Not -Contain 'linux-release-not-on-nvme-list'
            @($r.warnings) | Should -Not -Contain 'linux-release-nvme-not-read'
        }
    }
}

Describe 'IMAGE-SCRIPT-MATCH-1: the reason closes v6 and v7, and v5 stays' {
    It 'the blocker applies to v6 and v7, and the warning too' {
        (@($script:reasons.blockers.'linux-release-not-on-nvme-list'.appliesTo) -join ',') | Should -Be 'v6,v7'
        (@($script:reasons.warnings.'linux-release-nvme-not-read'.appliesTo) -join ',') | Should -Be 'v6,v7'
    }

    It 'both name Microsoft''s page that the list is read from' {
        $script:reasons.blockers.'linux-release-not-on-nvme-list'.docs.url | Should -Be 'https://learn.microsoft.com/en-us/azure/virtual-machines/enable-nvme-interface'
        $script:reasons.warnings.'linux-release-nvme-not-read'.docs.url | Should -Be 'https://learn.microsoft.com/en-us/azure/virtual-machines/enable-nvme-interface'
    }

    It 'a machine held by it is Blocked for v6 and v7 and ready for v5' {
        $rec = [pscustomobject]@{ classification = 'Blocked'; blockers = @('linux-release-not-on-nvme-list'); prepNeeded = @('linux-nvme-prep')
            diskController = 'SCSI'; platformManaged = $false }
        InModuleScope VmMigrationFactory -Parameters @{ r = $rec } {
            param($r)
            (Resolve-VmfEntryClassification -Assessment $r -TargetGeneration 'v6').Classification | Should -Be 'Blocked'
            (Resolve-VmfEntryClassification -Assessment $r -TargetGeneration 'v7').Classification | Should -Be 'Blocked'
            (Resolve-VmfEntryClassification -Assessment $r -TargetGeneration 'v5').Classification | Should -Not -Be 'Blocked'
        }
    }

    It 'the target options may carry it as a reason, and their format moved to version 32' {
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json') -Raw | ConvertFrom-Json
        @($schema.'$defs'.reason.enum) | Should -Contain 'linux-release-not-on-nvme-list'
        $schema.properties.schemaVersion.const | Should -Be 34
        InModuleScope VmMigrationFactory { Get-VmfTargetAdviceSchemaVersion | Should -Be 34 }
        (Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw) | Should -Match 'linux-release-not-on-nvme-list'
    }
}
