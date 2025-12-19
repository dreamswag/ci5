#!/bin/sh
# 🏰 Ci5 Unified Installer (v7.4-RC-1:Metamorphosis)
# Supports: Raspberry Pi OS (Implant Mode) & OpenWrt (Native Mode)

# Load Config
[ -f "ci5.config" ] && . ./ci5.config
[ -f "/etc/os-release" ] && . /etc/os-release

# Detect Mode
MODE="implant"
if command -v opkg >/dev/null; then
    MODE="native"
fi

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'

echo -e "${GREEN}=== Initiating Ci5 Install (Mode: ${MODE^^}) ===${NC}"

# ─────────────────────────────────────────────────────────────
# MODULE A: PACKAGE INSTALLATION
# ─────────────────────────────────────────────────────────────
echo "[*] Installing Dependencies..."
if [ "$MODE" = "native" ]; then
    # OPENWRT
    opkg update
    opkg install docker docker-compose dockerd luci-app-dockerman git-http curl
elif [ "$MODE" = "implant" ]; then
    # DEBIAN / PI OS
    apt-get update
    # Strip conflicting network managers
    systemctl disable --now dhcpcd 2>/dev/null
    systemctl disable --now NetworkManager 2>/dev/null
    
    # Install Engine & Tools
    curl -fsSL https://get.docker.com | sh
    apt-get install -y nftables bridge-utils ethtool irqbalance
fi

# ─────────────────────────────────────────────────────────────
# MODULE B: NETWORK CONFIGURATION
# ─────────────────────────────────────────────────────────────
echo "[*] Configuring Network Core..."

if [ "$MODE" = "native" ]; then
    # OPENWRT: Use UCI (Native)
    # This configures the router PERMANENTLY via OpenWrt config system
    uci set network.lan.ipaddr='192.168.99.1'
    uci set network.lan.proto='static'
    uci commit network
    /etc/init.d/network restart

elif [ "$MODE" = "implant" ]; then
    # PI OS: The Implant (rc.local injection)
    # We rely on configs/network_init.sh running at boot to override the OS
    
    echo "[*] Injecting Boot Scripts..."
    
    # 1. Enable IP Forwarding
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ci5-routing.conf
    
    # 2. Setup rc.local hook
    if ! grep -q "ci5/configs/network_init.sh" /etc/rc.local; then
        sed -i -e '$i \/opt\/ci5\/configs\/network_init.sh\n' /etc/rc.local
        sed -i -e '$i \/opt\/ci5\/configs\/firewall_init.sh\n' /etc/rc.local
        chmod +x /etc/rc.local
    fi
    
    # 3. Create Factory State (Offline Failsafe)
    echo "[*] Creating Factory Snapshot..."
    tar -czf /opt/ci5/factory_state.tar.gz -C /opt/ci5 .
fi

# ─────────────────────────────────────────────────────────────
# MODULE C: DOCKER STACK
# ─────────────────────────────────────────────────────────────
echo "[*] Deploying Docker Stack..."

# Configure Daemon (Force DNS to avoid loop)
mkdir -p /etc/docker
echo '{"dns": ["1.1.1.1"]}' > /etc/docker/daemon.json
systemctl restart docker 2>/dev/null || /etc/init.d/dockerd restart

# Deploy
cd /opt/ci5/docker
docker compose pull
# Note: We do NOT 'up' yet. We wait for reboot so networking is correct.

# ─────────────────────────────────────────────────────────────
# FINALIZATION
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}=== INSTALLATION COMPLETE ===${NC}"
echo "Mode: $MODE"
echo "IP Address: 192.168.99.1 (After Reboot)"
echo ""
echo "ACTION REQUIRED:"
echo "1. Unplug WAN from existing router."
echo "2. Plug WAN directly into Modem/ONT."
echo "3. Reboot."