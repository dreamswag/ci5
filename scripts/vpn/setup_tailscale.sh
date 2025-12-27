#!/bin/sh
# 🔗 Ci5 Tailscale Setup (v7.5-RELEASE)
# Connects your router to Tailscale mesh for secure remote access
# Route: /tailscale | Alias: /ts, /mesh
# Usage: curl ci5.run/tailscale | sh
#        curl ci5.run/tailscale | sh -s -- --remove
#        curl ci5.run/tailscale | sh -s -- --status
#        curl ci5.run/tailscale | sh -s -- --exit-node

set -e

# ═══════════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════════
CI5_BASE="${CI5_BASE:-/opt/ci5}"
TAILSCALE_STATE_DIR="/var/lib/tailscale"
TAILSCALE_SOCKET="/var/run/tailscale/tailscaled.sock"
LOG_PREFIX="[ci5-tailscale]"

# ═══════════════════════════════════════════════════════════════════
# COLORS & LOGGING
# ═══════════════════════════════════════════════════════════════════
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
log_err()  { echo -e "${RED}[✗]${NC} $1"; }
log_info() { echo -e "${CYAN}[*]${NC} $1"; }

# ═══════════════════════════════════════════════════════════════════
# HELP
# ═══════════════════════════════════════════════════════════════════
show_help() {
    echo ""
    echo "Ci5 Tailscale Setup"
    echo "==================="
    echo ""
    echo "Usage: curl ci5.run/tailscale | sh [-- OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --remove       Remove Tailscale completely"
    echo "  --status       Show current Tailscale status"
    echo "  --exit-node    Configure as exit node"
    echo "  --subnet       Advertise local subnets"
    echo "  --docker       Use Docker-based Tailscale (Full Stack)"
    echo "  --native       Use native Tailscale binary (Lite Stack)"
    echo "  --authkey KEY  Use auth key for headless setup"
    echo "  --help         Show this help"
    echo ""
    echo "Examples:"
    echo "  # Interactive setup"
    echo "  curl ci5.run/tailscale | sh"
    echo ""
    echo "  # Headless with auth key"
    echo "  curl ci5.run/tailscale | sh -s -- --authkey tskey-xxx"
    echo ""
    echo "  # Configure as exit node"
    echo "  curl ci5.run/tailscale | sh -s -- --exit-node"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════
# DETECTION FUNCTIONS
# ═══════════════════════════════════════════════════════════════════
is_openwrt() {
    [ -f /etc/openwrt_release ]
}

has_docker() {
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

is_tailscale_installed() {
    command -v tailscale >/dev/null 2>&1 || \
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^tailscale$"
}

is_tailscale_running() {
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^tailscale$"; then
        return 0
    fi
    if pgrep -x tailscaled >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

detect_stack_mode() {
    if has_docker && [ -f "${CI5_BASE}/docker/docker-compose.yml" ]; then
        echo "full"
    else
        echo "lite"
    fi
}

# ═══════════════════════════════════════════════════════════════════
# PREFLIGHT CHECKS
# ═══════════════════════════════════════════════════════════════════
preflight_check() {
    log_info "Running preflight checks..."
    
    # Check for root
    if [ "$(id -u)" -ne 0 ]; then
        log_err "This script must be run as root"
        exit 1
    fi
    
    # Check internet connectivity
    if ! ping -c 1 -W 5 1.1.1.1 >/dev/null 2>&1; then
        log_err "No internet connectivity"
        exit 1
    fi
    
    # Detect platform
    if is_openwrt; then
        log_ok "OpenWrt detected"
    else
        log_warn "Non-OpenWrt system - using generic Linux mode"
    fi
    
    # Detect stack mode
    STACK_MODE=$(detect_stack_mode)
    log_info "Stack mode: $STACK_MODE"
}

# ═══════════════════════════════════════════════════════════════════
# NATIVE INSTALLATION (Lite Stack)
# ═══════════════════════════════════════════════════════════════════
install_native() {
    log_info "Installing Tailscale (native binary)..."
    
    if is_openwrt; then
        # OpenWrt package installation
        opkg update
        opkg install tailscale
        
        # Enable and start service
        /etc/init.d/tailscale enable
        /etc/init.d/tailscale start
        
        # Wait for daemon
        sleep 3
        
        log_ok "Tailscale daemon started"
    else
        # Generic Linux - use official install script
        curl -fsSL https://tailscale.com/install.sh | sh
        
        systemctl enable tailscaled
        systemctl start tailscaled
        
        sleep 3
        log_ok "Tailscale daemon started"
    fi
}

# ═══════════════════════════════════════════════════════════════════
# DOCKER INSTALLATION (Full Stack)
# ═══════════════════════════════════════════════════════════════════
install_docker() {
    log_info "Installing Tailscale (Docker sidecar)..."
    
    mkdir -p "$TAILSCALE_STATE_DIR"
    
    # Create Docker compose entry
    cat > /tmp/tailscale-compose.yml << 'COMPOSE'
version: '3.8'
services:
  tailscale:
    image: tailscale/tailscale:latest
    container_name: tailscale
    hostname: ci5-router
    restart: unless-stopped
    network_mode: host
    cap_add:
      - NET_ADMIN
      - NET_RAW
      - SYS_MODULE
    volumes:
      - /var/lib/tailscale:/var/lib/tailscale
      - /dev/net/tun:/dev/net/tun
    environment:
      - TS_STATE_DIR=/var/lib/tailscale
      - TS_SOCKET=/var/run/tailscale/tailscaled.sock
      - TS_USERSPACE=false
COMPOSE

    # Pull and start
    docker compose -f /tmp/tailscale-compose.yml pull
    docker compose -f /tmp/tailscale-compose.yml up -d
    
    sleep 5
    
    if docker ps | grep -q tailscale; then
        log_ok "Tailscale container running"
    else
        log_err "Failed to start Tailscale container"
        docker logs tailscale 2>&1 | tail -20
        exit 1
    fi
}

# ═══════════════════════════════════════════════════════════════════
# AUTHENTICATION
# ═══════════════════════════════════════════════════════════════════
authenticate_tailscale() {
    local auth_key="$1"
    local extra_args="$2"
    
    log_info "Authenticating with Tailscale..."
    
    # Build tailscale up command
    TS_CMD="tailscale"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^tailscale$"; then
        TS_CMD="docker exec tailscale tailscale"
    fi
    
    if [ -n "$auth_key" ]; then
        # Headless auth with key
        log_info "Using auth key for headless setup..."
        $TS_CMD up --authkey="$auth_key" $extra_args
        
        if [ $? -eq 0 ]; then
            log_ok "Authenticated successfully"
        else
            log_err "Authentication failed"
            exit 1
        fi
    else
        # Interactive auth
        echo ""
        echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║  🔗 TAILSCALE AUTHENTICATION REQUIRED                            ║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        
        # Start auth flow
        $TS_CMD up $extra_args
        
        if [ $? -eq 0 ]; then
            log_ok "Authenticated successfully"
        else
            log_err "Authentication failed or cancelled"
            exit 1
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════════
# CONFIGURE AS EXIT NODE
# ═══════════════════════════════════════════════════════════════════
configure_exit_node() {
    log_info "Configuring as exit node..."
    
    TS_CMD="tailscale"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^tailscale$"; then
        TS_CMD="docker exec tailscale tailscale"
    fi
    
    # Enable IP forwarding
    sysctl -w net.ipv4.ip_forward=1
    sysctl -w net.ipv6.conf.all.forwarding=1
    
    # Persist
    if is_openwrt; then
        uci set network.globals.ula_prefix="$(uci get network.globals.ula_prefix 2>/dev/null || echo 'fd00::/48')"
        uci commit network
    else
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
    fi
    
    # Advertise as exit node
    $TS_CMD up --advertise-exit-node --reset
    
    echo ""
    log_ok "Exit node configured"
    echo ""
    echo -e "${YELLOW}Note: You must approve this exit node in the Tailscale admin console:${NC}"
    echo "https://login.tailscale.com/admin/machines"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════
# CONFIGURE SUBNET ROUTING
# ═══════════════════════════════════════════════════════════════════
configure_subnet_routing() {
    log_info "Configuring subnet routing..."
    
    TS_CMD="tailscale"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^tailscale$"; then
        TS_CMD="docker exec tailscale tailscale"
    fi
    
    # Detect local subnets
    SUBNETS=""
    
    # Add common Ci5 subnets
    SUBNETS="192.168.99.0/24"  # LAN
    SUBNETS="$SUBNETS,10.10.10.0/24"  # VLAN 10 (Trusted)
    SUBNETS="$SUBNETS,10.10.20.0/24"  # VLAN 20 (Admin)
    SUBNETS="$SUBNETS,10.10.30.0/24"  # VLAN 30 (IoT)
    SUBNETS="$SUBNETS,10.10.40.0/24"  # VLAN 40 (Guest)
    
    log_info "Advertising subnets: $SUBNETS"
    
    # Enable IP forwarding
    sysctl -w net.ipv4.ip_forward=1
    
    # Advertise subnets
    $TS_CMD up --advertise-routes="$SUBNETS" --reset
    
    echo ""
    log_ok "Subnet routing configured"
    echo ""
    echo -e "${YELLOW}Note: You must approve these routes in the Tailscale admin console:${NC}"
    echo "https://login.tailscale.com/admin/machines"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════
# FIREWALL CONFIGURATION
# ═══════════════════════════════════════════════════════════════════
configure_firewall() {
    log_info "Configuring firewall for Tailscale..."
    
    if is_openwrt; then
        # Create tailscale zone
        uci -q delete firewall.tailscale
        uci set firewall.tailscale=zone
        uci set firewall.tailscale.name='tailscale'
        uci set firewall.tailscale.input='ACCEPT'
        uci set firewall.tailscale.output='ACCEPT'
        uci set firewall.tailscale.forward='ACCEPT'
        uci set firewall.tailscale.masq='1'
        uci add_list firewall.tailscale.network='tailscale'
        
        # Create interface for tailscale
        uci -q delete network.tailscale
        uci set network.tailscale=interface
        uci set network.tailscale.proto='none'
        uci set network.tailscale.device='tailscale0'
        
        # Allow tailscale -> lan forwarding
        uci add firewall forwarding
        uci set firewall.@forwarding[-1].src='tailscale'
        uci set firewall.@forwarding[-1].dest='lan'
        
        # Allow lan -> tailscale forwarding
        uci add firewall forwarding
        uci set firewall.@forwarding[-1].src='lan'
        uci set firewall.@forwarding[-1].dest='tailscale'
        
        uci commit firewall
        uci commit network
        
        /etc/init.d/network reload
        /etc/init.d/firewall reload
        
        log_ok "OpenWrt firewall configured"
    else
        # Generic iptables
        iptables -I INPUT -i tailscale0 -j ACCEPT
        iptables -I FORWARD -i tailscale0 -j ACCEPT
        iptables -I FORWARD -o tailscale0 -j ACCEPT
        iptables -t nat -I POSTROUTING -o tailscale0 -j MASQUERADE
        
        log_ok "iptables rules added"
    fi
}

# ═══════════════════════════════════════════════════════════════════
# STATUS
# ═══════════════════════════════════════════════════════════════════
show_status() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                  TAILSCALE STATUS                                ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    TS_CMD="tailscale"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^tailscale$"; then
        TS_CMD="docker exec tailscale tailscale"
        log_info "Mode: Docker container"
    elif pgrep -x tailscaled >/dev/null 2>&1; then
        log_info "Mode: Native daemon"
    else
        log_err "Tailscale is not running"
        return 1
    fi
    
    echo ""
    echo "=== Connection Status ==="
    $TS_CMD status
    
    echo ""
    echo "=== IP Info ==="
    $TS_CMD ip -4
    $TS_CMD ip -6 2>/dev/null || true
    
    echo ""
    echo "=== Network Info ==="
    $TS_CMD netcheck 2>/dev/null | head -20 || true
    
    echo ""
}

# ═══════════════════════════════════════════════════════════════════
# REMOVAL
# ═══════════════════════════════════════════════════════════════════
remove_tailscale() {
    log_info "Removing Tailscale..."
    
    # Docker removal
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^tailscale$"; then
        log_info "Stopping Docker container..."
        docker stop tailscale 2>/dev/null
        docker rm tailscale 2>/dev/null
        log_ok "Docker container removed"
    fi
    
    # Native removal
    if is_openwrt; then
        if opkg list-installed | grep -q tailscale; then
            /etc/init.d/tailscale stop 2>/dev/null
            /etc/init.d/tailscale disable 2>/dev/null
            opkg remove tailscale tailscaled 2>/dev/null
            log_ok "OpenWrt package removed"
        fi
    else
        if command -v tailscale >/dev/null 2>&1; then
            systemctl stop tailscaled 2>/dev/null
            systemctl disable tailscaled 2>/dev/null
            # Note: Package removal varies by distro
            log_warn "Run 'apt remove tailscale' or equivalent to complete removal"
        fi
    fi
    
    # Remove firewall rules
    if is_openwrt; then
        uci -q delete firewall.tailscale
        uci -q delete network.tailscale
        uci commit firewall
        uci commit network
        /etc/init.d/firewall reload 2>/dev/null
    fi
    
    # Remove state (optional)
    echo ""
    echo -n "Delete Tailscale state/identity? [y/N]: "
    read -r DEL_STATE
    if [ "$DEL_STATE" = "y" ] || [ "$DEL_STATE" = "Y" ]; then
        rm -rf "$TAILSCALE_STATE_DIR"
        log_ok "State directory removed"
    fi
    
    echo ""
    log_ok "Tailscale removed"
}

# ═══════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════
main() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          🔗 Ci5 Tailscale Setup (v7.5-RELEASE)                   ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Parse arguments
    MODE="install"
    USE_DOCKER=""
    AUTH_KEY=""
    EXTRA_ARGS=""
    
    while [ $# -gt 0 ]; do
        case "$1" in
            --help|-h)
                show_help
                exit 0
                ;;
            --remove|--uninstall)
                MODE="remove"
                ;;
            --status)
                MODE="status"
                ;;
            --exit-node)
                MODE="exit-node"
                ;;
            --subnet|--subnets)
                MODE="subnet"
                ;;
            --docker)
                USE_DOCKER="yes"
                ;;
            --native)
                USE_DOCKER="no"
                ;;
            --authkey)
                shift
                AUTH_KEY="$1"
                ;;
            --accept-routes)
                EXTRA_ARGS="$EXTRA_ARGS --accept-routes"
                ;;
            --accept-dns)
                EXTRA_ARGS="$EXTRA_ARGS --accept-dns=false"
                ;;
            *)
                log_warn "Unknown option: $1"
                ;;
        esac
        shift
    done
    
    # Execute based on mode
    case "$MODE" in
        remove)
            remove_tailscale
            exit 0
            ;;
        status)
            show_status
            exit $?
            ;;
        exit-node)
            if ! is_tailscale_running; then
                log_err "Tailscale is not running. Install first."
                exit 1
            fi
            configure_exit_node
            exit 0
            ;;
        subnet)
            if ! is_tailscale_running; then
                log_err "Tailscale is not running. Install first."
                exit 1
            fi
            configure_subnet_routing
            exit 0
            ;;
    esac
    
    # Preflight
    preflight_check
    
    # Check if already installed
    if is_tailscale_running; then
        log_warn "Tailscale is already running"
        echo ""
        echo "Options:"
        echo "  --status      Show current status"
        echo "  --exit-node   Configure as exit node"
        echo "  --subnet      Advertise local subnets"
        echo "  --remove      Remove Tailscale"
        echo ""
        exit 0
    fi
    
    # Determine installation method
    if [ -z "$USE_DOCKER" ]; then
        # Auto-detect
        STACK_MODE=$(detect_stack_mode)
        if [ "$STACK_MODE" = "full" ]; then
            USE_DOCKER="yes"
        else
            USE_DOCKER="no"
        fi
    fi
    
    # Install
    if [ "$USE_DOCKER" = "yes" ]; then
        install_docker
    else
        install_native
    fi
    
    # Configure firewall
    configure_firewall
    
    # Authenticate
    authenticate_tailscale "$AUTH_KEY" "$EXTRA_ARGS"
    
    # Show status
    echo ""
    show_status
    
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✅ TAILSCALE SETUP COMPLETE                                     ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Next steps:"
    echo "  • Access this router remotely via Tailscale IP"
    echo "  • Configure as exit node: curl ci5.run/tailscale | sh -s -- --exit-node"
    echo "  • Advertise subnets: curl ci5.run/tailscale | sh -s -- --subnet"
    echo ""
}

main "$@"