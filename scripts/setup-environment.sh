#!/usr/bin/env bash
# setup-environment.sh — bootstraps a fresh machine to run algo-vpn.sh:
# installs the Azure CLI if it's missing, verifies the other tools
# algo-vpn.sh needs (all standard on macOS/Linux), and gets you logged in
# to Azure. Safe to re-run; every step is a no-op once already satisfied.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

install_az_macos() {
  if ! command -v brew >/dev/null 2>&1; then
    die "Homebrew not found. Install it from https://brew.sh, then re-run this script."
  fi
  log_info "installing azure-cli via Homebrew"
  brew install azure-cli
}

install_az_linux() {
  if command -v apt-get >/dev/null 2>&1; then
    log_info "installing azure-cli via Microsoft's apt install script"
    curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
  elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    log_info "installing azure-cli via Microsoft's yum/dnf repo"
    sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
    sudo dnf install -y https://packages.microsoft.com/config/rhel/9/packages-microsoft-prod.rpm 2>/dev/null \
      || sudo yum install -y https://packages.microsoft.com/config/rhel/9/packages-microsoft-prod.rpm
    (command -v dnf >/dev/null 2>&1 && sudo dnf install -y azure-cli) \
      || sudo yum install -y azure-cli
  else
    die "no supported package manager found (apt-get/dnf/yum). Install manually: https://learn.microsoft.com/cli/azure/install-azure-cli-linux"
  fi
}

ensure_az() {
  if command -v az >/dev/null 2>&1; then
    log_info "az CLI already installed"
    return
  fi
  log_warn "az CLI not found -- installing"
  case "$(uname -s)" in
    Darwin) install_az_macos ;;
    Linux)  install_az_linux ;;
    *) die "unsupported OS: $(uname -s). Install az manually: https://learn.microsoft.com/cli/azure/install-azure-cli" ;;
  esac
  command -v az >/dev/null 2>&1 \
    || die "az install appeared to succeed but 'az' is still not on PATH -- open a new shell and re-run this script"
}

ensure_tool() {
  command -v "$1" >/dev/null 2>&1 \
    || die "required command not found: $1 -- this should ship with macOS/Linux, so something unusual about this machine needs a look"
}

ensure_qrencode() {
  if command -v qrencode >/dev/null 2>&1; then
    log_info "qrencode already installed"
    return
  fi
  log_warn "qrencode not found -- installing to enable PNG & terminal QR code generation"
  case "$(uname -s)" in
    Darwin)
      if command -v brew >/dev/null 2>&1; then
        brew install qrencode
      fi
      ;;
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get install -y qrencode
      elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y qrencode
      elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y qrencode
      fi
      ;;
  esac
}

ensure_login() {
  if az account show >/dev/null 2>&1; then
    local sub
    sub="$(az account show --query name -o tsv)"
    log_info "already logged in to Azure -- active subscription: $sub"
  else
    log_info "not logged in -- opening browser for 'az login'"
    az login
  fi
}

log_info "checking prerequisites for algo-vpn.sh"
ensure_az
ensure_qrencode
for tool in ssh curl base64 tar; do
  ensure_tool "$tool"
done
ensure_login

log_info "all set. Run: ./scripts/algo-vpn.sh create [uk|australia|usa]"
