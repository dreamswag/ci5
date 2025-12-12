#!/bin/sh
# ==============================================================================
# 🕵️‍♂️ Ci5 FORENSIC AUDITOR (Bone Marrow Edition)
# ==============================================================================
# This script extracts a complete state definition of an OpenWrt device.
# It captures UCI, Kernel, Network, Firewall, and Package states.
# USE THIS to verify your "Golden Image" matches your repo.
# ==============================================================================

HOSTNAME=$(uci get system.@system[0].hostname)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUT_FILE="/tmp/${HOSTNAME}_bone_marrow_${TIMESTAMP}.md"

log() {
    echo "[$1] ..."
    echo "## $1" >> "$OUT_FILE"
    echo '```' >> "$OUT_FILE"
}

end_log() {
    echo '```' >> "$OUT_FILE"
    echo "" >> "$OUT_FILE"
}

echo "# 🦴 Bone Marrow Report: $HOSTNAME" > "$OUT_FILE"
echo "**Date:** $(date)" >> "$OUT_FILE"
echo "**Uptime:** $(uptime)" >> "$OUT_FILE"
echo "" >> "$OUT_FILE"

# ------------------------------------------------------------------------------
# 1. HARDWARE & KERNEL (The Metal)
# ------------------------------------------------------------------------------
echo "--- 1. Hardware & Kernel ---"
log "CPU & Architecture"
cat /proc/cpuinfo | grep -E "model name|Hardware|Revision|Serial" >> "$OUT_FILE"
uname -a >> "$OUT_FILE"
end_log

log "Kernel Modules (Loaded)"
lsmod | sort >> "$OUT_FILE"
end_log

log "Kernel Parameters (Sysctl - Full Dump)"
# Critical for verifying BBR/TCP tuning
sysctl -a 2>/dev/null | sort >> "$OUT_FILE"
end_log

log "Disk & Mounts"
df -h >> "$OUT_FILE"
mount >> "$OUT_FILE"
end_log

# ------------------------------------------------------------------------------
# 2. OPENWRT CORE (The Brain)
# ------------------------------------------------------------------------------
echo "--- 2. OpenWrt Configuration ---"
log "Installed Packages (The Manifest)"
# This creates your 'install-lite.sh' package list
opkg list-installed | sort >> "$OUT_FILE"
end_log

log "UCI Configuration (Active Config)"
# This is the single most important dump for networking/firewall
uci show >> "$OUT_FILE"
end_log

log "Changed Config Files (Overlay vs ROM)"
# Shows exactly what you modified from defaults
find /overlay/upper/etc/config -type f -exec ls -l {} \; 2>/dev/null >> "$OUT_FILE"
end_log

log "Startup Scripts (Enabled/Disabled)"
ls /etc/rc.d/ >> "$OUT_FILE"
end_log

log "RC.LOCAL (Custom Startup)"
cat /etc/rc.local >> "$OUT_FILE"
end_log

# ------------------------------------------------------------------------------
# 3. NETWORK STATE (The Veins)
# ------------------------------------------------------------------------------
echo "--- 3. Networking ---"
log "Interfaces (Low Level)"
ip -d link show >> "$OUT_FILE"
end_log

log "IP Addresses"
ip -d addr show >> "$OUT_FILE"
end_log

log "Routing Table"
ip route show table all >> "$OUT_FILE"
end_log

log "Ethtool Offload Status (CRITICAL)"
# Verifies if TSO/GRO/GSO are actually OFF
for iface in $(ls /sys/class/net/ | grep -vE "lo|docker|br-"); do
    echo "--- $iface Features ---" >> "$OUT_FILE"
    ethtool -k "$iface" 2>/dev/null | grep -E "tcp-segmentation|generic-segmentation|generic-receive" >> "$OUT_FILE"
    echo "--- $iface Flow Control ---" >> "$OUT_FILE"
    ethtool -a "$iface" 2>/dev/null >> "$OUT_FILE"
    echo "--- $iface Ring Buffers ---" >> "$OUT_FILE"
    ethtool -g "$iface" 2>/dev/null >> "$OUT_FILE"
done
end_log

log "Traffic Control (SQM/CAKE Stats)"
tc -s qdisc show >> "$OUT_FILE"
end_log

# ------------------------------------------------------------------------------
# 4. SECURITY (The Armor)
# ------------------------------------------------------------------------------
echo "--- 4. Security ---"
log "NFTables Ruleset (The Actual Firewall)"
nft list ruleset >> "$OUT_FILE"
end_log

log "Listening Ports"
netstat -tulpn >> "$OUT_FILE"
end_log

log "Conntrack Status"
conntrack -C 2>/dev/null || echo "conntrack tool not installed" >> "$OUT_FILE"
sysctl net.netfilter.nf_conntrack_count 2>/dev/null >> "$OUT_FILE"
end_log

# ------------------------------------------------------------------------------
# 5. DOCKER (Pi 5 Only - The Heavy Weapons)
# ------------------------------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
    echo "--- 5. Docker ---"
    log "Docker Daemon Config"
    cat /etc/docker/daemon.json 2>/dev/null >> "$OUT_FILE"
    end_log

    log "Running Containers"
    docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" >> "$OUT_FILE"
    end_log
    
    log "Docker Networks"
    docker network ls >> "$OUT_FILE"
    docker network inspect bridge >> "$OUT_FILE"
    end_log
fi

# ------------------------------------------------------------------------------
# 6. LOGS (The Evidence)
# ------------------------------------------------------------------------------
echo "--- 6. Recent Logs ---"
log "System Log (Last 100)"
logread | tail -n 100 >> "$OUT_FILE"
end_log

log "Kernel Log (Last 100)"
dmesg | tail -n 100 >> "$OUT_FILE"
end_log

echo "========================================================"
echo "✅ AUDIT COMPLETE"
echo "Report saved to: $OUT_FILE"
echo "SCP this file to your PC for analysis."
echo "========================================================"