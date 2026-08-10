#!/usr/bin/env bash
# algo-vpn.sh — provision or tear down a censorship-resistant Algo VPN
# endpoint on Azure, one region at a time.
#
# Usage:
#   algo-vpn.sh create [uk|australia|usa]   # omit the region to pick interactively
#   algo-vpn.sh replace [uk|australia|usa]  # tear down existing endpoint (if any) & recreate
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

RESOURCE_GROUP="kwang-vpn"
ADMIN_USER="kwang7"
VM_SIZE="Standard_B1s"
IMAGE="Canonical:ubuntu-24_04-lts:server:24.04.202608020"
ALGO_REPO="https://github.com/apexnyc/algo-vpn.git"
WIREGUARD_PORT=51820
CONFIGS_DIR="$HOME/Desktop/vpn"

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
  local services=(
    "https://api.ipify.org"
    "https://icanhazip.com"
    "https://ifconfig.me"
    "https://ipinfo.io/ip"
    "https://ident.me"
  )
  for svc in "${services[@]}"; do
    ip="$(curl -fsS --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      printf '%s' "$ip"
      return 0
    fi
  done
  die "could not determine your public IP"
}

usage() {
  cat >&2 <<'EOF'
Usage:
  algo-vpn.sh create [uk|australia|usa]
  algo-vpn.sh replace [uk|australia|usa]
  algo-vpn.sh rotate-ip [uk|australia|usa]
  algo-vpn.sh inspect [uk|australia|usa]
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
  remote_output="$(ssh -o StrictHostKeyChecking=accept-new "$ADMIN_USER@$vm_ip" "ALGO_REPO='$ALGO_REPO' bash -s" <<'EOF'
    set -e
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
    if [ ! -d algo-vpn ]; then
      sudo -E apt-get update
      sudo -E apt-get -y upgrade
      git clone "$ALGO_REPO" algo-vpn
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
EOF
)"
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

  # Convert legacy license_0..6 files to new device names if present
  if [[ -d "$CONFIGS_DIR/$config_dir/wireguard" ]]; then
    local devices=("mac" "ipad" "iphone" "windows" "android" "ios" "macmini")
    for idx in "${!devices[@]}"; do
      local dev="${devices[$idx]}"
      local old_base="license_${idx}"
      find "$CONFIGS_DIR/$config_dir" -type f -name "${old_base}.*" 2>/dev/null | while read -r old_file; do
        local ext="${old_file##*.}"
        local new_file="$(dirname "$old_file")/${config_dir}-${dev}.${ext}"
        mv "$old_file" "$new_file"
      done
    done
  fi

  find "$CONFIGS_DIR/$config_dir" -type f | sort

  # Automatically import config into WireGuard GUI on macOS if available
  local client_conf=""
  local vm_ip_prefix
  vm_ip_prefix="$(basename "$config_dir")"
  if [[ -f "$CONFIGS_DIR/$config_dir/wireguard/${vm_ip_prefix}-mac.conf" ]]; then
    client_conf="$CONFIGS_DIR/$config_dir/wireguard/${vm_ip_prefix}-mac.conf"
  elif [[ -f "$CONFIGS_DIR/$config_dir/wireguard/${vm_ip_prefix}-macmini.conf" ]]; then
    client_conf="$CONFIGS_DIR/$config_dir/wireguard/${vm_ip_prefix}-macmini.conf"
  elif [[ -f "$CONFIGS_DIR/$config_dir/wireguard/license_2.conf" ]]; then
    client_conf="$CONFIGS_DIR/$config_dir/wireguard/license_2.conf"
  elif [[ -f "$CONFIGS_DIR/$config_dir/wireguard/license_0.conf" ]]; then
    client_conf="$CONFIGS_DIR/$config_dir/wireguard/license_0.conf"
  else
    client_conf="$(find "$CONFIGS_DIR/$config_dir/wireguard" -name "*.conf" 2>/dev/null | head -n 1)"
  fi

  if [[ -n "$client_conf" && -d "/Applications/WireGuard.app" ]]; then
    log_info "importing $(basename "$client_conf") into WireGuard GUI..."
    osascript -e '
    on run argv
      set confPath to item 1 of argv
      tell application "WireGuard" to activate
      delay 0.5
      tell application "System Events"
        tell process "WireGuard"
          keystroke "o" using {command down}
          delay 1.0
          keystroke "g" using {command down, shift down}
          delay 1.0
          keystroke confPath
          delay 0.5
          keystroke return
          delay 0.8
          keystroke return
        end tell
      end tell
    end run' "$client_conf" >/dev/null 2>&1 || log_warn "could not auto-import into WireGuard GUI"
  fi

  echo
  echo "=================================================="
  echo " VPN ready: $VM_NAME  ($region / $LOCATION)"
  echo " IP address: $vm_ip"
  echo " Configs:    $CONFIGS_DIR/$VM_NAME"
  echo "=================================================="

  local ipad_conf=""
  if [[ -f "$CONFIGS_DIR/$config_dir/wireguard/${vm_ip_prefix}-ipad.conf" ]]; then
    ipad_conf="$CONFIGS_DIR/$config_dir/wireguard/${vm_ip_prefix}-ipad.conf"
  elif [[ -f "$CONFIGS_DIR/$config_dir/wireguard/license_1.conf" ]]; then
    ipad_conf="$CONFIGS_DIR/$config_dir/wireguard/license_1.conf"
  fi

  if command -v qrencode >/dev/null 2>&1 && [[ -n "${ipad_conf:-}" && -f "$ipad_conf" ]]; then
    echo
    echo "=================================================="
    echo " QR CODE FOR IPAD SCAN (Client Config: $(basename "$ipad_conf")):"
    echo "=================================================="
    qrencode -t ansiutf8 < "$ipad_conf"
  fi
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

cmd_inspect() {
  local target="${1:-}"
  require_cmd az; require_cmd ssh; require_cmd curl; require_az_login

  local vm_name="" region=""
  case "$target" in
    uk|australia|usa)
      region="$target"
      region_to_params "$region"
      vm_name="$VM_NAME"
      ;;
    algo-vpn-uk|algo-vpn-australia|algo-vpn-usa)
      vm_name="$target"
      region="${vm_name#algo-vpn-}"
      region_to_params "$region"
      ;;
    algo-vpn-*)
      vm_name="$target"
      region="${vm_name#algo-vpn-}"
      ;;
    "")
      log_info "No VM specified. Available VMs in resource group '$RESOURCE_GROUP':"
      cmd_list
      echo >&2
      read -r -p "Enter VM name or region (uk|australia|usa): " choice
      [[ -n "$choice" ]] || die "no VM specified"
      if [[ "$choice" =~ ^(uk|australia|usa)$ ]]; then
        region="$choice"
        region_to_params "$region"
        vm_name="$VM_NAME"
      else
        vm_name="$choice"
        region="${vm_name#algo-vpn-}"
      fi
      ;;
    *)
      vm_name="$target"
      region="${vm_name#algo-vpn-}"
      ;;
  esac

  log_info "Starting deep diagnostic inspection for '$vm_name'..."
  echo "================================================================================"
  echo " VPN DIAGNOSTIC INSPECTION REPORT: $vm_name"
  echo " Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "================================================================================"
  echo

  # 1. Azure Infrastructure Check
  echo "[1/4] Checking Azure Cloud Infrastructure & VM Status..."
  local vm_json
  vm_json="$(az vm show -d -g "$RESOURCE_GROUP" -n "$vm_name" -o json 2>/dev/null || true)"
  if [[ -z "$vm_json" ]]; then
    echo "  [FAIL] Azure VM '$vm_name' does not exist in resource group '$RESOURCE_GROUP'."
    echo
    echo "================================================================================"
    echo " [DIAGNOSIS] Virtual Machine Not Found"
    echo " Reason: No VM named '$vm_name' exists in Azure resource group '$RESOURCE_GROUP'."
    echo " [RECOMMENDATION] Create a new endpoint:"
    echo "   $0 create ${region:-uk}"
    echo "================================================================================"
    return 1
  fi

  local power_state vm_ip location nsg_name
  power_state="$(printf '%s' "$vm_json" | jq -r '.powerState // empty' 2>/dev/null || true)"
  vm_ip="$(printf '%s' "$vm_json" | jq -r '.publicIps // empty' 2>/dev/null || true)"
  location="$(printf '%s' "$vm_json" | jq -r '.location // empty' 2>/dev/null || true)"

  echo "  - Resource Group: $RESOURCE_GROUP"
  echo "  - Location:       ${location:-unknown}"
  echo "  - Public IP:       ${vm_ip:-none}"
  echo "  - Power State:     ${power_state:-unknown}"

  if [[ "$power_state" != "VM running" ]]; then
    echo "  [FAIL] VM is not running (Current state: $power_state)."
    echo
    echo "================================================================================"
    echo " [DIAGNOSIS] Virtual Machine Powered Off / Deallocated"
    echo " Reason: Azure VM '$vm_name' is not in 'VM running' state."
    echo " [RECOMMENDATION] Power on the VM using Azure CLI:"
    echo "   az vm start -g $RESOURCE_GROUP -n $vm_name"
    echo "================================================================================"
    return 1
  fi
  echo "  [OK] Azure VM power state is running."

  # Check NSG rules
  nsg_name="$(az network nsg list -g "$RESOURCE_GROUP" --query "[?contains(name, '$vm_name')].name | [0]" -o tsv 2>/dev/null || true)"
  local wg_nsg_rule="" ssh_allowed_ip="" ssh_rule_name=""
  if [[ -n "$nsg_name" ]]; then
    wg_nsg_rule="$(az network nsg rule show -g "$RESOURCE_GROUP" --nsg-name "$nsg_name" -n Port_51820 --query "access" -o tsv 2>/dev/null || true)"
    ssh_allowed_ip="$(az network nsg rule list -g "$RESOURCE_GROUP" --nsg-name "$nsg_name" --query "[?destinationPortRange=='22'].sourceAddressPrefix | [0]" -o tsv 2>/dev/null || true)"
    ssh_rule_name="$(az network nsg rule list -g "$RESOURCE_GROUP" --nsg-name "$nsg_name" --query "[?destinationPortRange=='22'].name | [0]" -o tsv 2>/dev/null || true)"
  fi
  echo "  - NSG Rule (Port 51820 UDP): ${wg_nsg_rule:-Allow}"
  echo "  - NSG SSH Whitelist (Port 22): ${ssh_allowed_ip:-unknown}"
  echo

  # 2. Local Network & Edge Reachability
  echo "[2/4] Checking Local Operator Network & Edge Reachability..."
  local my_ip
  my_ip="$(detect_public_ip)"
  echo "  - Current Operator Public IP: $my_ip"

  if [[ -n "$ssh_allowed_ip" && "$ssh_allowed_ip" != "$my_ip" && "$ssh_allowed_ip" != "*" ]]; then
    echo "  [WARN] Operator public IP changed (Current: $my_ip vs NSG Whitelist: $ssh_allowed_ip)."
    echo "         Updating NSG SSH rule to allow remote inspection..."
    if [[ -n "$ssh_rule_name" ]]; then
      az network nsg rule update -g "$RESOURCE_GROUP" --nsg-name "$nsg_name" -n "$ssh_rule_name" --source-address-prefixes "$my_ip" -o none 2>/dev/null || true
      echo "  [OK] Updated NSG SSH rule '$ssh_rule_name' to $my_ip."
    fi
  else
    echo "  [OK] Operator SSH whitelist is aligned."
  fi

  # ICMP Ping Probe
  echo -n "  - Testing ICMP Ping to $vm_ip... "
  local ping_out loss_rate
  ping_out="$(ping -c 4 -W 2000 "$vm_ip" 2>&1 || true)"
  loss_rate="$(printf '%s\n' "$ping_out" | grep -o '[0-9.]*% packet loss' | awk '{print $1}' || echo "100%")"
  if [[ "$loss_rate" == "0%" || "$loss_rate" == "0.0%" ]]; then
    echo "[OK] (0% loss)"
  elif [[ "$loss_rate" == "100%" || "$loss_rate" == "100.0%" ]]; then
    echo "[FAIL] (100% loss - ICMP unreachable)"
  else
    echo "[WARN] ($loss_rate loss)"
  fi

  # TCP Port 22 SSH Probe
  echo -n "  - Testing TCP Port 22 (SSH) reachability... "
  local tcp22_ok=false
  if nc -z -w 3 "$vm_ip" 22 >/dev/null 2>&1 || ssh-keyscan -p 22 -T 3 "$vm_ip" >/dev/null 2>&1; then
    tcp22_ok=true
    echo "[OK] (TCP 22 open)"
  else
    echo "[FAIL] (TCP 22 timed out / unreachable)"
  fi
  echo

  # 3. Remote WireGuard Server Health Inspection
  echo "[3/4] Checking Remote Server WireGuard Daemon & State..."
  local ssh_ok=false
  local remote_wg_service="unknown" remote_sysctl="unknown" remote_wg_status=""
  if $tcp22_ok; then
    set +e
    local remote_diag
    remote_diag="$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes "$ADMIN_USER@$vm_ip" bash -s <<'EOF' 2>/dev/null
      set -e
      echo "===WG_SERVICE==="
      systemctl is-active wg-quick@wg0 2>/dev/null || echo "inactive"
      echo "===SYSCTL==="
      sysctl net.ipv4.ip_forward 2>/dev/null || echo "net.ipv4.ip_forward = 0"
      echo "===WG_SHOW==="
      sudo wg show 2>/dev/null || echo "NO_WG_SHOW"
EOF
)"
    local ssh_rc=$?
    set -e
    if [[ $ssh_rc -eq 0 ]]; then
      ssh_ok=true
      remote_wg_service="$(printf '%s\n' "$remote_diag" | sed -n '/===WG_SERVICE===/,/===SYSCTL===/p' | grep -v '===' | tr -d '[:space:]')"
      remote_sysctl="$(printf '%s\n' "$remote_diag" | sed -n '/===SYSCTL===/,/===WG_SHOW===/p' | grep -v '===' | tr -d '[:space:]')"
      remote_wg_status="$(printf '%s\n' "$remote_diag" | sed -n '/===WG_SHOW===/,$p' | grep -v '===')"
    fi
  fi

  local peer_count=0 latest_handshakes=""
  if $ssh_ok; then
    local wg_service_upper
    wg_service_upper="$(printf '%s' "$remote_wg_service" | tr '[:lower:]' '[:upper:]')"
    echo "  - SSH Session:                  [OK] Established"
    echo "  - WireGuard Service (wg0):      [$wg_service_upper]"
    echo "  - Kernel IP Forwarding:        $remote_sysctl"

    peer_count="$(printf '%s\n' "$remote_wg_status" | grep -c '^peer:' || true)"
    latest_handshakes="$(printf '%s\n' "$remote_wg_status" | grep 'latest handshake:' || true)"

    echo "  - Configured VPN Peers:        $peer_count"
    if [[ -n "$latest_handshakes" ]]; then
      echo "  - Peer Handshakes:"
      printf '%s\n' "$latest_handshakes" | while read -r line; do
        echo "      $line"
      done
    else
      echo "  - Peer Handshakes:             No handshakes recorded yet"
    fi
  else
    echo "  - SSH Session:                  [FAIL] Remote SSH query failed or timed out"
  fi
  echo

  # 4. GFW Censorship Diagnosis & Root Cause Verdict
  echo "[4/4] Evaluating Censorship & Diagnostic Verdict..."
  echo "================================================================================"

  if [[ "$loss_rate" == "100%" || "$loss_rate" == "100.0%" ]] && ! $tcp22_ok; then
    echo " [DIAGNOSIS] GFW Full IP Block / Null-Routing Detected"
    echo
    echo " Reason: Both ICMP ping and TCP 22 (SSH) timed out completely from your network,"
    echo "         even though Azure confirms VM '$vm_name' is running with IP $vm_ip."
    echo "         The Great Firewall of China (GFW) has blacklisted/null-routed this IP."
    echo
    echo " [RECOMMENDATION] Rotate IP immediately by replacing the VM endpoint:"
    echo "   $0 replace ${region}"
  elif $tcp22_ok && [[ "$remote_wg_service" == "active" ]]; then
    local has_recent_handshake=false
    if [[ -n "$latest_handshakes" ]]; then
      while read -r line; do
        local mins=9999
        if [[ "$line" =~ hour || "$line" =~ day ]]; then
          mins=9999
        elif [[ "$line" =~ ([0-9]+)[[:space:]]*min ]]; then
          mins="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ([0-9]+)[[:space:]]*sec ]]; then
          mins=0
        fi
        if [ "$mins" -lt 5 ]; then
          has_recent_handshake=true
          break
        fi
      done <<< "$latest_handshakes"
    fi

    if $has_recent_handshake; then
      echo " [DIAGNOSIS] VPN Endpoint Healthy & Operational"
      echo
      echo " Reason: Remote WireGuard daemon is active, SSH is reachable, and recent"
      echo "         handshakes (< 5 min ago) are actively completing."
      echo "         No GFW blocking detected on UDP port 51820 at this time."
      echo
      echo " [RECOMMENDATION] No endpoint replacement needed."
      echo "   If client cannot browse: check local WireGuard client app toggle or DNS settings."
    else
      echo " [DIAGNOSIS] GFW Deep Packet Inspection (DPI) Protocol Block Detected"
      echo
      echo " Reason: TCP 22 (SSH) connects fine and VM WireGuard daemon is ACTIVE on port 51820,"
      echo "         BUT client WireGuard handshakes are not reaching the server (0 active handshakes)."
      echo "         The GFW detected standard WireGuard UDP 51820 handshake headers (148 bytes)"
      echo "         and is actively dropping UDP 51820 traffic to IP $vm_ip."
      echo
      echo " [RECOMMENDATION] Recovery Strategies:"
      echo "   1. Immediate fix: Replace VM to get a fresh Azure public IP address:"
      echo "        $0 replace ${region}"
      echo "   2. Protocol upgrade strategy: Standard WireGuard headers (148 bytes) are"
      echo "      fingerprinted by GFW DPI. Consider upgrading to obfuscated protocols"
      echo "      (e.g., AmneziaWG or VLESS+REALITY) for long-term censorship resistance."
    fi
  elif $tcp22_ok && [[ "$remote_wg_service" != "active" ]]; then
    echo " [DIAGNOSIS] Remote WireGuard Service Down"
    echo
    echo " Reason: VM is reachable via SSH, but WireGuard service (wg-quick@wg0) is inactive."
    echo
    echo " [RECOMMENDATION] Restart WireGuard service on remote VM:"
    echo "   ssh $ADMIN_USER@$vm_ip 'sudo systemctl restart wg-quick@wg0'"
  else
    echo " [DIAGNOSIS] Partial Network Disruption / Packet Loss"
    echo
    echo " Reason: Network probing showed partial reachability (ICMP loss: $loss_rate, TCP 22: $tcp22_ok)."
    echo
    echo " [RECOMMENDATION] Retry inspection or replace VM endpoint:"
    echo "   $0 replace ${region}"
  fi

  echo "================================================================================"
}

cmd_rotate_ip() {
  local target="${1:-}"
  require_cmd az; require_cmd curl; require_az_login

  local vm_name="" region=""
  case "$target" in
    uk|australia|usa)
      region="$target"
      region_to_params "$region"
      vm_name="$VM_NAME"
      ;;
    algo-vpn-uk|algo-vpn-australia|algo-vpn-usa)
      vm_name="$target"
      region="${vm_name#algo-vpn-}"
      region_to_params "$region"
      ;;
    "")
      region="$(prompt_region)"
      region_to_params "$region"
      vm_name="$VM_NAME"
      ;;
    *)
      vm_name="$target"
      region="${vm_name#algo-vpn-}"
      region_to_params "$region"
      ;;
  esac

  log_info "starting fast public IP rotation for '$vm_name'..."

  local vm_json
  vm_json="$(az vm show -d -g "$RESOURCE_GROUP" -n "$vm_name" -o json 2>/dev/null || true)"
  [[ -n "$vm_json" ]] || die "VM '$vm_name' not found in resource group '$RESOURCE_GROUP'"

  local old_ip nic_name ip_config_name
  old_ip="$(printf '%s' "$vm_json" | jq -r '.publicIps // empty' 2>/dev/null || true)"

  nic_name="$(az network nic list -g "$RESOURCE_GROUP" --query "[?contains(name, '$vm_name')].name | [0]" -o tsv)"
  [[ -n "$nic_name" ]] || die "could not find NIC for $vm_name"

  ip_config_name="$(az network nic show -g "$RESOURCE_GROUP" -n "$nic_name" --query "ipConfigurations[0].name" -o tsv)"
  [[ -n "$ip_config_name" ]] || die "could not find IP config for NIC $nic_name"

  local old_pip_name
  old_pip_name="$(az network public-ip list -g "$RESOURCE_GROUP" --query "[?contains(name, '$vm_name')].name | [0]" -o tsv)"

  local timestamp
  timestamp="$(date +%s)"
  local new_pip_name="${vm_name}PublicIP-${timestamp}"

  log_info "creating new Azure Public IP '$new_pip_name' in $LOCATION..."
  az network public-ip create \
    -g "$RESOURCE_GROUP" \
    -n "$new_pip_name" \
    -l "$LOCATION" \
    --sku Standard \
    --allocation-method Static \
    -o none

  log_info "attaching new Public IP to NIC '$nic_name'..."
  az network nic ip-config update \
    -g "$RESOURCE_GROUP" \
    --nic-name "$nic_name" \
    -n "$ip_config_name" \
    --public-ip-address "$new_pip_name" \
    -o none

  local new_ip
  new_ip="$(az network public-ip show -g "$RESOURCE_GROUP" -n "$new_pip_name" --query ipAddress -o tsv)"
  [[ -n "$new_ip" ]] || die "failed to resolve new Public IP"

  log_info "VM new Public IP is $new_ip (was ${old_ip:-unknown})"

  if [[ -n "$old_pip_name" && "$old_pip_name" != "$new_pip_name" ]]; then
    log_info "deleting old Public IP '$old_pip_name'..."
    az network public-ip delete -g "$RESOURCE_GROUP" -n "$old_pip_name" -o none || log_warn "could not delete old Public IP $old_pip_name"
  fi

  # Update local config files in ~/Desktop/vpn/ and ~/Desktop/vpn/$vm_name/
  if [[ -d "$CONFIGS_DIR" ]]; then
    local target_dir=""
    if [[ -L "$CONFIGS_DIR/$vm_name" ]]; then
      target_dir="$CONFIGS_DIR/$(readlink "$CONFIGS_DIR/$vm_name")"
    elif [[ -d "$CONFIGS_DIR/$vm_name" ]]; then
      target_dir="$CONFIGS_DIR/$vm_name"
    fi

    # Check if remote SSH is reachable to sync real configs if missing/stale
    log_info "checking SSH connection to new IP $new_ip..."
    local ssh_ready=false
    for _ in $(seq 1 6); do
      if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes "$ADMIN_USER@$new_ip" "test -d /home/$ADMIN_USER/algo-vpn/configs" 2>/dev/null; then
        ssh_ready=true
        break
      fi
      sleep 2
    done

    if $ssh_ready; then
      local remote_cfg_dir
      remote_cfg_dir="$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes "$ADMIN_USER@$new_ip" "find /home/$ADMIN_USER/algo-vpn/configs -maxdepth 1 -type d ! -path '*/configs' | head -n 1" 2>/dev/null || true)"
      if [[ -n "$remote_cfg_dir" ]]; then
        target_dir="$CONFIGS_DIR/$new_ip"
        mkdir -p "$target_dir"
        log_info "syncing authentic client configs from remote VM ($remote_cfg_dir)..."
        ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes "$ADMIN_USER@$new_ip" "cd '$remote_cfg_dir' && tar czf - ." | tar xzf - -C "$target_dir"
        ln -sfn "$new_ip" "$CONFIGS_DIR/$vm_name"
      fi
    else
      log_warn "SSH connection to new IP $new_ip not ready yet -- proceeding with local configs"
    fi

    if [[ -n "$target_dir" && -d "$target_dir" ]]; then
      log_info "updating local WireGuard configs in $target_dir with new endpoint IP $new_ip..."
      find "$target_dir" -type f -name "*.conf" -exec sed -i '' -E "s/Endpoint = [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:/Endpoint = ${new_ip}:/g" {} +

      # Rename directory to new IP if target_dir is named as an old IP
      if [[ "$(basename "$target_dir")" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$(basename "$target_dir")" != "$new_ip" ]]; then
        local new_target_dir="$CONFIGS_DIR/$new_ip"
        mv "$target_dir" "$new_target_dir"
        target_dir="$new_target_dir"
        ln -sfn "$new_ip" "$CONFIGS_DIR/$vm_name"
        log_info "renamed config folder to $new_target_dir and updated symlink $CONFIGS_DIR/$vm_name"
      fi

      # Rename files inside target_dir to start with new IP if they started with old IP
      if [[ -n "${old_ip:-}" && "$old_ip" != "$new_ip" ]]; then
        find "$target_dir" -type f -name "${old_ip}-*" 2>/dev/null | while read -r old_file; do
          local fname
          fname="$(basename "$old_file")"
          local new_file
          new_file="$(dirname "$old_file")/${new_ip}-${fname#${old_ip}-}"
          mv "$old_file" "$new_file"
        done
      fi

      # Convert legacy license_0..6 files to new device names if present
      if [[ -d "$target_dir/wireguard" ]]; then
        local devices=("mac" "ipad" "iphone" "windows" "android" "ios" "macmini")
        for idx in "${!devices[@]}"; do
          local dev="${devices[$idx]}"
          local old_base="license_${idx}"
          find "$target_dir" -type f -name "${old_base}.*" 2>/dev/null | while read -r old_file; do
            local ext="${old_file##*.}"
            local new_file="$(dirname "$old_file")/${new_ip}-${dev}.${ext}"
            mv "$old_file" "$new_file"
          done
        done
      fi

      # Clean up old IP address directories in CONFIGS_DIR that are no longer referenced by any active symlink
      find "$CONFIGS_DIR" -maxdepth 1 -type d 2>/dev/null | while read -r dir; do
        local bname
        bname="$(basename "$dir")"
        if [[ "$bname" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$bname" != "$new_ip" ]]; then
          if ! find "$CONFIGS_DIR" -maxdepth 1 -type l -exec readlink {} + 2>/dev/null | grep -q "$bname"; then
            rm -rf "$dir"
            log_info "cleaned up old IP config directory $dir"
          fi
        fi
      done

      # If qrencode is available, regenerate all QR code PNG images
      if command -v qrencode >/dev/null 2>&1; then
        log_info "regenerating QR code PNG images in $target_dir/wireguard..."
        find "$target_dir/wireguard" -name "*.conf" 2>/dev/null | while read -r conf_file; do
          png_file="${conf_file%.conf}.png"
          qrencode -o "$png_file" < "$conf_file" 2>/dev/null || true
        done
      fi

      # Auto import into WireGuard GUI on macOS if available
      local client_conf=""
      if [[ -f "$target_dir/wireguard/${new_ip}-mac.conf" ]]; then
        client_conf="$target_dir/wireguard/${new_ip}-mac.conf"
      elif [[ -f "$target_dir/wireguard/${new_ip}-macmini.conf" ]]; then
        client_conf="$target_dir/wireguard/${new_ip}-macmini.conf"
      elif [[ -f "$target_dir/wireguard/license_2.conf" ]]; then
        client_conf="$target_dir/wireguard/license_2.conf"
      elif [[ -f "$target_dir/wireguard/license_0.conf" ]]; then
        client_conf="$target_dir/wireguard/license_0.conf"
      else
        client_conf="$(find "$target_dir/wireguard" -name "*.conf" 2>/dev/null | head -n 1)"
      fi

      if [[ -n "$client_conf" && -d "/Applications/WireGuard.app" ]]; then
        local new_tunnel_name
        new_tunnel_name="$(basename "${client_conf%.conf}")"
        log_info "re-importing $new_tunnel_name into WireGuard GUI and removing old tunnel..."
        osascript -e '
        on run argv
          set confPath to item 1 of argv
          set newTunnelName to item 2 of argv
          set oldIp to item 3 of argv
          set vmName to item 4 of argv
          tell application "WireGuard" to activate
          delay 0.5
          tell application "System Events"
            tell process "WireGuard"
              if not (exists window 1) then
                try
                  perform action "AXPress" of menu bar item 1 of menu bar 2
                end try
              end if
              delay 0.5
              if exists window 1 then
                tell window 1
                  keystroke "o" using {command down}
                  delay 1.0
                  keystroke "g" using {command down, shift down}
                  delay 1.0
                  keystroke confPath
                  delay 0.5
                  keystroke return
                  delay 0.8
                  keystroke return
                  delay 1.0
                  
                  try
                    repeat with r in rows of table 1 of scroll area 1
                      set tName to ""
                      repeat with ch in UI elements of UI element 1 of r
                        try
                          if (get value of ch) is not missing value then set tName to (get value of ch)
                        end try
                        try
                          if (get title of ch) is not missing value then set tName to (get title of ch)
                        end try
                      end repeat
                      
                      if tName is not "" and tName is not newTunnelName then
                        if (oldIp is not "" and tName contains oldIp) or tName is vmName then
                          set selected of r to true
                          delay 0.3
                          click (first UI element whose description is "remove" or name is "remove")
                          delay 0.8
                          if exists sheet 1 then
                            click button "Delete" of sheet 1
                            delay 0.8
                          end if
                          exit repeat
                        end if
                      end if
                    end repeat
                  end try
                end tell
              end if
            end tell
          end tell
        end run' "$client_conf" "$new_tunnel_name" "${old_ip:-}" "$vm_name" >/dev/null 2>&1 || log_warn "could not auto-import into WireGuard GUI"
      fi
    fi
  fi

  echo
  echo "=================================================="
  echo " IP Rotation Complete for: $vm_name"
  echo " Old IP: ${old_ip:-unknown}"
  echo " New IP: $new_ip"
  echo " Configs updated in: $CONFIGS_DIR/$vm_name"
  echo "=================================================="

  local ipad_conf=""
  if [[ -f "$target_dir/wireguard/${new_ip}-ipad.conf" ]]; then
    ipad_conf="$target_dir/wireguard/${new_ip}-ipad.conf"
  elif [[ -f "$target_dir/wireguard/license_1.conf" ]]; then
    ipad_conf="$target_dir/wireguard/license_1.conf"
  fi

  if command -v qrencode >/dev/null 2>&1 && [[ -n "${ipad_conf:-}" && -f "$ipad_conf" ]]; then
    echo
    echo "=================================================="
    echo " QR CODE FOR IPAD SCAN (Client Config: $(basename "$ipad_conf")):"
    echo "=================================================="
    qrencode -t ansiutf8 < "$ipad_conf"
  fi
}

cmd_replace() {
  local region="${1:-}"
  [[ -n "$region" ]] || region="$(prompt_region)"
  region_to_params "$region"

  require_cmd az; require_az_login

  if az vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" >/dev/null 2>&1; then
    log_info "destroying existing VM '$VM_NAME' before replacing..."
    cmd_destroy "$VM_NAME" "--yes"
  else
    log_info "no existing VM '$VM_NAME' found -- proceeding with creation"
  fi

  cmd_create "$region"
}

if [[ "${1:-}" == "vpn" ]]; then
  shift
fi

case "${1:-}" in
  create)             shift; cmd_create "${1:-}" ;;
  replace)            shift; cmd_replace "${1:-}" ;;
  rotate-ip|rotate)   shift; cmd_rotate_ip "${1:-}" ;;
  inspect|inspection) shift; cmd_inspect "${1:-}" ;;
  list)               cmd_list ;;
  destroy)            shift; cmd_destroy "${1:-}" "${2:-}" ;;
  *) usage ;;
esac

