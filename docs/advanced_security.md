# 🔐 Advanced Security Options

These features are non-standard and should only be installed if you understand the risks (e.g., self-locking out).

## A. YubiKey / FIDO2 Authentication for SSH
This guide assumes you have \`openssh-server\` installed on OpenWrt (not the default \`dropbear\`).

1. **Install Packages:**
   \`\`\`bash
   opkg install openssh-server openssh-client libfido2
   \`\`\`

2. **Configure SSHD:**
   Edit \`/etc/ssh/sshd_config\` to ensure FIDO/U2F is enabled:
   \`\`\`conf
   PubkeyAuthentication yes
   HostbasedAuthentication no
   AuthenticationMethods publickey
   # Required for FIDO2/U2F devices
   SecurityKeyProvider /usr/libexec/ssh-sk-helper
   \`\`\`

3. **Enroll Key:**
   On your client PC, generate the FIDO key, specifying the Pi as the user:
   \`\`\`bash
   ssh-keygen -t ed25519-sk -f ~/.ssh/id_fido_pi5 -U pi5_user
   \`\`\`

4. **Deploy Key:**
   Copy the public key (\`.pub\` file) to \`/root/.ssh/authorized_keys\` on the Pi5.
   
5. **Test:**
   Always test the new key in a separate SSH session before logging out of your old one!

## B. CPU Frequency Scaling/Overclocking (Pi5 Only)
To ensure the Pi5 stays cool under maximum load and avoids throttling:

1. **Install:** \`opkg install cpufrequtils\`
2. **Setup:** Use custom governors or set limits in \`/etc/config/system\` or \`/etc/rc.local\` to manage thermal headroom.
