#!/bin/sh
# 🧙‍♂️ Ci5 Setup Wizard (v7.4-RC-1)
CONFIG_FILE="ci5.config"
R7800_SCRIPT="r7800_auto.sh"
GENERIC_GUIDE="generic_ap_reference.txt"

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

clear
echo -e "${BLUE}==========================================${NC}"
echo -e "${BLUE}   🃏 Ci5 Infrastructure Setup (v7.4-RC-1)${NC}"
echo -e "${BLUE}==========================================${NC}"
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
read -p "   WAN Interface [${DETECTED_WAN:-eth1}]: " WAN_IFACE
WAN_IFACE=${WAN_IFACE:-${DETECTED_WAN:-eth1}}

if ! ip link show "$WAN_IFACE" >/dev/null 2>&1; then
    echo -e "${RED}   ! Error: Interface $WAN_IFACE does not exist.${NC}"
    exit 1
fi

echo ""
echo "Does your ISP require a VLAN ID? (e.g. BT=101, Others=911)"
read -p "   VLAN ID (Leave empty for None): " WAN_VLAN
WAN_VLAN=${WAN_VLAN:-0}

echo ""
echo "   1) Plug-and-Play (DHCP) [Virgin/Starlink/Hyperoptic]"
echo "   2) Login Required (PPPoE) [Trooli/Openreach/BT]"
read -p "   Select Protocol [1]: " PROTO_CHOICE

if [ "$PROTO_CHOICE" = "2" ]; then
    WAN_PROTO="pppoe"
    read -p "   PPPoE Username: " PPPOE_USER
    read -p "   PPPoE Password: " PPPOE_PASS
else
    WAN_PROTO="dhcp"
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
read -p "   Trusted SSID [Ci5_Trusted]: " SSID_TRUSTED
SSID_TRUSTED=${SSID_TRUSTED:-Ci5_Trusted}
read -p "   Trusted Password: " KEY_TRUSTED
if [ -z "$KEY_TRUSTED" ]; then
    KEY_TRUSTED="Ci5_$(date +%s | tail -c 4)"
    echo "   -> Auto-generated: $KEY_TRUSTED"
fi
read -p "   IoT SSID [Ci5_IoT]: " SSID_IOT
SSID_IOT=${SSID_IOT:-Ci5_IoT}
read -p "   IoT Password [Same as Trusted]: " KEY_IOT
KEY_IOT=${KEY_IOT:-$KEY_TRUSTED}
read -p "   Guest SSID [Ci5_Guest]: " SSID_GUEST
SSID_GUEST=${SSID_GUEST:-Ci5_Guest}
read -p "   Guest Password [GuestAccess123]: " KEY_GUEST
KEY_GUEST=${KEY_GUEST:-GuestAccess123}
read -p "   Wi-Fi Country Code [GB]: " COUNTRY_CODE
COUNTRY_CODE=${COUNTRY_CODE:-GB}
read -p "   Set Pi 5 Root Password: " ROUTER_PASS
[ -z "$ROUTER_PASS" ] && exit 1
read -p "   Do you have a Netgear R7800? [y/N]: " IS_R7800

# Generation
cat <<CONF > "$CONFIG_FILE"
WAN_IFACE='$WAN_IFACE'
WAN_VLAN='$WAN_VLAN'
WAN_PROTO='$WAN_PROTO'
PPPOE_USER='$PPPOE_USER'
PPPOE_PASS='$PPPOE_PASS'
LINK_TYPE='$LINK_TYPE'
ROUTER_PASS='$ROUTER_PASS'
COUNTRY_CODE='$COUNTRY_CODE'
CONF
echo -e "${GREEN}   ✓ Saved: $CONFIG_FILE${NC}"

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
    cp "$R7800_SCRIPT" /www/r7800.sh
    chmod +r /www/r7800.sh
    echo -e "${GREEN}   ✓ Hosted at http://192.168.99.1/r7800.sh${NC}"
fi
echo -e "${GREEN}   🚀 READY${NC}"
