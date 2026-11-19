#!/bin/bash
# VOLUMES-MNT-DATA-DISK-1: RUN the shared vmf-temp-disk block against a fake
# /dev tree with REAL symbolic links, the way the Azure udev rules make them.
#
# The volume comparison (guest-validate.sh) and the mounts after a put-back
# (lvm-devices-refresh.sh) leave the Azure temporary disk out. They used to
# take /mnt for it by its folder name, so a managed data disk mounted on /mnt
# was never compared, and a move could leave it unmounted with no stop. Now
# vmf_is_temp_device_mount decides by the DEVICE only: the device behind
# /dev/disk/azure/resource or /dev/disk/cloud/azure_resource, or a partition
# of it. A data disk, or a device that is not known, is compared.
#
# Runs in CI's Linux job (ci.yml). Needs bash, readlink and awk only.
set -u

here=$(cd "$(dirname "$0")" && pwd)
src="$here/../../src/guest/linux/guest-validate.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

ln -s "$work" "$work/link-probe" 2>/dev/null
if [ ! -L "$work/link-probe" ]; then
    echo "FAIL: this machine cannot create symbolic links, so the device cases cannot be tested here. Run it on Linux (CI's Linux job does)."
    exit 1
fi

# The shared block, exactly as the guest script carries it.
block="$work/vmf-temp-disk.sh"
awk '/^# >>> vmf-temp-disk$/ { on = 1 } on { print } /^# <<< vmf-temp-disk$/ { on = 0 }' "$src" > "$block"
if ! grep -q '^vmf_is_temp_device_mount()' "$block"; then echo "FAIL: no vmf_is_temp_device_mount in the vmf-temp-disk block of guest-validate.sh"; exit 1; fi
# shellcheck source=/dev/null
. "$block"

# The fake machine: sdb is the resource disk, sdc the data disk on LUN 0.
root="$work/root"
mkdir -p "$root/dev/disk/azure/scsi1" "$root/dev/disk/cloud"
: > "$root/dev/sdb"; : > "$root/dev/sdb1"; : > "$root/dev/sdc"; : > "$root/dev/sdc1"
ln -s ../../sdb "$root/dev/disk/azure/resource"
ln -s ../../sdb1 "$root/dev/disk/azure/resource-part1"
ln -s ../../sdb1 "$root/dev/disk/cloud/azure_resource-part1"
ln -s ../../../sdc "$root/dev/disk/azure/scsi1/lun0"
export VMF_TEST_ROOT="$root"

# Stand-ins: what is mounted where ($MOUNTED: "<mount point> <device>"), and
# which device a UUID names ($UUIDS: "<source> <device>").
MOUNTED=""; UUIDS=""
findmnt() { local mp="${!#}"; printf '%s\n' "$MOUNTED" | awk -v m="$mp" '$1 == m { print $2; f = 1 } END { exit !f }'; }
findfs() { printf '%s\n' "$UUIDS" | awk -v s="$1" '$1 == s { print $2; f = 1 } END { exit !f }'; }

expect() { # description, want (temp|volume), mount point, fstab source
    local got=volume
    vmf_is_temp_device_mount "$3" "$4" && got=temp
    if [ "$got" = "$2" ]; then echo "PASS: $1"; else echo "FAIL: $1 - wanted $2, got $got"; failures=$((failures + 1)); fi
}

MOUNTED="/mnt $root/dev/sdc1"
expect "a data disk (LUN 0) mounted on /mnt is a volume" volume /mnt "UUID=0000-dat"
MOUNTED="/mnt $root/dev/disk/azure/scsi1/lun0"
expect "a data disk mounted on /mnt by its LUN link is a volume" volume /mnt "/dev/disk/azure/scsi1/lun0"
MOUNTED="/mnt $root/dev/sdb1"
expect "the resource disk partition mounted on /mnt is the temporary disk" temp /mnt "UUID=0000-res"
MOUNTED="/data/scratch $root/dev/disk/azure/resource-part1"
expect "the resource disk mounted anywhere, by its link, is the temporary disk" temp /data/scratch "UUID=0000-res"
MOUNTED="/mnt /dev/sdq1"
expect "a device that is not known is a volume, never left out" volume /mnt "UUID=0000-unk"
MOUNTED=""; UUIDS="UUID=0000-res $root/dev/sdb1
UUID=0000-dat $root/dev/sdc1"
expect "not mounted: the fstab UUID of the resource disk is the temporary disk" temp /mnt/resource "UUID=0000-res"
expect "not mounted: the fstab UUID of a data disk is a volume" volume /mnt "UUID=0000-dat"
expect "not mounted, a UUID nothing resolves: a volume" volume /mnt "UUID=0000-none"
expect "the fstab source cloud-init writes for the resource disk is the temporary disk" temp /mnt "/dev/disk/cloud/azure_resource-part1"
expect "the folder name alone is not the temporary disk" volume /mnt ""

# The name rule stays in vmf_is_temp_mount, for temp-disk-content.sh.
if vmf_is_temp_mount /mnt ""; then echo "PASS: vmf_is_temp_mount still knows /mnt by its name"; else echo "FAIL: vmf_is_temp_mount no longer knows /mnt by its name"; failures=$((failures + 1)); fi

if [ "$failures" -gt 0 ]; then echo "$failures case(s) failed"; exit 1; fi
echo "every case passed"
