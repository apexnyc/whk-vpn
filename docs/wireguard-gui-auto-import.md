# Automated WireGuard GUI Tunnel Import on macOS

This document details the automated tunnel import workflow integrated into `whk-vpn` (`scripts/algo-vpn.sh`). At the end of `vpn create` or `vpn replace`, generated WireGuard client configurations are automatically imported directly into the official **WireGuard macOS GUI application** (`WireGuard.app`).

---

## 1. Workflow Overview

When `algo-vpn.sh create [region]` completes unattended provisioning on Azure:
1. **Client Config Extraction**: Algo streams client credentials back to the local host and extracts them under `~/Desktop/vpn/<ip>/` (symlinked at `~/Desktop/vpn/<vm-name>`).
2. **Named Config Staging**: The primary client config (`wireguard/license_2.conf`) is staged as `~/Desktop/vpn/<vm-name>/<vm-name>.conf` so that the tunnel displays with a clean, identifiable name in the WireGuard GUI (e.g., `algo-vpn-usa`).
3. **AppleScript UI Automation**: An `osascript` helper activates `WireGuard.app` and automates the file selection dialog to import `<vm-name>.conf` without manual file browsing.

---

## 2. Technical Implementation

The auto-import logic is implemented in `cmd_create()` within [`scripts/algo-vpn.sh`](file:///Users/kwang7/ProjectX/whk-vpn/scripts/algo-vpn.sh):

```bash
# Automatically import config into WireGuard GUI on macOS if available
local client_conf=""
if [[ -f "$CONFIGS_DIR/$config_dir/wireguard/license_2.conf" ]]; then
  client_conf="$CONFIGS_DIR/$config_dir/wireguard/license_2.conf"
elif [[ -f "$CONFIGS_DIR/$config_dir/wireguard/license_0.conf" ]]; then
  client_conf="$CONFIGS_DIR/$config_dir/wireguard/license_0.conf"
else
  client_conf="$(find "$CONFIGS_DIR/$config_dir/wireguard" -name "*.conf" 2>/dev/null | head -n 1)"
fi

if [[ -n "$client_conf" && -d "/Applications/WireGuard.app" ]]; then
  local named_conf="$CONFIGS_DIR/$config_dir/$VM_NAME.conf"
  cp "$client_conf" "$named_conf"
  log_info "importing $VM_NAME into WireGuard GUI..."
  osascript -e '
  on run argv
    set confPath to item 1 of argv
    tell application "WireGuard" to activate
    delay 0.5
    tell application "System Events"
      tell process "WireGuard"
        keystroke "o" using {command down}
        delay 1.0
        keystroke "g" using {command down, shift down}
        delay 1.0
        keystroke confPath
        delay 0.5
        keystroke return
        delay 0.8
        keystroke return
      end tell
    end tell
  end run' "$named_conf" >/dev/null 2>&1 || log_warn "could not auto-import into WireGuard GUI"
fi
```

### AppleScript Key Sequence Breakdown:
1. `keystroke "o" using {command down}` — Triggers **Import tunnel(s) from file...** (`Cmd+O`) in WireGuard.app.
2. `keystroke "g" using {command down, shift down}` — Opens macOS Finder **Go to Folder** sheet (`Cmd+Shift+G`).
3. `keystroke confPath` — Types the full absolute file path into the input field.
4. `keystroke return` (x2) — Confirms path selection and completes the file import.

---

## 3. System Requirements & Permissions

* **Application**: `/Applications/WireGuard.app` installed (available on Mac App Store).
* **macOS Privacy & Security Permission**:
  Because macOS restricts synthetic keystrokes for GUI automation, your terminal application (e.g., Terminal.app, iTerm.app, or VS Code/IDE terminal) must be granted **Accessibility** access:
  * Open **System Settings** → **Privacy & Security** → **Accessibility**.
  * Ensure your terminal application (e.g., Terminal / iTerm) is toggled **ON**.

---

## 4. Alternative Import & Management Workflows

For future workflow iterations, the following alternative client integration strategies are available:

### A. macOS Native `.mobileconfig` Profiles (No WireGuard App Required)
Algo provisions macOS system profile payloads in `wireguard/apple/macos/license_2.mobileconfig`.
* **Command:**
  ```bash
  open ~/Desktop/vpn/algo-vpn-usa/wireguard/apple/macos/license_2.mobileconfig
  ```
* **Effect:** Automatically launches **System Settings → Profiles** for a 1-click native macOS VPN profile installation.

### B. Headless CLI Automation (`wireguard-tools`)
For terminal-only or server environments without GUI:
* **Tool:** Install via Homebrew: `brew install wireguard-tools`
* **Config Location:** `/opt/homebrew/etc/wireguard/<vm-name>.conf`
* **Control Commands:**
  ```bash
  sudo wg-quick up algo-vpn-usa
  sudo wg-quick down algo-vpn-usa
  sudo wg show
  ```
