#!/bin/sh
# 🆘 Ci5 Emergency Recovery Mode (v7.4-RC-1)
# Restores basic network access when locked out
#
# Usage Methods:
#   1. SSH (if still accessible): sh emergency_recovery.sh
#   2. Serial Console (UART): sh emergency_recovery.sh
#   3. Physical access to Pi terminal

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo ""
echo -e "${RED}========================================${NC}"
echo -e "${RED}   🆘 CI5 EMERGENCY RECOVERY MODE${NC}"
echo -e "${RED}========================================${NC}"
echo ""

# STEP 1: Create Fallback Static IP on eth0
echo "[1/4] Creating fallback interface..."
ip addr add 192.168.1.1/24 dev eth0 2>/dev/null || true
ip addr add 192.168.88.1/24 dev eth0 2>/dev/null || true
ip link set eth0 up
echo -e "${GREEN}      ✓ Fallback IPs: 192.168.1.1 + 192.168.88.1${NC}"

# STEP 2: Start Minimal DHCP Server
echo "[2/4] Starting emergency DHCP..."
killall dnsmasq 2>/dev/null || true
dnsmasq --interface=eth0 \
        --bind-interfaces \
        --dhcp-range=192.168.1.100,192.168.1.200,255.255.255.0,1h \
        --port=0 \
        --no-resolv \
        --no-hosts \
        --log-facility=/tmp/emergency_dhcp.log \
        2>/dev/null &
echo -e "${GREEN}      ✓ DHCP serving 192.168.1.100-200${NC}"

# STEP 3: Ensure SSH is Accessible
echo "[3/4] Verifying SSH access..."
if pgrep -x dropbear >/dev/null; then
    echo -e "${GREEN}      ✓ Dropbear SSH running${NC}"
elif pgrep -x sshd >/dev/null; then
    echo -e "${GREEN}      ✓ OpenSSH running${NC}"
else
    /etc/init.d/dropbear start 2>/dev/null || /etc/init.d/sshd start 2>/dev/null
    echo -e "${YELLOW}      ⚠ SSH was stopped, restarted${NC}"
fi

nft add rule inet fw4 input ip saddr 192.168.1.0/24 accept 2>/dev/null || true
nft add rule inet fw4 input ip saddr 192.168.88.0/24 accept 2>/dev/null || true
echo -e "${GREEN}      ✓ Firewall opened for fallback subnets${NC}"

# STEP 4: Display Recovery Instructions
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   ✅ EMERGENCY MODE ACTIVE${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Connect your PC directly to Pi 5 eth0 port and:"
echo ""
echo "  1. Set PC to DHCP (or static 192.168.1.x)"
echo "  2. SSH: ssh root@192.168.1.1"
echo "  3. Alt: ssh root@192.168.88.1"
echo ""
echo -e "${YELLOW}To restore normal operation:${NC}"
echo "  Option A: Fix your config manually"
echo "  Option B: Run 'sh /root/ci5/scripts/install-minimal.sh' to reset"
echo "  Option C: Reflash SD card with fresh image"
echo ""
echo -e "${RED}⚠️  This mode persists until reboot.${NC}"
echo ""

echo "Would you like to perform a FACTORY RESET?"
echo "This will erase all UCI config and restore OpenWrt defaults."
echo ""
read -p "Factory Reset? [y/N]: " RESET_CHOICE

if [ "$RESET_CHOICE" = "y" ] || [ "$RESET_CHOICE" = "Y" ]; then
    echo ""
    echo -e "${RED}⚠️  FACTORY RESET IN 5 SECONDS - CTRL+C TO ABORT${NC}"
    sleep 5
    echo "Resetting..."
    mkdir -p /root/pre-reset-backup
    cp -r /etc/config /root/pre-reset-backup/ 2>/dev/null
    firstboot -y && reboot
else
    echo ""
    echo "No reset performed. Emergency mode will remain active."
    echo "Reboot to restore normal (possibly broken) config."
fi
