# whk-vpn

Automated provisioning of a censorship-resistant personal VPN endpoint.

**Status: design stage.** Nothing is implemented yet.

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
- **Billing isolation:** must not share a billing boundary with trading infrastructure.
  The prior deployment shared an Azure subscription with other services; exhausting the
  monthly credit disabled the entire subscription.
- **Disposable infrastructure:** the server is rebuilt, not repaired. IP addresses are
  treated as consumable.

## Layout

```
docs/
  azure-kwang-vpn-teardown-record-*.md   Configuration record of the retired Azure estate
  superpowers/
    specs/    Design documents
    plans/    Implementation plans
```

## Open decisions

- Obfuscated transport: AmneziaWG vs. Xray (VLESS + REALITY)
- Hosting provider: flat-rate VPS vs. metered hyperscaler
- Region: Japan East / Korea Central / East Asia are the strongest candidates by latency
