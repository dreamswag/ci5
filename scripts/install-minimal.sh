#!/bin/sh
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  CI5 PHOENIX — MINIMAL PERFORMANCE INSTALLER                              ║
# ║  Bufferbloat fix only — no Docker, no services, no ecosystem              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

set -e

# Colors
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'

info() { printf "${G}[✓]${N} %s\n" "$1"; }
warn() { printf "${Y}[!]${N} %s\n" "$1"; }
step() { printf "\n${B}═══ %s ═══${N}\n\n" "$1"; }

# ─────────────────────────────────────────────────────────────────────────────
# PLATFORM DETECTION (Minimal - Bootloader pre-handled)
# ─────────────────────────────────────────────────────────────────────────────
detect_platform() {
    if [ -f /etc/openwrt_release ]; then
        PLATFORM="openwrt"
    else
        PLATFORM="linux"
    fi
    info "Platform: $PLATFORM"
}

# [Retain existing functions: install_sysctl_tuning, install_irq_balancing, install_sqm, create_uninstall]

# ─────────────────────────────────────────────────────────────────────────────
# POST-INSTALL SPEED TEST (New - Accurate tuning)
# ─────────────────────────────────────────────────────────────────────────────
run_speed_test() {
    step "AUTO-TUNING SQM BUFFERBLOAT SETTINGS"
    opkg install speedtest-cli >/dev/null 2>&1 || true
    if command -v speedtest-cli >/dev/null && [ -f "/opt/ci5/scripts/diagnostics/speed_test.sh" ]; then
        /opt/ci5/scripts/diagnostics/speed_test.sh auto
    else
        warn "speedtest-cli unavailable. Run manually later for optimal tuning."
        info "Command: /opt/ci5/scripts/diagnostics/speed_test.sh"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# FINALIZE (Updated)
# ─────────────────────────────────────────────────────────────────────────────
finalize() {
    step "INSTALLATION COMPLETE"

    cat << EOF

    ╔═══════════════════════════════════════════════════════════════════╗
    ║  ${G}✓ CI5 MINIMAL PERFORMANCE STACK INSTALLED${N}                      ║
    ╠═══════════════════════════════════════════════════════════════════╣
    ║                                                                   ║
    ║  WHAT'S INSTALLED:                                                ║
    ║    • Sysctl network tuning (BBR, buffers, conntrack)              ║
    ║    • IRQ balancing for USB NICs                                   ║
    ║    • SQM/CAKE scripts for bufferbloat                             ║
    ║                                                                   ║
    ║  WHAT'S NOT INSTALLED:                                            ║
    ║    ✗ No Docker                                                    ║
    ║    ✗ No services/daemons                                          ║
    ║    ✗ No HWID/ecosystem                                            ║
    ║    ✗ No cloud callbacks                                           ║
    ║                                                                   ║
    ║  NEXT STEPS:                                                      ║
    ║    • Auto-tuning complete (if speedtest succeeded)                ║
    ║    • Manual re-tune if needed:                                    ║
    ║      /opt/ci5/scripts/diagnostics/speed_test.sh                   ║
    ║                                                                   ║
    ║    • Test bufferbloat:                                            ║
    ║      https://www.waveform.com/tools/bufferbloat                   ║
    ║                                                                   ║
    ║  UNINSTALL:                                                       ║
    ║    ci5-minimal-uninstall                                          ║
    ║                                                                   ║
    ╚═══════════════════════════════════════════════════════════════════╝

EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN (Simplified)
# ─────────────────────────────────────────────────────────────────────────────
main() {
    clear
    printf "${B}CI5 PHOENIX — Minimal Performance Installer${N}\n"
    printf "═══════════════════════════════════════════════════════════════\n"
    printf "This will install network tuning ONLY. No Docker, no services.\n"
    printf "═══════════════════════════════════════════════════════════════\n\n"
    
    printf "Continue? [Y/n]: "
    read -r ans
    case "$ans" in
        n|N) echo "Aborted."; exit 0 ;;
    esac
    
    detect_platform
    install_sysctl_tuning
    install_irq_balancing
    install_sqm
    create_uninstall
    
    run_speed_test  # New: Precise post-install tuning
    
    finalize
}

main "$@"