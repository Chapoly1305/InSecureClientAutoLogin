#!/bin/bash

# VPN Auto-Connect/Disconnect with Keychain
# Usage: ./vpn-script.sh connect [--fix-routes] | disconnect | routes | status

VPN_SERVER="vpn.gmu.edu/VS-SR"  # Update this with your VPN server
USERNAME="jchen73"            # Update this with your username
KEYCHAIN_SERVICE_PASS="vpn-pass"
YUBIKEY_PATH="~/yksofttoken/yksoft"

# Loaded only after a successful connect; not installed as a login/startup item.
RECONNECT_INTERVAL=25200  # 7 hours, in seconds
RECONNECT_RETRY_DELAY=60
RECONNECT_LABEL="local.secureclientautologin.reconnect"
RECONNECT_TARGET="gui/$UID/$RECONNECT_LABEL"
RECONNECT_DIR="$HOME/Library/Application Support/SecureClientAutoLogin"
RECONNECT_PLIST="$RECONNECT_DIR/reconnect.plist"
RECONNECT_LOG="$RECONNECT_DIR/reconnect.log"
SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")"

# Local subnets to keep outside the VPN tunnel: "<subnet> <preferred-interface>".
# en1 is Wi-Fi on this Mac; en0 is Ethernet.
LOCAL_ROUTE_EXCEPTIONS="
192.168.1.0/24 en1
192.168.8.0/24 en0
"
VPN_CONNECT_TIMEOUT=75  # Seconds before a stalled interactive VPN login is stopped.
VPN_CLI="/opt/cisco/secureclient/bin/vpn"

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Error: Required command not found: $1"
        return 1
    fi
}

check_prerequisites() {
    local missing=0

    if [ ! -x "$VPN_CLI" ]; then
        echo "Error: Cisco VPN CLI not found at $VPN_CLI"
        missing=1
    fi

    for cmd in security awk grep tail perl; do
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
        return 1
    fi
}

stop_auto_reconnect() {
    if /bin/launchctl print "$RECONNECT_TARGET" >/dev/null 2>&1; then
        if ! /bin/launchctl bootout "$RECONNECT_TARGET"; then
            echo "Error: Could not stop automatic VPN reconnect."
            return 1
        fi
        echo "✓ Automatic VPN reconnect stopped"
    fi
}

start_auto_reconnect() {
    local temporary_plist

    stop_auto_reconnect || return 1
    umask 077
    mkdir -p "$RECONNECT_DIR" && chmod 700 "$RECONNECT_DIR" || return 1
    temporary_plist=$(mktemp "$RECONNECT_DIR/reconnect.XXXXXX") || return 1

    # plistlib safely handles spaces and XML characters in user/script paths.
    if ! /usr/bin/python3 - "$temporary_plist" "$RECONNECT_LABEL" "$SCRIPT_PATH" \
        "$RECONNECT_INTERVAL" "$RECONNECT_LOG" <<'PY'
import plistlib
import sys

path, label, script, interval, log = sys.argv[1:]
with open(path, "wb") as output:
    plistlib.dump({
        "Label": label,
        "ProgramArguments": ["/bin/bash", script, "_reconnect"],
        "StartInterval": int(interval),
        "ProcessType": "Background",
        "StandardOutPath": log,
        "StandardErrorPath": log,
        "EnvironmentVariables": {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
    }, output)
PY
    then
        rm -f "$temporary_plist"
        return 1
    fi

    if ! mv -f "$temporary_plist" "$RECONNECT_PLIST"; then
        rm -f "$temporary_plist"
        return 1
    fi
    if ! /bin/launchctl bootstrap "gui/$UID" "$RECONNECT_PLIST"; then
        echo "Error: VPN connected, but automatic reconnect could not be scheduled."
        return 1
    fi
    echo "✓ Automatic reconnect enabled: every 7 hours; vpnd stops it"
    echo "Reconnect log: $RECONNECT_LOG"
}

auto_reconnect() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Scheduled VPN reconnect"
    # Do not call the public disconnect/connect commands: they manage this job.
    # Continue with connect even if the old session has already disconnected.
    vpn_disconnect || true
    while ! vpn_connect 0; do
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Connection failed; retrying in ${RECONNECT_RETRY_DELAY}s"
        sleep "$RECONNECT_RETRY_DELAY"
    done
}

vpn_status() {
    "$VPN_CLI" status
    if /bin/launchctl print "$RECONNECT_TARGET" >/dev/null 2>&1; then
        echo "Automatic reconnect: enabled (every 7 hours)"
        echo "Reconnect log: $RECONNECT_LOG"
    else
        echo "Automatic reconnect: disabled"
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

subnet_network() {
    echo "$1" | awk -F/ '{print $1}'
}

subnet_prefix() {
    echo "$1" | awk -F'[./]' '{print $1 "." $2 "." $3 "."}'
}

subnet_netmask() {
    local masklen

    masklen=$(echo "$1" | awk -F/ '{print $2}')
    case "$masklen" in
        24|"") echo "255.255.255.0" ;;
        32) echo "255.255.255.255" ;;
        *)
            echo "Error: Unsupported local route mask length: /$masklen" >&2
            return 1
            ;;
    esac
}

cleanup_leaked_host_routes() {
    local excluded_subnet="$1"
    local local_interface="$2"
    local subnet_prefix
    local leaked_routes
    local ip
    local route_interface
    local failed=0

    subnet_prefix=$(subnet_prefix "$excluded_subnet")
    leaked_routes=$(
        /usr/sbin/netstat -rn -f inet | awk -v prefix="$subnet_prefix" '
            $1 ~ ("^" prefix "[0-9]+$") && $NF ~ /^utun[0-9]+$/ {
                key=$1 " " $NF
                if (!seen[key]++) {
                    print key
                }
            }
        '
    )

    if [ -z "$leaked_routes" ]; then
        return 0
    fi

    echo "Fixing host-route overrides in $excluded_subnet..."

    while read -r ip route_interface; do
        [ -z "$ip" ] && continue
        run_route_cmd -n delete -host "$ip" -ifscope "$route_interface" >/dev/null 2>&1 ||
            run_route_cmd -n delete -host "$ip" >/dev/null 2>&1 ||
            true

        run_route_cmd -n add -host "$ip" -interface "$local_interface" >/dev/null 2>&1 ||
            run_route_cmd -n change -host "$ip" -interface "$local_interface" >/dev/null 2>&1 ||
            failed=1
    done << EOF2
$leaked_routes
EOF2

    return "$failed"
}

exclude_local_subnet_from_vpn() {
    local excluded_subnet="$1"
    local preferred_interface="$2"
    local subnet_prefix
    local local_interface
    local network
    local netmask
    local failed=0

    if [ -z "$excluded_subnet" ]; then
        echo "Skipping local subnet exclusion (subnet is empty)."
        return 0
    fi

    subnet_prefix=$(subnet_prefix "$excluded_subnet")
    local_interface="$preferred_interface"
    network=$(subnet_network "$excluded_subnet")
    netmask=$(subnet_netmask "$excluded_subnet") || return 1

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
        echo "⚠ Could not determine a local interface for $excluded_subnet"
        return 1
    fi

    echo "Applying local route exception: $excluded_subnet via $local_interface"

    # Try changing existing route first (works if VPN inserted one), then add if missing.
    if run_route_cmd -n change -net "$network" -netmask "$netmask" -interface "$local_interface" >/dev/null 2>&1; then
        echo "✓ Route exception updated for $excluded_subnet"
    elif run_route_cmd -n add -net "$network" -netmask "$netmask" -interface "$local_interface" >/dev/null 2>&1; then
        echo "✓ Route exception added for $excluded_subnet"
    else
        echo "⚠ Failed to configure route exception automatically."
        echo "Try running manually:"
        echo "  sudo /sbin/route -n change -net $network -netmask $netmask -interface $local_interface"
        echo "  sudo /sbin/route -n add -net $network -netmask $netmask -interface $local_interface"
        failed=1
    fi

    if ! cleanup_leaked_host_routes "$excluded_subnet" "$local_interface"; then
        echo "⚠ Failed to repair one or more host-route overrides in $excluded_subnet"
        failed=1
    fi

    return "$failed"
}

apply_local_route_exceptions() {
    local excluded_subnet
    local preferred_interface
    local failed=0

    while read -r excluded_subnet preferred_interface; do
        [ -z "$excluded_subnet" ] && continue
        case "$excluded_subnet" in
            \#*) continue ;;
        esac

        if ! exclude_local_subnet_from_vpn "$excluded_subnet" "$preferred_interface"; then
            failed=1
        fi
    done << EOF2
$LOCAL_ROUTE_EXCEPTIONS
EOF2

    return "$failed"
}

routes_leaked_to_vpn() {
    # Return 0 if a subnet or host route for any excluded subnet still points
    # into a utun interface (i.e. the VPN client re-asserted its routes).
    local excluded_subnet
    local preferred_interface
    local subnet_prefix
    local network

    while read -r excluded_subnet preferred_interface; do
        [ -z "$excluded_subnet" ] && continue
        case "$excluded_subnet" in
            \#*) continue ;;
        esac
        subnet_prefix=$(subnet_prefix "$excluded_subnet")
        network=$(subnet_network "$excluded_subnet")
        if /usr/sbin/netstat -rn -f inet | awk -v prefix="$subnet_prefix" -v network="$network" '
            ($1 == network || $1 ~ ("^" prefix "[0-9]+$")) && $NF ~ /^utun[0-9]+$/ { found=1; exit }
            END { exit !found }
        '; then
            return 0
        fi
    done << EOF2
$LOCAL_ROUTE_EXCEPTIONS
EOF2
    return 1
}

apply_local_route_exceptions_with_retries() {
    # The Cisco client keeps installing/re-asserting its routes for a while
    # after connect, so a single fix pass gets overwritten. Apply, verify,
    # and retry until the excluded subnets stop pointing into utun.
    local attempts=${1:-5}
    local delay=${2:-5}
    local attempt=1

    while [ "$attempt" -le "$attempts" ]; do
        apply_local_route_exceptions
        if ! routes_leaked_to_vpn; then
            echo "✓ Local route exceptions stable"
            return 0
        fi
        if [ "$attempt" -lt "$attempts" ]; then
            echo "VPN re-asserted leaked routes (attempt $attempt/$attempts); retrying in ${delay}s..."
            sleep "$delay"
        fi
        attempt=$((attempt + 1))
    done
    echo "⚠ VPN kept re-asserting routes; run '$0 r' manually once routing settles."
    return 1
}

show_usage() {
    echo "Usage: $0 {c|connect} [--fix-routes]"
    echo "       $0 {d|disconnect}"
    echo "       $0 {r|routes|fix-routes}"
    echo "       $0 status"
    echo "       $0 {u|update-password}"
    echo "Connect enables automatic reconnect every 7 hours; disconnect stops it."
    echo "Connect skips route changes by default. --fix-routes enables them (requires sudo)."
    exit "${1:-1}"
}

update_password() {
    check_prerequisites || return 1
    echo "Updating VPN password in Keychain for $USERNAME..."
    security add-internet-password -U -a "$USERNAME" -s "$KEYCHAIN_SERVICE_PASS" -w
}

vpn_connect() {
    local fix_routes="${1:-0}"
    local connect_exit_code

    check_prerequisites || return 1
    echo "Connecting to VPN..."

    # Retrieve password from keychain
    echo "Retrieving password from keychain..."
    PASSWORD=$(security find-internet-password -a "$USERNAME" -s "$KEYCHAIN_SERVICE_PASS" -w 2>/dev/null)

    if [ -z "$PASSWORD" ]; then
        echo "Error: Password not found in keychain."
        echo "Store password first with: security add-internet-password -a \"$USERNAME\" -s \"$KEYCHAIN_SERVICE_PASS\" -w"
        echo "You will be prompted to enter your VPN password."
        return 1
    fi

    echo "✓ Password retrieved from keychain"

    # Check YubiKey token tool exists
    YUBIKEY_FULL_PATH=$(resolve_user_path "$YUBIKEY_PATH")

    if [ ! -x "$YUBIKEY_FULL_PATH" ]; then
        echo "Error: YubiKey token tool not found at $YUBIKEY_PATH"
        echo "Expected executable path: $YUBIKEY_FULL_PATH"
        unset PASSWORD
        return 1
    fi

    # Generate YubiKey token
    echo "Generating YubiKey token..."
    YUBIKEY_TOKEN=$("$YUBIKEY_FULL_PATH" 2>/dev/null)

    if [ -z "$YUBIKEY_TOKEN" ]; then
        echo "Error: Failed to generate YubiKey token"
        echo "Make sure your YubiKey is inserted and properly configured"
        unset PASSWORD YUBIKEY_TOKEN
        return 1
    fi

    echo "✓ YubiKey token generated"

    # Connect with combined credentials
    COMBINED_PASSWORD="${PASSWORD},${YUBIKEY_TOKEN}"
    echo "Connecting to $VPN_SERVER as $USERNAME (timeout: ${VPN_CONNECT_TIMEOUT}s)..."
    echo "Cisco Secure Client output follows:"

    # Stream Cisco progress, while still stopping a hidden prompt that hangs
    # when this same entry point runs unattended from launchd.
    /usr/bin/perl -e 'alarm shift; exec @ARGV' "$VPN_CONNECT_TIMEOUT" "$VPN_CLI" -s << EOF3
connect $VPN_SERVER
$USERNAME
$COMBINED_PASSWORD
y
EOF3
    connect_exit_code=$?

    # Clear sensitive variables
    unset PASSWORD YUBIKEY_TOKEN COMBINED_PASSWORD

    if [ "$connect_exit_code" -eq 142 ]; then
        echo "⚠ Connection timed out after ${VPN_CONNECT_TIMEOUT}s."
    elif [ "$connect_exit_code" -ne 0 ]; then
        echo "⚠ Cisco Secure Client exited with status $connect_exit_code."
    fi

    # Check status
    sleep 3
    echo "Checking connection status..."
    STATUS_OUTPUT=$("$VPN_CLI" status)

    if echo "$STATUS_OUTPUT" | grep -q "state: Connected"; then
        echo "✓ Successfully connected to VPN"
        CONNECTION_INFO=$(echo "$STATUS_OUTPUT" | grep "Connected to" | tail -1)
        if [ -n "$CONNECTION_INFO" ]; then
            echo "$CONNECTION_INFO"
        else
            echo "Connected to $VPN_SERVER"
        fi
        if [ "$fix_routes" -eq 1 ]; then
            # The Cisco client installs its tunneled routes several seconds after
            # the state reports Connected; fixing earlier just gets overwritten.
            echo "Waiting for Cisco client to finish installing routes (15s)..."
            sleep 15
            apply_local_route_exceptions_with_retries ||
                echo "⚠ VPN is connected, but local route repair failed."
        else
            echo "Skipping local route changes. Use 'vpnc --fix-routes' or '$0 routes' if needed."
        fi
        return 0
    else
        echo "⚠ Connection attempt completed. Current status:"
        echo "$STATUS_OUTPUT" | grep -E "(state:|Connected to)" || echo "Unable to determine status"
        echo "If the live output says 'Login failed' and your password changed, update the Keychain entry with:"
        echo "  $0 update-password"
        return 1
    fi
}

vpn_disconnect() {
    check_prerequisites || return 1
    echo "Disconnecting from VPN..."
    "$VPN_CLI" disconnect
    sleep 2

    STATUS_OUTPUT=$("$VPN_CLI" status)
    if echo "$STATUS_OUTPUT" | grep -q "state: Disconnected"; then
        echo "✓ Successfully disconnected from VPN"
    else
        echo "⚠ Disconnect attempt completed. Current status:"
        echo "$STATUS_OUTPUT" | grep -E "(state:|Connected to)" || echo "Unable to determine status"
        return 1
    fi
}

# Parse command line arguments
case "${1:-}" in
    c|connect)
        shift
        case "$#:${1:-}" in
            0:) FIX_ROUTES=0 ;;
            1:--fix-routes) FIX_ROUTES=1 ;;
            1:-h|1:--help) show_usage 0 ;;
            *) show_usage ;;
        esac
        stop_auto_reconnect && vpn_connect "$FIX_ROUTES" && start_auto_reconnect
        ;;
    d|disconnect)
        [ "$#" -eq 1 ] || show_usage
        stop_auto_reconnect && vpn_disconnect
        ;;
    r|routes|fix-routes)
        [ "$#" -eq 1 ] || show_usage
        check_prerequisites && apply_local_route_exceptions_with_retries
        ;;
    status)
        [ "$#" -eq 1 ] || show_usage
        vpn_status
        ;;
    _reconnect)
        [ "$#" -eq 1 ] || show_usage
        auto_reconnect
        ;;
    u|update-password)
        [ "$#" -eq 1 ] || show_usage
        update_password
        ;;
    -h|--help)
        show_usage 0
        ;;
    *)
        show_usage
        ;;
esac
