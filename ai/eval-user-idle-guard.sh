#!/usr/bin/env bash
set -euo pipefail

context=${1:-ui-eval}
REQUIRE_USER_IDLE=${REQUIRE_USER_IDLE:-1}
MIN_IDLE_SECONDS=${MIN_IDLE_SECONDS:-5}
MAX_IDLE_WAIT_SECONDS=${MAX_IDLE_WAIT_SECONDS:-20}
IDLE_POLL_SECONDS=${IDLE_POLL_SECONDS:-0.5}

if [ "$REQUIRE_USER_IDLE" = "0" ] || [ "${ALLOW_ACTIVE_USER_EVALS:-0}" = "1" ]; then
  echo "user-idle-guard status=skipped context=$context"
  exit 0
fi

deadline=$(( $(date +%s) + ${MAX_IDLE_WAIT_SECONDS%.*} ))
while :; do
  idle_ns=$(ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ {value=$NF} END {print value}')
  if [ -z "$idle_ns" ]; then
    echo "user-idle-guard status=unknown context=$context"
    exit 87
  fi

  idle_seconds=$(awk -v ns="$idle_ns" 'BEGIN { printf "%.3f", ns / 1000000000 }')
  if awk -v idle="$idle_seconds" -v min="$MIN_IDLE_SECONDS" 'BEGIN { exit(idle >= min ? 0 : 1) }'; then
    echo "user-idle-guard status=ok context=$context idle_seconds=$idle_seconds min_idle_seconds=$MIN_IDLE_SECONDS"
    exit 0
  fi
  if awk -v now="$(date +%s)" -v deadline="$deadline" 'BEGIN { exit(now >= deadline ? 0 : 1) }'; then
    break
  fi
  sleep "$IDLE_POLL_SECONDS"
done

echo "user-idle-guard status=ACTIVE context=$context idle_seconds=$idle_seconds min_idle_seconds=$MIN_IDLE_SECONDS"
exit 87
