#!/bin/sh
# 🃏 Ci5 Validation Check (v7.4-RC-1)
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'

[ -f "ci5.config" ] && . ./ci5.config

if [ -n "$WAN_VLAN" ] && [ "$WAN_VLAN" -ne 0 ]; then
    WAN_TARGET="${WAN_IFACE}.${WAN_VLAN}"
else
    WAN_TARGET="${WAN_IFACE:-eth1}"
fi

echo "=========================================="
echo "   🃏 Ci5 Validation Check (v7.4-RC-1)"
echo "   WAN: $WAN_TARGET"
echo "=========================================="

fail=0

# 1. VLANs
echo -n "[*] VLANs (10/20/30/40)... "
vlan_fail=0
for vlan in 10 20 30 40; do
    if ! ip link show eth0.${vlan} >/dev/null 2>&1; then
        [ $vlan_fail -eq 0 ] && echo ""
        echo -e "    ${RED}✗ VLAN $vlan missing${NC}"
        vlan_fail=1; fail=1
    fi
done
[ $vlan_fail -eq 0 ] && echo -e "${GREEN}✓${NC}"

# 2. CAKE SQM
echo -n "[*] SQM (CAKE on $WAN_TARGET)... "
if tc qdisc show dev $WAN_TARGET 2>/dev/null | grep -q cake; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗ Not active${NC}"
    echo "    Fix: /etc/init.d/sqm restart"
    fail=1
fi

# 3. Latency Tuning
echo -n "[*] Offloads Disabled... "
offload_check=$(ethtool -k ${WAN_IFACE:-eth1} 2>/dev/null | grep -E "tcp-segmentation-offload: on|generic-receive-offload: on")
if [ -z "$offload_check" ]; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗ FAILED${NC}"
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

# 5. Docker
echo -n "[*] Docker... "
if docker info >/dev/null 2>&1; then
    running=$(docker ps --filter "status=running" --format '{{.Names}}' 2>/dev/null | wc -l)
    if [ "$running" -gt 0 ]; then
        echo -e "${GREEN}✓ ($running containers)${NC}"
        for svc in adguardhome suricata crowdsec; do
            if ! docker ps | grep -q "$svc"; then
                echo -e "    ${YELLOW}⚠ $svc not running${NC}"
            fi
        done
        if grep -q "PASSWORD_HASH_GOES_HERE" /opt/ci5-docker/adguard/conf/AdGuardHome.yaml 2>/dev/null; then
             echo -e "    ${YELLOW}⚠ AdGuard password not set${NC}"
        fi
    else
        echo -e "${YELLOW}⚠ No containers running${NC}"
    fi
else
    echo "⊘ Not installed (Lite mode)"
fi

# 6. Internet
echo -n "[*] Internet Connectivity... "
if ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗ No Internet${NC}"
    fail=1
fi

echo "=========================================="
exit $fail
