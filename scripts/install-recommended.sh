#!/bin/sh
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  CI5 PHOENIX — RECOMMENDED STACK INSTALLER (RELEASE CANDIDATE)            ║
# ║  Full router + security + monitoring suite                                ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

set -e

CI5_BASE="https://ci5.run"
CI5_VERSION="1.0.0"
LOG_FILE="/var/log/ci5-install-$(date +%Y%m%d_%H%M%S).log"

# Colors
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'

# Logging
exec > >(tee -a "$LOG_FILE") 2>&1

info() { printf "${G}[✓]${N} %s\n" "$1"; }
warn() { printf "${Y}[!]${N} %s\n" "$1"; }
err()  { printf "${R}[✗]${N} %s\n" "$1"; }
step() { printf "\n${B}═══ %s ═══${N}\n\n" "$1"; }

# ─────────────────────────────────────────────────────────────────────────────
# PLATFORM DETECTION (Simplified - Bootloader already detected)
# ─────────────────────────────────────────────────────────────────────────────
detect_platform() {
    if [ -f /etc/openwrt_release ]; then
        PLATFORM="openwrt"
        PKG_UPDATE="opkg update"
        PKG_INSTALL="opkg install"
    else
        PLATFORM="unknown"
    fi
}

detect_hardware() {
    if [ -f /proc/device-tree/model ]; then
        PI_MODEL=$(tr -d '\0' < /proc/device-tree/model)
        info "Hardware: $PI_MODEL"
    fi
    
    RAM_MB=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
    info "RAM: ${RAM_MB}MB"
    
    if [ "$RAM_MB" -lt 4000 ]; then
        warn "Low RAM detected — ntopng will be skipped"
        SKIP_NTOPNG=1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# ROLLBACK SYSTEM (Retained for safety during install)
# ─────────────────────────────────────────────────────────────────────────────
BACKUP_DIR="/root/.ci5-backup-$(date +%Y%m%d%H%M%S)"
ROLLBACK_AVAILABLE=0

init_rollback() {
    mkdir -p "$BACKUP_DIR"
    
    [ -d /etc/config ] && cp -r /etc/config "$BACKUP_DIR/"
    [ -f /etc/sysctl.conf ] && cp /etc/sysctl.conf "$BACKUP_DIR/"
    [ -d /etc/sysctl.d ] && cp -r /etc/sysctl.d "$BACKUP_DIR/"
    
    if command -v docker >/dev/null 2>&1; then
        docker ps -a --format '{{.Names}}' > "$BACKUP_DIR/docker-containers.txt" 2>/dev/null || true
    fi
    
    ROLLBACK_AVAILABLE=1
    info "Rollback checkpoint created: $BACKUP_DIR"
}

execute_rollback() {
    # (Unchanged - retain full function)
    if [ "$ROLLBACK_AVAILABLE" -ne 1 ]; then
        err "No rollback checkpoint available"
        return 1
    fi
    
    warn "Executing rollback..."
    
    [ -d "$BACKUP_DIR/config" ] && cp -r "$BACKUP_DIR/config" /etc/
    [ -f "$BACKUP_DIR/sysctl.conf" ] && cp "$BACKUP_DIR/sysctl.conf" /etc/
    [ -d "$BACKUP_DIR/sysctl.d" ] && cp -r "$BACKUP_DIR/sysctl.d" /etc/
    
    if [ -f "$BACKUP_DIR/docker-containers.txt" ] && command -v docker >/dev/null 2>&1; then
        docker ps -a --format '{{.Names}}' | while read -r c; do
            grep -q "^${c}$" "$BACKUP_DIR/docker-containers.txt" || {
                docker stop "$c" 2>/dev/null || true
                docker rm "$c" 2>/dev/null || true
            }
        done
    fi
    
    sysctl --system >/dev/null 2>&1 || true
    [ -x /etc/init.d/network ] && /etc/init.d/network reload 2>/dev/null || true
    
    info "Rollback complete"
}

on_error() {
    err "Installation failed!"
    printf "Execute rollback? [Y/n]: "
    read -r ans
    case "$ans" in
        n|N) warn "Rollback skipped" ;;
        *)   execute_rollback ;;
    esac
    exit 1
}

trap on_error ERR

# ─────────────────────────────────────────────────────────────────────────────
# POST-INSTALL SPEED TEST (New - for accurate SQM tuning)
# ─────────────────────────────────────────────────────────────────────────────
run_speed_test() {
    step "AUTO-TUNING SQM BUFFERBLOAT SETTINGS"
    opkg install speedtest-cli >/dev/null 2>&1 || true
    if command -v speedtest-cli >/dev/null; then
        /opt/ci5/scripts/diagnostics/speed_test.sh auto
    else
        warn "speedtest-cli not available. Manual tuning recommended."
    fi
}

# [Retain all existing functions: install_core_tuning, install_sqm, install_docker, init_identity, inject_configs, install_security_stack, install_cli, finalize]

# ─────────────────────────────────────────────────────────────────────────────
# MAIN (Simplified)
# ─────────────────────────────────────────────────────────────────────────────
main() {
    clear
    printf "${B}CI5 PHOENIX — Recommended Stack Installer${N}\n"
    printf "═══════════════════════════════════════════════════\n\n"
    
    detect_platform
    detect_hardware
    init_rollback
    
    install_core_tuning
    install_sqm
    install_docker
    init_identity
    install_security_stack
    install_cli
    
    run_speed_test  # New: Accurate post-install tuning
    
    finalize
    
    trap - ERR
}

main "$@"