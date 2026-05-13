# FIDO2 Linux Authentication — Complete Hardening Guide

Full FIDO2-only authentication on Pop!_OS 24.04 COSMIC (Debian/Ubuntu-based). No password fallback on any privilege path.

Most guides online either use `sufficient` (password still works as fallback) or only cover one PAM service. This guide covers every path an attacker could use to escalate privileges, and explains exactly why each decision was made.

---

## What This Guide Solves

After debugging why FIDO2 worked inconsistently, three issues emerged that no existing documentation covers:

1. **`u2f_keys` single-line bug**: `pam_u2f` only reads the **first matching line** per user. Two lines = second key silently fails. Both keys must be on one line.
2. **`sufficient` vs `required` on cosmic-greeter**: Using `sufficient` causes cosmic-greeter to **freeze** after the FIDO2 timeout because it receives an unexpected `pam_unix` password conversation it can't handle. The correct flag is `required`.
3. **Stale FIDO2 credentials**: `blob[0]=0x2e` means the key has old `pam://hostname` entries. `ykman fido credentials list` reveals them.

---

## Prerequisites

- Any FIDO2-capable security key (YubiKey or equivalent)
- Pop!_OS 24.04 / Ubuntu 24.04 / Debian-based
- `sudo` access
- A second terminal or TTY open before making PAM changes — **never edit PAM without a fallback session open**

---

## Install Dependencies

```bash
sudo apt update
sudo apt install libpam-u2f yubikey-manager
```

---

## Step 1: Register FIDO2 Credentials

Generate credentials for each key. `-n` disables PIN verification (touch-only — required for lock screen since the greeter cannot prompt for a PIN).

```bash
# Key 1 — touch when LED blinks, copy the full output line
pamu2fcfg -n

# Key 2 — repeat
pamu2fcfg -n
```

### Create `u2f_keys` — CRITICAL: Both Keys on One Line

```bash
mkdir -p ~/.config/Yubico

# Format: username:Key1Handle,Key1PubKey,es256,+presence:Key2Handle,Key2PubKey,es256,+presence
# Both keys separated by : on a SINGLE LINE
nano ~/.config/Yubico/u2f_keys

chmod 600 ~/.config/Yubico/u2f_keys
```

**Wrong** (what most guides show — Key 2 will silently fail):
```
yourusername:<KEY1_DATA>,es256,+presence
yourusername:<KEY2_DATA>,es256,+presence
```

**Correct** (single line, colon-separated):
```
yourusername:<KEY1_DATA>,es256,+presence:<KEY2_DATA>,es256,+presence
```

`pam_u2f` reads line 1, finds a match for the username, and stops. It never reaches line 2.

---

## Step 2: Lock Screen (cosmic-greeter)

### Why `required`, not `sufficient`

- **`sufficient`**: If FIDO2 succeeds, skip the rest. If it times out or fails, fall through to `pam_unix` (password). Sounds safe — it's not. cosmic-greeter **freezes** after the FIDO2 timeout because it receives a `pam_unix` password conversation request it has no UI to handle.
- **`required`**: FIDO2 must succeed. Period. No fallback, no freeze.

### Why remove `@include common-auth`

`common-auth` includes `pam_unix` — the password module. Keeping it means password auth is still stacked below FIDO2. Removing it eliminates the password path entirely.

```bash
sudo cp /etc/pam.d/cosmic-greeter /etc/pam.d/cosmic-greeter.bak

sudo tee /etc/pam.d/cosmic-greeter > /dev/null << 'EOF'
#%PAM-1.0
auth    requisite       pam_nologin.so
auth    requisite       pam_succeed_if.so user != root quiet_success
auth    required        pam_u2f.so cue
auth    optional        pam_gnome_keyring.so
@include common-account
session [success=ok ignore=ignore module_unknown=ignore default=bad]        pam_selinux.so close
session required        pam_loginuid.so
session [success=ok ignore=ignore module_unknown=ignore default=bad]        pam_selinux.so open
session optional        pam_keyinit.so force revoke
session required        pam_limits.so
session required        pam_env.so readenv=1
session required        pam_env.so readenv=1 user_readenv=1 envfile=/etc/default/locale
@include common-session
session optional        pam_gnome_keyring.so auto_start
@include common-password
EOF
```

### Fix HID Permissions

cosmic-greeter needs access to the key's HID interface:

```bash
# Permanent (requires re-login)
sudo usermod -aG plugdev $USER

# Immediate (current session)
sudo setfacl -m u:$USER:rw /dev/hidraw*
```

---

## Step 3: sudo

Same logic applies. Replace `pam_yubico` (OTP) or any `@include common-auth` with FIDO2 `required`.

```bash
sudo cp /etc/pam.d/sudo /etc/pam.d/sudo.bak

sudo tee /etc/pam.d/sudo > /dev/null << 'EOF'
#%PAM-1.0
auth       required   pam_u2f.so cue
@include common-account
session    required   pam_limits.so
session    required   pam_env.so readenv=1 user_readenv=0
session    required   pam_env.so readenv=1 envfile=/etc/default/locale user_readenv=0
@include common-session-noninteractive
EOF
```

---

## Step 4: su, chsh, chfn

These are often overlooked. Without hardening, an attacker with your session can `su` to root with just a password.

```bash
sudo cp /etc/pam.d/su /etc/pam.d/su.bak
sudo cp /etc/pam.d/chsh /etc/pam.d/chsh.bak
sudo cp /etc/pam.d/chfn /etc/pam.d/chfn.bak

sudo tee /etc/pam.d/su > /dev/null << 'EOF'
#%PAM-1.0
auth       sufficient pam_rootok.so
auth       required   pam_u2f.so cue
@include common-account
session    required   pam_env.so readenv=1
session    required   pam_env.so readenv=1 envfile=/etc/default/locale
session    optional   pam_mail.so nopen
session    required   pam_limits.so
@include common-session
EOF

sudo tee /etc/pam.d/chsh > /dev/null << 'EOF'
#%PAM-1.0
auth       required   pam_shells.so
auth       sufficient pam_rootok.so
auth       required   pam_u2f.so cue
@include common-account
@include common-session
EOF

sudo tee /etc/pam.d/chfn > /dev/null << 'EOF'
#%PAM-1.0
auth       sufficient pam_rootok.so
auth       required   pam_u2f.so cue
@include common-account
@include common-session
EOF
```

`pam_rootok.so sufficient` means root can switch users without a challenge — intentional. All non-root users require FIDO2.

---

## Step 5: Emergency Recovery Path

**Do not remove or modify `/etc/pam.d/login`.** This is the TTY login config — accessible via `Ctrl+Alt+F2`. It uses password auth and is your recovery path if something goes wrong. Leave it untouched.

---

## Step 6: Sudoers — Trim NOPASSWD

Check your sudoers for overly broad NOPASSWD entries:

```bash
sudo cat /etc/sudoers.d/*
```

Common mistake — NOPASSWD on shell interpreters or file utilities bypasses PAM entirely:

```
# DANGEROUS — gives root shell with no auth
yourusername ALL=(ALL) NOPASSWD: /usr/bin/bash, /bin/sh, /usr/bin/cp, /usr/bin/rm, /usr/bin/tee
```

Safe NOPASSWD subset (for automation):
```
yourusername ALL=(ALL) NOPASSWD: /usr/bin/apt, /usr/bin/apt-get, /usr/bin/dpkg, /usr/bin/systemctl, /bin/systemctl, /usr/bin/restic, /usr/bin/tailscale, /usr/bin/journalctl
```

---

## Step 7: SSH Hardening

```bash
sudo tee /etc/ssh/sshd_config.d/hardening.conf > /dev/null << 'EOF'
PermitRootLogin no
PasswordAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
AuthenticationMethods publickey
PermitUserEnvironment no
MaxAuthTries 3
LoginGraceTime 20
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
GatewayPorts no
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers <yourusername>
ListenAddress <your-tailscale-ip>
EOF

# Validate config before reloading
sudo sshd -t && sudo systemctl reload ssh
```

Setting `ListenAddress` to your Tailscale IP means SSH only accepts connections over the encrypted mesh — not on the local network or public internet.

---

## Step 8: Firewall

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow in on tailscale0
sudo ufw --force enable
sudo ufw status verbose
```

All inbound traffic blocked except through the Tailscale interface.

---

## Step 9: Kernel Hardening (sysctl)

```bash
sudo tee /etc/sysctl.d/99-custom-hardening.conf > /dev/null << 'EOF'
# Disable ICMP redirect acceptance (prevent route hijacking)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Do not send ICMP redirects (not a router)
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Log packets with impossible source addresses
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
EOF

sudo sysctl --system
```

---

## Step 10: Audit Logging

```bash
sudo apt install auditd audispd-plugins

sudo tee /etc/audit/rules.d/hardening.rules > /dev/null << 'EOF'
# Changes to audit config itself
-w /etc/audit/ -p wa -k audit-config
-w /etc/audit/rules.d/ -p wa -k audit-config

# PAM, sudo, SSH config changes
-w /etc/pam.d/ -p wa -k pam-config
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers
-w /etc/ssh/sshd_config -p wa -k ssh-config
-w /etc/ssh/sshd_config.d/ -p wa -k ssh-config

# Identity file changes
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/gshadow -p wa -k identity

# Privileged command execution
-a always,exit -F path=/usr/bin/sudo -F perm=x -F auid>=1000 -F auid!=unset -k privileged-sudo
-a always,exit -F path=/bin/su -F perm=x -F auid>=1000 -F auid!=unset -k privileged-su

# Session tracking
-w /var/log/wtmp -p wa -k session
-w /var/log/btmp -p wa -k session
-w /var/run/utmp -p wa -k session

# Kernel module loading
-w /sbin/insmod -p x -k module-load
-w /sbin/modprobe -p x -k module-load
-w /sbin/rmmod -p x -k module-load

# Lock rules until reboot — must be last
-e 2
EOF

sudo systemctl enable --now auditd
sudo augenrules --load
```

Add `/var/log/audit` to your backup solution so logs go off-machine nightly.

---

## Step 11: Automatic Security Updates

```bash
sudo apt install unattended-upgrades

sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

sudo tee /etc/apt/apt.conf.d/50unattended-upgrades > /dev/null << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::DevRelease "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

sudo systemctl enable --now unattended-upgrades
```

---

## Troubleshooting

### `blob[0]=0x2e` — Key Not Found

The key has stale `pam://hostname` credentials from a previous setup.

```bash
ykman fido credentials list
ykman fido credentials delete <CRED_ID>
```

Re-register the key with `pamu2fcfg -n` after clearing.

### cosmic-greeter Freezes After Timeout

You have `sufficient` instead of `required`. With `sufficient`, after FIDO2 times out PAM falls through to `pam_unix` which sends a password conversation request that cosmic-greeter has no UI to handle — it hangs. Fix: change to `required` and remove `@include common-auth`.

### "Permissions 0664 are too open"

```bash
chmod 600 ~/.config/Yubico/u2f_keys
```

### Lock Screen Ignores Key

```bash
ls -la /dev/hidraw*
sudo setfacl -m u:$USER:rw /dev/hidraw*
```

### Locked Out Completely

Boot to TTY: `Ctrl+Alt+F2`. Log in with password (TTY uses `/etc/pam.d/login` which is untouched). Restore backups from `/etc/pam.d/*.bak`.

---

## File Reference

| File | Purpose |
|------|---------|
| `~/.config/Yubico/u2f_keys` | FIDO2 credentials — **single line per user** |
| `/etc/pam.d/cosmic-greeter` | Lock screen auth |
| `/etc/pam.d/sudo` | sudo auth |
| `/etc/pam.d/su` | su auth |
| `/etc/pam.d/chsh` | Shell change auth |
| `/etc/pam.d/chfn` | User info change auth |
| `/etc/pam.d/login` | TTY login — **leave untouched** (recovery path) |
| `/etc/ssh/sshd_config.d/hardening.conf` | SSH restrictions |
| `/etc/sysctl.d/99-custom-hardening.conf` | Kernel hardening |
| `/etc/audit/rules.d/hardening.rules` | Audit rules |
| `/etc/sudoers.d/<username>` | Per-user sudo rules |

---

## Hardware Notes

- **Long-tap vs tap**: On multi-configuration YubiKeys, short tap = credential slot 1, long tap = slot 2. Both work with FIDO2.
- **OTP disabled on slot 2**: Common on FIPS variants. Use FIDO2 for everything — it's more consistent and works across all slots.
- **Two keys, one line**: Register both keys, put both on the same line in `u2f_keys`. Test both before closing your backup session.

---

## Network Architecture

This PAM hardening is one layer of a full sovereign infrastructure stack.

```
                    ┌─────────────────────┐
                    │   AdGuard DNS       │
                    │   DNS filtering +   │
                    │   telemetry block   │
                    └──────────┬──────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
    ┌─────────▼──────┐ ┌───────▼──────┐ ┌──────▼───────┐
    │  Primary       │ │  Secondary   │ │   Mobile     │
    │  Machine       │ │  Machine     │ │  SSH Client  │
    │  Pop!_OS 24.04 │ │  Pop!_OS     │ │              │
    │  COSMIC        │ │              │ │              │
    └─────────┬──────┘ └───────┬──────┘ └──────┬───────┘
              │                │                │
              └────────────────┼────────────────┘
                               │
                    ┌──────────▼──────────┐
                    │     Tailscale       │
                    │  Encrypted Mesh VPN │
                    │  All devices        │
                    └─────────────────────┘
```

| Layer | Tool | Purpose |
|-------|------|---------|
| Authentication | FIDO2 Security Key | Hardware-enforced identity on all privilege paths |
| VPN Mesh | Tailscale | Encrypted tunnels, stable IPs across networks |
| DNS | AdGuard | Network-wide filtering, centralized control |
| Remote Access | SSH (pubkey-only, Tailscale-only) | Full terminal access from anywhere |
| OS | Pop!_OS 24.04 COSMIC | Both machines |

---

## License

MIT
