<div align="center">
  <img src="https://raw.githubusercontent.com/VrtxOmega/Gravity-Omega/master/omega_icon.png" width="120" alt="VERITAS Omega" />
  <h1>FIDO2 SOVEREIGN AUTH</h1>
  <p><strong>Hardware-Enforced Authentication · Zero Password Fallback · Full Privilege Path Coverage · Pop!_OS COSMIC</strong></p>
</div>

<div align="center">

![Status](https://img.shields.io/badge/Status-ACTIVE-success?style=flat-square&labelColor=000000&color=d4af37)
![Version](https://img.shields.io/badge/Version-v1.0.0-blue?style=flat-square&labelColor=000000)
![Platform](https://img.shields.io/badge/Platform-Pop!__OS%2024.04-informational?style=flat-square&labelColor=000000)
![Auth](https://img.shields.io/badge/Auth-FIDO2%20Only-d4af37?style=flat-square&labelColor=000000)
![License](https://img.shields.io/badge/License-MIT-green?style=flat-square&labelColor=000000)

</div>

---

## Ecosystem Canon

FIDO2 Sovereign Auth is the physical identity layer of the **VERITAS & Sovereign Ecosystem (Omega Universe)**. Every privilege escalation path — lock screen, sudo, su, shell change, user info change — requires physical hardware presence. No password fallback exists anywhere in the stack. A stolen session, a leaked credential, a remote exploit: none of them are enough. The attacker must hold the physical key.

This is not two-factor authentication. This is **hardware-gated access**. The password is not the second factor — it has been removed entirely.

> **SYSTEM INVARIANT:** Authentication does not succeed without physical key presence. No timeout, no fallback, no exception.

---

## What This Guide Solves

After debugging FIDO2 failures that no existing documentation explains, three critical issues were identified:

1. **`u2f_keys` single-line bug**: `pam_u2f` only reads the **first matching line** per user. Two lines = second key silently fails. Both keys must be on one line.
2. **`sufficient` freezes cosmic-greeter**: Using `sufficient` causes cosmic-greeter to **hang** after FIDO2 timeout — it falls through to `pam_unix` and receives a password conversation request it has no UI to handle. The fix is `required` with `@include common-auth` removed entirely.
3. **Stale FIDO2 credentials**: `blob[0]=0x2e` means the key has old `pam://hostname` entries. `ykman fido credentials list` reveals them.

No other guide covers the cosmic-greeter freeze, the single-line bug, or hardening every PAM service end to end.

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

- **`sufficient`**: If FIDO2 succeeds, skip the rest. If it times out or fails, fall through to `pam_unix` (password). cosmic-greeter **freezes** after the timeout because it receives a `pam_unix` password conversation request it has no UI to handle.
- **`required`**: FIDO2 must succeed. No fallback, no freeze.

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

These are the overlooked paths. Without hardening, an attacker with your session can `su` to root with just a password.

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

`pam_rootok.so sufficient` exempts root — intentional. All non-root users require FIDO2.

---

## Step 5: Emergency Recovery Path

**Do not modify `/etc/pam.d/login`.** This is TTY login — accessible via `Ctrl+Alt+F2`. It is the recovery path if something goes wrong. Leave it untouched.

---

## Step 6: Sudoers — Trim NOPASSWD

NOPASSWD entries bypass PAM entirely. A broad NOPASSWD list destroys everything above.

```bash
sudo cat /etc/sudoers.d/*
```

**Dangerous** — gives root shell with zero auth:
```
yourusername ALL=(ALL) NOPASSWD: /usr/bin/bash, /bin/sh, /usr/bin/cp, /usr/bin/rm, /usr/bin/tee, /usr/bin/curl
```

**Safe subset** for automation only:
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

sudo sshd -t && sudo systemctl reload ssh
```

`ListenAddress` set to Tailscale IP — SSH only accepts connections over the encrypted mesh.

---

## Step 8: Firewall

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow in on tailscale0
sudo ufw --force enable
sudo ufw status verbose
```

---

## Step 9: Kernel Hardening

```bash
sudo tee /etc/sysctl.d/99-custom-hardening.conf > /dev/null << 'EOF'
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
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
-w /etc/audit/ -p wa -k audit-config
-w /etc/audit/rules.d/ -p wa -k audit-config
-w /etc/pam.d/ -p wa -k pam-config
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers
-w /etc/ssh/sshd_config -p wa -k ssh-config
-w /etc/ssh/sshd_config.d/ -p wa -k ssh-config
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/gshadow -p wa -k identity
-a always,exit -F path=/usr/bin/sudo -F perm=x -F auid>=1000 -F auid!=unset -k privileged-sudo
-a always,exit -F path=/bin/su -F perm=x -F auid>=1000 -F auid!=unset -k privileged-su
-w /var/log/wtmp -p wa -k session
-w /var/log/btmp -p wa -k session
-w /var/run/utmp -p wa -k session
-w /sbin/insmod -p x -k module-load
-w /sbin/modprobe -p x -k module-load
-w /sbin/rmmod -p x -k module-load
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

Stale `pam://hostname` credentials on the key.

```bash
ykman fido credentials list
ykman fido credentials delete <CRED_ID>
```

Re-register with `pamu2fcfg -n` after clearing.

### cosmic-greeter Freezes After Timeout

You have `sufficient` instead of `required`. Change to `required` and remove `@include common-auth`.

### "Permissions 0664 are too open"

```bash
chmod 600 ~/.config/Yubico/u2f_keys
```

### Lock Screen Ignores Key

```bash
sudo setfacl -m u:$USER:rw /dev/hidraw*
```

### Locked Out Completely

`Ctrl+Alt+F2` → TTY login with password → restore from `/etc/pam.d/*.bak`.

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

- **Long-tap vs tap**: On multi-configuration keys, short tap = slot 1, long tap = slot 2. Both work with FIDO2.
- **OTP disabled on slot 2**: Common on FIPS variants. Use FIDO2 for everything — consistent across all slots.
- **Two keys, one line**: Register both, put both on the same line in `u2f_keys`. Test both before closing your backup session.

---

## Sovereign Stack

FIDO2 Sovereign Auth is the physical identity layer of the Omega Universe. No component of this stack trusts software alone.

```
                    ┌─────────────────────┐
                    │   Ω  AdGuard DNS    │
                    │   DNS filtering +   │
                    │   telemetry block   │
                    └──────────┬──────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
    ┌─────────▼──────┐ ┌───────▼──────┐ ┌──────▼───────┐
    │  Ω  Primary    │ │  Ω Secondary │ │  Ω  Mobile   │
    │  Pop!_OS 24.04 │ │  Pop!_OS     │ │  SSH Client  │
    │  COSMIC        │ │              │ │              │
    └─────────┬──────┘ └───────┬──────┘ └──────┬───────┘
              │                │                │
              └────────────────┼────────────────┘
                               │
                    ┌──────────▼──────────┐
                    │   Ω   Tailscale     │
                    │  Encrypted Mesh VPN │
                    │  All devices        │
                    └─────────────────────┘
```

| Layer | Tool | Purpose |
|-------|------|---------|
| **Identity** | FIDO2 Security Key | Hardware-enforced presence on all privilege paths |
| **Network** | Tailscale | Encrypted mesh, stable IPs across all networks |
| **DNS** | AdGuard | Network-wide filtering, centralized control |
| **Remote Access** | SSH (pubkey-only, Tailscale-only) | Full terminal access from anywhere |
| **OS** | Pop!_OS 24.04 COSMIC | Sovereign baseline on all machines |

---

<div align="center">
  <img src="https://raw.githubusercontent.com/VrtxOmega/Gravity-Omega/master/omega_icon.png" width="48" alt="Ω" />
  <br/>
  <sub>Part of the <strong>VERITAS & Sovereign Ecosystem</strong> · Omega Universe</sub>
</div>

---

## License

MIT
