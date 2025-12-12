#!/bin/sh
# OpenWrt startup script - network optimizations

# ----------------------------------------------------------------
# ☢️ NUCLEAR LATENCY TUNING (The Secret Sauce)
# ----------------------------------------------------------------
# Disabling hardware offloading forces the Pi 5 CPU (Cortex-A76)
# to process every packet individually. This allows CAKE to
# perfectly interleave gaming packets with bulk downloads.
# ----------------------------------------------------------------

for dev in eth0 eth1; do
  # Disable: 
  # - GRO (Generic Receive Offload)
  # - GSO (Generic Segmentation Offload)
  # - TSO (TCP Segmentation Offload)
  ethtool -K $dev gro off gso off tso off 2>/dev/null
  logger -t ci5-tuning "☢️ Nuclear Mode engaged on $dev"
done

# Enable RPS (Receive Packet Steering)
for dev in eth0 eth1; do
  if [ -d /sys/class/net/$dev/queues/rx-0 ]; then
    echo f > /sys/class/net/$dev/queues/rx-0/rps_cpus
    echo 4096 > /sys/class/net/$dev/queues/rx-0/rps_flow_cnt
  fi
done

exit 0
