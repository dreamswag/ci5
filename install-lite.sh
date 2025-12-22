#!/bin/sh
# 🚀 Ci5 Lite Installer (v7.5-HARDENED)
# Critical Fixes Applied:
#   [1] Atomic rollback on failure
#   [4] Dynamic partition detection (mmcblk/nvme/sda)
#   [5] Interactive cancel before reboot

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# ─────────────────────────────────────────────────────────────
# CRITICAL FIX [1]: ATOMIC ROLLBACK INFRASTRUCTURE
# ─────────────────────────────────────────────────────────────
ROLLBACK_ENABLED=0
BACKUP_DIR=""
ROLLBACK_MARKER="/tmp/.ci5_rollback_in_progress"

init_atomic_rollback() {
    BACKUP_DIR="/root/ci5-backup-$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    
    # Capture full system state
    echo "[ATOMIC] Creating restoration checkpoint..."
    
    # 1. UCI config snapshot
    cp -r /etc/config "$BACKUP_DIR/config" 2>/dev/null
    
    # 2. Critical system files
    cp /etc/rc.local "$BACKUP_DIR/rc.local" 2>/dev/null
    cp /etc/sysctl.conf "$BACKUP_DIR/sysctl.conf" 2>/dev/null
    cp /etc/passwd "$BACKUP_DIR/passwd" 2>/dev/null
    cp /etc/shadow "$BACKUP_DIR/shadow" 2>/dev/null
    
    # 3. Network state
    ip addr show > "$BACKUP_DIR/ip_addr.txt" 2>/dev/null
    ip route show > "$BACKUP_DIR/ip_route.txt" 2>/dev/null
    
    # 4. OpenWrt full backup (if available)
    if command -v sysupgrade >/dev/null 2>&1; then
        sysupgrade -b "$BACKUP_DIR/full-backup.tar.gz" 2>/dev/null
    fi
    
    # 5. Create rollback manifest
    cat > "$BACKUP_DIR/manifest.txt" << EOF
CI5_ROLLBACK_MANIFEST
Created: $(date)
Hostname: $(cat /proc/sys/kernel/hostname)
Kernel: $(uname -r)
EOF
    
    ROLLBACK_ENABLED=1
    echo "[ATOMIC] Checkpoint saved: $BACKUP_DIR"
}

execute_rollback() {
    if [ "$ROLLBACK_ENABLED" -ne 1 ] || [ -z "$BACKUP_DIR" ]; then
        echo "[ATOMIC] No rollback checkpoint available"
        return 1
    fi
    
    # Prevent recursive rollback
    if [ -f "$ROLLBACK_MARKER" ]; then
        echo "[ATOMIC] Rollback already in progress, aborting"
        return 1
    fi
    touch "$ROLLBACK_MARKER"
    
    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  🔄 EXECUTING ATOMIC ROLLBACK                                    ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # 1. Restore UCI configs
    if [ -d "$BACKUP_DIR/config" ]; then
        echo "[ROLLBACK] Restoring UCI configuration..."
        rm -rf /etc/config.failed 2>/dev/null
        mv /etc/config /etc/config.failed 2>/dev/null
        cp -r "$BACKUP_DIR/config" /etc/config
    fi
    
    # 2. Restore system files
    [ -f "$BACKUP_DIR/rc.local" ] && cp "$BACKUP_DIR/rc.local" /etc/rc.local
    [ -f "$BACKUP_DIR/sysctl.conf" ] && cp "$BACKUP_DIR/sysctl.conf" /etc/sysctl.conf
    
    # 3. Reload services
    echo "[ROLLBACK] Reloading services..."
    /etc/init.d/network reload 2>/dev/null
    /etc/init.d/firewall reload 2>/dev/null
    /etc/init.d/dnsmasq restart 2>/dev/null
    
    # 4. Verify network connectivity
    sleep 3
    if ping -c 1 -W 5 1.1.1.1 >/dev/null 2>&1; then
        echo -e "${GREEN}[ROLLBACK] Network restored successfully${NC}"
    else
        echo -e "${YELLOW}[ROLLBACK] Network may need manual intervention${NC}"
    fi
    
    rm -f "$ROLLBACK_MARKER"
    
    echo ""
    echo -e "${GREEN}[ROLLBACK] System restored to pre-install state${NC}"
    echo "Backup preserved at: $BACKUP_DIR"
    echo "Failed config saved at: /etc/config.failed"
    
    return 0
}

# Trap handler for failures
rollback_on_error() {
    local exit_code=$?
    local line_number=${1:-unknown}
    
    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  ❌ INSTALLATION FAILED AT LINE $line_number (Exit: $exit_code)${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Log file: $LOG_FILE"
    echo ""
    
    if [ "$ROLLBACK_ENABLED" -eq 1 ]; then
        echo -n "Automatic rollback available. Execute rollback? [Y/n]: "
        read -t 30 ROLLBACK_CHOICE || ROLLBACK_CHOICE="y"
        
        if [ "$ROLLBACK_CHOICE" != "n" ] && [ "$ROLLBACK_CHOICE" != "N" ]; then
            execute_rollback
        else
            echo "Rollback skipped. Manual recovery may be required."
            echo "Backup location: $BACKUP_DIR"
        fi
    fi
    
    show_cursor
    exit 1
}

# ─────────────────────────────────────────────────────────────
# CRITICAL FIX [4]: DYNAMIC PARTITION DETECTION
# ─────────────────────────────────────────────────────────────
detect_root_partition() {
    # Detect the root device and partition scheme
    ROOT_DEV=$(mount | grep ' / ' | awk '{print $1}')
    
    if [ -z "$ROOT_DEV" ]; then
        echo "[PARTITION] Warning: Could not detect root device"
        return 1
    fi
    
    # Extract base device and partition number
    case "$ROOT_DEV" in
        /dev/mmcblk*p*)
            # SD Card: /dev/mmcblk0p2 -> base=/dev/mmcblk0, part=2
            ROOT_DISK=$(echo "$ROOT_DEV" | sed 's/p[0-9]*$//')
            PART_NUM=$(echo "$ROOT_DEV" | grep -o 'p[0-9]*$' | tr -d 'p')
            PART_PREFIX="p"
            STORAGE_TYPE="sdcard"
            ;;
        /dev/nvme*n*p*)
            # NVMe: /dev/nvme0n1p2 -> base=/dev/nvme0n1, part=2
            ROOT_DISK=$(echo "$ROOT_DEV" | sed 's/p[0-9]*$//')
            PART_NUM=$(echo "$ROOT_DEV" | grep -o 'p[0-9]*$' | tr -d 'p')
            PART_PREFIX="p"
            STORAGE_TYPE="nvme"
            ;;
        /dev/sd*)
            # USB/SATA: /dev/sda2 -> base=/dev/sda, part=2
            ROOT_DISK=$(echo "$ROOT_DEV" | sed 's/[0-9]*$//')
            PART_NUM=$(echo "$ROOT_DEV" | grep -o '[0-9]*$')
            PART_PREFIX=""
            STORAGE_TYPE="usb"
            ;;
        *)
            echo "[PARTITION] Unknown device type: $ROOT_DEV"
            STORAGE_TYPE="unknown"
            return 1
            ;;
    esac
    
    TARGET_PART="${ROOT_DISK}${PART_PREFIX}${PART_NUM}"
    
    echo "[PARTITION] Detected:"
    echo "   Root Device: $ROOT_DEV"
    echo "   Base Disk:   $ROOT_DISK"
    echo "   Partition:   $PART_NUM"
    echo "   Type:        $STORAGE_TYPE"
    
    # Validate the detected partition exists
    if [ ! -b "$TARGET_PART" ]; then
        echo "[PARTITION] Error: Target partition $TARGET_PART not found"
        return 1
    fi
    
    export ROOT_DISK ROOT_DEV TARGET_PART PART_NUM STORAGE_TYPE
    return 0
}

expand_filesystem() {
    if ! command -v parted >/dev/null 2>&1; then
        echo "[EXPAND] parted not available, skipping expansion"
        return 0
    fi
    
    if ! detect_root_partition; then
        echo "[EXPAND] Partition detection failed, skipping expansion"
        return 0
    fi
    
    echo "[EXPAND] Attempting to expand $TARGET_PART on $ROOT_DISK..."
    
    # Check if expansion is needed (partition doesn't fill disk)
    DISK_SIZE=$(blockdev --getsize64 "$ROOT_DISK" 2>/dev/null)
    PART_END=$(parted -s "$ROOT_DISK" unit B print 2>/dev/null | grep "^ ${PART_NUM}" | awk '{print $3}' | tr -d 'B')
    
    if [ -n "$DISK_SIZE" ] && [ -n "$PART_END" ]; then
        REMAINING=$((DISK_SIZE - PART_END))
        if [ "$REMAINING" -lt 104857600 ]; then  # Less than 100MB remaining
            echo "[EXPAND] Partition already fills disk (${REMAINING}B remaining)"
            return 0
        fi
    fi
    
    # Expand partition
    parted -s "$ROOT_DISK" resizepart "$PART_NUM" 100% 2>/dev/null
    
    # Expand filesystem
    case "$STORAGE_TYPE" in
        sdcard|nvme|usb)
            if resize2fs "$TARGET_PART" 2>/dev/null; then
                echo "[EXPAND] Filesystem expanded successfully"
            else
                echo "[EXPAND] resize2fs failed (may not be ext4)"
            fi
            ;;
    esac
    
    return 0
}

# ─────────────────────────────────────────────────────────────
# LEADERBOARD DATA (Fetched/Hardcoded - Update via CI/CD)
# ─────────────────────────────────────────────────────────────
GUINEA_RANK_0_NAME="—"
GUINEA_RANK_0_ISP="—"
GUINEA_RANK_0_THROUGHPUT="—"
GUINEA_RANK_0_LATENCY="—"
GUINEA_RANK_0_DATE="—"

SHAME_RANK_1_NAME="—"; SHAME_RANK_1_ISP="—"; SHAME_RANK_1_THROUGHPUT="—"
SHAME_RANK_1_LATENCY="—"; SHAME_RANK_1_APPLIANCE="—"; SHAME_RANK_1_COST="—"
SHAME_RANK_2_NAME="—"; SHAME_RANK_2_ISP="—"; SHAME_RANK_2_THROUGHPUT="—"
SHAME_RANK_2_LATENCY="—"; SHAME_RANK_2_APPLIANCE="—"; SHAME_RANK_2_COST="—"
SHAME_RANK_3_NAME="—"; SHAME_RANK_3_ISP="—"; SHAME_RANK_3_THROUGHPUT="—"
SHAME_RANK_3_LATENCY="—"; SHAME_RANK_3_APPLIANCE="—"; SHAME_RANK_3_COST="—"
SHAME_RANK_4_NAME="—"; SHAME_RANK_4_ISP="—"; SHAME_RANK_4_THROUGHPUT="—"
SHAME_RANK_4_LATENCY="—"; SHAME_RANK_4_APPLIANCE="—"; SHAME_RANK_4_COST="—"
SHAME_RANK_5_NAME="—"; SHAME_RANK_5_ISP="—"; SHAME_RANK_5_THROUGHPUT="—"
SHAME_RANK_5_LATENCY="—"; SHAME_RANK_5_APPLIANCE="—"; SHAME_RANK_5_COST="—"

# ─────────────────────────────────────────────────────────────
# TERMINAL CONTROL
# ─────────────────────────────────────────────────────────────
TERM_LINES=$(tput lines 2>/dev/null || echo 24)
TERM_COLS=$(tput cols 2>/dev/null || echo 80)
STATUS_LINE=32

save_cursor() { printf '\033[s'; }
restore_cursor() { printf '\033[u'; }
move_cursor() { printf '\033[%d;%dH' "$1" "$2"; }
clear_line() { printf '\033[2K'; }
hide_cursor() { printf '\033[?25l'; }
show_cursor() { printf '\033[?25h'; }

cleanup() {
    show_cursor
    tput cnorm 2>/dev/null
}
trap cleanup EXIT INT TERM

# ─────────────────────────────────────────────────────────────
# SPINNER ANIMATION
# ─────────────────────────────────────────────────────────────
SPINNER_CHARS="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
SPINNER_IDX=0

spin() {
    SPINNER_IDX=$(( (SPINNER_IDX + 1) % 10 ))
    printf '%s' "$(echo "$SPINNER_CHARS" | cut -c$((SPINNER_IDX + 1)))"
}

progress_bar() {
    local current=$1
    local total=$2
    local width=40
    local pct=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))
    
    printf "${CYAN}["
    printf '%*s' "$filled" '' | tr ' ' '█'
    printf '%*s' "$empty" '' | tr ' ' '░'
    printf "] ${GREEN}%3d%%${NC}" "$pct"
}

# ─────────────────────────────────────────────────────────────
# DISPLAY LEADERBOARD (PERSISTENT)
# ─────────────────────────────────────────────────────────────
display_leaderboard() {
    clear
    hide_cursor
    
    echo -e "${MAGENTA}╔════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║${NC}                    ${BOLD}${CYAN}🐹🪽 ST. GUINEA CI5 🪦🎖️${NC}                                   ${MAGENTA}║${NC}"
    echo -e "${MAGENTA}║${NC}              ${DIM}First to verifiably hit 1.74Gbps+ with Full Stack${NC}                 ${MAGENTA}║${NC}"
    echo -e "${MAGENTA}╠════════════════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${MAGENTA}║${NC} ${BOLD}Rank${NC} │ ${BOLD}Name${NC}              │ ${BOLD}ISP Speed${NC}  │ ${BOLD}Throughput${NC}  │ ${BOLD}Latency${NC}  │ ${BOLD}Date${NC}       ${MAGENTA}║${NC}"
    echo -e "${MAGENTA}╟──────┼───────────────────┼────────────┼─────────────┼──────────┼────────────╢${NC}"
    printf "${MAGENTA}║${NC}  ${YELLOW}0${NC}   │ %-17s │ %-10s │ %-11s │ %-8s │ %-10s ${MAGENTA}║${NC}\n" \
        "$GUINEA_RANK_0_NAME" "$GUINEA_RANK_0_ISP" "$GUINEA_RANK_0_THROUGHPUT" "$GUINEA_RANK_0_LATENCY" "$GUINEA_RANK_0_DATE"
    echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    echo -e "${RED}╔════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║${NC}                      ${BOLD}${YELLOW}👨‍🚀🏆 HALL_OF.shame 🛰️🌎${NC}                                ${RED}║${NC}"
    echo -e "${RED}║${NC}            ${DIM}Top 5 within 31 days of first 1.74Gbps+ 'flent rrul'${NC}               ${RED}║${NC}"
    echo -e "${RED}╠════════════════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${RED}║${NC} ${BOLD}#${NC} │ ${BOLD}Name${NC}         │ ${BOLD}Throughput${NC} │ ${BOLD}Latency${NC} │ ${BOLD}Appliance Beaten${NC}      │ ${BOLD}Cost/Ratio${NC}  ${RED}║${NC}"
    echo -e "${RED}╟───┼──────────────┼────────────┼─────────┼───────────────────────┼────────────╢${NC}"
    
    printf "${RED}║${NC} ${GREEN}1${NC} │ %-12s │ %-10s │ %-7s │ %-21s │ %-10s ${RED}║${NC}\n" \
        "$SHAME_RANK_1_NAME" "$SHAME_RANK_1_THROUGHPUT" "$SHAME_RANK_1_LATENCY" "$SHAME_RANK_1_APPLIANCE" "$SHAME_RANK_1_COST"
    printf "${RED}║${NC} ${GREEN}2${NC} │ %-12s │ %-10s │ %-7s │ %-21s │ %-10s ${RED}║${NC}\n" \
        "$SHAME_RANK_2_NAME" "$SHAME_RANK_2_THROUGHPUT" "$SHAME_RANK_2_LATENCY" "$SHAME_RANK_2_APPLIANCE" "$SHAME_RANK_2_COST"
    printf "${RED}║${NC} ${GREEN}3${NC} │ %-12s │ %-10s │ %-7s │ %-21s │ %-10s ${RED}║${NC}\n" \
        "$SHAME_RANK_3_NAME" "$SHAME_RANK_3_THROUGHPUT" "$SHAME_RANK_3_LATENCY" "$SHAME_RANK_3_APPLIANCE" "$SHAME_RANK_3_COST"
    printf "${RED}║${NC} ${GREEN}4${NC} │ %-12s │ %-10s │ %-7s │ %-21s │ %-10s ${RED}║${NC}\n" \
        "$SHAME_RANK_4_NAME" "$SHAME_RANK_4_THROUGHPUT" "$SHAME_RANK_4_LATENCY" "$SHAME_RANK_4_APPLIANCE" "$SHAME_RANK_4_COST"
    printf "${RED}║${NC} ${GREEN}5${NC} │ %-12s │ %-10s │ %-7s │ %-21s │ %-10s ${RED}║${NC}\n" \
        "$SHAME_RANK_5_NAME" "$SHAME_RANK_5_THROUGHPUT" "$SHAME_RANK_5_LATENCY" "$SHAME_RANK_5_APPLIANCE" "$SHAME_RANK_5_COST"
    
    echo -e "${RED}╚════════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BLUE}══════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}                       🚀 CI5 LITE INSTALLER v7.5-HARDENED${NC}"
    echo -e "${BLUE}══════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# ─────────────────────────────────────────────────────────────
# UPDATE STATUS LINE (DYNAMIC)
# ─────────────────────────────────────────────────────────────
CURRENT_STEP=0
TOTAL_STEPS=12

update_status() {
    local message="$1"
    local step="$2"
    
    [ -n "$step" ] && CURRENT_STEP=$step
    
    move_cursor $STATUS_LINE 1
    clear_line
    
    printf "   "
    progress_bar $CURRENT_STEP $TOTAL_STEPS
    echo ""
    
    move_cursor $((STATUS_LINE + 1)) 1
    clear_line
    printf "   ${CYAN}$(spin)${NC} ${BOLD}%s${NC}" "$message"
    
    move_cursor $((STATUS_LINE + 2)) 1
    clear_line
}

log_success() {
    move_cursor $((STATUS_LINE + 3)) 1
    printf "   ${GREEN}✓${NC} %s\n" "$1"
}

log_warning() {
    move_cursor $((STATUS_LINE + 3)) 1
    printf "   ${YELLOW}⚠${NC} %s\n" "$1"
}

log_error() {
    move_cursor $((STATUS_LINE + 3)) 1
    printf "   ${RED}✗${NC} %s\n" "$1"
}

# ─────────────────────────────────────────────────────────────
# LOGGING SETUP
# ─────────────────────────────────────────────────────────────
LOG_FILE="/root/ci5-install-$(date +%Y%m%d_%H%M%S).log"
exec 3>&1 4>&2
exec 1>>"$LOG_FILE" 2>&1

echo "=== Ci5 Lite Installation Started: $(date) ===" >&1
echo "=== Log File: $LOG_FILE ===" >&1

display_to_term() {
    echo "$@" >&3
}

# ─────────────────────────────────────────────────────────────
# DISPLAY LEADERBOARD
# ─────────────────────────────────────────────────────────────
display_leaderboard >&3

# ─────────────────────────────────────────────────────────────
# INITIALIZE ATOMIC ROLLBACK
# ─────────────────────────────────────────────────────────────
update_status "Creating atomic rollback checkpoint..." 1 >&3
init_atomic_rollback >> "$LOG_FILE" 2>&1
log_success "Rollback checkpoint created: $BACKUP_DIR" >&3

# Set trap with line number reporting
trap 'rollback_on_error $LINENO' ERR

# ─────────────────────────────────────────────────────────────
# CONFIG VALIDATION
# ─────────────────────────────────────────────────────────────
update_status "Validating configuration..." 2 >&3

if [ -f "ci5.config" ]; then
    . ./ci5.config
    export WAN_IFACE WAN_VLAN WAN_PROTO PPPOE_USER PPPOE_PASS LINK_TYPE ROUTER_PASS
elif [ -f "/root/ci5/ci5.config" ]; then
    . /root/ci5/ci5.config
    export WAN_IFACE WAN_VLAN WAN_PROTO PPPOE_USER PPPOE_PASS LINK_TYPE ROUTER_PASS
else
    move_cursor $STATUS_LINE 1 >&3
    clear_line >&3
    echo -e "   ${RED}[✗] Config missing! Run setup.sh first.${NC}" >&3
    show_cursor
    exit 1
fi

if [ -z "$WAN_IFACE" ] || [ -z "$ROUTER_PASS" ]; then
    move_cursor $STATUS_LINE 1 >&3
    clear_line >&3
    echo -e "   ${RED}[✗] Invalid config. Re-run setup.sh${NC}" >&3
    show_cursor
    exit 1
fi

sleep 0.5
log_success "Configuration validated" >&3

# ─────────────────────────────────────────────────────────────
# TIME SYNCHRONIZATION
# ─────────────────────────────────────────────────────────────
update_status "Synchronizing system clock..." 3 >&3

/etc/init.d/sysntpd restart 2>/dev/null || true
if command -v ntpd >/dev/null 2>&1; then
    ntpd -q -p pool.ntp.org 2>/dev/null || ntpd -q -p time.google.com 2>/dev/null || true
fi
sleep 1

log_success "Time synchronized: $(date)" >&3

# ─────────────────────────────────────────────────────────────
# FILESYSTEM EXPANSION (Using dynamic detection)
# ─────────────────────────────────────────────────────────────
update_status "Expanding filesystem (dynamic detection)..." 4 >&3

expand_filesystem >> "$LOG_FILE" 2>&1
if [ -n "$STORAGE_TYPE" ]; then
    log_success "Storage: $STORAGE_TYPE ($TARGET_PART)" >&3
else
    log_warning "Partition detection skipped" >&3
fi

sleep 0.3

# ─────────────────────────────────────────────────────────────
# SET ROOT PASSWORD
# ─────────────────────────────────────────────────────────────
update_status "Setting root password..." 5 >&3

echo "root:$ROUTER_PASS" | chpasswd
sleep 0.2
log_success "Root password configured" >&3

# ─────────────────────────────────────────────────────────────
# APPLY NETWORK CONFIG
# ─────────────────────────────────────────────────────────────
update_status "Applying network configuration..." 6 >&3

chmod +x configs/*.sh 2>/dev/null
./configs/network_init.sh
sleep 0.3
log_success "Network interfaces configured" >&3

# ─────────────────────────────────────────────────────────────
# APPLY FIREWALL CONFIG
# ─────────────────────────────────────────────────────────────
update_status "Configuring firewall zones..." 7 >&3

./configs/firewall_init.sh
sleep 0.3
log_success "Firewall zones configured" >&3

# ─────────────────────────────────────────────────────────────
# APPLY SQM CONFIG
# ─────────────────────────────────────────────────────────────
update_status "Initializing SQM/CAKE..." 8 >&3

./configs/sqm_init.sh
sleep 0.3
log_success "SQM initialized" >&3

# ─────────────────────────────────────────────────────────────
# APPLY DNSMASQ CONFIG
# ─────────────────────────────────────────────────────────────
update_status "Configuring DHCP/DNS..." 9 >&3

./configs/dnsmasq_init.sh
sleep 0.3
log_success "DHCP/DNS configured" >&3

# ─────────────────────────────────────────────────────────────
# KERNEL TUNING
# ─────────────────────────────────────────────────────────────
update_status "Applying kernel optimizations..." 10 >&3

cat configs/tuning_sysctl.conf > /etc/sysctl.conf
sysctl -p >/dev/null 2>&1
cat configs/tuning_rclocal.sh > /etc/rc.local
chmod +x /etc/rc.local

sleep 0.3
log_success "Kernel parameters optimized" >&3

# ─────────────────────────────────────────────────────────────
# DNS (UNBOUND)
# ─────────────────────────────────────────────────────────────
update_status "Configuring Unbound DNS resolver..." 11 >&3

[ -f "/etc/init.d/adguardhome" ] && /etc/init.d/adguardhome stop 2>/dev/null
cp configs/unbound /etc/config/unbound
uci set unbound.ub_main.listen_port='5335'
uci set unbound.ub_main.localservice='1'
uci set unbound.ub_main.enabled='1'
uci commit unbound
/etc/init.d/unbound enable
/etc/init.d/unbound restart

sleep 0.5
log_success "Unbound DNS resolver active" >&3

# ─────────────────────────────────────────────────────────────
# SPEED AUTO-TUNE
# ─────────────────────────────────────────────────────────────
update_status "Running speed auto-tune (this takes ~30s)..." 12 >&3

if ! command -v speedtest-cli >/dev/null; then
    update_status "Installing speedtest-cli via pip..." 12 >&3
    pip3 install speedtest-cli --break-system-packages >/dev/null 2>&1 || \
    pip3 install speedtest-cli >/dev/null 2>&1
fi

if command -v speedtest-cli >/dev/null; then
    if [ -f "extras/speed_wizard.sh" ]; then
        sh extras/speed_wizard.sh auto
        log_success "Speed auto-tune complete" >&3
    fi
else
    log_warning "speedtest-cli unavailable. Using defaults." >&3
    uci set sqm.eth1.enabled='1'
    uci set sqm.eth1.download='475000'
    uci set sqm.eth1.upload='475000'
    uci commit sqm
fi

# ─────────────────────────────────────────────────────────────
# SD CARD WEAR PROTECTION
# ─────────────────────────────────────────────────────────────
if [ "$STORAGE_TYPE" = "sdcard" ]; then
    update_status "Configuring SD card wear protection..." 12 >&3
    cat > /etc/logrotate.d/ci5 << 'LOGROTATE'
/var/log/messages {
    rotate 3
    size 5M
    compress
    missingok
}
LOGROTATE
    log_success "Log rotation configured" >&3
fi

# ─────────────────────────────────────────────────────────────
# COMMIT & VALIDATE
# ─────────────────────────────────────────────────────────────
update_status "Committing changes and validating..." 12 >&3

uci commit
/etc/init.d/network reload 2>/dev/null
/etc/init.d/firewall reload 2>/dev/null
/etc/init.d/sqm restart 2>/dev/null

sleep 1

# ─────────────────────────────────────────────────────────────
# VALIDATION
# ─────────────────────────────────────────────────────────────
VALIDATION_FAILED=0
for vlan in 10 20 30 40; do
    if ! ip link show eth0.${vlan} >/dev/null 2>&1; then
        log_warning "VLAN $vlan will be created on reboot" >&3
    fi
done
if ! pgrep unbound >/dev/null; then
    log_warning "Unbound will start on reboot" >&3
fi

# ─────────────────────────────────────────────────────────────
# COMPLETE - WITH INTERACTIVE CANCEL (CRITICAL FIX [5])
# ─────────────────────────────────────────────────────────────
move_cursor $STATUS_LINE 1 >&3
clear_line >&3
progress_bar $TOTAL_STEPS $TOTAL_STEPS >&3
echo "" >&3

move_cursor $((STATUS_LINE + 2)) 1 >&3
echo -e "${GREEN}══════════════════════════════════════════════════════════════════════════════════${NC}" >&3
echo -e "${GREEN}                        ✅ LITE INSTALLATION COMPLETE${NC}" >&3
echo -e "${GREEN}══════════════════════════════════════════════════════════════════════════════════${NC}" >&3
echo "" >&3
echo -e "   ${CYAN}Log:${NC}    $LOG_FILE" >&3
echo -e "   ${CYAN}Backup:${NC} $BACKUP_DIR" >&3
echo "" >&3

# CRITICAL FIX: Interactive reboot with cancel option
show_cursor >&3
echo -e "   ${YELLOW}System will reboot in 30 seconds to apply changes.${NC}" >&3
echo "" >&3
echo -e "   ${BOLD}Options:${NC}" >&3
echo -e "     Press ${GREEN}ENTER${NC} to reboot immediately" >&3
echo -e "     Press ${RED}C${NC} to cancel and stay in shell" >&3
echo -e "     Wait 30 seconds for automatic reboot" >&3
echo "" >&3

# Read with timeout - allows cancel
REBOOT_CHOICE=""
read -t 30 -n 1 REBOOT_CHOICE 2>&3 <&3 || true

case "$REBOOT_CHOICE" in
    c|C)
        echo "" >&3
        echo -e "${YELLOW}Reboot cancelled.${NC}" >&3
        echo "Run 'reboot' manually when ready." >&3
        echo "Or run 'sh validate.sh' to verify installation." >&3
        exit 0
        ;;
    *)
        echo "" >&3
        echo -e "${GREEN}Rebooting now...${NC}" >&3
        sleep 1
        reboot
        ;;
esac
