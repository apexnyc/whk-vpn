# Design: Azure provisioning for an Amnezia-hosted VPN

**Date:** 2026-08-04
**Status:** Draft, awaiting review

## Purpose

Provide a single command that prepares an Azure VM ready for AmneziaVPN to install a
censorship-resistant VPN server onto, plus commands to tear it down and to rotate its
public IP.

The end user is the author's parents, on ordinary home broadband in mainland China.

## Why this shape

AmneziaVPN's server installer is a **desktop GUI with no headless mode**. It connects to a
bare Linux host over SSH and installs Docker containers, one per protocol. That step
cannot be scripted.

Everything *around* it can be, and that is precisely the part that failed before: six-plus
Azure deployments were created by hand across six regions, none were cleanly destroyed, and
the residue (ten orphaned network security groups, four idle static IPs, eight virtual
networks) accumulated until the subscription's monthly credit was exhausted and Azure
disabled it.

So the split is:

| Layer | Owner | Automated? |
|---|---|---|
| Azure infrastructure | this project's scripts | **yes** |
| VPN protocol install | AmneziaVPN desktop client | no — GUI only |
| Client connection | AmneziaVPN mobile/desktop app | no — user action |

## Architecture

```
  operator's MacBook
    │
    │  1. ./scripts/provision.sh            ──► Azure: resource group, VM,
    │     (bash + az CLI)                          NSG, static public IP
    │                                                    │
    │  2. AmneziaVPN desktop ──SSH──────────────────────►│ installs Docker +
    │     (IP, login, password from step 1)              │ protocol containers
    │                                                    │
    │  3. export config (QR / text key / file)           │
    ▼                                                    │
  parents' device ──────────────────────────────────────►│ AmneziaVPN app connects
```

## Scope of the scripts

### `provision.sh`

Creates, in the **`kwang-vpn` resource group** — dedicated to this VPN and nothing else, so
teardown stays a single atomic operation:

- Ubuntu 24.04 LTS VM, `Standard_B1s` (1 vCPU, 1 GB RAM)
- 32 GB Standard SSD (`E4`) OS disk
- A **2 GB swap file**, configured at first boot
- Static Standard-SKU public IP
- Network security group with the rules below
- Linux admin user with a generated password

**On sizing.** Docker plus both protocol containers occupies roughly 600 MB, leaving about
400 MB of headroom on a 1 GB host. Steady-state VPN forwarding is CPU and network work and
uses almost no memory; the spikes come from `docker pull` and `apt upgrade`. The swap file
converts a potential out-of-memory kill into a temporary slowdown, which for a remote box
that non-technical users depend on is the difference between degraded and dead.

Standard SSD is retained rather than the cheaper Standard HDD specifically *because* of that
swap dependency — Standard HDD delivers around 500 IOPS at millisecond latency, so swapping
on it is punitive, and it would engage exactly when the host is already under pressure. The
$0.86/month difference does not justify crippling the only safety valve. Were the host
sized at 2 GB and not reliant on swap, Standard HDD would be the correct choice, since disk
throughput is otherwise irrelevant to a VPN.

Prints, at the end, exactly the three values AmneziaVPN's connection dialog asks for:
public IP, login, password.

Must be **idempotent**: re-running against an existing deployment reports current state
rather than creating duplicates.

### `destroy.sh`

Deletes the resource group. One operation, dependency-ordered by Azure. This exists because
its absence is what caused the orphan accumulation described above.

### `rotate-ip.sh`

Detaches the public IP, allocates a new one, attaches it to the same NIC. The VM, its
Docker containers, and all protocol keys survive. This is the recovery path when an address
is blocked at the border rather than the protocol being detected — the two failure modes are
distinguished by whether SSH to the address still connects from inside China.

## Network security group rules

| Priority | Port | Protocol | Source | Purpose |
|---|---|---|---|---|
| 300 | 22 | TCP | **operator's public IP only** | SSH for the Amnezia installer |
| 310 | 443 | TCP | `*` | XRay REALITY |
| 320 | configurable | UDP | `*` | AmneziaWG |

Two firewalls exist and neither reports the other's drops: Azure's NSG sits in front of the
VM, and Amnezia configures iptables inside it. A protocol can install successfully, report
success, and never pass traffic because the NSG silently discards it. Always confirm the NSG
rule before concluding a protocol has been blocked by censorship — otherwise a working
protocol gets discarded on a false negative.

The previous deployment left port 22 open to the entire internet with **password
authentication enabled and no SSH keys**, on all four hosts. Restricting source to the
operator's address is the direct remedy.

## What the operator must provide

| # | Input | Notes |
|---|---|---|
| 1 | Azure subscription | See open decision on billing isolation below |
| 2 | Region | `westus2`. US West is roughly 150ms from mainland China versus ~230ms for US East, so it is the better of the two US options. Japan East or Korea Central would reach ~60ms and remain the strongest choice if latency proves uncomfortable |
| 3 | Admin username | Any Linux username; becomes the Amnezia SSH login |
| 4 | Operator's current public IP | Locks the SSH rule; script can detect it automatically with an override flag |
| 5 | AmneziaWG UDP port | Any high port. Not 51820 — that is WireGuard's registered port and was scanned and blocked on every prior deployment |
| 6 | AmneziaVPN desktop client | Installed on the operator's Mac before running step 2 |

The admin **password is generated by the script**, not supplied. It is echoed once to
stdout and written to `.env` in the repository root, which `.gitignore` already excludes.

## Security decisions

**Password SSH authentication is enabled**, because AmneziaVPN's documented connection flow
authenticates with a username and password. This is a real weakening, mitigated three ways:

1. NSG restricts port 22 to the operator's address, so the internet cannot reach it
2. The password is generated at 32+ characters, not chosen by a human

Password authentication **stays enabled after the install**, by decision. Disabling it would
force a manual re-enable every time a protocol is changed or reinstalled, which is a
frequent operation during the measurement phase this project is built for. The NSG source
restriction is what actually protects the port; with it in place, disabling password auth
adds little. This differs from the retired deployment, where password auth was enabled *and*
port 22 was open to the entire internet.

**The Amnezia client receives the VM's admin password.** This is inherent to its design and
is an accepted trust decision: the host is a single-purpose VPN box holding no other data,
created and destroyed by these scripts.

**Generated credentials must never be committed.** The repository's `.gitignore` already
excludes `configs/`, `*.conf`, `.env`, and `*.key` for this reason — VPN client
configurations embed private keys in plaintext, and git history preserves them permanently
even after deletion.

## Implementation language

**Bash plus the `az` CLI.** The work is a short, linear sequence of `az` invocations;
a Python layer would add dependency management for no benefit, and bash keeps the script
directly comparable to Azure's own documentation. If the project later grows multiple
endpoints, health checks, or failover, that logic warrants Python and this decision should
be revisited.

## Testing

No unit-test surface — the script's behaviour is entirely Azure API calls. Verification is
therefore end-to-end and manual:

1. `provision.sh` into a scratch resource group; confirm the VM exists and SSH succeeds from
   the operator's IP and fails from anywhere else
2. Run it a second time; confirm no duplicate resources appear
3. Complete an Amnezia install; confirm a client connects
4. `rotate-ip.sh`; confirm the address changes and the VM and containers survive
5. `destroy.sh`; confirm `az group exists` returns false and no orphaned public IPs, NICs,
   or NSGs remain anywhere in the subscription

Step 5 is not optional. The failure this project exists to prevent is silent resource
accumulation, and only an explicit post-teardown sweep proves it did not happen.

## Deliberately out of scope

Deferred until a protocol is proven to survive on the target connection. Building these
before that is known would industrialise a guess:

- Multiple endpoints with automatic failover
- Uptime monitoring and alerting
- DNS indirection, so client configs survive an IP change untouched
- Router-based deployment covering every device on the parents' network with no client app
- Automating the Amnezia protocol install itself

DNS indirection and failover are the two that matter most for a stability phase, because
availability here is dominated by how quickly a human notices and reacts, not by server
reliability.

## Cost

Verified against Azure's public retail price API for `westus2` on 2026-08-04:

| Item | Rate | Monthly at 24/7 |
|---|---|---|
| `Standard_B1s` VM | $0.0104 / hour | $7.59 |
| Standard SSD 32 GB (E4 LRS) | — | $2.40 |
| Static Standard IPv4 address | $0.005 / hour | $3.65 |
| **Fixed subtotal** | | **≈ $13.64** |
| Egress | first 100 GB/month free, then ≈ $0.08/GB | usage-dependent |

Alternatives considered, same region: `Standard_B1ms` at $15.11/month buys 2 GB RAM and
removes the swap dependency; `Standard_B2s` at $30.37 is unnecessary. Standard HDD (`S4`) at
$1.54/month would save $0.86 but is rejected for the reason given in the sizing note above.

Realistic totals: a few hours of 1080p streaming daily (~180 GB) lands near $20/month;
sustained 4K for two people could reach $50–80/month.

If memory pressure proves to be a real problem in practice, `Standard_B1ms` is a resize
away and does not require rebuilding the host.

**Nothing outside Azure costs money.** The AmneziaVPN client and its mobile apps are free
and open source. Note that *Amnezia Premium* is a separate paid hosted service from the same
team — self-hosting does not use it and does not require an account of any kind.

A domain name (~$10–15/year) becomes necessary only if DNS indirection is added later, which
is out of scope here.

## Decisions

1. **Region: `westus2`.** US West chosen over US East for latency; see the inputs table.
2. **Resource group: `kwang-vpn`**, reused. It is dedicated to VPN infrastructure only, which
   is what makes `destroy.sh` safe as a single group-level delete.
3. **Protocol order: AmneziaWG first, XRay REALITY second.** AmneziaWG needs no domain, no
   certificate, and no SNI target, so it isolates "is the pipeline working?" from "is the
   protocol surviving?". XRay REALITY is installed immediately afterwards as a second
   container, giving both a fallback and a like-for-like comparison on one host.
4. **Password authentication remains enabled** after install. Rationale in the security
   section above.
5. **Billing: the existing subscription**, implied by reusing `kwang-vpn`. This retains a
   shared-fate risk — exhausting the monthly credit disables the whole subscription and would
   take `apex-trading` down with it, as happened on 2026-08-04. Accepted for now on the basis
   that projected VPN spend (~$28/month typical) sits well within the monthly credit. Revisit
   if usage approaches the cap.

## Measurement

The purpose of the first deployment is to answer a question no amount of analysis can:
**which protocol survives on the parents' actual connection, and for how long.** Record for
each trial: protocol, port, start date, failure date, and rough traffic volume before
failure. Three or four labelled observations are worth more than any prediction, including
the ones in this document.
