#!/bin/bash

# VPN Auto-Connect/Disconnect with Keychain
# Usage: ./vpn-script.sh [c|connect|d|disconnect]

VPN_SERVER="vpn.example.edu"  # Update this with your VPN server
USERNAME="USERNAME"            # Update this with your username
KEYCHAIN_SERVICE_PASS="vpn-pass"
YUBIKEY_PATH="~/yksofttoken/yksoft"

show_usage() {
    echo "Usage: $0 [c|connect|d|disconnect]"
    exit 1
}

vpn_connect() {
    echo "Connecting to VPN..."
    
    # Retrieve password from keychain
    echo "Retrieving password from keychain..."
    PASSWORD=$(security find-internet-password -a "$USERNAME" -s "$KEYCHAIN_SERVICE_PASS" -w 2>/dev/null)
    
    if [ -z "$PASSWORD" ]; then
        echo "Error: Password not found in keychain."
        echo "Store password first with: security add-internet-password -a \"$USERNAME\" -s \"$KEYCHAIN_SERVICE_PASS\" -w"
        echo "You will be prompted to enter your VPN password."
        exit 1
    fi
    
    echo "✓ Password retrieved from keychain"
    
    # Check YubiKey token tool exists
    YUBIKEY_FULL_PATH=$(eval echo "$YUBIKEY_PATH")
    
    if [ ! -f "$YUBIKEY_FULL_PATH" ]; then
        echo "Error: YubiKey token tool not found at $YUBIKEY_PATH"
        exit 1
    fi
    
    # Generate YubiKey token
    echo "Generating YubiKey token..."
    YUBIKEY_TOKEN=$("$YUBIKEY_FULL_PATH" 2>/dev/null)
    
    if [ -z "$YUBIKEY_TOKEN" ]; then
        echo "Error: Failed to generate YubiKey token"
        echo "Make sure your YubiKey is inserted and properly configured"
        exit 1
    fi
    
    echo "✓ YubiKey token generated"
    
    # Connect with combined credentials
    COMBINED_PASSWORD="${PASSWORD},${YUBIKEY_TOKEN}"
    echo "Connecting to $VPN_SERVER as $USERNAME..."
    
    /opt/cisco/secureclient/bin/vpn -s << EOF
connect $VPN_SERVER
$USERNAME
$COMBINED_PASSWORD
y
EOF
    
    # Clear sensitive variables
    unset PASSWORD YUBIKEY_TOKEN COMBINED_PASSWORD
    
    # Check status
    sleep 3
    echo "Checking connection status..."
    STATUS_OUTPUT=$(/opt/cisco/secureclient/bin/vpn status)
    
    if echo "$STATUS_OUTPUT" | grep -q "state: Connected"; then
        echo "✓ Successfully connected to VPN"
        CONNECTION_INFO=$(echo "$STATUS_OUTPUT" | grep "Connected to" | tail -1)
        if [ -n "$CONNECTION_INFO" ]; then
            echo "$CONNECTION_INFO"
        else
            echo "Connected to $VPN_SERVER"
        fi
    else
        echo "⚠ Connection attempt completed. Current status:"
        echo "$STATUS_OUTPUT" | grep -E "(state:|Connected to)" || echo "Unable to determine status"
    fi
}

vpn_disconnect() {
    echo "Disconnecting from VPN..."
    /opt/cisco/secureclient/bin/vpn disconnect
    sleep 2
    
    STATUS_OUTPUT=$(/opt/cisco/secureclient/bin/vpn status)
    if echo "$STATUS_OUTPUT" | grep -q "state: Disconnected"; then
        echo "✓ Successfully disconnected from VPN"
    else
        echo "⚠ Disconnect attempt completed. Current status:"
        echo "$STATUS_OUTPUT" | grep -E "(state:|Connected to)" || echo "Unable to determine status"
    fi
}

# Parse command line arguments
case "${1:-}" in
    c|connect)
        vpn_connect
        ;;
    d|disconnect)
        vpn_disconnect
        ;;
    *)
        show_usage
        ;;
esac