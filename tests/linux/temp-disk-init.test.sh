#!/bin/bash
# LINUX-TEMP-3: RUN the boot task that finds the local NVMe temporary disk,
# against fake /sys and /dev trees, and check which disks it would prepare.
#
# Found by the Gen1 drill, 2026-09-25: on Ubuntu 18.04 the temporary disk
# stayed raw after the move. The boot task found disks through azure-vm-utils
# or the `nvme` command, and the likely cause is an image with neither. It
# now reads each device's model from /sys. Every other check of this script
# reads its TEXT; this one runs it, in the dry run the script provides for
# tests, so nothing is formatted and nothing is mounted.
#
# Runs in CI's Linux job (ci.yml). Needs bash, readlink and grep only.
set -u

here=$(cd "$(dirname "$0")" && pwd)
setup="$here/../../src/guest/linux/temp-disk-setup.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

# Cases 4 and 5 are about a symbolic link. Where links cannot be made (Git Bash
# on Windows copies the file instead), those cases would silently pass through
# the OTHER lookup - a result never measured. Refuse to run instead.
ln -s "$work" "$work/link-probe" 2>/dev/null
if [ ! -L "$work/link-probe" ]; then
    echo "FAIL: this machine cannot create symbolic links, so the azure-vm-utils cases cannot be tested here. Run it on Linux (CI's Linux job does)."
    exit 1
fi

# The boot task is written by temp-disk-setup.sh from a quoted heredoc.
# Extract exactly that text, so the test runs what a machine would run.
init="$work/vmf-temp-disk-init.sh"
awk '/<<.INITEOF.$/ { on = 1; next } /^INITEOF$/ { on = 0 } on' "$setup" > "$init"
if [ ! -s "$init" ]; then echo "FAIL: could not extract the boot task from temp-disk-setup.sh"; exit 1; fi
# A mount point that is certainly not mounted, so the task does not stop early
# on a runner whose own /mnt is in use.
sed -i "s#__MOUNT_POINT__#$work/not-mounted#" "$init"

# One fake machine: disk "name:model" pairs, and an optional by-index link.
make_machine() {
    local root="$1"; shift
    mkdir -p "$root/dev" "$root/sys/block"
    local pair name model
    for pair in "$@"; do
        name="${pair%%:*}"; model="${pair#*:}"
        mkdir -p "$root/sys/block/$name/device"
        printf '%s\n' "$model" > "$root/sys/block/$name/device/model"
        : > "$root/dev/$name"
    done
}

targets() { VMF_TEST_ROOT="$1" VMF_TEST_DRY_RUN=1 bash "$init" 2>/dev/null | sed -n 's/^TARGETS://p'; }

expect() { # description, root, expected device names (space separated, may be empty)
    local got want
    got=$(targets "$2" | tr ' ' '\n' | sed '/^$/d' | xargs -n1 basename 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//')
    want=$(printf '%s\n' $3 | sed '/^$/d' | sort | tr '\n' ' ' | sed 's/ $//')
    if [ "$got" = "$want" ]; then echo "PASS: $1"; else echo "FAIL: $1 - wanted [$want], got [$got]"; failures=$((failures + 1)); fi
}

# 1. The drill's Ubuntu 18.04: no azure-vm-utils, no nvme-cli. The OS disk and
#    one local disk, as the kernel names them.
m="$work/u18"; make_machine "$m" "nvme0n1:MSFT NVMe Accelerator v1.0" "nvme1n1:Microsoft NVMe Direct Disk"
expect "finds the local disk from /sys alone, and never the OS disk" "$m" "nvme1n1"

# 2. A size with two local disks, reporting the v2 model string measured on
#    real machines.
m="$work/two"; make_machine "$m" "nvme0n1:MSFT NVMe Accelerator v1.0" "nvme1n1:Microsoft NVMe Direct Disk v2" "nvme2n1:Microsoft NVMe Direct Disk v2"
expect "finds both local disks on a size with two" "$m" "nvme1n1 nvme2n1"

# 3. A size with no local disk: nothing to prepare.
m="$work/none"; make_machine "$m" "nvme0n1:MSFT NVMe Accelerator v1.0"
expect "a size with no local disk prepares nothing" "$m" ""

# 4. azure-vm-utils present: its link is used, and its index is not assumed.
m="$work/utils"; make_machine "$m" "nvme0n1:MSFT NVMe Accelerator v1.0" "nvme1n1:Microsoft NVMe Direct Disk v2"
mkdir -p "$m/dev/disk/azure/local/by-index"; ln -s ../../../../nvme1n1 "$m/dev/disk/azure/local/by-index/1"
expect "uses the azure-vm-utils link when it is there" "$m" "nvme1n1"

# 5. A link that somehow resolves to the OS disk is still refused.
m="$work/badlink"; make_machine "$m" "nvme0n1:MSFT NVMe Accelerator v1.0"
mkdir -p "$m/dev/disk/azure/local/by-index"; ln -s ../../../../nvme0n1 "$m/dev/disk/azure/local/by-index/0"
expect "never the OS disk, even through a link" "$m" ""

if [ "$failures" -gt 0 ]; then echo "$failures failure(s)"; exit 1; fi
echo "all passed"
