#!/bin/sh
# 🌐 Ci5 Network Init (v7.4-RC-1 - Idempotent)
echo "[*] Configuring network..."

# ─────────────────────────────────────────────────────────────
# WAN INTERFACE
# ─────────────────────────────────────────────────────────────
if [ -n "$WAN_VLAN" ] && [ "$WAN_VLAN" -ne 0 ]; then
    echo "    -> Configuring WAN on ${WAN_IFACE}.${WAN_VLAN} (Tagged)"
    uci -q delete network.wan_vlan_dev
    uci set network.wan_vlan_dev=device
    uci set network.wan_vlan_dev.name="${WAN_IFACE}.${WAN_VLAN}"
    uci set network.wan_vlan_dev.type='8021q'
    uci set network.wan_vlan_dev.ifname="${WAN_IFACE}"
    uci set network.wan_vlan_dev.vid="${WAN_VLAN}"
    uci set network.wan.device="${WAN_IFACE}.${WAN_VLAN}"
else
    echo "    -> Configuring WAN on ${WAN_IFACE} (Untagged)"
    uci set network.wan.device="${WAN_IFACE:-eth1}"
fi

if [ "$WAN_PROTO" = "pppoe" ]; then
    uci set network.wan.proto='pppoe'
    uci set network.wan.username="$PPPOE_USER"
    uci set network.wan.password="$PPPOE_PASS"
    uci set network.wan.ipv6='auto'
else
    uci set network.wan.proto='dhcp'
    uci set network.wan.ipv6='auto'
fi

# ─────────────────────────────────────────────────────────────
# LAN BRIDGE (Idempotent)
# ─────────────────────────────────────────────────────────────
uci -q delete network.@device[0]
uci add network device
uci set network.@device[-1].name='br-lan'
uci set network.@device[-1].type='bridge'
uci add_list network.@device[-1].ports='eth0'

uci set network.lan.proto='static'
uci set network.lan.device='br-lan'
uci set network.lan.ipaddr='192.168.99.1'
uci set network.lan.netmask='255.255.255.0'

# ─────────────────────────────────────────────────────────────
# VLANs (Idempotent - delete before create)
# ─────────────────────────────────────────────────────────────
for vlan in 10 20 30 40; do
    # Remove existing VLAN config
    uci -q delete network.vlan${vlan}_dev
    uci -q delete network.vlan${vlan}
    
    # Create VLAN device
    uci add network device
    uci set network.@device[-1].name="eth0.${vlan}"
    uci set network.@device[-1].type='8021q'
    uci set network.@device[-1].ifname='eth0'
    uci set network.@device[-1].vid="${vlan}"
    
    # Create VLAN interface
    uci set network.vlan${vlan}=interface
    uci set network.vlan${vlan}.proto='static'
    uci set network.vlan${vlan}.device="eth0.${vlan}"
    uci set network.vlan${vlan}.ipaddr="10.10.${vlan}.1"
    uci set network.vlan${vlan}.netmask='255.255.255.0'
done

# ─────────────────────────────────────────────────────────────
# IPv6
# ─────────────────────────────────────────────────────────────
uci -q delete network.wan6
uci set network.wan6=interface
uci set network.wan6.proto='dhcpv6'
uci set network.wan6.device='@wan'
uci set network.wan6.reqaddress='try'
uci set network.wan6.reqprefix='auto'
uci set network.lan.ip6assign='60'

uci commit network
