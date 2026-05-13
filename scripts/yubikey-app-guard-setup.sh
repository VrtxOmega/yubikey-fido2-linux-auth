#!/usr/bin/env bash
# Setup script: YubiKey FIDO2 app guard
# Run with: sudo bash ~/yubikey-app-guard-setup.sh
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run with sudo: sudo bash $0" >&2
    exit 1
fi

REAL_USER="${SUDO_USER:?Run with sudo: sudo bash $0}"
USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

echo "[1/4] Installing pamtester and libnotify-bin..."
apt-get install -y --no-install-recommends pamtester libnotify-bin

echo "[2/4] Creating PAM service /etc/pam.d/yubikey-app-guard..."
cat > /etc/pam.d/yubikey-app-guard << 'EOF'
#%PAM-1.0
auth    required    pam_u2f.so cue
account required    pam_permit.so
EOF
chmod 644 /etc/pam.d/yubikey-app-guard

echo "[3/4] Creating guard script and app wrappers in /usr/local/bin/..."

cat > /usr/local/bin/yubikey-guard << 'EOF'
#!/usr/bin/env bash
# Requires FIDO2 YubiKey touch before launching an app.
# Usage: yubikey-guard /path/to/real-binary [args...]
set -euo pipefail

REAL_BIN="$1"; shift
APP_NAME=$(basename "$REAL_BIN")
CURRENT_USER=$(id -un)

_notify() {
    local urgency="$1" icon="$2" title="$3" body="$4"
    if command -v notify-send >/dev/null 2>&1; then
        notify-send --urgency="$urgency" --icon="$icon" --expire-time=15000 "$title" "$body"
    fi
}

_notify normal security-high "YubiKey Required" "Touch your key to open ${APP_NAME}"

if pamtester yubikey-app-guard "${CURRENT_USER}" authenticate 2>/dev/null; then
    exec "$REAL_BIN" "$@"
else
    _notify critical dialog-error "Access Denied" "YubiKey auth failed — ${APP_NAME} blocked"
    exit 1
fi
EOF
chmod 755 /usr/local/bin/yubikey-guard

cat > /usr/local/bin/firefox << 'EOF'
#!/usr/bin/env bash
exec /usr/local/bin/yubikey-guard /usr/bin/firefox "$@"
EOF
chmod 755 /usr/local/bin/firefox

cat > /usr/local/bin/cosmic-settings << 'EOF'
#!/usr/bin/env bash
exec /usr/local/bin/yubikey-guard /usr/bin/cosmic-settings "$@"
EOF
chmod 755 /usr/local/bin/cosmic-settings

cat > /usr/local/bin/cosmic-files << 'EOF'
#!/usr/bin/env bash
exec /usr/local/bin/yubikey-guard /usr/bin/cosmic-files "$@"
EOF
chmod 755 /usr/local/bin/cosmic-files

echo "[4/4] Patching user Firefox desktop entry (absolute path bypass fix)..."
FIREFOX_DESKTOP="${USER_HOME}/.local/share/applications/userapp-Firefox-6QUUO3.desktop"
if [[ -f "$FIREFOX_DESKTOP" ]]; then
    # Replace the absolute firefox-bin path with the guard wrapper
    sed -i 's|Exec=/usr/lib/firefox/firefox-bin|Exec=/usr/local/bin/yubikey-guard /usr/lib/firefox/firefox-bin|g' "$FIREFOX_DESKTOP"
    echo "    Patched: $FIREFOX_DESKTOP"
else
    echo "    Skipped: $FIREFOX_DESKTOP not found"
fi

echo ""
echo "Done. Verify:"
echo "  pamtester yubikey-app-guard \$(id -un) authenticate"
echo "  which firefox          # should show /usr/local/bin/firefox"
echo "  which cosmic-settings  # should show /usr/local/bin/cosmic-settings"
