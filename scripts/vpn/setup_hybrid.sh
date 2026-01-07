#!/bin/sh
# ═══════════════════════════════════════════════════════════════════════════
# ci5.run/hybrid — Split-Horizon VPN (Mullvad + Tailscale Coexistence)
# Version: 1.1-PHOENIX (Merged - UCI + Full Features)
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
#   1. Use UCI network rules for OpenWrt compatibility
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

# Law 1: BCM2712 Hardware Lock
if ! grep -q "Raspberry Pi 5" /proc/cpuinfo 2>/dev/null; then
    echo "FATAL: CI5 requires BCM2712 (Pi 5) hardware."
    exit 1
fi

# Law 5: The Soul Configuration
[ -f "/root/ci5/ci5.config" ] && . /root/ci5/ci5.config

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
    command -v uci >/dev/null 2>&1 || err "UCI not found (requires OpenWrt)"
    command -v ip >/dev/null 2>&1 || err "iproute2 not installed"

    if ! uci get network.wg_mullvad >/dev/null 2>&1; then
        err "Mullvad interface (wg_mullvad) not configured. Run 'ci5 mullvad' first."
    fi

    if ! uci get network.tailscale >/dev/null 2>&1 && ! ip link show tailscale0 >/dev/null 2>&1; then
        err "Tailscale not configured. Run 'ci5 tailscale' first."
    fi
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
    if ip link show wg_mullvad >/dev/null 2>&1; then
        local mullvad_ip=$(ip -4 addr show wg_mullvad 2>/dev/null | awk '/inet/ {print $2}')
        printf "  ${G}●${N} Interface: wg_mullvad (%s)\n" "${mullvad_ip:-no IP}"
    elif ip link show mullvad >/dev/null 2>&1; then
        local mullvad_ip=$(ip -4 addr show mullvad 2>/dev/null | awk '/inet/ {print $2}')
        printf "  ${G}●${N} Interface: mullvad (%s)\n" "${mullvad_ip:-no IP}"
    else
        printf "  ${R}●${N} Interface: not found\n"
    fi

    if [ -f "/etc/wireguard/mullvad.conf" ]; then
        printf "  ${G}●${N} Config: /etc/wireguard/mullvad.conf\n"
    else
        printf "  ${Y}●${N} Config: using UCI (no .conf file)\n"
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

    if command -v tailscale >/dev/null 2>&1; then
        local ts_status=$(tailscale status --json 2>/dev/null | grep -o '"BackendState":"[^"]*"' | cut -d'"' -f4)
        if [ "$ts_status" = "Running" ]; then
            printf "  ${G}●${N} Status: Running\n"
        else
            printf "  ${Y}●${N} Status: %s\n" "${ts_status:-Unknown}"
        fi
    fi

    echo ""

    # Check routing rules (UCI)
    echo "Policy Routing (UCI):"
    if uci show network 2>/dev/null | grep -q "ts_bypass"; then
        printf "  ${G}●${N} Tailscale bypass rule: active\n"
    else
        printf "  ${R}●${N} Tailscale bypass rule: not found\n"
    fi

    # Also check ip rule for legacy/manual setups
    if ip rule show | grep -q "fwmark $TS_FWMARK"; then
        printf "  ${G}●${N} fwmark rule: active (ip rule)\n"
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

    if command -v tailscale >/dev/null 2>&1; then
        if tailscale status >/dev/null 2>&1; then
            printf "  ${G}●${N} Tailscale: Reachable\n"
        else
            printf "  ${Y}●${N} Tailscale: Cannot verify (may still work)\n"
        fi
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

# ─────────────────────────────────────────────────────────────────────────────
# ENABLE/DISABLE
# ─────────────────────────────────────────────────────────────────────────────

enable_hybrid() {
    step "ENABLING HYBRID VPN MODE"

    check_dependencies

    # Create state directory
    mkdir -p "$HYBRID_DIR"

    setup_routing_tables

    local default_if=$(get_default_interface)
    local default_gw=$(get_default_gateway)

    if [ -n "$default_if" ] && [ -n "$default_gw" ]; then
        info "Physical interface: $default_if (gateway: $default_gw)"
    fi

    info "Configuring network rules via UCI..."

    # 1. Disable default route in Main table for Mullvad
    uci set network.wg_mullvad_peer.route_allowed_ips='0' 2>/dev/null || true

    # 2. Add default route to VPN table (51820)
    uci -q delete network.vpn_default 2>/dev/null || true
    uci set network.vpn_default=route
    uci set network.vpn_default.interface='wg_mullvad'
    uci set network.vpn_default.target='0.0.0.0/0'
    uci set network.vpn_default.table="$MULLVAD_TABLE"

    # 3. Rule: Tailscale fwmark -> Main table (Bypass VPN)
    uci -q delete network.ts_bypass 2>/dev/null || true
    uci set network.ts_bypass=rule
    uci set network.ts_bypass.mark="$TS_FWMARK"
    uci set network.ts_bypass.lookup='main'
    uci set network.ts_bypass.priority='5000'

    # 4. Rule: Tailscale CGNAT source -> Main table (Bypass VPN)
    uci -q delete network.ts_src 2>/dev/null || true
    uci set network.ts_src=rule
    uci set network.ts_src.src='100.64.0.0/10'
    uci set network.ts_src.lookup='main'
    uci set network.ts_src.priority='5001'

    # 5. Rule: Everything else -> VPN table
    uci -q delete network.catch_all 2>/dev/null || true
    uci set network.catch_all=rule
    uci set network.catch_all.dest='0.0.0.0/0'
    uci set network.catch_all.lookup="$MULLVAD_TABLE"
    uci set network.catch_all.priority='5100'

    # Commit changes
    uci commit network

    # Also add ip rules as backup (for immediate effect)
    ip rule add fwmark "$TS_FWMARK" table main priority 5000 2>/dev/null || true
    ip rule add from 100.64.0.0/10 table $TAILSCALE_TABLE priority 5001 2>/dev/null || true

    # Populate tailscale table with default route via physical interface
    if [ -n "$default_gw" ] && [ -n "$default_if" ]; then
        ip route replace default via "$default_gw" dev "$default_if" table $TAILSCALE_TABLE 2>/dev/null || true
    fi

    # Restart network to apply UCI changes
    info "Restarting network..."
    /etc/init.d/network reload

    # Verify Tailscale still works
    info "Verifying Tailscale connectivity..."
    sleep 3
    if command -v tailscale >/dev/null 2>&1; then
        if ! tailscale status >/dev/null 2>&1; then
            warn "Tailscale may need reconnection"
        fi
    fi

    # Save state
    cat > "$HYBRID_CONF" << EOF
ENABLED=true
CONFIGURED_AT=$(date -Iseconds)
MULLVAD_TABLE=$MULLVAD_TABLE
TAILSCALE_TABLE=$TAILSCALE_TABLE
DEFAULT_IF=$default_if
DEFAULT_GW=$default_gw
EOF

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

    info "Reverting UCI configuration..."

    # Remove UCI rules
    uci -q delete network.ts_bypass 2>/dev/null || true
    uci -q delete network.ts_src 2>/dev/null || true
    uci -q delete network.catch_all 2>/dev/null || true
    uci -q delete network.vpn_default 2>/dev/null || true

    # Restore Mullvad default route behavior
    uci set network.wg_mullvad_peer.route_allowed_ips='1' 2>/dev/null || true

    uci commit network

    # Remove ip rules
    ip rule del fwmark "$TS_FWMARK" table main priority 5000 2>/dev/null || true
    ip rule del from 100.64.0.0/10 table $TAILSCALE_TABLE priority 5001 2>/dev/null || true

    info "Restarting network..."
    /etc/init.d/network reload

    # Clear state
    rm -rf "$HYBRID_DIR"

    info "Hybrid mode disabled"
    warn "Note: Tailscale may not work correctly while Mullvad is active"
    echo "  To use Tailscale alone: ifdown wg_mullvad"
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
