# whk-vpn

Automated provisioning of a censorship-resistant personal VPN endpoint.

**Status: implemented and deployed.** `vpn-cn` is live in the `kwang-vpn` resource group.

## Goal

A single command that provisions a VPN server and returns importable client
configuration files, usable from mainland China on ordinary domestic broadband.

## Why this exists

The previous setup — [Algo VPN](https://github.com/trailofbits/algo) running stock
WireGuard on Azure — was blocked from mainland China within roughly 48 hours of each
deployment, repeatedly, across six-plus endpoints in six regions.

The cause is protocol-level, not geographic. WireGuard's handshake is a fixed-length
packet with a fixed type byte and three zero reserved bytes, making it trivially
identifiable by deep packet inspection. Algo's own FAQ is explicit that this is out of
scope for the project:

> Algo is designed for privacy and security, not censorship avoidance… it won't hide the
> fact that you're using a VPN or help you access blocked content in restrictive
> countries.

Rotating IP addresses and regions treats the symptom. This project targets the cause by
deploying an obfuscated transport instead.

## Constraints

- **Target network:** ordinary Chinese home broadband — no roaming, no leased line
- **Clients:** macOS and iPadOS (US App Store)
- **Billing isolation:** not currently satisfied — accepted risk. This deployment shares
  the same Azure subscription as `apex-trading` (see design doc Decision #5), which is the
  same failure mode that took down the prior deployment when the monthly credit was
  exhausted. Accepted for now because projected VPN spend (~$28/month) sits well within the
  monthly credit; revisit if usage approaches the cap.
- **Disposable infrastructure:** the server is rebuilt, not repaired. IP addresses are
  treated as consumable.

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

SSH is NSG-restricted to the operator's own IP only (see `## Setup`'s NSG rules), so an
SSH attempt from inside China is always dropped at the firewall regardless of whether
censorship is actually happening there — it cannot distinguish anything. Port 443 (XRay
REALITY), by contrast, is open to `*`, so probe that instead when the tunnel stops working:

```bash
nc -vz <server_ip> 443
```

| Result | Meaning | Action |
|---|---|---|
| Connects (or "refused") | The address itself is reachable; protocol-level blocking is happening | Change protocol or port. Rotating the IP will not help. |
| Times out | Address is blackholed at the border | `./scripts/rotate-ip.sh` |

### Updating the SSH NSG rule

If the operator's own public IP changes and SSH access to the VM is lost, update the
`ssh` NSG rule to the new address:

```bash
az network nsg rule update -g kwang-vpn --nsg-name vpn-cn-nsg -n ssh \
  --source-address-prefixes "$(curl -fsS https://api.ipify.org)"
```

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
shellcheck -x -P SCRIPTDIR lib/*.sh scripts/*.sh
```
