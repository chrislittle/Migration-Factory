#!/bin/bash
# lvm-devices-refresh.sh - make LVM use its physical volumes again after the
# machine is put back on disks made from the safety copies, then activate the
# volume groups and mount fstab (VmMigrationFactory, VOLUMES-ONLINE-1).
#
# FOUND IN THE FINAL LAB, 2026-11-13 (Oracle Linux 9.7, root on LVM): the
# devices file /etc/lvm/devices/system.devices named the root PV by its
# sys_wwid. A disk made from a snapshot is a new disk with a new device ID, so
# after the rollback LVM did not use the PV - `pvs` showed nothing,
# rootvg-crashlv stayed inactive and /var/crash was not mounted. Root still
# started, from the initramfs (rd.lvm.lv), where the devices file is not read.
# LVM refreshes device IDs by itself only when the machine's product_uuid
# changes (lvm2 2.03.23 and later), and a rollback keeps the same machine.
#
# The engine runs this after every rollback and every restore of a Linux
# machine, before it compares the volumes with the reading before the move.
# Where the devices file is not in use, it reports that and changes nothing.
# The shebang stays: a payload with none runs under sh (CLAUDE.md).
#
# Emits ONE JSON object per schemas/guest-output.schema.json (vmf.guest/2).
# result: FIXED (it changed something) | NO_CHANGE | BLOCKED (a physical
# volume is still not found, or an fstab entry did not mount).
VMF_VERSION="1.1.0"
SCRIPT_NAME="lvm-devices-refresh.sh"
# The tests point these at files of their own. On a machine they are empty.
FSTAB="${VMF_FSTAB:-/etc/fstab}"

CHECKS="[]"
CHANGED=0
BLOCKED_MSG=""

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
    [ "$2" = "FIXED" ] && CHANGED=1
    [ "$2" = "FAIL" ] && BLOCKED_MSG="$1: $3"
    return 0
}

emit() {
    local os
    os=$(json_escape "$DISTRO_PRETTY")
    printf '{"schema":"vmf.guest/2","script":"%s","version":"%s","os":"%s","result":"%s","checks":%s,"warnings":[]' \
        "$SCRIPT_NAME" "$VMF_VERSION" "$os" "$1" "$CHECKS"
    if [ -n "$2" ]; then printf ',"error":"%s"' "$(json_escape "$2")"; fi
    printf '}\n'
}

DISTRO_PRETTY="unknown"
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_PRETTY="${PRETTY_NAME:-$ID}"
fi

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

# >>> vmf-lvm-refresh
# VOLUMES-ONLINE-1: the same text in every guest script that has it - a test
# holds every copy equal. lvmdevices(8): "lvmdevices --update --refresh"
# finds each physical volume of the devices file on its new device, by its
# PVID. An lvm2 with no --refresh (before 2.03.23), or a PV the refresh does
# not find: --delpvid takes out the entry with the old device ID, and --adddev
# adds the device that holds that PV now. Only a PVID the file lists is ever
# added, so a disk the file kept out stays out. The file is copied once, to
# <file>.vmf-bak, before the first change; a copy that is there is kept.
# Prints none, refresh, adddev or failed.
vmf_lvm_refresh() {
    local f how pvid dev
    f=$(vmf_lvm_devfile)
    if [ -z "$(vmf_lvm_missing)" ]; then echo none; return 0; fi
    [ -e "$f.vmf-bak" ] || cp -p "$f" "$f.vmf-bak" 2>/dev/null
    how=failed
    if lvmdevices --help 2>&1 | grep -q -- '--refresh'; then
        lvmdevices --update --refresh >/dev/null 2>&1
        [ -z "$(vmf_lvm_missing)" ] && how=refresh
    fi
    if [ "$how" = failed ]; then
        for pvid in $(vmf_lvm_missing); do
            dev=$(pvs --devicesfile "" --noheadings -o pv_name,pv_uuid 2>/dev/null | awk -v want="$pvid" '{ u = $2; gsub(/-/, "", u); if (u == want) { print $1; exit } }')
            [ -n "$dev" ] || continue
            lvmdevices --delpvid "$pvid" >/dev/null 2>&1
            lvmdevices --adddev "$dev" >/dev/null 2>&1
        done
        [ -z "$(vmf_lvm_missing)" ] && how=adddev
    fi
    echo "$how"
}
# <<< vmf-lvm-refresh

DEVFILE=$(vmf_lvm_devfile)
add_check "lvm devices file" "INFO" "$(vmf_lvm_fact)"
if [ "$(vmf_lvm_inuse)" != "yes" ]; then
    emit "NO_CHANGE" ""
    exit 0
fi

# --- 1. the devices file ---------------------------------------------------
# A disk can arrive a moment after the agent answers: wait for udev first.
if command -v udevadm >/dev/null 2>&1; then udevadm settle --timeout=60 >/dev/null 2>&1; fi
HOW=$(vmf_lvm_refresh)
case "$HOW" in
    none)    add_check "lvm devices refresh" "PASS" "every physical volume in the devices file is found" ;;
    refresh) add_check "lvm devices refresh" "FIXED" "lvmdevices --update --refresh found each physical volume on its new device (backup: $DEVFILE.vmf-bak)" ;;
    adddev)  add_check "lvm devices refresh" "FIXED" "lvmdevices --adddev added each physical volume again by its PVID (backup: $DEVFILE.vmf-bak)" ;;
    *)       add_check "lvm devices refresh" "FAIL" "not found on any device after the refresh: $(vmf_lvm_missing | tr '\n' ' ' | sed 's/ *$//')" ;;
esac

# --- 2. activation ----------------------------------------------------------
# -aay is the activation a start does: it keeps auto_activation_volume_list,
# so a logical volume the machine does not activate at start stays inactive.
active_before=$(lvs --noheadings -o lv_active 2>/dev/null | grep -c active)
if vgchange -aay >/dev/null 2>&1; then
    active_after=$(lvs --noheadings -o lv_active 2>/dev/null | grep -c active)
    if [ "$active_after" -gt "$active_before" ]; then
        add_check "lvm activation" "FIXED" "vgchange -aay activated $((active_after - active_before)) logical volume(s)"
    else
        add_check "lvm activation" "PASS" "vgchange -aay: every logical volume was already active"
    fi
else
    add_check "lvm activation" "FAIL" "vgchange -aay did not finish"
fi

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

# --- 3. fstab ---------------------------------------------------------------
# What a start mounts: every entry that is not mounted, except swap, noauto,
# a network share and the temporary disk (its own task, and judged apart).
mounted=""
failed=""
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
    vmf_is_temp_device_mount "$real" "$src" && continue
    if findmnt -n "$real" >/dev/null 2>&1; then continue; fi
    if mount "$real" >/dev/null 2>&1; then mounted="$mounted $mp"; else failed="$failed $mp"; fi
done < "$FSTAB"
if [ -n "$failed" ]; then
    add_check "fstab mounts after refresh" "FAIL" "did not mount:$failed$( [ -n "$mounted" ] && printf '; mounted:%s' "$mounted")"
elif [ -n "$mounted" ]; then
    add_check "fstab mounts after refresh" "FIXED" "mounted:$mounted"
else
    add_check "fstab mounts after refresh" "PASS" "every entry a start mounts is mounted"
fi

if [ -n "$BLOCKED_MSG" ]; then emit "BLOCKED" "$BLOCKED_MSG"
elif [ "$CHANGED" -eq 1 ]; then emit "FIXED" ""
else emit "NO_CHANGE" ""; fi
exit 0
