#!/bin/sh
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo "=========================================="
echo "   🃏 Ci5 Lite Installer"
echo "=========================================="
echo ""

# Pre-flight
if [ ! -f /etc/openwrt_release ]; then
    echo -e "${RED}[✗] Not running OpenWrt!${NC}"
    exit 1
fi

if ! grep -q "Raspberry Pi 5" /proc/cpuinfo 2>/dev/null; then
    echo -e "${RED}[!] WARNING: Not a Raspberry Pi 5${NC}"
    read -p "    Continue anyway? (y/n): " hw_confirm
    [ "$hw_confirm" != "y" ] && exit 0
fi

if ! ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
    echo -e "${RED}[✗] No internet connectivity!${NC}"
    exit 1
fi

echo -e "${GREEN}[✓] Pre-flight checks passed${NC}"
echo ""

# Backup
echo "[*] Backing up existing config..."
mkdir -p /tmp/ci5-backup
tar -czf /tmp/ci5-backup/config-$(date +%s).tar.gz /etc/config/ 2>/dev/null
echo "    Saved to /tmp/ci5-backup/"
echo ""

# WAN Detection
echo "Detected network interfaces:"
ip -br link | grep -E 'eth|enp'
echo ""
read -p "WAN interface [eth1]: " WAN_IFACE
WAN_IFACE=${WAN_IFACE:-eth1}
export WAN_IFACE

echo ""
echo "WAN Protocol:"
echo "  1) DHCP (most common)"
echo "  2) PPPoE (DSL/some fiber)"
read -p "Choose [1-2]: " wan_choice

if [ "$wan_choice" = "2" ]; then
    WAN_PROTO="pppoe"
    read -p "PPPoE Username: " PPPOE_USER
    read -sp "PPPoE Password: " PPPOE_PASS
    echo ""
    export WAN_PROTO PPPOE_USER PPPOE_PASS
else
    WAN_PROTO="dhcp"
    export WAN_PROTO
fi

echo ""
echo -e "${GREEN}[+] Starting installation...${NC}"
echo ""

# Package Installation
echo "[*] Installing packages..."
opkg update
opkg install \
  kmod-sched-cake sqm-scripts \
  kmod-tcp-bbr ethtool \
  adguardhome unbound-daemon \
  luci-app-sqm luci-app-unbound

# Apply Configs
echo "[*] Applying configurations..."
chmod +x configs/*.sh

./configs/network_init.sh
./configs/firewall_init.sh
./configs/sqm_init.sh
./configs/dnsmasq_init.sh

# System Tuning
echo "[*] Applying kernel tuning..."
cat configs/tuning_sysctl.conf >> /etc/sysctl.conf
sysctl -p

if ! grep -q "# Ci5 RPS" /etc/rc.local 2>/dev/null; then
    cat configs/tuning_rclocal.sh >> /etc/rc.local
fi
chmod +x /etc/rc.local

# DNS Setup
echo "[*] Configuring DNS stack..."

# Unbound (port 5335)
uci set unbound.ub_main.listen_port='5335'
uci set unbound.ub_main.localservice='1'
uci set unbound.ub_main.protocol='ip4_ip6'
uci set unbound.ub_main.verbosity='1'
uci set unbound.ub_main.enabled='1'
uci commit unbound

/etc/init.d/unbound enable
/etc/init.d/unbound restart

# AdGuard (port 53, upstream to Unbound)
/etc/init.d/adguardhome enable
/etc/init.d/adguardhome start

echo ""
echo "=========================================="
echo -e "${GREEN}[✓] Ci5 Lite installation complete!${NC}"
echo "=========================================="
echo ""
echo "⚠️  NEXT STEPS:"
echo ""
echo "1. REBOOT NOW:"
echo "   reboot"
echo ""
echo "2. After reboot, configure AdGuard:"
echo "   http://192.168.99.1:3000"
echo ""
echo "3. Validate installation:"
echo "   sh validate.sh"
echo ""
echo "4. For Full Stack (Docker IDS/monitoring):"
echo "   sh install-full.sh"
echo "=========================================="
