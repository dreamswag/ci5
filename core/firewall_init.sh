#!/bin/sh
# 🔥 Ci5 Firewall Init (v7.4-RC-1 - Idempotent)
echo "🔥 Configuring Firewall..."

# Clear custom zones first (idempotent)
uci -q delete firewall.docker
uci -q delete firewall.iot
uci -q delete firewall.guest

# Clear custom rules (find and delete by name)
while uci -q delete firewall.@rule[-1]; do :; done 2>/dev/null
while uci -q delete firewall.@forwarding[-1]; do :; done 2>/dev/null

# Defaults
uci set firewall.@defaults[0].input='REJECT'
uci set firewall.@defaults[0].output='ACCEPT'
uci set firewall.@defaults[0].forward='REJECT'
uci set firewall.@defaults[0].synflood_protect='1'

# WAN Zone
uci set firewall.@zone[1].name='wan'
uci set firewall.@zone[1].input='REJECT'
uci set firewall.@zone[1].output='ACCEPT'
uci set firewall.@zone[1].forward='REJECT'
uci set firewall.@zone[1].masq='1'
uci set firewall.@zone[1].mtu_fix='1'
uci -q del firewall.@zone[1].network
uci add_list firewall.@zone[1].network='wan'
uci add_list firewall.@zone[1].network='wan6'

# LAN Zone
uci set firewall.@zone[0].name='lan'
uci set firewall.@zone[0].input='ACCEPT'
uci set firewall.@zone[0].output='ACCEPT'
uci set firewall.@zone[0].forward='ACCEPT'
uci -q del firewall.@zone[0].network
uci add_list firewall.@zone[0].network='lan'
uci add_list firewall.@zone[0].network='vlan10'
uci add_list firewall.@zone[0].network='vlan20'

# IoT Zone
uci add firewall zone
uci set firewall.@zone[-1].name='iot'
uci set firewall.@zone[-1].input='REJECT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='REJECT'
uci add_list firewall.@zone[-1].network='vlan30'

# Guest Zone
uci add firewall zone
uci set firewall.@zone[-1].name='guest'
uci set firewall.@zone[-1].input='REJECT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='REJECT'
uci add_list firewall.@zone[-1].network='vlan40'

# Docker Zone
uci add firewall zone
uci set firewall.@zone[-1].name='docker'
uci set firewall.@zone[-1].input='REJECT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='REJECT'
uci add_list firewall.@zone[-1].network='docker'

# Forwardings
for zone in lan iot guest docker; do
    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src="$zone"
    uci set firewall.@forwarding[-1].dest='wan'
done
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='lan'
uci set firewall.@forwarding[-1].dest='docker'

# Rules
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

uci add firewall rule
uci set firewall.@rule[-1].name='Allow-Docker-DNS'
uci set firewall.@rule[-1].src='docker'
uci set firewall.@rule[-1].dest='lan'
uci set firewall.@rule[-1].dest_ip='192.168.99.1'
uci set firewall.@rule[-1].proto='tcp udp'
uci set firewall.@rule[-1].dest_port='53 5335'
uci set firewall.@rule[-1].target='ACCEPT'

uci add firewall rule
uci set firewall.@rule[-1].name='Block-Google-DoH'
uci set firewall.@rule[-1].src='lan'
uci set firewall.@rule[-1].dest='wan'
uci set firewall.@rule[-1].dest_ip='8.8.8.8 8.8.4.4 1.1.1.1 1.0.0.1'
uci set firewall.@rule[-1].proto='tcp udp'
uci set firewall.@rule[-1].dest_port='443 853'
uci set firewall.@rule[-1].target='REJECT'

uci add firewall rule
uci set firewall.@rule[-1].name='Block-WAN-Mgmt'
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].dest_port='22 2222 80 443 3000 3001'
uci set firewall.@rule[-1].target='REJECT'

for dest in lan iot guest; do
    uci add firewall rule
    uci set firewall.@rule[-1].name="Block-Docker-to-$dest"
    uci set firewall.@rule[-1].src='docker'
    uci set firewall.@rule[-1].dest="$dest"
    uci set firewall.@rule[-1].target='REJECT'
done

uci commit firewall
