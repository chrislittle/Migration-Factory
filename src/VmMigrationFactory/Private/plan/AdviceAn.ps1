# ADVISE-AN-1: the option a machine starts on keeps the accelerated networking
# it uses today.
#
# The target advice picked v6 by default whatever its facts said. A Linux
# machine whose release Microsoft does not list for MANA (Ubuntu 18.04, Red Hat
# 8) then started on a v6 size, where accelerated networking uses MANA and the
# kernel has no driver for it: the move stops at GUEST_PREP (driverBelowFloor),
# or an approver lets it go on and the accelerated path is gone.
#
# What the advice can know, and from where. It reads Azure, never the guest:
#   - the RUNNING release, from the VM agent: Resource Graph's instanceView
#     osName and osVersion, which Microsoft's own assessment query reads
#     (sizes-v6-v7-modernization-assess). Empty when the machine is
#     deallocated. Recorded by the scan from assessment v3.
#   - else the release of the IMAGE the machine was made from. A release only
#     goes up in place, so the image is the LOWEST release the machine can run.
#     The same order OSVER-1 uses for the Windows version.
#   - never the kernel. mana-check.sh reads it from inside the machine, in the
#     run (GUEST_PREP), and Microsoft's table names a minimum kernel per
#     release. So a release the table lists can get MANA, with "Update the
#     kernel" when its kernel is older (KERNEL-UX-1); a release it does not list
#     cannot, and an update does not change the release (RHEL8-MANA-1,
#     Resolve-VmfKernelUpdate).
#
# Pure: no Azure call, no store read.

function ConvertTo-VmfDistroId {
    <#
    .SYNOPSIS
        The distribution id of Microsoft's MANA table (the os-release ID) for a
        name the VM agent or an image gives. $null for a name it does not know.
    .DESCRIPTION
        MEASURED 2026-10-11 (ADVISE-AN-1 work item): the agent reports ubuntu
        18.04 and 22.04 (no point release), redhat 8.10, sles 15.5 and debian
        12. Other distributions are not measured, so both spellings seen in the
        wild are read (rhel and redhat, sles and suse, ol and oracle). A name
        it does not know is no release at all - never a guess.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Name)
    $n = ([string]$Name).Trim().ToLowerInvariant()
    if (-not $n) { return $null }
    if ($n -match '^ubuntu') { return 'ubuntu' }
    if ($n -match '^(rhel|redhat|red hat)') { return 'rhel' }
    if ($n -match '^(sles|suse)') { return 'sles' }
    if ($n -match '^debian') { return 'debian' }
    if ($n -match '^(ol|oracle)([^a-z]|$)') { return 'ol' }
    if ($n -match '^almalinux') { return 'almalinux' }
    if ($n -match '^rocky') { return 'rocky' }
    # CBL-Mariner 2.0 is Azure Linux 2.0 in Microsoft's naming.
    if ($n -match '^(azurelinux|azure linux|azure-linux|mariner|cbl-mariner)') { return 'azurelinux' }
    if ($n -match '^centos') { return 'centos' }
    $null
}

function Get-VmfImageRelease {
    <#
    .SYNOPSIS
        The Linux release of a marketplace image: @{ distroId; version }, or
        $null when the image says nothing this reads with certainty.
    .DESCRIPTION
        Read from the image's publisher, offer and SKU, the names Azure gives
        them (Canonical UbuntuServer 18.04-LTS, RedHat RHEL 8_10, SUSE
        sles-15-sp5). A major release with no minor (RHEL 9-lvm-gen2) keeps no
        minor: the image does not say it.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Publisher,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Offer,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Sku
    )
    $pub = ([string]$Publisher).ToLowerInvariant()
    $off = ([string]$Offer).ToLowerInvariant()
    $s = ([string]$Sku).ToLowerInvariant()
    $make = { param([string]$Id, [string]$Version) @{ distroId = $Id; version = $Version } }
    switch ($pub) {
        'canonical' {
            foreach ($text in @($s, $off)) {
                if ($text -match '(^|[^0-9])(\d{2})[._](\d{2})([^0-9]|$)') { return & $make 'ubuntu' "$($Matches[2]).$($Matches[3])" }
            }
            $names = [ordered]@{ xenial = '16.04'; bionic = '18.04'; focal = '20.04'; jammy = '22.04'; noble = '24.04' }
            foreach ($k in $names.Keys) { if ($off -match "(^|-)$k(-|$)") { return & $make 'ubuntu' $names[$k] } }
            return $null
        }
        'redhat' {
            if ($s -match '^(\d+)[._](\d+)([^0-9]|$)') { return & $make 'rhel' "$($Matches[1]).$($Matches[2])" }
            # 94_gen2 is 9.4, 79-gen2 is 7.9, 810-gen2 is 8.10: a one-digit
            # major, then the minor. RHEL-EUS-SKU-LIST-1 (Azure's list,
            # docs/research/rhel-image-skus.md): 100-gen2 is 10.0 and 101-gen2
            # is 10.1 - major 10, as their image versions say, never major 1.
            if ($s -match '^(10)(\d{1,2})[-_]gen2$') { return & $make 'rhel' "$($Matches[1]).$($Matches[2])" }
            if ($s -match '^(\d)(\d{1,2})[-_]gen2$') { return & $make 'rhel' "$($Matches[1]).$($Matches[2])" }
            # The LVM SKUs (non-EUS, no minor): 9-lvm, 9-lvm-gen2, 7-LVM and
            # 7lvm-gen2, with no hyphen.
            if ($s -match '^(\d+)(-?lvm)?([-_]gen[12])?$') { return & $make 'rhel' $Matches[1] }
            return $null
        }
        'suse' {
            foreach ($text in @($off, $s)) {
                if ($text -match '(^|[^0-9])(\d+)-sp(\d+)([^0-9]|$)') { return & $make 'sles' "$($Matches[2]).$($Matches[3])" }
            }
            return $null
        }
        'debian' {
            if ($off -match '^debian-(\d+)([^0-9]|$)') { return & $make 'debian' $Matches[1] }
            if ($s -match '^(\d+)([^0-9.]|$)') { return & $make 'debian' $Matches[1] }
            return $null
        }
        'oracle' {
            if ($s -match '^ol(\d)(\d{1,2})([^0-9]|$)') { return & $make 'ol' "$($Matches[1]).$($Matches[2])" }
            if ($s -match '^(\d+)[._](\d+)([^0-9]|$)') { return & $make 'ol' "$($Matches[1]).$($Matches[2])" }
            return $null
        }
        'microsoftcblmariner' {
            foreach ($text in @($s, $off)) {
                if ($text -match '(azure-linux|cbl-mariner)-(\d+)') { return & $make 'azurelinux' $Matches[2] }
            }
            return $null
        }
        'microsoftazurelinux' {
            # DRIFT-12: Azure Linux 4 (offer azurelinux-4, SKUs 4 and 4-fips).
            # The support list's entry says which offers this publisher has
            # and where the release is in the name: its offerPattern group.
            $entry = (Get-VmfImageMatrixEntry -Publisher $pub -Offer $off).Entry
            if ($entry -and $entry.PSObject.Properties['offerPattern'] -and $off -imatch [string]$entry.offerPattern -and $Matches[1]) {
                return & $make 'azurelinux' $Matches[1]
            }
            return $null
        }
    }
    $null
}

function Get-VmfLinuxRelease {
    <#
    .SYNOPSIS
        ADVISE-AN-1: the Linux release of an assessed machine, as the advice can
        know it: @{ distroId; version; source = 'agent' | 'image' }, or $null.
    .DESCRIPTION
        The VM agent's reading first - the release that RUNS - and the image
        only when the agent reported none (deallocated, no agent, or a name
        this does not read). An assessment before v3 has no agent reading, so
        the image decides. A custom image with no agent reading has none.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$Vm)
    if ([string]$Vm.os -notmatch '^(?i)linux$') { return $null }
    $field = { param([string]$Name) if ($Vm.PSObject.Properties[$Name]) { [string]$Vm.$Name } else { '' } }
    $id = ConvertTo-VmfDistroId -Name (& $field 'runningOsName')
    $ver = (& $field 'runningOsVersion').Trim()
    if ($id -and $ver -match '^\d+(\.\d+)*$') {
        return @{ distroId = $id; version = $ver; source = 'agent' }
    }
    $image = Get-VmfImageRelease -Publisher (& $field 'imagePublisher') -Offer (& $field 'imageOffer') -Sku (& $field 'osVersion')
    if ($image) { return @{ distroId = $image.distroId; version = $image.version; source = 'image' } }
    $null
}

function Get-VmfEusImage {
    <#
    .SYNOPSIS
        RHEL-EUS-TARGET-NOTE-1: the RHEL image on the EUS repositories a machine
        was made from, when its kernel for MANA needs a later minor release:
        [ordered]@{ image; release; listedFrom }, or $null.
    .DESCRIPTION
        Microsoft, Red Hat Update Infrastructure
        (https://learn.microsoft.com/en-us/azure/virtual-machines/workloads/redhat/redhat-rhui):
        "Images connected to EUS repositories contain a minor version number in
        the SKU"; images on the non-EUS repositories do not (X-LVM, X-RAW), and
        RHUI is for pay-as-you-go images only. Such a machine gets no later
        minor release by an update (measured 2026-11-08: RedHat:RHEL:94_gen2
        found no newer kernel, kernelNotInRepositories).

        Marked only where every fact says it, and nothing where one is missing:
          - the image is publisher RedHat, offer RHEL (not an SAP offer, which
            has its own RHUI channels, and not a BYOS offer);
          - no licence type, or None: a RHEL_BYOS machine (Azure Hybrid
            Benefit) takes its updates from Red Hat, not RHUI;
          - the SKU has a minor version (Get-VmfImageRelease, the one reader);
          - the release the machine runs (Get-VmfLinuxRelease: the VM agent,
            else the image) is that same minor release - a machine on a later
            one, or another major, has left the repositories of its image;
          - Microsoft's MANA table covers that release only by a LATER minor
            release (Find-VmfManaTableEntry, minorReachedByUpdate), so the
            kernel for MANA is one the EUS repositories do not hold.
        The repositories the machine uses NOW are never known here: Microsoft's
        page switches them both ways, and the scan reads nothing inside the
        machine. So this says what was read, and changes no offer.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]$Vm,
        [Parameter()][AllowNull()]$Floors
    )
    $field = { param([string]$Name) if ($Vm.PSObject.Properties[$Name] -and $null -ne $Vm.$Name) { ([string]$Vm.$Name).Trim() } else { '' } }
    $pub = & $field 'imagePublisher'
    $off = & $field 'imageOffer'
    $sku = & $field 'osVersion'
    if ($pub -ne 'RedHat' -or $off -ne 'RHEL') { return $null }
    $licence = & $field 'licenseType'
    if ($licence -and $licence -ne 'None') { return $null }
    $image = Get-VmfImageRelease -Publisher $pub -Offer $off -Sku $sku
    # A Linux machine only (Get-VmfLinuxRelease), and the minor release of the
    # image: $running is always major.minor, so no image, or a SKU with no
    # minor, never matches.
    $release = Get-VmfLinuxRelease -Vm $Vm
    if (-not $release -or $release.distroId -ne 'rhel') { return $null }
    $running = if ([string]$release.version -match '^(\d+)\.(\d+)') { "$($Matches[1]).$($Matches[2])" } else { '' }
    if ($running -ne [string]$image.version) { return $null }
    $row = Find-VmfManaTableEntry -DistroId 'rhel' -DistroVersion $running -Floors $Floors
    # No row, or a row with no minor (it covers every minor of its major).
    if ([string]$row.versionId -notmatch '^\d+\.\d+$') { return $null }
    if ([version][string]$row.versionId -le [version]$running) { return $null }
    [ordered]@{ image = "$($pub):$($off):$($sku)"; release = $running; listedFrom = [string]$row.versionId }
}

function Get-VmfManaReleaseListing {
    <#
    .SYNOPSIS
        ADVISE-AN-1: does Microsoft's MANA table list this release? 'listed',
        'unlisted' or 'unknown'.
    .DESCRIPTION
        listed    Find-VmfManaTableEntry finds its row - the reader the engine
                  judges the guest with, so the advice and the run agree.
        unknown   no release; Oracle Linux by release (UEK R8 is listed on any
                  release, and the kernel is read only from inside the
                  machine); an IMAGE release whose major has a row - a routine
                  update takes Red Hat 9.4 to 9.6 in place, so the image's
                  minor is a floor, not the release; a running release with no
                  minor whose major has a row with one.
        unlisted  every other release: Ubuntu 18.04 and 20.04, Red Hat 8,
                  Debian 11, SUSE 15 SP4. (A running Red Hat 9.4 is listed
                  since AN-MANA-DRIVER-RULE-1: a normal update reaches 9.6,
                  so the table reader judges it by the 9.6 row - its kernel
                  is updated as a listed release's is.) A kernel of 6.14 or later
                  gives MANA there too (fallbackForUnlistedDistros), but that is
                  a custom kernel on these releases, and the run still reads it
                  (Get-VmfManaDriverPresence) - the pick only sets where a
                  machine starts.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()]$Release,
        [Parameter()][AllowNull()]$Floors
    )
    if (-not $Release -or -not [string]$Release.distroId -or -not [string]$Release.version) { return 'unknown' }
    $f = if ($Floors) { $Floors } else { Get-VmfDriverFloors }
    $id = [string]$Release.distroId
    $version = [string]$Release.version
    if (Find-VmfManaTableEntry -DistroId $id -DistroVersion $version -Kernel '' -Floors $f) { return 'listed' }
    if ($id -eq 'ol') { return 'unknown' }
    $major = ($version -split '\.')[0]
    $sameMajor = @(@($f.mana.linux.distros) | Where-Object {
            [string]$_.id -eq $id -and -not [string]$_.kernelFlavor -and ([string]$_.versionId -split '\.')[0] -eq $major })
    if ($sameMajor.Count) {
        if ([string]$Release.source -eq 'image') { return 'unknown' }
        if ($version -notmatch '\.') { return 'unknown' }
    }
    'unlisted'
}

function Test-VmfUsesAcceleratedNetworking {
    <#
    .SYNOPSIS
        ADVISE-AN-1: does the machine use accelerated networking today? $true,
        $false or $null.
    .DESCRIPTION
        The engine decides it from the PRIMARY interface
        (Resolve-VmfAcceleratedNetworkingForMove), and the scan records the
        primary's setting by the engine's rule (AN-PRIMARY-1). An assessment
        without it has only the count, which settles one interface, or none on
        at all. Anything else is unknown, never a no - the same reading the
        option's turnsOn makes.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory)]$Vm)
    if ($Vm.PSObject.Properties['primaryNicAccelerated'] -and $null -ne $Vm.primaryNicAccelerated) { return [bool]$Vm.primaryNicAccelerated }
    $count = if ($Vm.PSObject.Properties['acceleratedNicCount'] -and $null -ne $Vm.acceleratedNicCount) { [int]$Vm.acceleratedNicCount } else { $null }
    $nics = if ($Vm.PSObject.Properties['nicCount'] -and [int]$Vm.nicCount -gt 0) { [int]$Vm.nicCount } else { 1 }
    if ($null -eq $count) { return $null }
    if ($count -eq 0) { return $false }
    if ($nics -eq 1) { return $true }
    $null
}

function Get-VmfAnTurnsOn {
    <#
    .SYNOPSIS
        BSV2-NOTES-1: does the move turn accelerated networking on for the
        primary interface? $true, $false or $null.
    .DESCRIPTION
        The engine's rule, asked of the advice's facts. With no setting of its
        own, every move but a SCSI reversion has the policy ensureOn
        (Get-VmfPolicy), and Resolve-VmfAcceleratedNetworkingForMove turns the
        primary on - on a size that does not require it too. The advice said
        "turns on" only where the size requires it, so a B2s -> B2ls_v2 move
        that turned it on was shown as Off -> Off (lab, 2026-10-11).

        AN-MANA-DRIVER-RULE-1 (2026-11-06): there is no exception any
        more. A Linux kernel with no MANA driver kept a primary that was off as
        it was, on a size that can give MANA (AN-KEEP-1), so this said unknown
        for Linux there. Now the move turns it on, or stops in Preparing before
        any change (driverBelowFloor) - it never moves the machine with it off.
        A primary that was not read is unknown, never a no (AN-PRIMARY-1).
        Pure.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]$Vm,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$TargetSize,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Move,
        [Parameter()][AllowNull()]$Required
    )
    if ($Move -eq 'scsi-reversion') { return $false }
    $uses = Test-VmfUsesAcceleratedNetworking -Vm $Vm
    if ($null -eq $uses) { return $null }
    -not $uses
}
function Get-VmfAnKeptOn {
    <#
    .SYNOPSIS
        ADVISE-AN-1: on this option, does the accelerated networking a machine
        uses today keep working? @{ KeptOn = $true|$false|$null; Why }.
    .DESCRIPTION
        Only asked of a machine that uses it today; any other gets $null, $null.
        The question is the adapter the target size can give, and whether the
        operating system drives it:
          - a size that never gives MANA (AMD v5): Mellanox, which every
            endorsed distribution and Windows drive - kept;
          - a size that can give MANA (every v6 and v7 size, Intel v5):
              Windows - kept. Windows installs its in-box driver when the
              hardware appears (AN-KEEP-1), and MANA-WIN-1 adds one;
              Linux on a release Microsoft lists - kept (an old kernel can be
              updated on the targets step, KERNEL-UX-1);
              Linux on a release it does not list - not kept on v6 or v7
              (Why 'unlisted'), and unknown on Intel v5 (Why 'host'): Microsoft
              says those sizes run on Mellanox AND MANA hosts, by region and by
              host, so Mellanox is never the reason to pick one;
              Linux on a release nobody could read - unknown
              (Why 'release-unknown');
          - a size whose name cannot be read - unknown (Why 'size-unreadable').
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Os,
        [Parameter()][AllowNull()]$UsesAn,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Move,
        [Parameter()][AllowNull()]$MayUseMana,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Listing,
        # Review finding 1: where the release was read. An IMAGE release cannot
        # prove the machine still runs it (an in-place upgrade changes the
        # release, not the image), so an unlisted image release is not a no.
        [Parameter()][AllowNull()][AllowEmptyString()][string]$ReleaseSource = 'agent'
    )
    if ($UsesAn -ne $true) { return @{ KeptOn = $null; Why = $null } }
    $mana = if ($Move -eq 'nvme-conversion') { $true } else { $MayUseMana }
    if ($mana -eq $false) { return @{ KeptOn = $true; Why = $null } }
    if ($null -eq $mana) { return @{ KeptOn = $null; Why = 'size-unreadable' } }
    if ($Os -match '(?i)windows') { return @{ KeptOn = $true; Why = $null } }
    if ($Os -notmatch '^(?i)linux$') { return @{ KeptOn = $null; Why = 'release-unknown' } }
    switch ($Listing) {
        'listed' { return @{ KeptOn = $true; Why = $null } }
        'unlisted' {
            if ($ReleaseSource -eq 'image') { return @{ KeptOn = $null; Why = 'image-unlisted' } }
            if ($Move -eq 'nvme-conversion') { return @{ KeptOn = $false; Why = 'unlisted' } }
            return @{ KeptOn = $null; Why = 'host' }
        }
    }
    @{ KeptOn = $null; Why = 'release-unknown' }
}

function Select-VmfAnKeepingStart {
    <#
    .SYNOPSIS
        ADVISE-AN-1: the option a machine starts on, moved off one where its
        accelerated networking certainly stops working.
    .DESCRIPTION
        Only when the default's keptOn is $false, and only to the first
        supported option, in the default's own order, whose keptOn is $true.
        With none, the default stays, and the screen marks it. Unknown is never
        read as yes or no: an option whose answer is $null is neither avoided
        nor chosen for it. Nothing here picks a bigger size (OWNER-QUESTIONS-1
        row 31): each option keeps its own size.

        AN-MANA-DRIVER-RULE-1 (2026-11-06): DRIFT-11 also moved a
        machine with accelerated networking OFF today, whose release has no
        MANA driver, to v7, where it stayed off. That is gone: no size that can
        give MANA is offered to such a machine (Resolve-VmfEntryTarget,
        no-mana-driver), whether it uses accelerated networking today or not.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Start,
        [Parameter()][AllowNull()]$Options,
        [Parameter()][string[]]$Order = @()
    )
    if (-not $Start) { return $null }
    $byName = @{}
    foreach ($o in @($Options)) { if ($o) { $byName[[string]$o.option] = $o } }
    $chosen = $byName[$Start]
    if (-not $chosen -or $chosen.acceleratedNetworking.keptOn -ne $false) { return $Start }
    foreach ($s in $Order) {
        $o = $byName[$s]
        if ($o -and $o.supported -and $o.acceleratedNetworking.keptOn -eq $true) { return $s }
    }
    $Start
}

function Get-VmfManaUpgradeRelease {
    <#
    .SYNOPSIS
        AN-MANA-DRIVER-RULE-1: the release to upgrade a Linux machine to, so
        that it has a MANA driver - @{ distroId; version }, or $null.
    .DESCRIPTION
        The first release of the same distribution that Microsoft's MANA table
        lists, above this one (Ubuntu 18.04 -> 22.04, Red Hat 8.10 -> 9.6,
        Debian 11 -> 12, SUSE 15 SP4 -> 15.5). The targets step names it for a
        machine whose release has no MANA driver possible, which is not offered
        a size that can give MANA. $null for a distribution the table does not
        list at all (CentOS), or a release it cannot read: the screen then
        names no release. Pure.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter()][AllowNull()]$Release,
        [Parameter()][AllowNull()]$Floors
    )
    if (-not $Release -or -not [string]$Release.distroId -or -not [string]$Release.version) { return $null }
    $f = if ($Floors) { $Floors } else { Get-VmfDriverFloors }
    $id = [string]$Release.distroId
    $mine = [string]$Release.version
    $later = @(@($f.mana.linux.distros) | Where-Object {
            [string]$_.id -eq $id -and -not [string]$_.kernelFlavor -and [string]$_.versionId -match '^\d+(\.\d+)?$' -and
            (Compare-VmfKernelVersion -Running ([string]$_.versionId) -Floor $mine) -eq 1 } |
        Sort-Object { [version]$(if ([string]$_.versionId -match '\.') { [string]$_.versionId } else { "$($_.versionId).0" }) })
    if (-not $later.Count) { return $null }
    [ordered]@{ distroId = $id; version = [string]$later[0].versionId }
}
function Test-VmfReleaseKnownUnlisted {
    <#
    .SYNOPSIS
        ADVISE-AN-1, 2026-10-12 (the product never shows an option that is
        not possible): does the VM agent report a Linux release that
        Microsoft does not list for MANA?
    .DESCRIPTION
        Then no kernel update can give the machine MANA - an update does not
        change the release (Resolve-VmfKernelUpdate) - so "Update the kernel"
        is neither offered nor planned. AN-MANA-DRIVER-RULE-1: and no size that
        can give MANA is offered at all (Resolve-VmfEntryTarget,
        no-mana-driver): the machine has no MANA driver possible. Only the
        agent's reading counts: an image release, or none, keeps the choice as
        before, and the run reads the driver in Preparing. Pure.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()]$Vm)
    if (-not $Vm) { return $false }
    $release = Get-VmfLinuxRelease -Vm $Vm
    [bool]($release -and [string]$release.source -eq 'agent' -and (Get-VmfManaReleaseListing -Release $release) -eq 'unlisted')
}

function Get-VmfNoManaDriverReason {
    <#
    .SYNOPSIS
        AN-MANA-DRIVER-RULE-1: the words for a size refused because the
        machine has no MANA driver possible (the reason no-mana-driver). Pure.
    .DESCRIPTION
        A plan records a machine it does not move with this reason in
        planNotes, so it says what to do: upgrade the operating system to the
        release Get-VmfManaUpgradeRelease names, then assess again.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Vm, [Parameter()][AllowNull()][AllowEmptyString()][string]$Size)
    $release = Get-VmfLinuxRelease -Vm $Vm
    $name = if ($release) { "$($release.distroId) $($release.version)" } else { 'this Linux release' }
    $upgrade = Get-VmfManaUpgradeRelease -Release $release
    $to = if ($upgrade) { "to $($upgrade.distroId) $($upgrade.version) or a later release" } else { 'to a release that Microsoft lists for MANA' }
    ("Microsoft does not list $name for MANA, and $Size can give the MANA adapter, so accelerated networking would not work after the move. " +
     "Upgrade the operating system $to, then assess again.")
}