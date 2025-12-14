#!/bin/sh
GREEN='\033[0;32m'; NC='\033[0m'
MODE="$1"

# Load Config for Interface Awareness
if [ -f "$(dirname "$0")/../ci5.config" ]; then
    . "$(dirname "$0")/../ci5.config"
elif [ -f "/root/ci5/ci5.config" ]; then
    . "/root/ci5/ci5.config"
fi

# Determine Correct SQM Interface
if [ -n "$WAN_VLAN" ] && [ "$WAN_VLAN" -ne 0 ]; then
    SQM_IFACE="${WAN_IFACE}.${WAN_VLAN}"
else
    SQM_IFACE="${WAN_IFACE:-eth1}"
fi

echo "[*] Running Speed Auto-Tune on $SQM_IFACE..."

if ! command -v speedtest-cli >/dev/null; then
    echo "    ! Speedtest CLI not found. Skipping."
    exit 1
fi

# 1. Disable SQM
uci set sqm.eth1.interface="$SQM_IFACE"
uci set sqm.eth1.enabled='0'
uci commit sqm
/etc/init.d/sqm restart 2>/dev/null
sleep 2

# 2. Run Test
echo "    - Testing Speed (this takes 30s)..."
RESULTS=$(speedtest-cli --json)
DL_RAW=$(echo "$RESULTS" | grep -o '"download": [0-9.]*' | awk '{print $2}')
UL_RAW=$(echo "$RESULTS" | grep -o '"upload": [0-9.]*' | awk '{print $2}')

if [ -z "$DL_RAW" ]; then
    echo "    ! Speedtest failed. Keeping defaults."
    exit 1
fi

# 3. Calculate 95%
SQM_DL=$(echo "$DL_RAW" | awk '{printf "%.0f", ($1/1000) * 0.95}')
SQM_UL=$(echo "$UL_RAW" | awk '{printf "%.0f", ($1/1000) * 0.95}')

echo -e "${GREEN}    ✓ Measured: $(($DL_RAW / 1000000)) Mbps / $(($UL_RAW / 1000000)) Mbps${NC}"
echo -e "${GREEN}    ✓ Applied Limits (95%): ${SQM_DL}k / ${SQM_UL}k${NC}"

# 4. Apply
uci set sqm.eth1.enabled='1'
uci set sqm.eth1.download="$SQM_DL"
uci set sqm.eth1.upload="$SQM_UL"
uci commit sqm
/etc/init.d/sqm restart

if [ "$MODE" != "auto" ]; then
    echo "Done. Press Enter to exit."
    read -r
fi
