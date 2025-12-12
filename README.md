

# 📡🕵️‍♂️ Raspberry-Ci5: The Net Correctional 📊🛰️

> ###### **Status:** `Functional` 🌱 (Class A Operational)

---

> [!NOTE]
>
> # 🛸💨 **The Proof** 🟰 **The** 🍰
>
> ### Pi 5 Cortex-A76 achieving **+0ms Latency** & **0.2ms Jitter** under full load.
>
> ![/docs/buffer.png](/docs/buffer.png)
>
> **This is not "good" for a home router. It is statistically perfect.**
>
> ###### (Test: 500/500Mbps Fiber via R7800 AP | Active: Suricata IDS + CrowdSec + CAKE)
> ---
> ### **[Bufferbloat Result (+ direct download for /docs/.csv)](https://www.waveform.com/tools/bufferbloat?test-id=bb0dc946-bb4e-4b63-a2e5-72f47f80040e)**

<<<<<<< Updated upstream
=======
---

>>>>>>> Stashed changes
## 📉 **The "Why" (Market Correction)** 📈

Most routers are **Tier 1 Garbage** (ISP/Consumer) or **Tier 3 Overkill** ($600+ Enterprise/Vendor-Locked).

Ci5 proves that commodity ARM hardware + open-source software can mechanically outperform proprietary appliances costing 4x as much.

| **Model** | **Price (£)** | **Latency / Jitter** | **IDS Throughput** |       **Architecture** |  **Freedom?** |
| --------------------- | :------------ | :------------------: | :----------------: | :--------------------------: | :------------: |
| **Pi5 OpenWrt (Ci5)** | **£130** |  **✅ +0ms / 0.2ms** |   **~920 Mbps** | **Hybrid (Kernel + Docker)** | **🔓 Absolute** |
| Ubiquiti UDM-SE       | £480          |     ⚠️ +3ms / 2ms     |      3.5 Gbps      |          Monolithic          | 🔒 Vendor Lock  |
| Firewalla Gold+       | £580+         |     ✅ +1ms / 1ms     |      2.5 Gbps      |      Proprietary Linux       | 🔒 Proprietary  |
| GL.iNet Flint 2       | £130          |     ✅ +2ms / 3ms     |     ~500 Mbps      |         OpenWrt Fork         | 🔓 Open Source  |
| UniFi Gateway Ultra   | £105          |   ⚠️ +10ms (SmartQ)   |       1 Gbps       |          Monolithic          | 🔒 Vendor Lock  |

---

## 🔌 **Reference Setup (Wiring Guide)**

To achieve the intended "Reference" performance and isolation, wire your system exactly as follows:

### **1. Raspberry Pi 5 (The Brain)**
* **USB 3.0 Port (Middle Blue):** Plug in your **USB Gigabit/2.5G Adapter**.
    * *This is `eth1` (WAN). Connect this to your ISP Modem/ONT.*
* **Onboard Ethernet:**
    * *This is `eth0` (LAN). Connect this to R7800 Port 1.*

### **2. Netgear R7800 (The Managed Switch/AP)**
* **Port 1 (LAN):** 🔗 Connect to **Pi 5 Onboard Ethernet**.
    * *Role: Trunk Port (Carries all VLANs).*
* **Port 2 (LAN):** 🖥️ **Trusted Devices** (PC/Mac).
    * *Role: Access Port (VLAN 10).*
* **Port 3 (LAN):** 💡 **IoT Hubs** (Hue Bridge/Tado).
    * *Role: Access Port (VLAN 30).*
* **Port 4 (LAN):** 🆘 **Emergency Access**.
    * *Role: Admin/Management (VLAN 1). Use this if you lock yourself out.*
* **WAN Port:** ❌ **Leave Empty**.

---

## 💾 **Installation: The Happy Path** 🛣️

### 1. Firmware Generation 🃏
We utilize a custom "Golden Master" OpenWrt image. This pre-bakes the kernel drivers and tools needed to run Docker on bare metal.
**CRITICAL: Use the EXT4 image. SquashFS is read-only and will brick this workflow.**

- ⚙️ **[🔗 DOWNLOAD FACTORY IMAGE (openwrt-24.10.4-ext4-factory.img.gz)](https://sysupgrade.openwrt.org/store/7766ba8cd22b62ab32c4c4085844ca2cabe30cf054858693a997c9cce152cef3/openwrt-24.10.4-5557c802b251-bcm27xx-bcm2712-rpi-5-ext4-factory.img.gz)**
- *Flash to SD Card using BalenaEtcher or Rufus.*

### 2. The Wizard (Infrastructure Identity) 🧙‍♂️
Once the Pi 5 boots, SSH in (`root` / no password).
Run this **ONCE** to define your ISP, Passwords, and Network Identity.

```bash
sh setup.sh
```

> *This will generate a `ci5.config` file and (optional) AP scripts based on your inputs.*

### 3. Deploy The Core (Lite) 🌐

Reads your config and deploys the router, firewall, CAKE SQM, and AdGuard Home.

Zero questions asked. The router will reboot automatically.

<<<<<<< Updated upstream
------

## 🛡️ Phase 3: The Architecture – Hybrid Control Plane ⚔️

**Why Your Internet Never Dies**

| Path          | Runs Where       | Job                                      | If It Crashes → Internet Impact |
|---------------|------------------|------------------------------------------|--------------------------------|
| **Fast Path** | Bare metal kernel| Routing · NAT · CAKE SQM · BBR · Unbound | **Still 100% up** – 0 ms latency maintained |
| **Smart Path**| Isolated Docker  | Suricata IDS · CrowdSec · Ntopng · Redis · AdGuard | **Still 100% up** – temporarily packet blind |

Even if Docker explodes, Suricata shits itself, and/or you fat-finger a container update: 
* the packets keep flowing with perfect CAKE shaping.
* Zoom call / CS2 Premier match don't care that the IDS just segfaulted.

Meanwhile - "Docker-on-Router" setup usually means: 
* the entire network loses connectivity as soon as Docker sneezes.

## 1. **The Core (Lite)** 🌐🧱

**The "Set and Forget" Router**

- **Stack:** Native OpenWrt + Unbound + CAKE SQM.
- **Performance:** Max throughput, lowest latency. Zero bloat.
- **Target:** Gaming, households, people who just want the internet to work perfectly.

> [!IMPORTANT]
>
> - [ ] **Run this first! Even if you want the Full stack, this lays the foundation**:
=======
Bash
>>>>>>> Stashed changes

```
sh install-lite.sh
```

### 4. Tune Performance (Speed Wizard) 🏎️

Mandatory for 0ms Latency.

<<<<<<< Updated upstream
- **Stack:** Adds Suricata (IDS), CrowdSec (IPS), AdGuard Home (AdBlock), Ntopng (Vis), Redis.
- **Capabilities:** Deep Packet Inspection, IP ban-lists, Layer-7 Analysis.
- **Cost:** Uses ~1.8GB RAM. Requires 4GB+ Pi.

> [!IMPORTANT]
>
> - [ ] **Reboot after Lite install, then run**:
=======
Once internet is up, run this to benchmark your line and auto-configure CAKE SQM limits.

Bash

```
sh extras/speed_wizard.sh
```

### 5. Deploy The Fortress (Full) 🚨

(Optional) Adds Suricata (IDS), CrowdSec (IPS), Ntopng, and Redis via Docker.

Requires 8GB Pi 5.

Bash
>>>>>>> Stashed changes

```
sh install-full.sh
```

------

## 🛜 **Access Point Configuration**

### Option A: I have a Netgear R7800 (The "Reference" AP)

If you generated the R7800 script in the Wizard:

1. Connect R7800 **WAN Port** (Temporary) to Pi 5 to transfer file, OR use a USB stick.

2. Copy `r7800_auto.sh` to your R7800 `/tmp/` folder.

3. SSH into the R7800 and run it:

   sh /tmp/r7800_auto.sh

4. **REWIRE:** Once finished, move the cable to **LAN 1** as per the Wiring Guide.

> **⚠️ WARNING:** This script is destructive. It wipes the R7800 and applies the VLAN Port Isolation logic described in "Wiring Guide".

### Option B: I have a Unifi / Omada / Asus AP

Check generic_ap_reference.txt (generated by the Wizard).

Configure your AP Controller with:

- **Trusted SSID** → VLAN **10**
- **IoT SSID** → VLAN **30** (Client Isolation: ON)
- **Guest SSID** → VLAN **40** (Client Isolation: ON)

------

## ❓ **FAQ / Troubleshooting**

### **"I didn't set a Wi-Fi password in the Wizard!"**

The Wizard requires you to set passwords to prevent locked-out APs. If you skipped AP generation but forgot what you typed, view your config:

cat ci5.config

### **"How do I apply the R7800 config if I've already set it up?"**

The `r7800_auto.sh` script is an **Enforcer**. It does not merge settings; it overwrites them.

- If your R7800 is already running OpenWrt, simply run the script. It will delete the old interfaces and apply the new VLAN bridge topology automatically.

### **"Why is my PC on R7800 Port 2 not working?"**

Check the wiring.

- Port 1 MUST go to the Pi 5.
- Port 2 is VLAN 10 (Trusted). If your PC is set to a Static IP on a different subnet, it will fail. Ensure PC is DHCP.

### **"My Bufferbloat is 'B' or 'C', not 'A+'?"**

1. **Run the Wizard:** Did you run `sh extras/speed_wizard.sh`?

2. Disable Offloading: Ensure you have disabled hardware offloading. Run:

   ethtool -K eth1 gro off gso off tso off

------

> [!TIP]
>
> ```
> "Fuck all this Dream Machine dick-measuring contest. We all gon be dead in 100 years.
> Let the kids have the unmaintained Raspberry-Ci5 auto-install scripts w/ Docker, NIDs & 0ms lag"
> ```
>
> ------
>
> ###### > 🌪️ **UDM Pro Funnel:** 🎪  jape.eth 🃏