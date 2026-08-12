# whk-vpn

Automated provisioning and management of censorship-resistant personal VPN endpoints on Azure.

## Overview

`whk-vpn` provides shell automation to provision, inspect, and tear down disposable VPN endpoints on Microsoft Azure designed to beat Great Firewall (GFW) blocking in mainland China.

It supports two VPN protocol engines:
1. **AmneziaWG (Default / Primary)**: Obfuscated WireGuard protocol fork with randomized header parameters (`Jc`, `Jmin`, `Jmax`, `S1`, `S2`, `H1-H4`) designed to defeat GFW Deep Packet Inspection (DPI) header matching. Fast ~30-second deployment with instant terminal QR codes for mobile devices.
2. **Algo WireGuard (Legacy)**: Standard WireGuard deployment via [`apexnyc/algo-vpn`](https://github.com/apexnyc/algo-vpn).

---

## Features

- **Multi-Device Support:** Auto-generates 7 client profiles and **PNG QR code image files** for **MacBook**, **Mac Mini**, **iPhone**, **iPad**, **iOS**, **Android**, and **Windows**.
- **PNG & Terminal QR Codes:** Saves `.png` image files (`iphone_qr.png`, `ipad_qr.png`, `android_qr.png`, etc.) directly to disk and renders ANSI QR codes in terminal for 1-tap camera scanning into mobile apps.
- **GFW DPI Resistance:** AmneziaWG obfuscation header scrambling prevents GFW from detecting standard WireGuard handshakes.
- **Dynamic IP Restriction:** Restricts inbound SSH access on port 22 exclusively to the operator's public IP address.
- **Deep Diagnostic Inspection:** `vpn inspect` detects Azure VM power state, SSH reachability, daemon status, active handshakes, and GFW IP null-routing vs DPI blocks.

---

## Prerequisites

Before running the provisioning scripts, ensure you have:
- An active Azure subscription.
- Basic UNIX tools: `ssh`, `curl`, `base64`, `tar`.
- `azure-cli` (`az`).

Run the setup script to install dependencies and authenticate Azure:

```bash
./scripts/setup-environment.sh
```

---

## Usage

Manage endpoints using the unified [`scripts/vpn.sh`](file:///Users/kwang7/ProjectX/whk-vpn/scripts/vpn.sh) CLI (aliased as `vpn`):

### Create an Endpoint

Provision a new AmneziaWG endpoint (default) or legacy Algo endpoint using lowercase country names (`japan`, `korea`, `singapore`, `hongkong`, `usa`, `uk`, `australia`, `germany`, `france`, `canada`, etc.) or raw Azure region names (`japaneast`, `koreacentral`, `eastus`):

```bash
vpn create japan                       # AmneziaWG japaneast      -> VM awg-vpn-japan (~30s)
vpn create korea                       # AmneziaWG koreacentral   -> VM awg-vpn-korea
vpn create singapore                   # AmneziaWG southeastasia  -> VM awg-vpn-singapore
vpn create hongkong                    # AmneziaWG eastasia       -> VM awg-vpn-hongkong
vpn create usa                         # AmneziaWG eastus         -> VM awg-vpn-usa
vpn create uk                          # AmneziaWG uksouth        -> VM awg-vpn-uk
vpn create australia                   # AmneziaWG australiaeast  -> VM awg-vpn-australia

# Legacy Algo WireGuard:
vpn create --engine algo japan        # Algo WireGuard           -> VM algo-vpn-japan (~10-15m)
```

### Inspect an Endpoint

Perform a deep multi-layer diagnostic check to detect Azure status, IP alignment, SSH reachability, daemon state, and GFW blocking:

```bash
vpn inspect usa                         # inspect awg-vpn-usa or algo-vpn-usa
vpn inspect awg-vpn-uk
```

### Rotate Public IP (Fast ~15s IP Swap)

Swap the Azure public IP attached to the VM's network interface without deleting the VM, wiping server storage, or re-running Ansible. The script automatically syncs authentic client configs from the server, updates local `.conf` files in `$HOME/Desktop/vpn/`, regenerates all PNG QR code files, re-imports into WireGuard macOS GUI, and renders a terminal QR code for iPad scanning:

```bash
vpn rotate-ip usa                         # swaps IP for algo-vpn-usa
./scripts/algo-vpn.sh rotate-ip uk        # swaps IP for algo-vpn-uk
```

### Replace an Endpoint

Tear down an existing endpoint in a region and immediately provision a fresh VM with a new public IP and fresh noise parameters:

```bash
vpn replace usa                         # replaces awg-vpn-usa with new IP & noise params
vpn replace --engine algo uk            # replaces algo-vpn-uk
```

### List Running Endpoints

Display all active VPN virtual machines in the `kwang-vpn` resource group:

```bash
vpn list
```

### Destroy an Endpoint

Tear down a specific VM instance and delete associated Azure resources:

```bash
vpn destroy awg-vpn-usa
vpn destroy algo-vpn-uk --yes           # skip confirmation prompt
```

---

## Project Structure

```
.
├── CLAUDE.md                             # Agent operating guide & workflow summary
├── README.md                             # Project documentation
├── scripts/
│   ├── vpn.sh                            # Unified CLI entrypoint controller
│   ├── amnezia-vpn.sh                    # AmneziaWG provisioner, QR generator & inspector (~30s build)
│   ├── algo-vpn.sh                       # Legacy Algo WireGuard provisioner & inspector
│   ├── common.sh                         # Shared region resolution, logging & Azure utilities
│   └── setup-environment.sh              # Prerequisites installer & Azure CLI authenticator
└── docs/
    ├── amneziawg-client-guide.md         # AmneziaWG client setup & App Store guide
    ├── wireguard-gui-auto-import.md      # macOS WireGuard GUI AppleScript auto-import guide
    └── azure-kwang-vpn-teardown-record-2026-08-04.md  # Audit log of historical Azure VPN estate
```
