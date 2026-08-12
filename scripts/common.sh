#!/usr/bin/env bash
# common.sh — Shared helper functions, logging, and region mapping for whk-vpn scripts.
set -euo pipefail

RESOURCE_GROUP="kwang-vpn"
ADMIN_USER="kwang7"
CONFIGS_DIR="$HOME/Desktop/vpn"

log_info()  { printf '[INFO]  %s\n'  "$*" >&2; }
log_warn()  { printf '[WARN]  %s\n'  "$*" >&2; }
log_error() { printf '[ERROR] %s\n'  "$*" >&2; }
die()       { log_error "$*"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1 (run scripts/setup-environment.sh)"
}

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

# region_to_params <region-or-country-input> [vm-prefix]
# Sets global variables LOCATION and VM_NAME
region_to_params() {
  local input="${1:-}"
  local prefix="${2:-awg-vpn-}"
  local reg
  reg="$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')"

  case "$reg" in
    usa|us|unitedstates)             LOCATION="eastus";             VM_NAME="${prefix}usa" ;;
    uk|unitedkingdom|britain)        LOCATION="uksouth";            VM_NAME="${prefix}uk" ;;
    australia|aus)                   LOCATION="australiaeast";      VM_NAME="${prefix}australia" ;;
    japan|jp)                        LOCATION="japaneast";          VM_NAME="${prefix}japan" ;;
    korea|kr|southkorea)             LOCATION="koreacentral";       VM_NAME="${prefix}korea" ;;
    singapore|sg)                    LOCATION="southeastasia";      VM_NAME="${prefix}singapore" ;;
    hongkong|hk)                     LOCATION="eastasia";           VM_NAME="${prefix}hongkong" ;;
    germany|de)                      LOCATION="germanywestcentral"; VM_NAME="${prefix}germany" ;;
    france|fr)                       LOCATION="francecentral";      VM_NAME="${prefix}france" ;;
    netherlands|nl|holland)          LOCATION="westeurope";         VM_NAME="${prefix}netherlands" ;;
    canada|ca)                       LOCATION="canadacentral";      VM_NAME="${prefix}canada" ;;
    sweden|se)                       LOCATION="swedencentral";      VM_NAME="${prefix}sweden" ;;
    switzerland|ch)                  LOCATION="switzerlandnorth";   VM_NAME="${prefix}switzerland" ;;
    india|in)                        LOCATION="centralindia";       VM_NAME="${prefix}india" ;;
    brazil|br)                       LOCATION="brazilsouth";        VM_NAME="${prefix}brazil" ;;
    italy|it)                        LOCATION="italynorth";         VM_NAME="${prefix}italy" ;;
    spain|es)                        LOCATION="spaincentral";       VM_NAME="${prefix}spain" ;;
    poland|pl)                       LOCATION="polandcentral";      VM_NAME="${prefix}poland" ;;
    norway|no)                       LOCATION="norwayeast";         VM_NAME="${prefix}norway" ;;
    uae)                             LOCATION="uaenorth";           VM_NAME="${prefix}uae" ;;
    ireland|ie)                      LOCATION="northeurope";        VM_NAME="${prefix}ireland" ;;
    indonesia|id)                    LOCATION="indonesiacentral";   VM_NAME="${prefix}indonesia" ;;
    malaysia|my)                     LOCATION="malaysiawest";       VM_NAME="${prefix}malaysia" ;;
    mexico|mx)                       LOCATION="mexicocentral";      VM_NAME="${prefix}mexico" ;;
    southafrica|za)                  LOCATION="southafricanorth";   VM_NAME="${prefix}southafrica" ;;
    *)
      if [[ -n "$reg" ]]; then
        LOCATION="$reg"
        if [[ "$reg" =~ ^${prefix} ]]; then
          VM_NAME="$reg"
        else
          VM_NAME="${prefix}${reg}"
        fi
      else
        die "region or country name is required"
      fi
      ;;
  esac
}

prompt_region() {
  local prompt_title="${1:-VPN}"
  echo "Which region/country for $prompt_title?" >&2
  echo "  1) Japan       (japaneast)" >&2
  echo "  2) Korea       (koreacentral)" >&2
  echo "  3) Singapore   (southeastasia)" >&2
  echo "  4) Hong Kong   (eastasia)" >&2
  echo "  5) USA         (eastus)" >&2
  echo "  6) UK          (uksouth)" >&2
  echo "  7) Australia   (australiaeast)" >&2
  echo "  8) Germany     (germanywestcentral)" >&2
  echo "  9) France      (francecentral)" >&2
  echo " 10) Netherlands (westeurope)" >&2
  echo " 11) Canada      (canadacentral)" >&2
  read -r -p "Enter number or country name (e.g. japan): " choice
  choice="$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')"
  case "$choice" in
    1) echo japan ;;
    2) echo korea ;;
    3) echo singapore ;;
    4) echo hongkong ;;
    5) echo usa ;;
    6) echo uk ;;
    7) echo australia ;;
    8) echo germany ;;
    9) echo france ;;
    10) echo netherlands ;;
    11) echo canada ;;
    *)
      if [[ -n "$choice" ]]; then
        echo "$choice"
      else
        die "invalid choice: $choice"
      fi
      ;;
  esac
}
