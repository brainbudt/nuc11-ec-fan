#!/bin/bash
#description=Fan curve for Intel NUC 11 Pro via the EC (sets the fan's minimum duty from CPU temperature). Re-run after changing settings.
#name=NUC fan curve
#
# ======================= SETTINGS =======================
# Fan curve: "CPU-temperature-C:minimum-fan-percent" pairs, temperatures ascending.
# Between points the percentage is interpolated linearly. Below the first point
# the first percentage is used, above the last point the last percentage.
CURVE="50:45 60:50 70:65 80:85 90:100"

# Seconds between temperature checks.
INTERVAL=5

# The fan is only lowered once the CPU is this many degrees C cooler than the
# temperature that would justify the current speed (prevents flapping).
HYSTERESIS=3
# ========================================================
#
# Notes
# - This sets the *minimum* duty of the EC's own fan curve. The EC still speeds
#   the fan up further when it gets hot, so the fan never runs slower than the
#   BIOS curve allows above that minimum.
# - Values are clamped to 40..100 %. Below about 45 % the fan did not get any
#   slower in tests (about 2960 RPM). 40-80 % was tested; above 80 % only
#   makes the fan faster.
# - Stop it with the "NUC fan curve stop" script; that restores the value that
#   was active before the first start since boot. The User Scripts "Abort"
#   button does NOT stop the curve (it runs detached in the background).
# - Status: /tmp/nuc-fan-curve.status   Log: syslog tag "nuc-fan-curve".

set -u -o pipefail
# Paths (overridable only for hardware-free testing)
DIR=${NFC_DIR:-/boot/config/plugins/nuc-ec-fan}
ECMEM=${NFC_ECMEM:-/usr/local/sbin/nuc-ecmem}
ECMEM_SHA=${NFC_ECMEM_SHA:-eefd621944a30cf73d03f914b6a0d37b694498742bb309f37966edc474cecfbd}
PIDFILE=${NFC_PIDFILE:-/var/run/nuc-fan-curve.pid}
ORIGFILE=${NFC_ORIGFILE:-/tmp/nuc-fan-curve.orig}
STATUS=${NFC_STATUS:-/tmp/nuc-fan-curve.status}
CPU_TEMP_FILE=${NFC_CPU_TEMP_FILE:-}
STARTLOCK=${NFC_STARTLOCK:-/var/run/nuc-fan-curve.start.lock}
LOOPLOCK=${NFC_LOOPLOCK:-/var/run/nuc-fan-curve.loop.lock}
OFF=0x83 DUTY_MIN=40 DUTY_MAX=100

log() { logger -t nuc-fan-curve -- "$*"; echo "$*"; }
die() { log "ERROR: $*"; exit 1; }

# True if pid $1 is a running fan curve loop (guards against stale, reused pids).
is_loop() { [[ $1 =~ ^[0-9]+$ ]] && tr '\0' ' ' 2>/dev/null < "/proc/$1/cmdline" | grep -q -- ' __nuc_fan_curve_loop $'; }

stop_running() {
  local pid
  pid=$(cat "$PIDFILE" 2>/dev/null)
  if ! is_loop "$pid"; then
    rm -f "$PIDFILE"
    flock -n "$LOOPLOCK" true || die "a fan curve loop is running without a pid file; stop it manually"
    return 0
  fi
  kill -TERM "$pid"
  for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.2; done
  die "previous instance (pid $pid) did not stop"
}

# Reads the EC window; sets DUTY (current byte at 0x83, decimal) and RPM.
read_ec() {
  local d
  mapfile -t d < <("$ECMEM" read | tr ' ' '\n' | grep -v '^$') || return 1
  [ "${#d[@]}" -eq 256 ] || return 1
  DUTY=$(( 16#${d[OFF]} )); RPM=$(( 16#${d[0x1d]} * 256 + 16#${d[0x1e]} ))
}

# Writes duty $1 (percent) over the current value; verifies by reading back.
set_duty() {
  read_ec || return 1
  [ "$DUTY" -eq "$1" ] && return 0
  "$ECMEM" write $OFF "$DUTY" "$1" >/dev/null
  read_ec && [ "$DUTY" -eq "$1" ]
}

# Curve value for temperature $1 (degrees C).
curve() {
  local t=$1 p t1 d1 t2 d2 first=1
  for p in $CURVE; do
    t2=${p%%:*}; d2=${p##*:}
    if [ $first = 1 ]; then
      first=0; t1=$t2; d1=$d2
      (( t <= t2 )) && { echo "$d2"; return; }
      continue
    fi
    if (( t <= t2 )); then echo $(( d1 + (t - t1) * (d2 - d1) / (t2 - t1) )); return; fi
    t1=$t2; d1=$d2
  done
  echo "$d1"
}

clamp() { local v=$1; (( v < DUTY_MIN )) && v=$DUTY_MIN; (( v > DUTY_MAX )) && v=$DUTY_MAX; echo "$v"; }

validate_settings() {
  local p t d prev_t=-1 prev_d=-1 n=0
  [[ $INTERVAL =~ ^[0-9]+$ ]] && (( INTERVAL >= 1 && INTERVAL <= 60 )) || die "INTERVAL must be 1..60"
  [[ $HYSTERESIS =~ ^[0-9]+$ ]] && (( HYSTERESIS <= 15 )) || die "HYSTERESIS must be 0..15"
  for p in $CURVE; do
    [[ $p =~ ^[0-9]+:[0-9]+$ ]] || die "CURVE entry '$p' is not TEMP:PERCENT"
    t=${p%%:*}; d=${p##*:}
    (( t > prev_t )) || die "CURVE temperatures must be strictly ascending"
    (( d >= prev_d )) || die "CURVE percentages must not decrease"
    (( t <= 105 && d <= 100 )) || die "CURVE entry '$p' out of range"
    prev_t=$t; prev_d=$d; n=$((n + 1))
  done
  (( n >= 1 )) || die "CURVE is empty"
}

cpu_temp() {
  local h f t
  f=$CPU_TEMP_FILE
  if [ -z "$f" ]; then
    h=$(grep -l "^coretemp$" /sys/class/hwmon/hwmon*/name 2>/dev/null | head -1) || return 1
    f=$(dirname "$h")/temp1_input
  fi
  t=$(cat "$f") && [[ $t =~ ^[0-9]+$ ]] || return 1
  echo $(( t / 1000 ))
}

loop() {
  local orig cur t up down want old fails=0
  exec 8>"$LOOPLOCK"
  flock -n 8 || { log "another fan curve loop is already running; exiting"; exit 1; }
  echo $$ > "$PIDFILE"
  orig=$(cat "$ORIGFILE")
  cur=-1
  SLEEP_PID=
  trap '[ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null; set_duty "$orig" && log "stopped, restored minimum duty $orig %" || log "WARNING: could not restore minimum duty $orig %"; [ "$(cat "$PIDFILE" 2>/dev/null)" = $$ ] && rm -f "$PIDFILE"; exit 0' TERM INT HUP
  log "started: curve '$CURVE', interval ${INTERVAL}s, hysteresis ${HYSTERESIS}C, original $orig %"
  while :; do
    if ! t=$(cpu_temp); then
      log "CPU temperature unreadable"; kill -TERM $$; sleep 1; continue
    fi
    up=$(clamp "$(curve "$t")")
    down=$(clamp "$(curve $(( t + HYSTERESIS )))")
    want=$cur
    if (( cur < 0 || up > cur )); then want=$up
    elif (( down < cur )); then want=$down
    fi
    read_ec || DUTY=-1
    if (( want != cur || DUTY != want )); then   # also corrects changes made by others
      old=$DUTY
      if set_duty "$want"; then
        (( want != cur )) && log "CPU ${t}C: minimum duty $cur -> $want %" || log "corrected minimum duty $old -> $want %"
        cur=$want; fails=0
      else
        fails=$((fails + 1)); log "write of $want % failed ($fails)"
        (( fails >= 3 )) && { log "giving up"; kill -TERM $$; sleep 1; }
      fi
    fi
    read_ec && echo "$(date '+%F %T') cpu=${t}C min_duty=${DUTY}% rpm=${RPM}" > "$STATUS"
    sleep "$INTERVAL" 8>&- & SLEEP_PID=$!   # no lock fd: the lock must die with the loop
    wait $SLEEP_PID                          # interruptible, so a stop signal acts at once
  done
}

[ "${1:-}" = __nuc_fan_curve_loop ] && { loop; exit; }

# ---- start ----
[ "$(id -u)" = 0 ] || [ -n "${NFC_DIR:-}" ] || die "must run as root"
validate_settings
[ -f "$DIR/ecmem" ] || die "$DIR/ecmem not found"
echo "$ECMEM_SHA  $DIR/ecmem" | sha256sum -c --status || die "$DIR/ecmem has an unexpected checksum"
install -m 755 "$DIR/ecmem" "$ECMEM"
"$ECMEM" read >/dev/null || die "EC window not readable (wrong machine or /dev/mem blocked)"
exec 9>"$STARTLOCK"
flock -n 9 || die "another start is in progress"
stop_running
read_ec || die "EC read failed"
if [ ! -s "$ORIGFILE" ]; then
  (( DUTY >= DUTY_MIN && DUTY <= DUTY_MAX )) || die "current minimum duty $DUTY % is outside $DUTY_MIN..$DUTY_MAX; not touching it"
  echo "$DUTY" > "$ORIGFILE"
fi
rm -f "$PIDFILE"
# Detach with setsid -f and reset INT/HUP to default: a starter that runs in the
# background has them ignored, and bash cannot trap signals ignored at entry.
# The loop writes its own pid file while holding the loop lock.
setsid -f env --default-signal=INT,HUP bash "$(readlink -f "$0")" __nuc_fan_curve_loop < /dev/null > /dev/null 2>&1 9>&-
for _ in $(seq 1 25); do [ -s "$PIDFILE" ] && break; sleep 0.2; done
kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null || die "fan curve did not start; see syslog"
for _ in $(seq 1 10); do [ "$STATUS" -nt "$PIDFILE" ] && break; sleep 0.2; done
log "running (pid $(cat "$PIDFILE")); status: $(cat "$STATUS" 2>/dev/null)"
