#!/bin/sh
# Removes AdGuard Home and restores dnsmasq
docker stop adguardhome 2>/dev/null
docker rm adguardhome 2>/dev/null
uci set dhcp.@dnsmasq[0].server='127.0.0.1#5335'
uci commit dhcp
/etc/init.d/dnsmasq restart
echo "✅ AdGuard removed. DNS reverted to Unbound."
