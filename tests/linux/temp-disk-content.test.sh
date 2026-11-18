#!/bin/bash
# LINUX-TEMP-DISK-FILES-1 and LINUX-MNT-DATA-DISK-1: RUN temp-disk-content.sh
# against a fake machine with REAL symbolic links under /dev/disk/azure, and
# check which mount it reads as the temporary disk. The device decides, never
# the folder name: a managed data disk mounted on /mnt is kept by the move, so
# a stop for its files would say something false.
#
# tests/unit/LinuxTempDiskFiles.Tests.ps1 runs the script too, with plain files
# for the device names, because Git Bash on Windows cannot make a link. This
# file covers the links and the partitions.
#
# Runs in CI's Linux job (ci.yml). Needs bash, readlink and grep only.
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/../../src/guest/linux/temp-disk-content.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

ln -s "$work" "$work/link-probe" 2>/dev/null
if [ ! -L "$work/link-probe" ]; then
    echo "FAIL: this machine cannot create symbolic links, so the device cases cannot be tested here. Run it on Linux (CI's Linux job does)."
    exit 1
fi

# One fake machine: the resource disk is sdb, the data disks are sdc (LUN 0,
# scsi1 tree) and sdd (LUN 1, data/by-lun tree). Argument: the /proc/mounts
# lines. Prints the machine root.
make_machine() {
    local m
    m=$(mktemp -d -p "$work")
    mkdir -p "$m/proc" "$m/etc" "$m/mnt" "$m/dev/disk/azure/scsi1" "$m/dev/disk/azure/data/by-lun"
    : > "$m/dev/sdb"; : > "$m/dev/sdb1"; : > "$m/dev/sdc"; : > "$m/dev/sdd"; : > "$m/dev/sdd1"; : > "$m/dev/sde1"
    ln -s ../../sdb "$m/dev/disk/azure/resource"
    ln -s ../../sdb1 "$m/dev/disk/azure/resource-part1"
    ln -s ../../../sdc "$m/dev/disk/azure/scsi1/lun0"
    ln -s ../../../../sdd "$m/dev/disk/azure/data/by-lun/1"
    printf '%s\n' "$@" > "$m/proc/mounts"
    printf 'Filename Type Size Used Priority\n' > "$m/proc/swaps"
    : > "$m/mnt/customer-file.txt"
    mkdir -p "$m/mnt/lost+found"
    printf '%s' "$m"
}

# Arguments: case name, machine root, a fixed string the output must hold, and
# a fixed string it must not hold (or "").
expect() {
    local name="$1" m="$2" want="$3" notwant="$4" out
    out=$(VMF_TEST_ROOT="$m" bash "$script" 2>/dev/null)
    if ! printf '%s' "$out" | grep -qF -- "$want"; then
        echo "FAIL: $name - wanted [$want] in: $out"; failures=$((failures + 1)); return
    fi
    if [ -n "$notwant" ] && printf '%s' "$out" | grep -qF -- "$notwant"; then
        echo "FAIL: $name - did not want [$notwant] in: $out"; failures=$((failures + 1)); return
    fi
    echo "ok: $name"
}

m=$(make_machine '/dev/sda1 / ext4 rw 0 0' '/dev/sdb1 /mnt ext4 rw 0 0')
expect "the resource disk's partition on /mnt is read" "$m" '"result":"NEEDS_PREP"' ''
expect "and its file is named" "$m" '"warnings":["/mnt/customer-file.txt"]' ''

m=$(make_machine '/dev/sda1 / ext4 rw 0 0' '/dev/sdc /mnt xfs rw 0 0')
expect "a data disk (scsi1/lun0) on /mnt is not read" "$m" '"result":"READY"' 'customer-file.txt'

m=$(make_machine '/dev/sda1 / ext4 rw 0 0' '/dev/sdd1 /mnt xfs rw 0 0')
expect "a partition of a data disk (data/by-lun) on /mnt is not read" "$m" '"result":"READY"' 'customer-file.txt'
expect "and it is known as a data disk, not unknown" "$m" '"result":"READY"' 'temporary disk identity'

# Only the whole-disk link (no resource-part1, as cloud-init's azure_resource
# alone gives): the partition is matched by its name.
m=$(make_machine '/dev/sda1 / ext4 rw 0 0' '/dev/sdb1 /mnt ext4 rw 0 0')
rm "$m/dev/disk/azure/resource-part1"
expect "a partition of the resource disk, with only the whole-disk link, is read" "$m" '"warnings":["/mnt/customer-file.txt"]' ''

m=$(make_machine '/dev/sda1 / ext4 rw 0 0' '/dev/sde1 /mnt ext4 rw 0 0')
expect "an unknown device on /mnt is not read, and the result says so" "$m" 'The script did not read /mnt, because it cannot identify the device as the temporary disk.' 'customer-file.txt'

m=$(make_machine '/dev/sda1 / ext4 rw 0 0')
expect "the resource disk not mounted is not read, and the result says so" "$m" 'The temporary disk is not mounted. The script did not read it.' 'customer-file.txt'

if [ "$failures" -gt 0 ]; then echo "$failures case(s) failed"; exit 1; fi
echo "temp-disk-content.test.sh: every case passed"
