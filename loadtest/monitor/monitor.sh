#!/usr/bin/env bash
# Собирает ресурсы контейнеров и метрики ClickHouse раз в INTERVAL секунд.
set -euo pipefail

INTERVAL="${INTERVAL:-5}"
OUT="${OUT:-metrics_$(date +%Y%m%d_%H%M%S).log}"
CH_CONTAINER="${CH_CONTAINER:-clickhouse}"

echo "logging to $OUT (interval ${INTERVAL}s). Ctrl+C to stop."
{
  echo "=== monitor start $(date -Is) ==="
  while true; do
    echo "---- $(date -Is) ----"

    echo "[docker stats]"
    docker stats --no-stream \
      --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}' || true

    echo "[clickhouse]"
    docker exec "$CH_CONTAINER" clickhouse-client -q "
      SELECT
        (SELECT count() FROM traffic_logs)                    AS rows_total,
        (SELECT count() FROM parse_errors)                    AS parse_errors,
        (SELECT count() FROM system.parts
           WHERE table='traffic_logs' AND active)             AS active_parts,
        (SELECT formatReadableSize(sum(bytes_on_disk))
           FROM system.parts WHERE table='traffic_logs' AND active) AS disk,
        (SELECT count() FROM system.merges)                   AS merges,
        (SELECT count() FROM system.processes)                AS running_queries
      FORMAT Vertical" 2>/dev/null || echo "  (clickhouse query failed)"

    echo "[disk]"
    df -h / | tail -1

    sleep "$INTERVAL"
  done
} | tee -a "$OUT"
