#!/bin/bash
# Inbound SSH for mesh laptops: Tailscale/LAN peers use pubkey only.
# Outbound FIDO2 touch is enforced on the client (mesh-ssh-outbound-guard).
# Run: sudo bash mesh-sshd-inbound-tailnet-pubkey.sh
set -euo pipefail

[[ "${EUID}" -eq 0 ]] || { echo "Run with sudo"; exit 1; }

echo "==> Host: $(hostname) — mesh inbound SSH (pubkey only)"

rm -f /etc/ssh/sshd_config.d/98-yubikey-u2f.conf
rm -f /etc/ssh/sshd_config.d/99-yubikey-u2f.conf

for f in /etc/ssh/sshd_config.d/hardening.conf /etc/ssh/sshd_config.d/99-mesh-hardening.conf; do
  [[ -f "$f" ]] || continue
  cp -a "$f" "${f}.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
  sed -i '/^AuthenticationMethods /d;/^KbdInteractiveAuthentication /d;/^ChallengeResponseAuthentication /d' "$f"
done

cat >/etc/ssh/sshd_config.d/99-mesh-ssh.conf <<'EOF'
# Mesh inbound: SSH public key only for tailnet/LAN peers.
# FIDO2 touch for SSH is outbound on the client (mesh-ssh wrapper).
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
EOF
chmod 644 /etc/ssh/sshd_config.d/99-mesh-ssh.conf

PAM=/etc/pam.d/sshd
if grep -q 'pam_u2f.so' "$PAM"; then
  cp -a "$PAM" "${PAM}.bak.$(date +%Y%m%d-%H%M%S)"
  sed -i '/pam_u2f.so/d' "$PAM"
  echo "==> Removed pam_u2f from sshd PAM (sudo/greeter still use FIDO2)"
fi

sshd_out="$(sshd -t 2>&1)" || {
  if grep -q 'Unsupported option UsePAM' <<<"$sshd_out" \
    && ! grep -v 'Unsupported option UsePAM' <<<"$sshd_out" | grep -q .; then
    echo "[WARN] UsePAM deprecation only — continuing (Pop!_OS quirk)"
  else
    echo "$sshd_out"
    exit 1
  fi
}

systemctl reload ssh 2>/dev/null || systemctl reload sshd
echo "OK: inbound SSH is pubkey-only. Reload outbound guard on this host if needed."