#!/bin/sh
# CI5 First-Boot: Absorb Soul Configuration
# Reads injected config from /boot/ci5-init/soul.conf

SOUL_FILE="/boot/ci5-init/soul.conf"
DEST_FILE="/etc/ci5/soul.conf"

if [ ! -f "$SOUL_FILE" ]; then
    echo "[!] No soul configuration found"
    exit 0
fi

echo "[*] Absorbing soul configuration..."

# Source the soul
. "$SOUL_FILE"

mkdir -p /etc/ci5

# Apply WAN configuration
if [ -n "$WAN_PROTO" ]; then
    uci set network.wan.proto="$WAN_PROTO"
    [ -n "$ISP_USER" ] && uci set network.wan.username="$ISP_USER"
    [ -n "$ISP_PASS" ] && uci set network.wan.password="$ISP_PASS"
    [ -n "$VLAN_ID" ] && {
        WAN_DEV=$(uci get network.wan.device)
        uci set network.wan.device="${WAN_DEV}.${VLAN_ID}"
    }
    uci commit network
fi

# Apply SQM overhead settings
if [ -n "$OVERHEAD" ]; then
    uci set sqm.wan.overhead="$OVERHEAD"
    uci set sqm.wan.linklayer="${LINKLAYER:-ethernet}"
    uci commit sqm
fi

# Initialize hardware-bound identity
echo "[*] Initializing Goldilocks Lite identity..."
/root/ci5/scripts/identity/goldilocks-lite.sh init

# Preserve custom options for install-custom.sh
if [ -n "$CUSTOM_OPTS" ]; then
    echo "CUSTOM_OPTS=\"$CUSTOM_OPTS\"" >> "$DEST_FILE"
fi

# Copy soul to persistent location
cp "$SOUL_FILE" "$DEST_FILE"

# Run speed wizard for SQM auto-tuning
if [ -x /root/ci5/scripts/diagnostics/speed_test.sh ]; then
    echo "[*] Running speed wizard for SQM calibration..."
    /root/ci5/scripts/diagnostics/speed_test.sh auto
fi

# Determine installer to run
case "$INSTALL_MODE" in
    recommended) /root/ci5/scripts/install-recommended.sh ;;
    minimal)     /root/ci5/scripts/install-minimal.sh ;;
    custom)      /root/ci5/scripts/install-custom.sh ;;
esac

echo "[+] Soul absorption complete"
