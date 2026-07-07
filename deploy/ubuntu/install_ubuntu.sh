#!/usr/bin/env bash
# Установка стенда нагрузочного тестирования loadtest-for-network_monitor на Ubuntu.
set -euo pipefail

# ---- параметры ----
REPO_URL="${REPO_URL:-https://github.com/varlahin-gena/loadtest-for-network_monitor.git}"
INSTALL_DIR="${INSTALL_DIR:-/opt/loadtest-for-network_monitor}"
GO_VERSION="${GO_VERSION:-1.22.5}"
INSTALL_K6="${INSTALL_K6:-yes}"   # нужен только для read-нагрузки (фазы C/D)

log()  { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
die()  { echo -e "\033[1;31m[x]\033[0m $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "запусти от root (sudo)"
. /etc/os-release 2>/dev/null || true
[ "${ID:-}" = "ubuntu" ] || warn "ожидается Ubuntu, обнаружено: ${ID:-unknown} — продолжаю"

ARCH="$(dpkg --print-architecture)"   # amd64 / arm64
case "$ARCH" in
  amd64) GO_ARCH=amd64 ;;
  arm64) GO_ARCH=arm64 ;;
  *) die "неподдерживаемая архитектура: $ARCH" ;;
esac

# ---- базовые пакеты ----
log "устанавливаю базовые пакеты"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y git curl ca-certificates gnupg tar

# ---- Go ----
if command -v go >/dev/null 2>&1; then
  log "Go уже установлен: $(go version)"
else
  log "устанавливаю Go ${GO_VERSION} (${GO_ARCH})"
  TARBALL="go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
  curl -fsSL "https://go.dev/dl/${TARBALL}" -o "/tmp/${TARBALL}"
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "/tmp/${TARBALL}"
  rm -f "/tmp/${TARBALL}"
  # PATH для всех пользователей
  echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh
  export PATH=$PATH:/usr/local/go/bin
  log "установлен $(go version)"
fi

# ---- k6 (для read-нагрузки) ----
if [ "$INSTALL_K6" = "yes" ]; then
  if command -v k6 >/dev/null 2>&1; then
    log "k6 уже установлен: $(k6 version 2>/dev/null | head -1)"
  else
    log "устанавливаю k6"
    mkdir -p /usr/share/keyrings
    curl -fsSL https://dl.k6.io/key.gpg | gpg --dearmor -o /usr/share/keyrings/k6-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" \
      > /etc/apt/sources.list.d/k6.list
    apt-get update -y
    apt-get install -y k6
  fi
else
  warn "пропускаю установку k6 (INSTALL_K6=no); фазы C/D работать не будут"
fi

# ---- клонирование / обновление репозитория ----
if [ -d "$INSTALL_DIR/.git" ]; then
  log "репозиторий уже есть, обновляю: $INSTALL_DIR"
  git -C "$INSTALL_DIR" pull --ff-only
else
  log "клонирую $REPO_URL -> $INSTALL_DIR"
  git clone "$REPO_URL" "$INSTALL_DIR"
fi

# ---- синхронизация образцов событий из основного проекта ----
if [ -f "$INSTALL_DIR/loadtest/scripts/sync-samples.sh" ]; then
  log "синхронизирую samples.go из network_monitor"
  bash "$INSTALL_DIR/loadtest/scripts/sync-samples.sh" || warn "sync-samples завершился с ошибкой — проверь вручную"
fi

# ---- права на исполнение ----
log "делаю скрипты исполняемыми"
find "$INSTALL_DIR" -type f -name '*.sh' -exec chmod +x {} \;

# ---- сборка генератора (проверка, что всё компилируется) ----
if [ -f "$INSTALL_DIR/loadtest/gen/go.mod" ]; then
  log "проверяю сборку генератора"
  ( cd "$INSTALL_DIR/loadtest/gen" && go build ./... ) \
    && log "генератор собирается" \
    || warn "генератор не собрался — вероятно, нужна ручная правка samplesrc (см. вопрос 1)"
fi

cat <<EOF

$(log "готово")
Каталог:        $INSTALL_DIR
Запуск (с ЭТОЙ или ОТДЕЛЬНОЙ машины, генератор лучше внешне):

  cd $INSTALL_DIR/loadtest
  # мониторинг в отдельном терминале (на сервере с backend/ClickHouse):
  INTERVAL=5 ./monitor/monitor.sh
  # нагрузка (подставь IP сервера):
  URL=http://SERVER_IP:8080/api/ingest BASE=http://SERVER_IP:8080 ./run.sh B

Если открыл новую сессию — подхвати PATH:  source /etc/profile.d/go.sh
EOF
