#!/bin/bash
# temp-disk-setup.sh - LINUX-TEMP-1 part 2. The Linux twin of
# Install-TempDiskInit.ps1: installs a boot-time initialiser for the v6/v7
# local NVMe temporary disk, then removes the stale cloud-image fstab line
# that can no longer resolve. Idempotent.
#
# WHY A BOOT TASK AND NOT A ONE-OFF. Microsoft (enable-nvme-temp-faqs,
# retrieved 2026-08-28): v6 VMs "come with raw, unformatted NVMe disks",
# nothing is visible "until after they're initialized and formatted", and
# "it's a best practice to run the mounting script automatically every time
# the VM starts". The drive is wiped on every stop, deallocation and
# maintenance event - formatting once would last until the first restart.
#
# MEASURED, and it is why the identification here is what it is: the local
# drive answers "Microsoft NVMe Direct Disk" while the OS disk answers
# "MSFT NVMe Accelerator", and azure-vm-utils exposes the local drive at
# /dev/disk/azure/local/by-index/N - N was 1, not the 0 in Microsoft's own
# example. Nothing may assume a device name, an order, or an index.
#
# Runs INSIDE the guest via RunCommand, BEFORE conversion. The unit fires on
# the first boot of the new size.
# Emits ONE JSON object per schemas/guest-output.schema.json.
# result: FIXED | NO_CHANGE | BLOCKED
VMF_VERSION="1.1.0"
SCRIPT_NAME="temp-disk-setup.sh"
MOUNT_POINT="${1:-/mnt}"

CHECKS="[]"
CHANGED=0
BLOCKED_MSG=""
DISTRO_PRETTY=$(. /etc/os-release 2>/dev/null && printf '%s' "$PRETTY_NAME")

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

if [ "$(id -u)" -ne 0 ]; then
    add_check "privileges" "FAIL" "must run as root"
    emit "BLOCKED" "$BLOCKED_MSG"; exit 0
fi

INIT_PATH="/usr/local/sbin/vmf-temp-disk-init.sh"
UNIT_PATH="/etc/systemd/system/vmf-temp-disk-init.service"

# --- 1. the per-boot initialiser -------------------------------------------
# Written here, run by systemd on every boot. It must be safe on a machine
# where the drive is already set up (a restart that did NOT wipe it) and on
# one where it is raw (the normal case).
cat > "$INIT_PATH" <<'INITEOF'
#!/bin/bash
# Installed by VmMigrationFactory (LINUX-TEMP-1). Prepares the local NVMe
# temporary disk on every boot, because Azure presents it raw every time.
# It is scratch space: everything on it is expected to be lost on a stop.
set -u
MOUNT_POINT="__MOUNT_POINT__"
LABEL="vmf_temp"
log() { logger -t vmf-temp-disk-init "$1"; }

already_mounted() { findmnt -n "$MOUNT_POINT" >/dev/null 2>&1; }
if already_mounted; then log "already mounted at $MOUNT_POINT"; exit 0; fi

# LINUX-TEMP-3: tests only. A fake /sys and /dev tree to find disks in, and a
# dry run that reports what it WOULD prepare and changes nothing. Both are
# empty on a real machine.
ROOT="${VMF_TEST_ROOT:-}"

# The model string the device itself reports, read from /sys. Every kernel
# provides it, so it needs no package. The OS disk answers "NVMe Accelerator";
# a local temporary disk answers "NVMe Direct Disk".
model_of() { cat "$ROOT/sys/block/$(basename "$1")/device/model" 2>/dev/null; }

# Identify LOCAL temporary disks. Preferred: the azure-vm-utils symlink tree,
# which Azure itself maintains. Otherwise: each NVMe device's own model string.
# Never a device name, never an index we assumed.
#
# LINUX-TEMP-3, Gen1 drill 2026-09-25: the fallback used to ask the `nvme`
# command (nvme-cli). On Ubuntu 18.04 the temporary disk stayed raw after the
# move - the likely cause being an image with neither azure-vm-utils nor
# nvme-cli, so nothing was found and this exited quietly. /sys needs neither.
devices=""
if [ -d "$ROOT/dev/disk/azure/local/by-index" ]; then
    for link in "$ROOT"/dev/disk/azure/local/by-index/*; do
        [ -e "$link" ] || continue
        case "$link" in *-part*) continue ;; esac
        devices="$devices $(readlink -f "$link")"
    done
fi
if [ -z "$devices" ]; then
    for block in "$ROOT"/sys/block/nvme*n*; do
        [ -e "$block" ] || continue
        if model_of "$block" | grep -qi 'NVMe Direct Disk'; then
            devices="$devices $ROOT/dev/$(basename "$block")"
        fi
    done
fi

usable=""
for d in $devices; do
    # Never touch a device that carries a mounted filesystem, and never the
    # OS disk (which answers "NVMe Accelerator", not "Direct Disk").
    if lsblk -n -o MOUNTPOINT "$d" 2>/dev/null | grep -q '[^[:space:]]'; then
        log "SKIP $d - something on it is mounted"; continue
    fi
    if model_of "$d" | grep -qi 'Accelerator'; then
        log "SKIP $d - this is the OS/remote disk"; continue
    fi
    usable="$usable $d"
done

if [ -n "${VMF_TEST_DRY_RUN:-}" ]; then echo "TARGETS:$usable"; exit 0; fi

set -- $usable
if [ "$#" -eq 0 ]; then log "no local temporary disk found - nothing to do"; exit 0; fi

target=""
if [ "$#" -eq 1 ]; then
    target="$1"
else
    # More than one: stripe them, the same shape as the Windows storage pool.
    mdadm --stop /dev/md/vmf_temp >/dev/null 2>&1
    for d in "$@"; do mdadm --zero-superblock "$d" >/dev/null 2>&1; done
    if mdadm --create /dev/md/vmf_temp --run --name=vmf_temp --level=0 \
            --raid-devices="$#" "$@" >/dev/null 2>&1; then
        target="/dev/md/vmf_temp"
    else
        log "could not stripe the drives; using the first one only"
        target="$1"
    fi
fi

mkfs.ext4 -q -F -L "$LABEL" "$target" || { log "format failed on $target"; exit 0; }
mkdir -p "$MOUNT_POINT"
mount "$target" "$MOUNT_POINT" || { log "mount failed for $target"; exit 0; }
chmod 1777 "$MOUNT_POINT" 2>/dev/null
log "prepared $target at $MOUNT_POINT"
exit 0
INITEOF
sed -i "s#__MOUNT_POINT__#$MOUNT_POINT#" "$INIT_PATH"
chmod 755 "$INIT_PATH"
add_check "boot initialiser" "FIXED" "installed $INIT_PATH (mount point $MOUNT_POINT)"

# --- 2. the unit that runs it every boot ------------------------------------
cat > "$UNIT_PATH" <<UNITEOF
[Unit]
Description=Prepare the local NVMe temporary disk (VmMigrationFactory)
DefaultDependencies=no
After=local-fs.target
Before=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$INIT_PATH

[Install]
WantedBy=multi-user.target
UNITEOF
if systemctl enable vmf-temp-disk-init.service >/dev/null 2>&1; then
    add_check "boot task" "FIXED" "vmf-temp-disk-init.service enabled (runs at every start)"
else
    add_check "boot task" "FAIL" "could not enable vmf-temp-disk-init.service"
    emit "BLOCKED" "$BLOCKED_MSG"; exit 0
fi

# --- 3. fstab ---------------------------------------------------------------
# The cloud image writes a /mnt line pointing at the SCSI resource disk on
# first boot. MEASURED: a machine born on v6 has no such line, and on v6 that
# path cannot exist - so it is removed here, with a backup. The mount itself
# is made by the boot task above, which is why no replacement line is needed;
# any line we did add would have to carry nofail, because the drive is
# genuinely optional.
if grep -Eqs '^[^#]*azure_resource' /etc/fstab; then
    cp /etc/fstab /etc/fstab.vmf-bak
    sed -i.tmp '/azure_resource/d' /etc/fstab && rm -f /etc/fstab.tmp
    add_check "stale temp-disk fstab entry" "FIXED" "removed the cloud image's resource-disk line (backup: /etc/fstab.vmf-bak); on the new hardware that device cannot exist"
else
    add_check "stale temp-disk fstab entry" "PASS" "none present"
fi

if [ "$CHANGED" -eq 1 ]; then emit "FIXED"; else emit "NO_CHANGE"; fi
exit 0
