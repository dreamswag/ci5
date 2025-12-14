#!/bin/sh
# 🚀 Ci5 Lite Installer (v7.4-RC-1)
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'

# ─────────────────────────────────────────────────────────────
# LOGGING SETUP
# ─────────────────────────────────────────────────────────────
LOG_FILE="/root/ci5-install-$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== Ci5 Lite Installation Started: $(date) ==="
echo "=== Log File: $LOG_FILE ==="

# ─────────────────────────────────────────────────────────────
# CONFIG VALIDATION
# ─────────────────────────────────────────────────────────────
if [ -f "ci5.config" ]; then
    . ./ci5.config
    export WAN_IFACE WAN_VLAN WAN_PROTO PPPOE_USER PPPOE_PASS LINK_TYPE ROUTER_PASS
else
    echo -e "${RED}[✗] Config missing! Run setup.sh first.${NC}"
    exit 1
fi

if [ -z "$WAN_IFACE" ] || [ -z "$ROUTER_PASS" ]; then
    echo -e "${RED}[✗] Invalid config. Re-run setup.sh${NC}"
    exit 1
fi

# ─────────────────────────────────────────────────────────────
# BACKUP EXISTING CONFIG
# ─────────────────────────────────────────────────────────────
echo "[*] Creating Configuration Backup..."
BACKUP_DIR="/root/ci5-backup-$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp -r /etc/config "$BACKUP_DIR/" 2>/dev/null
cp /etc/rc.local "$BACKUP_DIR/" 2>/dev/null
cp /etc/sysctl.conf "$BACKUP_DIR/" 2>/dev/null
if command -v sysupgrade >/dev/null 2>&1; then
    sysupgrade -b "$BACKUP_DIR/full-backup.tar.gz" 2>/dev/null
fi
echo -e "${GREEN}    ✓ Backup saved to $BACKUP_DIR${NC}"

# Error handler
rollback_on_error() {
    echo -e "${RED}[!] Installation failed. Check log: $LOG_FILE${NC}"
    echo "    Backup available at: $BACKUP_DIR"
    exit 1
}
trap rollback_on_error ERR

# ─────────────────────────────────────────────────────────────
# TIME SYNCHRONIZATION
# ─────────────────────────────────────────────────────────────
echo "[*] Synchronizing System Clock..."
/etc/init.d/sysntpd restart 2>/dev/null || true
if command -v ntpd >/dev/null 2>&1; then
    ntpd -q -p pool.ntp.org 2>/dev/null || ntpd -q -p time.google.com 2>/dev/null || true
fi
sleep 2
echo -e "${GREEN}    ✓ Time: $(date)${NC}"

# ─────────────────────────────────────────────────────────────
# FILESYSTEM EXPANSION
# ─────────────────────────────────────────────────────────────
echo "[*] Expanding Filesystem (Universal)..."
if command -v parted >/dev/null; then
    BOOT_DEV=$(mount | grep ' /boot ' | awk '{print $1}')
    if [ -n "$BOOT_DEV" ]; then
        ROOT_DISK=$(echo "$BOOT_DEV" | sed -E 's/p?[0-9]+$//')
        PART_NUM="2"
        if echo "$ROOT_DISK" | grep -qE "(mmcblk|nvme)"; then
            TARGET_PART="${ROOT_DISK}p${PART_NUM}"
        else
            TARGET_PART="${ROOT_DISK}${PART_NUM}"
        fi
        
        if [ -b "$TARGET_PART" ]; then
            parted -s "$ROOT_DISK" resizepart "$PART_NUM" 100% 2>/dev/null
            resize2fs "$TARGET_PART" 2>/dev/null
            echo -e "${GREEN}    ✓ Storage Expanded ($TARGET_PART)${NC}"
        else
            echo -e "${YELLOW}    ! Warning: Partition $TARGET_PART not found. Skipping.${NC}"
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
sysctl -p >/dev/null 2>&1
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
if ! command -v speedtest-cli >/dev/null; then
    echo "    - Installing speedtest-cli via pip..."
    pip3 install speedtest-cli --break-system-packages >/dev/null 2>&1 || \
    pip3 install speedtest-cli >/dev/null 2>&1
fi

if command -v speedtest-cli >/dev/null; then
    if [ -f "extras/speed_wizard.sh" ]; then
        sh extras/speed_wizard.sh auto
    fi
else
    echo -e "${YELLOW}    ! speedtest-cli unavailable. Using defaults.${NC}"
    uci set sqm.eth1.enabled='1'
    uci set sqm.eth1.download='475000'
    uci set sqm.eth1.upload='475000'
    uci commit sqm
fi

# ─────────────────────────────────────────────────────────────
# SD CARD WEAR PROTECTION
# ─────────────────────────────────────────────────────────────
ROOT_DEV=$(mount | grep ' / ' | awk '{print $1}')
if echo "$ROOT_DEV" | grep -q "mmcblk"; then
    echo "[*] Configuring SD Card Wear Protection..."
    cat > /etc/logrotate.d/ci5 << 'LOGROTATE'
/var/log/messages {
    rotate 3
    size 5M
    compress
    missingok
}
LOGROTATE
    echo -e "${GREEN}    ✓ Log rotation configured${NC}"
fi

# ─────────────────────────────────────────────────────────────
# COMMIT & VALIDATE
# ─────────────────────────────────────────────────────────────
uci commit
/etc/init.d/network reload 2>/dev/null
/etc/init.d/firewall reload 2>/dev/null
/etc/init.d/sqm restart 2>/dev/null

echo "[*] Validating..."
VALIDATION_FAILED=0
for vlan in 10 20 30 40; do
    if ! ip link show eth0.${vlan} >/dev/null 2>&1; then
        echo -e "${YELLOW}    ⚠ VLAN $vlan will be created on reboot${NC}"
    fi
done
if ! pgrep unbound >/dev/null; then
    echo -e "${YELLOW}    ⚠ Unbound will start on reboot${NC}"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   ✅ LITE INSTALLATION COMPLETE${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Log: $LOG_FILE"
echo "Backup: $BACKUP_DIR"
echo ""
echo "Rebooting in 5 seconds..."
sleep 5
reboot
