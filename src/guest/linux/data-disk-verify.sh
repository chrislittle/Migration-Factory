#!/bin/bash
# data-disk-verify.sh - DISK-1 verify (VmMigrationFactory). Read-only.
# After migration: every /datadisk<N> must be mounted and its seed file must
# hash to the stored value. Emits ONE JSON object per guest-output schema.
# result: PASS | FAIL
VMF_VERSION="1.0.0"
SCRIPT_NAME="data-disk-verify.sh"

CHECKS="[]"
FAILS=0

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
    [ "$2" = "FAIL" ] && FAILS=$((FAILS+1))
}

DISTRO_PRETTY="unknown"
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_PRETTY="${PRETTY_NAME:-$ID}"
fi

found=0
for mp in /datadisk*; do
    [ -d "$mp" ] || continue
    found=$((found+1))
    if ! mountpoint -q "$mp"; then
        add_check "mount $mp" "FAIL" "not mounted after migration"
        continue
    fi
    add_check "mount $mp" "PASS" "$(findmnt -n -o SOURCE "$mp")"
    if [ ! -f "$mp/vmf-seed.bin" ] || [ ! -f "$mp/vmf-seed.sha256" ]; then
        add_check "seed $mp" "FAIL" "seed or hash file missing"
        continue
    fi
    expected=$(cat "$mp/vmf-seed.sha256")
    actual=$(sha256sum "$mp/vmf-seed.bin" | awk '{print $1}')
    if [ "$expected" = "$actual" ]; then
        add_check "seed $mp" "PASS" "sha256 intact ($(printf '%s' "$actual" | cut -c1-12)...)"
    else
        add_check "seed $mp" "FAIL" "hash mismatch"
    fi
done

if [ "$found" -eq 0 ]; then
    add_check "data mounts" "FAIL" "no /datadisk* mountpoints found"
fi

if [ "$FAILS" -eq 0 ]; then result="PASS"; else result="FAIL"; fi
os=$(json_escape "$DISTRO_PRETTY")
printf '{"schema":"vmf.guest/2","script":"%s","version":"%s","os":"%s","result":"%s","checks":%s,"warnings":[]}\n' \
    "$SCRIPT_NAME" "$VMF_VERSION" "$os" "$result" "$CHECKS"
exit 0
