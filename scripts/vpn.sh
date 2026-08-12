#!/usr/bin/env bash
# vpn.sh — Unified CLI manager for censorship-resistant Azure VPN endpoints.
#
# Engine Options:
#   --engine amneziawg (default): Obfuscated AmneziaWG VPN (~30s deploy, beats GFW DPI)
#   --engine algo               : Legacy standard Algo WireGuard (~10-15m deploy)
#
# Usage:
#   vpn.sh create [--engine amneziawg|algo] [uk|australia|usa]
#   vpn.sh replace [--engine amneziawg|algo] [uk|australia|usa]
#   vpn.sh inspect [uk|australia|usa|vm-name]
#   vpn.sh list
#   vpn.sh destroy <vm-name> [--yes]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOURCE_GROUP="kwang-vpn"

log_info()  { printf '[INFO]  %s\n'  "$*" >&2; }
log_error() { printf '[ERROR] %s\n'  "$*" >&2; }
die() { log_error "$*"; exit 1; }

usage() {
  cat >&2 <<'EOF'
Usage:
  vpn create [--engine amneziawg|algo] [uk|australia|usa]
  vpn replace [--engine amneziawg|algo] [uk|australia|usa]
  vpn inspect [uk|australia|usa|vm-name]
  vpn list
  vpn destroy <vm-name> [--yes]
EOF
  exit 1
}

# Parse engine flag if provided
ENGINE="amneziawg"
ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine)
      ENGINE="${2:-}"
      shift 2
      ;;
    --engine=*)
      ENGINE="${1#*=}"
      shift
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

set -- "${ARGS[@]}"
CMD="${1:-}"
[[ -n "$CMD" ]] || usage
shift || true

case "$ENGINE" in
  amneziawg|awg) PROVISIONER="$SCRIPT_DIR/amnezia-vpn.sh" ;;
  algo|wireguard) PROVISIONER="$SCRIPT_DIR/algo-vpn.sh" ;;
  *) die "unknown engine '$ENGINE' -- expected amneziawg or algo" ;;
esac

case "$CMD" in
  create)
    exec "$PROVISIONER" create "${1:-}"
    ;;
  replace)
    exec "$PROVISIONER" replace "${1:-}"
    ;;
  list)
    az account show >/dev/null 2>&1 || die "not logged in to Azure. Run: az login"
    log_info "Listing all active VPN endpoints in resource group '$RESOURCE_GROUP':"
    az vm list -g "$RESOURCE_GROUP" -d --query "[].{name:name, ip:publicIps, location:location, state:powerState}" -o table
    ;;
  destroy)
    VM_NAME="${1:-}"
    [[ -n "$VM_NAME" ]] || die "usage: vpn destroy <vm-name> [--yes]"
    if [[ "$VM_NAME" =~ ^awg-vpn- ]]; then
      exec "$SCRIPT_DIR/amnezia-vpn.sh" destroy "$VM_NAME" "${2:-}"
    else
      exec "$SCRIPT_DIR/algo-vpn.sh" destroy "$VM_NAME" "${2:-}"
    fi
    ;;
  inspect|inspection)
    TARGET="${1:-}"
    if [[ "$TARGET" =~ ^awg-vpn- ]]; then
      exec "$SCRIPT_DIR/amnezia-vpn.sh" inspect "$TARGET"
    elif [[ "$TARGET" =~ ^algo-vpn- ]]; then
      exec "$SCRIPT_DIR/algo-vpn.sh" inspect "$TARGET"
    else
      # Check if VM exists in Azure to inspect appropriately
      if az vm show -g "$RESOURCE_GROUP" -n "awg-vpn-$TARGET" >/dev/null 2>&1; then
        exec "$SCRIPT_DIR/amnezia-vpn.sh" inspect "$TARGET"
      elif az vm show -g "$RESOURCE_GROUP" -n "algo-vpn-$TARGET" >/dev/null 2>&1; then
        exec "$SCRIPT_DIR/algo-vpn.sh" inspect "$TARGET"
      else
        # Default to AmneziaWG inspector
        exec "$SCRIPT_DIR/amnezia-vpn.sh" inspect "$TARGET"
      fi
    fi
    ;;
  qr|qrcode)
    exec "$SCRIPT_DIR/amnezia-vpn.sh" qr "${1:-}" "${2:-}"
    ;;
  rotate-ip|rotate)
    TARGET="${1:-}"
    if [[ "$TARGET" =~ ^algo-vpn- || "$ENGINE" == "algo" ]]; then
      exec "$SCRIPT_DIR/algo-vpn.sh" rotate-ip "$TARGET"
    else
      exec "$SCRIPT_DIR/amnezia-vpn.sh" replace "$TARGET"
    fi
    ;;
  *)
    usage
    ;;
esac
