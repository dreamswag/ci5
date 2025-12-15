#!/bin/sh
# 🏰 Ci5 Full Stack Installer (v7.4-RC-1)
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'

# ─────────────────────────────────────────────────────────────
# LOGGING
# ─────────────────────────────────────────────────────────────
LOG_FILE="/root/ci5-full-install-$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== Ci5 Full Stack Installation Started: $(date) ==="

# ─────────────────────────────────────────────────────────────
# PRE-CHECKS
# ─────────────────────────────────────────────────────────────
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1024 / 1024))
if [ "$TOTAL_RAM_GB" -lt 7 ]; then
    echo -e "${RED}[✗] Full Stack requires 8GB RAM (found ${TOTAL_RAM_GB}GB)${NC}"
    echo "    Use install-lite.sh instead."
    exit 1
fi

# Time sync for Docker pulls
echo "[*] Syncing time..."
/etc/init.d/sysntpd restart 2>/dev/null || true
ntpd -q -p pool.ntp.org 2>/dev/null || true
sleep 3

echo "[*] Installing Docker..."
opkg update
opkg install dockerd docker-compose crowdsec-firewall-bouncer

# ─────────────────────────────────────────────────────────────
# DOCKER DAEMON CONFIG (Local DNS Only - No External Fallback)
# ─────────────────────────────────────────────────────────────
echo "[*] Configuring Docker daemon..."
mkdir -p /etc/docker
cat << 'JSON' > /etc/docker/daemon.json
{
  "iptables": false,
  "ip6tables": false,
  "bip": "172.18.0.1/24",
  "dns": ["192.168.99.1"],
  "mtu": 1452,
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
JSON

/etc/init.d/dockerd enable
/etc/init.d/dockerd start
sleep 5

# Docker network
uci -q delete network.docker
uci set network.docker=interface
uci set network.docker.proto='none'
uci set network.docker.device='docker0'
uci commit network
/etc/init.d/network reload

echo "[*] Deploying Stack..."
mkdir -p /opt/ci5-docker
cp -r docker/* /opt/ci5-docker/
rm -f /opt/ci5-docker/adguard/AdGuardHome.yaml

echo "[*] Securing AdGuard Home..."
AG_USER="admin"
AG_PASS="ci5admin"
echo "    - Generating hash for '$AG_PASS'..."

AG_HASH=$(timeout 60 docker run --rm adguard/adguardhome:latest /opt/adguardhome/AdGuardHome --generate-password "$AG_PASS" 2>/dev/null | grep "Hashed" | awk '{print $NF}')

if [ -z "$AG_HASH" ]; then
    echo -e "${YELLOW}    ! Hash generation failed or timed out.${NC}"
    echo "    ! Configure AdGuard manually at http://192.168.99.1:3000"
else
    sed -i "s|PASSWORD_HASH_GOES_HERE|$AG_HASH|g" /opt/ci5-docker/adguard/conf/AdGuardHome.yaml
    echo -e "${GREEN}    ✓ AdGuard Login: $AG_USER / $AG_PASS${NC}"
fi

echo "[*] Starting Containers..."
cd /opt/ci5-docker
docker-compose pull
docker-compose up -d

echo "[*] Waiting for services to start..."
sleep 30

# ─────────────────────────────────────────────────────────────
# DNS FAILOVER WATCHDOG (Unbound Self-Sufficient Fallback)
# ─────────────────────────────────────────────────────────────
echo "[*] Installing DNS Failover Watchdog..."

cat > /etc/ci5-dns-failover.sh << 'WATCHDOG'
#!/bin/sh
# 🛡️ Ci5 DNS Failover Watchdog (v7.4-RC-1)
# Monitors AdGuard Home and fails over to Unbound if down

ADGUARD_PORT=53
UNBOUND_PORT=5335
CHECK_INTERVAL=30
FAIL_THRESHOLD=3
FAIL_COUNT=0
FALLBACK_ACTIVE=0

log() { logger -t ci5-dns-failover "$1"; }

check_adguard() {
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q adguardhome; then
        if nc -z -w2 127.0.0.1 $ADGUARD_PORT 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

enable_unbound_primary() {
    log "🚨 AdGuard DOWN - Activating Unbound fallback on :53"
    
    uci set dhcp.@dnsmasq[0].port='53535'
    uci commit dhcp
    
    uci set unbound.ub_main.listen_port='53'
    uci commit unbound
    /etc/init.d/unbound restart
    
    FALLBACK_ACTIVE=1
    log "✅ Unbound now serving DNS on :53"
}

restore_adguard_primary() {
    log "✅ AdGuard RECOVERED - Restoring normal DNS chain"
    
    uci set unbound.ub_main.listen_port='5335'
    uci commit unbound
    /etc/init.d/unbound restart
    
    FALLBACK_ACTIVE=0
    log "✅ AdGuard restored as primary DNS"
}

while true; do
    if check_adguard; then
        FAIL_COUNT=0
        if [ "$FALLBACK_ACTIVE" = "1" ]; then
            restore_adguard_primary
        fi
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        if [ "$FAIL_COUNT" -ge "$FAIL_THRESHOLD" ] && [ "$FALLBACK_ACTIVE" = "0" ]; then
            enable_unbound_primary
        fi
    fi
    sleep $CHECK_INTERVAL
done
WATCHDOG
chmod +x /etc/ci5-dns-failover.sh

cat > /etc/init.d/ci5-dns-failover << 'INITSCRIPT'
#!/bin/sh /etc/rc.common
# Ci5 DNS Failover Service (v7.4-RC-1)

START=99
STOP=10
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /bin/sh /etc/ci5-dns-failover.sh
    procd_set_param respawn 3600 5 5
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
INITSCRIPT
chmod +x /etc/init.d/ci5-dns-failover

/etc/init.d/ci5-dns-failover enable
/etc/init.d/ci5-dns-failover start
echo -e "${GREEN}    ✓ DNS failover watchdog installed${NC}"

# ─────────────────────────────────────────────────────────────
# PPPOE QDISC GUARD (Prevent Double CAKE)
# ─────────────────────────────────────────────────────────────
echo "[*] Installing PPPoE qdisc guard..."

cat > /etc/hotplug.d/iface/99-pppoe-noqdisc << 'HOTPLUG'
#!/bin/sh
# Prevent CAKE from being applied to pppoe-wan (already on eth1)
[ "$ACTION" = "ifup" ] && [ "$INTERFACE" = "wan" ] && {
    PPPOE_DEV=$(ip link show | grep pppoe | awk -F: '{print $2}' | tr -d ' ')
    [ -n "$PPPOE_DEV" ] && tc qdisc del dev "$PPPOE_DEV" root 2>/dev/null
}
HOTPLUG
chmod +x /etc/hotplug.d/iface/99-pppoe-noqdisc
echo -e "${GREEN}    ✓ PPPoE qdisc guard installed${NC}"

# ─────────────────────────────────────────────────────────────
# CONTAINER HEALTH CHECK
# ─────────────────────────────────────────────────────────────
echo "[*] Checking container health..."
for svc in redis adguardhome suricata crowdsec ntopng; do
    if docker ps | grep -q "$svc"; then
        echo -e "${GREEN}    ✓ $svc running${NC}"
    else
        echo -e "${YELLOW}    ⚠ $svc not running${NC}"
    fi
done

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   ✅ FULL STACK DEPLOYED${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "AdGuard Home: http://192.168.99.1:3000"
echo "Ntopng:       http://192.168.99.1:3001"
echo ""
echo "Features installed:"
echo "  • Docker stack (5 containers)"
echo "  • DNS failover watchdog (Unbound auto-takeover)"
echo "  • PPPoE qdisc guard (prevents double CAKE)"
echo ""
echo "Log: $LOG_FILE"
