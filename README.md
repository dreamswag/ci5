###### 📟 [ci5.run](https://github.com/dreamswag/ci5.run): curl ~ 🔬 [ci5.host](https://github.com/dreamswag/ci5.host): cure ~ 🧪 [ci5.dev](https://github.com/dreamswag/ci5.dev): cork ~ 🥼 [ci5.network](https://github.com/dreamswag/ci5.network): cert ~ 📡[ci5](https://github.com/dreamswag/ci5)🛰️
# 📡 🛸 Raspberry-Ci5: The Net Correctional 💨 🛰️
| **Model**             | **Price (£)** | **Latency** | **IDS Throughput** |       **Architecture**       | **Freedom?**   |
| --------------------- | ------------- | :------------------: | :----------------: | :--------------------------: | :------------- |
| **Pi5 OpenWrt (Ci5)** | **£130**      |  **✅ +0ms**  |   **~920 Mbps (+)**    | **Hybrid** | **🔓 Absolute** |
| Ubiquiti UDM-SE       | £480          |     ⚠️ +3ms     |      3.5 Gbps      |          Monolithic          | 🔒 Vendor Lock  |
-----
> [!NOTE]
> ## 📊 Realtime Response Under Load (RRUL)
>
> ### RRUL 30s Sustained:
> ###### > 500/500Mbps ONT Fiber
> ###### > USB 3.0 Gigabit NIC (WAN)
> ###### > Packet Offloading Disabled
> ![rrul.png](images/rrul.png)
> ----
> ### CPU Usage Max w/ RRUL: 46% (All Cores)
> ###### > Active: (Suricata IDS + CrowdSec + Ntopng + Redis + AdGuard Home + Unbound + CAKE)
> ![rrul_peak.jpg](images/RRUL_peak.jpg)
> ## **Throughput 🟰 Volume ; Latency 🟰 Discipline**
>
> **1. Network does not buckle under load:**
> * **Status:** Saturated (500/500 Mbps)
> * *Visual:* **Maximum throughput** (Top/Middle blocks)
>
> **2. Traffic queued based on packet priority near-instantly:**
> * **Jitter:** ±0.5ms (Imperceptible)
> * *Visual:* **Near-zero latency drift** (Bottom flatline)
> -----
> ###### **[External Verification (Waveform)](https://www.waveform.com/tools/bufferbloat?test-id=bb0dc946-bb4e-4b63-a2e5-72f47f80040e)**

---
> [!CAUTION]
> ## 🎯 Reference Hardware Stack
> | Component | Required | Notes |
> |-----------|----------|-------|
> | **Compute** | Raspberry Pi 5 (4GB / 8GB / 16GB) | **Non-negotiable** |
> | **WAN** | USB 3.0 Gigabit NIC (RTL8153) | eth1 interface |
> | **AP** | Netgear R7800 or VLAN-capable | Auto-config provided for R7800 |
>
> * **Pi 5 (4GB):** Supported - Lite Stack (Full Stack may OOM).
> * **Pi 5 (1/2GB)**: Unsupported - even Lite Stack will likely OOM.
> * **Pi 4 (Any):** Unsupported - can't achieve documented performance.
>
> 📚 **[Full Hardware Compatibility →](https://github.com/dreamswag/ci5.network/blob/main/docs/GOLDEN_HARDWARE.md)**

---

## ⚡ Install
**Run on Pi 5 terminal**: 
```bash
curl ci5.run/free | sh
```
Bootloader handles everything.

---

## 🏗️ Architecture

**Hybrid Control Plane:** Kernel handles packets. Docker handles intelligence.

| Path | Runs Where | If It Dies |
|------|------------|------------|
| **Fast Path** | Bare metal | N/A (kernel) |
| **Smart Path** | Docker | Internet stays up |

📚 **[Deep Dive →](https://github.com/dreamswag/ci5.network/blob/main/docs/ARCHITECTURE.md)**

---

## ✅ Reference

| Step | Action |
|------|--------|
| 1 | Flash Golden Image or run `curl ci5.run/free \| sh` |
| 2 | Connect hardware (USB NIC → WAN, eth0 → AP) |
| 3 | Run `sh setup.sh` |
| 4 | Deploy stack (`install-lite.sh` or `install-full.sh`) |

📚 **[5-Minute Quickstart →](https://github.com/dreamswag/ci5.network/blob/main/docs/QUICKSTART.md)**

---

## 📚 Documentation
**Everything is located at [ci5.network/docs](https://github.com/dreamswag/ci5.network/tree/main/docs)**:

| Doc | Purpose |
|-----|---------|
| [**QUICKSTART.md**](https://github.com/dreamswag/ci5.network/blob/main/docs/QUICKSTART.md) | 5-minute Setup |
| [**GOLDEN_HARDWARE.md**](https://github.com/dreamswag/ci5.network/blob/main/docs/GOLDEN_HARDWARE.md) | Hardware Requirements |
| [**ARCHITECTURE.md**](https://github.com/dreamswag/ci5.network/blob/main/docs/ARCHITECTURE.md) | Technical Deep-Dive |
| [**MAINTENANCE.md**](https://github.com/dreamswag/ci5.network/blob/main/docs/MAINTENANCE.md) | Updates & Recovery |

---
> [!TIP]
> ```
> "Fuck all this Dream Machine dick-measuring contest. We all gon be dead in 100 years.
> Let the kids have the Raspberry-Ci5 auto-installer w/ NIDs, Corks & 0ms bufferbloat"
> ```
> ------
> ###### > 🌪️ **UDM Pro Funnel:** 🎪 jape.eth 🃏
