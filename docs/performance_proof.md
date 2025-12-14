# 🚀 Pi5 Router Killer: Live Performance Proof
**Date:** 2025-12-09 15:43:42
**Scenario:** 3-Person Flat (4 Active Users, Multiple Devices)

## ⚡ Real-Time Network Load
Capturing live traffic throughput...
```text
⬇️ **Current Download:** 453 Mbps
⬆️ **Current Upload:** 1 Mbps
```
*Note: This is the background traffic currently being routed without latency spikes.*

## 🧠 System Health (Under Load)
```bash
Load Average (1/5/15 min): 0.06 0.06 0.07
CPU Temp: 40°C
RAM Usage: 1905496 / 8152256 (Buffers: 2418404)
```

## 🍰 SQM / CAKE Status (Bufferbloat Killer)
Checking if packets are being delayed or dropped to maintain 0ms latency:
```text
 Sent 7882045697 bytes 17532108 pkt (dropped 523, overlimits 11739853 requeues 560) 
 backlog 0b 0p requeues 560
 memory used: 7916288b of 15060Kb
```

## 🐳 Service Overhead (Docker)
Resources consumed by IDS (CrowdSec), DPI (Ntopng), and DNS (AdGuard):
```text
NAME       CPU %     MEM USAGE / LIMIT
ntopng     21.58%    0B / 0B
redis      0.26%     0B / 0B
crowdsec   0.17%     0B / 0B
suricata   7.52%     0B / 0B
```

## 🔌 Active Connections
```text
Total Active Flows: 875
Top 5 Talkers (Local IPs):
    164 src=10.10.40.166
    110 src=10.10.40.1
     88 src=10.10.20.145
     57 src=10.10.10.142
     51 src=10.10.20.1
```
