#!/bin/sh
# Full working network topology – VLANs 10/20/30/40 + management

echo "[*] Configuring network – WAN + br-lan + 4 VLANs"

# WAN
uci set network.wan.device="${WAN_IFACE:-eth1}"
if [ "$WAN_PROTO" = "pppoe" ]; then
    uci set network.wan.proto='pppoe'
    uci set network.wan.username="$PPPOE_USER"
    uci set network.wan.password="$PPPOE_PASS"
    uci set network.wan.ipv6='auto'
else
    uci set network.wan.proto='dhcp'
    uci set network.wan.ipv6='auto='1'
fi

# Management LAN
uci set network.lan.proto='static'
uci set network.lan.device='eth0'
uci set network.lan.ipaddr='192.168.99.1'
uci set network.lan.netmask='255.255.255.0'

# VLANs 10/20/30/40 on eth0 (Pi5 onboard port)
for vlan in 10 20 30 40; do
    uci set network.vlan${vlan}=interface
    uci set network.vlan${vlan}.proto='static'
    uci set network.vlan${vlan}.device="eth0.${vlan}"
    uci set network.vlan${vlan}.ipaddr="10.10.${vlan}.1"
    uci set network.vlan${vlan}.netmask='255.255.255.0'
done

# DHCP per VLAN
for vlan in 10 20 30 40; do
    uci set dhcp.vlan${vlan}=dhcp
    uci set dhcp.vlan${vlan}.interface="vlan${vlan}"
    uci set dhcp.vlan${vlan}.start='100'
    uci set dhcp.vlan${vlan}.limit='150'
    uci set dhcp.vlan${vlan}.leasetime='12h'
done

uci commit network
uci commit dhcp
echo "[✓] Network configuration complete"
