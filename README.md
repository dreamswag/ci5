# 📡🕵️‍♂️ Raspberry-Ci5: The Net Correctional 📊🛰️

> ###### **Status:** `Functional` 🌱 (Class A Operational)

------

> [!NOTE]
>
> # 🛸💨 **The Proof** 🟰 **The** 🍰
>
> ### Pi 5 Cortex-A76 achieving **+0ms Latency** & **0.2ms Jitter** under full load.
>
> ![buffer.png](docs/buffer.png)
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

Ci5 proves that commodity ARM hardware + open-source software can mechanically outperform proprietary appliances costing 4x as much.

| **Model** | **Price (£)** | **Latency / Jitter** | **IDS Throughput** |       **Architecture** |  **Freedom?** |
| --------------------- | :------------ | :------------------: | :----------------: | :--------------------------: | :------------: |
| **Pi5 OpenWrt (Ci5)** | **£130** |  **✅ +0ms / 0.2ms** |   **~920 Mbps** | **Hybrid (Kernel + Docker)** | **🔓 Absolute** |
| UniFi Gateway Ultra   | £105          |   ⚠️ +10ms (SmartQ)   |       1 Gbps       |          Monolithic          | 🔒 Vendor Lock  |
| GL.iNet Flint 2       | £130          |     ✅ +2ms / 3ms     |     ~500 Mbps      |         OpenWrt Fork         | 🔓 Open Source  |
| Ubiquiti UDM-SE       | £480          |     ⚠️ +3ms / 2ms     |      3.5 Gbps      |          Monolithic          | 🔒 Vendor Lock  |
| Firewalla Gold+       | £580+         |     ✅ +1ms / 1ms     |      2.5 Gbps      |      Proprietary Linux       | 🔒 Proprietary  |

------

## 🛡️ The Architecture – Hybrid Control Plane ⚔️

"**Docker-on-Router**" usually means: 

* the entire network loses connectivity as soon as Docker sneezes.

**Why Your Internet Never Dies (Default Behaviour)**

| Path           | Runs Where        | Job                                      | If It Crashes → Internet Impact              |
| -------------- | ----------------- | ---------------------------------------- | -------------------------------------------- |
| **Fast Path**  | Bare metal kernel | Routing · NAT · CAKE SQM · BBR · Unbound | **Still 100% up** – 0 ms latency maintained  |
| **Smart Path** | Isolated Docker   | Suricata IDS · CrowdSec · Ntopng · Redis · AdGuard | **Still 100% up** – temporarily packet blind |

Even if Docker explodes, Suricata shits itself, and/or you fat-finger a container update: 

* the packets keep flowing with perfect CAKE shaping.
* Zoom call and/or ranked matchmaking don't care that Suricata just segfaulted.

## 👁️ **Optional: The Kill Switch (Schizo Mode)**

[ *For users who prioritize: **Security > Connectivity*** ]

By default, Ci5 is **Fail-Open** (Connectivity First). 

* However - there is also an included optional watchdog script which can be enforced post-installation.
* Intended for **high-threat environments** by enforcing **Fail-Closed** security.

**Tool:** `extras/paranoia_watchdog.sh`

* **Logic:** It polls critical containers (Suricata & CrowdSec) every 10 seconds.
* **Action:** If inspection dies, it **physically kills the WAN interface** (`ip link set eth1 down`).
* **Result:** **No Inspection = No Internet.** 
  * Traffic only resumes when the security stack is confirmed running again.

------

## 🛒 Phase 1: **<u>Hardware Essentials</u>** 👨‍🔧

> 🧠 **The Brain (Compute)**

| **Component** | **Rationale** | **Note** |
| -------------------------------- | ------------------------------------------------------------ | ------------------------------------------------------------ |
| **🤖 Raspberry Pi 5 (4GB / 8GB)** | Cortex-A76 is required for line-rate DPI/SQM. Pi 4 cannot do this. | 8GB mandatory for **Full Stack**.                            |
| **⚡ USB-C PD PSU (27W+)** | Stability is non-negotiable. Packet processing spikes power. | Official PSU recommended.                                    |
| **💾 Storage** | **Lite:** MicroSD (A1/A2) is fine. **Full:** USB 3.0 Flash/SSD highly recommended. | Logs and Docker I/O will kill SD cards.                      |
| **🔌 USB 3.0 NIC (WAN)** | Dedicated lane for Internet ingress. Leaves onboard ETH for LAN. | Yes, USB 3.0 works. The latency overhead is negligible vs CAKE gains. |
| **🛜 Access Point** | Pi 5 onboard Wi-Fi is garbage. Use a dedicated AP.           | Tested with Netgear R7800 (OpenWrt)                 |

------

## 🔌 Phase 2: **<u>Reference Wiring</u>** ⚡

To achieve the intended performance and isolation, wire your system exactly as follows:

### **1. Raspberry Pi 5 (The Brain/Router)**
* **USB 3.0 Port (Middle Blue):** Plug in your **USB Gigabit/2.5G Adapter**.
    * *This is `eth1` (WAN). Connect this to your ISP Modem/ONT.*
* **Onboard Ethernet:**
    * *This is `eth0` (LAN). Connect this to R7800/AP Port 1.*

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

## 💾 Phase 3: **<u>Installation</u>** 🛣️

### 1: Firmware Generation 🃏
We utilize a custom "Golden Master" OpenWrt image. This pre-bakes the kernel drivers, file systems, and tools needed to run Docker on bare metal.
**CRITICAL: Use the EXT4 image. SquashFS is read-only and will brick this workflow.**

- ⚙️ **Direct Download (Recommended)**
  - **[🔗 DOWNLOAD (openwrt-24.10.4-ext4-factory.img.gz)](https://sysupgrade.openwrt.org/store/807e824a47843a246639ddd2c7ab4ab434ab7a21dc35c9ed40d8d6e778091f7c/openwrt-24.10.4-54a3724f6671-bcm27xx-bcm2712-rpi-5-ext4-factory.img.gz)**

- 🛠️ **Alternative: Build it Yourself** (*Trust Issues Edition*)
  - Go to **[firmware-selector.openwrt.org](https://firmware-selector.openwrt.org/)** -> **Raspberry Pi 5** -> **24.10.4**.
  - Click '**Customize installed packages**' and paste the block below.
  - **Request Build** -> Download **FACTORY (EXT4)**.

<details>
<summary>📦 <b>Click to expand Package List (Updated)</b></summary>

```text
base-files bcm27xx-gpu-fw bcm27xx-utils bind-dig bind-libs block-mount brcmfmac-firmware-usb brcmfmac-nvram-43455-sdio btrfs-progs busybox ca-bundle ca-certificates cgi-io curl cypress-firmware-43455-sdio dbus dnsmasq dropbear e2fsprogs ethtool fdisk firewall4 fstools fwtool getrandom hostapd-common htop ip-full ip-tiny ip6tables-zz-legacy iptables-mod-conntrack-extra iptables-mod-extra iptables-mod-ipopt iptables-nft iptables-zz-legacy iw iwinfo jansson4 jq jshn jsonfilter kernel kmod-br-netfilter kmod-brcmfmac kmod-brcmutil kmod-cfg80211 kmod-crypto-acompress kmod-crypto-blake2b kmod-crypto-crc32c kmod-crypto-hash kmod-crypto-kpp kmod-crypto-lib-chacha20 kmod-crypto-lib-chacha20poly1305 kmod-crypto-lib-curve25519 kmod-crypto-lib-poly1305 kmod-crypto-sha256 kmod-crypto-xxhash kmod-fs-btrfs kmod-fs-exfat kmod-fs-ext4 kmod-fs-ntfs3 kmod-fs-vfat kmod-hid kmod-hid-generic kmod-hwmon-core kmod-hwmon-pwmfan kmod-i2c-bcm2835 kmod-i2c-brcmstb kmod-i2c-core kmod-i2c-designware-core kmod-i2c-designware-platform kmod-ifb kmod-input-core kmod-input-evdev kmod-ip6tables kmod-ipt-conntrack kmod-ipt-conntrack-extra kmod-ipt-core kmod-ipt-extra kmod-ipt-ipopt kmod-ipt-nat kmod-ipt-nat6 kmod-ipt-physdev kmod-lib-crc-ccitt kmod-lib-crc16 kmod-lib-crc32c kmod-lib-lzo kmod-lib-raid6 kmod-lib-xor kmod-lib-xxhash kmod-lib-zlib-deflate kmod-lib-zlib-inflate kmod-lib-zstd kmod-libphy kmod-mdio-devres kmod-mii kmod-mmc kmod-net-selftests kmod-nf-conncount kmod-nf-conntrack kmod-nf-conntrack6 kmod-nf-flow kmod-nf-ipt kmod-nf-ipt6 kmod-nf-log kmod-nf-log6 kmod-nf-nat kmod-nf-nat6 kmod-nf-reject kmod-nf-reject6 kmod-nfnetlink kmod-nfnetlink-queue kmod-nft-bridge kmod-nft-compat kmod-nft-core kmod-nft-fib kmod-nft-nat kmod-nft-offload kmod-nft-queue kmod-nls-base kmod-nls-cp437 kmod-nls-iso8859-1 kmod-nls-utf8 kmod-phy-ax88796b kmod-phylink kmod-ppp kmod-pppoe kmod-pppox kmod-regmap-core kmod-sched-cake kmod-sched-core kmod-scsi-core kmod-slhc kmod-spi-bcm2835 kmod-spi-dw kmod-spi-dw-mmio kmod-tcp-bbr kmod-thermal kmod-tun kmod-udptunnel4 kmod-udptunnel6 kmod-usb-core kmod-usb-hid kmod-usb-net kmod-usb-net-asix kmod-usb-net-asix-ax88179 kmod-usb-net-cdc-ether kmod-usb-net-cdc-ncm kmod-usb-net-rtl8152 kmod-usb-storage kmod-usb-storage-uas kmod-veth libatomic1 libattr libblkid1 libblobmsg-json20240329 libbpf1 libc libcap libcbor0 libcomerr0 libcurl4 libdaemon libdbus libe2p2 libelf1 libevdev libevent2-7 libexpat libext2fs2 libf2fs6 libfdisk1 libfdt libfido2-1 libgcc1 libip4tc2 libip6tc2 libiptext-nft0 libiptext0 libiptext6-0 libiwinfo-data libiwinfo20230701 libjson-c5 libjson-script20240329 liblua5.1.5 liblucihttp-lua liblucihttp-ucode liblucihttp0 liblzo2 libmbedtls21 libmnl0 libmount1 libncurses6 libnftnl11 libnghttp2-14 libnl-tiny1 libopenssl3 libparted libpcap1 libpthread libreadline8 librt libseccomp libsmartcols1 libss2 libubox20240329 libubus-lua libubus20250102 libuci20250120 libuclient20201210 libucode20230711 libudebug libudev-zero libunbound liburcu libusb-1.0-0 libustream-mbedtls20201210 libuuid1 libuv1 libwebsockets-full libxtables12 logd losetup lua luci luci-app-firewall luci-app-package-manager luci-app-sqm luci-app-unbound luci-base luci-compat luci-lib-base luci-lib-ip luci-lib-jsonc luci-lib-nixio luci-lib-uqr luci-light luci-lua-runtime luci-mod-admin-full luci-mod-network luci-mod-status luci-mod-system luci-proto-ipv6 luci-proto-ppp luci-theme-bootstrap mkf2fs mtd netifd nftables-json odhcp6c odhcpd-ipv6only openwrt-keyring opkg parted partx-utils ppp ppp-mod-pppoe procd procd-seccomp procd-ujail r8152-firmware resize2fs resolveip rpcd rpcd-mod-file rpcd-mod-iwinfo rpcd-mod-luci rpcd-mod-rrdns rpcd-mod-ucode sqm-scripts tc-tiny tcpdump terminfo ubox ubus ubusd uci uclient-fetch ucode ucode-mod-fs ucode-mod-html ucode-mod-lua ucode-mod-math ucode-mod-nl80211 ucode-mod-rtnl ucode-mod-ubus ucode-mod-uci ucode-mod-uloop uhttpd uhttpd-mod-ubus unbound-control unbound-daemon urandom-seed usbids usbutils usign wifi-scripts wireless-regdb wpad-basic-mbedtls xtables-legacy xtables-nft zlib python3 python3-pip kmod-nft-offload kmod-ipt-offload
```
</details>

### 1.5: Flashing The Media (Windows 11) 💿
**Recommended Tool:** [BalenaEtcher](https://etcher.balena.io/) or [Rufus](https://rufus.ie/).

1. **Insert Media:** Plug your **High-Endurance MicroSD** or **USB 3.0 Drive** into your PC.
2. **Select Image:** Open Etcher/Rufus and select the `.img.gz` file you downloaded.
3. **Flash:** Click **Flash!** and wait for validation to complete.
4. **⚠️ PRE-LOAD THE SCRIPTS (Optional but Recommended):**
   * *If you plan to use a **Keyboard + Monitor**, do this now:*
   1. Unplug and Re-plug the USB drive into your PC.
   2. Windows will detect a small partition named `boot`. Open it.
   3. Extract the ci5.rar file (which is provided from downloading this GitHub repo)
   4. Drag your **`ci5` folder** (containing these scripts) directly onto this `boot` drive.
   5. Eject safely.

---

### 📁 2: Initial Access & File Transfer 

You have two ways to access the Pi 5 to start the installation. Choose one:

------

#### 🧑‍💻 <u>**Method A: Ethernet + SSH**</u>  
*Best for users who want to copy-paste commands from their PC.*

1. **Wiring:**
   
   * **WAN:** Connect your Modem/ONT to the Pi 5 **USB Adapter** (`eth1`).
   * **LAN:** Connect your PC directly to the Pi 5 **Onboard Ethernet** (`eth0`).
2. **Connect:**
   * Ensure your PC network adapter is set to **Automatic (DHCP)**.
   * Open PowerShell / Terminal on your PC.
3. **Transfer & Login:**
   * **Send the Scripts:** (Run from your PC's `ci5` folder location)
     
     ```powershell
     scp -r ci5 root@192.168.1.1:/root/
     ```
   * **Login:**
     ```powershell
     ssh root@192.168.1.1
     ```
   * *(Accept the fingerprint by typing `yes`. No password is required yet.)*

------

#### 🖥️ <u>Method B: Keyboard + Monitor</u>
*Best option for those who don't have PC LAN port and/or prefer direct Pi 5 console access*

1. **Wiring:**
   
   * **WAN:** Connect your Modem/ONT to the Pi 5 **USB Adapter** (`eth1`).
   * **Console:** Connect a monitor (Micro-HDMI) and Keyboard to the Pi 5.
2. **Boot:** Power on the Pi. Wait for the scrolling text to stop.
3. **Login:**
   * Press **Enter**.
   * You should see 'root@openwrt:#'
4. **Retrieve the Scripts:**
   * If you dragged the `ci5` folder onto the drive in Step 1.5, move it to your home folder:
     ```bash
     cp -r /boot/ci5 /root/
     cd /root/ci5
     ```
   * *Troubleshooting:* If you forgot to preload them, you can plug in a **second** USB drive containing the folder and mount it:
     
     ```bash
     mkdir -p /mnt/usb
     mount /dev/sda1 /mnt/usb  #  (If 'ci5' folder is on an external SD card: replace sda1 with sdb1)
     cp -r /mnt/usb/ci5 /root/
     ```

------

### 📂 <u>Regardless of method chosen - you should now have</u>:

* **access to the Pi 5 terminal**
  * **Confirmation**: (*root@openwrt:#*) text present with a blinking input cursor shown to the right
    * indicates ability to enter further commands (*which are noted below*)
   
* **'*/root/ci5*' folder present in your Pi 5 Openwrt install directory**
  * **Confirmation**: type '*ls /root/ci5*' - then press the **Enter** key (*do not type the apostrophes*)
    * should return a list showing all of the same files on the '**dreamswag/ci5**' GitHub page

------

## 🧙‍♂️ 2.5: Run Configuration Wizard

> [!IMPORTANT]
>
> >   - [ ] Run this **ONCE** to define your ISP, Passwords, and Network Identity:
>
> ```bash
> /root/ci5/setup.sh
> ```
>
> *This will generate a `ci5.config` file and (optional) AP scripts based on your inputs.*

------

## 3\. Deploy The Core (Lite) 🌐🌎

**The "Set and Forget" Router** 🛜

  - **Actions:** Resizes storage, Tunes Kernel (0ms), Configures Unbound, **Auto-Tunes SQM**.
  - **Performance:** Max throughput, lowest latency. Zero bloat.
  - **Target:** Gaming, households, people who just want the internet to work perfectly.

> [!IMPORTANT]
>
> >   - [ ] **Run this first\! Even if you want the Full stack, this lays the foundation:**
>
> ```bash
> /root/ci5/install-lite.sh
> ```
> *(Note: The Speed Wizard runs automatically at the end. The system will reboot when finished.)*

------

## 4\. Deploy The Fortress (Full) 🚨🔍

**(Optional) The "Citadel"** 🏰

  - **Actions:** Installs Docker, Suricata (IDS), CrowdSec (IPS), AdGuard Home (AdBlock), Ntopng, Redis.
  - **Capabilities:** Deep Packet Inspection, IP ban-lists, Layer-7 Analysis.
  - **Cost:** Uses \~1.8GB RAM. Requires 4GB+ Pi.

> [!IMPORTANT]
>
> > - [ ] **Once reboot is completed after Lite install, run**:
>
> ```bash
> /root/ci5/install-full.sh
> ```
>

-----

## 🛜 **Access Point Configuration**

### Option A: I have a Netgear R7800 (The "Reference" AP)

If you generated the R7800 script in the Wizard:

1. Grab the auto-generated file from Pi5 (/root/ci5)

   1.   **scp root@192.168.1.1:/tmp/r7800_auto.sh 'C:\Downloads\ci5'**

2. Connect R7800 **WAN Port** (Temporary) to Pi 5 to transfer file

3. **Copy `r7800_auto.sh` to your R7800 `/tmp/` folde**r:

   1.  Go to the folder containing the 'r7800_auto.sh' file
   2.  Click the box at the top of the file explorer which co file location  at the top of the folder containing 'r7800_auto.sh': 
       1.  delete all text (e.g. 'C:\Downloads\ci5') and type 'cmd' instead
       2.  press Enter -> which should bring up a Command Prompt starting with 'C:\Downloads\ci5>'
       3.  type '**scp root@192.168.1.1:/tmp/r7800_auto.sh r7800_auto.sh**' and press Enter

4. SSH into the R7800 (ssh root@192.168.1.1) and run it:
   ```bash
   /tmp/r7800_auto.sh
   ```

5. **REWIRE:** Once finished, move the cable to **LAN 1** as per the Wiring Guide.

### Option B: I have a Unifi / Omada / Asus AP

Check `generic_ap_reference.txt` (generated by the Wizard)

* Configure your AP Controller with:#
  * **Trusted SSID** → VLAN **10**
  * **IoT SSID** → VLAN **30** (Client Isolation: ON)
  * **Guest SSID** → VLAN **40** (Client Isolation: ON)

-----

## ❓ **FAQ / Troubleshooting**

### **"I didn't set a Wi-Fi password in the Wizard\!"**

The Wizard requires you to set passwords to prevent locked-out APs. If you skipped AP generation but forgot what you typed, view your config:
```bash
cat ci5.config
```

### **"How do I apply the R7800 config if I've already set it up?"**

The `r7800_auto.sh` script is an **Enforcer**. It does not merge settings; it overwrites them.

  - If your R7800 is already running OpenWrt, simply run the script. It will delete the old interfaces and apply the new VLAN bridge topology automatically.

### **"Why is my PC on R7800 Port 2 not working?"**

Check the wiring.

  - Port 1 MUST go to the Pi 5.
  - Port 2 is VLAN 10 (Trusted). If your PC is set to a Static IP on a different subnet, it will fail. Ensure PC is DHCP.

### **"My Bufferbloat is 'B' or 'C', not 'A+'?"**

1.  **Re-Run the Wizard:** You can run the speed tuner manually if your line speed changed:
    ```bash
    sh extras/speed_wizard.sh
    ```
2.  **Disable Offloading:** Ensure you have disabled hardware offloading. Run:
    ```bash
    ethtool -K eth1 gro off gso off tso off
    ```

-----

> [!TIP]
>
> ```
> "Fuck all this Dream Machine dick-measuring contest. We all gon be dead in 100 years.
> Let the kids have the unmaintained Raspberry-Ci5 auto-install scripts w/ Docker, NIDs & 0ms lag"
> ```
>
> -----
>
> ###### \> 🌪️ **UDM Pro Funnel:** 🎪  jape.eth 🃏
