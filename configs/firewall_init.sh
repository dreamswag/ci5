#!/bin/sh
# Ci5 Firewall Logic (Hardened & Fixed)

echo "🔥 Configuring Firewall Zones & Rules..."

# 1. Reset & Defaults
uci -q delete firewall.docker
uci -q delete firewall.iot
uci -q delete firewall.guest
uci set firewall.@defaults[0].input='REJECT'
uci set firewall.@defaults[0].output='ACCEPT'
uci set firewall.@defaults[0].forward='REJECT'
uci set firewall.@defaults[0].synflood_protect='1'

# 2. Zone Definitions

# WAN (Internet)
uci set firewall.@zone[1].name='wan'
uci set firewall.@zone[1].input='REJECT'
uci set firewall.@zone[1].output='ACCEPT'
uci set firewall.@zone[1].forward='REJECT'
uci set firewall.@zone[1].masq='1'
uci set firewall.@zone[1].mtu_fix='1'
uci -q del firewall.@zone[1].network
uci add_list firewall.@zone[1].network='wan'
uci add_list firewall.@zone[1].network='wan6'

# LAN (Trusted: Mgmt + PC + Mobile)
uci set firewall.@zone[0].name='lan'
uci set firewall.@zone[0].input='ACCEPT'
uci set firewall.@zone[0].output='ACCEPT'
uci set firewall.@zone[0].forward='ACCEPT'
uci -q del firewall.@zone[0].network
uci add_list firewall.@zone[0].network='lan'
uci add_list firewall.@zone[0].network='vlan10'
uci add_list firewall.@zone[0].network='vlan20'

# IoT (Restricted: Hue/Smart Devices)
uci add firewall zone
uci set firewall.@zone[-1].name='iot'
uci set firewall.@zone[-1].input='REJECT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='REJECT'
uci add_list firewall.@zone[-1].network='vlan30'

# Guest (Restricted: Flatmate)
uci add firewall zone
uci set firewall.@zone[-1].name='guest'
uci set firewall.@zone[-1].input='REJECT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='REJECT'
uci add_list firewall.@zone[-1].network='vlan40'

# Docker (Isolated Container Network)
uci add firewall zone
uci set firewall.@zone[-1].name='docker'
uci set firewall.@zone[-1].input='REJECT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='REJECT'
uci add_list firewall.@zone[-1].network='docker'

# 3. Forwarding (Who can access the Internet?)
for zone in lan iot guest docker; do
    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src="$zone"
    uci set firewall.@forwarding[-1].dest='wan'
done

# Allow LAN to access Docker
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='lan'
uci set firewall.@forwarding[-1].dest='docker'

# 4. Critical Rules

# Allow DHCP & DNS for Restricted Zones
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

# Allow Docker to reach AdGuard/Unbound
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-Docker-DNS'
uci set firewall.@rule[-1].src='docker'
uci set firewall.@rule[-1].dest='lan'
uci set firewall.@rule[-1].dest_ip='192.168.99.1'
uci set firewall.@rule[-1].proto='tcp udp'
uci set firewall.@rule[-1].dest_port='53 5335'
uci set firewall.@rule[-1].target='ACCEPT'

# Block External DNS
for zone in lan iot guest; do
    uci add firewall rule
    uci set firewall.@rule[-1].name="Block-DoH-$zone"
    uci set firewall.@rule[-1].src="$zone"
    uci set firewall.@rule[-1].dest='wan'
    uci set firewall.@rule[-1].proto='tcp udp'
    uci set firewall.@rule[-1].dest_port='853'
    uci set firewall.@rule[-1].target='REJECT'
done

# Block WAN Management
uci add firewall rule
uci set firewall.@rule[-1].name='Block-WAN-Mgmt'
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].dest_port='22 80 443 3000 3001'
uci set firewall.@rule[-1].target='REJECT'

# Explicitly Block Docker from touching IoT/Guest
for dest in lan iot guest; do
    uci add firewall rule
    uci set firewall.@rule[-1].name="Block-Docker-to-$dest"
    uci set firewall.@rule[-1].src='docker'
    uci set firewall.@rule[-1].dest="$dest"
    uci set firewall.@rule[-1].target='REJECT'
done

uci commit firewall
/etc/init.d/firewall restart
