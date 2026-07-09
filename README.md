# loadtest-for-network_monitor
Нагрузочное тестирование для [network_monitor](https://github.com/varlahin-gena/network_monitor).

## Установка одной командой

На чистом Ubuntu-сервере (от root):

```bash
curl -fsSL https://raw.githubusercontent.com/varlahin-gena/loadtest-for-network_monitor/main/install.sh | sudo bash
```

С указанием адреса network_monitor:

```bash
curl -fsSL https://raw.githubusercontent.com/varlahin-gena/loadtest-for-network_monitor/main/install.sh | \
  sudo bash -s -- --target-url http://10.0.0.5/api/ingest --target-base http://10.0.0.5 --with-docker
```

Установщик сам:
- ставит Go, k6 и зависимости;
- клонирует репозиторий в `/opt/loadtest-for-network_monitor`;
- синхронизирует образцы событий из network_monitor;
- собирает генератор нагрузки;
- создаёт команды `loadtest-run`, `loadtest-monitor`, `loadtest-status`;
- пишет конфиг в `/etc/default/loadtest-for-network_monitor`.

Лог установки: `/var/log/loadtest-install.log`

### Локально из клонированного репо

```bash
sudo ./install.sh
# или с параметрами:
sudo ./install.sh --target-url http://192.168.1.10/api/ingest --with-docker
```

### Удаление

```bash
sudo deploy/ubuntu/uninstall_ubuntu.sh --remove-k6
# полная очистка включая Go:
sudo REMOVE_GO=yes REMOVE_K6=yes deploy/ubuntu/uninstall_ubuntu.sh
```

## Запуск нагрузки

После установки:

```bash
loadtest-status                  # проверить, что всё на месте
loadtest-monitor                 # мониторинг ClickHouse (нужен Docker)
loadtest-run B                   # фаза B — ramp ingest
loadtest-run C                   # read-нагрузка (k6)
loadtest-run map                 # демонстрация карты с публичными GeoIP-адресами
```

Или вручную (переопредели URL в `/etc/default/loadtest-for-network_monitor`):

```bash
cd /opt/loadtest-for-network_monitor/loadtest
URL=http://SERVER_IP/api/ingest BASE=http://SERVER_IP ./run.sh B
```

## Фазы тестирования

| Фаза | Описание |
|------|----------|
| `A` | baseline — эталонные latency |
| `B` | ramp — предел записи |
| `C` | read-нагрузка (/api/events), нужен k6 |
| `D` | смешанная нагрузка |
| `E` | stress до отказа |
| `F` | soak 6ч |
| `G` | spike |
| `map` | demo-режим для карты с публичными IP из разных регионов |
| `dirty` | путь parse_errors |
| `syslog` | syslog-ng → importer (UDP) |

## Переменные окружения установщика

| Переменная | По умолчанию | Описание |
|------------|--------------|----------|
| `INSTALL_DIR` | `/opt/loadtest-for-network_monitor` | Каталог установки |
| `TARGET_URL` | авто | URL ingest API |
| `TARGET_BASE` | авто | Базовый URL для read |
| `INSTALL_K6` | `yes` | Установить k6 (при сбое CDN — fallback с GitHub) |
| `K6_VERSION` | `2.0.0` | Версия k6 для установки с GitHub |
| `INSTALL_DOCKER` | `no` | Установить Docker |
| `SKIP_SYNC` | `no` | Не синхронизировать samples |
| `REPO_BRANCH` | `main` | Ветка репозитория |
