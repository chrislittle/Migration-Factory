#!/bin/bash
# temp-disk-content.sh - list what is on the Azure temporary disk that the
# system did not put there. Read-only (LINUX-TEMP-DISK-FILES-1). The Linux twin
# of Test-TempDiskContent.ps1.
#
# Runs INSIDE the guest via Azure RunCommand. The shebang stays: a payload with
# none runs under sh (CLAUDE.md).
#
# A move stops (deallocates) the machine. Microsoft: data on the temporary
# disk might be lost "when you stop the VM", and "On Azure Linux VMs, the
# temporary disk is typically /dev/disk/azure/resource"
# (https://learn.microsoft.com/en-us/azure/virtual-machines/managed-disks-overview#temporary-disk,
# read 2026-11-14). The engine asks this in PRECHECK, while the machine still
# runs and before anything stops or changes it, so a machine that stops for
# these files is left exactly as it was.
#
# The temporary disk is a MOUNTED file system whose DEVICE is the Azure
# resource disk: the device that /dev/disk/azure/resource or
# /dev/disk/cloud/azure_resource points to (the Azure udev rules, cloud-init),
# or a partition of it - vmf_temp_devices in the shared block. Never the folder
# name alone (LINUX-MNT-DATA-DISK-1): a managed data disk mounted on /mnt is
# kept by the move, so a stop for its files would say something false. A mount
# from a data disk (/dev/disk/azure/scsi1/lun*, /dev/disk/azure/data/by-lun/*)
# is never the temporary disk. A mount that the shared block takes for the
# temporary disk by its name or by waagent.conf, with a device that is neither,
# is not read, and the result says so (unknown is no stop, and no pass either:
# the check is INFO). The shared block itself is not changed here - two other
# scripts read it - so the stricter test is this script's own.
#
# A temporary disk that is not mounted is not read: reading it would need a
# mount, which changes the machine, and no program on the machine can reach
# files on it while it is not mounted. The result says so. A /mnt folder on
# the OS disk is not mounted, and a move does not lose it.
#
# What the system puts there itself, never reported: lost+found (mkfs),
# DATALOSS_WARNING_README.txt (Azure), swapfile (the Azure Linux Agent's
# ResourceDisk.EnableSwap, and cloud-init's usual name), any file that is an
# active swap file in /proc/swaps, and System Volume Information (a disk still
# NTFS, as Azure formats it).
#
# RunCommand returns only the last 4096 bytes of output, so at most 40 items
# or about 2500 characters are named, then "and N more" - as on Windows.
#
# Output contract: schemas/guest-output.schema.json. result: READY (nothing to
# lose), NEEDS_PREP (files found - listed in `warnings`), BLOCKED (a listing
# failed). The ENGINE decides, by the wave's onDDataFound setting.
#
# VMF_TEST_ROOT: the tests point it at a stand-in machine. On a machine it is
# empty.
VMF_VERSION="1.1.0"
SCRIPT_NAME="temp-disk-content.sh"
MAXNAMED=40
MAXCHARS=2500
ROOT="${VMF_TEST_ROOT:-}"

CHECKS="[]"
WARNINGS="[]"
DISTRO_PRETTY="unknown"
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    DISTRO_PRETTY=$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-$ID}")
fi

# The JSON text of $1, in $JE. Every control character goes, not only CR and
# LF: a tab in a file name must not break the one JSON object. Pure bash, with
# no subshell: it runs once for each item on the disk.
json_escape() {
    JE="${1//\\/\\\\}"
    JE="${JE//\"/\\\"}"
    JE="${JE//[[:cntrl:]]/}"
}

add_check() { # name status detail
    local n s d
    json_escape "$1"; n="$JE"; json_escape "$2"; s="$JE"; json_escape "$3"; d="$JE"
    if [ "$CHECKS" = "[]" ]; then
        CHECKS="[{\"name\":\"$n\",\"status\":\"$s\",\"detail\":\"$d\"}]"
    else
        CHECKS="${CHECKS%]},{\"name\":\"$n\",\"status\":\"$s\",\"detail\":\"$d\"}]"
    fi
    return 0
}

add_warning() {
    json_escape "$1"
    if [ "$WARNINGS" = "[]" ]; then WARNINGS="[\"$JE\"]"; else WARNINGS="${WARNINGS%]},\"$JE\"]"; fi
}

emit() { # result [error]
    json_escape "$DISTRO_PRETTY"
    printf '{"schema":"vmf.guest/2","script":"%s","version":"%s","os":"%s","result":"%s","checks":%s,"warnings":%s' \
        "$SCRIPT_NAME" "$VMF_VERSION" "$JE" "$1" "$CHECKS" "$WARNINGS"
    if [ -n "$2" ]; then json_escape "$2"; printf ',"error":"%s"' "$JE"; fi
    printf '}\n'
}

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

# The mounted file systems: "<source> <mount point> ...", octal escapes as the
# kernel writes them (a space is \040, a backslash \134). printf %b reads an
# octal escape as \0NNN, so each backslash gets its 0 first. Each mount point
# once.
MOUNTS_FILE="$ROOT/proc/mounts"
SWAPS_FILE="$ROOT/proc/swaps"
if [ ! -r "$MOUNTS_FILE" ]; then
    add_check "temporary disk content" "FAIL" "The script cannot read $MOUNTS_FILE."
    emit "BLOCKED" "The script cannot read the list of mounted file systems in $MOUNTS_FILE."
    exit 0
fi
# The devices of the resource disk and of the managed data disks, resolved.
tempdevs=$(vmf_temp_devices)
datadevs=""
for l in "$ROOT"/dev/disk/azure/scsi1/lun* "$ROOT"/dev/disk/azure/data/by-lun/*; do
    [ -e "$l" ] || continue
    r=$(readlink -f "$l" 2>/dev/null)
    [ -n "$r" ] && datadevs="${datadevs:+$datadevs
}$r"
done
# Arguments: a resolved device and a list of devices, one per line. True when
# the device is one of them or a partition of one.
vmf_dev_in() {
    local dev="$1" d
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        case "$dev" in "$d"|"$d"[0-9]*|"$d"p[0-9]*) return 0 ;; esac
    done <<DEVEOF
$2
DEVEOF
    return 1
}

temps=""
tempdevmounted=""
allmounts=""
unknown=""
while read -r src mp _rest; do
    [ -n "$mp" ] || continue
    printf -v src '%b' "${src//\\/\\0}"; printf -v mp '%b' "${mp//\\/\\0}"
    allmounts="${allmounts:+$allmounts
}$mp"
    dev=""
    case "$src" in /dev/*) dev=$(readlink -f "$ROOT$src" 2>/dev/null) ;; esac
    if [ -n "$dev" ] && vmf_dev_in "$dev" "$datadevs"; then
        continue
    fi
    if [ -n "$dev" ] && [ -n "$tempdevs" ] && vmf_dev_in "$dev" "$tempdevs"; then
        tempdevmounted=1
        case "
$temps
" in *"
$mp
"*) ;; *) temps="${temps:+$temps
}$mp" ;; esac
    elif vmf_is_temp_mount "$mp" "$src"; then
        unknown="${unknown:+$unknown, }$mp"
    fi
done < "$MOUNTS_FILE"

if [ -n "$unknown" ]; then
    add_check "temporary disk identity" "INFO" "The script did not read $unknown, because it cannot identify the device as the temporary disk."
fi
if [ -z "$temps" ]; then
    if [ -n "$tempdevs" ] && [ -z "$tempdevmounted" ]; then
        add_check "temporary disk content" "INFO" "The temporary disk is not mounted. The script did not read it."
    else
        add_check "temporary disk content" "INFO" "The script found no mounted temporary disk."
    fi
    emit "READY"
    exit 0
fi

# The active swap files, by path.
swaps=""
if [ -r "$SWAPS_FILE" ]; then
    while read -r f _rest; do
        [ "$f" = "Filename" ] && continue
        [ -n "$f" ] || continue
        printf -v f '%b' "${f//\\/\\0}"
        swaps="${swaps:+$swaps
}$f"
    done < "$SWAPS_FILE"
fi

found=0
used=0
named=0
blocked=""
while IFS= read -r mp; do
    [ -n "$mp" ] || continue
    dir="$ROOT$mp"
    # A listing that fails is BLOCKED, never "nothing found".
    if [ ! -d "$dir" ] || [ ! -r "$dir" ] || [ ! -x "$dir" ]; then
        blocked="The script cannot list the folder $mp of the temporary disk."
        break
    fi
    shopt -s nullglob dotglob
    for item in "$dir"/*; do
        name="${item##*/}"
        case "$name" in
            lost+found|DATALOSS_WARNING_README.txt|swapfile|"System Volume Information") continue ;;
        esac
        full="${mp%/}/$name"
        # An active swap file is the system's. A folder that another file
        # system is mounted on is that file system, not the temporary disk.
        case "
$swaps
$allmounts
" in *"
$full
"*) continue ;; esac
        found=$((found + 1))
        line="$full"
        # Run Command keeps only the tail of the output, about 4 KB, so the
        # cap counts BYTES of the line as it is written into the JSON (after
        # escaping): a name of multi-byte characters, or one with many quotes,
        # must not push the object past the tail and fail the check.
        esc=$(json_escape "$line")
        cost=$(LC_ALL=C; echo "${#esc}")
        if [ "$named" -lt "$MAXNAMED" ] && [ $((used + cost)) -le "$MAXCHARS" ] && [ "$named" -eq "$((found - 1))" ]; then
            add_warning "$line"
            named=$((named + 1)); used=$((used + cost))
        fi
    done
    shopt -u nullglob dotglob
done <<EOF
$temps
EOF

if [ -n "$blocked" ]; then
    add_check "temporary disk content" "FAIL" "$blocked"
    emit "BLOCKED" "$blocked"
    exit 0
fi

where=$(printf '%s' "$temps" | tr '\n' ' ' | sed 's/ $//')
if [ "$found" -gt 0 ]; then
    if [ "$found" -gt "$named" ]; then
        more=$((found - named))
        if [ "$more" -eq 1 ]; then add_warning "1 more file or folder"; else add_warning "$more more files or folders"; fi
    fi
    if [ "$found" -eq 1 ]; then items="1 file or folder"; else items="$found files or folders"; fi
    add_check "temporary disk content" "WARN" "The script found $items on $where that the system did not create. The warnings list them."
    emit "NEEDS_PREP"
else
    add_check "temporary disk content" "PASS" "The script found only system files and folders on $where."
    emit "READY"
fi
exit 0
