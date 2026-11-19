#!/bin/bash
# lvm-devices-task.sh - the LVM devices file start task for a move to v5 or
# Bsv2 (VmMigrationFactory, VOLUMES-ONLINE-V5-1). Idempotent.
# A move to v5 or Bsv2 is a resize on SCSI, and the disk most likely keeps its
# device ID - but that is not measured. Where LVM uses a devices file and it
# lists a physical volume, this installs the same one-time start task as the
# NVMe preparation (nvme-fix.sh step 4, one text): at the first start after
# the move it finds each physical volume on its device ID, activates the
# volume groups, and removes itself. It changes nothing else: no fstab, no
# start-up image, and not the devices file itself.
# Emits ONE JSON object per schemas/guest-output.schema.json.
# result: FIXED | NO_CHANGE | BLOCKED
VMF_VERSION="1.0.0"
SCRIPT_NAME="lvm-devices-task.sh"

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
add_check "distro" "INFO" "$DISTRO_PRETTY"
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
# >>> vmf-lvm-task
# VOLUMES-ONLINE-V5-1: the same text in nvme-fix.sh (a move to NVMe) and
# lvm-devices-task.sh (a move to v5 or Bsv2) - a test holds them equal.
# The tests install under a folder of their own. On a machine it is empty.
LVM_TASK="${VMF_TEST_ROOT:-}/usr/local/sbin/vmf-lvm-devices-refresh.sh"
LVM_UNIT="${VMF_TEST_ROOT:-}/etc/systemd/system/vmf-lvm-devices-refresh.service"
if [ "$(vmf_lvm_inuse)" = "yes" ] && [ -n "$(vmf_lvm_file_pvids)" ]; then
    lvm_had=0
    [ -f "$LVM_UNIT" ] && [ -f "$LVM_TASK" ] && lvm_had=1
    mkdir -p "$(dirname "$LVM_TASK")" "$(dirname "$LVM_UNIT")"
    cat > "$LVM_TASK" <<'LVMTASKEOF'
#!/bin/bash
# Installed by VmMigrationFactory (VOLUMES-ONLINE-1). Runs once, at the first
# start after the move: it finds each LVM physical volume
# of the devices file on its new device ID, activates the volume groups, and
# removes itself - also when a PV is still not found, which the journal (tag
# vmf-lvm-devices-refresh) names.
set -u
UNIT="vmf-lvm-devices-refresh.service"
log() { logger -t vmf-lvm-devices-refresh "$1" 2>/dev/null || true; }
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
HOW=none
if [ "$(vmf_lvm_inuse)" = "yes" ]; then
    # The disks must be known to udev before LVM looks for them.
    if command -v udevadm >/dev/null 2>&1; then udevadm settle --timeout=60 >/dev/null 2>&1; fi
    HOW=$(vmf_lvm_refresh)
    log "devices file $(vmf_lvm_devfile): $HOW"
    # -aay is the activation a start does: it keeps auto_activation_volume_list.
    vgchange -aay >/dev/null 2>&1
fi
# Once only: a start that ran the refresh ends the task, whatever it found.
# A PV still not found is left for Verifying, which finds the volume not
# mounted and rolls the move back. What stays: the copy <file>.vmf-bak and
# this line in the journal.
if [ "$HOW" = "failed" ]; then
    log "not found on any device: $(vmf_lvm_missing | tr '\n' ' '). The devices file and its copy <file>.vmf-bak stay as they are."
fi
systemctl disable "$UNIT" >/dev/null 2>&1
rm -f "${VMF_TEST_ROOT:-}/etc/systemd/system/$UNIT" "$0"
log "done, and removed itself"
exit 0
LVMTASKEOF
    chmod 755 "$LVM_TASK"
    cat > "$LVM_UNIT" <<'LVMUNITEOF'
[Unit]
Description=Find the LVM physical volumes on their new device IDs once, after the move (VmMigrationFactory)
DefaultDependencies=no
After=systemd-remount-fs.service systemd-udev-trigger.service
Before=local-fs-pre.target
Wants=local-fs-pre.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vmf-lvm-devices-refresh.sh
TimeoutStartSec=180

[Install]
WantedBy=sysinit.target
LVMUNITEOF
    if systemctl enable vmf-lvm-devices-refresh.service >/dev/null 2>&1; then
        if [ "$lvm_had" -eq 1 ]; then
            add_check "lvm devices file" "PASS" "vmf-lvm-devices-refresh.service is installed and enabled ($(vmf_lvm_fact))"
        else
            add_check "lvm devices file" "FIXED" "The product installed vmf-lvm-devices-refresh.service. At the first start after the move, the task finds each physical volume by its new device ID. Then the task removes itself. $(vmf_lvm_fact)."
        fi
    else
        add_check "lvm devices file" "FAIL" "The product could not enable vmf-lvm-devices-refresh.service. $(vmf_lvm_fact)."
    fi
else
    add_check "lvm devices file" "PASS" "$(vmf_lvm_fact)"
fi
# <<< vmf-lvm-task

if [ -n "$BLOCKED_MSG" ]; then emit "BLOCKED" "$BLOCKED_MSG"
elif [ "$CHANGED" -eq 1 ]; then emit "FIXED"
else emit "NO_CHANGE"; fi
exit 0