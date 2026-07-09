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

script_dir() {
  local src="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
  cd "$(dirname "$src")" && pwd
}
