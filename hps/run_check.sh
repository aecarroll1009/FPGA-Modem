#!/usr/bin/env bash
# Runs iq_streamd against the software model of the Avalon slave and checks
# the datagrams that come out. Needs no board and no ARM toolchain.
#
#   ./hps/run_check.sh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

make -C hps iq_streamd_fake >/dev/null

PORT="${PORT:-5055}"
PAIRS=3600
LOG="$(mktemp)"

python3 -u host/iq_udp.py --port "$PORT" --check-ramp "$PAIRS" >"$LOG" 2>&1 &
RX=$!
trap 'kill $RX 2>/dev/null || true; rm -f "$LOG"' EXIT

for _ in $(seq 200); do
    grep -q "listening on udp/" "$LOG" && break
    sleep 0.05
done

./hps/iq_streamd_fake --host 127.0.0.1 --port "$PORT" \
    --pairs "$PAIRS" --rate decimated --lo-hz 85000

wait "$RX"
cat "$LOG"
