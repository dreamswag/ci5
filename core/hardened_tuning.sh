#!/bin/sh
# 🛡️ Phoenix Protocol: Hardened System Tuning (v7.5-RESTORED)
# Target: BCM2712 (Pi 5) | OpenWrt 23.05+
# Merges sysctl.conf and rc.local logic from Source A

echo "[*] Applying Hardened Kernel Tuning..."

# 1. CPU Governor (Force Performance)
# -----------------------------------------------------------------------------
if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
    echo "    -> Setting CPU Governor to 'performance'"
    echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null
fi

# 2. Sysctl Network Optimization (High Bandwidth/Low Latency)
# -----------------------------------------------------------------------------
echo "    -> Applying Sysctl Parameters (16MB Buffers, BBR, CAKE)"
cat << 'EOF' > /etc/sysctl.d/99-phoenix-tuning.conf
# Congestion Control & Queuing
net.core.default_qdisc=cake
net.ipv4.tcp_congestion_control=bbr

# TCP/UDP Buffers (16MB for Gigabit+)
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216

# Connection Tracking (High Capacity)
net.netfilter.nf_conntrack_max=131072
net.netfilter.nf_conntrack_tcp_timeout_established=7200

# Routing & Forwarding
net.ipv4.ip_forward=1
net.ipv4.conf.all.forwarding=1
net.ipv6.conf.all.forwarding=1

# TCP Behavior
net.ipv4.tcp_fin_timeout=30
net.ipv4.tcp_tw_reuse=1
net.core.netdev_max_backlog=5000
net.core.somaxconn=1024

# RPS Flow Entries
net.core.rps_sock_flow_entries=16384

# File System Watchers (for Docker/Apps)
fs.inotify.max_user_instances=128
fs.inotify.max_user_watches=65536
EOF

# Apply immediately
sysctl -p /etc/sysctl.d/99-phoenix-tuning.conf >/dev/null 2>&1

# 3. NIC Offload Killing & Ring Buffer Maximization
# -----------------------------------------------------------------------------
echo "    -> Tuning Network Interfaces (Ethtool & RPS)"

# Iterate physical interfaces only
for net_path in /sys/class/net/*; do
    dev=$(basename "$net_path")

    # Skip virtual/loopback/bridge interfaces
    case "$dev" in
        lo|docker*|veth*|br-*|wlan*|tailscale*|wg*|ifb*) continue ;;
    esac

    if [ -e "$net_path/device" ]; then
        echo "       - Tuning $dev..."

        # Disable Hardware Offloads (Crucial for CAKE/Suricata accuracy)
        ethtool -K "$dev" tso off gso off gro off ufo off 2>/dev/null

        # Disable Flow Control (Let TCP handle it)
        ethtool -A "$dev" rx off tx off 2>/dev/null

        # Disable Energy Efficient Ethernet
        ethtool --set-eee "$dev" eee off 2>/dev/null

        # Maximize Ring Buffers (Prevent drops during bursts)
        ethtool -G "$dev" rx 4096 2>/dev/null

        # Coalesce Settings (Latency optimization)
        if grep -q "1" "$net_path/carrier" 2>/dev/null; then
             ethtool -C "$dev" adaptive-rx off adaptive-tx off rx-usecs 0 tx-usecs 0 2>/dev/null
        fi

        # Enable RPS (Receive Packet Steering) - Distribute IRQs across cores
        # Mask 'f' = 1111 (Use all 4 cores on Pi 5)
        if [ -d "$net_path/queues/rx-0" ]; then
            echo f > "$net_path/queues/rx-0/rps_cpus" 2>/dev/null
            echo 4096 > "$net_path/queues/rx-0/rps_flow_cnt" 2>/dev/null
        fi
    fi
done

# 4. Hardware RNG Enforcement (Crypto Acceleration for TrustZone/Nostr)
# -----------------------------------------------------------------------------
echo "    -> Verifying Hardware RNG..."

if [ -c /dev/hwrng ]; then
    echo "       - Hardware RNG detected (/dev/hwrng)"

    # Check current and available RNG sources
    current_rng=$(cat /sys/class/misc/hw_random/rng_current 2>/dev/null || echo "none")
    available_rng=$(cat /sys/class/misc/hw_random/rng_available 2>/dev/null || echo "")

    echo "       - Current RNG: $current_rng"
    echo "       - Available: $available_rng"

    # If using software timer or none, try to switch to hardware
    if [ "$current_rng" = "timer" ] || [ "$current_rng" = "none" ] || [ -z "$current_rng" ]; then
        # Prefer BCM2712 (Pi 5) or BCM2835 (Pi 4/3) RNG
        preferred=""
        for rng in bcm2712-rng bcm2835-rng iproc-rng200; do
            if echo "$available_rng" | grep -q "$rng"; then
                preferred="$rng"
                break
            fi
        done

        if [ -n "$preferred" ]; then
            echo "$preferred" > /sys/class/misc/hw_random/rng_current 2>/dev/null && \
                echo "       - Switched to $preferred (Hardware)"
        fi
    else
        echo "       - Already using hardware RNG: $current_rng"
    fi

    # Ensure rngd/rng-tools is using hwrng for kernel entropy pool
    if command -v rngd >/dev/null 2>&1; then
        # Check if rngd is running, if not start it
        if ! pgrep -x rngd >/dev/null 2>&1; then
            rngd -r /dev/hwrng 2>/dev/null || true
            echo "       - Started rngd with /dev/hwrng"
        fi
    fi

    # Verify entropy pool is healthy (should be > 256 for crypto operations)
    ENTROPY=$(cat /proc/sys/kernel/random/entropy_avail 2>/dev/null || echo "0")
    if [ "$ENTROPY" -lt 256 ]; then
        echo "       - WARNING: Low entropy ($ENTROPY bits) - crypto ops may block"
    else
        echo "       - Entropy pool healthy: $ENTROPY bits"
    fi
else
    echo "       - WARNING: No Hardware RNG found (/dev/hwrng missing)"
    echo "       - Crypto operations (WireGuard, Nostr) may be slower or less secure"
    echo "       - Consider: opkg install rng-tools haveged"
fi

echo "[✓] Hardened Tuning Applied."
