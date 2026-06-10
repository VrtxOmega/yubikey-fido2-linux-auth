#!/bin/bash
# Install outbound mesh SSH guard (local FIDO2 touch before ssh to mesh peers).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${HOME}/bin"
mkdir -p "$BIN"

install -m 755 "${SCRIPT_DIR}/mesh-ssh-outbound-guard" "${BIN}/mesh-ssh"

MARKER='# Mesh SSH: outbound FIDO2 touch on THIS machine'
if ! grep -qF "$MARKER" "${HOME}/.bashrc" 2>/dev/null; then
  cat >>"${HOME}/.bashrc" <<EOF

${MARKER}
ssh() { command ${BIN}/mesh-ssh "\$@"; }
EOF
  echo "Added ssh() guard to ${HOME}/.bashrc"
else
  echo "bashrc guard already present"
fi

echo ""
echo "Outbound SSH guard installed on $(hostname)."
echo "  Interactive: ssh <peer-host>  → touch key HERE, then connect"
echo "  Automation:  MESH_SSH_NO_GUARD=1 ssh -o BatchMode=yes <peer-host> ..."
echo ""
echo "Run on each mesh laptop. Then: sudo bash scripts/mesh-sshd-inbound-tailnet-pubkey.sh"