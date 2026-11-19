#!/bin/bash
# neutral-mark.sh - read the machine name and the time, and nothing else
# (VmMigrationFactory, RUNCMD-REPLAY-1).
#
# Measured 2026-10-11: after a machine went back to disks made from its first
# copy, Azure ran the machine's LAST Run Command again when it started. When
# the last Run Command before the put-back only read the machine, nothing came
# back. So the engine runs this script straight after every guest script that
# changes the machine: if Azure runs the last command again, it runs this one,
# which changes nothing.
#
# It checks nothing about the move, so it reads the same on every move: v5,
# v6, v7, SCSI or NVMe. It writes nothing, starts nothing and stops nothing.
# The shebang stays: a payload with none runs under sh (CLAUDE.md).
#
# Emits ONE JSON object per schemas/guest-output.schema.json (vmf.guest/2).
# result: READY.
VMF_VERSION="1.0.0"
SCRIPT_NAME="neutral-mark.sh"

# Keep only characters that need no escape in JSON.
clean() { printf '%s' "$1" | tr -cd 'A-Za-z0-9._:-'; }

NAME=$(clean "$(cat /proc/sys/kernel/hostname 2>/dev/null || hostname 2>/dev/null)")
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)

printf '{"schema":"vmf.guest/2","script":"%s","version":"%s","result":"READY","checks":[{"name":"machine name","status":"INFO","detail":"%s"},{"name":"time","status":"INFO","detail":"%s"}],"warnings":[]}\n' \
    "$SCRIPT_NAME" "$VMF_VERSION" "$NAME" "$NOW"
exit 0
