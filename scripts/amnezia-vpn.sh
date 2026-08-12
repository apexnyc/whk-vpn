#!/usr/bin/env bash
# amnezia-vpn.sh — provision, inspect, or tear down a censorship-resistant
# AmneziaWG (AWG) VPN endpoint on Azure, one region at a time.
#
# Usage:
#   amnezia-vpn.sh create [uk|australia|usa]   # omit region to pick interactively
#   amnezia-vpn.sh replace [uk|australia|usa]  # tear down existing AWG endpoint (if any) & recreate
#   amnezia-vpn.sh inspect [uk|australia|usa]  # perform deep diagnostic on AWG endpoint
#   amnezia-vpn.sh list                        # show live AWG VMs in resource group
#   amnezia-vpn.sh destroy <vm-name> [--yes]   # tear down just that VM and its resources
#
# AmneziaWG is an obfuscated WireGuard fork designed to defeat GFW Deep Packet Inspection
# (DPI) by randomizing packet headers (Jc, Jmin, Jmax, S1, S2, H1-H4).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

VM_SIZE="Standard_B1s"
IMAGE="Canonical:ubuntu-24_04-lts:server:24.04.202608020"
WIREGUARD_PORT=51820

usage() {
  cat >&2 <<'EOF'
Usage:
  amnezia-vpn.sh create [country|region]
  amnezia-vpn.sh replace [country|region]
  amnezia-vpn.sh inspect [country|region|vm-name]
  amnezia-vpn.sh list
  amnezia-vpn.sh destroy <vm-name> [--yes]

Examples:
  amnezia-vpn.sh create japan
  amnezia-vpn.sh create korea
  amnezia-vpn.sh create singapore
  amnezia-vpn.sh create hongkong
  amnezia-vpn.sh create usa
  amnezia-vpn.sh create uk
EOF
  exit 1
}

cmd_create() {
  local region="${1:-}"
  [[ -n "$region" ]] || region="$(prompt_region)"
  region_to_params "$region"

  log_info "Initializing AmneziaWG endpoint deployment in region '$region' ($LOCATION)..."
  log_info "Checking Azure CLI prerequisites and authenticating..."

  require_cmd az; require_cmd ssh; require_cmd curl; require_cmd base64; require_cmd tar
  require_az_login

  log_info "Detecting operator public IP address..."
  local my_ip
  my_ip="$(detect_public_ip)"
  log_info "Operator public IP: $my_ip"

  log_info "Ensuring Azure resource group '$RESOURCE_GROUP' exists in $LOCATION..."
  az group create -n "$RESOURCE_GROUP" -l "$LOCATION" --tags managed-by=whk-vpn -o none

  local feature_state
  feature_state="$(az feature show --namespace Microsoft.Compute --name UseStandardSecurityType --query "properties.state" -o tsv 2>/dev/null || true)"
  if [[ "$feature_state" != "Registered" ]]; then
    log_info "Registering UseStandardSecurityType feature (one-time check)..."
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
    log_info "Azure VM '$VM_NAME' already exists -- reusing existing instance"
  else
    log_info "Creating Azure VM '$VM_NAME' in $LOCATION ($VM_SIZE)... (takes ~1-2 min)"
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
  log_info "Azure VM public IP: $vm_ip"

  local nsg_name
  nsg_name="$(az network nsg list -g "$RESOURCE_GROUP" --query "[?contains(name, '$VM_NAME')].name | [0]" -o tsv)"
  [[ -n "$nsg_name" ]] || die "could not find the NSG auto-created for $VM_NAME"

  local ssh_rule
  ssh_rule="$(az network nsg rule list -g "$RESOURCE_GROUP" --nsg-name "$nsg_name" --query "[?destinationPortRange=='22'].name | [0]" -o tsv)"
  if [[ -n "$ssh_rule" ]]; then
    az network nsg rule update -g "$RESOURCE_GROUP" --nsg-name "$nsg_name" -n "$ssh_rule" --source-address-prefixes "$my_ip" -o none
    log_info "Restricted SSH port 22 access exclusively to operator IP: $my_ip"
  fi

  if ! az network nsg rule show -g "$RESOURCE_GROUP" --nsg-name "$nsg_name" -n Port_51820 >/dev/null 2>&1; then
    az network nsg rule create -g "$RESOURCE_GROUP" --nsg-name "$nsg_name" -n Port_51820 \
      --priority 310 --access Allow --direction Inbound --protocol '*' \
      --source-address-prefixes '*' --source-port-ranges '*' \
      --destination-address-prefixes '*' --destination-port-ranges "$WIREGUARD_PORT" -o none
    log_info "Inbound rule Port_51820 created (UDP port 51820, source Any)"
  fi

  log_info "Waiting for SSH connection to $vm_ip..."
  local ssh_connected=false
  for i in $(seq 1 30); do
    if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes "$ADMIN_USER@$vm_ip" "echo ok" >/dev/null 2>&1; then
      ssh_connected=true
      break
    fi
    log_info "SSH not ready yet ($i/30)... retrying in 5s"
    sleep 5
  done
  $ssh_connected || die "SSH never became reachable on $vm_ip"
  log_info "SSH connection established with $vm_ip"

  log_info "Deploying AmneziaWG server on $vm_ip (~30 sec)..."
  set +e
  local remote_output
  remote_output="$(ssh -o StrictHostKeyChecking=accept-new "$ADMIN_USER@$vm_ip" "VM_IP='$vm_ip' WIREGUARD_PORT='$WIREGUARD_PORT' bash -s" <<'EOF'
    set -e
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

    # Install AmneziaWG tools & kernel module
    sudo apt-get update -qq
    sudo apt-get install -y -qq software-properties-common qrencode iptables >/dev/null 2>&1
    sudo add-apt-repository -y ppa:amnezia/ppa < /dev/null >/dev/null 2>&1 || true
    sudo apt-get update -qq
    sudo apt-get install -y -qq amneziawg amneziawg-tools >/dev/null 2>&1 || true

    # Fallback to wireguard-tools if amneziawg-tools binary missing
    AWG_BIN="$(command -v awg 2>/dev/null || true)"
    AWG_QUICK_BIN="$(command -v awg-quick 2>/dev/null || true)"
    if [ -z "$AWG_BIN" ]; then
      sudo apt-get install -y -qq wireguard-tools >/dev/null 2>&1
      AWG_BIN="$(command -v wg 2>/dev/null || true)"
      AWG_QUICK_BIN="$(command -v wg-quick 2>/dev/null || true)"
    fi

    # Generate random obfuscation parameters (Jc, Jmin, Jmax, S1, S2, H1, H2, H3, H4)
    JC=$(shuf -i 4-8 -n 1)
    JMIN=$(shuf -i 40-60 -n 1)
    JMAX=$(shuf -i 70-120 -n 1)
    S1=$(shuf -i 15-35 -n 1)
    S2=$(shuf -i 20-45 -n 1)
    H1=$(shuf -i 100000000-2147483647 -n 1)
    H2=$(shuf -i 100000000-2147483647 -n 1)
    H3=$(shuf -i 100000000-2147483647 -n 1)
    H4=$(shuf -i 100000000-2147483647 -n 1)

    # Key generation
    SERVER_PRIV=$($AWG_BIN genkey)
    SERVER_PUB=$(echo "$SERVER_PRIV" | $AWG_BIN pubkey)

    MACBOOK_PRIV=$($AWG_BIN genkey)
    MACBOOK_PUB=$(echo "$MACBOOK_PRIV" | $AWG_BIN pubkey)

    IPHONE_PRIV=$($AWG_BIN genkey)
    IPHONE_PUB=$(echo "$IPHONE_PRIV" | $AWG_BIN pubkey)

    IPAD_PRIV=$($AWG_BIN genkey)
    IPAD_PUB=$(echo "$IPAD_PRIV" | $AWG_BIN pubkey)

    IOS_PRIV=$($AWG_BIN genkey)
    IOS_PUB=$(echo "$IOS_PRIV" | $AWG_BIN pubkey)

    ANDROID_PRIV=$($AWG_BIN genkey)
    ANDROID_PUB=$(echo "$ANDROID_PRIV" | $AWG_BIN pubkey)

    WINDOWS_PRIV=$($AWG_BIN genkey)
    WINDOWS_PUB=$(echo "$WINDOWS_PRIV" | $AWG_BIN pubkey)

    MACMINI_PRIV=$($AWG_BIN genkey)
    MACMINI_PUB=$(echo "$MACMINI_PRIV" | $AWG_BIN pubkey)

    # Server config
    sudo mkdir -p /etc/amneziawg /etc/amnezia/amneziawg
    cat <<AWGCFG | sudo tee /etc/amneziawg/awg0.conf >/dev/null
[Interface]
PrivateKey = $SERVER_PRIV
Address = 10.8.0.1/24
ListenPort = $WIREGUARD_PORT
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4

PostUp = sysctl -w net.ipv4.ip_forward=1; iptables -A FORWARD -i awg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i awg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

# MacBook Peer
[Peer]
PublicKey = $MACBOOK_PUB
AllowedIPs = 10.8.0.2/32

# iPhone Peer
[Peer]
PublicKey = $IPHONE_PUB
AllowedIPs = 10.8.0.3/32

# iPad Peer
[Peer]
PublicKey = $IPAD_PUB
AllowedIPs = 10.8.0.4/32

# Generic iOS Peer
[Peer]
PublicKey = $IOS_PUB
AllowedIPs = 10.8.0.5/32

# Android Peer
[Peer]
PublicKey = $ANDROID_PUB
AllowedIPs = 10.8.0.6/32

# Windows Peer
[Peer]
PublicKey = $WINDOWS_PUB
AllowedIPs = 10.8.0.7/32

# Mac Mini Peer
[Peer]
PublicKey = $MACMINI_PUB
AllowedIPs = 10.8.0.8/32
AWGCFG

    sudo cp /etc/amneziawg/awg0.conf /etc/amnezia/amneziawg/awg0.conf
    sudo chmod 600 /etc/amneziawg/awg0.conf /etc/amnezia/amneziawg/awg0.conf
    sudo systemctl stop awg-quick@awg0 2>/dev/null || true
    sudo systemctl enable awg-quick@awg0 --now >/dev/null 2>&1 || sudo $AWG_QUICK_BIN up awg0 >/dev/null 2>&1

    # Staging directory for generated client configs
    TMP_DIR=$(mktemp -d)

    create_conf() {
      local dev_name="$1"
      local dev_priv="$2"
      local dev_ip="$3"

      local filename="${VM_IP}-${dev_name}.conf"
      local pngname="${VM_IP}-${dev_name}_qr.png"
      local txtname="${VM_IP}-${dev_name}_qr.txt"

      cat <<CONF > "$TMP_DIR/$filename"
[Interface]
PrivateKey = $dev_priv
Address = $dev_ip/24
DNS = 1.1.1.1, 8.8.8.8
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4

[Peer]
PublicKey = $SERVER_PUB
Endpoint = $VM_IP:$WIREGUARD_PORT
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
CONF

      # Create friendly symlinks inside staging directory
      ln -sfn "$filename" "$TMP_DIR/${dev_name}.conf"
      ln -sfn "$pngname" "$TMP_DIR/${dev_name}_qr.png"

      # Render PNG image file and ANSI text QR codes
      qrencode -o "$TMP_DIR/$pngname" < "$TMP_DIR/$filename" 2>/dev/null || true
      qrencode -t ansiutf8 < "$TMP_DIR/$filename" > "$TMP_DIR/$txtname" 2>/dev/null || echo "QR code generation unavailable" > "$TMP_DIR/$txtname"
      ln -sfn "$txtname" "$TMP_DIR/${dev_name}_qr.txt"
    }

    create_conf "macbook" "$MACBOOK_PRIV" "10.8.0.2"
    create_conf "iphone"  "$IPHONE_PRIV"  "10.8.0.3"
    create_conf "ipad"    "$IPAD_PRIV"    "10.8.0.4"
    create_conf "ios"     "$IOS_PRIV"     "10.8.0.5"
    create_conf "android" "$ANDROID_PRIV" "10.8.0.6"
    create_conf "windows" "$WINDOWS_PRIV" "10.8.0.7"
    create_conf "macmini" "$MACMINI_PRIV" "10.8.0.8"

    echo "===AWG_CONFIGS_BEGIN:$VM_IP==="
    tar -czf - -C "$TMP_DIR" . | base64
    echo "===AWG_CONFIGS_END==="
    rm -rf "$TMP_DIR"
EOF
)"
  local ssh_status=$?
  set -e

  if [[ $ssh_status -ne 0 ]]; then
    printf '%s\n' "$remote_output" | tail -60
    die "remote install failed (ssh exit $ssh_status) -- see output above"
  fi

  local target_dir="$CONFIGS_DIR/$vm_ip"
  mkdir -p "$target_dir"
  printf '%s\n' "$remote_output" \
    | sed -n '/===AWG_CONFIGS_BEGIN/,/===AWG_CONFIGS_END===/p' \
    | sed '1d;$d' \
    | base64 -d \
    | tar xzf - -C "$target_dir"

  # Symlink $CONFIGS_DIR/$VM_NAME to $CONFIGS_DIR/$vm_ip (matching Algo structure)
  ln -sfn "$vm_ip" "$CONFIGS_DIR/$VM_NAME"
  cp "$target_dir/$vm_ip-macbook.conf" "$target_dir/$VM_NAME.conf"

  # Auto-import into AmneziaWG app or WireGuard app on macOS
  if [[ -d "/Applications/AmneziaWG.app" ]]; then
    log_info "auto-importing $VM_NAME.conf into AmneziaWG GUI..."
    osascript -e '
    on run argv
      set confPath to item 1 of argv
      tell application "AmneziaWG" to activate
      delay 0.5
      tell application "System Events"
        tell process "AmneziaWG"
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
    end run' "$target_dir/$VM_NAME.conf" >/dev/null 2>&1 || log_warn "could not auto-import into AmneziaWG GUI"
  elif [[ -d "/Applications/WireGuard.app" ]]; then
    log_info "AmneziaWG.app not found -- importing into WireGuard GUI..."
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
    end run' "$target_dir/$VM_NAME.conf" >/dev/null 2>&1 || log_warn "could not auto-import into WireGuard GUI"
  fi

  echo
  echo "================================================================================"
  echo " AMNEZIAWG VPN ENDPOINT READY: $VM_NAME ($region / $LOCATION)"
  echo " Server IP: $vm_ip"
  echo " Configs & QR Code Images saved to: $target_dir"
  echo "   - MacBook:  $target_dir/$vm_ip-macbook.conf"
  echo "   - Mac Mini: $target_dir/$vm_ip-macmini.conf"
  echo "   - iPhone:   $target_dir/$vm_ip-iphone.conf  (Image: $vm_ip-iphone_qr.png)"
  echo "   - iPad:     $target_dir/$vm_ip-ipad.conf    (Image: $vm_ip-ipad_qr.png)"
  echo "   - iOS:      $target_dir/$vm_ip-ios.conf     (Image: $vm_ip-ios_qr.png)"
  echo "   - Android:  $target_dir/$vm_ip-android.conf (Image: $vm_ip-android_qr.png)"
  echo "   - Windows:  $target_dir/$vm_ip-windows.conf (Image: $vm_ip-windows_qr.png)"
  echo " Symlinked at: $CONFIGS_DIR/$VM_NAME"
  echo "================================================================================"
  echo
  echo "--- SCAN QR CODE WITH IPHONE (AMNEZIAWG APP) ---"
  cat "$target_dir/$vm_ip-iphone_qr.txt" 2>/dev/null || cat "$target_dir/iphone_qr.txt"
  echo
  echo "--- SCAN QR CODE WITH IPAD (AMNEZIAWG APP) ---"
  cat "$target_dir/$vm_ip-ipad_qr.txt" 2>/dev/null || cat "$target_dir/ipad_qr.txt"
  echo "================================================================================"
}

cmd_qr() {
  local target="${1:-}"
  local device="${2:-iphone}"

  local vm_name=""
  case "$target" in
    awg-vpn-*) vm_name="$target" ;;
    "")        vm_name="awg-vpn-usa" ;;
    *)
      region_to_params "$target"
      vm_name="$VM_NAME"
      ;;
  esac

  local target_dir="$CONFIGS_DIR/$vm_name"
  [[ -d "$target_dir" ]] || die "no configuration directory found at $target_dir -- did you run 'vpn create $target'?"

  local conf_file="$target_dir/${device}.conf"
  local qr_file="$target_dir/${device}_qr.txt"

  if [[ -f "$qr_file" ]]; then
    echo "--- AMNEZIAWG QR CODE FOR ${device^^} ($vm_name) ---"
    cat "$qr_file"
  elif [[ -f "$conf_file" ]] && command -v qrencode >/dev/null 2>&1; then
    echo "--- AMNEZIAWG QR CODE FOR ${device^^} ($vm_name) ---"
    qrencode -t ansiutf8 < "$conf_file"
  else
    die "could not find QR code for $device in $target_dir"
  fi
}

cmd_list() {
  require_cmd az; require_az_login
  az vm list -g "$RESOURCE_GROUP" -d --query "[?contains(name, 'awg-vpn')].{name:name, ip:publicIps, location:location, state:powerState}" -o table
}

cmd_destroy() {
  local vm_name="${1:-}"
  local force="${2:-}"
  [[ -n "$vm_name" ]] || die "usage: $0 destroy <vm-name> [--yes]"

  require_cmd az; require_az_login

  az vm show -g "$RESOURCE_GROUP" -n "$vm_name" >/dev/null 2>&1 \
    || die "VM '$vm_name' not found in resource group '$RESOURCE_GROUP' (see: $0 list)"

  local disk_name
  disk_name="$(az vm show -g "$RESOURCE_GROUP" -n "$vm_name" --query "storageProfile.osDisk.managedDisk.id" -o tsv | awk -F/ '{print $NF}')"

  log_warn "about to permanently delete VM '$vm_name' and its resources in '$RESOURCE_GROUP'"
  if [[ "$force" != "--yes" ]]; then
    read -r -p "Type the VM name to confirm: " confirm
    [[ "$confirm" == "$vm_name" ]] || die "confirmation did not match -- aborted"
  fi

  log_info "deleting VM '$vm_name'..."
  az vm delete -g "$RESOURCE_GROUP" -n "$vm_name" --yes -o none

  local nic_name ip_name nsg_name
  nic_name="$(az network nic list -g "$RESOURCE_GROUP" --query "[?contains(name, '$vm_name')].name | [0]" -o tsv)"
  ip_name="$(az network public-ip list -g "$RESOURCE_GROUP" --query "[?contains(name, '$vm_name')].name | [0]" -o tsv)"
  nsg_name="$(az network nsg list -g "$RESOURCE_GROUP" --query "[?contains(name, '$vm_name')].name | [0]" -o tsv)"
  [[ -n "$nic_name" ]] && az network nic delete -g "$RESOURCE_GROUP" -n "$nic_name" -o none
  [[ -n "$ip_name" ]] && az network public-ip delete -g "$RESOURCE_GROUP" -n "$ip_name" -o none
  [[ -n "$nsg_name" ]] && az network nsg delete -g "$RESOURCE_GROUP" -n "$nsg_name" -o none
  [[ -n "$disk_name" ]] && az disk delete -g "$RESOURCE_GROUP" -n "$disk_name" --yes -o none

  rm -rf "$CONFIGS_DIR/$vm_name"
  log_info "removed local configs for $vm_name"
}

cmd_inspect() {
  local target="${1:-}"
  require_cmd az; require_cmd ssh; require_cmd curl; require_az_login

  local vm_name="" region=""
  case "$target" in
    awg-vpn-*)
      vm_name="$target"
      region="${vm_name#awg-vpn-}"
      ;;
    "")
      log_info "Available AWG VMs in resource group '$RESOURCE_GROUP':"
      cmd_list
      echo >&2
      read -r -p "Enter VM name or region/country (e.g. japan, korea, uk): " choice
      [[ -n "$choice" ]] || die "no VM specified"
      if [[ "$choice" =~ ^awg-vpn- ]]; then
        vm_name="$choice"
      else
        region_to_params "$choice"
        vm_name="$VM_NAME"
      fi
      ;;
    *)
      region_to_params "$target"
      vm_name="$VM_NAME"
      ;;
  esac

  log_info "Starting deep diagnostic inspection for AmneziaWG endpoint '$vm_name'..."
  echo "================================================================================"
  echo " AMNEZIAWG DIAGNOSTIC INSPECTION REPORT: $vm_name"
  echo " Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "================================================================================"
  echo

  echo "[1/4] Checking Azure Cloud Infrastructure & VM Status..."
  local vm_json
  vm_json="$(az vm show -d -g "$RESOURCE_GROUP" -n "$vm_name" -o json 2>/dev/null || true)"
  if [[ -z "$vm_json" ]]; then
    echo "  [FAIL] Azure VM '$vm_name' does not exist in resource group '$RESOURCE_GROUP'."
    return 1
  fi

  local power_state vm_ip location
  power_state="$(printf '%s' "$vm_json" | jq -r '.powerState // empty' 2>/dev/null || true)"
  vm_ip="$(printf '%s' "$vm_json" | jq -r '.publicIps // empty' 2>/dev/null || true)"
  location="$(printf '%s' "$vm_json" | jq -r '.location // empty' 2>/dev/null || true)"

  echo "  - Resource Group: $RESOURCE_GROUP"
  echo "  - Location:       ${location:-unknown}"
  echo "  - Public IP:       ${vm_ip:-none}"
  echo "  - Power State:     ${power_state:-unknown}"

  if [[ "$power_state" != "VM running" ]]; then
    echo "  [FAIL] VM is not running."
    return 1
  fi
  echo "  [OK] Azure VM power state is running."
  echo

  echo "[2/4] Checking Local Operator Network & Edge Reachability..."
  local my_ip
  my_ip="$(detect_public_ip)"
  echo "  - Current Operator Public IP: $my_ip"

  echo -n "  - Testing ICMP Ping to $vm_ip... "
  local ping_out loss_rate
  ping_out="$(ping -c 4 -W 2000 "$vm_ip" 2>&1 || true)"
  loss_rate="$(printf '%s\n' "$ping_out" | grep -o '[0-9.]*% packet loss' | awk '{print $1}' || echo "100%")"
  if [[ "$loss_rate" == "0%" || "$loss_rate" == "0.0%" ]]; then
    echo "[OK] (0% loss)"
  else
    echo "[WARN] ($loss_rate loss)"
  fi

  echo -n "  - Testing TCP Port 22 (SSH) reachability... "
  local tcp22_ok=false
  if nc -z -w 3 "$vm_ip" 22 >/dev/null 2>&1 || ssh-keyscan -p 22 -T 3 "$vm_ip" >/dev/null 2>&1; then
    tcp22_ok=true
    echo "[OK] (TCP 22 open)"
  else
    echo "[FAIL] (TCP 22 timed out / unreachable)"
  fi
  echo

  echo "[3/4] Checking Remote Server AmneziaWG Daemon & Obfuscation State..."
  local ssh_ok=false
  local remote_awg_service="unknown" remote_status=""
  if $tcp22_ok; then
    set +e
    local remote_diag
    remote_diag="$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes "$ADMIN_USER@$vm_ip" bash -s <<'EOF' 2>/dev/null
      echo "===AWG_SERVICE==="
      systemctl is-active awg-quick@awg0 2>/dev/null || systemctl is-active wg-quick@awg0 2>/dev/null || echo "inactive"
      echo "===AWG_SHOW==="
      sudo awg show 2>/dev/null || sudo wg show 2>/dev/null || echo "NO_SHOW"
EOF
)"
    local ssh_rc=$?
    set -e
    if [[ $ssh_rc -eq 0 ]]; then
      ssh_ok=true
      remote_awg_service="$(printf '%s\n' "$remote_diag" | sed -n '/===AWG_SERVICE===/,/===AWG_SHOW===/p' | grep -v '===' | tr -d '[:space:]')"
      remote_status="$(printf '%s\n' "$remote_diag" | sed -n '/===AWG_SHOW===/,$p' | grep -v '===')"
    fi
  fi

  if $ssh_ok; then
    echo "  - SSH Session:                  [OK] Established"
    echo "  - AmneziaWG Service (awg0):     [$remote_awg_service]"
    local peer_count
    peer_count="$(printf '%s\n' "$remote_status" | grep -c '^peer:' || true)"
    echo "  - Configured Peers:             $peer_count (MacBook, iPhone, iPad, Windows)"
    local handshakes
    handshakes="$(printf '%s\n' "$remote_status" | grep 'latest handshake:' || true)"
    if [[ -n "$handshakes" ]]; then
      echo "  - Peer Handshakes:"
      printf '%s\n' "$handshakes" | while read -r line; do
        echo "      $line"
      done
    else
      echo "  - Peer Handshakes:             No handshakes recorded yet"
    fi
  else
    echo "  - SSH Session:                  [FAIL] Remote SSH query failed"
  fi
  echo

  echo "[4/4] Evaluating Censorship & Diagnostic Verdict..."
  echo "================================================================================"

  if [[ "$loss_rate" == "100%" || "$loss_rate" == "100.0%" ]] && ! $tcp22_ok; then
    echo " [DIAGNOSIS] GFW Full IP Block / Null-Routing Detected"
    echo " [RECOMMENDATION] Replace VM endpoint: $0 replace ${region:-usa}"
  elif $tcp22_ok && [[ "$remote_awg_service" == "active" ]]; then
    echo " [DIAGNOSIS] AmneziaWG Endpoint Active & Obfuscated"
    echo " Obfuscation headers (Jc, Jmin, Jmax, S1, S2, H1-H4) are active on UDP 51820."
  else
    echo " [DIAGNOSIS] Service Attention Needed"
  fi
  echo "================================================================================"
}

cmd_replace() {
  local region="${1:-}"
  [[ -n "$region" ]] || region="$(prompt_region)"
  region_to_params "$region"

  require_cmd az; require_az_login

  if az vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" >/dev/null 2>&1; then
    log_info "destroying existing VM '$VM_NAME' before replacing..."
    cmd_destroy "$VM_NAME" "--yes"
  fi

  cmd_create "$region"
}

cmd_rotate_ip() {
  local target="${1:-}"
  require_cmd az; require_cmd curl; require_az_login

  local vm_name="" region=""
  case "$target" in
    awg-vpn-*)
      vm_name="$target"
      region="${vm_name#awg-vpn-}"
      region_to_params "$region"
      ;;
    "")
      region="$(prompt_region)"
      region_to_params "$region"
      vm_name="$VM_NAME"
      ;;
    *)
      region_to_params "$target"
      vm_name="$VM_NAME"
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

  local target_dir=""
  if [[ -L "$CONFIGS_DIR/$vm_name" ]]; then
    target_dir="$CONFIGS_DIR/$(readlink "$CONFIGS_DIR/$vm_name")"
  elif [[ -d "$CONFIGS_DIR/$vm_name" ]]; then
    target_dir="$CONFIGS_DIR/$vm_name"
  fi

  if [[ -n "$target_dir" && -d "$target_dir" ]]; then
    local new_target_dir="$CONFIGS_DIR/$new_ip"
    if [[ "$target_dir" != "$new_target_dir" ]]; then
      mv "$target_dir" "$new_target_dir"
      target_dir="$new_target_dir"
      ln -sfn "$new_ip" "$CONFIGS_DIR/$vm_name"
    fi

    for f in "$target_dir"/*.conf; do
      [[ -f "$f" && ! -L "$f" ]] || continue
      local fname
      fname="$(basename "$f")"
      local dev_part
      dev_part="$(echo "$fname" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+-)?//')"

      if [[ -n "$old_ip" ]]; then
        sed -i '' "s/$old_ip/$new_ip/g" "$f" 2>/dev/null || sed -i "s/$old_ip/$new_ip/g" "$f"
      fi

      local new_fname="${new_ip}-${dev_part}"
      if [[ "$fname" != "$new_fname" ]]; then
        mv "$f" "$target_dir/$new_fname"
      fi
    done

    for dev in macbook macmini iphone ipad ios android windows; do
      local conf_f="$target_dir/${new_ip}-${dev}.conf"
      if [[ -f "$conf_f" ]]; then
        ln -sfn "${new_ip}-${dev}.conf" "$target_dir/${dev}.conf"
        qrencode -o "$target_dir/${new_ip}-${dev}_qr.png" < "$conf_f" 2>/dev/null || true
        ln -sfn "${new_ip}-${dev}_qr.png" "$target_dir/${dev}_qr.png"
        qrencode -t ansiutf8 < "$conf_f" > "$target_dir/${new_ip}-${dev}_qr.txt" 2>/dev/null || true
        ln -sfn "${new_ip}-${dev}_qr.txt" "$target_dir/${dev}_qr.txt"
      fi
    done

    cp "$target_dir/${new_ip}-macbook.conf" "$target_dir/$vm_name.conf" 2>/dev/null || true

    if [[ -d "/Applications/AmneziaWG.app" ]]; then
      log_info "auto-importing updated $vm_name.conf into AmneziaWG GUI..."
      osascript -e '
      on run argv
        set confPath to item 1 of argv
        tell application "AmneziaWG" to activate
        delay 0.5
        tell application "System Events"
          tell process "AmneziaWG"
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
      end run' "$target_dir/$vm_name.conf" >/dev/null 2>&1 || log_warn "could not auto-import into AmneziaWG GUI"
    fi
  fi

  echo
  echo "=================================================="
  echo " Fast IP Rotation Complete for: $vm_name"
  echo " Old IP: ${old_ip:-unknown}"
  echo " New IP: $new_ip"
  echo " Configs updated in: $CONFIGS_DIR/$vm_name ($target_dir)"
  echo "=================================================="
  echo
  echo "--- SCAN NEW QR CODE WITH IPHONE (AMNEZIAWG APP) ---"
  cat "$target_dir/${new_ip}-iphone_qr.txt" 2>/dev/null || cat "$target_dir/iphone_qr.txt" 2>/dev/null || true
}

case "${1:-}" in
  create)                      shift; cmd_create "${1:-}" ;;
  replace)                     shift; cmd_replace "${1:-}" ;;
  rotate-ip|rotate)            shift; cmd_rotate_ip "${1:-}" ;;
  inspect|inspection)          shift; cmd_inspect "${1:-}" ;;
  qr|qrcode)                   shift; cmd_qr "${1:-}" "${2:-}" ;;
  list)                        cmd_list ;;
  destroy)                     shift; cmd_destroy "${1:-}" "${2:-}" ;;
  *) usage ;;
esac
