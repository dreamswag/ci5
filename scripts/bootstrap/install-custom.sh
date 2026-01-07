#!/bin/sh
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  CI5 PHOENIX — CUSTOM INSTALLER                                           ║
# ║  Pick exactly which components to install                                 ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

set -e

CI5_VERSION="3.0.0"
SOUL_FILE="/etc/ci5/soul.conf"

# Colors
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'

info() { printf "${G}[✓]${N} %s\n" "$1"; }
warn() { printf "${Y}[!]${N} %s\n" "$1"; }
err()  { printf "${R}[✗]${N} %s\n" "$1"; }
step() { printf "\n${B}═══ %s ═══${N}\n\n" "$1"; }

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
        warn "Low RAM - ntopng disabled"
        CUSTOM_NTOPNG=0
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# PLATFORM DETECTION
# ─────────────────────────────────────────────────────────────────────────────
detect_platform() {
    if [ -f /etc/openwrt_release ]; then
        PLATFORM="openwrt"
        info "Platform: OpenWrt"
    else
        err "CI5 Custom requires OpenWrt"
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# COMPONENT STATE (Defaults)
# ─────────────────────────────────────────────────────────────────────────────
# These can be overridden by soul config
CUSTOM_VLANS="${CUSTOM_VLANS:-1}"
CUSTOM_FIREWALL="${CUSTOM_FIREWALL:-1}"
CUSTOM_SQM="${CUSTOM_SQM:-1}"
CUSTOM_UNBOUND="${CUSTOM_UNBOUND:-1}"
CUSTOM_ADGUARD="${CUSTOM_ADGUARD:-0}"
CUSTOM_SURICATA="${CUSTOM_SURICATA:-0}"
CUSTOM_CROWDSEC="${CUSTOM_CROWDSEC:-0}"
CUSTOM_NTOPNG="${CUSTOM_NTOPNG:-0}"
CUSTOM_DOCKER="${CUSTOM_DOCKER:-0}"

# ─────────────────────────────────────────────────────────────────────────────
# INTERACTIVE MENU
# ─────────────────────────────────────────────────────────────────────────────
toggle() {
    eval "val=\$CUSTOM_$1"
    if [ "$val" = "1" ]; then
        eval "CUSTOM_$1=0"
    else
        eval "CUSTOM_$1=1"
    fi
}

checkbox() {
    if [ "$1" = "1" ]; then
        printf "${G}[x]${N}"
    else
        printf "[ ]"
    fi
}

show_menu() {
    clear
    printf "${B}CI5 PHOENIX — Custom Component Selection${N}\n"
    printf "═══════════════════════════════════════════════════════════════\n"
    printf "Toggle with letter key, Enter to proceed\n\n"

    printf "  ${B}CORE NETWORK:${N}\n"
    printf "    %s [V] VLANs (10=Trusted, 20=Work, 30=IoT, 40=Guest)\n" "$(checkbox $CUSTOM_VLANS)"
    printf "    %s [F] Firewall Zones (hardened)\n" "$(checkbox $CUSTOM_FIREWALL)"
    printf "    %s [Q] SQM/CAKE (0ms bufferbloat)\n" "$(checkbox $CUSTOM_SQM)"
    printf "\n"

    printf "  ${B}DNS:${N}\n"
    printf "    %s [U] Unbound (recursive resolver, privacy)\n" "$(checkbox $CUSTOM_UNBOUND)"
    printf "    %s [A] AdGuard Home (ad-blocking) ${Y}[Docker]${N}\n" "$(checkbox $CUSTOM_ADGUARD)"
    printf "\n"

    printf "  ${B}SECURITY:${N}\n"
    printf "    %s [S] Suricata IDS ${Y}[Docker]${N}\n" "$(checkbox $CUSTOM_SURICATA)"
    printf "    %s [C] CrowdSec (threat intelligence) ${Y}[Docker]${N}\n" "$(checkbox $CUSTOM_CROWDSEC)"
    printf "\n"

    printf "  ${B}MONITORING:${N}\n"
    printf "    %s [N] ntopng (traffic analysis) ${Y}[Docker]${N}\n" "$(checkbox $CUSTOM_NTOPNG)"
    printf "\n"

    printf "  ${B}INFRASTRUCTURE:${N}\n"
    printf "    %s [D] Docker (auto-enabled if needed)\n" "$(checkbox $CUSTOM_DOCKER)"
    printf "\n"

    printf "  ─────────────────────────────────────────────────────────────\n"
    printf "  [Enter] Install | [R] Reset | [X] Exit\n"
    printf "\n"
}

run_menu() {
    while true; do
        show_menu
        printf "  Toggle: "
        read -r choice

        case "$choice" in
            v|V) toggle VLANS ;;
            f|F) toggle FIREWALL ;;
            q|Q) toggle SQM ;;
            u|U) toggle UNBOUND ;;
            a|A)
                toggle ADGUARD
                [ "$CUSTOM_ADGUARD" = "1" ] && CUSTOM_DOCKER=1
                ;;
            s|S)
                toggle SURICATA
                [ "$CUSTOM_SURICATA" = "1" ] && CUSTOM_DOCKER=1
                ;;
            c|C)
                toggle CROWDSEC
                [ "$CUSTOM_CROWDSEC" = "1" ] && CUSTOM_DOCKER=1
                ;;
            n|N)
                toggle NTOPNG
                [ "$CUSTOM_NTOPNG" = "1" ] && CUSTOM_DOCKER=1
                ;;
            d|D) toggle DOCKER ;;
            r|R)
                CUSTOM_VLANS=1; CUSTOM_FIREWALL=1; CUSTOM_SQM=1
                CUSTOM_UNBOUND=1; CUSTOM_ADGUARD=0
                CUSTOM_SURICATA=0; CUSTOM_CROWDSEC=0; CUSTOM_NTOPNG=0
                CUSTOM_DOCKER=0
                ;;
            x|X) echo "Aborted."; exit 0 ;;
            "") break ;;
        esac
    done

    # Auto-enable Docker if any Docker component selected
    if [ "$CUSTOM_ADGUARD" = "1" ] || [ "$CUSTOM_SURICATA" = "1" ] || \
       [ "$CUSTOM_CROWDSEC" = "1" ] || [ "$CUSTOM_NTOPNG" = "1" ]; then
        CUSTOM_DOCKER=1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# WAN CONFIGURATION (from soul)
# ─────────────────────────────────────────────────────────────────────────────
configure_wan() {
    step "CONFIGURING WAN CONNECTION"

    WAN_IF="${WAN_IF:-eth1}"

    if [ -n "$WAN_VLAN" ]; then
        WAN_DEVICE="${WAN_IF}.${WAN_VLAN}"
        info "WAN VLAN: $WAN_VLAN"
    else
        WAN_DEVICE="$WAN_IF"
    fi

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
# COMPONENT INSTALLERS
# ─────────────────────────────────────────────────────────────────────────────

install_sysctl() {
    step "APPLYING SYSCTL TUNING (${NIC_PROFILE:-usb3} profile)"

    CI5_RAW="${CI5_RAW:-https://raw.githubusercontent.com/dreamswag/ci5/main}"
    mkdir -p /opt/ci5/lib

    if curl -fsSL "${CI5_RAW}/core/system/nic-tuning.sh" -o /opt/ci5/lib/nic-tuning.sh 2>/dev/null; then
        chmod +x /opt/ci5/lib/nic-tuning.sh
        export NIC_PROFILE WAN_IF LAN_IF APLESS_MODE PCIE_DRIVER
        /opt/ci5/lib/nic-tuning.sh apply
        ln -sf /opt/ci5/lib/nic-tuning.sh /usr/bin/ci5-nic-tune 2>/dev/null || true
        info "Applied ${NIC_PROFILE:-usb3} NIC tuning profile"
    else
        warn "NIC tuning module unavailable, using fallback"
        cat > /etc/sysctl.d/99-ci5-tuning.conf << 'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.netfilter.nf_conntrack_max=65536
net.ipv4.ip_forward=1
net.ipv4.conf.all.forwarding=1
net.ipv6.conf.all.forwarding=1
EOF
        sysctl --system >/dev/null 2>&1
        for dev in eth0 eth1 eth2; do
            [ -d "/sys/class/net/$dev" ] || continue
            ethtool -K "$dev" tso off gso off gro off 2>/dev/null || true
        done
        info "Applied fallback tuning"
    fi
}

install_vlans() {
    step "CONFIGURING VLANs"

    LAN_IF="${LAN_IF:-eth0}"

    for vlan in 10 20 30 40; do
        case $vlan in
            10) IP="192.168.10.1" ;;
            20) IP="192.168.20.1" ;;
            30) IP="192.168.30.1" ;;
            40) IP="192.168.40.1" ;;
        esac

        uci -q delete "network.vlan${vlan}" 2>/dev/null || true
        uci set "network.vlan${vlan}=interface"
        uci set "network.vlan${vlan}.proto=static"
        uci set "network.vlan${vlan}.device=${LAN_IF}.${vlan}"
        uci set "network.vlan${vlan}.ipaddr=${IP}"
        uci set "network.vlan${vlan}.netmask=255.255.255.0"
    done

    uci commit network
    info "VLANs: 10 (Trusted), 20 (Work), 30 (IoT), 40 (Guest)"
}

install_firewall() {
    step "CONFIGURING FIREWALL"

    uci set firewall.@defaults[0].input='REJECT'
    uci set firewall.@defaults[0].forward='REJECT'
    uci set firewall.@defaults[0].synflood_protect='1'

    # Add VLANs to appropriate zones
    uci -q del firewall.@zone[0].network 2>/dev/null || true
    uci add_list firewall.@zone[0].network='lan'
    uci add_list firewall.@zone[0].network='vlan10'
    uci add_list firewall.@zone[0].network='vlan20'

    # IoT zone
    uci add firewall zone
    uci set firewall.@zone[-1].name='iot'
    uci set firewall.@zone[-1].input='REJECT'
    uci set firewall.@zone[-1].forward='REJECT'
    uci add_list firewall.@zone[-1].network='vlan30'

    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src='iot'
    uci set firewall.@forwarding[-1].dest='wan'

    # Guest zone
    uci add firewall zone
    uci set firewall.@zone[-1].name='guest'
    uci set firewall.@zone[-1].input='REJECT'
    uci set firewall.@zone[-1].forward='REJECT'
    uci add_list firewall.@zone[-1].network='vlan40'

    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src='guest'
    uci set firewall.@forwarding[-1].dest='wan'

    # DHCP/DNS rules for restricted zones
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

install_sqm() {
    step "INSTALLING SQM/CAKE"

    opkg update >/dev/null 2>&1
    opkg install sqm-scripts luci-app-sqm >/dev/null 2>&1

    uci -q delete sqm.wan 2>/dev/null || true
    uci set sqm.wan=queue
    uci set sqm.wan.enabled='0'
    uci set sqm.wan.interface='wan'
    uci set sqm.wan.qdisc='cake'
    uci set sqm.wan.script='piece_of_cake.qos'
    uci set sqm.wan.linklayer="${LINK_LAYER:-ethernet}"
    uci set sqm.wan.overhead="${OVERHEAD:-18}"
    uci commit sqm

    info "SQM/CAKE installed"
}

install_unbound() {
    step "INSTALLING UNBOUND"

    opkg install unbound-daemon unbound-control >/dev/null 2>&1 || \
        opkg install unbound-daemon-heavy >/dev/null 2>&1

    # Port depends on whether AdGuard is also installed
    if [ "$CUSTOM_ADGUARD" = "1" ]; then
        UNBOUND_PORT="5335"
        info "Unbound on port 5335 (upstream for AdGuard)"
    else
        UNBOUND_PORT="53"
        info "Unbound on port 53 (direct DNS)"
    fi

    cat > /etc/config/unbound << EOF
config unbound 'ub_main'
    option enabled '1'
    option listen_port '$UNBOUND_PORT'
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

    # Disable dnsmasq DNS if Unbound on port 53
    if [ "$UNBOUND_PORT" = "53" ]; then
        uci set dhcp.@dnsmasq[0].port='0'
        uci commit dhcp
    fi

    /etc/init.d/unbound enable
    /etc/init.d/unbound restart
}

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

install_adguard() {
    step "INSTALLING ADGUARD HOME"

    mkdir -p /opt/ci5/adguard/{work,conf}

    cat > /opt/ci5/docker/docker-compose-adguard.yml << 'EOF'
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
EOF

    cd /opt/ci5/docker
    docker compose -f docker-compose-adguard.yml up -d 2>/dev/null || \
        docker-compose -f docker-compose-adguard.yml up -d

    sleep 5
    if docker ps | grep -q adguardhome; then
        info "AdGuard Home running (port 53, UI on 3000)"
    else
        warn "AdGuard may need manual configuration"
    fi
}

install_suricata() {
    step "INSTALLING SURICATA IDS"

    mkdir -p /opt/ci5/suricata/{logs,rules}

    cat > /opt/ci5/docker/docker-compose-suricata.yml << 'EOF'
version: '3.8'
services:
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
EOF

    cd /opt/ci5/docker
    docker compose -f docker-compose-suricata.yml up -d 2>/dev/null || \
        docker-compose -f docker-compose-suricata.yml up -d

    info "Suricata IDS installed"
}

install_crowdsec() {
    step "INSTALLING CROWDSEC"

    mkdir -p /opt/ci5/crowdsec/{data,config}

    cat > /opt/ci5/docker/docker-compose-crowdsec.yml << 'EOF'
version: '3.8'
services:
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
EOF

    cd /opt/ci5/docker
    docker compose -f docker-compose-crowdsec.yml up -d 2>/dev/null || \
        docker-compose -f docker-compose-crowdsec.yml up -d

    info "CrowdSec installed"
}

install_ntopng() {
    step "INSTALLING NTOPNG"

    mkdir -p /opt/ci5/ntopng

    cat > /opt/ci5/docker/docker-compose-ntopng.yml << 'EOF'
version: '3.8'
services:
  ntopng:
    image: ntop/ntopng:stable
    container_name: ntopng
    restart: unless-stopped
    network_mode: host
    volumes:
      - /opt/ci5/ntopng:/var/lib/ntopng
    command: --community -i br-lan -w 3001
EOF

    cd /opt/ci5/docker
    docker compose -f docker-compose-ntopng.yml up -d 2>/dev/null || \
        docker-compose -f docker-compose-ntopng.yml up -d

    info "ntopng installed (UI on port 3001)"
}

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

    uci commit dhcp
    /etc/init.d/dnsmasq restart
    info "DHCP pools configured"
}

# ─────────────────────────────────────────────────────────────────────────────
# INSTALLATION ORCHESTRATOR
# ─────────────────────────────────────────────────────────────────────────────
run_installation() {
    step "INSTALLING SELECTED COMPONENTS"

    # Summary
    info "Selected components:"
    [ "$CUSTOM_VLANS" = "1" ] && printf "  • VLANs\n"
    [ "$CUSTOM_FIREWALL" = "1" ] && printf "  • Firewall Zones\n"
    [ "$CUSTOM_SQM" = "1" ] && printf "  • SQM/CAKE\n"
    [ "$CUSTOM_UNBOUND" = "1" ] && printf "  • Unbound DNS\n"
    [ "$CUSTOM_ADGUARD" = "1" ] && printf "  • AdGuard Home\n"
    [ "$CUSTOM_SURICATA" = "1" ] && printf "  • Suricata IDS\n"
    [ "$CUSTOM_CROWDSEC" = "1" ] && printf "  • CrowdSec\n"
    [ "$CUSTOM_NTOPNG" = "1" ] && printf "  • ntopng\n"
    [ "$CUSTOM_DOCKER" = "1" ] && printf "  • Docker\n"
    printf "\n"

    # Always apply sysctl tuning
    install_sysctl

    # Core network
    [ "$CUSTOM_VLANS" = "1" ] && install_vlans
    [ "$CUSTOM_FIREWALL" = "1" ] && install_firewall
    [ "$CUSTOM_VLANS" = "1" ] && install_dhcp_pools
    [ "$CUSTOM_SQM" = "1" ] && install_sqm

    # Docker (before Docker components)
    [ "$CUSTOM_DOCKER" = "1" ] && {
        install_docker
        mkdir -p /opt/ci5/docker
    }

    # DNS
    [ "$CUSTOM_UNBOUND" = "1" ] && install_unbound
    [ "$CUSTOM_ADGUARD" = "1" ] && install_adguard

    # Security
    [ "$CUSTOM_SURICATA" = "1" ] && install_suricata
    [ "$CUSTOM_CROWDSEC" = "1" ] && install_crowdsec

    # Monitoring
    [ "$CUSTOM_NTOPNG" = "1" ] && install_ntopng

    # Reload network
    /etc/init.d/network reload 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# FINALIZE
# ─────────────────────────────────────────────────────────────────────────────
finalize() {
    step "INSTALLATION COMPLETE"

    mkdir -p /etc/ci5
    echo "$CI5_VERSION" > /etc/ci5/version
    echo "custom" > /etc/ci5/mode
    date -Iseconds > /etc/ci5/installed

    # Save what was installed
    cat > /etc/ci5/components << EOF
CUSTOM_VLANS=$CUSTOM_VLANS
CUSTOM_FIREWALL=$CUSTOM_FIREWALL
CUSTOM_SQM=$CUSTOM_SQM
CUSTOM_UNBOUND=$CUSTOM_UNBOUND
CUSTOM_ADGUARD=$CUSTOM_ADGUARD
CUSTOM_SURICATA=$CUSTOM_SURICATA
CUSTOM_CROWDSEC=$CUSTOM_CROWDSEC
CUSTOM_NTOPNG=$CUSTOM_NTOPNG
CUSTOM_DOCKER=$CUSTOM_DOCKER
EOF

    cat << 'EOF'

    ╔═══════════════════════════════════════════════════════════════════╗
    ║  CI5 CUSTOM STACK INSTALLED                                       ║
    ╠═══════════════════════════════════════════════════════════════════╣
    ║                                                                   ║
    ║  Your selected components have been installed.                    ║
    ║                                                                   ║
    ║  WEB INTERFACES:                                                  ║
    ║    • LuCI:    http://192.168.1.1                                  ║
EOF
    [ "$CUSTOM_ADGUARD" = "1" ] && printf "    ║    • AdGuard: http://192.168.1.1:3000                             ║\n"
    [ "$CUSTOM_NTOPNG" = "1" ] && printf "    ║    • ntopng:  http://192.168.1.1:3001                             ║\n"
    cat << 'EOF'
    ║                                                                   ║
    ║  NEXT STEPS:                                                      ║
    ║    1. Run speed test: curl -sL ci5.run | sh -s fast               ║
    ║    2. Configure AP VLANs to match SSIDs                           ║
    ║                                                                   ║
    ╚═══════════════════════════════════════════════════════════════════╝

EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
main() {
    clear
    printf "${B}CI5 PHOENIX — Custom Installer${N}\n"
    printf "═══════════════════════════════════════════════════════════════\n\n"

    check_hardware
    detect_platform

    # Load soul config if available
    if [ "$FROM_SOUL" -eq 1 ]; then
        if load_soul; then
            info "Using pre-selected components from bootstrap"
        else
            warn "No soul config found, showing menu"
            run_menu
        fi
    else
        # Try to load soul for WAN settings, but run menu for component selection
        load_soul 2>/dev/null || true
        run_menu
    fi

    # Configure WAN if soul has settings
    [ -n "$WAN_PROTO" ] && configure_wan

    # Run installation
    run_installation

    finalize
}

main "$@"
