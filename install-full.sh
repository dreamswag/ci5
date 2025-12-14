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
echo "Log: $LOG_FILE"
