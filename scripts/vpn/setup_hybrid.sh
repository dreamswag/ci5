#!/bin/sh
# ═══════════════════════════════════════════════════════════════════════════
# ci5.run/hybrid — Split-Horizon VPN (Mullvad + Tailscale Coexistence)
# Version: 1.0-PHOENIX
#
# Configures policy-based routing to allow:
#   INCOMING: Tailscale (remote access to your network)
#   OUTGOING: Mullvad WireGuard (privacy/anonymity)
#
# The Problem:
#   Mullvad's WireGuard config uses AllowedIPs = 0.0.0.0/0, which captures
#   ALL traffic including Tailscale's coordination traffic, breaking it.
#
# The Solution:
#   1. Use fwmark-based policy routing
#   2. Tailscale marks its packets with 0x80000
#   3. Create routing rules so Tailscale traffic bypasses Mullvad table
#   4. All other traffic goes through Mullvad
#
# Prerequisites:
#   - Mullvad account and WireGuard config
#   - Tailscale account (free tier works)
#
# Usage:
#   curl -sL ci5.run | sh -s hybrid              # Interactive setup
#   curl -sL ci5.run | sh -s hybrid --status     # Check current status
#   curl -sL ci5.run | sh -s hybrid --disable    # Disable hybrid mode
# ═══════════════════════════════════════════════════════════════════════════

set -e

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

CI5_DIR="/etc/ci5"
HYBRID_DIR="$CI5_DIR/hybrid"
HYBRID_CONF="$HYBRID_DIR/config"

# Routing tables (defined in /etc/iproute2/rt_tables)
MULLVAD_TABLE="51820"
TAILSCALE_TABLE="52"

# Tailscale's fwmark (hardcoded in tailscaled)
TS_FWMARK="0x80000"
TS_FWMASK="0xff0000"

# Colors
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'
B='\033[1m'; N='\033[0m'; M='\033[0;35m'; D='\033[0;90m'

info() { printf "${G}[✓]${N} %s\n" "$1"; }
warn() { printf "${Y}[!]${N} %s\n" "$1"; }
err()  { printf "${R}[✗]${N} %s\n" "$1"; exit 1; }
step() { printf "\n${C}═══ %s ═══${N}\n\n" "$1"; }

# ─────────────────────────────────────────────────────────────────────────────
# ARGUMENT PARSING
# ─────────────────────────────────────────────────────────────────────────────

ACTION="setup"

for arg in "$@"; do
    case "$arg" in
        --status|-s)     ACTION="status" ;;
        --disable|-d)    ACTION="disable" ;;
        --help|-h)
            cat << 'HELP'
CI5 Hybrid VPN (Split-Horizon Mode)

Usage: curl -sL ci5.run | sh -s hybrid [OPTIONS]

Options:
  --status, -s     Check current hybrid VPN status
  --disable, -d    Disable hybrid mode and restore normal routing
  --help, -h       Show this help

How It Works:
  ┌─────────────────────────────────────────────────────────────────┐
  │                      YOUR RASPBERRY PI                         │
  │                                                                 │
  │  ┌─────────────┐    ┌────────────────────────────────────────┐ │
  │  │  Tailscale  │◄───│  INCOMING: Remote access via Tailscale │ │
  │  │  Interface  │    │  (Your laptop, phone connecting to Pi) │ │
  │  └─────────────┘    └────────────────────────────────────────┘ │
  │         │                                                      │
  │         │ Tailscale traffic uses fwmark 0x80000               │
  │         │ → Routed via physical interface (bypasses Mullvad)  │
  │         │                                                      │
  │  ┌─────────────┐    ┌────────────────────────────────────────┐ │
  │  │   Mullvad   │───►│  OUTGOING: All other traffic           │ │
  │  │  WireGuard  │    │  (Web browsing, downloads, etc.)       │ │
  │  └─────────────┘    └────────────────────────────────────────┘ │
  └─────────────────────────────────────────────────────────────────┘

Requirements:
  1. Run 'ci5 mullvad' first to set up Mullvad WireGuard
  2. Run 'ci5 tailscale' first to set up Tailscale
  3. Then run 'ci5 hybrid' to enable coexistence
HELP
            exit 0
            ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────

[ "$(id -u)" -eq 0 ] || err "Must run as root"

check_dependencies() {
    command -v wg >/dev/null 2>&1 || err "WireGuard not installed. Run 'ci5 mullvad' first."
    command -v tailscale >/dev/null 2>&1 || err "Tailscale not installed. Run 'ci5 tailscale' first."
    command -v ip >/dev/null 2>&1 || err "iproute2 not installed"
}

get_default_interface() {
    ip route show default | awk '/default/ {print $5}' | head -n1
}

get_default_gateway() {
    ip route show default | awk '/default/ {print $3}' | head -n1
}

# ─────────────────────────────────────────────────────────────────────────────
# STATUS CHECK
# ─────────────────────────────────────────────────────────────────────────────

show_status() {
    step "HYBRID VPN STATUS"
    
    # Check Mullvad
    echo "Mullvad WireGuard:"
    if ip link show mullvad >/dev/null 2>&1; then
        local mullvad_ip=$(ip -4 addr show mullvad 2>/dev/null | awk '/inet/ {print $2}')
        printf "  ${G}●${N} Interface: mullvad (%s)\n" "${mullvad_ip:-no IP}"
    else
        printf "  ${R}●${N} Interface: not found\n"
    fi
    
    if [ -f "/etc/wireguard/mullvad.conf" ]; then
        printf "  ${G}●${N} Config: /etc/wireguard/mullvad.conf\n"
    else
        printf "  ${R}●${N} Config: not found\n"
    fi
    
    echo ""
    
    # Check Tailscale
    echo "Tailscale:"
    if ip link show tailscale0 >/dev/null 2>&1; then
        local ts_ip=$(ip -4 addr show tailscale0 2>/dev/null | awk '/inet/ {print $2}')
        printf "  ${G}●${N} Interface: tailscale0 (%s)\n" "${ts_ip:-no IP}"
    else
        printf "  ${R}●${N} Interface: not found\n"
    fi
    
    local ts_status=$(tailscale status --json 2>/dev/null | grep -o '"BackendState":"[^"]*"' | cut -d'"' -f4)
    if [ "$ts_status" = "Running" ]; then
        printf "  ${G}●${N} Status: Running\n"
    else
        printf "  ${Y}●${N} Status: %s\n" "${ts_status:-Unknown}"
    fi
    
    echo ""
    
    # Check routing rules
    echo "Policy Routing:"
    if ip rule show | grep -q "fwmark $TS_FWMARK"; then
        printf "  ${G}●${N} Tailscale bypass rule: active\n"
    else
        printf "  ${R}●${N} Tailscale bypass rule: not found\n"
    fi
    
    if ip rule show | grep -q "table $MULLVAD_TABLE"; then
        printf "  ${G}●${N} Mullvad routing table: active\n"
    else
        printf "  ${Y}●${N} Mullvad routing table: not configured\n"
    fi
    
    echo ""
    
    # Check effective routing
    echo "Effective Routes:"
    printf "  Default: %s via %s\n" "$(get_default_interface)" "$(get_default_gateway)"
    
    # Test connectivity
    echo ""
    echo "Connectivity Test:"
    if curl -s --max-time 5 https://am.i.mullvad.net/connected 2>/dev/null | grep -q "You are connected"; then
        printf "  ${G}●${N} Mullvad: Connected\n"
    else
        printf "  ${Y}●${N} Mullvad: Not connected or unreachable\n"
    fi
    
    if tailscale ping --timeout=3s "$(tailscale status --json 2>/dev/null | grep -o '"Self":{"ID":"[^"]*' | head -1)" >/dev/null 2>&1; then
        printf "  ${G}●${N} Tailscale: Reachable\n"
    else
        printf "  ${Y}●${N} Tailscale: Cannot verify (may still work)\n"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# ROUTING TABLE SETUP
# ─────────────────────────────────────────────────────────────────────────────

setup_routing_tables() {
    # Ensure routing tables are defined
    if ! grep -q "^${MULLVAD_TABLE}" /etc/iproute2/rt_tables 2>/dev/null; then
        echo "${MULLVAD_TABLE} mullvad" >> /etc/iproute2/rt_tables
        info "Added 'mullvad' routing table (${MULLVAD_TABLE})"
    fi
    
    if ! grep -q "^${TAILSCALE_TABLE}" /etc/iproute2/rt_tables 2>/dev/null; then
        echo "${TAILSCALE_TABLE} tailscale" >> /etc/iproute2/rt_tables
        info "Added 'tailscale' routing table (${TAILSCALE_TABLE})"
    fi
}

setup_policy_routing() {
    local default_if=$(get_default_interface)
    local default_gw=$(get_default_gateway)
    
    if [ -z "$default_if" ] || [ -z "$default_gw" ]; then
        err "Could not determine default interface/gateway"
    fi
    
    info "Physical interface: $default_if (gateway: $default_gw)"
    
    # Rule 1: Tailscale-marked packets use main table (bypass VPN)
    # Priority 5000 - before Mullvad rules
    if ! ip rule show | grep -q "fwmark $TS_FWMARK.*lookup main"; then
        ip rule add fwmark "$TS_FWMARK" table main priority 5000
        info "Added Tailscale bypass rule (fwmark → main table)"
    fi
    
    # Rule 2: Packets from Tailscale CGNAT range use tailscale table
    # This ensures responses to Tailscale connections go back correctly
    if ! ip rule show | grep -q "from 100.64.0.0/10"; then
        ip rule add from 100.64.0.0/10 table $TAILSCALE_TABLE priority 5001
        info "Added Tailscale source routing rule"
    fi
    
    # Populate tailscale table with default route via physical interface
    ip route replace default via "$default_gw" dev "$default_if" table $TAILSCALE_TABLE 2>/dev/null || true
    
    # Rule 3: Ensure Tailscale coordination servers are reachable
    # These are the DERP servers and coordination plane
    # We add them to main table explicitly
    local ts_coord_ips="
        controlplane.tailscale.com
        login.tailscale.com
    "
    
    for host in $ts_coord_ips; do
        local ip=$(getent hosts "$host" 2>/dev/null | awk '{print $1}' | head -1)
        if [ -n "$ip" ]; then
            ip route replace "$ip" via "$default_gw" dev "$default_if" 2>/dev/null || true
        fi
    done
    
    info "Policy routing configured"
}

# ─────────────────────────────────────────────────────────────────────────────
# MULLVAD CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

check_mullvad_config() {
    if [ ! -f "/etc/wireguard/mullvad.conf" ]; then
        err "Mullvad config not found. Run 'curl ci5.run/mullvad | sh' first."
    fi
}

patch_mullvad_config() {
    local conf="/etc/wireguard/mullvad.conf"
    
    # Backup original
    [ -f "${conf}.orig" ] || cp "$conf" "${conf}.orig"
    
    # Check if already patched
    if grep -q "Table = " "$conf"; then
        info "Mullvad config already has Table directive"
        return 0
    fi
    
    # Add Table and PostUp/PostDown for proper routing
    # We want Mullvad to use its own routing table, not override main
    
    local temp=$(mktemp)
    
    cat "$conf" | while IFS= read -r line; do
        echo "$line"
        
        # After [Interface] section, add our routing directives
        if echo "$line" | grep -q "^\[Interface\]"; then
            cat << EOF

# CI5 Hybrid Mode additions
Table = $MULLVAD_TABLE
PostUp = ip rule add not fwmark $TS_FWMARK table $MULLVAD_TABLE priority 5100
PostDown = ip rule del not fwmark $TS_FWMARK table $MULLVAD_TABLE priority 5100 2>/dev/null || true
EOF
        fi
    done > "$temp"
    
    mv "$temp" "$conf"
    chmod 600 "$conf"
    
    info "Patched Mullvad config for hybrid mode"
}

# ─────────────────────────────────────────────────────────────────────────────
# TAILSCALE CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

check_tailscale() {
    if ! systemctl is-active tailscaled >/dev/null 2>&1; then
        warn "Tailscale daemon not running, starting..."
        systemctl start tailscaled
        sleep 2
    fi
    
    local status=$(tailscale status --json 2>/dev/null | grep -o '"BackendState":"[^"]*"' | cut -d'"' -f4)
    
    if [ "$status" != "Running" ]; then
        warn "Tailscale not authenticated. Please run: tailscale up"
        err "Tailscale must be authenticated before enabling hybrid mode"
    fi
    
    info "Tailscale is running and authenticated"
}

# ─────────────────────────────────────────────────────────────────────────────
# ENABLE/DISABLE
# ─────────────────────────────────────────────────────────────────────────────

enable_hybrid() {
    step "ENABLING HYBRID VPN MODE"
    
    check_dependencies
    check_mullvad_config
    check_tailscale
    
    # Create state directory
    mkdir -p "$HYBRID_DIR"
    
    # Setup routing infrastructure
    setup_routing_tables
    setup_policy_routing
    
    # Patch Mullvad config
    patch_mullvad_config
    
    # Restart Mullvad with new config
    info "Restarting Mullvad WireGuard..."
    wg-quick down mullvad 2>/dev/null || true
    sleep 1
    wg-quick up mullvad
    
    # Verify Tailscale still works
    info "Verifying Tailscale connectivity..."
    sleep 2
    if ! tailscale status >/dev/null 2>&1; then
        warn "Tailscale may need reconnection"
        tailscale up --accept-routes=false 2>/dev/null || true
    fi
    
    # Save state
    cat > "$HYBRID_CONF" << EOF
ENABLED=true
CONFIGURED_AT=$(date -Iseconds)
MULLVAD_TABLE=$MULLVAD_TABLE
TAILSCALE_TABLE=$TAILSCALE_TABLE
EOF
    
    # Create systemd drop-in to restore routing on boot
    mkdir -p /etc/systemd/system/wg-quick@mullvad.service.d
    cat > /etc/systemd/system/wg-quick@mullvad.service.d/hybrid.conf << EOF
[Service]
ExecStartPost=/sbin/ip rule add fwmark $TS_FWMARK table main priority 5000 || true
ExecStartPost=/sbin/ip rule add from 100.64.0.0/10 table $TAILSCALE_TABLE priority 5001 || true
EOF
    
    systemctl daemon-reload
    
    step "HYBRID MODE ENABLED"
    
    echo ""
    info "Split-horizon VPN is now active:"
    echo "  • Incoming: Accessible via Tailscale"
    echo "  • Outgoing: Protected by Mullvad"
    echo ""
    echo "Test with:"
    echo "  curl https://am.i.mullvad.net/connected  # Should show Mullvad"
    echo "  tailscale status                         # Should show peers"
    echo ""
}

disable_hybrid() {
    step "DISABLING HYBRID VPN MODE"
    
    # Remove routing rules
    ip rule del fwmark "$TS_FWMARK" table main priority 5000 2>/dev/null || true
    ip rule del from 100.64.0.0/10 table $TAILSCALE_TABLE priority 5001 2>/dev/null || true
    
    # Restore original Mullvad config
    if [ -f "/etc/wireguard/mullvad.conf.orig" ]; then
        mv /etc/wireguard/mullvad.conf.orig /etc/wireguard/mullvad.conf
        info "Restored original Mullvad config"
    fi
    
    # Remove systemd drop-in
    rm -rf /etc/systemd/system/wg-quick@mullvad.service.d
    systemctl daemon-reload
    
    # Restart Mullvad
    wg-quick down mullvad 2>/dev/null || true
    wg-quick up mullvad 2>/dev/null || true
    
    # Clear state
    rm -rf "$HYBRID_DIR"
    
    info "Hybrid mode disabled"
    warn "Note: Tailscale may not work correctly while Mullvad is active"
    echo "  To use Tailscale alone: wg-quick down mullvad"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

main() {
    case "$ACTION" in
        status)
            show_status
            ;;
        disable)
            disable_hybrid
            ;;
        setup)
            echo ""
            echo "╔═══════════════════════════════════════════════════════════════════╗"
            echo "║          CI5 HYBRID VPN — Split-Horizon Configuration             ║"
            echo "╚═══════════════════════════════════════════════════════════════════╝"
            echo ""
            enable_hybrid
            ;;
    esac
}

main "$@"
