#!/bin/sh
# 🚀 Ci5 Lite Installer (v7.4-RC-1)
# Enhanced with HG Leaderboard Loading Screen

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# ─────────────────────────────────────────────────────────────
# LEADERBOARD DATA (Fetched/Hardcoded - Update via CI/CD)
# ─────────────────────────────────────────────────────────────
# St. Guinea CiG - First 1.74Gbps+
GUINEA_RANK_0_NAME="—"
GUINEA_RANK_0_ISP="—"
GUINEA_RANK_0_THROUGHPUT="—"
GUINEA_RANK_0_LATENCY="—"
GUINEA_RANK_0_DATE="—"

# Hall of .shAME - Top 5 (within 31 days of first record)
SHAME_RANK_1_NAME="—"
SHAME_RANK_1_ISP="—"
SHAME_RANK_1_THROUGHPUT="—"
SHAME_RANK_1_LATENCY="—"
SHAME_RANK_1_APPLIANCE="—"
SHAME_RANK_1_COST="—"

SHAME_RANK_2_NAME="—"
SHAME_RANK_2_ISP="—"
SHAME_RANK_2_THROUGHPUT="—"
SHAME_RANK_2_LATENCY="—"
SHAME_RANK_2_APPLIANCE="—"
SHAME_RANK_2_COST="—"

SHAME_RANK_3_NAME="—"
SHAME_RANK_3_ISP="—"
SHAME_RANK_3_THROUGHPUT="—"
SHAME_RANK_3_LATENCY="—"
SHAME_RANK_3_APPLIANCE="—"
SHAME_RANK_3_COST="—"

SHAME_RANK_4_NAME="—"
SHAME_RANK_4_ISP="—"
SHAME_RANK_4_THROUGHPUT="—"
SHAME_RANK_4_LATENCY="—"
SHAME_RANK_4_APPLIANCE="—"
SHAME_RANK_4_COST="—"

SHAME_RANK_5_NAME="—"
SHAME_RANK_5_ISP="—"
SHAME_RANK_5_THROUGHPUT="—"
SHAME_RANK_5_LATENCY="—"
SHAME_RANK_5_APPLIANCE="—"
SHAME_RANK_5_COST="—"

# ─────────────────────────────────────────────────────────────
# TERMINAL CONTROL
# ─────────────────────────────────────────────────────────────
TERM_LINES=$(tput lines 2>/dev/null || echo 24)
TERM_COLS=$(tput cols 2>/dev/null || echo 80)
STATUS_LINE=32  # Line where status updates appear

# Save cursor position, move cursor, restore
save_cursor() { printf '\033[s'; }
restore_cursor() { printf '\033[u'; }
move_cursor() { printf '\033[%d;%dH' "$1" "$2"; }
clear_line() { printf '\033[2K'; }
hide_cursor() { printf '\033[?25l'; }
show_cursor() { printf '\033[?25h'; }

# Cleanup on exit
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

# Progress bar
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
    
    # Header
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
    
    # Hall of .shAME
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
    echo -e "${BOLD}                         🚀 CI5 LITE INSTALLER v7.4-RC-1${NC}"
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
    
    # Move to status area
    move_cursor $STATUS_LINE 1
    clear_line
    
    # Progress bar
    printf "   "
    progress_bar $CURRENT_STEP $TOTAL_STEPS
    echo ""
    
    move_cursor $((STATUS_LINE + 1)) 1
    clear_line
    printf "   ${CYAN}$(spin)${NC} ${BOLD}%s${NC}" "$message"
    
    # Status details line
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
# ANIMATED TASK EXECUTION
# ─────────────────────────────────────────────────────────────
run_task() {
    local step="$1"
    local message="$2"
    shift 2
    local cmd="$@"
    
    update_status "$message" "$step"
    
    # Run with spinner animation
    (
        while true; do
            update_status "$message"
            sleep 0.1
        done
    ) &
    SPINNER_PID=$!
    
    # Execute actual command
    eval "$cmd" >> "$LOG_FILE" 2>&1
    local result=$?
    
    # Kill spinner
    kill $SPINNER_PID 2>/dev/null
    wait $SPINNER_PID 2>/dev/null
    
    return $result
}

# ─────────────────────────────────────────────────────────────
# LOGGING SETUP
# ─────────────────────────────────────────────────────────────
LOG_FILE="/root/ci5-install-$(date +%Y%m%d_%H%M%S).log"
exec 3>&1 4>&2  # Save stdout/stderr
exec 1>>"$LOG_FILE" 2>&1

echo "=== Ci5 Lite Installation Started: $(date) ===" >&1
echo "=== Log File: $LOG_FILE ===" >&1

# Restore for display functions
display_to_term() {
    echo "$@" >&3
}

# ─────────────────────────────────────────────────────────────
# DISPLAY LEADERBOARD
# ─────────────────────────────────────────────────────────────
display_leaderboard >&3

# ─────────────────────────────────────────────────────────────
# CONFIG VALIDATION
# ─────────────────────────────────────────────────────────────
update_status "Validating configuration..." 1 >&3

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
# BACKUP EXISTING CONFIG
# ─────────────────────────────────────────────────────────────
update_status "Creating configuration backup..." 2 >&3

BACKUP_DIR="/root/ci5-backup-$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp -r /etc/config "$BACKUP_DIR/" 2>/dev/null
cp /etc/rc.local "$BACKUP_DIR/" 2>/dev/null
cp /etc/sysctl.conf "$BACKUP_DIR/" 2>/dev/null
if command -v sysupgrade >/dev/null 2>&1; then
    sysupgrade -b "$BACKUP_DIR/full-backup.tar.gz" 2>/dev/null
fi

sleep 0.3
log_success "Backup saved to $BACKUP_DIR" >&3

# Error handler
rollback_on_error() {
    move_cursor $STATUS_LINE 1 >&3
    clear_line >&3
    echo -e "   ${RED}[!] Installation failed. Check log: $LOG_FILE${NC}" >&3
    echo "    Backup available at: $BACKUP_DIR" >&3
    show_cursor
    exit 1
}
trap 'rollback_on_error' ERR

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
# FILESYSTEM EXPANSION
# ─────────────────────────────────────────────────────────────
update_status "Expanding filesystem (if needed)..." 4 >&3

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
            log_success "Storage expanded ($TARGET_PART)" >&3
        else
            log_warning "Partition $TARGET_PART not found. Skipping." >&3
        fi
    fi
else
    log_warning "parted not available, skipping expansion" >&3
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
ROOT_DEV=$(mount | grep ' / ' | awk '{print $1}')
if echo "$ROOT_DEV" | grep -q "mmcblk"; then
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
# COMPLETE
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
echo -e "   ${YELLOW}Rebooting in 5 seconds...${NC}" >&3

show_cursor
sleep 5
reboot
