#!/usr/bin/env bash
set -euo pipefail

if [[ -f ".venv/bin/activate" ]]; then
  source .venv/bin/activate
fi

if [[ ! -f "./scripts/key.pem" || ! -f "./scripts/cert.pem" ]]; then
  ./scripts/gen-cert.sh
fi

# If something is already listening on the port, try to stop it gracefully
PORT=8240
echo "Checking for processes listening on port $PORT..."
PIDS=$(ss -ltnp 2>/dev/null | awk -v p=":$PORT" '$4 ~ p { gsub(/.*pid=/, "", $NF); gsub(/,.*/, "", $NF); print $NF }' || true)
if [[ -n "$PIDS" ]]; then
  echo "Found running process(es) on port $PORT: $PIDS"
  for pid in $PIDS; do
    echo "Stopping PID $pid... (SIGTERM)"
    kill "$pid" || true
  done
  # wait up to 5s for processes to exit
  for i in {1..5}; do
    sleep 1
    PIDS=$(ss -ltnp 2>/dev/null | awk -v p=":$PORT" '$4 ~ p { gsub(/.*pid=/, "", $NF); gsub(/,.*/, "", $NF); print $NF }' || true)
    if [[ -z "$PIDS" ]]; then
      break
    fi
    echo "Waiting for processes to exit..."
  done
  if [[ -n "$PIDS" ]]; then
    echo "Forcing kill of remaining PIDs: $PIDS"
    for pid in $PIDS; do
      kill -9 "$pid" || true
    done
  fi
fi

exec python -m uvicorn app.main:app --host 0.0.0.0 --port $PORT \
  --ssl-keyfile=./scripts/key.pem --ssl-certfile=./scripts/cert.pem
