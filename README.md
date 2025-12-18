# 📡 🛸 Raspberry-Ci5: The Net Correctional 💨 🛰️

###### 📡 [ci5.host](https://github.com/dreamswag/ci5/): core ~ 📟 [ci5.run](https://github.com/dreamswag/ci5.run): auto ~ 🔬 [ci5.network](https://github.com/dreamswag/ci5.network) docs

> [!NOTE]
>
> # **📊 Realtime Response Under Load (RRUL) 📊**
>
> ###### RRUL 30s Sustained:
> ###### > 500/500Mbps ONT Fiber
> ###### > USB 3.0 Gigabit NIC (WAN)
> ###### > Packet Offloading Disabled
> ![rrul.png](docs/images/rrul.png)
> ###### (Active: Suricata IDS + CrowdSec + Ntopng + Redis + AdGuard Home + Unbound + CAKE)
>
> ## **Throughput is volume; Latency is discipline.**
>
> ### **1. Network does not buckle under load:**
>
> * **Status:** Saturated (500/500 Mbps)
> * *Visual:* Maximum throughput (Top/Middle blocks)
>
> ### **2. Traffic queued based on packet priority near-instantly:**
>
> * **Jitter:** ±0.2ms (Imperceptible)
> * *Visual:* **Near-zero latency drift** (Bottom flatline)
> ------
> ###### **[External Verification (Waveform)](https://www.waveform.com/tools/bufferbloat?test-id=bb0dc946-bb4e-4b63-a2e5-72f47f80040e)**
------

## 📉 **The "Why" (Market Correction)** 📈

Most routers are **Tier 1 Garbage** (ISP/Consumer) or **Tier 3 Overkill** ($600+ Enterprise/Vendor-Locked). 

**Ci5 proves that commodity ARM hardware + open-source software can mechanically outperform proprietary appliances costing 4x as much**:

| **Model**             | **Price (£)** | **Latency / Jitter** | **IDS Throughput** |       **Architecture**       | **Freedom?**   |
| --------------------- | ------------- | :------------------: | :----------------: | :--------------------------: | :------------- |
| **Pi5 OpenWrt (Ci5)** | **£130**      |  **✅ +0ms / 0.2ms**  |   **~920 Mbps**    | **Hybrid (Kernel + Docker)** | **🔓 Absolute** |
| Ubiquiti UDM-SE       | £480          |     ⚠️ +3ms / 2ms     |      3.5 Gbps      |          Monolithic          | 🔒 Vendor Lock  |

------

## 🛡️ The Architecture – Hybrid Control Plane ⚔️

"**Docker-on-Router**" usually means the entire network loses connectivity as soon as Docker sneezes. 

**Ci5 decouples these functions**:

| Path           | Runs Where        | Job                                                | If It Crashes → Internet Impact              |
| -------------- | ----------------- | -------------------------------------------------- | -------------------------------------------- |
| **Fast Path**  | Bare metal kernel | Routing · NAT · CAKE SQM · BBR · Unbound           | **Still 100% up** – 0 ms latency maintained  |
| **Smart Path** | Isolated Docker   | Suricata IDS · CrowdSec · Ntopng · Redis · AdGuard | **Still 100% up** – temporarily packet blind |

------

# 🛣️ **Installation** 🛣️

## ⚡ **Native**
### For automated deployment & optimization - run via Raspberry Pi 5's terminal:
```bash
# Initialize / Liberate
curl ci5.run/free | sh
```
## 📡 **Source**
### To audit code or fetch raw files (from this repo):
```
# Example: Fetch raw file via CDN
curl ci5.host/install-lite.sh
```
## 🔬 **Manual**
### For hardware compatibility lists, manual build instructions, binaries, and FAQs: 
   * 👉 **[ci5.network](https://github.com/dreamswag/ci5.network)**
------

> [!TIP]
> ```
> "Fuck all this Dream Machine dick-measuring contest. We all gon be dead in 100 years.
> Let the kids have the unmaintained Raspberry-Ci5 auto-install scripts w/ NIDs & 0ms bufferbloat"
> ```
> ------
> ###### > 🌪️ **UDM Pro Funnel:** 🎪 jape.eth 🃏
