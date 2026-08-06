#!/usr/bin/env bash
# Provisions an Azure VM and runs a fully unattended Algo VPN install on it
# (apexnyc/algo-vpn -- a fork of trailofbits/algo patched to skip every
# interactive prompt and stream its generated client configs back over
# stdout), then extracts those configs into ./configs locally.
#
# This deliberately does NOT reuse lib/common.sh's load_config/validate_port:
# those enforce AmneziaWG-era rules (e.g. rejecting port 51820) that do not
# apply here -- Algo's WireGuard listener is meant to be 51820.
set -euo pipefail

REPO_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
# shellcheck source=../lib/common.sh
source "$REPO_ROOT/lib/common.sh"

# --- configuration -------------------------------------------------------
RESOURCE_GROUP="${ALGO_RESOURCE_GROUP:-kwang-vpn}"
LOCATION="${ALGO_LOCATION:-eastus}"
VM_NAME="${ALGO_VM_NAME:-algo-vpn-us-east}"
ADMIN_USER="${ALGO_ADMIN_USER:-kwang7}"
VM_SIZE="Standard_B1s"
IMAGE="Canonical:ubuntu-24_04-lts:server:24.04.202608020"
ALGO_REPO="https://github.com/apexnyc/algo-vpn.git"
WIREGUARD_PORT=51820
# ---------------------------------------------------------------------------

require_cmd az
require_cmd ssh
require_cmd base64
require_cmd tar
require_az_login

MY_IP="$(detect_public_ip)"
log_info "operator public IP: $MY_IP"

log_info "ensuring resource group '$RESOURCE_GROUP' exists in $LOCATION"
az group create -n "$RESOURCE_GROUP" -l "$LOCATION" --tags managed-by=whk-vpn -o none

# Azure gates disabling Trusted Launch (security-type Standard) behind a
# subscription-level feature flag. Registration is one-time and idempotent;
# skip it once already registered so reruns don't pay a propagation delay.
FEATURE_STATE="$(az feature show --namespace Microsoft.Compute --name UseStandardSecurityType --query "properties.state" -o tsv 2>/dev/null || true)"
if [[ "$FEATURE_STATE" != "Registered" ]]; then
  log_info "registering UseStandardSecurityType feature (one-time, can take several minutes)"
  az feature register --namespace Microsoft.Compute --name UseStandardSecurityType -o none
  for _ in $(seq 1 40); do
    FEATURE_STATE="$(az feature show --namespace Microsoft.Compute --name UseStandardSecurityType --query "properties.state" -o tsv)"
    [[ "$FEATURE_STATE" == "Registered" ]] && break
    sleep 15
  done
  [[ "$FEATURE_STATE" == "Registered" ]] || die "UseStandardSecurityType feature did not register in time"
  az provider register -n Microsoft.Compute -o none
fi

if az vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" >/dev/null 2>&1; then
  log_info "VM '$VM_NAME' already exists -- reusing it"
else
  log_info "creating VM '$VM_NAME' in $LOCATION ($VM_SIZE)"
  az vm create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --location "$LOCATION" \
    --size "$VM_SIZE" \
    --image "$IMAGE" \
    --security-type Standard \
    --os-disk-size-gb 30 \
    --storage-sku Standard_LRS \
    --public-ip-sku Standard \
    --public-ip-address-allocation static \
    --admin-username "$ADMIN_USER" \
    --generate-ssh-keys \
    -o none
fi

VM_IP="$(az vm show -d -g "$RESOURCE_GROUP" -n "$VM_NAME" --query publicIps -o tsv)"
[[ -n "$VM_IP" ]] || die "could not resolve VM public IP"
log_info "VM public IP: $VM_IP"

NSG_NAME="$(az network nsg list -g "$RESOURCE_GROUP" --query "[?contains(name, '$VM_NAME')].name | [0]" -o tsv)"
[[ -n "$NSG_NAME" ]] || die "could not find the NSG auto-created for $VM_NAME"

SSH_RULE="$(az network nsg rule list -g "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" --query "[?destinationPortRange=='22'].name | [0]" -o tsv)"
if [[ -n "$SSH_RULE" ]]; then
  az network nsg rule update -g "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" -n "$SSH_RULE" --source-address-prefixes "$MY_IP" -o none
  log_info "SSH rule '$SSH_RULE' restricted to $MY_IP"
fi

if ! az network nsg rule show -g "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" -n Port_51820 >/dev/null 2>&1; then
  az network nsg rule create -g "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" -n Port_51820 \
    --priority 310 --access Allow --direction Inbound --protocol '*' \
    --source-address-prefixes '*' --source-port-ranges '*' \
    --destination-address-prefixes '*' --destination-port-ranges "$WIREGUARD_PORT" -o none
  log_info "Port_51820 rule created (Any protocol, source Any)"
fi

log_info "waiting for SSH to become reachable"
for _ in $(seq 1 30); do
  ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes "$ADMIN_USER@$VM_IP" "echo ok" >/dev/null 2>&1 && break
  sleep 10
done
ssh -o BatchMode=yes -o ConnectTimeout=5 "$ADMIN_USER@$VM_IP" "echo ok" >/dev/null 2>&1 \
  || die "SSH never became reachable on $VM_IP"

log_info "running unattended install on $VM_IP (this can take 10-20 min)"
set +e
REMOTE_OUTPUT="$(ssh -o StrictHostKeyChecking=accept-new "$ADMIN_USER@$VM_IP" '
  set -e
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  if [ ! -d algo-vpn ]; then
    sudo -E apt-get update
    sudo -E apt-get -y upgrade
    git clone '"$ALGO_REPO"' algo-vpn
    sudo apt install -y --no-install-recommends python3-virtualenv
  fi
  cd algo-vpn
  if [ ! -x .env/bin/ansible-playbook ]; then
    python3 -m virtualenv --python="$(command -v python3)" .env
    source .env/bin/activate
    python3 -m pip install -U pip virtualenv
    python3 -m pip install -r requirements.txt
  else
    source .env/bin/activate
  fi
  ./algo
')"
SSH_STATUS=$?
set -e

if [[ $SSH_STATUS -ne 0 ]]; then
  printf '%s\n' "$REMOTE_OUTPUT" | tail -60
  die "remote install failed (ssh exit $SSH_STATUS) -- see output above"
fi

printf '%s\n' "$REMOTE_OUTPUT" | grep -v '^===ALGO_CONFIGS' | tail -40

CONFIG_DIR="$(printf '%s\n' "$REMOTE_OUTPUT" | grep -o '===ALGO_CONFIGS_BEGIN:[^=]*===' | sed -E 's/===ALGO_CONFIGS_BEGIN:(.*)===/\1/')"
[[ -n "$CONFIG_DIR" ]] || die "install finished but no config blob was found in the output -- check the log above"

log_info "extracting configs for $CONFIG_DIR"
mkdir -p "$REPO_ROOT/configs"
printf '%s\n' "$REMOTE_OUTPUT" \
  | sed -n '/===ALGO_CONFIGS_BEGIN/,/===ALGO_CONFIGS_END===/p' \
  | sed '1d;$d' \
  | base64 -d \
  | tar xzf - -C "$REPO_ROOT/configs"

log_info "done -- VM_IP=$VM_IP"
log_info "configs at $REPO_ROOT/configs/$CONFIG_DIR"
find "$REPO_ROOT/configs/$CONFIG_DIR" -type f | sort
