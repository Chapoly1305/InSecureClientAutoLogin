#!/bin/bash

# VPN Auto-Connect/Disconnect with Keychain
# Usage: ./vpn-script.sh [c|connect|d|disconnect]

VPN_SERVER="vpn.gmu.edu/VS-SR"  # Update this with your VPN server
USERNAME="jchen73"            # Update this with your username
KEYCHAIN_SERVICE_PASS="vpn-pass"
YUBIKEY_PATH="~/yksofttoken/yksoft"
EXCLUDED_SUBNET=""            # Optional. Leave empty to disable local subnet exclusion.

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Error: Required command not found: $1"
        return 1
    fi
}

check_prerequisites() {
    local missing=0

    if [ ! -x "/opt/cisco/secureclient/bin/vpn" ]; then
        echo "Error: Cisco VPN CLI not found at /opt/cisco/secureclient/bin/vpn"
        missing=1
    fi

    for cmd in security awk grep tail; do
        if ! require_command "$cmd"; then
            missing=1
        fi
    done

    if [ ! -x "/sbin/ifconfig" ]; then
        echo "Error: Required binary not found: /sbin/ifconfig"
        missing=1
    fi

    if [ ! -x "/sbin/route" ]; then
        echo "Error: Required binary not found: /sbin/route"
        missing=1
    fi

    if [ ! -x "/usr/sbin/netstat" ]; then
        echo "Error: Required binary not found: /usr/sbin/netstat"
        missing=1
    fi

    if [ "$missing" -ne 0 ]; then
        echo "Fix missing dependencies and run again."
        exit 1
    fi
}

resolve_user_path() {
    if [ "$1" = "~" ]; then
        echo "$HOME"
    elif [ "${1:0:2}" = "~/" ]; then
        echo "$HOME/${1:2}"
    else
        echo "$1"
    fi
}

run_route_cmd() {
    if [ "$EUID" -eq 0 ]; then
        /sbin/route "$@"
    else
        sudo /sbin/route "$@"
    fi
}

find_interface_for_subnet() {
    local subnet_prefix="$1"
    /sbin/ifconfig | awk -v prefix="$subnet_prefix" '
        /^[a-zA-Z0-9]+:/ {
            iface=$1
            sub(/:$/, "", iface)
        }
        /inet / {
            if (index($2, prefix) == 1) {
                print iface
                exit
            }
        }
    '
}

interface_has_subnet_ip() {
    local iface="$1"
    local subnet_prefix="$2"

    /sbin/ifconfig "$iface" 2>/dev/null | awk -v prefix="$subnet_prefix" '
        /inet / {
            if (index($2, prefix) == 1) {
                found=1
                exit
            }
        }
        END {
            if (found == 1) {
                exit 0
            }
            exit 1
        }
    '
}

cleanup_leaked_host_routes() {
    local local_interface="$1"
    local subnet_prefix
    local leaked_hosts
    local ip

    subnet_prefix=$(echo "$EXCLUDED_SUBNET" | awk -F'[./]' '{print $1 "." $2 "." $3 "."}')
    leaked_hosts=$(
        /usr/sbin/netstat -rn -f inet | awk -v prefix="$subnet_prefix" '
            $1 ~ ("^" prefix "[0-9]+$") && $NF ~ /^utun[0-9]+$/ {
                if (!seen[$1]++) {
                    print $1
                }
            }
        '
    )

    if [ -z "$leaked_hosts" ]; then
        return 0
    fi

    echo "Fixing host-route overrides in $EXCLUDED_SUBNET..."

    while IFS= read -r ip; do
        [ -z "$ip" ] && continue
        run_route_cmd -n delete -host "$ip" >/dev/null 2>&1 || true
        run_route_cmd -n add -host "$ip" -interface "$local_interface" >/dev/null 2>&1 || true
    done << EOF2
$leaked_hosts
EOF2
}

exclude_local_subnet_from_vpn() {
    local preferred_interface="$1"
    local subnet_prefix
    local local_interface

    if [ -z "$EXCLUDED_SUBNET" ]; then
        echo "Skipping local subnet exclusion (EXCLUDED_SUBNET is empty)."
        return 0
    fi

    subnet_prefix=$(echo "$EXCLUDED_SUBNET" | awk -F'[./]' '{print $1 "." $2 "." $3 "."}')
    local_interface="$preferred_interface"

    # Reject tunnel/default interfaces that do not actually belong to the target subnet.
    if [ -n "$local_interface" ]; then
        if echo "$local_interface" | grep -q '^utun'; then
            local_interface=""
        elif ! interface_has_subnet_ip "$local_interface" "$subnet_prefix"; then
            local_interface=""
        fi
    fi

    if [ -z "$local_interface" ]; then
        local_interface=$(find_interface_for_subnet "$subnet_prefix")
    fi

    if [ -z "$local_interface" ]; then
        echo "⚠ Could not determine a local interface for $EXCLUDED_SUBNET"
        return 1
    fi

    echo "Applying local route exception: $EXCLUDED_SUBNET via $local_interface"

    # Try changing existing route first (works if VPN inserted one), then add if missing.
    if run_route_cmd -n change -net "$EXCLUDED_SUBNET" -interface "$local_interface" >/dev/null 2>&1; then
        echo "✓ Route exception updated for $EXCLUDED_SUBNET"
    elif run_route_cmd -n add -net "$EXCLUDED_SUBNET" -interface "$local_interface" >/dev/null 2>&1; then
        echo "✓ Route exception added for $EXCLUDED_SUBNET"
    else
        echo "⚠ Failed to configure route exception automatically."
        echo "Try running manually:"
        echo "  sudo /sbin/route -n change -net $EXCLUDED_SUBNET -interface $local_interface"
        echo "  sudo /sbin/route -n add -net $EXCLUDED_SUBNET -interface $local_interface"
        return 1
    fi

    cleanup_leaked_host_routes "$local_interface"
    return 0
}

show_usage() {
    echo "Usage: $0 [c|connect|d|disconnect]"
    exit 1
}

vpn_connect() {
    local pre_vpn_interface

    check_prerequisites
    echo "Connecting to VPN..."

    pre_vpn_interface=$(/sbin/route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')

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
    YUBIKEY_FULL_PATH=$(resolve_user_path "$YUBIKEY_PATH")

    if [ ! -x "$YUBIKEY_FULL_PATH" ]; then
        echo "Error: YubiKey token tool not found at $YUBIKEY_PATH"
        echo "Expected executable path: $YUBIKEY_FULL_PATH"
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

    /opt/cisco/secureclient/bin/vpn -s << EOF3
connect $VPN_SERVER
$USERNAME
$COMBINED_PASSWORD
y
EOF3

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
        exclude_local_subnet_from_vpn "$pre_vpn_interface"
    else
        echo "⚠ Connection attempt completed. Current status:"
        echo "$STATUS_OUTPUT" | grep -E "(state:|Connected to)" || echo "Unable to determine status"
    fi
}

vpn_disconnect() {
    check_prerequisites
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
