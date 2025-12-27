#!/bin/sh
uci set dhcp.@dnsmasq[0].port='53535'
uci set dhcp.@dnsmasq[0].noresolv='1'
uci set dhcp.@dnsmasq[0].localservice='0'
uci set dhcp.lan.dhcp_option='6,192.168.99.1'
uci set dhcp.vlan10.dhcp_option='6,10.10.10.1'
uci set dhcp.vlan20.dhcp_option='6,10.10.20.1'
uci set dhcp.vlan30.dhcp_option='6,10.10.30.1'
uci set dhcp.vlan40.dhcp_option='6,10.10.40.1'
uci commit dhcp
/etc/init.d/dnsmasq restart
