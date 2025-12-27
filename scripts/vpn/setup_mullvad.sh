#!/bin/sh
# ══════════════════════════════════════════════════════════════════════════════
# Ci5 Mullvad WireGuard Setup (v7.4-RC-1)
# ══════════════════════════════════════════════════════════════════════════════
# Features:
#   - Parse .conf files from Mullvad web interface
#   - VLAN-selective routing (only route chosen VLANs through VPN)
#   - Multi-server failover with health monitoring
#   - Kill switch support
# ══════════════════════════════════════════════════════════════════════════════

set -e

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────
CI5_BASE="${CI5_BASE:-/opt/ci5}"
[ ! -d "$CI5_BASE" ] && CI5_BASE="/root/ci5"

# Ci5 default LAN (192.168.99.1)
CI5_LAN_IP="192.168.99.1"
CI5_LAN_SUBNET="192.168.99.0/24"

# Mullvad config storage
MULLVAD_CONF_DIR="${CI5_BASE}/mullvad"
MULLVAD_STATE_FILE="/tmp/ci5_mullvad_state"
MULLVAD_HEALTH_LOG="/tmp/ci5_mullvad_health.log"

# WireGuard defaults
WG_INTERFACE="${WG_INTERFACE:-wg_mullvad}"
WG_METRIC="${WG_METRIC:-50}"
WG_TABLE="100"
WG_FWMARK="0x1"

# Health check defaults
HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-30}"
HEALTH_CHECK_TIMEOUT="${HEALTH_CHECK_TIMEOUT:-5}"
HEALTH_FAILURE_THRESHOLD="${HEALTH_FAILURE_THRESHOLD:-3}"

# Failover daemon
FAILOVER_BIN="/usr/bin/ci5-mullvad-failover"
FAILOVER_INIT="/etc/init.d/ci5-mullvad-failover"

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
│  Ci5 Mullvad WireGuard Setup (v7.4-RC-1)                                     │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  USAGE:                                                                      │
│    mullvad.sh [command] [options]                                            │
│                                                                              │
│  COMMANDS:                                                                   │
│    setup         Initial setup with config file(s)                           │
│    add-server    Add additional failover server config                       │
│    list-servers  Show all configured servers                                 │
│    rotate        Manually rotate to next server                              │
│    status        Show connection status                                      │
│    disable       Disable VPN (keep config)                                   │
│    remove        Remove all Mullvad configuration                            │
│                                                                              │
│  SETUP OPTIONS:                                                              │
│    -c, --config <path>      Primary Mullvad .conf file (required for setup)  │
│    -a, --add <path>         Add failover server config (can repeat)          │
│    -v, --vlan <id>          Route only this VLAN through VPN (can repeat)    │
│    -k, --killswitch         Enable kill switch for routed VLANs              │
│    -f, --failover           Enable automatic server failover daemon          │
│    -i, --interface <name>   WireGuard interface name (default: wg_mullvad)   │
│                                                                              │
│  VLAN ROUTING:                                                               │
│    By default, ALL traffic routes through Mullvad.                           │
│    Use --vlan to selectively route only specific VLANs:                      │
│                                                                              │
│    --vlan 10                Route VLAN 10 through VPN, others via WAN        │
│    --vlan 10 --vlan 20      Route VLANs 10 & 20 through VPN                  │
│    --vlan 30 --vlan 40      Route VLANs 30 & 40, leave 10/20 on WAN          │
│    --vlan guest             Route 'guest' interface through VPN              │
│                                                                              │
│    Ci5 VLAN Scheme (default):                                                │
│      VLAN 10 → 192.168.10.0/24 (e.g., Trusted)                               │
│      VLAN 20 → 192.168.20.0/24 (e.g., IoT)                                   │
│      VLAN 30 → 192.168.30.0/24 (e.g., Guest)                                 │
│      VLAN 40 → 192.168.40.0/24 (e.g., Kids)                                  │
│      Main LAN → 192.168.99.0/24                                              │
│                                                                              │
│  FAILOVER:                                                                   │
│    Add multiple server configs for automatic failover:                       │
│                                                                              │
│    mullvad.sh setup -c se-got.conf -a se-sto.conf -a de-fra.conf -f          │
│                                                                              │
│    The failover daemon monitors connectivity every 30s and rotates           │
│    servers after 3 consecutive failures (~90s of downtime).                  │
│                                                                              │
│  EXAMPLES:                                                                   │
│    # Basic setup (all traffic through VPN)                                   │
│    curl ci5.run/mullvad | sh -s setup -c /tmp/mullvad.conf                   │
│                                                                              │
│    # Route only VLAN 20 (IoT) and VLAN 40 (kids) through VPN                 │
│    curl ci5.run/mullvad | sh -s setup -c /tmp/mullvad.conf -v 20 -v 40       │
│                                                                              │
│    # Full setup: 3 servers, VLAN routing, kill switch, failover              │
│    curl ci5.run/mullvad | sh -s setup -c se-got.conf -a se-sto.conf \        │
│         -a de-fra.conf -v 20 -v 40 -k -f                                     │
│                                                                              │
│    # Add another failover server later                                       │
│    curl ci5.run/mullvad | sh -s add-server -c /tmp/ch-zur.conf               │
│                                                                              │
│    # Manually rotate to next server                                          │
│    curl ci5.run/mullvad | sh -s rotate                                       │
│                                                                              │
│  FIRST TIME SETUP:                                                           │
│    1. Log into https://mullvad.net/account/wireguard-config                  │
│    2. Generate configs for 2-3 servers (different locations for failover)   │
│    3. Download .conf files to router:                                        │
│       scp *.conf root@192.168.99.1:/tmp/                                     │
│    4. Run setup command                                                      │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
EOF
    exit 0
}

# ─────────────────────────────────────────────────────────────────────────────
# DEPENDENCY CHECK
# ─────────────────────────────────────────────────────────────────────────────
check_deps() {
    log_info "Checking dependencies..."
    
    local MISSING=""
    local REQUIRED="wireguard-tools kmod-wireguard ip-full"
    
    for pkg in $REQUIRED; do
        if ! opkg list-installed 2>/dev/null | grep -q "^$pkg "; then
            MISSING="$MISSING $pkg"
        fi
    done
    
    if [ -n "$MISSING" ]; then
        log_warn "Installing missing packages:$MISSING"
        opkg update >/dev/null 2>&1 || {
            log_err "Failed to update package list"
            exit 1
        }
        # shellcheck disable=SC2086
        opkg install $MISSING >/dev/null 2>&1 || {
            log_err "Failed to install required packages"
            exit 1
        }
        log_ok "Dependencies installed"
    else
        log_ok "All dependencies present"
    fi
    
    # Optional LuCI support
    if ! opkg list-installed 2>/dev/null | grep -q "^luci-proto-wireguard "; then
        log_info "Tip: Install luci-proto-wireguard for LuCI WireGuard UI"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# PARSE MULLVAD CONFIG FILE
# ─────────────────────────────────────────────────────────────────────────────
parse_config() {
    local CONF_PATH="$1"
    local OUTPUT_PREFIX="$2"
    
    if [ -z "$CONF_PATH" ]; then
        log_err "No config file specified"
        echo ""
        echo "To get a Mullvad config file:"
        echo "  1. Visit: https://mullvad.net/account/wireguard-config"
        echo "  2. Select a server location"
        echo "  3. Download the .conf file"
        echo "  4. Transfer to router: scp mullvad.conf root@${CI5_LAN_IP}:/tmp/"
        echo "  5. Run: $0 setup -c /tmp/mullvad.conf"
        exit 1
    fi
    
    if [ ! -f "$CONF_PATH" ]; then
        log_err "Config file not found: $CONF_PATH"
        exit 1
    fi
    
    # Extract values from WireGuard config
    local PRIVATE_KEY=$(grep -E "^PrivateKey\s*=" "$CONF_PATH" | sed 's/.*=\s*//' | tr -d ' ')
    local ADDRESS=$(grep -E "^Address\s*=" "$CONF_PATH" | sed 's/.*=\s*//' | tr -d ' ')
    local PUBKEY=$(grep -E "^PublicKey\s*=" "$CONF_PATH" | sed 's/.*=\s*//' | tr -d ' ')
    local ENDPOINT=$(grep -E "^Endpoint\s*=" "$CONF_PATH" | sed 's/.*=\s*//' | tr -d ' ')
    local DNS=$(grep -E "^DNS\s*=" "$CONF_PATH" | sed 's/.*=\s*//' | tr -d ' ')
    
    # Parse endpoint
    local HOST=$(echo "$ENDPOINT" | cut -d':' -f1)
    local PORT=$(echo "$ENDPOINT" | cut -d':' -f2)
    [ -z "$PORT" ] && PORT="51820"
    
    # Extract IPv4
    local IPV4=$(echo "$ADDRESS" | cut -d',' -f1 | cut -d'/' -f1)
    local IPV4_MASK=$(echo "$ADDRESS" | cut -d',' -f1 | grep -o '/[0-9]*' | tr -d '/')
    [ -z "$IPV4_MASK" ] && IPV4_MASK="32"
    
    # Validate
    if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBKEY" ] || [ -z "$HOST" ]; then
        log_err "Invalid config file: missing required fields"
        exit 1
    fi
    
    # Export for caller (or save to file)
    if [ -n "$OUTPUT_PREFIX" ]; then
        # Save parsed config
        cat > "${OUTPUT_PREFIX}" << EOF
PRIVATE_KEY="$PRIVATE_KEY"
ADDRESS="$ADDRESS"
IPV4="$IPV4"
IPV4_MASK="$IPV4_MASK"
PUBKEY="$PUBKEY"
HOST="$HOST"
PORT="$PORT"
DNS="$DNS"
CONF_NAME="$(basename "$CONF_PATH" .conf)"
EOF
    else
        # Export to current shell
        WG_PRIVATE_KEY="$PRIVATE_KEY"
        VPN_ADDRESS="$ADDRESS"
        VPN_IPV4="$IPV4"
        VPN_IPV4_MASK="$IPV4_MASK"
        SERVER_PUBKEY="$PUBKEY"
        SERVER_HOST="$HOST"
        SERVER_PORT="$PORT"
        DNS_SERVERS="$DNS"
    fi
    
    # Derive public key for verification
    local DERIVED_PUB=$(echo "$PRIVATE_KEY" | wg pubkey 2>/dev/null) || {
        log_err "Failed to derive public key"
        exit 1
    }
    
    log_ok "Parsed: $HOST:$PORT ($IPV4/$IPV4_MASK)"
}

# ─────────────────────────────────────────────────────────────────────────────
# INITIALIZE CONFIG STORAGE
# ─────────────────────────────────────────────────────────────────────────────
init_storage() {
    mkdir -p "$MULLVAD_CONF_DIR"
    chmod 700 "$MULLVAD_CONF_DIR"
}

# ─────────────────────────────────────────────────────────────────────────────
# ADD SERVER CONFIG
# ─────────────────────────────────────────────────────────────────────────────
add_server_config() {
    local CONF_PATH="$1"
    local SERVER_NUM=$(ls -1 "$MULLVAD_CONF_DIR"/server_*.conf 2>/dev/null | wc -l)
    SERVER_NUM=$((SERVER_NUM + 1))
    
    local DEST="${MULLVAD_CONF_DIR}/server_${SERVER_NUM}.conf"
    
    log_info "Adding server config #$SERVER_NUM..."
    parse_config "$CONF_PATH" "$DEST"
    
    log_ok "Server #$SERVER_NUM added: $(grep HOST "$DEST" | cut -d'"' -f2)"
}

# ─────────────────────────────────────────────────────────────────────────────
# LIST SERVERS
# ─────────────────────────────────────────────────────────────────────────────
list_servers() {
    echo ""
    echo "┌──────────────────────────────────────────────────────────────────┐"
    echo "│  Configured Mullvad Servers                                     │"
    echo "└──────────────────────────────────────────────────────────────────┘"
    echo ""
    
    if [ ! -d "$MULLVAD_CONF_DIR" ] || [ -z "$(ls -A "$MULLVAD_CONF_DIR" 2>/dev/null)" ]; then
        echo "    No servers configured."
        echo "    Run: $0 setup -c /path/to/mullvad.conf"
        return
    fi
    
    local CURRENT=""
    [ -f "$MULLVAD_STATE_FILE" ] && CURRENT=$(grep "^ACTIVE=" "$MULLVAD_STATE_FILE" 2>/dev/null | cut -d'=' -f2)
    
    local IDX=1
    for conf in "$MULLVAD_CONF_DIR"/server_*.conf; do
        [ -f "$conf" ] || continue
        . "$conf"
        
        local MARKER="  "
        [ "$IDX" = "$CURRENT" ] && MARKER="${GREEN}▶${NC} "
        
        printf "    %b#%d: %s:%s (%s)\n" "$MARKER" "$IDX" "$HOST" "$PORT" "$CONF_NAME"
        IDX=$((IDX + 1))
    done
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# CREATE UCI CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────
configure_wireguard() {
    local SERVER_FILE="$1"
    
    # Load server config
    . "$SERVER_FILE"
    
    log_info "Configuring WireGuard interface: $WG_INTERFACE"
    
    # Remove existing config
    uci -q delete network."$WG_INTERFACE" 2>/dev/null || true
    uci -q delete network."${WG_INTERFACE}_peer" 2>/dev/null || true
    
    # Create interface
    uci set network."$WG_INTERFACE"=interface
    uci set network."$WG_INTERFACE".proto='wireguard'
    uci set network."$WG_INTERFACE".private_key="$PRIVATE_KEY"
    uci add_list network."$WG_INTERFACE".addresses="${IPV4}/${IPV4_MASK}"
    uci set network."$WG_INTERFACE".mtu='1320'
    uci set network."$WG_INTERFACE".nohostroute='1'
    
    # For policy routing, don't set default route
    if [ -n "$ROUTED_VLANS" ]; then
        uci set network."$WG_INTERFACE".metric='9999'
    else
        uci set network."$WG_INTERFACE".metric="$WG_METRIC"
    fi
    
    # Add peer
    uci set network."${WG_INTERFACE}_peer"=wireguard_"$WG_INTERFACE"
    uci set network."${WG_INTERFACE}_peer".public_key="$PUBKEY"
    uci set network."${WG_INTERFACE}_peer".endpoint_host="$HOST"
    uci set network."${WG_INTERFACE}_peer".endpoint_port="$PORT"
    uci set network."${WG_INTERFACE}_peer".persistent_keepalive='25'
    uci add_list network."${WG_INTERFACE}_peer".allowed_ips='0.0.0.0/0'
    uci add_list network."${WG_INTERFACE}_peer".allowed_ips='::/0'
    
    # Only set route_allowed_ips if not doing policy routing
    if [ -z "$ROUTED_VLANS" ]; then
        uci set network."${WG_INTERFACE}_peer".route_allowed_ips='1'
    else
        uci set network."${WG_INTERFACE}_peer".route_allowed_ips='0'
    fi
    
    log_ok "WireGuard interface configured"
}

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURE VLAN SELECTIVE ROUTING
# ─────────────────────────────────────────────────────────────────────────────
configure_vlan_routing() {
    log_info "Configuring VLAN-selective routing..."
    
    # Create VPN routing table if not exists
    if ! grep -q "^${WG_TABLE}.*vpn_mullvad" /etc/iproute2/rt_tables 2>/dev/null; then
        echo "${WG_TABLE}    vpn_mullvad" >> /etc/iproute2/rt_tables
    fi
    
    # Create routing rules script
    cat > /etc/hotplug.d/iface/90-mullvad-vlan-routing << VLANROUTE
#!/bin/sh
# Ci5 Mullvad VLAN Routing - Auto-generated

[ "\$ACTION" = "ifup" ] && [ "\$INTERFACE" = "$WG_INTERFACE" ] && {
    logger -t mullvad-vlan "Setting up VLAN routing through $WG_INTERFACE"
    
    # Add default route to VPN table
    ip route add default dev $WG_INTERFACE table $WG_TABLE 2>/dev/null || \\
        ip route replace default dev $WG_INTERFACE table $WG_TABLE
    
    # Add fwmark rule
    ip rule add fwmark $WG_FWMARK lookup $WG_TABLE prio 99 2>/dev/null || true
    
VLANROUTE

    # Add rules for each VLAN
    for VLAN in $ROUTED_VLANS; do
        local VLAN_SUBNET=""
        
        # Determine subnet based on VLAN ID
        if echo "$VLAN" | grep -qE '^[0-9]+$'; then
            # Numeric VLAN ID - ci5 uses 192.168.{VLAN_ID}.0/24
            VLAN_SUBNET="192.168.${VLAN}.0/24"
        else
            # Named interface (e.g., "guest", "iot") - try to detect
            local VLAN_IF="br-$VLAN"
            [ ! -e "/sys/class/net/$VLAN_IF" ] && VLAN_IF="$VLAN"
            VLAN_SUBNET=$(ip addr show "$VLAN_IF" 2>/dev/null | grep -oP 'inet \K[\d.]+/\d+' | head -1)
        fi
        
        if [ -n "$VLAN_SUBNET" ]; then
            log_info "  VLAN $VLAN → $VLAN_SUBNET via VPN"
            
            cat >> /etc/hotplug.d/iface/90-mullvad-vlan-routing << VLANRULE
    # VLAN $VLAN ($VLAN_SUBNET)
    ip rule add from $VLAN_SUBNET lookup $WG_TABLE prio 100 2>/dev/null || true
VLANRULE
        fi
    done
    
    cat >> /etc/hotplug.d/iface/90-mullvad-vlan-routing << 'VLANEND'
    
    logger -t mullvad-vlan "VLAN routing configured"
}

[ "$ACTION" = "ifdown" ] && [ "$INTERFACE" = "wg_mullvad" ] && {
    logger -t mullvad-vlan "Cleaning up VLAN routing"
    ip route flush table vpn_mullvad 2>/dev/null || true
    # Note: ip rules persist, but will be no-op without the route
}
VLANEND

    chmod +x /etc/hotplug.d/iface/90-mullvad-vlan-routing
    
    # Create mangle rules for packet marking (belt and suspenders)
    cat > /etc/firewall.mullvad_vlan.sh << FWSCRIPT
#!/bin/sh
# Ci5 Mullvad VLAN Packet Marking - Auto-generated

FWSCRIPT

    for VLAN in $ROUTED_VLANS; do
        if echo "$VLAN" | grep -qE '^[0-9]+$'; then
            local VLAN_SUBNET="192.168.${VLAN}.0/24"
            cat >> /etc/firewall.mullvad_vlan.sh << FWMARK
iptables -t mangle -A PREROUTING -s $VLAN_SUBNET -j MARK --set-mark $WG_FWMARK 2>/dev/null || true
FWMARK
        fi
    done
    
    chmod +x /etc/firewall.mullvad_vlan.sh
    
    log_ok "VLAN routing configured for: $ROUTED_VLANS"
    echo "    Other VLANs and main LAN ($CI5_LAN_SUBNET) route via WAN"
}

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURE FIREWALL
# ─────────────────────────────────────────────────────────────────────────────
configure_firewall() {
    log_info "Configuring firewall..."
    
    # Create VPN zone
    local VPN_ZONE_EXISTS=$(uci show firewall 2>/dev/null | grep -c "\.name='vpn'" || true)
    
    if [ "$VPN_ZONE_EXISTS" -eq 0 ]; then
        uci add firewall zone
        uci set firewall.@zone[-1].name='vpn'
        uci set firewall.@zone[-1].input='REJECT'
        uci set firewall.@zone[-1].output='ACCEPT'
        uci set firewall.@zone[-1].forward='REJECT'
        uci set firewall.@zone[-1].masq='1'
        uci set firewall.@zone[-1].mtu_fix='1'
        uci add_list firewall.@zone[-1].network="$WG_INTERFACE"
        
        # Allow LAN to VPN forwarding
        uci add firewall forwarding
        uci set firewall.@forwarding[-1].src='lan'
        uci set firewall.@forwarding[-1].dest='vpn'
        
        log_ok "Created VPN firewall zone"
    else
        # Add interface to existing zone
        local ZONE_IDX=$(uci show firewall 2>/dev/null | grep "\.name='vpn'" | head -1 | sed "s/.*\[@zone\[\([0-9]*\)\].*/\1/")
        uci add_list firewall.@zone["$ZONE_IDX"].network="$WG_INTERFACE" 2>/dev/null || true
        log_ok "Added to existing VPN zone"
    fi
    
    # Include VLAN marking script if exists
    if [ -f /etc/firewall.mullvad_vlan.sh ]; then
        # Add include to firewall config
        local INCLUDE_EXISTS=$(uci show firewall 2>/dev/null | grep -c "mullvad_vlan" || true)
        if [ "$INCLUDE_EXISTS" -eq 0 ]; then
            uci add firewall include
            uci set firewall.@include[-1].path='/etc/firewall.mullvad_vlan.sh'
            uci set firewall.@include[-1].reload='1'
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURE KILL SWITCH (VLAN-aware)
# ─────────────────────────────────────────────────────────────────────────────
configure_killswitch() {
    log_info "Configuring kill switch..."
    
    local WAN_IF=$(uci -q get network.wan.device 2>/dev/null || uci -q get network.wan.ifname 2>/dev/null || echo "eth1")
    
    cat > /etc/hotplug.d/iface/99-mullvad-killswitch << KILLSWITCH
#!/bin/sh
# Ci5 Mullvad Kill Switch - Block VPN-routed traffic if tunnel drops

WAN_IF="$WAN_IF"

[ "\$ACTION" = "ifdown" ] && [ "\$INTERFACE" = "$WG_INTERFACE" ] && {
    logger -t mullvad-ks "VPN down - activating kill switch"
    
KILLSWITCH

    if [ -n "$ROUTED_VLANS" ]; then
        # Only block traffic from VPN-routed VLANs
        for VLAN in $ROUTED_VLANS; do
            if echo "$VLAN" | grep -qE '^[0-9]+$'; then
                local VLAN_SUBNET="192.168.${VLAN}.0/24"
                cat >> /etc/hotplug.d/iface/99-mullvad-killswitch << KSRULE
    # Block VLAN $VLAN ($VLAN_SUBNET) from WAN
    iptables -I FORWARD -s $VLAN_SUBNET -o "\$WAN_IF" -j DROP 2>/dev/null || true
KSRULE
            fi
        done
        
        cat >> /etc/hotplug.d/iface/99-mullvad-killswitch << 'KSMSG'
    logger -t mullvad-ks "Kill switch active - VPN VLANs blocked from WAN"
}
KSMSG
    else
        # Block all non-local traffic
        cat >> /etc/hotplug.d/iface/99-mullvad-killswitch << 'KSALL'
    # Block all WAN-bound traffic
    iptables -I FORWARD -o "$WAN_IF" -j DROP 2>/dev/null || true
    iptables -I OUTPUT -o "$WAN_IF" ! -d 10.0.0.0/8 ! -d 172.16.0.0/12 ! -d 192.168.0.0/16 -j DROP 2>/dev/null || true
    logger -t mullvad-ks "Kill switch active - ALL WAN traffic blocked"
}
KSALL
    fi
    
    cat >> /etc/hotplug.d/iface/99-mullvad-killswitch << KSUP

[ "\$ACTION" = "ifup" ] && [ "\$INTERFACE" = "$WG_INTERFACE" ] && {
    logger -t mullvad-ks "VPN up - deactivating kill switch"
    
    # Remove blocking rules
KSUP

    if [ -n "$ROUTED_VLANS" ]; then
        for VLAN in $ROUTED_VLANS; do
            if echo "$VLAN" | grep -qE '^[0-9]+$'; then
                local VLAN_SUBNET="192.168.${VLAN}.0/24"
                cat >> /etc/hotplug.d/iface/99-mullvad-killswitch << KSCLEAN
    iptables -D FORWARD -s $VLAN_SUBNET -o "\$WAN_IF" -j DROP 2>/dev/null || true
KSCLEAN
            fi
        done
    else
        cat >> /etc/hotplug.d/iface/99-mullvad-killswitch << 'KSCLEANALL'
    iptables -D FORWARD -o "$WAN_IF" -j DROP 2>/dev/null || true
    iptables -D OUTPUT -o "$WAN_IF" ! -d 10.0.0.0/8 ! -d 172.16.0.0/12 ! -d 192.168.0.0/16 -j DROP 2>/dev/null || true
KSCLEANALL
    fi
    
    echo "}" >> /etc/hotplug.d/iface/99-mullvad-killswitch
    
    chmod +x /etc/hotplug.d/iface/99-mullvad-killswitch
    log_ok "Kill switch configured"
}

# ─────────────────────────────────────────────────────────────────────────────
# INSTALL FAILOVER DAEMON
# ─────────────────────────────────────────────────────────────────────────────
install_failover_daemon() {
    log_info "Installing failover daemon..."
    
    cat > "$FAILOVER_BIN" << 'FAILOVER'
#!/bin/sh
# Ci5 Mullvad Failover Daemon
# Monitors VPN health and rotates servers on failure

CONF_DIR="/opt/ci5/mullvad"
[ ! -d "$CONF_DIR" ] && CONF_DIR="/root/ci5/mullvad"
STATE_FILE="/tmp/ci5_mullvad_state"
LOG_FILE="/tmp/ci5_mullvad_health.log"
WG_INTERFACE="wg_mullvad"

INTERVAL="${HEALTH_CHECK_INTERVAL:-30}"
TIMEOUT="${HEALTH_CHECK_TIMEOUT:-5}"
THRESHOLD="${HEALTH_FAILURE_THRESHOLD:-3}"

FAIL_COUNT=0
CURRENT_SERVER=1

log() {
    local MSG="$(date '+%Y-%m-%d %H:%M:%S') $1"
    logger -t mullvad-failover "$1"
    echo "$MSG" >> "$LOG_FILE"
    # Keep log small
    tail -100 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"
}

count_servers() {
    ls -1 "$CONF_DIR"/server_*.conf 2>/dev/null | wc -l
}

health_check() {
    # Method 1: Check WireGuard handshake recency
    local LAST_HANDSHAKE=$(wg show "$WG_INTERFACE" latest-handshakes 2>/dev/null | awk '{print $2}')
    if [ -n "$LAST_HANDSHAKE" ] && [ "$LAST_HANDSHAKE" -gt 0 ]; then
        local NOW=$(date +%s)
        local AGE=$((NOW - LAST_HANDSHAKE))
        # If handshake older than 3 minutes, consider unhealthy
        if [ "$AGE" -gt 180 ]; then
            log "Handshake stale: ${AGE}s old"
            return 1
        fi
    fi
    
    # Method 2: Check Mullvad connectivity
    local MULLVAD_CHECK=$(curl -s --max-time "$TIMEOUT" --interface "$WG_INTERFACE" https://am.i.mullvad.net/connected 2>/dev/null)
    if echo "$MULLVAD_CHECK" | grep -qi "you are connected"; then
        return 0
    fi
    
    # Method 3: Ping Mullvad DNS through tunnel
    local MULLVAD_DNS="10.64.0.1"
    if ping -c 1 -W "$TIMEOUT" -I "$WG_INTERFACE" "$MULLVAD_DNS" >/dev/null 2>&1; then
        return 0
    fi
    
    return 1
}

rotate_server() {
    local TOTAL=$(count_servers)
    [ "$TOTAL" -le 1 ] && {
        log "Only one server configured, cannot rotate"
        return 1
    }
    
    CURRENT_SERVER=$((CURRENT_SERVER % TOTAL + 1))
    local SERVER_FILE="$CONF_DIR/server_${CURRENT_SERVER}.conf"
    
    if [ ! -f "$SERVER_FILE" ]; then
        log "Server file not found: $SERVER_FILE"
        return 1
    fi
    
    . "$SERVER_FILE"
    log "Rotating to server #$CURRENT_SERVER: $HOST:$PORT ($CONF_NAME)"
    
    # Update WireGuard peer endpoint (hot-swap without full teardown)
    wg set "$WG_INTERFACE" peer "$PUBKEY" endpoint "$HOST:$PORT" 2>/dev/null || {
        # Fallback: full interface restart
        log "Hot-swap failed, restarting interface"
        ifdown "$WG_INTERFACE" 2>/dev/null
        sleep 2
        
        # Update UCI
        uci set network."${WG_INTERFACE}_peer".endpoint_host="$HOST"
        uci set network."${WG_INTERFACE}_peer".endpoint_port="$PORT"
        uci set network."${WG_INTERFACE}_peer".public_key="$PUBKEY"
        uci commit network
        
        ifup "$WG_INTERFACE" 2>/dev/null
    }
    
    # Save state
    echo "ACTIVE=$CURRENT_SERVER" > "$STATE_FILE"
    echo "HOST=$HOST" >> "$STATE_FILE"
    echo "CONF_NAME=$CONF_NAME" >> "$STATE_FILE"
    echo "ROTATED=$(date -Iseconds)" >> "$STATE_FILE"
    
    # Give new connection time to establish
    sleep 5
    
    return 0
}

# Initialize
log "Failover daemon started (interval: ${INTERVAL}s, threshold: $THRESHOLD)"

# Load current state
[ -f "$STATE_FILE" ] && . "$STATE_FILE" 2>/dev/null
[ -z "$ACTIVE" ] && CURRENT_SERVER=1 || CURRENT_SERVER="$ACTIVE"

TOTAL_SERVERS=$(count_servers)
log "Monitoring $TOTAL_SERVERS server(s), currently on #$CURRENT_SERVER"

# Main loop
while true; do
    if health_check; then
        [ "$FAIL_COUNT" -gt 0 ] && log "Connection recovered"
        FAIL_COUNT=0
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        log "Health check failed ($FAIL_COUNT/$THRESHOLD)"
        
        if [ "$FAIL_COUNT" -ge "$THRESHOLD" ]; then
            log "Threshold reached, rotating server"
            if rotate_server; then
                FAIL_COUNT=0
            else
                # If rotation fails, wait longer before retrying
                sleep 60
            fi
        fi
    fi
    
    sleep "$INTERVAL"
done
FAILOVER

    chmod +x "$FAILOVER_BIN"
    
    # Create init script
    cat > "$FAILOVER_INIT" << 'INITSCRIPT'
#!/bin/sh /etc/rc.common

START=99
STOP=10
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/ci5-mullvad-failover
    procd_set_param respawn 3600 5 5
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
INITSCRIPT

    chmod +x "$FAILOVER_INIT"
    
    # Enable and start
    "$FAILOVER_INIT" enable
    "$FAILOVER_INIT" start
    
    log_ok "Failover daemon installed and started"
    echo "    Health log: tail -f $MULLVAD_HEALTH_LOG"
}

# ─────────────────────────────────────────────────────────────────────────────
# APPLY CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────
apply_config() {
    log_info "Applying configuration..."
    
    uci commit network
    uci commit firewall
    
    /etc/init.d/network reload >/dev/null 2>&1 || true
    /etc/init.d/firewall reload >/dev/null 2>&1 || true
    
    sleep 3
    
    # Trigger hotplug for VLAN routing
    if [ -n "$ROUTED_VLANS" ] && [ -x /etc/hotplug.d/iface/90-mullvad-vlan-routing ]; then
        ACTION=ifup INTERFACE="$WG_INTERFACE" /etc/hotplug.d/iface/90-mullvad-vlan-routing
    fi
    
    log_ok "Configuration applied"
}

# ─────────────────────────────────────────────────────────────────────────────
# STATUS
# ─────────────────────────────────────────────────────────────────────────────
show_status() {
    echo ""
    echo "┌──────────────────────────────────────────────────────────────────┐"
    echo "│  Ci5 Mullvad VPN Status                                         │"
    echo "└──────────────────────────────────────────────────────────────────┘"
    echo ""
    
    # Interface status
    if ! uci -q get network."$WG_INTERFACE" >/dev/null 2>&1; then
        log_err "Mullvad interface not configured"
        echo "    Run: $0 setup -c /path/to/mullvad.conf"
        return 1
    fi
    
    local IF_STATUS=$(ifstatus "$WG_INTERFACE" 2>/dev/null)
    if echo "$IF_STATUS" | grep -q '"up": true'; then
        echo -e "    Interface:   ${GREEN}UP${NC} ($WG_INTERFACE)"
    else
        echo -e "    Interface:   ${RED}DOWN${NC} ($WG_INTERFACE)"
    fi
    
    # Current server
    if [ -f "$MULLVAD_STATE_FILE" ]; then
        . "$MULLVAD_STATE_FILE" 2>/dev/null
        echo "    Server:      #${ACTIVE:-1} - ${HOST:-unknown} (${CONF_NAME:-?})"
        [ -n "$ROTATED" ] && echo "    Last Rotate: $ROTATED"
    fi
    
    # WireGuard stats
    if command -v wg >/dev/null 2>&1; then
        local WG_STATS=$(wg show "$WG_INTERFACE" 2>/dev/null)
        if [ -n "$WG_STATS" ]; then
            local ENDPOINT=$(echo "$WG_STATS" | grep endpoint | awk '{print $2}')
            local HANDSHAKE=$(echo "$WG_STATS" | grep "latest handshake" | sed 's/.*: //')
            local TRANSFER=$(echo "$WG_STATS" | grep transfer | sed 's/.*: //')
            
            [ -n "$ENDPOINT" ] && echo "    Endpoint:    $ENDPOINT"
            [ -n "$HANDSHAKE" ] && echo "    Handshake:   $HANDSHAKE"
            [ -n "$TRANSFER" ] && echo "    Transfer:    $TRANSFER"
        fi
    fi
    
    # External IP check
    echo ""
    echo -n "    External IP: "
    local EXT_IP=$(curl -s --max-time 5 https://am.i.mullvad.net/ip 2>/dev/null || echo "Unknown")
    echo "$EXT_IP"
    
    echo -n "    Mullvad:     "
    local MULLVAD_CHECK=$(curl -s --max-time 5 https://am.i.mullvad.net/connected 2>/dev/null || echo "Unknown")
    if echo "$MULLVAD_CHECK" | grep -qi "you are connected"; then
        echo -e "${GREEN}Connected${NC}"
    else
        echo -e "${YELLOW}Not connected via Mullvad${NC}"
    fi
    
    # VLAN routing status
    local VLAN_RULES=$(ip rule show 2>/dev/null | grep "lookup vpn_mullvad\|lookup $WG_TABLE")
    if [ -n "$VLAN_RULES" ]; then
        echo ""
        echo "    VLAN Routing:"
        echo "$VLAN_RULES" | while read rule; do
            echo "        $rule"
        done
    fi
    
    # Failover status
    echo ""
    if pgrep -f "ci5-mullvad-failover" >/dev/null 2>&1; then
        echo -e "    Failover:    ${GREEN}ACTIVE${NC}"
    else
        echo -e "    Failover:    ${YELLOW}INACTIVE${NC}"
    fi
    local TOTAL_SERVERS=$(ls -1 "$MULLVAD_CONF_DIR"/server_*.conf 2>/dev/null | wc -l)
    echo "    Servers:     $TOTAL_SERVERS configured"
    
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# ROTATE SERVER (manual)
# ─────────────────────────────────────────────────────────────────────────────
manual_rotate() {
    log_info "Manually rotating to next server..."
    
    local TOTAL=$(ls -1 "$MULLVAD_CONF_DIR"/server_*.conf 2>/dev/null | wc -l)
    if [ "$TOTAL" -le 1 ]; then
        log_err "Only one server configured"
        echo "    Add more servers with: $0 add-server -c /path/to/other.conf"
        return 1
    fi
    
    local CURRENT=1
    [ -f "$MULLVAD_STATE_FILE" ] && CURRENT=$(grep "^ACTIVE=" "$MULLVAD_STATE_FILE" 2>/dev/null | cut -d'=' -f2)
    [ -z "$CURRENT" ] && CURRENT=1
    
    local NEXT=$((CURRENT % TOTAL + 1))
    local SERVER_FILE="${MULLVAD_CONF_DIR}/server_${NEXT}.conf"
    
    if [ ! -f "$SERVER_FILE" ]; then
        log_err "Server file not found: $SERVER_FILE"
        return 1
    fi
    
    . "$SERVER_FILE"
    log_info "Switching from #$CURRENT to #$NEXT: $HOST:$PORT ($CONF_NAME)"
    
    # Update WireGuard peer
    wg set "$WG_INTERFACE" peer "$PUBKEY" endpoint "$HOST:$PORT" 2>/dev/null || {
        # Fallback: UCI update
        uci set network."${WG_INTERFACE}_peer".endpoint_host="$HOST"
        uci set network."${WG_INTERFACE}_peer".endpoint_port="$PORT"
        uci commit network
        ifdown "$WG_INTERFACE" && sleep 2 && ifup "$WG_INTERFACE"
    }
    
    echo "ACTIVE=$NEXT" > "$MULLVAD_STATE_FILE"
    echo "HOST=$HOST" >> "$MULLVAD_STATE_FILE"
    echo "CONF_NAME=$CONF_NAME" >> "$MULLVAD_STATE_FILE"
    echo "ROTATED=$(date -Iseconds)" >> "$MULLVAD_STATE_FILE"
    
    log_ok "Rotated to server #$NEXT"
    sleep 3
    show_status
}

# ─────────────────────────────────────────────────────────────────────────────
# DISABLE / REMOVE
# ─────────────────────────────────────────────────────────────────────────────
disable_vpn() {
    log_info "Disabling Mullvad VPN..."
    ifdown "$WG_INTERFACE" 2>/dev/null || true
    log_ok "VPN disabled (config preserved)"
    echo "    Re-enable: ifup $WG_INTERFACE"
}

remove_config() {
    log_warn "Removing all Mullvad configuration..."
    
    # Stop services
    ifdown "$WG_INTERFACE" 2>/dev/null || true
    [ -x "$FAILOVER_INIT" ] && "$FAILOVER_INIT" stop 2>/dev/null && "$FAILOVER_INIT" disable 2>/dev/null
    pkill -f "ci5-mullvad-failover" 2>/dev/null || true
    
    # Remove UCI config
    uci -q delete network."$WG_INTERFACE" 2>/dev/null || true
    uci -q delete network."${WG_INTERFACE}_peer" 2>/dev/null || true
    uci commit network
    
    # Clean up ip rules
    ip rule del lookup vpn_mullvad 2>/dev/null || true
    ip rule del fwmark "$WG_FWMARK" 2>/dev/null || true
    ip route flush table vpn_mullvad 2>/dev/null || true
    
    # Remove files
    rm -rf "$MULLVAD_CONF_DIR" 2>/dev/null || true
    rm -f "$FAILOVER_BIN" "$FAILOVER_INIT" 2>/dev/null || true
    rm -f /etc/hotplug.d/iface/90-mullvad-vlan-routing 2>/dev/null || true
    rm -f /etc/hotplug.d/iface/99-mullvad-killswitch 2>/dev/null || true
    rm -f /etc/firewall.mullvad_vlan* 2>/dev/null || true
    rm -f "$MULLVAD_STATE_FILE" "$MULLVAD_HEALTH_LOG" 2>/dev/null || true
    
    # Reload
    /etc/init.d/network reload >/dev/null 2>&1 || true
    /etc/init.d/firewall reload >/dev/null 2>&1 || true
    
    log_ok "Mullvad configuration removed"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
main() {
    local CMD="${1:-}"
    shift 2>/dev/null || true
    
    # Parse global options
    local PRIMARY_CONF=""
    local ADDITIONAL_CONFS=""
    local ENABLE_KILLSWITCH=0
    local ENABLE_FAILOVER=0
    ROUTED_VLANS=""
    
    while [ $# -gt 0 ]; do
        case "$1" in
            -c|--config)
                PRIMARY_CONF="$2"
                shift 2
                ;;
            -a|--add)
                ADDITIONAL_CONFS="$ADDITIONAL_CONFS $2"
                shift 2
                ;;
            -v|--vlan)
                ROUTED_VLANS="$ROUTED_VLANS $2"
                shift 2
                ;;
            -k|--killswitch)
                ENABLE_KILLSWITCH=1
                shift
                ;;
            -f|--failover)
                ENABLE_FAILOVER=1
                shift
                ;;
            -i|--interface)
                WG_INTERFACE="$2"
                shift 2
                ;;
            -h|--help)
                usage
                ;;
            *)
                shift
                ;;
        esac
    done
    
    # Trim whitespace
    ROUTED_VLANS=$(echo "$ROUTED_VLANS" | xargs)
    ADDITIONAL_CONFS=$(echo "$ADDITIONAL_CONFS" | xargs)
    
    echo ""
    echo "┌──────────────────────────────────────────────────────────────────┐"
    echo "│  Ci5 Mullvad WireGuard (v7.4-RC-1)                               │"
    echo "└──────────────────────────────────────────────────────────────────┘"
    echo ""
    
    case "$CMD" in
        setup)
            if [ -z "$PRIMARY_CONF" ]; then
                log_err "No config file specified"
                echo "    Usage: $0 setup -c /path/to/mullvad.conf"
                exit 1
            fi
            
            check_deps
            init_storage
            
            # Parse and save primary config
            log_info "Adding primary server..."
            add_server_config "$PRIMARY_CONF"
            
            # Add additional servers
            for CONF in $ADDITIONAL_CONFS; do
                add_server_config "$CONF"
            done
            
            # Load primary config for WireGuard setup
            . "${MULLVAD_CONF_DIR}/server_1.conf"
            VPN_IPV4="$IPV4"
            VPN_IPV4_MASK="$IPV4_MASK"
            
            # Configure WireGuard
            configure_wireguard "${MULLVAD_CONF_DIR}/server_1.conf"
            
            # Configure VLAN routing if specified
            [ -n "$ROUTED_VLANS" ] && configure_vlan_routing
            
            # Configure firewall
            configure_firewall
            
            # Configure kill switch if requested
            [ "$ENABLE_KILLSWITCH" -eq 1 ] && configure_killswitch
            
            # Apply
            apply_config
            
            # Install failover daemon if requested or if multiple servers
            local SERVER_COUNT=$(ls -1 "$MULLVAD_CONF_DIR"/server_*.conf 2>/dev/null | wc -l)
            if [ "$ENABLE_FAILOVER" -eq 1 ] || [ "$SERVER_COUNT" -gt 1 ]; then
                install_failover_daemon
            fi
            
            # Save initial state
            echo "ACTIVE=1" > "$MULLVAD_STATE_FILE"
            . "${MULLVAD_CONF_DIR}/server_1.conf"
            echo "HOST=$HOST" >> "$MULLVAD_STATE_FILE"
            echo "CONF_NAME=$CONF_NAME" >> "$MULLVAD_STATE_FILE"
            
            echo ""
            show_status
            
            echo ""
            log_ok "Mullvad setup complete!"
            echo ""
            if [ -n "$ROUTED_VLANS" ]; then
                echo "    VLANs routed via VPN: $ROUTED_VLANS"
                echo "    Other traffic (including $CI5_LAN_SUBNET): WAN"
            else
                echo "    Routing: ALL traffic via VPN"
            fi
            [ "$ENABLE_KILLSWITCH" -eq 1 ] && echo "    Kill switch:  ENABLED"
            [ "$SERVER_COUNT" -gt 1 ] && echo "    Failover:     ENABLED ($SERVER_COUNT servers)"
            echo ""
            ;;
            
        add-server)
            if [ -z "$PRIMARY_CONF" ]; then
                log_err "No config file specified"
                echo "    Usage: $0 add-server -c /path/to/mullvad.conf"
                exit 1
            fi
            init_storage
            add_server_config "$PRIMARY_CONF"
            list_servers
            
            # Restart failover daemon if running
            if pgrep -f "ci5-mullvad-failover" >/dev/null 2>&1; then
                log_info "Restarting failover daemon to pick up new server..."
                "$FAILOVER_INIT" restart 2>/dev/null || true
            fi
            ;;
            
        list-servers|list)
            list_servers
            ;;
            
        rotate)
            manual_rotate
            ;;
            
        status)
            show_status
            ;;
            
        disable)
            disable_vpn
            ;;
            
        remove)
            remove_config
            ;;
            
        -h|--help|help|"")
            usage
            ;;
            
        *)
            log_err "Unknown command: $CMD"
            usage
            ;;
    esac
}

main "$@"
