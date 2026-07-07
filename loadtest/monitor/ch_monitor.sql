-- Запускать вручную во время/после теста: docker exec -it clickhouse clickhouse-client < ch_monitor.sql

-- 1. Скорость записи и объём
SELECT count() AS rows, formatReadableSize(sum(bytes)) AS uncompressed
FROM traffic_logs;

-- 2. Активные парты (рост = мержи не успевают -> "too many parts")
SELECT table, count() AS parts, formatReadableSize(sum(bytes_on_disk)) AS size
FROM system.parts WHERE active AND database='default'
GROUP BY table ORDER BY parts DESC;

-- 3. Медленные запросы (read-нагрузка)
SELECT query_duration_ms, read_rows, formatReadableSize(memory_usage) AS mem,
       substring(query, 1, 80) AS q
FROM system.query_log
WHERE type='QueryFinish' AND event_time > now() - INTERVAL 15 MINUTE
ORDER BY query_duration_ms DESC LIMIT 20;

-- 4. Insert-и: размеры батчей и задержки
SELECT event_time, written_rows, query_duration_ms
FROM system.query_log
WHERE type='QueryFinish' AND query LIKE 'INSERT%'
  AND event_time > now() - INTERVAL 15 MINUTE
ORDER BY event_time DESC LIMIT 30;

-- 5. Ошибки
SELECT event_time, substring(query,1,60) AS q, exception
FROM system.query_log
WHERE type='ExceptionWhileProcessing' AND event_time > now() - INTERVAL 15 MINUTE
ORDER BY event_time DESC LIMIT 20;
