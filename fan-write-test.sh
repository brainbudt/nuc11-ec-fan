#!/bin/bash
# One-shot experiment: record-1 primary min_duty 0x32 -> 0x46 for 30 s, then restore.
# Run as root on the NUC. Logs to stdout. Restore runs on any exit or signal.
set -u
ECMEM=/tmp/ecmem
OFF=0x83 OLD=0x32 NEW=0x46
HWMON=$(grep -l "^coretemp$" /sys/class/hwmon/hwmon*/name | head -1 | xargs -r dirname)
CPU_TEMP=${HWMON:-/nonexistent}/temp1_input

byte() { "$ECMEM" read | tr ' ' '\n' | grep -v '^$' | sed -n "$((OFF + 1))p"; }
rpm()  { /tmp/nuc-fan.sh "$ECMEM" | sed -n 's/.*rpm=//p'; }
log()  { echo "[$(date +%T)] cpu=$(( $(cat $CPU_TEMP) / 1000 ))C rpm=$(rpm) byte=0x$(byte) $*"; }

restored=0
restore() {
  [ "$restored" = 1 ] && return
  restored=1
  local cur; cur=0x$(byte)
  case "$cur" in
    0x46) "$ECMEM" write $OFF $NEW $OLD ;;
    0x32) echo "already restored" ;;
    *)    echo "MANUAL RECOVERY NEEDED: byte is $cur (expected 0x46 or 0x32); reboot restores BIOS profile"; return ;;
  esac
  cur=0x$(byte)
  [ "$cur" = 0x32 ] && echo "restore verified" || echo "MANUAL RECOVERY NEEDED: byte is $cur after restore"
}

# Preconditions
"$ECMEM" read >/dev/null || { echo "ecmem read failed"; exit 1; }
[ "0x$(byte)" = $OLD ] || { echo "abort: byte is 0x$(byte), expected $OLD"; exit 1; }
[ -r "$CPU_TEMP" ] || { echo "abort: coretemp hwmon not found"; exit 1; }
[ "$(cat "$CPU_TEMP")" -lt 70000 ] || { echo "abort: CPU >= 70C"; exit 1; }

trap restore EXIT HUP INT TERM
for i in 1 2 3; do log baseline; sleep 3; done

"$ECMEM" write $OFF $OLD $NEW; echo "write exit=$?"
for i in $(seq 1 10); do log test; sleep 3; done

restore
for i in $(seq 1 10); do log after; sleep 3; done
