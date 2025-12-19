#!/bin/bash
# ci5: The Bufferbloat Slayer (Full Install)

Red='\033[0;31m'
Green='\033[0;32m'
BGreen='\033[1;32m'
Color_Off='\033[0m'

echo -e "${BGreen}>> ci5: INITIALIZING FULL INSTALLATION...${Color_Off}"

# --- RESILIENCE MATRIX ---
# 1. Primary:   ci5.run (Cloudflare CDN) - Speed.
# 2. Secondary: GitHub Raw (Microsoft)   - Auditability.
# 3. Tertiary:  IPFS/ENS (Decentralized) - Permanence.
safe_curl() {
    local output="$1"
    local primary="$2"
    local backup="$3"
    
    echo -e "${Green}>> Fetching asset...${Color_Off}"
    
    # Try Primary
    if curl -sL --fail --connect-timeout 5 "$primary" -o "$output"; then return 0; fi
    echo -e "${Red}!! Primary Uplink Down. Engaging Backup...${Color_Off}"
    
    # Try Secondary
    if curl -sL --fail --connect-timeout 5 "$backup" -o "$output"; then return 0; fi
    
    echo -e "${Red}!! Network Collapse. Aborting.${Color_Off}"
    return 1
}

# 1. System Update
echo -e "${Green}>> Updating system dependencies...${Color_Off}"
apt-get update && apt-get install -y curl git ethtool jq ca-certificates gnupg lsb-release bridge-utils dnsutils

# 2. Network Config
echo -e "${Green}>> Configuring Network Bridge...${Color_Off}"
if [ -f /etc/dhcpcd.conf ]; then
    cp /etc/dhcpcd.conf /etc/dhcpcd.conf.bak
    echo "interface eth0" >> /etc/dhcpcd.conf
    echo "fallback static_eth0" >> /etc/dhcpcd.conf
fi

# 3. Kernel Tuning
echo -e "${Green}>> Hardening Kernel (Sysctl)...${Color_Off}"
cat <<EOF > /etc/sysctl.d/99-ci5-tuning.conf
net.core.default_qdisc = cake
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_forward = 1
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 16384
fs.file-max = 2097152
EOF
sysctl --system

# 4. Docker
if ! command -v docker &> /dev/null; then
    echo -e "${Green}>> Installing Docker...${Color_Off}"
    curl -fsSL https://get.docker.com | sh
    usermod -aG docker $USER
fi

# 5. Pull Stack (Resilient Fetch)
echo -e "${Green}>> Pulling Docker Stack...${Color_Off}"
mkdir -p /opt/ci5/docker
safe_curl \
    "/opt/ci5/docker/docker-compose.yml" \
    "https://ci5.host/docker/docker-compose.yml" \
    "https://raw.githubusercontent.com/dreamswag/ci5/main/docker/docker-compose.yml"

# 6. Enable Services
cd /opt/ci5/docker && docker compose pull

# 7. Boot Scripts
echo -e "${Green}>> Installing Boot Logic...${Color_Off}"
cat <<EOF > /etc/rc.local
#!/bin/bash
/opt/ci5/scripts/network_init.sh
/opt/ci5/scripts/firewall_init.sh
/opt/ci5/scripts/sqm_init.sh
exit 0
EOF
chmod +x /etc/rc.local

# 8. Proof-of-Life (Resilient Fetch)
echo -e "${BGreen}>> Staging Proof-of-Life Protocol...${Color_Off}"
safe_curl \
    "/etc/profile.d/z99-ci5-handshake.sh" \
    "https://ci5.run/handshake" \
    "https://raw.githubusercontent.com/dreamswag/ci5.run/main/scripts/sovereign-handshake.sh"
chmod +x /etc/profile.d/z99-ci5-handshake.sh

echo -e "${BGreen}>> INSTALLATION COMPLETE. REBOOT REQUIRED.${Color_Off}"
read -p "Reboot now? [y/N] " -r
if [[ "$REPLY" =~ ^([yY][eE][sS]|[yY])$ ]]; then reboot; fi