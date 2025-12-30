#!/bin/sh
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  CI5 PHOENIX — CUSTOM INSTALLER                                           ║
# ║  Pick exactly which components to install                                 ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

set -e

CI5_BASE="https://ci5.run"
CI5_VERSION="1.0.0"

# Colors
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'; DIM='\033[2m'

# ─────────────────────────────────────────────────────────────────────────────
# COMPONENT STATE (Defaults)
# ─────────────────────────────────────────────────────────────────────────────
OPT_SYSCTL=1
OPT_SQM=1

OPT_SURICATA=0
OPT_CROWDSEC=0
OPT_FIREWALL=0

OPT_UNBOUND=0
OPT_ADGUARD=0

OPT_NTOPNG=0
OPT_HOMEPAGE=0

OPT_WIREGUARD=0
OPT_OPENVPN=0
OPT_CAPTIVE=0

OPT_DOCKER=0
OPT_CORKS=0
OPT_HWID=0

OPT_PARANOIA=0
OPT_TOR=0
OPT_MAC_RANDOM=0
OPT_SSH_KEYS=0
OPT_FAIL2BAN=0
OPT_NO_AUTOUPDATE=0
OPT_OFFLINE_MODE=0

# ─────────────────────────────────────────────────────────────────────────────
# HELPERS (Unchanged)
# ─────────────────────────────────────────────────────────────────────────────
toggle() {
    eval "val=\$OPT_$1"
    if [ "$val" = "1" ]; then
        eval "OPT_$1=0"
    else
        eval "OPT_$1=1"
    fi
}

checkbox() {
    if [ "$1" = "1" ]; then
        printf "${G}[✓]${N}"
    else
        printf "[ ]"
    fi
}

requires_docker() {
    [ "$OPT_SURICATA" = "1" ] || [ "$OPT_CROWDSEC" = "1" ] || \
    [ "$OPT_ADGUARD" = "1" ] || [ "$OPT_UNBOUND" = "1" ] || \
    [ "$OPT_NTOPNG" = "1" ] || [ "$OPT_HOMEPAGE" = "1" ] || \
    [ "$OPT_CORKS" = "1" ]
}

# [Retain show_menu, show_advanced functions unchanged]

# ─────────────────────────────────────────────────────────────────────────────
# APPLY PRE-CAPTURED SELECTIONS (New - From bootloader)
# ─────────────────────────────────────────────────────────────────────────────
apply_pre_captured() {
    SOUL_FILE="/etc/ci5/soul.conf"  # Persistent location post-flash
    if [ -f "$SOUL_FILE" ]; then
        . "$SOUL_FILE"  # Source CUSTOM_OPTS string
        if [ -n "$CUSTOM_OPTS" ]; then
            eval "$CUSTOM_OPTS"  # Apply overrides
            info "Pre-captured custom selections applied."
            return 0
        fi
    fi
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# POST-INSTALL SPEED TEST (New)
# ─────────────────────────────────────────────────────────────────────────────
run_speed_test() {
    step "AUTO-TUNING SQM BUFFERBLOAT SETTINGS"
    opkg install speedtest-cli >/dev/null 2>&1 || true
    if command -v speedtest-cli >/dev/null && [ -f "/opt/ci5/scripts/diagnostics/speed_test.sh" ]; then
        /opt/ci5/scripts/diagnostics/speed_test.sh auto
    else
        warn "speedtest-cli unavailable. Manual tuning recommended."
    fi
}

# [Retain run_installation function unchanged]

# ─────────────────────────────────────────────────────────────────────────────
# MAIN (Updated - Conditional menu)
# ─────────────────────────────────────────────────────────────────────────────
main() {
    clear
    printf "${B}CI5 PHOENIX — Custom Installer${N}\n"
    printf "═══════════════════════════════════════════════════\n\n"

    # Apply pre-captured if available
    if apply_pre_captured; then
        info "Using pre-selected components. Proceeding to installation..."
    else
        # Interactive menu loop (unchanged)
        while true; do
            show_menu
            printf "    Toggle [S/C/F/U/G/N/H/W/O/P/K/I] or [A]dvanced/[Enter] Install: "
            read -r choice
            
            case "$choice" in
                s|S) toggle SURICATA ;;
                c|C) toggle CROWDSEC ;;
                f|F) toggle FIREWALL ;;
                u|U) toggle UNBOUND ;;
                g|G) toggle ADGUARD ;;
                n|N) toggle NTOPNG ;;
                h|H) toggle HOMEPAGE ;;
                w|W) toggle WIREGUARD ;;
                o|O) toggle OPENVPN ;;
                p|P) toggle CAPTIVE ;;
                k|K) toggle CORKS ;;
                i|I) toggle HWID ;;
                r|R)
                    # Reset to defaults (unchanged)
                    OPT_SURICATA=0; OPT_CROWDSEC=0; OPT_FIREWALL=0
                    OPT_UNBOUND=0; OPT_ADGUARD=0
                    OPT_NTOPNG=0; OPT_HOMEPAGE=0
                    OPT_WIREGUARD=0; OPT_OPENVPN=0; OPT_CAPTIVE=0
                    OPT_CORKS=0; OPT_HWID=0
                    OPT_PARANOIA=0; OPT_TOR=0; OPT_MAC_RANDOM=0
                    OPT_SSH_KEYS=0; OPT_FAIL2BAN=0; OPT_NO_AUTOUPDATE=0
                    OPT_OFFLINE_MODE=0
                    ;;
                a|A)
                    while true; do
                        show_advanced
                        printf "    Toggle [1-7] or [B]ack: "
                        read -r adv
                        case "$adv" in
                            1) toggle PARANOIA ;;
                            2) toggle MAC_RANDOM ;;
                            3) toggle TOR ;;
                            4) toggle SSH_KEYS ;;
                            5) toggle FAIL2BAN ;;
                            6) toggle NO_AUTOUPDATE ;;
                            7) toggle OFFLINE_MODE ;;
                            b|B) break ;;
                        esac
                    done
                    ;;
                q|Q) echo "Aborted."; exit 0 ;;
                "") break ;;  # Proceed to install
            esac
        done
    fi

    run_installation
    run_speed_test

    # Final summary (retain or update as needed)
    step "CUSTOM INSTALLATION COMPLETE"
    info "Selected components deployed."
}

main "$@"