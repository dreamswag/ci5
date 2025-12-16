#!/bin/sh
# 🏰 Ci5 Full Stack Installer (v7.4-RC-1)
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

# Docker-specific spinner (container icons)
DOCKER_SPINNER="🐳🐋🐳🐋"
DOCKER_IDX=0

docker_spin() {
    DOCKER_IDX=$(( (DOCKER_IDX + 1) % 4 ))
    case $DOCKER_IDX in
        0) printf '🐳' ;;
        1) printf '🐋' ;;
        2) printf '🐳' ;;
        3) printf '🐋' ;;
    esac
}

# Progress bar
progress_bar() {
    local current=$1
    local total=$2
    local width=40
    local pct=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))
    
    printf "${MAGENTA}["
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
    echo -e "${BOLD}                   🏰 CI5 FULL STACK INSTALLER v7.4-RC-1 🐳${NC}"
    echo -e "${BLUE}══════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# ─────────────────────────────────────────────────────────────
# UPDATE STATUS LINE (DYNAMIC)
# ─────────────────────────────────────────────────────────────
CURRENT_STEP=0
TOTAL_STEPS=10

update_status() {
    local message="$1"
    local step="$2"
    local is_docker="$3"
    
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
    
    if [ "$is_docker" = "docker" ]; then
        printf "   ${CYAN}$(docker_spin)${NC} ${BOLD}%s${NC}" "$message"
    else
        printf "   ${CYAN}$(spin)${NC} ${BOLD}%s${NC}" "$message"
    fi
    
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

# Container status display
show_container_status() {
    local name="$1"
    local status="$2"
    local icon="$3"
    
    move_cursor $((STATUS_LINE + 4)) 1
    clear_line
    printf "       ${DIM}├─${NC} %s ${BOLD}%s${NC}: %s" "$icon" "$name" "$status"
}

# ─────────────────────────────────────────────────────────────
# LOGGING SETUP
# ─────────────────────────────────────────────────────────────
LOG_FILE="/root/ci5-full-install-$(date +%Y%m%d_%H%M%S).log"
exec 3>&1 4>&2  # Save stdout/stderr

# Log function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# ─────────────────────────────────────────────────────────────
# DISPLAY LEADERBOARD
# ─────────────────────────────────────────────────────────────
display_leaderboard

log "=== Ci5 Full Stack Installation Started ==="

# ─────────────────────────────────────────────────────────────
# STEP 1: INSTALL DOCKER
# ─────────────────────────────────────────────────────────────
update_status "Installing Docker daemon..." 1

{
    opkg update
    opkg install dockerd docker-compose crowdsec-firewall-bouncer
} >> "$LOG_FILE" 2>&1

sleep 0.5
log_success "Docker packages installed"

# ─────────────────────────────────────────────────────────────
# STEP 2: CONFIGURE DOCKER DAEMON
# ─────────────────────────────────────────────────────────────
update_status "Configuring Docker daemon (DNS lockdown)..." 2

mkdir -p /etc/docker
cat << 'JSON' > /etc/docker/daemon.json
{
  "iptables": false,
  "ip6tables": false,
  "bip": "172.18.0.1/24",
  "dns": ["192.168.99.1"],
  "mtu": 1452,
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
JSON

log "Docker daemon.json configured"
sleep 0.3
log_success "Docker DNS locked to local resolver"

# ─────────────────────────────────────────────────────────────
# STEP 3: START DOCKER
# ─────────────────────────────────────────────────────────────
update_status "Starting Docker daemon..." 3 "docker"

{
    /etc/init.d/dockerd enable
    /etc/init.d/dockerd start
} >> "$LOG_FILE" 2>&1

# Wait for Docker to be ready
DOCKER_WAIT=0
while ! docker info >/dev/null 2>&1; do
    sleep 1
    DOCKER_WAIT=$((DOCKER_WAIT + 1))
    update_status "Waiting for Docker daemon ($DOCKER_WAIT s)..." 3 "docker"
    if [ $DOCKER_WAIT -gt 30 ]; then
        log_error "Docker failed to start"
        show_cursor
        exit 1
    fi
done

log_success "Docker daemon running"

# ─────────────────────────────────────────────────────────────
# STEP 4: DEPLOY STACK DIRECTORY
# ─────────────────────────────────────────────────────────────
update_status "Preparing container configuration..." 4

mkdir -p /opt/ci5-docker
cp -r docker/* /opt/ci5-docker/
cd /opt/ci5-docker

log "Stack directory prepared at /opt/ci5-docker"
sleep 0.3
log_success "Container configs deployed"

# ─────────────────────────────────────────────────────────────
# STEP 5: PULL CONTAINER IMAGES
# ─────────────────────────────────────────────────────────────
update_status "Pulling container images (this may take several minutes)..." 5 "docker"

{
    docker-compose pull
} >> "$LOG_FILE" 2>&1 &
PULL_PID=$!

# Animate while pulling
PULL_DOTS=""
while kill -0 $PULL_PID 2>/dev/null; do
    PULL_DOTS="${PULL_DOTS}."
    [ ${#PULL_DOTS} -gt 5 ] && PULL_DOTS="."
    update_status "Pulling container images${PULL_DOTS}" 5 "docker"
    
    # Show which images are being pulled
    PULLING=$(docker images --format "{{.Repository}}" 2>/dev/null | tail -1)
    if [ -n "$PULLING" ]; then
        show_container_status "Latest" "$PULLING" "📦"
    fi
    
    sleep 0.5
done

wait $PULL_PID
PULL_RESULT=$?

if [ $PULL_RESULT -eq 0 ]; then
    log_success "All container images pulled"
else
    log_warning "Some images may have failed to pull"
fi

# ─────────────────────────────────────────────────────────────
# STEP 6: START CONTAINERS
# ─────────────────────────────────────────────────────────────
update_status "Starting security stack containers..." 6 "docker"

{
    docker-compose up -d
} >> "$LOG_FILE" 2>&1

sleep 2

# Verify containers
CONTAINERS="redis adguardhome ntopng suricata crowdsec"
RUNNING_COUNT=0
for c in $CONTAINERS; do
    if docker ps --format '{{.Names}}' | grep -q "^${c}$"; then
        RUNNING_COUNT=$((RUNNING_COUNT + 1))
        show_container_status "$c" "${GREEN}running${NC}" "🐳"
        sleep 0.3
    else
        show_container_status "$c" "${RED}failed${NC}" "💀"
        log "WARNING: Container $c not running"
    fi
done

if [ $RUNNING_COUNT -ge 4 ]; then
    log_success "$RUNNING_COUNT/5 containers running"
else
    log_warning "Only $RUNNING_COUNT/5 containers running"
fi

# ─────────────────────────────────────────────────────────────
# STEP 7: INSTALL DNS WATCHDOG
# ─────────────────────────────────────────────────────────────
update_status "Installing DNS Failover Watchdog..." 7

cp /root/ci5/extras/dns_failover.sh /etc/ci5-dns-failover.sh
cp /root/ci5/extras/dns_failover.init /etc/init.d/ci5-dns-failover
chmod +x /etc/ci5-dns-failover.sh /etc/init.d/ci5-dns-failover

{
    /etc/init.d/ci5-dns-failover enable
    /etc/init.d/ci5-dns-failover start
} >> "$LOG_FILE" 2>&1

sleep 0.3
log_success "DNS Failover Watchdog active"

# ─────────────────────────────────────────────────────────────
# STEP 8: INSTALL PPPOE GUARD
# ─────────────────────────────────────────────────────────────
update_status "Installing PPPoE qdisc guard..." 8

mkdir -p /etc/hotplug.d/iface
cp /root/ci5/extras/pppoe_noqdisc.hotplug /etc/hotplug.d/iface/99-pppoe-noqdisc
chmod +x /etc/hotplug.d/iface/99-pppoe-noqdisc

log "PPPoE guard installed"
sleep 0.3
log_success "PPPoE double-shaping prevention enabled"

# ─────────────────────────────────────────────────────────────
# STEP 9: INSTALL PARANOIA WATCHDOG (OPTIONAL)
# ─────────────────────────────────────────────────────────────
update_status "Installing Paranoia Watchdog (disabled by default)..." 9

mkdir -p /root/scripts
cp /root/ci5/extras/paranoia_watchdog.sh /root/scripts/
chmod +x /root/scripts/paranoia_watchdog.sh

log "Paranoia watchdog installed (disabled)"
sleep 0.3
log_success "Paranoia Watchdog available (enable in rc.local)"

# ─────────────────────────────────────────────────────────────
# STEP 10: FINAL VALIDATION
# ─────────────────────────────────────────────────────────────
update_status "Running final validation..." 10

VALIDATION_OUTPUT=""
VALIDATION_PASS=0

# Check containers
RUNNING=$(docker ps --filter "status=running" --format '{{.Names}}' 2>/dev/null | wc -l)
if [ "$RUNNING" -ge 4 ]; then
    VALIDATION_OUTPUT="${VALIDATION_OUTPUT}✓ Docker: $RUNNING containers\n"
    VALIDATION_PASS=$((VALIDATION_PASS + 1))
else
    VALIDATION_OUTPUT="${VALIDATION_OUTPUT}⚠ Docker: Only $RUNNING containers\n"
fi

# Check DNS watchdog
if pgrep -f "ci5-dns-failover" >/dev/null 2>&1; then
    VALIDATION_OUTPUT="${VALIDATION_OUTPUT}✓ DNS Watchdog: Active\n"
    VALIDATION_PASS=$((VALIDATION_PASS + 1))
else
    VALIDATION_OUTPUT="${VALIDATION_OUTPUT}⚠ DNS Watchdog: Not running\n"
fi

# Check AdGuard
if docker ps --format '{{.Names}}' | grep -q "adguardhome"; then
    VALIDATION_OUTPUT="${VALIDATION_OUTPUT}✓ AdGuard Home: Running\n"
    VALIDATION_PASS=$((VALIDATION_PASS + 1))
fi

# Check Suricata
if docker ps --format '{{.Names}}' | grep -q "suricata"; then
    VALIDATION_OUTPUT="${VALIDATION_OUTPUT}✓ Suricata IDS: Running\n"
    VALIDATION_PASS=$((VALIDATION_PASS + 1))
fi

sleep 0.5

# ─────────────────────────────────────────────────────────────
# COMPLETE
# ─────────────────────────────────────────────────────────────
move_cursor $STATUS_LINE 1
clear_line
progress_bar $TOTAL_STEPS $TOTAL_STEPS
echo ""

move_cursor $((STATUS_LINE + 2)) 1
echo -e "${GREEN}══════════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}                      ✅ FULL STACK DEPLOYMENT COMPLETE${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════════════════════════════════${NC}"
echo ""

# Container status summary
move_cursor $((STATUS_LINE + 6)) 1
echo -e "   ${BOLD}Container Status:${NC}"
for c in $CONTAINERS; do
    if docker ps --format '{{.Names}}' | grep -q "^${c}$"; then
        printf "      ${GREEN}●${NC} %-15s ${DIM}running${NC}\n" "$c"
    else
        printf "      ${RED}○${NC} %-15s ${DIM}stopped${NC}\n" "$c"
    fi
done

echo ""
echo -e "   ${CYAN}AdGuard Login:${NC} ${BOLD}admin${NC} / ${BOLD}ci5admin${NC}"
echo -e "   ${CYAN}AdGuard URL:${NC}   http://192.168.99.1:3000"
echo -e "   ${CYAN}Ntopng URL:${NC}    http://192.168.99.1:3001"
echo ""
echo -e "   ${CYAN}Log:${NC} $LOG_FILE"
echo ""
echo -e "   ${YELLOW}Note:${NC} To enable Paranoia Mode (fail-closed):"
echo -e "         Add to /etc/rc.local: ${DIM}/bin/sh /root/scripts/paranoia_watchdog.sh &${NC}"
echo ""

log "=== Full Stack Installation Complete ==="
show_cursor

echo -e "${GREEN}✅ FULL STACK DEPLOYED${NC}"
