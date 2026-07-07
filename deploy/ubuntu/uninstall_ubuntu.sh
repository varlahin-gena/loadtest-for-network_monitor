#!/usr/bin/env bash
# Удаление стенда loadtest-for-network_monitor с Ubuntu.
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/loadtest-for-network_monitor}"
REMOVE_GO="${REMOVE_GO:-no}"    # yes = снести и Go из /usr/local/go
REMOVE_K6="${REMOVE_K6:-no}"    # yes = снести k6 и его apt-репозиторий

log()  { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
die()  { echo -e "\033[1;31m[x]\033[0m $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "запусти от root (sudo)"

# ---- репозиторий ----
if [ -d "$INSTALL_DIR" ]; then
  log "удаляю $INSTALL_DIR"
  rm -rf "$INSTALL_DIR"
else
  warn "каталог $INSTALL_DIR не найден"
fi

# ---- Go (опционально) ----
if [ "$REMOVE_GO" = "yes" ]; then
  log "удаляю Go"
  rm -rf /usr/local/go
  rm -f /etc/profile.d/go.sh
else
  warn "Go оставлен (REMOVE_GO=yes чтобы удалить)"
fi

# ---- k6 (опционально) ----
if [ "$REMOVE_K6" = "yes" ]; then
  log "удаляю k6"
  export DEBIAN_FRONTEND=noninteractive
  apt-get remove -y k6 || true
  rm -f /etc/apt/sources.list.d/k6.list
  rm -f /usr/share/keyrings/k6-archive-keyring.gpg
  apt-get update -y || true
else
  warn "k6 оставлен (REMOVE_K6=yes чтобы удалить)"
fi

log "удаление завершено"
