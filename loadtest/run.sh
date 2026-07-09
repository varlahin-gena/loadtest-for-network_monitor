#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Мишень: подставь IP/URL своего network_monitor (через nginx = порт 80)
URL="${URL:-http://127.0.0.1/api/ingest}"
BASE="${BASE:-http://127.0.0.1}"

GEN_BIN="$(pwd)/gen/loadgen"

# Предпочитаем уже собранный бинарник из install.sh.
# Если его нет, пробуем собрать на месте, даже в non-login shell.
if [ ! -x "$GEN_BIN" ]; then
  export PATH="$PATH:/usr/local/go/bin"
  if ! command -v go >/dev/null 2>&1; then
    echo "loadgen не найден и Go недоступен в PATH; переустанови стенд через ./install.sh" >&2
    exit 1
  fi
  ( cd gen && go build -o loadgen . )
fi

GEN="$GEN_BIN"

phase() {
  echo
  echo "########## PHASE $1: $2 ##########"
}

case "${1:-help}" in
  A)
    phase A "baseline"
    "$GEN" -url "$URL" -stages "500:10m" -start-rate 500 -batch 2000 -workers 8
    ;;
  B)
    phase B "ingest ramp — предел записи"
    "$GEN" -url "$URL" -stages "5000:3m,10000:3m,20000:3m,35000:3m,50000:3m" \
      -start-rate 1000 -batch 2500 -workers 16
    ;;
  C)
    phase C "read load (/api/events)"
    k6 run -e BASE="$BASE" ./read/read.js
    ;;
  D)
    phase D "mixed realistic"
    "$GEN" -url "$URL" -stages "12000:12m" -start-rate 12000 -batch 2500 -workers 16 &
    GEN_PID=$!
    sleep 5
    k6 run -e BASE="$BASE" ./read/read.js || true
    kill "$GEN_PID" 2>/dev/null || true
    ;;
  E)
    phase E "stress"
    "$GEN" -url "$URL" -stages "20000:2m,40000:2m,70000:2m,100000:3m" \
      -start-rate 5000 -batch 2500 -workers 24
    ;;
  F)
    phase F "soak 6h"
    "$GEN" -url "$URL" -stages "10000:6h" -start-rate 10000 -batch 2500 -workers 16
    ;;
  G)
    phase G "spike"
    "$GEN" -url "$URL" -stages "2000:2m,35000:30s,2000:2m,35000:30s,2000:2m" \
      -start-rate 2000 -batch 2500 -workers 24
    ;;
  map)
    phase M "geo map demo"
    "$GEN" -url "$URL" -geo-mode map -stages "2000:5m" -start-rate 1000 -batch 1000 -workers 16 \
      -hot-ips 2000 -total-ips 2000000
    ;;
  dirty)
    phase X "parse_errors path (30% мусора)"
    "$GEN" -url "$URL" -stages "8000:5m" -start-rate 8000 -batch 2500 -workers 16 -dirty-rate 0.3
    ;;
  skipped)
    phase X "Skipped path (include Skip:true)"
    "$GEN" -url "$URL" -stages "8000:5m" -start-rate 8000 -batch 2500 -workers 16 -include-skip
    ;;
  syslog)
    phase X "syslog-ng -> importer (UDP)"
    "$GEN" -mode udp -syslog "${SYSLOG:-127.0.0.1:514}" -stages "5000:5m" \
      -start-rate 5000 -batch 1 -workers 8
    ;;
  *)
    echo "usage: URL=http://IP/api/ingest BASE=http://IP $0 {A|B|C|D|E|F|G|map|dirty|skipped|syslog}"
    ;;
esac
