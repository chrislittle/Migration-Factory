#!/bin/bash
# nvme-check.sh - read-only Linux NVMe readiness check (VmMigrationFactory)
# Runs inside the guest via Azure RunCommand. Emits ONE JSON object on stdout
# per schemas/guest-output.schema.json. result: READY | NEEDS_PREP | BLOCKED
VMF_VERSION="1.0.0"
SCRIPT_NAME="nvme-check.sh"

CHECKS="[]"
FAILS=0

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n\r'; }

add_check() { # name status detail
    local n s d
    n=$(json_escape "$1"); s=$(json_escape "$2"); d=$(json_escape "$3")
    CHECKS=$(printf '%s' "$CHECKS" | sed 's/\]$//')
    if [ "$CHECKS" = "[" ]; then
        CHECKS="[{\"name\":\"$n\",\"status\":\"$s\",\"detail\":\"$d\"}]"
    else
        CHECKS="$CHECKS,{\"name\":\"$n\",\"status\":\"$s\",\"detail\":\"$d\"}]"
    fi
    [ "$2" = "FAIL" ] && FAILS=$((FAILS+1))
}

emit() { # result [error]
    local os
    os=$(json_escape "$DISTRO_PRETTY")
    printf '{"schema":"vmf.guest/2","script":"%s","version":"%s","os":"%s","result":"%s","checks":%s,"warnings":[]' \
        "$SCRIPT_NAME" "$VMF_VERSION" "$os" "$1" "$CHECKS"
    if [ -n "$2" ]; then printf ',"error":"%s"' "$(json_escape "$2")"; fi
    printf '}\n'
}

# --- distro detection ---
DISTRO="unknown"; DISTRO_PRETTY="unknown"
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO="$ID"; DISTRO_PRETTY="${PRETTY_NAME:-$ID}"
fi
add_check "distro" "INFO" "$DISTRO_PRETTY"

# --- 1. NVMe driver in initrd/initramfs (or built-in) ---
case "$DISTRO" in
    ubuntu|debian)
        if lsinitramfs /boot/initrd.img-* 2>/dev/null | grep -q nvme; then
            add_check "nvme in initramfs" "PASS" ""
        elif grep -qs "CONFIG_BLK_DEV_NVME=y" "/boot/config-$(uname -r)"; then
            add_check "nvme in initramfs" "PASS" "built into kernel"
        else
            add_check "nvme in initramfs" "FAIL" "nvme driver not in initramfs"
        fi ;;
    rhel|centos|rocky|almalinux|sles|suse|ol|fedora)
        if lsinitrd 2>/dev/null | grep -q nvme; then
            add_check "nvme in initrd" "PASS" ""
        elif grep -qs "CONFIG_BLK_DEV_NVME=y" "/boot/config-$(uname -r)"; then
            add_check "nvme in initrd" "PASS" "built into kernel"
        else
            add_check "nvme in initrd" "FAIL" "nvme driver not in initrd"
        fi ;;
    *)
        add_check "nvme in initrd" "WARN" "unsupported distro '$DISTRO' - manual check required" ;;
esac

# --- 2. nvme_core.io_timeout=240 ---
if grep -qs "nvme_core.io_timeout=240" /etc/default/grub /etc/grub.conf /boot/grub/grub.cfg /boot/grub2/grub.cfg /proc/cmdline 2>/dev/null; then
    add_check "nvme_core.io_timeout" "PASS" "240 configured"
else
    add_check "nvme_core.io_timeout" "FAIL" "not set to 240 in grub config"
fi

# --- 3. fstab: no fragile SCSI device names ---
if grep -Eqs '^[^#]*(/dev/sd[a-z][0-9]*|/dev/disk/azure/scsi[0-9]*/lun[0-9]*)' /etc/fstab; then
    add_check "fstab device names" "FAIL" "contains /dev/sd* or azure scsi paths - convert to UUID"
else
    add_check "fstab device names" "PASS" "no fragile SCSI device references"
fi

# --- 4. ADE guard (belt-and-braces; engine also checks the extension) ---
# LINUX-TEMP-1: does this machine have a temporary disk mounted TODAY? The
# engine compares this to the same fact after the move - without it, a lost
# /mnt can only ever be discovered afterwards, and never predicted.
if findmnt -n /mnt >/dev/null 2>&1 || findmnt -n /mnt/resource >/dev/null 2>&1; then
    add_check "temp disk mount" "INFO" "mounted"
else
    add_check "temp disk mount" "INFO" "not mounted"
fi

if [ -d /var/lib/azure_disk_encryption_config ] && [ -n "$(ls -A /var/lib/azure_disk_encryption_config 2>/dev/null)" ]; then
    add_check "azure disk encryption" "FAIL" "ADE config present - ADE for Linux does not support NVMe"
else
    add_check "azure disk encryption" "PASS" "no ADE config detected"
fi

# LVM-ROOT-1 (2026-09-03): EVERYTHING BELOW USED TO SIT AFTER `exit 0`.
#
# It was appended when LVM-1 was written, below an `exit 0` that had been
# there since the first scaffold - so not one of these checks had ever run,
# on any distribution, since the day they were added. bash does not warn and
# nor does shellcheck - a comment starting with that word is read as a
# DIRECTIVE, which is how this very line first broke CI. The script simply
# ended before them.
#
# The cost was not a crash. It was the ENGINE going quiet: storageBefore came
# back with six checks and no LVM facts, so Test-VmfStorageTopology had
# nothing to compare and returned UNKNOWN - which is the SAFE answer, and
# therefore the one nobody chases. Two drills recorded it and both were read
# as "the drill needs fixing". The volume drill has "storage volumes:
# UNKNOWN; storage volumes: UNKNOWN" sitting in its committed evidence.
#
# So the check that exists to catch a customer silently losing a filesystem
# could never once have caught it. Found by the LVM-ROOT-1 drill: a machine
# that came back perfectly, and an engine that could not say so.

# LVM-1: report whether the root filesystem sits on LVM, and
# whether the volume group can be assembled from the initramfs. FACTS ONLY -
# the engine judges them, per the SCSI-direction rule. Nothing here decides
# anything, and nothing here fails a machine.
#
# Why it matters: on an LVM root the volume group must be assembled BEFORE the
# root filesystem can be mounted, which means the initramfs needs both the LVM
# tooling and the NVMe modules. If the NVMe modules are missing the physical
# volumes are invisible at that moment, and the machine cannot find its own
# root - the same class of failure as a missing nvme driver, one layer up.
#
# /dev/mapper/<vg>-<lv> is also stable across the controller change, where
# /dev/sdX is not, so an LVM machine may be SAFER to mount by than a plain one.
rootsrc=$(findmnt -n -o SOURCE / 2>/dev/null)
if echo "$rootsrc" | grep -q '^/dev/mapper/' || { command -v lvs >/dev/null 2>&1 && lvs --noheadings 2>/dev/null | grep -q .; }; then
    if echo "$rootsrc" | grep -q '^/dev/mapper/'; then
        add_check "lvm root" "INFO" "root is on LVM ($rootsrc)"
    else
        add_check "lvm root" "INFO" "LVM volumes present, root is not on one ($rootsrc)"
    fi
    # Is the tooling in the initramfs? An LVM root without it cannot assemble.
    img=""
    for cand in "/boot/initramfs-$(uname -r).img" "/boot/initrd.img-$(uname -r)"; do
        [ -f "$cand" ] && img="$cand" && break
    done
    if [ -n "$img" ] && command -v lsinitrd >/dev/null 2>&1; then
        if lsinitrd "$img" 2>/dev/null | grep -qi 'lvm'; then
            add_check "lvm in initramfs" "INFO" "present"
        else
            add_check "lvm in initramfs" "INFO" "not found in $img"
        fi
    elif [ -n "$img" ] && command -v lsinitramfs >/dev/null 2>&1; then
        if lsinitramfs "$img" 2>/dev/null | grep -qi 'lvm'; then
            add_check "lvm in initramfs" "INFO" "present"
        else
            add_check "lvm in initramfs" "INFO" "not found in $img"
        fi
    else
        add_check "lvm in initramfs" "INFO" "could not be inspected on this image"
    fi
    # Name the physical volumes: these are the devices that must still be
    # visible after the controller changes.
    if command -v pvs >/dev/null 2>&1; then
        pvlist=$(pvs --noheadings -o pv_name 2>/dev/null | tr -d ' ' | tr '
' ' ')
        [ -n "$pvlist" ] && add_check "lvm physical volumes" "INFO" "$pvlist"
    fi
else
    add_check "lvm root" "INFO" "no LVM in use"
fi

# LVM-1 part 2: LVM on DATA DISKS, which is more common than LVM
# on root and fails far more quietly.
#
# A data volume group is not boot-critical - the machine comes up, the agent
# reports Ready, root is on NVMe, the drivers are bound, and validation is
# happy. The only thing missing is the filesystem holding the application's
# data. Three specific things are reported here because nothing else would see
# them:
#
#  1. VG COMPLETENESS. A volume group spanning several data disks needs ALL of
#     its physical volumes. On a Path B recreate the data disks are detached and
#     reattached, and a group missing a member will not activate at all. "How
#     many PVs are missing" is the question, and lvm answers it directly.
#  2. THE TOPOLOGY, so the engine can compare before and after. "Two groups and
#     five volumes before, one group and three now" is invisible to a block
#     device inventory, which sees disks rather than volumes.
#  3. WHICH MOUNTS ARE DEVICE-MAPPER. This matters because of `nofail`:
#     Microsoft's own guidance recommends nofail on Azure data disks so a
#     missing one cannot block boot, and check 3 above therefore downgrades an
#     unmounted nofail entry to INFO. That is right for a plain disk - it may
#     legitimately be absent. It is WRONG for a /dev/mapper path, where the
#     device only fails to exist if the volume group did not assemble. Same
#     symptom, completely different meaning, so it is reported separately.
if command -v vgs >/dev/null 2>&1 && vgs --noheadings 2>/dev/null | grep -q .; then
    vgtotal=$(vgs --noheadings 2>/dev/null | wc -l | tr -d ' ')
    lvtotal=$(lvs --noheadings 2>/dev/null | wc -l | tr -d ' ')
    add_check "lvm topology" "INFO" "${vgtotal} volume group(s), ${lvtotal} logical volume(s)"

    incomplete=""
    while read -r vgname missing; do
        [ -n "$vgname" ] || continue
        if [ -n "$missing" ] && [ "$missing" != "0" ]; then
            incomplete="$incomplete ${vgname}(${missing} missing)"
        fi
    done <<EOF_VG
$(vgs --noheadings -o vg_name,vg_missing_pv_count 2>/dev/null | tr -s ' ')
EOF_VG
    if [ -n "$incomplete" ]; then
        add_check "lvm volume groups complete" "INFO" "INCOMPLETE:$incomplete"
    else
        add_check "lvm volume groups complete" "INFO" "all groups have every disk"
    fi

    # Device-mapper mounts that fstab asks for and that are NOT mounted. See
    # the note above about why nofail must not soften this one.
    dmmissing=""
    while IFS= read -r line; do
        case "$line" in \#*|"") continue ;; esac
        src=$(echo "$line" | awk '{print $1}')
        mp=$(echo "$line" | awk '{print $2}')
        case "$src" in /dev/mapper/*) ;; *) continue ;; esac
        [ -n "$mp" ] || continue
        findmnt -n "$mp" >/dev/null 2>&1 || dmmissing="$dmmissing ${mp}(${src})"
    done < /etc/fstab
    if [ -n "$dmmissing" ]; then
        add_check "lvm volumes mounted" "INFO" "NOT MOUNTED:$dmmissing - the volume group did not assemble"
    else
        add_check "lvm volumes mounted" "INFO" "every LVM entry in fstab is mounted"
    fi
fi


if [ "$FAILS" -eq 0 ]; then emit "READY"; else emit "NEEDS_PREP"; fi
exit 0
