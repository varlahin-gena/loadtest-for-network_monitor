#!/usr/bin/env bash
# Точка входа: один запуск — полная установка стенда нагрузочного тестирования.
#
# С сервера (без клонирования репозитория вручную):
#   curl -fsSL https://raw.githubusercontent.com/varlahin-gena/loadtest-for-network_monitor/main/install.sh | sudo bash
#
# Из клонированного репозитория:
#   sudo ./install.sh
#
# Параметры передаются в установщик Ubuntu, например:
#   sudo ./install.sh --target-url http://10.0.0.5:8080/api/ingest
set -euo pipefail

if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  exec bash "$ROOT/deploy/ubuntu/install_ubuntu.sh" "$@"
fi

# curl | bash — скачиваем свежий установщик из main
REPO_URL="${REPO_URL:-https://github.com/varlahin-gena/loadtest-for-network_monitor.git}"
BRANCH="${REPO_BRANCH:-main}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if command -v git >/dev/null 2>&1; then
  git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$TMP/repo"
  exec bash "$TMP/repo/deploy/ubuntu/install_ubuntu.sh" "$@"
fi

# git ещё не установлен — ставим минимальный набор и клонируем
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y git ca-certificates
git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$TMP/repo"
exec bash "$TMP/repo/deploy/ubuntu/install_ubuntu.sh" "$@"
