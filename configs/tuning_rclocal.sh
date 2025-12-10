#!/bin/sh
# OpenWrt startup script - network optimizations

# Enable RPS (Receive Packet Steering) on all interfaces
for dev in eth0 eth1; do
  if [ -d /sys/class/net/$dev/queues/rx-0 ]; then
    # Enable all 4 CPU cores: f = 1111 in binary = CPUs 0,1,2,3
    echo f > /sys/class/net/$dev/queues/rx-0/rps_cpus
    # Increase flow tracking for high connection count
    echo 4096 > /sys/class/net/$dev/queues/rx-0/rps_flow_cnt
    logger -t rps "Enabled RPS on $dev"
  fi
done

# Set global RPS flow entries (must be >= sum of all rps_flow_cnt)
sysctl -w net.core.rps_sock_flow_entries=16384

# Disable Energy Efficient Ethernet (EEE) for stability
ethtool --set-eee eth0 eee off 2>/dev/null
ethtool --set-eee eth1 eee off 2>/dev/null

# Increase eth1 ring buffer for WAN
ethtool -G eth1 rx 4096 2>/dev/null

# Start monitoring alert engine if present
# [ -x /root/monitoring/alert_engine.sh ] && /root/monitoring/alert_engine.sh &

exit 0
