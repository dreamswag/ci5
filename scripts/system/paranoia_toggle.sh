#!/bin/sh
# ══════════════════════════════════════════════════════════════════════════════
# Ci5 Paranoia Mode (v7.4-RC-1) - IDS Dead-Man Switch
# ══════════════════════════════════════════════════════════════════════════════
# If Suricata dies, WAN dies. No exceptions.
# ══════════════════════════════════════════════════════════════════════════════

set -e

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────
WATCHDOG_BIN="/usr/bin/ci5-paranoia-watchdog"
INIT_SCRIPT="/etc/init.d/ci5-paranoia"
STATE_FILE="/tmp/ci5_paranoia_state"
PID_FILE="/var/run/ci5-paranoia.pid"

# Ci5 default LAN
CI5_LAN_IP="192.168.99.1"

# Monitored container (change if your IDS container has different name)
IDS_CONTAINER="${IDS_CONTAINER:-suricata}"

# How often to check (seconds)
CHECK_INTERVAL="${CHECK_INTERVAL:-5}"

# How many consecutive failures before killing WAN
FAILURE_THRESHOLD="${FAILURE_THRESHOLD:-3}"

# WAN interface (auto-detected if not set)
WAN_IFACE="${WAN_IFACE:-}"

# ─────────────────────────────────────────────────────────────────────────────
# COLORS & LOGGING
# ─────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'

log_ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
log_err()  { echo -e "${RED}[✗]${NC} $1"; }
log_info() { echo -e "${CYAN}[*]${NC} $1"; }

# ─────────────────────────────────────────────────────────────────────────────
# USAGE
# ─────────────────────────────────────────────────────────────────────────────
usage() {
    cat << 'EOF'
┌──────────────────────────────────────────────────────────────────────────────┐
│  Ci5 PARANOIA MODE - IDS Dead-Man Switch                                     │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  If your IDS container dies, your WAN connection dies with it.               │
│  No traffic escapes unmonitored. Ever.                                       │
│                                                                              │
│  USAGE:                                                                      │
│    paranoia.sh [command]                                                     │
│                                                                              │
│  COMMANDS:                                                                   │
│    enable      Activate paranoia mode (install + start watchdog)             │
│    disable     Deactivate paranoia mode (stop + remove watchdog)             │
│    status      Show current paranoia mode state                              │
│    toggle      Toggle between enabled/disabled (default if no args)          │
│    panic       Manually trigger WAN kill (for testing)                       │
│    restore     Manually restore WAN (emergency recovery)                     │
│                                                                              │
│  ENVIRONMENT:                                                                │
│    IDS_CONTAINER     Container to monitor (default: suricata)                │
│    CHECK_INTERVAL    Seconds between checks (default: 5)                     │
│    FAILURE_THRESHOLD Failures before WAN kill (default: 3)                   │
│    WAN_IFACE         WAN interface (auto-detected)                           │
│                                                                              │
│  EXAMPLES:                                                                   │
│    curl ci5.run/paranoia | sh              # Toggle mode                     │
│    curl ci5.run/paranoia | sh -s enable    # Enable mode                     │
│    curl ci5.run/paranoia | sh -s status    # Check status                    │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
EOF
    exit 0
}

# ─────────────────────────────────────────────────────────────────────────────
# DETECT WAN INTERFACE
# ─────────────────────────────────────────────────────────────────────────────
detect_wan() {
    if [ -n "$WAN_IFACE" ]; then
        echo "$WAN_IFACE"
        return
    fi
    
    # Try UCI first
    local UCI_WAN
    UCI_WAN=$(uci -q get network.wan.device 2>/dev/null || uci -q get network.wan.ifname 2>/dev/null || true)
    if [ -n "$UCI_WAN" ]; then
        echo "$UCI_WAN"
        return
    fi
    
    # Fallback: find interface with default route
    local DEFAULT_IF
    DEFAULT_IF=$(ip route show default 2>/dev/null | grep -oP 'dev \K\S+' | head -1)
    if [ -n "$DEFAULT_IF" ]; then
        echo "$DEFAULT_IF"
        return
    fi
    
    # Last resort
    echo "eth1"
}

# ─────────────────────────────────────────────────────────────────────────────
# INSTALL WATCHDOG BINARY
# ─────────────────────────────────────────────────────────────────────────────
install_watchdog() {
    log_info "Installing watchdog daemon..."
    
    local WAN
    WAN=$(detect_wan)
    
    cat > "$WATCHDOG_BIN" << WATCHDOG
#!/bin/sh
# Ci5 Paranoia Watchdog - Auto-generated, do not edit
# Monitors: $IDS_CONTAINER | Interval: ${CHECK_INTERVAL}s | Threshold: $FAILURE_THRESHOLD

CONTAINER="$IDS_CONTAINER"
INTERVAL=$CHECK_INTERVAL
THRESHOLD=$FAILURE_THRESHOLD
WAN_IF="$WAN"
STATE_FILE="$STATE_FILE"
FAIL_COUNT=0

log() {
    logger -t ci5-paranoia "\$1"
    echo "\$(date '+%Y-%m-%d %H:%M:%S') \$1" >> /tmp/ci5_paranoia.log
}

check_container() {
    if command -v docker >/dev/null 2>&1; then
        docker ps --format '{{.Names}}' 2>/dev/null | grep -qw "\$CONTAINER"
        return \$?
    elif command -v podman >/dev/null 2>&1; then
        podman ps --format '{{.Names}}' 2>/dev/null | grep -qw "\$CONTAINER"
        return \$?
    else
        # No container runtime - assume OK (fallback)
        return 0
    fi
}

kill_wan() {
    log "CRITICAL: IDS container '\$CONTAINER' down for \${THRESHOLD}+ checks - KILLING WAN"
    
    # Method 1: Bring interface down via UCI/netifd
    ifdown wan 2>/dev/null || true
    
    # Method 2: Force link down
    ip link set "\$WAN_IF" down 2>/dev/null || true
    
    # Method 3: Block via nftables (Dedicated Table)
    if command -v nft >/dev/null 2>&1; then
        # Create separate table for clean handling
        nft add table inet ci5_paranoia 2>/dev/null || true
        
        # Hook forward (traffic passing through router)
        nft add chain inet ci5_paranoia block_fwd { type filter hook forward priority 0; policy accept; }
        nft add rule inet ci5_paranoia block_fwd oifname "\$WAN_IF" drop
        
        # Hook output (traffic from router)
        nft add chain inet ci5_paranoia block_out { type filter hook output priority 0; policy accept; }
        nft add rule inet ci5_paranoia block_out oifname "\$WAN_IF" drop
    fi
    
    echo "KILLED" > "\$STATE_FILE"
    log "WAN interface '\$WAN_IF' terminated"
}

restore_wan() {
    log "IDS container '\$CONTAINER' recovered - restoring WAN"
    
    # Remove nftables blocks
    if command -v nft >/dev/null 2>&1; then
        nft delete table inet ci5_paranoia 2>/dev/null || true
    fi
    
    # Bring interface back up
    ip link set "\$WAN_IF" up 2>/dev/null || true
    ifup wan 2>/dev/null || true
    
    echo "ACTIVE" > "\$STATE_FILE"
    log "WAN interface '\$WAN_IF' restored"
}

# Main loop
log "Watchdog started - monitoring '\$CONTAINER' every \${INTERVAL}s"
echo "ACTIVE" > "\$STATE_FILE"

while true; do
    if check_container; then
        # Container is running
        if [ "\$FAIL_COUNT" -gt 0 ]; then
            log "IDS container '\$CONTAINER' recovered after \$FAIL_COUNT failures"
        fi
        FAIL_COUNT=0
        
        # Restore WAN if it was killed and container is back
        if [ -f "\$STATE_FILE" ] && grep -q "KILLED" "\$STATE_FILE" 2>/dev/null; then
            restore_wan
        fi
    else
        # Container not running
        FAIL_COUNT=\$((FAIL_COUNT + 1))
        log "WARNING: IDS container '\$CONTAINER' not running (failure \$FAIL_COUNT/\$THRESHOLD)"
        
        if [ "\$FAIL_COUNT" -ge "\$THRESHOLD" ]; then
            # Only kill if not already killed
            if ! grep -q "KILLED" "\$STATE_FILE" 2>/dev/null; then
                kill_wan
            fi
        fi
    fi
    
    sleep "\$INTERVAL"
done
WATCHDOG

    chmod +x "$WATCHDOG_BIN"
    log_ok "Watchdog installed: $WATCHDOG_BIN"
}

# ─────────────────────────────────────────────────────────────────────────────
# INSTALL PROCD INIT SCRIPT
# ─────────────────────────────────────────────────────────────────────────────
install_init() {
    log_info "Installing init script..."
    
    cat > "$INIT_SCRIPT" << 'INITSCRIPT'
#!/bin/sh /etc/rc.common
# Ci5 Paranoia Mode - procd init script

START=99
STOP=10
USE_PROCD=1

WATCHDOG_BIN="/usr/bin/ci5-paranoia-watchdog"
PID_FILE="/var/run/ci5-paranoia.pid"

start_service() {
    logger -t ci5-paranoia "Starting paranoia mode watchdog"
    
    procd_open_instance
    procd_set_param command "$WATCHDOG_BIN"
    procd_set_param respawn 3600 5 5
    procd_set_param pidfile "$PID_FILE"
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

stop_service() {
    logger -t ci5-paranoia "Stopping paranoia mode watchdog"
    
    # Clean up nftables rules
    if command -v nft >/dev/null 2>&1; then
        nft delete table inet ci5_paranoia 2>/dev/null || true
    fi
    
    # Ensure WAN is up
    local WAN_IF
    WAN_IF=$(uci -q get network.wan.device 2>/dev/null || uci -q get network.wan.ifname 2>/dev/null || echo "eth1")
    
    ip link set "$WAN_IF" up 2>/dev/null || true
    ifup wan 2>/dev/null || true
    
    rm -f /tmp/ci5_paranoia_state
}

service_triggers() {
    procd_add_reload_trigger "ci5-paranoia"
}
INITSCRIPT

    chmod +x "$INIT_SCRIPT"
    log_ok "Init script installed: $INIT_SCRIPT"
}

# ─────────────────────────────────────────────────────────────────────────────
# ENABLE PARANOIA MODE
# ─────────────────────────────────────────────────────────────────────────────
enable_paranoia() {
    echo ""
    echo -e "${MAGENTA}┌──────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${MAGENTA}│${NC}  ${RED}⚠  ENABLING PARANOIA MODE${NC}                                      ${MAGENTA}│${NC}"
    echo -e "${MAGENTA}├──────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "${MAGENTA}│${NC}  If container '${CYAN}$IDS_CONTAINER${NC}' stops, WAN will be ${RED}TERMINATED${NC}.      ${MAGENTA}│${NC}"
    echo -e "${MAGENTA}│${NC}  No internet traffic will flow until IDS is restored.         ${MAGENTA}│${NC}"
    echo -e "${MAGENTA}└──────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    
    # Check if container exists
    if command -v docker >/dev/null 2>&1; then
        if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qw "$IDS_CONTAINER"; then
            log_warn "Container '$IDS_CONTAINER' not found!"
            echo -n "    Continue anyway? [y/N]: "
            read -r CONTINUE
            [ "$CONTINUE" != "y" ] && [ "$CONTINUE" != "Y" ] && exit 1
        fi
    fi
    
    install_watchdog
    install_init
    
    # Enable and start
    "$INIT_SCRIPT" enable
    "$INIT_SCRIPT" start
    
    echo ""
    log_ok "Paranoia mode ${GREEN}ENABLED${NC}"
    echo ""
    echo "    Monitoring:  $IDS_CONTAINER"
    echo "    Interval:    ${CHECK_INTERVAL}s"
    echo "    Threshold:   $FAILURE_THRESHOLD failures"
    echo "    WAN:         $(detect_wan)"
    echo ""
    echo "    Logs:        tail -f /tmp/ci5_paranoia.log"
    echo "    Disable:     $0 disable"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# DISABLE PARANOIA MODE
# ─────────────────────────────────────────────────────────────────────────────
disable_paranoia() {
    log_info "Disabling paranoia mode..."
    
    # Stop and disable service
    if [ -x "$INIT_SCRIPT" ]; then
        "$INIT_SCRIPT" stop 2>/dev/null || true
        "$INIT_SCRIPT" disable 2>/dev/null || true
    fi
    
    # Kill any remaining watchdog processes
    pkill -f "ci5-paranoia-watchdog" 2>/dev/null || true
    
    # Remove files
    rm -f "$WATCHDOG_BIN" 2>/dev/null || true
    rm -f "$INIT_SCRIPT" 2>/dev/null || true
    rm -f "$STATE_FILE" 2>/dev/null || true
    rm -f "$PID_FILE" 2>/dev/null || true
    rm -f /tmp/ci5_paranoia.log 2>/dev/null || true
    
    # Ensure WAN is restored
    local WAN
    WAN=$(detect_wan)
    
    if command -v nft >/dev/null 2>&1; then
        nft delete table inet ci5_paranoia 2>/dev/null || true
    fi
    
    ip link set "$WAN" up 2>/dev/null || true
    ifup wan 2>/dev/null || true
    
    echo ""
    log_ok "Paranoia mode ${YELLOW}DISABLED${NC}"
    echo "    WAN interface restored"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# STATUS
# ─────────────────────────────────────────────────────────────────────────────
show_status() {
    echo ""
    echo "┌──────────────────────────────────────────────────────────────────┐"
    echo "│  Ci5 Paranoia Mode Status                                       │"
    echo "└──────────────────────────────────────────────────────────────────┘"
    echo ""
    
    # Check if installed
    if [ ! -x "$WATCHDOG_BIN" ]; then
        echo -e "    Mode:        ${YELLOW}NOT INSTALLED${NC}"
        echo ""
        echo "    Enable with: $0 enable"
        return 0
    fi
    
    # Check if running
    if pgrep -f "ci5-paranoia-watchdog" >/dev/null 2>&1; then
        echo -e "    Mode:        ${GREEN}ACTIVE${NC}"
    else
        echo -e "    Mode:        ${RED}STOPPED${NC} (installed but not running)"
    fi
    
    # Show state
    if [ -f "$STATE_FILE" ]; then
        local STATE
        STATE=$(cat "$STATE_FILE" 2>/dev/null || echo "UNKNOWN")
        if [ "$STATE" = "KILLED" ]; then
            echo -e "    WAN Status:  ${RED}KILLED${NC} (IDS was down)"
        else
            echo -e "    WAN Status:  ${GREEN}ACTIVE${NC}"
        fi
    fi
    
    # Show container status
    echo -n "    IDS Status:  "
    if command -v docker >/dev/null 2>&1; then
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -qw "$IDS_CONTAINER"; then
            echo -e "${GREEN}RUNNING${NC} ($IDS_CONTAINER)"
        else
            echo -e "${RED}NOT RUNNING${NC} ($IDS_CONTAINER)"
        fi
    else
        echo -e "${YELLOW}UNKNOWN${NC} (docker not found)"
    fi
    
    # Show config
    echo ""
    echo "    Configuration:"
    echo "    ├── Container:  $IDS_CONTAINER"
    echo "    ├── Interval:   ${CHECK_INTERVAL}s"
    echo "    ├── Threshold:  $FAILURE_THRESHOLD failures"
    echo "    └── WAN:        $(detect_wan)"
    
    # Show recent log
    if [ -f /tmp/ci5_paranoia.log ]; then
        echo ""
        echo "    Recent Log:"
        tail -3 /tmp/ci5_paranoia.log 2>/dev/null | sed 's/^/    │ /'
    fi
    
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# TOGGLE
# ─────────────────────────────────────────────────────────────────────────────
toggle_paranoia() {
    if [ -x "$WATCHDOG_BIN" ] && pgrep -f "ci5-paranoia-watchdog" >/dev/null 2>&1; then
        disable_paranoia
    else
        enable_paranoia
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# MANUAL PANIC (for testing)
# ─────────────────────────────────────────────────────────────────────────────
manual_panic() {
    log_warn "MANUAL PANIC - Killing WAN interface..."
    
    local WAN
    WAN=$(detect_wan)
    
    ifdown wan 2>/dev/null || true
    ip link set "$WAN" down 2>/dev/null || true
    
    if command -v nft >/dev/null 2>&1; then
        nft add table inet ci5_paranoia 2>/dev/null || true
        nft add chain inet ci5_paranoia block_fwd { type filter hook forward priority 0; policy accept; }
        nft add rule inet ci5_paranoia block_fwd oifname "$WAN" drop
        nft add chain inet ci5_paranoia block_out { type filter hook output priority 0; policy accept; }
        nft add rule inet ci5_paranoia block_out oifname "$WAN" drop
    fi
    
    echo "KILLED" > "$STATE_FILE"
    
    log_err "WAN TERMINATED"
    echo ""
    echo "    Restore with: $0 restore"
}

# ─────────────────────────────────────────────────────────────────────────────
# MANUAL RESTORE
# ─────────────────────────────────────────────────────────────────────────────
manual_restore() {
    log_info "Restoring WAN interface..."
    
    local WAN
    WAN=$(detect_wan)
    
    if command -v nft >/dev/null 2>&1; then
        nft delete table inet ci5_paranoia 2>/dev/null || true
    fi
    
    ip link set "$WAN" up 2>/dev/null || true
    ifup wan 2>/dev/null || true
    
    echo "ACTIVE" > "$STATE_FILE"
    
    log_ok "WAN RESTORED"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
main() {
    local CMD="${1:-toggle}"
    
    case "$CMD" in
        enable|on|start)
            enable_paranoia
            ;;
        disable|off|stop)
            disable_paranoia
            ;;
        status|check)
            show_status
            ;;
        toggle)
            toggle_paranoia
            ;;
        panic|kill)
            manual_panic
            ;;
        restore|recover)
            manual_restore
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            log_err "Unknown command: $CMD"
            usage
            ;;
    esac
}

main "$@"