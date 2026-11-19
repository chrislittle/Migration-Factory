#!/bin/bash
# data-disk-seed.sh - DISK-1 (VmMigrationFactory). Idempotent.
# Partition/format RAW data disks (ext4), mount at /datadisk<N> with fstab UUID
# entries, and write a seed file + sha256 so a post-migration verify can prove
# the data survived. Never touches the OS disk or the resource/temp disk.
# Emits ONE JSON object per schemas/guest-output.schema.json.
# result: FIXED | NO_CHANGE | BLOCKED
VMF_VERSION="1.0.0"
SCRIPT_NAME="data-disk-seed.sh"

CHECKS="[]"
CHANGED=0

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
    [ "$2" = "FIXED" ] && CHANGED=1
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

# Azure stable symlinks identify data disks by LUN regardless of SCSI/NVMe naming.
# Both symlink trees can exist and point at the SAME devices - dedupe by
# resolved device (found by the P2-7 drill: double-processing broke mounts).
mount_index=0
seen_devs=""
for lun_link in /dev/disk/azure/scsi1/lun*[0-9] /dev/disk/azure/data/by-lun/*[0-9]; do
    [ -e "$lun_link" ] || continue
    case "$lun_link" in *-part*) continue ;; esac
    dev=$(readlink -f "$lun_link")
    case " $seen_devs " in *" $dev "*) continue ;; esac
    seen_devs="$seen_devs $dev"

    # Skip if the whole disk or a partition already has a filesystem
    if blkid "$dev" >/dev/null 2>&1 || blkid "${dev}1" >/dev/null 2>&1 || blkid "${dev}p1" >/dev/null 2>&1; then
        add_check "disk $lun_link" "PASS" "already has filesystem"
    else
        parted -s "$dev" mklabel gpt mkpart primary ext4 0% 100% >/dev/null 2>&1
        sleep 2
        part="${dev}1"; [ -b "$part" ] || part="${dev}p1"
        mkfs.ext4 -q -L "vmf-data-$mount_index" "$part"
        add_check "disk $lun_link" "FIXED" "partitioned + ext4 ($part)"
    fi

    # Resolve the partition device for mounting
    part="${dev}1"; [ -b "$part" ] || part="${dev}p1"
    [ -b "$part" ] || { add_check "partition for $lun_link" "FAIL" "not found"; continue; }

    mp="/datadisk$mount_index"
    uuid=$(blkid -s UUID -o value "$part")
    if ! grep -qs "UUID=$uuid" /etc/fstab; then
        mkdir -p "$mp"
        echo "UUID=$uuid $mp ext4 defaults,nofail 0 2" >> /etc/fstab
        add_check "fstab $mp" "FIXED" "UUID=$uuid"
    fi
    mountpoint -q "$mp" || mount "$mp" 2>/dev/null
    if mountpoint -q "$mp"; then
        add_check "mount $mp" "PASS" ""
    else
        add_check "mount $mp" "FAIL" "could not mount $part at $mp"
        mount_index=$((mount_index+1)); continue
    fi

    if [ -f "$mp/vmf-seed.bin" ] && [ -f "$mp/vmf-seed.sha256" ]; then
        add_check "seed $mp" "PASS" "already seeded"
    else
        dd if=/dev/urandom of="$mp/vmf-seed.bin" bs=1M count=4 status=none
        sha256sum "$mp/vmf-seed.bin" | awk '{print $1}' > "$mp/vmf-seed.sha256"
        add_check "seed $mp" "FIXED" "$(cut -c1-12 "$mp/vmf-seed.sha256")..."
    fi
    mount_index=$((mount_index+1))
done

if [ "$mount_index" -eq 0 ]; then
    add_check "data disks" "WARN" "no data-disk LUN symlinks found"
fi

if printf '%s' "$CHECKS" | grep -q '"status":"FAIL"'; then emit "BLOCKED" "one or more disk operations failed"
elif [ "$CHANGED" -eq 1 ]; then emit "FIXED"
else emit "NO_CHANGE"; fi
exit 0
