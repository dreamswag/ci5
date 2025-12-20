#!/bin/bash
# 🏰 Ci5 Unified Installer (v7.5: The Cork Registry)
# Deploys Docker, Core Services, and Community Corks

export PATH=/usr/sbin:/usr/bin:/sbin:/bin
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo -e "${GREEN}Starting Ci5 Installation...${NC}"

# ─────────────────────────────────────────────────────────────
# MODULE A: PREREQUISITES
# ─────────────────────────────────────────────────────────────
echo "[*] Installing Dependencies..."
opkg update
opkg install git-http curl ca-certificates parted losetup resize2fs

# ─────────────────────────────────────────────────────────────
# MODULE B: DOCKER ENGINE
# ─────────────────────────────────────────────────────────────
echo "[*] Checking Docker..."
if ! command -v docker &> /dev/null; then
    echo "    -> Installing Docker (dockerd)..."
    opkg install dockerd docker-compose
    # Enable and Start
    /etc/init.d/dockerd enable
    /etc/init.d/dockerd start
    sleep 5
fi

# ─────────────────────────────────────────────────────────────
# MODULE C: CORE STACK (AdGuard/Unbound)
# ─────────────────────────────────────────────────────────────
echo "[*] Deploying Core Stack..."
cd /opt/ci5/docker
# Ensure networks exist
docker network create ci5_net 2>/dev/null

# Launch Core
docker compose up -d adguardhome unbound
echo "    -> Core Services Active."

# ─────────────────────────────────────────────────────────────
# MODULE D: CORK INJECTION (The App Store)
# ─────────────────────────────────────────────────────────────
echo "[*] Uncorking Registry Modules..."

# 1. Defaults (If no Soul injection)
DEFAULT_CORKS="dreamswag/cork-ntopng" 

# 2. Load "Soul" List
if [ -f /etc/ci5_corks ]; then
    USER_CORKS=$(cat /etc/ci5_corks)
    echo -e "    -> Found User Loadout: ${YELLOW}$USER_CORKS${NC}"
else
    USER_CORKS="$DEFAULT_CORKS"
fi

# 3. Fetch & Deploy Loop
mkdir -p /opt/ci5/corks
for REPO in $USER_CORKS; do
    NAME=$(basename "$REPO")
    echo "    -> Fetching Cork: $NAME"
    
    # Clone (Depth 1 for speed)
    if [ -d "/opt/ci5/corks/$NAME" ]; then
        cd "/opt/ci5/corks/$NAME" && git pull
    else
        git clone --depth 1 "https://github.com/$REPO.git" "/opt/ci5/corks/$NAME" 2>/dev/null
    fi
    
    if [ $? -eq 0 ]; then
        # Check for Docker vs Script
        if [ -f "/opt/ci5/corks/$NAME/docker-compose.yml" ]; then
            echo "       [Docker] Starting $NAME..."
            cd "/opt/ci5/corks/$NAME" && docker compose up -d
        elif [ -f "/opt/ci5/corks/$NAME/init.sh" ]; then
            echo "       [Script] Running init for $NAME..."
            bash "/opt/ci5/corks/$NAME/init.sh"
        fi
    else
        echo -e "       ${RED}[ERROR] Failed to download $REPO${NC}"
    fi
done

# ─────────────────────────────────────────────────────────────
# MODULE E: FINALIZATION
# ─────────────────────────────────────────────────────────────
echo "[*] Installation Complete."
echo "    Access Dashboard at: http://192.168.99.1"