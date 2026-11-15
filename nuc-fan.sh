#!/bin/bash
# Print NUC EC fan status: RPM and decoded fan record 1. Read-only.
# Usage: nuc-fan.sh [path-to-ecmem]
set -euo pipefail
ECMEM=${1:-/usr/local/lib/nuc-ec-fan/ecmem}

# 256 bytes -> array of hex strings
mapfile -t B < <("$ECMEM" read | tr ' ' '\n' | grep -v '^$')
[ "${#B[@]}" -eq 256 ] || { echo "unexpected dump length ${#B[@]}" >&2; exit 1; }
h() { printf '%d' "0x${B[$1]}"; }

rpm=$(( $(h 0x1d) * 256 + $(h 0x1e) ))
printf 'fan_present=%d rpm=%d\n' "$(h 0x1c)" "$rpm"
printf 'record1 primary:   source=%d max=%dC min=%dC min_duty=%d%% incr=%d off=%dC\n' \
  "$(h 0x80)" "$(h 0x81)" "$(h 0x82)" "$(h 0x83)" "$(h 0x84)" "$(h 0x85)"
printf 'record1 secondary: source=%d max=%dC min=%dC min_duty=%d%% incr=%d off=%dC\n' \
  "$(h 0x86)" "$(h 0x87)" "$(h 0x88)" "$(h 0x89)" "$(h 0x8a)" "$(h 0x8b)"
printf 'record1 config1=0x%s config2=0x%s\n' "${B[0x8c]}" "${B[0x8d]}"
