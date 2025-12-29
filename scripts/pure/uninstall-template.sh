#!/bin/sh
# ═══════════════════════════════════════════════════════════════════════════
# Cork Uninstall Script Template
# Version: 1.0
# 
# Include this (customized) in your cork submission as uninstall.sh
# The CI5 pure system will use this for clean removal
#
# Copy and modify for your cork's specific needs
# ═══════════════════════════════════════════════════════════════════════════

set -e

# Cork identification
CORK_NAME="example-cork"
CORK_VERSION="1.0.0"

# CI5 paths
CI5_DIR="/etc/ci5"
STATE_DIR="$CI5_DIR/state/corks/$CORK_NAME"

# Colors
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; N='\033[0m'
info() { printf "${G}[✓]${N} %s\n" "$1"; }
warn() { printf "${Y}[!]${N} %s\n" "$1"; }
err()  { printf "${R}[✗]${N} %s\n" "$1"; exit 1; }

echo ""
echo "═══ Uninstalling: $CORK_NAME v$CORK_VERSION ═══"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# PRE-UNINSTALL CHECKS
# ─────────────────────────────────────────────────────────────────────────────

# Check if we're running as root
[ "$(id -u)" -eq 0 ] || err "Must run as root"

# Check for dependent corks (optional - pure handles this, but good for standalone)
check_dependents() {
    local deps_file="$CI5_DIR/state/dependencies.json"
    if [ -f "$deps_file" ]; then
        local dependents=$(jq -r --arg cork "$CORK_NAME" '.corks[$cork].dependents // [] | .[]' "$deps_file" 2>/dev/null)
        if [ -n "$dependents" ]; then
            warn "Warning: These corks depend on $CORK_NAME:"
            echo "$dependents" | while read dep; do
                echo "  - $dep"
            done
            printf "\n  Continue anyway? [y/N]: "
            read -r confirm
            [ "$confirm" = "y" ] || exit 0
        fi
    fi
}

check_dependents

# ─────────────────────────────────────────────────────────────────────────────
# DOCKER CLEANUP
# ─────────────────────────────────────────────────────────────────────────────

# Define your Docker resources here
CONTAINERS="example-container"
VOLUMES="example-volume example-data"
NETWORKS="example-network"
IMAGES="example/image:latest"

cleanup_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        return 0
    fi
    
    # Stop and remove containers
    for container in $CONTAINERS; do
        if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
            info "Stopping container: $container"
            docker stop "$container" 2>/dev/null || true
            docker rm "$container" 2>/dev/null || true
        fi
    done
    
    # Remove volumes (with data!)
    for volume in $VOLUMES; do
        if docker volume ls -q | grep -q "^${volume}$"; then
            warn "Removing volume (data will be lost): $volume"
            docker volume rm "$volume" 2>/dev/null || true
        fi
    done
    
    # Remove networks
    for network in $NETWORKS; do
        if docker network ls --format '{{.Name}}' | grep -q "^${network}$"; then
            info "Removing network: $network"
            docker network rm "$network" 2>/dev/null || true
        fi
    done
    
    # Remove images (optional - uncomment if desired)
    # for image in $IMAGES; do
    #     if docker images --format '{{.Repository}}:{{.Tag}}' | grep -q "^${image}$"; then
    #         info "Removing image: $image"
    #         docker rmi "$image" 2>/dev/null || true
    #     fi
    # done
}

cleanup_docker

# ─────────────────────────────────────────────────────────────────────────────
# SYSTEMD SERVICES
# ─────────────────────────────────────────────────────────────────────────────

SERVICES="example-cork.service example-cork.timer"

cleanup_services() {
    for service in $SERVICES; do
        if systemctl list-unit-files | grep -q "$service"; then
            info "Disabling service: $service"
            systemctl stop "$service" 2>/dev/null || true
            systemctl disable "$service" 2>/dev/null || true
        fi
        
        # Remove unit files
        rm -f "/etc/systemd/system/$service"
        rm -f "/usr/lib/systemd/system/$service"
    done
    
    systemctl daemon-reload
}

cleanup_services

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION FILES
# ─────────────────────────────────────────────────────────────────────────────

# Files to remove
REMOVE_FILES="
/etc/example-cork/
/opt/example-cork/
/var/lib/example-cork/
/var/log/example-cork.log
"

# Files to restore from backup (handled by pure, but can also do manually)
RESTORE_FILES="
/etc/resolv.conf
/etc/systemd/resolved.conf
"

cleanup_files() {
    # Remove created files/directories
    for item in $REMOVE_FILES; do
        if [ -e "$item" ]; then
            info "Removing: $item"
            rm -rf "$item"
        fi
    done
    
    # Restore backed up configs
    local backup_dir="$STATE_DIR/config-backup"
    if [ -d "$backup_dir" ]; then
        for file in $RESTORE_FILES; do
            local backup="$backup_dir$(echo "$file" | sed 's|/|/|')"
            if [ -f "$backup" ]; then
                info "Restoring: $file"
                cp -a "$backup" "$file"
            fi
        done
    fi
}

cleanup_files

# ─────────────────────────────────────────────────────────────────────────────
# NETWORK CLEANUP
# ─────────────────────────────────────────────────────────────────────────────

cleanup_network() {
    # Remove iptables rules (example)
    # iptables -D INPUT -p tcp --dport 8080 -j ACCEPT 2>/dev/null || true
    
    # Remove nftables rules (example)
    # nft delete table inet example-cork 2>/dev/null || true
    
    # Restore DNS if modified
    # systemctl restart systemd-resolved 2>/dev/null || true
    
    :  # Placeholder - add your network cleanup
}

cleanup_network

# ─────────────────────────────────────────────────────────────────────────────
# PACKAGE CLEANUP (Optional)
# ─────────────────────────────────────────────────────────────────────────────

# Packages installed specifically for this cork
# Be careful - other corks might need these!
PACKAGES=""

cleanup_packages() {
    if [ -n "$PACKAGES" ] && command -v apt-get >/dev/null 2>&1; then
        warn "The following packages were installed for this cork:"
        echo "  $PACKAGES"
        printf "  Remove them? [y/N]: "
        read -r remove
        if [ "$remove" = "y" ]; then
            apt-get remove -y $PACKAGES
            apt-get autoremove -y
        fi
    fi
}

# Uncomment to enable package removal prompt
# cleanup_packages

# ─────────────────────────────────────────────────────────────────────────────
# USER/GROUP CLEANUP (Optional)
# ─────────────────────────────────────────────────────────────────────────────

cleanup_users() {
    # Remove cork-specific user
    # userdel example-cork 2>/dev/null || true
    
    # Remove cork-specific group
    # groupdel example-cork 2>/dev/null || true
    
    :  # Placeholder
}

cleanup_users

# ─────────────────────────────────────────────────────────────────────────────
# DEPENDENCY UPDATES
# ─────────────────────────────────────────────────────────────────────────────

update_dependencies() {
    # If this cork configured another cork, notify or reconfigure
    
    # Example: If we modified AdGuard's upstream DNS
    # if [ -f "/opt/AdGuardHome/AdGuardHome.yaml" ]; then
    #     warn "Note: You may need to reconfigure AdGuard's upstream DNS"
    #     warn "This cork was providing DNS at 127.0.0.1:5335"
    # fi
    
    # Example: If we were Unbound providing upstream for AdGuard
    # This is where you'd document/handle the failover scenario
    
    :  # Placeholder
}

update_dependencies

# ─────────────────────────────────────────────────────────────────────────────
# CLEANUP STATE TRACKING
# ─────────────────────────────────────────────────────────────────────────────

# Note: The pure system handles this automatically
# This is only needed for standalone uninstall

cleanup_state() {
    if [ -d "$STATE_DIR" ]; then
        # Archive instead of delete for recovery
        local archive="/etc/ci5/state/archive/$(date +%Y%m%d-%H%M%S)-$CORK_NAME"
        mkdir -p "$(dirname "$archive")"
        mv "$STATE_DIR" "$archive" 2>/dev/null || rm -rf "$STATE_DIR"
    fi
    
    # Update dependency graph
    local deps_file="$CI5_DIR/state/dependencies.json"
    if [ -f "$deps_file" ] && command -v jq >/dev/null 2>&1; then
        local temp=$(mktemp)
        jq --arg cork "$CORK_NAME" \
            'del(.corks[$cork]) | .edges = [.edges[] | select(.from != $cork and .to != $cork)]' \
            "$deps_file" > "$temp" && mv "$temp" "$deps_file"
    fi
}

# Uncomment for standalone uninstall support
# cleanup_state

# ─────────────────────────────────────────────────────────────────────────────
# COMPLETION
# ─────────────────────────────────────────────────────────────────────────────

echo ""
info "Uninstall complete: $CORK_NAME"
echo ""

# Post-uninstall notes
cat << 'NOTES'
Post-uninstall notes:
- Configuration backups archived in /etc/ci5/state/archive/
- Docker images retained (remove manually if desired)
- Check dependent services for any required reconfiguration
NOTES

exit 0
