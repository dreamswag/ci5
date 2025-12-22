#!/bin/bash
# 🏰 Ci5 Unified Installer (v7.5-HARDENED: The Cork Registry)
# Deploys Docker, Core Services, and Community Corks
# 
# Critical Fixes Applied:
#   [1] Atomic rollback on failure

export PATH=/usr/sbin:/usr/bin:/sbin:/bin
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

echo -e "${GREEN}Starting Ci5 Full Stack Installation (v7.5-HARDENED)...${NC}"

# ─────────────────────────────────────────────────────────────
# CRITICAL FIX [1]: ATOMIC ROLLBACK INFRASTRUCTURE
# ─────────────────────────────────────────────────────────────
ROLLBACK_ENABLED=0
BACKUP_DIR=""
ROLLBACK_MARKER="/tmp/.ci5_rollback_in_progress"
LOG_FILE="/root/ci5-full-install-$(date +%Y%m%d_%H%M%S).log"

# Start logging
exec > >(tee -a "$LOG_FILE") 2>&1

init_atomic_rollback() {
    BACKUP_DIR="/root/ci5-backup-$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    
    echo "[ATOMIC] Creating restoration checkpoint..."
    
    # 1. UCI config snapshot
    cp -r /etc/config "$BACKUP_DIR/config" 2>/dev/null
    
    # 2. Critical system files
    cp /etc/rc.local "$BACKUP_DIR/rc.local" 2>/dev/null
    cp /etc/sysctl.conf "$BACKUP_DIR/sysctl.conf" 2>/dev/null
    
    # 3. Docker state (if exists)
    if command -v docker &> /dev/null; then
        docker ps -a --format '{{.Names}}' > "$BACKUP_DIR/docker_containers.txt" 2>/dev/null
        docker images --format '{{.Repository}}:{{.Tag}}' > "$BACKUP_DIR/docker_images.txt" 2>/dev/null
    fi
    
    # 4. Existing Cork list
    [ -f /etc/ci5_corks ] && cp /etc/ci5_corks "$BACKUP_DIR/ci5_corks"
    
    # 5. Network state
    ip addr show > "$BACKUP_DIR/ip_addr.txt" 2>/dev/null
    ip route show > "$BACKUP_DIR/ip_route.txt" 2>/dev/null
    
    # 6. OpenWrt full backup (if available)
    if command -v sysupgrade >/dev/null 2>&1; then
        sysupgrade -b "$BACKUP_DIR/full-backup.tar.gz" 2>/dev/null
    fi
    
    # 7. Create rollback manifest
    cat > "$BACKUP_DIR/manifest.txt" << EOF
CI5_FULL_ROLLBACK_MANIFEST
Created: $(date)
Hostname: $(cat /proc/sys/kernel/hostname)
Kernel: $(uname -r)
Docker: $(docker --version 2>/dev/null || echo "not installed")
EOF
    
    ROLLBACK_ENABLED=1
    echo -e "${GREEN}[ATOMIC] Checkpoint saved: $BACKUP_DIR${NC}"
}

execute_rollback() {
    if [ "$ROLLBACK_ENABLED" -ne 1 ] || [ -z "$BACKUP_DIR" ]; then
        echo "[ATOMIC] No rollback checkpoint available"
        return 1
    fi
    
    # Prevent recursive rollback
    if [ -f "$ROLLBACK_MARKER" ]; then
        echo "[ATOMIC] Rollback already in progress, aborting"
        return 1
    fi
    touch "$ROLLBACK_MARKER"
    
    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  🔄 EXECUTING ATOMIC ROLLBACK                                    ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # 1. Stop and remove any newly created containers
    echo "[ROLLBACK] Stopping new Docker containers..."
    if command -v docker &> /dev/null; then
        # Get containers that weren't in the backup
        if [ -f "$BACKUP_DIR/docker_containers.txt" ]; then
            docker ps -a --format '{{.Names}}' | while read container; do
                if ! grep -q "^${container}$" "$BACKUP_DIR/docker_containers.txt" 2>/dev/null; then
                    echo "   Removing new container: $container"
                    docker stop "$container" 2>/dev/null
                    docker rm "$container" 2>/dev/null
                fi
            done
        fi
    fi
    
    # 2. Restore UCI configs
    if [ -d "$BACKUP_DIR/config" ]; then
        echo "[ROLLBACK] Restoring UCI configuration..."
        rm -rf /etc/config.failed 2>/dev/null
        mv /etc/config /etc/config.failed 2>/dev/null
        cp -r "$BACKUP_DIR/config" /etc/config
    fi
    
    # 3. Restore system files
    [ -f "$BACKUP_DIR/rc.local" ] && cp "$BACKUP_DIR/rc.local" /etc/rc.local
    [ -f "$BACKUP_DIR/sysctl.conf" ] && cp "$BACKUP_DIR/sysctl.conf" /etc/sysctl.conf
    
    # 4. Restore Cork list
    [ -f "$BACKUP_DIR/ci5_corks" ] && cp "$BACKUP_DIR/ci5_corks" /etc/ci5_corks
    
    # 5. Reload services
    echo "[ROLLBACK] Reloading services..."
    /etc/init.d/network reload 2>/dev/null
    /etc/init.d/firewall reload 2>/dev/null
    /etc/init.d/dnsmasq restart 2>/dev/null
    
    # 6. Verify network connectivity
    sleep 3
    if ping -c 1 -W 5 1.1.1.1 >/dev/null 2>&1; then
        echo -e "${GREEN}[ROLLBACK] Network restored successfully${NC}"
    else
        echo -e "${YELLOW}[ROLLBACK] Network may need manual intervention${NC}"
    fi
    
    rm -f "$ROLLBACK_MARKER"
    
    echo ""
    echo -e "${GREEN}[ROLLBACK] System restored to pre-install state${NC}"
    echo "Backup preserved at: $BACKUP_DIR"
    echo "Failed config saved at: /etc/config.failed"
    echo ""
    echo "To retry installation, fix the issue and run:"
    echo "   sh /opt/ci5/install-full.sh"
    
    return 0
}

# Trap handler for failures
rollback_on_error() {
    local exit_code=$?
    local failed_command="${BASH_COMMAND}"
    
    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  ❌ INSTALLATION FAILED                                          ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Exit code: $exit_code"
    echo "Failed at: $failed_command"
    echo "Log file:  $LOG_FILE"
    echo ""
    
    if [ "$ROLLBACK_ENABLED" -eq 1 ]; then
        echo -n "Automatic rollback available. Execute rollback? [Y/n]: "
        read -t 30 ROLLBACK_CHOICE || ROLLBACK_CHOICE="y"
        
        if [ "$ROLLBACK_CHOICE" != "n" ] && [ "$ROLLBACK_CHOICE" != "N" ]; then
            execute_rollback
        else
            echo "Rollback skipped. Manual recovery may be required."
            echo "Backup location: $BACKUP_DIR"
        fi
    fi
    
    exit 1
}

# Enable error trapping
set -E
trap 'rollback_on_error' ERR

# ─────────────────────────────────────────────────────────────
# INITIALIZE ATOMIC ROLLBACK
# ─────────────────────────────────────────────────────────────
echo "[*] Initializing atomic rollback system..."
init_atomic_rollback

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
    
    # Wait for Docker to be ready
    echo "    -> Waiting for Docker daemon..."
    DOCKER_WAIT=0
    while ! docker info >/dev/null 2>&1; do
        sleep 1
        DOCKER_WAIT=$((DOCKER_WAIT + 1))
        if [ $DOCKER_WAIT -gt 30 ]; then
            echo -e "${RED}    -> Docker failed to start within 30 seconds${NC}"
            exit 1
        fi
    done
    echo "    -> Docker ready after ${DOCKER_WAIT}s"
fi

# Verify Docker is functional
if ! docker info >/dev/null 2>&1; then
    echo -e "${RED}[!] Docker is not running. Attempting restart...${NC}"
    /etc/init.d/dockerd restart
    sleep 5
    if ! docker info >/dev/null 2>&1; then
        echo -e "${RED}[!] Docker failed to start${NC}"
        exit 1
    fi
fi

# ─────────────────────────────────────────────────────────────
# MODULE C: CORE STACK (AdGuard/Unbound)
# ─────────────────────────────────────────────────────────────
echo "[*] Deploying Core Stack..."

# Ensure we're in the right directory
if [ -d "/opt/ci5/docker" ]; then
    cd /opt/ci5/docker
elif [ -d "./docker" ]; then
    cd ./docker
else
    echo -e "${RED}[!] Docker compose directory not found${NC}"
    exit 1
fi

# Ensure networks exist
docker network create ci5_net 2>/dev/null || true

# Launch Core (with pull to ensure images exist)
echo "    -> Pulling core images..."
docker compose pull adguardhome unbound 2>/dev/null || true

echo "    -> Starting core services..."
docker compose up -d adguardhome unbound

# Verify core services started
sleep 5
CORE_RUNNING=0
if docker ps | grep -q adguardhome; then
    CORE_RUNNING=$((CORE_RUNNING + 1))
fi
if docker ps | grep -q unbound; then
    CORE_RUNNING=$((CORE_RUNNING + 1))
fi

if [ $CORE_RUNNING -lt 1 ]; then
    echo -e "${YELLOW}    -> Warning: Some core services may not have started${NC}"
    docker ps -a | grep -E "(adguard|unbound)"
else
    echo -e "${GREEN}    -> Core Services Active ($CORE_RUNNING containers)${NC}"
fi

# ─────────────────────────────────────────────────────────────
# MODULE D: CORK INJECTION (The App Store)
# ─────────────────────────────────────────────────────────────
echo "[*] Uncorking Registry Modules..."

# 1. Defaults (If no Soul injection)
DEFAULT_CORKS="dreamswag/cork-ntopng" 

# 2. Load "Soul" List
if [ -f /etc/ci5_corks ]; then
    USER_CORKS=$(cat /etc/ci5_corks | tr '\n' ' ')
    echo -e "    -> Found User Loadout: ${YELLOW}$USER_CORKS${NC}"
else
    USER_CORKS="$DEFAULT_CORKS"
fi

# 3. Fetch & Deploy Loop
mkdir -p /opt/ci5/corks
CORK_SUCCESS=0
CORK_FAILED=0

for REPO in $USER_CORKS; do
    # Skip empty entries
    [ -z "$REPO" ] && continue
    
    NAME=$(basename "$REPO")
    echo "    -> Fetching Cork: $NAME"
    
    # Clone (Depth 1 for speed)
    if [ -d "/opt/ci5/corks/$NAME" ]; then
        echo "       [Update] Pulling latest..."
        cd "/opt/ci5/corks/$NAME" && git pull --quiet
        CLONE_RESULT=$?
    else
        git clone --depth 1 "https://github.com/$REPO.git" "/opt/ci5/corks/$NAME" 2>/dev/null
        CLONE_RESULT=$?
    fi
    
    if [ $CLONE_RESULT -eq 0 ]; then
        # Check for Docker vs Script
        if [ -f "/opt/ci5/corks/$NAME/docker-compose.yml" ]; then
            echo "       [Docker] Starting $NAME..."
            cd "/opt/ci5/corks/$NAME"
            docker compose pull 2>/dev/null || true
            if docker compose up -d; then
                CORK_SUCCESS=$((CORK_SUCCESS + 1))
            else
                echo -e "       ${YELLOW}[WARN] $NAME container failed to start${NC}"
                CORK_FAILED=$((CORK_FAILED + 1))
            fi
        elif [ -f "/opt/ci5/corks/$NAME/init.sh" ]; then
            echo "       [Script] Running init for $NAME..."
            if bash "/opt/ci5/corks/$NAME/init.sh"; then
                CORK_SUCCESS=$((CORK_SUCCESS + 1))
            else
                echo -e "       ${YELLOW}[WARN] $NAME init script failed${NC}"
                CORK_FAILED=$((CORK_FAILED + 1))
            fi
        else
            echo -e "       ${YELLOW}[WARN] No docker-compose.yml or init.sh found${NC}"
            CORK_FAILED=$((CORK_FAILED + 1))
        fi
    else
        echo -e "       ${RED}[ERROR] Failed to download $REPO${NC}"
        CORK_FAILED=$((CORK_FAILED + 1))
    fi
done

echo ""
echo "    Cork Summary: ${GREEN}$CORK_SUCCESS succeeded${NC}, ${YELLOW}$CORK_FAILED failed${NC}"

# ─────────────────────────────────────────────────────────────
# MODULE E: FULL STACK DEPLOYMENT (IDS/IPS)
# ─────────────────────────────────────────────────────────────
echo "[*] Deploying Full Security Stack..."

cd /opt/ci5/docker 2>/dev/null || cd ./docker 2>/dev/null || true

# Deploy full profile
echo "    -> Pulling full stack images..."
docker compose --profile full pull 2>/dev/null || true

echo "    -> Starting security services..."
docker compose --profile full up -d

# Wait and verify
sleep 10
echo ""
echo "[*] Service Status:"
docker ps --format "    {{.Names}}: {{.Status}}" | head -10

# ─────────────────────────────────────────────────────────────
# MODULE F: FINALIZATION
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ✅ FULL STACK INSTALLATION COMPLETE                             ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "    Log file:     $LOG_FILE"
echo "    Backup:       $BACKUP_DIR"
echo ""
echo "    Access Points:"
echo "      SSH:        ssh root@192.168.99.1"
echo "      AdGuard:    http://192.168.99.1:3000"
echo "      Ntopng:     http://192.168.99.1:3001"
echo ""

# Disable error trap for clean exit
trap - ERR

# Mark rollback as no longer needed (successful completion)
rm -f "$ROLLBACK_MARKER" 2>/dev/null

echo "[*] Run 'sh validate.sh' to verify installation."
