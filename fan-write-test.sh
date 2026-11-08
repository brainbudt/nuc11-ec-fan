#!/bin/bash
# One-shot experiment: record-1 primary min_duty 0x32 -> 0x46 for 30 s, then restore.
# Run as root on the NUC. Logs to stdout. Restore runs on any exit or signal;
# exit status 2 means the byte could not be verified as restored.
set -u -o pipefail
ECMEM=${ECMEM:-/tmp/ecmem} NUCFAN=${NUCFAN:-/tmp/nuc-fan.sh}
OFF=0x83 OLD=0x32 NEW=0x46
HWMON=$(grep -l "^coretemp$" /sys/class/hwmon/hwmon*/name | head -1 | xargs -r dirname)
CPU_TEMP=${CPU_TEMP:-${HWMON:-/nonexistent}/temp1_input}

byte() { local b; b=$("$ECMEM" read | tr ' ' '\n' | grep -v '^$' | sed -n "$((OFF + 1))p") && [[ $b =~ ^[0-9a-f]{2}$ ]] && echo "0x$b"; }
rpm()  { local r; r=$("$NUCFAN" "$ECMEM" | sed -n 's/.*rpm=//p') && [[ $r =~ ^[0-9]+$ ]] && echo "$r"; }
log()  {
  local b r t
  b=$(byte) && r=$(rpm) && t=$(cat "$CPU_TEMP") || { echo "sample failed"; return 1; }
  echo "[$(date +%T)] cpu=$(( t / 1000 ))C rpm=$r byte=$b $*"
}

restored=0
restore() {
  [ "$restored" = 1 ] && return 0
  restored=1
  local cur; cur=$(byte)
  case "$cur" in
    0x46) "$ECMEM" write $OFF $NEW $OLD ;;  # result checked by readback below
    0x32) echo "already restored" ;;
    *)    echo "MANUAL RECOVERY NEEDED: byte is '$cur' (expected 0x46 or 0x32); reboot restores BIOS profile"; return 1 ;;
  esac
  cur=$(byte)
  [ "$cur" = 0x32 ] && { echo "restore verified"; return 0; }
  echo "MANUAL RECOVERY NEEDED: byte is '$cur' after restore"; return 1
}
cleanup() { trap '' HUP INT TERM; restore || exit 2; }

# Preconditions (nothing written yet)
[ -r "$CPU_TEMP" ] || { echo "abort: coretemp hwmon not found"; exit 1; }
[ "$(byte)" = $OLD ] || { echo "abort: byte is '$(byte)', expected $OLD"; exit 1; }
[ "$(cat "$CPU_TEMP")" -lt 70000 ] || { echo "abort: CPU >= 70C"; exit 1; }
for i in 1 2 3; do log baseline || exit 1; sleep 3; done

trap cleanup EXIT
trap 'exit 1' HUP INT TERM
"$ECMEM" write $OFF $OLD $NEW || { echo "write failed"; exit 1; }
for i in $(seq 1 10); do log test || exit 1; sleep 3; done

restore || exit 2
for i in $(seq 1 10); do log after || exit 1; sleep 3; done
