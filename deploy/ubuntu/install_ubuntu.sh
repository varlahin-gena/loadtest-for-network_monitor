#!/usr/bin/env bash
# Полностью автономная установка стенда loadtest-for-network_monitor на Ubuntu/Debian.
#
# Одна команда с сервера:
#   curl -fsSL https://raw.githubusercontent.com/varlahin-gena/loadtest-for-network_monitor/main/install.sh | sudo bash
#
# С указанием цели (network_monitor):
#   curl -fsSL .../install.sh | sudo bash -s -- --target-url http://10.0.0.5/api/ingest
#
# Переменные окружения (альтернатива флагам):
#   REPO_URL, INSTALL_DIR, GO_VERSION, INSTALL_K6, INSTALL_DOCKER,
#   TARGET_URL, TARGET_BASE, CH_CONTAINER, SKIP_SYNC, REPO_BRANCH
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

# ---- defaults ----
REPO_URL="${REPO_URL:-https://github.com/varlahin-gena/loadtest-for-network_monitor.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/loadtest-for-network_monitor}"
GO_VERSION="${GO_VERSION:-1.22.5}"
INSTALL_K6="${INSTALL_K6:-yes}"
INSTALL_DOCKER="${INSTALL_DOCKER:-no}"
SKIP_SYNC="${SKIP_SYNC:-no}"
TARGET_URL="${TARGET_URL:-}"
TARGET_BASE="${TARGET_BASE:-}"
CH_CONTAINER="${CH_CONTAINER:-clickhouse}"
LOG_FILE="${LOG_FILE:-/var/log/loadtest-install.log}"
MANIFEST="$INSTALL_DIR/.install-manifest"

usage() {
  cat <<'EOF'
Установка стенда нагрузочного тестирования loadtest-for-network_monitor.

Использование:
  sudo deploy/ubuntu/install_ubuntu.sh [опции]

Опции:
  --target-url URL    URL ingest API (например http://10.0.0.5/api/ingest)
  --target-base URL   Базовый URL для read-нагрузки (например http://10.0.0.5)
  --install-dir PATH  Каталог установки (по умолчанию /opt/loadtest-for-network_monitor)
  --no-k6             Не устанавливать k6 (фазы C/D недоступны)
  --with-docker       Установить Docker CLI (для monitor.sh)
  --skip-sync         Не синхронизировать samples.go из network_monitor
  --branch BRANCH     Ветка репозитория (по умолчанию main)
  -h, --help          Справка

Примеры:
  sudo ./install.sh
  sudo ./install.sh --target-url http://192.168.1.10/api/ingest --with-docker
  TARGET_URL=http://host/api/ingest sudo deploy/ubuntu/install_ubuntu.sh
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --target-url)   TARGET_URL="$2"; shift 2 ;;
    --target-base)  TARGET_BASE="$2"; shift 2 ;;
    --install-dir)  INSTALL_DIR="$2"; MANIFEST="$INSTALL_DIR/.install-manifest"; shift 2 ;;
    --no-k6)        INSTALL_K6=no; shift ;;
    --with-docker)  INSTALL_DOCKER=yes; shift ;;
    --skip-sync)    SKIP_SYNC=yes; shift ;;
    --branch)       REPO_BRANCH="$2"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *) die "неизвестный аргумент: $1 (см. --help)" ;;
  esac
done

mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

log "=== установка loadtest-for-network_monitor $(date -Is) ==="
log "лог: $LOG_FILE"

require_root
detect_os
detect_arch
ensure_path_go

if [ "$OS_FAMILY" != debian ]; then
  warn "ожидается Ubuntu/Debian, обнаружено: ${OS_ID:-unknown} — продолжаю на свой риск"
fi

# ---- preflight ----
preflight() {
  log "проверка окружения"

  local free_mb
  free_mb="$(df -Pm / | awk 'NR==2 {print $4}')"
  if [ "${free_mb:-0}" -lt 1024 ]; then
    warn "мало свободного места на /: ${free_mb}MB (рекомендуется >= 1GB)"
  fi

  if ! retry 3 3 curl -fsSL --max-time 15 https://go.dev/ -o /dev/null; then
    die "нет доступа в интернет (нужен для загрузки Go/k6/репозитория)"
  fi

  log "ОС: ${OS_ID} ${OS_VERSION}, архитектура: $ARCH"
}
preflight

# ---- пакеты ----
install_base_packages() {
  log "устанавливаю базовые пакеты"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y git curl ca-certificates gnupg tar jq rsync
}
install_base_packages

# ---- Go ----
install_go() {
  if command -v go >/dev/null 2>&1; then
    log "Go уже установлен: $(go version)"
    return
  fi

  log "устанавливаю Go ${GO_VERSION} (${GO_ARCH})"
  local tarball="go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
  retry 3 5 curl -fsSL "https://go.dev/dl/${tarball}" -o "/tmp/${tarball}"
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "/tmp/${tarball}"
  rm -f "/tmp/${tarball}"
  cat > /etc/profile.d/go.sh <<'EOF'
export PATH=$PATH:/usr/local/go/bin
EOF
  chmod 644 /etc/profile.d/go.sh
  export PATH="$PATH:/usr/local/go/bin"
  log "установлен $(go version)"
}
install_go
ensure_path_go

# ---- k6 ----
install_k6_pkg() {
  if [ "$INSTALL_K6" != yes ]; then
    warn "пропускаю k6 (фазы C/D недоступны)"
    return
  fi
  if command -v k6 >/dev/null 2>&1; then
    log "k6 уже установлен: $(k6 version 2>/dev/null | head -1)"
    return
  fi

  log "устанавливаю k6"
  mkdir -p /usr/share/keyrings
  retry 3 5 curl -fsSL https://dl.k6.io/key.gpg | gpg --dearmor -o /usr/share/keyrings/k6-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" \
    > /etc/apt/sources.list.d/k6.list
  apt-get update -y
  apt-get install -y k6
  log "k6: $(k6 version 2>/dev/null | head -1)"
}
install_k6_pkg

# ---- Docker (опционально, для monitor.sh) ----
install_docker_cli() {
  if [ "$INSTALL_DOCKER" != yes ]; then
    return
  fi
  if command -v docker >/dev/null 2>&1; then
    log "Docker уже установлен: $(docker --version)"
    return
  fi

  log "устанавливаю Docker"
  retry 3 5 curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker 2>/dev/null || true
  log "Docker: $(docker --version)"
}
install_docker_cli

# ---- репозиторий: локальный или clone ----
detect_local_repo() {
  local candidate
  candidate="$(cd "$SCRIPT_DIR/../.." && pwd)"
  if [ -f "$candidate/loadtest/run.sh" ] && [ -f "$candidate/loadtest/gen/go.mod" ]; then
    echo "$candidate"
    return 0
  fi
  return 1
}

install_repo() {
  local local_repo=""
  local_repo="$(detect_local_repo || true)"

  if [ -n "$local_repo" ] && [ "$(readlink -f "$local_repo" 2>/dev/null || echo "$local_repo")" = "$(readlink -f "$INSTALL_DIR" 2>/dev/null || echo "$INSTALL_DIR")" ]; then
    log "установка из текущего каталога: $INSTALL_DIR"
    return
  fi

  if [ -n "$local_repo" ]; then
    log "копирую локальный репозиторий: $local_repo -> $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    rsync -a --delete \
      --exclude '.git' \
      --exclude 'loadtest/gen/loadgen' \
      "$local_repo/" "$INSTALL_DIR/"
    return
  fi

  if [ -d "$INSTALL_DIR/.git" ]; then
    log "обновляю репозиторий: $INSTALL_DIR (ветка $REPO_BRANCH)"
    git -C "$INSTALL_DIR" fetch origin "$REPO_BRANCH"
    git -C "$INSTALL_DIR" checkout "$REPO_BRANCH"
    git -C "$INSTALL_DIR" pull --ff-only origin "$REPO_BRANCH"
  else
    log "клонирую $REPO_URL (ветка $REPO_BRANCH) -> $INSTALL_DIR"
    rm -rf "$INSTALL_DIR"
    retry 3 5 git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$INSTALL_DIR"
  fi
}
install_repo

# ---- samples ----
sync_samples() {
  if [ "$SKIP_SYNC" = yes ]; then
    warn "пропускаю sync-samples (SKIP_SYNC=yes)"
    return
  fi
  local sync_script="$INSTALL_DIR/loadtest/scripts/sync-samples.sh"
  if [ ! -f "$sync_script" ]; then
    warn "sync-samples.sh не найден"
    return
  fi
  log "синхронизирую samples.go из network_monitor"
  if bash "$sync_script"; then
    log "samples синхронизированы"
  else
    warn "sync-samples завершился с ошибкой — проверь сеть и репозиторий network_monitor"
  fi
}
sync_samples

# ---- права и сборка ----
prepare_project() {
  log "настраиваю проект"
  find "$INSTALL_DIR" -type f -name '*.sh' -exec chmod +x {} \;

  local gen_dir="$INSTALL_DIR/loadtest/gen"
  if [ ! -f "$gen_dir/go.mod" ]; then
    die "не найден $gen_dir/go.mod — репозиторий установлен неполностью"
  fi

  log "собираю генератор нагрузки"
  ( cd "$gen_dir" && go build -o loadgen . )
  log "бинарник: $gen_dir/loadgen"

  log "проверяю тесты генератора"
  if ( cd "$gen_dir" && go test ./... ); then
    log "тесты генератора прошли"
  else
    warn "тесты генератора не прошли — нагрузка может работать некорректно"
  fi
}
prepare_project

# ---- конфигурация по умолчанию ----
write_config() {
  local ip base url
  ip="$(detect_primary_ip)"

  if [ -z "$TARGET_BASE" ]; then
    TARGET_BASE="http://${ip}"
  fi
  if [ -z "$TARGET_URL" ]; then
    TARGET_URL="${TARGET_BASE%/}/api/ingest"
  fi

  log "конфигурация: TARGET_URL=$TARGET_URL TARGET_BASE=$TARGET_BASE"

  cat > /etc/default/loadtest-for-network_monitor <<EOF
# Сгенерировано установщиком $(date -Is)
# Переопредели здесь URL целевого network_monitor.
INSTALL_DIR="$INSTALL_DIR"
TARGET_URL="$TARGET_URL"
TARGET_BASE="$TARGET_BASE"
URL="\$TARGET_URL"
BASE="\$TARGET_BASE"
CH_CONTAINER="$CH_CONTAINER"
INTERVAL=5
EOF
  chmod 644 /etc/default/loadtest-for-network_monitor
}
write_config

# ---- команды в PATH ----
install_cli_wrappers() {
  log "устанавливаю команды loadtest-run и loadtest-monitor в /usr/local/bin"

  cat > /usr/local/bin/loadtest-run <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
[ -f /etc/default/loadtest-for-network_monitor ] && . /etc/default/loadtest-for-network_monitor
INSTALL_DIR="${INSTALL_DIR:-/opt/loadtest-for-network_monitor}"
export URL="${URL:-${TARGET_URL:-http://127.0.0.1/api/ingest}}"
export BASE="${BASE:-${TARGET_BASE:-http://127.0.0.1}}"
cd "$INSTALL_DIR/loadtest"
exec ./run.sh "$@"
EOF

  cat > /usr/local/bin/loadtest-monitor <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
[ -f /etc/default/loadtest-for-network_monitor ] && . /etc/default/loadtest-for-network_monitor
INSTALL_DIR="${INSTALL_DIR:-/opt/loadtest-for-network_monitor}"
export CH_CONTAINER="${CH_CONTAINER:-clickhouse}"
export INTERVAL="${INTERVAL:-5}"
cd "$INSTALL_DIR/loadtest"
exec ./monitor/monitor.sh
EOF

  cat > /usr/local/bin/loadtest-status <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
INSTALL_DIR="${INSTALL_DIR:-/opt/loadtest-for-network_monitor}"
MANIFEST="$INSTALL_DIR/.install-manifest"
CONFIG=/etc/default/loadtest-for-network_monitor

echo "=== loadtest-for-network_monitor ==="
[ -f "$MANIFEST" ] && cat "$MANIFEST"
echo
[ -f "$CONFIG" ] && grep -E '^(TARGET_|INSTALL_|CH_)' "$CONFIG" 2>/dev/null || true
echo
command -v go >/dev/null && echo "Go:    $(go version)"
command -v k6 >/dev/null && echo "k6:    $(k6 version 2>/dev/null | head -1)"
command -v docker >/dev/null && echo "Docker: $(docker --version)"
[ -x "$INSTALL_DIR/loadtest/gen/loadgen" ] && echo "loadgen: OK ($INSTALL_DIR/loadtest/gen/loadgen)" || echo "loadgen: MISSING"
EOF

  chmod 755 /usr/local/bin/loadtest-run /usr/local/bin/loadtest-monitor /usr/local/bin/loadtest-status
}
install_cli_wrappers

# ---- манифест и проверка ----
write_manifest() {
  cat > "$MANIFEST" <<EOF
installed_at=$(date -Is)
install_dir=$INSTALL_DIR
repo_url=$REPO_URL
repo_branch=$REPO_BRANCH
go_version=$(go version 2>/dev/null || echo unknown)
k6_installed=$([ "$INSTALL_K6" = yes ] && echo yes || echo no)
docker_installed=$([ "$INSTALL_DOCKER" = yes ] && echo yes || echo no)
os=${OS_ID} ${OS_VERSION}
arch=$ARCH
log_file=$LOG_FILE
EOF
}
write_manifest

verify_install() {
  log "проверка установки"
  local ok=yes

  [ -x "$INSTALL_DIR/loadtest/run.sh" ]            || { warn "нет run.sh"; ok=no; }
  [ -x "$INSTALL_DIR/loadtest/gen/loadgen" ]       || { warn "нет loadgen"; ok=no; }
  [ -x /usr/local/bin/loadtest-run ]               || { warn "нет loadtest-run"; ok=no; }
  [ -f /etc/default/loadtest-for-network_monitor ] || { warn "нет конфига"; ok=no; }

  if [ -x "$INSTALL_DIR/loadtest/gen/loadgen" ]; then
    log "loadgen: бинарник собран и исполняемый"
  fi

  if [ "$ok" = yes ]; then
    log "все проверки пройдены"
  else
    warn "установка завершена с предупреждениями — см. $LOG_FILE"
  fi
}
verify_install

# ---- итог ----
PRIMARY_IP="$(detect_primary_ip)"
cat <<EOF

$(log "установка завершена")

Каталог:     $INSTALL_DIR
Конфиг:      /etc/default/loadtest-for-network_monitor
Лог:         $LOG_FILE
Статус:      loadtest-status

Цель по умолчанию (отредактируй /etc/default/loadtest-for-network_monitor):
  TARGET_URL=$TARGET_URL
  TARGET_BASE=$TARGET_BASE

Быстрый старт:
  loadtest-monitor          # мониторинг ClickHouse (нужен Docker + контейнер $CH_CONTAINER)
  loadtest-run B            # фаза B — ramp ingest
  loadtest-run C            # read-нагрузка (k6)
  loadtest-run help         # все фазы

Или вручную:
  cd $INSTALL_DIR/loadtest
  URL=$TARGET_URL BASE=$TARGET_BASE ./run.sh B

Если network_monitor на другом хосте — укажи при установке:
  sudo ./install.sh --target-url http://MONITOR_IP/api/ingest --target-base http://MONITOR_IP

Обнаружен IP этой машины: $PRIMARY_IP
EOF
