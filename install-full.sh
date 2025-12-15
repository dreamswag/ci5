#!/bin/sh
# 🏰 Ci5 Full Stack Installer (v7.4-RC-1)
GREEN='\033[0;32m'; NC='\033[0m'

echo "[*] Installing Docker..."
opkg update && opkg install dockerd docker-compose crowdsec-firewall-bouncer

# Docker Daemon (Local DNS Lock)
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
/etc/init.d/dockerd enable; /etc/init.d/dockerd start

# Deploy Stack
echo "[*] Deploying Containers..."
mkdir -p /opt/ci5-docker
cp -r docker/* /opt/ci5-docker/
cd /opt/ci5-docker
docker-compose pull
docker-compose up -d

# Install & Enable DNS Watchdog (Essential)
echo "[*] Installing DNS Watchdog..."
cp /root/ci5/extras/dns_failover.sh /etc/ci5-dns-failover.sh
cp /root/ci5/extras/dns_failover.init /etc/init.d/ci5-dns-failover
chmod +x /etc/ci5-dns-failover.sh /etc/init.d/ci5-dns-failover
/etc/init.d/ci5-dns-failover enable
/etc/init.d/ci5-dns-failover start

# Install PPPoE Guard (Essential)
echo "[*] Installing PPPoE Guard..."
cp /root/ci5/extras/pppoe_noqdisc.hotplug /etc/hotplug.d/iface/99-pppoe-noqdisc
chmod +x /etc/hotplug.d/iface/99-pppoe-noqdisc

# Install Paranoia Watchdog (Optional - Disabled by Default)
echo "[*] Installing Paranoia Watchdog (Disabled)..."
mkdir -p /root/scripts
cp /root/ci5/extras/paranoia_watchdog.sh /root/scripts/
chmod +x /root/scripts/paranoia_watchdog.sh
echo "    -> To enable paranoia mode: Add '/bin/sh /root/scripts/paranoia_watchdog.sh &' to /etc/rc.local"

echo -e "${GREEN}✅ FULL STACK DEPLOYED${NC}"
