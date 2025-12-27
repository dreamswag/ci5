#!/bin/sh
# Removes Suricata IDS
docker stop suricata 2>/dev/null
docker rm suricata 2>/dev/null
echo "✅ Suricata removed. IDS disabled."
