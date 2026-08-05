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
