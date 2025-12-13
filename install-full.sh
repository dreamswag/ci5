#!/bin/sh
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=========================================="
echo "   🃏 Ci5 Full Installer (Fortress Mode)"
echo "=========================================="
echo ""

# Check RAM
TOTAL_RAM=$(grep MemTotal /proc/meminfo | awk '{print $2}')
if [ "$TOTAL_RAM" -lt 3500000 ]; then
    echo -e "${YELLOW}[!] WARNING: Less than 4GB RAM detected${NC}"
    echo "    Full Stack requires 8GB Pi 5 recommended."
    read -p "    Continue anyway? (y/n): " ram_confirm
    [ "$ram_confirm" != "y" ] && exit 0
fi

# Install Docker & Security Dependencies
echo "[*] Installing Docker & Security packages..."
opkg update
opkg install dockerd docker-compose crowdsec-firewall-bouncer

# Configure Docker (Zero Trust - Point to Router DNS)
echo "[*] Configuring Docker isolation..."
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

# Start Docker
/etc/init.d/dockerd enable
/etc/init.d/dockerd start

# Create Network Interface for Firewall Control (docker0)
uci set network.docker=interface
uci set network.docker.proto='none'
uci set network.docker.device='docker0'
uci commit network
/etc/init.d/network reload

# Deploy Stack
echo "[*] Deploying container stack..."
mkdir -p /opt/ci5-docker
cp -r docker/* /opt/ci5-docker/
cd /opt/ci5-docker

# Initialize Suricata Rules
echo "[*] Fetching Suricata Rules..."
mkdir -p suricata/rules
docker run --rm -v $(pwd)/suricata:/var/lib/suricata jasonish/suricata:latest suricata-update

echo "[*] Starting containers..."
docker-compose up -d

echo ""
echo "=========================================="
echo -e "${GREEN}[✓] Full Stack deployed!${NC}"
echo "=========================================="
echo ""
echo -e "${YELLOW}[!] ACTION REQUIRED: Connect CrowdSec Bouncer${NC}"
echo "    The Firewall Bouncer is installed but needs an API key from the Docker container."
echo "    Run these commands manually:"
echo ""
echo "    1. docker exec crowdsec cscli bouncers add openwrt-firewall"
echo "    2. uci set crowdsec.@bouncer[0].api_key='<KEY_FROM_ABOVE>'"
echo "    3. uci set crowdsec.@bouncer[0].api_url='http://127.0.0.1:8081'"
echo "    4. uci commit crowdsec && /etc/init.d/crowdsec-firewall-bouncer restart"
echo ""
