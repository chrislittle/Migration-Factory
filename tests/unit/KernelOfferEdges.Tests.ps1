#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# KERNEL-OFFER-EDGES-1 (2026-11-14, part of the 1.0 work):
# never offer, and never run, a kernel update that cannot succeed.
#
# Update the kernel was offered, and run, where the engine always stopped or
# where no update can reach Microsoft's minimum (driver-floors.json):
#   * Ubuntu on a kernel that is not linux-azure (-azure-fips, -generic): the
#     update script has no rule for it, and never swaps the flavour.
#   * Debian 12 on 6.1: Microsoft lists 6.12.21; the Debian 12 repositories give
#     kernel series 6.1, and Debian gives 6.12 in bookworm-backports
#     (packages.debian.org, read 2026-11-14). An update gave a real kernel
#     change, a restart and a rollback.
#   * SUSE on kernel-azure: Microsoft's rows are kernel-default numbers
#     (SP5 5.14.21-150500.55.121.2); SUSE numbers kernel-azure on its own line
#     (SUSE-SU-2024:1801-1: kernel-azure-5.14.21-150500.33.54.1), so an updated
#     kernel-azure is still read below the minimum - restart, then rollback.
#   * Red Hat and its rebuilds held to a minor release by the releasever
#     setting (Microsoft, RHUI certificate page: EUS, SAP and HA clients lock
#     releasever): an update stays on that minor release and cannot reach the
#     kernel of the later minor release Microsoft lists.
# The engine now refuses these before any change. Review (2026-11-14): never
# refuse an update that would succeed - only the running kernel's series
# counts (a Debian 12 backports 6.12 kernel is updated), SUSE only on the
# release its source covers, and the targets step bars nothing, because the
# scan reads neither the kernel nor the releasever setting.
#
# RHUI-REFRESH-1 (2026-11-14, the choice to run Microsoft's fix): the outcome of the
# update script says whether the RHUI client package was updated first.
#
# KERNEL-FLOOR-UPLOAD-1 (2026-11-14): Ubuntu's uname -r has no upload
# number (5.15.0-1096-azure), and Microsoft's minimum has one (5.15.0-1096.105).
# A kernel exactly at the minimum read below it. The guest reports the kernel
# package version; with it the engine compares the whole version, and without
# it a kernel equal to the minimum as far as uname goes is UNKNOWN, never below.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_MachineList.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:KoFacts([string]$Distro, [string]$Version, [string]$Kernel, [hashtable]$Extra = @{}) {
        $f = [ordered]@{ os = 'Linux'; distroId = $Distro; distroVersion = $Version; kernelVersion = $Kernel; fabric = 'mlx5' }
        foreach ($k in $Extra.Keys) { $f[$k] = $Extra[$k] }
        [pscustomobject]$f
    }
    function Global:KoResolve($Facts) {
        InModuleScope VmMigrationFactory -Parameters @{ f = $Facts } { param($f) Resolve-VmfKernelUpdate -Os 'Linux' -Facts $f }
    }
    function Global:KoVm([string]$Name, [hashtable]$Fields) {
        $vm = [ordered]@{
            vmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/$Name"
            name = $Name; location = 'centralus'; classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'
            osVersion = ''; imagePublisher = ''; imageOffer = ''; imageId = ''; runningOsName = ''; runningOsVersion = ''; licenseType = $null
            sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; sourceTempDisks = 0; diskController = 'SCSI'
            dataDiskCount = 0; nicCount = 1; acceleratedNicCount = 1; primaryNicAccelerated = $true
            platformManaged = $false; blockers = @(); prepNeeded = @()
        }
        foreach ($k in $Fields.Keys) { $vm[$k] = $Fields[$k] }
        [pscustomobject]$vm
    }

}
AfterAll {
    foreach ($f in 'KoFacts', 'KoResolve', 'KoVm') { Remove-Item "Function:\$f" -ErrorAction SilentlyContinue }
}

Describe 'KERNEL-OFFER-EDGES-1: the engine runs an update only where it can reach the minimum' {

    It 'Ubuntu on <Kernel>: no update, the flavour has no rule' -TestCases @(
        @{ Kernel = '5.15.0-1050-azure-fips' }
        @{ Kernel = '5.15.0-91-generic' }
    ) {
        $r = KoResolve (KoFacts 'ubuntu' '22.04' $Kernel)
        $r.Update | Should -BeFalse
        $r.NoRule | Should -BeTrue
        $r.CannotReach | Should -Not -BeTrue
        $r.Detail | Should -BeExactly "The machine runs the kernel $Kernel. On Ubuntu, the product updates only the Azure kernel, linux-azure. The product does not change the kernel flavour. The product did not update the kernel."
    }

    It 'Ubuntu on the Azure kernel: the update goes ahead, as before' {
        $r = KoResolve (KoFacts 'ubuntu' '22.04' '5.15.0-1031-azure')
        $r.Update | Should -BeTrue
        $r.NoRule | Should -Not -BeTrue
    }

    It 'the rule for Ubuntu is the rule of the update script (one rule, two places)' {
        $sh = Get-Content (Join-Path $script:repoRoot 'src' 'guest' 'linux' 'kernel-update.sh') -Raw
        # The script's case for Ubuntu: only *-azure has a package; anything else is NORULE.
        $sh | Should -Match '(?s)ubuntu\)\s+PM="apt-get"\s+case "\$KVER" in\s+\*-azure\)'
    }

    It 'Debian 12 on its own kernel series: no update, said with the series and where Debian gives the later one' {
        $r = KoResolve (KoFacts 'debian' '12' '6.1.0-41-cloud-amd64')
        $r.Update | Should -BeFalse
        $r.CannotReach | Should -BeTrue
        $r.Detail | Should -BeExactly 'The machine runs debian 12 with the kernel 6.1.0-41-cloud-amd64. Microsoft lists kernel 6.12.21 or later for MANA on debian 12. The repositories of debian 12 have kernel series 6.1. Debian supplies kernel series 6.12 in bookworm-backports. The product does not change the machine to a kernel from bookworm-backports. An update in kernel series 6.1 cannot reach the minimum version. The product did not update the kernel.'
    }

    It 'Debian 12 on a bookworm-backports 6.12 kernel below the minimum: not refused - backports upgrades it within 6.12' {
        $r = KoResolve (KoFacts 'debian' '12' '6.12.10+bpo-cloud-amd64')
        $r.Update | Should -BeTrue
        $r.CannotReach | Should -Not -BeTrue
    }

    It 'a kernel whose series cannot be read is not refused (Debian 12 on <Kernel>)' -TestCases @(
        @{ Kernel = 'custom' }
        @{ Kernel = '6' }
    ) {
        (KoResolve (KoFacts 'debian' '12' $Kernel)).CannotReach | Should -Not -BeTrue
    }

    It 'Debian 13 below the minimum: its repositories give 6.12, so the update goes ahead' {
        (KoResolve (KoFacts 'debian' '13' '6.12.10+deb13-cloud-amd64')).Update | Should -BeTrue
    }

    It 'SUSE on kernel-azure: no update, the numbers of kernel-azure are not the numbers of the minimum' {
        $r = KoResolve (KoFacts 'sles' '15.5' '5.14.21-150500.33.54-azure')
        $r.Update | Should -BeFalse
        $r.CannotReach | Should -BeTrue
        $r.Detail | Should -BeExactly 'The machine runs the kernel-azure kernel 5.14.21-150500.33.54-azure. Microsoft lists the minimum kernel for sles 15.5 as 5.14.21-150500.55.121.2. This is a version of the kernel-default package. SUSE uses different version numbers for kernel-azure. An updated kernel-azure kernel stays below 5.14.21-150500.55.121.2. The product does not change the kernel flavour. The product did not update the kernel.'
    }

    It 'SUSE <Version> on kernel-azure: no source says its numbers differ there, so the update goes ahead' -TestCases @(
        @{ Version = '15.6'; Kernel = '6.4.0-150600.8.20-azure' }
        @{ Version = '15.7'; Kernel = '6.4.0-150700.20.3-azure' }
        @{ Version = '16'; Kernel = '6.12.0-160000.3.1-azure' }
    ) {
        (KoResolve (KoFacts 'sles' $Version $Kernel)).Update | Should -BeTrue
    }

    It 'SUSE on kernel-default: the update goes ahead, as before' {
        (KoResolve (KoFacts 'sles' '15.5' '5.14.21-150500.55.100-default')).Update | Should -BeTrue
    }

    It '<Distro> <Version> held to <Lock> by releasever: update <Update>' -TestCases @(
        @{ Distro = 'rhel'; Version = '9.4'; Lock = '9.4'; Update = $false }
        @{ Distro = 'rocky'; Version = '9.4'; Lock = '9.4'; Update = $false }
        @{ Distro = 'almalinux'; Version = '9.2'; Lock = '9.2'; Update = $false }
        @{ Distro = 'rhel'; Version = '9.4'; Lock = 'none'; Update = $true }
        @{ Distro = 'rhel'; Version = '9.4'; Lock = 'unknown'; Update = $true }
        @{ Distro = 'rhel'; Version = '9.6'; Lock = '9.6'; Update = $true }
        @{ Distro = 'rhel'; Version = '9.4'; Lock = '9'; Update = $true }
    ) {
        $r = KoResolve (KoFacts $Distro $Version '5.14.0-427.13.1.el9_4.x86_64' @{ releaseverLock = $Lock })
        $r.Update | Should -Be $Update
        if (-not $Update) {
            $r.CannotReach | Should -BeTrue
            $r.Detail | Should -BeExactly "The releasever setting holds the machine on $Distro $Lock. The EUS, SAP and HA RHUI clients set this value. Microsoft lists $Distro 9.6 or later for MANA, with kernel 5.14.0-570.52.1 or later. An update on $Distro $Lock cannot reach the minimum version. The product did not update the kernel."
        }
    }

    It 'a machine that reported no releasever setting (an older guest) is updated as before' {
        (KoResolve (KoFacts 'rhel' '9.4' '5.14.0-427.13.1.el9_4.x86_64')).Update | Should -BeTrue
    }

    It 'the facts behind the refusals are data, each with its source' {
        $f = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'driver-floors.json') -Raw | ConvertFrom-Json
        $deb = @($f.mana.linux.updateCannotReach.releases) | Where-Object { $_.id -eq 'debian' -and $_.versionId -eq '12' }
        $deb.repositoryKernelSeries | Should -Be '6.1'
        $deb.laterSeries | Should -Be '6.12'
        $deb.laterIn | Should -Be 'bookworm-backports'
        @($deb.sources) | Should -Contain 'https://packages.debian.org/bookworm/linux-image-cloud-amd64'
        @($deb.sources) | Should -Contain 'https://packages.debian.org/bookworm-backports/linux-image-cloud-amd64'
        $sles = @($f.mana.linux.updateCannotReach.flavours) | Where-Object { $_.id -eq 'sles' }
        $sles.kernelSuffix | Should -Be '-azure'
        @($sles.versionIds) | Should -Be @('15.5') -Because 'the SUSE advisory covers SP5 only'
        @($deb.sources) | Should -Contain 'https://backports.debian.org/Instructions/'
        $sles.package | Should -Be 'kernel-azure'
        @($sles.sources) | Should -Contain 'https://ftp.suse.com/pub/projects/security/cvrf/cvrf-suse-su-2024:1801-1.xml'
        @($f.sources.url) | Should -Contain 'https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-machines/linux/troubleshoot-linux-rhui-certificate-issues'
    }

    It 'no row in the data makes no refusal: a release with no entry is updated as before' {
        $floors = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'driver-floors.json') -Raw | ConvertFrom-Json
        $floors.mana.linux.updateCannotReach.releases = @()
        $floors.mana.linux.updateCannotReach.flavours = @()
        InModuleScope VmMigrationFactory -Parameters @{ fl = $floors } {
            param($fl)
            (Resolve-VmfKernelUpdate -Os 'Linux' -Facts ([pscustomobject]@{ distroId = 'debian'; distroVersion = '12'; kernelVersion = '6.1.0-41-cloud-amd64' }) -Floors $fl).Update | Should -BeTrue
            (Resolve-VmfKernelUpdate -Os 'Linux' -Facts ([pscustomobject]@{ distroId = 'sles'; distroVersion = '15.5'; kernelVersion = '5.14.21-150500.33.54-azure' }) -Floors $fl).Update | Should -BeTrue
        }
    }

    It 'the stop has its own reason, untouched, and its advice never sends the person back to Update the kernel' {
        InModuleScope VmMigrationFactory {
            $g = Get-VmfStopGuidance -Code 'kernelUpdateCannotReachMinimum'
            $g | Should -Not -BeNullOrEmpty
            $g.machine | Should -Be 'untouched'
            $g.retry | Should -Be 'afterFix'
            $g.whatToDo | Should -Not -Match 'Choose Update the kernel'
            $g.title | Should -BeExactly 'An update cannot reach the kernel version that Microsoft lists for MANA'
        }
    }
}

Describe 'KERNEL-OFFER-EDGES-1 (review): the targets step bars nothing it cannot know' {
    # The rule: never refuse, or bar, an update that would succeed. The scan
    # reads Azure, not the guest, so it knows neither the running kernel nor
    # the releasever setting: an EUS image may since have moved off EUS, and a
    # Debian 12 machine may run a backports 6.12 kernel. Preparing judges.
    It 'a plan entry from an EUS image, and Debian 12 from the VM agent, are offered Update the kernel' {
        InModuleScope VmMigrationFactory {
            $entry = { param($a) [pscustomobject]@{ assessment = $a; target = [pscustomobject]@{ size = 'Standard_D2s_v6'; controller = 'NVMe' } } }
            $eus = [pscustomobject]@{ os = 'Linux'; imagePublisher = 'RedHat'; imageOffer = 'RHEL'; osVersion = '94_gen2'; runningOsName = 'redhat'; runningOsVersion = '9.4' }
            $deb = [pscustomobject]@{ os = 'Linux'; runningOsName = 'debian'; runningOsVersion = '12' }
            Test-VmfKernelUpdateOfferedForEntry -PlanEntry (& $entry $eus) | Should -BeTrue
            Test-VmfKernelUpdateOfferedForEntry -PlanEntry (& $entry $deb) | Should -BeTrue
            Get-Command Get-VmfKernelUpdateBar -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            Get-VmfTargetAdviceSchemaVersion | Should -Be 34   # IMAGE-SCRIPT-MATCH-1 v32, TARGET-CAPABILITY-PRECHECK-1 v33 (main)
        }
    }
}
Describe 'RHUI-REFRESH-1: what the update script answered about the RHUI client' {
    BeforeAll {
        function Global:KoOut([string]$Result, [string]$RhuiStatus, [string]$RhuiDetail, [string]$Ran = 'yes') {
            $checks = @(
                [pscustomobject]@{ name = 'kernel before'; status = 'INFO'; detail = '5.14.0-570.12.1.el9_6.x86_64' }
                [pscustomobject]@{ name = 'package manager ran'; status = 'INFO'; detail = $Ran })
            if ($RhuiStatus) { $checks += [pscustomobject]@{ name = 'rhui client'; status = $RhuiStatus; detail = $RhuiDetail } }
            $checks += [pscustomobject]@{ name = 'package manager'; status = 'INFO'; detail = 'dnf' }
            $checks += [pscustomobject]@{ name = 'kernel package'; status = 'INFO'; detail = 'kernel' }
            $checks += [pscustomobject]@{ name = 'kernel installed'; status = 'INFO'; detail = '5.14.0-570.60.1.el9_6.x86_64' }
            [pscustomobject]@{ schema = 'vmf.guest/2'; script = 'kernel-update.sh'; version = '1.2.0'; os = 'rhel 9.6'; result = $Result; warnings = @(); checks = $checks }
        }
    }
    AfterAll { Remove-Item 'Function:\KoOut' -ErrorAction SilentlyContinue }

    It 'a refreshed client is said first, then the kernel' {
        $o = InModuleScope VmMigrationFactory -Parameters @{ g = (KoOut 'FIXED' 'FIXED' 'The package manager updated rhui-azure-rhel9-2.3-656 to rhui-azure-rhel9-2.3-916.') } { param($g) Get-VmfKernelUpdateOutcome -GuestOutput $g }
        $o.Restart | Should -BeTrue
        $o.RhuiRefreshed | Should -BeTrue
        $o.Detail | Should -BeExactly 'First, the package manager updated the RHUI client package from rhui-azure-rhel9-2.3-656 to rhui-azure-rhel9-2.3-916. It used the Microsoft repository. The package manager installed kernel 5.14.0-570.60.1.el9_6.x86_64. The machine runs kernel 5.14.0-570.12.1.el9_6.x86_64 until it restarts.'
    }

    It 'a client that was current says nothing more' {
        $o = InModuleScope VmMigrationFactory -Parameters @{ g = (KoOut 'FIXED' 'INFO' 'The Microsoft repository has no newer package than rhui-azure-rhel9-2.3-916.') } { param($g) Get-VmfKernelUpdateOutcome -GuestOutput $g }
        $o.RhuiRefreshed | Should -BeFalse
        $o.Detail | Should -BeExactly 'The package manager installed kernel 5.14.0-570.60.1.el9_6.x86_64. The machine runs kernel 5.14.0-570.12.1.el9_6.x86_64 until it restarts.'
    }

    It 'a refreshed client then no newer kernel: the machine changed, so it is not untouched (it goes back to its copy)' {
        $o = InModuleScope VmMigrationFactory -Parameters @{ g = (KoOut 'NO_CHANGE' 'FIXED' 'The package manager updated rhui-azure-rhel9-2.3-656 to rhui-azure-rhel9-2.3-916.') } { param($g) Get-VmfKernelUpdateOutcome -GuestOutput $g }
        $o.Restart | Should -BeFalse
        $o.Changed | Should -BeTrue
    }

    It 'a FIXED check whose two versions are the same is no change (review)' {
        $o = InModuleScope VmMigrationFactory -Parameters @{ g = (KoOut 'NO_CHANGE' 'FIXED' 'The package manager updated rhui-azure-rhel9-2.3-916 to rhui-azure-rhel9-2.3-916.') } { param($g) Get-VmfKernelUpdateOutcome -GuestOutput $g }
        $o.RhuiRefreshed | Should -BeFalse
        $o.Changed | Should -BeFalse
    }

    It 'the words the script writes for a refreshed client are the words the engine reads (one sentence, two places)' {
        $sh = Get-Content (Join-Path $script:repoRoot 'src' 'guest' 'linux' 'kernel-update.sh') -Raw
        $sh | Should -Match ([regex]::Escape('add_check "rhui client" "FIXED" "The package manager updated $RHUI_BEFORE to $RHUI_AFTER."'))
    }

    It 'no newer kernel and no refresh: untouched, as before' {
        $o = InModuleScope VmMigrationFactory -Parameters @{ g = (KoOut 'NO_CHANGE' 'INFO' 'The Microsoft repository has no newer package than rhui-azure-rhel9-2.3-916.') } { param($g) Get-VmfKernelUpdateOutcome -GuestOutput $g }
        $o.Changed | Should -BeFalse
    }
}

Describe 'KERNEL-FLOOR-UPLOAD-1: a kernel at the minimum is not read below it' {
    It '<Case>' -TestCases @(
        @{ Case = 'uname 5.15.0-1096-azure, package 5.15.0-1096.105: at the minimum'; Kernel = '5.15.0-1096-azure'; Package = '5.15.0-1096.105'; Status = 'PASS' }
        @{ Case = 'uname 5.15.0-1096-azure, package 5.15.0-1096.104: below'; Kernel = '5.15.0-1096-azure'; Package = '5.15.0-1096.104'; Status = 'FAIL' }
        @{ Case = 'uname 5.15.0-1096-azure, package 5.15.0-1096.110: above'; Kernel = '5.15.0-1096-azure'; Package = '5.15.0-1096.110'; Status = 'PASS' }
        @{ Case = 'uname 5.15.0-1096-azure, no package version: cannot tell'; Kernel = '5.15.0-1096-azure'; Package = ''; Status = 'UNKNOWN' }
        @{ Case = 'uname 5.15.0-1096-azure, package unknown: cannot tell'; Kernel = '5.15.0-1096-azure'; Package = 'unknown'; Status = 'UNKNOWN' }
        @{ Case = 'uname 5.15.0-1096-azure, a package version with no upload number: cannot tell'; Kernel = '5.15.0-1096-azure'; Package = '5.15.0-1096'; Status = 'UNKNOWN' }
        @{ Case = 'uname 5.15.0-1095-azure, no package version: below, as uname already says'; Kernel = '5.15.0-1095-azure'; Package = ''; Status = 'FAIL' }
        @{ Case = 'uname 5.15.0-1102-azure, no package version: above'; Kernel = '5.15.0-1102-azure'; Package = ''; Status = 'PASS' }
    ) {
        $extra = @{}
        if ($Package) { $extra.kernelPackageVersion = $Package }
        $facts = KoFacts 'ubuntu' '22.04' $Kernel $extra
        $v = InModuleScope VmMigrationFactory -Parameters @{ f = $facts } { param($f) Get-VmfDriverJudgement -Facts $f -TargetIsBoost $true }
        $v.Status | Should -Be $Status
    }

    It 'the cannot-tell answer says why, and never says below' {
        $facts = KoFacts 'ubuntu' '22.04' '5.15.0-1096-azure'
        $v = InModuleScope VmMigrationFactory -Parameters @{ f = $facts } { param($f) Get-VmfDriverJudgement -Facts $f -TargetIsBoost $true }
        $v.Detail | Should -BeExactly 'the numbers of kernel 5.15.0-1096-azure are the first numbers of the published minimum 5.15.0-1096.105 for ubuntu 22.04. The minimum has more numbers. The machine did not report the version of its kernel package. The product does not know if the kernel is at the minimum.'
        $v.Detail | Should -Not -Match 'below'
    }

    It 'the package version is compared in its place: at the minimum, and below it' {
        $at = InModuleScope VmMigrationFactory { Get-VmfDriverJudgement -Facts ([pscustomobject]@{ os = 'Linux'; distroId = 'ubuntu'; distroVersion = '22.04'; kernelVersion = '5.15.0-1096-azure'; kernelPackageVersion = '5.15.0-1096.105' }) }
        $at.Detail | Should -BeExactly 'kernel 5.15.0-1096-azure (package version 5.15.0-1096.105) meets the published minimum 5.15.0-1096.105 for ubuntu 22.04'
        $below = InModuleScope VmMigrationFactory { Get-VmfDriverJudgement -Facts ([pscustomobject]@{ os = 'Linux'; distroId = 'ubuntu'; distroVersion = '22.04'; kernelVersion = '5.15.0-1096-azure'; kernelPackageVersion = '5.15.0-1096.104' }) }
        $below.MinKernel | Should -Be '5.15.0-1096.105'
        $below.Detail | Should -Match '^kernel 5\.15\.0-1096-azure \(package version 5\.15\.0-1096\.104\) is below the published minimum 5\.15\.0-1096\.105'
    }

    It 'a package version of another kernel is never used (it must start with the numbers of uname)' {
        $facts = KoFacts 'ubuntu' '22.04' '5.15.0-1096-azure' @{ kernelPackageVersion = '6.8.0-1041.47' }
        $v = InModuleScope VmMigrationFactory -Parameters @{ f = $facts } { param($f) Get-VmfDriverJudgement -Facts $f -TargetIsBoost $true }
        $v.Status | Should -Be 'UNKNOWN'
    }

    It 'the guest contract declares the two new facts (vmf.guest/6)' {
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'guest-output.schema.json') -Raw | ConvertFrom-Json
        @($schema.properties.schema.enum) | Should -Contain 'vmf.guest/6'
        $schema.properties.facts.properties.kernelPackageVersion.type | Should -Be 'string'
        $schema.properties.facts.properties.releaseverLock.type | Should -Be 'string'
        $v6 = '{"schema":"vmf.guest/6","script":"mana-check.sh","version":"1.3.0","result":"READY","checks":[],"facts":{"kernelPackageVersion":"5.15.0-1096.105","releaseverLock":"none"}}'
        $v6 | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'guest-output.schema.json') | Should -BeTrue
        { ConvertFrom-VmfGuestOutput -RawOutput $v6 } | Should -Not -Throw
    }
}
