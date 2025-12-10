#!/bin/sh
# Moves dnsmasq off port 53 and disables WAN peering

# Set DNSmasq to listen on a non-standard port for AGH/Unbound to use
uci set dhcp.@dnsmasq[0].port='53535'
uci set dhcp.@dnsmasq[0].noresolv='1'
uci set dhcp.@dnsmasq[0].localservice='0'
# Set DNS option to point clients to the router's main IP (where AGH is)
uci set dhcp.lan.dhcp_option='6,192.168.99.1'
uci set dhcp.vlan10.dhcp_option='6,10.10.10.1'
uci set dhcp.vlan20.dhcp_option='6,10.10.20.1'
uci set dhcp.vlan30.dhcp_option='6,10.10.30.1'
uci set dhcp.vlan40.dhcp_option='6,10.10.40.1'

# Final UCI commit
uci commit dhcp
/etc/init.d/dnsmasq restart
