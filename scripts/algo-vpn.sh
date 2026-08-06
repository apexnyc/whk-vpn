#!/usr/bin/env bash
# algo-vpn.sh — provision or tear down a censorship-resistant Algo VPN
# endpoint on Azure, one region at a time.
#
# Usage:
#   algo-vpn.sh create [uk|australia|usa]   # omit the region to pick interactively
#   algo-vpn.sh list                        # show live Algo VMs in the resource group
#   algo-vpn.sh destroy <vm-name> [--yes]   # tear down just that VM and its resources
#
# Uses apexnyc/algo-vpn (a fork of trailofbits/algo patched to run fully
# unattended and stream its generated client configs back over stdout) --
# see that repo's history for what's changed and why.
#
# On a machine that doesn't have the prerequisites yet, run
# scripts/setup-environment.sh first.
set -euo pipefail

REPO_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
RESOURCE_GROUP="kwang-vpn"
ADMIN_USER="kwang7"
VM_SIZE="Standard_B1s"
IMAGE="Canonical:ubuntu-24_04-lts:server:24.04.202608020"
ALGO_REPO="https://github.com/apexnyc/algo-vpn.git"
WIREGUARD_PORT=51820
CONFIGS_DIR="$REPO_ROOT/configs"

log_info()  { printf '[INFO]  %s\n'  "$*" >&2; }
log_warn()  { printf '[WARN]  %s\n'  "$*" >&2; }
log_error() { printf '[ERROR] %s\n'  "$*" >&2; }
die() { log_error "$*"; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1 (run scripts/setup-environment.sh)"; }

require_az_login() {
  az account show >/dev/null 2>&1 || die "not logged in to Azure. Run: az login"
}

detect_public_ip() {
  local ip
  ip="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "could not determine your public IP"
  printf '%s' "$ip"
}

usage() {
  cat >&2 <<'EOF'
Usage:
  algo-vpn.sh create [uk|australia|usa]
  algo-vpn.sh list
  algo-vpn.sh destroy <vm-name> [--yes]
EOF
  exit 1
}

region_to_params() {
  case "$1" in
    uk)        LOCATION="uksouth";       VM_NAME="algo-vpn-uk" ;;
    australia) LOCATION="australiaeast"; VM_NAME="algo-vpn-australia" ;;
    usa)       LOCATION="eastus";        VM_NAME="algo-vpn-usa" ;;
    *) die "unknown region '$1' -- choose uk, australia, or usa" ;;
  esac
}

prompt_region() {
  echo "Which region?" >&2
  echo "  1) UK        (uksouth)" >&2
  echo "  2) Australia (australiaeast)" >&2
  echo "  3) USA       (eastus)" >&2
  read -r -p "Enter 1-3: " choice
  case "$choice" in
    1) echo uk ;;
    2) echo australia ;;
    3) echo usa ;;
    *) die "invalid choice: $choice" ;;
  esac
}

cmd_create() {
  local region="${1:-}"
  [[ -n "$region" ]] || region="$(prompt_region)"
  region_to_params "$region"

  require_cmd az; require_cmd ssh; require_cmd curl; require_cmd base64; require_cmd tar
  require_az_login

  local my_ip
  my_ip="$(detect_public_ip)"
  log_info "operator public IP: $my_ip"

  log_info "ensuring resource group '$RESOURCE_GROUP' exists in $LOCATION"
  az group create -n "$RESOURCE_GROUP" -l "$LOCATION" --tags managed-by=whk-vpn -o none

  # Azure gates disabling Trusted Launch (security-type Standard) behind a
  # subscription-level feature flag. One-time and idempotent; skip once set.
  local feature_state
  feature_state="$(az feature show --namespace Microsoft.Compute --name UseStandardSecurityType --query "properties.state" -o tsv 2>/dev/null || true)"
  if [[ "$feature_state" != "Registered" ]]; then
    log_info "registering UseStandardSecurityType feature (one-time, can take several minutes)"
    az feature register --namespace Microsoft.Compute --name UseStandardSecurityType -o none
    for _ in $(seq 1 40); do
      feature_state="$(az feature show --namespace Microsoft.Compute --name UseStandardSecurityType --query "properties.state" -o tsv)"
      [[ "$feature_state" == "Registered" ]] && break
      sleep 15
    done
    [[ "$feature_state" == "Registered" ]] || die "UseStandardSecurityType feature did not register in time"
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

  local vm_ip
  vm_ip="$(az vm show -d -g "$RESOURCE_GROUP" -n "$VM_NAME" --query publicIps -o tsv)"
  [[ -n "$vm_ip" ]] || die "could not resolve VM public IP"
  log_info "VM public IP: $vm_ip"

  local nsg_name
  nsg_name="$(az network nsg list -g "$RESOURCE_GROUP" --query "[?contains(name, '$VM_NAME')].name | [0]" -o tsv)"
  [[ -n "$nsg_name" ]] || die "could not find the NSG auto-created for $VM_NAME"

  local ssh_rule
  ssh_rule="$(az network nsg rule list -g "$RESOURCE_GROUP" --nsg-name "$nsg_name" --query "[?destinationPortRange=='22'].name | [0]" -o tsv)"
  if [[ -n "$ssh_rule" ]]; then
    az network nsg rule update -g "$RESOURCE_GROUP" --nsg-name "$nsg_name" -n "$ssh_rule" --source-address-prefixes "$my_ip" -o none
    log_info "SSH rule '$ssh_rule' restricted to $my_ip"
  fi

  if ! az network nsg rule show -g "$RESOURCE_GROUP" --nsg-name "$nsg_name" -n Port_51820 >/dev/null 2>&1; then
    az network nsg rule create -g "$RESOURCE_GROUP" --nsg-name "$nsg_name" -n Port_51820 \
      --priority 310 --access Allow --direction Inbound --protocol '*' \
      --source-address-prefixes '*' --source-port-ranges '*' \
      --destination-address-prefixes '*' --destination-port-ranges "$WIREGUARD_PORT" -o none
    log_info "Port_51820 rule created (Any protocol, source Any)"
  fi

  log_info "waiting for SSH to become reachable"
  for _ in $(seq 1 30); do
    ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes "$ADMIN_USER@$vm_ip" "echo ok" >/dev/null 2>&1 && break
    sleep 10
  done
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$ADMIN_USER@$vm_ip" "echo ok" >/dev/null 2>&1 \
    || die "SSH never became reachable on $vm_ip"

  log_info "running unattended install on $vm_ip (this can take 10-20 min)"
  set +e
  local remote_output
  remote_output="$(ssh -o StrictHostKeyChecking=accept-new "$ADMIN_USER@$vm_ip" '
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
  local ssh_status=$?
  set -e

  if [[ $ssh_status -ne 0 ]]; then
    printf '%s\n' "$remote_output" | tail -60
    die "remote install failed (ssh exit $ssh_status) -- see output above"
  fi

  printf '%s\n' "$remote_output" | grep -v '^===ALGO_CONFIGS' | tail -40

  local config_dir
  config_dir="$(printf '%s\n' "$remote_output" | grep -o '===ALGO_CONFIGS_BEGIN:[^=]*===' | sed -E 's/===ALGO_CONFIGS_BEGIN:(.*)===/\1/')"
  [[ -n "$config_dir" ]] || die "install finished but no config blob was found in the output -- check the log above"

  log_info "extracting configs for $config_dir"
  mkdir -p "$CONFIGS_DIR"
  printf '%s\n' "$remote_output" \
    | sed -n '/===ALGO_CONFIGS_BEGIN/,/===ALGO_CONFIGS_END===/p' \
    | sed '1d;$d' \
    | base64 -d \
    | tar xzf - -C "$CONFIGS_DIR"

  ln -sfn "$config_dir" "$CONFIGS_DIR/$VM_NAME"
  log_info "done -- VM_NAME=$VM_NAME VM_IP=$vm_ip"
  log_info "configs at $CONFIGS_DIR/$VM_NAME -> $config_dir"
  find "$CONFIGS_DIR/$config_dir" -type f | sort
}

cmd_list() {
  require_cmd az; require_az_login
  az vm list -g "$RESOURCE_GROUP" -d --query "[].{name:name, ip:publicIps, location:location, state:powerState}" -o table
}

cmd_destroy() {
  local vm_name="${1:-}"
  local force="${2:-}"
  [[ -n "$vm_name" ]] || die "usage: $0 destroy <vm-name> [--yes]"

  require_cmd az; require_az_login

  az vm show -g "$RESOURCE_GROUP" -n "$vm_name" >/dev/null 2>&1 \
    || die "VM '$vm_name' not found in resource group '$RESOURCE_GROUP' (see: $0 list)"

  # Capture the disk name before deleting the VM -- the VM-to-disk link is
  # gone once the VM itself is deleted.
  local disk_name
  disk_name="$(az vm show -g "$RESOURCE_GROUP" -n "$vm_name" --query "storageProfile.osDisk.managedDisk.id" -o tsv | awk -F/ '{print $NF}')"

  log_warn "about to permanently delete VM '$vm_name' and its disk/NIC/public IP/NSG in '$RESOURCE_GROUP'"
  log_warn "other VMs in that resource group are not affected"
  if [[ "$force" != "--yes" ]]; then
    read -r -p "Type the VM name to confirm: " confirm
    [[ "$confirm" == "$vm_name" ]] || die "confirmation did not match -- aborted"
  fi

  log_info "deleting VM"
  az vm delete -g "$RESOURCE_GROUP" -n "$vm_name" --yes -o none

  log_info "deleting associated NIC/public IP/NSG/disk"
  local nic_name ip_name nsg_name
  nic_name="$(az network nic list -g "$RESOURCE_GROUP" --query "[?contains(name, '$vm_name')].name | [0]" -o tsv)"
  ip_name="$(az network public-ip list -g "$RESOURCE_GROUP" --query "[?contains(name, '$vm_name')].name | [0]" -o tsv)"
  nsg_name="$(az network nsg list -g "$RESOURCE_GROUP" --query "[?contains(name, '$vm_name')].name | [0]" -o tsv)"
  [[ -n "$nic_name" ]] && az network nic delete -g "$RESOURCE_GROUP" -n "$nic_name" -o none
  [[ -n "$ip_name" ]] && az network public-ip delete -g "$RESOURCE_GROUP" -n "$ip_name" -o none
  [[ -n "$nsg_name" ]] && az network nsg delete -g "$RESOURCE_GROUP" -n "$nsg_name" -o none
  [[ -n "$disk_name" ]] && az disk delete -g "$RESOURCE_GROUP" -n "$disk_name" --yes -o none

  # Drop the local friendly symlink and downloaded configs for this VM, if any.
  if [[ -L "$CONFIGS_DIR/$vm_name" ]]; then
    local target
    target="$(readlink "$CONFIGS_DIR/$vm_name")"
    rm -f "$CONFIGS_DIR/$vm_name"
    rm -rf "${CONFIGS_DIR:?}/$target"
    log_info "removed local configs for $vm_name ($target)"
  fi

  log_info "done. remaining VMs in '$RESOURCE_GROUP':"
  az vm list -g "$RESOURCE_GROUP" -o table
}

case "${1:-}" in
  create)  shift; cmd_create "${1:-}" ;;
  list)    cmd_list ;;
  destroy) shift; cmd_destroy "${1:-}" "${2:-}" ;;
  *) usage ;;
esac
