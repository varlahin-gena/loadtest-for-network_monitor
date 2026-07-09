#!/usr/bin/env bash
# Удаление стенда loadtest-for-network_monitor с Ubuntu/Debian.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

INSTALL_DIR="${INSTALL_DIR:-/opt/loadtest-for-network_monitor}"
REMOVE_GO="${REMOVE_GO:-no}"
REMOVE_K6="${REMOVE_K6:-no}"
REMOVE_DOCKER="${REMOVE_DOCKER:-no}"
REMOVE_CONFIG="${REMOVE_CONFIG:-yes}"

usage() {
  cat <<'EOF'
Удаление loadtest-for-network_monitor.

  sudo deploy/ubuntu/uninstall_ubuntu.sh

Переменные:
  REMOVE_GO=yes       удалить Go из /usr/local/go
  REMOVE_K6=yes       удалить k6 и apt-репозиторий
  REMOVE_DOCKER=yes   удалить Docker (осторожно!)
  REMOVE_CONFIG=no    оставить /etc/default/loadtest-for-network_monitor
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --remove-go)     REMOVE_GO=yes; shift ;;
    --remove-k6)     REMOVE_K6=yes; shift ;;
    --remove-docker) REMOVE_DOCKER=yes; shift ;;
    --keep-config)   REMOVE_CONFIG=no; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) die "неизвестный аргумент: $1" ;;
  esac
done

require_root

# ---- CLI-обёртки и конфиг ----
for bin in loadtest-run loadtest-monitor loadtest-status; do
  if [ -f "/usr/local/bin/$bin" ]; then
    log "удаляю /usr/local/bin/$bin"
    rm -f "/usr/local/bin/$bin"
  fi
done

if [ "$REMOVE_CONFIG" = yes ] && [ -f /etc/default/loadtest-for-network_monitor ]; then
  log "удаляю /etc/default/loadtest-for-network_monitor"
  rm -f /etc/default/loadtest-for-network_monitor
fi

# ---- репозиторий ----
if [ -d "$INSTALL_DIR" ]; then
  log "удаляю $INSTALL_DIR"
  rm -rf "$INSTALL_DIR"
else
  warn "каталог $INSTALL_DIR не найден"
fi

# ---- Go ----
if [ "$REMOVE_GO" = yes ]; then
  log "удаляю Go"
  rm -rf /usr/local/go
  rm -f /etc/profile.d/go.sh
else
  warn "Go оставлен (REMOVE_GO=yes или --remove-go чтобы удалить)"
fi

# ---- k6 ----
if [ "$REMOVE_K6" = yes ]; then
  log "удаляю k6"
  export DEBIAN_FRONTEND=noninteractive
  apt-get remove -y k6 2>/dev/null || true
  rm -f /etc/apt/sources.list.d/k6.list
  rm -f /usr/share/keyrings/k6-archive-keyring.gpg
  apt-get update -y 2>/dev/null || true
else
  warn "k6 оставлен (REMOVE_K6=yes или --remove-k6 чтобы удалить)"
fi

# ---- Docker ----
if [ "$REMOVE_DOCKER" = yes ]; then
  warn "удаляю Docker (REMOVE_DOCKER=yes)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get remove -y docker-ce docker-ce-cli containerd.io 2>/dev/null || true
  rm -f /etc/apt/sources.list.d/docker.list 2>/dev/null || true
else
  warn "Docker оставлен (REMOVE_DOCKER=yes или --remove-docker чтобы удалить)"
fi

LOG_FILE="/var/log/loadtest-install.log"
if [ -f "$LOG_FILE" ]; then
  warn "лог установки сохранён: $LOG_FILE (удали вручную при необходимости)"
fi

log "удаление завершено"
