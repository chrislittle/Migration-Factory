#!/bin/bash
# MANA-LINUX-KERNEL-1: RUN the guest script that updates a Linux kernel, with
# the package managers, uname and dpkg replaced by stubs on PATH, and a fake
# /etc/os-release and /boot under VMF_TEST_ROOT. Nothing is installed.
#
# What it proves: each distribution asks its own package manager for its own
# kernel package (and never anything else), the answer is ONE JSON object, a
# newer kernel reads FIXED, no newer kernel reads NO_CHANGE, and a failed
# package manager reads BLOCKED with its own words - with no raw control
# character, which would make the engine read no answer at all.
#
# Runs in CI's Linux job (ci.yml), and under Git Bash. Needs bash, sort -V and
# python3 (or python) to read the JSON.
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/../../src/guest/linux/kernel-update.sh"
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

# Every stub logs what it was asked, so a test can say which package manager
# ran and with which package.
cat > "$bin/uname" <<'EOF'
#!/bin/bash
echo "$FAKE_KERNEL"
EOF
cat > "$bin/dpkg" <<'EOF'
#!/bin/bash
echo "amd64"
EOF
cat > "$bin/dpkg-query" <<'EOF'
#!/bin/bash
[ -n "${FAKE_DPKG:-}" ] && printf '%s\n' "$FAKE_DPKG"
exit 0
EOF
# RHUI-REFRESH-1: rpm knows the RHUI client package FAKE_RHUI_NAME, whose
# version is in FAKE_RHUI_FILE; anything else answers FAKE_RPM_RC as before.
cat > "$bin/rpm" <<'EOF'
#!/bin/bash
case "$*" in
    *-qa*rhui-azure*) [ -n "${FAKE_RHUI_NAME:-}" ] && echo "$FAKE_RHUI_NAME"; exit 0 ;;
    *rhui-azure*) [ -s "${FAKE_RHUI_FILE:-}" ] && cat "$FAKE_RHUI_FILE"; exit 0 ;;
esac
exit "${FAKE_RPM_RC:-0}"
EOF
for pm in apt-get dnf yum zypper tdnf; do
    cat > "$bin/$pm" <<'EOF'
#!/bin/bash
name=$(basename "$0")
echo "$name $*" >> "$FAKE_LOG"
# RHUI-REFRESH-1: the update from the Microsoft repository only: a newer
# client (FAKE_RHUI_NEW), a failure (FAKE_RHUI_FAIL), or nothing newer.
case " $* " in
    *"microsoft-azure"*)
        if [ -n "${FAKE_RHUI_FAIL:-}" ]; then echo "Error: Failed to download metadata for repo 'rhui-microsoft-azure-rhel9'" >&2; exit 1; fi
        if [ -n "${FAKE_RHUI_NEW:-}" ]; then echo "$FAKE_RHUI_NEW" > "$FAKE_RHUI_FILE"; fi
        exit 0 ;;
esac
case " $* " in
    *" update "*) if [ "$name" = "apt-get" ] && [ "$#" -le 3 ]; then exit 0; fi ;;
esac
if [ -n "${FAKE_NEW:-}" ] && [ -n "${FAKE_RC:-}" ]; then : > "$VMF_TEST_ROOT/boot/vmlinuz-$FAKE_NEW"; exit "$FAKE_RC"; fi
if [ -n "${FAKE_FAIL:-}" ]; then
    printf 'E:\tUnable to locate package "%s"\n' "${*: -1}" >&2
    exit 100
fi
if [ -n "${FAKE_NEW:-}" ]; then : > "$VMF_TEST_ROOT/boot/vmlinuz-$FAKE_NEW"; fi
exit 0
EOF
done
# ORACLE-UEK-UPDATE-1: grubby, the Oracle Linux tool for the default boot
# kernel. The default starts as FAKE_DEFAULT; a change is logged and kept in
# FAKE_DEFAULT_FILE, so the script reads it back (KERNEL-UPDATE-OL-RHCK-1).
cat > "$bin/grubby" <<'EOF'
#!/bin/bash
echo "grubby $*" >> "$FAKE_LOG"
case "$1" in
    --default-kernel) cat "$FAKE_DEFAULT_FILE"; echo; exit 0 ;;
    --set-default)
        rc="${FAKE_GRUBBY_RC:-0}"
        [ "$rc" = "0" ] && printf '%s' "$2" > "$FAKE_DEFAULT_FILE"
        exit "$rc" ;;
esac
exit 0
EOF
chmod +x "$bin"/*

# One fake machine: its os-release, its running kernel, and the kernels in /boot.
# FAKE_EXTRA_BOOT: more kernels already in /boot, separated by spaces.
run_case() { # id version_id running_kernel new_kernel(or empty) [fail] [rpm_rc]; FAKE_DPKG and FAKE_RC from the caller
    local root="$work/root-$RANDOM" extra
    mkdir -p "$root/etc" "$root/boot"
    printf 'ID=%s\nVERSION_ID="%s"\nPRETTY_NAME="%s %s"\n' "$1" "$2" "$1" "$2" > "$root/etc/os-release"
    : > "$root/boot/vmlinuz-$3"
    for extra in ${FAKE_EXTRA_BOOT:-}; do : > "$root/boot/vmlinuz-$extra"; done
    : > "$work/pm.log"
    printf '%s' "${FAKE_RHUI_BEFORE:-}" > "$work/rhui.txt"
    printf '%s' "${FAKE_DEFAULT:-}" > "$work/default.txt"
    OUT=$(PATH="$bin:$PATH" VMF_TEST_ROOT="$root" FAKE_KERNEL="$3" FAKE_NEW="$4" FAKE_FAIL="${5:-}" FAKE_RPM_RC="${6:-0}" \
          FAKE_DPKG="${FAKE_DPKG:-}" FAKE_RC="${FAKE_RC:-}" FAKE_LOG="$work/pm.log" \
          FAKE_DEFAULT_FILE="$work/default.txt" FAKE_GRUBBY_RC="${FAKE_GRUBBY_RC:-0}" \
          FAKE_RHUI_NAME="${FAKE_RHUI_NAME:-}" FAKE_RHUI_FILE="$work/rhui.txt" FAKE_RHUI_NEW="${FAKE_RHUI_NEW:-}" FAKE_RHUI_FAIL="${FAKE_RHUI_FAIL:-}" \
          bash "$script" 2>/dev/null)
    LOGTEXT=$(cat "$work/pm.log")
}

# A field of the JSON the script wrote: result, error, or the detail of a check.
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
expect_has() { # description, text, part
    case "$2" in *"$3"*) echo "PASS: $1" ;; *) echo "FAIL: $1 - [$3] not in [$2]"; failures=$((failures + 1)) ;; esac
}
expect_one_object() {
    local lines
    lines=$(printf '%s\n' "$OUT" | sed '/^$/d' | wc -l | tr -d ' ')
    expect "$1: one line of output" "$lines" "1"
    if printf '%s' "$OUT" | "$PY" -c 'import json,sys; d=json.loads(sys.stdin.read()); assert d["schema"]=="vmf.guest/2" and d["script"]=="kernel-update.sh"' 2>/dev/null; then
        echo "PASS: $1: one JSON object of the guest contract"
    else
        echo "FAIL: $1: not one JSON object of the guest contract - [$OUT]"; failures=$((failures + 1))
    fi
}

# Ubuntu: linux-azure, from apt-get, and a newer kernel waits for the restart.
run_case ubuntu 22.04 5.15.0-1031-azure 5.15.0-1102-azure
expect_one_object "ubuntu"
expect "ubuntu: a newer kernel is FIXED" "$(field result)" "FIXED"
expect "ubuntu: the package is linux-azure" "$(field 'check:kernel package')" "linux-azure"
expect "ubuntu: the newest kernel installed" "$(field 'check:kernel installed')" "5.15.0-1102-azure"
expect "ubuntu: the kernel before is a fact" "$(field 'fact:kernelVersion')" "5.15.0-1031-azure"
expect_has "ubuntu: apt-get installs linux-azure" "$LOGTEXT" "install linux-azure"
expect_has "ubuntu: apt-get reads the configured repositories first" "$LOGTEXT" "apt-get -o DPkg::Lock::Timeout=120 update"

expect "ubuntu: the package manager ran" "$(field 'check:package manager ran')" "yes"

# Ubuntu pinned to an LTS Azure kernel keeps it.
FAKE_DPKG='linux-azure-lts-22.04 install ok installed'
run_case ubuntu 22.04 5.15.0-1031-azure 5.15.0-1102-azure
expect "ubuntu lts: the package is the one it has" "$(field 'check:kernel package')" "linux-azure-lts-22.04"
FAKE_DPKG=''

# Another Ubuntu flavour is never swapped for linux-azure: BLOCKED, nothing run.
run_case ubuntu 22.04 5.15.0-1031-azure-fips 5.15.0-1102-azure
expect "ubuntu fips: BLOCKED" "$(field result)" "BLOCKED"
expect "ubuntu fips: nothing was installed" "$LOGTEXT" ""
expect "ubuntu fips: the package manager did not run" "$(field 'check:package manager ran')" "no"
run_case ubuntu 22.04 5.15.0-120-generic 5.15.0-1102-azure
expect "ubuntu generic: BLOCKED" "$(field result)" "BLOCKED"

# SUSE's zypper says a reboot is needed with exit code 102: still a success.
FAKE_RC=102
run_case sles 15.5 5.14.21-150500.33.29-azure 5.14.21-150500.33.72-azure
expect "zypper 102 is a success" "$(field result)" "FIXED"
FAKE_RC=104
run_case sles 15.5 5.14.21-150500.33.29-azure 5.14.21-150500.33.72-azure
expect "zypper 104 is a failure" "$(field result)" "BLOCKED"
FAKE_RC=''

# Nothing newer in the configured repositories: NO_CHANGE, nothing claimed.
run_case ubuntu 22.04 5.15.0-1031-azure ""
expect "no newer kernel is NO_CHANGE" "$(field result)" "NO_CHANGE"

# A failed package manager: BLOCKED, with its own words, and no raw tab.
run_case ubuntu 22.04 5.15.0-1031-azure 5.15.0-1102-azure fail
expect_one_object "failure"
expect "a failed install is BLOCKED" "$(field result)" "BLOCKED"
expect_has "the error names the exit code" "$(field error)" "exit code 100"
expect_has "the error carries the package manager's own words" "$(field error)" "Unable to locate package"
case "$OUT" in *$'\t'*) echo "FAIL: a raw tab reached the JSON"; failures=$((failures + 1)) ;; *) echo "PASS: no raw control character in the JSON" ;; esac

# Red Hat: dnf upgrades the installed kernel package.
run_case rhel 9.4 5.14.0-427.13.1.el9_4.x86_64 5.14.0-570.52.1.el9_6.x86_64
expect "rhel: FIXED" "$(field result)" "FIXED"
expect "rhel: the package is kernel" "$(field 'check:kernel package')" "kernel"
expect_has "rhel: dnf upgrades it" "$LOGTEXT" "dnf -y upgrade kernel"

# A kernel package that is not installed yet is installed, not upgraded.
run_case almalinux 9.6 5.14.0-570.12.1.el9_6.x86_64 5.14.0-570.52.1.el9_6.x86_64 "" 1
expect_has "alma: a missing package is installed" "$LOGTEXT" "dnf -y install kernel"

# Oracle Linux on UEK stays on UEK.
run_case ol 9.4 5.15.0-200.131.27.el9uek.x86_64 6.12.0-100.28.2.el9uek.x86_64
expect "oracle uek: the package is kernel-uek" "$(field 'check:kernel package')" "kernel-uek"

# ORACLE-UEK-UPDATE-1: Oracle Linux 9.7 set to start UEK R7, with the UEK R8
# repository enabled (lab 2026-11-14). dnf upgrades kernel-uek to UEK R8, and
# grubby makes it the default boot kernel - never a repository change.
FAKE_DEFAULT=/boot/vmlinuz-5.15.0-326.224.5.1.el9uek.x86_64
run_case ol 9.7 5.15.0-326.224.5.1.el9uek.x86_64 6.12.0-105.51.5.el9uek.x86_64
expect_one_object "oracle uek r8"
expect "oracle uek r8: FIXED" "$(field result)" "FIXED"
expect "oracle uek r8: the kernel installed" "$(field 'check:kernel installed')" "6.12.0-105.51.5.el9uek.x86_64"
expect_has "oracle uek r8: dnf upgrades kernel-uek" "$LOGTEXT" "dnf -y upgrade kernel-uek"
expect_has "oracle uek r8: grubby makes it the default" "$LOGTEXT" "grubby --set-default /boot/vmlinuz-6.12.0-105.51.5.el9uek.x86_64"
expect "oracle uek r8: the default boot kernel is said" "$(field 'check:default boot kernel')" "6.12.0-105.51.5.el9uek.x86_64"
expect "oracle uek r8: the default before is said" "$(field 'check:default boot kernel before')" "/boot/vmlinuz-5.15.0-326.224.5.1.el9uek.x86_64"
case "$LOGTEXT" in *config-manager*|*--enablerepo*|*--disablerepo*) echo "FAIL: oracle uek r8: a repository was changed"; failures=$((failures + 1)) ;; *) echo "PASS: oracle uek r8: no repository is changed" ;; esac

# UEK R8 already installed but not the default: nothing newer to install, and
# it is made the default.
FAKE_EXTRA_BOOT=6.12.0-105.51.5.el9uek.x86_64
run_case ol 9.7 5.15.0-326.224.5.1.el9uek.x86_64 ""
expect "oracle uek r8 there: FIXED" "$(field result)" "FIXED"
expect_has "oracle uek r8 there: grubby makes it the default" "$LOGTEXT" "grubby --set-default /boot/vmlinuz-6.12.0-105.51.5.el9uek.x86_64"

# Already the default: grubby changes nothing.
FAKE_DEFAULT=/boot/vmlinuz-6.12.0-105.51.5.el9uek.x86_64
run_case ol 9.7 5.15.0-326.224.5.1.el9uek.x86_64 ""
expect "oracle uek default: said" "$(field 'check:default boot kernel')" "6.12.0-105.51.5.el9uek.x86_64"
case "$LOGTEXT" in *--set-default*) echo "FAIL: oracle uek default: grubby was asked to change it"; failures=$((failures + 1)) ;; *) echo "PASS: oracle uek default: grubby changes nothing" ;; esac
FAKE_EXTRA_BOOT=''

# grubby refuses: BLOCKED, and the package manager ran, so the engine puts the
# machine back.
FAKE_DEFAULT=/boot/vmlinuz-5.15.0-326.224.5.1.el9uek.x86_64
FAKE_GRUBBY_RC=1
run_case ol 9.7 5.15.0-326.224.5.1.el9uek.x86_64 6.12.0-105.51.5.el9uek.x86_64
expect "oracle uek grubby fails: BLOCKED" "$(field result)" "BLOCKED"
expect "oracle uek grubby fails: the package manager ran" "$(field 'check:package manager ran')" "yes"
expect_has "oracle uek grubby fails: says why" "$(field error)" "grubby could not make 6.12.0-105.51.5.el9uek.x86_64 the default boot kernel"
FAKE_GRUBBY_RC=0

# A newer Red Hat Compatible Kernel in /boot is not the UEK update: no newer
# UEK kernel is NO_CHANGE, and grubby is never asked.
FAKE_EXTRA_BOOT=5.14.0-611.5.1.el9_7.x86_64
run_case ol 9.7 5.4.17-2136.330.7.el9uek.x86_64 ""
expect "oracle uek with a newer rhck: NO_CHANGE" "$(field result)" "NO_CHANGE"
case "$LOGTEXT" in *grubby*) echo "FAIL: oracle uek with a newer rhck: grubby was asked"; failures=$((failures + 1)) ;; *) echo "PASS: oracle uek with a newer rhck: grubby is not asked" ;; esac
FAKE_EXTRA_BOOT=''

# KERNEL-UPDATE-OL-RHCK-1 (final lab, 2026-11-16, machine f-olr): Oracle Linux
# 9.7 set with grubby to start the Red Hat Compatible Kernel, with the image's
# UEK R8 kernel still in /boot. The update is kernel, the kernel installed is
# the newer RHCK kernel (never the UEK kernel, which sorts above it), and
# grubby makes it the default boot kernel.
FAKE_DEFAULT=/boot/vmlinuz-5.14.0-570.51.1.0.1.el9_6.x86_64
FAKE_EXTRA_BOOT=6.12.0-202.76.4.2.el9uek.x86_64
run_case ol 9.7 5.14.0-570.51.1.0.1.el9_6.x86_64 5.14.0-570.52.1.0.1.el9_6.x86_64
expect_one_object "oracle rhck"
expect "oracle rhck: FIXED" "$(field result)" "FIXED"
expect "oracle rhck: the package is kernel" "$(field 'check:kernel package')" "kernel"
expect "oracle rhck: the kernel installed is the RHCK kernel" "$(field 'check:kernel installed')" "5.14.0-570.52.1.0.1.el9_6.x86_64"
expect_has "oracle rhck: grubby makes it the default" "$LOGTEXT" "grubby --set-default /boot/vmlinuz-5.14.0-570.52.1.0.1.el9_6.x86_64"
expect "oracle rhck: the default boot kernel is said" "$(field 'check:default boot kernel')" "5.14.0-570.52.1.0.1.el9_6.x86_64"
case "$LOGTEXT" in *kernel-uek*|*"set-default /boot/vmlinuz-6.12"*) echo "FAIL: oracle rhck: the UEK kernel was asked for"; failures=$((failures + 1)) ;; *) echo "PASS: oracle rhck: the UEK kernel is not asked for" ;; esac

# No newer RHCK kernel in the repositories: NO_CHANGE, and the UEK kernel is
# never made the default.
run_case ol 9.7 5.14.0-570.51.1.0.1.el9_6.x86_64 ""
expect "oracle rhck none newer: NO_CHANGE" "$(field result)" "NO_CHANGE"
case "$LOGTEXT" in *set-default*) echo "FAIL: oracle rhck none newer: grubby was asked to change it"; failures=$((failures + 1)) ;; *) echo "PASS: oracle rhck none newer: grubby changes nothing" ;; esac
FAKE_EXTRA_BOOT=''
FAKE_DEFAULT=''

# Review, 2026-11-16: a +debug or +rt kernel of the same release is not a
# newer kernel for a machine on the plain kernel, and is never made the default.
FAKE_DEFAULT=/boot/vmlinuz-5.14.0-570.52.1.el9_6.x86_64
FAKE_EXTRA_BOOT="5.14.0-570.52.1.el9_6.x86_64+debug 5.14.0-570.52.1.el9_6.x86_64+rt"
run_case rhel 9.6 5.14.0-570.52.1.el9_6.x86_64 ""
expect "rhel variants only: NO_CHANGE" "$(field result)" "NO_CHANGE"
case "$LOGTEXT" in *set-default*) echo "FAIL: rhel variants only: grubby was asked to change it"; failures=$((failures + 1)) ;; *) echo "PASS: rhel variants only: grubby changes nothing" ;; esac
run_case rhel 9.6 5.14.0-570.52.1.el9_6.x86_64 5.14.0-570.60.1.el9_6.x86_64
expect "rhel variants and a newer plain kernel: the plain kernel" "$(field 'check:kernel installed')" "5.14.0-570.60.1.el9_6.x86_64"
FAKE_EXTRA_BOOT=''
FAKE_DEFAULT=''
# SUSE keeps the flavour it runs.
run_case sles 15.5 5.14.21-150500.33.29-azure 5.14.21-150500.33.72-azure
expect "sles azure: the package is kernel-azure" "$(field 'check:kernel package')" "kernel-azure"
expect_has "sles: zypper updates it" "$LOGTEXT" "zypper --non-interactive update kernel-azure"
run_case sles 15.5 5.14.21-150500.55.44-default 5.14.21-150500.55.121-default
expect "sles default: the package is kernel-default" "$(field 'check:kernel package')" "kernel-default"

# Debian: its cloud kernel when it runs one, and the general kernel otherwise.
run_case debian 12 6.1.0-25-cloud-amd64 6.1.0-28-cloud-amd64
expect "debian cloud: the package is linux-image-cloud-amd64" "$(field 'check:kernel package')" "linux-image-cloud-amd64"
run_case debian 12 6.1.0-25-amd64 6.1.0-28-amd64
expect "debian: the package is linux-image-amd64" "$(field 'check:kernel package')" "linux-image-amd64"

# Azure Linux: tdnf.
run_case azurelinux 3.0 6.6.47.1-1.azl3 6.6.57.1-2.azl3
expect_has "azure linux: tdnf upgrades kernel" "$LOGTEXT" "tdnf -y upgrade kernel"

# A distribution with no rule: BLOCKED, and no package manager is asked anything.
run_case fedora 40 6.8.5-301.fc40.x86_64 6.9.0-1.fc40.x86_64
expect_one_object "no rule"
expect "no rule: BLOCKED" "$(field result)" "BLOCKED"
expect "no rule: nothing was installed" "$LOGTEXT" ""
expect "no rule: the package manager did not run" "$(field 'check:package manager ran')" "no"

# RHUI-REFRESH-1 (2026-11-14, run Microsoft's own fix): on Red Hat the
# RHUI client package is updated first, from the Microsoft repository only,
# with Microsoft's command for an expired RHUI certificate - then the kernel.
# Lab 2026-11-14: RHEL 9.6 image 9.6.2025051906 had rhui-azure-rhel9-2.3-656,
# whose certificate had expired; after the update (2.3-916) dnf worked.
FAKE_RHUI_NAME=rhui-azure-rhel9
FAKE_RHUI_BEFORE=rhui-azure-rhel9-2.3-656.noarch
FAKE_RHUI_NEW=rhui-azure-rhel9-2.3-916.noarch
run_case rhel 9.6 5.14.0-570.12.1.el9_6.x86_64 5.14.0-570.60.1.el9_6.x86_64
expect_one_object "rhel rhui"
expect "rhel rhui: FIXED" "$(field result)" "FIXED"
expect "rhel rhui: the client was updated" "$(field 'status:rhui client')" "FIXED"
expect "rhel rhui: from and to" "$(field 'check:rhui client')" "The package manager updated rhui-azure-rhel9-2.3-656.noarch to rhui-azure-rhel9-2.3-916.noarch."
expect_has "rhel rhui: Microsoft's command, for the client package only" "$LOGTEXT" "dnf update -y --disablerepo=* --enablerepo=*microsoft-azure* rhui-azure-rhel9"
first=$(printf '%s\n' "$LOGTEXT" | head -n 1)
expect_has "rhel rhui: the client first, then the kernel" "$first" "microsoft-azure"
expect_has "rhel rhui: then the kernel" "$LOGTEXT" "dnf -y upgrade kernel"
expect "rhel rhui: the package manager ran" "$(field 'check:package manager ran')" "yes"

# A client with no newer package: said, and the kernel update goes on.
FAKE_RHUI_BEFORE=rhui-azure-rhel9-2.3-916.noarch
FAKE_RHUI_NEW=''
run_case rhel 9.6 5.14.0-570.12.1.el9_6.x86_64 5.14.0-570.60.1.el9_6.x86_64
expect "rhel rhui current: INFO" "$(field 'status:rhui client')" "INFO"
expect "rhel rhui current: said" "$(field 'check:rhui client')" "The Microsoft repository has no newer package than rhui-azure-rhel9-2.3-916.noarch."
expect "rhel rhui current: the kernel is updated" "$(field result)" "FIXED"

# The client update fails: BLOCKED, the package manager ran, the kernel is
# never asked for.
FAKE_RHUI_BEFORE=rhui-azure-rhel9-2.3-656.noarch
FAKE_RHUI_FAIL=1
run_case rhel 9.6 5.14.0-570.12.1.el9_6.x86_64 5.14.0-570.60.1.el9_6.x86_64
expect_one_object "rhel rhui fails"
expect "rhel rhui fails: BLOCKED" "$(field result)" "BLOCKED"
expect "rhel rhui fails: the package manager ran" "$(field 'check:package manager ran')" "yes"
expect "rhel rhui fails: the client is WARN" "$(field 'status:rhui client')" "WARN"
expect_has "rhel rhui fails: says why" "$(field error)" "did not update the RHUI client package rhui-azure-rhel9"
case "$LOGTEXT" in *"upgrade kernel"*|*"install kernel"*) echo "FAIL: rhel rhui fails: the kernel was asked for"; failures=$((failures + 1)) ;; *) echo "PASS: rhel rhui fails: the kernel is not asked for" ;; esac
FAKE_RHUI_FAIL=''

# No RHUI client (a machine registered with Red Hat itself): nothing from the
# Microsoft repository, and the kernel update goes on.
FAKE_RHUI_NAME=''
FAKE_RHUI_BEFORE=''
run_case rhel 9.6 5.14.0-570.12.1.el9_6.x86_64 5.14.0-570.60.1.el9_6.x86_64
expect "rhel no rhui: said" "$(field 'check:rhui client')" "No RHUI client package is installed."
case "$LOGTEXT" in *microsoft-azure*) echo "FAIL: rhel no rhui: the Microsoft repository was asked"; failures=$((failures + 1)) ;; *) echo "PASS: rhel no rhui: the Microsoft repository is not asked" ;; esac
expect "rhel no rhui: FIXED" "$(field result)" "FIXED"

# Only Red Hat: a rebuild has no RHUI, and is never asked.
FAKE_RHUI_NAME=rhui-azure-rhel9
FAKE_RHUI_BEFORE=rhui-azure-rhel9-2.3-656.noarch
FAKE_RHUI_NEW=rhui-azure-rhel9-2.3-916.noarch
run_case rocky 9.6 5.14.0-570.12.1.el9_6.x86_64 5.14.0-570.60.1.el9_6.x86_64
expect "rocky: no rhui check" "$(field 'check:rhui client')" "<none>"
case "$LOGTEXT" in *microsoft-azure*) echo "FAIL: rocky: the Microsoft repository was asked"; failures=$((failures + 1)) ;; *) echo "PASS: rocky: the Microsoft repository is not asked" ;; esac
FAKE_RHUI_NAME=''
FAKE_RHUI_BEFORE=''
FAKE_RHUI_NEW=''

# A rescue image is never read as the newest kernel.
root="$work/root-rescue"
mkdir -p "$root/etc" "$root/boot"
printf 'ID=rhel\nVERSION_ID="9.4"\n' > "$root/etc/os-release"
: > "$root/boot/vmlinuz-5.14.0-427.13.1.el9_4.x86_64"
: > "$root/boot/vmlinuz-0-rescue-0123456789abcdef"
: > "$work/pm.log"
OUT=$(PATH="$bin:$PATH" VMF_TEST_ROOT="$root" FAKE_KERNEL="5.14.0-427.13.1.el9_4.x86_64" FAKE_NEW="" FAKE_LOG="$work/pm.log" bash "$script" 2>/dev/null)
expect "a rescue image is not a newer kernel" "$(field result)" "NO_CHANGE"

if [ "$failures" -gt 0 ]; then echo "$failures failure(s)"; exit 1; fi
echo "all passed"
