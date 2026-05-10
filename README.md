# YubiKey FIDO2 Linux Authentication

Configure YubiKey 5C NFC FIPS for passwordless `sudo` and lock screen on Pop!_OS (Debian/Ubuntu-based) using `pam_u2f.so`.

## What This Guide Solves

After spending hours debugging why my YubiKey worked for lock screen but not `sudo`, I found three issues that zero existing documentation covers:

1. **`u2f_keys` file format**: `pam_u2f` only reads the **first matching line** per user. Multiple lines = one key works, the other silently fails.
2. **Stale FIDO2 credentials**: When `pam_u2f` returns `blob[0]=0x2e`, the YubiKey has old credentials you can't see — `ykman fido credentials list` reveals them.
3. **Key 2 OTP disabled**: The second key on a YubiKey 5C NFC FIPS may have OTP disabled by default. Don't fight it — use FIDO2 for everything.

## Prerequisites

- YubiKey 5C NFC FIPS (or any FIDO2-capable YubiKey)
- Pop!_OS / Ubuntu / Debian
- `sudo` access

## Install Dependencies

```bash
sudo apt update
sudo apt install libpam-u2f pam-yubico yubikey-manager
```

## Lock Screen: FIDO2 (`pam_u2f.so`)

### 1. Register Credentials

Generate credentials for each key. `-n` = no PIN verification (touch-only, required for lock screen since the greeter can't prompt for PIN).

```bash
# Key 1
pamu2fcfg -n
# Hit Enter, touch key when LED blinks, copy output

# Key 2
pamu2fcfg -n
# Hit Enter, touch key, copy output
```

### 2. Create `u2f_keys` (CRITICAL: Single Line!)

Both credentials must be on **one line per user**. This is the bug zero guides mention.

```bash
mkdir -p ~/.config/Yubico

# Write as ONE LINE
# Format: username:keyhandle1,publickey1,es256,+presence:keyhandle2,publickey2,es256,+presence
cat > ~/.config/Yubico/u2f_keys << 'EOF'
rage:<KEY1_HANDLE>,<KEY1_PUBKEY>,es256,+presence:<KEY2_HANDLE>,<KEY2_PUBKEY>,es256,+presence
EOF

# Lock permissions — 0664 triggers warnings and can fail
chmod 600 ~/.config/Yubico/u2f_keys
```

**Wrong** (what most guides show):
```
rage:<KEY1_HANDLE>,<KEY1_PUBKEY>,es256,+presence
rage:<KEY2_HANDLE>,<KEY2_PUBKEY>,es256,+presence
```
`pam_u2f` reads line 1, matches user `rage`, stops. Key 2 never checked.

### 3. Update PAM for Lock Screen

```bash
# Remove any existing YubiKey config
sudo sed -i '/pam_yubico\|pam_u2f/d' /etc/pam.d/cosmic-greeter

# Add FIDO2 with touch cue
sudo sed -i '/@include common-auth/i auth sufficient pam_u2f.so cue' /etc/pam.d/cosmic-greeter
```

### 4. Fix HID Permissions

`cosmic-greeter` runs as your user — it needs access to YubiKey's HID interface.

```bash
# Add to group (needs re-login)
sudo usermod -aG plugdev $USER

# Immediate fix (active session)
sudo setfacl -m u:$USER:rw /dev/hidraw*
```

### 5. Test Lock Screen

Log out. Lock screen should show "Please touch the device." when you insert YubiKey.

Test **both keys**.

## Sudo: FIDO2 (Recommended)

If Key 2's OTP is disabled, FIDO2 is consistent and works for both lock screen + sudo.

```bash
# Remove old OTP config
sudo sed -i '/pam_yubico/d' /etc/pam.d/sudo

# Add FIDO2 — same u2f_keys file
sudo sed -i '/@include common-auth/i auth sufficient pam_u2f.so cue' /etc/pam.d/sudo
```

## Sudo: OTP (If Your Key Supports It)

If both keys have OTP enabled and you prefer OTP:

```bash
# Add to top of /etc/pam.d/sudo
auth sufficient pam_yubico.so id=<YUBICO_CLIENT_ID> key=<YUBICO_API_KEY> authfile=/etc/yubico/authorized_yubikeys
```

Create the authfile:
```bash
sudo mkdir -p /etc/yubico
echo "rage:cccccdeirbfc" | sudo tee /etc/yubico/authorized_yubikeys
echo "rage:cccccdehervg" | sudo tee -a /etc/yubico/authorized_yubikeys
```

## Troubleshooting

### "Key not found" / `blob[0]=0x2e`

The YubiKey has stale `pam://hostname` credentials that `pam_u2f` is trying and failing on.

```bash
# List all FIDO2 credentials on the key
ykman fido credentials list

# Delete old pam://hostname entries
ykman fido credentials delete <CRED_ID>
```

### "Permissions 0664 are too open"

```bash
chmod 600 ~/.config/Yubico/u2f_keys
```

### `ykman otp info` says "not enabled"

Key 2 has OTP disabled. Switch to FIDO2 for `sudo` (recommended) or enable OTP via YubiKey Manager GUI.

### Lock screen ignores YubiKey

Check HID access:
```bash
ls -la /dev/hidraw*
getfacl /dev/hidraw*
```

If you see `plugdev` group doesn't have write access, fix:
```bash
sudo setfacl -m u:$USER:rw /dev/hidraw*
```

## Files

| File | Purpose |
|------|---------|
| `~/.config/Yubico/u2f_keys` | FIDO2 credentials for `pam_u2f`. **Must be single line per user.** |
| `/etc/pam.d/cosmic-greeter` | Lock screen PAM config |
| `/etc/pam.d/sudo` | Sudo PAM config |
| `/etc/yubico/authorized_yubikeys` | OTP token IDs (if using yubico PAM) |

## Hardware Notes

- **YubiKey 5C NFC FIPS**: Two physical keys on one device (tap = Key 1, long-tap = Key 2)
- **Key 1**: Usually has OTP enabled by default
- **Key 2**: Usually has OTP disabled; only FIDO2/WebAuthn available
- **Solution**: Use FIDO2 for everything — consistent across both keys, no keyboard buffer injection issues

## Sovereign Network Architecture

This YubiKey setup is one layer of a broader sovereign infrastructure stack built on a fresh Pop!_OS 24.04 COSMIC install.

### Network Topology

```
                    ┌─────────────────────┐
                    │   AdGuard DNS        │
                    │   (Raider Hub)       │
                    │   DNS filtering +    │
                    │   telemetry blocking   │
                    └──────────┬──────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
    ┌─────────▼──────┐ ┌───────▼──────┐ ┌──────▼───────┐
    │  MSI Raider    │ │  Dell Lat    │ │   Phone      │
    │  GE78 HX       │ │  5430 Rugged │ │  Termius     │
    │  Pop!_OS 24.04 │ │  Pop!_OS     │ │  SSH Client  │
    │  COSMIC        │ │  Staging Node│ │              │
    └─────────┬──────┘ └───────┬──────┘ └──────┬───────┘
              │                │                │
              └────────────────┼────────────────┘
                               │
                    ┌──────────▼──────────┐
                    │     Tailscale        │
                    │  Encrypted Mesh VPN  │
                    │  All devices, always │
                    └─────────────────────┘
```

### Stack Components

| Layer | Tool | Purpose |
|-------|------|---------|
| Authentication | YubiKey 5C NFC FIPS | Hardware-enforced identity — `sudo` + lock screen |
| VPN Mesh | Tailscale | Encrypted tunnels between all devices, any network |
| DNS | AdGuard DNS (Raider) | Network-wide ad/telemetry blocking, centralized control |
| Remote Access | Termius (iOS/Android) | Full terminal access to Raider and Dell from anywhere |
| OS | Pop!_OS 24.04 COSMIC | Both laptops, clean Linux-native environment |
| Staging | Dell Latitude 5430 Rugged | Verification node, bidirectional SSH with Raider |

### Why This Matters

Every component is chosen for sovereignty. No cloud dependency, no third-party data capture, no trust assumptions you didn't make yourself.

- **Tailscale** gives every device a stable private IP that works across networks.
- **AdGuard DNS** on the Raider filters at the network level — before any device makes an external call.
- **YubiKey FIDO2** means the machines at the center require physical hardware presence to authenticate.
- **Termius** means the whole stack is accessible from your pocket.

### Access Patterns

```bash
# From phone — into Raider
ssh rage@raider.tail43dc9a.ts.net

# From phone — into Dell
ssh vrtxomega@pop-os.tail43dc9a.ts.net

# Raider ↔ Dell (bidirectional)
ssh vrtxomega@pop-os.tail43dc9a.ts.net
ssh rage@raider.tail43dc9a.ts.net

# DNS filtering active on all devices via AdGuard running on Raider
```

## License

MIT