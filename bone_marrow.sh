#!/bin/sh
# 🦴 Bone Marrow Diagnostic Dump (v7.4-RC-1)
# Generates comprehensive system report for troubleshooting
# Usage: sh bone_marrow.sh [output_file]

HOSTNAME=$(cat /proc/sys/kernel/hostname)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT="${1:-${HOSTNAME}_bone_marrow_${TIMESTAMP}.md}"

[ -f "/root/ci5/ci5.config" ] && . /root/ci5/ci5.config

echo "🦴 Generating Bone Marrow Report: $OUTPUT"
echo "   This may take 30-60 seconds..."

cat > "$OUTPUT" << HEADER
# 🦴 Bone Marrow Report: $HOSTNAME
**Date:** $(date)
**Uptime:** $(uptime)

HEADER

echo '## CPU & Architecture' >> "$OUTPUT"
echo '```' >> "$OUTPUT"
grep -E "^(model name|Hardware|Revision|Serial)" /proc/cpuinfo >> "$OUTPUT" 2>/dev/null
uname -a >> "$OUTPUT"
echo '```' >> "$OUTPUT"
echo "" >> "$OUTPUT"

echo '## Kernel Modules (Loaded)' >> "$OUTPUT"
echo '```' >> "$OUTPUT"
lsmod >> "$OUTPUT"
echo '```' >> "$OUTPUT"
echo "" >> "$OUTPUT"

echo '## Kernel Parameters (Sysctl - Full Dump)' >> "$OUTPUT"
echo '```' >> "$OUTPUT"
sysctl -a 2>/dev/null >> "$OUTPUT"
echo '```' >> "$OUTPUT"
echo "" >> "$OUTPUT"

echo '## Network Interfaces' >> "$OUTPUT"
echo '```' >> "$OUTPUT"
ip -br addr >> "$OUTPUT"
echo "" >> "$OUTPUT"
ip route >> "$OUTPUT"
echo "" >> "$OUTPUT"
ip -6 route 2>/dev/null >> "$OUTPUT"
echo '```' >> "$OUTPUT"
echo "" >> "$OUTPUT"

echo '## SQM (CAKE) Status' >> "$OUTPUT"
echo '```' >> "$OUTPUT"
if [ -n "$WAN_VLAN" ] && [ "$WAN_VLAN" -ne 0 ]; then
    WAN_TARGET="${WAN_IFACE}.${WAN_VLAN}"
else
    WAN_TARGET="${WAN_IFACE:-eth1}"
fi
tc -s qdisc show dev "$WAN_TARGET" 2>/dev/null >> "$OUTPUT" || echo "No qdisc on $WAN_TARGET" >> "$OUTPUT"
echo "" >> "$OUTPUT"
IFB_DEV="ifb4${WAN_TARGET}"
if ip link show "$IFB_DEV" >/dev/null 2>&1; then
    echo "=== Ingress ($IFB_DEV) ===" >> "$OUTPUT"
    tc -s qdisc show dev "$IFB_DEV" 2>/dev/null >> "$OUTPUT"
fi
echo '```' >> "$OUTPUT"
echo "" >> "$OUTPUT"

echo '## Ethtool (Offload & Ring Settings)' >> "$OUTPUT"
echo '```' >> "$OUTPUT"
for iface in eth0 ${WAN_IFACE:-eth1}; do
    if ip link show "$iface" >/dev/null 2>&1; then
        echo "=== $iface ===" >> "$OUTPUT"
        ethtool -k "$iface" 2>/dev/null | grep -E "(offload|segmentation|scatter)" >> "$OUTPUT"
        ethtool -g "$iface" 2>/dev/null >> "$OUTPUT"
        echo "" >> "$OUTPUT"
    fi
done
echo '```' >> "$OUTPUT"
echo "" >> "$OUTPUT"

echo '## UCI Network Config' >> "$OUTPUT"
echo '```' >> "$OUTPUT"
uci show network 2>/dev/null >> "$OUTPUT"
echo '```' >> "$OUTPUT"
echo "" >> "$OUTPUT"

echo '## UCI Firewall Config' >> "$OUTPUT"
echo '```' >> "$OUTPUT"
uci show firewall 2>/dev/null >> "$OUTPUT"
echo '```' >> "$OUTPUT"
echo "" >> "$OUTPUT"

echo '## UCI SQM Config' >> "$OUTPUT"
echo '```' >> "$OUTPUT"
uci show sqm 2>/dev/null >> "$OUTPUT"
echo '```' >> "$OUTPUT"
echo "" >> "$OUTPUT"

if command -v docker >/dev/null 2>&1; then
    echo '## Docker Status' >> "$OUTPUT"
    echo '```' >> "$OUTPUT"
    docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" >> "$OUTPUT" 2>/dev/null
    echo "" >> "$OUTPUT"
    echo "=== Resource Usage ===" >> "$OUTPUT"
    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" >> "$OUTPUT" 2>/dev/null
    echo '```' >> "$OUTPUT"
    echo "" >> "$OUTPUT"
    
    echo '## Docker Logs (Last 50 Lines Each)' >> "$OUTPUT"
    for container in suricata crowdsec adguardhome ntopng; do
        if docker ps -a --format '{{.Names}}' | grep -q "$container"; then
            echo "### $container" >> "$OUTPUT"
            echo '```' >> "$OUTPUT"
            docker logs --tail 50 "$container" 2>&1 >> "$OUTPUT"
            echo '```' >> "$OUTPUT"
            echo "" >> "$OUTPUT"
        fi
    done
fi

echo '## DNS Status' >> "$OUTPUT"
echo '```' >> "$OUTPUT"
echo "=== Listening Ports ===" >> "$OUTPUT"
netstat -tlnp 2>/dev/null | grep -E ':(53|5335|3000) ' >> "$OUTPUT"
echo "" >> "$OUTPUT"
echo "=== Unbound Status ===" >> "$OUTPUT"
pgrep -a unbound >> "$OUTPUT" 2>/dev/null || echo "Not running" >> "$OUTPUT"
echo "" >> "$OUTPUT"
echo "=== DNS Resolution Test ===" >> "$OUTPUT"
nslookup google.com 127.0.0.1 2>&1 | head -10 >> "$OUTPUT"
echo '```' >> "$OUTPUT"
echo "" >> "$OUTPUT"

echo '## Connection Tracking' >> "$OUTPUT"
echo '```' >> "$OUTPUT"
echo "Total Connections: $(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 'N/A')" >> "$OUTPUT"
echo "Max Connections: $(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 'N/A')" >> "$OUTPUT"
echo "" >> "$OUTPUT"
echo "=== Top 10 Sources ===" >> "$OUTPUT"
cat /proc/net/nf_conntrack 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i~/^src=/) print $i}' | sort | uniq -c | sort -rn | head -10 >> "$OUTPUT"
echo '```' >> "$OUTPUT"
echo "" >> "$OUTPUT"

echo '## System Resources' >> "$OUTPUT"
echo '```' >> "$OUTPUT"
free -h >> "$OUTPUT"
echo "" >> "$OUTPUT"
cat /proc/loadavg >> "$OUTPUT"
echo "" >> "$OUTPUT"
echo "CPU Temp: $(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null | awk '{printf "%.1f°C", $1/1000}')" >> "$OUTPUT"
echo '```' >> "$OUTPUT"
echo "" >> "$OUTPUT"

if [ -f "/root/ci5/ci5.config" ]; then
    echo '## Ci5 Config (Passwords Redacted)' >> "$OUTPUT"
    echo '```' >> "$OUTPUT"
    sed 's/PASS=.*/PASS=\[REDACTED\]/g; s/password=.*/password=\[REDACTED\]/g' /root/ci5/ci5.config >> "$OUTPUT"
    echo '```' >> "$OUTPUT"
    echo "" >> "$OUTPUT"
fi

echo '## System Log (Last 200 Lines)' >> "$OUTPUT"
echo '```' >> "$OUTPUT"
logread | tail -200 >> "$OUTPUT"
echo '```' >> "$OUTPUT"
echo "" >> "$OUTPUT"

echo '## Kernel Log (Last 100)' >> "$OUTPUT"
echo '```' >> "$OUTPUT"
dmesg | tail -100 >> "$OUTPUT"
echo '```' >> "$OUTPUT"
echo "" >> "$OUTPUT"

echo ""
echo "✅ Bone Marrow Report Generated: $OUTPUT"
echo "   Size: $(du -h "$OUTPUT" | awk '{print $1}')"
echo ""
echo "📤 To share for troubleshooting:"
echo "   scp root@192.168.99.1:$OUTPUT ."
