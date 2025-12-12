#!/bin/sh
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo "=========================================="
echo "   🃏 Ci5 Lite Installer"
echo "=========================================="
echo ""

# 1. Load Config
if [ -f "ci5.config" ]; then
    echo "[*] Loading configuration..."
    . ./ci5.config
    # Export variables for child scripts
    export WAN_IFACE WAN_PROTO PPPOE_USER PPPOE_PASS
else
    echo -e "${RED}[✗] Config missing! Run 'sh setup.sh' first.${NC}"
    exit 1
fi

# 2. Apply Password
echo "root:$ROUTER_PASS" | chpasswd

# 3. Package Installation
echo "[*] Installing packages..."
opkg update
opkg install \
  kmod-sched-cake sqm-scripts \
  kmod-tcp-bbr ethtool \
  adguardhome unbound-daemon \
  luci-app-sqm luci-app-unbound \
  kmod-8021q python3-pip

# 4. Apply Configs
echo "[*] Applying configurations..."
chmod +x configs/*.sh

./configs/network_init.sh
./configs/firewall_init.sh
./configs/sqm_init.sh
./configs/dnsmasq_init.sh

# 5. System Tuning
echo "[*] Applying kernel tuning..."
cat configs/tuning_sysctl.conf >> /etc/sysctl.conf
sysctl -p

if ! grep -q "# Ci5 RPS" /etc/rc.local 2>/dev/null; then
    cat configs/tuning_rclocal.sh >> /etc/rc.local
fi
chmod +x /etc/rc.local

# 6. DNS Stack
echo "[*] Configuring DNS..."
uci set unbound.ub_main.listen_port='5335'
uci set unbound.ub_main.localservice='1'
uci set unbound.ub_main.enabled='1'
uci commit unbound
/etc/init.d/unbound enable
/etc/init.d/unbound restart
/etc/init.d/adguardhome enable
/etc/init.d/adguardhome start

echo ""
echo "=========================================="
echo -e "${GREEN}[✓] Ci5 Core Installed${NC}"
echo "=========================================="

# 7. Auto-Tune Trigger
echo ""
echo "Running Speed Auto-Tune..."
if [ -f "extras/speed_wizard.sh" ]; then
    sh extras/speed_wizard.sh
else
    echo "⚠️ Speed wizard not found. SQM disabled by default."
fi

echo ""
echo "=========================================="
echo "   🎉 INSTALLATION COMPLETE"
echo "=========================================="
echo "1. Rebooting in 5 seconds..."
sleep 5
reboot
