# MANA-LINUX-KERNEL-1, 2026-10-04: a Linux machine whose kernel
# has no MANA driver can have the product UPDATE THE KERNEL during the move, if a
# person chose that for the machine on the targets step. Microsoft: Linux MANA
# is in the kernel (5.15 and later upstream, and distribution backports), and
# "To update your VM's Linux kernel, check the documentation for your specific
# distribution" (accelerated-networking-mana-linux, watched).
#
# Where it happens: GUEST_PREP, after the pristine copy and before every script
# that prepares the machine for its new hardware. The update runs with the
# distribution's own package manager (kernel-update.sh), the machine is stopped
# and started, and mana-check.sh reads it again. If the update fails, the
# machine does not come back, or the driver is still missing, the machine goes
# back to its pristine copy - one change window, never left half changed.
#
# Guests report facts; these functions judge them. Pure: no store, no Azure.

function Test-VmfKernelUpdateOffered {
    <#
    .SYNOPSIS
        MANA-LINUX-KERNEL-1: can a person choose "Update the kernel" for a
        machine going to this target?
    .DESCRIPTION
        Only a Linux machine (Windows takes the MANA driver into its driver
        store - MANA-WIN-1), and only on a move whose target can give MANA:
        every NVMe conversion (v6, v7), and a v5 resize unless its size cannot
        give MANA (AMD v5). The same rule GUEST_PREP judges the driver with, so
        the choice is offered exactly where the question can come up. A size
        that cannot be read ($null) can give MANA, as there.
    .PARAMETER Move
        nvme-conversion, scsi-resize or scsi-reversion (the advice's `move`,
        Get-VmfMoveKind for a plan entry).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Os,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Move,
        [Parameter()][AllowNull()]$MayUseMana
    )
    if ($Os -notmatch '^(?i)linux$') { return $false }
    if ($Move -eq 'nvme-conversion') { return $true }
    [bool]($Move -eq 'scsi-resize' -and $MayUseMana -ne $false)
}

function Test-VmfKernelUpdateOfferedForEntry {
    <#
    .SYNOPSIS
        Test-VmfKernelUpdateOffered for a plan entry: its OS, its move and
        what its target size can give.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$PlanEntry)
    if (-not $PlanEntry.target -or -not [string]$PlanEntry.target.size) { return $false }
    # ADVISE-AN-1: never where the VM agent reports a release Microsoft does
    # not list - an update cannot give it MANA (Test-VmfReleaseKnownUnlisted).
    if ($PlanEntry.PSObject.Properties['assessment'] -and (Test-VmfReleaseKnownUnlisted -Vm $PlanEntry.assessment)) { return $false }

    $move = Get-VmfMoveKind -PlanEntry $PlanEntry
    Test-VmfKernelUpdateOffered -Os ([string]$PlanEntry.assessment.os) -Move $move `
        -MayUseMana (Test-VmfTargetMayUseMana -SizeName ([string]$PlanEntry.target.size))
}

function Resolve-VmfKernelUpdate {
    <#
    .SYNOPSIS
        MANA-LINUX-KERNEL-1: GUEST_PREP found a kernel with no MANA driver for
        a machine whose plan says updateKernel. Does an update go ahead?
    .DESCRIPTION
        Only where an update can help. Microsoft's MANA table decides which
        Linux releases support MANA (RHEL8-MANA-1), and a kernel update does
        not change the release. So the update goes ahead only for a release the
        table lists (Find-VmfManaTableEntry finds its row): a kernel below that
        row's minimum, or with no MANA module, gets the distribution's current
        kernel. A release the table does not list - Ubuntu 18.04 or 20.04, Red
        Hat 8 - stops as it did before, untouched, and the words say why.
    .OUTPUTS
        @{ Update = <bool>; Detail = <words when there is no update>;
           Unlisted = $true when the release is one Microsoft does not list;
           UekNotListed = $true when the kernel is a UEK kernel the table does
           not list (ORACLE-UEK7-KERNEL-STOP-1) }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Os,
        [Parameter()][AllowNull()]$Facts,
        [Parameter()][AllowNull()]$Floors
    )
    if ($Os -notmatch '^(?i)linux$') {
        return @{ Update = $false; Detail = 'The kernel is updated only on Linux.' }
    }
    $id = if ($Facts) { [string]$Facts.distroId } else { '' }
    $version = if ($Facts) { [string]$Facts.distroVersion } else { '' }
    $kernel = if ($Facts) { [string]$Facts.kernelVersion } else { '' }
    if (-not $id -or -not $kernel) {
        return @{ Update = $false; Detail = 'The machine did not report its distribution and kernel, so the product did not update the kernel.' }
    }
    $f = if ($Floors) { $Floors } else { Get-VmfDriverFloors }
    if (-not (Find-VmfManaTableEntry -DistroId $id -DistroVersion $version -Kernel $kernel -Floors $f)) {
        $detail = "Microsoft does not list $id $version for MANA. A kernel update does not change the release, so the product did not update the kernel."
        # ORACLE-UEK7-KERNEL-STOP-1: a UEK kernel is matched by its series, not
        # by the release (the table lists UEK R8 on any Oracle Linux release),
        # so no row for it is not an unlisted release. Oracle gives UEK R8 in
        # its own repository, and an update does not switch to it by itself.
        # ORACLE-UEK-UPDATE-1 (2026-11-14): the update script never
        # changes a repository, but where a person already ENABLED the UEK R8
        # repository of this release, `kernel-uek` from the repositories the
        # machine has is UEK R8 (lab 2026-11-14, Oracle Linux 9.7: ol9_UEKR8
        # gave 6.12, which starts). mana-check.sh reports the enabled UEK
        # repositories (uekRepositories, vmf.guest/5); then the update runs
        # for a UEK kernel below UEK R8, and the reading after the restart
        # proves the running kernel. Else the words name the kernel, the
        # repository for this release, and whether it is enabled.
        if ($kernel -match '(?i)uek') {
            $r8 = $f.mana.linux.uekR8
            $major = ($version -split '\.')[0]
            $repo = @($r8.repositories) | Where-Object { [string]$_.versionId -eq $major } | Select-Object -First 1
            $releases = (@($r8.repositories) | ForEach-Object { [string]$_.versionId }) -join ' and '
            $lowest = @($r8.repositories)[0].versionId
            # The other kernel of the release, only where the table has its row.
            $rhck = @($f.mana.linux.distros) | Where-Object { $_.id -eq 'ol' -and [string]$_.kernelFlavor -ne 'uek' -and [string]$_.versionId -eq $major } | Select-Object -First 1
            $reported = if ($Facts -and $Facts.PSObject.Properties['uekRepositories']) { [string]$Facts.uekRepositories } else { '' }
            $read = $reported -and $reported -ne 'unknown'
            $enabled = @($reported -split '\s+' | Where-Object { $_ })
            $belowR8 = (Compare-VmfKernelVersion -Running $kernel -Floor ([string]$r8.kernelSeries)) -eq -1
            if ($repo -and $belowR8 -and $read -and ($enabled -contains [string]$repo.repository)) {
                return @{ Update = $true; Detail = '' }
            }
            $how = if ($repo) {
                "Oracle gives UEK R8 for Oracle Linux $major in the $($repo.repository) repository."
                if ($belowR8 -and -not $read) { " The product could not read whether the $($repo.repository) repository is enabled on the machine." }
                elseif ($belowR8) { " The $($repo.repository) repository is not enabled on the machine, and the product does not change repositories. Enable the $($repo.repository) repository with the steps from Oracle. Then the product can install UEK R8 when you retry the machine." }
                if ($rhck) { " Microsoft also lists Oracle Linux $major on the Red Hat Compatible Kernel." }
            }
            else {
                "Oracle gives UEK R8 only for Oracle Linux $releases. Upgrade the operating system to Oracle Linux $lowest or a later release."
            }
            return @{ Update = $false; UekNotListed = $true
                Detail = "The machine runs the UEK kernel $kernel. Microsoft lists UEK R8 (kernel series $($r8.kernelSeries)) for MANA, not this UEK kernel. $(@($how) -join '')" }
        }
        # KERNEL-CHOICE-STOP-ADVICE-1: said as an unlisted release (its own
        # stop reason), with the release to upgrade to, as the targets step
        # names it for no-mana-driver (Get-VmfManaUpgradeRelease).
        $upgrade = Get-VmfManaUpgradeRelease -Release @{ distroId = $id; version = $version } -Floors $f
        $to = if ($upgrade) { " Upgrade the operating system to $($upgrade.distroId) $($upgrade.version) or a later release." } else { '' }
        return @{ Update = $false; Unlisted = $true; Detail = "$detail$to" }
    }
    # KERNEL-OFFER-EDGES-1: a listed release where the update cannot reach the
    # minimum - no rule for the kernel flavour, or a kernel the repositories,
    # the flavour or the release lock keep below it. Refused here, before any
    # change, so the machine never gets a kernel change, a restart and a
    # rollback for nothing.
    $reach = Get-VmfKernelUpdateReach -Facts $Facts -Floors $f
    if ($reach) {
        if ($reach.Kind -eq 'noRule') { return @{ Update = $false; NoRule = $true; Detail = $reach.Detail } }
        return @{ Update = $false; CannotReach = $true; Detail = $reach.Detail }
    }
    @{ Update = $true; Detail = '' }
}

function Get-VmfKernelUpdateReach {
    <#
    .SYNOPSIS
        KERNEL-OFFER-EDGES-1: on a release Microsoft lists, can Update the
        kernel reach the minimum of its row? $null when it can (or nothing
        says otherwise), else @{ Kind = 'noRule' | 'cannotReach'; Detail }.
        Pure.
    .DESCRIPTION
        From what mana-check.sh reported, and the data with its sources
        (driver-floors.json, mana.linux.updateCannotReach):
          noRule       Ubuntu on a kernel that is not linux-azure (-azure-fips,
                       -generic). kernel-update.sh has a package only for
                       *-azure, and never changes the flavour. The same rule as
                       the script's case, held to it by a test.
          cannotReach  the repositories of the release give a kernel series
                       below the minimum (Debian 12: 6.1, minimum 6.12.21); a
                       flavour numbered apart from the rows (SUSE kernel-azure);
                       or Red Hat or a rebuild held to a minor release by the
                       releasever setting (the EUS, SAP and HA RHUI clients
                       lock it), below the minor release of its row.
        A fact that is missing or unknown refuses nothing: the update runs as
        before, and the reading after the restart judges it.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()]$Facts,
        [Parameter()][AllowNull()]$Floors
    )
    if (-not $Facts) { return $null }
    $f = if ($Floors) { $Floors } else { Get-VmfDriverFloors }
    $id = ([string]$Facts.distroId).ToLowerInvariant()
    $version = [string]$Facts.distroVersion
    $kernel = [string]$Facts.kernelVersion
    if (-not $id -or -not $kernel) { return $null }

    # Ubuntu: kernel-update.sh's own rule - linux-azure for a *-azure kernel only.
    if ($id -eq 'ubuntu' -and $kernel -notmatch '-azure$') {
        return @{ Kind = 'noRule'
            Detail = "The machine runs the kernel $kernel. On Ubuntu, the product updates only the Azure kernel, linux-azure. The product does not change the kernel flavour. The product did not update the kernel." }
    }

    $row = Find-VmfManaTableEntry -DistroId $id -DistroVersion $version -Kernel $kernel -Floors $f
    if (-not $row -or -not [string]$row.minKernel) { return $null }
    $min = [string]$row.minKernel
    $data = if ($f.mana.linux.PSObject.Properties['updateCannotReach']) { $f.mana.linux.updateCannotReach } else { $null }

    # A release whose repositories give a kernel series below the minimum -
    # and only while the RUNNING kernel is of such a series. A kernel of the
    # minimum's series (Debian 12 on a bookworm-backports 6.12 kernel) is
    # updated within that series, as any installed package is: refusing it
    # would refuse an update that can succeed (review, 2026-11-14).
    $rel = Find-VmfReleaseBelowMinimum -DistroId $id -DistroVersion $version -MinKernel $min -Floors $f
    if ($rel -and -not (Test-VmfKernelSeriesBelow -Kernel $kernel -MinKernel $min -Series ([string]$rel.repositoryKernelSeries))) { $rel = $null }
    if ($rel) {
        return @{ Kind = 'cannotReach'
            Detail = "The machine runs $id $version with the kernel $kernel. Microsoft lists kernel $min or later for MANA on $id $version. The repositories of $id $version have kernel series $($rel.repositoryKernelSeries). $($rel.maker) supplies kernel series $($rel.laterSeries) in $($rel.laterIn). The product does not change the machine to a kernel from $($rel.laterIn). An update in kernel series $($rel.repositoryKernelSeries) cannot reach the minimum version. The product did not update the kernel." }
    }

    # A flavour numbered apart from the rows: an update keeps the flavour.
    # Only on the releases its source covers (versionIds): elsewhere nothing
    # says the numbers differ, so the update runs and the reading after the
    # restart judges it (review, 2026-11-14).
    $flavour = @($(if ($data) { $data.flavours })) | Where-Object {
        $_ -and [string]$_.id -eq $id -and @($_.versionIds) -contains $version -and
        $kernel.EndsWith([string]$_.kernelSuffix, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
    if ($flavour) {
        return @{ Kind = 'cannotReach'
            Detail = "The machine runs the $($flavour.package) kernel $kernel. Microsoft lists the minimum kernel for $id $version as $min. This is a version of the kernel-default package. SUSE uses different version numbers for $($flavour.package). An updated $($flavour.package) kernel stays below $min. The product does not change the kernel flavour. The product did not update the kernel." }
    }

    # Held to a minor release by releasever, below the minor release of its row.
    $lock = if ($Facts.PSObject.Properties['releaseverLock']) { ([string]$Facts.releaseverLock).Trim() } else { '' }
    if ($lock -match '^\d+\.\d+$' -and @($f.mana.linux.minorReachedByUpdate.ids) -contains $id -and
        [string]$row.versionId -match '^\d+\.\d+$' -and ([version][string]$row.versionId) -gt ([version]$lock)) {
        return @{ Kind = 'cannotReach'
            Detail = "The releasever setting holds the machine on $id $lock. The EUS, SAP and HA RHUI clients set this value. Microsoft lists $id $($row.versionId) or later for MANA, with kernel $min or later. An update on $id $lock cannot reach the minimum version. The product did not update the kernel." }
    }
    $null
}

function Find-VmfReleaseBelowMinimum {
    <#
    .SYNOPSIS
        KERNEL-OFFER-EDGES-1: the updateCannotReach.releases entry of this
        release when its repositories give a kernel series below the minimum,
        else $null. Pure.
    .DESCRIPTION
        Compared as series, to as many numbers as the series has: 6.12
        reaches 6.12.21, and 6.1 does not.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$DistroId,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$DistroVersion,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$MinKernel,
        [Parameter()][AllowNull()]$Floors
    )
    if (-not $DistroId -or -not $DistroVersion -or -not $MinKernel) { return $null }
    $f = if ($Floors) { $Floors } else { Get-VmfDriverFloors }
    $data = if ($f.mana.linux.PSObject.Properties['updateCannotReach']) { $f.mana.linux.updateCannotReach } else { $null }
    $rel = @($(if ($data) { $data.releases })) | Where-Object {
        $_ -and [string]$_.id -eq $DistroId -and ([string]$_.versionId -eq $DistroVersion -or $DistroVersion -like "$($_.versionId).*") } | Select-Object -First 1
    if (-not $rel) { return $null }
    $series = [string]$rel.repositoryKernelSeries
    $count = @([regex]::Matches($series, '\d+')).Count
    if (-not $count) { return $null }
    $minSeries = (@([regex]::Matches(($MinKernel -replace '^\s*kernel-', ''), '\d+') | Select-Object -First $count | ForEach-Object { $_.Value })) -join '.'
    if ((Compare-VmfKernelVersion -Running $series -Floor $minSeries) -eq -1) { return $rel }
    $null
}

function Test-VmfKernelSeriesBelow {
    <#
    .SYNOPSIS
        KERNEL-OFFER-EDGES-1 (review): is the running kernel of a series below
        the minimum's series, to as many numbers as -Series has? Pure.
        6.1.0-41-cloud-amd64 against 6.12.21: yes. 6.12.10+bpo-cloud-amd64:
        no. A kernel it cannot read is not below - nothing is refused on it.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Kernel,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$MinKernel,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Series
    )
    $count = @([regex]::Matches([string]$Series, '\d+')).Count
    if (-not $count) { return $false }
    $first = { param([string]$s) (@([regex]::Matches(($s -replace '^\s*kernel-', ''), '\d+') | Select-Object -First $count | ForEach-Object { $_.Value })) -join '.' }
    $running = & $first $Kernel
    $minimum = & $first $MinKernel
    if (@($running -split '\.' | Where-Object { $_ }).Count -lt $count) { return $false }
    (Compare-VmfKernelVersion -Running $running -Floor $minimum) -eq -1
}

function Get-VmfDriverCheckLine {
    <#
    .SYNOPSIS
        ORACLE-UEK-UPDATE-1: the Activity line of GUEST_PREP's driver reading.
        Pure.
    .DESCRIPTION
        "<Status>: <detail>", as before - except a kernel below Microsoft's
        minimum (FAIL) on a machine whose choice is Update the kernel, where
        Resolve-VmfKernelUpdate says the update goes ahead. That line says
        what happens next (lab 2026-11-14: a bare 'FAIL:' hid that the chosen
        update was about to run). A FAIL where
        the machine will stop keeps its words.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()]$Verdict,
        [Parameter()][bool]$UpdateKernel,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Os,
        [Parameter()][AllowNull()]$Facts,
        [Parameter()][AllowNull()]$Floors
    )
    $status = if ($Verdict) { [string]$Verdict.Status } else { '' }
    $line = "$($status): $(if ($Verdict) { [string]$Verdict.Detail })"
    if ($status -ne 'FAIL' -or -not $UpdateKernel -or -not [string]$Verdict.MinKernel) { return $line }
    if (-not (Resolve-VmfKernelUpdate -Os $Os -Facts $Facts -Floors $Floors).Update) { return $line }
    "The kernel $([string]$Facts.kernelVersion) is below the minimum version $([string]$Verdict.MinKernel) that Microsoft lists for $([string]$Facts.distroId) $([string]$Facts.distroVersion). The product updates the kernel now, as chosen for this machine."
}

function Get-VmfKernelUpdateOutcome {
    <#
    .SYNOPSIS
        MANA-LINUX-KERNEL-1: what kernel-update.sh answered. Pure.
    .DESCRIPTION
        FIXED      a kernel newer than the running one is installed: the
                   machine is restarted, then read again.
        NO_CHANGE  the package manager found no kernel newer than the running
                   one, so the driver is still missing.
        Anything else - BLOCKED, an answer this engine does not know, or no
        answer - is a failure. An unknown answer is never read as an update.

        Changed says whether the machine may have changed: not for NO_CHANGE
        (the running kernel is the newest), and not for a BLOCKED answer that
        says the package manager never ran. Anything it cannot tell - no
        answer, or no word on the package manager - is read as changed, so the
        machine goes back to its pristine copy.

        RHUI-REFRESH-1 (2026-11-14): on Red Hat the script first updates
        the RHUI client package from the Microsoft repository (Microsoft's fix
        for an expired RHUI certificate). Its check 'rhui client' is FIXED when
        a newer package was installed: that is a change, so a NO_CHANGE after
        it is not untouched, and the machine goes back to its pristine copy.
        The Activity line says the refresh first.

        KERNEL-UPDATE-OL-RHCK-1: KernelDefault is the kernel of the check
        'default boot kernel' when the script set or read it (INFO or FIXED):
        the kernel the machine starts on after the restart. A WARN (no grubby,
        or grubby failed) gives none.
    .OUTPUTS
        @{ Restart = <bool>; Changed = <bool>; Detail; ScriptResult; KernelInstalled; KernelDefault; Package; PackageManager; RhuiRefreshed = <bool> }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter()][AllowNull()]$GuestOutput)

    $check = { param([string]$Name)
        if (-not $GuestOutput) { return '' }
        [string](@($GuestOutput.checks) | Where-Object { $_ -and [string]$_.name -eq $Name } | Select-Object -First 1).detail }
    $result = if ($GuestOutput) { [string]$GuestOutput.result } else { '' }
    $ran = & $check 'package manager ran'
    $rhui = if ($GuestOutput) { @($GuestOutput.checks) | Where-Object { $_ -and [string]$_.name -eq 'rhui client' } | Select-Object -First 1 } else { $null }
    # A change only when the package version changed: the check says
    # '<before> to <after>', and the two must differ (review, 2026-11-14).
    $rhuiRefreshed = $false
    if ($rhui -and [string]$rhui.status -eq 'FIXED' -and [string]$rhui.detail -match '^The package manager updated (.+) to (.+)\.$') {
        $rhuiFrom = $Matches[1].Trim()
        $rhuiTo = $Matches[2].Trim()
        $rhuiRefreshed = $rhuiFrom -ne $rhuiTo
    }
    $out = @{
        Restart         = $false
        Changed         = $rhuiRefreshed -or -not ($result -eq 'NO_CHANGE' -or ($result -eq 'BLOCKED' -and $ran -eq 'no'))
        RhuiRefreshed   = $rhuiRefreshed
        ScriptResult    = $(if ($result) { $result } else { $null })
        KernelInstalled = $(if (& $check 'kernel installed') { & $check 'kernel installed' } else { $null })
        KernelDefault   = $null
        Package         = $(if (& $check 'kernel package') { & $check 'kernel package' } else { $null })
        PackageManager  = $(if (& $check 'package manager') { & $check 'package manager' } else { $null })
        Detail          = ''
    }
    $default = if ($GuestOutput) { @($GuestOutput.checks) | Where-Object { $_ -and [string]$_.name -eq 'default boot kernel' } | Select-Object -First 1 } else { $null }
    if ($default -and [string]$default.status -in 'INFO', 'FIXED' -and [string]$default.detail) { $out.KernelDefault = ([string]$default.detail).Trim() }
    $before = & $check 'kernel before'
    $first = if ($rhuiRefreshed) { "First, the package manager updated the RHUI client package from $rhuiFrom to $rhuiTo. It used the Microsoft repository. " } else { '' }
    switch ($result) {
        'FIXED' {
            $out.Restart = $true
            $out.Detail = "$($first)The package manager installed kernel $($out.KernelInstalled). The machine runs kernel $before until it restarts."
            return $out
        }
        'NO_CHANGE' {
            $out.Detail = "$($first)The package manager found no kernel newer than $before in the repositories this machine uses."
            return $out
        }
    }
    $why = if ($GuestOutput -and $GuestOutput.PSObject.Properties['error'] -and $GuestOutput.error) { [string]$GuestOutput.error }
           elseif ($result) { "The update script reported $result, which is not an answer the engine accepts." }
           else { 'The update script returned no answer.' }
    $out.Detail = "$($first)The kernel could not be updated. $why"
    $out
}

function Get-VmfKernelUpdateRecheck {
    <#
    .SYNOPSIS
        MANA-LINUX-KERNEL-1: after the restart, does the kernel that RUNS now
        carry a MANA driver? Pure.
    .DESCRIPTION
        mana-check.sh is read again, with the same two readers GUEST_PREP used
        before the update: Get-VmfManaDriverPresence (`modinfo mana` against
        the running kernel, and Microsoft's table) must say present, and the
        floor judgement (Get-VmfDriverJudgement) must not say FAIL. Unknown is
        not present: the update was made to get the driver, and a driver that
        cannot be shown is not there.

        KERNEL-UPDATE-OL-RHCK-1: the words compare the kernel the machine
        started on with the default boot kernel the script set (-KernelDefault),
        and with the installed kernel only when the script reported no default.
    .OUTPUTS
        @{ Ok = <bool>; Detail }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Presence,
        [Parameter()][AllowNull()]$Verdict,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$KernelBefore,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$KernelInstalled,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$KernelAfter,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$KernelDefault
    )
    $status = if ($Verdict) { [string]$Verdict.Status } else { '' }
    $booted = if (-not $KernelAfter) { 'The machine did not report the kernel it runs.' }
              elseif ($KernelDefault -and $KernelAfter -ne $KernelDefault) { "The machine started on kernel $KernelAfter, not on the default boot kernel $KernelDefault." }
              elseif ($KernelDefault) { "The machine started on kernel $KernelAfter." }
              elseif ($KernelInstalled -and $KernelAfter -ne $KernelInstalled) { "The machine started on kernel $KernelAfter, not on the installed kernel $KernelInstalled." }
              elseif ($KernelAfter -eq $KernelBefore) { "The machine started on its old kernel $KernelAfter." }
              else { "The machine started on kernel $KernelAfter." }
    if ($Presence -eq 'present' -and $status -ne 'FAIL') {
        return @{ Ok = $true; Detail = "The kernel was updated from $KernelBefore to $KernelAfter, and it has a MANA driver." }
    }
    $why = switch ($Presence) {
        'absent'   { 'That kernel has no MANA driver.' }
        'unlisted' { 'Microsoft does not list that release and kernel for MANA.' }
        'present'  { [string]$Verdict.Detail }
        default    { 'The product could not read whether that kernel has a MANA driver.' }
    }
    @{ Ok = $false; Detail = "$booted $why" }
}
