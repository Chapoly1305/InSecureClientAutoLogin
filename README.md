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
VPN_CONNECT_TIMEOUT=75               # seconds before an unattended login is stopped
LOCAL_ROUTE_EXCEPTIONS="
192.168.1.0/24 en1
192.168.8.0/24 en0
"  # optional local subnets and preferred interfaces; used only for route repair
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

If you want local LAN resources (for example NAS) to stay outside VPN, configure `LOCAL_ROUTE_EXCEPTIONS` in `vpn-script.sh` with one subnet and preferred interface per line:

```bash
LOCAL_ROUTE_EXCEPTIONS="
192.168.8.0/24 en0
"
```

Notes:
- Normal `connect` does not modify routes or invoke `sudo`.
- Use `connect --fix-routes` to repair routes after connecting, or `routes` to repair them separately. These operations may prompt for `sudo` because route updates require root.
- Leave `LOCAL_ROUTE_EXCEPTIONS=""` to disable local route exceptions entirely.
- This works best with Local LAN Access enabled in your Cisco profile (Step 8).

### 10. Connect and disconnect

From repo directory:

```bash
./vpn-script.sh connect
./vpn-script.sh connect --fix-routes  # optional route repair; may prompt for sudo
./vpn-script.sh routes                # repair routes separately; may prompt for sudo
./vpn-script.sh disconnect
./vpn-script.sh update-password      # update the Keychain password
```

Optional aliases (`~/.zshrc`):

```bash
alias vpnc='$HOME/InSecureClientAutoLogin/vpn-script.sh connect'
alias vpnd='$HOME/InSecureClientAutoLogin/vpn-script.sh disconnect'
alias vpnup='$HOME/InSecureClientAutoLogin/vpn-script.sh update-password'
```

Reload shell:

```bash
source ~/.zshrc
```

With the aliases above, use `vpnc` for a normal connection or `vpnc --fix-routes` to also repair local routes.

## Automatic Reconnect

After a successful `vpnc`, a user-level macOS `launchd` job disconnects and
reconnects the VPN every 7 hours. It keeps running when the terminal closes.
Each reconnect reads the password from Keychain and generates a fresh OTP.
If connection fails, the job retries every 60 seconds until it succeeds.

- `vpnd` stops the job before disconnecting, so it stays disconnected.
- Running `vpnc` again replaces the existing schedule and resets the 7-hour timer.
- Automatic reconnect never repairs routes or invokes `sudo`; `--fix-routes`
  applies only to the initial interactive connection.
- This job is active for the current login session. After logging out or
  restarting the Mac, run `vpnc` again to enable it.
- Sleep, network outages, Keychain access restrictions, and VPN server policy
  can interrupt connectivity. Reconnecting also briefly interrupts traffic.

Check VPN and scheduler status:

```bash
./vpn-script.sh status
```

The schedule and log are stored in
`~/Library/Application Support/SecureClientAutoLogin/` (`reconnect.plist` and
`reconnect.log`). This directory is restricted to your user. Scheduling uses
`/usr/bin/python3` to write the plist; Xcode Command Line Tools provide it.

Run the isolated regression checks (no real VPN or credentials are used):

```bash
python3 -B -m unittest discover -s tests -v
```

## What to Expect on Connect

- Script reads password from Keychain
- Script generates OTP from `yksofttoken`
- Script streams Cisco VPN CLI progress and stops stalled login after 75 seconds
- `update-password` updates the Keychain entry after a password change
- A successful connection enables automatic reconnect every 7 hours
- By default, connection skips local route changes and does not invoke `sudo`
- With `--fix-routes`, script adds/changes local subnet routes and may prompt for `sudo`

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
- `Login failed`
  - If your password changed, run `./vpn-script.sh update-password` and save it to Keychain.
- `route: must be root`
  - This applies to `connect --fix-routes` and `routes`.
  - Re-run the route repair command and approve the `sudo` prompt.
- `Subnet route looks correct, but NAS IP still goes to utun`
  - This applies when local route exceptions are configured.
  - Check with: `route -n get 192.168.8.197`
  - If it shows `interface: utun*`, run:
    `sudo route -n delete -host 192.168.8.197`
    `sudo route -n add -host 192.168.8.197 -interface en0`
- `NAS` host cannot be opened
  - This is often name resolution, not routing. Test by IP first (`smb://192.168.8.x`).
  - If IP works but hostname fails, fix local DNS/mDNS/hosts for `NAS`.

## License

This project is provided as-is for educational purposes.
