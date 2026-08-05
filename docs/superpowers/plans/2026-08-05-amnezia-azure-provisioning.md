# Amnezia Azure Provisioning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provide three shell commands that create, destroy, and re-address an Azure VM prepared for the AmneziaVPN desktop client to install a VPN server onto.

**Architecture:** Pure-logic helpers live in `lib/common.sh` and are unit-tested with `bats`. Three entry-point scripts in `scripts/` compose those helpers with `az` CLI calls. Configuration comes from a gitignored `config.env` created from a committed template. The scripts never install VPN software — AmneziaVPN's desktop client does that over SSH, because it has no headless mode.

**Tech Stack:** Bash 3.2+ (macOS default), Azure CLI 2.83+, `bats-core` for tests, `shellcheck` for linting, cloud-init for first-boot configuration.

## Global Constraints

- Resource group is `kwang-vpn`, and it must contain VPN resources **only** — `destroy.sh` deletes the entire group, which is safe only under that invariant.
- Region is `westus2`.
- VM size is `Standard_B1s` (1 vCPU, 1 GB RAM).
- OS disk is 32 GB `StandardSSD_LRS`. Do **not** substitute Standard HDD: the host depends on swap, and Standard HDD's ~500 IOPS makes swapping punitive exactly when the host is under pressure.
- A 2 GB swap file is created at first boot.
- SSH password authentication is **enabled and stays enabled**. Port 22 is restricted by NSG to the operator's public IP only.
- The AmneziaWG UDP port must not be 51820 — that is WireGuard's registered port and was scanned and blocked on every prior deployment.
- Generated passwords are never committed. They go to `.env`, which `.gitignore` already excludes.
- Every script starts with `set -euo pipefail`.
- All scripts must pass `shellcheck` with no warnings.

---

## File Structure

| Path | Responsibility |
|---|---|
| `config.env.example` | Committed template of all tunable settings |
| `config.env` | Operator's actual settings — **gitignored** |
| `lib/common.sh` | Pure helpers: logging, validation, password generation, config loading, preflight |
| `scripts/provision.sh` | Creates resource group, VM, disk, swap, NSG rules; prints Amnezia credentials |
| `scripts/destroy.sh` | Deletes the resource group and sweeps for orphans |
| `scripts/rotate-ip.sh` | Replaces the public IP, leaving VM and containers intact |
| `cloud-init/swap.yaml` | First-boot swap file configuration |
| `tests/test_common.bats` | Unit tests for `lib/common.sh` |
| `README.md` | Operator runbook including the Amnezia handoff |

`lib/common.sh` holds everything testable without touching Azure. The three scripts hold everything that talks to Azure and is therefore verified end-to-end rather than by unit test. That split is what makes any of this testable at all.

---

### Task 1: Shared library — validation and password generation

**Files:**
- Create: `lib/common.sh`
- Create: `tests/test_common.bats`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `generate_password()` → prints a 32-character password to stdout, guaranteed to contain lowercase, uppercase, digit, and special characters
  - `validate_port <port>` → returns 0 if the port is an integer in 1024–65535 and not 51820; returns 1 otherwise
  - `validate_ipv4 <address>` → returns 0 if the argument is a dotted-quad IPv4 address with each octet 0–255; returns 1 otherwise

- [ ] **Step 1: Install the test runner**

```bash
brew install bats-core shellcheck
bats --version
```

Expected: prints a version such as `Bats 1.11.0`.

- [ ] **Step 2: Write the failing tests**

Create `tests/test_common.bats`:

```bash
#!/usr/bin/env bats

setup() {
  REPO_ROOT="$( cd "$( dirname "$BATS_TEST_FILENAME" )/.." && pwd )"
  # shellcheck source=../lib/common.sh
  source "$REPO_ROOT/lib/common.sh"
}

@test "generate_password returns exactly 32 characters" {
  run generate_password
  [ "$status" -eq 0 ]
  [ "${#output}" -eq 32 ]
}

@test "generate_password includes all four character classes" {
  for _ in $(seq 1 20); do
    pw="$(generate_password)"
    [[ "$pw" =~ [a-z] ]]
    [[ "$pw" =~ [A-Z] ]]
    [[ "$pw" =~ [0-9] ]]
    [[ "$pw" =~ [@#%^*_+=-] ]]
  done
}

@test "generate_password produces different values on each call" {
  a="$(generate_password)"
  b="$(generate_password)"
  [ "$a" != "$b" ]
}

@test "validate_port accepts a normal high port" {
  run validate_port 44921
  [ "$status" -eq 0 ]
}

@test "validate_port rejects 51820, WireGuard's registered port" {
  run validate_port 51820
  [ "$status" -eq 1 ]
}

@test "validate_port rejects privileged ports" {
  run validate_port 80
  [ "$status" -eq 1 ]
}

@test "validate_port rejects out-of-range ports" {
  run validate_port 70000
  [ "$status" -eq 1 ]
}

@test "validate_port rejects non-numeric input" {
  run validate_port abcd
  [ "$status" -eq 1 ]
}

@test "validate_ipv4 accepts a valid address" {
  run validate_ipv4 203.0.113.42
  [ "$status" -eq 0 ]
}

@test "validate_ipv4 rejects an octet above 255" {
  run validate_ipv4 203.0.113.999
  [ "$status" -eq 1 ]
}

@test "validate_ipv4 rejects a three-octet address" {
  run validate_ipv4 203.0.113
  [ "$status" -eq 1 ]
}

@test "validate_ipv4 rejects arbitrary text" {
  run validate_ipv4 not-an-ip
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bats tests/test_common.bats`
Expected: every test fails with `No such file or directory` for `lib/common.sh`.

- [ ] **Step 4: Write the minimal implementation**

Create `lib/common.sh`:

```bash
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
  (( port >= 1024 && port <= 65535 )) || return 1
  # 51820 is WireGuard's registered port. Every prior deployment exposed it
  # and was identified by port scan before any packet was inspected.
  (( port == 51820 )) && return 1
  return 0
}

validate_ipv4() {
  local ip="${1:-}" octet
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  for octet in ${ip//./ }; do
    (( octet >= 0 && octet <= 255 )) || return 1
  done
  return 0
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats tests/test_common.bats`
Expected: `11 tests, 0 failures`

- [ ] **Step 6: Lint**

Run: `shellcheck lib/common.sh`
Expected: no output.

- [ ] **Step 7: Commit**

```bash
git add lib/common.sh tests/test_common.bats
git commit -m "feat: add validation and password helpers with tests"
```

---

### Task 2: Configuration loading and preflight checks

**Files:**
- Create: `config.env.example`
- Modify: `lib/common.sh` (append)
- Modify: `tests/test_common.bats` (append)

**Interfaces:**
- Consumes: `validate_port`, `validate_ipv4` from Task 1
- Produces:
  - `log_info <msg>`, `log_warn <msg>`, `log_error <msg>` → write to stderr with a level prefix
  - `die <msg>` → logs an error and exits 1
  - `require_cmd <name>` → dies unless the command exists on PATH
  - `require_az_login()` → dies unless `az account show` succeeds
  - `detect_public_ip()` → prints the caller's public IPv4 to stdout
  - `load_config <path>` → sources the file, then dies if `RESOURCE_GROUP`, `LOCATION`, `VM_NAME`, `ADMIN_USER`, or `AMNEZIAWG_PORT` is unset or invalid

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_common.bats`:

```bash
@test "die exits with status 1" {
  run die "something broke"
  [ "$status" -eq 1 ]
}

@test "die writes the message to stderr" {
  run --separate-stderr die "something broke"
  [[ "$stderr" == *"something broke"* ]]
}

@test "require_cmd succeeds for a command that exists" {
  run require_cmd bash
  [ "$status" -eq 0 ]
}

@test "require_cmd dies for a command that does not exist" {
  run require_cmd definitely-not-a-real-command
  [ "$status" -eq 1 ]
}

@test "load_config dies when the file is missing" {
  run load_config /nonexistent/config.env
  [ "$status" -eq 1 ]
}

@test "load_config dies when AMNEZIAWG_PORT is 51820" {
  cat > "$BATS_TEST_TMPDIR/bad.env" <<'CONF'
RESOURCE_GROUP=kwang-vpn
LOCATION=westus2
VM_NAME=vpn-cn
ADMIN_USER=kwang7
AMNEZIAWG_PORT=51820
CONF
  run load_config "$BATS_TEST_TMPDIR/bad.env"
  [ "$status" -eq 1 ]
}

@test "load_config dies when a required variable is missing" {
  cat > "$BATS_TEST_TMPDIR/incomplete.env" <<'CONF'
RESOURCE_GROUP=kwang-vpn
LOCATION=westus2
CONF
  run load_config "$BATS_TEST_TMPDIR/incomplete.env"
  [ "$status" -eq 1 ]
}

@test "load_config succeeds on a complete valid file" {
  cat > "$BATS_TEST_TMPDIR/good.env" <<'CONF'
RESOURCE_GROUP=kwang-vpn
LOCATION=westus2
VM_NAME=vpn-cn
ADMIN_USER=kwang7
AMNEZIAWG_PORT=44921
CONF
  run load_config "$BATS_TEST_TMPDIR/good.env"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/test_common.bats`
Expected: the 8 new tests fail with `command not found`; the 11 from Task 1 still pass.

- [ ] **Step 3: Write the minimal implementation**

Append to `lib/common.sh`:

```bash
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/test_common.bats`
Expected: `19 tests, 0 failures`

- [ ] **Step 5: Create the config template**

Create `config.env.example`:

```bash
# Copy to config.env and edit. config.env is gitignored.

# Azure placement. The resource group must hold VPN resources ONLY --
# destroy.sh deletes the whole group.
RESOURCE_GROUP=kwang-vpn
LOCATION=westus2

# Host
VM_NAME=vpn-cn
VM_SIZE=Standard_B1s
OS_DISK_SIZE_GB=32
OS_DISK_SKU=StandardSSD_LRS
IMAGE_URN=Canonical:ubuntu-24_04-lts:server:latest

# Linux admin account. The password is generated by provision.sh and written
# to .env -- do not set it here.
ADMIN_USER=kwang7

# Protocol ports opened in the network security group.
# AMNEZIAWG_PORT must not be 51820 (WireGuard's registered port -- it gets
# found by port scan before any packet is inspected).
AMNEZIAWG_PORT=44921
XRAY_PORT=443

# Leave empty to auto-detect the machine running provision.sh.
# SSH is restricted to this address only.
SSH_ALLOWED_IP=
```

- [ ] **Step 6: Lint and commit**

```bash
shellcheck lib/common.sh
bats tests/test_common.bats
git add lib/common.sh tests/test_common.bats config.env.example
git commit -m "feat: add config loading and preflight checks"
```

---

### Task 3: Cloud-init swap configuration

**Files:**
- Create: `cloud-init/swap.yaml`

**Interfaces:**
- Consumes: nothing
- Produces: a cloud-config file passed to `az vm create --custom-data`

- [ ] **Step 1: Write the cloud-init file**

Create `cloud-init/swap.yaml`:

```yaml
#cloud-config
# Creates a 2 GB swap file at first boot.
#
# The host is Standard_B1s with 1 GB of RAM. Docker plus both Amnezia
# protocol containers occupy roughly 600 MB, leaving little headroom.
# Memory spikes come from `docker pull` and `apt upgrade`, not from VPN
# forwarding. Swap converts an out-of-memory kill into a slowdown, which
# on a remote host that non-technical users depend on is the difference
# between degraded and dead.
#
# fallocate/mkswap is used rather than cloud-init's `swap` module because
# the module's size syntax has varied between cloud-init versions.
runcmd:
  - [ bash, -c, "test -f /swapfile || fallocate -l 2G /swapfile" ]
  - [ chmod, "600", /swapfile ]
  - [ bash, -c, "swapon --show=NAME --noheadings | grep -q /swapfile || { mkswap /swapfile && swapon /swapfile; }" ]
  - [ bash, -c, "grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab" ]
```

- [ ] **Step 2: Validate the YAML parses**

Run:

```bash
python3 -c "import yaml,sys; yaml.safe_load(open('cloud-init/swap.yaml')); print('valid')"
```

Expected: `valid`

- [ ] **Step 3: Commit**

```bash
git add cloud-init/swap.yaml
git commit -m "feat: add cloud-init swap configuration"
```

---

### Task 4: provision.sh — resource group, VM, and disk

**Files:**
- Create: `scripts/provision.sh`

**Interfaces:**
- Consumes: `load_config`, `die`, `log_info`, `require_cmd`, `require_az_login`, `generate_password`, `detect_public_ip`, `validate_ipv4`
- Produces: a running VM named `$VM_NAME` in `$RESOURCE_GROUP` with a static public IP named `${VM_NAME}-ip` and an NSG named `${VM_NAME}-nsg`

- [ ] **Step 1: Write the script**

Create `scripts/provision.sh`:

```bash
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
```

- [ ] **Step 2: Lint**

Run: `shellcheck scripts/provision.sh`
Expected: no output.

- [ ] **Step 3: Verify the guard clause without creating anything**

Run: `bash scripts/provision.sh` with no `config.env` present.
Expected: exits 1 with `config file not found: .../config.env (copy config.env.example)`

- [ ] **Step 4: Create your config and run for real**

```bash
cp config.env.example config.env
chmod +x scripts/provision.sh
./scripts/provision.sh
```

Expected: logs the detected public IP, creates the group and VM, and prints a public IP and exact image version. Takes roughly 60–90 seconds.

- [ ] **Step 5: Verify what was created**

```bash
az vm show -g kwang-vpn -n vpn-cn -d \
  --query "{name:name, size:hardwareProfile.vmSize, power:powerState, ip:publicIps}" -o table
az disk list -g kwang-vpn --query "[].{name:name, sku:sku.name, sizeGb:diskSizeGb}" -o table
```

Expected: `Standard_B1s`, `VM running`, a public IP, and one 32 GB `StandardSSD_LRS` disk.

- [ ] **Step 6: Verify idempotency**

Run: `./scripts/provision.sh`
Expected: exits 0 with `VM 'vpn-cn' already exists` and creates nothing.

- [ ] **Step 7: Commit**

```bash
git add scripts/provision.sh
git commit -m "feat: add provision.sh creating the Azure host"
```

---

### Task 5: provision.sh — NSG rules and credential output

**Files:**
- Modify: `scripts/provision.sh` (append after the VM creation block)

**Interfaces:**
- Consumes: `$RESOURCE_GROUP`, `$NSG_NAME`, `$SSH_ALLOWED_IP`, `$AMNEZIAWG_PORT`, `$XRAY_PORT`, `$PUBLIC_IP`, `$ADMIN_USER`, `$ADMIN_PASSWORD` from Task 4
- Produces: three NSG rules, a written `.env`, and the three values AmneziaVPN's connection dialog requires

- [ ] **Step 1: Append the NSG and output logic**

Append to `scripts/provision.sh`:

```bash
add_nsg_rule() {
  local name="$1" priority="$2" protocol="$3" port="$4" source="$5"
  log_info "NSG rule: $name ($protocol/$port from $source)"
  az network nsg rule create \
    --resource-group "$RESOURCE_GROUP" \
    --nsg-name "$NSG_NAME" \
    --name "$name" \
    --priority "$priority" \
    --direction Inbound \
    --access Allow \
    --protocol "$protocol" \
    --source-address-prefixes "$source" \
    --destination-port-ranges "$port" \
    --output none
}

# SSH is reachable only from the operator. Password authentication stays
# enabled because Amnezia's installer needs it and re-enabling it for every
# protocol change is friction; this source restriction is what actually
# protects the port. The retired deployment had password auth enabled AND
# port 22 open to the entire internet.
add_nsg_rule ssh       300 Tcp 22                  "$SSH_ALLOWED_IP"
add_nsg_rule xray      310 Tcp "$XRAY_PORT"        '*'
add_nsg_rule amneziawg 320 Udp "$AMNEZIAWG_PORT"   '*'

umask 077
cat > "$REPO_ROOT/.env" <<ENVFILE
# Generated by scripts/provision.sh -- gitignored, do not commit.
VPN_PUBLIC_IP=$PUBLIC_IP
VPN_ADMIN_USER=$ADMIN_USER
VPN_ADMIN_PASSWORD=$ADMIN_PASSWORD
VPN_IMAGE_EXACT=$IMAGE_EXACT
VPN_AMNEZIAWG_PORT=$AMNEZIAWG_PORT
VPN_XRAY_PORT=$XRAY_PORT
ENVFILE

cat <<BANNER

────────────────────────────────────────────────────────────
  Host ready. Enter these into the AmneziaVPN desktop client:

    IP address :  $PUBLIC_IP
    Login      :  $ADMIN_USER
    Password   :  $ADMIN_PASSWORD

  Install AmneziaWG first (it needs no domain or certificate,
  so a failure means the pipeline is wrong, not the protocol).
  Use UDP port $AMNEZIAWG_PORT -- it is already open in the NSG.
  Add XRay REALITY afterwards on TCP $XRAY_PORT.

  Saved to .env (gitignored).
────────────────────────────────────────────────────────────

BANNER
```

- [ ] **Step 2: Lint**

Run: `shellcheck scripts/provision.sh`
Expected: no output.

- [ ] **Step 3: Rebuild so the new code runs end to end**

```bash
./scripts/destroy.sh   # if Task 6 is done; otherwise: az group delete -n kwang-vpn --yes
./scripts/provision.sh
```

Expected: the banner prints an IP, login, and 32-character password.

- [ ] **Step 4: Verify the NSG rules**

```bash
az network nsg rule list -g kwang-vpn --nsg-name vpn-cn-nsg \
  --query "[].{prio:priority,name:name,proto:protocol,port:destinationPortRange,src:sourceAddressPrefix}" \
  -o table
```

Expected: three rules — `ssh` TCP 22 from your IP only, `xray` TCP 443 from `*`, `amneziawg` UDP 44921 from `*`.

- [ ] **Step 5: Verify SSH actually works and is actually restricted**

```bash
source .env
ssh -o StrictHostKeyChecking=no "$VPN_ADMIN_USER@$VPN_PUBLIC_IP" 'free -h; swapon --show'
```

Expected: connects with the generated password, and `swapon --show` lists `/swapfile` at 2 GB. If swap is missing, cloud-init may still be running — wait 60 seconds and retry.

- [ ] **Step 6: Confirm .env is not tracked by git**

Run: `git status --short .env`
Expected: no output — `.gitignore` already excludes it. **If `.env` appears, stop and fix `.gitignore` before committing anything.**

- [ ] **Step 7: Commit**

```bash
git add scripts/provision.sh
git commit -m "feat: add NSG rules and Amnezia credential output"
```

---

### Task 6: destroy.sh with orphan sweep

**Files:**
- Create: `scripts/destroy.sh`

**Interfaces:**
- Consumes: `load_config`, `die`, `log_info`, `log_warn`, `require_cmd`, `require_az_login`
- Produces: nothing — deletes the resource group

- [ ] **Step 1: Write the script**

Create `scripts/destroy.sh`:

```bash
#!/usr/bin/env bash
# Deletes the whole VPN resource group, then sweeps the subscription for
# orphans. The sweep exists because Azure does not cascade VM deletion to
# networking: deleting a VM by hand leaves its public IP billing and its
# NSG reserving a name. The retired deployment accumulated ten orphaned
# NSGs and four idle static IPs that way.
set -euo pipefail

REPO_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
# shellcheck source=../lib/common.sh
source "$REPO_ROOT/lib/common.sh"

require_cmd az
require_az_login
load_config "$REPO_ROOT/config.env"

if [[ "$(az group exists -n "$RESOURCE_GROUP")" != "true" ]]; then
  log_info "resource group '$RESOURCE_GROUP' does not exist -- nothing to do"
  exit 0
fi

COUNT="$(az resource list -g "$RESOURCE_GROUP" --query "length(@)" -o tsv)"
log_warn "about to permanently delete $COUNT resources in '$RESOURCE_GROUP'"
az resource list -g "$RESOURCE_GROUP" --query "[].{name:name,type:type}" -o table

read -r -p "Type the resource group name to confirm: " CONFIRM
[[ "$CONFIRM" == "$RESOURCE_GROUP" ]] || die "confirmation did not match -- aborted"

log_info "deleting..."
az group delete -n "$RESOURCE_GROUP" --yes --output none
log_info "resource group deleted"

log_info "sweeping the subscription for orphans"
ORPHAN_IPS="$(az network public-ip list --query "length([?ipConfiguration==null])" -o tsv)"
ORPHAN_NICS="$(az network nic list --query "length([?virtualMachine==null])" -o tsv)"
ORPHAN_NSGS="$(az network nsg list --query "length([?networkInterfaces==null && subnets==null])" -o tsv)"

printf '  unattached public IPs : %s\n' "$ORPHAN_IPS"
printf '  unattached NICs       : %s\n' "$ORPHAN_NICS"
printf '  unused NSGs           : %s\n' "$ORPHAN_NSGS"

if (( ORPHAN_IPS + ORPHAN_NICS + ORPHAN_NSGS > 0 )); then
  log_warn "orphans found elsewhere in the subscription -- these bill for nothing"
  az network public-ip list --query "[?ipConfiguration==null].{name:name,rg:resourceGroup,ip:ipAddress}" -o table
else
  log_info "clean: no orphaned network resources anywhere in the subscription"
fi
```

- [ ] **Step 2: Lint**

Run: `shellcheck scripts/destroy.sh`
Expected: no output.

- [ ] **Step 3: Verify the confirmation guard rejects wrong input**

```bash
chmod +x scripts/destroy.sh
echo "wrong-name" | ./scripts/destroy.sh
```

Expected: exits 1 with `confirmation did not match -- aborted`, and the group still exists.

- [ ] **Step 4: Destroy for real**

Run: `./scripts/destroy.sh` and type `kwang-vpn` at the prompt.
Expected: lists the resources, deletes them, then reports `clean: no orphaned network resources`.

- [ ] **Step 5: Verify nothing survived**

```bash
az group exists -n kwang-vpn
az network public-ip list --query "length([?ipConfiguration==null])" -o tsv
```

Expected: `false` and `0`.

- [ ] **Step 6: Verify the no-op path**

Run: `./scripts/destroy.sh`
Expected: exits 0 with `does not exist -- nothing to do`.

- [ ] **Step 7: Commit**

```bash
git add scripts/destroy.sh
git commit -m "feat: add destroy.sh with subscription orphan sweep"
```

---

### Task 7: rotate-ip.sh

**Files:**
- Create: `scripts/rotate-ip.sh`

**Interfaces:**
- Consumes: `load_config`, `die`, `log_info`, `require_cmd`, `require_az_login`
- Produces: a new public IP on the same VM; updates `VPN_PUBLIC_IP` in `.env`

- [ ] **Step 1: Write the script**

Create `scripts/rotate-ip.sh`:

```bash
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

IP_NAME="${VM_NAME}-ip"
NEW_IP_NAME="${VM_NAME}-ip-$(date +%Y%m%d%H%M%S)"

az vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" >/dev/null 2>&1 \
  || die "VM '$VM_NAME' not found in '$RESOURCE_GROUP'"

NIC_ID="$(az vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" \
  --query "networkProfile.networkInterfaces[0].id" -o tsv)"
NIC_NAME="${NIC_ID##*/}"
IPCFG_NAME="$(az network nic show --ids "$NIC_ID" \
  --query "ipConfigurations[0].name" -o tsv)"
OLD_IP="$(az network public-ip show -g "$RESOURCE_GROUP" -n "$IP_NAME" \
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

log_info "deleting the old address so it stops billing"
az network public-ip delete -g "$RESOURCE_GROUP" -n "$IP_NAME" --output none 2>/dev/null || true

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
```

- [ ] **Step 2: Lint**

Run: `shellcheck scripts/rotate-ip.sh`
Expected: no output.

- [ ] **Step 3: Provision a host to rotate**

```bash
./scripts/provision.sh
source .env && echo "before: $VPN_PUBLIC_IP"
```

- [ ] **Step 4: Rotate**

```bash
chmod +x scripts/rotate-ip.sh
./scripts/rotate-ip.sh
```

Expected: prints `old -> new` with two different addresses.

- [ ] **Step 5: Verify the VM survived and the old IP is gone**

```bash
az vm show -g kwang-vpn -n vpn-cn -d --query "{power:powerState, ip:publicIps}" -o table
az network public-ip list -g kwang-vpn --query "[].{name:name, ip:ipAddress}" -o table
source .env && ssh -o StrictHostKeyChecking=no "$VPN_ADMIN_USER@$VPN_PUBLIC_IP" 'uptime'
```

Expected: `VM running` with the new IP, exactly one public IP in the group, and SSH succeeds — proving the host was never rebuilt.

- [ ] **Step 6: Commit**

```bash
git add scripts/rotate-ip.sh
git commit -m "feat: add rotate-ip.sh for address recovery"
```

---

### Task 8: Operator runbook

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: all three scripts
- Produces: documentation only

- [ ] **Step 1: Replace the "Layout" and "Open decisions" sections of `README.md`**

Replace everything from the `## Layout` heading to the end of the file with:

```markdown
## Setup

Requires the Azure CLI (`brew install azure-cli`), an `az login` session, and
the AmneziaVPN desktop client from https://amnezia.org.

```bash
cp config.env.example config.env   # edit if you want different values
./scripts/provision.sh             # ~90s; prints IP, login, password
```

Then, in the AmneziaVPN desktop client, enter the printed IP, login, and
password. It connects over SSH, installs Docker, and runs one container per
protocol.

**Install AmneziaWG first.** It needs no domain, certificate, or SNI target,
so a failure means the pipeline is wrong rather than the protocol being
detected. Use the UDP port shown in the banner — it is already open in the
network security group. Add XRay REALITY afterwards on TCP 443; both run
side by side as separate containers, which is what makes them comparable on
one host.

Share access to a client device using Amnezia's QR code, text key, or
settings file. Server credentials never leave your machine.

## Client devices

Everyone installs the same app, **AmneziaVPN**, regardless of protocol.

| Device | Source | Catch |
|---|---|---|
| iPhone / iPad | App Store | Needs a **non-mainland-China Apple ID**. Apple removed VPN apps from the China App Store in 2017. |
| Android | APK from GitHub releases | Google Play is unavailable in mainland China; sideloading is normal there. |
| Windows / macOS | Installer from GitHub releases | amnezia.org may be blocked; GitHub generally is not. |

Downloading a VPN client from inside China is a chicken-and-egg problem.
The reliable answer is to download the installer outside China and send the
file directly.

*Amnezia Premium* is a separate paid hosted service. Self-hosting is free and
requires no account.

## Recovery

Test from inside China when the tunnel stops working:

```bash
ssh -p 22 user@<server_ip>
```

| Result | Meaning | Action |
|---|---|---|
| SSH connects | Protocol signature is being matched | Change protocol or port. Rotating the IP will not help. |
| SSH times out | Address is blackholed at the border | `./scripts/rotate-ip.sh` |

## Teardown

```bash
./scripts/destroy.sh
```

Deletes the resource group and then sweeps the whole subscription for
unattached public IPs, NICs, and unused NSGs — Azure does not cascade VM
deletion to networking, so orphans bill silently forever.

## Measurement

The first deployment exists to answer a question no analysis can: which
protocol survives on the target connection, and for how long. Record for
each trial: protocol, port, start date, failure date, and rough traffic
volume before failure.

Before concluding that a protocol is blocked, **confirm its NSG rule
exists**. Azure's network security group and the VM's own iptables are
independent layers and neither logs the other's drops, so a missing NSG rule
looks exactly like censorship.

## Development

```bash
brew install bats-core shellcheck
bats tests/
shellcheck lib/*.sh scripts/*.sh
```
```

- [ ] **Step 2: Verify every command in the runbook is real**

Run each fenced command that does not create billable resources and confirm it behaves as documented.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: add operator runbook for provisioning and recovery"
```

---

## Self-Review

**Spec coverage.** Each spec requirement maps to a task: `provision.sh` scope → Tasks 4–5; `destroy.sh` → Task 6; `rotate-ip.sh` → Task 7; NSG rule table → Task 5; the six operator inputs → Task 2's `config.env.example`; generated password to gitignored `.env` → Tasks 1 and 5; B1s plus swap plus Standard SSD → Tasks 3 and 4; idempotency → Task 4 Step 6; the five-step testing section → verification steps in Tasks 4–7; protocol ordering → the Task 5 banner and Task 8 runbook; measurement protocol → Task 8.

**Placeholders.** None. Every code step contains complete, runnable content.

**Type and name consistency.** `generate_password`, `validate_port`, `validate_ipv4`, `log_info`, `log_warn`, `log_error`, `die`, `require_cmd`, `require_az_login`, `detect_public_ip`, and `load_config` are defined in Tasks 1–2 and used with identical names and arities in Tasks 4–7. Variables `RESOURCE_GROUP`, `LOCATION`, `VM_NAME`, `VM_SIZE`, `ADMIN_USER`, `AMNEZIAWG_PORT`, `XRAY_PORT`, `SSH_ALLOWED_IP`, `IP_NAME`, and `NSG_NAME` are consistent throughout.

**Known gap, deliberate.** Task 5's verification depends on `destroy.sh` from Task 6 to rebuild cleanly; the step gives the raw `az group delete` fallback so Task 5 remains independently completable.
