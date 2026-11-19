#!/bin/bash
# sriov-unmanaged-check.sh - report the facts that show whether the network
# settings of this machine leave the SR-IOV interface of accelerated
# networking unmanaged (VmMigrationFactory, VF-UNMANAGED-CONFIG-1). Read-only.
#
# Microsoft, accelerated-networking-overview, "Configure drivers to be
# unmanaged": "Accelerated Networking requires configuring the SR-IOV drivers
# as unmanaged devices in your network settings. This requirement applies to
# the NVIDIA/Mellanox mlx4_core and mlx5_core drivers and to the MANA driver.
# Images using cloud-init version 23.2 or later automatically apply the
# correct network configuration ..." The page gives the udev rule
# 10-azure-unmanaged-sriov.rules (azure-vm-utils 0.6.0 or later) for
# NetworkManager and systemd-networkd, and 01-azure-unmanaged-sriov.network
# for systemd-networkd below 255.
#
# The engine runs this at Checking, before any safety copy and before any
# stop, on a Linux move that has accelerated networking on after it.
#
# FACTS ONLY. The ENGINE judges them (Get-VmfSriovUnmanagedVerdict):
#   networkManager, networkd, wicked - what `systemctl is-active` says
#   ifupdown         - yes when /etc/network/interfaces (or interfaces.d)
#                      has an iface stanza for an interface other than lo
#   systemdVersion   - the number `systemctl --version` gives, or unknown
#   cloudInitVersion - the version `cloud-init --version` gives, none when
#                      cloud-init is not installed, unknown when unreadable
#   cloudInitNetwork - disabled when network-config=disabled is on the kernel
#                      command line, or a cloud.cfg file holds
#                      "config: disabled" (cloud-init docs, "Disabling network
#                      configuration"); else enabled
#   sriovUdevLines   - each rule line, not a comment, of the udev rule files in
#                      force that names NM_UNMANAGED, ID_NET_MANAGED_BY or
#                      AZURE_UNMANAGED_SRIOV, as "<file>: <line>", joined by
#                      " ;; ". udev(7): a file in /etc replaces a file with the
#                      same name in /run or /usr/lib, and /run replaces /usr;
#                      a link to /dev/null turns a file off.
#   sriovNetworkFiles - each systemd .network file in force that holds
#                      Property=...AZURE_UNMANAGED_SRIOV=1 and Unmanaged=yes
#   nmUnmanagedDevices - each unmanaged-devices value of NetworkManager, as
#                      "<file>: <value>", joined by " ;; "
# Every list that is empty is "none".
# It reads; it starts, stops and writes nothing. The shebang stays: a payload
# with none runs under sh (CLAUDE.md).
#
# Emits ONE JSON object per schemas/guest-output.schema.json (vmf.guest/7).
# result: READY when the facts were read; BLOCKED when systemctl is missing.
# The engine reads BLOCKED as unknown, never as "set".
VMF_VERSION="1.0.0"
SCRIPT_NAME="sriov-unmanaged-check.sh"
# The tests point this at a folder of their own. On a machine it is empty: /.
ROOT="${VMF_ROOT:-}"
SEP=" ;; "

CHECKS="[]"
FACTS="{}"

# The text as a JSON string body, into the named variable. No subshell and
# no pipe: a line of a rule file can hold a quote, a backslash or a tab.
# Its own variable has a name no caller uses: printf -v sets the variable of
# that name in the nearest scope.
json_escape_to() {
    local vmf_je="$2"
    vmf_je="${vmf_je//\\/\\\\}"
    vmf_je="${vmf_je//\"/\\\"}"
    vmf_je="${vmf_je//$'\t'/ }"
    vmf_je="${vmf_je//[$'\001'-$'\037']/}"
    printf -v "$1" '%s' "$vmf_je"
}

add_check() {
    local n s d
    json_escape_to n "$1"; json_escape_to s "$2"; json_escape_to d "$3"
    if [ "$CHECKS" = "[]" ]; then
        CHECKS="[{\"name\":\"$n\",\"status\":\"$s\",\"detail\":\"$d\"}]"
    else
        CHECKS="${CHECKS%]},{\"name\":\"$n\",\"status\":\"$s\",\"detail\":\"$d\"}]"
    fi
}

add_fact() {
    local n v
    json_escape_to n "$1"; json_escape_to v "$2"
    if [ "$FACTS" = "{}" ]; then
        FACTS="{\"$n\":\"$v\"}"
    else
        FACTS="${FACTS%\}},\"$n\":\"$v\"}"
    fi
}

emit() {
    local os
    json_escape_to os "$OS_PRETTY"
    printf '{"schema":"vmf.guest/7","script":"%s","version":"%s","os":"%s","result":"%s","checks":%s,"facts":%s,"warnings":[]%s}\n' \
        "$SCRIPT_NAME" "$VMF_VERSION" "$os" "$1" "$CHECKS" "$FACTS" "$2"
}

# Adds one item to a list held in the named variable, joined by SEP.
append() {
    local cur
    cur="${!1}"
    if [ -z "$cur" ]; then printf -v "$1" '%s' "$2"; else printf -v "$1" '%s%s%s' "$cur" "$SEP" "$2"; fi
}

OS_PRETTY="unknown"
if [ -f "$ROOT/etc/os-release" ]; then
    # shellcheck disable=SC1091
    . "$ROOT/etc/os-release"
    OS_PRETTY="${PRETTY_NAME:-$ID}"
fi
add_fact "os" "Linux"

if ! command -v systemctl >/dev/null 2>&1; then
    add_check "systemctl" "INFO" "systemctl is not installed"
    emit "BLOCKED" ",\"error\":\"systemctl is not installed.\""
    exit 0
fi

# What systemd says, first line only, letters and dashes only.
unit_state() {
    local s
    s=$(systemctl is-active "$1" 2>/dev/null)
    s="${s%%$'\n'*}"
    s="${s//[^a-z-]/}"
    [ -n "$s" ] || s="unknown"
    printf '%s' "$s"
}

NM=$(unit_state NetworkManager)
ND=$(unit_state systemd-networkd)
WK=$(unit_state wicked)
add_fact "networkManager" "$NM"
add_fact "networkd" "$ND"
add_fact "wicked" "$WK"
add_check "NetworkManager service" "INFO" "$NM"
add_check "systemd-networkd service" "INFO" "$ND"
add_check "wicked service" "INFO" "$WK"

SDV=$(systemctl --version 2>/dev/null)
SDV="${SDV%%$'\n'*}"
SDV="${SDV#systemd }"
SDV="${SDV%% *}"
SDV="${SDV//[^0-9]/}"
[ -n "$SDV" ] || SDV="unknown"
add_fact "systemdVersion" "$SDV"
add_check "systemd version" "INFO" "$SDV"

# ifupdown: an iface stanza for an interface other than lo.
IFUP="no"
for f in "$ROOT/etc/network/interfaces" "$ROOT"/etc/network/interfaces.d/*; do
    [ -f "$f" ] || continue
    if grep -E '^[[:space:]]*iface[[:space:]]+' "$f" 2>/dev/null | awk '{print $2}' | grep -qvx 'lo'; then IFUP="yes"; fi
done
add_fact "ifupdown" "$IFUP"
add_check "ifupdown interfaces" "INFO" "$IFUP"

# cloud-init: its version, and whether its network configuration is off.
if command -v cloud-init >/dev/null 2>&1; then
    CIV=$(cloud-init --version 2>&1 | head -n 1 | grep -oE '[0-9]+[.][0-9]+([.][0-9]+)?' | head -n 1)
    [ -n "$CIV" ] || CIV="unknown"
else
    CIV="none"
fi
add_fact "cloudInitVersion" "$CIV"
add_check "cloud-init version" "INFO" "$CIV"
CIN="enabled"
if grep -q 'network-config=disabled' "$ROOT/proc/cmdline" 2>/dev/null; then CIN="disabled"; fi
for f in "$ROOT/etc/cloud/cloud.cfg" "$ROOT"/etc/cloud/cloud.cfg.d/*.cfg; do
    [ -f "$f" ] || continue
    if grep -E '^[^#]*config:[[:space:]]*disabled' "$f" >/dev/null 2>&1; then CIN="disabled"; fi
done
add_fact "cloudInitNetwork" "$CIN"
add_check "cloud-init network configuration" "INFO" "$CIN"

# The files in force in a set of folders, highest first: the first file of a
# name wins, and a link to /dev/null turns that name off. Prints full paths.
files_in_force() {
    local pattern="$1"; shift
    local seen="" d f base
    for d in "$@"; do
        for f in "$ROOT$d"/$pattern; do
            [ -e "$f" ] || [ -L "$f" ] || continue
            base=$(basename "$f")
            case "$seen" in *"/$base/"*) continue ;; esac
            seen="$seen/$base/"
            if [ -L "$f" ] && [ "$(readlink "$f")" = "/dev/null" ]; then continue; fi
            [ -f "$f" ] && printf '%s\n' "$f"
        done
    done
}

UDEV=""
while IFS= read -r f; do
    [ -n "$f" ] || continue
    shown="${f#"$ROOT"}"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        append UDEV "$shown: $line"
    done < <(grep -E 'NM_UNMANAGED|ID_NET_MANAGED_BY|AZURE_UNMANAGED_SRIOV' "$f" 2>/dev/null | grep -vE '^[[:space:]]*#')
done < <(files_in_force '*.rules' /etc/udev/rules.d /run/udev/rules.d /usr/local/lib/udev/rules.d /usr/lib/udev/rules.d /lib/udev/rules.d)
add_fact "sriovUdevLines" "${UDEV:-none}"
add_check "udev rules for the SR-IOV interface" "INFO" "${UDEV:-none}"

NETF=""
while IFS= read -r f; do
    [ -n "$f" ] || continue
    if grep -qE '^[[:space:]]*Property=.*AZURE_UNMANAGED_SRIOV=1' "$f" 2>/dev/null &&
       grep -qE '^[[:space:]]*Unmanaged=(yes|true|on|1)[[:space:]]*$' "$f" 2>/dev/null; then
        append NETF "${f#"$ROOT"}"
    fi
done < <(files_in_force '*.network' /etc/systemd/network /run/systemd/network /usr/local/lib/systemd/network /usr/lib/systemd/network /lib/systemd/network)
add_fact "sriovNetworkFiles" "${NETF:-none}"
add_check "systemd-networkd files for the SR-IOV interface" "INFO" "${NETF:-none}"

NMU=""
nm_files() {
    [ -f "$ROOT/etc/NetworkManager/NetworkManager.conf" ] && printf '%s\n' "$ROOT/etc/NetworkManager/NetworkManager.conf"
    files_in_force '*.conf' /etc/NetworkManager/conf.d /run/NetworkManager/conf.d /usr/lib/NetworkManager/conf.d
}
while IFS= read -r f; do
    [ -n "$f" ] || continue
    shown="${f#"$ROOT"}"
    while IFS= read -r value; do
        append NMU "$shown: $value"
    done < <(grep -E '^[[:space:]]*unmanaged-devices[[:space:]]*=' "$f" 2>/dev/null | sed -e 's/^[^=]*=[[:space:]]*//' -e 's/[[:space:]]*$//')
done < <(nm_files)
add_fact "nmUnmanagedDevices" "${NMU:-none}"
add_check "NetworkManager unmanaged-devices" "INFO" "${NMU:-none}"

emit "READY" ""

exit 0
