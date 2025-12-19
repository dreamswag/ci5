#!/bin/bash
# ⛩️ Ci5 Bootstrap: The Phoenix Protocol
# Captures config -> Wipes Disk -> Flashes OpenWrt -> Injects Config -> Reboots

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
CONFIG_FILE="/dev/shm/ci5_soul.conf"

# --- 1. AM I ALREADY OPENWRT? ---
if [ -f /etc/openwrt_release ]; then
    echo -e "${GREEN}System is OpenWrt. Proceeding to Stack Injection...${NC}"
    opkg update && opkg install git-http curl ca-certificates
    mkdir -p /opt
    if [ -d "/opt/ci5" ]; then cd /opt/ci5 && git pull; else git clone https://github.com/dreamswag/ci5.git /opt/ci5; fi
    chmod +x /opt/ci5/*.sh
    exec /opt/ci5/install-full.sh
    exit 0
fi

# --- 2. THE INTERVIEW (Run on Debian) ---
clear
echo -e "${GREEN}Ci5 MIGRATION WIZARD${NC}"
echo "This will replace your current OS with Ci5 (OpenWrt)."
echo "We need your network details to ensure the new OS comes online automatically."
echo ""

# A. Detect Interface
IFACE=$(ls /sys/class/net | grep -v "lo" | head -n 1)
echo -e "Detected WAN Interface: ${YELLOW}$IFACE${NC}"

# B. Protocol Selection
echo ""
echo "Select WAN Protocol:"
echo "1) DHCP (Cable, Starlink, Existing Router)"
echo "2) PPPoE (Fiber/DSL - Requires Login)"
read -p "Select [1/2]: " PROTO_SEL

if [ "$PROTO_SEL" = "2" ]; then
    PROTO="pppoe"
    read -p "PPPoE Username: " PPP_USER
    read -p "PPPoE Password: " PPP_PASS
    read -p "VLAN ID (Leave empty if none, BT=101): " VLAN_ID
else
    PROTO="dhcp"
fi

# Save the "Soul" to RAM
cat > $CONFIG_FILE <<EOF
WAN_IFACE="$IFACE"
WAN_PROTO="$PROTO"
PPP_USER="$PPP_USER"
PPP_PASS="$PPP_PASS"
VLAN_ID="$VLAN_ID"
EOF

# --- 3. PREPARE THE FLASH (RAM) ---
MODEL=$(cat /proc/device-tree/model 2>/dev/null)
if echo "$MODEL" | grep -q "Raspberry Pi 5"; then
    IMG_URL="https://downloads.openwrt.org/snapshots/targets/bcm27xx/bcm2712/openwrt-bcm27xx-bcm2712-rpi-5-squashfs-factory.img.gz"
elif echo "$MODEL" | grep -q "Raspberry Pi 4"; then
    IMG_URL="https://downloads.openwrt.org/releases/23.05.2/targets/bcm27xx/bcm2711/openwrt-23.05.2-bcm27xx-bcm2711-rpi-4-squashfs-factory.img.gz"
else
    echo "Unsupported Hardware."
    exit 1
fi

echo ""
echo -e "${YELLOW}Downloading Payload to RAM...${NC}"
cd /dev/shm
curl -L -o openwrt.img.gz "$IMG_URL"
curl -L -o busybox "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox"
chmod +x busybox

# Create the Phoenix Script
cat > phoenix.sh << 'EOF'
#!/bin/sh
echo ">> WRITING OPENWRT TO DISK..."
zcat openwrt.img.gz | dd of=/dev/mmcblk0 bs=4M conv=fsync status=none

echo ">> RELOADING PARTITION TABLE..."
blockdev --rereadpt /dev/mmcblk0
mdev -s 2>/dev/null
sleep 2

echo ">> INJECTING SOUL (CONFIG)..."
mkdir -p /mnt/new_root
mount /dev/mmcblk0p2 /mnt/new_root

if [ $? -eq 0 ]; then
    . /ci5_soul.conf
    NW_FILE="/mnt/new_root/etc/config/network"
    RC_FILE="/mnt/new_root/etc/rc.local"

    # Reset network to basic static LAN
    echo "config interface 'loopback'" > $NW_FILE
    echo "    option device 'lo'" >> $NW_FILE
    echo "    option proto 'static'" >> $NW_FILE
    echo "    option ipaddr '127.0.0.1'" >> $NW_FILE
    echo "    option netmask '255.0.0.0'" >> $NW_FILE
    echo "" >> $NW_FILE
    echo "config globals 'globals'" >> $NW_FILE
    echo "    option ula_prefix 'fd00::/48'" >> $NW_FILE
    echo "" >> $NW_FILE
    echo "config device" >> $NW_FILE
    echo "    option name 'br-lan'" >> $NW_FILE
    echo "    option type 'bridge'" >> $NW_FILE
    echo "    list ports 'eth0'" >> $NW_FILE
    echo "" >> $NW_FILE
    echo "config interface 'lan'" >> $NW_FILE
    echo "    option device 'br-lan'" >> $NW_FILE
    echo "    option proto 'static'" >> $NW_FILE
    echo "    option ipaddr '192.168.1.1'" >> $NW_FILE
    echo "    option netmask '255.255.255.0'" >> $NW_FILE

    # Inject WAN
    WAN_DEV="$WAN_IFACE"
    echo "" >> $NW_FILE
    echo "config interface 'wan'" >> $NW_FILE
    if [ "$WAN_PROTO" = "pppoe" ]; then
        if [ -n "$VLAN_ID" ]; then
            echo "    option device '$WAN_DEV.$VLAN_ID'" >> $NW_FILE
        else
            echo "    option device '$WAN_DEV'" >> $NW_FILE
        fi
        echo "    option proto 'pppoe'" >> $NW_FILE
        echo "    option username '$PPP_USER'" >> $NW_FILE
        echo "    option password '$PPP_PASS'" >> $NW_FILE
    else
        echo "    option device '$WAN_DEV'" >> $NW_FILE
        echo "    option proto 'dhcp'" >> $NW_FILE
    fi
    echo "    option peerdns '0'" >> $NW_FILE 
    echo "    list dns '1.1.1.1'" >> $NW_FILE 

    # Inject Auto-Installer
    sed -i '$d' $RC_FILE
    echo "opkg update && opkg install git-http curl ca-certificates" >> $RC_FILE
    echo "git clone https://github.com/dreamswag/ci5.git /opt/ci5" >> $RC_FILE
    echo "chmod +x /opt/ci5/*.sh" >> $RC_FILE
    echo "/opt/ci5/install-full.sh &" >> $RC_FILE
    echo "exit 0" >> $RC_FILE

    umount /mnt/new_root
else
    echo ">> MOUNT FAILED. BOOTING STOCK."
fi

echo ">> REBOOTING..."
echo b > /proc/sysrq-trigger
EOF

chmod +x phoenix.sh
cp $CONFIG_FILE /dev/shm/ci5_soul.conf

# --- 4. EXECUTE PHOENIX ---
echo -e "${RED}Goodbye, Debian.${NC}"
mkdir -p /run/initramfs
mount -t tmpfs tmpfs /run/initramfs
cp phoenix.sh openwrt.img.gz ci5_soul.conf busybox /bin/dd /bin/gzip /bin/sync /run/initramfs/
cd /run/initramfs
echo 1 > /proc/sys/kernel/sysrq
echo u > /proc/sysrq-trigger
echo e > /proc/sysrq-trigger
exec /run/initramfs/phoenix.sh