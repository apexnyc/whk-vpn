# whk-vpn

Censorship-resistant personal VPN endpoints on Azure, for use from mainland China.

## AmneziaWG (Primary Anti-GFW Flow)

`scripts/amnezia-vpn.sh` (invoked via `vpn` command or `scripts/vpn.sh`) provisions and manages AmneziaWG endpoints (`awg-vpn-japan`, `awg-vpn-korea`, `awg-vpn-singapore`, `awg-vpn-hongkong`, `awg-vpn-usa`, `awg-vpn-uk`, etc.). AmneziaWG randomizes WireGuard header parameters (`Jc`, `Jmin`, `Jmax`, `S1`, `S2`, `H1-H4`) to defeat GFW Deep Packet Inspection (DPI).

Provisioning takes **~30 seconds** and generates 7 client profiles & PNG QR code image files stored in `~/Desktop/vpn/<public-ip>/` (symlinked at `~/Desktop/vpn/awg-vpn-<region>/`):
* `<public-ip>-macbook.conf` (Auto-imported into macOS `/Applications/AmneziaWG.app`)
* `<public-ip>-macmini.conf`
* `<public-ip>-iphone.conf` & `<public-ip>-iphone_qr.png`
* `<public-ip>-ipad.conf` & `<public-ip>-ipad_qr.png`
* `<public-ip>-ios.conf` & `<public-ip>-ios_qr.png`
* `<public-ip>-android.conf` & `<public-ip>-android_qr.png`
* `<public-ip>-windows.conf` & `<public-ip>-windows_qr.png`

```bash
# Create an AmneziaWG endpoint by lowercase country name or region
vpn create japan       # japaneast       -> VM awg-vpn-japan (~30s)
vpn create korea       # koreacentral    -> VM awg-vpn-korea
vpn create singapore   # southeastasia   -> VM awg-vpn-singapore
vpn create hongkong    # eastasia        -> VM awg-vpn-hongkong
vpn create usa         # eastus          -> VM awg-vpn-usa
vpn create uk          # uksouth         -> VM awg-vpn-uk
vpn create australia   # australiaeast   -> VM awg-vpn-australia
vpn create germany     # germanywest     -> VM awg-vpn-germany

# Inspect why an endpoint is unreachable (detects Azure status, SSH, AWG daemon, GFW IP null-route vs DPI)
vpn inspect japan      # or: vpn inspect awg-vpn-japan

# Replace endpoint with a fresh Azure IP and new random noise parameters
vpn replace usa

# Fast IP rotation (swaps Azure Public IP in ~15s without deleting VM)
vpn rotate-ip usa

# Display QR code on terminal for a device
vpn qr usa iphone
vpn qr usa ipad

# List all active VPN VMs in resource group kwang-vpn
vpn list

# Tear down one endpoint by VM name
vpn destroy awg-vpn-usa
vpn destroy awg-vpn-usa --yes   # skip confirm prompt
```

## Algo WireGuard (Legacy Flow)

`scripts/algo-vpn.sh` remains 100% supported for standard WireGuard provisioning:

```bash
# Create legacy Algo WireGuard endpoint
vpn create --engine algo usa     # eastus -> VM algo-vpn-usa (~10-15m)
vpn inspect algo-vpn-usa
vpn rotate-ip algo-vpn-usa
vpn destroy algo-vpn-usa --yes
```

All regions share the `kwang-vpn` resource group. Generated client configs land in `~/Desktop/vpn/<public-ip>/`.
