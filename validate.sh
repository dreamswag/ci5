#!/bin/sh
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=========================================="
echo "   🃏 Ci5 Validation Check"
echo "=========================================="
echo ""

fail=0

# 1. VLANs
echo -n "[*] VLANs (10/20/30/40)... "
vlan_fail=0
for vlan in 10 20 30 40; do
    if ! ip link show eth0.${vlan} >/dev/null 2>&1; then
        [ $vlan_fail -eq 0 ] && echo ""
        echo -e "    ${RED}✗ VLAN $vlan missing${NC}"
        vlan_fail=1
        fail=1
    fi
done
[ $vlan_fail -eq 0 ] && echo -e "${GREEN}✓${NC}"

# 2. CAKE SQM
echo -n "[*] SQM (CAKE on eth1)... "
if tc qdisc show dev eth1 2>/dev/null | grep -q cake; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗ Not active${NC}"
    echo "    Fix: /etc/init.d/sqm restart"
    fail=1
fi

# 3. BBR
echo -n "[*] TCP BBR... "
if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${YELLOW}⚠ Not enabled${NC}"
fi

# 4. Unbound
echo -n "[*] Unbound (port 5335)... "
if pgrep unbound >/dev/null && netstat -ln 2>/dev/null | grep -q ':5335'; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗ Not running${NC}"
    fail=1
fi

# 5. AdGuard
echo -n "[*] AdGuard (port 53)... "
if pgrep adguardhome >/dev/null && netstat -ln 2>/dev/null | grep -q ':53 '; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗ Not running${NC}"
    fail=1
fi

# 6. Firewall
echo -n "[*] Firewall (nftables)... "
if nft list tables 2>/dev/null | grep -q inet; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗ Not active${NC}"
    fail=1
fi

# 7. Docker (if Full)
echo -n "[*] Docker... "
if docker info >/dev/null 2>&1; then
    running=$(docker ps --filter "status=running" --format '{{.Names}}' 2>/dev/null | wc -l)
    if [ "$running" -gt 0 ]; then
        echo -e "${GREEN}✓ ($running containers)${NC}"
    else
        echo -e "${YELLOW}⚠ No containers running${NC}"
    fi
else
    echo "⊘ Not installed (Lite mode)"
fi

# 8. WAN
echo -n "[*] WAN connectivity... "
if ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗ No internet${NC}"
    fail=1
fi

echo ""
echo "=========================================="
if [ $fail -eq 0 ]; then
    echo -e "${GREEN}[✓] ALL GREEN – Ready for deployment!${NC}"
    echo ""
    echo "📝 Next steps:"
    echo "  1. Configure AdGuard: http://192.168.99.1:3000"
    echo "  2. Test bufferbloat: waveform.com/tools/bufferbloat"
    echo "  3. Configure AP with VLANs"
    echo ""
    echo "📊 Monitoring:"
    echo "  - LuCI:   http://192.168.99.1"
    echo "  - Ntopng: http://192.168.99.1:3001 (if Full)"
else
    echo -e "${RED}[✗] Some checks failed${NC}"
    echo ""
    echo "📋 Troubleshooting:"
    echo "  - Logs: logread"
    echo "  - Services: ps | grep -E 'unbound|adguard'"
    echo "  - Reboot: reboot"
fi
echo "=========================================="
exit $fail
