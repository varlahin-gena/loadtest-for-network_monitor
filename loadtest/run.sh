#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

URL="${URL:-http://127.0.0.1:8080/api/ingest}"
BASE="${BASE:-http://127.0.0.1:8080}"
GEN="go run ./gen"

phase() { echo; echo "########## PHASE $1: $2 ##########"; }

# Запусти monitor в отдельном терминале:  INTERVAL=5 ./monitor/monitor.sh
echo "Убедись, что monitor/monitor.sh запущен отдельно."

case "${1:-all}" in
  A) phase A "baseline (smoke)"
     $GEN -url "$URL" -stages "500:10m" -start-rate 500 -batch 50 -workers 32 ;;

  B) phase B "ingest ramp (write path breakpoint)"
     $GEN -url "$URL" -stages "5000:3m,10000:3m,20000:3m,40000:3m,60000:3m" \
          -start-rate 1000 -batch 200 -workers 96 ;;

  C) phase C "read load (aggregator)"
     k6 run -e BASE="$BASE" ./read/read.js ;;

  D) phase D "mixed realistic (write ~60% + read)"
     ( $GEN -url "$URL" -stages "15000:12m" -start-rate 15000 -batch 200 -workers 96 ) &
     GEN_PID=$!
     sleep 5
     k6 run -e BASE="$BASE" ./read/read.js || true
     kill $GEN_PID 2>/dev/null || true ;;

  E) phase E "stress to failure"
     $GEN -url "$URL" -stages "20000:2m,50000:2m,80000:2m,120000:3m" \
          -start-rate 5000 -batch 500 -workers 128 ;;

  F) phase F "soak / endurance (6h @ ~50%)"
     $GEN -url "$URL" -stages "12000:6h" -start-rate 12000 -batch 200 -workers 96 ;;

  G) phase G "spike"
     $GEN -url "$URL" -stages "2000:2m,40000:30s,2000:2m,40000:30s,2000:2m" \
          -start-rate 2000 -batch 200 -workers 128 ;;

  dirty) phase X "parse_errors path (30% garbage)"
     $GEN -url "$URL" -stages "10000:5m" -start-rate 10000 -batch 100 -workers 64 -dirty-rate 0.3 ;;

  syslog) phase X "syslog-ng -> importer path (UDP)"
     $GEN -mode udp -syslog "127.0.0.1:514" -stages "5000:5m" -start-rate 5000 -batch 1 -workers 32 ;;

  all)
     bash "$0" A; sleep 30
     bash "$0" B; sleep 30
     bash "$0" C; sleep 30
     bash "$0" D
     echo "E/F/G запускай отдельно (stress/soak/spike)." ;;
  *) echo "usage: $0 {A|B|C|D|E|F|G|dirty|syslog|all}"; exit 1 ;;
esac
