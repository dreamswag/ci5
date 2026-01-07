#!/bin/sh
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  CI5 PHOENIX — RECOMMENDED STACK INSTALLER                                ║
# ║  Full router + security + monitoring suite with DNS failover              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

set -e

CI5_VERSION="3.0.0"
SOUL_FILE="/etc/ci5/soul.conf"
LOG_FILE="/var/log/ci5-install-$(date +%Y%m%d_%H%M%S).log"

# Colors
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'

# Logging
mkdir -p "$(dirname "$LOG_FILE")"
: > "$LOG_FILE"
_log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"; }

info() { printf "${G}[✓]${N} %s\n" "$1"; _log "[INFO] $1"; }
warn() { printf "${Y}[!]${N} %s\n" "$1"; _log "[WARN] $1"; }
err()  { printf "${R}[✗]${N} %s\n" "$1"; _log "[ERROR] $1"; }
step() { printf "\n${B}═══ %s ═══${N}\n\n" "$1"; _log "[STEP] $1"; }

# ─────────────────────────────────────────────────────────────────────────────
# ARGUMENT PARSING & SOUL LOADING
# ─────────────────────────────────────────────────────────────────────────────
FROM_SOUL=0
for arg in "$@"; do
    case "$arg" in
        --from-soul) FROM_SOUL=1 ;;
    esac
done

load_soul() {
    if [ -f "$SOUL_FILE" ]; then
        . "$SOUL_FILE"
        info "Loaded configuration from soul"
        return 0
    fi
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# HARDWARE VERIFICATION
# ─────────────────────────────────────────────────────────────────────────────
check_hardware() {
    if ! grep -q "Raspberry Pi 5" /proc/cpuinfo 2>/dev/null; then
        err "CI5 requires BCM2712 (Pi 5) hardware."
        exit 1
    fi

    RAM_MB=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
    info "Hardware: Raspberry Pi 5 (${RAM_MB}MB RAM)"

    if [ "$RAM_MB" -lt 4000 ]; then
        warn "Low RAM detected — ntopng will be skipped"
        SKIP_NTOPNG=1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# PLATFORM DETECTION
# ─────────────────────────────────────────────────────────────────────────────
detect_platform() {
    if [ -f /etc/openwrt_release ]; then
        PLATFORM="openwrt"
        PKG_UPDATE="opkg update"
        PKG_INSTALL="opkg install"
        info "Platform: OpenWrt"
    else
        err "CI5 Recommended requires OpenWrt"
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# ROLLBACK SYSTEM
# ─────────────────────────────────────────────────────────────────────────────
BACKUP_DIR="/root/.ci5-backup-$(date +%Y%m%d%H%M%S)"
ROLLBACK_AVAILABLE=0

init_rollback() {
    mkdir -p "$BACKUP_DIR"

    [ -d /etc/config ] && cp -r /etc/config "$BACKUP_DIR/"
    [ -f /etc/sysctl.conf ] && cp /etc/sysctl.conf "$BACKUP_DIR/"
    [ -d /etc/sysctl.d ] && cp -r /etc/sysctl.d "$BACKUP_DIR/"

    if command -v docker >/dev/null 2>&1; then
        docker ps -a --format '{{.Names}}' > "$BACKUP_DIR/docker-containers.txt" 2>/dev/null || true
    fi

    ROLLBACK_AVAILABLE=1
    info "Rollback checkpoint: $BACKUP_DIR"
}

execute_rollback() {
    [ "$ROLLBACK_AVAILABLE" -ne 1 ] && { err "No rollback checkpoint"; return 1; }

    warn "Executing rollback..."

    [ -d "$BACKUP_DIR/config" ] && cp -r "$BACKUP_DIR/config" /etc/
    [ -f "$BACKUP_DIR/sysctl.conf" ] && cp "$BACKUP_DIR/sysctl.conf" /etc/
    [ -d "$BACKUP_DIR/sysctl.d" ] && cp -r "$BACKUP_DIR/sysctl.d" /etc/

    sysctl --system >/dev/null 2>&1 || true
    /etc/init.d/network reload 2>/dev/null || true

    info "Rollback complete"
}

on_error() {
    err "Installation failed!"
    if [ "$FROM_SOUL" -eq 1 ]; then
        warn "Automatic rollback skipped (first boot mode)"
    else
        printf "Execute rollback? [Y/n]: "
        read -r ans
        case "$ans" in
            n|N) warn "Rollback skipped" ;;
            *)   execute_rollback ;;
        esac
    fi
    exit 1
}

trap on_error ERR

# ─────────────────────────────────────────────────────────────────────────────
# WAN CONFIGURATION (from soul)
# ─────────────────────────────────────────────────────────────────────────────
configure_wan() {
    step "CONFIGURING WAN CONNECTION"

    # Determine WAN interface
    WAN_IF="${WAN_IF:-eth1}"

    # Apply VLAN if specified
    if [ -n "$WAN_VLAN" ]; then
        WAN_DEVICE="${WAN_IF}.${WAN_VLAN}"
        info "WAN VLAN: $WAN_VLAN"
    else
        WAN_DEVICE="$WAN_IF"
    fi

    # Configure WAN based on protocol
    uci set network.wan.device="$WAN_DEVICE"
    uci set network.wan.proto="$WAN_PROTO"

    case "$WAN_PROTO" in
        pppoe)
            uci set network.wan.username="$WAN_USER"
            uci set network.wan.password="$WAN_PASS"
            info "WAN: PPPoE ($WAN_USER)"
            ;;
        static)
            uci set network.wan.ipaddr="$WAN_IPADDR"
            uci set network.wan.netmask="$WAN_NETMASK"
            uci set network.wan.gateway="$WAN_GATEWAY"
            [ -n "$WAN_DNS" ] && uci set network.wan.dns="$WAN_DNS"
            info "WAN: Static ($WAN_IPADDR)"
            ;;
        dhcp|*)
            info "WAN: DHCP"
            ;;
    esac

    uci commit network
}

# ─────────────────────────────────────────────────────────────────────────────
# CORE TUNING (NIC-profile aware)
# ─────────────────────────────────────────────────────────────────────────────
install_core_tuning() {
    step "APPLYING CORE TUNING (${NIC_PROFILE:-usb3} profile)"

    # Download NIC tuning module
    CI5_RAW="${CI5_RAW:-https://raw.githubusercontent.com/dreamswag/ci5/main}"
    mkdir -p /opt/ci5/lib

    if curl -fsSL "${CI5_RAW}/core/system/nic-tuning.sh" -o /opt/ci5/lib/nic-tuning.sh 2>/dev/null; then
        chmod +x /opt/ci5/lib/nic-tuning.sh
        # Export soul config vars
        export NIC_PROFILE WAN_IF LAN_IF APLESS_MODE PCIE_DRIVER
        # Apply NIC-profile-specific tuning
        /opt/ci5/lib/nic-tuning.sh apply
        # Create convenience command
        ln -sf /opt/ci5/lib/nic-tuning.sh /usr/bin/ci5-nic-tune 2>/dev/null || true
        info "Applied ${NIC_PROFILE:-usb3} NIC tuning profile"
    else
        # Fallback: embedded basic tuning
        warn "NIC tuning module unavailable, using fallback"
        cat > /etc/sysctl.d/99-ci5-tuning.conf << 'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.netfilter.nf_conntrack_max=131072
net.ipv4.ip_forward=1
net.ipv4.conf.all.forwarding=1
net.ipv6.conf.all.forwarding=1
net.ipv4.tcp_fin_timeout=30
net.ipv4.tcp_tw_reuse=1
net.core.netdev_max_backlog=5000
EOF
        sysctl --system >/dev/null 2>&1
        for dev in eth0 eth1 eth2; do
            [ -d "/sys/class/net/$dev" ] || continue
            ethtool -K "$dev" tso off gso off gro off 2>/dev/null || true
            ethtool -A "$dev" rx off tx off 2>/dev/null || true
        done
        info "Applied fallback tuning (BBR + 16MB buffers)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# VLAN SEGMENTATION
# ─────────────────────────────────────────────────────────────────────────────
install_vlans() {
    step "CONFIGURING VLAN SEGMENTATION"

    LAN_IF="${LAN_IF:-eth0}"

    # VLAN 10: Trusted
    uci -q delete network.vlan10 2>/dev/null || true
    uci set network.vlan10=interface
    uci set network.vlan10.proto='static'
    uci set network.vlan10.device="${LAN_IF}.10"
    uci set network.vlan10.ipaddr='192.168.10.1'
    uci set network.vlan10.netmask='255.255.255.0'

    # VLAN 20: Work
    uci -q delete network.vlan20 2>/dev/null || true
    uci set network.vlan20=interface
    uci set network.vlan20.proto='static'
    uci set network.vlan20.device="${LAN_IF}.20"
    uci set network.vlan20.ipaddr='192.168.20.1'
    uci set network.vlan20.netmask='255.255.255.0'

    # VLAN 30: IoT
    uci -q delete network.vlan30 2>/dev/null || true
    uci set network.vlan30=interface
    uci set network.vlan30.proto='static'
    uci set network.vlan30.device="${LAN_IF}.30"
    uci set network.vlan30.ipaddr='192.168.30.1'
    uci set network.vlan30.netmask='255.255.255.0'

    # VLAN 40: Guest
    uci -q delete network.vlan40 2>/dev/null || true
    uci set network.vlan40=interface
    uci set network.vlan40.proto='static'
    uci set network.vlan40.device="${LAN_IF}.40"
    uci set network.vlan40.ipaddr='192.168.40.1'
    uci set network.vlan40.netmask='255.255.255.0'

    uci commit network
    info "VLANs: 10 (Trusted), 20 (Work), 30 (IoT), 40 (Guest)"
}

# ─────────────────────────────────────────────────────────────────────────────
# FIREWALL
# ─────────────────────────────────────────────────────────────────────────────
install_firewall() {
    step "CONFIGURING FIREWALL ZONES"

    # Default policies
    uci set firewall.@defaults[0].input='REJECT'
    uci set firewall.@defaults[0].output='ACCEPT'
    uci set firewall.@defaults[0].forward='REJECT'
    uci set firewall.@defaults[0].synflood_protect='1'

    # Add VLANs to LAN zone
    uci -q del firewall.@zone[0].network 2>/dev/null || true
    uci add_list firewall.@zone[0].network='lan'
    uci add_list firewall.@zone[0].network='vlan10'
    uci add_list firewall.@zone[0].network='vlan20'

    # IoT Zone (internet only)
    uci -q delete firewall.iot 2>/dev/null || true
    uci add firewall zone
    uci set firewall.@zone[-1].name='iot'
    uci set firewall.@zone[-1].input='REJECT'
    uci set firewall.@zone[-1].output='ACCEPT'
    uci set firewall.@zone[-1].forward='REJECT'
    uci add_list firewall.@zone[-1].network='vlan30'

    # Guest Zone (isolated)
    uci -q delete firewall.guest 2>/dev/null || true
    uci add firewall zone
    uci set firewall.@zone[-1].name='guest'
    uci set firewall.@zone[-1].input='REJECT'
    uci set firewall.@zone[-1].output='ACCEPT'
    uci set firewall.@zone[-1].forward='REJECT'
    uci add_list firewall.@zone[-1].network='vlan40'

    # Zone forwardings
    for zone in lan iot guest; do
        uci add firewall forwarding
        uci set firewall.@forwarding[-1].src="$zone"
        uci set firewall.@forwarding[-1].dest='wan'
    done

    # Allow DHCP/DNS for restricted zones
    for zone in iot guest; do
        uci add firewall rule
        uci set firewall.@rule[-1].name="Allow-DHCP-$zone"
        uci set firewall.@rule[-1].src="$zone"
        uci set firewall.@rule[-1].proto='udp'
        uci set firewall.@rule[-1].dest_port='67'
        uci set firewall.@rule[-1].target='ACCEPT'

        uci add firewall rule
        uci set firewall.@rule[-1].name="Allow-DNS-$zone"
        uci set firewall.@rule[-1].src="$zone"
        uci set firewall.@rule[-1].proto='tcp udp'
        uci set firewall.@rule[-1].dest_port='53'
        uci set firewall.@rule[-1].target='ACCEPT'
    done

    uci commit firewall
    /etc/init.d/firewall reload
    info "Firewall zones configured"
}

# ─────────────────────────────────────────────────────────────────────────────
# SQM/CAKE
# ─────────────────────────────────────────────────────────────────────────────
install_sqm() {
    step "INSTALLING SQM/CAKE"

    opkg update >/dev/null 2>&1
    opkg install sqm-scripts luci-app-sqm >/dev/null 2>&1

    # Pre-configure SQM with soul overhead settings
    uci -q delete sqm.wan 2>/dev/null || true
    uci set sqm.wan=queue
    uci set sqm.wan.enabled='0'  # Disabled until speed test
    uci set sqm.wan.interface='wan'
    uci set sqm.wan.qdisc='cake'
    uci set sqm.wan.script='piece_of_cake.qos'
    uci set sqm.wan.linklayer="${LINK_LAYER:-ethernet}"
    uci set sqm.wan.overhead="${OVERHEAD:-18}"
    uci commit sqm

    info "SQM/CAKE installed (run speed test to enable)"
}

# ─────────────────────────────────────────────────────────────────────────────
# UNBOUND (Native - DNS failsafe)
# ─────────────────────────────────────────────────────────────────────────────
install_unbound() {
    step "INSTALLING UNBOUND (PORT 5335 - UPSTREAM FOR ADGUARD)"

    opkg install unbound-daemon unbound-control >/dev/null 2>&1 || \
        opkg install unbound-daemon-heavy >/dev/null 2>&1 || {
            err "Failed to install Unbound"
            return 1
        }

    # Configure on port 5335 (AdGuard upstream)
    cat > /etc/config/unbound << 'EOF'
config unbound 'ub_main'
    option enabled '1'
    option listen_port '5335'
    option localservice '1'
    option interface_auto '1'
    option domain 'lan'
    option edns_size '1232'
    option hide_binddata '1'
    option num_threads '2'
    option rebind_protection '1'
    option recursion 'default'
    option ttl_min '120'
    option validator '0'
    list iface_trig 'lan'
    list iface_trig 'wan'
EOF

    /etc/init.d/unbound enable
    /etc/init.d/unbound restart

    sleep 2
    if nslookup -port=5335 google.com 127.0.0.1 >/dev/null 2>&1; then
        info "Unbound operational on port 5335"
    else
        warn "Unbound may need time to initialize"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# DOCKER
# ─────────────────────────────────────────────────────────────────────────────
install_docker() {
    step "INSTALLING DOCKER"

    if ! command -v docker >/dev/null 2>&1; then
        opkg install docker dockerd docker-compose >/dev/null 2>&1
        /etc/init.d/dockerd enable
        /etc/init.d/dockerd start
        sleep 5
    fi
    info "Docker ready"
}

# ─────────────────────────────────────────────────────────────────────────────
# DOCKER STACK (AdGuard + Security)
# ─────────────────────────────────────────────────────────────────────────────
install_docker_stack() {
    step "DEPLOYING DOCKER CONTAINERS"

    # Create docker-compose configuration
    mkdir -p /opt/ci5/docker
    cat > /opt/ci5/docker/docker-compose.yml << 'COMPOSE'
version: '3.8'

services:
  adguard:
    image: adguard/adguardhome:latest
    container_name: adguardhome
    restart: unless-stopped
    network_mode: host
    volumes:
      - /opt/ci5/adguard/work:/opt/adguardhome/work
      - /opt/ci5/adguard/conf:/opt/adguardhome/conf
    cap_add:
      - NET_ADMIN

  suricata:
    image: jasonish/suricata:latest
    container_name: suricata
    restart: unless-stopped
    network_mode: host
    cap_add:
      - NET_ADMIN
      - SYS_NICE
    volumes:
      - /opt/ci5/suricata/logs:/var/log/suricata
      - /opt/ci5/suricata/rules:/var/lib/suricata/rules
    command: -i br-lan
    profiles:
      - full

  crowdsec:
    image: crowdsecurity/crowdsec:latest
    container_name: crowdsec
    restart: unless-stopped
    environment:
      - COLLECTIONS=crowdsecurity/linux crowdsecurity/iptables
    volumes:
      - /opt/ci5/crowdsec/data:/var/lib/crowdsec/data
      - /opt/ci5/crowdsec/config:/etc/crowdsec
      - /var/log:/var/log:ro
    ports:
      - "127.0.0.1:8080:8080"
    profiles:
      - full

  ntopng:
    image: ntop/ntopng:stable
    container_name: ntopng
    restart: unless-stopped
    network_mode: host
    volumes:
      - /opt/ci5/ntopng:/var/lib/ntopng
    command: --community -i br-lan -w 3001
    profiles:
      - monitoring
COMPOSE

    # Create directories
    mkdir -p /opt/ci5/adguard/{work,conf}
    mkdir -p /opt/ci5/suricata/{logs,rules}
    mkdir -p /opt/ci5/crowdsec/{data,config}
    mkdir -p /opt/ci5/ntopng

    cd /opt/ci5/docker

    # Pull and start AdGuard (always)
    info "Starting AdGuard Home..."
    docker compose up -d adguard 2>/dev/null || docker-compose up -d adguard

    # Configure AdGuard to use Unbound as upstream
    sleep 5
    if [ ! -f /opt/ci5/adguard/conf/AdGuardHome.yaml ]; then
        # Wait for initial config generation
        sleep 10
    fi

    # Start full security stack if enough RAM
    if [ "${SKIP_NTOPNG:-0}" -ne 1 ]; then
        info "Starting security stack (Suricata, CrowdSec, ntopng)..."
        docker compose --profile full --profile monitoring up -d 2>/dev/null || \
            docker-compose --profile full --profile monitoring up -d
    else
        info "Starting security stack (Suricata, CrowdSec)..."
        docker compose --profile full up -d 2>/dev/null || \
            docker-compose --profile full up -d
    fi

    # Verify AdGuard
    sleep 3
    if docker ps | grep -q adguardhome; then
        info "AdGuard Home running (port 53, UI on 3000)"
    else
        warn "AdGuard may need manual start"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# DNS FAILOVER WATCHDOG
# ─────────────────────────────────────────────────────────────────────────────
install_dns_failover() {
    step "INSTALLING DNS FAILOVER WATCHDOG"

    cat > /etc/init.d/ci5-dns-failover << 'INITSCRIPT'
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/ci5-dns-failover
    procd_set_param respawn 3600 5 5
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
INITSCRIPT
    chmod +x /etc/init.d/ci5-dns-failover

    cat > /usr/bin/ci5-dns-failover << 'DAEMON'
#!/bin/sh
# CI5 DNS Failover: If AdGuard dies, switch Unbound to port 53

MODE="primary"
FAIL_COUNT=0

log() { logger -t ci5-dns-failover "$1"; }

test_adguard() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qw "adguardhome" && \
    nslookup -timeout=2 google.com 127.0.0.1 >/dev/null 2>&1
}

switch_to_failover() {
    log "FAILOVER: AdGuard down, Unbound taking port 53"
    uci set unbound.ub_main.listen_port='53'
    uci commit unbound
    /etc/init.d/unbound restart
    MODE="failover"
}

switch_to_primary() {
    log "RECOVERY: AdGuard back, Unbound returning to port 5335"
    uci set unbound.ub_main.listen_port='5335'
    uci commit unbound
    /etc/init.d/unbound restart
    MODE="primary"
}

log "DNS Failover started"

while true; do
    if test_adguard; then
        FAIL_COUNT=0
        [ "$MODE" = "failover" ] && switch_to_primary
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        [ "$FAIL_COUNT" -ge 3 ] && [ "$MODE" = "primary" ] && switch_to_failover
    fi
    sleep 10
done
DAEMON
    chmod +x /usr/bin/ci5-dns-failover

    /etc/init.d/ci5-dns-failover enable
    /etc/init.d/ci5-dns-failover start

    info "DNS failover watchdog installed"
}

# ─────────────────────────────────────────────────────────────────────────────
# DHCP POOLS
# ─────────────────────────────────────────────────────────────────────────────
install_dhcp_pools() {
    step "CONFIGURING DHCP POOLS"

    for vlan in 10 20 30 40; do
        uci -q delete "dhcp.vlan${vlan}" 2>/dev/null || true
        uci set "dhcp.vlan${vlan}=dhcp"
        uci set "dhcp.vlan${vlan}.interface=vlan${vlan}"
        uci set "dhcp.vlan${vlan}.start=100"
        uci set "dhcp.vlan${vlan}.limit=100"
        uci set "dhcp.vlan${vlan}.leasetime=12h"
    done

    # Point DHCP to AdGuard for DNS
    uci set dhcp.@dnsmasq[0].port='0'  # Disable dnsmasq DNS
    uci set dhcp.@dnsmasq[0].localuse='0'

    uci commit dhcp
    /etc/init.d/dnsmasq restart

    info "DHCP pools configured for VLANs 10-40"
}

# ─────────────────────────────────────────────────────────────────────────────
# FINALIZE
# ─────────────────────────────────────────────────────────────────────────────
finalize() {
    step "FINALIZING"

    /etc/init.d/network reload 2>/dev/null || true
    /etc/init.d/firewall reload 2>/dev/null || true

    # Mark installation complete
    echo "$CI5_VERSION" > /etc/ci5/version
    date -Iseconds > /etc/ci5/installed

    step "INSTALLATION COMPLETE"

    cat << 'EOF'

    ╔═══════════════════════════════════════════════════════════════════╗
    ║  CI5 RECOMMENDED STACK INSTALLED                                  ║
    ╠═══════════════════════════════════════════════════════════════════╣
    ║                                                                   ║
    ║  NETWORK:                                                         ║
    ║    • BBR + 16MB buffers + SQM/CAKE                                ║
    ║    • VLANs: 10 (Trusted), 20 (Work), 30 (IoT), 40 (Guest)         ║
    ║    • Hardened firewall zones                                      ║
    ║                                                                   ║
    ║  DNS (with failover):                                             ║
    ║    Primary:  LAN → AdGuard (:53) → Unbound (:5335) → Internet     ║
    ║    Failover: LAN → Unbound (:53) → Internet                       ║
    ║                                                                   ║
    ║  CONTAINERS:                                                      ║
    ║    • AdGuard Home (DNS filtering, UI on :3000)                    ║
    ║    • Suricata IDS                                                 ║
    ║    • CrowdSec (threat intelligence)                               ║
    ║    • ntopng (traffic analysis, UI on :3001)                       ║
    ║                                                                   ║
    ║  WEB INTERFACES:                                                  ║
    ║    • LuCI:    http://192.168.1.1                                  ║
    ║    • AdGuard: http://192.168.1.1:3000                             ║
    ║    • ntopng:  http://192.168.1.1:3001                             ║
    ║                                                                   ║
    ║  NEXT STEPS:                                                      ║
    ║    1. Run speed test: curl -sL ci5.run | sh -s fast               ║
    ║    2. Configure AdGuard upstream: 127.0.0.1:5335                  ║
    ║    3. Configure AP VLANs to match SSIDs                           ║
    ║                                                                   ║
    ╚═══════════════════════════════════════════════════════════════════╝

EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
main() {
    clear
    printf "${B}CI5 PHOENIX — Recommended Stack Installer${N}\n"
    printf "═══════════════════════════════════════════════════════════════\n\n"

    # Load soul config if available
    if [ "$FROM_SOUL" -eq 1 ]; then
        load_soul || warn "No soul config found, using defaults"
    else
        # Interactive mode - confirm
        printf "This will install the full CI5 stack:\n"
        printf "  • VLANs + Firewall + SQM/CAKE\n"
        printf "  • AdGuard + Unbound (with DNS failover)\n"
        printf "  • Suricata IDS + CrowdSec + ntopng\n\n"
        printf "Continue? [Y/n]: "
        read -r ans
        case "$ans" in
            n|N) echo "Aborted."; exit 0 ;;
        esac

        # Try to load existing soul for WAN settings
        load_soul 2>/dev/null || true
    fi

    check_hardware
    detect_platform
    init_rollback

    # Configure WAN from soul
    [ -n "$WAN_PROTO" ] && configure_wan

    install_core_tuning
    install_vlans
    install_firewall
    install_dhcp_pools
    install_sqm
    install_unbound
    install_docker
    install_docker_stack
    install_dns_failover

    finalize

    trap - ERR
}

main "$@"
