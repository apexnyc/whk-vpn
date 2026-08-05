#!/usr/bin/env bash
# Creates an Azure VM prepared for the AmneziaVPN desktop client.
# This script does NOT install any VPN software -- Amnezia's client does
# that over SSH, because it has no headless mode.
set -euo pipefail

REPO_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
# shellcheck source=../lib/common.sh
source "$REPO_ROOT/lib/common.sh"

require_cmd az
require_cmd curl
require_az_login
load_config "$REPO_ROOT/config.env"

: "${VM_SIZE:=Standard_B1s}"
: "${OS_DISK_SIZE_GB:=32}"
: "${OS_DISK_SKU:=StandardSSD_LRS}"
: "${IMAGE_URN:=Canonical:ubuntu-24_04-lts:server:latest}"
: "${XRAY_PORT:=443}"

IP_NAME="${VM_NAME}-ip"
NSG_NAME="${VM_NAME}-nsg"

if [[ -z "${SSH_ALLOWED_IP:-}" ]]; then
  SSH_ALLOWED_IP="$(detect_public_ip)"
  log_info "detected your public IP as $SSH_ALLOWED_IP"
else
  validate_ipv4 "$SSH_ALLOWED_IP" || die "SSH_ALLOWED_IP '$SSH_ALLOWED_IP' is not a valid IPv4 address"
fi

if az vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" >/dev/null 2>&1; then
  log_warn "VM '$VM_NAME' already exists in '$RESOURCE_GROUP' -- nothing to create."
  log_warn "Run scripts/destroy.sh first if you want a clean rebuild."
  exit 0
fi

log_info "creating resource group '$RESOURCE_GROUP' in '$LOCATION'"
az group create -n "$RESOURCE_GROUP" -l "$LOCATION" --output none

ADMIN_PASSWORD="$(generate_password)"

log_info "creating VM '$VM_NAME' ($VM_SIZE, $OS_DISK_SIZE_GB GB $OS_DISK_SKU)"
az vm create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --location "$LOCATION" \
  --image "$IMAGE_URN" \
  --size "$VM_SIZE" \
  --admin-username "$ADMIN_USER" \
  --admin-password "$ADMIN_PASSWORD" \
  --authentication-type password \
  --os-disk-size-gb "$OS_DISK_SIZE_GB" \
  --storage-sku "$OS_DISK_SKU" \
  --public-ip-address "$IP_NAME" \
  --public-ip-sku Standard \
  --public-ip-address-allocation static \
  --nsg "$NSG_NAME" \
  --nsg-rule NONE \
  --custom-data "$REPO_ROOT/cloud-init/swap.yaml" \
  --output none

PUBLIC_IP="$(az network public-ip show -g "$RESOURCE_GROUP" -n "$IP_NAME" --query ipAddress -o tsv)"
IMAGE_EXACT="$(az vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" \
  --query storageProfile.imageReference.exactVersion -o tsv)"

log_info "VM created. Public IP: $PUBLIC_IP  (image $IMAGE_EXACT)"
