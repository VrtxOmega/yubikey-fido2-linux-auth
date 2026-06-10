#!/bin/bash
# Shielded SSH + FIDO2 mesh health check (no secret values printed).
set -euo pipefail

USER_NAME="${1:-$(id -un)}"
USER_HOME="$(getent passwd "${USER_NAME}" | cut -d: -f6)"
U2F_KEYS="${USER_HOME}/.config/Yubico/u2f_keys"

echo "=== Mesh SSH / FIDO2 doctor (${USER_NAME}@$(hostname)) ==="

for dropin in /etc/ssh/sshd_config.d/99-mesh-ssh.conf \
  /etc/ssh/sshd_config.d/99-yubikey-u2f.conf; do
  if [[ -f "$dropin" ]]; then
    echo "sshd drop-in: $dropin"
    sed 's/^/  /' "$dropin"
  fi
done

if grep -q 'pam_u2f.so' /etc/pam.d/sshd 2>/dev/null; then
  echo "pam sshd: pam_u2f PRESENT (mesh inbound should remove this)"
else
  echo "pam sshd: pam_u2f absent (good for mesh inbound pubkey-only)"
fi

if [[ -s "$U2F_KEYS" ]]; then
  count="$(grep -vc '^#\|^$' "$U2F_KEYS" 2>/dev/null || echo 0)"
  echo "u2f_keys: present (${count} active line(s))"
else
  echo "u2f_keys: MISSING — run pamu2fcfg -n"
fi

if [[ -x "${USER_HOME}/bin/mesh-ssh" ]]; then
  echo "outbound guard: ${USER_HOME}/bin/mesh-ssh"
else
  echo "outbound guard: not installed — bash scripts/mesh-install-outbound-ssh.sh"
fi

if grep -q 'Mesh SSH: outbound' "${USER_HOME}/.bashrc" 2>/dev/null; then
  echo "bashrc ssh() wrapper: present"
else
  echo "bashrc ssh() wrapper: missing"
fi

if [[ -f /etc/pam.d/yubikey-app-guard ]]; then
  echo "yubikey-app-guard PAM: present"
else
  echo "yubikey-app-guard PAM: missing — run yubikey-app-guard-setup.sh"
fi

echo ""
echo "Expected: outbound touch on THIS host; inbound pubkey for Tailscale/LAN peers."