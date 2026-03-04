# Cisco Secure Client Auto-Login

Automates Cisco Secure Client CLI login on macOS by combining:
- password from macOS Keychain
- YubiKey OTP from a local `yksofttoken` executable

## Security Warning

This method is insecure and intended only as an educational counter-example.
You are automating MFA flow and storing reusable secrets locally.

## Requirements

- macOS
- Cisco Secure Client installed (`/opt/cisco/secureclient/bin/vpn`)
- `git`
- Homebrew
- Xcode Command Line Tools
- YubiKey/soft-token flow already allowed by your organization

## Fresh Machine Setup (Step-by-step)

### 1. Install base tooling

```bash
xcode-select --install
```

Install Homebrew if not installed:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

### 2. Install/verify Cisco Secure Client CLI

Install Cisco Secure Client from your organization.
Then verify CLI is present:

```bash
ls -l /opt/cisco/secureclient/bin/vpn
```

### 3. Clone this repo

```bash
git clone https://github.com/Chapoly1305/InSecureClientAutoLogin.git
cd InSecureClientAutoLogin
chmod +x vpn-script.sh
```

### 4. Build `yksofttoken`

```bash
cd ~
git clone https://github.com/arr2036/yksofttoken.git
cd yksofttoken
brew install libyubikey
make
```

Expected executable path after build:
- `~/yksofttoken/yksoft`

### 5. Create and register one virtual YubiKey on this device

Create a local token profile and print its registration values:

```bash
mkdir -p ~/.yksoft
~/yksofttoken/yksoft -r ~/.yksoft/default
```

Expected output format:

```text
<public_id_modhex>, <private_id_hex>, <secret_key_hex>
```

Important terminology:
- `public_id_modhex` is also called the `Serial Number` by many VPN/MFA enrollment portals.
- `private_id_hex` is the private identity.
- `secret_key_hex` is the AES secret key.

Register those values with your organization as your OTP/soft-token device.

Then generate an OTP and verify your login flow accepts `password,otp` format:

```bash
~/yksofttoken/yksoft ~/.yksoft/default
```

### 6. Configure `vpn-script.sh`

Edit `vpn-script.sh` and set:

```bash
VPN_SERVER="vpn.gmu.edu/VS-SR"      # your VPN server/profile
USERNAME="your_username"
KEYCHAIN_SERVICE_PASS="vpn-pass"     # must match Step 7 service name
YUBIKEY_PATH="~/yksofttoken/yksoft"  # path from Step 4
EXCLUDED_SUBNET=""                    # optional; leave empty to disable exclusion
```

### 7. Save VPN password to Keychain

Use the same username/service as script variables:

```bash
security add-internet-password -a "your_username" -s "vpn-pass" -w
```

### 8. (Optional) Enable Local LAN Access in Cisco profile

If your profile blocks local LAN, update the profile XML (path/profile name may vary):

```bash
sudo grep -R "LocalLanAccess" /opt/cisco/secureclient/vpn/profile
```

Set:

```xml
<LocalLanAccess UserControllable="true">true</LocalLanAccess>
```

### 9. (Optional) Exclude a local subnet from VPN

If you want local LAN resources (for example NAS) to stay outside VPN, set `EXCLUDED_SUBNET` in `vpn-script.sh`:

```bash
EXCLUDED_SUBNET="192.168.8.0/24"
```

Notes:
- Leave it empty (`EXCLUDED_SUBNET=""`) to keep exclusion disabled (default).
- You may be prompted for `sudo` when exclusion is enabled because route updates require root.
- This works best with Local LAN Access enabled in your Cisco profile (Step 8).

### 10. Connect and disconnect

From repo directory:

```bash
./vpn-script.sh connect
./vpn-script.sh disconnect
```

Optional aliases (`~/.zshrc`):

```bash
alias vpnc='$HOME/InSecureClientAutoLogin/vpn-script.sh connect'
alias vpnd='$HOME/InSecureClientAutoLogin/vpn-script.sh disconnect'
```

Reload shell:

```bash
source ~/.zshrc
```

## What to Expect on Connect

- Script reads password from Keychain
- Script generates OTP from `yksofttoken`
- Script connects Cisco VPN CLI
- If `EXCLUDED_SUBNET` is set, script adds/changes route for that subnet to local interface
- If exclusion is enabled, you may be prompted for `sudo` to modify route table

## Verification

After `connect`, verify VPN state:

```bash
/opt/cisco/secureclient/bin/vpn status
```

If exclusion is enabled, verify excluded subnet routes locally (example IP in that subnet):

```bash
route -n get 192.168.8.1
```

Expected: local interface (for example `en0`), not `utun*`.

## Troubleshooting

- `Password not found in keychain`
  - Re-run Step 7 and ensure `USERNAME` + `KEYCHAIN_SERVICE_PASS` match script.
- `YubiKey token tool not found`
  - Confirm `YUBIKEY_PATH` points to executable `yksofttoken/yksoft`.
- `route: must be root`
  - This only applies when `EXCLUDED_SUBNET` is enabled.
  - Re-run connect and approve `sudo` prompt.
- `Subnet route looks correct, but NAS IP still goes to utun`
  - This only applies when `EXCLUDED_SUBNET` is enabled.
  - Check with: `route -n get 192.168.8.197`
  - If it shows `interface: utun*`, run:
    `sudo route -n delete -host 192.168.8.197`
    `sudo route -n add -host 192.168.8.197 -interface en0`
- `NAS` host cannot be opened
  - This is often name resolution, not routing. Test by IP first (`smb://192.168.8.x`).
  - If IP works but hostname fails, fix local DNS/mDNS/hosts for `NAS`.

## License

This project is provided as-is for educational purposes.
