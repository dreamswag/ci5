#!/bin/sh
# 🚁 Ci5 Pre-Flight Check (v7.4-RC-1)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo "Running System Diagnostics..."

# 1. HARDWARE ID
MODEL=$(cat /proc/device-tree/model 2>/dev/null || echo "Unknown")
echo "   Hardware: $MODEL"

IS_PI5=0
if echo "$MODEL" | grep -q "Raspberry Pi 5"; then
    IS_PI5=1
    echo -e "   Status:   ${GREEN}APPROVED (Pi 5)${NC}"
elif echo "$MODEL" | grep -q "Raspberry Pi 4"; then
    echo -e "   Status:   ${YELLOW}ACCEPTABLE (Pi 4)${NC}"
else
    # HIDDEN FAILSAFE: Check for override file
    if [ -f "/tmp/ci5_override" ]; then
         echo -e "   Status:   ${RED}UNSUPPORTED (Override Active)${NC}"
    else
         echo -e "   Status:   ${RED}UNSUPPORTED${NC}"
         echo "   This suite is tuned for Raspberry Pi 4/5."
         echo "   To force install, run: 'touch /tmp/ci5_override' and retry."
         exit 1
    fi
fi

# 2. OS DETECTION (The Fork)
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
elif [ -f /etc/openwrt_release ]; then
    OS="openwrt"
else
    OS="unknown"
fi

echo "   OS Identity: $OS"

if [ "$OS" = "raspbian" ] || [ "$OS" = "debian" ] || [ "$OS" = "openwrt" ]; then
    echo -e "   Compat:   ${GREEN}NATIVE${NC}"
else
    echo -e "   Compat:   ${YELLOW}EXPERIMENTAL ($OS)${NC}"
    echo "   Ci5 will attempt 'Generic Linux' implant mode."
    sleep 3
fi

# 3. INTERNET CHECK
if ! ping -c 1 1.1.1.1 >/dev/null 2>&1; then
    echo -e "${RED}ERR: NO UPLINK.${NC}"
    echo "Please plug WAN into an existing router for initial setup."
    exit 1
fi

echo -e "${GREEN}✓ Pre-flight Complete.${NC}"
exit 0