#!/bin/sh
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'

if [ -f "ci5.config" ]; then
    . ./ci5.config
    export WAN_IFACE WAN_VLAN WAN_PROTO PPPOE_USER PPPOE_PASS LINK_TYPE
else
    echo -e "${RED}[✗] Config missing!${NC}"; exit 1
fi

echo "[*] Expanding Filesystem (Universal)..."
if command -v parted >/dev/null; then
    BOOT_DEV=$(mount | grep ' /boot ' | awk '{print $1}')
    if [ -n "$BOOT_DEV" ]; then
        ROOT_DISK=$(echo "$BOOT_DEV" | sed -E 's/p?[0-9]+$//')
        PART_NUM="2"
        if [[ "$ROOT_DISK" == *"mmcblk"* ]] || [[ "$ROOT_DISK" == *"nvme"* ]]; then
            TARGET_PART="${ROOT_DISK}p${PART_NUM}"
        else
            TARGET_PART="${ROOT_DISK}${PART_NUM}"
        fi
        
        if [ -b "$TARGET_PART" ]; then
            parted -s "$ROOT_DISK" resizepart "$PART_NUM" 100% 2>/dev/null
            resize2fs "$TARGET_PART" 2>/dev/null
            echo -e "${GREEN}    ✓ Storage Expanded ($TARGET_PART)${NC}"
        else
            echo -e "${YELLOW}    ! Warning: Partition $TARGET_PART not found. Skipping expansion.${NC}"
        fi
    fi
fi

echo "root:$ROUTER_PASS" | chpasswd

echo "[*] Applying Configs..."
chmod +x configs/*.sh
./configs/network_init.sh
./configs/firewall_init.sh
./configs/sqm_init.sh
./configs/dnsmasq_init.sh

echo "[*] Applying Kernel Tuning..."
cat configs/tuning_sysctl.conf > /etc/sysctl.conf
sysctl -p
cat configs/tuning_rclocal.sh > /etc/rc.local
chmod +x /etc/rc.local

echo "[*] Configuring DNS..."
[ -f "/etc/init.d/adguardhome" ] && /etc/init.d/adguardhome stop 2>/dev/null
cp configs/unbound /etc/config/unbound
uci set unbound.ub_main.listen_port='5335'
uci set unbound.ub_main.localservice='1'
uci set unbound.ub_main.enabled='1'
uci commit unbound
/etc/init.d/unbound enable
/etc/init.d/unbound restart

echo "[*] Running Speed Auto-Tune..."
# Fix: Auto-install speedtest-cli via pip if missing (Build Fallback)
if ! command -v speedtest-cli >/dev/null; then
    echo "    - Installing speedtest-cli via pip..."
    pip3 install speedtest-cli >/dev/null 2>&1
fi

if command -v speedtest-cli >/dev/null; then
    if [ -f "extras/speed_wizard.sh" ]; then
        sh extras/speed_wizard.sh auto
    fi
else
    echo -e "${YELLOW}    ! speedtest-cli install failed. Run manually later: pip3 install speedtest-cli && sh extras/speed_wizard.sh${NC}"
fi

echo "Rebooting..."
sleep 2
reboot
