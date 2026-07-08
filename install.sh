#!/bin/bash
# gdm-glassmorphic install.sh
# Installs the glassmorphic GDM login screen theme and wallpaper sync tools.
#
# MUST be run as root:  sudo ./install.sh
#
# What it does:
#   1. Backs up the current Yaru GDM gresource
#   2. Extracts all CSS and SVG assets from the gresource
#   3. Appends glassmorphic CSS overrides to every Yaru CSS variant
#   4. Recompiles a new gresource and installs it as "Yaru-Glassmorphic"
#   5. Registers it with update-alternatives and sets it active
#   6. Installs update-gdm-wallpaper to /usr/local/bin
#   7. Installs a PostLogin hook so the wallpaper syncs on every login
#   8. Runs the first wallpaper sync immediately

set -euo pipefail

# ---- Privilege check -------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root. Use: sudo ./install.sh" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERRIDES_CSS="$SCRIPT_DIR/glassmorphic-overrides.css"
WALLPAPER_SCRIPT="$SCRIPT_DIR/update-gdm-wallpaper.sh"

THEME_NAME="Yaru-Glassmorphic"
INSTALL_THEME_DIR="/usr/share/gnome-shell/theme/$THEME_NAME"
BUILD_DIR="$(mktemp -d /tmp/gdm-glassmorphic-XXXXXX)"

# Always source from the ORIGINAL Yaru gresource — never from our own
# Glassmorphic build, which would double-apply overrides on re-runs.
ORIGINAL_YARU="/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource"
if [[ ! -f "$ORIGINAL_YARU" ]]; then
    # Fallback: find any non-Glassmorphic registered alternative
    ORIGINAL_YARU=$(update-alternatives --list gdm-theme.gresource 2>/dev/null \
        | grep -v Glassmorphic | grep Yaru | head -1)
fi
if [[ -z "$ORIGINAL_YARU" || ! -f "$ORIGINAL_YARU" ]]; then
    echo "ERROR: Cannot locate the original Yaru gresource." >&2
    exit 1
fi
SOURCE_GRESOURCE="$ORIGINAL_YARU"
BACKUP_PATH="$ORIGINAL_YARU.bak"

echo "============================================="
echo "  GDM Glassmorphic Setup"
echo "============================================="
echo "  Source gresource : $SOURCE_GRESOURCE"
echo "  Build dir        : $BUILD_DIR"
echo "  Install dir      : $INSTALL_THEME_DIR"
echo ""

# ---- 1. Backup --------------------------------------------------------------
if [[ ! -f "$BACKUP_PATH" ]]; then
    echo "[1/8] Backing up original Yaru gresource to $BACKUP_PATH ..."
    cp "$SOURCE_GRESOURCE" "$BACKUP_PATH"
else
    echo "[1/8] Backup already exists at $BACKUP_PATH — skipping."
fi

# ---- 2. Extract gresource ---------------------------------------------------
echo "[2/8] Extracting resources from gresource ..."
mkdir -p "$BUILD_DIR/Yaru"

# Classify resources by path prefix
while IFS= read -r resource_path; do
    filename=$(basename "$resource_path")
    if [[ "$resource_path" == */Yaru/* ]]; then
        # CSS files live under /org/gnome/shell/theme/Yaru/
        gresource extract "$SOURCE_GRESOURCE" "$resource_path" \
            > "$BUILD_DIR/Yaru/$filename"
    else
        # SVG / other assets live directly under /org/gnome/shell/theme/
        gresource extract "$SOURCE_GRESOURCE" "$resource_path" \
            > "$BUILD_DIR/$filename"
    fi
done < <(gresource list "$SOURCE_GRESOURCE")

echo "    CSS files  : $(ls "$BUILD_DIR/Yaru" | wc -l)"
echo "    Asset files: $(ls "$BUILD_DIR" | grep -v Yaru | grep -v manifest | wc -l)"

# ---- 3. Append glassmorphic CSS overrides -----------------------------------
echo "[3/8] Appending glassmorphic CSS overrides ..."

# Apply to all Yaru variant CSS files
for css_file in "$BUILD_DIR/Yaru"/*.css; do
    cat "$OVERRIDES_CSS" >> "$css_file"
done
echo "    Applied to $(ls "$BUILD_DIR/Yaru"/*.css | wc -l) Yaru CSS variants."

# CRITICAL: also apply to gdm.css — this is the file GDM actually loads at
# runtime (not the Yaru-prefixed variants above).
if [[ -f "$BUILD_DIR/gdm.css" ]]; then
    cat "$OVERRIDES_CSS" >> "$BUILD_DIR/gdm.css"
    echo "    Applied to gdm.css (primary GDM stylesheet)."
else
    echo "    WARNING: gdm.css not found in extracted resources!" >&2
fi

# ---- 4. Generate XML manifest -----------------------------------------------
echo "[4/8] Generating gresource XML manifest ..."
MANIFEST="$BUILD_DIR/manifest.xml"

{
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<gresources>'
    echo '  <gresource prefix="/org/gnome/shell/theme">'

    # Yaru CSS files → will be at /org/gnome/shell/theme/Yaru/<file>
    for f in "$BUILD_DIR/Yaru"/*.css; do
        fname=$(basename "$f")
        echo "    <file>Yaru/$fname</file>"
    done

    # SVG and other assets → /org/gnome/shell/theme/<file>
    for f in "$BUILD_DIR"/*; do
        fname=$(basename "$f")
        # Skip the Yaru dir and the manifest itself
        [[ "$fname" == "Yaru" ]] && continue
        [[ "$fname" == "manifest.xml" ]] && continue
        echo "    <file>$fname</file>"
    done

    echo '  </gresource>'
    echo '</gresources>'
} > "$MANIFEST"

# ---- 5. Compile new gresource -----------------------------------------------
echo "[5/8] Compiling new gresource ..."
COMPILED_GRESOURCE="$BUILD_DIR/gnome-shell-theme.gresource"
glib-compile-resources \
    --sourcedir="$BUILD_DIR" \
    "$MANIFEST" \
    --target="$COMPILED_GRESOURCE"
echo "    Compiled: $(du -h "$COMPILED_GRESOURCE" | cut -f1)"

# ---- 6. Install new theme ---------------------------------------------------
echo "[6/8] Installing to $INSTALL_THEME_DIR ..."
mkdir -p "$INSTALL_THEME_DIR"
cp "$COMPILED_GRESOURCE" "$INSTALL_THEME_DIR/gnome-shell-theme.gresource"
rm -rf "$BUILD_DIR"

# Register with update-alternatives
PRIORITY=20
if update-alternatives --list gdm-theme.gresource 2>/dev/null | \
        grep -q "$INSTALL_THEME_DIR"; then
    echo "    Updating existing alternative ..."
    update-alternatives --install \
        /usr/share/gnome-shell/gdm-theme.gresource \
        gdm-theme.gresource \
        "$INSTALL_THEME_DIR/gnome-shell-theme.gresource" \
        "$PRIORITY" 2>/dev/null || true
else
    echo "    Registering new alternative (priority $PRIORITY) ..."
    update-alternatives --install \
        /usr/share/gnome-shell/gdm-theme.gresource \
        gdm-theme.gresource \
        "$INSTALL_THEME_DIR/gnome-shell-theme.gresource" \
        "$PRIORITY"
fi

update-alternatives --set \
    gdm-theme.gresource \
    "$INSTALL_THEME_DIR/gnome-shell-theme.gresource"

echo "    Active theme: $(readlink -f /usr/share/gnome-shell/gdm-theme.gresource)"

# ---- 6b. Set up GDM dconf profile and system-db ----------------------------
echo "[6b] Configuring GDM dconf profile ..."

# Create the dconf profile for the gdm user so it reads our system-db
DCONF_PROFILE_GDM="/etc/dconf/profile/gdm"
cat > "$DCONF_PROFILE_GDM" <<'PROFILE'
user-db:user
system-db:gdm
file-db:/var/lib/gdm3/greeter-dconf-defaults
PROFILE
echo "     Created: $DCONF_PROFILE_GDM"

# Create system-db directory
mkdir -p /etc/dconf/db/gdm.d

# Write wallpaper placeholder (will be overwritten by wallpaper sync step)
cat > /etc/dconf/db/gdm.d/00-gdm-glassmorphic <<'DBEOF'
[org/gnome/desktop/interface]
color-scheme='prefer-dark'
DBEOF

dconf update
echo "     dconf database compiled."

# ---- 7. Install update-gdm-wallpaper tool -----------------------------------
echo "[7/8] Installing update-gdm-wallpaper to /usr/local/bin ..."
install -m 755 "$WALLPAPER_SCRIPT" /usr/local/bin/update-gdm-wallpaper

# Install PostLogin hook so wallpaper is synced on every session start
POSTLOGIN="/etc/gdm3/PostLogin/Default"
if [[ ! -f "$POSTLOGIN" ]]; then
    cp /etc/gdm3/PostLogin/Default.sample "$POSTLOGIN" 2>/dev/null || \
        printf '#!/bin/sh\nexit 0\n' > "$POSTLOGIN"
    chmod +x "$POSTLOGIN"
fi

# Add hook only once
if ! grep -q "update-gdm-wallpaper" "$POSTLOGIN"; then
    cat >> "$POSTLOGIN" <<'HOOK'

# --- glassmorphic wallpaper sync ---
# Runs in the background so it does not delay login.
/usr/local/bin/update-gdm-wallpaper &
HOOK
    echo "    PostLogin hook added to $POSTLOGIN"
else
    echo "    PostLogin hook already present in $POSTLOGIN — skipping."
fi

# ---- 8. First wallpaper sync ------------------------------------------------
echo "[8/8] Running initial wallpaper sync ..."
/usr/local/bin/update-gdm-wallpaper || {
    echo "    WARNING: Wallpaper sync failed (no active session yet?)."
    echo "    Run manually after logging in: sudo update-gdm-wallpaper"
}

echo ""
echo "============================================="
echo "  Installation complete!"
echo "============================================="
echo ""
echo "  Theme         : $THEME_NAME"
echo "  Gresource     : $INSTALL_THEME_DIR/gnome-shell-theme.gresource"
echo "  Wallpaper tool: /usr/local/bin/update-gdm-wallpaper"
echo ""
echo "  To apply changes, restart GDM:"
echo "    sudo systemctl restart gdm3"
echo ""
echo "  After changing your desktop wallpaper, re-sync:"
echo "    sudo update-gdm-wallpaper"
echo ""
echo "  To restore the original theme:"
echo "    sudo update-alternatives --set gdm-theme.gresource \\"
echo "        $SOURCE_GRESOURCE"
echo ""
