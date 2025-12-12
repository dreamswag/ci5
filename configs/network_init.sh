#!/bin/sh
# Fixed network topology with proper VLAN device creation

echo "[*] Configuring network – WAN + br-lan + 4 VLANs"

# WAN Configuration (Variables from install-lite export)
uci set network.wan.device="${WAN_IFACE:-eth1}"
if [ "$WAN_PROTO" = "pppoe" ]; then
    uci set network.wan.proto='pppoe'
    uci set network.wan.username="$PPPOE_USER"
    uci set network.wan.password="$PPPOE_PASS"
    uci set network.wan.ipv6='auto'
else
    uci set network.wan.proto='dhcp'
    uci set network.wan.ipv6='auto'
fi

# Create bridge device for LAN
uci set network.@device[0]=device
uci set network.@device[0].name='br-lan'
uci set network.@device[0].type='bridge'
uci add_list network.@device[0].ports='eth0'

# Management LAN
uci set network.lan.proto='static'
uci set network.lan.device='br-lan'
uci set network.lan.ipaddr='192.168.99.1'
uci set network.lan.netmask='255.255.255.0'

# Create VLAN devices explicitly
for vlan in 10 20 30 40; do
    uci add network device
    uci set network.@device[-1].name="eth0.${vlan}"
    uci set network.@device[-1].type='8021q'
    uci set network.@device[-1].ifname='eth0'
    uci set network.@device[-1].vid="${vlan}"
    
    uci set network.vlan${vlan}=interface
    uci set network.vlan${vlan}.proto='static'
    uci set network.vlan${vlan}.device="eth0.${vlan}"
    uci set network.vlan${vlan}.ipaddr="10.10.${vlan}.1"
    uci set network.vlan${vlan}.netmask='255.255.255.0'
done

uci commit network
