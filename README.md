# Cisco Secure Client Auto-Login

Password authentication and Duo Push may be inconvenient, but they provide security. 

This script insecurely stores your password and simulates a YubiKey locally. It also automates the login process for Cisco Secure Client VPN with YubiKey token authentication and macOS Keychain integration. Please note that you should not use this script to automate authentication. It is highly insecure. This script is conter-example for educational purposes. 

## Prerequisites

- macOS with Cisco Secure Client installed
- YubiKey device configured for TOTP
- Git (for cloning dependencies)

## Setup

### 1. Clone and Setup SoftYubiKey Software Token Tool

First, clone and set up the YubiKey software token tool:

```bash
# Clone the yksofttoken repository (tested commit 8c8a39c75e4f378417cf591795723a84a0fcdae0)
git clone https://github.com/arr2036/yksofttoken.git

# Navigate to the directory
cd yksofttoken

# Follow the build instructions in that repository's README
brew install libyubikey
make
```

**Setup:** Run the compiled executable (`yksofttoken/yksoft`). The first output contains your `Serial Number`, `Private Identity`, and `Secret Key`. It's insecure to register this key with your organization's 2FA platform, e.g., https://password.gmu.edu, Manage DUO 2FA Account - Add A New Device - Yubikey.

**Test-Setup:** When logging in any page requires 2FA, run `yksofttoken/yksoft` again to generate a temporary password. Immediately combine your password and the generated code with a comma: `yourpassword,generatedcode`. If your password is `deadbeef` and the program outputs `ddddffcgveuufdtcvuluuhtetvutkHBDLVMIJKDEFABC`, enter: `deadbeef,ddddffcgveuufdtcvuluuhtetvutkHBDLVMIJKDEFABC`. The expected result is no further 2FA is asked and you can login normally. If not, check if you have register properly and maybe your system uses different seperator, you will need to do your own research.

### 2. Configure the Script

Edit the `vpn-script.sh` file and update the following variables:

```bash
VPN_SERVER="your-vpn-server.domain.com"    # Replace with your VPN server address
USERNAME="your-username"                    # Replace with your VPN username
YUBIKEY_PATH="~/yksofttoken/yksoft"        # Update if yksofttoken is in different location
```

### 3. Store VPN Password in Keychain

Store your VPN password securely in macOS Keychain:

```bash
security add-internet-password -a "your-username" -s "vpn-pass" -w
```

You'll be prompted to enter your VPN password. This will be stored securely and retrieved automatically by the script.

### 4. Make Script Executable

```bash
chmod +x vpn-script.sh
```

## Usage

**Exit Secure Client GUI before run the script or it will fail.**

### Connect to VPN
```bash
./vpn-script.sh connect
# or
./vpn-script.sh c
```

### Disconnect from VPN
```bash
./vpn-script.sh disconnect
# or
./vpn-script.sh d
```

### Hint Set as alias
```bash
# Make the script executable (or change to actual location of this script)
# Or move it to a system location (optional)
vi ~/.zshrc

# Add these lines to the file:
alias vpnc='/PATH/vpn-script.sh connect'
alias vpnd='/PATH/vpn-script.sh disconnect'

# Or if you moved it to /usr/local/bin:
alias vpnc='vpn-script connect'
alias vpnd='vpn-script disconnect'
```


## License

This project is provided as-is for educational purposes.