#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# CI5 Identity Initialization
# Called during install-full.sh to create permanent hardware identity
# ═══════════════════════════════════════════════════════════════════════════

CI5_IDENTITY_DIR="/etc/ci5"
CI5_IDENTITY_VERSION="v1"
CI5_IDENTITY_FILE="$CI5_IDENTITY_DIR/.hwid"

# Skip if already initialized
if [ -f "$CI5_IDENTITY_FILE" ]; then
    EXISTING_HWID=$(cat "$CI5_IDENTITY_FILE")
    echo "✅ Identity exists: ${EXISTING_HWID:0:8}..."
    return 0 2>/dev/null || exit 0
fi

echo "🦴 Initializing Ci5 Hardware Identity..."

# Create directory with secure permissions
mkdir -p "$CI5_IDENTITY_DIR"
chmod 700 "$CI5_IDENTITY_DIR"

# ═══════════════════════════════════════════════════════════════════════════
# GET HARDWARE SERIAL
# Priority: Pi Serial > DMI UUID > MAC Address > Random (last resort)
# ═══════════════════════════════════════════════════════════════════════════

SERIAL=""

# Try 1: Raspberry Pi serial from cpuinfo
if [ -f /proc/cpuinfo ]; then
    SERIAL=$(grep -i "^Serial" /proc/cpuinfo 2>/dev/null | awk '{print $3}' | head -1)
    
    # Exclude invalid/default values
    if [ "$SERIAL" = "0000000000000000" ] || [ "$SERIAL" = "00000000" ]; then
        SERIAL=""
    fi
fi

# Try 2: x86/Server DMI product UUID
if [ -z "$SERIAL" ] && [ -f /sys/class/dmi/id/product_uuid ]; then
    SERIAL=$(cat /sys/class/dmi/id/product_uuid 2>/dev/null)
fi

# Try 3: Primary network interface MAC address
if [ -z "$SERIAL" ]; then
    for iface in eth0 enp0s3 ens33 wlan0; do
        if [ -f "/sys/class/net/$iface/address" ]; then
            MAC=$(cat "/sys/class/net/$iface/address" 2>/dev/null | tr -d ':')
            if [ -n "$MAC" ] && [ "$MAC" != "000000000000" ]; then
                SERIAL="MAC_$MAC"
                break
            fi
        fi
    done
fi

# Try 4: Last resort - generate random UUID (not ideal, will change on reinstall)
if [ -z "$SERIAL" ]; then
    echo "⚠️  Warning: No hardware serial found. Using random identity."
    echo "   (This identity will change if you reinstall.)"
    SERIAL="RANDOM_$(cat /proc/sys/kernel/random/uuid | tr -d '-')"
fi

# ═══════════════════════════════════════════════════════════════════════════
# GENERATE DETERMINISTIC HWID
# SHA256(Serial + Salt) — Same hardware always produces same hash
# ═══════════════════════════════════════════════════════════════════════════

HWID=$(echo -n "${SERIAL}:ci5-permanent-identity-${CI5_IDENTITY_VERSION}" | sha256sum | cut -d' ' -f1)

# Store identity
echo "$HWID" > "$CI5_IDENTITY_FILE"
chmod 600 "$CI5_IDENTITY_FILE"

# Output success
echo "✅ Identity Initialized: ${HWID:0:8}...${HWID: -8}"
echo ""
echo "   To link with GitHub, run: ci5 link"
echo ""
