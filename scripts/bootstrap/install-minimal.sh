#!/bin/sh
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  CI5 PHOENIX — MINIMAL PERFORMANCE INSTALLER                              ║
# ║  Full network stack without Docker: VLANs, Firewall, Unbound, SQM         ║
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
}

# ─────────────────────────────────────────────────────────────────────────────
# PLATFORM DETECTION
# ─────────────────────────────────────────────────────────────────────────────
detect_platform() {
    if [ -f /etc/openwrt_release ]; then
        PLATFORM="openwrt"
        info "Platform: OpenWrt"
    else
        err "CI5 Minimal requires OpenWrt"
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# WAN CONFIGURATION (from soul)
# ─────────────────────────────────────────────────────────────────────────────
configure_wan() {
    step "CONFIGURING WAN CONNECTION"

    WAN_IF="${WAN_IF:-eth1}"

    # Apply VLAN if specified
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
# SYSCTL TUNING (NIC-profile aware)
# ─────────────────────────────────────────────────────────────────────────────
install_sysctl_tuning() {
    step "APPLYING SYSCTL TUNING (${NIC_PROFILE:-usb3} profile)"

    # Download NIC tuning module
    CI5_RAW="${CI5_RAW:-https://raw.githubusercontent.com/dreamswag/ci5/main}"
    mkdir -p /opt/ci5/lib

    if curl -fsSL "${CI5_RAW}/core/system/nic-tuning.sh" -o /opt/ci5/lib/nic-tuning.sh 2>/dev/null; then
        chmod +x /opt/ci5/lib/nic-tuning.sh
        export NIC_PROFILE WAN_IF LAN_IF APLESS_MODE PCIE_DRIVER
        /opt/ci5/lib/nic-tuning.sh apply
        ln -sf /opt/ci5/lib/nic-tuning.sh /usr/bin/ci5-nic-tune 2>/dev/null || true
        info "Applied ${NIC_PROFILE:-usb3} NIC tuning profile"
    else
        # Fallback
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
            ethtool -A "$dev" rx off tx off 2>/dev/null || true
            ethtool --set-eee "$dev" eee off 2>/dev/null || true
        done
        info "Applied fallback tuning"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# VLAN SEGMENTATION
# ─────────────────────────────────────────────────────────────────────────────
install_vlans() {
    step "CONFIGURING VLAN SEGMENTATION"

    # Backup existing config
    cp /etc/config/network /etc/config/network.bak.ci5 2>/dev/null || true

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

    # Backup existing config
    cp /etc/config/firewall /etc/config/firewall.bak.ci5 2>/dev/null || true

    # Default policies
    uci set firewall.@defaults[0].input='REJECT'
    uci set firewall.@defaults[0].output='ACCEPT'
    uci set firewall.@defaults[0].forward='REJECT'
    uci set firewall.@defaults[0].synflood_protect='1'

    # WAN Zone (hardened)
    uci set firewall.@zone[1].input='REJECT'
    uci set firewall.@zone[1].output='ACCEPT'
    uci set firewall.@zone[1].forward='REJECT'
    uci set firewall.@zone[1].masq='1'
    uci set firewall.@zone[1].mtu_fix='1'

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

    info "Firewall zones: lan (trusted), iot (internet-only), guest (isolated)"
}

# ─────────────────────────────────────────────────────────────────────────────
# UNBOUND DNS (Native - port 53)
# ─────────────────────────────────────────────────────────────────────────────
install_unbound() {
    step "INSTALLING UNBOUND RECURSIVE DNS"

    opkg update >/dev/null 2>&1
    opkg install unbound-daemon unbound-control >/dev/null 2>&1 || \
        opkg install unbound-daemon-heavy >/dev/null 2>&1 || {
            err "Failed to install Unbound"
            return 1
        }

    # Configure on port 53 (direct DNS)
    cat > /etc/config/unbound << 'EOF'
config unbound 'ub_main'
    option enabled '1'
    option listen_port '53'
    option localservice '1'
    option interface_auto '1'
    option domain 'lan'
    option add_local_fqdn '1'
    option edns_size '1232'
    option hide_binddata '1'
    option num_threads '2'
    option rebind_protection '1'
    option recursion 'default'
    option resource 'default'
    option ttl_min '120'
    option validator '0'
    list iface_trig 'lan'
    list iface_trig 'wan'
EOF

    # Disable dnsmasq DNS
    uci set dhcp.@dnsmasq[0].port='0'
    uci set dhcp.@dnsmasq[0].localuse='0'
    uci commit dhcp

    /etc/init.d/unbound enable
    /etc/init.d/unbound restart
    /etc/init.d/dnsmasq restart

    sleep 2
    if nslookup google.com 127.0.0.1 >/dev/null 2>&1; then
        info "Unbound operational on port 53"
    else
        warn "Unbound may need time to initialize"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# SQM/CAKE
# ─────────────────────────────────────────────────────────────────────────────
install_sqm() {
    step "INSTALLING SQM/CAKE"

    opkg update >/dev/null 2>&1
    opkg install sqm-scripts luci-app-sqm >/dev/null 2>&1

    # Pre-configure with soul overhead settings
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
    mkdir -p /etc/ci5
    echo "$CI5_VERSION" > /etc/ci5/version
    echo "minimal" > /etc/ci5/mode
    date -Iseconds > /etc/ci5/installed

    step "INSTALLATION COMPLETE"

    cat << 'EOF'

    ╔═══════════════════════════════════════════════════════════════════╗
    ║  CI5 MINIMAL STACK INSTALLED                                      ║
    ╠═══════════════════════════════════════════════════════════════════╣
    ║                                                                   ║
    ║  WHAT'S INSTALLED:                                                ║
    ║    • BBR + 16MB buffers + hardware offload prohibition            ║
    ║    • SQM/CAKE (run speed test to enable)                          ║
    ║    • Unbound recursive DNS (port 53, maximum privacy)             ║
    ║    • VLANs: 10 (Trusted), 20 (Work), 30 (IoT), 40 (Guest)         ║
    ║    • Hardened firewall zones                                      ║
    ║    • DHCP pools for all VLANs                                     ║
    ║                                                                   ║
    ║  WHAT'S NOT INSTALLED:                                            ║
    ║    • No Docker                                                    ║
    ║    • No Ad-blocking (use /free for AdGuard)                       ║
    ║    • No IDS (use /free for Suricata)                              ║
    ║                                                                   ║
    ║  VLAN ASSIGNMENT (configure on your AP):                          ║
    ║    VLAN 10 (192.168.10.x) — Trusted devices                       ║
    ║    VLAN 20 (192.168.20.x) — Work devices                          ║
    ║    VLAN 30 (192.168.30.x) — IoT devices (internet only)           ║
    ║    VLAN 40 (192.168.40.x) — Guest devices (isolated)              ║
    ║                                                                   ║
    ║  NEXT STEPS:                                                      ║
    ║    1. Run speed test: curl -sL ci5.run | sh -s fast               ║
    ║    2. Configure AP VLANs to match SSIDs                           ║
    ║    3. Test bufferbloat: waveform.com/tools/bufferbloat            ║
    ║                                                                   ║
    ║  UPGRADE TO FULL STACK:                                           ║
    ║    curl -sL ci5.run | sh -s free                                  ║
    ║                                                                   ║
    ╚═══════════════════════════════════════════════════════════════════╝

EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
main() {
    clear
    printf "${B}CI5 PHOENIX — Minimal Performance Installer${N}\n"
    printf "═══════════════════════════════════════════════════════════════\n\n"

    # Load soul config if available
    if [ "$FROM_SOUL" -eq 1 ]; then
        load_soul || warn "No soul config found, using defaults"
    else
        # Interactive mode - confirm
        printf "This will install the minimal CI5 stack:\n"
        printf "  • VLANs + Firewall + Unbound DNS + SQM/CAKE\n"
        printf "  • No Docker, no ad-blocking, no IDS\n\n"
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

    # Configure WAN from soul
    [ -n "$WAN_PROTO" ] && configure_wan

    install_sysctl_tuning
    install_vlans
    install_firewall
    install_dhcp_pools
    install_unbound
    install_sqm

    finalize
}

main "$@"
