#!/bin/sh
# 🌐 Ci5 Network Init (Debian Implant Edition)
# Runs at boot via rc.local on Raspberry Pi OS

# Load Config
. /opt/ci5/ci5.config

echo "[Ci5] Initializing Network..."

# 1. FLUSH & PREP
ip addr flush dev eth0
ip link set eth0 up

# 2. CREATE BRIDGE (LAN)
ip link add name br-lan type bridge
ip link set br-lan up
ip addr add 192.168.99.1/24 dev br-lan

# 3. WAN CONFIGURATION
if [ "$WAN_PROTO" = "pppoe" ]; then
    # PPPoE Mode (Requires 'pppoeconf' or similar, simplified here)
    # Ideally, we trigger the dsl-provider created by setup.sh
    pon dsl-provider
else
    # DHCP Mode (Cable/Starlink)
    # We assume the USB NIC is eth1 (or whatever was detected)
    ip link set $WAN_IFACE up
    dhclient $WAN_IFACE
fi

# 4. LAN PORTS (Bridge eth0 to LAN)
ip link set eth0 master br-lan

echo "[Ci5] Network Active."