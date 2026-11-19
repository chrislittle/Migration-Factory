#!/bin/bash
# mana-check.sh - Linux MANA driver readiness (VmMigrationFactory). Read-only, advisory.
# Emits ONE JSON object per schemas/guest-output.schema.json. result: READY | NEEDS_PREP
VMF_VERSION="1.4.0"
SCRIPT_NAME="mana-check.sh"

CHECKS="[]"
FACTS="{}"
FOUND=0
IMDS_URI="http://169.254.169.254/metadata/instance/compute?api-version=2023-07-01"

# Tests only (tests/linux/mana-check.test.sh): a fake /etc. Empty on a real
# machine.
ROOT="${VMF_TEST_ROOT:-}"
# The network interfaces (AN-TRAFFIC-VERIFY-1), under the same test root.
NET_DIR="$ROOT/sys/class/net"

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
}

# GUEST-2: facts are DECLARED fields in the contract now, not checks with a
# naming convention. They used to travel as "fact:<name>" checks because there
# was nowhere to put them - so nothing declared which facts existed, and a guest
# could omit one with nothing noticing. That is how every Windows machine came
# to report an UNKNOWN driver state.
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

DISTRO_PRETTY="unknown"
DISTRO_ID="unknown"
DISTRO_VERSION_ID="unknown"
if [ -f "$ROOT/etc/os-release" ]; then
    # shellcheck disable=SC1090,SC1091
    . "$ROOT/etc/os-release"
    DISTRO_PRETTY="${PRETTY_NAME:-$ID}"
    DISTRO_ID="${ID:-unknown}"
    DISTRO_VERSION_ID="${VERSION_ID:-unknown}"
fi

KVER=$(uname -r)
add_check "kernel" "INFO" "$KVER"
# Which OS this is, as a fact rather than something the engine infers from a
# caption string. Its absence on the Windows side is what let the UPST-2 drill
# find every Windows machine being judged against the Linux MANA kernel floor.
add_fact "os" "Linux"
add_fact "kernelVersion" "$KVER"
add_fact "distroId" "$DISTRO_ID"
add_fact "distroVersion" "$DISTRO_VERSION_ID"

# ORACLE-UEK-UPDATE-1: on Oracle Linux, the enabled repositories whose id has
# UEK in it (ol9_UEKR7, ol9_UEKR8), as a fact. Oracle gives UEK R8 in its own
# repository, and the engine runs Update the kernel for a UEK kernel below UEK
# R8 only when that repository is enabled - the product never changes one.
# Read from the repository files, the files dnf and dnf config-manager use,
# so nothing reaches the network. A section with no enabled line is enabled,
# as dnf reads it. 'none' when no such repository is enabled; 'unknown' when
# the folder is not there.
uek_repositories() {
    local dir="$ROOT/etc/yum.repos.d" list
    if [ ! -d "$dir" ]; then echo "unknown"; return; fi
    list=$(for repo in "$dir"/*.repo; do [ -f "$repo" ] && { cat "$repo"; echo; }; done | tr -d '\r' | awk '
        function flush() { if (id != "" && on && toupper(id) ~ /UEK/) print id }
        /^[[:space:]]*\[.*\][[:space:]]*$/ {
            flush(); id = $0; sub(/^[[:space:]]*\[[[:space:]]*/, "", id); sub(/[[:space:]]*\][[:space:]]*$/, "", id); on = 1; next }
        /^[[:space:]]*enabled[[:space:]]*=/ {
            v = $0; sub(/^[^=]*=/, "", v); gsub(/[[:space:]]/, "", v); v = tolower(v)
            on = (v == "1" || v == "yes" || v == "true" || v == "on"); next }
        END { flush() }' | sort -u | tr '\n' ' ' | sed 's/ *$//')
    echo "${list:-none}"
}
if [ "$DISTRO_ID" = "ol" ]; then
    UEK_REPOS=$(uek_repositories)
    add_fact "uekRepositories" "$UEK_REPOS"
    add_check "uek repositories enabled" "INFO" "$UEK_REPOS"
fi

# KERNEL-OFFER-EDGES-1: on Red Hat and its rebuilds, the minor release dnf is
# held to, as a fact. Microsoft's RHUI certificate page: the EUS, SAP and HA
# RHUI clients lock the releasever variable to one minor release, so an update
# stays on it. Read from /etc/dnf/vars/releasever, else
# /etc/yum/vars/releasever, first line, trimmed; 'none' when neither is there.
case "$DISTRO_ID" in
    rhel|almalinux|rocky|centos|ol)
        RELEASEVER="none"
        for file in "$ROOT/etc/dnf/vars/releasever" "$ROOT/etc/yum/vars/releasever"; do
            if [ -f "$file" ]; then
                RELEASEVER=$(head -n 1 "$file" | tr -d '\r' | tr -d '[:space:]')
                [ -n "$RELEASEVER" ] || RELEASEVER="none"
                break
            fi
        done
        add_fact "releaseverLock" "$RELEASEVER"
        add_check "releasever" "INFO" "$RELEASEVER" ;;
    *) ;;  # no releasever lock on any other distribution: no fact (IMAGE-SCRIPT-MATCH-1)
esac

# KERNEL-FLOOR-UPLOAD-1: on Ubuntu and Debian, the version of the package of
# the running kernel, as a fact. Ubuntu's kernel version is base-ABI.upload
# and uname -r leaves out the upload number
# (https://wiki.ubuntu.com/Kernel/FAQ/GeneralVersionMeaning), while
# Microsoft's minimum has it (5.15.0-1096.105). 'unknown' when dpkg-query
# gives none.
case "$DISTRO_ID" in
    ubuntu|debian)
        KPKG=$(dpkg-query -W -f='${Version}' "linux-image-$KVER" 2>/dev/null)
        [ -n "$KPKG" ] || KPKG="unknown"
        add_fact "kernelPackageVersion" "$KPKG"
        add_check "kernel package version" "INFO" "$KPKG" ;;
    *) ;;  # no Debian package version elsewhere: no fact (IMAGE-SCRIPT-MATCH-1)
esac

# Kernel floor: MANA ethernet upstream in 5.15+, advanced features 6.2+
KMAJ=$(echo "$KVER" | cut -d. -f1)
KMIN=$(echo "$KVER" | cut -d. -f2)
if [ "$KMAJ" -gt 5 ] || { [ "$KMAJ" -eq 5 ] && [ "$KMIN" -ge 15 ]; }; then
    add_check "kernel floor (5.15+)" "PASS" "$KVER"
else
    add_check "kernel floor (5.15+)" "WARN" "$KVER is below 5.15 - MANA ethernet not upstream"
fi

if lsmod 2>/dev/null | grep -qi '^mana'; then
    add_check "mana module loaded" "PASS" "$(lsmod | grep -i '^mana' | head -1 | awk '{print $1}')"
    FOUND=1
else
    add_check "mana module loaded" "INFO" "not currently loaded (expected before migration)"
fi

MANA_DRIVER_VERSION=""
# MANA-BUILTIN-READ-1: Microsoft's own check also reads a driver built into the
# running kernel (accelerated-networking-mana-linux, "Kernel version check":
# grep /mana*.ko /lib/modules/$(uname -r)/modules.builtin). An older modinfo
# does not report a built-in driver, so the list is read when modinfo finds
# nothing. A built-in driver counts as present.
MANA_BUILTIN=""
if [ -f "$ROOT/lib/modules/$KVER/modules.builtin" ]; then
    MANA_BUILTIN=$(grep -E '(^|/)mana\.ko$' "$ROOT/lib/modules/$KVER/modules.builtin" 2>/dev/null | tr -d '\r' | head -n 1)
fi
if modinfo mana >/dev/null 2>&1; then
    add_check "mana module available" "PASS" "$(modinfo -F filename mana 2>/dev/null)"
    MANA_DRIVER_VERSION=$(modinfo -F version mana 2>/dev/null)
    FOUND=1
elif [ -n "$MANA_BUILTIN" ]; then
    add_check "mana module available" "PASS" "The MANA driver is built into the kernel. modules.builtin lists $MANA_BUILTIN."
    FOUND=1
else
    add_check "mana module available" "WARN" "modinfo mana failed - driver not present in this kernel"
fi

SRIOV_FOUND=0
# AN-TRAFFIC-VERIFY-1: every virtual function interface, and how many are down.
VF_IFACES=0
VF_DOWN=0
VF_DOWN_NAMES=""
for iface in "$NET_DIR"/*; do
    name=$(basename "$iface")
    [ "$name" = "lo" ] && continue
    drv=$(ethtool -i "$name" 2>/dev/null | awk '/^driver:/ {print $2}')
    if echo "$drv" | grep -qiE '^mana|^mlx[45]'; then
        VF_IFACES=$((VF_IFACES + 1))
        if [ "$(cat "$iface/operstate" 2>/dev/null)" = "down" ]; then
            VF_DOWN=$((VF_DOWN + 1))
            VF_DOWN_NAMES="$VF_DOWN_NAMES $name"
        fi
    fi
    if echo "$drv" | grep -qi mana; then
        add_check "interface $name" "PASS" "using MANA driver"
        FOUND=1
    fi
    # SR-IOV VF fabric (mlx4/mlx5): some v6 clusters accelerate via a Mellanox
    # VF instead of MANA (observed on E2ads_v6/AMD, REH-2). Fact, not judgment.
    if echo "$drv" | grep -qiE '^mlx[45]'; then
        state=$(cat "$iface/operstate" 2>/dev/null)
        if [ "$state" = "up" ]; then
            add_check "sriov vf bound $name" "PASS" "using $drv (SR-IOV VF, up)"
            SRIOV_FOUND=1
        fi
    fi
done
[ "$SRIOV_FOUND" -eq 0 ] && add_check "sriov vf bound" "INFO" "no SR-IOV VF interface up"

# DRIVER-1: which fabric is actually carrying this machine, as a fact.
FABRIC="none"
MLX_DRIVER=""
for iface in "$NET_DIR"/*; do
    name=$(basename "$iface")
    [ "$name" = "lo" ] && continue
    drv=$(ethtool -i "$name" 2>/dev/null | awk '/^driver:/ {print $2}')
    if echo "$drv" | grep -qi mana; then
        FABRIC="mana"
        break
    fi
    if echo "$drv" | grep -qiE '^mlx[45]'; then
        FABRIC="mlx5"
        MLX_DRIVER=$(ethtool -i "$name" 2>/dev/null | awk '/^version:/ {print $2}')
    fi
done
add_fact "fabric" "$FABRIC"
if [ "$FABRIC" = "mana" ]; then
    add_fact "driverVersion" "${MANA_DRIVER_VERSION:-unknown}"
else
    add_fact "driverVersion" "${MLX_DRIVER:-unknown}"
fi

# DRIVER-1: Microsoft's own verification that the accelerated path is really
# in use - "if the values associated with the VF are 0 or do not increment,
# you are not using the virtual function". A present driver proves nothing.
# AN-TRAFFIC-VERIFY-1: the counters that decide are read AFTER a few Instance
# Metadata Service requests, so the machine sent traffic just before. The
# reading before them is kept in the check, as evidence of the increment.
# Facts only: the ENGINE judges vfTraffic against the plan.

# One line per interface with virtual function counters: name rx tx. The
# synthetic interface (hv_netvsc) reports them; "cpu0_vf_rx_packets" and the
# like are per processor, so only the exact total counts.
read_vf() {
    for iface in "$NET_DIR"/*; do
        name=$(basename "$iface")
        [ "$name" = "lo" ] && continue
        stats=$(ethtool -S "$name" 2>/dev/null)
        vfrx=$(printf '%s\n' "$stats" | awk '$1 == "vf_rx_packets:" {print $2; exit}')
        [ -n "$vfrx" ] || continue
        vftx=$(printf '%s\n' "$stats" | awk '$1 == "vf_tx_packets:" {print $2; exit}')
        echo "$name $vfrx ${vftx:-0}"
    done
}

# Three requests, 0.3 seconds apart: inside the service's limit of 5 requests
# a second. Header Metadata: true and no proxy (VERIFY-FP-1). An answer is not
# needed; a machine that never reaches the service still sent the requests.
send_traffic() {
    local _
    for _ in 1 2 3; do
        if command -v curl >/dev/null 2>&1; then
            curl -s --noproxy '*' -H 'Metadata: true' --max-time 2 "$IMDS_URI" >/dev/null 2>&1
        elif command -v wget >/dev/null 2>&1; then
            wget -q -O /dev/null --no-proxy --header='Metadata: true' --timeout=2 "$IMDS_URI" >/dev/null 2>&1
        fi
        sleep 0.3 2>/dev/null || sleep 1
    done
}

VF_BEFORE=$(read_vf)
send_traffic
VF_AFTER=$(read_vf)

VF_TRAFFIC="unknown"
if [ -z "$VF_AFTER" ]; then
    add_check "vf carrying traffic" "INFO" "no interface reports vf_rx_packets"
elif [ "$VF_IFACES" -gt 0 ] && [ "$VF_DOWN" -eq "$VF_IFACES" ]; then
    add_check "vf carrying traffic" "WARN" "every virtual function interface is down:$VF_DOWN_NAMES"
    VF_TRAFFIC="no"
else
    VF_TRAFFIC="no"
    SHOWN=""
    while read -r name vfrx vftx; do
        [ -n "$name" ] || continue
        before=$(printf '%s\n' "$VF_BEFORE" | awk -v n="$name" '$1 == n {print "vf_rx_packets=" $2 " vf_tx_packets=" $3; exit}')
        line="vf_rx_packets=$vfrx vf_tx_packets=$vftx after the metadata requests (before them: ${before:-not read})"
        if [ "$vfrx" -gt 0 ] 2>/dev/null || [ "$vftx" -gt 0 ] 2>/dev/null; then
            if [ "$VF_TRAFFIC" != "yes" ]; then
                add_check "vf carrying traffic ($name)" "PASS" "$line"
                VF_TRAFFIC="yes"
            fi
        elif [ -z "$SHOWN" ]; then
            SHOWN="$name|$line"
        fi
    done <<EOF
$VF_AFTER
EOF
    if [ "$VF_TRAFFIC" = "no" ]; then
        add_check "vf carrying traffic (${SHOWN%%|*})" "WARN" "${SHOWN#*|} - the accelerated path is not carrying traffic"
    fi
fi
add_fact "vfTraffic" "$VF_TRAFFIC"

if [ "$FOUND" -eq 1 ]; then emit_result="READY"; else emit_result="NEEDS_PREP"; fi
os=$(json_escape "$DISTRO_PRETTY")
printf '{"schema":"vmf.guest/6","script":"%s","version":"%s","os":"%s","result":"%s","checks":%s,"facts":%s,"warnings":[]}\n' \
    "$SCRIPT_NAME" "$VMF_VERSION" "$os" "$emit_result" "$CHECKS" "$FACTS"
exit 0
