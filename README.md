# whk-vpn

Automated provisioning and management of censorship-resistant personal VPN endpoints on Azure.

## Overview

`whk-vpn` provides shell automation to provision, inspect, and tear down disposable Algo VPN endpoints on Microsoft Azure. It uses [`apexnyc/algo-vpn`](https://github.com/apexnyc/algo-vpn) — a patched fork of [Trail of Bits' Algo VPN](https://github.com/trailofbits/algo) designed to run completely unattended and stream client configuration files back over SSH.

## Features

- **One-command provisioning:** Automatically sets up Azure infrastructure (`Standard_B1s` Ubuntu 24.04 VM, static public IP, NSG) and deploys Algo VPN without interactive prompts.
- **Dynamic IP restriction:** Restricts inbound SSH access on port 22 exclusively to the operator's public IP address at deployment time.
- **Direct config extraction:** Client profiles and WireGuard configs stream directly back to `$HOME/Desktop/vpn/` with convenient symlinks.
- **Granular teardown:** Safely deletes a specific VPN instance (VM, NIC, public IP, NSG, disk) without affecting other endpoints running in the `kwang-vpn` resource group.

## Prerequisites

Before running the provisioning scripts, ensure you have:
- An active Azure subscription.
- Basic UNIX tools: `ssh`, `curl`, `base64`, `tar`.
- `azure-cli` (`az`).

You can run the environment setup script to automatically install `az` (via Homebrew on macOS or `apt`/`dnf`/`yum` on Linux) and perform `az login`:

```bash
./scripts/setup-environment.sh
```
```

## Usage

Use [`scripts/algo-vpn.sh`](file:///Users/kwang7/ProjectX/whk-vpn/scripts/algo-vpn.sh) to manage endpoints:

### Create an Endpoint

Provision a new VPN endpoint in a specific region (`uk`, `australia`, or `usa`). If omitted, an interactive region prompt will appear.

```bash
./scripts/algo-vpn.sh create uk          # uksouth        -> VM algo-vpn-uk
./scripts/algo-vpn.sh create australia   # australiaeast  -> VM algo-vpn-australia
./scripts/algo-vpn.sh create usa         # eastus         -> VM algo-vpn-usa
```

### Inspect an Endpoint

Perform a deep multi-layer diagnostic check to determine why a VPN endpoint is blocked or failing (detecting Azure VM status, operator IP alignment, ICMP reachability, TCP 22 SSH reachability, remote WireGuard daemon status, active peer handshakes, and GFW DPI vs IP null-routing block reasons):

```bash
vpn inspect usa                         # inspect algo-vpn-usa
vpn inspect algo-vpn-uk                 # inspect algo-vpn-uk
./scripts/algo-vpn.sh inspect australia # inspect algo-vpn-australia
```

### Rotate Public IP (Fast ~15s IP Swap)

Swap the Azure public IP attached to the VM's network interface without deleting the VM, wiping server storage, or re-running Ansible. The script automatically syncs authentic client configs from the server, updates local `.conf` files in `$HOME/Desktop/vpn/`, regenerates all PNG QR code files, re-imports into WireGuard macOS GUI, and renders a terminal QR code for iPad scanning:

```bash
vpn rotate-ip usa                         # swaps IP for algo-vpn-usa
./scripts/algo-vpn.sh rotate-ip uk        # swaps IP for algo-vpn-uk
```

### Replace an Endpoint

Non-interactively tear down an existing endpoint in a region (if it exists) and immediately provision a fresh one:

```bash
./scripts/algo-vpn.sh replace usa         # replaces algo-vpn-usa without confirmation
./scripts/algo-vpn.sh replace uk
./scripts/algo-vpn.sh replace australia
```

### List Running Endpoints

Display all active VPN virtual machines, their power states, locations, and public IPs in the `kwang-vpn` resource group:

```bash
./scripts/algo-vpn.sh list
```

### Destroy an Endpoint

Tear down a specific VPN instance and clean up associated Azure resources (NIC, public IP, NSG, managed disk) and local client configs:

```bash
./scripts/algo-vpn.sh destroy algo-vpn-uk
./scripts/algo-vpn.sh destroy algo-vpn-uk --yes   # skip interactive confirmation
```

## Project Structure

```
.
├── CLAUDE.md                             # Agent operating guide & workflow summary
├── README.md                             # Project documentation
├── scripts/
│   ├── algo-vpn.sh                       # Provisioning & lifecycle script for Azure Algo VPN endpoints
│   └── setup-environment.sh              # Prerequisites installer & Azure CLI authenticator
└── docs/
    └── azure-kwang-vpn-teardown-record-2026-08-04.md  # Audit log of historical Azure VPN estate
```

## Context & Future Work

Standard WireGuard handshakes have fixed-length packet headers easily identified by Deep Packet Inspection (DPI) in restrictive network environments (such as mainland China home broadband). While disposable IP rotation via Algo VPN enables quick recovery when endpoints are blocked, future iterations aim to integrate obfuscated transports (e.g. AmneziaWG or Xray with VLESS + REALITY) for long-term censorship resistance.

