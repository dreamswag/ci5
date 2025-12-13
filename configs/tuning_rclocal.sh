#!/bin/sh
# CI5 NUCLEAR TUNING - RC.LOCAL
# Matches "Bone Marrow Report" for 0ms Latency
# -----------------------------

# 1. CPU Packet Steering (RPS)
for dev in eth0 eth1; do
  if [ -d /sys/class/net/$dev/queues/rx-0 ]; then
    echo f > /sys/class/net/$dev/queues/rx-0/rps_cpus
    echo 4096 > /sys/class/net/$dev/queues/rx-0/rps_flow_cnt
  fi
done
sysctl -w net.core.rps_sock_flow_entries=16384

# 2. DISABLE Flow Control (Let CAKE manage congestion)
ethtool -A eth0 rx off tx off 2>/dev/null
ethtool -A eth1 rx off tx off 2>/dev/null

# 3. DISABLE Hardware Offloading (CRITICAL FOR A+)
ethtool -K eth0 tso off gso off gro off ufo off 2>/dev/null
ethtool -K eth1 tso off gso off gro off ufo off 2>/dev/null

# 4. Disable EEE (Energy Efficient Ethernet)
ethtool --set-eee eth0 eee off 2>/dev/null
ethtool --set-eee eth1 eee off 2>/dev/null

# 5. Increase Ring Buffer (Safe with CAKE)
ethtool -G eth1 rx 4096 2>/dev/null

exit 0
