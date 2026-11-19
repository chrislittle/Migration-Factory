#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# EOL-RELEASE-AN-1 (decided 2026-11-14), part 3 of IMAGE-SCRIPT-MATCH-1.
#
# Microsoft, accelerated-networking-overview (pinned, "For virtual machines
# (VMs) with Mellanox Adapters"): all Azure endorsed Linux distributions are
# supported "as long as the vendors don't mark them as end of life (EOL)".
# The support list goes by publisher, and no release had an end date, so the
# product never compared a release with its vendor's end of standard support.
# DriverReadiness said the operating system "is checked separately" - it was
# not, for the age of the release.
#
# Now data/linux-release-eol.json holds each admitted release's STANDARD end
# of support, read from the vendor's own page. The scan states the fact (a
# warning, never a refusal: the vendors sell extended support - ESM, ELS,
# LTSS, Extended Support - so the words never call the machine unsupported),
# and Checking stops such a machine with a decision a person accepts
# (linuxReleaseEndOfLife, lever onReleaseEndOfLife = proceed), the mechanism
# the temporary disk files use. Only the release the Azure Linux Agent reports
# is past an end date: an image is the lowest release a machine can run.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    $script:eolPath = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'linux-release-eol.json'
    $script:eol = Get-Content $script:eolPath -Raw | ConvertFrom-Json
    $script:reasons = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'assessment-reasons.json') -Raw | ConvertFrom-Json
    $script:stops = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json
    $script:now = [datetime]::new(2026, 11, 14, 12, 0, 0, [System.DateTimeKind]::Utc)
    $script:tail = 'Microsoft supports accelerated networking only on releases that the vendor has not marked as end of life.'

    function Global:EolRow {
        param([string]$Publisher = 'Canonical', [string]$Offer = '0001-com-ubuntu-server-jammy', [string]$Sku = '22_04-lts-gen2',
            [string]$OsName = '', [string]$OsVersion = '', [string]$Os = 'Linux')
        [pscustomobject]@{
            id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm-e'
            name = 'vm-e'; resourceGroup = 'rg'; location = 'centralus'; zones = @()
            sku = 'Standard_D2s_v4'; os = $Os; gen = 'V2'; diskController = 'SCSI'
            osName = $OsName; osVersionRunning = $OsVersion
            imagePublisher = $Publisher; imageOffer = $Offer; imageSku = $Sku; imageId = ''
            vmssId = ''; hibernationEnabled = $false; securityType = ''
            dataDiskCount = 0; nicCount = 1; availabilitySetId = ''; tags = $null
        }
    }
    function Global:EolEntry {
        param([string]$OsName = 'ubuntu', [string]$OsVersion = '18.04', [string]$Os = 'Linux', [string]$Policy = '')
        $pol = [ordered]@{ targetGeneration = 'v6' }
        if ($Policy) { $pol['onReleaseEndOfLife'] = $Policy }
        [pscustomobject]@{
            vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm-e'
            policy = [pscustomobject]$pol
            assessment = [pscustomobject]@{ os = $Os; osVersion = '18.04-LTS'; imagePublisher = 'Canonical'; imageOffer = 'UbuntuServer'
                runningOsName = $OsName; runningOsVersion = $OsVersion }
        }
    }
}

AfterAll { Remove-Item 'function:\EolRow', 'function:\EolEntry' -ErrorAction SilentlyContinue }

Describe 'EOL-RELEASE-AN-1: the end of standard support of each release is data, from the vendor' {
    It 'names the Microsoft rule it serves and the date it was read' {
        $script:eol.schemaVersion | Should -Be 1
        $script:eol.readUtc | Should -Be '2026-11-14'
        $script:eol.microsoftSource | Should -Be 'https://learn.microsoft.com/azure/virtual-network/accelerated-networking-overview'
        $page = Get-Content (Join-Path $script:repoRoot 'docs' 'upstream-docs' 'azure' 'virtual-network' 'accelerated-networking-overview.md') -Raw
        $page | Should -Match ([regex]::Escape("as long as the vendors don't mark them as end of life (EOL)"))
    }

    It 'every row names the vendor, the release, its date and the vendor page' {
        $vendors = @{ ubuntu = 'Canonical'; rhel = 'Red Hat'; sles = 'SUSE'; ol = 'Oracle'; debian = 'Debian'; almalinux = 'AlmaLinux OS Foundation'; rocky = 'Rocky Enterprise Software Foundation' }
        foreach ($r in @($script:eol.releases)) {
            $vendors.ContainsKey([string]$r.distroId) | Should -BeTrue -Because "$($r.label) is a distribution the list admits"
            [string]$r.vendor | Should -Be $vendors[[string]$r.distroId]
            [string]$r.label | Should -Not -BeNullOrEmpty
            [string]$r.endOfStandardSupport | Should -Match '^\d{4}-\d{2}(-\d{2})?$'
            [string]$r.source | Should -Match '^https://'
            $r.PSObject.Properties.Name | Should -Contain 'minor'
        }
    }

    It 'has rows for each distribution the support list admits by publisher' {
        foreach ($id in 'ubuntu', 'rhel', 'sles', 'ol', 'debian') {
            @($script:eol.releases | Where-Object { $_.distroId -eq $id }).Count | Should -BeGreaterThan 1 -Because $id
        }
    }

    It 'holds the dates the vendor pages gave on 2026-11-14' -ForEach @(
        @{ Id = 'ubuntu'; Major = 18; Minor = 4; Date = '2023-05' }
        @{ Id = 'ubuntu'; Major = 24; Minor = 4; Date = '2029-05' }
        @{ Id = 'rhel'; Major = 7; Minor = $null; Date = '2024-06-30' }
        @{ Id = 'rhel'; Major = 9; Minor = $null; Date = '2032-05-31' }
        @{ Id = 'sles'; Major = 15; Minor = 5; Date = '2024-12-31' }
        @{ Id = 'sles'; Major = 15; Minor = 7; Date = '2031-07-31' }
        @{ Id = 'ol'; Major = 7; Minor = $null; Date = '2024-12' }
        @{ Id = 'debian'; Major = 12; Minor = $null; Date = '2026-07-11' }
    ) {
        $r = @($script:eol.releases | Where-Object { $_.distroId -eq $Id -and [int]$_.major -eq $Major -and $_.minor -eq $Minor })
        $r.Count | Should -Be 1
        $r[0].endOfStandardSupport | Should -Be $Date
    }
}

Describe 'EOL-RELEASE-AN-1: the dates the review asked to source carry the vendor''s words (review, 2026-11-15)' {
    It '<Label> quotes its page: <Words>' -ForEach @(
        @{ Label = 'Ubuntu 22.04 LTS'; Words = 'Standard security maintenance May 2027'; Date = '2027-05' }
        @{ Label = 'Ubuntu 24.04 LTS'; Words = 'Standard security maintenance May 2029'; Date = '2029-05' }
        @{ Label = 'Ubuntu 26.04 LTS'; Words = 'Standard security maintenance May 2031'; Date = '2031-05' }
        @{ Label = 'Debian 12'; Words = 'full Debian support, until July 11th, 2026'; Date = '2026-07-11' }
        @{ Label = 'AlmaLinux 9'; Words = 'security support until 31 May 2032'; Date = '2032-05-31' }
        @{ Label = 'Rocky Linux 9'; Words = 'security support through 31 May 2032'; Date = '2032-05-31' }
    ) {
        $r = @($script:eol.releases | Where-Object { $_.label -eq $Label })
        $r.Count | Should -Be 1
        $r[0].endOfStandardSupport | Should -Be $Date
        [string]$r[0].quote | Should -Match ([regex]::Escape($Words))
        $r[0].quotedUtc | Should -Be '2026-11-15'
    }
}

Describe 'EOL-RELEASE-AN-1: is a release past its end of standard support' {
    It '<Id> <Version> from <Source> on <When> is <Expected>' -ForEach @(
        @{ Id = 'ubuntu'; Version = '18.04'; Source = 'agent'; When = '2026-11-14'; Expected = 'past' }
        @{ Id = 'ubuntu'; Version = '22.04'; Source = 'agent'; When = '2026-11-14'; Expected = 'current' }
        @{ Id = 'ubuntu'; Version = '24.04'; Source = 'agent'; When = '2029-05-31'; Expected = 'current' }
        @{ Id = 'ubuntu'; Version = '24.04'; Source = 'agent'; When = '2029-06-01'; Expected = 'past' }
        @{ Id = 'rhel'; Version = '7.9'; Source = 'agent'; When = '2024-06-30'; Expected = 'current' }
        @{ Id = 'rhel'; Version = '7.9'; Source = 'agent'; When = '2024-07-01'; Expected = 'past' }
        @{ Id = 'rhel'; Version = '8.10'; Source = 'agent'; When = '2026-11-14'; Expected = 'current' }
        @{ Id = 'sles'; Version = '15.6'; Source = 'agent'; When = '2026-11-14'; Expected = 'past' }
        @{ Id = 'sles'; Version = '15.7'; Source = 'agent'; When = '2026-11-14'; Expected = 'current' }
        @{ Id = 'ol'; Version = '7.9'; Source = 'agent'; When = '2026-11-14'; Expected = 'past' }
        @{ Id = 'debian'; Version = '11'; Source = 'agent'; When = '2026-11-14'; Expected = 'past' }
        @{ Id = 'debian'; Version = '13'; Source = 'agent'; When = '2026-11-14'; Expected = 'current' }
        @{ Id = 'rhel'; Version = '7'; Source = 'image'; When = '2026-11-14'; Expected = 'unknown' }
        @{ Id = 'ubuntu'; Version = '24.04'; Source = 'image'; When = '2026-11-14'; Expected = 'current' }
        @{ Id = 'ubuntu'; Version = '25.04'; Source = 'agent'; When = '2026-11-14'; Expected = 'unknown' }
        @{ Id = 'sles'; Version = '15'; Source = 'agent'; When = '2026-11-14'; Expected = 'unknown' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ rel = @{ distroId = $Id; version = $Version; source = $Source }; when = [datetime]::Parse("$($When)T12:00:00Z").ToUniversalTime(); want = $Expected } {
            param($rel, $when, $want)
            (Get-VmfLinuxReleaseEol -Release $rel -Now $when).Status | Should -Be $want
        }
    }

    It 'no release is unknown' {
        InModuleScope VmMigrationFactory -Parameters @{ now = $script:now } { param($now) (Get-VmfLinuxReleaseEol -Release $null -Now $now).Status | Should -Be 'unknown' }
    }

    It 'the words state the vendor, the release and the date, and never call the machine unsupported' {
        InModuleScope VmMigrationFactory -Parameters @{ now = $script:now; tail = $script:tail } {
            param($now, $tail)
            $day = Get-VmfLinuxReleaseEol -Release @{ distroId = 'rhel'; version = '7.9'; source = 'agent' } -Now $now
            $day.Text | Should -Be "Red Hat ended standard support for Red Hat Enterprise Linux 7 on 30 June 2024. $tail"
            $month = Get-VmfLinuxReleaseEol -Release @{ distroId = 'ubuntu'; version = '18.04'; source = 'agent' } -Now $now
            $month.Text | Should -Be "Canonical ended standard support for Ubuntu 18.04 LTS in May 2023. $tail"
            foreach ($t in $day.Text, $month.Text) { $t | Should -Not -Match '(?i)unsupported|not supported|no longer supported' }
        }
    }
}

Describe 'EOL-RELEASE-AN-1: the scan states the fact and does not refuse the machine' {
    It 'a release past its end gets the warning and the note, and no blocker' {
        InModuleScope VmMigrationFactory -Parameters @{ now = $script:now; tail = $script:tail } {
            param($now, $tail)
            $r = Get-VmfAssessmentRecord -Vm (EolRow -OsName 'ubuntu' -OsVersion '20.04') -Now $now
            @($r.warnings) | Should -Contain 'linux-release-past-standard-support'
            (@($r.notes) -join ' ') | Should -Match ([regex]::Escape("Canonical ended standard support for Ubuntu 20.04 LTS in May 2025. $tail"))
            @($r.blockers) | Should -BeNullOrEmpty
        }
    }

    It 'a current release gets nothing' {
        InModuleScope VmMigrationFactory -Parameters @{ now = $script:now } {
            param($now)
            $r = Get-VmfAssessmentRecord -Vm (EolRow -OsName 'ubuntu' -OsVersion '22.04') -Now $now
            @($r.warnings) | Should -Not -Contain 'linux-release-past-standard-support'
            @($r.warnings) | Should -Not -Contain 'linux-release-end-of-support-not-known'
        }
    }

    It 'a release it cannot compare is a warning: cannot verify' {
        InModuleScope VmMigrationFactory -Parameters @{ now = $script:now } {
            param($now)
            $r = Get-VmfAssessmentRecord -Vm (EolRow -Publisher 'RedHat' -Offer 'RHEL' -Sku '7_9') -Now $now
            @($r.warnings) | Should -Not -Contain 'linux-release-past-standard-support'
            @($r.warnings) | Should -Contain 'linux-release-end-of-support-not-known'
        }
    }

    It 'a machine converted to AlmaLinux or Rocky Linux from an admitted image is compared with its vendor''s date (review, 2026-11-15)' {
        InModuleScope VmMigrationFactory -Parameters @{ now = $script:now } {
            param($now)
            foreach ($name in 'almalinux', 'rocky') {
                $r = Get-VmfAssessmentRecord -Vm (EolRow -Publisher 'RedHat' -Offer 'RHEL' -Sku '9_4' -OsName $name -OsVersion '9.4') -Now $now
                @($r.warnings) | Should -Not -Contain 'linux-release-end-of-support-not-known' -Because "$name 9 has a row"
                @($r.warnings) | Should -Not -Contain 'linux-release-past-standard-support'
            }
            (Get-VmfLinuxReleaseEol -Release @{ distroId = 'rocky'; version = '8.10'; source = 'agent' } -Now ([datetime]'2029-06-01')).Status | Should -Be 'past'
        }
    }

    It 'an AlmaLinux, Rocky Linux or CentOS image is refused by the support list, so it gets neither warning' {
        InModuleScope VmMigrationFactory -Parameters @{ now = $script:now } {
            param($now)
            foreach ($img in @(@('almalinux', 'almalinux-x86_64', '9-gen2', 'almalinux'), @('resf', 'rockylinux-x86_64', '9-base', 'rocky'), @('OpenLogic', 'CentOS', '7_9-gen2', 'centos'))) {
                $r = Get-VmfAssessmentRecord -Vm (EolRow -Publisher $img[0] -Offer $img[1] -Sku $img[2] -OsName $img[3] -OsVersion '9.4') -Now $now
                @($r.blockers) | Should -Contain 'image-not-supported'
                @($r.warnings) | Should -Not -Contain 'linux-release-end-of-support-not-known'
                @($r.warnings) | Should -Not -Contain 'linux-release-past-standard-support'
            }
        }
    }

    It 'a Windows machine, and an image the list refuses, get neither' {
        InModuleScope VmMigrationFactory -Parameters @{ now = $script:now } {
            param($now)
            $w = Get-VmfAssessmentRecord -Vm (EolRow -Os 'Windows' -Publisher 'MicrosoftWindowsServer' -Offer 'WindowsServer' -Sku '2022-datacenter-g2' -OsName 'Windows Server 2022 Datacenter') -Now $now
            $c = Get-VmfAssessmentRecord -Vm (EolRow -Publisher 'OpenLogic' -Offer 'CentOS' -Sku '7_9-gen2' -OsName 'centos' -OsVersion '7.9') -Now $now
            foreach ($r in $w, $c) {
                @($r.warnings) | Should -Not -Contain 'linux-release-past-standard-support'
                @($r.warnings) | Should -Not -Contain 'linux-release-end-of-support-not-known'
            }
        }
    }

    It 'both warnings apply to every series and name the Microsoft rule' {
        foreach ($code in 'linux-release-past-standard-support', 'linux-release-end-of-support-not-known') {
            (@($script:reasons.warnings.$code.appliesTo) -join ',') | Should -Be 'v5,v6,v7'
            $script:reasons.warnings.$code.docs.url | Should -Be 'https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-overview'
            ([string]$script:reasons.warnings.$code.meaning + ' ' + [string]$script:reasons.warnings.$code.whatToDo) | Should -Not -Match '(?i)unsupported|not supported'
        }
    }
}

Describe 'EOL-RELEASE-AN-1: Checking stops such a machine for a person to accept' {
    It 'a release past its end stops with the decision, before anything changes' {
        InModuleScope VmMigrationFactory -Parameters @{ now = $script:now; tail = $script:tail } {
            param($now, $tail)
            $s = Get-VmfReleaseEndOfLifeStop -PlanEntry (EolEntry -OsVersion '18.04') -Now $now
            $s.Next | Should -Be 'NEEDS_DECISION'
            $s.Reason | Should -Be 'linuxReleaseEndOfLife'
            $s.MachineState | Should -Be 'untouched'
            $s.Detail | Should -Match ([regex]::Escape("Canonical ended standard support for Ubuntu 18.04 LTS in May 2023. $tail"))
            $s.Detail | Should -Match 'Nothing on the machine changed\.$'
        }
    }

    It 'an accepted machine goes on: onReleaseEndOfLife = proceed' {
        InModuleScope VmMigrationFactory -Parameters @{ now = $script:now } {
            param($now)
            Get-VmfReleaseEndOfLifeStop -PlanEntry (EolEntry -OsVersion '18.04' -Policy 'proceed') -Now $now | Should -BeNullOrEmpty
            (Get-VmfReleaseEndOfLifeStop -PlanEntry (EolEntry -OsVersion '18.04' -Policy 'stop') -Now $now).Reason | Should -Be 'linuxReleaseEndOfLife'
        }
    }

    It 'a current release, an unknown release and a Windows machine go on' {
        InModuleScope VmMigrationFactory -Parameters @{ now = $script:now } {
            param($now)
            Get-VmfReleaseEndOfLifeStop -PlanEntry (EolEntry -OsVersion '22.04') -Now $now | Should -BeNullOrEmpty
            Get-VmfReleaseEndOfLifeStop -PlanEntry (EolEntry -OsName '' -OsVersion '') -Now $now | Should -BeNullOrEmpty
            Get-VmfReleaseEndOfLifeStop -PlanEntry (EolEntry -Os 'Windows' -OsName 'Windows Server 2016 Datacenter' -OsVersion '10.0') -Now $now | Should -BeNullOrEmpty
        }
    }

    It 'Checking asks it after the stops for machines outside the scope of this tool' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1')
        $host1 = $code.IndexOf('$hostHibernationStop = Get-VmfHostHibernationStop -Vm $vm')
        $eolAt = $code.IndexOf('$releaseEolStop = Get-VmfReleaseEndOfLifeStop -PlanEntry $Context.Plan')
        $host1 | Should -BeGreaterThan 0
        $eolAt | Should -BeGreaterThan $host1
        $code | Should -Match ([regex]::Escape('if ($releaseEolStop) { return $releaseEolStop }'))
    }

    It 'the stop reason is a decision an approver accepts with onReleaseEndOfLife = proceed' {
        $r = @($script:stops.reasons | Where-Object { $_.code -eq 'linuxReleaseEndOfLife' })
        $r.Count | Should -Be 1
        $r[0].retry | Should -Be 'decision'
        $r[0].machine | Should -Be 'untouched'
        $r[0].decide.lever | Should -Be 'onReleaseEndOfLife'
        $r[0].decide.accept | Should -Be 'proceed'
        $r[0].decide.approver | Should -BeTrue
        ([string]$r[0].meaning + ' ' + [string]$r[0].whatToDo) | Should -Not -Match '(?i)unsupported|not supported'
        # Review, 2026-11-15: the stop comes inside a migration that has a plan,
        # and a migration keeps its plan - the wizard's words (UX.s3Planned).
        [string]$r[0].whatToDo | Should -Match ([regex]::Escape('Upgrade the release. Then run a new assessment. Select Delete this migration on the Migrations page. Then plan a new migration from the assessment.'))
        $wizard = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.js') -Raw
        $wizard | Should -Match ([regex]::Escape('select Delete this migration on the Migrations page. Then plan a new migration from the assessment.'))
    }

    It 'the plan contract carries the lever, and its version moved to 34' {
        InModuleScope VmMigrationFactory {
            @((Get-VmfPolicyLevers)['onReleaseEndOfLife']) | Should -Be @('stop', 'proceed')
            (Test-VmfPolicyOverride -Override @{ onReleaseEndOfLife = 'proceed' }).Ok | Should -BeTrue
            (Test-VmfPolicyOverride -Override @{ onReleaseEndOfLife = 'maybe' }).Ok | Should -BeFalse
            Get-VmfPlanSchemaVersion | Should -Be 37
        }
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json') -Raw | ConvertFrom-Json
        @($schema.properties.policy.properties.onReleaseEndOfLife.enum) | Should -Be @('stop', 'proceed')
        $schema.properties.schemaVersion.const | Should -Be 37
        (Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw) | Should -Match 'plan-entry v33 -> v34'
    }
}

Describe 'EOL-RELEASE-AN-1: the support matrix lists each date' {
    It 'has a row for each release, with its vendor, its date and the vendor page' {
        $page = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'reference' 'support-matrix.md') -Raw
        $section = [regex]::Match($page, '(?s)## End of standard support of a Linux release\s*\n(.*?)\n## ').Groups[1].Value
        $section | Should -Not -BeNullOrEmpty
        $rows = @([regex]::Matches($section, '(?m)^\| (?!Linux release|---)(.+?) \| (.+?) \| (.+?) \| \[.+?\]\((.+?)\) \|\s*$'))
        $rows.Count | Should -Be @($script:eol.releases).Count
        foreach ($r in @($script:eol.releases)) {
            $hit = @($rows | Where-Object { $_.Groups[1].Value -eq $r.label -and $_.Groups[2].Value -eq $r.vendor -and $_.Groups[4].Value -eq $r.source })
            $hit.Count | Should -Be 1 -Because "$($r.label) has its row"
        }
        @($rows | Where-Object { $_.Groups[1].Value -eq 'Red Hat Enterprise Linux 7' })[0].Groups[3].Value | Should -Be '30 June 2024'
        @($rows | Where-Object { $_.Groups[1].Value -eq 'Ubuntu 18.04 LTS' })[0].Groups[3].Value | Should -Be 'May 2023'
    }
}

Describe 'EOL-RELEASE-AN-1: the network check no longer says the release is checked elsewhere' {
    It 'the Mellanox line names the rule the product applies' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'validate' 'DriverReadiness.ps1')
        $code | Should -Not -Match 'checked separately'
        $code | Should -Match 'end of standard support'
    }
}
