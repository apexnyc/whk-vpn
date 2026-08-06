# whk-vpn

Censorship-resistant personal VPN endpoints on Azure, for use from mainland China.

## Algo VPN (current approach)

`scripts/algo-vpn.sh` (also copied to `~/Command/algo-vpn.sh` for convenience
on this machine) provisions and tears down Algo VPN endpoints. It runs
[apexnyc/algo-vpn](https://github.com/apexnyc/algo-vpn) — a fork of
trailofbits/algo patched to skip every interactive prompt and stream its
generated client configs back over the same SSH session, instead of needing
a separate pull step.

On a machine that doesn't have the Azure CLI yet, run
`scripts/setup-environment.sh` first — installs `az` (Homebrew on macOS,
Microsoft's apt/dnf repo on Linux) and runs `az login` if needed. Safe to
re-run; every check is a no-op once already satisfied.

```bash
# Create an endpoint. Omit the region for an interactive 1/2/3 prompt.
algo-vpn.sh create uk          # uksouth        -> VM algo-vpn-uk
algo-vpn.sh create australia   # australiaeast  -> VM algo-vpn-australia
algo-vpn.sh create usa         # eastus         -> VM algo-vpn-usa

# See what's currently running
algo-vpn.sh list

# Tear down one endpoint by name -- only that VM and its own NIC/public
# IP/NSG/disk are deleted; other VMs in the resource group are untouched.
algo-vpn.sh destroy algo-vpn-uk
algo-vpn.sh destroy algo-vpn-uk --yes   # skip the type-to-confirm prompt
```

All three regions share the `kwang-vpn` resource group and can run at the same
time. Generated WireGuard/IPsec client configs land in
`~/ProjectX/whk-vpn/configs/<public-ip>/`, with a friendly symlink at
`~/ProjectX/whk-vpn/configs/<vm-name>` pointing at it.

## Amnezia VPN (earlier approach, retired)

The `kwang7/amnezia-azure-provisioning` branch holds an earlier, GUI-client-based
approach using AmneziaVPN. Superseded by Algo above because Amnezia's official
client has no headless install mode, which made unattended, repeatable
provisioning impossible. Kept as history, not deleted — see that branch's
`docs/superpowers/` for the full design record.
