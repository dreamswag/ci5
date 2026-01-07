#!/bin/sh
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  CI5 PHOENIX BOOTSTRAP v3.0                                               ║
# ║  Handles: Debian→OpenWrt flash | OpenWrt in-place upgrade                 ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Usage: curl -sL ci5.run | sh -s free    (recommended)
#        curl -sL ci5.run | sh -s 4evr    (minimal)
#        curl -sL ci5.run | sh -s 1314    (custom)

set -e

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────
CI5_VERSION="3.0.0"
CI5_RAW="https://raw.githubusercontent.com/dreamswag/ci5/main"
SOUL_FILE="/etc/ci5/soul.conf"
OPENWRT_IMAGE_URL="https://downloads.openwrt.org/releases/23.05.3/targets/bcm27xx/bcm2712/openwrt-23.05.3-bcm27xx-bcm2712-rpi-5-ext4-factory.img.gz"

# Colors
if [ -t 1 ]; then
    R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
else
    R=''; G=''; Y=''; C=''; B=''; N=''
fi

# Helpers
die() { printf "${R}[✗] %s${N}\n" "$1" >&2; exit 1; }
info() { printf "${G}[✓]${N} %s\n" "$1"; }
warn() { printf "${Y}[!]${N} %s\n" "$1"; }
err() { printf "${R}[✗]${N} %s\n" "$1"; }
step() { printf "\n${B}═══ %s ═══${N}\n\n" "$1"; }

# ─────────────────────────────────────────────────────────────────────────────
# ARGUMENT PARSING
# ─────────────────────────────────────────────────────────────────────────────
INSTALL_MODE="recommended"

for arg in "$@"; do
    case "$arg" in
        -recommended|-free) INSTALL_MODE="recommended" ;;
        -minimal|-4evr)     INSTALL_MODE="minimal" ;;
        -custom|-1314)      INSTALL_MODE="custom" ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# HARDWARE CHECK (Pi 5 Only)
# ─────────────────────────────────────────────────────────────────────────────
check_hardware() {
    step "HARDWARE VERIFICATION"

    if ! grep -q "Raspberry Pi 5" /proc/cpuinfo 2>/dev/null; then
        if [ -f /proc/device-tree/model ]; then
            MODEL=$(tr -d '\0' < /proc/device-tree/model)
            err "Detected: $MODEL"
        fi
        die "CI5 requires Raspberry Pi 5 (BCM2712). Pi 4 and lower are unsupported."
    fi

    RAM_MB=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
    info "Hardware: Raspberry Pi 5 (${RAM_MB}MB RAM)"

    if [ "$RAM_MB" -lt 4000 ]; then
        warn "4GB RAM detected - ntopng will be skipped in recommended mode"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# PLATFORM DETECTION
# ─────────────────────────────────────────────────────────────────────────────
detect_platform() {
    if [ -f /etc/openwrt_release ]; then
        PLATFORM="openwrt"
        . /etc/openwrt_release
        info "Platform: OpenWrt $DISTRIB_RELEASE"
    elif [ -f /etc/debian_version ]; then
        PLATFORM="debian"
        DEBIAN_VER=$(cat /etc/debian_version)
        info "Platform: Debian $DEBIAN_VER (will flash OpenWrt)"
    else
        PLATFORM="unknown"
        warn "Unknown platform - attempting OpenWrt in-place mode"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# NIC DETECTION & CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────
detect_nic() {
    step "NIC DETECTION"

    NIC_PROFILE=""
    WAN_IF=""
    HAT_NIC_DETECTED=0
    USB_NIC_DETECTED=0
    PCIE_DEVICE=""

    # Check for PCIe HAT NIC (Intel i225/i226, Realtek 8125, etc.)
    if [ -d /sys/bus/pci/devices ]; then
        for pci_dev in /sys/bus/pci/devices/*; do
            [ -d "$pci_dev" ] || continue
            vendor=$(cat "$pci_dev/vendor" 2>/dev/null | tr -d '\n')
            device=$(cat "$pci_dev/device" 2>/dev/null | tr -d '\n')
            class=$(cat "$pci_dev/class" 2>/dev/null | tr -d '\n')

            # Network controller class (0x02xxxx)
            if echo "$class" | grep -qi "^0x02"; then
                case "$vendor" in
                    0x8086)  # Intel
                        case "$device" in
                            0x15f3|0x15f2|0x125b|0x125c)  # i225-V, i225-LM, i226-V, i226-LM
                                HAT_NIC_DETECTED=1
                                PCIE_DEVICE="Intel i225/i226 (2.5GbE)"
                                PCIE_DRIVER="igc"
                                ;;
                        esac
                        ;;
                    0x10ec)  # Realtek
                        case "$device" in
                            0x8125|0x8126)  # RTL8125 2.5GbE
                                HAT_NIC_DETECTED=1
                                PCIE_DEVICE="Realtek RTL8125 (2.5GbE)"
                                PCIE_DRIVER="r8169"
                                ;;
                        esac
                        ;;
                esac
            fi
        done
    fi

    # Check for USB 3.0 NIC (RTL8153, AX88179, etc.)
    if [ -d /sys/bus/usb/devices ]; then
        for usb_dev in /sys/bus/usb/devices/*; do
            [ -f "$usb_dev/idVendor" ] || continue
            vendor=$(cat "$usb_dev/idVendor" 2>/dev/null)
            product=$(cat "$usb_dev/idProduct" 2>/dev/null)

            case "${vendor}:${product}" in
                0bda:8153|0bda:8156)  # Realtek RTL8153/RTL8156
                    USB_NIC_DETECTED=1
                    USB_DEVICE="Realtek RTL8153 (1GbE USB3)"
                    ;;
                0b95:1790|0b95:178a)  # ASIX AX88179
                    USB_NIC_DETECTED=1
                    USB_DEVICE="ASIX AX88179 (1GbE USB3)"
                    ;;
                2357:0601|2357:0602)  # TP-Link UE300/UE306
                    USB_NIC_DETECTED=1
                    USB_DEVICE="TP-Link USB3 GbE"
                    ;;
            esac
        done
    fi

    # Report findings
    if [ "$HAT_NIC_DETECTED" = "1" ]; then
        info "HAT NIC detected: ${C}$PCIE_DEVICE${N}"
    fi
    if [ "$USB_NIC_DETECTED" = "1" ]; then
        info "USB NIC detected: ${C}$USB_DEVICE${N}"
    fi

    # Determine available interfaces
    printf "\n"
    info "Available network interfaces:"
    for iface in /sys/class/net/*; do
        [ -d "$iface" ] || continue
        name=$(basename "$iface")
        [ "$name" = "lo" ] && continue

        # Get driver info
        driver=""
        if [ -L "$iface/device/driver" ]; then
            driver=$(basename "$(readlink "$iface/device/driver")" 2>/dev/null)
        fi

        # Get MAC and state
        mac=$(cat "$iface/address" 2>/dev/null)
        state=$(cat "$iface/operstate" 2>/dev/null)

        case "$name" in
            eth0) printf "    ${B}eth0${N}: Onboard (LAN default) - $mac\n" ;;
            eth1)
                if [ "$driver" = "r8152" ] || [ "$driver" = "ax88179_178a" ]; then
                    printf "    ${B}eth1${N}: USB 3.0 NIC ($driver) - $mac\n"
                else
                    printf "    ${B}eth1${N}: $driver - $mac\n"
                fi
                ;;
            eth2)
                printf "    ${B}eth2${N}: HAT NIC ($driver) - $mac\n"
                ;;
            wlan*) printf "    ${C}$name${N}: WiFi - $mac\n" ;;
            *) printf "    $name: $driver - $mac\n" ;;
        esac
    done

    printf "\n"

    # Auto-select or prompt
    if [ "$HAT_NIC_DETECTED" = "1" ] && [ "$USB_NIC_DETECTED" = "1" ]; then
        # Both detected - ask user
        printf "${B}Multiple WAN NICs detected. Select your WAN interface:${N}\n"
        printf "  ${B}1)${N} USB 3.0 NIC (eth1) - ${USB_DEVICE}\n"
        printf "  ${B}2)${N} HAT NIC (eth2) - ${PCIE_DEVICE} ${G}[Recommended]${N}\n"
        printf "  ${B}3)${N} AP-less mode (eth0 to PC, WiFi for personal use)\n"
        printf "Select [1-3]: "
        read -r nic_choice
        case "$nic_choice" in
            1) NIC_PROFILE="usb3"; WAN_IF="eth1" ;;
            3) NIC_PROFILE="apless"; WAN_IF="eth1"; APLESS_MODE=1 ;;
            *) NIC_PROFILE="hat"; WAN_IF="eth2" ;;
        esac
    elif [ "$HAT_NIC_DETECTED" = "1" ]; then
        info "Auto-selected: HAT NIC (eth2)"
        NIC_PROFILE="hat"
        WAN_IF="eth2"

        printf "Use HAT NIC as WAN? [Y/n] or [a]p-less mode: "
        read -r ans
        case "$ans" in
            n|N) NIC_PROFILE="usb3"; WAN_IF="eth1" ;;
            a|A) NIC_PROFILE="apless"; WAN_IF="eth1"; APLESS_MODE=1 ;;
        esac
    elif [ "$USB_NIC_DETECTED" = "1" ]; then
        info "Auto-selected: USB 3.0 NIC (eth1)"
        NIC_PROFILE="usb3"
        WAN_IF="eth1"

        printf "Use USB NIC as WAN? [Y/n] or [a]p-less mode: "
        read -r ans
        case "$ans" in
            n|N) NIC_PROFILE="hat"; WAN_IF="eth2" ;;
            a|A) NIC_PROFILE="apless"; WAN_IF="eth1"; APLESS_MODE=1 ;;
        esac
    else
        # No WAN NIC detected - prompt
        warn "No USB 3.0 or HAT NIC auto-detected"
        printf "${B}Select your WAN configuration:${N}\n"
        printf "  ${B}1)${N} USB 3.0 NIC on eth1 ${G}[Default]${N}\n"
        printf "  ${B}2)${N} HAT/PCIe NIC on eth2\n"
        printf "  ${B}3)${N} AP-less mode (eth0 to PC, WiFi for personal use)\n"
        printf "Select [1-3]: "
        read -r nic_choice
        case "$nic_choice" in
            2) NIC_PROFILE="hat"; WAN_IF="eth2" ;;
            3) NIC_PROFILE="apless"; WAN_IF="eth1"; APLESS_MODE=1 ;;
            *) NIC_PROFILE="usb3"; WAN_IF="eth1" ;;
        esac
    fi

    # Set LAN interface based on mode
    if [ "${APLESS_MODE:-0}" = "1" ]; then
        LAN_IF="wlan0"
        info "AP-less mode: eth0→PC, wlan0→Personal WiFi"
    else
        LAN_IF="eth0"
    fi

    info "NIC Profile: ${C}$NIC_PROFILE${N} | WAN: ${C}$WAN_IF${N} | LAN: ${C}$LAN_IF${N}"
}

# ─────────────────────────────────────────────────────────────────────────────
# HAT NIC SETUP (PCIe configuration)
# ─────────────────────────────────────────────────────────────────────────────
setup_hat_nic() {
    [ "$NIC_PROFILE" != "hat" ] && return 0

    step "CONFIGURING HAT NIC (PCIe)"

    # Install required kernel modules
    if [ "$PLATFORM" = "openwrt" ]; then
        info "Installing PCIe NIC kernel modules..."
        opkg update >/dev/null 2>&1

        case "$PCIE_DRIVER" in
            igc)
                opkg install kmod-igc pciutils >/dev/null 2>&1 && \
                    info "Installed kmod-igc (Intel i225/i226)" || \
                    warn "kmod-igc install failed - may need manual install"
                ;;
            r8169)
                opkg install kmod-r8169 pciutils >/dev/null 2>&1 && \
                    info "Installed kmod-r8169 (Realtek 8125)" || \
                    warn "kmod-r8169 install failed"
                ;;
        esac
    fi

    # Configure PCIe Gen3 in config.txt (if accessible)
    BOOT_CONFIG=""
    for cfg in /boot/config.txt /boot/firmware/config.txt /mnt/boot/config.txt; do
        [ -f "$cfg" ] && BOOT_CONFIG="$cfg" && break
    done

    if [ -n "$BOOT_CONFIG" ]; then
        info "Configuring PCIe Gen3 in $BOOT_CONFIG"

        # Add PCIe configuration if not present
        if ! grep -q "dtparam=pciex1" "$BOOT_CONFIG"; then
            cat >> "$BOOT_CONFIG" << 'PCIE_CFG'

# CI5 HAT NIC PCIe Configuration
dtparam=pciex1
dtparam=pciex1_gen=3
PCIE_CFG
            info "Added PCIe Gen3 configuration (requires reboot)"
            HAT_NEEDS_REBOOT=1
        else
            info "PCIe already configured in config.txt"
        fi
    else
        warn "config.txt not found - PCIe Gen3 may need manual configuration"
        warn "Add to /boot/config.txt: dtparam=pciex1 and dtparam=pciex1_gen=3"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# ISP SETTINGS CAPTURE (Manual)
# ─────────────────────────────────────────────────────────────────────────────
capture_isp_settings() {
    step "ISP CONNECTIVITY SETUP"
    info "Configure your WAN connection for the new CI5 installation."
    printf "\n"

    # WAN Protocol
    printf "WAN Protocol:\n"
    printf "  ${B}1)${N} DHCP (Cable, Starlink, Fiber ONT, behind existing router) ${G}[Default]${N}\n"
    printf "  ${B}2)${N} PPPoE (DSL/Fiber with ISP login required)\n"
    printf "  ${B}3)${N} Static IP\n"
    printf "Select [1-3]: "
    read -r proto_sel

    case "$proto_sel" in
        2)
            WAN_PROTO="pppoe"
            printf "PPPoE Username: "
            read -r WAN_USER
            printf "PPPoE Password: "
            read -r WAN_PASS
            printf "VLAN ID (leave empty if none): "
            read -r WAN_VLAN
            ;;
        3)
            WAN_PROTO="static"
            printf "IP Address (e.g., 192.168.1.2): "
            read -r WAN_IPADDR
            printf "Netmask (e.g., 255.255.255.0): "
            read -r WAN_NETMASK
            printf "Gateway (e.g., 192.168.1.1): "
            read -r WAN_GATEWAY
            printf "DNS Server (e.g., 1.1.1.1): "
            read -r WAN_DNS
            ;;
        *)
            WAN_PROTO="dhcp"
            WAN_USER=""
            WAN_PASS=""
            WAN_VLAN=""
            ;;
    esac

    # Connection type for CAKE overhead
    printf "\nPhysical connection type (for SQM overhead calculation):\n"
    printf "  ${B}1)${N} Ethernet/Fiber (direct)\n"
    printf "  ${B}2)${N} Cable Modem (DOCSIS)\n"
    printf "  ${B}3)${N} VDSL\n"
    printf "  ${B}4)${N} ADSL\n"
    printf "Select [1-4]: "
    read -r link_sel

    case "$link_sel" in
        2) LINK_LAYER="ethernet"; OVERHEAD=22 ;;
        3) LINK_LAYER="none"; OVERHEAD=26 ;;
        4) LINK_LAYER="atm"; OVERHEAD=44 ;;
        *) LINK_LAYER="ethernet"; OVERHEAD=18 ;;
    esac

    # Add PPPoE overhead
    [ "$WAN_PROTO" = "pppoe" ] && OVERHEAD=$((OVERHEAD + 8))
    [ -n "$WAN_VLAN" ] && OVERHEAD=$((OVERHEAD + 4))

    info "WAN: $WAN_PROTO | Overhead: $OVERHEAD bytes"
}

# ─────────────────────────────────────────────────────────────────────────────
# ISP SETTINGS CAPTURE (Auto from OpenWrt)
# ─────────────────────────────────────────────────────────────────────────────
capture_openwrt_settings() {
    step "AUTO-DETECTING CURRENT SETTINGS"

    # WAN settings
    WAN_PROTO=$(uci -q get network.wan.proto || echo "dhcp")
    WAN_DEVICE=$(uci -q get network.wan.device || uci -q get network.wan.ifname || echo "eth1")

    # Extract VLAN if present
    WAN_VLAN=""
    if echo "$WAN_DEVICE" | grep -q '\.'; then
        WAN_VLAN=$(echo "$WAN_DEVICE" | cut -d'.' -f2)
    fi

    # PPPoE credentials
    if [ "$WAN_PROTO" = "pppoe" ]; then
        WAN_USER=$(uci -q get network.wan.username || echo "")
        WAN_PASS=$(uci -q get network.wan.password || echo "")
    fi

    # Static IP settings
    if [ "$WAN_PROTO" = "static" ]; then
        WAN_IPADDR=$(uci -q get network.wan.ipaddr || echo "")
        WAN_NETMASK=$(uci -q get network.wan.netmask || echo "255.255.255.0")
        WAN_GATEWAY=$(uci -q get network.wan.gateway || echo "")
        WAN_DNS=$(uci -q get network.wan.dns || echo "")
    fi

    # SQM settings if exist
    OVERHEAD=$(uci -q get sqm.wan.overhead || echo "18")
    LINK_LAYER=$(uci -q get sqm.wan.linklayer || echo "ethernet")

    # LAN interface
    LAN_IF=$(uci -q get network.lan.device || uci -q get network.lan.ifname || echo "eth0")

    info "Detected settings:"
    info "  WAN Protocol: $WAN_PROTO"
    [ -n "$WAN_VLAN" ] && info "  WAN VLAN: $WAN_VLAN"
    [ "$WAN_PROTO" = "pppoe" ] && info "  PPPoE User: $WAN_USER"
    [ "$WAN_PROTO" = "static" ] && info "  Static IP: $WAN_IPADDR"
    info "  SQM Overhead: $OVERHEAD"
    info "  LAN Interface: $LAN_IF"

    printf "\n${Y}Use these settings? [Y/n] or [m]anual: ${N}"
    read -r ans
    case "$ans" in
        n|N) die "Aborted by user" ;;
        m|M) capture_isp_settings ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# CUSTOM PROFILE CAPTURE (Interactive)
# ─────────────────────────────────────────────────────────────────────────────
capture_custom_profile() {
    step "CUSTOM COMPONENT SELECTION"

    # Defaults
    CUSTOM_SURICATA=0; CUSTOM_CROWDSEC=0; CUSTOM_ADGUARD=0
    CUSTOM_UNBOUND=1; CUSTOM_NTOPNG=0; CUSTOM_DOCKER=0
    CUSTOM_VLANS=1; CUSTOM_FIREWALL=1; CUSTOM_SQM=1

    toggle() {
        eval "val=\$CUSTOM_$1"
        if [ "$val" = "1" ]; then eval "CUSTOM_$1=0"; else eval "CUSTOM_$1=1"; fi
    }

    checkbox() {
        if [ "$1" = "1" ]; then printf "${G}[x]${N}"; else printf "[ ]"; fi
    }

    while true; do
        clear
        printf "${B}CI5 CUSTOM PROFILE${N}\n"
        printf "Toggle components with their letter, Enter to proceed:\n\n"

        printf "  ${B}CORE (always enabled):${N}\n"
        printf "    %s [V]LANs (10=Trusted, 20=Work, 30=IoT, 40=Guest)\n" "$(checkbox $CUSTOM_VLANS)"
        printf "    %s [F]irewall Zones\n" "$(checkbox $CUSTOM_FIREWALL)"
        printf "    %s [Q] SQM/CAKE\n" "$(checkbox $CUSTOM_SQM)"
        printf "\n"
        printf "  ${B}DNS:${N}\n"
        printf "    %s [U]nbound (recursive resolver)\n" "$(checkbox $CUSTOM_UNBOUND)"
        printf "    %s [A]dGuard Home (ad-blocking, requires Docker)\n" "$(checkbox $CUSTOM_ADGUARD)"
        printf "\n"
        printf "  ${B}SECURITY (requires Docker):${N}\n"
        printf "    %s [S]uricata IDS\n" "$(checkbox $CUSTOM_SURICATA)"
        printf "    %s [C]rowdSec (threat intelligence)\n" "$(checkbox $CUSTOM_CROWDSEC)"
        printf "\n"
        printf "  ${B}MONITORING (requires Docker):${N}\n"
        printf "    %s [N]topng (traffic analysis)\n" "$(checkbox $CUSTOM_NTOPNG)"
        printf "\n"
        printf "    %s [D]ocker (auto-enabled if needed)\n" "$(checkbox $CUSTOM_DOCKER)"
        printf "\n"
        printf "  [Enter] Proceed | [R]eset | [Q]uit\n"
        printf "  Toggle: "
        read -r choice

        case "$choice" in
            v|V) toggle VLANS ;;
            f|F) toggle FIREWALL ;;
            q|Q) if [ "$choice" = "Q" ] || [ "$choice" = "q" ]; then
                     printf "Quit? [y/N]: "; read -r q; [ "$q" = "y" ] && exit 0
                 fi
                 toggle SQM ;;
            u|U) toggle UNBOUND ;;
            a|A) toggle ADGUARD; [ "$CUSTOM_ADGUARD" = "1" ] && CUSTOM_DOCKER=1 ;;
            s|S) toggle SURICATA; [ "$CUSTOM_SURICATA" = "1" ] && CUSTOM_DOCKER=1 ;;
            c|C) toggle CROWDSEC; [ "$CUSTOM_CROWDSEC" = "1" ] && CUSTOM_DOCKER=1 ;;
            n|N) toggle NTOPNG; [ "$CUSTOM_NTOPNG" = "1" ] && CUSTOM_DOCKER=1 ;;
            d|D) toggle DOCKER ;;
            r|R)
                CUSTOM_SURICATA=0; CUSTOM_CROWDSEC=0; CUSTOM_ADGUARD=0
                CUSTOM_UNBOUND=1; CUSTOM_NTOPNG=0; CUSTOM_DOCKER=0
                CUSTOM_VLANS=1; CUSTOM_FIREWALL=1; CUSTOM_SQM=1
                ;;
            "") break ;;
        esac
    done

    # Auto-enable Docker if any Docker component selected
    if [ "$CUSTOM_SURICATA" = "1" ] || [ "$CUSTOM_CROWDSEC" = "1" ] || \
       [ "$CUSTOM_ADGUARD" = "1" ] || [ "$CUSTOM_NTOPNG" = "1" ]; then
        CUSTOM_DOCKER=1
    fi

    info "Custom profile captured"
}

# ─────────────────────────────────────────────────────────────────────────────
# SAVE SOUL (Configuration for installers)
# ─────────────────────────────────────────────────────────────────────────────
save_soul() {
    step "SAVING CONFIGURATION"

    mkdir -p /etc/ci5

    cat > "$SOUL_FILE" << EOF
# CI5 Soul Configuration
# Generated: $(date -Iseconds)
# Mode: $INSTALL_MODE

# Install mode
INSTALL_MODE="$INSTALL_MODE"

# NIC Configuration
NIC_PROFILE="${NIC_PROFILE:-usb3}"
WAN_IF="${WAN_IF:-eth1}"
LAN_IF="${LAN_IF:-eth0}"
APLESS_MODE="${APLESS_MODE:-0}"
PCIE_DRIVER="${PCIE_DRIVER:-}"

# WAN Configuration
WAN_PROTO="$WAN_PROTO"
WAN_USER="$WAN_USER"
WAN_PASS="$WAN_PASS"
WAN_VLAN="$WAN_VLAN"
WAN_IPADDR="${WAN_IPADDR:-}"
WAN_NETMASK="${WAN_NETMASK:-}"
WAN_GATEWAY="${WAN_GATEWAY:-}"
WAN_DNS="${WAN_DNS:-}"

# SQM Configuration
LINK_LAYER="$LINK_LAYER"
OVERHEAD="$OVERHEAD"

# Custom Profile (1314 mode)
CUSTOM_VLANS="${CUSTOM_VLANS:-1}"
CUSTOM_FIREWALL="${CUSTOM_FIREWALL:-1}"
CUSTOM_SQM="${CUSTOM_SQM:-1}"
CUSTOM_UNBOUND="${CUSTOM_UNBOUND:-1}"
CUSTOM_ADGUARD="${CUSTOM_ADGUARD:-0}"
CUSTOM_SURICATA="${CUSTOM_SURICATA:-0}"
CUSTOM_CROWDSEC="${CUSTOM_CROWDSEC:-0}"
CUSTOM_NTOPNG="${CUSTOM_NTOPNG:-0}"
CUSTOM_DOCKER="${CUSTOM_DOCKER:-0}"
EOF

    chmod 600 "$SOUL_FILE"
    info "Soul saved to $SOUL_FILE"
}

# ─────────────────────────────────────────────────────────────────────────────
# DETECT TARGET DRIVE (for Debian→OpenWrt flash)
# ─────────────────────────────────────────────────────────────────────────────
detect_target_drive() {
    step "DETECTING TARGET STORAGE"

    # Find USB or NVMe drive (not the boot SD card)
    TARGET_DRIVE=""

    # Try NVMe first
    for dev in /dev/nvme0n1 /dev/nvme1n1; do
        if [ -b "$dev" ]; then
            TARGET_DRIVE="$dev"
            break
        fi
    done

    # Try USB drives
    if [ -z "$TARGET_DRIVE" ]; then
        for dev in /dev/sda /dev/sdb /dev/sdc; do
            if [ -b "$dev" ]; then
                # Make sure it's not the boot device
                BOOT_DEV=$(mount | grep ' / ' | cut -d' ' -f1 | sed 's/[0-9]*$//')
                if [ "$dev" != "$BOOT_DEV" ]; then
                    TARGET_DRIVE="$dev"
                    break
                fi
            fi
        done
    fi

    if [ -z "$TARGET_DRIVE" ]; then
        err "No target drive detected!"
        warn "Please insert a USB 3.0 drive or NVMe SSD (16GB minimum)"
        die "Cannot proceed without target storage"
    fi

    DRIVE_SIZE=$(lsblk -dn -o SIZE "$TARGET_DRIVE" 2>/dev/null || echo "unknown")
    DRIVE_MODEL=$(lsblk -dn -o MODEL "$TARGET_DRIVE" 2>/dev/null | xargs || echo "unknown")

    info "Target: ${C}$TARGET_DRIVE${N} ($DRIVE_MODEL, $DRIVE_SIZE)"

    printf "\n${R}WARNING: ALL DATA ON $TARGET_DRIVE WILL BE ERASED!${N}\n"
    printf "Proceed? [y/N]: "
    read -r confirm
    [ "$confirm" = "y" ] || [ "$confirm" = "Y" ] || die "Aborted by user"
}

# ─────────────────────────────────────────────────────────────────────────────
# FLASH OPENWRT (Debian→OpenWrt path)
# ─────────────────────────────────────────────────────────────────────────────
flash_openwrt() {
    step "FLASHING OPENWRT TO $TARGET_DRIVE"

    # Download OpenWrt image
    info "Downloading OpenWrt image..."
    curl -L -o /tmp/openwrt.img.gz "$OPENWRT_IMAGE_URL" || \
        die "Failed to download OpenWrt image"

    # Write to drive
    info "Writing image (this takes a few minutes)..."
    zcat /tmp/openwrt.img.gz | dd of="$TARGET_DRIVE" bs=4M status=progress conv=fsync

    sync
    sleep 2

    # Refresh partition table
    partprobe "$TARGET_DRIVE" 2>/dev/null || true
    sleep 3

    # Mount and inject soul
    step "INJECTING CONFIGURATION"

    # Determine partition naming
    if echo "$TARGET_DRIVE" | grep -q "nvme"; then
        ROOT_PART="${TARGET_DRIVE}p2"
    else
        ROOT_PART="${TARGET_DRIVE}2"
    fi

    mkdir -p /mnt/ci5_target
    if mount "$ROOT_PART" /mnt/ci5_target 2>/dev/null; then
        # Copy soul config
        mkdir -p /mnt/ci5_target/etc/ci5
        cp "$SOUL_FILE" /mnt/ci5_target/etc/ci5/soul.conf

        # Create first-boot marker
        touch /mnt/ci5_target/etc/ci5/.first_boot_pending

        # Create first-boot script that runs CI5 installer
        mkdir -p /mnt/ci5_target/etc/uci-defaults
        cat > /mnt/ci5_target/etc/uci-defaults/99-ci5-first-boot << 'FIRSTBOOT'
#!/bin/sh
# CI5 First Boot - runs after OpenWrt initial setup

[ -f /etc/ci5/.first_boot_pending ] || exit 0

# Wait for network
sleep 10

# Source soul config
. /etc/ci5/soul.conf

# Download and run appropriate installer
CI5_RAW="https://raw.githubusercontent.com/dreamswag/ci5/main"

case "$INSTALL_MODE" in
    recommended)
        curl -fsSL "${CI5_RAW}/scripts/bootstrap/install-recommended.sh" -o /tmp/ci5-install.sh
        ;;
    minimal)
        curl -fsSL "${CI5_RAW}/scripts/bootstrap/install-minimal.sh" -o /tmp/ci5-install.sh
        ;;
    custom)
        curl -fsSL "${CI5_RAW}/scripts/bootstrap/install-custom.sh" -o /tmp/ci5-install.sh
        ;;
esac

chmod +x /tmp/ci5-install.sh
/tmp/ci5-install.sh --from-soul

# Remove marker
rm -f /etc/ci5/.first_boot_pending
FIRSTBOOT
        chmod +x /mnt/ci5_target/etc/uci-defaults/99-ci5-first-boot

        umount /mnt/ci5_target
        info "Configuration injected successfully"
    else
        warn "Could not mount target partition for injection"
        warn "Manual configuration will be required after first boot"
    fi

    rm -f /tmp/openwrt.img.gz
}

# ─────────────────────────────────────────────────────────────────────────────
# RUN INSTALLER (OpenWrt in-place path)
# ─────────────────────────────────────────────────────────────────────────────
run_installer() {
    step "RUNNING CI5 INSTALLER ($INSTALL_MODE)"

    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

    case "$INSTALL_MODE" in
        recommended)
            if [ -f "$SCRIPT_DIR/install-recommended.sh" ]; then
                exec "$SCRIPT_DIR/install-recommended.sh" --from-soul
            else
                curl -fsSL "${CI5_RAW}/scripts/bootstrap/install-recommended.sh" -o /tmp/ci5-install.sh
                chmod +x /tmp/ci5-install.sh
                exec /tmp/ci5-install.sh --from-soul
            fi
            ;;
        minimal)
            if [ -f "$SCRIPT_DIR/install-minimal.sh" ]; then
                exec "$SCRIPT_DIR/install-minimal.sh" --from-soul
            else
                curl -fsSL "${CI5_RAW}/scripts/bootstrap/install-minimal.sh" -o /tmp/ci5-install.sh
                chmod +x /tmp/ci5-install.sh
                exec /tmp/ci5-install.sh --from-soul
            fi
            ;;
        custom)
            if [ -f "$SCRIPT_DIR/install-custom.sh" ]; then
                exec "$SCRIPT_DIR/install-custom.sh" --from-soul
            else
                curl -fsSL "${CI5_RAW}/scripts/bootstrap/install-custom.sh" -o /tmp/ci5-install.sh
                chmod +x /tmp/ci5-install.sh
                exec /tmp/ci5-install.sh --from-soul
            fi
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
main() {
    clear
    printf "${B}╔═══════════════════════════════════════════════════════════════════╗${N}\n"
    printf "${B}║          CI5 PHOENIX BOOTSTRAP — Pi 5 Sovereign Router            ║${N}\n"
    printf "${B}╚═══════════════════════════════════════════════════════════════════╝${N}\n"
    printf "\n"
    printf "  Install Mode: ${C}$INSTALL_MODE${N}\n"
    printf "\n"

    # Must be root
    [ "$(id -u)" -eq 0 ] || die "Must run as root"

    # Hardware check
    check_hardware

    # Platform detection
    detect_platform

    # NIC detection & configuration
    detect_nic

    # Setup HAT NIC if selected
    setup_hat_nic

    # ISP/WAN settings capture
    if [ "$PLATFORM" = "openwrt" ]; then
        capture_openwrt_settings
    else
        capture_isp_settings
    fi

    # Custom profile capture (1314 mode only)
    if [ "$INSTALL_MODE" = "custom" ]; then
        capture_custom_profile
    fi

    # Save soul configuration
    save_soul

    # Execute based on platform
    if [ "$PLATFORM" = "openwrt" ]; then
        # In-place installation
        printf "\n${Y}Ready to install CI5 on this OpenWrt system.${N}\n"
        printf "Continue? [Y/n]: "
        read -r ans
        case "$ans" in
            n|N) die "Aborted by user" ;;
        esac

        run_installer
    else
        # Debian/other: Flash OpenWrt to secondary drive
        printf "\n${Y}This will flash OpenWrt to a secondary drive (USB/NVMe).${N}\n"
        printf "${Y}Your current system on the SD card will NOT be modified.${N}\n"
        printf "Continue? [Y/n]: "
        read -r ans
        case "$ans" in
            n|N) die "Aborted by user" ;;
        esac

        detect_target_drive
        flash_openwrt

        step "FLASH COMPLETE"
        cat << EOF

${G}OpenWrt has been flashed to $TARGET_DRIVE${N}

${B}NEXT STEPS:${N}
  1. Power off: ${C}sudo poweroff${N}
  2. Remove the SD card (optional but recommended)
  3. Power on - the Pi will boot from $TARGET_DRIVE
  4. CI5 will auto-configure on first boot

${B}FIRST BOOT:${N}
  - OpenWrt will initialize (~2 minutes)
  - CI5 installer will run automatically
  - Your WAN settings have been pre-configured
  - Access LuCI at: ${C}http://192.168.1.1${N}

EOF
    fi
}

main "$@"
