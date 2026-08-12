#!/usr/bin/env bash
# vpn.sh — Unified CLI manager for censorship-resistant Azure VPN endpoints.
#
# Engine Options:
#   --engine amneziawg (default): Obfuscated AmneziaWG VPN (~30s deploy, beats GFW DPI)
#   --engine algo               : Legacy standard Algo WireGuard (~10-15m deploy)
#
# Usage:
#   vpn.sh create [--engine amneziawg|algo] [country|region]
#   vpn.sh replace [--engine amneziawg|algo] [country|region]
#   vpn.sh inspect [country|region|vm-name]
#   vpn.sh list
#   vpn.sh destroy <vm-name> [--yes]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  vpn create [--engine amneziawg|algo] [country|region]
  vpn replace [--engine amneziawg|algo] [country|region]
  vpn inspect [country|region|vm-name]
  vpn rotate-ip [country|region|vm-name]
  vpn qr [country|region|vm-name] [device]
  vpn list
  vpn destroy <vm-name> [--yes]

Examples:
  vpn create japan
  vpn create korea
  vpn create singapore
  vpn create hongkong
  vpn create germany
  vpn create france
  vpn create netherlands
  vpn create canada
  vpn create usa
  vpn create uk
  vpn create australia
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
    require_az_login
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
    elif [[ -n "$TARGET" ]]; then
      region_to_params "$TARGET" "awg-vpn-"
      awg_vm="$VM_NAME"
      region_to_params "$TARGET" "algo-vpn-"
      algo_vm="$VM_NAME"

      if az vm show -g "$RESOURCE_GROUP" -n "$awg_vm" >/dev/null 2>&1; then
        exec "$SCRIPT_DIR/amnezia-vpn.sh" inspect "$awg_vm"
      elif az vm show -g "$RESOURCE_GROUP" -n "$algo_vm" >/dev/null 2>&1; then
        exec "$SCRIPT_DIR/algo-vpn.sh" inspect "$algo_vm"
      else
        exec "$SCRIPT_DIR/amnezia-vpn.sh" inspect "$TARGET"
      fi
    else
      exec "$SCRIPT_DIR/amnezia-vpn.sh" inspect ""
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
