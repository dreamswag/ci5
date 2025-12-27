#!/bin/sh
echo "🔥 [Tuning] Setting CPU Governor to Performance..."
echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null

for net_path in /sys/class/net/*; do
    dev=$(basename "$net_path")
    case "$dev" in
        lo|docker*|veth*|br-*|wlan*|tailscale*|wg*) continue ;;
    esac
    if [ -e "$net_path/device" ]; then
        if [ -d "$net_path/queues/rx-0" ]; then
            echo f > "$net_path/queues/rx-0/rps_cpus"
            echo 4096 > "$net_path/queues/rx-0/rps_flow_cnt"
        fi
        ethtool -K "$dev" tso off gso off gro off ufo off 2>/dev/null
        ethtool -A "$dev" rx off tx off 2>/dev/null
        ethtool --set-eee "$dev" eee off 2>/dev/null
        ethtool -G "$dev" rx 4096 2>/dev/null
        if grep -q "1" "$net_path/carrier" 2>/dev/null; then
             ethtool -C "$dev" adaptive-rx off adaptive-tx off rx-usecs 0 tx-usecs 0 2>/dev/null
        fi
    fi
done
sysctl -w net.core.rps_sock_flow_entries=16384 >/dev/null
exit 0
