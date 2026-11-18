#!/bin/bash
# kernel-update.sh - update the Linux kernel with the distribution's own
# package manager (VmMigrationFactory, MANA-LINUX-KERNEL-1).
#
# Runs ONLY when a person chose "Update the kernel" for this machine and the
# engine found that its kernel has no MANA driver, after the first safety copy
# was taken. Microsoft: Linux MANA is in the kernel (5.15 and later upstream,
# and distribution backports), and "To update your VM's Linux kernel, check
# the documentation for your specific distribution."
#
# What it does: asks the package manager the machine already uses for the
# distribution's supported kernel package - Ubuntu linux-azure, Debian its
# cloud kernel, Red Hat and its rebuilds kernel (kernel-uek on Oracle UEK),
# SUSE the kernel flavour it runs, Azure Linux kernel. It uses only the
# repositories the machine already has, and never adds one or changes its
# settings. On Red Hat, its rebuilds and Oracle Linux it stays in the kernel
# family the machine runs (Oracle: UEK or the Red Hat Compatible Kernel), and
# makes the newest kernel of that family the default boot kernel with grubby
# (ORACLE-UEK-UPDATE-1, KERNEL-UPDATE-OL-RHCK-1).
#
# RHUI-REFRESH-1 (2026-11-14, the choice to run Microsoft's fix): on Red Hat with
# a Microsoft RHUI client package (pay-as-you-go), it first updates ONLY that
# package, from the Microsoft repository the machine already has, with
# Microsoft's command for an expired RHUI client certificate
# (troubleshoot-linux-rhui-certificate-issues, Solution 1):
#   yum update -y --disablerepo='*' --enablerepo='*microsoft-azure*'
# limited to the RHUI client packages that are installed (EUS, SAP and HA
# clients included), with dnf where the machine has it. The Microsoft
# repository needs no client certificate, so this works when the expired one
# stops every other repository (lab 2026-11-14: RHEL 9.6 9.6.2025051906,
# rhui-azure-rhel9-2.3-656 to 2.3-916, then dnf worked). The check
# 'rhui client' says what happened.
#
# Reports FACTS: the kernel that runs now, the package asked for, and the
# newest kernel installed afterwards. It does not judge MANA - the engine
# restarts the machine and reads it again with mana-check.sh.
#   FIXED      a kernel newer than the running one, of its family, is
#              installed (and on Red Hat and Oracle Linux, the default boot
#              kernel), and waits for a restart
#   NO_CHANGE  the newest installed kernel is the running one
#   BLOCKED    the package manager failed, or this distribution has no rule
#
# Emits ONE JSON object per schemas/guest-output.schema.json. RunCommand keeps
# only the last 4096 bytes of output, so the package manager's own output is
# cut to its last lines and only on a failure.
VMF_VERSION="1.3.0"
SCRIPT_NAME="kernel-update.sh"

CHECKS="[]"
FACTS="{}"

# Tests only (tests/linux/kernel-update.test.sh): a fake /etc and /boot. Empty
# on a real machine.
ROOT="${VMF_TEST_ROOT:-}"

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n\r\t' '   ' | tr -d '\000-\037'; }

add_check() {
    local n s d
    n=$(json_escape "$1"); s=$(json_escape "$2"); d=$(json_escape "$3")
    CHECKS=$(printf '%s' "$CHECKS" | sed 's/\]$//')
    if [ "$CHECKS" = "[" ]; then
        CHECKS="[{\"name\":\"$n\",\"status\":\"$s\",\"detail\":\"$d\"}]"
    else
        CHECKS="$CHECKS,{\"name\":\"$n\",\"status\":\"$s\",\"detail\":\"$d\"}]"
    fi
}

add_fact() {
    local n v
    n=$(json_escape "$1"); v=$(json_escape "$2")
    if [ "$FACTS" = "{}" ]; then
        FACTS="{\"$n\":\"$v\"}"
    else
        FACTS=$(printf '%s' "$FACTS" | sed 's/}$//')
        FACTS="$FACTS,\"$n\":\"$v\"}"
    fi
}

emit() {
    local result="$1" err="$2" os
    os=$(json_escape "$DISTRO_PRETTY")
    if [ -n "$err" ]; then
        printf '{"schema":"vmf.guest/2","script":"%s","version":"%s","os":"%s","result":"%s","checks":%s,"facts":%s,"warnings":[],"error":"%s"}\n' \
            "$SCRIPT_NAME" "$VMF_VERSION" "$os" "$result" "$CHECKS" "$FACTS" "$(json_escape "$err")"
    else
        printf '{"schema":"vmf.guest/2","script":"%s","version":"%s","os":"%s","result":"%s","checks":%s,"facts":%s,"warnings":[]}\n' \
            "$SCRIPT_NAME" "$VMF_VERSION" "$os" "$result" "$CHECKS" "$FACTS"
    fi
}

DISTRO_PRETTY="unknown"
DISTRO_ID="unknown"
DISTRO_VERSION_ID="unknown"
if [ -f "$ROOT/etc/os-release" ]; then
    # shellcheck disable=SC1090,SC1091
    . "$ROOT/etc/os-release"
    DISTRO_PRETTY="${PRETTY_NAME:-${ID:-unknown}}"
    DISTRO_ID="${ID:-unknown}"
    DISTRO_VERSION_ID="${VERSION_ID:-unknown}"
fi

KVER=$(uname -r)
add_fact "os" "Linux"
add_fact "kernelVersion" "$KVER"
add_fact "distroId" "$DISTRO_ID"
add_fact "distroVersion" "$DISTRO_VERSION_ID"
add_check "kernel before" "INFO" "$KVER"

# The newest kernel image installed, by version, of the kernel family the
# machine runs. A rescue image is not a kernel the machine boots by default.
# ORACLE-UEK-UPDATE-1: on a UEK kernel, only UEK kernels count.
# KERNEL-UPDATE-OL-RHCK-1 (final lab, 2026-11-16): on the Red Hat Compatible
# Kernel, a UEK kernel never counts. Oracle Linux 9.7 started on RHCK
# 5.14.0-570.51.1.0.1.el9_6 with the image's UEK kernel 6.12 still in /boot:
# 6.12 sorts above every 5.14 kernel, so the script said it had installed the
# UEK kernel, and the machine restarted on RHCK.
same_family() {
    case "$PKG" in
        kernel-uek) grep -i 'uek' ;;
        kernel) grep -v -i 'uek' ;;
        *) cat ;;
    esac
}
# Review, 2026-11-16: on Red Hat, its rebuilds and Oracle Linux a variant
# kernel of a release (+debug, +rt, +64k after the architecture) sorts above
# the plain kernel, so a debug kernel in /boot read as a newer kernel and was
# made the default. A variant counts only when the running kernel is the same
# variant; a plain kernel counts only when the running kernel is plain.
KVARIANT=""
case "$KVER" in *+*) KVARIANT="+${KVER#*+}" ;; esac
same_variant() {
    if [ "$PM" != "dnf" ] && [ "$PM" != "yum" ]; then cat; return; fi
    local k v
    while IFS= read -r k; do
        case "$k" in *+*) v="+${k#*+}" ;; *) v="" ;; esac
        [ "$v" = "$KVARIANT" ] && printf '%s\n' "$k"
    done
    return 0
}
newest_kernel() {
    find "$ROOT/boot" -maxdepth 1 -name 'vmlinuz-*' 2>/dev/null |
        sed 's#.*/vmlinuz-##' | grep -v -i 'rescue' | same_family | same_variant |
        sort -V | tail -n 1
}

# The distribution's own package manager and its supported kernel package -
# in the kernel flavour the machine runs, never another. A flavour with no rule
# here (Ubuntu -azure-fips, -generic) is BLOCKED before anything is installed:
# installing another flavour would move the machine onto a kernel nobody chose.
PM=""
PKG=""
NORULE=""
case "$DISTRO_ID" in
    ubuntu)
        PM="apt-get"
        case "$KVER" in
            *-azure)
                # The Azure metapackage the machine already has (linux-azure,
                # or a linux-azure-lts-<release> it was pinned to), else linux-azure.
                PKG=$(dpkg-query -W -f='${binary:Package} ${Status}\n' 'linux-azure*' 2>/dev/null |
                    awk '$NF == "installed" && ($1 == "linux-azure" || $1 ~ /^linux-azure-lts-/) { print $1; exit }')
                [ -n "$PKG" ] || PKG="linux-azure" ;;
            *) NORULE="the kernel flavour of $KVER" ;;
        esac ;;
    debian)
        PM="apt-get"
        ARCH=$(dpkg --print-architecture 2>/dev/null)
        [ -n "$ARCH" ] || ARCH="amd64"
        if printf '%s' "$KVER" | grep -q -- '-cloud-'; then PKG="linux-image-cloud-$ARCH"; else PKG="linux-image-$ARCH"; fi ;;
    rhel|almalinux|rocky|centos|ol)
        if command -v dnf >/dev/null 2>&1; then PM="dnf"; else PM="yum"; fi
        if printf '%s' "$KVER" | grep -qi 'uek'; then PKG="kernel-uek"; else PKG="kernel"; fi ;;
    sles|sles_sap|opensuse-leap)
        PM="zypper"
        if printf '%s' "$KVER" | grep -q -- '-azure$'; then PKG="kernel-azure"; else PKG="kernel-default"; fi ;;
    azurelinux|mariner)
        PM="tdnf"; PKG="kernel" ;;
esac

# Until the package manager runs, nothing on the machine has changed, and the
# engine stops the move without putting the machine back.
add_check "package manager ran" "INFO" "no"
if [ -z "$PM" ] || [ -n "$NORULE" ]; then
    what="${NORULE:-the distribution $DISTRO_ID}"
    add_check "kernel package" "WARN" "no rule for $what"
    emit "BLOCKED" "This script has no kernel package rule for $what. Update the kernel with the documentation of the distribution."
    exit 0
fi
add_check "package manager" "INFO" "$PM"
add_check "kernel package" "INFO" "$PKG"

if ! command -v "$PM" >/dev/null 2>&1; then
    emit "BLOCKED" "The package manager $PM is not on this machine."
    exit 0
fi

LOG=$(mktemp 2>/dev/null || echo "/tmp/vmf-kernel-update.$$")
trap 'rm -f "$LOG"' EXIT

run_pm() {
    case "$PM" in
        apt-get)
            export DEBIAN_FRONTEND=noninteractive
            apt-get -o DPkg::Lock::Timeout=120 update >>"$LOG" 2>&1 &&
                apt-get -y -o DPkg::Lock::Timeout=120 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
                    install "$PKG" >>"$LOG" 2>&1 ;;
        dnf)
            # An installed kernel package is upgraded to the newest one the
            # configured repositories carry; a missing one is installed.
            if rpm -q "$PKG" >/dev/null 2>&1; then dnf -y upgrade "$PKG" >>"$LOG" 2>&1; else dnf -y install "$PKG" >>"$LOG" 2>&1; fi ;;
        yum)
            if rpm -q "$PKG" >/dev/null 2>&1; then yum -y update "$PKG" >>"$LOG" 2>&1; else yum -y install "$PKG" >>"$LOG" 2>&1; fi ;;
        zypper)
            if rpm -q "$PKG" >/dev/null 2>&1; then zypper --non-interactive update "$PKG" >>"$LOG" 2>&1; else zypper --non-interactive install "$PKG" >>"$LOG" 2>&1; fi ;;
        tdnf)
            if rpm -q "$PKG" >/dev/null 2>&1; then tdnf -y upgrade "$PKG" >>"$LOG" 2>&1; else tdnf -y install "$PKG" >>"$LOG" 2>&1; fi ;;
    esac
}

CHECKS=$(printf '%s' "$CHECKS" | sed 's/"name":"package manager ran","status":"INFO","detail":"no"/"name":"package manager ran","status":"INFO","detail":"yes"/')

# RHUI-REFRESH-1: the RHUI client first, on Red Hat only (RHUI is for Red Hat
# pay-as-you-go images). A failure stops here: the package manager ran, so the
# engine puts the machine back.
if [ "$DISTRO_ID" = "rhel" ] && { [ "$PM" = "dnf" ] || [ "$PM" = "yum" ]; }; then
    RHUI_PKGS=$(rpm -qa --qf '%{NAME}\n' 'rhui-azure*' 2>/dev/null | sort -u | tr '\n' ' ' | sed 's/ *$//')
    if [ -z "$RHUI_PKGS" ]; then
        add_check "rhui client" "INFO" "No RHUI client package is installed."
    else
        # shellcheck disable=SC2086
        RHUI_BEFORE=$(rpm -q $RHUI_PKGS 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')
        # shellcheck disable=SC2086
        if "$PM" update -y --disablerepo='*' --enablerepo='*microsoft-azure*' $RHUI_PKGS >>"$LOG" 2>&1; then
            # shellcheck disable=SC2086
            RHUI_AFTER=$(rpm -q $RHUI_PKGS 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')
            if [ -n "$RHUI_AFTER" ] && [ "$RHUI_AFTER" != "$RHUI_BEFORE" ]; then
                add_check "rhui client" "FIXED" "The package manager updated $RHUI_BEFORE to $RHUI_AFTER."
            else
                add_check "rhui client" "INFO" "The Microsoft repository has no newer package than ${RHUI_BEFORE:-$RHUI_PKGS}."
            fi
        else
            RC=$?
            TAIL=$(tail -c 400 "$LOG" 2>/dev/null)
            add_check "rhui client" "WARN" "The update of $RHUI_PKGS stopped with exit code $RC."
            emit "BLOCKED" "$PM did not update the RHUI client package $RHUI_PKGS from the Microsoft repository. It stopped with exit code $RC. The last lines of the log: $TAIL"
            exit 0
        fi
    fi
fi

run_pm
RC=$?
# zypper reports some successes with a code of 100 and up: 102 a reboot is
# needed (a kernel asks for one), 103 zypper itself was updated, 106 a
# repository was skipped. Whether a newer kernel arrived is read from /boot.
if [ "$PM" = "zypper" ]; then
    case "$RC" in 100|101|102|103|106) RC=0 ;; esac
fi
if [ "$RC" -ne 0 ]; then
    # Its own words, cut short: RunCommand keeps only the last 4096 bytes, and
    # stderr is the part that says why.
    TAIL=$(tail -c 400 "$LOG" 2>/dev/null)
    add_check "package manager output" "WARN" "exit code $RC"
    emit "BLOCKED" "$PM could not install $PKG (exit code $RC): $TAIL"
    exit 0
fi

NEWEST=$(newest_kernel)
if [ -z "$NEWEST" ]; then
    emit "BLOCKED" "No kernel image was found in /boot after the update."
    exit 0
fi
add_check "kernel installed" "INFO" "$NEWEST"

if [ "$NEWEST" = "$KVER" ]; then
    emit "NO_CHANGE" ""
    exit 0
fi
LATER=$(printf '%s\n%s\n' "$KVER" "$NEWEST" | sort -V | tail -n 1)
if [ "$LATER" = "$NEWEST" ]; then
    # ORACLE-UEK-UPDATE-1: on Oracle UEK, the newest UEK kernel is made the
    # default boot kernel when it is not. A machine set to start UEK R7 keeps
    # that default after kernel-uek from the UEK R8 repository is installed
    # (or was already there), and would start on UEK R7 again. grubby is the
    # Oracle Linux tool for the default kernel.
    # KERNEL-UPDATE-OL-RHCK-1: the same for the Red Hat Compatible Kernel,
    # and on Red Hat and its rebuilds, which use grubby too: a machine set
    # with grubby to start one kernel keeps that default after a newer kernel
    # is installed. The default is read back after the change: a default that
    # is not the new kernel is BLOCKED, after the package manager ran, so the
    # engine puts the machine back. The check 'default boot kernel' holds
    # only the kernel version, and the engine compares the kernel the machine
    # starts on with it.
    if [ "$PM" = "dnf" ] || [ "$PM" = "yum" ]; then
        if command -v grubby >/dev/null 2>&1; then
            WANT="/boot/vmlinuz-$NEWEST"
            CURRENT=$(grubby --default-kernel 2>/dev/null | head -n 1)
            if [ "$CURRENT" = "$WANT" ]; then
                add_check "default boot kernel" "INFO" "$NEWEST"
            elif grubby --set-default "$WANT" >>"$LOG" 2>&1; then
                READBACK=$(grubby --default-kernel 2>/dev/null | head -n 1)
                add_check "default boot kernel before" "INFO" "${CURRENT:-not read}"
                if [ "$READBACK" = "$WANT" ]; then
                    add_check "default boot kernel" "FIXED" "$NEWEST"
                else
                    add_check "default boot kernel" "WARN" "grubby did not make $NEWEST the default"
                    emit "BLOCKED" "grubby did not make $NEWEST the default boot kernel. The default boot kernel is ${READBACK:-not read}."
                    exit 0
                fi
            else
                TAIL=$(tail -c 400 "$LOG" 2>/dev/null)
                add_check "default boot kernel" "WARN" "grubby could not set $NEWEST"
                emit "BLOCKED" "grubby could not make $NEWEST the default boot kernel: $TAIL"
                exit 0
            fi
        else
            add_check "default boot kernel" "WARN" "grubby is not on this machine"
        fi
    fi
    emit "FIXED" ""
else
    emit "NO_CHANGE" ""
fi
exit 0
