#!/usr/bin/env bash
# Shared helpers for whk-vpn provisioning scripts.
# Contains only logic that does not call Azure, so it can be unit-tested.

generate_password() {
  # Azure requires 12-123 characters with at least three of four character
  # classes. We require all four and 32 characters, then reject and retry
  # any candidate that happens to miss a class.
  local pw
  while :; do
    pw="$(LC_ALL=C tr -dc 'A-Za-z0-9@#%^*_+=-' < /dev/urandom | head -c 32)"
    if [[ "$pw" =~ [a-z] ]] && [[ "$pw" =~ [A-Z] ]] \
       && [[ "$pw" =~ [0-9] ]] && [[ "$pw" =~ [@#%^*_+=-] ]]; then
      printf '%s' "$pw"
      return 0
    fi
  done
}

validate_port() {
  local port="${1:-}"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  (( 10#$port >= 1024 && 10#$port <= 65535 )) || return 1
  # 51820 is WireGuard's registered port. Every prior deployment exposed it
  # and was identified by port scan before any packet was inspected.
  (( 10#$port == 51820 )) && return 1
  return 0
}

validate_ipv4() {
  local ip="${1:-}" octet
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  for octet in ${ip//./ }; do
    (( 10#$octet >= 0 && 10#$octet <= 255 )) || return 1
  done
  return 0
}

log_info()  { printf '[INFO]  %s\n'  "$*" >&2; }
log_warn()  { printf '[WARN]  %s\n'  "$*" >&2; }
log_error() { printf '[ERROR] %s\n'  "$*" >&2; }

die() { log_error "$*"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_az_login() {
  az account show >/dev/null 2>&1 \
    || die "not logged in to Azure. Run: az login"
}

detect_public_ip() {
  local ip
  ip="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  validate_ipv4 "$ip" || die "could not determine your public IP; set SSH_ALLOWED_IP in config.env"
  printf '%s' "$ip"
}

load_config() {
  local path="${1:-}"
  [[ -f "$path" ]] || die "config file not found: $path (copy config.env.example)"
  # shellcheck disable=SC1090
  source "$path"

  local var
  for var in RESOURCE_GROUP LOCATION VM_NAME ADMIN_USER AMNEZIAWG_PORT; do
    [[ -n "${!var:-}" ]] || die "config.env is missing required setting: $var"
  done

  validate_port "$AMNEZIAWG_PORT" \
    || die "AMNEZIAWG_PORT '$AMNEZIAWG_PORT' is invalid. Use 1024-65535, and not 51820."
  return 0
}
