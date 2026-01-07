#!/bin/sh
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  CI5 NIC TUNING MODULE                                                    ║
# ║  Profile-specific kernel optimizations for USB3, HAT, and AP-less modes   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Profiles:
#   usb3   - USB 3.0 NIC (RTL8153, etc.) - Disable offloads, USB-specific IRQ
#   hat    - PCIe HAT NIC (i225, RTL8125) - Can use some offloads, PCIe tuning
#   apless - AP-less mode (onboard eth0 to PC, WiFi for personal)

# Load soul config if available
SOUL_FILE="/etc/ci5/soul.conf"
[ -f "$SOUL_FILE" ] && . "$SOUL_FILE"

NIC_PROFILE="${NIC_PROFILE:-usb3}"
WAN_IF="${WAN_IF:-eth1}"
LAN_IF="${LAN_IF:-eth0}"

# Colors (for standalone use)
G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
info() { printf "${G}[✓]${N} %s\n" "$1"; }
warn() { printf "${Y}[!]${N} %s\n" "$1"; }

# ─────────────────────────────────────────────────────────────────────────────
# COMMON SYSCTL (All profiles)
# ─────────────────────────────────────────────────────────────────────────────
apply_common_sysctl() {
    cat > /etc/sysctl.d/99-ci5-common.conf << 'EOF'
# CI5 Common Network Tuning

# Congestion Control
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# Connection Tracking
net.netfilter.nf_conntrack_max=131072
net.netfilter.nf_conntrack_tcp_timeout_established=7200

# Routing
net.ipv4.ip_forward=1
net.ipv4.conf.all.forwarding=1
net.ipv6.conf.all.forwarding=1

# TCP Optimization
net.ipv4.tcp_fin_timeout=30
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=60
net.ipv4.tcp_keepalive_probes=5
net.core.somaxconn=4096

# Reduce latency
net.ipv4.tcp_low_latency=1
net.ipv4.tcp_fastopen=3

# ARP cache
net.ipv4.neigh.default.gc_thresh1=1024
net.ipv4.neigh.default.gc_thresh2=2048
net.ipv4.neigh.default.gc_thresh3=4096
EOF
    info "Applied common sysctl settings"
}

# ─────────────────────────────────────────────────────────────────────────────
# USB 3.0 NIC TUNING (RTL8153, AX88179, etc.)
# ─────────────────────────────────────────────────────────────────────────────
apply_usb3_tuning() {
    info "Applying USB 3.0 NIC tuning profile"

    cat > /etc/sysctl.d/99-ci5-usb3.conf << 'EOF'
# CI5 USB 3.0 NIC Tuning
# Optimized for RTL8153 and similar USB GbE adapters

# 16MB Buffer Standard (USB benefits from larger buffers)
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=262144
net.core.wmem_default=262144
net.ipv4.tcp_rmem=4096 131072 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192

# USB-specific: Increase backlog to handle USB latency
net.core.netdev_max_backlog=10000
net.core.netdev_budget=600
net.core.netdev_budget_usecs=8000

# Reduce CPU overhead
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
EOF

    # Disable ALL hardware offloads for USB NICs (they cause issues)
    for dev in eth1 $WAN_IF; do
        [ -d "/sys/class/net/$dev" ] || continue
        ethtool -K "$dev" tso off gso off gro off lro off 2>/dev/null || true
        ethtool -K "$dev" tx off rx off sg off 2>/dev/null || true
        ethtool -K "$dev" tx-checksum-ip-generic off 2>/dev/null || true
        ethtool -K "$dev" tx-scatter-gather off 2>/dev/null || true
        # Disable flow control (reduces latency)
        ethtool -A "$dev" rx off tx off 2>/dev/null || true
        # Disable EEE (Energy Efficient Ethernet causes latency spikes)
        ethtool --set-eee "$dev" eee off 2>/dev/null || true
        # Minimize interrupt coalescing
        ethtool -C "$dev" adaptive-rx off adaptive-tx off 2>/dev/null || true
        ethtool -C "$dev" rx-usecs 0 tx-usecs 0 2>/dev/null || true
        info "Disabled offloads on $dev (USB NIC)"
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# HAT NIC TUNING (PCIe - Intel i225, Realtek 8125, etc.)
# ─────────────────────────────────────────────────────────────────────────────
apply_hat_tuning() {
    info "Applying HAT NIC (PCIe) tuning profile"

    cat > /etc/sysctl.d/99-ci5-hat.conf << 'EOF'
# CI5 HAT NIC (PCIe) Tuning
# Optimized for Intel i225/i226, Realtek RTL8125 (2.5GbE)

# Larger buffers for 2.5GbE throughput
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.core.rmem_default=524288
net.core.wmem_default=524288
net.ipv4.tcp_rmem=4096 524288 33554432
net.ipv4.tcp_wmem=4096 262144 33554432
net.ipv4.udp_rmem_min=16384
net.ipv4.udp_wmem_min=16384

# PCIe can handle higher backlog
net.core.netdev_max_backlog=30000
net.core.netdev_budget=1200
net.core.netdev_budget_usecs=4000

# TCP settings
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_window_scaling=1
EOF

    # Disable ALL offloads - required for CAKE accuracy and IDS inspection
    # Pi 5 has plenty of CPU headroom for software packet processing
    for dev in eth2 $WAN_IF; do
        [ -d "/sys/class/net/$dev" ] || continue

        # Get driver for logging
        driver=""
        [ -L "/sys/class/net/$dev/device/driver" ] && \
            driver=$(basename "$(readlink /sys/class/net/$dev/device/driver)")

        # Disable ALL hardware offloads (CAKE + IDS requirement)
        ethtool -K "$dev" tso off gso off gro off lro off 2>/dev/null || true
        ethtool -K "$dev" tx off rx off sg off 2>/dev/null || true
        ethtool -K "$dev" tx-checksum-ip-generic off 2>/dev/null || true
        ethtool -K "$dev" tx-scatter-gather off 2>/dev/null || true

        # Disable flow control (reduces latency)
        ethtool -A "$dev" rx off tx off 2>/dev/null || true

        # Disable EEE (Energy Efficient Ethernet causes latency spikes)
        ethtool --set-eee "$dev" eee off 2>/dev/null || true

        # PCIe-specific: larger ring buffers for 2.5GbE throughput
        case "$driver" in
            igc)
                ethtool -G "$dev" rx 4096 tx 4096 2>/dev/null || true
                ;;
            r8169)
                ethtool -G "$dev" rx 1024 tx 1024 2>/dev/null || true
                ;;
        esac

        # Minimize interrupt coalescing for latency
        ethtool -C "$dev" adaptive-rx off adaptive-tx off 2>/dev/null || true
        ethtool -C "$dev" rx-usecs 0 tx-usecs 0 2>/dev/null || true

        info "Disabled offloads on $dev (HAT NIC - $driver)"
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# AP-LESS MODE TUNING (eth0 to PC, WiFi for personal use)
# ─────────────────────────────────────────────────────────────────────────────
apply_apless_tuning() {
    info "Applying AP-less mode tuning"

    # Use USB3 tuning as base (for the WAN NIC)
    apply_usb3_tuning

    cat >> /etc/sysctl.d/99-ci5-apless.conf << 'EOF'
# CI5 AP-less Mode Additions

# WiFi client mode benefits
net.ipv4.tcp_slow_start_after_idle=0

# Optimize for single-client (PC) on eth0
net.core.optmem_max=65536
EOF

    # Configure onboard eth0 for direct PC connection
    # Still disable offloads - traffic routes through CAKE/IDS
    if [ -d "/sys/class/net/eth0" ]; then
        ethtool -K eth0 tso off gso off gro off lro off 2>/dev/null || true
        ethtool -K eth0 tx off rx off sg off 2>/dev/null || true
        ethtool -A eth0 rx off tx off 2>/dev/null || true
        ethtool --set-eee eth0 eee off 2>/dev/null || true
        ethtool -C eth0 adaptive-rx off adaptive-tx off 2>/dev/null || true
        info "Disabled offloads on eth0 (PC connection)"
    fi

    # Configure WiFi interface
    if [ -d "/sys/class/net/wlan0" ]; then
        info "WiFi interface detected (wlan0) - used as LAN"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# IRQ AFFINITY
# ─────────────────────────────────────────────────────────────────────────────
setup_irq_affinity() {
    info "Configuring IRQ affinity"

    # Pi 5 has 4 cores (0-3)
    # Strategy: Dedicate cores to network processing
    #   Core 0: System
    #   Core 1: WAN NIC
    #   Core 2: LAN NIC
    #   Core 3: Applications/Docker

    case "$NIC_PROFILE" in
        hat)
            # HAT NICs typically have their own IRQ line on PCIe
            for irq in $(grep -l "$WAN_IF" /proc/irq/*/smp_affinity 2>/dev/null | cut -d/ -f4); do
                echo 2 > /proc/irq/$irq/smp_affinity 2>/dev/null || true  # Core 1
            done
            ;;
        usb3)
            # USB3 shares xHCI controller
            for irq in $(grep -l "xhci" /proc/irq/*/smp_affinity 2>/dev/null | cut -d/ -f4); do
                echo 2 > /proc/irq/$irq/smp_affinity 2>/dev/null || true  # Core 1
            done
            ;;
    esac

    # LAN (eth0/onboard) to Core 2
    for irq in $(grep -l "eth0\|bcmgenet" /proc/irq/*/smp_affinity 2>/dev/null | cut -d/ -f4); do
        echo 4 > /proc/irq/$irq/smp_affinity 2>/dev/null || true  # Core 2
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN APPLY FUNCTION
# ─────────────────────────────────────────────────────────────────────────────
apply_nic_tuning() {
    # Apply common settings
    apply_common_sysctl

    # Apply profile-specific settings
    case "$NIC_PROFILE" in
        hat)    apply_hat_tuning ;;
        apless) apply_apless_tuning ;;
        usb3|*) apply_usb3_tuning ;;
    esac

    # Apply IRQ affinity
    setup_irq_affinity

    # Load all sysctl settings
    sysctl --system >/dev/null 2>&1

    info "NIC tuning applied (profile: $NIC_PROFILE)"
}

# ─────────────────────────────────────────────────────────────────────────────
# STANDALONE MODE SWITCH (for post-install changes)
# ─────────────────────────────────────────────────────────────────────────────
switch_nic_profile() {
    case "$1" in
        usb3|hat|apless)
            NIC_PROFILE="$1"
            ;;
        *)
            printf "Usage: $0 switch <usb3|hat|apless>\n"
            printf "\nProfiles:\n"
            printf "  usb3   - USB 3.0 NIC (eth1) - Realtek RTL8153, etc.\n"
            printf "  hat    - PCIe HAT NIC (eth2) - Intel i225, RTL8125\n"
            printf "  apless - AP-less (eth0→PC, WiFi→Personal)\n"
            return 1
            ;;
    esac

    # Update soul config
    if [ -f "$SOUL_FILE" ]; then
        sed -i "s/^NIC_PROFILE=.*/NIC_PROFILE=\"$NIC_PROFILE\"/" "$SOUL_FILE"
    fi

    # Re-apply tuning
    apply_nic_tuning

    printf "${G}Switched to $NIC_PROFILE profile${N}\n"
    printf "${Y}Note: WAN interface change may require network restart${N}\n"
}

# ─────────────────────────────────────────────────────────────────────────────
# CLI INTERFACE
# ─────────────────────────────────────────────────────────────────────────────
if [ "${1:-}" = "apply" ]; then
    apply_nic_tuning
elif [ "${1:-}" = "switch" ]; then
    switch_nic_profile "$2"
elif [ "${1:-}" = "status" ]; then
    printf "NIC Profile: ${C}$NIC_PROFILE${N}\n"
    printf "WAN Interface: ${C}$WAN_IF${N}\n"
    printf "LAN Interface: ${C}$LAN_IF${N}\n"
    printf "AP-less Mode: ${C}${APLESS_MODE:-0}${N}\n"
fi
