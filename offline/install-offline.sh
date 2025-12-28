#!/bin/sh
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  CI5 PHOENIX — OFFLINE INSTALLER                                          ║
# ║  For use with ci5-sovereign.tar.gz or ci5-baremetal.tar.gz               ║
# ║  Zero network calls — everything bundled                                  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CI5_VERSION="1.0.0"

# Colors
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'

info() { printf "${G}[✓]${N} %s\n" "$1"; }
warn() { printf "${Y}[!]${N} %s\n" "$1"; }
err()  { printf "${R}[✗]${N} %s\n" "$1"; exit 1; }
step() { printf "\n${B}═══ %s ═══${N}\n\n" "$1"; }

# ─────────────────────────────────────────────────────────────────────────────
# VERIFY ARCHIVE INTEGRITY
# ─────────────────────────────────────────────────────────────────────────────
verify_integrity() {
    step "VERIFYING ARCHIVE INTEGRITY"
    
    if [ -f "$SCRIPT_DIR/SHA256SUMS" ]; then
        cd "$SCRIPT_DIR"
        if sha256sum -c SHA256SUMS --quiet 2>/dev/null; then
            info "All checksums verified"
        else
            warn "Checksum verification failed — files may be corrupted"
            printf "Continue anyway? [y/N]: "
            read -r ans
            [ "$ans" = "y" ] || [ "$ans" = "Y" ] || exit 1
        fi
    else
        warn "No SHA256SUMS file — skipping integrity check"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# DETECT ARCHIVE TYPE
# ─────────────────────────────────────────────────────────────────────────────
detect_archive_type() {
    if [ -d "$SCRIPT_DIR/ecosystem" ]; then
        ARCHIVE_TYPE="sovereign"
        info "Detected: Sovereign archive (full ecosystem)"
    elif [ -d "$SCRIPT_DIR/modules" ]; then
        ARCHIVE_TYPE="baremetal"
        info "Detected: Baremetal archive (scripts only)"
    else
        err "Unknown archive structure — missing ecosystem/ or modules/"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# PLATFORM DETECTION
# ─────────────────────────────────────────────────────────────────────────────
detect_platform() {
    if [ -f /etc/openwrt_release ]; then
        PLATFORM="openwrt"
    elif [ -f /etc/debian_version ]; then
        PLATFORM="debian"
    else
        PLATFORM="linux"
    fi
    info "Platform: $PLATFORM"
}

# ─────────────────────────────────────────────────────────────────────────────
# INSTALL BUNDLED PACKAGES (Debian)
# ─────────────────────────────────────────────────────────────────────────────
install_bundled_debs() {
    if [ "$PLATFORM" != "debian" ]; then
        return 0
    fi
    
    if [ -d "$SCRIPT_DIR/debs" ]; then
        step "INSTALLING BUNDLED PACKAGES"
        
        # Install all .deb files
        for deb in "$SCRIPT_DIR"/debs/*.deb; do
            [ -f "$deb" ] || continue
            dpkg -i "$deb" 2>/dev/null || true
        done
        
        # Fix any dependency issues
        apt-get -f install -y --no-download 2>/dev/null || true
        
        info "Bundled packages installed"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# CORE TUNING (Always)
# ─────────────────────────────────────────────────────────────────────────────
install_core_tuning() {
    step "CORE NETWORK TUNING"
    
    # Copy sysctl config
    if [ -f "$SCRIPT_DIR/modules/core/99-ci5-network.conf" ]; then
        cp "$SCRIPT_DIR/modules/core/99-ci5-network.conf" /etc/sysctl.d/
    else
        # Inline fallback
        cat > /etc/sysctl.d/99-ci5-network.conf << 'SYSCTL'
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 1048576 16777216
net.ipv4.tcp_wmem = 4096 1048576 16777216
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.ip_forward = 1
net.netfilter.nf_conntrack_max = 262144
SYSCTL
    fi
    sysctl --system >/dev/null 2>&1 || true
    info "Sysctl tuning applied"
    
    # IRQ balancing script
    if [ -f "$SCRIPT_DIR/modules/core/ci5-irq-balance" ]; then
        cp "$SCRIPT_DIR/modules/core/ci5-irq-balance" /usr/local/bin/
    else
        cat > /usr/local/bin/ci5-irq-balance << 'IRQ'
#!/bin/sh
for irq in $(grep -E 'xhci|usb|eth' /proc/interrupts 2>/dev/null | cut -d: -f1 | tr -d ' '); do
    echo 0c > /proc/irq/$irq/smp_affinity 2>/dev/null || true
done
IRQ
    fi
    chmod +x /usr/local/bin/ci5-irq-balance
    /usr/local/bin/ci5-irq-balance 2>/dev/null || true
    info "IRQ balancing configured"
    
    # SQM script
    if [ -f "$SCRIPT_DIR/modules/core/ci5-sqm" ]; then
        cp "$SCRIPT_DIR/modules/core/ci5-sqm" /usr/local/bin/
    else
        cat > /usr/local/bin/ci5-sqm << 'SQM'
#!/bin/sh
WAN="${1:-eth0}"; DOWN="${2:-0}"; UP="${3:-0}"
[ "$DOWN" = "0" ] && { echo "Usage: ci5-sqm <if> <down> <up>"; exit 1; }
tc qdisc replace dev "$WAN" root cake bandwidth "${UP}mbit"
modprobe ifb 2>/dev/null; ip link add ifb0 type ifb 2>/dev/null; ip link set ifb0 up
tc qdisc replace dev "$WAN" handle ffff: ingress
tc filter replace dev "$WAN" parent ffff: protocol all u32 match u32 0 0 action mirred egress redirect dev ifb0
tc qdisc replace dev ifb0 root cake bandwidth "${DOWN}mbit"
echo "SQM: ${DOWN}↓ ${UP}↑ Mbps on $WAN"
SQM
    fi
    chmod +x /usr/local/bin/ci5-sqm
    info "SQM script installed"
}

# ─────────────────────────────────────────────────────────────────────────────
# SOVEREIGN: Full Ecosystem
# ─────────────────────────────────────────────────────────────────────────────
install_sovereign() {
    step "SOVEREIGN MODE: Full Ecosystem"
    
    # Install Docker if bundled
    if [ -d "$SCRIPT_DIR/docker" ]; then
        if ! command -v docker >/dev/null 2>&1; then
            if [ -f "$SCRIPT_DIR/docker/docker-ce.deb" ]; then
                dpkg -i "$SCRIPT_DIR"/docker/*.deb 2>/dev/null || true
                apt-get -f install -y --no-download 2>/dev/null || true
            fi
        fi
        
        systemctl enable docker 2>/dev/null || true
        systemctl start docker 2>/dev/null || true
        info "Docker installed from bundle"
    fi
    
    # Load Docker images if bundled
    if [ -d "$SCRIPT_DIR/images" ]; then
        for img in "$SCRIPT_DIR"/images/*.tar; do
            [ -f "$img" ] || continue
            docker load < "$img"
            info "Loaded: $(basename "$img")"
        done
    fi
    
    # Deploy compose stack
    if [ -d "$SCRIPT_DIR/ecosystem/docker" ]; then
        mkdir -p /opt/ci5
        cp -r "$SCRIPT_DIR/ecosystem/docker" /opt/ci5/
        cd /opt/ci5/docker
        docker compose up -d 2>/dev/null || docker-compose up -d
        info "Docker stack deployed"
    fi
    
    # Install CLI
    if [ -f "$SCRIPT_DIR/ecosystem/ci5-cli" ]; then
        mkdir -p /opt/ci5/bin
        cp "$SCRIPT_DIR/ecosystem/ci5-cli" /opt/ci5/bin/ci5
        chmod +x /opt/ci5/bin/ci5
        ln -sf /opt/ci5/bin/ci5 /usr/local/bin/ci5
        info "CI5 CLI installed"
    fi
    
    # Initialize HWID
    mkdir -p /etc/ci5 && chmod 700 /etc/ci5
    SERIAL=$(grep -i "^Serial" /proc/cpuinfo 2>/dev/null | awk '{print $3}')
    [ -z "$SERIAL" ] && SERIAL=$(cat /sys/class/net/eth0/address 2>/dev/null | tr -d ':')
    [ -z "$SERIAL" ] && SERIAL=$(cat /proc/sys/kernel/random/uuid)
    HWID=$(printf '%s' "${SERIAL}:ci5-phoenix-v1" | sha256sum | cut -d' ' -f1)
    echo "$HWID" > /etc/ci5/.hwid
    chmod 600 /etc/ci5/.hwid
    info "HWID: ${HWID:0:8}...${HWID: -8}"
}

# ─────────────────────────────────────────────────────────────────────────────
# BAREMETAL: Scripts Only (Custom Toggles)
# ─────────────────────────────────────────────────────────────────────────────
install_baremetal_menu() {
    # For baremetal, show toggle menu like online custom install
    # Copy the toggle functions from install-custom.sh
    
    cat << 'EOF'

    ╔═══════════════════════════════════════════════════════════════════╗
    ║  BAREMETAL OFFLINE — Component Selection                          ║
    ╠═══════════════════════════════════════════════════════════════════╣
    ║                                                                   ║
    ║  Core tuning (sysctl, IRQ, SQM) is always installed.              ║
    ║                                                                   ║
    ║  Optional modules available in this archive:                      ║
EOF
    
    [ -d "$SCRIPT_DIR/modules/vpn" ] && printf "    ║    • VPN scripts (WireGuard, OpenVPN)                            ║\n"
    [ -d "$SCRIPT_DIR/modules/firewall" ] && printf "    ║    • Firewall hardening                                          ║\n"
    [ -d "$SCRIPT_DIR/modules/docker" ] && printf "    ║    • Docker + compose templates                                  ║\n"
    
    cat << 'EOF'
    ║                                                                   ║
    ║  Install all optional modules? [y/N]:                             ║
    ╚═══════════════════════════════════════════════════════════════════╝
EOF
    
    printf "    Choice: "
    read -r ans
    
    if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
        # Install all optional modules
        for mod in vpn firewall docker; do
            if [ -d "$SCRIPT_DIR/modules/$mod" ] && [ -f "$SCRIPT_DIR/modules/$mod/install.sh" ]; then
                step "MODULE: $mod"
                sh "$SCRIPT_DIR/modules/$mod/install.sh"
            fi
        done
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# FINALIZE
# ─────────────────────────────────────────────────────────────────────────────
finalize() {
    step "INSTALLATION COMPLETE"
    
    printf "\n"
    printf "${G}╔═══════════════════════════════════════════════════════════════════╗${N}\n"
    printf "${G}║  ✓ CI5 PHOENIX OFFLINE INSTALLATION COMPLETE                      ║${N}\n"
    printf "${G}╠═══════════════════════════════════════════════════════════════════╣${N}\n"
    printf "${G}║                                                                   ║${N}\n"
    printf "${G}║  Archive: %-10s                                              ║${N}\n" "$ARCHIVE_TYPE"
    printf "${G}║  Platform: %-10s                                             ║${N}\n" "$PLATFORM"
    printf "${G}║                                                                   ║${N}\n"
    printf "${G}║  ZERO NETWORK CALLS WERE MADE                                     ║${N}\n"
    printf "${G}║                                                                   ║${N}\n"
    
    if [ "$ARCHIVE_TYPE" = "sovereign" ]; then
        printf "${G}║  ci5 status     — Check services                                 ║${N}\n"
        printf "${G}║  ci5 help       — CLI usage                                      ║${N}\n"
    fi
    
    printf "${G}║  ci5-sqm eth0 X Y — Enable bufferbloat fix                        ║${N}\n"
    printf "${G}║                                                                   ║${N}\n"
    printf "${G}╚═══════════════════════════════════════════════════════════════════╝${N}\n"
    printf "\n"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
main() {
    clear
    printf "${B}CI5 PHOENIX — OFFLINE INSTALLER${N}\n"
    printf "═══════════════════════════════════════════════════════════════\n"
    printf "This installer makes ${G}ZERO${N} network calls.\n"
    printf "═══════════════════════════════════════════════════════════════\n\n"
    
    [ "$(id -u)" -eq 0 ] || err "Must run as root"
    
    verify_integrity
    detect_archive_type
    detect_platform
    install_bundled_debs
    install_core_tuning
    
    case "$ARCHIVE_TYPE" in
        sovereign) install_sovereign ;;
        baremetal) install_baremetal_menu ;;
    esac
    
    finalize
}

main "$@"
