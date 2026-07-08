#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# ВАЖНО: запускай с ОТДЕЛЬНОЙ машины. Подставь IP сервера:
URL="${URL:-http://SERVER_IP:8080/api/ingest}"
BASE="${BASE:-http://SERVER_IP:8080}"
GEN_BIN="$(cd "$(dirname "$0")/gen" && pwd)/loadgen"
( cd "$(dirname "$0")/gen" && go build -o loadgen . ) || { echo "build failed"; exit 1; }GEN="$GEN_BIN"

# batch=5000 => каждый HTTP-запрос = один INSERT ~5000 строк в CH (крупные парты, мало мержей)
# workers=16 => сети хватает, backend не задыхается от параллелизма на 4 vCPU
phase() { echo; echo "########## PHASE $1: $2 ##########"; }

case "${1:-help}" in
  A) phase A "baseline"
     $GEN -url "$URL" -stages "500:10m" -start-rate 500 -batch 2000 -workers 8 ;;

  B) phase B "ingest ramp — предел записи"
     $GEN -url "$URL" -stages "5000:3m,10000:3m,20000:3m,35000:3m,50000:3m" \
          -start-rate 1000 -batch 5000 -workers 16 ;;

  C) phase C "read load (/api/events)"
     k6 run -e BASE="$BASE" ./read/read.js ;;

  D) phase D "mixed realistic"
     ( $GEN -url "$URL" -stages "12000:12m" -start-rate 12000 -batch 5000 -workers 16 ) &
     GEN_PID=$!; sleep 5
     k6 run -e BASE="$BASE" ./read/read.js || true
     kill $GEN_PID 2>/dev/null || true ;;

  E) phase E "stress"
     $GEN -url "$URL" -stages "20000:2m,40000:2m,70000:2m,100000:3m" \
          -start-rate 5000 -batch 10000 -workers 24 ;;

  F) phase F "soak 6h"
     $GEN -url "$URL" -stages "10000:6h" -start-rate 10000 -batch 5000 -workers 16 ;;

  G) phase G "spike"
     $GEN -url "$URL" -stages "2000:2m,35000:30s,2000:2m,35000:30s,2000:2m" \
          -start-rate 2000 -batch 5000 -workers 24 ;;

  dirty) phase X "parse_errors path"
     $GEN -url "$URL" -stages "8000:5m" -start-rate 8000 -batch 5000 -workers 16 -dirty-rate 0.3 ;;

  syslog) phase X "syslog-ng -> importer (UDP, по одному событию)"
     $GEN -mode udp -syslog "SERVER_IP:514" -stages "5000:5m" -start-rate 5000 -batch 1 -workers 8 ;;

  *) echo "usage: URL=http://SERVER_IP:8080/api/ingest BASE=http://SERVER_IP:8080 $0 {A|B|C|D|E|F|G|dirty|syslog}";;
esac
