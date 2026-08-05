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
