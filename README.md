# 📡🕵️‍♂️ Raspberry-Ci5: The Net Correctional 📊🛰️

> ###### **Status:** `Functional` 🌱 (Class A Operational)

------

> [!NOTE]
>
> # 🛸💨 **The Proof** 🟰 **The** 🍰
>
> ### Pi 5 Cortex-A76 achieving **+0ms Latency** & **0.2ms Jitter** under full load.
>
> ![buffer.png](docs/images/buffer.png)
>
> **This is not "good" for a home router. It is statistically perfect.**
>
> ###### (Test: 500/500Mbps Fiber via R7800 AP & Packet Offloading Disabled)
> ###### (Active: Suricata IDS + CrowdSec + Ntopng + Redis + AdGuard Home + Rebound + CAKE)
> ------
> ### **[Bufferbloat Result (+ direct download for /docs/.csv)](https://www.waveform.com/tools/bufferbloat?test-id=bb0dc946-bb4e-4b63-a2e5-72f47f80040e)**

------

## 📉 **The "Why" (Market Correction)** 📈

Most routers are **Tier 1 Garbage** (ISP/Consumer) or **Tier 3 Overkill** ($600+ Enterprise/Vendor-Locked).

Ci5 proves that commodity ARM hardware + open-source software can mechanically outperform proprietary appliances costing 4x as much:

| **Model** | **Price (£)** | **Latency / Jitter** | **IDS Throughput** | **Architecture** | **Freedom?** |
| --- | --- | :-: | :-: | :-: | :-- |
| **Pi5 OpenWrt (Ci5)** | **£130** | **✅ +0ms / 0.2ms** | **~920 Mbps** | **Hybrid (Kernel + Docker)** | **🔓 Absolute** |
| UniFi Gateway Ultra | £105 | ⚠️ +10ms (SmartQ) | 1 Gbps | Monolithic | 🔒 Vendor Lock |
| GL.iNet Flint 2 | £130 | ✅ +2ms / 3ms | ~500 Mbps | OpenWrt Fork | 🔓 Open Source |
| Ubiquiti UDM-SE | £480 | ⚠️ +3ms / 2ms | 3.5 Gbps | Monolithic | 🔒 Vendor Lock |
| Firewalla Gold+ | £580+ | ✅ +1ms / 1ms | 2.5 Gbps | Proprietary Linux | 🔒 Proprietary |

------

## 🛡️ The Architecture – Hybrid Control Plane ⚔️

"**Docker-on-Router**" usually means the entire network loses connectivity as soon as Docker sneezes.

### **Why Your Internet Never Dies (Default Behaviour)**

| Path | Runs Where | Job | If It Crashes → Internet Impact |
| --- | --- | --- | --- |
| **Fast Path** | Bare metal kernel | Routing · NAT · CAKE SQM · BBR · Unbound | **Still 100% up** – 0 ms latency maintained |
| **Smart Path** | Isolated Docker | Suricata IDS · CrowdSec · Ntopng · Redis · AdGuard | **Still 100% up** – temporarily packet blind |

Even if Docker explodes, Suricata shits itself, and/or you fat-finger a container update:

* The packets keep flowing with perfect CAKE shaping.
* Zoom call and/or ranked matchmaking don't care that Suricata just segfaulted.

------

## 👁️ **Optional: Fail-Closed Security (Kill Switch)**

*For users who prioritize: **Security > Connectivity***

By default, Ci5 is **Fail-Open** (Connectivity First). 

However, there is an optional watchdog script for **high-threat environments** that enforces **Fail-Closed** security.

**Tool:** `extras/paranoia_watchdog.sh`

* **Logic:** Polls critical containers (Suricata & CrowdSec) every 10 seconds.
* **Action:** If inspection dies, it **physically kills the WAN interface** (`ip link set eth1 down`).
* **Result:** **No Inspection = No Internet.** Traffic only resumes when the security stack is confirmed running again.

------

## 🛒 Phase 1: **Hardware Essentials** 👨‍🔧

| **Component** | **Rationale** | **Note** |
| --- | --- | --- |
| **🤖 Raspberry Pi 5 (4GB / 8GB)** | **Cortex-A76 is required** for line-rate DPI/SQM. **Pi 4 cannot do this**. | 8GB mandatory for **Full Stack**. |
| **⚡ USB-C PD PSU (27W+)** | Stability is non-negotiable. Packet processing spikes power. | Official PSU recommended. |
| **💾 Storage (Lite)** | MicroSD (A1/A2) is fine. | Logs and Docker I/O will kill SD cards. |
| **💾 Storage (Full)** | USB 3.0 Flash/SSD is highly recommended. | Optimised for Full Stack reliability. |
| **🔌 USB 3.0 NIC (WAN)** | Dedicated lane for Internet ingress. Leaves onboard ETH for LAN. | Yes, USB 3.0 works. Latency overhead is negligible vs CAKE gains. |
| **🛜 Access Point** | Pi 5 onboard Wi-Fi is garbage. Use a dedicated AP. | Tested with Netgear R7800 (OpenWrt) |

------

## 🔌 Phase 2: **Reference Wiring** ⚡

Wire your system exactly as follows to achieve intended performance and isolation:

### **1. Raspberry Pi 5 (The Brain/Router)**

* **USB 3.0 Port (Middle Blue):** Plug in your **USB Gigabit/2.5G Adapter**.
  * *This is `eth1` (WAN). Connect this to your ISP Modem/ONT.*
* **Onboard Ethernet:** *This is `eth0` (LAN). Connect this to R7800/AP Port 1.*

### **2. Netgear R7800 (The Managed Switch/AP)**

* **Port 1 (LAN):** 🔗 Connect to **Pi 5 Onboard Ethernet**.
  * *Role: Trunk Port (Carries all VLANs).*
* **Port 2 (LAN):** 🖥️ **Trusted Devices** (PC/Mac).
  * *Role: Access Port (VLAN 10).*
* **Port 3 (LAN):** 💡 **IoT Hubs** (Hue Bridge/Tado).
  * *Role: Access Port (VLAN 30).*
* **Port 4 (LAN):** 🆘 **Emergency Access**.
  * *Role: Admin/Management (VLAN 1). Use this if you lock yourself out.*
* **WAN Port:** ❌ **Leave Empty**

------

## 💾 Phase 3: **Installation (Auto-Install)** 🛣️

### 🧠 Step 1: Flash The Brain

We utilize a pre-baked "Golden Master" image containing all drivers, Python dependencies, and Ci5 scripts pre-loaded.

1. **Download:** Go to **[Releases](https://github.com/dreamswag/ci5/releases)** and grab the latest `Ci5-v7.4-RC-1.img.gz`.
2. **Flash:** Use [**BalenaEtcher**](https://etcher.balena.io/) to write it to your SD Card or USB SSD.
3. **Boot:** Insert into Pi 5 and power on.

------

### 🧙‍♂️ Step 2: The Setup Wizard

1. **Connect:** Ensure your PC is connected to the Pi 5 LAN port (direct or via AP).
2. **Login:** Open Terminal / PowerShell:
   ```bash
   ssh root@192.168.1.1
   ```
3. **Launch:**
   ```bash
   cd ci5 && sh setup.sh
   ```
   > **Answer the configuration questions (ISP Type, Wi-Fi Password, etc)**

------

### 🧱 Step 3: Install Core (Lite)

- **Establishes the "0ms" foundation.**

- *Resizes storage, tunes kernel, configures CAKE SQM, sets up Unbound DNS.*

```bash
sh install-lite.sh
```
> *(System will reboot automatically; Speed test runs on startup)*

**Status:** Optimised & functional router 🛜

------

### 🏰 Step 4: Secure The Citadel (Full)

**Deploys the Docker Security Stack.**

*Installs Docker, Suricata (IDS), CrowdSec (IPS), AdGuard Home, Ntopng, and Redis.*

```bash
ssh root@192.168.99.1
cd ci5 && sh install-full.sh
```

> **AdGuard Login:** `admin` / `ci5admin`

------

## 🛜 Phase 4: **Access Point Setup** 🪄

### ✅ Option A: I have a Netgear R7800 (The "Reference" AP)

The Pi 5 Wizard generated a custom configuration script for your AP. You just need to tell the AP to fetch it.

1. **Connect:** Ensure R7800 WAN port is connected to Pi 5 LAN port temporarily.
2. **Execute:** Run this **single command** from your PC terminal:

   ```powershell
   ssh -o StrictHostKeyChecking=no root@192.168.1.1 "wget -O - http://192.168.99.1/r7800.sh | sh"
   ```

   *(R7800 will download its config from the Pi 5, apply VLANs, and reboot into a Dumb AP)*

3. **REWIRE:** Once finished, move the **Pi 5** (*eth0 internal*) **cable** to **LAN 1** as per the Wiring Guide.

------

### ❓ Option B: I have a UniFi / Omada / Asus AP

<details>
<summary>📡 <b>Expand Generic AP Configuration</b></summary>

Check `generic_ap_reference.txt` (generated by the Wizard). Your goal is to map SSIDs to VLAN IDs.

------

#### **For Controller-Based Systems (UniFi / Omada)**

These systems use a "Controller" to push settings to APs.

**1. Create Networks (VLAN-Only / Third-Party Gateway):**

| Name | VLAN ID | DHCP Server | Notes |
| --- | --- | --- | --- |
| Trusted | 10 | **Disabled** | Handled by Pi 5 |
| IoT | 30 | **Disabled** | Handled by Pi 5 |
| Guest | 40 | **Disabled** | Handled by Pi 5 |

**2. Create Wi-Fi Networks (SSIDs):**

| SSID | Network | VLAN | Client Isolation |
| --- | --- | --- | --- |
| Ci5_Trusted | Trusted | 10 | OFF |
| Ci5_IoT | IoT | 30 | **ON** |
| Ci5_Guest | Guest | 40 | **ON** |

**3. Management Network:**

* Leave the AP's own IP address on the **Default / Native LAN (VLAN 1)**.
* The Pi 5 will assign it an IP in the `192.168.99.x` range.

**4. Physical Wiring (Critical):**

* **Pi 5 LAN Port** → **AP / Switch Uplink Port**.
* This connection acts as a **Trunk** (Carries VLANs 1, 10, 30, 40).
* Ensure your AP/Switch port is set to **"All Profiles"** or **"Trunk"**.

------

#### **For Consumer Routers as APs (Asus / Netgear Stock Firmware)**

If reusing an old router running stock firmware:

**1. Operation Mode:**

* Set device to **"Access Point (AP) Mode"**.
* This automatically disables Firewall, NAT, and DHCP Server.

**2. VLAN Support:**

* ⚠️ **Warning:** Most stock consumer routers **CANNOT** assign VLANs to SSIDs ⚠️
* If your router does not support "VLAN to SSID Mapping" (often called "IPTV/VLAN" or "Multi-SSID"):
  *  everything will connect to the **Trusted Network (VLAN 10)** or **Management Network**.

* **Fix:** Flash OpenWrt on it (See Option A) or buy a VLAN-capable AP (UniFi U6, Omada EAP).

**3. Physical Wiring:**

* **Pi 5 LAN Port** → **AP WAN or LAN1 Port**.
* Set AP's IP to `192.168.99.2/24`, Gateway to `192.168.99.1`.

------

#### **Quick Reference Table**

| **VLAN** | **Network** | **Purpose** | **Client Isolation** | **DHCP** |
| --- | --- | --- | --- | --- |
| 1 | Management | AP Admin Access | N/A | Pi 5 (`192.168.99.x`) |
| 10 | Trusted | PCs, Phones, Laptops | OFF | Pi 5 (`10.10.10.x`) |
| 30 | IoT | Smart Home Devices | **ON** | Pi 5 (`10.10.30.x`) |
| 40 | Guest | Visitors | **ON** | Pi 5 (`10.10.40.x`) |

</details>

------

## 🖥️ "I Build My Own Binaries"

<details>
<summary>🔒 <b>Trust Issues Edition (Manual Install / Source Build)</b></summary>
If you do not want to use the pre-baked image, follow this manual path.

#### 1. Flash Stock OpenWrt

Download the official **24.10.4 EXT4** image for Raspberry Pi 5:

* 🔗 **[firmware-selector.openwrt.org](https://firmware-selector.openwrt.org/)** → **Raspberry Pi 5** → **24.10.4** 

**CRITICAL: Download the EXT4 (Factory) image. SquashFS is read-only and will brick this workflow.**

<details>
<summary>📦 <b>Expand Package List (for custom builds)</b></summary>

```text
base-files bcm27xx-gpu-fw bcm27xx-utils bind-dig bind-libs block-mount brcmfmac-firmware-usb brcmfmac-nvram-43455-sdio btrfs-progs busybox ca-bundle ca-certificates cgi-io curl cypress-firmware-43455-sdio dbus dnsmasq dropbear e2fsprogs ethtool fdisk firewall4 fstools fwtool getrandom hostapd-common htop ip-full ip-tiny ip6tables-zz-legacy iptables-mod-conntrack-extra iptables-mod-extra iptables-mod-ipopt iptables-nft iptables-zz-legacy iw iwinfo jansson4 jq jshn jsonfilter kernel kmod-br-netfilter kmod-brcmfmac kmod-brcmutil kmod-cfg80211 kmod-crypto-acompress kmod-crypto-blake2b kmod-crypto-crc32c kmod-crypto-hash kmod-crypto-kpp kmod-crypto-lib-chacha20 kmod-crypto-lib-chacha20poly1305 kmod-crypto-lib-curve25519 kmod-crypto-lib-poly1305 kmod-crypto-sha256 kmod-crypto-xxhash kmod-fs-btrfs kmod-fs-exfat kmod-fs-ext4 kmod-fs-ntfs3 kmod-fs-vfat kmod-hid kmod-hid-generic kmod-hwmon-core kmod-hwmon-pwmfan kmod-i2c-bcm2835 kmod-i2c-brcmstb kmod-i2c-core kmod-i2c-designware-core kmod-i2c-designware-platform kmod-ifb kmod-input-core kmod-input-evdev kmod-ip6tables kmod-ipt-conntrack kmod-ipt-conntrack-extra kmod-ipt-core kmod-ipt-extra kmod-ipt-ipopt kmod-ipt-nat kmod-ipt-nat6 kmod-ipt-physdev kmod-lib-crc-ccitt kmod-lib-crc16 kmod-lib-crc32c kmod-lib-lzo kmod-lib-raid6 kmod-lib-xor kmod-lib-xxhash kmod-lib-zlib-deflate kmod-lib-zlib-inflate kmod-lib-zstd kmod-libphy kmod-mdio-devres kmod-mii kmod-mmc kmod-net-selftests kmod-nf-conncount kmod-nf-conntrack kmod-nf-conntrack6 kmod-nf-flow kmod-nf-ipt kmod-nf-ipt6 kmod-nf-log kmod-nf-log6 kmod-nf-nat kmod-nf-nat6 kmod-nf-reject kmod-nf-reject6 kmod-nfnetlink kmod-nfnetlink-queue kmod-nft-bridge kmod-nft-compat kmod-nft-core kmod-nft-fib kmod-nft-nat kmod-nft-offload kmod-nft-queue kmod-nls-base kmod-nls-cp437 kmod-nls-iso8859-1 kmod-nls-utf8 kmod-phy-ax88796b kmod-phylink kmod-ppp kmod-pppoe kmod-pppox kmod-regmap-core kmod-sched-cake kmod-sched-core kmod-scsi-core kmod-slhc kmod-spi-bcm2835 kmod-spi-dw kmod-spi-dw-mmio kmod-tcp-bbr kmod-thermal kmod-tun kmod-udptunnel4 kmod-udptunnel6 kmod-usb-core kmod-usb-hid kmod-usb-net kmod-usb-net-asix kmod-usb-net-asix-ax88179 kmod-usb-net-cdc-ether kmod-usb-net-cdc-ncm kmod-usb-net-rtl8152 kmod-usb-net-aqc111 kmod-usb-storage kmod-usb-storage-uas kmod-veth libatomic1 libattr libblkid1 libblobmsg-json20240329 libbpf1 libc libcap libcbor0 libcomerr0 libcurl4 libdaemon libdbus libe2p2 libelf1 libevdev libevent2-7 libexpat libext2fs2 libf2fs6 libfdisk1 libfdt libfido2-1 libgcc1 libip4tc2 libip6tc2 libiptext-nft0 libiptext0 libiptext6-0 libiwinfo-data libiwinfo20230701 libjson-c5 libjson-script20240329 liblua5.1.5 liblucihttp-lua liblucihttp-ucode liblucihttp0 liblzo2 libmbedtls21 libmnl0 libmount1 libncurses6 libnftnl11 libnghttp2-14 libnl-tiny1 libopenssl3 libparted libpcap1 libpthread libreadline8 librt libseccomp libsmartcols1 libss2 libubox20240329 libubus-lua libubus20250102 libuci20250120 libuclient20201210 libucode20230711 libudebug libudev-zero libunbound liburcu libusb-1.0-0 libustream-mbedtls20201210 libuuid1 libuv1 libwebsockets-full libxtables12 logd losetup lua luci luci-app-firewall luci-app-package-manager luci-app-sqm luci-app-unbound luci-base luci-compat luci-lib-base luci-lib-ip luci-lib-jsonc luci-lib-nixio luci-lib-uqr luci-light luci-lua-runtime luci-mod-admin-full luci-mod-network luci-mod-status luci-mod-system luci-proto-ipv6 luci-proto-ppp luci-theme-bootstrap mkf2fs mtd netifd nftables-json odhcp6c odhcpd-ipv6only openwrt-keyring opkg parted partx-utils ppp ppp-mod-pppoe procd procd-seccomp procd-ujail r8152-firmware resize2fs resolveip rpcd rpcd-mod-file rpcd-mod-iwinfo rpcd-mod-luci rpcd-mod-rrdns rpcd-mod-ucode sqm-scripts tc-tiny tcpdump terminfo ubox ubus ubusd uci uclient-fetch ucode ucode-mod-fs ucode-mod-html ucode-mod-lua ucode-mod-math ucode-mod-nl80211 ucode-mod-rtnl ucode-mod-ubus ucode-mod-uci ucode-mod-uloop uhttpd uhttpd-mod-ubus unbound-control unbound-daemon urandom-seed usbids usbutils usign wifi-scripts wireless-regdb wpad-basic-mbedtls xtables-legacy xtables-nft zlib python3 python3-pip nano kmod-nft-offload kmod-ipt-offload
```

</details>

------

#### 2. Transfer Scripts

Connect your PC to the Pi 5 (`eth0`).

```powershell
# From your PC
scp -r ci5 root@192.168.1.1:/root/
ssh root@192.168.1.1
```

#### 3. Execute

```bash
cd /root/ci5
sh setup.sh
sh install-lite.sh
```

</details>

------

## 🙋 **FAQ / Troubleshooting**

<details>
<summary><b>"I didn't set a Wi-Fi password in the Wizard!"</b></summary>
- The Wizard requires you to set passwords to prevent locked-out APs.
- If you skipped AP generation but forgot what you typed, view your config:

```bash
cat /root/ci5/ci5.config
```

</details>

<details>
<summary><b>"How do I apply the R7800 config if I've already set it up?"</b></summary>
- The `r7800_auto.sh` script is an **Enforcer**. It does not merge settings; it overwrites them.
- If your R7800 is already running OpenWrt, simply run the script as detailed in Phase 4 Option A:
  - It will delete the old interfaces and apply the new VLAN bridge topology automatically.

</details>

<details>
<summary><b>"My PC on R7800 Port 2 is not working?"</b></summary>
- Check the wiring:
  - Port 1 MUST go to the Pi 5.
  - Port 2 is VLAN 10 (Trusted). 
    - If your PC is set to a Static IP on a different subnet, it will fail. 
      - Ensure PC is DHCP.

</details>

<details>
<summary><b>"Why is my Bufferbloat not 'A+'?"</b></summary>

1. **Re-Run the Wizard:** You can run the speed tuner manually if your line speed changed:
   ```bash
   /root/ci5/extras/speed_wizard.sh
   ```
2. **Disable Offloading:** Ensure you have disabled hardware offloading. Run:
   ```bash
   ethtool -K eth1 gro off gso off tso off
   ```

</details>

<details>
<summary><b>"How do I update the Docker stack?"</b></summary>

```bash
cd /opt/ci5-docker
docker-compose pull
docker-compose up -d
```

</details>

------

> [!TIP]
>
> ```
> "Fuck all this Dream Machine dick-measuring contest. We all gon be dead in 100 years.
> Let the kids have the unmaintained Raspberry-Ci5 auto-install scripts w/ NIDs & 0ms lag"
> ```
>
> ------
>
> ###### > 🌪️ **UDM Pro Funnel:** 🎪 jape.eth 🃏
