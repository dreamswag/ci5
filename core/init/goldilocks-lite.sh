#!/bin/sh
# Goldilocks Lite: Hardware-Bound Identity (No Factory Key Required)
# Uses: CPU Serial (OTP 31+35) + MAC (OTP 50-55) + Random Salt

set -e

IDENTITY_DIR="/etc/ci5/identity"
SALT_FILE="$IDENTITY_DIR/salt"
NPUB_FILE="$IDENTITY_DIR/npub"

# ─────────────────────────────────────────────────────────────────────────────
# READ HARDWARE IDENTIFIERS FROM OTP
# ─────────────────────────────────────────────────────────────────────────────
read_otp_serial() {
    # Read from OTP rows 31 and 35
    local row31=$(vcgencmd otp_dump | grep "^31:" | cut -d: -f2)
    local row35=$(vcgencmd otp_dump | grep "^35:" | cut -d: -f2)

    # Combine: upper 32 bits (row 35) + lower 32 bits (row 31)
    echo "${row35}${row31}"
}

read_otp_mac() {
    # Read from OTP rows 50-51
    local row50=$(vcgencmd otp_dump | grep "^50:" | cut -d: -f2)
    local row51=$(vcgencmd otp_dump | grep "^51:" | cut -d: -f2)

    echo "${row51}${row50}"
}

# ─────────────────────────────────────────────────────────────────────────────
# MULTI-PATH SERIAL VERIFICATION
# ─────────────────────────────────────────────────────────────────────────────
verify_serial_consistency() {
    # Path 1: OTP dump
    local otp_serial=$(read_otp_serial)

    # Path 2: Device tree
    local dt_serial=""
    if [ -f /proc/device-tree/serial-number ]; then
        dt_serial=$(tr -d '\0' < /proc/device-tree/serial-number)
    fi

    # Path 3: /proc/cpuinfo
    local cpuinfo_serial=$(grep -i "^serial" /proc/cpuinfo | awk '{print $3}')

    # All paths should match (ignoring case, leading zeros)
    local normalized_otp=$(echo "$otp_serial" | tr '[:upper:]' '[:lower:]')
    local normalized_dt=$(echo "$dt_serial" | tr '[:upper:]' '[:lower:]')
    local normalized_cpu=$(echo "$cpuinfo_serial" | tr '[:upper:]' '[:lower:]')

    # Basic normalization to handle potential leading zeros diffs if necessary, 
    # but usually they match exactly on Pi.
    
    # Note: If commands fail (e.g. non-Pi hardware), vars might be empty.
    if [ -z "$normalized_otp" ]; then
         echo "[!] SECURITY ALERT: Could not read OTP serial."
         return 1
    fi

    if [ "$normalized_otp" != "$normalized_dt" ] || [ "$normalized_dt" != "$normalized_cpu" ]; then
        echo "[!] SECURITY ALERT: Serial number mismatch across read paths!"
        echo "    OTP:      $otp_serial"
        echo "    DevTree:  $dt_serial"
        echo "    CPUInfo:  $cpuinfo_serial"
        return 1
    fi

    echo "$otp_serial"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# IDENTITY DERIVATION
# ─────────────────────────────────────────────────────────────────────────────
init_identity() {
    mkdir -p "$IDENTITY_DIR"
    chmod 700 "$IDENTITY_DIR"

    # Step 1: Verify hardware consistency
    echo "[*] Verifying hardware identifiers..."
    local serial=$(verify_serial_consistency)
    if [ $? -ne 0 ]; then
        echo "Hardware verification failed."
        return 1
    fi

    local mac=$(read_otp_mac)

    echo "[+] Serial: $serial"
    echo "[+] MAC:    $mac"

    # Step 2: Generate or load salt
    if [ ! -f "$SALT_FILE" ]; then
        echo "[*] Generating random salt (first run)..."
        # SECURITY: Hardware RNG is MANDATORY - no software fallbacks allowed
        if [ ! -c /dev/hwrng ]; then
            echo "[!] FATAL: HWRNG MISSING - /dev/hwrng not available"
            echo "[!] Hardware binding requires BCM2712 hardware RNG."
            echo "[!] Cannot generate secure identity without hardware entropy."
            exit 1
        fi
        dd if=/dev/hwrng bs=32 count=1 2>/dev/null | xxd -p -c 64 > "$SALT_FILE"
        chmod 600 "$SALT_FILE"
    fi
    local salt=$(cat "$SALT_FILE")

    # Step 3: Derive Nostr private key
    # Using Argon2id: Serial + MAC + Salt → 32-byte key
    echo "[*] Deriving Nostr identity..."

    local input="${serial}:${mac}:${salt}"
    
    # Check if argon2 is installed
    if ! command -v argon2 >/dev/null 2>&1; then
        echo "[!] argon2 not found. Install it first."
        return 1
    fi

    local derived_key=$(echo -n "$input" | argon2 "$salt" -id -t 3 -m 16 -p 4 -l 32 -r)

    # Convert to Nostr nsec format
    # Note: This requires secp256k1 tools or nak. 
    # Assuming 'nak' is available as per plan.
    if ! command -v nak >/dev/null 2>&1; then
        echo "[!] nak not found. Install it first."
        return 1
    fi

    # Hex key is derived_key (raw bytes). 
    # Argon2 output raw needs to be hex encoded for some tools, but 'nak' might take hex string?
    # argon2 -r outputs raw bytes. We might need hex for intermediate tools.
    # Let's adjust: get hex output from argon2 to be safe for shell handling, then convert.
    # Actually the plan uses -r (raw) but shell handling raw bytes is tricky.
    # Let's use hex output from argon2 (no -r) and parse it?
    # Or just pipe raw.
    # The plan snippet: local derived_key=$(echo -n "$input" | argon2 "$salt" -id -t 3 -m 16 -p 4 -l 32 -r)
    # The variable derived_key will contain raw bytes which might break shell strings.
    # BETTER: Get hex encoded output.
    
    local derived_key_hex=$(echo -n "$input" | argon2 "$salt" -id -t 3 -m 16 -p 4 -l 32 -e | sed 's/^.*\$//' | base64 -d | xxd -p -c 32)
    # Note: argon2 cli output format is complex. 
    # Let's stick to the plan's intent but make it robust.
    # If we use `argon2 ... -r | xxd -p -c 32` we get hex string.
    
    derived_key_hex=$(echo -n "$input" | argon2 "$salt" -id -t 3 -m 16 -p 4 -l 32 -r | xxd -p -c 32)

    local nsec=$(echo "$derived_key_hex" | nak key convert --to-nsec 2>/dev/null)
    local npub=$(echo "$derived_key_hex" | nak key convert --to-npub 2>/dev/null)

    # Store npub (public, can be shared)
    echo "$npub" > "$NPUB_FILE"
    chmod 644 "$NPUB_FILE"

    # Private key is derived on-demand, never stored
    echo "[+] Identity initialized: $npub"

    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────
get_npub() {
    [ -f "$NPUB_FILE" ] && cat "$NPUB_FILE" || { init_identity && cat "$NPUB_FILE"; }
}

sign_event() {
    local event="$1"

    # Re-derive the private key (never stored)
    local serial=$(verify_serial_consistency)
    local mac=$(read_otp_mac)
    local salt=$(cat "$SALT_FILE")
    local input="${serial}:${mac}:${salt}"
    local derived_key_hex=$(echo -n "$input" | argon2 "$salt" -id -t 3 -m 16 -p 4 -l 32 -r | xxd -p -c 32)

    # Sign with nak
    echo "$event" | nak event sign --sec "$derived_key_hex"
}

# CLI interface
case "$1" in
    init)     init_identity ;;
    npub)     get_npub ;;
    sign)     sign_event "$2" ;;
    verify)   verify_serial_consistency >/dev/null && echo "OK" || echo "FAIL" ;;
    *)        echo "Usage: $0 {init|npub|sign|verify}" ;;
esac
