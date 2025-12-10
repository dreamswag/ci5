#!/bin/sh
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=========================================="
echo "   🃏 Ci5 Full Installer"
echo "=========================================="
echo ""

# Check if Lite was installed
if ! tc qdisc show dev eth1 2>/dev/null | grep -q cake; then
    echo -e "${RED}[✗] ERROR: Lite install not detected!${NC}"
    echo ""
    echo "You must run 'sh install-lite.sh' first, then reboot."
    exit 1
fi

# Check RAM
TOTAL_RAM=$(grep MemTotal /proc/meminfo | awk '{print $2}')
if [ "$TOTAL_RAM" -lt 3500000 ]; then
    echo -e "${YELLOW}[!] WARNING: Less than 4GB RAM detected${NC}"
    echo "    Full Stack may use significant memory"
    read -p "    Continue anyway? (y/n): " ram_confirm
    [ "$ram_confirm" != "y" ] && exit 0
fi

echo -e "${GREEN}[✓] Lite installation verified${NC}"
echo ""

# Install Docker
echo "[*] Installing Docker..."
opkg update
opkg install dockerd docker-compose

# Configure Docker (Zero Trust)
echo "[*] Configuring Docker isolation..."
mkdir -p /etc/docker
cat << 'JSON' > /etc/docker/daemon.json
{
  "iptables": false,
  "ip6tables": false,
  "bip": "172.18.0.1/24",
  "dns": ["192.168.99.1", "1.1.1.1"],
  "mtu": 1452,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
JSON

# Start Docker
echo "[*] Starting Docker daemon..."
/etc/init.d/dockerd enable
/etc/init.d/dockerd start

# Wait for Docker
TIMEOUT=30
ELAPSED=0
until docker info >/dev/null 2>&1; do
    if [ $ELAPSED -ge $TIMEOUT ]; then
        echo -e "${RED}[✗] Docker failed to start within ${TIMEOUT}s${NC}"
        exit 1
    fi
    echo "    Waiting for Docker daemon... (${ELAPSED}s)"
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

echo -e "${GREEN}[✓] Docker ready${NC}"
echo ""

# Deploy Stack
echo "[*] Deploying container stack..."
mkdir -p /opt/ci5-docker
cp -r docker/* /opt/ci5-docker/
cd /opt/ci5-docker

echo "    -> Pulling images (may take 5-10 minutes)..."
docker-compose pull

echo "    -> Starting containers..."
docker-compose up -d

# Wait for containers
sleep 5

echo ""
echo "=========================================="
echo -e "${GREEN}[✓] Full Stack deployed!${NC}"
echo "=========================================="
echo ""
echo "🐳 Container Status:"
docker ps --format "table {{.Names}}\t{{.Status}}"
echo ""
echo "=========================================="
echo "📊 Access Points:"
echo "  - LuCI:    http://192.168.99.1"
echo "  - AdGuard: http://192.168.99.1:3000"
echo "  - Ntopng:  http://192.168.99.1:3001"
echo ""
echo "🛡️  Security:"
echo "  - Docker is ISOLATED (cannot access LAN)"
echo "  - Suricata IDS monitoring traffic"
echo "  - CrowdSec threat detection active"
echo ""
echo "Validate: sh validate.sh"
echo "=========================================="
