#!/bin/bash
# Restores the original Yaru GDM theme and removes glassmorphic files.
# Usage: sudo ./uninstall.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run as root: sudo ./uninstall.sh" >&2
    exit 1
fi

INSTALL_THEME_DIR="/usr/share/gnome-shell/theme/Yaru-Glassmorphic"

# ---- Restore original alternative -------------------------------------------
ORIGINAL=$(update-alternatives --list gdm-theme.gresource 2>/dev/null | \
    grep -v Glassmorphic | head -1)

if [[ -n "$ORIGINAL" ]]; then
    echo "Restoring original theme: $ORIGINAL"
    update-alternatives --set gdm-theme.gresource "$ORIGINAL"
else
    # Fallback: restore from backup
    BACKUP=$(find /usr/share/gnome-shell/theme/Yaru -name "*.gresource.bak" 2>/dev/null | head -1)
    if [[ -n "$BACKUP" ]]; then
        ORIG="${BACKUP%.bak}"
        echo "Restoring from backup: $BACKUP"
        cp "$BACKUP" "$ORIG"
        update-alternatives --set gdm-theme.gresource "$ORIG" || true
    else
        echo "WARNING: No original theme found to restore." >&2
    fi
fi

# ---- Remove installed files -------------------------------------------------
echo "Removing alternative registration ..."
update-alternatives --remove gdm-theme.gresource \
    "$INSTALL_THEME_DIR/gnome-shell-theme.gresource" 2>/dev/null || true

echo "Removing $INSTALL_THEME_DIR ..."
rm -rf "$INSTALL_THEME_DIR"

echo "Removing /usr/local/bin/update-gdm-wallpaper ..."
rm -f /usr/local/bin/update-gdm-wallpaper

# Remove PostLogin hook
POSTLOGIN="/etc/gdm3/PostLogin/Default"
if [[ -f "$POSTLOGIN" ]]; then
    echo "Removing PostLogin wallpaper hook ..."
    sed -i '/# --- glassmorphic wallpaper sync ---/,/^$/d' "$POSTLOGIN"
fi

# Restore greeter dconf defaults
echo "Restoring /etc/gdm3/greeter.dconf-defaults ..."
cat > /etc/gdm3/greeter.dconf-defaults <<'EOF'
# These are the options for the greeter session that can be set
# through GSettings. Any GSettings setting that is used by the
# greeter session can be set here.

[org/gnome/desktop/interface]
# gtk-theme='Adwaita'
[org/gnome/desktop/background]
# picture-uri='file:///usr/share/themes/Adwaita/backgrounds/stripes.jpg'
# picture-options='zoom'
[org/gnome/login-screen]
# logo='/usr/share/images/vendor-logos/logo-text-version-64.png'
EOF

dconf update

echo ""
echo "  Uninstall complete. Restart GDM to apply:"
echo "    sudo systemctl restart gdm3"
echo ""
