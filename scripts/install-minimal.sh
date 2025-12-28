#!/bin/sh
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  CI5 PHOENIX — MINIMAL PERFORMANCE INSTALLER                              ║
# ║  Bufferbloat fix only — no Docker, no services, no ecosystem              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

set -e

# Colors
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'

info() { printf "${G}[✓]${N} %s\n" "$1"; }
warn() { printf "${Y}[!]${N} %s\n" "$1"; }
step() { printf "\n${B}═══ %s ═══${N}\n\n" "$1"; }

# ─────────────────────────────────────────────────────────────────────────────
# PLATFORM DETECTION
# ─────────────────────────────────────────────────────────────────────────────
detect_platform() {
    if [ -f /etc/openwrt_release ]; then
        PLATFORM="openwrt"
    elif [ -f /etc/debian_version ]; then
        PLATFORM="debian"
    else
        PLATFORM="linux"
    fi
    info "Platform: $PLATFORM"
}

# ─────────────────────────────────────────────────────────────────────────────
# CORE NETWORK TUNING (sysctl)
# ─────────────────────────────────────────────────────────────────────────────
install_sysctl_tuning() {
    step "NETWORK TUNING (sysctl)"
    
    # Backup existing
    [ -f /etc/sysctl.conf ] && cp /etc/sysctl.conf /etc/sysctl.conf.ci5bak
    
    mkdir -p /etc/sysctl.d
    
    cat > /etc/sysctl.d/99-ci5-performance.conf << 'SYSCTL'
# ═══════════════════════════════════════════════════════════════════════════
# CI5 MINIMAL — Network Performance Tuning
# ═══════════════════════════════════════════════════════════════════════════

# ─────────────────────────────────────────────────────────────────────────────
# TCP/UDP BUFFER SIZES
# Larger buffers = better throughput for high-bandwidth connections
# ─────────────────────────────────────────────────────────────────────────────
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 1048576 16777216
net.ipv4.tcp_wmem = 4096 1048576 16777216
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# ─────────────────────────────────────────────────────────────────────────────
# TCP OPTIMIZATION
# ─────────────────────────────────────────────────────────────────────────────
# TCP Fast Open (reduce latency on repeated connections)
net.ipv4.tcp_fastopen = 3

# Reuse TIME_WAIT sockets (improves connection handling)
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15

# Keepalive (detect dead connections faster)
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15

# Backlog queue
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 16384

# Don't slow down after idle
net.ipv4.tcp_slow_start_after_idle = 0

# MTU probing (helps with path MTU discovery issues)
net.ipv4.tcp_mtu_probing = 1

# ─────────────────────────────────────────────────────────────────────────────
# CONGESTION CONTROL — BBR + FQ
# BBR is Google's congestion control, dramatically improves throughput
# FQ (Fair Queueing) provides better packet scheduling
# ─────────────────────────────────────────────────────────────────────────────
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq

# ─────────────────────────────────────────────────────────────────────────────
# FORWARDING (Router Mode)
# ─────────────────────────────────────────────────────────────────────────────
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# ─────────────────────────────────────────────────────────────────────────────
# CONNTRACK (Connection Tracking)
# Higher limits prevent "table full" errors under heavy load
# ─────────────────────────────────────────────────────────────────────────────
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 180

# ─────────────────────────────────────────────────────────────────────────────
# ARP/NEIGHBOR TABLE
# Prevent "neighbor table overflow" on busy networks
# ─────────────────────────────────────────────────────────────────────────────
net.ipv4.neigh.default.gc_thresh1 = 1024
net.ipv4.neigh.default.gc_thresh2 = 4096
net.ipv4.neigh.default.gc_thresh3 = 8192

# ─────────────────────────────────────────────────────────────────────────────
# MISC
# ─────────────────────────────────────────────────────────────────────────────
# Increase max open files
fs.file-max = 2097152

# Better memory management under load
vm.swappiness = 10
SYSCTL
    
    # Apply
    sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-ci5-performance.conf
    
    info "Sysctl tuning applied"
}

# ─────────────────────────────────────────────────────────────────────────────
# IRQ BALANCING (for USB NICs)
# ─────────────────────────────────────────────────────────────────────────────
install_irq_balancing() {
    step "IRQ BALANCING"
    
    cat > /usr/local/bin/ci5-irq-balance << 'IRQ'
#!/bin/sh
# CI5 IRQ Balancing for USB 3.0 NICs
# Pins USB/xHCI interrupts to performance cores

# Detect number of CPUs
NCPU=$(nproc 2>/dev/null || echo 4)

# On Pi5: CPUs 2,3 are performance cores
# Affinity mask 0c = CPUs 2,3 (binary: 1100)
if [ "$NCPU" -ge 4 ]; then
    AFFINITY="0c"
else
    AFFINITY="03"
fi

for irq in $(grep -E 'xhci|usb|eth' /proc/interrupts 2>/dev/null | cut -d: -f1 | tr -d ' '); do
    echo "$AFFINITY" > /proc/irq/$irq/smp_affinity 2>/dev/null && \
        echo "IRQ $irq -> CPUs $AFFINITY"
done
IRQ
    chmod +x /usr/local/bin/ci5-irq-balance
    
    # Run now
    /usr/local/bin/ci5-irq-balance || true
    
    # Run on boot
    if [ -f /etc/rc.local ]; then
        grep -q 'ci5-irq-balance' /etc/rc.local 2>/dev/null || {
            sed -i '/^exit 0/i /usr/local/bin/ci5-irq-balance >/dev/null 2>&1' /etc/rc.local 2>/dev/null || \
            echo '/usr/local/bin/ci5-irq-balance >/dev/null 2>&1' >> /etc/rc.local
        }
    else
        cat > /etc/rc.local << 'RC'
#!/bin/sh
/usr/local/bin/ci5-irq-balance >/dev/null 2>&1
exit 0
RC
        chmod +x /etc/rc.local
    fi
    
    # Also create systemd service if applicable
    if [ -d /etc/systemd/system ]; then
        cat > /etc/systemd/system/ci5-irq-balance.service << 'SYSTEMD'
[Unit]
Description=CI5 IRQ Balancing
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ci5-irq-balance
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SYSTEMD
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable ci5-irq-balance 2>/dev/null || true
    fi
    
    info "IRQ balancing configured"
}

# ─────────────────────────────────────────────────────────────────────────────
# SQM/QOS (CAKE)
# ─────────────────────────────────────────────────────────────────────────────
install_sqm() {
    step "SQM/QOS (BUFFERBLOAT FIX)"
    
    if [ "$PLATFORM" = "openwrt" ]; then
        # OpenWRT: Use native SQM
        opkg update >/dev/null 2>&1 || true
        opkg install sqm-scripts sqm-scripts-extra 2>/dev/null || opkg install sqm-scripts
        
        # Auto-detect WAN interface
        WAN_IF=$(uci get network.wan.device 2>/dev/null || uci get network.wan.ifname 2>/dev/null || echo "eth1")
        
        # Configure SQM (speeds set to 0 = user must configure)
        uci batch << EOF 2>/dev/null
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
        /etc/init.d/sqm enable 2>/dev/null || true
        /etc/init.d/sqm start 2>/dev/null || true
        
        info "SQM installed (OpenWRT)"
        warn "Configure speeds: uci set sqm.wan.download=XXX; uci set sqm.wan.upload=XXX; uci commit sqm"
    else
        # Other Linux: Create CAKE script
        cat > /usr/local/bin/ci5-sqm << 'SQM'
#!/bin/sh
# ═══════════════════════════════════════════════════════════════════════════
# CI5 SIMPLE SQM (CAKE)
# Usage: ci5-sqm <interface> <download_mbps> <upload_mbps>
# Example: ci5-sqm eth0 100 20
# ═══════════════════════════════════════════════════════════════════════════

WAN_IF="${1:-eth0}"
DOWN="${2:-0}"
UP="${3:-0}"

usage() {
    echo "Usage: ci5-sqm <interface> <download_mbps> <upload_mbps>"
    echo "Example: ci5-sqm eth0 100 20"
    echo ""
    echo "Current qdisc on interfaces:"
    tc qdisc show 2>/dev/null | grep -E '^qdisc' | head -5
    exit 1
}

# Show current config if no args
[ "$DOWN" = "0" ] || [ "$UP" = "0" ] && usage

# Check interface exists
[ -d "/sys/class/net/$WAN_IF" ] || { echo "ERROR: Interface $WAN_IF not found"; exit 1; }

# Apply CAKE
echo "Applying CAKE SQM to $WAN_IF..."

# Egress (upload) - apply to interface directly
tc qdisc replace dev "$WAN_IF" root cake bandwidth "${UP}mbit" besteffort

# Ingress (download) - requires IFB (Intermediate Functional Block)
modprobe ifb 2>/dev/null || true
ip link add ifb0 type ifb 2>/dev/null || true
ip link set ifb0 up

tc qdisc replace dev "$WAN_IF" handle ffff: ingress
tc filter replace dev "$WAN_IF" parent ffff: protocol all u32 match u32 0 0 action mirred egress redirect dev ifb0
tc qdisc replace dev ifb0 root cake bandwidth "${DOWN}mbit" besteffort wash

echo ""
echo "✓ SQM Active:"
echo "  Download: ${DOWN} Mbps (CAKE on ifb0)"
echo "  Upload:   ${UP} Mbps (CAKE on $WAN_IF)"
echo ""
echo "Test at: https://www.waveform.com/tools/bufferbloat"
SQM
        chmod +x /usr/local/bin/ci5-sqm
        
        # Create disable script
        cat > /usr/local/bin/ci5-sqm-disable << 'DISABLE'
#!/bin/sh
echo "Removing SQM..."
tc qdisc del dev ifb0 root 2>/dev/null || true
tc qdisc del dev "$1" ingress 2>/dev/null || true
tc qdisc del dev "$1" root 2>/dev/null || true
echo "SQM disabled"
DISABLE
        chmod +x /usr/local/bin/ci5-sqm-disable
        
        info "SQM script installed"
        warn "Enable with: ci5-sqm <interface> <down_mbps> <up_mbps>"
        warn "Example: ci5-sqm eth0 100 20"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# UNINSTALL SCRIPT
# ─────────────────────────────────────────────────────────────────────────────
create_uninstall() {
    cat > /usr/local/bin/ci5-minimal-uninstall << 'UNINSTALL'
#!/bin/sh
echo "Removing CI5 Minimal Performance tuning..."

# Restore sysctl
[ -f /etc/sysctl.conf.ci5bak ] && mv /etc/sysctl.conf.ci5bak /etc/sysctl.conf
rm -f /etc/sysctl.d/99-ci5-performance.conf

# Remove scripts
rm -f /usr/local/bin/ci5-irq-balance
rm -f /usr/local/bin/ci5-sqm
rm -f /usr/local/bin/ci5-sqm-disable

# Remove from rc.local
[ -f /etc/rc.local ] && sed -i '/ci5-irq-balance/d' /etc/rc.local

# Remove systemd service
rm -f /etc/systemd/system/ci5-irq-balance.service
systemctl daemon-reload 2>/dev/null || true

# Reload defaults
sysctl --system >/dev/null 2>&1 || true

echo "✓ CI5 Minimal removed. Reboot recommended."
UNINSTALL
    chmod +x /usr/local/bin/ci5-minimal-uninstall
}

# ─────────────────────────────────────────────────────────────────────────────
# FINALIZATION
# ─────────────────────────────────────────────────────────────────────────────
finalize() {
    cat << 'EOF'

    ╔═══════════════════════════════════════════════════════════════════╗
    ║  ✓ CI5 MINIMAL PERFORMANCE INSTALLED                              ║
    ╠═══════════════════════════════════════════════════════════════════╣
    ║                                                                   ║
    ║  WHAT'S INSTALLED:                                                ║
    ║    • Sysctl network tuning (BBR, buffers, conntrack)              ║
    ║    • IRQ balancing for USB NICs                                   ║
    ║    • SQM/CAKE scripts for bufferbloat                             ║
    ║                                                                   ║
    ║  WHAT'S NOT INSTALLED:                                            ║
    ║    ✗ No Docker                                                    ║
    ║    ✗ No services/daemons                                          ║
    ║    ✗ No HWID/ecosystem                                            ║
    ║    ✗ No cloud callbacks                                           ║
    ║                                                                   ║
    ║  NEXT STEPS:                                                      ║
EOF
    
    if [ "$PLATFORM" = "openwrt" ]; then
        cat << 'EOF'
    ║    1. Configure SQM speeds in LuCI or via:                        ║
    ║       uci set sqm.wan.download=YOUR_DOWN_SPEED                    ║
    ║       uci set sqm.wan.upload=YOUR_UP_SPEED                        ║
    ║       uci commit sqm && /etc/init.d/sqm restart                   ║
EOF
    else
        cat << 'EOF'
    ║    1. Enable SQM with your actual speeds:                         ║
    ║       ci5-sqm eth0 <download_mbps> <upload_mbps>                  ║
    ║       Example: ci5-sqm eth0 100 20                                ║
EOF
    fi
    
    cat << 'EOF'
    ║                                                                   ║
    ║    2. Test bufferbloat:                                           ║
    ║       https://www.waveform.com/tools/bufferbloat                  ║
    ║                                                                   ║
    ║  UNINSTALL:                                                       ║
    ║    ci5-minimal-uninstall                                          ║
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
    printf "═══════════════════════════════════════════════════════════════\n"
    printf "This will install network tuning ONLY. No Docker, no services.\n"
    printf "═══════════════════════════════════════════════════════════════\n\n"
    
    printf "Continue? [Y/n]: "
    read -r ans
    case "$ans" in
        n|N) echo "Aborted."; exit 0 ;;
    esac
    
    detect_platform
    install_sysctl_tuning
    install_irq_balancing
    install_sqm
    create_uninstall
    finalize
}

main "$@"
