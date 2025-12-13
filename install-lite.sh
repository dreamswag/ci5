#!/bin/sh
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo "=========================================="
echo "   🃏 Ci5 Lite Installer (Golden 0ms Base)"
echo "=========================================="
echo ""

# 1. Load Config
if [ -f "ci5.config" ]; then
    echo "[*] Loading configuration..."
    . ./ci5.config
    export WAN_IFACE WAN_PROTO PPPOE_USER PPPOE_PASS
else
    echo -e "${RED}[✗] Config missing! Run 'sh setup.sh' first.${NC}"
    exit 1
fi

# 2. Storage Expansion (Using tools from Custom Image)
echo "[*] Checking filesystem..."
if command -v parted >/dev/null && command -v resize2fs >/dev/null; then
    ROOT_DISK="/dev/mmcblk0"
    PART_NUM="2"
    if [ -b "$ROOT_DISK" ]; then
        echo "    - Expanding $ROOT_DISK partition $PART_NUM to 100%..."
        parted -s $ROOT_DISK resizepart $PART_NUM 100% 2>/dev/null
        resize2fs "${ROOT_DISK}p${PART_NUM}" 2>/dev/null
        echo -e "${GREEN}    ✓ Storage Expanded${NC}"
    fi
else
    echo -e "${RED}    ! Critical: 'parted' or 'resize2fs' missing from image.${NC}"
fi

# 3. Apply Password
echo "root:$ROUTER_PASS" | chpasswd

# 4. Package Verification (No Install)
echo "[*] Verifying Image Integrity..."
if ! opkg list-installed | grep -q "sqm-scripts"; then
    echo -e "${RED}[!] WARNING: sqm-scripts not found.${NC}"
    echo "    Ensure you flashed the Ci5 Custom Image."
fi

# 5. Apply Configs
echo "[*] Applying configurations..."
chmod +x configs/*.sh

./configs/network_init.sh
./configs/firewall_init.sh
./configs/sqm_init.sh
./configs/dnsmasq_init.sh

# 6. System Tuning (0ms Kernel Config)
echo "[*] Applying kernel tuning..."
cat configs/tuning_sysctl.conf > /etc/sysctl.conf
sysctl -p

# Overwrite RC.Local with Golden Tuning (Ring Buffers/Offloads)
cat configs/tuning_rclocal.sh > /etc/rc.local
chmod +x /etc/rc.local

# 7. DNS Stack (Unbound Only)
echo "[*] Configuring DNS..."
# Disable native AdGuard if present (migrated to Docker)
if [ -f "/etc/init.d/adguardhome" ]; then
    /etc/init.d/adguardhome stop 2>/dev/null
    /etc/init.d/adguardhome disable 2>/dev/null
fi

# Enable Unbound
uci set unbound.ub_main.listen_port='5335'
uci set unbound.ub_main.localservice='1'
uci set unbound.ub_main.enabled='1'
uci commit unbound
/etc/init.d/unbound enable
/etc/init.d/unbound restart

echo ""
echo "=========================================="
echo -e "${GREEN}[✓] Ci5 Core Installed${NC}"
echo "=========================================="

# 8. Auto-Tune Trigger
echo ""
echo "Running Speed Auto-Tune..."
# Install speedtest-cli via pip (pip must be in image)
if command -v pip3 >/dev/null; then
    pip3 install speedtest-cli >/dev/null 2>&1
    if [ -f "extras/speed_wizard.sh" ]; then
        sh extras/speed_wizard.sh auto
    else
        echo "⚠️ Speed wizard script missing."
    fi
else
    echo "⚠️ Python3/Pip missing from image. Skipping Auto-Tune."
fi

echo ""
echo "=========================================="
echo "   🎉 INSTALLATION COMPLETE"
echo "=========================================="
echo "1. Rebooting in 5 seconds..."
sleep 5
reboot
