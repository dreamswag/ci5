#!/bin/sh
# 🏎️ Ci5 Speed Wizard (Auto-Tuner)

GREEN='\033[0;32m'
NC='\033[0m'

echo "[*] Running Speed Auto-Tune..."

# Install pip & speedtest
opkg update >/dev/null 2>&1
opkg install python3-pip >/dev/null 2>&1
pip3 install speedtest-cli >/dev/null 2>&1

# Run Test
RESULTS=$(speedtest-cli --json)
DL_RAW=$(echo "$RESULTS" | grep -o '"download": [0-9.]*' | awk '{print $2}')
UL_RAW=$(echo "$RESULTS" | grep -o '"upload": [0-9.]*' | awk '{print $2}')

# Calculate 95% (kbps)
SQM_DL=$(echo "$DL_RAW" | awk '{printf "%.0f", ($1/1000) * 0.95}')
SQM_UL=$(echo "$UL_RAW" | awk '{printf "%.0f", ($1/1000) * 0.95}')

echo -e "${GREEN}✓ Applied Limits: ${SQM_DL}k / ${SQM_UL}k${NC}"

uci set sqm.eth1.enabled='1'
uci set sqm.eth1.download="$SQM_DL"
uci set sqm.eth1.upload="$SQM_UL"
uci commit sqm
/etc/init.d/sqm restart
