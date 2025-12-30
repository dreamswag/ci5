#!/bin/sh
# 🌐 Reinforced Ci5 DHCP Logic
uci set dhcp.@dnsmasq[0].port='53535'
uci set dhcp.@dnsmasq[0].noresolv='1'
uci set dhcp.@dnsmasq[0].localservice='0'

# LAN Infrastructure (Reinforce .99.1)
uci set dhcp.lan.interface='lan'
uci set dhcp.lan.start='100'
uci set dhcp.lan.limit='150'
uci set dhcp.lan.leasetime='12h'
uci set dhcp.lan.dhcp_option='3,192.168.99.1' 
uci set dhcp.lan.dhcp_option='6,192.168.99.1' 

# VLAN DNS Isolation
uci set dhcp.vlan10.dhcp_option='6,10.10.10.1'
uci set dhcp.vlan20.dhcp_option='6,10.10.20.1'
uci set dhcp.vlan30.dhcp_option='6,10.10.30.1'
uci set dhcp.vlan40.dhcp_option='6,10.10.40.1'

uci commit dhcp
/etc/init.d/dnsmasq restart