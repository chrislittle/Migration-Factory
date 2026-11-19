#!/bin/bash
# guest-validate.sh - Linux post-migration validation (VmMigrationFactory). Read-only.
# Emits ONE JSON object per schemas/guest-output.schema.json. result: PASS | FAIL
VMF_VERSION="1.2.0"
SCRIPT_NAME="guest-validate.sh"
# The tests point this at a file of their own. On a machine it is empty.
FSTAB="${VMF_FSTAB:-/etc/fstab}"

CHECKS="[]"
FAILS=0

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n\r'; }

add_check() {
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

DISTRO_PRETTY="unknown"
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_PRETTY="${PRETTY_NAME:-$ID}"
fi

# 1. Root device bus is reported as a FACT - the engine judges it against the
#    plan's target controller (SCSI reversion is as valid as an NVMe move).
rootdev=$(findmnt -n -o SOURCE / 2>/dev/null)
if echo "$rootdev" | grep -q nvme || lsblk -no NAME,TYPE 2>/dev/null | grep -q '^nvme.*disk'; then
    add_check "root device bus" "INFO" "nvme ($rootdev)"
else
    add_check "root device bus" "INFO" "non-nvme ($rootdev)"
fi

# 2. nvme driver state (fact; required only on NVMe boots)
if lsmod 2>/dev/null | grep -q '^nvme' || [ -d /sys/module/nvme_core ]; then
    add_check "nvme driver" "INFO" "active"
else
    add_check "nvme driver" "INFO" "not active"
fi

# 3. All fstab entries mounted.
#
# LINUX-TEMP-1 (found live): this used to fail ANY unmounted non-root entry,
# which made every v4 -> v6 Linux machine fail validation. Two reasons it was
# wrong. The cloud image's temp-disk entry carries `nofail` - the operating
# system has been told that mount may be absent, and the machine boots fine -
# so failing it made this check stricter than the machine's own configuration.
# And the temp disk is already judged by check 6; judging it here as well let
# the generic rule silently overrule the specific one.
#
# So: a REQUIRED entry that is not mounted is still a failure. An entry the
# system itself marks optional is a fact, and the temp disk belongs to check 6.
missing=""
optional=""
while IFS= read -r line; do
    case "$line" in \#*|"") continue ;; esac
    mp=$(echo "$line" | awk '{print $2}')
    opts=$(echo "$line" | awk '{print $4}')
    case "$mp" in /|none|swap|/boot/efi) continue ;; esac
    # the temporary disk is check 6's business, not this one's
    case "$mp" in /mnt|/mnt/resource) continue ;; esac
    [ -n "$mp" ] || continue
    if findmnt -n "$mp" >/dev/null 2>&1; then continue; fi
    case ",$opts," in
        *,nofail,*) optional="$optional $mp" ;;
        *)          missing="$missing $mp" ;;
    esac
done < "$FSTAB"
if [ -n "$missing" ]; then
    add_check "fstab mounts" "FAIL" "not mounted:$missing"
elif [ -n "$optional" ]; then
    add_check "fstab mounts" "INFO" "not mounted, marked nofail by the system:$optional"
else
    add_check "fstab mounts" "PASS" "all required entries mounted"
fi

# 3b. The mounted volumes, a FACT the engine compares with the reading before
# the move (VOLUMES-ONLINE-1: "volumes online as they were before"). Every
# fstab mount point that is mounted now, nofail ones too - a nofail volume that
# was mounted before and is not now is a volume lost. Left out: swap, noauto
# (a start does not mount it, so a move must not be failed for it), a network
# share (it comes and goes with the network, not with the disks) and the
# temporary disk (its own check, 6). Joined with "; ", as fstab writes it.
# >>> vmf-temp-disk
# VOLUMES-ONLINE-1: the same text in every guest script that has it - a test
# holds every copy equal. The Azure temporary disk is not a volume the move
# must keep: a move to a size without one removes it by design, and its own
# check judges it.
# VOLUMES-MNT-DATA-DISK-1: the volume comparison and the mounts after a
# put-back ask vmf_is_temp_device_mount - the temporary disk only by its
# DEVICE: the fstab source names azure_resource (cloud-init), or the device
# (mounted now, or the fstab source resolved) is the one that
# /dev/disk/azure/resource or /dev/disk/cloud/azure_resource points to, or a
# partition of it (the Azure udev rules). Never by the folder name: a managed
# data disk mounted on /mnt is a volume like any other, and a device that is
# not known is compared, never left out.
# vmf_is_temp_mount (the name too: /mnt, /mnt/resource, waagent.conf's
# ResourceDisk.MountPoint) stays for temp-disk-content.sh, which reports such
# a mount as not known rather than reading it.
vmf_temp_devices() {
    local l r
    for l in "${VMF_TEST_ROOT:-}"/dev/disk/azure/resource "${VMF_TEST_ROOT:-}"/dev/disk/azure/resource-part* \
             "${VMF_TEST_ROOT:-}"/dev/disk/cloud/azure_resource "${VMF_TEST_ROOT:-}"/dev/disk/cloud/azure_resource-part*; do
        [ -e "$l" ] || continue
        r=$(readlink -f "$l" 2>/dev/null)
        [ -n "$r" ] && printf '%s\n' "$r"
    done
}
# Arguments: the mount point (unescaped) and its fstab source. True when it is
# the temporary disk.
vmf_is_temp_mount() {
    local mp="$1" src="$2" wa dev d
    case "$mp" in /mnt|/mnt/resource) return 0 ;; esac
    case "$src" in *azure_resource*|*/dev/disk/azure/resource*) return 0 ;; esac
    wa=$(sed -n 's/^[[:space:]]*ResourceDisk\.MountPoint=//p' "${VMF_TEST_ROOT:-}/etc/waagent.conf" 2>/dev/null | tail -n 1 | tr -d ' ')
    [ -n "$wa" ] && [ "$mp" = "$wa" ] && return 0
    dev=$(findmnt -n -o SOURCE "$mp" 2>/dev/null)
    [ -n "$dev" ] || return 1
    dev=$(readlink -f "$dev" 2>/dev/null || printf '%s' "$dev")
    for d in $(vmf_temp_devices); do
        case "$dev" in "$d"|"$d"[0-9]*|"$d"p[0-9]*) return 0 ;; esac
    done
    return 1
}
# Arguments: the mount point (unescaped) and its fstab source. True only when
# its device is the Azure resource disk.
vmf_is_temp_device_mount() {
    local mp="$1" src="$2" dev d
    case "$src" in *azure_resource*|*/dev/disk/azure/resource*) return 0 ;; esac
    dev=$(findmnt -n -o SOURCE "$mp" 2>/dev/null)
    if [ -z "$dev" ]; then
        case "$src" in
            UUID=*|LABEL=*|PARTUUID=*|PARTLABEL=*) dev=$(findfs "$src" 2>/dev/null) ;;
            /dev/*) dev="$src" ;;
        esac
    fi
    [ -n "$dev" ] || return 1
    dev=$(readlink -f "$dev" 2>/dev/null || printf '%s' "$dev")
    for d in $(vmf_temp_devices); do
        case "$dev" in "$d"|"$d"[0-9]*|"$d"p[0-9]*) return 0 ;; esac
    done
    return 1
}
# <<< vmf-temp-disk
vols=""
while IFS= read -r line; do
    case "$line" in \#*|"") continue ;; esac
    src=$(echo "$line" | awk '{print $1}')
    mp=$(echo "$line" | awk '{print $2}')
    fstype=$(echo "$line" | awk '{print $3}')
    opts=$(echo "$line" | awk '{print $4}')
    [ -n "$mp" ] || continue
    case "$mp" in none|swap) continue ;; esac
    case "$fstype" in swap|nfs|nfs4|cifs|smb3|smbfs|glusterfs|ceph|fuse.*|davfs) continue ;; esac
    case ",$opts," in *,noauto,*|*,_netdev,*) continue ;; esac
    real=$(printf '%b' "$mp")
    findmnt -n "$real" >/dev/null 2>&1 || continue
    vmf_is_temp_device_mount "$real" "$src" && continue
    if [ -z "$vols" ]; then vols="$mp"; else vols="$vols; $mp"; fi
done < "$FSTAB"
add_check "mounted volumes" "INFO" "${vols:-none}"

# 4. No fragile SCSI refs left in fstab
if grep -Eqs '^[^#]*(/dev/sd[a-z][0-9]*|/dev/disk/azure/scsi[0-9]*/lun[0-9]*)' "$FSTAB"; then
    add_check "fstab device names" "FAIL" "stale SCSI paths remain"
else
    add_check "fstab device names" "PASS" ""
fi

# 5. Block device inventory (engine compares to captured)
inv=$(lsblk -dn -o NAME,SIZE,TYPE 2>/dev/null | tr '\n' ' ')
add_check "block devices" "INFO" "$inv"

# 6. Temp disk mount. FACTS ONLY - the engine compares them to what this
# machine had before it moved (LINUX-TEMP-1). On v6/v7 the temporary disk is
# an NVMe namespace that arrives RAW on every start, so "there is a device but
# nothing on it" is a different and more useful fact than "not mounted".
tmp_mp=""
findmnt -n /mnt >/dev/null 2>&1 && tmp_mp="/mnt"
[ -z "$tmp_mp" ] && findmnt -n /mnt/resource >/dev/null 2>&1 && tmp_mp="/mnt/resource"
if [ -n "$tmp_mp" ]; then
    tmp_src=$(findmnt -n -o SOURCE "$tmp_mp" 2>/dev/null)
    add_check "temp disk mount" "PASS" "mounted at $tmp_mp from ${tmp_src:-unknown}"
else
    # Name the candidate device so an operator is not left guessing which one.
    tmp_dev=$(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk" && $1 ~ /^nvme/ {print $1}' | tail -1)
    if [ -n "$tmp_dev" ] && [ -z "$(lsblk -n -o NAME "/dev/$tmp_dev" 2>/dev/null | tail -n +2)" ]; then
        add_check "temp disk mount" "INFO" "not mounted; /dev/$tmp_dev present with no partitions (raw)"
    else
        add_check "temp disk mount" "INFO" "not mounted (diskless size, or the image manages it elsewhere)"
    fi
fi

if [ "$FAILS" -eq 0 ]; then result="PASS"; else result="FAIL"; fi
os=$(json_escape "$DISTRO_PRETTY")
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
#
# VOLUMES-ONLINE-1: and when root is on LVM, the topology is reported even
# when vgs shows nothing. An LVM devices file that names the disks by an old
# device ID hides every volume group from vgs while root still runs (it was
# activated in the initramfs). This block used to be skipped then, so the
# comparison saw no topology after and said MATCH, with /var/crash not mounted.
if command -v vgs >/dev/null 2>&1 && { echo "$rootsrc" | grep -q '^/dev/mapper/' || vgs --noheadings 2>/dev/null | grep -q .; }; then
    vgtotal=$(vgs --noheadings 2>/dev/null | grep -c .)
    lvtotal=$(lvs --noheadings 2>/dev/null | grep -c .)
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
        opts=$(echo "$line" | awk '{print $4}')
        case "$src" in /dev/mapper/*) ;; *) continue ;; esac
        [ -n "$mp" ] || continue
        # VOLUMES-ONLINE-1: swap is never mounted, and a start does not mount
        # noauto - neither is a volume group that did not assemble.
        case "$mp" in none|swap) continue ;; esac
        case ",$opts," in *,noauto,*) continue ;; esac
        findmnt -n "$mp" >/dev/null 2>&1 || dmmissing="$dmmissing ${mp}(${src})"
    done < "$FSTAB"
    if [ -n "$dmmissing" ]; then
        add_check "lvm volumes mounted" "INFO" "NOT MOUNTED:$dmmissing - the volume group did not assemble"
    else
        add_check "lvm volumes mounted" "INFO" "every LVM entry in fstab is mounted"
    fi
fi

# VOLUMES-ONLINE-1: the LVM devices file, a FACT - in use or not, and each
# physical volume it lists that LVM does not use now.
# >>> vmf-lvm-facts
# VOLUMES-ONLINE-1: the same text in every guest script that has it - a test
# holds every copy equal. lvmdevices(8): with use_devicesfile=1 and the file
# present, LVM uses only the devices the file lists, each by a device ID
# (sys_wwid first). A disk made from a snapshot, and the same disk on NVMe,
# has another device ID, so LVM does not use its physical volume: pvs shows
# nothing, and fstab cannot mount a volume of that volume group.
vmf_lvm_devfile() {
    if [ -n "${VMF_LVM_DEVICES_FILE:-}" ]; then printf '%s' "$VMF_LVM_DEVICES_FILE"; return 0; fi
    local name
    name=$(lvmconfig --typeconfig full --valuesonly devices/devicesfile 2>/dev/null | tr -d '" ')
    [ -n "$name" ] || name="system.devices"
    printf '/etc/lvm/devices/%s' "$name"
}
# yes, no, or nolvm.
vmf_lvm_inuse() {
    command -v pvs >/dev/null 2>&1 || { echo nolvm; return 0; }
    local v
    v=$(lvmconfig --typeconfig full --valuesonly devices/use_devicesfile 2>/dev/null | tr -d '" ')
    if [ "$v" = "1" ] && [ -f "$(vmf_lvm_devfile)" ]; then echo yes; else echo no; fi
}
# The PVID of each physical volume the devices file lists.
vmf_lvm_file_pvids() {
    grep -o 'PVID=[^ ]*' "$(vmf_lvm_devfile)" 2>/dev/null | sed 's/^PVID=//' | grep -v -x -F 'none' | grep . | sort -u
}
# The PVID of each physical volume LVM uses now.
vmf_lvm_seen_pvids() {
    pvs --noheadings -o pv_uuid 2>/dev/null | tr -d ' -' | grep . | sort -u
}
# Each PVID the devices file lists that LVM does not use now.
vmf_lvm_missing() {
    local seen id
    seen=$(vmf_lvm_seen_pvids)
    for id in $(vmf_lvm_file_pvids); do
        printf '%s\n' "$seen" | grep -qx "$id" || printf '%s\n' "$id"
    done
}
# The fact, in the words the engine reads (Get-VmfLvmDevicesFileFact).
vmf_lvm_fact() {
    local total missing count
    case "$(vmf_lvm_inuse)" in
        nolvm) echo "LVM is not installed"; return 0 ;;
        no) echo "not in use"; return 0 ;;
    esac
    total=$(vmf_lvm_file_pvids | grep -c .)
    missing=$(vmf_lvm_missing | tr '\n' ' ' | sed 's/ *$//')
    if [ -z "$missing" ]; then
        echo "in use ($(vmf_lvm_devfile)): $total physical volume(s), every one found"
    else
        count=$(vmf_lvm_missing | grep -c .)
        echo "in use ($(vmf_lvm_devfile)): $total physical volume(s), $count not found: $missing"
    fi
}
# <<< vmf-lvm-facts
add_check "lvm devices file" "INFO" "$(vmf_lvm_fact)"

printf '{"schema":"vmf.guest/2","script":"%s","version":"%s","os":"%s","result":"%s","checks":%s,"warnings":[]}\n' \
    "$SCRIPT_NAME" "$VMF_VERSION" "$os" "$result" "$CHECKS"
exit 0
