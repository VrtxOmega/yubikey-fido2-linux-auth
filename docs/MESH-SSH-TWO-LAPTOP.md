# Two-Laptop Mesh SSH with FIDO2

**Added 2026-06-10** — policy for a Tailscale mesh with one YubiKey per laptop (e.g. primary + secondary Pop!_OS machines).

## The problem we hit

Early setups used **inbound** `pam_u2f` on `sshd`: after your SSH public key was accepted, the **remote** server demanded a YubiKey touch via `keyboard-interactive`.

That fails in real life:

- SSH from laptop A → laptop B runs `pam_u2f` on **B**
- The key must be **plugged into B** at that moment
- If you are traveling with only laptop A, you cannot touch B's key

**OTP vs FIDO2:** Legacy YubiKey OTP slots conflict with FIDO2 provisioning. This guide uses **FIDO2/U2F only** (`pam_u2f`, `pamu2fcfg`), not OTP (`pam_yubico`).

## The model that works

Split auth into two layers:

| Direction | Where YubiKey is touched | What is checked |
|-----------|--------------------------|-----------------|
| **Outbound (client)** | The machine you are sitting at | Local `pam_u2f` via `mesh-ssh` wrapper before `ssh` runs |
| **Inbound (server)** | N/A for mesh peers | Tailscale/LAN source → **SSH public key only** |
| **Local privilege** | Same machine | `sudo`, greeter, `su` — unchanged FIDO2 `required` |

```
  [ Laptop A ]  --touch key on A-->  mesh-ssh  --SSH key-->  [ Laptop B ]
                     outbound                         inbound: pubkey only
```

Network gate: UFW allows SSH only on `tailscale0` (or equivalent). Untrusted networks never reach `sshd`.

## Scripts in this repo

| Script | Run on | Purpose |
|--------|--------|---------|
| `scripts/mesh-ssh-outbound-guard` | each laptop (user `bin/`) | Touch local key before mesh `ssh` |
| `scripts/mesh-install-outbound-ssh.sh` | each laptop | Install guard + `ssh()` in `.bashrc` |
| `scripts/mesh-sshd-inbound-tailnet-pubkey.sh` | each laptop (`sudo`) | Inbound: pubkey only; strip `pam_u2f` from `sshd` |
| `scripts/mesh-ssh-yubikey-doctor.sh` | either | Shielded health check (no secrets printed) |

Requires `scripts/yubikey-app-guard-setup.sh` first (creates `/etc/pam.d/yubikey-app-guard` used by outbound guard).

## Quick setup (both laptops)

On **each** machine, as the normal user:

```bash
# 1. App guard PAM service (once, sudo)
sudo bash scripts/yubikey-app-guard-setup.sh

# 2. Register this machine's key (touch when prompted)
pamu2fcfg -n | tee -a ~/.config/Yubico/u2f_keys
chmod 600 ~/.config/Yubico/u2f_keys

# 3. Outbound guard
cp scripts/mesh-ssh-outbound-guard ~/bin/mesh-ssh
chmod +x ~/bin/mesh-ssh
bash scripts/mesh-install-outbound-ssh.sh

# 4. Inbound policy (sudo)
sudo bash scripts/mesh-sshd-inbound-tailnet-pubkey.sh
```

Add `Host` aliases in `~/.ssh/config` on each side (names only — no secrets):

```
Host peer-laptop
  HostName <tailscale-or-lan-ip>
  User <remote-username>
  IdentityFile ~/.ssh/id_ed25519_mesh
```

## Expected behavior

```bash
ssh peer-laptop
```

1. `Touch YubiKey on <this-host> to SSH → peer-laptop` — local outbound guard
2. Logged in — **no** remote touch, **no** password

Automation (cron, agents):

```bash
MESH_SSH_NO_GUARD=1 ssh -o BatchMode=yes peer-laptop ...
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Second touch or password on remote | Inbound still has `pam_u2f` / old drop-in | `sudo bash scripts/mesh-sshd-inbound-tailnet-pubkey.sh` |
| `Please touch device` on **remote** | Same — server-side kbd-int | Remove `98-yubikey-u2f.conf` / `pam_u2f` from `/etc/pam.d/sshd` |
| No local touch outbound | `mesh-ssh` not in `.bashrc` | `bash scripts/mesh-install-outbound-ssh.sh` |
| `errno 2` / `ssh-askpass` in IDE | No TTY in non-interactive terminal | Use a real terminal, or `apt install ssh-askpass` |
| `Pseudo-terminal will not be allocated` piping to `ssh -t` | stdin redirect breaks `-t` | `scp` script to peer, run there with `sudo bash` |

Run `bash scripts/mesh-ssh-yubikey-doctor.sh` on each host.

## Optional: FIDO-backed SSH keys

For touch-during-handshake (no separate `pamtester` step):

```bash
ssh-keygen -t ed25519-sk -O resident -O verify-required -f ~/.ssh/id_mesh_sk -C "$(whoami)@$(hostname)-mesh"
```

Add pubkey to peer `authorized_keys`. Point `IdentityFile` at the `-sk` key in `~/.ssh/config`.

## Related work (same day, out of repo)

- Mesh security scripts under personal `~/bin/` (pentest, UFW, sudoers tighten)
- Sovereign Secret Manager `consolidate` command — one unlock, batch import (not per-secret `set` loops)
- Omega agent gate policy export

None of those belong in this repo; they are environment-specific.