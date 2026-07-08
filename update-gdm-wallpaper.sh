#!/bin/bash
# update-gdm-wallpaper
# Syncs the current desktop wallpaper to the GDM login screen background,
# creating a pre-blurred version for the glassmorphic effect.
#
# Usage: sudo update-gdm-wallpaper [username]
#   username  - optional; defaults to the user of the active graphical session
#
# Environment variables:
#   GDM_BLUR_RADIUS   - ImageMagick blur radius sigma (default: 22)
#   GDM_BRIGHTNESS    - Brightness offset, negative = darker (default: -18)

set -euo pipefail

GDM_BG_DIR="/usr/share/backgrounds/gdm"
GDM_BG_ORIGINAL="$GDM_BG_DIR/current-wallpaper.jpg"
GDM_BG_BLURRED="$GDM_BG_DIR/current-wallpaper-blurred.jpg"
DCONF_FILE="/etc/gdm3/greeter.dconf-defaults"

BLUR_RADIUS="${GDM_BLUR_RADIUS:-8}"
BRIGHTNESS="${GDM_BRIGHTNESS:--10}"

# ---- Determine target user -----------------------------------------------
if [[ -n "${1:-}" ]]; then
    TARGET_USER="$1"
elif [[ -n "${SUDO_USER:-}" ]]; then
    TARGET_USER="$SUDO_USER"
else
    TARGET_USER=$(who | awk '$2 ~ /^:[0-9]/' | awk '{print $1}' | head -1)
    [[ -z "$TARGET_USER" ]] && TARGET_USER=$(who | awk '{print $1}' | head -1)
fi

if [[ -z "$TARGET_USER" ]]; then
    echo "ERROR: Cannot determine current user. Pass the username as argument." >&2
    exit 1
fi

USER_ID=$(id -u "$TARGET_USER" 2>/dev/null) || {
    echo "ERROR: User '$TARGET_USER' not found." >&2
    exit 1
}

echo "[update-gdm-wallpaper] User: $TARGET_USER (uid $USER_ID)"

# ---- Get wallpaper path -------------------------------------------------------
# Priority order:
#   1. swww query  (Hyprland/swww — most accurate, reflects live state)
#   2. awww query  (alternative swww fork)
#   3. hyprpaper config  (static hyprpaper wallpaper)
#   4. rofi .current_wallpaper symlink  (set by WallpaperSelect.sh)
#   5. hypr wallpaper_effects file
#   6. gsettings (GNOME sessions)
#   7. first file in ~/Pictures/wallpapers
#   8. first system background

USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
WALLPAPER_PATH=""

# 1. swww / awww query — returns "MONITOR: WxH ... image: /path/to/file"
for ww_cmd in swww awww; do
    if command -v "$ww_cmd" &>/dev/null; then
        _path=$(sudo -u "$TARGET_USER" \
            WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-1}" \
            XDG_RUNTIME_DIR="/run/user/${USER_ID}" \
            "$ww_cmd" query 2>/dev/null \
            | grep -oP "(?<=image: ).*" | head -1)
        if [[ -n "$_path" && -f "$_path" ]]; then
            WALLPAPER_PATH="$_path"
            echo "[update-gdm-wallpaper] Source via ${ww_cmd} query: $WALLPAPER_PATH"
            break
        fi
    fi
done

# 2. hyprpaper config — "wallpaper = MONITOR,/path"
if [[ -z "$WALLPAPER_PATH" ]] && [[ -f "$USER_HOME/.config/hypr/hyprpaper.conf" ]]; then
    _path=$(grep -oP "(?<=wallpaper\s=\s)[^,]+,\K.*" \
        "$USER_HOME/.config/hypr/hyprpaper.conf" 2>/dev/null | head -1)
    [[ -n "$_path" && -f "$_path" ]] && WALLPAPER_PATH="$_path" && \
        echo "[update-gdm-wallpaper] Source via hyprpaper.conf: $WALLPAPER_PATH"
fi

# 3. rofi .current_wallpaper symlink
if [[ -z "$WALLPAPER_PATH" ]]; then
    _link="$USER_HOME/.config/rofi/.current_wallpaper"
    if [[ -L "$_link" ]]; then
        _path=$(readlink -f "$_link" 2>/dev/null)
        [[ -n "$_path" && -f "$_path" ]] && WALLPAPER_PATH="$_path" && \
            echo "[update-gdm-wallpaper] Source via rofi symlink: $WALLPAPER_PATH"
    fi
fi

# 4. hypr wallpaper_effects/.wallpaper_current (plain-text path file)
if [[ -z "$WALLPAPER_PATH" ]]; then
    _wf="$USER_HOME/.config/hypr/wallpaper_effects/.wallpaper_current"
    if [[ -f "$_wf" ]]; then
        _path=$(strings "$_wf" 2>/dev/null | grep -E "^/" | grep -E "\.(jpg|jpeg|png|webp)$" | head -1)
        [[ -n "$_path" && -f "$_path" ]] && WALLPAPER_PATH="$_path" && \
            echo "[update-gdm-wallpaper] Source via wallpaper_effects file: $WALLPAPER_PATH"
    fi
fi

# 5. gsettings (GNOME / fallback)
if [[ -z "$WALLPAPER_PATH" ]]; then
    DBUS="unix:path=/run/user/${USER_ID}/bus"
    for key in picture-uri picture-uri-dark; do
        _path=$(sudo -u "$TARGET_USER" \
            DBUS_SESSION_BUS_ADDRESS="$DBUS" \
            gsettings get org.gnome.desktop.background "$key" 2>/dev/null \
            | tr -d "'" | sed 's|file://||')
        if [[ -n "$_path" && -f "$_path" ]]; then
            WALLPAPER_PATH="$_path"
            echo "[update-gdm-wallpaper] Source via gsettings ($key): $WALLPAPER_PATH"
            break
        fi
    done
fi

# 6. ~/Pictures/wallpapers
if [[ -z "$WALLPAPER_PATH" ]]; then
    _path=$(find "$USER_HOME/Pictures/wallpapers" -maxdepth 3 \
        \( -name "*.jpg" -o -name "*.jpeg" -o -name "*.png" -o -name "*.webp" \) \
        2>/dev/null | head -1)
    [[ -n "$_path" && -f "$_path" ]] && WALLPAPER_PATH="$_path" && \
        echo "[update-gdm-wallpaper] Source via ~/Pictures/wallpapers: $WALLPAPER_PATH"
fi

# 7. System backgrounds
if [[ -z "$WALLPAPER_PATH" ]]; then
    echo "WARNING: No user wallpaper found. Falling back to system backgrounds." >&2
    WALLPAPER_PATH=$(find /usr/share/backgrounds -maxdepth 3 \
        \( -name "*.jpg" -o -name "*.png" -o -name "*.jpeg" \) \
        -not -path "*/gdm/*" 2>/dev/null | head -1)
fi

if [[ -z "$WALLPAPER_PATH" || ! -f "$WALLPAPER_PATH" ]]; then
    echo "ERROR: No wallpaper found. Run:  sudo update-gdm-wallpaper  or pass the path as argument." >&2
    exit 1
fi

echo "[update-gdm-wallpaper] Source: $WALLPAPER_PATH"

# ---- Prepare destination -------------------------------------------------
mkdir -p "$GDM_BG_DIR"

if command -v convert &>/dev/null; then
    echo "[update-gdm-wallpaper] Copying original..."
    convert "$WALLPAPER_PATH" -quality 95 "$GDM_BG_ORIGINAL"

    echo "[update-gdm-wallpaper] Creating blurred version (sigma=$BLUR_RADIUS, brightness=$BRIGHTNESS)..."
    convert "$WALLPAPER_PATH" \
        -filter Gaussian \
        -blur 0x"${BLUR_RADIUS}" \
        -brightness-contrast "${BRIGHTNESS}x5" \
        -quality 90 \
        "$GDM_BG_BLURRED"
    USE_BG="$GDM_BG_BLURRED"
else
    echo "WARNING: ImageMagick not found — using unblurred wallpaper." >&2
    cp "$WALLPAPER_PATH" "$GDM_BG_ORIGINAL"
    cp "$WALLPAPER_PATH" "$GDM_BG_BLURRED"
    USE_BG="$GDM_BG_ORIGINAL"
fi

echo "[update-gdm-wallpaper] GDM background: $USE_BG"

# ---- Write greeter dconf settings ----------------------------------------
# Path 1: /etc/gdm3/greeter.dconf-defaults
#   Symlinked as /usr/share/gdm/dconf/90-debian-settings → compiled by
#   generate-config at GDM start into /var/lib/gdm3/greeter-dconf-defaults.
cat > "$DCONF_FILE" <<EOF
# GDM greeter dconf overrides
# Managed by update-gdm-wallpaper — do not edit manually.
# Re-run:  sudo update-gdm-wallpaper

[org/gnome/desktop/background]
picture-uri='file://${USE_BG}'
picture-uri-dark='file://${USE_BG}'
picture-options='zoom'

[org/gnome/desktop/interface]
color-scheme='prefer-dark'
EOF
echo "[update-gdm-wallpaper] Updated $DCONF_FILE"

# Path 2: /etc/dconf/db/gdm.d/ — the system-db for the gdm dconf profile.
# This takes effect immediately after dconf update without a GDM restart.
DCONF_SYSDB_DIR="/etc/dconf/db/gdm.d"
mkdir -p "$DCONF_SYSDB_DIR"
cat > "$DCONF_SYSDB_DIR/00-gdm-glassmorphic" <<EOF
[org/gnome/desktop/background]
picture-uri='file://${USE_BG}'
picture-uri-dark='file://${USE_BG}'
picture-options='zoom'

[org/gnome/desktop/interface]
color-scheme='prefer-dark'
EOF

# Ensure the dconf profile for the gdm user exists
DCONF_PROFILE_GDM="/etc/dconf/profile/gdm"
if [[ ! -f "$DCONF_PROFILE_GDM" ]]; then
    cat > "$DCONF_PROFILE_GDM" <<'PROFILE'
user-db:user
system-db:gdm
file-db:/var/lib/gdm3/greeter-dconf-defaults
PROFILE
    echo "[update-gdm-wallpaper] Created dconf profile: $DCONF_PROFILE_GDM"
fi

# ---- Apply dconf database ------------------------------------------------
dconf update && echo "[update-gdm-wallpaper] dconf database updated."

echo ""
echo "  GDM wallpaper synced successfully!"
echo "   Source  : $WALLPAPER_PATH"
echo "   GDM bg  : $USE_BG"
echo ""
echo "   Restart GDM to apply: sudo systemctl restart gdm3"
