# DRIVER-1: judging accelerated-networking driver readiness.
#
# Why this exists, in Microsoft's own words: "The Azure platform doesn't update
# the Mellanox NIC or MANA drivers in the VM." The guest owns its driver, so a
# machine can land on Boost hardware and quietly lose accelerated networking
# with nothing on the platform side to notice.
#
# What is knowable, and what is not (see data/driver-floors.json for sources):
#   MANA / Linux    a published per-distribution minimum kernel table exists.
#                   Real floor, copied verbatim, compared properly.
#   MANA / Windows  NO published minimum driver version. Recorded as a fact.
#   Mellanox        NO version floor at all - the published rule is "endorsed
#                   distro, not end of life", which is IMAGE-1's question.
#
# Guests report facts; this judges them. Unknown is never turned into a pass
# or a fail, and no floor is ever invented.

function Get-VmfDriverFloors {
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter()][string]$Path)

    if (-not $script:VmfDriverFloors -or $Path) {
        $file = if ($Path) { $Path } else { Join-Path $script:VmfModuleRoot 'data' 'driver-floors.json' }
        $script:VmfDriverFloors = Get-Content $file -Raw -Encoding utf8 | ConvertFrom-Json
    }
    $script:VmfDriverFloors
}

function Compare-VmfKernelVersion {
    <#
    .SYNOPSIS
        Compare two kernel version strings. -1 / 0 / 1, or $null when the
        comparison cannot be made honestly.
    .DESCRIPTION
        Distributions decorate the same ordering differently: Ubuntu appends
        -azure or -generic, Red Hat prefixes kernel- and suffixes .el9_6. The
        numbers in order are what carry the meaning, so both sides are reduced
        to their numeric segments and compared element by element - numerically,
        because '10' must sort above '9'.

        A missing or unparseable side returns $null. A wrong answer here would
        block a healthy machine or wave through a broken one.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()][AllowNull()][string]$Running,
        [Parameter()][AllowNull()][string]$Floor
    )

    if ([string]::IsNullOrWhiteSpace($Running) -or [string]::IsNullOrWhiteSpace($Floor)) { return $null }

    # LINUX-VERSION-OVERFLOW-1: a segment that does not fit a 64-bit number
    # is read as nothing, and the comparison is not made - unknown, never a
    # pass and never a fail. A cast threw, and stopped the caller.
    $segmentsOf = {
        param([string]$Text)
        $clean = $Text -replace '^\s*kernel-', ''
        @([regex]::Matches($clean, '\d+') | ForEach-Object { ConvertTo-VmfBoundedNumber -Text $_.Value -Long })
    }
    $a = @(& $segmentsOf $Running)
    $b = @(& $segmentsOf $Floor)
    if ($a.Count -eq 0 -or $b.Count -eq 0) { return $null }
    if (@($a + $b | Where-Object { $null -eq $_ }).Count) { return $null }

    $len = [math]::Min($a.Count, $b.Count)
    for ($i = 0; $i -lt $len; $i++) {
        if ($a[$i] -gt $b[$i]) { return 1 }
        if ($a[$i] -lt $b[$i]) { return -1 }
    }
    # Equal as far as both go. A longer floor (5.15.0-1096.105 vs 5.15.0-1096)
    # means the floor is more specific and therefore higher.
    if ($b.Count -gt $a.Count) { return -1 }
    if ($a.Count -gt $b.Count) { return 1 }
    0
}

function ConvertTo-VmfGuestFacts {
    <#
    .SYNOPSIS
        The facts a guest reported, as a plain object the engine can judge.
    .DESCRIPTION
        GUEST-2: `vmf.guest/2` carries a DECLARED `facts` object, so the facts
        are part of the contract rather than a naming convention riding on the
        checks list. Under v1 they travelled as checks named "fact:<name>",
        which meant nothing declared which facts existed - a guest could omit
        one and nothing noticed, which is exactly how every Windows machine came
        to report an UNKNOWN driver state (DRIVER-2).

        Both are read here, and only here. v1 evidence stays readable because a
        support bundle or a resumed wave must not become unreadable when the
        contract moves; what the declared object says always wins.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter()][AllowNull()]$GuestOutput)

    $facts = [ordered]@{}

    # GUEST-2: a declared `facts` object is the contract now. Read it first.
    if ($GuestOutput -and $GuestOutput.PSObject.Properties['facts'] -and $GuestOutput.facts) {
        foreach ($p in $GuestOutput.facts.PSObject.Properties) { $facts[$p.Name] = [string]$p.Value }
    }

    # v1 evidence, still readable: facts travelled as checks named "fact:<name>".
    # Kept for stored output from earlier runs - a support bundle or a resumed
    # wave must not become unreadable because the contract moved. Anything the
    # declared object already said WINS; this only fills gaps.
    foreach ($c in @($GuestOutput.checks)) {
        $name = [string]$c.name
        if ($name -like 'fact:*') {
            $key = $name.Substring(5)
            if (-not $facts.Contains($key)) { $facts[$key] = [string]$c.detail }
        }
    }

    # Last resort only. The OS caption is NOT the fact - reading it as one is
    # what made every Windows machine report UNKNOWN (DRIVER-2). A v2 guest
    # always states `os` outright, so this is reached only for old evidence.
    if ($GuestOutput -and $GuestOutput.os -and -not $facts.Contains('os')) {
        $facts['os'] = [string]$GuestOutput.os
    }
    [pscustomobject]$facts
}

function Find-VmfManaTableEntry {
    <#
    .SYNOPSIS
        RHEL8-MANA-1: the row of Microsoft's MANA table that covers this
        machine, or nothing when the table does not cover it.
    .DESCRIPTION
        Each row names a MINIMUM release, so on a distribution named in
        coveredByEarlierRow a later minor release of the same major is covered
        by the nearest row at or below it: Red Hat 9.8 by the 9.6 row
        (measured - it got MANA), SUSE 15 SP8 by SP7. Any other distribution
        takes a row only for its exact release: Ubuntu 24.10 is not covered by
        the 24.04 row (KERNEL-MINOR-ROW-1). An earlier release
        is not covered: SUSE 15 SP4, Red Hat 8 - except an earlier minor on a
        distribution where a normal update reaches the row (Red Hat 9.4, Rocky
        and Alma 9.x: minorReachedByUpdate, AN-MANA-DRIVER-RULE-1), which is
        judged against the lowest row of its major above it. A release the row
        names with no minor (Debian 12, Oracle Linux 9) covers every minor of it.

        Oracle Linux has two kernels and the table rows them separately: the
        Red Hat compatible kernel by release, and UEK by kernel series. A UEK
        kernel ('uek' in its release string) is matched only against UEK rows.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$DistroId,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$DistroVersion,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Kernel,
        [Parameter()][AllowNull()]$Floors
    )

    if (-not $DistroId) { return $null }
    $f = if ($Floors) { $Floors } else { Get-VmfDriverFloors }
    $id = $DistroId.ToLowerInvariant()
    $isUek = $Kernel -match '(?i)uek'
    $rows = @(@($f.mana.linux.distros) | Where-Object {
            $_.id -eq $id -and ([string]$_.kernelFlavor -eq 'uek') -eq $isUek })
    if ($isUek) {
        return $rows | Where-Object { $Kernel -like "$($_.kernelSeries).*" } | Select-Object -First 1
    }

    # LINUX-VERSION-OVERFLOW-1: no row covers a release nobody can read. A
    # part that does not fit a 32-bit number (9.99999999999) threw below, in
    # the scan, the advice and the run; it matched a row by its first parts.
    if (-not (Test-VmfVersionInRange -Version $DistroVersion)) { return $null }

    $exact = $rows | Where-Object { $_.versionId -eq $DistroVersion -or $DistroVersion -like "$($_.versionId).*" } | Select-Object -First 1
    if ($exact) { return $exact }

    $split = {
        param([string]$v)
        $parts = $v -split '\.'
        $minor = if ($parts.Count -gt 1 -and $parts[1] -match '^\d+') { [int]($parts[1] -replace '\D.*$', '') } else { $null }
        [pscustomobject]@{ major = $parts[0]; minor = $minor }
    }
    $mine = & $split $DistroVersion
    if ($null -eq $mine.minor) { return $null }
    # KERNEL-MINOR-ROW-1 (2026-11-21): only a distribution named in
    # coveredByEarlierRow is covered by an earlier row of its major. Ubuntu
    # 24.10 got the 24.04 row, and Microsoft lists 24.04 only. An Ubuntu
    # version is YY.MM: 24.10 is an interim release with its own kernel
    # series, not a later minor release of 24.04. With no row it is a release
    # Microsoft does not list, as 20.04 is - never a floor the table does not
    # give.
    $coveredIds = if ($f.mana.linux.PSObject.Properties['coveredByEarlierRow']) { @($f.mana.linux.coveredByEarlierRow.ids) } else { @() }
    if ($coveredIds -contains $id) {
        $covering = $rows | ForEach-Object {
            $row = $_
            $v = & $split ([string]$row.versionId)
            if ($v.major -eq $mine.major -and $null -ne $v.minor -and $v.minor -le $mine.minor) {
                [pscustomobject]@{ row = $row; minor = $v.minor }
            }
        } | Sort-Object minor -Descending | Select-Object -First 1 | ForEach-Object { $_.row }
        if ($covering) { return $covering }
    }

    # AN-MANA-DRIVER-RULE-1 (2026-11-06): on Red Hat and its rebuilds
    # a normal update within the major reaches a later minor release, and its
    # kernel (minorReachedByUpdate). So Red Hat 9.4 is judged against the 9.6
    # row - the LOWEST row of its major above it: its kernel must meet that
    # row's minimum, as a listed release's kernel must, and Update the kernel
    # brings it there. Before, 9.4 was a release Microsoft does not list, and
    # nothing offered the update. SUSE is not on the list: a service pack is
    # not a normal update, so SUSE 15 SP4 stays unlisted.
    if (@($f.mana.linux.minorReachedByUpdate.ids) -notcontains $id) { return $null }
    $rows | ForEach-Object {
        $row = $_
        $v = & $split ([string]$row.versionId)
        if ($v.major -eq $mine.major -and $null -ne $v.minor -and $v.minor -gt $mine.minor) {
            [pscustomobject]@{ row = $row; minor = $v.minor }
        }
    } | Sort-Object minor | Select-Object -First 1 | ForEach-Object { $_.row }
}
function Get-VmfDriverJudgement {
    <#
    .SYNOPSIS
        DRIVER-1: is this machine's accelerated-networking driver good enough?
    .OUTPUTS
        @{ Status = PASS|FAIL|INFO|UNKNOWN; Detail = <plain language> }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()]$Facts,
        [Parameter()][AllowNull()]$Floors,
        # Is the machine HEADING for Boost hardware (an NVMe target)? Found by
        # the DRIVER-1 drill: before migration a v4 machine is on MELLANOX, so
        # judging the fabric it currently has answers the wrong question
        # entirely - "no floor for Mellanox" - and lets a below-floor kernel
        # walk into a post-migration failure. What matters is the fabric it is
        # MOVING TO. Facts come from the guest; the plan decides what to judge.
        [Parameter()][bool]$TargetIsBoost = $true
    )

    if (-not $Facts) {
        return @{ Status = 'UNKNOWN'; Detail = 'the machine reported nothing about its network driver' }
    }

    $f = if ($Floors) { $Floors } else { Get-VmfDriverFloors }
    $fabric = [string]$Facts.fabric
    # Found by the UPST-2 drill: this was an EXACT match against 'Windows', but
    # the Windows guest emits no `fact:os` at all, so the engine fell back to
    # the OS caption - "Microsoft Windows Server 2022 Datacenter (10.0.20348)".
    # That is not equal to 'Windows', so every Windows machine was judged down
    # the MANA-on-LINUX path, found no kernel version, and reported UNKNOWN -
    # while the Windows driver version we deliberately record was never
    # recorded. The same shape of mistake as DRIVER-1 itself: the judgement
    # took the wrong branch and said something plausible.
    #
    # Both ends are fixed - the guests now emit `fact:os` explicitly - but the
    # engine must not depend on that alone, or old guest output silently takes
    # the wrong branch again.
    $guestIsWindows = [string]$Facts.os -match '(?i)windows'

    # The MANA kernel floor applies when the machine will be on MANA - either
    # because it is already, or because that is where the plan is sending it.
    $judgeMana = (-not $guestIsWindows) -and ($TargetIsBoost -or $fabric -match '(?i)mana')

    if (-not $judgeMana) {
        if ($guestIsWindows) {
            $v = [string]$Facts.driverVersion
            return @{
                Status = 'INFO'
                Detail = $(if ($v) { "network driver version $v (Microsoft publishes no minimum version for Windows, so this is recorded rather than judged)" }
                           else { 'the machine did not report a network driver version' })
            }
        }
        if ($fabric -match '(?i)mlx') {
            return @{
                Status = 'INFO'
                Detail = 'This machine stays on a Mellanox adapter. Microsoft publishes no minimum driver version for the Mellanox adapter. Microsoft supports the Mellanox adapter only on Linux releases that the vendor has not marked as end of life. The scan shows the end of standard support of the release.'
            }
        }
        return @{ Status = 'INFO'; Detail = 'this machine has no accelerated network adapter' }
    }

    # MANA on Linux: the one place a real, published floor exists.
    $distroId = ([string]$Facts.distroId).ToLowerInvariant()
    $distroVersion = [string]$Facts.distroVersion
    $kernel = [string]$Facts.kernelVersion
    if (-not $kernel) {
        return @{ Status = 'UNKNOWN'; Detail = 'the machine did not report its kernel version' }
    }

    $entry = Find-VmfManaTableEntry -DistroId $distroId -DistroVersion $distroVersion -Kernel $kernel -Floors $f

    if (-not $entry) {
        return @{
            Status = 'UNKNOWN'
            Detail = "$distroId $distroVersion is not listed in the published support table, so there is no floor to check this kernel ($kernel) against"
        }
    }
    if (-not $entry.minKernel) {
        return @{ Status = 'PASS'; Detail = "$distroId $distroVersion is supported on any version of its kernel series ($kernel)" }
    }

    $min = [string]$entry.minKernel
    $cmp = Compare-VmfKernelVersion -Running $kernel -Floor $min
    if ($null -eq $cmp) {
        return @{ Status = 'UNKNOWN'; Detail = "could not compare kernel '$kernel' with the published minimum '$min'" }
    }
    # KERNEL-FLOOR-UPLOAD-1 (2026-11-14): Ubuntu's uname -r has no
    # upload number (5.15.0-1096-azure) and Microsoft's minimum has one
    # (5.15.0-1096.105). Ubuntu's kernel version is base-ABI.upload, and the
    # upload number is in the kernel PACKAGE version, not in uname
    # (https://wiki.ubuntu.com/Kernel/FAQ/GeneralVersionMeaning). So where
    # the running kernel equals the minimum as far as its numbers go, and the
    # minimum has more, the package version mana-check.sh reports decides -
    # only when it starts with the numbers of uname (the package of THIS
    # kernel). Without it the answer is UNKNOWN: the product cannot tell, and
    # never says below.
    $label = $kernel
    if ($cmp -lt 0 -and (Test-VmfKernelVersionPrefix -Running $kernel -Floor $min)) {
        $pkg = if ($Facts.PSObject.Properties['kernelPackageVersion']) { ([string]$Facts.kernelPackageVersion).Trim() } else { '' }
        # 'unknown' (dpkg-query gave none) has no numbers, so the prefix rule
        # refuses it as it refuses a package of another kernel.
        if (-not $pkg -or -not (Test-VmfKernelVersionPrefix -Running $pkg -Floor $kernel -Within)) {
            return @{ Status = 'UNKNOWN'
                Detail = "the numbers of kernel $kernel are the first numbers of the published minimum $min for $distroId $distroVersion. The minimum has more numbers. The machine did not report the version of its kernel package. The product does not know if the kernel is at the minimum." }
        }
        $cmp = Compare-VmfKernelVersion -Running $pkg -Floor $min
        if ($null -eq $cmp) {
            return @{ Status = 'UNKNOWN'; Detail = "could not compare kernel '$kernel' with the published minimum '$min'" }
        }
        $label = "$kernel (package version $pkg)"
    }
    if ($cmp -lt 0) {
        return @{
            Status = 'FAIL'
            # ORACLE-UEK-UPDATE-1: the minimum, for the line that says an update comes next.
            MinKernel = $min
            Detail = "kernel $label is below the published minimum $min for $distroId $distroVersion. The target hardware uses the Microsoft Azure Network Adapter. Accelerated networking can fail after the move."
        }
    }
    @{ Status = 'PASS'; Detail = "kernel $label meets the published minimum $min for $distroId $distroVersion" }
}

function Test-VmfKernelVersionPrefix {
    <#
    .SYNOPSIS
        KERNEL-FLOOR-UPLOAD-1: are the numbers of one version the first numbers
        of the other? Pure.
    .DESCRIPTION
        Default: the running kernel's numbers are all the first numbers of the
        floor, and the floor has more (5.15.0-1096-azure and 5.15.0-1096.105) -
        the one case Compare-VmfKernelVersion reads as below without knowing.
        -Within: the numbers of -Floor are all the first numbers of -Running
        (a package version 5.15.0-1096.105 of the kernel 5.15.0-1096-azure).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Running,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Floor,
        [switch]$Within
    )
    # LINUX-VERSION-OVERFLOW-1: a number that does not fit is not read, and
    # nothing is a prefix of a version nobody can read.
    $nums = { param([string]$s) @([regex]::Matches(($s -replace '^\s*kernel-', ''), '\d+') | ForEach-Object { ConvertTo-VmfBoundedNumber -Text $_.Value -Long }) }
    $short = @(& $nums $(if ($Within) { $Floor } else { $Running }))
    $long = @(& $nums $(if ($Within) { $Running } else { $Floor }))
    if (@($short + $long | Where-Object { $null -eq $_ }).Count) { return $false }
    if ($short.Count -eq 0 -or $long.Count -le $short.Count) { return $false }
    for ($i = 0; $i -lt $short.Count; $i++) { if ($short[$i] -ne $long[$i]) { return $false } }
    $true
}

# AN-KEEP-1, Gen1 Microsoft-route drill 2026-09-25: an Ubuntu 18.04 machine had
# accelerated networking OFF, the engine switched it ON for the v6 target, the
# kernel had no MANA driver, and VALIDATING failed a machine that would have
# moved fine with the network it already had. The answer then was to keep it
# off ('preserve'). AN-MANA-DRIVER-RULE-1 (2026-11-06) replaced that:
# MEASURED on 2026-11-06 (centralus, Ubuntu 22.04, one region, one day), with
# the interface's accelerated networking set to false Azure still attached the
# virtual function on Intel v5, Bsv2, AMD v6, Intel v6 and v7 and AMD v7 - only
# AMD v5 gave none. So off is not off on a size that can give MANA, and a
# machine with no driver runs on the synthetic interface. The rule: never use
# NetVSC. A size that can give MANA needs a machine with a MANA driver, and
# accelerated networking is always on there.
function Get-VmfManaDriverPresence {
    <#
    .SYNOPSIS
        AN-KEEP-1: does the machine's own software carry a MANA driver, read
        BEFORE the move? 'present', 'absent', 'unlisted' or 'unknown'.
    .DESCRIPTION
        Linux: mana-check.sh's "mana module available" check - `modinfo mana`
        against the running kernel. The kernel carries the driver or it does
        not; nothing installs one at boot. That is a definite answer.

        Microsoft's per-distribution table does not decide 'present' alone:
        a kernel with the module is 'present' when the table lists the
        release, or the kernel is 6.14 or later (fallbackForUnlistedDistros),
        and 'unlisted' otherwise (RHEL8-MANA-1) - handled as 'absent'.
        Before the guest is read, the same table answer for the release the
        Azure Linux Agent reports (Test-VmfReleaseKnownUnlisted) sets the
        interface count of the targets step and Checking (AN-ONE-NIC-2). This
        reading, at GUEST_PREP, is the one the move uses, and GUEST_PREP asks
        the count again when it turns the primary interface on after all
        (Test-VmfGuestPrepAcceleratedNicsFit).

        Windows: ALWAYS 'unknown'. Measured in this repository's run evidence:
        two Windows machines reported no mana*.sys before their move
        (2026-09-03, 2026-09-25) and a bound MANA adapter after it, and both
        passed. Windows installs its in-box driver when the hardware appears,
        so a missing file before the move says nothing about after it.
        MANA-WIN-1 reads the Windows DRIVER STORE separately, in GUEST_PREP,
        and adds the pinned driver when the store has none - so this decision
        never has to keep accelerated networking off for a Windows machine.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()]$GuestOutput,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Os,
        # RHEL8-MANA-1: what the machine reported about itself, to set against
        # Microsoft's MANA table. Without it, only the module is read.
        [Parameter()][AllowNull()]$Facts,
        [Parameter()][AllowNull()]$Floors
    )

    if ($Os -match '(?i)windows') { return 'unknown' }
    $check = @($GuestOutput.checks) | Where-Object { $_ -and [string]$_.name -eq 'mana module available' } | Select-Object -First 1
    if (-not $check) { return 'unknown' }
    if ([string]$check.status -eq 'WARN') { return 'absent' }
    if ([string]$check.status -ne 'PASS') { return 'unknown' }

    # RHEL8-MANA-1: a module is not support. Red Hat 8.10's kernel carries
    # mana.ko, it loaded on D2ds_v6, and nothing bound - and Microsoft's table
    # does not list Red Hat 8. So the table decides: 'unlisted' is handled
    # exactly as 'absent' is.
    if (-not $Facts -or -not [string]$Facts.distroId) { return 'present' }
    $f = if ($Floors) { $Floors } else { Get-VmfDriverFloors }
    $kernel = [string]$Facts.kernelVersion
    if (Find-VmfManaTableEntry -DistroId ([string]$Facts.distroId) -DistroVersion ([string]$Facts.distroVersion) -Kernel $kernel -Floors $f) {
        return 'present'
    }
    $cmp = Compare-VmfKernelVersion -Running $kernel -Floor ([string]$f.mana.linux.fallbackForUnlistedDistros.minKernel)
    if ($null -eq $cmp) { return 'unknown' }
    # The fallback (a kernel of 6.14 or later) does not depend on the release,
    # so it stands for any release.
    if ($cmp -ge 0) { return 'present' }
    # LINUX-VERSION-OVERFLOW-1: a release version with a number that does not
    # fit is a release the product cannot read, not an unlisted one.
    # Find-VmfManaTableEntry gives no row for it, so 'unlisted' here would be
    # a no made from a value nobody read - unknown is never a no. (A UEK
    # kernel is matched by its series, not by the release, so its answer
    # stands.)
    $distroVersion = [string]$Facts.distroVersion
    if ($kernel -notmatch '(?i)uek' -and $distroVersion -match '\d' -and -not (Test-VmfVersionInRange -Version $distroVersion)) { return 'unknown' }
    'unlisted'
}

function Test-VmfTargetNeedsManaDriver {
    <#
    .SYNOPSIS
        AN-MANA-DRIVER-RULE-1: does this target size need a machine with a
        MANA driver? Pure.
    .DESCRIPTION
        Every size that MIGHT give MANA (Test-VmfTargetMayUseMana: every v6 and
        v7 size, Intel and AMD, Intel v5 and Bsv2, from manaProcessors in
        target-families.json) - and a size whose name cannot be read, which
        might. Only AMD v5 does not: Microsoft's pages and a lab measurement
        agree that it never gives MANA. AMD v6 stays one that might: its size
        pages say NetVSC and ConnectX, the v6 and v7 planning page says MANA,
        and unknown is never a no (AMD-V6-NO-MANA-1, dropped).
        On such a size accelerated networking is always on
        (Resolve-VmfAcceleratedNetworkingForMove), and a Linux release with no
        MANA driver possible is not offered it (Resolve-VmfEntryTarget).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$SizeName)
    (Test-VmfTargetMayUseMana -SizeName $SizeName) -ne $false
}
function Resolve-VmfAcceleratedNetworkingForMove {
    <#
    .SYNOPSIS
        AN-KEEP-1: what the move does with accelerated networking, decided
        BEFORE the machine is stopped.
    .DESCRIPTION
        Pure. Two questions, both about the TARGET SIZE (GEN-V5-1):

        1. Does Microsoft REQUIRE accelerated networking there? (Intel D and
           Intel E v5 - E since 2026-10-01, DRIFT-5 - and every v6 size since
           2026-10-27, DRIFT-11.)
           Then it must be on after the move, and Microsoft says to turn it on
           before the resize. A machine that had it off stops here - untouched - with 'acceleratedNetworkingRequired',
           unless an approver asked for it on ('ensureOn' set explicitly).

        2. Can the target give the machine MANA? (Every v6 and v7 size, Intel
           v5 and Bsv2 - Test-VmfTargetNeedsManaDriver.) AN-MANA-DRIVER-RULE-1
           (2026-11-06): then accelerated networking is ALWAYS on. A
           plan that keeps it off there (preserve on a primary that is off)
           stops here, untouched, with
           'acceleratedNetworkingRequired' - in Checking, before any change.
           MEASURED: with it set to false Azure still attached the virtual
           function on those sizes, so off is not off. AMD v5 may still turn
           it off.
           And a Linux kernel with no MANA driver ('absent', or 'unlisted' by
           Microsoft's table) - on before the move or off, the move turns it
           on - stops untouched (driverBelowFloor), whatever onDriverBelowFloor
           says (AN-PROCEED-NETVSC-1: an approver's Continue moved it onto the
           synthetic interface); 'updateKernel' has GUEST_PREP update the
           kernel first. A machine off before is
           never kept off: that was 'preserve' (AN-KEEP-1), and it left the
           machine on the synthetic interface.

        A SCSI reversion, no captured NICs, or a driver that is 'present' or
        'unknown': unchanged.
    .OUTPUTS
        @{ Policy; ExpectFabric; OnAfter; Stop; Reason; Detail }
        OnAfter (MANA-WIN-1): is accelerated networking on for the primary
        interface after the move, as decided here.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$PlanEntry,
        [Parameter()][AllowNull()]$CapturedNics,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$ManaDriver
    )

    $policy = Get-VmfPolicy -PlanEntry $PlanEntry -Name 'acceleratedNetworking'
    $kind = Get-VmfMoveKind -PlanEntry $PlanEntry
    $size = [string]$PlanEntry.target.size
    $primary = Get-VmfPrimaryNic -Nics @($CapturedNics)
    $explicit = [bool]($PlanEntry.policy -and $PlanEntry.policy.PSObject.Properties['acceleratedNetworking'] -and
        $PlanEntry.policy.acceleratedNetworking)
    $primaryWasOn = [bool]($primary -and $primary.acceleratedNetworking)
    $onAfter = if ($policy -eq 'ensureOn') { $true } else { $primaryWasOn }

    # An accelerated adapter (MANA or the SR-IOV virtual function) is expected after an NVMe conversion, as before, and after a
    # v5 move that leaves it on. A reversion expects nothing.
    # ADVISE-AN-1, review finding 4: on an NVMe conversion too, only when it
    # is on after the move. A plan that keeps it off on a machine whose
    # kernel HAS a driver demanded an adapter that cannot be there, and
    # failed a healthy machine in VALIDATING.
    $expect = switch ($kind) { 'nvme-conversion' { $onAfter } 'scsi-resize' { $onAfter } default { $false } }
    $out = @{ Policy = $policy; ExpectFabric = $expect; OnAfter = $onAfter; Stop = $false; Reason = ''; Detail = '' }
    if ($kind -eq 'scsi-reversion' -or -not $primary) { return $out }

    if ((Test-VmfTargetRequiresAcceleratedNetworking -SizeName $size) -eq $true) {
        if (-not $onAfter -or (-not $explicit -and -not $primaryWasOn)) {
            $out.Stop = $true
            $out.Reason = 'acceleratedNetworkingRequired'
            $out.Detail = ("Microsoft requires accelerated networking on $size, and it is off on this machine. " +
                           'Microsoft says to turn it on before the resize.')
            return $out
        }
    }

    # MANA: every v6 and v7 size, Intel v5, Bsv2, and a size that cannot be read.
    $mayMana = $kind -eq 'nvme-conversion' -or (Test-VmfTargetNeedsManaDriver -SizeName $size)
    if (-not $mayMana) { return $out }
    # AN-MANA-DRIVER-RULE-1: always on where the size can give MANA. Asked
    # with no driver reading too, so PRECHECK stops it before any change.
    if (-not $onAfter) {
        $out.Stop = $true
        $out.Reason = 'acceleratedNetworkingRequired'
        $out.Detail = ("$size can give the MANA adapter, so the product keeps accelerated networking on there. It is off on this machine, and this plan keeps it off. " +
                       'Azure gives the adapter with the setting off too, and the machine then runs without it.')
        return $out
    }
    if ($ManaDriver -notin @('absent', 'unlisted')) { return $out }
    $why = if ($ManaDriver -eq 'unlisted') { 'Microsoft does not list this Linux release for MANA.' } else { 'Its kernel has no MANA driver.' }
    # Every policy stops here, untouched. MANA-LINUX-KERNEL-1: GUEST_PREP
    # reads this stop under 'updateKernel' as the kernel to update; any other
    # reading - a release Microsoft does not list, no update possible - stays
    # the stop. AN-PROCEED-NETVSC-1 (2026-11-06: a move is not allowed if the
    # network will not work with AN): 'proceed' moved the machine as
    # planned and stopped demanding MANA afterwards. On a MANA host its network
    # then ran on the synthetic interface (NetVSC), with no accelerated path -
    # a network that does not work on accelerated networking. So 'proceed' left
    # the plan contract (v33, OLD-VERSION-READERS-REMOVE-3).
    $out.Stop = $true
    $out.Reason = 'driverBelowFloor'
    $out.ExpectFabric = $false
    $out.Detail = "Accelerated networking is on after the move to $size, and the size can give the MANA adapter. $why Accelerated networking would not work after the move."
    $out
}

function Get-VmfAnNotCheckedDetail {
    <#
    .SYNOPSIS
        ADVISE-AN-1 (second review): what VALIDATING says when it does not look
        for an accelerated adapter. Pure.
    .DESCRIPTION
        Two plans skip the check. One keeps accelerated networking OFF
        ('preserve' for a machine that had it off). The other keeps it ON on
        a size that gives no MANA (AMD v5). The line said "off" for both,
        which is false for the second.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Policy)
    if ($Policy -eq 'preserve') { return 'Accelerated networking is off on this machine, as planned, so MANA is not checked.' }
    'Accelerated networking is on, and the plan does not require MANA after the move, so MANA is not checked.'
}

function Get-VmfAcceleratedNetworkingDecision {
    <#
    .SYNOPSIS
        AN-KEEP-1: the accelerated-networking decision GUEST_PREP saved, for
        CONVERTING and VALIDATING to use.
    .DESCRIPTION
        One decision, made while the machine was still running and untouched,
        and read back by both later steps - so the conversion and the check
        can never disagree about what was intended. GUEST_PREP saves it on
        every move before SAFETY_COPY, with the policy always set
        (Get-VmfPolicy gives the default). OLD-STATE-READERS-FINISH-1: a
        record with no saved decision is no record this version writes, so
        it throws, and the plan is never read in its place.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()]$Doc
    )

    $saved = if ($Doc -and $Doc.captured -and $Doc.captured.PSObject.Properties['acceleratedNetworking']) { $Doc.captured.acceleratedNetworking } else { $null }
    if (-not ($saved -and [string]$saved.policy)) {
        throw 'The record of this machine holds no accelerated networking decision from Preparing, so the product does not change the machine.'
    }
    @{ Policy = [string]$saved.policy; ExpectFabric = [bool]$saved.expectFabric }
}

# MANA-WIN-1, 2026-10-04: a Windows machine whose move can land
# it on MANA hardware gets the MANA driver put in its driver store when the
# store has none. A driver already there is never replaced. V5-LAB-1 measured
# that Windows takes this driver from the STORE, not from Windows Update, so the
# store is the place to read and the place to put it.

function Test-VmfManaDriverInstallWanted {
    <#
    .SYNOPSIS
        MANA-WIN-1: should GUEST_PREP make sure the Windows driver store holds a
        MANA driver? Pure.
    .DESCRIPTION
        Three conditions, all from facts the step already has:
          - the machine is Windows (Linux carries MANA in its kernel - AN-KEEP-1);
          - the target can give MANA: every v6 and v7 size, and Intel v5, from
            manaProcessors in target-families.json (Test-VmfTargetMayUseMana);
          - accelerated networking is on for the primary interface after the
            move, as Resolve-VmfAcceleratedNetworkingForMove decided. With it
            off, Azure gives the machine no MANA device to bind.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Os,
        [Parameter()][bool]$TargetMayMana,
        [Parameter()][bool]$AcceleratedNetworkingAfter
    )
    [bool](($Os -match '(?i)windows') -and $TargetMayMana -and $AcceleratedNetworkingAfter)
}

# MANA-WIN-3: the plan's note for a Windows machine whose move runs the MANA
# driver install. Install-ManaDriver.ps1 downloads the pinned package from
# download.microsoft.com; a machine that cannot reach it stops with
# manaDriverInstallFailed in GUEST_PREP, before the machine is stopped. One
# sentence, held here, so a writer that asks again can find the one it wrote.
$script:VmfManaDriverDownloadNote = 'If the Windows driver store of this machine has no MANA driver, the move downloads one from download.microsoft.com. ' +
    'Make sure that the machine can connect to download.microsoft.com over HTTPS. ' +
    'If the download fails, the machine stops with the reason that the MANA driver could not be installed. It keeps its current size.'

function Get-VmfManaDriverDownloadNote {
    <#
    .SYNOPSIS
        MANA-WIN-3: the plan note for a machine whose move runs the MANA driver
        install, or $null. Pure.
    .DESCRIPTION
        The engine's own rule (Test-VmfManaDriverInstallWanted), asked with
        what the plan entry already says, the way GUEST_PREP asks it live:
          - the operating system the scan recorded;
          - the target can give MANA: a size whose manaProcessors name its
            maker (Test-VmfTargetMayUseMana), and a size it cannot read, as
            GUEST_PREP reads it. (GUEST_PREP also counts an NVMe conversion;
            every v6 and v7 size gives MANA, so that adds nothing here.)
          - accelerated networking on for the primary interface after the
            move. Only a definite off is a no: a move that turns nothing on for a primary the scan read as off
            (Get-VmfPlannedAnOutcome). A primary the scan did not read is
            unknown, and unknown is never a no - the note says "if".
        Whether the driver store already holds a MANA driver is read only
        inside the machine, during the move - so the note says "if".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowNull()]$PlanEntry)

    if (-not $PlanEntry) { return $null }
    $asRead = if ($PlanEntry -is [System.Collections.IDictionary]) { $PlanEntry | ConvertTo-Json -Depth 24 | ConvertFrom-Json -Depth 24 } else { $PlanEntry }
    $outcome = Get-VmfPlannedAnOutcome -PlanEntry $asRead
    if (-not $outcome) { return $null }
    $offAfter = ($outcome.turnsOn -eq $false -and (Test-VmfUsesAcceleratedNetworking -Vm $asRead.assessment) -eq $false)
    $mayMana = (Test-VmfTargetMayUseMana -SizeName ([string]$asRead.target.size)) -ne $false
    $os = if ($asRead.assessment) { [string]$asRead.assessment.os } else { '' }
    if (-not (Test-VmfManaDriverInstallWanted -Os $os -TargetMayMana $mayMana -AcceleratedNetworkingAfter (-not $offAfter))) { return $null }
    $script:VmfManaDriverDownloadNote
}

function Set-VmfManaDriverDownloadNote {
    <#
    .SYNOPSIS
        MANA-WIN-3: write Get-VmfManaDriverDownloadNote into one plan entry's
        planNotes, or take it away from an entry whose move no longer runs
        the install. The other notes stay, in their order.
    .DESCRIPTION
        Every plan writer that changes what decides it asks this for the entry
        it changes: the plan (New-VmfPlan), a target changed in the wave
        editor (Set-VmfMachineTarget) and a decision that sets accelerated
        networking (Resolve-VmfDecision). The same notes again leave the
        entry as it was: a changed entry changes the version of its wave, and
        that voids the approval of the wave (WAVE-APPROVE-1).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$PlanEntry)
    if (-not $PSCmdlet.ShouldProcess([string]$PlanEntry.vmId, 'record whether the move can download the MANA driver')) { return }

    $isDict = $PlanEntry -is [System.Collections.IDictionary]
    $had = if ($isDict) { if ($PlanEntry.Contains('planNotes')) { @($PlanEntry['planNotes']) } else { @() } }
           elseif ($PlanEntry.PSObject.Properties['planNotes']) { @($PlanEntry.planNotes) } else { @() }
    $had = @($had | Where-Object { $null -ne $_ })
    $note = Get-VmfManaDriverDownloadNote -PlanEntry $PlanEntry
    $want = @(@($had | Where-Object { [string]$_ -cne $script:VmfManaDriverDownloadNote }) + @($note | Where-Object { $_ }))
    if ((ConvertTo-Json -InputObject @($had) -Compress) -ceq (ConvertTo-Json -InputObject @($want) -Compress)) { return }
    if ($isDict) { $PlanEntry['planNotes'] = $want }
    elseif ($PlanEntry.PSObject.Properties['planNotes']) { $PlanEntry.planNotes = $want }
    else { $PlanEntry | Add-Member -NotePropertyName planNotes -NotePropertyValue $want }
}

function Get-VmfManaDriverInstallOutcome {
    <#
    .SYNOPSIS
        MANA-WIN-1: what Install-ManaDriver.ps1's answer means for the move.
        Pure.
    .DESCRIPTION
        NO_CHANGE   a MANA driver was already in the store, or an adapter
                    bound: nothing installed.
        NEEDS_PREP  none was, and this version of the product has no pinned
                    package (no sha256): nothing installed. The move goes on,
                    as it did before MANA-WIN-1 - the check after the move
                    still says whether MANA works. Never a stop: the store
                    read has not yet been proved on every image (MANA-WIN-2),
                    and a reading that missed an in-box driver must not stop a
                    machine that moves today.
        FIXED       the pinned package is in the store now, read back after
                    every pnputil add succeeded.
        Anything else - BLOCKED, an answer this engine does not know, or no
        answer - is a stop. An unknown answer is never read as a driver.
    .OUTPUTS
        @{ Stop; Warn; Added = <INF files pnputil added, 0 when not said>;
           Detail = <engine fact>; Record = <captured.manaDriverInstall> }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()]$GuestOutput,
        # The manifest's pin for the package (Get-VmfGuestScript .Packages).
        [Parameter()][AllowNull()]$Package
    )

    $check = { param([string]$Name)
        if (-not $GuestOutput) { return '' }
        [string](@($GuestOutput.checks) | Where-Object { $_ -and [string]$_.name -eq $Name } | Select-Object -First 1).detail }
    $result = if ($GuestOutput) { [string]$GuestOutput.result } else { '' }
    $addedText = & $check 'packages added'
    $added = 0
    # LINUX-VERSION-OVERFLOW-1: a count that does not fit is not said, as text
    # that is not a number is not.
    if ($addedText -match '^\d+$') { $read = ConvertTo-VmfBoundedNumber -Text $addedText; if ($null -ne $read) { $added = $read } }
    $record = [ordered]@{
        outcome     = 'failed'
        result      = $result
        storeBefore = & $check 'mana driver in store'
        pnputilBefore = & $check 'mana driver in pnputil'
        checkedUtc  = (Get-Date).ToUniversalTime().ToString('o')
    }
    # The package is named only where the product tried to install it.
    $withPackage = {
        $record.packageName = $(if ($Package) { [string]$Package.name } else { '' })
        $record.packageVersion = $(if ($Package) { [string]$Package.version } else { '' })
        $record.packageSha256 = $(if ($Package) { [string]$Package.sha256 } else { '' })
    }

    switch ($result) {
        'NO_CHANGE' {
            $record.outcome = 'present'
            $found = @($record.storeBefore, $record.pnputilBefore) | Where-Object { $_ -and $_ -ne 'none' }
            $where = if (@($found).Count) { "The MANA driver is in the Windows driver store ($(@($found)[0]))." }
                     else { 'A MANA adapter is already bound in Windows.' }
            return @{ Stop = $false; Warn = $false; Added = 0; Record = $record; Detail = "$where The product installed nothing." }
        }
        'NEEDS_PREP' {
            $record.outcome = 'notPinned'
            return @{ Stop = $false; Warn = $true; Added = 0; Record = $record
                Detail = ('The Windows driver store has no MANA driver, and this version of the product has no pinned MANA driver to install. ' +
                          'The move goes on, and the check after the move says whether MANA works.') }
        }
        'FIXED' {
            $record.outcome = 'installed'
            $record.storeAfter = & $check 'mana driver in store after'
            . $withPackage
            return @{ Stop = $false; Warn = $false; Added = $added; Record = $record
                Detail = "The Windows driver store had no MANA driver. The product added MANA driver $($record.packageVersion) from Microsoft, and Windows uses it when the Microsoft Azure Network Adapter appears on the new size." }
        }
    }

    . $withPackage
    $why = if ($GuestOutput -and $GuestOutput.PSObject.Properties['error'] -and $GuestOutput.error) { [string]$GuestOutput.error }
           elseif ($result) { "The MANA driver install on the machine returned $result. The product does not accept this answer." }
           else { 'The MANA driver install on the machine returned no answer.' }
    $record.error = $why
    $record.added = $added
    @{ Stop = $true; Warn = $true; Added = $added; Record = $record
        Detail = "The Windows driver store has no MANA driver, and the product could not install one. $why" }
}

function Get-VmfGuestChangeThisAttempt {
    <#
    .SYNOPSIS
        MANA-WIN-1, PREP-ROLLBACK-1: did a script change the guest in this
        attempt? 'none', 'changed' or 'mayHaveChanged'. Pure.
    .DESCRIPTION
        A stop in GUEST_PREP may claim the machine is untouched only when
        nothing in this attempt changed the guest, and a stop before the move
        puts the machine back only when something did. The step is visited
        again: STOPPED sends a machine back to re-prepare, and a resume repeats
        the step after a crash. The attempt starts at its latest PRECHECK; the
        audit trail (guestExecutions) says what ran since.

        changed         a changing script reported FIXED.
        mayHaveChanged  a changing script is STARTED - it never answered: it
                        threw, or the worker stopped while it ran (review F3) -
                        or it reported BLOCKED or anything else that is not
                        NO_CHANGE. The fixer scripts decide their verdict at
                        the end, after their changes ran.
        none            otherwise. A changing script that reported NO_CHANGE
                        changed nothing.

        Install-ManaDriver.ps1 counts only as FIXED or STARTED: NO_CHANGE found
        a driver there, NEEDS_PREP installed nothing, and a BLOCKED install is
        judged by its own count of files added, in GUEST_PREP (MANA-WIN-1).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()]$Doc)

    if (-not $Doc -or -not $Doc.PSObject.Properties['guestExecutions']) { return 'none' }
    $asTime = { param($v)
        if ($null -eq $v) { return $null }
        if ($v -is [datetime]) { return $v.ToUniversalTime() }
        [datetime]::Parse([string]$v, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal) }
    $starts = @(@($Doc.history) | Where-Object { $_ -and [string]$_.state -eq 'PRECHECK' })
    $since = if ($starts.Count) { & $asTime $starts[-1].tsUtc } else { $null }
    $answer = 'none'
    foreach ($run in @($Doc.guestExecutions)) {
        if (-not $run -or [string]$run.script -notin $script:VmfGuestChangerScripts) { continue }
        if ($since -and (& $asTime $run.tsUtc) -lt $since) { continue }
        $result = [string]$run.result
        if ([string]$run.script -eq 'Install-ManaDriver.ps1' -and $result -notin @('FIXED', $script:VmfGuestStartedResult)) { continue }
        if ($result -in @('NO_CHANGE', 'READING')) { continue }
        if ($result -eq 'FIXED') { return 'changed' }
        $answer = 'mayHaveChanged'
    }
    $answer
}

function Test-VmfGuestChangedThisAttempt {
    <#
    .SYNOPSIS
        MANA-WIN-1: has a script that changes the guest run in this attempt -
        changed it, or may have? Pure. See Get-VmfGuestChangeThisAttempt.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()]$Doc)
    (Get-VmfGuestChangeThisAttempt -Doc $Doc) -ne 'none'
}
