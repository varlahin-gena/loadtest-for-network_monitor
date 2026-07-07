# loadtest-for-network_monitor
Нагрузочное тестирование для network_monitor

Как запускать

# 1. терминал: мониторинг
cd loadtest && INTERVAL=5 CH_CONTAINER=clickhouse ./monitor/monitor.sh

# 2. терминал: фазы по порядку
cd loadtest  
chmod +x run.sh monitor/monitor.sh  
./run.sh A      # baseline — снять эталонные latency  
./run.sh B      # ramp — найти предел записи (смотри active_parts, dropped, fail)  
./run.sh C      # read-нагрузка (нужен k6)  
./run.sh D      # смешанная, как в проде  
./run.sh dirty  # проверка пути parse_errors  
./run.sh syslog # проверка пути syslog-ng -> importer  
./run.sh E      # stress до отказа  
./run.sh F      # soak 6ч (утечки/диск/мержи)  
./run.sh G      # spike  
