#!/bin/bash
#description=Stops the NUC fan curve and restores the original minimum fan duty.
#name=NUC fan curve stop
PIDFILE=${NFC_PIDFILE:-/var/run/nuc-fan-curve.pid}
pid=$(cat "$PIDFILE" 2>/dev/null)
# Only signal the pid if it really is the fan curve loop (pid files can go stale).
if [[ $pid =~ ^[0-9]+$ ]] && tr '\0' ' ' 2>/dev/null < "/proc/$pid/cmdline" | grep -q -- ' __nuc_fan_curve_loop $'; then
  kill -TERM "$pid"
  for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
  kill -0 "$pid" 2>/dev/null && { echo "fan curve (pid $pid) did not stop"; exit 1; }
  echo "fan curve stopped"
else
  echo "fan curve is not running"
fi
grep nuc-fan-curve /var/log/syslog | tail -3
