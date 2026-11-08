#!/bin/bash
# Controlled sweep of fan record 1 primary min_duty (EC offset 0x83).
# Each step: >= 60 s baseline at the original value, write the step value,
# >= HOLD_S s hold (real time, default 12), restore, verify. Sham steps write the original
# value over itself. The default plan is two sweeps, the second in reverse order.
# Run as root on the NUC. Prints one CSV line per sample:
#   step,value,phase,t,cpu_c,src4_c,rpm,byte     (t = real seconds since phase start)
# Exit 2 = byte could not be verified as restored (manual recovery needed).
set -u -o pipefail
ECMEM=${ECMEM:-/tmp/ecmem} NUCFAN=${NUCFAN:-/tmp/nuc-fan.sh}
OFF=0x83 OLD=0x32
STEPS=${STEPS:-"0x32 0x3c 0x28 0x50 0x32 0x46 0x2d 0x2d 0x46 0x32 0x50 0x28 0x3c 0x32"}
ALLOWED=" 0x28 0x2d 0x32 0x3c 0x46 0x50 "   # 40..80 % only
MAX_CPU=${MAX_CPU:-65000}                     # abort during any phase
MAX_CPU_LOWER=${MAX_CPU_LOWER:-60000}         # required before lowering duty
BASE_S=60 HOLD_S=${HOLD_S:-12} END_S=40 DT=${DT:-0.25}
HWMON=$(grep -l "^coretemp$" /sys/class/hwmon/hwmon*/name | head -1 | xargs -r dirname)
CPU_TEMP=${CPU_TEMP:-${HWMON:-/nonexistent}/temp1_input}

dump() { "$ECMEM" read | tr ' ' '\n' | grep -v '^$'; }
now()  { date +%s%3N; }   # milliseconds

# sample <step> <value> <phase> <t0> <expected-byte>
# Fails on read error, unexpected byte, or CPU over limit.
sample() {
  local d t b r s4 el
  mapfile -t d < <(dump) && [ "${#d[@]}" -eq 256 ] && t=$(cat "$CPU_TEMP") || { echo "# sample failed"; return 1; }
  b=0x${d[OFF]}; r=$(( 16#${d[0x1d]} * 256 + 16#${d[0x1e]} ))
  [ "${d[0x10]}" = 04 ] && s4=$(( 16#${d[0x11]} )) || s4=NA
  LAST_MS=$(( $(now) - $4 )); el=$(printf "%d.%03d" $((LAST_MS / 1000)) $((LAST_MS % 1000)))
  echo "$1,$2,$3,$el,$(( t / 1000 )),$s4,$r,$b"
  [ "$b" = "$5" ] || { echo "# byte $b, expected $5"; return 1; }
  [ "$t" -lt "$MAX_CPU" ] || { echo "# CPU over limit"; return 1; }
}

# run_phase <step> <value> <phase> <seconds> <expected-byte>
run_phase() {
  local t0; t0=$(now)
  while :; do
    sample "$1" "$2" "$3" "$t0" "$5" || return 1
    (( LAST_MS >= $4 * 1000 )) && return 0   # last logged sample is at/after the deadline
    sleep $DT
  done
}

byte() { local b; b=$(dump | sed -n "$((OFF + 1))p") && [[ $b =~ ^[0-9a-f]{2}$ ]] && echo "0x$b"; }
restore() {   # always re-reads; idempotent
  local cur; cur=$(byte)
  if [ "$cur" = "$OLD" ]; then return 0
  elif [[ -n $cur && $ALLOWED == *" $cur "* ]]; then "$ECMEM" write $OFF "$cur" $OLD >/dev/null  # checked below
  else echo "# MANUAL RECOVERY NEEDED: byte is '$cur'; reboot expected to reload BIOS profile"; return 1
  fi
  cur=$(byte)
  [ "$cur" = "$OLD" ] && return 0
  echo "# MANUAL RECOVERY NEEDED: byte is '$cur' after restore"; return 1
}
cleanup() { trap '' HUP INT TERM; restore || exit 2; }

# Preconditions (nothing written yet)
[ -r "$CPU_TEMP" ] || { echo "abort: coretemp hwmon not found"; exit 1; }
[ "$(byte)" = $OLD ] || { echo "abort: byte is '$(byte)', expected $OLD"; exit 1; }
for v in $STEPS; do [[ $ALLOWED == *" $v "* ]] || { echo "abort: step $v not allowed"; exit 1; }; done

trap cleanup EXIT
trap 'exit 1' HUP INT TERM
echo "step,value,phase,t,cpu_c,src4_c,rpm,byte"
n=0
for v in $STEPS; do
  n=$((n + 1))
  run_phase $n "$v" base $BASE_S $OLD || exit 1
  if (( v < OLD )); then
    t=$(cat "$CPU_TEMP") && [[ $t =~ ^[0-9]+$ ]] && (( t < MAX_CPU_LOWER )) || { echo "# CPU unreadable or too warm to lower duty"; exit 1; }
  fi
  "$ECMEM" write $OFF $OLD "$v" >/dev/null || { echo "# write failed"; exit 1; }
  run_phase $n "$v" hold $HOLD_S "$v" || exit 1
  restore || exit 2
done
run_phase end $OLD end $END_S $OLD || exit 1
