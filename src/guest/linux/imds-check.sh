#!/bin/bash
# imds-check.sh - ask the Instance Metadata Service what this machine is
# (VmMigrationFactory, VERIFY-FP-1). Read-only. Facts only: the ENGINE judges
# them against the plan and against the reading before the move.
#
# Microsoft (instance-metadata-service): IMDS is at 169.254.169.254, and
# requests "must be sent using the VM's primary NIC and primary IP, and DHCP
# must be enabled" - so one answer proves the part of the network a move
# rebuilds. The header Metadata: true, no proxy, at most 5 requests a second,
# and retry a 410 "for a max of 70 seconds" (and a 429 or a 5xx): tries two
# seconds apart for up to 70 seconds, and the first answer ends it.
# securityType needs api-version 2021-12-13 or later. A machine that never
# reaches IMDS reports imdsReached=no and is not failed for it.
#
# Emits ONE JSON object per schemas/guest-output.schema.json.
# result: READY, or BLOCKED when no HTTP client exists (read as unknown).
VMF_VERSION="1.1.0"
SCRIPT_NAME="imds-check.sh"
URI="http://169.254.169.254/metadata/instance/compute?api-version=2023-07-01"

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

# One value out of the JSON IMDS returns: "key":"value", spaces allowed.
field() { printf '%s' "$BODY" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n 1 | cut -d'"' -f4; }

emit() {
    printf '{"schema":"vmf.guest/3","script":"%s","version":"%s","os":"%s","result":"%s","checks":%s,"facts":%s,"warnings":[]%s}\n' \
        "$SCRIPT_NAME" "$VMF_VERSION" "$(json_escape "$OS_PRETTY")" "$1" "$CHECKS" "$FACTS" "$2"
}

OS_PRETTY="unknown"
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_PRETTY="${PRETTY_NAME:-$ID}"
fi
add_fact "os" "Linux"

get() {
    if command -v curl >/dev/null 2>&1; then
        curl -s --noproxy '*' -H 'Metadata: true' --max-time 5 "$URI"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O - --no-proxy --header='Metadata: true' --timeout=5 "$URI"
    else
        return 127
    fi
}

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    add_check "instance metadata service" "INFO" "neither curl nor wget is installed"
    emit "BLOCKED" ",\"error\":\"no HTTP client to ask the Instance Metadata Service\""
    exit 0
fi

BODY=""
TRIES=0
START=$(date +%s)
while :; do
    TRIES=$((TRIES + 1))
    BODY=$(get 2>/dev/null)
    if [ -n "$BODY" ] && [ -n "$(field vmSize)" ]; then break; fi
    BODY=""
    [ $(( $(date +%s) - START )) -ge 70 ] && break
    sleep 2
done

if [ -n "$BODY" ]; then
    SIZE=$(field vmSize)
    add_fact "imdsReached" "yes"
    add_fact "imdsVmSize" "$SIZE"
    ST=$(field securityType); [ -n "$ST" ] && add_fact "imdsSecurityType" "$ST"
    SB=$(field secureBootEnabled); [ -n "$SB" ] && add_fact "imdsSecureBoot" "$SB"
    VT=$(field virtualTpmEnabled); [ -n "$VT" ] && add_fact "imdsVtpm" "$VT"
    add_check "instance metadata service" "INFO" "answered: size $SIZE"
else
    add_fact "imdsReached" "no"
    add_check "instance metadata service" "INFO" "no answer after $TRIES tries in 70 seconds"
fi

emit "READY" ""
exit 0
