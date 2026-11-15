#!/bin/bash
#description=Stops the NUC fan curve and restores the original minimum fan duty.
# For the background mode (no systemd, or Unraid). Under systemd use
# "systemctl stop nuc-fan-curve" instead.
#name=NUC fan curve stop
PIDFILE=${NFC_PIDFILE:-/run/nuc-fan-curve.pid}
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
for f in /var/log/syslog /var/log/messages; do
  [ -r "$f" ] && { grep nuc-fan-curve "$f" | tail -3; exit 0; }
done
journalctl -t nuc-fan-curve -n 3 --no-pager 2>/dev/null
