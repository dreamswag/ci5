#!/bin/sh
# 🧙‍♂️ Ci5 Setup Wizard (Step 1)
# "Infrastructure First"

CONFIG_FILE="ci5.config"
R7800_SCRIPT="r7800_auto.sh"
GENERIC_GUIDE="generic_ap_reference.txt"

# ANSI Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

clear
echo -e "${BLUE}==========================================${NC}"
echo -e "${BLUE}   🃏 Ci5 Infrastructure Setup (v7.4-RC1)${NC}"
echo -e "${BLUE}==========================================${NC}"
echo ""

# ========================================================
# 1. WAN / ISP CONFIGURATION
# ========================================================
echo -e "${YELLOW}[1] Internet Connection (ISP)${NC}"
echo "-----------------------------"
echo "Detected Interfaces:"
ip -br link | grep -E 'eth|enp|usb' | awk '{print "   - " $1}'
echo ""
echo "Which port connects to your Modem/ONT?"
read -p "   WAN Interface [eth1]: " WAN_IFACE
WAN_IFACE=${WAN_IFACE:-eth1}

echo ""
echo "How does your ISP authenticate?"
echo "   1) Plug-and-Play (DHCP) [Virgin/Starlink/Hyperoptic]"
echo "   2) Login Required (PPPoE) [Trooli/Openreach/BT]"
read -p "   Select [1]: " PROTO_CHOICE

if [ "$PROTO_CHOICE" = "2" ]; then
    WAN_PROTO="pppoe"
    read -p "   PPPoE Username: " PPPOE_USER
    read -p "   PPPoE Password: " PPPOE_PASS
else
    WAN_PROTO="dhcp"
fi

# ========================================================
# 2. WIRELESS IDENTITY
# ========================================================
echo ""
echo -e "${YELLOW}[2] Wireless Identity${NC}"
echo "-----------------------------"
echo "Define your network passwords now."
echo ""

# Trusted
read -p "   Trusted SSID [Ci5_Trusted]: " SSID_TRUSTED
SSID_TRUSTED=${SSID_TRUSTED:-Ci5_Trusted}
read -p "   Trusted Password: " KEY_TRUSTED
if [ -z "$KEY_TRUSTED" ]; then
    KEY_TRUSTED="Ci5_$(date +%s | tail -c 4)"
    echo "   -> Auto-generated Password: $KEY_TRUSTED"
fi

# IoT
echo ""
read -p "   IoT SSID [Ci5_IoT]: " SSID_IOT
SSID_IOT=${SSID_IOT:-Ci5_IoT}
read -p "   IoT Password [Same as Trusted]: " KEY_IOT
KEY_IOT=${KEY_IOT:-$KEY_TRUSTED}

# Guest
echo ""
read -p "   Guest SSID [Ci5_Guest]: " SSID_GUEST
SSID_GUEST=${SSID_GUEST:-Ci5_Guest}
read -p "   Guest Password [GuestAccess123]: " KEY_GUEST
KEY_GUEST=${KEY_GUEST:-GuestAccess123}

# Country
echo ""
read -p "   Wi-Fi Country Code (GB, US, DE) [GB]: " COUNTRY_CODE
COUNTRY_CODE=${COUNTRY_CODE:-GB}

# ========================================================
# 3. SYSTEM SECURITY
# ========================================================
echo ""
echo -e "${YELLOW}[3] Router Security${NC}"
echo "-----------------------------"
read -p "   Set Pi 5 Root Password: " ROUTER_PASS
if [ -z "$ROUTER_PASS" ]; then
    echo -e "${RED}   ! Password cannot be empty.${NC}"
    exit 1
fi

# ========================================================
# 4. ACCESS POINT GENERATOR
# ========================================================
echo ""
echo -e "${YELLOW}[4] Access Point Hardware${NC}"
echo "-----------------------------"
echo "Do you have a Netgear R7800 (Nighthawk X4S)?"
echo "   (If YES, we will generate an auto-flash script)"
read -p "   [y/N]: " IS_R7800

# ========================================================
# GENERATION PHASE
# ========================================================
echo ""
echo -e "${BLUE}[*] Generating Artifacts...${NC}"

# 1. SAVE CONFIG (For Installers)
cat <<EOF > "$CONFIG_FILE"
# Ci5 Configuration
# Generated: $(date)

WAN_IFACE='$WAN_IFACE'
WAN_PROTO='$WAN_PROTO'
PPPOE_USER='$PPPOE_USER'
PPPOE_PASS='$PPPOE_PASS'
ROUTER_PASS='$ROUTER_PASS'
COUNTRY_CODE='$COUNTRY_CODE'
EOF
echo -e "${GREEN}   ✓ Saved: $CONFIG_FILE${NC}"

# 2. GENERATE GENERIC GUIDE
cat <<EOF > "$GENERIC_GUIDE"
Ci5 Generic Access Point Guide
==============================
CRITICAL: You must configure your AP as a "Dumb Access Point" (Layer 2 Only).

1. DISABLE ROUTING SERVICES (MANDATORY):
   - DHCP Server:  OFF (Disable completely)
   - Firewall:     OFF (Disable SPI/NAT)
   - WAN Port:     DO NOT USE (Unless bridging WAN to LAN in software)
   - IP Mode:      Static IP (See below)

2. MANAGEMENT NETWORK:
   - IP Address: 192.168.99.2
   - Subnet:     255.255.255.0
   - Gateway:    192.168.99.1
   - DNS:        192.168.99.1

3. WIRELESS / VLAN MAPPING:
   (A) TRUSTED -> SSID: "$SSID_TRUSTED" / VLAN 10
   (B) IOT     -> SSID: "$SSID_IOT"     / VLAN 30 / Isolation: ON
   (C) GUEST   -> SSID: "$SSID_GUEST"   / VLAN 40 / Isolation: ON
EOF
echo -e "${GREEN}   ✓ Saved: $GENERIC_GUIDE${NC}"

# 3. GENERATE R7800 SCRIPT (With Port Isolation)
if [ "$IS_R7800" = "y" ] || [ "$IS_R7800" = "Y" ]; then
    cat <<EOF > "$R7800_SCRIPT"
#!/bin/sh
# Auto-Generated R7800 AP Script for Ci5
# ⚠️ WARNING: DESTRUCTIVE - WIPES CONFIGURATION ⚠️

echo "🔥 [1/3] Neutering Router Services (Dumb AP Mode)..."
/etc/init.d/firewall stop 2>/dev/null
/etc/init.d/firewall disable 2>/dev/null
/etc/init.d/odhcpd stop 2>/dev/null
/etc/init.d/odhcpd disable 2>/dev/null
/etc/init.d/dnsmasq stop 2>/dev/null
/etc/init.d/dnsmasq disable 2>/dev/null

echo "🌉 [2/3] Configuring DSA Bridge & VLANs..."
uci -q delete network.wan
uci -q delete network.wan6
uci -q delete network.lan

uci set network.br_lan=device
uci set network.br_lan.name='br-lan'
uci set network.br_lan.type='bridge'
uci set network.br_lan.ports='lan1 lan2 lan3 lan4 wan'
uci set network.br_lan.vlan_filtering='1'

# Management (VLAN 1 / Untagged)
uci set network.lan=interface
uci set network.lan.device='br-lan.1'
uci set network.lan.proto='static'
uci set network.lan.ipaddr='192.168.99.2'
uci set network.lan.netmask='255.255.255.0'
uci set network.lan.gateway='192.168.99.1'
uci set network.lan.dns='192.168.99.1'

# VLAN 10 (Trusted) Bridge Port
uci set network.vlan10=interface
uci set network.vlan10.device='br-lan.10'
uci set network.vlan10.proto='none'

# VLAN 30 (IoT) Bridge Port
uci set network.vlan30=interface
uci set network.vlan30.device='br-lan.30'
uci set network.vlan30.proto='none'

# VLAN 40 (Guest) Bridge Port
uci set network.vlan40=interface
uci set network.vlan40.device='br-lan.40'
uci set network.vlan40.proto='none'

# --- PORT ASSIGNMENTS ---
# LAN 1 (to Pi5): TRUNK (Tagged 10,30,40 + Untagged Mgmt)
uci set network.lan1=bridge-vlan
uci set network.lan1.device='br-lan'
uci set network.lan1.vlan='10 30 40'
uci set network.lan1.ports='lan1:t' 

# LAN 2 (PC): ACCESS VLAN 10 (Trusted)
uci set network.lan2=bridge-vlan
uci set network.lan2.device='br-lan'
uci set network.lan2.vlan='10'
uci set network.lan2.ports='lan2' 

# LAN 3 (Hue Bridge): ACCESS VLAN 30 (IoT)
uci set network.lan3=bridge-vlan
uci set network.lan3.device='br-lan'
uci set network.lan3.vlan='30'
uci set network.lan3.ports='lan3' 

# LAN 4 (Emergency): ACCESS VLAN 1 (Mgmt)
# (Default behavior, no extra config needed usually, but ensuring bridge membership)

# Wireless SSIDs
uci set wireless.trusted_5g=wifi-iface
uci set wireless.trusted_5g.device='radio0'
uci set wireless.trusted_5g.mode='ap'
uci set wireless.trusted_5g.ssid='$SSID_TRUSTED'
uci set wireless.trusted_5g.key='$KEY_TRUSTED'
uci set wireless.trusted_5g.network='vlan10'
uci set wireless.trusted_5g.encryption='sae-mixed'
uci set wireless.trusted_5g.country='$COUNTRY_CODE'

uci set wireless.iot_2g=wifi-iface
uci set wireless.iot_2g.device='radio1'
uci set wireless.iot_2g.mode='ap'
uci set wireless.iot_2g.ssid='$SSID_IOT'
uci set wireless.iot_2g.key='$KEY_IOT'
uci set wireless.iot_2g.network='vlan30'
uci set wireless.iot_2g.encryption='psk2'
uci set wireless.iot_2g.isolate='1'
uci set wireless.iot_2g.country='$COUNTRY_CODE'

uci set wireless.guest_5g=wifi-iface
uci set wireless.guest_5g.device='radio0'
uci set wireless.guest_5g.mode='ap'
uci set wireless.guest_5g.ssid='$SSID_GUEST'
uci set wireless.guest_5g.key='$KEY_GUEST'
uci set wireless.guest_5g.network='vlan40'
uci set wireless.guest_5g.encryption='psk2'
uci set wireless.guest_5g.isolate='1'

uci commit
echo "✅ [3/3] Configuration Applied. Rebooting..."
reboot
EOF
    chmod +x "$R7800_SCRIPT"
    echo -e "${GREEN}   ✓ Generated: $R7800_SCRIPT${NC}"
fi

echo ""
echo "=========================================="
echo "   🚀 READY"
echo "=========================================="
echo "1. Run 'sh install-lite.sh' (Auto-tunes speed at the end)"
