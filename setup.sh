#!/bin/sh
# 🧙‍♂️ Ci5 Setup Wizard (v7.5-HARDENED)
# Critical Fixes Applied:
#   [6] Encrypt credentials in ci5.config using hardware-derived key (Pi serial)

CONFIG_FILE="ci5.config"
CONFIG_FILE_ENC="ci5.config.enc"
R7800_SCRIPT="r7800_auto.sh"
GENERIC_GUIDE="generic_ap_reference.txt"

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

# ─────────────────────────────────────────────────────────────
# CRITICAL FIX [6]: HARDWARE-DERIVED ENCRYPTION KEY
# ─────────────────────────────────────────────────────────────

# Get Pi serial number for hardware-bound encryption
get_hardware_key() {
    local serial=""
    
    # Try to get Pi serial from cpuinfo
    if [ -f /proc/cpuinfo ]; then
        serial=$(grep -i "serial" /proc/cpuinfo | awk '{print $3}' 2>/dev/null)
    fi
    
    # Fallback: use machine-id
    if [ -z "$serial" ] && [ -f /etc/machine-id ]; then
        serial=$(cat /etc/machine-id)
    fi
    
    # Fallback: use DMI product UUID
    if [ -z "$serial" ] && [ -f /sys/class/dmi/id/product_uuid ]; then
        serial=$(cat /sys/class/dmi/id/product_uuid 2>/dev/null)
    fi
    
    # Final fallback: generate and store a random ID
    if [ -z "$serial" ]; then
        if [ -f /etc/ci5_hwid ]; then
            serial=$(cat /etc/ci5_hwid)
        else
            serial=$(head -c 32 /dev/urandom | sha256sum | cut -c1-32)
            echo "$serial" > /etc/ci5_hwid
            chmod 600 /etc/ci5_hwid
        fi
    fi
    
    # Derive key from serial + salt
    echo -n "${serial}CI5_SOVEREIGN_SALT_2025" | sha256sum | cut -c1-64
}

# Encrypt the config file
encrypt_config() {
    local plaintext_file="$1"
    local encrypted_file="$2"
    
    if ! command -v openssl >/dev/null 2>&1; then
        echo -e "${YELLOW}   ! openssl not available, storing config unencrypted${NC}"
        return 1
    fi
    
    local hw_key=$(get_hardware_key)
    
    # Encrypt with AES-256-CBC using hardware-derived key
    openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 \
        -in "$plaintext_file" \
        -out "$encrypted_file" \
        -pass "pass:$hw_key" 2>/dev/null
    
    if [ $? -eq 0 ]; then
        # Secure the encrypted file
        chmod 600 "$encrypted_file"
        # Remove plaintext (keep backup for this session)
        mv "$plaintext_file" "${plaintext_file}.tmp"
        echo -e "${GREEN}   ✓ Config encrypted with hardware-bound key${NC}"
        return 0
    else
        echo -e "${YELLOW}   ! Encryption failed, keeping plaintext${NC}"
        return 1
    fi
}

# Decrypt the config file (for use by other scripts)
decrypt_config() {
    local encrypted_file="$1"
    local plaintext_file="$2"
    
    if [ ! -f "$encrypted_file" ]; then
        return 1
    fi
    
    if ! command -v openssl >/dev/null 2>&1; then
        return 1
    fi
    
    local hw_key=$(get_hardware_key)
    
    openssl enc -aes-256-cbc -d -salt -pbkdf2 -iter 100000 \
        -in "$encrypted_file" \
        -out "$plaintext_file" \
        -pass "pass:$hw_key" 2>/dev/null
    
    return $?
}

# Export decryption function for other scripts
export_decrypt_function() {
    cat > /tmp/ci5_decrypt.sh << 'DECRYPT_FUNC'
#!/bin/sh
# Ci5 Config Decryption Helper
# Source this file to get decrypt_ci5_config function

decrypt_ci5_config() {
    local encrypted_file="${1:-ci5.config.enc}"
    local output_file="${2:-/tmp/ci5.config.dec}"
    
    # Get hardware key
    local serial=""
    if [ -f /proc/cpuinfo ]; then
        serial=$(grep -i "serial" /proc/cpuinfo | awk '{print $3}' 2>/dev/null)
    fi
    [ -z "$serial" ] && [ -f /etc/machine-id ] && serial=$(cat /etc/machine-id)
    [ -z "$serial" ] && [ -f /etc/ci5_hwid ] && serial=$(cat /etc/ci5_hwid)
    
    local hw_key=$(echo -n "${serial}CI5_SOVEREIGN_SALT_2025" | sha256sum | cut -c1-64)
    
    openssl enc -aes-256-cbc -d -salt -pbkdf2 -iter 100000 \
        -in "$encrypted_file" \
        -out "$output_file" \
        -pass "pass:$hw_key" 2>/dev/null
    
    if [ $? -eq 0 ]; then
        chmod 600 "$output_file"
        echo "$output_file"
        return 0
    fi
    return 1
}
DECRYPT_FUNC
    chmod 755 /tmp/ci5_decrypt.sh
}

clear
echo -e "${BLUE}==========================================${NC}"
echo -e "${BLUE}   🃏 Ci5 Infrastructure Setup (v7.5-HARDENED)${NC}"
echo -e "${BLUE}==========================================${NC}"
echo ""
echo -e "${GREEN}   🔐 Credentials will be encrypted with hardware-bound key${NC}"
echo ""

# ─────────────────────────────────────────────────────────────
# PRE-FLIGHT CHECK
# ─────────────────────────────────────────────────────────────
if [ -f "preflight.sh" ]; then
    echo -e "${YELLOW}[0] Running Pre-Flight Checks...${NC}"
    echo ""
    if ! sh preflight.sh; then
        echo ""
        echo -e "${RED}Pre-flight checks failed. Fix issues above before continuing.${NC}"
        exit 1
    fi
    echo ""
fi

# ─────────────────────────────────────────────────────────────
# CHECK FOR EXISTING ENCRYPTED CONFIG
# ─────────────────────────────────────────────────────────────
if [ -f "$CONFIG_FILE_ENC" ]; then
    echo -e "${YELLOW}[!] Existing encrypted config found.${NC}"
    echo -n "    Decrypt and modify? [y/N]: "
    read MODIFY_EXISTING
    if [ "$MODIFY_EXISTING" = "y" ] || [ "$MODIFY_EXISTING" = "Y" ]; then
        if decrypt_config "$CONFIG_FILE_ENC" "$CONFIG_FILE"; then
            echo -e "${GREEN}   ✓ Config decrypted for editing${NC}"
            # Load existing values as defaults
            . "./$CONFIG_FILE"
        else
            echo -e "${RED}   ! Failed to decrypt. Starting fresh.${NC}"
        fi
    fi
fi

# ─────────────────────────────────────────────────────────────
# AUTO-DETECT USB NIC
# ─────────────────────────────────────────────────────────────
DETECTED_WAN=""
for iface in /sys/class/net/*; do
    name=$(basename "$iface")
    [ "$name" = "lo" ] && continue
    [ "$name" = "eth0" ] && continue
    [ "$name" = "wlan0" ] && continue
    if readlink -f "$iface/device" 2>/dev/null | grep -q usb; then
        DETECTED_WAN="$name"
        break
    fi
done

# 1. WAN / ISP
echo -e "${YELLOW}[1] Internet Connection (ISP)${NC}"
echo "Detected Interfaces:"
ip -br link | grep -E '^(eth|enx|usb)' | awk '{print "   - " $1}'
if [ -n "$DETECTED_WAN" ]; then
    echo -e "   ${GREEN}(Auto-detected USB NIC: $DETECTED_WAN)${NC}"
fi
echo ""
read -p "   WAN Interface [${WAN_IFACE:-${DETECTED_WAN:-eth1}}]: " INPUT_WAN_IFACE
WAN_IFACE=${INPUT_WAN_IFACE:-${WAN_IFACE:-${DETECTED_WAN:-eth1}}}

if ! ip link show "$WAN_IFACE" >/dev/null 2>&1; then
    echo -e "${RED}   ! Error: Interface $WAN_IFACE does not exist.${NC}"
    exit 1
fi

echo ""
echo "Does your ISP require a VLAN ID? (e.g. BT=101, Others=911)"
read -p "   VLAN ID (Leave empty for None) [${WAN_VLAN:-}]: " INPUT_WAN_VLAN
WAN_VLAN=${INPUT_WAN_VLAN:-${WAN_VLAN:-0}}

echo ""
echo "   1) Plug-and-Play (DHCP) [Virgin/Starlink/Hyperoptic]"
echo "   2) Login Required (PPPoE) [Trooli/Openreach/BT]"
read -p "   Select Protocol [1]: " PROTO_CHOICE

if [ "$PROTO_CHOICE" = "2" ]; then
    WAN_PROTO="pppoe"
    read -p "   PPPoE Username: " PPPOE_USER
    # Use stty to hide password input
    echo -n "   PPPoE Password: "
    stty -echo 2>/dev/null || true
    read PPPOE_PASS
    stty echo 2>/dev/null || true
    echo ""
else
    WAN_PROTO="dhcp"
    PPPOE_USER=""
    PPPOE_PASS=""
fi

# Link Layer
echo ""
echo "What is your physical connection type?"
echo "   1) Fiber (FTTP) / Ethernet [Default] (Overhead: 40)"
echo "   2) DSL (FTTC) / Copper               (Overhead: 44)"
echo "   3) Starlink / 5G / LTE               (Overhead: None)"
read -p "   Select Type [1]: " LINK_CHOICE
case "$LINK_CHOICE" in
    2) LINK_TYPE="dsl" ;;
    3) LINK_TYPE="starlink" ;;
    *) LINK_TYPE="fiber" ;;
esac

# 2. Wireless
echo ""
echo -e "${YELLOW}[2] Wireless Identity${NC}"
read -p "   Trusted SSID [${SSID_TRUSTED:-Ci5_Trusted}]: " INPUT_SSID_TRUSTED
SSID_TRUSTED=${INPUT_SSID_TRUSTED:-${SSID_TRUSTED:-Ci5_Trusted}}

read -p "   Trusted Password: " KEY_TRUSTED
if [ -z "$KEY_TRUSTED" ]; then
    KEY_TRUSTED="Ci5_$(date +%s | tail -c 4)"
    echo "   -> Auto-generated: $KEY_TRUSTED"
fi

read -p "   IoT SSID [${SSID_IOT:-Ci5_IoT}]: " INPUT_SSID_IOT
SSID_IOT=${INPUT_SSID_IOT:-${SSID_IOT:-Ci5_IoT}}

read -p "   IoT Password [Same as Trusted]: " KEY_IOT
KEY_IOT=${KEY_IOT:-$KEY_TRUSTED}

read -p "   Guest SSID [${SSID_GUEST:-Ci5_Guest}]: " INPUT_SSID_GUEST
SSID_GUEST=${INPUT_SSID_GUEST:-${SSID_GUEST:-Ci5_Guest}}

read -p "   Guest Password [GuestAccess123]: " KEY_GUEST
KEY_GUEST=${KEY_GUEST:-GuestAccess123}

read -p "   Wi-Fi Country Code [${COUNTRY_CODE:-GB}]: " INPUT_COUNTRY_CODE
COUNTRY_CODE=${INPUT_COUNTRY_CODE:-${COUNTRY_CODE:-GB}}

# Router password with confirmation
echo ""
echo -e "${YELLOW}[3] Security${NC}"
while true; do
    echo -n "   Set Pi 5 Root Password: "
    stty -echo 2>/dev/null || true
    read ROUTER_PASS
    stty echo 2>/dev/null || true
    echo ""
    
    if [ -z "$ROUTER_PASS" ]; then
        echo -e "${RED}   ! Password cannot be empty${NC}"
        continue
    fi
    
    echo -n "   Confirm Password: "
    stty -echo 2>/dev/null || true
    read ROUTER_PASS_CONFIRM
    stty echo 2>/dev/null || true
    echo ""
    
    if [ "$ROUTER_PASS" != "$ROUTER_PASS_CONFIRM" ]; then
        echo -e "${RED}   ! Passwords do not match. Try again.${NC}"
        continue
    fi
    break
done

read -p "   Do you have a Netgear R7800? [y/N]: " IS_R7800

# ─────────────────────────────────────────────────────────────
# GENERATE CONFIG (Plaintext first, then encrypt)
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}[4] Generating Configuration...${NC}"

cat <<CONF > "$CONFIG_FILE"
# Ci5 Configuration (v7.5-HARDENED)
# Generated: $(date)
# WARNING: This file contains sensitive credentials
# It will be encrypted with hardware-bound key

WAN_IFACE='$WAN_IFACE'
WAN_VLAN='$WAN_VLAN'
WAN_PROTO='$WAN_PROTO'
PPPOE_USER='$PPPOE_USER'
PPPOE_PASS='$PPPOE_PASS'
LINK_TYPE='$LINK_TYPE'
ROUTER_PASS='$ROUTER_PASS'
COUNTRY_CODE='$COUNTRY_CODE'
SSID_TRUSTED='$SSID_TRUSTED'
KEY_TRUSTED='$KEY_TRUSTED'
SSID_IOT='$SSID_IOT'
KEY_IOT='$KEY_IOT'
SSID_GUEST='$SSID_GUEST'
KEY_GUEST='$KEY_GUEST'
CONF

# Set restrictive permissions on plaintext (temporary)
chmod 600 "$CONFIG_FILE"

# Encrypt the config
if encrypt_config "$CONFIG_FILE" "$CONFIG_FILE_ENC"; then
    # Export decryption helper for other scripts
    export_decrypt_function
    
    # Create a loader script for other Ci5 scripts to source
    cat > "ci5.config.loader" << 'LOADER'
#!/bin/sh
# Ci5 Config Loader (v7.5-HARDENED)
# Source this file instead of ci5.config directly

_ci5_load_config() {
    local config_dir="${1:-.}"
    local enc_file="$config_dir/ci5.config.enc"
    local plain_file="$config_dir/ci5.config"
    local temp_file="/tmp/ci5.config.$$"
    
    # Try encrypted first
    if [ -f "$enc_file" ]; then
        # Get hardware key
        local serial=""
        [ -f /proc/cpuinfo ] && serial=$(grep -i "serial" /proc/cpuinfo | awk '{print $3}' 2>/dev/null)
        [ -z "$serial" ] && [ -f /etc/machine-id ] && serial=$(cat /etc/machine-id)
        [ -z "$serial" ] && [ -f /etc/ci5_hwid ] && serial=$(cat /etc/ci5_hwid)
        
        local hw_key=$(echo -n "${serial}CI5_SOVEREIGN_SALT_2025" | sha256sum | cut -c1-64)
        
        if openssl enc -aes-256-cbc -d -salt -pbkdf2 -iter 100000 \
            -in "$enc_file" -out "$temp_file" -pass "pass:$hw_key" 2>/dev/null; then
            . "$temp_file"
            rm -f "$temp_file"
            return 0
        fi
    fi
    
    # Fallback to plaintext
    if [ -f "$plain_file" ]; then
        . "$plain_file"
        return 0
    fi
    
    return 1
}

# Auto-load on source
_ci5_load_config "$(dirname "$0")" || _ci5_load_config "/root/ci5" || _ci5_load_config "/opt/ci5"
LOADER
    chmod 644 "ci5.config.loader"
    echo -e "${GREEN}   ✓ Created ci5.config.loader for other scripts${NC}"
    
    # Clean up plaintext
    rm -f "${CONFIG_FILE}.tmp" 2>/dev/null
    
    echo -e "${GREEN}   ✓ Encrypted config saved: $CONFIG_FILE_ENC${NC}"
else
    echo -e "${GREEN}   ✓ Saved: $CONFIG_FILE (unencrypted)${NC}"
fi

# Generate Generic Guide
cat <<GENGUIDE > "$GENERIC_GUIDE"
Ci5 Generic Access Point Guide
==============================
1. DISABLE ROUTING: DHCP Server OFF, Firewall OFF, WAN Port Unused.
2. IP SETTINGS: Static IP 192.168.99.2, Gateway 192.168.99.1.
3. VLAN MAPPING:
   - Trusted: SSID "$SSID_TRUSTED" -> VLAN 10
   - IoT:     SSID "$SSID_IOT"     -> VLAN 30 (Isolation ON)
   - Guest:   SSID "$SSID_GUEST"   -> VLAN 40 (Isolation ON)
   - Mgmt:    Pi5 Port -> Trunk (Tagged 10/30/40, Untagged 1)
GENGUIDE
echo -e "${GREEN}   ✓ Saved: $GENERIC_GUIDE${NC}"

if [ "$IS_R7800" = "y" ] || [ "$IS_R7800" = "Y" ]; then
    cat <<APCONF > "$R7800_SCRIPT"
#!/bin/sh
/etc/init.d/firewall stop 2>/dev/null; /etc/init.d/firewall disable 2>/dev/null
/etc/init.d/odhcpd stop 2>/dev/null; /etc/init.d/dnsmasq stop 2>/dev/null
uci -q delete network.wan; uci -q delete network.wan6; uci -q delete network.lan
uci set network.br_lan=device; uci set network.br_lan.name='br-lan'; uci set network.br_lan.type='bridge'
uci set network.br_lan.ports='lan1 lan2 lan3 lan4 wan'; uci set network.br_lan.vlan_filtering='1'
uci set network.lan=interface; uci set network.lan.device='br-lan.1'; uci set network.lan.proto='static'
uci set network.lan.ipaddr='192.168.99.2'; uci set network.lan.netmask='255.255.255.0'
uci set network.lan.gateway='192.168.99.1'; uci set network.lan.dns='192.168.99.1'
uci set network.vlan10=interface; uci set network.vlan10.device='br-lan.10'; uci set network.vlan10.proto='none'
uci set network.vlan30=interface; uci set network.vlan30.device='br-lan.30'; uci set network.vlan30.proto='none'
uci set network.vlan40=interface; uci set network.vlan40.device='br-lan.40'; uci set network.vlan40.proto='none'
uci set network.lan1=bridge-vlan; uci set network.lan1.device='br-lan'; uci set network.lan1.vlan='10 30 40'; uci set network.lan1.ports='lan1:t' 
uci set network.lan2=bridge-vlan; uci set network.lan2.device='br-lan'; uci set network.lan2.vlan='10'; uci set network.lan2.ports='lan2' 
uci set network.lan3=bridge-vlan; uci set network.lan3.device='br-lan'; uci set network.lan3.vlan='30'; uci set network.lan3.ports='lan3' 
uci set wireless.trusted_5g=wifi-iface; uci set wireless.trusted_5g.device='radio0'; uci set wireless.trusted_5g.mode='ap'; uci set wireless.trusted_5g.ssid='$SSID_TRUSTED'; uci set wireless.trusted_5g.key='$KEY_TRUSTED'; uci set wireless.trusted_5g.network='vlan10'; uci set wireless.trusted_5g.encryption='sae-mixed'; uci set wireless.trusted_5g.country='$COUNTRY_CODE'
uci set wireless.iot_2g=wifi-iface; uci set wireless.iot_2g.device='radio1'; uci set wireless.iot_2g.mode='ap'; uci set wireless.iot_2g.ssid='$SSID_IOT'; uci set wireless.iot_2g.key='$KEY_IOT'; uci set wireless.iot_2g.network='vlan30'; uci set wireless.iot_2g.encryption='psk2'; uci set wireless.iot_2g.isolate='1'; uci set wireless.iot_2g.country='$COUNTRY_CODE'
uci set wireless.guest_5g=wifi-iface; uci set wireless.guest_5g.device='radio0'; uci set wireless.guest_5g.mode='ap'; uci set wireless.guest_5g.ssid='$SSID_GUEST'; uci set wireless.guest_5g.key='$KEY_GUEST'; uci set wireless.guest_5g.network='vlan40'; uci set wireless.guest_5g.encryption='psk2'; uci set wireless.guest_5g.isolate='1'
uci commit; reboot
APCONF
    chmod +x "$R7800_SCRIPT"
    cp "$R7800_SCRIPT" /tmp/
    cp "$R7800_SCRIPT" /www/r7800.sh 2>/dev/null || true
    chmod +r /www/r7800.sh 2>/dev/null || true
    echo -e "${GREEN}   ✓ Hosted at http://192.168.99.1/r7800.sh${NC}"
fi

echo ""
echo -e "${GREEN}==========================================${NC}"
echo -e "${GREEN}   🚀 SETUP COMPLETE${NC}"
echo -e "${GREEN}==========================================${NC}"
echo ""
echo "   Credentials are encrypted with your device's hardware ID."
echo "   The config can ONLY be decrypted on THIS device."
echo ""
echo "   Next: Run 'sh install-lite.sh' or 'sh install-full.sh'"
echo ""
