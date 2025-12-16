# Maintenance Policy (Read Before Opening Issues)

### 🛑 Status: "Works on My Machine" Ware 🛑

---

This repository is a **reference implementation**, not a managed software product.

I built this to solve a specific problem on my specific hardware stack. It works perfectly for me.

I am sharing it so you can learn from it, fork it, or copy it - but I am not your tech support.

---

## 🛠️ The "Golden" Hardware Stack

I only build, test, and validate this code on the following configuration:

| Component   | Exact Model                              | Notes                                            |
| ----------- | ---------------------------------------- | ------------------------------------------------ |
| **Compute** | Raspberry Pi 5 (8GB)                     | Pi 5 non-negotiable; 4GB has leeway but untested |
| **WAN NIC** | **USB 3.0 Gigabit** (RTL8153) (eth1)     | RTL8153 tested; AX88179 likely works too         |
| **LAN**     | **Onboard Ethernet** (eth0)              | Trunk to AP                                      |
| **AP**      | **Netgear R7800** (OpenWrt)              | VLAN-capable                                     |
| **Storage** | **SanDisk 128GB High Endurance SD Card** | SD card works; USB preferred; nVME HAT optimal   |
| **Line**    | **500/500 Mbps ONT Fiber** (PPPoE)       | Your ISP will vary                               |
| **Case**    | **Pironman5-Mini**                       | Not required; recommended for HAT NIC            |

**If you deviate from this stack, you are the QA department.**

---

## 🚫 What This Project Is NOT 🚫

| Expectation                  | Reality                          |
| ---------------------------- | -------------------------------- |
| Enterprise product with SLAs | Personal project shared publicly |
| Supported on all hardware    | Works on one hardware stack      |
| Maintained by a team         | Maintained when it breaks for me |
| Compatible with Pi 4         | **Absolutely not**               |
| Guaranteed to work for you   | Works for me                     |

---

## ⚠️ Hardware Compatibility: The Hard Truths ⚠️

### Raspberry Pi 4: Not Supported. Won't Work. Don't Ask.

The Pi 4's **Cortex-A72** cannot achieve what the Pi 5's **Cortex-A76** delivers. This is not a software limitation. This is silicon.

| Metric              | Pi 4 (Cortex-A72) | Pi 5 (Cortex-A76) |
| ------------------- | ----------------- | ----------------- |
| Single-thread perf  | ~1.8 DMIPS/MHz    | ~2.7 DMIPS/MHz    |
| IPC improvement     | Baseline          | +50%              |
| CAKE + IDS headroom | Insufficient      | Comfortable       |
| Bufferbloat at load | Degrades          | +0ms sustained    |

**The Pi 4 cannot run CAKE SQM + Suricata IDS at gigabit without packet drops, latency spikes, or thermal throttling.**

------

**If you already own a Pi 4**:

- Use it for something else 
  - (*Pi-hole, Home Assistant, PiKVM*)

- Accept the fact that Ci5 results won't be replicated

**If you're buying new hardware**:

- Buy the Pi 5 (8GB)
  - Don't buy the Pi 4 "to save money"
  - Don't buy the Pi 5 (4GB) "to save money"

- Accept the £15-20 extra cost as a '**premium for sanity**'
  - Mitigating hours of (*likely inherently fruitless*) frustration is priceless


---

## Raspberry Pi 5 (4GB): Technically Possible, Spiritually Inadvisable

The 4GB model *can* run the Lite stack comfortably - and *might* run the Full stack under light load.

**However - the 8GB model provides peace of mind you cannot buy retroactively**:

| Scenario                               | 4GB Outcome     |
| -------------------------------------- | --------------- |
| Lite stack only                        | ✅ Fine          |
| Full stack, idle                       | ⚠️ Probably fine |
| Full stack, active browsing            | ⚠️ May be fine   |
| Full stack, saturation test            | ❌ OOM risk      |
| Full stack + Suricata rule update      | ❌ OOM likely    |
| Full stack + Ntopng historical queries | ❌ Swap hell     |

------

### **If you already have a 4GB**:

- Run the Lite stack
- Be cautious with Full stack
- Monitor `htop` during load tests
- Don't open issues when you OOM

---

## USB NIC Compatibility

**Validated chipsets:**
- **RTL8153** (*most common*)

**Not validated - but likely to work:**

- **AX88179** (*common*)
- **AQC111U** (*2.5Gbps HATs*)

**Not validated - and not recommended:**

- Random Amazon specials
- Realtek RTL8152 (*100Mbps, wrong chip*)
- Anything that doesn't show up as `eth1`

## **If your NIC doesn't work:**

1. Check `dmesg | grep -i eth`
2. Check `ip link`
3. Ensure driver is loaded (`lsmod | grep r8152` or similar)
4. Try a different NIC
5. Don't open an issue

---

## 🛜 Access Point Requirements 🛜

Your AP must support **802.1Q VLAN tagging** to use the VLAN segmentation features.

**Known compatible:**
- **Netgear R7800** (OpenWrt) - Reference AP
  - auto-installer included for configuration


**Untested, but highly likely to be compatible:**

- UniFi APs (*controller-managed*)
- Omada APs (*controller-managed*)
- Any OpenWrt-capable router in AP mode

**Not compatible:**
- ISP-provided routers (usually)
- Most consumer routers on stock firmware
- Mesh systems without Ethernet backhaul
- "Range extenders"

**If you can't assign VLANs to SSIDs, you can't use the VLAN features.** 

* The core routing will still work, but you'll have a flat network (undermining local security).

---

## ♻️ Update Frequency ♻️

| Scenario                   | Response                                                     |
| -------------------------- | ------------------------------------------------------------ |
| **It breaks for me**       | Fixed immediately.                                           |
| **It breaks for you**      | It won't be fixed.                                           |
| **Security vulnerability** | If reported: will be reviewed (& integrated if necessary)    |
| **Feature request**        | You have my full blessing to fork the repo and implement it. |
| "**Works on Pi 4?**"       | No.                                                          |
| "**Works on 2GB Pi 5?**"   | 🤨❓🧐                                                          |

---

## 🤝 Contributing & Forking 🤝

### **Do you want to:**

- Add Pi 4 support?
- Build a web GUI configurator?
- Fix a bug that only affects Starlink users?
- Add integration with Home Assistant?
- Port this to Orange Pi / Radxa / x86?

### **Incredible! Fork it.** 

**I encourage you to take this code and make it your own**:

- Build a better version
- Release a "Universal Edition"
- Create `ci5-enterprise` with logging compliance
- Make `ci5-travel` for portable routers

**The code is free (MIT), but my time is not.**

- (especially when it regards troubleshooting hardware which I don't own)

---

## 🐛 Bug Reports 🐛

### Valid Bug Reports:
- Syntax error in a script (with line number)
- Documented feature doesn't work as described
- Security vulnerability (report privately)
- **Pull Request included**

### Invalid Bug Reports:
- "Doesn't work" (with no details)
- "How do I configure X?" (RTFM)
- "Works on Pi 4?" (no)
- "My ISP uses weird VLANs" (your problem)
- "I changed Y and now Z is broken" (you broke it)
- Any issue without `bone_marrow.sh` output

---

## 📋 Pre-Issue Submission Checklist 📋 

1. **Are you running the Golden Hardware Stack?** If not, see above.
2. **Did you read the README?** All of it?
3. **Did you run `validate.sh`?** What does it say?
4. **Did you run `bone_marrow.sh`?** Do you have the output?
5. **Did you try the AI debugging workflow?** (See below)
6. **Did you search existing issues/Reddit?**
7. **Can you reproduce on a fresh flash?**

If you answered "no" to any of these: please don't open an issue.

---

# 🔧 Common Issues: Pre-Answered 🧑‍🔧

- ### **"My bufferbloat is not A+"**


1. **Did you run `speed_wizard.sh`?** SQM limits must match your line speed.
2. **Are hardware offloads disabled?** Run: `ethtool -k eth1 | grep -E "offload|segmentation"` — all should be `off`
3. **Is CAKE active?** Run: `tc qdisc show dev eth1 | grep cake`
4. **PPPoE double-shaping?** Run: `tc qdisc show dev pppoe-wan` — should NOT show cake
5. **Is your ISP the bottleneck?** Compare to direct-to-modem results.

- ### **"Docker containers won't start"**


1. **Is Docker running?** `/etc/init.d/dockerd status`
2. **Enough disk space?** `df -h`
3. **Pull failed?** Check internet connectivity: `ping 1.1.1.1`
4. **ARM64 images?** All Ci5 containers are ARM64-native.

- ### **"DNS not working"**


1. **Is Unbound running?** `pgrep unbound`

2. **Is AdGuard running?** `docker ps | grep adguard`

3. **Port conflict?** `netstat -tlnp | grep ':53'`

4. **Firewall blocking?** Check `uci show firewall`

   

- ### **"Can't SSH after fresh flash"**


**Clear old host keys:**
```bash
ssh-keygen -f "$HOME/.ssh/known_hosts" -R "192.168.1.1"
ssh-keygen -f "$HOME/.ssh/known_hosts" -R "192.168.99.1"
```

- ### **"VLANs not working"**


1. **Does your AP support 802.1Q?**
2. **Is the trunk port configured correctly?**
3. **Did you run the R7800 auto-config or manually configure?**
4. **Can you see VLAN interfaces?** `ip link show | grep eth0.`

- ### **"Speed is lower than expected"**


1. **What does speedtest show direct to modem?** (Baseline)
2. **What does `iperf3` show LAN-only?** (Isolate Pi vs ISP)
3. **Is SQM limiting below your line speed?** Check `uci show sqm`
4. **Thermal throttling?** Check `cat /sys/class/thermal/thermal_zone0/temp`
5. **Are you using Ethernet?** 

- ### **"Suricata not detecting threats"**


1. **Is Suricata running?** `docker ps | grep suricata`
2. **Are rules loaded?** `docker exec suricata suricata-update list-sources`
3. **Correct interface?** Check docker-compose.yml `-i` flag
4. **Test with EICAR:** `wget http://www.eicar.org/download/eicar.com`

---

## 🤖 "I Still Need Help" Protocol 🤖

**This project has no**: help desk, Discord moderators, or paid support tier.

**What you do have**: the same identical tools which the creator used to build it.

## The Process

### Step 1: Generate Diagnostic Report
```bash
ssh root@192.168.99.1
sh /root/ci5/extras/bone_marrow.sh
```

This creates a comprehensive system dump: 

- CPU, kernel, network config, firewall rules, Docker status, DNS state, SQM config, logs 
  - everything needed for a comprehensive 'system state' capture to a single text file

### Step 2: Export to Your PC
```bash
# From your PC
scp root@192.168.99.1:/root/*_bone_marrow_*.md ./
```

Or, if you prefer:
```bash
# On the Pi
cat /root/*_bone_marrow_*.md
# Copy the output
```

### Step 3: Consult The Oracle

1. Open [Claude](https://claude.ai) or [Gemini](https://gemini.google.com) 
   1. (*avoid Gemini 'Fast' model as much as possible*)

2. Upload/paste the entire Ci5 repository 
   1. GitHub link likely won't work based on current models - so either:
      1. upload the entire folder (via **Gemini 'Import Code'**)
      2. Fork the repo, and import directly (via **Claude 'Add from GitHub'**)

3. Attach your `bone_marrow_report.md`
4. Describe your problem with **explicit, complete detail**:
   - What you expected to happen
   - What actually happened
   - What you already tried
   - Exact error messages (copy-paste, not paraphrase)
5. Follow the advice **diligently**

#### Step 4: Evaluate Outcomes

**a) Issue resolved**
→ Congratulations. 
→ You learned something. 
→ Document it for yourself and/or share with others.

**b) Issue persists**
→ Generate a new `bone_marrow.sh` report (state has changed)
→ Repeat Step 3 onwards with updated diagnostics
→ Iterate until fixed

**c) Network bricked / locked out**
→ Connect directly to Pi5 eth0 port
→ Try `sh /root/ci5/extras/emergency_recovery.sh` (if accessible)
→ Or: Re-flash SD/USB with golden image (10 minutes)
→ You're back to a known-good state
→ Try again, more carefully and/or with different prompt approach
→ (describe to the same AI conversation instance that previous instructions bricked access)

**d) Exhausted all options**
→ Verify you meet all hardware requirements
→ Post to Reddit (r/openwrt, r/homelab, r/networking)
→ **Include your `bone_marrow.sh` output**
→ Describe your full troubleshooting journey
→ Someone might help.

---

## 🤔 Why This Process? 🤔

**This is the exact workflow the repository creator follows.**

You have access to the exact same:
- AI models
- diagnostic tools
- recovery options
- documentation
- source code

The only difference is willingness to iterate.

- **Pay the labour tax.**

- **Learn the process.**

- **Own your infrastructure.** 

- **Build 'the next Ci5'.**

---

### What "Pay the Labor Tax" Means

| Traditional Expectation       | Ci5 Reality                  |
| ----------------------------- | ---------------------------- |
| Free software + free support  | Free software + your effort  |
| Maintainer solves my problems | AI + you solve your problems |
| Pay with donations            | You pay with labour          |
| Passive consumption           | Active learning              |

If you expected a human to solve your problems for free, you misunderstood what open source means in 2025.

---

## 🆘 Emergency Recovery Reference 🆘

If you've truly bricked your network and can't SSH in:

### Option 1: Emergency Recovery Script

If you can connect a keyboard/monitor to the Pi, or access via serial:
```bash
sh /root/ci5/extras/emergency_recovery.sh
```

This creates fallback IPs (192.168.1.1, 192.168.88.1), starts emergency DHCP, and opens firewall.

### Option 2: Re-Flash

1. Power off Pi
2. Remove SD card / USB drive
3. Flash fresh Ci5 image with Balena Etcher
4. Re-insert and boot
5. Run setup wizard
6. You're back to baseline in 10 minutes

### Option 3: Factory Reset

If you can access the Pi at all:
```bash
firstboot -y && reboot
```

This wipes UCI config and restores OpenWrt defaults. You'll need to re-run Ci5 setup.

---

## 📊 Diagnostic Tools Reference 📊

| Tool                    | Purpose                                   | Location                         |
| ----------------------- | ----------------------------------------- | -------------------------------- |
| `validate.sh`           | Pre-flight check, verifies all components | `/root/ci5/`                     |
| `bone_marrow.sh`        | Comprehensive system diagnostic dump      | `/root/ci5/extras/`              |
| `speed_wizard.sh`       | Tune SQM to line speed                    | `/root/ci5/extras/`              |
| `emergency_recovery.sh` | Restore network access when locked out    | `/root/ci5/extras/`              |
| `partial-uninstall.sh`  | Granular component removal                | `/root/ci5/extras/uninstallers/` |

**Run `validate.sh` after every change.** If it's not all green, something is wrong.

---

## 🔄 The Iteration Mindset 🔄

Networking is stateful. Changes have consequences. Things break.

**The correct response to "it broke" is:**

1. Gather diagnostics (`bone_marrow.sh`)
2. Understand what changed
3. Consult AI with full context
4. Apply fix
5. Validate (`validate.sh`)
6. Test (`flent`, `ping`, bufferbloat test)
7. Repeat if necessary

**The incorrect response to "it broke" is:**

1. Panic
2. Open GitHub issue with "doesn't work"
3. Demand immediate human tech support
4. Get angry when ignored

------

- This project rewards patience, iteration, and willingness to learn. 

- Zero intention to reward entitlement 
  - especially given that this project is the result of sharing an accidental discovery
    - which has been streamlined for widely available hardware & completely free-of-charge

---

## 🎯 Philosophy 🎯

### Why No Support?

1. **I built this for me.** 
   1. Sharing it is a gift, not a contract.

2. **Your setup is different.** 
   1. I can't debug hardware I don't own.

3. **AI exists.** 
   1. The same tool that helped build this can help you fix it.

4. **Learning has value.** 
   1. Solving your own problems makes you better.

5. **Time is finite.**
   1. ⏳


### Why Share At All?

- **Because** someone might find it useful.
- **Because** open source is how we got here.
- **Because** vendor lock-in is bullshit.
- **Because** £130 shouldn't beat £500.
- **Because** "enterprise" is often a pricing strategy, not a capability tier.
- **Because** maybe you'll build something better.

------

### What I Owe You

Nothing.

### What You Owe Me

Nothing.

### What You Owe Yourself

The effort to learn, or the honesty to admit this isn't for you.

---

## 📜 License 📜

MIT. Do whatever you want. Attribution appreciated but not required.

- **If you make money from this**: cool. 

- **If you fork it and never credit me**: cool. 

- **If you use it to learn and build something better**: very cool.

---

## 📲 Contact 📲

**For security vulnerabilities:** Open a private security advisory on GitHub.

**For everything else:** Don't.

---

> **TL;DR:**
>
> - No Pi 4 support
> - Get the 8GB Pi 5
> - Run `validate.sh`
> - Run `bone_marrow.sh`
> - Ask AI before asking me
> - Re-flash if stuck
> - Fork if you want changes
> - Your setup, your problem
> - Learn or leave

---

🌪️ **UDM Pro Funnel:** 🎪 jape.eth 🃏