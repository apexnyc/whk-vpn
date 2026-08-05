#!/usr/bin/env bash
# Replaces the VM's public IP without touching the VM, its disk, its Docker
# containers, or any protocol keys.
#
# Use this when an address is blackholed at the border rather than the
# protocol being detected. The two are distinguished by testing SSH to the
# address from inside China: if SSH still connects, the IP is fine and the
# protocol signature is what is being matched -- rotating will not help.
set -euo pipefail

REPO_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
# shellcheck source=../lib/common.sh
source "$REPO_ROOT/lib/common.sh"

require_cmd az
require_az_login
load_config "$REPO_ROOT/config.env"

NEW_IP_NAME="${VM_NAME}-ip-$(date +%Y%m%d%H%M%S)"

az vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" >/dev/null 2>&1 \
  || die "VM '$VM_NAME' not found in '$RESOURCE_GROUP'"

NIC_ID="$(az vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" \
  --query "networkProfile.networkInterfaces[0].id" -o tsv)"
NIC_NAME="${NIC_ID##*/}"
IPCFG_NAME="$(az network nic show --ids "$NIC_ID" \
  --query "ipConfigurations[0].name" -o tsv)"

# Identify the currently-attached public IP by querying the NIC directly --
# never by a naming guess. Rotated addresses are timestamp-suffixed (see
# NEW_IP_NAME below), so after the first rotation a fixed "$VM_NAME-ip" name
# no longer matches what's actually attached; guessing wrong would silently
# leave the real old IP undeleted and billing forever.
OLD_IP_ID="$(az network nic show --ids "$NIC_ID" \
  --query "ipConfigurations[0].publicIPAddress.id" -o tsv)"
OLD_IP_NAME="${OLD_IP_ID##*/}"
OLD_IP="$(az network public-ip show --ids "$OLD_IP_ID" \
  --query ipAddress -o tsv 2>/dev/null || echo 'none')"

log_info "current address: $OLD_IP"

log_info "allocating a new static address"
az network public-ip create -g "$RESOURCE_GROUP" -n "$NEW_IP_NAME" \
  --sku Standard --allocation-method Static --location "$LOCATION" --output none

log_info "detaching the old address"
az network nic ip-config update -g "$RESOURCE_GROUP" \
  --nic-name "$NIC_NAME" -n "$IPCFG_NAME" --remove publicIPAddress --output none

log_info "attaching the new address"
az network nic ip-config update -g "$RESOURCE_GROUP" \
  --nic-name "$NIC_NAME" -n "$IPCFG_NAME" --public-ip-address "$NEW_IP_NAME" --output none

log_info "deleting the old address ($OLD_IP_NAME) so it stops billing"
if [[ -n "$OLD_IP_ID" ]]; then
  az network public-ip delete --ids "$OLD_IP_ID" --output none 2>/dev/null \
    || log_warn "failed to delete old public IP ($OLD_IP_NAME) -- check for orphan billing"
fi

NEW_IP="$(az network public-ip show -g "$RESOURCE_GROUP" -n "$NEW_IP_NAME" \
  --query ipAddress -o tsv)"

if [[ -f "$REPO_ROOT/.env" ]]; then
  sed -i '' "s|^VPN_PUBLIC_IP=.*|VPN_PUBLIC_IP=$NEW_IP|" "$REPO_ROOT/.env"
fi

cat <<BANNER

────────────────────────────────────────────────────────────
  Address rotated:  $OLD_IP  ->  $NEW_IP

  The VM, its containers, and all protocol keys are untouched.
  Update the endpoint in each client config to $NEW_IP.

  Note: SSH is still restricted to the operator IP recorded at
  provision time. If yours has changed, update the 'ssh' NSG rule.
────────────────────────────────────────────────────────────

BANNER
