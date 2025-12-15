#!/bin/sh
# 🛫 Ci5 Pre-Flight Check (v7.4-RC-1)
# Run this BEFORE setup.sh to validate hardware/software compatibility
# Exit codes: 0 = Ready, 1 = Fatal, 2 = Warnings only

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
FATAL=0
WARN=0
RAM_4GB_ACKNOWLEDGED=0

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}   🛫 Ci5 Pre-Flight Validation (v7.4-RC-1)${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# ─────────────────────────────────────────────────────────────
# 1. CPU ARCHITECTURE (Pi 5 = Cortex-A76 / BCM2712)
# ─────────────────────────────────────────────────────────────
echo -n "[1/10] CPU Architecture... "
CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null || grep -m1 "Hardware" /proc/cpuinfo)
PI_REVISION=$(grep "^Revision" /proc/cpuinfo | awk '{print $3}')

if echo "$PI_REVISION" | grep -qE '^d0'; then
    echo -e "${GREEN}✓ Raspberry Pi 5 (Rev: $PI_REVISION)${NC}"
elif echo "$CPU_MODEL" | grep -qi "Cortex-A76"; then
    echo -e "${GREEN}✓ Cortex-A76 Detected${NC}"
elif echo "$CPU_MODEL" | grep -qi "Cortex-A72"; then
    echo -e "${RED}✗ Cortex-A72 (Pi 4) - NOT SUPPORTED${NC}"
    echo "    Pi 4 cannot achieve 0ms bufferbloat with IDS."
    FATAL=1
else
    echo -e "${YELLOW}⚠ Unknown CPU ($CPU_MODEL)${NC}"
    WARN=1
fi

# ─────────────────────────────────────────────────────────────
# 2. RAM CHECK (Updated: 4GB allowed with warning)
# ─────────────────────────────────────────────────────────────
echo -n "[2/10] System RAM... "
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1024 / 1024))

if [ "$TOTAL_RAM_GB" -ge 7 ]; then
    echo -e "${GREEN}✓ ${TOTAL_RAM_GB}GB (Full Stack Ready)${NC}"
elif [ "$TOTAL_RAM_GB" -ge 3 ]; then
    # 4GB Pi 5 detected - allow with explicit warning
    echo -e "${YELLOW}⚠ ${TOTAL_RAM_GB}GB Detected${NC}"
    echo ""
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  ⚠️  4GB RASPBERRY PI 5 STABILITY WARNING                        ║${NC}"
    echo -e "${YELLOW}╠══════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${YELLOW}║  Testing shows ~1.8GB RAM usage during active Bufferbloat tests  ║${NC}"
    echo -e "${YELLOW}║  with the Full Stack running. While this leaves headroom on 4GB, ║${NC}"
    echo -e "${YELLOW}║  the following risks exist:                                       ║${NC}"
    echo -e "${YELLOW}║                                                                   ║${NC}"
    echo -e "${YELLOW}║  • OOM kills possible under heavy IDS + traffic load             ║${NC}"
    echo -e "${YELLOW}║  • Suricata may drop packets if RAM is exhausted                 ║${NC}"
    echo -e "${YELLOW}║  • Docker containers may restart unexpectedly                    ║${NC}"
    echo -e "${YELLOW}║  • System instability during firmware/rule updates               ║${NC}"
    echo -e "${YELLOW}║                                                                   ║${NC}"
    echo -e "${YELLOW}║  RECOMMENDATION: 8GB model for Full Stack production use.        ║${NC}"
    echo -e "${YELLOW}║  4GB is suitable for: Lite Stack, testing, or light home use.    ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Do you acknowledge these risks and wish to proceed?${NC}"
    echo "Type 'I UNDERSTAND' to continue with 4GB configuration:"
    read -r ACKNOWLEDGE_4GB
    
    if [ "$ACKNOWLEDGE_4GB" = "I UNDERSTAND" ]; then
        echo -e "${GREEN}    ✓ 4GB risk acknowledged. Proceeding...${NC}"
        RAM_4GB_ACKNOWLEDGED=1
        # Mark as warning, not fatal - user has explicitly acknowledged
        WARN=1
    else
        echo -e "${RED}    ✗ Acknowledgment not received. Aborting.${NC}"
        echo "    For Full Stack stability, use 8GB Raspberry Pi 5."
        echo "    For Lite Stack (no Docker/IDS), 4GB is fully supported."
        FATAL=1
    fi
else
    echo -e "${RED}✗ ${TOTAL_RAM_GB}GB (Minimum 4GB Required)${NC}"
    FATAL=1
fi

# ─────────────────────────────────────────────────────────────
# 3. OPENWRT VERSION
# ─────────────────────────────────────────────────────────────
echo -n "[3/10] OpenWrt Version... "
if [ -f /etc/openwrt_release ]; then
    OWRT_VER=$(grep DISTRIB_RELEASE /etc/openwrt_release | cut -d"'" -f2)
    OWRT_MAJOR=$(echo "$OWRT_VER" | cut -d'.' -f1)
    OWRT_MINOR=$(echo "$OWRT_VER" | cut -d'.' -f2)
    
    if [ "$OWRT_MAJOR" -ge 24 ]; then
        echo -e "${GREEN}✓ OpenWrt $OWRT_VER${NC}"
    elif [ "$OWRT_MAJOR" -eq 23 ] && [ "$OWRT_MINOR" -ge 05 ]; then
        echo -e "${YELLOW}⚠ OpenWrt $OWRT_VER (24.10+ Recommended)${NC}"
        WARN=1
    else
        echo -e "${RED}✗ OpenWrt $OWRT_VER (Requires 24.10+)${NC}"
        FATAL=1
    fi
else
    echo -e "${RED}✗ Not OpenWrt (or /etc/openwrt_release missing)${NC}"
    FATAL=1
fi

# ─────────────────────────────────────────────────────────────
# 4. ROOT FILESYSTEM TYPE
# ─────────────────────────────────────────────────────────────
echo -n "[4/10] Root Filesystem... "
ROOT_FS=$(mount | grep ' / ' | awk '{print $5}')

if echo "$ROOT_FS" | grep -qi "ext4"; then
    echo -e "${GREEN}✓ EXT4 (Writable)${NC}"
elif echo "$ROOT_FS" | grep -qi "squashfs"; then
    echo -e "${RED}✗ SquashFS (Read-Only) - Use EXT4 Image!${NC}"
    FATAL=1
else
    echo -e "${YELLOW}⚠ Unknown FS: $ROOT_FS${NC}"
    WARN=1
fi

# ─────────────────────────────────────────────────────────────
# 5. STORAGE SPACE
# ─────────────────────────────────────────────────────────────
echo -n "[5/10] Free Storage... "
FREE_MB=$(df -m / | tail -1 | awk '{print $4}')

if [ "$FREE_MB" -ge 2000 ]; then
    echo -e "${GREEN}✓ ${FREE_MB}MB Free${NC}"
elif [ "$FREE_MB" -ge 1000 ]; then
    echo -e "${YELLOW}⚠ ${FREE_MB}MB Free (2GB+ Recommended for Full Stack)${NC}"
    WARN=1
else
    echo -e "${RED}✗ ${FREE_MB}MB Free (Minimum 1GB Required)${NC}"
    FATAL=1
fi

# ─────────────────────────────────────────────────────────────
# 6. USB NIC DETECTION
# ─────────────────────────────────────────────────────────────
echo -n "[6/10] USB Network Adapter... "
USB_NIC=""
USB_DRIVER=""

for iface in /sys/class/net/*; do
    name=$(basename "$iface")
    [ "$name" = "lo" ] && continue
    [ "$name" = "eth0" ] && continue
    [ "$name" = "wlan0" ] && continue
    
    if readlink -f "$iface/device" 2>/dev/null | grep -q usb; then
        USB_NIC="$name"
        USB_DRIVER=$(basename $(readlink "$iface/device/driver" 2>/dev/null) 2>/dev/null)
        break
    fi
done

if [ -n "$USB_NIC" ]; then
    CARRIER=$(cat /sys/class/net/$USB_NIC/carrier 2>/dev/null || echo "0")
    if [ "$CARRIER" = "1" ]; then
        echo -e "${GREEN}✓ $USB_NIC ($USB_DRIVER) - Link UP${NC}"
    else
        echo -e "${YELLOW}⚠ $USB_NIC ($USB_DRIVER) - No Link (Check Cable)${NC}"
        WARN=1
    fi
else
    if lsmod | grep -qE '(r8152|ax88179|asix|cdc_ncm|aqc111)'; then
        echo -e "${YELLOW}⚠ Driver loaded but no USB NIC detected${NC}"
        WARN=1
    else
        echo -e "${RED}✗ No USB NIC Found${NC}"
        echo "    Supported: RTL8153, AX88179, ASIX, AQC111"
        FATAL=1
    fi
fi

# ─────────────────────────────────────────────────────────────
# 7. ONBOARD ETHERNET
# ─────────────────────────────────────────────────────────────
echo -n "[7/10] Onboard Ethernet (eth0)... "
if ip link show eth0 >/dev/null 2>&1; then
    ETH0_CARRIER=$(cat /sys/class/net/eth0/carrier 2>/dev/null || echo "0")
    if [ "$ETH0_CARRIER" = "1" ]; then
        echo -e "${GREEN}✓ eth0 Present - Link UP${NC}"
    else
        echo -e "${YELLOW}⚠ eth0 Present - No Link${NC}"
        WARN=1
    fi
else
    echo -e "${RED}✗ eth0 Not Found${NC}"
    FATAL=1
fi

# ─────────────────────────────────────────────────────────────
# 8. REQUIRED KERNEL MODULES
# ─────────────────────────────────────────────────────────────
echo -n "[8/10] Kernel Modules... "
MISSING_MODS=""

for mod in sch_cake tcp_bbr nft_nat br_netfilter veth; do
    mod_name=$(echo "$mod" | sed 's/^kmod-//' | tr '-' '_')
    if ! lsmod | grep -q "^$mod_name" && ! lsmod | grep -q "^$(echo $mod_name | tr '_' '-')"; then
        if ! grep -q "^$mod_name " /proc/modules 2>/dev/null; then
            MISSING_MODS="$MISSING_MODS $mod"
        fi
    fi
done

if [ -z "$MISSING_MODS" ]; then
    echo -e "${GREEN}✓ All Required Modules Loaded${NC}"
else
    echo -e "${YELLOW}⚠ May be missing:$MISSING_MODS${NC}"
    echo "    (Some modules load on-demand, may be OK)"
    WARN=1
fi

# ─────────────────────────────────────────────────────────────
# 9. PACKAGE AVAILABILITY
# ─────────────────────────────────────────────────────────────
echo -n "[9/10] Critical Packages... "
MISSING_PKGS=""

for pkg in sqm-scripts unbound-daemon; do
    if ! opkg list-installed 2>/dev/null | grep -q "^$pkg "; then
        if opkg list 2>/dev/null | grep -q "^$pkg "; then
            MISSING_PKGS="$MISSING_PKGS $pkg(available)"
        else
            MISSING_PKGS="$MISSING_PKGS $pkg(MISSING)"
        fi
    fi
done

if [ -z "$MISSING_PKGS" ]; then
    echo -e "${GREEN}✓ Core Packages Installed${NC}"
else
    echo -e "${YELLOW}⚠ Not installed:$MISSING_PKGS${NC}"
    echo "    (Will be installed during setup)"
    WARN=1
fi

# ─────────────────────────────────────────────────────────────
# 10. INTERNET CONNECTIVITY
# ─────────────────────────────────────────────────────────────
echo -n "[10/10] Internet Access... "
if ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
    echo -e "${GREEN}✓ Connected${NC}"
elif ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
    echo -e "${GREEN}✓ Connected${NC}"
else
    echo -e "${YELLOW}⚠ No Internet (Required for Docker pull)${NC}"
    WARN=1
fi

# ─────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}========================================${NC}"

if [ "$FATAL" -gt 0 ]; then
    echo -e "${RED}   ❌ PRE-FLIGHT FAILED${NC}"
    echo -e "${RED}   Fix critical issues above before proceeding.${NC}"
    echo -e "${BLUE}========================================${NC}"
    exit 1
elif [ "$WARN" -gt 0 ]; then
    echo -e "${YELLOW}   ⚠️  PRE-FLIGHT: WARNINGS${NC}"
    if [ "$RAM_4GB_ACKNOWLEDGED" -eq 1 ]; then
        echo -e "${YELLOW}   4GB RAM acknowledged. Lite Stack recommended.${NC}"
    fi
    echo -e "${YELLOW}   Proceed with caution. Review warnings above.${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    read -p "Continue anyway? [y/N]: " CONTINUE
    [ "$CONTINUE" = "y" ] || [ "$CONTINUE" = "Y" ] || exit 2
    exit 0
else
    echo -e "${GREEN}   ✅ PRE-FLIGHT PASSED${NC}"
    echo -e "${GREEN}   System is ready for Ci5 installation.${NC}"
    echo -e "${BLUE}========================================${NC}"
    exit 0
fi
