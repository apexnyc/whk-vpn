# Azure `kwang-vpn` — Configuration Record Before Teardown

**Recorded:** 2026-08-04
**Subscription:** Visual Studio Enterprise Subscription (`6df64017-6b2a-45b0-bda3-4ef45f0a44ac`)
**Resource group:** `kwang-vpn`
**Reason:** Monthly credit exhausted, subscription auto-disabled. Tearing down all VPN
infrastructure to stop the drain and rebuild on an obfuscated stack.

All figures below were read live from `az` CLI on the date above. Nothing here is
reconstructed from memory.

---

## 1. `vpn-66` — full configuration

The VM this record was requested for.

### Compute

| Property | Value |
|---|---|
| Name | `vpn-66` |
| Resource ID | `/subscriptions/6df64017-.../resourceGroups/kwang-vpn/providers/Microsoft.Compute/virtualMachines/vpn-66` |
| VM ID | `3c3ff795-cc05-4f06-b865-107f680c28cb` |
| Location / Zone | `westus2` / zone `1` |
| Size | `Standard_B1s` (1 vCPU, 1 GiB RAM, burstable) |
| Created | 2026-04-14T01:21:45Z |
| Power state at teardown | **deallocated** |

### Operating system

| Property | Value |
|---|---|
| Publisher / Offer | `canonical` / `ubuntu-24_04-lts` |
| SKU | `server` |
| Exact version | `24.04.202603290` |
| OS type | Linux, Hyper-V generation **V2** |

> Note: Ubuntu **24.04**. Upstream Algo supports **22.04 only**. This mismatch is the
> likely source of the `distutils`/Python 3.12 errors recorded in the old runbook —
> `distutils` was removed from the stdlib in Python 3.12, which ships as default on 24.04.

### Identity and access

| Property | Value |
|---|---|
| Admin username | `kwang7` |
| Computer name | `vpn-66` |
| `disablePasswordAuthentication` | `false` → **password authentication ENABLED** |
| SSH public keys configured | **none (0)** |

> Security finding: password SSH on a public IP with port 22 open to `*`. Same on all
> four VMs in this group. Do not reproduce this in the replacement build.

### Storage

| Property | Value |
|---|---|
| OS disk | `vpn-66_OsDisk_1_1d45f0a16d9040f69e20b3232d662cf8` |
| Unique ID | `1d45f0a1-6d90-40f6-9e20-b3232d662cf8` |
| Size | 30 GB |
| SKU | `Standard_LRS` |
| Throughput | 60 MBps |
| Caching | ReadWrite |
| Create option | FromImage |
| Encryption | `EncryptionAtRestWithPlatformKey` |
| Disk state at teardown | `Reserved` (billing while VM deallocated) |
| Data disks | none |

### Networking

| Property | Value |
|---|---|
| Public IP resource | `vpn-66-ip` |
| **Public IP address** | **`20.9.145.163`** |
| Allocation | **Static** |
| SKU / Tier | `Standard` / `Regional` |
| IP version | IPv4 |
| Idle timeout | 4 minutes |
| DNS FQDN | none |
| NIC | `vpn-66796_z1` |
| Private IP | `10.0.0.4` (Dynamic) |
| IP forwarding | disabled |
| Accelerated networking | disabled |
| VNet | `vpn-66-vnet`, address space `10.0.0.0/16` |
| Subnet | `default`, `10.0.0.0/24` |

### Firewall (NSG `vpn-66-nsg`)

| Priority | Name | Direction | Access | Protocol | Port | Source |
|---|---|---|---|---|---|---|
| 300 | `SSH` | Inbound | Allow | TCP | 22 | `*` |
| 310 | `Port_51820` | Inbound | Allow | Any | 51820 | `*` |

No IPsec rules (UDP 500/4500) — this was a **WireGuard-only** deployment.

### Rebuild-equivalent command

Recreates the same shape. **Do not use as-is** — it reproduces the security posture
documented above. Kept for reference only.

```bash
az vm create \
  --resource-group kwang-vpn \
  --name vpn-66 \
  --location westus2 \
  --zone 1 \
  --size Standard_B1s \
  --image canonical:ubuntu-24_04-lts:server:24.04.202603290 \
  --admin-username kwang7 \
  --os-disk-size-gb 30 \
  --storage-sku Standard_LRS \
  --public-ip-sku Standard \
  --public-ip-address-allocation static \
  --generate-ssh-keys          # NOT --authentication-type password
```

---

## 2. Other VMs in the group (added — teardown destroys these too)

Not explicitly requested, but captured because deletion is irreversible.

| VM | Region | Size | Image (exact) | Admin | SSH auth | Created | Public IP |
|---|---|---|---|---|---|---|---|
| `vpn-32` | eastus | B1s | `0001-com-ubuntu-server-focal/20_04-lts-gen2` (20.04.202407150) | `kwang7` | password, 0 keys | 2024-07-24 | 172.210.61.91 |
| `aus-vpn` | australiaeast | B1s | `ubuntu-24_04-lts/server` (24.04.202606060) | `kwang7` | password, 0 keys | 2026-07-06 | 20.28.138.65 |
| `vpn-uk` | uksouth | B1s | `ubuntu-24_04-lts/server` (24.04.202605310) | `kwang7` | password, 0 keys | 2026-06-06 | 20.77.104.185 |

All three carry the identical NSG pattern — SSH TCP/22 from `*`, and port **51820**
(any protocol) from `*`:

```
vpn-32-nsg   300 SSH TCP 22 *   |  310 AllowAnyCustom51820Inbound * 51820 *
aus-vpn-nsg  300 SSH TCP 22 *   |  310 p_51820                    * 51820 *
vpn-uk-nsg   300 SSH TCP 22 *   |  310 P_51820                    * 51820 *
```

`vpn-32` runs **Ubuntu 20.04**, whose standard support ended April 2025 — unpatched for
over a year while internet-facing.

---

## 3. Full resource inventory at teardown (34 resources)

| Type | Resources |
|---|---|
| Virtual machines (4) | `vpn-32`, `vpn-66`, `vpn-uk`, `aus-vpn` |
| Managed disks (4) | `vpn-32_OsDisk_1_692a701f…`, `vpn-66_OsDisk_1_1d45f0a1…`, `vpn-uk_OsDisk_1_5159ea18…`, `aus-vpn_OsDisk_1_aff89e54…` |
| Public IPs (4) | `vpn-32-ip` (172.210.61.91), `vpn-66-ip` (20.9.145.163), `vpn-uk-ip` (20.77.104.185), `aus-vpn-ip` (20.28.138.65) |
| NICs (4) | `vpn-32609_z1`, `vpn-66796_z1`, `vpn-uk761_z1`, `aus-vpn699_z1` |
| VNets (8) | `kwang-vpn-vnet`, `vnet-eastus`, `vnet-centralus`, `vpn-66-vnet`, `vpn-uk-vnet`, `australia-vnet`, `vpn-india-vnet`, `vpn-36-vnet` |
| NSGs (10) | `vpn-32-nsg`, `vpn-66-nsg`, `vpn-uk-nsg`, `aus-vpn-nsg`, `vpn-nsg`, `vpn-65-nsg`, `australia-nsg`, `vpn-india-nsg`, `vpn-india-2-nsg`, `vpnindiansg428` |

**Orphan ratio:** 10 NSGs and 8 VNets for 4 live VMs. Regions represented include
`centralindia`, `israelcentral`, and `centralus` with no surviving VM — the residue of
earlier deployments. `vpn-65` (israelcentral) was deleted manually on 2026-08-05T02:03Z.

---

## 4. What is NOT captured here

**On-box configuration was not recoverable.** All four VMs were deallocated, so no SSH
session was possible. The following are lost when the disks are deleted:

- WireGuard server private keys and `wg0.conf`
- The peer list (client public keys)
- Algo's generated `configs/` output — client `.conf` files, QR codes, IPsec `.p12`
  bundles and CA
- Host-level iptables/ufw rules written by Algo

No local copy exists on the Mac either — there is no `~/algo` or `~/algo-vpn` directory.

**This was judged acceptable**: every client config points at a burned IP, using a
fingerprinted protocol, on a flagged default port. All three properties are being
replaced.

---

## 5. Observations carried forward to the rebuild

1. **Default port 51820 was open to the world on every host.** Combined with WireGuard's
   fixed 148-byte handshake signature, each server was identifiable twice over — by port
   scan and by packet inspection.
2. **Static public IPs are the wrong allocation model here.** They survive deallocation,
   so a burned address stays burned across stop/start. IP reputation is the fast-moving
   failure domain and needs to be disposable.
3. **Password SSH on `*` with no keys, on all four hosts.** Replace with key-only auth and
   an NSG source restriction.
4. **Geographic scatter did not solve a protocol-layer problem.** Six-plus endpoints
   across India, Israel, Australia, UK, and two US regions all failed the same way. None
   of these regions is a good China endpoint anyway — Japan East, Korea Central, or East
   Asia would materially reduce RTT.
5. **Metered egress is a poor fit for a VPN.** Azure bills outbound per GB against a
   capped monthly credit; exhausting it disabled the entire subscription.
6. **Shared-fate risk.** This subscription also hosts `apex-trading`, `whk-relay-board`,
   `iot-hub`, `nightwing`, `function-apps-group`, and `kwang-gai`. VPN bandwidth taking
   the credit to zero takes those down with it. The replacement should not share a
   billing boundary with trading infrastructure.
