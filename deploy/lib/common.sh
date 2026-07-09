#!/usr/bin/env bash
# Общие функции для install/uninstall.
# shellcheck shell=bash

set -euo pipefail

log()  { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
die()  { echo -e "\033[1;31m[x]\033[0m $*" >&2; exit 1; }
info() { echo -e "\033[1;36m[i]\033[0m $*"; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "запусти от root: sudo $0"
}

retry() {
  local attempts="${1:-3}"
  local delay="${2:-5}"
  shift 2
  local n=1
  until "$@"; do
    if [ "$n" -ge "$attempts" ]; then
      return 1
    fi
    warn "повтор $n/$attempts через ${delay}s: $*"
    sleep "$delay"
    n=$((n + 1))
  done
}

detect_os() {
  . /etc/os-release 2>/dev/null || true
  export OS_ID="${ID:-unknown}"
  export OS_VERSION="${VERSION_ID:-}"
  case "$OS_ID" in
    ubuntu|debian) export OS_FAMILY=debian ;;
    *) export OS_FAMILY=unknown ;;
  esac
}

detect_arch() {
  if command -v dpkg >/dev/null 2>&1; then
    ARCH="$(dpkg --print-architecture)"
  else
    ARCH="$(uname -m)"
  fi
  case "$ARCH" in
    amd64|x86_64) GO_ARCH=amd64 ;;
    arm64|aarch64) GO_ARCH=arm64 ;;
    *) die "неподдерживаемая архитектура: $ARCH" ;;
  esac
  export ARCH GO_ARCH
}

detect_primary_ip() {
  local ip=""
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')" || true
  if [ -z "$ip" ]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')" || true
  fi
  echo "${ip:-127.0.0.1}"
}

ensure_path_go() {
  if [ -x /usr/local/go/bin/go ]; then
    export PATH="$PATH:/usr/local/go/bin"
  fi
}

# Установка k6: apt (dl.k6.io) -> GitHub releases -> пропуск с предупреждением.
# Не прерывает установку при сбое сети.
install_k6() {
  local want="${1:-yes}"
  local version="${K6_VERSION:-2.0.0}"

  if [ "$want" != yes ]; then
    warn "пропускаю k6 (фазы C/D недоступны)"
    return 0
  fi
  if command -v k6 >/dev/null 2>&1; then
    log "k6 уже установлен: $(k6 version 2>/dev/null | head -1)"
    return 0
  fi

  log "устанавливаю k6 (версия ${version})"

  if _install_k6_apt; then
    log "k6: $(k6 version 2>/dev/null | head -1)"
    return 0
  fi

  warn "репозиторий dl.k6.io недоступен — пробую скачать с GitHub"
  _cleanup_k6_apt_repo

  if _install_k6_github "$version"; then
    log "k6: $(k6 version 2>/dev/null | head -1)"
    return 0
  fi

  warn "k6 не удалось установить (таймаут сети или блокировка CDN)"
  warn "основные фазы A/B/E/F/G работают без k6; фазы C/D (read) — нет"
  warn "установи позже вручную: curl -L https://github.com/grafana/k6/releases/download/v${version}/k6-v${version}-linux-${GO_ARCH}.tar.gz | tar xz && sudo cp k6-v${version}-linux-${GO_ARCH}/k6 /usr/local/bin/"
  return 0
}

_install_k6_apt() {
  set +e
  mkdir -p /usr/share/keyrings
  if ! retry 3 5 curl -fsSL --connect-timeout 20 --max-time 60 \
      https://dl.k6.io/key.gpg | gpg --dearmor -o /usr/share/keyrings/k6-archive-keyring.gpg; then
    set -e
    return 1
  fi
  echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" \
    > /etc/apt/sources.list.d/k6.list
  apt-get update -y
  local n=1
  local ok=1
  while [ "$n" -le 3 ]; do
    if apt-get install -y -o Acquire::Retries=3 k6; then
      ok=0
      break
    fi
    warn "apt install k6: попытка $n/3 не удалась"
    sleep 10
    n=$((n + 1))
  done
  set -e
  return "$ok"
}

_install_k6_github() {
  local version="$1"
  local tarball="k6-v${version}-linux-${GO_ARCH}.tar.gz"
  local url="https://github.com/grafana/k6/releases/download/v${version}/${tarball}"
  local tmpdir bin

  tmpdir="$(mktemp -d)"
  if ! retry 3 15 curl -fsSL --connect-timeout 30 --max-time 600 \
      "$url" -o "$tmpdir/$tarball"; then
    rm -rf "$tmpdir"
    return 1
  fi
  if ! tar -xzf "$tmpdir/$tarball" -C "$tmpdir"; then
    rm -rf "$tmpdir"
    return 1
  fi
  bin="$(find "$tmpdir" -type f -name k6 | head -1)"
  if [ -z "$bin" ] || [ ! -f "$bin" ]; then
    rm -rf "$tmpdir"
    return 1
  fi
  install -m 755 "$bin" /usr/local/bin/k6
  rm -rf "$tmpdir"
  return 0
}

_cleanup_k6_apt_repo() {
  rm -f /etc/apt/sources.list.d/k6.list
  rm -f /usr/share/keyrings/k6-archive-keyring.gpg
  apt-get update -y 2>/dev/null || true
}

script_dir() {
  local src="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
  cd "$(dirname "$src")" && pwd
}
