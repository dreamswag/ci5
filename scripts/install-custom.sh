#!/bin/sh
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  CI5 PHOENIX — CUSTOM INSTALLER                                           ║
# ║  Pick exactly which components to install                                 ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

set -e

CI5_BASE="https://ci5.run"
CI5_VERSION="1.0.0"

# Colors
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'; DIM='\033[2m'

# ─────────────────────────────────────────────────────────────────────────────
# COMPONENT STATE (0=off, 1=on)
# ─────────────────────────────────────────────────────────────────────────────
# CORE (always on)
OPT_SYSCTL=1
OPT_SQM=1

# SECURITY
OPT_SURICATA=0
OPT_CROWDSEC=0
OPT_FIREWALL=0

# DNS
OPT_UNBOUND=0
OPT_ADGUARD=0

# MONITORING
OPT_NTOPNG=0
OPT_HOMEPAGE=0

# VPN
OPT_WIREGUARD=0
OPT_OPENVPN=0
OPT_CAPTIVE=0

# ECOSYSTEM
OPT_DOCKER=0
OPT_CORKS=0
OPT_HWID=0

# ADVANCED
OPT_PARANOIA=0
OPT_TOR=0
OPT_MAC_RANDOM=0
OPT_SSH_KEYS=0
OPT_FAIL2BAN=0
OPT_NO_AUTOUPDATE=0
OPT_OFFLINE_MODE=0

# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────
toggle() {
    eval "val=\$OPT_$1"
    if [ "$val" = "1" ]; then
        eval "OPT_$1=0"
    else
        eval "OPT_$1=1"
    fi
}

checkbox() {
    if [ "$1" = "1" ]; then
        printf "${G}[✓]${N}"
    else
        printf "[ ]"
    fi
}

requires_docker() {
    [ "$OPT_SURICATA" = "1" ] || [ "$OPT_CROWDSEC" = "1" ] || \
    [ "$OPT_ADGUARD" = "1" ] || [ "$OPT_UNBOUND" = "1" ] || \
    [ "$OPT_NTOPNG" = "1" ] || [ "$OPT_HOMEPAGE" = "1" ] || \
    [ "$OPT_CORKS" = "1" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN MENU
# ─────────────────────────────────────────────────────────────────────────────
show_menu() {
    clear
    cat << EOF
    ╔═══════════════════════════════════════════════════════════════════╗
    ║           CI5 PHOENIX — CUSTOM INSTALL                            ║
    ╠═══════════════════════════════════════════════════════════════════╣
    ║                                                                   ║
    ║  ${B}CORE (Required)${N}                                                 ║
    ║  $(checkbox $OPT_SYSCTL) ${DIM}[locked]${N}  Network Tuning       sysctl, IRQ, buffers    ║
    ║  $(checkbox $OPT_SQM) ${DIM}[locked]${N}  SQM/QoS              Bufferbloat fix (CAKE)  ║
    ║                                                                   ║
    ║  ${B}SECURITY${N}                                                        ║
    ║  $(checkbox $OPT_SURICATA) [S]       Suricata             IDS/IPS detection         ║
    ║  $(checkbox $OPT_CROWDSEC) [C]       CrowdSec             Threat intelligence       ║
    ║  $(checkbox $OPT_FIREWALL) [F]       Firewall Hardening   iptables lockdown         ║
    ║                                                                   ║
    ║  ${B}DNS${N}                                                             ║
    ║  $(checkbox $OPT_UNBOUND) [U]       Unbound              Local resolver + DoT      ║
    ║  $(checkbox $OPT_ADGUARD) [G]       AdGuard Home         DNS filtering/adblock     ║
    ║                                                                   ║
    ║  ${B}MONITORING${N}                                                      ║
    ║  $(checkbox $OPT_NTOPNG) [N]       ntopng + Redis       Traffic analysis          ║
    ║  $(checkbox $OPT_HOMEPAGE) [H]       Homepage             Dashboard                 ║
    ║                                                                   ║
    ║  ${B}VPN${N}                                                             ║
    ║  $(checkbox $OPT_WIREGUARD) [W]       WireGuard            Server + client           ║
    ║  $(checkbox $OPT_OPENVPN) [O]       OpenVPN              Client configs            ║
    ║  $(checkbox $OPT_CAPTIVE) [P]       Captive Portal       Hotel/airport bypass      ║
    ║                                                                   ║
    ║  ${B}ECOSYSTEM${N}                                                       ║
    ║  $(checkbox $OPT_CORKS) [K]       Cork System          ci5 managed containers    ║
    ║  $(checkbox $OPT_HWID) [I]       HWID + Forums        Identity for community    ║
    ║                                                                   ║
    ║  ─────────────────────────────────────────────────────────────────║
    ║  ${C}[A]${N} Advanced Options    ${C}[R]${N} Reset to Defaults                  ║
    ║  ${C}[Enter]${N} Install          ${C}[Q]${N} Quit                              ║
    ║                                                                   ║
    ╚═══════════════════════════════════════════════════════════════════╝
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# ADVANCED MENU
# ─────────────────────────────────────────────────────────────────────────────
show_advanced() {
    clear
    cat << EOF
    ╔═══════════════════════════════════════════════════════════════════╗
    ║           CI5 PHOENIX — ADVANCED OPTIONS                          ║
    ╠═══════════════════════════════════════════════════════════════════╣
    ║                                                                   ║
    ║  ${B}FIRST BOOT BEHAVIOR${N}                                             ║
    ║  $(checkbox $OPT_PARANOIA) [1]       Paranoia Mode        Block WAN until login     ║
    ║  $(checkbox $OPT_MAC_RANDOM) [2]       MAC Randomization    Rotate on each boot       ║
    ║  $(checkbox $OPT_TOR) [3]       Tor Default Route    All traffic via Tor       ║
    ║                                                                   ║
    ║  ${B}HARDENING${N}                                                       ║
    ║  $(checkbox $OPT_SSH_KEYS) [4]       SSH Key-Only         Disable password auth     ║
    ║  $(checkbox $OPT_FAIL2BAN) [5]       Fail2ban             Brute force protection    ║
    ║  $(checkbox $OPT_NO_AUTOUPDATE) [6]       No Auto-Updates      Manual updates only       ║
    ║                                                                   ║
    ║  ${B}ECOSYSTEM PRIVACY${N}                                               ║
    ║  $(checkbox $OPT_OFFLINE_MODE) [7]       Offline Mode         Never phone home          ║
    ║                                                                   ║
    ║  ─────────────────────────────────────────────────────────────────║
    ║  ${C}[B]${N} Back to Main Menu                                           ║
    ║                                                                   ║
    ╚═══════════════════════════════════════════════════════════════════╝
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# INSTALLATION FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────
info() { printf "${G}[✓]${N} %s\n" "$1"; }
warn() { printf "${Y}[!]${N} %s\n" "$1"; }
err()  { printf "${R}[✗]${N} %s\n" "$1"; }
step() { printf "\n${B}═══ %s ═══${N}\n\n" "$1"; }

detect_platform() {
    if [ -f /etc/openwrt_release ]; then
        PLATFORM="openwrt"
        PKG_INSTALL="opkg install"
    elif [ -f /etc/debian_version ]; then
        PLATFORM="debian"
        PKG_INSTALL="apt-get install -y -qq"
    else
        PLATFORM="linux"
        PKG_INSTALL="echo 'Manual install needed:'"
    fi
}

install_docker_if_needed() {
    if requires_docker; then
        if ! command -v docker >/dev/null 2>&1; then
            step "DOCKER ENGINE"
            if [ "$PLATFORM" = "openwrt" ]; then
                opkg update && opkg install dockerd docker-compose
                /etc/init.d/dockerd enable && /etc/init.d/dockerd start
            elif [ "$PLATFORM" = "debian" ]; then
                curl -fsSL https://get.docker.com | sh
                systemctl enable docker && systemctl start docker
            fi
            sleep 3
        fi
        OPT_DOCKER=1
        info "Docker ready"
    fi
}

run_installation() {
    clear
    printf "${B}CI5 PHOENIX — Installing Selected Components${N}\n"
    printf "═══════════════════════════════════════════════════════════════\n\n"
    
    detect_platform
    
    # ─────────────────────────────────────────────────────────────────────
    # CORE (Always)
    # ─────────────────────────────────────────────────────────────────────
    step "CORE: Network Tuning"
    
    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/99-ci5-network.conf << 'SYSCTL'
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 1048576 16777216
net.ipv4.tcp_wmem = 4096 1048576 16777216
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.ip_forward = 1
net.netfilter.nf_conntrack_max = 262144
SYSCTL
    sysctl --system >/dev/null 2>&1 || true
    info "Sysctl tuning applied"
    
    # IRQ Balancing
    cat > /usr/local/bin/ci5-irq-balance << 'IRQ'
#!/bin/sh
for irq in $(grep -E 'xhci|usb|eth' /proc/interrupts 2>/dev/null | cut -d: -f1 | tr -d ' '); do
    echo 0c > /proc/irq/$irq/smp_affinity 2>/dev/null || true
done
IRQ
    chmod +x /usr/local/bin/ci5-irq-balance
    /usr/local/bin/ci5-irq-balance 2>/dev/null || true
    info "IRQ balancing configured"
    
    # SQM script
    cat > /usr/local/bin/ci5-sqm << 'SQM'
#!/bin/sh
WAN="${1:-eth0}"; DOWN="${2:-0}"; UP="${3:-0}"
[ "$DOWN" = "0" ] && { echo "Usage: ci5-sqm <if> <down> <up>"; exit 1; }
tc qdisc replace dev "$WAN" root cake bandwidth "${UP}mbit"
modprobe ifb 2>/dev/null; ip link add ifb0 type ifb 2>/dev/null; ip link set ifb0 up
tc qdisc replace dev "$WAN" handle ffff: ingress
tc filter replace dev "$WAN" parent ffff: protocol all u32 match u32 0 0 action mirred egress redirect dev ifb0
tc qdisc replace dev ifb0 root cake bandwidth "${DOWN}mbit"
echo "SQM: ${DOWN}↓ ${UP}↑ Mbps on $WAN"
SQM
    chmod +x /usr/local/bin/ci5-sqm
    info "SQM script installed"
    
    # ─────────────────────────────────────────────────────────────────────
    # Docker if needed
    # ─────────────────────────────────────────────────────────────────────
    install_docker_if_needed
    
    # ─────────────────────────────────────────────────────────────────────
    # Create docker-compose for selected services
    # ─────────────────────────────────────────────────────────────────────
    if requires_docker; then
        step "DOCKER SERVICES"
        
        mkdir -p /opt/ci5/docker
        cat > /opt/ci5/docker/docker-compose.yml << 'COMPOSE_HEAD'
version: '3.8'
networks:
  ci5_net:
    driver: bridge
services:
COMPOSE_HEAD
        
        [ "$OPT_SURICATA" = "1" ] && cat >> /opt/ci5/docker/docker-compose.yml << 'SVC'
  suricata:
    image: jasonish/suricata:latest
    container_name: ci5-suricata
    network_mode: host
    cap_add: [NET_ADMIN, SYS_NICE]
    volumes: [./suricata/logs:/var/log/suricata]
    restart: unless-stopped
SVC
        
        [ "$OPT_CROWDSEC" = "1" ] && cat >> /opt/ci5/docker/docker-compose.yml << 'SVC'
  crowdsec:
    image: crowdsecurity/crowdsec:latest
    container_name: ci5-crowdsec
    networks: [ci5_net]
    volumes: [./crowdsec:/etc/crowdsec, /var/log:/var/log:ro]
    restart: unless-stopped
SVC
        
        [ "$OPT_ADGUARD" = "1" ] && cat >> /opt/ci5/docker/docker-compose.yml << 'SVC'
  adguard:
    image: adguard/adguardhome:latest
    container_name: ci5-adguard
    networks: [ci5_net]
    ports: ["53:53/tcp", "53:53/udp", "3000:3000"]
    volumes: [./adguard/work:/opt/adguardhome/work, ./adguard/conf:/opt/adguardhome/conf]
    restart: unless-stopped
SVC
        
        [ "$OPT_UNBOUND" = "1" ] && cat >> /opt/ci5/docker/docker-compose.yml << 'SVC'
  unbound:
    image: mvance/unbound:latest
    container_name: ci5-unbound
    networks: [ci5_net]
    volumes: [./unbound:/opt/unbound/etc/unbound]
    restart: unless-stopped
SVC
        
        [ "$OPT_NTOPNG" = "1" ] && cat >> /opt/ci5/docker/docker-compose.yml << 'SVC'
  redis:
    image: redis:alpine
    container_name: ci5-redis
    networks: [ci5_net]
    restart: unless-stopped
  ntopng:
    image: ntop/ntopng:stable
    container_name: ci5-ntopng
    network_mode: host
    depends_on: [redis]
    restart: unless-stopped
SVC
        
        [ "$OPT_HOMEPAGE" = "1" ] && cat >> /opt/ci5/docker/docker-compose.yml << 'SVC'
  homepage:
    image: ghcr.io/gethomepage/homepage:latest
    container_name: ci5-homepage
    networks: [ci5_net]
    ports: ["80:3000"]
    volumes: [./homepage:/app/config]
    restart: unless-stopped
SVC
        
        # Create directories
        mkdir -p /opt/ci5/docker/{suricata/logs,crowdsec,adguard/{work,conf},unbound,homepage}
        
        # Start
        cd /opt/ci5/docker
        docker compose pull 2>/dev/null || docker-compose pull
        docker compose up -d 2>/dev/null || docker-compose up -d
        info "Docker services started"
    fi
    
    # ─────────────────────────────────────────────────────────────────────
    # VPN
    # ─────────────────────────────────────────────────────────────────────
    if [ "$OPT_WIREGUARD" = "1" ]; then
        step "WIREGUARD"
        if [ "$PLATFORM" = "debian" ]; then
            apt-get install -y -qq wireguard wireguard-tools
        elif [ "$PLATFORM" = "openwrt" ]; then
            opkg install wireguard-tools luci-proto-wireguard
        fi
        info "WireGuard installed"
    fi
    
    if [ "$OPT_OPENVPN" = "1" ]; then
        step "OPENVPN"
        if [ "$PLATFORM" = "debian" ]; then
            apt-get install -y -qq openvpn
        elif [ "$PLATFORM" = "openwrt" ]; then
            opkg install openvpn-openssl luci-app-openvpn
        fi
        info "OpenVPN installed"
    fi
    
    # ─────────────────────────────────────────────────────────────────────
    # HWID
    # ─────────────────────────────────────────────────────────────────────
    if [ "$OPT_HWID" = "1" ]; then
        step "HARDWARE IDENTITY"
        mkdir -p /etc/ci5 && chmod 700 /etc/ci5
        
        SERIAL=$(grep -i "^Serial" /proc/cpuinfo 2>/dev/null | awk '{print $3}')
        [ -z "$SERIAL" ] && SERIAL=$(cat /sys/class/dmi/id/product_uuid 2>/dev/null)
        [ -z "$SERIAL" ] && SERIAL=$(cat /sys/class/net/eth0/address 2>/dev/null | tr -d ':')
        [ -z "$SERIAL" ] && SERIAL=$(cat /proc/sys/kernel/random/uuid)
        
        HWID=$(printf '%s' "${SERIAL}:ci5-phoenix-v1" | sha256sum | cut -d' ' -f1)
        echo "$HWID" > /etc/ci5/.hwid
        chmod 600 /etc/ci5/.hwid
        info "HWID: ${HWID:0:8}...${HWID: -8}"
    fi
    
    # ─────────────────────────────────────────────────────────────────────
    # ADVANCED OPTIONS
    # ─────────────────────────────────────────────────────────────────────
    if [ "$OPT_PARANOIA" = "1" ]; then
        step "PARANOIA MODE"
        cat > /usr/local/bin/ci5-paranoia << 'PARANOIA'
#!/bin/sh
# Block all WAN until explicitly unlocked
iptables -I FORWARD -o eth+ -j DROP
iptables -I OUTPUT -o eth+ ! -d 192.168.0.0/16 -j DROP
echo "PARANOIA MODE ACTIVE - run 'ci5-paranoia-unlock' after login"
PARANOIA
        chmod +x /usr/local/bin/ci5-paranoia
        
        cat > /usr/local/bin/ci5-paranoia-unlock << 'UNLOCK'
#!/bin/sh
iptables -D FORWARD -o eth+ -j DROP 2>/dev/null
iptables -D OUTPUT -o eth+ ! -d 192.168.0.0/16 -j DROP 2>/dev/null
echo "Paranoia mode disabled - WAN unlocked"
UNLOCK
        chmod +x /usr/local/bin/ci5-paranoia-unlock
        
        # Add to boot
        grep -q 'ci5-paranoia' /etc/rc.local 2>/dev/null || \
            echo '/usr/local/bin/ci5-paranoia' >> /etc/rc.local
        
        info "Paranoia mode configured (active on next boot)"
    fi
    
    if [ "$OPT_MAC_RANDOM" = "1" ]; then
        step "MAC RANDOMIZATION"
        cat > /usr/local/bin/ci5-mac-random << 'MAC'
#!/bin/sh
for iface in eth0 wlan0; do
    [ -d "/sys/class/net/$iface" ] || continue
    ip link set $iface down
    NEWMAC=$(printf '%02x:%02x:%02x:%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))
    ip link set $iface address $NEWMAC
    ip link set $iface up
    echo "$iface -> $NEWMAC"
done
MAC
        chmod +x /usr/local/bin/ci5-mac-random
        info "MAC randomization script installed"
    fi
    
    if [ "$OPT_FAIL2BAN" = "1" ]; then
        step "FAIL2BAN"
        if [ "$PLATFORM" = "debian" ]; then
            apt-get install -y -qq fail2ban
            systemctl enable fail2ban
            systemctl start fail2ban
            info "Fail2ban installed and running"
        else
            warn "Fail2ban: manual install required for $PLATFORM"
        fi
    fi
    
    # ─────────────────────────────────────────────────────────────────────
    # FINALIZE
    # ─────────────────────────────────────────────────────────────────────
    printf "\n"
    printf "${G}╔═══════════════════════════════════════════════════════════════════╗${N}\n"
    printf "${G}║  ✓ CI5 CUSTOM INSTALLATION COMPLETE                               ║${N}\n"
    printf "${G}╚═══════════════════════════════════════════════════════════════════╝${N}\n"
    printf "\n"
    printf "  Installed components:\n"
    printf "    ${G}✓${N} Network tuning (sysctl, IRQ)\n"
    printf "    ${G}✓${N} SQM/QoS scripts\n"
    [ "$OPT_DOCKER" = "1" ] && printf "    ${G}✓${N} Docker\n"
    [ "$OPT_SURICATA" = "1" ] && printf "    ${G}✓${N} Suricata\n"
    [ "$OPT_CROWDSEC" = "1" ] && printf "    ${G}✓${N} CrowdSec\n"
    [ "$OPT_ADGUARD" = "1" ] && printf "    ${G}✓${N} AdGuard Home\n"
    [ "$OPT_UNBOUND" = "1" ] && printf "    ${G}✓${N} Unbound\n"
    [ "$OPT_NTOPNG" = "1" ] && printf "    ${G}✓${N} ntopng\n"
    [ "$OPT_HOMEPAGE" = "1" ] && printf "    ${G}✓${N} Homepage\n"
    [ "$OPT_WIREGUARD" = "1" ] && printf "    ${G}✓${N} WireGuard\n"
    [ "$OPT_OPENVPN" = "1" ] && printf "    ${G}✓${N} OpenVPN\n"
    [ "$OPT_HWID" = "1" ] && printf "    ${G}✓${N} HWID\n"
    [ "$OPT_PARANOIA" = "1" ] && printf "    ${G}✓${N} Paranoia Mode\n"
    [ "$OPT_FAIL2BAN" = "1" ] && printf "    ${G}✓${N} Fail2ban\n"
    printf "\n"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN LOOP
# ─────────────────────────────────────────────────────────────────────────────
main() {
    while true; do
        show_menu
        printf "    Toggle [S/C/F/U/G/N/H/W/O/P/K/I] or [A]dvanced/[Enter] Install: "
        read -r choice
        
        case "$choice" in
            s|S) toggle SURICATA ;;
            c|C) toggle CROWDSEC ;;
            f|F) toggle FIREWALL ;;
            u|U) toggle UNBOUND ;;
            g|G) toggle ADGUARD ;;
            n|N) toggle NTOPNG ;;
            h|H) toggle HOMEPAGE ;;
            w|W) toggle WIREGUARD ;;
            o|O) toggle OPENVPN ;;
            p|P) toggle CAPTIVE ;;
            k|K) toggle CORKS ;;
            i|I) toggle HWID ;;
            r|R)
                # Reset to defaults
                OPT_SURICATA=0; OPT_CROWDSEC=0; OPT_FIREWALL=0
                OPT_UNBOUND=0; OPT_ADGUARD=0
                OPT_NTOPNG=0; OPT_HOMEPAGE=0
                OPT_WIREGUARD=0; OPT_OPENVPN=0; OPT_CAPTIVE=0
                OPT_CORKS=0; OPT_HWID=0
                OPT_PARANOIA=0; OPT_TOR=0; OPT_MAC_RANDOM=0
                OPT_SSH_KEYS=0; OPT_FAIL2BAN=0; OPT_NO_AUTOUPDATE=0
                OPT_OFFLINE_MODE=0
                ;;
            a|A)
                while true; do
                    show_advanced
                    printf "    Toggle [1-7] or [B]ack: "
                    read -r adv
                    case "$adv" in
                        1) toggle PARANOIA ;;
                        2) toggle MAC_RANDOM ;;
                        3) toggle TOR ;;
                        4) toggle SSH_KEYS ;;
                        5) toggle FAIL2BAN ;;
                        6) toggle NO_AUTOUPDATE ;;
                        7) toggle OFFLINE_MODE ;;
                        b|B) break ;;
                    esac
                done
                ;;
            q|Q) echo "Aborted."; exit 0 ;;
            "") run_installation; exit 0 ;;
        esac
    done
}

main "$@"
