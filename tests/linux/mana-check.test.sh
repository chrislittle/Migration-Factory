#!/bin/bash
# ORACLE-UEK-UPDATE-1: RUN the Linux MANA readiness check with uname, lsmod,
# modinfo and ethtool replaced by stubs on PATH, and a fake /etc/os-release and
# /etc/yum.repos.d under VMF_TEST_ROOT. Nothing on this machine is read.
#
# What it proves: on Oracle Linux the check reports the enabled repositories
# whose id has UEK in it (uekRepositories) - a section with no enabled line is
# enabled, enabled=0 is not, every .repo file is read - 'none' when none is
# enabled and 'unknown' with no repository folder; another distribution reports
# no such fact; and the answer is ONE JSON object of the guest contract, v6.
# KERNEL-OFFER-EDGES-1 and KERNEL-FLOOR-UPLOAD-1: the releasever setting on
# Red Hat and its rebuilds, and the kernel package version on Ubuntu and Debian.
#
# Runs in CI's Linux job (ci.yml), and under Git Bash. Needs bash and python3
# (or python) to read the JSON.
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/../../src/guest/linux/mana-check.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

PY=""
for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import json' >/dev/null 2>&1; then PY="$candidate"; break; fi
done
if [ -z "$PY" ]; then echo "FAIL: python3 is needed to read the JSON the script writes"; exit 1; fi

bin="$work/bin"
mkdir -p "$bin"
cat > "$bin/uname" <<'EOF'
#!/bin/bash
echo "$FAKE_KERNEL"
EOF
# AN-TRAFFIC-VERIFY-1: curl and wget too - the check sends Instance Metadata
# Service requests before it reads the counters, and nothing here may reach
# the network.
for tool in lsmod modinfo ethtool curl wget; do
    printf '#!/bin/bash\nexit 1\n' > "$bin/$tool"
done
# KERNEL-FLOOR-UPLOAD-1: dpkg-query gives the version of the kernel package
# FAKE_DPKG_PACKAGE, and logs what it was asked.
cat > "$bin/dpkg-query" <<'EOF'
#!/bin/bash
echo "dpkg-query $*" >> "$FAKE_LOG"
last="${*: -1}"
if [ -n "${FAKE_DPKG_VERSION:-}" ] && [ "$last" = "${FAKE_DPKG_PACKAGE:-}" ]; then printf '%s' "$FAKE_DPKG_VERSION"; exit 0; fi
echo "dpkg-query: no packages found matching $last" >&2
exit 1
EOF
chmod +x "$bin"/*

# One fake machine: its os-release and, when asked, a repository folder.
new_root() { # id version_id
    ROOTDIR="$work/root-$RANDOM$RANDOM"
    mkdir -p "$ROOTDIR/etc"
    printf 'ID="%s"\nVERSION_ID="%s"\nPRETTY_NAME="%s %s"\n' "$1" "$2" "$1" "$2" > "$ROOTDIR/etc/os-release"
}
run_check() {
    : > "$work/tools.log"
    OUT=$(PATH="$bin:$PATH" VMF_TEST_ROOT="$ROOTDIR" FAKE_KERNEL="$1" FAKE_LOG="$work/tools.log" \
          FAKE_DPKG_VERSION="${FAKE_DPKG_VERSION:-}" FAKE_DPKG_PACKAGE="${FAKE_DPKG_PACKAGE:-}" bash "$script" 2>/dev/null)
    LOGTEXT=$(cat "$work/tools.log")
}

field() {
    printf '%s' "$OUT" | "$PY" -c '
import json, sys
doc = json.loads(sys.stdin.read())
key = sys.argv[1]
if key.startswith("check:"):
    name = key[6:]
    print(next((c.get("detail", "") for c in doc["checks"] if c["name"] == name), "<none>"))
elif key.startswith("status:"):
    name = key[7:]
    print(next((c.get("status", "") for c in doc["checks"] if c["name"] == name), "<none>"))
elif key.startswith("fact:"):
    print(doc.get("facts", {}).get(key[5:], "<none>"))
else:
    print(doc.get(key, "<none>"))
' "$1"
}

expect() { # description, got, want
    if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 - wanted [$3], got [$2]"; failures=$((failures + 1)); fi
}
expect_one_object() {
    local lines
    lines=$(printf '%s\n' "$OUT" | sed '/^$/d' | wc -l | tr -d ' ')
    expect "$1: one line of output" "$lines" "1"
    if printf '%s' "$OUT" | "$PY" -c 'import json,sys; d=json.loads(sys.stdin.read()); assert d["schema"]=="vmf.guest/6" and d["script"]=="mana-check.sh"' 2>/dev/null; then
        echo "PASS: $1: one JSON object of the guest contract"
    else
        echo "FAIL: $1: not one JSON object of the guest contract - [$OUT]"; failures=$((failures + 1))
    fi
}

# Oracle Linux 9.7 as the Azure image ships it, with UEK R7 set to start and
# ol9_UEKR8 still enabled (lab 2026-11-14). The section with no enabled line
# is enabled; enabled=0 is not; a second file is read too; CR line ends are
# read as LF.
new_root ol 9.7
mkdir -p "$ROOTDIR/etc/yum.repos.d"
printf '[ol9_UEKR7]\nname=UEK R7\nbaseurl=https://yum.example.com/uekr7\nenabled=1\n\n[ol9_UEKR8]\nname=UEK R8\nbaseurl=https://yum.example.com/uekr8\nenabled = 1\n\n[ol9_UEKR6]\nname=UEK R6\nenabled=0\n' > "$ROOTDIR/etc/yum.repos.d/uek-ol9.repo"
printf '[ol9_baseos_latest]\r\nname=BaseOS\r\nenabled=1\r\n[ol9_UEKR8_test]\r\nname=test\r\n' > "$ROOTDIR/etc/yum.repos.d/oracle-linux-ol9.repo"
run_check 5.15.0-326.224.5.1.el9uek.x86_64
expect_one_object "oracle linux"
expect "oracle linux: the enabled UEK repositories" "$(field 'fact:uekRepositories')" "ol9_UEKR7 ol9_UEKR8 ol9_UEKR8_test"
expect "oracle linux: said in the checks too" "$(field 'check:uek repositories enabled')" "ol9_UEKR7 ol9_UEKR8 ol9_UEKR8_test"
expect "oracle linux: the kernel" "$(field 'fact:kernelVersion')" "5.15.0-326.224.5.1.el9uek.x86_64"

# The UEK R8 repository turned off (dnf config-manager writes enabled=0).
new_root ol 9.7
mkdir -p "$ROOTDIR/etc/yum.repos.d"
printf '[ol9_UEKR7]\nenabled=1\n[ol9_UEKR8]\nenabled=0\n' > "$ROOTDIR/etc/yum.repos.d/uek-ol9.repo"
run_check 5.15.0-326.224.5.1.el9uek.x86_64
expect "uek r8 off: only UEK R7" "$(field 'fact:uekRepositories')" "ol9_UEKR7"

# No UEK repository enabled at all.
new_root ol 9.7
mkdir -p "$ROOTDIR/etc/yum.repos.d"
printf '[ol9_UEKR7]\nenabled=0\n[ol9_baseos_latest]\nenabled=1\n' > "$ROOTDIR/etc/yum.repos.d/uek-ol9.repo"
run_check 5.15.0-326.224.5.1.el9uek.x86_64
expect "none enabled: none" "$(field 'fact:uekRepositories')" "none"

# No repository folder: unknown, never none.
new_root ol 9.7
run_check 5.15.0-326.224.5.1.el9uek.x86_64
expect "no folder: unknown" "$(field 'fact:uekRepositories')" "unknown"

# Another distribution reports no such fact.
new_root ubuntu 22.04
mkdir -p "$ROOTDIR/etc/yum.repos.d"
printf '[ol9_UEKR8]\nenabled=1\n' > "$ROOTDIR/etc/yum.repos.d/uek-ol9.repo"
run_check 5.15.0-1031-azure
expect_one_object "ubuntu"
expect "ubuntu: no uekRepositories fact" "$(field 'fact:uekRepositories')" "<none>"
expect "ubuntu: the distribution" "$(field 'fact:distroId')" "ubuntu"

# KERNEL-OFFER-EDGES-1: Red Hat and its rebuilds report the minor release dnf
# is held to (the EUS, SAP and HA RHUI clients lock releasever), read from
# /etc/dnf/vars, else /etc/yum/vars.
new_root rhel 9.4
mkdir -p "$ROOTDIR/etc/dnf/vars"
printf '9.4\n' > "$ROOTDIR/etc/dnf/vars/releasever"
run_check 5.14.0-427.13.1.el9_4.x86_64
expect_one_object "rhel eus"
expect "rhel eus: held to 9.4" "$(field 'fact:releaseverLock')" "9.4"
expect "rhel eus: said in the checks too" "$(field 'check:releasever')" "9.4"
expect "rhel eus: no kernel package version (not dpkg)" "$(field 'fact:kernelPackageVersion')" "<none>"

new_root rocky 9.4
mkdir -p "$ROOTDIR/etc/yum/vars"
printf '  9.4  \r\n' > "$ROOTDIR/etc/yum/vars/releasever"
run_check 5.14.0-427.13.1.el9_4.x86_64
expect "rocky: yum vars are read too, trimmed" "$(field 'fact:releaseverLock')" "9.4"

new_root rhel 9.6
run_check 5.14.0-570.12.1.el9_6.x86_64
expect "rhel non-eus: none" "$(field 'fact:releaseverLock')" "none"

new_root ubuntu 22.04
run_check 5.15.0-1096-azure
expect "ubuntu: no releasever fact" "$(field 'fact:releaseverLock')" "<none>"

# KERNEL-FLOOR-UPLOAD-1: Ubuntu reports the version of the package of the
# running kernel - the upload number is there, not in uname.
FAKE_DPKG_VERSION='5.15.0-1096.105'
FAKE_DPKG_PACKAGE='linux-image-5.15.0-1096-azure'
new_root ubuntu 22.04
run_check 5.15.0-1096-azure
expect_one_object "ubuntu package version"
expect "ubuntu: the kernel package version" "$(field 'fact:kernelPackageVersion')" "5.15.0-1096.105"
expect "ubuntu: said in the checks too" "$(field 'check:kernel package version')" "5.15.0-1096.105"
case "$LOGTEXT" in *"linux-image-5.15.0-1096-azure"*) echo "PASS: ubuntu: dpkg-query is asked for the package of the running kernel" ;; *) echo "FAIL: ubuntu: dpkg-query was not asked for linux-image-5.15.0-1096-azure - [$LOGTEXT]"; failures=$((failures + 1)) ;; esac
FAKE_DPKG_PACKAGE='linux-image-some-other-kernel'
new_root ubuntu 22.04
run_check 5.15.0-1096-azure
expect "ubuntu: no package found is unknown" "$(field 'fact:kernelPackageVersion')" "unknown"
new_root debian 12
FAKE_DPKG_PACKAGE='linux-image-6.1.0-41-cloud-amd64'
FAKE_DPKG_VERSION='6.1.158-1'
run_check 6.1.0-41-cloud-amd64
expect "debian: the kernel package version" "$(field 'fact:kernelPackageVersion')" "6.1.158-1"
new_root rhel 9.6
run_check 5.14.0-570.12.1.el9_6.x86_64
expect "rhel: no kernel package version" "$(field 'fact:kernelPackageVersion')" "<none>"
FAKE_DPKG_VERSION=''
FAKE_DPKG_PACKAGE=''

# MANA-BUILTIN-READ-1: Microsoft's own check also reads a driver built into the
# kernel - grep /mana*.ko /lib/modules/$(uname -r)/modules.builtin. modinfo
# (the stub fails here, as an older modinfo does for a built-in driver) is not
# the only answer: a built-in driver counts as present.
new_root ubuntu 24.04
mkdir -p "$ROOTDIR/lib/modules/6.8.0-1041-azure"
printf 'kernel/drivers/net/hyperv/hv_netvsc.ko\nkernel/drivers/net/ethernet/microsoft/mana/mana.ko\n' > "$ROOTDIR/lib/modules/6.8.0-1041-azure/modules.builtin"
run_check 6.8.0-1041-azure
expect_one_object "built-in mana"
expect "built-in mana: the driver is available" "$(field 'status:mana module available')" "PASS"
expect "built-in mana: said where" "$(field 'check:mana module available')" "The MANA driver is built into the kernel. modules.builtin lists kernel/drivers/net/ethernet/microsoft/mana/mana.ko."
expect "built-in mana: READY" "$(field result)" "READY"

# A modules.builtin of the running kernel with no MANA driver, or another
# kernel's list: not available.
new_root ubuntu 24.04
mkdir -p "$ROOTDIR/lib/modules/6.8.0-1041-azure" "$ROOTDIR/lib/modules/6.8.0-1050-azure"
printf 'kernel/drivers/net/hyperv/hv_netvsc.ko\nkernel/drivers/net/ethernet/microsoft/mana/manafake.ko\n' > "$ROOTDIR/lib/modules/6.8.0-1041-azure/modules.builtin"
printf 'kernel/drivers/net/ethernet/microsoft/mana/mana.ko\n' > "$ROOTDIR/lib/modules/6.8.0-1050-azure/modules.builtin"
run_check 6.8.0-1041-azure
expect "no built-in mana: WARN" "$(field 'status:mana module available')" "WARN"
expect "no built-in mana: NEEDS_PREP" "$(field result)" "NEEDS_PREP"

# No modules.builtin at all: not available, as before.
new_root ubuntu 24.04
run_check 6.8.0-1041-azure
expect "no modules.builtin: WARN" "$(field 'status:mana module available')" "WARN"

if [ "$failures" -gt 0 ]; then echo "$failures failure(s)"; exit 1; fi
echo "all passed"
