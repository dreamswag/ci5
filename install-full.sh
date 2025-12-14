#!/bin/sh
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'

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
uci set network.docker=interface; uci set network.docker.proto='none'; uci set network.docker.device='docker0'; uci commit network
/etc/init.d/network reload

echo "[*] Deploying Stack..."
mkdir -p /opt/ci5-docker
cp -r docker/* /opt/ci5-docker/
# Explicit cleanup of stub if it exists (Fix for duplicate YAMLs)
rm -f /opt/ci5-docker/adguard/AdGuardHome.yaml

echo "[*] Securing AdGuard Home..."
AG_USER="admin"
AG_PASS="ci5admin"
echo "    - Generating hash for '$AG_PASS'..."

# Timeout added to prevent hang if image pull fails
AG_HASH=$(timeout 30 docker run --rm adguard/adguardhome:latest /opt/adguardhome/AdGuardHome --generate-password "$AG_PASS" | grep "Hashed" | awk '{print $NF}')

if [ -z "$AG_HASH" ]; then
    echo -e "${RED}    ! Hash generation failed or timed out.${NC}"
    echo "    ! Using default config. You MUST configure AdGuard manually at http://192.168.99.1:3000"
else
    # Inject Hash into Config
    sed -i "s|PASSWORD_HASH_GOES_HERE|$AG_HASH|g" /opt/ci5-docker/adguard/conf/AdGuardHome.yaml
    echo -e "${GREEN}    AdGuard Login: $AG_USER / $AG_PASS${NC}"
fi

echo "[*] Starting Containers..."
cd /opt/ci5-docker
docker-compose up -d
echo -e "${GREEN}[✓] Full Stack Deployed${NC}"
