#!/bin/sh
# CI5 Bootloader Gateway - Handles build choice, autoconfig, nuke/migration, and installer branching
# Supports: curl -sL ci5.run/free | sh (recommended), /4evr (minimal), /1314 (custom)

set -e

# Constants
CONFIG_FILE="/dev/shm/ci5_soul.conf"
GOLDEN_URL="https://github.com/dreamswag/ci5/releases/latest/download/ci5-factory.img.gz"
CI5_REPO="https://github.com/dreamswag/ci5.git"
IMAGE_NAME="Ci5-factory.img.gz"

# Colors
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[1m'; N='\033[0m'

info() { printf "${G}[✓]${N} %s\n" "$1"; }
warn() { printf "${Y}[!]${N} %s\n" "$1"; }
err()  { printf "${R}[✗]${N} %s\n" "$1"; }
step() { printf "\n${B}═══ %s ═══${N}\n\n" "$1"; }

# Set mode: Env Var takes precedence (from wrappers), then flags, then default
[ -n "$INSTALL_MODE" ] || INSTALL_MODE="recommended"

for arg in "$@"; do
    case "$arg" in
        -free) INSTALL_MODE="recommended" ;;
        -4evr) INSTALL_MODE="minimal" ;;
        -1314) INSTALL_MODE="custom" ;;
    esac
done

export INSTALL_MODE

# ─────────────────────────────────────────────────────────────────────────────
# PLATFORM DETECTION
# ─────────────────────────────────────────────────────────────────────────────
detect_platform() {
    if [ -f /etc/openwrt_release ]; then
        PLATFORM="openwrt"
        PKG_UPDATE="opkg update"
        PKG_INSTALL="opkg install"
    elif [ -f /etc/debian_version ]; then
        PLATFORM="debian"
        PKG_UPDATE="apt-get update -qq"
        PKG_INSTALL="apt-get install -y -qq"
    else
        err "Unsupported platform"
        exit 1
    fi
    info "Detected platform: $PLATFORM"
}

# ─────────────────────────────────────────────────────────────────────────────
# HARDWARE CHECK (Pi 5)
# ─────────────────────────────────────────────────────────────────────────────
check_hardware() {
    if ! grep -q "Raspberry Pi 5" /proc/cpuinfo; then
        warn "This is optimized for Raspberry Pi 5. Proceeding in 3s..."
        sleep 3
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# AUTO-CAPTURE ISP SETTINGS (OpenWrt only)
# ─────────────────────────────────────────────────────────────────────────────
capture_openwrt_isp() {
    step "AUTO-CAPTURING ISP SETTINGS (OpenWrt)"

    WAN_IF=$(uci get network.wan.device 2>/dev/null || uci get network.wan.ifname 2>/dev/null || ip route | awk '/default/ {print $5; exit}')
    WAN_PROTO=$(uci get network.wan.proto 2>/dev/null || echo "dhcp")
    VLAN_ID=""  # Detect if device has .VLAN, e.g., eth1.101
    if echo "$WAN_IF" | grep -q '\.'; then
        VLAN_ID=$(echo "$WAN_IF" | cut -d'.' -f2)
        WAN_IF=$(echo "$WAN_IF" | cut -d'.' -f1)
    fi

    if [ "$WAN_PROTO" = "pppoe" ]; then
        ISP_USER=$(uci get network.wan.username 2>/dev/null || "")
        ISP_PASS=$(uci get network.wan.password 2>/dev/null || "")
    fi

    LAN_IF=$(uci get network.lan.device 2>/dev/null || "eth0")

    # Capture SQM if exists
    SQM_DOWNLOAD=$(uci get sqm.wan.download 2>/dev/null || 0)
    SQM_UPLOAD=$(uci get sqm.wan.upload 2>/dev/null || 0)
    SQM_OVERHEAD=$(uci get sqm.wan.overhead 2>/dev/null || 0)
    SQM_LINKLAYER=$(uci get sqm.wan.linklayer 2>/dev/null || "none")

    # Display captured
    info "Captured settings:"
    info "  WAN Interface: $WAN_IF"
    [ -n "$VLAN_ID" ] && info "  VLAN ID: $VLAN_ID"
    info "  Protocol: $WAN_PROTO"
    [ "$WAN_PROTO" = "pppoe" ] && info "  PPPoE User: $ISP_USER"
    info "  LAN Interface: $LAN_IF"
    info "  SQM Download/Upload: $SQM_DOWNLOAD / $SQM_UPLOAD kbit/s"
    info "  SQM Overhead/Linklayer: $SQM_OVERHEAD / $SQM_LINKLAYER"

    printf "${Y}Use these settings? (or configure manually) [Y/m]: ${N}"
    read -r ans
    if [ "$ans" = "m" ] || [ "$ans" = "M" ]; then
        interactive_isp_setup
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# INTERACTIVE ISP SETUP (Manual for Debian or override)
# ─────────────────────────────────────────────────────────────────────────────
interactive_isp_setup() {
    step "CONFIGURE ISP SETTINGS"

    echo "Detected interfaces:"
    ip -br link show | grep -v lo

    printf "WAN interface (e.g., eth1): "
    read -r WAN_IF

    printf "LAN interface (e.g., eth0): "
    read -r LAN_IF

    echo "Select WAN Protocol:"
    echo "1) DHCP (Cable, Starlink, Existing Router)"
    echo "2) PPPoE (Fiber/DSL - Requires Login)"
    printf "Select [1/2]: "
    read -r PROTO_SEL
    if [ "$PROTO_SEL" = "2" ]; then
        WAN_PROTO="pppoe"
        printf "PPPoE Username: "
        read -r ISP_USER
        printf "PPPoE Password: "
        read -r ISP_PASS
        printf "VLAN ID (leave empty if none): "
        read -r VLAN_ID
    else
        WAN_PROTO="dhcp"
    fi

    echo "Underlying connection type (for CAKE overhead):"
    echo "1) Cable Modem (DOCSIS)"
    echo "2) Fiber/Ethernet"
    echo "3) VDSL"
    echo "4) ADSL"
    echo "5) Other"
    printf "Select [1-5]: "
    read -r LINK_SEL
    case "$LINK_SEL" in
        1) LINK_TYPE="cable"; LINKLAYER="ethernet"; BASE_OVERHEAD=22 ;;
        2) LINK_TYPE="fiber"; LINKLAYER="ethernet"; BASE_OVERHEAD=18 ;;
        3) LINK_TYPE="vdsl"; LINKLAYER="none"; BASE_OVERHEAD=26 ;;
        4) LINK_TYPE="adsl"; LINKLAYER="atm"; BASE_OVERHEAD=40 ;;
        *) LINK_TYPE="other"; LINKLAYER="ethernet"; BASE_OVERHEAD=18 ;;
    esac

    # Compute overhead
    OVERHEAD=$BASE_OVERHEAD
    [ "$WAN_PROTO" = "pppoe" ] && OVERHEAD=$((OVERHEAD + 8))
    [ -n "$VLAN_ID" ] && OVERHEAD=$((OVERHEAD + 4))

    printf "Approximate download speed (Mbps, 0 to set manually later): "
    read -r DOWNLOAD_MBPS
    printf "Approximate upload speed (Mbps, 0 to set manually later): "
    read -r UPLOAD_MBPS
}

# ─────────────────────────────────────────────────────────────────────────────
# PRESERVE CORKS
# ─────────────────────────────────────────────────────────────────────────────
preserve_corks() {
    EXISTING_CORKS=""
    if [ -f /etc/ci5_corks ]; then
        EXISTING_CORKS=$(cat /etc/ci5_corks)
        info "Preserving Corks: $EXISTING_CORKS"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# SAVE SOUL TO RAM
# ─────────────────────────────────────────────────────────────────────────────
save_soul() {
    cat > $CONFIG_FILE <<EOF
WAN_IF="$WAN_IF"
LAN_IF="$LAN_IF"
WAN_PROTO="$WAN_PROTO"
ISP_USER="$ISP_USER"
ISP_PASS="$ISP_PASS"
VLAN_ID="$VLAN_ID"
LINKLAYER="$LINKLAYER"
OVERHEAD="$OVERHEAD"
DOWNLOAD_MBPS="$DOWNLOAD_MBPS"
UPLOAD_MBPS="$UPLOAD_MBPS"
EXISTING_CORKS="$EXISTING_CORKS"
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# NUKE OPENWRT CONFIG TO BASELINE
# ─────────────────────────────────────────────────────────────────────────────
nuke_openwrt_config() {
    step "NUKING EXISTING OPENWRT CONFIG TO BASELINE"

    if [ -n "$SSH_CONNECTION" ]; then
        warn "NUKE OVER SSH MAY LOCK YOU OUT!"
        printf "Type NUKE to continue: "
        read -r confirm
        [ "$confirm" = "NUKE" ] || exit 1
    fi

    # Overwrite network config
    cat > /etc/config/network << EOF
config interface 'loopback'
    option device 'lo'
    option proto 'static'
    option ipaddr '127.0.0.1'
    option netmask '255.0.0.0'

config globals 'globals'
    option ula_prefix 'fd00::/48'

config device
    option name 'br-lan'
    option type 'bridge'
    list ports '$LAN_IF'

config interface 'lan'
    option device 'br-lan'
    option proto 'static'
    option ipaddr '192.168.99.1'
    option netmask '255.255.255.0'

config interface 'wan'
    option proto '$WAN_PROTO'
EOF

    if [ "$WAN_PROTO" = "pppoe" ]; then
        WAN_DEV="$WAN_IF"
        [ -n "$VLAN_ID" ] && WAN_DEV="$WAN_IF.$VLAN_ID"
        echo "    option device '$WAN_DEV'" >> /etc/config/network
        echo "    option username '$ISP_USER'" >> /etc/config/network
        echo "    option password '$ISP_PASS'" >> /etc/config/network
    else
        echo "    option device '$WAN_IF'" >> /etc/config/network
    fi
    echo "    option peerdns '0'" >> /etc/config/network
    echo "    list dns '1.1.1.1'" >> /etc/config/network

    /etc/init.d/network restart || true
    sleep 5

    # Set SQM
    $PKG_INSTALL sqm-scripts luci-app-sqm >/dev/null 2>&1
    DOWNLOAD_KBPS=0
    UPLOAD_KBPS=0
    if [ "$DOWNLOAD_MBPS" -gt 0 ]; then
        DOWNLOAD_KBPS=$((DOWNLOAD_MBPS * 950))
    fi
    if [ "$UPLOAD_MBPS" -gt 0 ]; then
        UPLOAD_KBPS=$((UPLOAD_MBPS * 950))
    fi

    uci batch << EOF
set sqm.wan=queue
set sqm.wan.enabled='1'
set sqm.wan.interface='$WAN_IF'
set sqm.wan.download='$DOWNLOAD_KBPS'
set sqm.wan.upload='$UPLOAD_KBPS'
set sqm.wan.qdisc='cake'
set sqm.wan.script='piece_of_cake.qos'
set sqm.wan.linklayer='$LINKLAYER'
set sqm.wan.overhead='$OVERHEAD'
commit sqm
EOF
    /etc/init.d/sqm restart >/dev/null 2>&1 || true

    info "OpenWrt config nuked to baseline with injected settings"
}

# ─────────────────────────────────────────────────────────────────────────────
# FLASH GOLDEN IMAGE (Debian to OpenWrt migration)
# ─────────────────────────────────────────────────────────────────────────────
flash_golden_image() {
    step "FLASHING GOLDEN IMAGE (Debian to OpenWrt)"

    cd /dev/shm
    info "Downloading Golden Image..."
    curl -L -o openwrt.img.gz "$GOLDEN_URL"
    [ -s openwrt.img.gz ] || err "Download failed"

    curl -L -o busybox "https://busybox.net/downloads/binaries/1.35.0-aarch64-linux-musl/busybox"
    chmod +x busybox

    cat > phoenix.sh << 'EOF'
#!/bin/sh
zcat openwrt.img.gz | dd of=/dev/mmcblk0 bs=4M conv=fsync status=none
./busybox blockdev --rereadpt /dev/mmcblk0
sleep 1
printf "d\n2\nn\np\n2\n\n\nw\n" | ./busybox fdisk /dev/mmcblk0
./busybox blockdev --rereadpt /dev/mmcblk0
sleep 1
mkdir -p /mnt/new_root
mount /dev/mmcblk0p2 /mnt/new_root
if [ $? -eq 0 ]; then
    . /ci5_soul.conf
    NW_FILE="/mnt/new_root/etc/config/network"
    SQM_FILE="/mnt/new_root/etc/config/sqm"
    RC_FILE="/mnt/new_root/etc/rc.local"
    if [ -n "$EXISTING_CORKS" ]; then
        echo "$EXISTING_CORKS" > /mnt/new_root/etc/ci5_corks
    fi
    echo "config interface 'loopback'" > $NW_FILE
    echo " option device 'lo'" >> $NW_FILE
    echo " option proto 'static'" >> $NW_FILE
    echo " option ipaddr '127.0.0.1'" >> $NW_FILE
    echo " option netmask '255.0.0.0'" >> $NW_FILE
    echo "config globals 'globals'" >> $NW_FILE
    echo " option ula_prefix 'fd00::/48'" >> $NW_FILE
    echo "config device" >> $NW_FILE
    echo " option name 'br-lan'" >> $NW_FILE
    echo " option type 'bridge'" >> $NW_FILE
    echo " list ports '$LAN_IF'" >> $NW_FILE
    echo "config interface 'lan'" >> $NW_FILE
    echo " option device 'br-lan'" >> $NW_FILE
    echo " option proto 'static'" >> $NW_FILE
    echo " option ipaddr '192.168.99.1'" >> $NW_FILE
    echo " option netmask '255.255.255.0'" >> $NW_FILE
    echo "config interface 'wan'" >> $NW_FILE
    WAN_DEV="$WAN_IF"
    [ -n "$VLAN_ID" ] && WAN_DEV="$WAN_IF.$VLAN_ID"
    echo " option device '$WAN_DEV'" >> $NW_FILE
    echo " option proto '$WAN_PROTO'" >> $NW_FILE
    if [ "$WAN_PROTO" = "pppoe" ]; then
        echo " option username '$ISP_USER'" >> $NW_FILE
        echo " option password '$ISP_PASS'" >> $NW_FILE
    fi
    echo " option peerdns '0'" >> $NW_FILE
    echo " list dns '1.1.1.1'" >> $NW_FILE

    # Inject SQM
    DOWNLOAD_KBPS=0
    UPLOAD_KBPS=0
    if [ "$DOWNLOAD_MBPS" -gt 0 ]; then
        DOWNLOAD_KBPS=$((DOWNLOAD_MBPS * 950))
    fi
    if [ "$UPLOAD_MBPS" -gt 0 ]; then
        UPLOAD_KBPS=$((UPLOAD_MBPS * 950))
    fi
    echo "config queue 'wan'" > $SQM_FILE
    echo " option enabled '1'" >> $SQM_FILE
    echo " option interface '$WAN_IF'" >> $SQM_FILE
    echo " option download '$DOWNLOAD_KBPS'" >> $SQM_FILE
    echo " option upload '$UPLOAD_KBPS'" >> $SQM_FILE
    echo " option qdisc 'cake'" >> $SQM_FILE
    echo " option script 'piece_of_cake.qos'" >> $SQM_FILE
    echo " option linklayer '$LINKLAYER'" >> $SQM_FILE
    echo " option overhead '$OVERHEAD'" >> $SQM_FILE

    # Inject installer to rc.local (OFFLINE-FIRST: Using Pre-baked scripts)
    sed -i '$d' $RC_FILE
    echo "chmod +x /root/ci5/scripts/*.sh" >> $RC_FILE
    case "$INSTALL_MODE" in
        recommended) echo "/root/ci5/scripts/install-recommended.sh --nuke &" >> $RC_FILE ;;
        minimal)     echo "/root/ci5/scripts/install-minimal.sh &" >> $RC_FILE ;;
        custom)      echo "/root/ci5/scripts/install-custom.sh &" >> $RC_FILE ;;
    esac
    echo "exit 0" >> $RC_FILE
    umount /mnt/new_root
fi
echo b > /proc/sysrq-trigger
EOF

    chmod +x phoenix.sh
    cp $CONFIG_FILE /dev/shm/ci5_soul.conf

    echo -e "${R}Executing Phoenix Protocol...${N}"
    mkdir -p /run/initramfs
    mount -t tmpfs tmpfs /run/initramfs
    cp phoenix.sh openwrt.img.gz ci5_soul.conf busybox /run/initramfs/
    cd /run/initramfs
    echo 1 > /proc/sys/kernel/sysrq
    echo u > /proc/sysrq-trigger
    echo e > /proc/sysrq-trigger
    exec /run/initramfs/phoenix.sh
}

# ─────────────────────────────────────────────────────────────────────────────
# RUN INSTALLER (OpenWrt path)
# ─────────────────────────────────────────────────────────────────────────────
run_installer() {
    step "RUNNING CI5 INSTALLER ($INSTALL_MODE)"

    # Prioritize local path from build script
    local LOCAL_PATH="/root/ci5/scripts"
    
    if [ ! -d "$LOCAL_PATH" ]; then
        info "Pre-baked scripts not found. Attempting emergency pull..."
        $PKG_UPDATE >/dev/null 2>&1
        $PKG_INSTALL git-http curl ca-certificates >/dev/null 2>&1
        git clone https://github.com/dreamswag/ci5.git /root/ci5 >/dev/null 2>&1
    fi

    chmod +x "$LOCAL_PATH"/*.sh

    case "$INSTALL_MODE" in
        recommended) exec "$LOCAL_PATH/install-recommended.sh" --nuke ;;
        minimal)     exec "$LOCAL_PATH/install-minimal.sh" ;;
        custom)      exec "$LOCAL_PATH/install-custom.sh" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# RUN SPEED TEST (Auto for SQM)
# ─────────────────────────────────────────────────────────────────────────────
run_speed_test() {
    step "AUTO-CONFIGURING SQM VIA SPEED TEST"

    $PKG_INSTALL speedtest-cli >/dev/null 2>&1 || true
    if command -v speedtest-cli >/dev/null; then
        /opt/ci5/scripts/diagnostics/speed_test.sh auto
    else
        warn "Speedtest CLI unavailable. SQM set to manual tuning."
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
main() {
    clear
    printf "${B}CI5 PHOENIX BOOTLOADER — $INSTALL_MODE Mode${N}\n"
    printf "═══════════════════════════════════════════════════\n\n"

    check_hardware
    detect_platform
    preserve_corks

    if [ "$PLATFORM" = "openwrt" ]; then
        capture_openwrt_isp
        save_soul
        nuke_openwrt_config
        run_installer
    else  # Debian
        interactive_isp_setup
        save_soul
        prepare_image
        warn "Connect WAN to eth1 now for tuning. Press Enter when ready."
        read -r _
        flash_golden_image
    fi

    info "Rebooting to complete setup..."
    reboot
}

main "$@"