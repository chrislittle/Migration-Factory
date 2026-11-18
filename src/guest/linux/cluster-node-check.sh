#!/bin/bash
# cluster-node-check.sh - report the facts that show whether this machine is
# a node of a cluster (VmMigrationFactory, CLUSTER-DETECT-1). Read-only.
#
# The engine runs this at Checking, before any safety copy and before any
# stop. A Pacemaker cluster, or a SQL Server availability group that it
# manages, has no record in Azure, so the machine looks like a machine that
# is alone - and a stop of the primary replica causes a failover or an outage.
#
# FACTS ONLY. The ENGINE judges them (Get-VmfClusterNodeVerdict):
#   pacemaker - what `systemctl is-active pacemaker` says
#   corosync  - what `systemctl is-active corosync` says
#   sqlHadr   - hadr.hadrenabled is 1 in /var/opt/mssql/mssql.conf: yes or no.
#               It names the kind of cluster, and never decides.
# And one check that is not about clusters: 'lvm devices file'
# (VOLUMES-ONLINE-1), read here because Checking runs only this script.
# It reads; it starts, stops and writes nothing, and needs no SQL Server
# login. The shebang stays: a payload with none runs under sh (CLAUDE.md).
#
# Emits ONE JSON object per schemas/guest-output.schema.json (vmf.guest/4).
# result: READY when every fact was read; BLOCKED when it could not read one.
# The engine reads BLOCKED as unknown, never as "not a cluster node".
VMF_VERSION="1.1.0"
SCRIPT_NAME="cluster-node-check.sh"
# The tests point this at a file of their own. On a machine it is the file
# SQL Server on Linux reads.
MSSQL_CONF="${VMF_MSSQL_CONF:-/var/opt/mssql/mssql.conf}"

CHECKS="[]"
FACTS="{}"

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n\r'; }

add_check() {
    local n s d
    n=$(json_escape "$1"); s=$(json_escape "$2"); d=$(json_escape "$3")
    if [ "$CHECKS" = "[]" ]; then
        CHECKS="[{\"name\":\"$n\",\"status\":\"$s\",\"detail\":\"$d\"}]"
    else
        CHECKS="${CHECKS%]},{\"name\":\"$n\",\"status\":\"$s\",\"detail\":\"$d\"}]"
    fi
}

add_fact() {
    local n v
    n=$(json_escape "$1"); v=$(json_escape "$2")
    if [ "$FACTS" = "{}" ]; then
        FACTS="{\"$n\":\"$v\"}"
    else
        FACTS="${FACTS%\}},\"$n\":\"$v\"}"
    fi
}

emit() {
    printf '{"schema":"vmf.guest/4","script":"%s","version":"%s","os":"%s","result":"%s","checks":%s,"facts":%s,"warnings":[]%s}\n' \
        "$SCRIPT_NAME" "$VMF_VERSION" "$(json_escape "$OS_PRETTY")" "$1" "$CHECKS" "$FACTS" "$2"
}

OS_PRETTY="unknown"
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_PRETTY="${PRETTY_NAME:-$ID}"
fi
add_fact "os" "Linux"

if ! command -v systemctl >/dev/null 2>&1; then
    add_check "systemctl" "INFO" "systemctl is not installed"
    emit "BLOCKED" ",\"error\":\"no systemctl to read the pacemaker and corosync services\""
    exit 0
fi

# What systemd says, first line only, letters and dashes only. A unit that is
# not installed reads inactive (or unknown on an older systemd).
unit_state() {
    local s
    s=$(systemctl is-active "$1" 2>/dev/null | head -n 1 | tr -cd 'a-z-')
    [ -n "$s" ] || s="unknown"
    printf '%s' "$s"
}

PM=$(unit_state pacemaker)
CS=$(unit_state corosync)
add_fact "pacemaker" "$PM"
add_fact "corosync" "$CS"
add_check "pacemaker service" "INFO" "$PM"
add_check "corosync service" "INFO" "$CS"

# mssql.conf is an ini file: hadrenabled under the [hadr] section.
SQL="no"
if [ -e "$MSSQL_CONF" ]; then
    if [ ! -r "$MSSQL_CONF" ]; then
        add_check "mssql.conf" "INFO" "cannot read $MSSQL_CONF"
        emit "BLOCKED" ",\"error\":\"cannot read $(json_escape "$MSSQL_CONF")\""
        exit 0
    fi
    V=$(awk -F= '
        /^[[:space:]]*\[/ { s = tolower($0); gsub(/[^a-z]/, "", s); next }
        { k = tolower($1); gsub(/[[:space:]]/, "", k)
          if (s == "hadr" && k == "hadrenabled") { v = $2; gsub(/[[:space:]]/, "", v); print v } }
    ' "$MSSQL_CONF" 2>/dev/null | tail -n 1)
    [ "$V" = "1" ] && SQL="yes"
    add_check "mssql.conf hadr.hadrenabled" "INFO" "${V:-not set}"
else
    add_check "mssql.conf hadr.hadrenabled" "INFO" "no $MSSQL_CONF"
fi
add_fact "sqlHadr" "$SQL"

# VOLUMES-ONLINE-1: and, while Checking runs here, whether LVM uses a devices
# file - a FACT the engine records. It never decides anything, and never makes
# this check BLOCKED.
# >>> vmf-lvm-facts
# VOLUMES-ONLINE-1: the same text in every guest script that has it - a test
# holds every copy equal. lvmdevices(8): with use_devicesfile=1 and the file
# present, LVM uses only the devices the file lists, each by a device ID
# (sys_wwid first). A disk made from a snapshot, and the same disk on NVMe,
# has another device ID, so LVM does not use its physical volume: pvs shows
# nothing, and fstab cannot mount a volume of that volume group.
vmf_lvm_devfile() {
    if [ -n "${VMF_LVM_DEVICES_FILE:-}" ]; then printf '%s' "$VMF_LVM_DEVICES_FILE"; return 0; fi
    local name
    name=$(lvmconfig --typeconfig full --valuesonly devices/devicesfile 2>/dev/null | tr -d '" ')
    [ -n "$name" ] || name="system.devices"
    printf '/etc/lvm/devices/%s' "$name"
}
# yes, no, or nolvm.
vmf_lvm_inuse() {
    command -v pvs >/dev/null 2>&1 || { echo nolvm; return 0; }
    local v
    v=$(lvmconfig --typeconfig full --valuesonly devices/use_devicesfile 2>/dev/null | tr -d '" ')
    if [ "$v" = "1" ] && [ -f "$(vmf_lvm_devfile)" ]; then echo yes; else echo no; fi
}
# The PVID of each physical volume the devices file lists.
vmf_lvm_file_pvids() {
    grep -o 'PVID=[^ ]*' "$(vmf_lvm_devfile)" 2>/dev/null | sed 's/^PVID=//' | grep -v -x -F 'none' | grep . | sort -u
}
# The PVID of each physical volume LVM uses now.
vmf_lvm_seen_pvids() {
    pvs --noheadings -o pv_uuid 2>/dev/null | tr -d ' -' | grep . | sort -u
}
# Each PVID the devices file lists that LVM does not use now.
vmf_lvm_missing() {
    local seen id
    seen=$(vmf_lvm_seen_pvids)
    for id in $(vmf_lvm_file_pvids); do
        printf '%s\n' "$seen" | grep -qx "$id" || printf '%s\n' "$id"
    done
}
# The fact, in the words the engine reads (Get-VmfLvmDevicesFileFact).
vmf_lvm_fact() {
    local total missing count
    case "$(vmf_lvm_inuse)" in
        nolvm) echo "LVM is not installed"; return 0 ;;
        no) echo "not in use"; return 0 ;;
    esac
    total=$(vmf_lvm_file_pvids | grep -c .)
    missing=$(vmf_lvm_missing | tr '\n' ' ' | sed 's/ *$//')
    if [ -z "$missing" ]; then
        echo "in use ($(vmf_lvm_devfile)): $total physical volume(s), every one found"
    else
        count=$(vmf_lvm_missing | grep -c .)
        echo "in use ($(vmf_lvm_devfile)): $total physical volume(s), $count not found: $missing"
    fi
}
# <<< vmf-lvm-facts
add_check "lvm devices file" "INFO" "$(vmf_lvm_fact)"

emit "READY" ""

exit 0
