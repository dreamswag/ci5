#!/bin/sh
# 🃏 Ci5 Validation Check (v7.4-RC-1)
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'

[ -f "ci5.config" ] && . ./ci5.config
[ -f "/root/ci5/ci5.config" ] && . /root/ci5/ci5.config

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
echo -n "[1/10] VLANs (10/20/30/40)... "
vlan_fail=0
for vlan in 10 20 30 40; do
    if ! ip link show eth0.${vlan} >/dev/null 2>&1; then
        [ $vlan_fail -eq 0 ] && echo ""
        echo -e "    ${RED}✗ VLAN $vlan missing${NC}"
        vlan_fail=1; fail=1
    fi
done
[ $vlan_fail -eq 0 ] && echo -e "${GREEN}✓${NC}"

# 2. CAKE SQM on physical WAN
echo -n "[2/10] SQM (CAKE on $WAN_TARGET)... "
if tc qdisc show dev "$WAN_TARGET" 2>/dev/null | grep -q cake; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗ Not active${NC}"
    echo "    Fix: /etc/init.d/sqm restart"
    fail=1
fi

# 3. No CAKE on pppoe-wan (double shaping check)
echo -n "[3/10] PPPoE qdisc guard... "
PPPOE_DEV=$(ip link show 2>/dev/null | grep -o 'pppoe-[^:@]*' | head -1)
if [ -n "$PPPOE_DEV" ]; then
    if tc qdisc show dev "$PPPOE_DEV" 2>/dev/null | grep -q cake; then
        echo -e "${RED}✗ CAKE on $PPPOE_DEV (double shaping!)${NC}"
        echo "    Fix: tc qdisc del dev $PPPOE_DEV root"
        fail=1
    else
        echo -e "${GREEN}✓ No double shaping${NC}"
    fi
else
    echo -e "${YELLOW}⊘ No PPPoE (N/A)${NC}"
fi

# 4. Offloads disabled
echo -n "[4/10] Offloads disabled... "
offload_check=$(ethtool -k ${WAN_IFACE:-eth1} 2>/dev/null | grep -E "tcp-segmentation-offload: on|generic-receive-offload: on")
if [ -z "$offload_check" ]; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗ FAILED${NC}"
    fail=1
fi

# 5. Unbound
echo -n "[5/10] Unbound (port 5335)... "
if pgrep unbound >/dev/null && nc -z -w1 127.0.0.1 5335 2>/dev/null; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗ Not running${NC}"
    fail=1
fi

# 6. Docker containers
echo -n "[6/10] Docker stack... "
if docker info >/dev/null 2>&1; then
    running=$(docker ps --filter "status=running" --format '{{.Names}}' 2>/dev/null | wc -l)
    if [ "$running" -ge 4 ]; then
        echo -e "${GREEN}✓ ($running containers)${NC}"
        
        # Check specific containers
        for svc in adguardhome suricata crowdsec ntopng; do
            if ! docker ps --format '{{.Names}}' | grep -q "$svc"; then
                echo -e "    ${YELLOW}⚠ $svc not running${NC}"
            fi
        done
        
        # Check AdGuard password
        if grep -q "PASSWORD_HASH_GOES_HERE" /opt/ci5-docker/adguard/conf/AdGuardHome.yaml 2>/dev/null; then
            echo -e "    ${YELLOW}⚠ AdGuard password not set${NC}"
        fi
    else
        echo -e "${YELLOW}⚠ Only $running containers running${NC}"
    fi
else
    echo "⊘ Not installed (Lite mode)"
fi

# 7. ntopng image version
echo -n "[7/10] ntopng image... "
NTOP_IMAGE=$(docker inspect ntopng --format '{{.Config.Image}}' 2>/dev/null)
if [ -n "$NTOP_IMAGE" ]; then
    if echo "$NTOP_IMAGE" | grep -q "5.6-stable"; then
        echo -e "${GREEN}✓ $NTOP_IMAGE${NC}"
    elif echo "$NTOP_IMAGE" | grep -q "dev"; then
        echo -e "${YELLOW}⚠ Dev image ($NTOP_IMAGE)${NC}"
    else
        echo -e "${GREEN}✓ $NTOP_IMAGE${NC}"
    fi
else
    echo "⊘ Not running"
fi

# 8. DNS Failover watchdog
echo -n "[8/10] DNS Failover watchdog... "
if pgrep -f "ci5-dns-failover" >/dev/null 2>&1; then
    echo -e "${GREEN}✓ Running${NC}"
elif [ -f "/etc/init.d/ci5-dns-failover" ]; then
    echo -e "${YELLOW}⚠ Installed but not running${NC}"
else
    echo -e "${YELLOW}⊘ Not installed${NC}"
fi

# 9. Docker DNS config
echo -n "[9/10] Docker DNS config... "
if [ -f "/etc/docker/daemon.json" ]; then
    if grep -q "1.1.1.1\|8.8.8.8\|9.9.9.9" /etc/docker/daemon.json 2>/dev/null; then
        echo -e "${YELLOW}⚠ External DNS fallback present${NC}"
    else
        echo -e "${GREEN}✓ Local DNS only${NC}"
    fi
else
    echo -e "${YELLOW}⚠ No daemon.json${NC}"
fi

# 10. Internet
echo -n "[10/10] Internet connectivity... "
if ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗ No Internet${NC}"
    fail=1
fi

echo "=========================================="
if [ $fail -eq 0 ]; then
    echo -e "${GREEN}   ✅ ALL CHECKS PASSED${NC}"
else
    echo -e "${YELLOW}   ⚠️  SOME CHECKS FAILED${NC}"
fi
echo "=========================================="

exit $fail
