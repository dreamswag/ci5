#!/bin/sh
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  CI5 PHOENIX — RECOMMENDED STACK INSTALLER                                ║
# ║  Full router + security + monitoring suite                                ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

set -e

CI5_BASE="https://ci5.run"
CI5_VERSION="1.0.0"
LOG_FILE="/var/log/ci5-install-$(date +%Y%m%d_%H%M%S).log"

# Colors
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'

# Logging
exec > >(tee -a "$LOG_FILE") 2>&1

info() { printf "${G}[✓]${N} %s\n" "$1"; }
warn() { printf "${Y}[!]${N} %s\n" "$1"; }
err()  { printf "${R}[✗]${N} %s\n" "$1"; }
step() { printf "\n${B}═══ %s ═══${N}\n\n" "$1"; }

# ─────────────────────────────────────────────────────────────────────────────
# ROLLBACK SYSTEM
# ─────────────────────────────────────────────────────────────────────────────
BACKUP_DIR="/root/.ci5-backup-$(date +%Y%m%d%H%M%S)"
ROLLBACK_AVAILABLE=0

init_rollback() {
    mkdir -p "$BACKUP_DIR"
    
    # Backup critical configs
    [ -d /etc/config ] && cp -r /etc/config "$BACKUP_DIR/"
    [ -f /etc/sysctl.conf ] && cp /etc/sysctl.conf "$BACKUP_DIR/"
    [ -d /etc/sysctl.d ] && cp -r /etc/sysctl.d "$BACKUP_DIR/"
    
    # Record Docker state
    if command -v docker >/dev/null 2>&1; then
        docker ps -a --format '{{.Names}}' > "$BACKUP_DIR/docker-containers.txt" 2>/dev/null || true
    fi
    
    ROLLBACK_AVAILABLE=1
    info "Rollback checkpoint created: $BACKUP_DIR"
}

execute_rollback() {
    if [ "$ROLLBACK_AVAILABLE" -ne 1 ]; then
        err "No rollback checkpoint available"
        return 1
    fi
    
    warn "Executing rollback..."
    
    # Restore configs
    [ -d "$BACKUP_DIR/config" ] && cp -r "$BACKUP_DIR/config" /etc/
    [ -f "$BACKUP_DIR/sysctl.conf" ] && cp "$BACKUP_DIR/sysctl.conf" /etc/
    [ -d "$BACKUP_DIR/sysctl.d" ] && cp -r "$BACKUP_DIR/sysctl.d" /etc/
    
    # Remove new Docker containers
    if [ -f "$BACKUP_DIR/docker-containers.txt" ] && command -v docker >/dev/null 2>&1; then
        docker ps -a --format '{{.Names}}' | while read -r c; do
            grep -q "^${c}$" "$BACKUP_DIR/docker-containers.txt" || {
                docker stop "$c" 2>/dev/null || true
                docker rm "$c" 2>/dev/null || true
            }
        done
    fi
    
    # Reload
    sysctl --system >/dev/null 2>&1 || true
    [ -x /etc/init.d/network ] && /etc/init.d/network reload 2>/dev/null || true
    
    info "Rollback complete"
}

on_error() {
    err "Installation failed!"
    printf "Execute rollback? [Y/n]: "
    read -r ans
    case "$ans" in
        n|N) warn "Rollback skipped" ;;
        *)   execute_rollback ;;
    esac
    exit 1
}

trap on_error ERR

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
    elif [ -f /etc/arch-release ]; then
        PLATFORM="arch"
        PKG_UPDATE="pacman -Sy"
        PKG_INSTALL="pacman -S --noconfirm"
    else
        PLATFORM="unknown"
        warn "Unknown platform — some features may not work"
    fi
    
    info "Detected platform: $PLATFORM"
}

# ─────────────────────────────────────────────────────────────────────────────
# HARDWARE DETECTION
# ─────────────────────────────────────────────────────────────────────────────
detect_hardware() {
    # Detect Pi model
    if [ -f /proc/device-tree/model ]; then
        PI_MODEL=$(tr -d '\0' < /proc/device-tree/model)
        info "Hardware: $PI_MODEL"
    fi
    
    # Check RAM
    RAM_MB=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
    info "RAM: ${RAM_MB}MB"
    
    if [ "$RAM_MB" -lt 4000 ]; then
        warn "Low RAM detected — ntopng will be skipped"
        SKIP_NTOPNG=1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE: CORE NETWORK TUNING
# ─────────────────────────────────────────────────────────────────────────────
install_core_tuning() {
    step "CORE NETWORK TUNING"
    
    # Sysctl tuning
    cat > /etc/sysctl.d/99-ci5-network.conf << 'SYSCTL'
# CI5 Network Performance Tuning
# TCP/UDP Buffer Sizes
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 1048576 16777216
net.ipv4.tcp_wmem = 4096 1048576 16777216
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# TCP Optimization
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1

# Congestion Control
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq

# Forwarding (router mode)
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# Conntrack
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 7200

# Neighbor table
net.ipv4.neigh.default.gc_thresh1 = 1024
net.ipv4.neigh.default.gc_thresh2 = 4096
net.ipv4.neigh.default.gc_thresh3 = 8192
SYSCTL
    
    sysctl --system >/dev/null 2>&1
    info "Sysctl tuning applied"
    
    # IRQ Balancing for USB NICs
    cat > /usr/local/bin/ci5-irq-balance << 'IRQ'
#!/bin/sh
# CI5 IRQ Balancing for USB 3.0 NICs
for irq in $(grep -E 'xhci|usb' /proc/interrupts | cut -d: -f1 | tr -d ' '); do
    # Prefer CPU 2/3 on Pi5 (performance cores)
    echo 0c > /proc/irq/$irq/smp_affinity 2>/dev/null || true
done
IRQ
    chmod +x /usr/local/bin/ci5-irq-balance
    
    # Run on boot
    if [ -f /etc/rc.local ]; then
        grep -q 'ci5-irq-balance' /etc/rc.local || \
            sed -i '/^exit 0/i /usr/local/bin/ci5-irq-balance' /etc/rc.local
    else
        echo '#!/bin/sh' > /etc/rc.local
        echo '/usr/local/bin/ci5-irq-balance' >> /etc/rc.local
        echo 'exit 0' >> /etc/rc.local
        chmod +x /etc/rc.local
    fi
    
    /usr/local/bin/ci5-irq-balance
    info "IRQ balancing configured"
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE: SQM/QOS
# ─────────────────────────────────────────────────────────────────────────────
install_sqm() {
    step "SQM/QOS (BUFFERBLOAT FIX)"
    
    if [ "$PLATFORM" = "openwrt" ]; then
        $PKG_INSTALL sqm-scripts luci-app-sqm
        
        # Auto-detect WAN
        WAN_IF=$(uci get network.wan.device 2>/dev/null || echo "eth1")
        
        # Basic SQM config (user should tune speeds)
        uci batch << EOF
set sqm.wan=queue
set sqm.wan.enabled='1'
set sqm.wan.interface='$WAN_IF'
set sqm.wan.download='0'
set sqm.wan.upload='0'
set sqm.wan.qdisc='cake'
set sqm.wan.script='piece_of_cake.qos'
set sqm.wan.linklayer='ethernet'
set sqm.wan.overhead='44'
commit sqm
EOF
        /etc/init.d/sqm restart 2>/dev/null || true
        info "SQM installed — configure speeds via LuCI or 'uci set sqm.wan.download/upload'"
    else
        # Debian/other: install tc-based CAKE
        if [ "$PLATFORM" = "debian" ]; then
            $PKG_INSTALL iproute2
        fi
        
        # Create simple CAKE script
        cat > /usr/local/bin/ci5-sqm << 'SQM'
#!/bin/sh
# CI5 Simple CAKE SQM
# Edit WAN_IF and speeds as needed
WAN_IF="${1:-eth0}"
DOWN_MBPS="${2:-0}"
UP_MBPS="${3:-0}"

if [ "$DOWN_MBPS" -gt 0 ] && [ "$UP_MBPS" -gt 0 ]; then
    tc qdisc replace dev $WAN_IF root cake bandwidth ${DOWN_MBPS}mbit
    tc qdisc replace dev $WAN_IF ingress
    tc qdisc replace dev ifb0 root cake bandwidth ${UP_MBPS}mbit
    echo "SQM active: ${DOWN_MBPS}↓ ${UP_MBPS}↑ Mbps on $WAN_IF"
else
    echo "Usage: ci5-sqm <interface> <down_mbps> <up_mbps>"
fi
SQM
        chmod +x /usr/local/bin/ci5-sqm
        info "SQM script installed — run: ci5-sqm eth0 100 20"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE: DOCKER
# ─────────────────────────────────────────────────────────────────────────────
install_docker() {
    step "DOCKER ENGINE"
    
    if command -v docker >/dev/null 2>&1; then
        info "Docker already installed"
        return 0
    fi
    
    if [ "$PLATFORM" = "openwrt" ]; then
        $PKG_INSTALL dockerd docker-compose
        /etc/init.d/dockerd enable
        /etc/init.d/dockerd start
    elif [ "$PLATFORM" = "debian" ]; then
        curl -fsSL https://get.docker.com | sh
        systemctl enable docker
        systemctl start docker
    else
        warn "Manual Docker installation required for platform: $PLATFORM"
        return 1
    fi
    
    sleep 3
    docker --version && info "Docker installed"
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE: CI5 IDENTITY (HWID)
# ─────────────────────────────────────────────────────────────────────────────
init_identity() {
    step "CI5 HARDWARE IDENTITY"
    
    CI5_DIR="/etc/ci5"
    mkdir -p "$CI5_DIR"
    chmod 700 "$CI5_DIR"
    
    if [ -f "$CI5_DIR/.hwid" ]; then
        HWID=$(cat "$CI5_DIR/.hwid")
        info "Existing HWID: ${HWID:0:8}...${HWID: -8}"
        return 0
    fi
    
    # Detection priority: Pi serial > DMI UUID > MAC > random
    if [ -f /proc/cpuinfo ]; then
        SERIAL=$(grep -i "^Serial" /proc/cpuinfo 2>/dev/null | awk '{print $3}')
    fi
    
    if [ -z "$SERIAL" ] && [ -f /sys/class/dmi/id/product_uuid ]; then
        SERIAL=$(cat /sys/class/dmi/id/product_uuid 2>/dev/null)
    fi
    
    if [ -z "$SERIAL" ]; then
        for iface in eth0 end0 enp0s3 ens33 wlan0; do
            if [ -f "/sys/class/net/$iface/address" ]; then
                SERIAL=$(cat "/sys/class/net/$iface/address" | tr -d ':')
                break
            fi
        done
    fi
    
    if [ -z "$SERIAL" ]; then
        SERIAL=$(cat /proc/sys/kernel/random/uuid | tr -d '-')
        warn "No hardware serial found — using random UUID (will change on reinstall)"
    fi
    
    # Generate HWID
    HWID=$(printf '%s' "${SERIAL}:ci5-phoenix-v1" | sha256sum | cut -d' ' -f1)
    echo "$HWID" > "$CI5_DIR/.hwid"
    chmod 600 "$CI5_DIR/.hwid"
    
    info "HWID generated: ${HWID:0:8}...${HWID: -8}"
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE: SECURITY STACK
# ─────────────────────────────────────────────────────────────────────────────
install_security_stack() {
    step "SECURITY STACK"
    
    mkdir -p /opt/ci5/docker
    
    cat > /opt/ci5/docker/docker-compose.yml << 'COMPOSE'
version: '3.8'

networks:
  ci5_net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.30.0.0/24

services:
  # ─────────────────────────────────────────────────
  # SURICATA — IDS/IPS
  # ─────────────────────────────────────────────────
  suricata:
    image: jasonish/suricata:latest
    container_name: ci5-suricata
    network_mode: host
    cap_add:
      - NET_ADMIN
      - SYS_NICE
    volumes:
      - ./suricata/logs:/var/log/suricata
      - ./suricata/rules:/var/lib/suricata/rules
    command: -i eth0
    restart: unless-stopped

  # ─────────────────────────────────────────────────
  # CROWDSEC — Threat Intelligence
  # ─────────────────────────────────────────────────
  crowdsec:
    image: crowdsecurity/crowdsec:latest
    container_name: ci5-crowdsec
    networks:
      - ci5_net
    volumes:
      - ./crowdsec/config:/etc/crowdsec
      - ./crowdsec/data:/var/lib/crowdsec/data
      - /var/log:/var/log:ro
    environment:
      - COLLECTIONS=crowdsecurity/linux crowdsecurity/iptables crowdsecurity/sshd
    restart: unless-stopped

  # ─────────────────────────────────────────────────
  # ADGUARD HOME — DNS Filtering
  # ─────────────────────────────────────────────────
  adguard:
    image: adguard/adguardhome:latest
    container_name: ci5-adguard
    networks:
      ci5_net:
        ipv4_address: 172.30.0.53
    ports:
      - "53:53/tcp"
      - "53:53/udp"
      - "3000:3000/tcp"
    volumes:
      - ./adguard/work:/opt/adguardhome/work
      - ./adguard/conf:/opt/adguardhome/conf
    restart: unless-stopped

  # ─────────────────────────────────────────────────
  # UNBOUND — Local DNS Resolver + DoT
  # ─────────────────────────────────────────────────
  unbound:
    image: mvance/unbound:latest
    container_name: ci5-unbound
    networks:
      ci5_net:
        ipv4_address: 172.30.0.54
    volumes:
      - ./unbound:/opt/unbound/etc/unbound
    restart: unless-stopped

  # ─────────────────────────────────────────────────
  # REDIS — Backend for ntopng
  # ─────────────────────────────────────────────────
  redis:
    image: redis:alpine
    container_name: ci5-redis
    networks:
      - ci5_net
    volumes:
      - ./redis:/data
    restart: unless-stopped
    profiles:
      - monitoring

  # ─────────────────────────────────────────────────
  # NTOPNG — Traffic Analysis
  # ─────────────────────────────────────────────────
  ntopng:
    image: ntop/ntopng:stable
    container_name: ci5-ntopng
    network_mode: host
    depends_on:
      - redis
    volumes:
      - ./ntopng:/var/lib/ntopng
    command: --redis localhost:6379 -i eth0
    restart: unless-stopped
    profiles:
      - monitoring

  # ─────────────────────────────────────────────────
  # HOMEPAGE — Dashboard
  # ─────────────────────────────────────────────────
  homepage:
    image: ghcr.io/gethomepage/homepage:latest
    container_name: ci5-homepage
    networks:
      - ci5_net
    ports:
      - "80:3000"
    volumes:
      - ./homepage:/app/config
    restart: unless-stopped
COMPOSE
    
    info "Docker compose file created"
    
    # Create config directories
    mkdir -p /opt/ci5/docker/{suricata/{logs,rules},crowdsec/{config,data},adguard/{work,conf},unbound,redis,ntopng,homepage}
    
    # AdGuard initial config
    cat > /opt/ci5/docker/adguard/conf/AdGuardHome.yaml << 'ADGUARD'
bind_host: 0.0.0.0
bind_port: 3000
users:
  - name: admin
    password: "$2a$10$CHANGE_ON_FIRST_RUN"
dns:
  bind_hosts:
    - 0.0.0.0
  port: 53
  upstream_dns:
    - 172.30.0.54  # Local Unbound
  bootstrap_dns:
    - 1.1.1.1
filtering:
  filtering_enabled: true
  protection_enabled: true
ADGUARD
    
    # Homepage config
    cat > /opt/ci5/docker/homepage/services.yaml << 'HOMEPAGE'
---
- CI5 Services:
    - AdGuard:
        href: http://localhost:3000
        description: DNS Filtering
        icon: adguard-home.png
    - ntopng:
        href: http://localhost:3001
        description: Traffic Analysis
        icon: ntopng.png
    - Suricata:
        href: "#"
        description: IDS/IPS Running
        icon: suricata.png
HOMEPAGE
    
    # Start services
    cd /opt/ci5/docker
    docker compose pull
    
    if [ "$SKIP_NTOPNG" = "1" ]; then
        docker compose up -d suricata crowdsec adguard unbound homepage
        warn "ntopng skipped (low RAM)"
    else
        docker compose --profile monitoring up -d
    fi
    
    info "Security stack deployed"
}

# ─────────────────────────────────────────────────────────────────────────────
# MODULE: CI5 CLI
# ─────────────────────────────────────────────────────────────────────────────
install_cli() {
    step "CI5 CLI"
    
    mkdir -p /opt/ci5/bin
    
    curl -fsSL "https://raw.githubusercontent.com/dreamswag/ci5/main/tools/ci5-cli" -o /opt/ci5/bin/ci5
    chmod +x /opt/ci5/bin/ci5
    
    ln -sf /opt/ci5/bin/ci5 /usr/local/bin/ci5 2>/dev/null || \
    ln -sf /opt/ci5/bin/ci5 /usr/bin/ci5
    
    info "CI5 CLI installed — run 'ci5 help'"
}

# ─────────────────────────────────────────────────────────────────────────────
# FINALIZATION
# ─────────────────────────────────────────────────────────────────────────────
finalize() {
    step "INSTALLATION COMPLETE"
    
    HWID=$(cat /etc/ci5/.hwid 2>/dev/null || echo "N/A")
    
    cat << EOF

    ╔═══════════════════════════════════════════════════════════════════╗
    ║  ${G}✓ CI5 RECOMMENDED STACK INSTALLED${N}                               ║
    ╠═══════════════════════════════════════════════════════════════════╣
    ║                                                                   ║
    ║  HWID:     ${HWID:0:8}...${HWID: -8}                                        ║
    ║                                                                   ║
    ║  ACCESS POINTS:                                                   ║
    ║    Dashboard:  http://$(hostname -I | awk '{print $1}')                              ║
    ║    AdGuard:    http://$(hostname -I | awk '{print $1}'):3000                         ║
    ║    ntopng:     http://$(hostname -I | awk '{print $1}'):3001                         ║
    ║                                                                   ║
    ║  COMMANDS:                                                        ║
    ║    ci5 status          Show service status                        ║
    ║    ci5 link            Link GitHub for forums (optional)          ║
    ║    ci5 cork install X  Install additional containers              ║
    ║                                                                   ║
    ║  LOG: $LOG_FILE                                                   ║
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
    printf "═══════════════════════════════════════════════════\n\n"
    
    detect_platform
    detect_hardware
    init_rollback
    
    install_core_tuning
    install_sqm
    install_docker
    init_identity
    install_security_stack
    install_cli
    
    finalize
    
    trap - ERR
}

main "$@"
