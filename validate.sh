#!/bin/sh
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=========================================="
echo "   🃏 Ci5 Validation Check"
echo "=========================================="

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

# 3. Latency Tuning (The 0ms check)
echo -n "[*] Nuclear Tuning (Offloads DISABLED)... "
offload_check=$(ethtool -k eth1 2>/dev/null | grep -E "tcp-segmentation-offload: on|generic-receive-offload: on")

if [ -z "$offload_check" ]; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗ FAILED${NC}"
    echo "    Hardware offloading is ON. Latency will suffer."
    fail=1
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

# 6. Docker (if Full)
echo -n "[*] Docker... "
if docker info >/dev/null 2>&1; then
    running=$(docker ps --filter "status=running" --format '{{.Names}}' 2>/dev/null | wc -l)
    if [ "$running" -gt 0 ]; then
        echo -e "${GREEN}✓ ($running containers)${NC}"
        
        # Test Docker DNS resolution
        echo -n "[*] Docker DNS (AdGuard access)... "
        if docker run --rm busybox nslookup google.com 192.168.99.1 >/dev/null 2>&1; then
            echo -e "${GREEN}✓${NC}"
        else
            echo -e "${RED}✗ Cannot resolve via AdGuard${NC}"
            fail=1
        fi
    else
        echo -e "${YELLOW}⚠ No containers running${NC}"
    fi
else
    echo "⊘ Not installed (Lite mode)"
fi

echo ""
echo "=========================================="
if [ $fail -eq 0 ]; then
    echo -e "${GREEN}[✓] ALL GREEN${NC}"
else
    echo -e "${RED}[✗] Checks failed${NC}"
fi
echo "=========================================="
exit $fail
