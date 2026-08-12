# AmneziaWG Client & Censorship-Resistance Guide

`whk-vpn` supports **AmneziaWG (AWG)** — an obfuscated WireGuard protocol fork specifically designed to defeat GFW Deep Packet Inspection (DPI) in mainland China.

---

## 1. Why AmneziaWG Defeats GFW

Standard WireGuard uses fixed 4-byte message type headers (`0x01`, `0x02`, `0x03`, `0x04`) that GFW DPI regex matching easily identifies and blocks on Chinese ISP gateways.

AmneziaWG introduces **6 random noise parameters**:
* `Jc`: Junk packet count sent before the handshake.
* `Jmin` / `Jmax`: Junk packet byte size range.
* `S1` / `S2`: Handshake initiation and response padding bytes.
* `H1` – `H4`: Randomized 32-bit uint header magic numbers.

These parameters alter the packet signatures, rendering AmneziaWG traffic completely un-fingerprintable to GFW DPI filters.

---

## 2. Recommended Free Client Applications

| Platform | Recommended App | Cost | Download Link |
| :--- | :--- | :--- | :--- |
| **macOS** | AmneziaWG GUI | Free | [US App Store Link](https://apps.apple.com/us/app/amneziawg/id6477382767) |
| **iOS / iPadOS** | AmneziaWG | Free | [US App Store Link](https://apps.apple.com/us/app/amneziawg/id6477382767) |
| **Windows** | AmneziaWG Windows Client | Free | [GitHub Releases](https://github.com/amnezia-vpn/amneziawg-windows-client/releases) |

---

## 3. Provisioning & Device Import Workflow

### Step 1: Create an Endpoint
Run the unified `vpn` command from your terminal (defaults to AmneziaWG):

```bash
vpn create usa          # provision awg-vpn-usa in eastus (~30 sec)
vpn create uk           # provision awg-vpn-uk in uksouth
vpn create australia    # provision awg-vpn-australia in australiaeast
```

### Step 2: Import into Devices

When `vpn create` finishes, configuration files and **QR code PNG image files** are stored in `~/Desktop/vpn/<public-ip>/` (symlinked at `~/Desktop/vpn/awg-vpn-<region>/`):

* **MacBook**: `<public-ip>-macbook.conf` (Auto-imported into AmneziaWG GUI on macOS)
* **Mac Mini**: `<public-ip>-macmini.conf`
* **iPhone**: `<public-ip>-iphone.conf` & **`<public-ip>-iphone_qr.png`** (Renders ANSI QR in terminal & saves PNG image file)
* **iPad**: `<public-ip>-ipad.conf` & **`<public-ip>-ipad_qr.png`** (Renders ANSI QR in terminal & saves PNG image file)
* **iOS (Generic)**: `<public-ip>-ios.conf` & **`<public-ip>-ios_qr.png`**
* **Android**: `<public-ip>-android.conf` & **`<public-ip>-android_qr.png`**
* **Windows**: `<public-ip>-windows.conf` & **`<public-ip>-windows_qr.png`**

*(Convenience symlinks like `iphone.conf`, `ipad.conf`, `macbook.conf` are also generated inside the directory for easy access).*

---

### How to Import via Image File

You can open or AirDrop any of the generated `.png` files directly:
```bash
open ~/Desktop/vpn/awg-vpn-usa/iphone_qr.png
open ~/Desktop/vpn/awg-vpn-usa/ipad_qr.png
open ~/Desktop/vpn/awg-vpn-usa/android_qr.png
```
Or open the **AmneziaWG** / **WireGuard** app on your phone/tablet -> tap **`+`** -> **Scan QR Code** or **Import from Photos**!

---

## 4. Lifecycle & Inspection Commands

* **Inspect Health & GFW Status**:
  ```bash
  vpn inspect usa
  ```
  Deeply probes Azure VM power state, SSH connectivity, AmneziaWG daemon status (`awg0`), and active peer handshakes.

* **Replace Endpoint (Fresh IP + New Noise Parameters)**:
  ```bash
  vpn replace usa
  ```
  Tears down `awg-vpn-usa` and provisions a new Azure VM with a fresh public IP and randomized noise parameters.

* **List Active Endpoints**:
  ```bash
  vpn list
  ```

* **Destroy Endpoint**:
  ```bash
  vpn destroy awg-vpn-usa
  ```
