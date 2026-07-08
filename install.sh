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
#
# Debug mode:
#   sudo DEBUG=1 ./install.sh    — enables verbose per-file and command tracing

set -euo pipefail

# ---- Colour codes -----------------------------------------------------------
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
BOLD='\033[1m'
RESET='\033[0m'

# ---- Logging helpers ---------------------------------------------------------
# Usage:
#   dbg  "message"   — printed only when DEBUG=1
#   info "message"   — always printed (cyan)
#   warn "message"   — always printed (yellow, to stderr)
#   err  "message"   — always printed (red, to stderr), does NOT exit
DEBUG="${DEBUG:-0}"

dbg()  { [[ "$DEBUG" == "1" ]] && echo -e "${CYAN}[DBG]${RESET}  $*" >&2 || true; }
info() { echo -e "${GREEN}[INFO]${RESET} $*" >&2; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*" >&2; }
err()  { echo -e "${RED}[ERR]${RESET}  $*" >&2; }

# ---- ERR trap: print the exact line that caused the failure ------------------
_err_trap() {
    local exit_code=$?
    local line_no=${BASH_LINENO[0]}
    local command="${BASH_COMMAND}"
    err "============================================================"
    err "  Script FAILED at line ${line_no} (exit code: ${exit_code})"
    err "  Failed command: ${command}"
    err "============================================================"
    err "  Tip: Re-run with DEBUG=1 for verbose output:"
    err "    sudo DEBUG=1 ./install.sh"
    err "============================================================"
}
trap '_err_trap' ERR

# ---- Privilege check ---------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root. Use: sudo ./install.sh"
    exit 1
fi

# ---- Environment diagnostics (always shown) ----------------------------------
echo ""
echo -e "${BOLD}=============================================${RESET}"
echo -e "${BOLD}  GDM Glassmorphic — System Diagnostics${RESET}"
echo -e "${BOLD}=============================================${RESET}"
info "Hostname         : $(hostname)"
info "Kernel           : $(uname -r)"
info "Distribution     : $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '\"' || echo 'Unknown')"
info "GDM version      : $(gdm3 --version 2>/dev/null || gdm --version 2>/dev/null || echo 'gdm/gdm3 not in PATH')"
info "GNOME Shell ver  : $(gnome-shell --version 2>/dev/null || echo 'gnome-shell not in PATH')"
info "Script user      : ${SUDO_USER:-root}"
echo ""

# ---- Dependency check --------------------------------------------------------
echo -e "${BOLD}  Checking required dependencies ...${RESET}"
MISSING_DEPS=0
check_dep() {
    local cmd="$1"
    local pkg="${2:-$1}"
    if command -v "$cmd" &>/dev/null; then
        dbg "  [OK] $cmd -> $(command -v "$cmd")"
        info "  [OK] $cmd"
    else
        err "  [MISSING] $cmd  — install with: sudo apt install $pkg"
        MISSING_DEPS=$((MISSING_DEPS + 1))
    fi
}

check_dep "gresource"          "libglib2.0-bin"
check_dep "glib-compile-resources" "libglib2.0-dev-bin"
check_dep "update-alternatives" "dpkg"
check_dep "dconf"              "dconf-cli"
check_dep "install"            "coreutils"
check_dep "mktemp"             "coreutils"

# ImageMagick is optional but important
if command -v convert &>/dev/null; then
    info "  [OK] convert (ImageMagick) -> $(command -v convert)"
else
    warn "  [OPTIONAL MISSING] ImageMagick not found. Wallpaper will not be blurred."
    warn "    Install with: sudo apt install imagemagick"
fi

if [[ "$MISSING_DEPS" -gt 0 ]]; then
    err "$MISSING_DEPS required dependency/dependencies missing. Aborting."
    exit 1
fi
echo ""

# ---- Path setup --------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERRIDES_CSS="$SCRIPT_DIR/glassmorphic-overrides.css"
WALLPAPER_SCRIPT="$SCRIPT_DIR/update-gdm-wallpaper.sh"

dbg "SCRIPT_DIR       : $SCRIPT_DIR"
dbg "OVERRIDES_CSS    : $OVERRIDES_CSS"
dbg "WALLPAPER_SCRIPT : $WALLPAPER_SCRIPT"

# Validate source files exist before doing any work
if [[ ! -f "$OVERRIDES_CSS" ]]; then
    err "glassmorphic-overrides.css not found at: $OVERRIDES_CSS"
    exit 1
fi
dbg "  [OK] glassmorphic-overrides.css found ($(wc -l < "$OVERRIDES_CSS") lines)"

if [[ ! -f "$WALLPAPER_SCRIPT" ]]; then
    err "update-gdm-wallpaper.sh not found at: $WALLPAPER_SCRIPT"
    exit 1
fi
dbg "  [OK] update-gdm-wallpaper.sh found"

THEME_NAME="Yaru-Glassmorphic"
INSTALL_THEME_DIR="/usr/share/gnome-shell/theme/$THEME_NAME"
BUILD_DIR="$(mktemp -d /tmp/gdm-glassmorphic-XXXXXX)"
dbg "BUILD_DIR        : $BUILD_DIR"

# ---- Locate source gresource -------------------------------------------------
# Search strategy (in order):
#   1. Standard Ubuntu/Debian Yaru path
#   2. update-alternatives (Ubuntu — safe, no-op on Debian where this alt may
#      not be registered; the command substitution is wrapped in a function
#      with || true so set -e cannot fire here)
#   3. Any *.gresource under /usr/share/gnome-shell/theme/ (Debian default
#      themes: Adwaita, HighContrast, etc.)
#   4. The canonical GDM fallback at /usr/share/gnome-shell/gnome-shell-theme.gresource
#
# We also skip any path that contains "Glassmorphic" to avoid re-applying
# our own overrides on a re-run.

_find_gresource() {
    local candidate=""

    # 1. Standard Ubuntu Yaru path
    candidate="/usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource"
    if [[ -f "$candidate" ]]; then
        dbg "  Found via path-1 (Yaru standard): $candidate"
        echo "$candidate"; return 0
    fi
    dbg "  path-1 miss: $candidate"

    # 2. update-alternatives — may not be registered on Debian at all;
    #    the || true prevents set -e from firing when the alternative is absent.
    local alt_list=""
    alt_list=$(update-alternatives --list gdm-theme.gresource 2>/dev/null) || true
    dbg "  update-alternatives output: '${alt_list:-<none>}'"
    if [[ -n "$alt_list" ]]; then
        candidate=$(echo "$alt_list" | grep -v Glassmorphic | grep Yaru | head -1 || true)
        if [[ -n "$candidate" && -f "$candidate" ]]; then
            dbg "  Found via path-2 (update-alternatives/Yaru): $candidate"
            echo "$candidate"; return 0
        fi
        # Non-Yaru alternative (e.g., Adwaita on Debian)
        candidate=$(echo "$alt_list" | grep -v Glassmorphic | head -1 || true)
        if [[ -n "$candidate" && -f "$candidate" ]]; then
            dbg "  Found via path-2 (update-alternatives/non-Yaru): $candidate"
            echo "$candidate"; return 0
        fi
    fi
    dbg "  path-2 miss (no usable alternatives)"

    # 3. Scan /usr/share/gnome-shell/theme/ for any .gresource (Debian ships
    #    Adwaita, HighContrast, etc. here)
    dbg "  Scanning /usr/share/gnome-shell/theme/ for *.gresource ..."
    while IFS= read -r f; do
        [[ "$f" == *Glassmorphic* ]] && continue
        dbg "    candidate: $f"
        echo "$f"; return 0
    done < <(find /usr/share/gnome-shell/theme -maxdepth 2 \
                  -name "gnome-shell-theme.gresource" 2>/dev/null | sort)
    dbg "  path-3 miss"

    # 4. Canonical top-level GDM gresource (some Debian/RHEL setups)
    candidate="/usr/share/gnome-shell/gnome-shell-theme.gresource"
    if [[ -f "$candidate" ]]; then
        dbg "  Found via path-4 (canonical top-level): $candidate"
        echo "$candidate"; return 0
    fi
    dbg "  path-4 miss: $candidate"

    return 1
}

info "Locating GDM gresource ..."
SOURCE_GRESOURCE=""
SOURCE_GRESOURCE=$(_find_gresource) || true

if [[ -z "$SOURCE_GRESOURCE" || ! -f "$SOURCE_GRESOURCE" ]]; then
    err "Cannot locate any GDM gresource to use as a base."
    err ""
    err "  Paths searched:"
    err "    /usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource"
    err "    update-alternatives --list gdm-theme.gresource"
    err "    find /usr/share/gnome-shell/theme -name gnome-shell-theme.gresource"
    err "    /usr/share/gnome-shell/gnome-shell-theme.gresource"
    err ""
    err "  On Debian, install the Yaru theme for the best compatibility:"
    err "    sudo apt install yaru-theme-gnome-shell"
    err ""
    err "  Or install any GNOME Shell theme package, for example:"
    err "    sudo apt install gnome-shell   # provides the default Adwaita gresource"
    err ""
    err "  All *.gresource files currently on this system:"
    find /usr/share/gnome-shell -name "*.gresource" 2>/dev/null | \
        while read -r f; do err "    $f"; done || true
    exit 1
fi

# Confirm we're not accidentally re-patching our own output
if [[ "$SOURCE_GRESOURCE" == *Glassmorphic* ]]; then
    err "Source gresource resolves to our own Glassmorphic theme: $SOURCE_GRESOURCE"
    err "This would double-apply the CSS overrides. Remove the old install first:"
    err "  sudo ./uninstall.sh"
    exit 1
fi

BACKUP_PATH="${SOURCE_GRESOURCE}.bak"
info "Source gresource : $SOURCE_GRESOURCE"
info "Size             : $(du -h "$SOURCE_GRESOURCE" | cut -f1)"

echo ""
echo -e "${BOLD}=============================================${RESET}"
echo -e "${BOLD}  GDM Glassmorphic Setup${RESET}"
echo -e "${BOLD}=============================================${RESET}"
info "Source gresource : $SOURCE_GRESOURCE"
info "Build dir        : $BUILD_DIR"
info "Install dir      : $INSTALL_THEME_DIR"
echo ""

# ---- 1. Backup ---------------------------------------------------------------
echo -e "${BOLD}[1/8] Backup${RESET}"
if [[ ! -f "$BACKUP_PATH" ]]; then
    info "Backing up original Yaru gresource to $BACKUP_PATH ..."
    cp "$SOURCE_GRESOURCE" "$BACKUP_PATH"
    dbg "Backup written: $(du -h "$BACKUP_PATH" | cut -f1)"
else
    info "Backup already exists at $BACKUP_PATH — skipping."
    dbg "Existing backup size: $(du -h "$BACKUP_PATH" | cut -f1)"
fi

# ---- 2. Extract gresource ----------------------------------------------------
echo ""
echo -e "${BOLD}[2/8] Extract gresource${RESET}"
info "Extracting resources from: $SOURCE_GRESOURCE"
mkdir -p "$BUILD_DIR/Yaru"

dbg "Listing all resources in gresource:"
gresource list "$SOURCE_GRESOURCE" | while read -r res; do dbg "  $res"; done

EXTRACTED_COUNT=0
FAILED_COUNT=0
while IFS= read -r resource_path; do
    filename=$(basename "$resource_path")
    if [[ "$resource_path" == */Yaru/* ]]; then
        dest="$BUILD_DIR/Yaru/$filename"
        if gresource extract "$SOURCE_GRESOURCE" "$resource_path" > "$dest" 2>/dev/null; then
            dbg "  [OK] $resource_path -> Yaru/$filename ($(wc -c < "$dest") bytes)"
            EXTRACTED_COUNT=$((EXTRACTED_COUNT + 1))
        else
            warn "  [FAIL] Could not extract: $resource_path"
            FAILED_COUNT=$((FAILED_COUNT + 1))
        fi
    else
        dest="$BUILD_DIR/$filename"
        if gresource extract "$SOURCE_GRESOURCE" "$resource_path" > "$dest" 2>/dev/null; then
            dbg "  [OK] $resource_path -> $filename ($(wc -c < "$dest") bytes)"
            EXTRACTED_COUNT=$((EXTRACTED_COUNT + 1))
        else
            warn "  [FAIL] Could not extract: $resource_path"
            FAILED_COUNT=$((FAILED_COUNT + 1))
        fi
    fi
done < <(gresource list "$SOURCE_GRESOURCE")

info "Extracted: $EXTRACTED_COUNT files"
info "CSS files in Yaru/: $(ls "$BUILD_DIR/Yaru" 2>/dev/null | wc -l)"
info "Asset files       : $(ls "$BUILD_DIR" 2>/dev/null | grep -v Yaru | grep -v manifest | wc -l)"
[[ "$FAILED_COUNT" -gt 0 ]] && warn "Failed to extract: $FAILED_COUNT files"
dbg "Build dir contents:"
dbg "  Yaru/: $(ls "$BUILD_DIR/Yaru" 2>/dev/null | tr '\n' ' ')"
dbg "  Root : $(ls "$BUILD_DIR" 2>/dev/null | grep -v Yaru | tr '\n' ' ')"

# ---- 3. Append glassmorphic CSS overrides ------------------------------------
echo ""
echo -e "${BOLD}[3/8] Append glassmorphic CSS overrides${RESET}"
info "Appending overrides from: $OVERRIDES_CSS"
info "Override CSS size: $(wc -l < "$OVERRIDES_CSS") lines / $(wc -c < "$OVERRIDES_CSS") bytes"

CSS_APPLIED=0

# Apply to Yaru variants (Ubuntu)
if [[ -d "$BUILD_DIR/Yaru" ]]; then
    for css_file in "$BUILD_DIR/Yaru"/*.css; do
        [[ -f "$css_file" ]] || continue
        if cat "$OVERRIDES_CSS" >> "$css_file"; then
            dbg "  [OK] Appended to: Yaru/$(basename "$css_file")"
            CSS_APPLIED=$((CSS_APPLIED + 1))
        else
            warn "  [FAIL] Could not append to: $css_file"
        fi
    done
fi

# Apply to root CSS files (Debian defaults: gnome-shell-dark.css, gdm.css, etc.)
for css_file in "$BUILD_DIR"/*.css; do
    [[ -f "$css_file" ]] || continue
    if cat "$OVERRIDES_CSS" >> "$css_file"; then
        dbg "  [OK] Appended to: $(basename "$css_file")"
        CSS_APPLIED=$((CSS_APPLIED + 1))
    else
        warn "  [FAIL] Could not append to: $css_file"
    fi
done

info "Applied to $CSS_APPLIED CSS files total."

if [[ $CSS_APPLIED -eq 0 ]]; then
    warn "No CSS files were patched! The theme may not have any effect."
    warn "  Files in build root: $(ls "$BUILD_DIR" | tr '\n' ' ')"
fi

# ---- 4. Generate XML manifest ------------------------------------------------
echo ""
echo -e "${BOLD}[4/8] Generate gresource XML manifest${RESET}"
MANIFEST="$BUILD_DIR/manifest.xml"
info "Generating manifest at: $MANIFEST"

{
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<gresources>'
    echo '  <gresource prefix="/org/gnome/shell/theme">'

    # Yaru CSS files → will be at /org/gnome/shell/theme/Yaru/<file>
    for f in "$BUILD_DIR/Yaru"/*.css; do
        fname=$(basename "$f")
        echo "    <file>Yaru/$fname</file>"
        dbg "  manifest entry: Yaru/$fname"
    done

    # SVG and other assets → /org/gnome/shell/theme/<file>
    for f in "$BUILD_DIR"/*; do
        fname=$(basename "$f")
        [[ "$fname" == "Yaru" ]] && continue
        [[ "$fname" == "manifest.xml" ]] && continue
        echo "    <file>$fname</file>"
        dbg "  manifest entry: $fname"
    done

    echo '  </gresource>'
    echo '</gresources>'
} > "$MANIFEST"

info "Manifest generated ($(wc -l < "$MANIFEST") lines)."
dbg "Manifest contents:"
[[ "$DEBUG" == "1" ]] && cat "$MANIFEST" | while IFS= read -r line; do dbg "  $line"; done

# ---- 5. Compile new gresource ------------------------------------------------
echo ""
echo -e "${BOLD}[5/8] Compile gresource${RESET}"
COMPILED_GRESOURCE="$BUILD_DIR/gnome-shell-theme.gresource"
info "Compiling gresource ..."
dbg "Command: glib-compile-resources --sourcedir=$BUILD_DIR $MANIFEST --target=$COMPILED_GRESOURCE"

glib-compile-resources \
    --sourcedir="$BUILD_DIR" \
    "$MANIFEST" \
    --target="$COMPILED_GRESOURCE"

if [[ -f "$COMPILED_GRESOURCE" ]]; then
    info "Compiled successfully: $(du -h "$COMPILED_GRESOURCE" | cut -f1)"
else
    err "Compiled gresource not found at: $COMPILED_GRESOURCE"
    exit 1
fi

# ---- 6. Install new theme ----------------------------------------------------
echo ""
echo -e "${BOLD}[6/8] Install theme${RESET}"
info "Installing to: $INSTALL_THEME_DIR"
mkdir -p "$INSTALL_THEME_DIR"
dbg "Copying: $COMPILED_GRESOURCE -> $INSTALL_THEME_DIR/gnome-shell-theme.gresource"
cp "$COMPILED_GRESOURCE" "$INSTALL_THEME_DIR/gnome-shell-theme.gresource"
info "Copied. Cleaning up build dir: $BUILD_DIR"
rm -rf "$BUILD_DIR"
dbg "Build dir removed."

# Register with update-alternatives
PRIORITY=20
dbg "Checking update-alternatives for existing entry ..."
dbg "Current alternatives:"
[[ "$DEBUG" == "1" ]] && update-alternatives --list gdm-theme.gresource 2>/dev/null | while read -r alt; do dbg "  $alt"; done

if update-alternatives --list gdm-theme.gresource 2>/dev/null | \
        grep -q "$INSTALL_THEME_DIR"; then
    info "Updating existing update-alternatives entry ..."
    update-alternatives --install \
        /usr/share/gnome-shell/gdm-theme.gresource \
        gdm-theme.gresource \
        "$INSTALL_THEME_DIR/gnome-shell-theme.gresource" \
        "$PRIORITY" 2>/dev/null || true
else
    info "Registering new alternative (priority $PRIORITY) ..."
    update-alternatives --install \
        /usr/share/gnome-shell/gdm-theme.gresource \
        gdm-theme.gresource \
        "$INSTALL_THEME_DIR/gnome-shell-theme.gresource" \
        "$PRIORITY"
fi

dbg "Setting active alternative ..."
update-alternatives --set \
    gdm-theme.gresource \
    "$INSTALL_THEME_DIR/gnome-shell-theme.gresource"

ACTIVE_THEME="$(readlink -f /usr/share/gnome-shell/gdm-theme.gresource 2>/dev/null || echo 'symlink not found')"
info "Active theme symlink: $ACTIVE_THEME"
if [[ "$ACTIVE_THEME" != "$INSTALL_THEME_DIR/gnome-shell-theme.gresource" ]]; then
    warn "Active theme does not point to the newly installed file!"
    warn "  Expected : $INSTALL_THEME_DIR/gnome-shell-theme.gresource"
    warn "  Got      : $ACTIVE_THEME"
fi

# ---- 6c. Direct gresource replacement (Debian) ------------------------------
# On Ubuntu, GDM is patched to read from the update-alternatives symlink at
# /usr/share/gnome-shell/gdm-theme.gresource. On stock Debian, GDM ignores
# that symlink entirely and reads directly from:
#   /usr/share/gnome-shell/gnome-shell-theme.gresource
#
# So we must also replace that file with our glassmorphic build.
echo ""
echo -e "${BOLD}[6c] Direct gresource replacement (Debian compatibility)${RESET}"

GDM_DIRECT_GRESOURCE="/usr/share/gnome-shell/gnome-shell-theme.gresource"
GDM_DIRECT_BACKUP="${GDM_DIRECT_GRESOURCE}.orig"

if [[ -f "$GDM_DIRECT_GRESOURCE" ]]; then
    # Check if this is already our glassmorphic file (re-run protection)
    DIRECT_SIZE=$(stat -c%s "$GDM_DIRECT_GRESOURCE" 2>/dev/null || echo 0)
    GLASS_SIZE=$(stat -c%s "$INSTALL_THEME_DIR/gnome-shell-theme.gresource" 2>/dev/null || echo 0)
    dbg "Direct gresource size : $DIRECT_SIZE bytes"
    dbg "Glassmorphic size     : $GLASS_SIZE bytes"

    # Check if it's a regular file (not a symlink — Ubuntu would have a symlink here)
    if [[ ! -L "$GDM_DIRECT_GRESOURCE" ]]; then
        info "Debian detected: $GDM_DIRECT_GRESOURCE is a regular file (not a symlink)."
        info "GDM reads this file directly — replacing it with glassmorphic build."

        # Back up only once
        if [[ ! -f "$GDM_DIRECT_BACKUP" ]]; then
            info "  Backing up original to: $GDM_DIRECT_BACKUP"
            cp "$GDM_DIRECT_GRESOURCE" "$GDM_DIRECT_BACKUP"
            dbg "  Backup size: $(du -h "$GDM_DIRECT_BACKUP" | cut -f1)"
        else
            info "  Backup already exists at $GDM_DIRECT_BACKUP — skipping backup."
            dbg "  Existing backup size: $(du -h "$GDM_DIRECT_BACKUP" | cut -f1)"
        fi

        # Replace with our glassmorphic build
        cp "$INSTALL_THEME_DIR/gnome-shell-theme.gresource" "$GDM_DIRECT_GRESOURCE"
        info "  Replaced $GDM_DIRECT_GRESOURCE with glassmorphic build."
        dbg "  New file size: $(du -h "$GDM_DIRECT_GRESOURCE" | cut -f1)"
    else
        info "$GDM_DIRECT_GRESOURCE is a symlink (Ubuntu-style) — skipping direct replacement."
        dbg "  Symlink target: $(readlink -f "$GDM_DIRECT_GRESOURCE")"
    fi
else
    warn "$GDM_DIRECT_GRESOURCE not found. GDM may load its theme from an unexpected location."
    warn "  The update-alternatives symlink should still work on Ubuntu."
fi

# ---- 6b. Set up GDM dconf profile and system-db -----------------------------
echo ""
echo -e "${BOLD}[6b] Configure GDM dconf profile${RESET}"
DCONF_PROFILE_GDM="/etc/dconf/profile/gdm"

# Ensure parent directory exists (Debian may not have it by default)
if [[ ! -d "/etc/dconf/profile" ]]; then
    warn "/etc/dconf/profile/ directory does not exist. Creating it ..."
    mkdir -p /etc/dconf/profile
    dbg "  Created: /etc/dconf/profile/"
fi

info "Writing dconf profile: $DCONF_PROFILE_GDM"
cat > "$DCONF_PROFILE_GDM" <<'PROFILE'
user-db:user
system-db:gdm
file-db:/var/lib/gdm3/greeter-dconf-defaults
PROFILE
dbg "dconf profile contents:"
[[ "$DEBUG" == "1" ]] && cat "$DCONF_PROFILE_GDM" | while IFS= read -r line; do dbg "  $line"; done

# Create system-db directory
mkdir -p /etc/dconf/db/gdm.d
dbg "Created/verified: /etc/dconf/db/gdm.d/"

info "Writing initial dconf system-db entry ..."
cat > /etc/dconf/db/gdm.d/00-gdm-glassmorphic <<'DBEOF'
[org/gnome/desktop/interface]
color-scheme='prefer-dark'
DBEOF
dbg "Wrote: /etc/dconf/db/gdm.d/00-gdm-glassmorphic"

dbg "Running: dconf update"
dconf update
info "dconf database compiled."

# ---- 7. Install update-gdm-wallpaper tool ------------------------------------
echo ""
echo -e "${BOLD}[7/8] Install wallpaper sync tool${RESET}"
info "Installing update-gdm-wallpaper to /usr/local/bin ..."
dbg "Source: $WALLPAPER_SCRIPT"
install -m 755 "$WALLPAPER_SCRIPT" /usr/local/bin/update-gdm-wallpaper
info "Installed: /usr/local/bin/update-gdm-wallpaper (permissions: $(stat -c '%a' /usr/local/bin/update-gdm-wallpaper))"

# Install PostLogin hook so wallpaper is synced on every session start
POSTLOGIN="/etc/gdm3/PostLogin/Default"
dbg "PostLogin hook target: $POSTLOGIN"

if [[ ! -d "/etc/gdm3/PostLogin" ]]; then
    warn "/etc/gdm3/PostLogin/ directory does not exist."
    warn "  Is gdm3 installed? Check: dpkg -l gdm3"
    warn "  Creating directory manually ..."
    mkdir -p /etc/gdm3/PostLogin
fi

if [[ ! -f "$POSTLOGIN" ]]; then
    info "PostLogin/Default not found. Creating from sample or scratch ..."
    if [[ -f /etc/gdm3/PostLogin/Default.sample ]]; then
        cp /etc/gdm3/PostLogin/Default.sample "$POSTLOGIN"
        dbg "  Copied from Default.sample"
    else
        warn "  Default.sample not found. Writing minimal script ..."
        printf '#!/bin/sh\nexit 0\n' > "$POSTLOGIN"
    fi
    chmod +x "$POSTLOGIN"
    info "  Created: $POSTLOGIN"
fi
dbg "PostLogin file: $(ls -la "$POSTLOGIN")"

# Add hook only once
if ! grep -q "update-gdm-wallpaper" "$POSTLOGIN"; then
    cat >> "$POSTLOGIN" <<'HOOK'

# --- glassmorphic wallpaper sync ---
# Runs in the background so it does not delay login.
/usr/local/bin/update-gdm-wallpaper &
HOOK
    info "PostLogin hook appended to $POSTLOGIN"
else
    info "PostLogin hook already present in $POSTLOGIN — skipping."
    dbg "Existing hook line: $(grep -n 'update-gdm-wallpaper' "$POSTLOGIN")"
fi

# ---- 8. First wallpaper sync -------------------------------------------------
echo ""
echo -e "${BOLD}[8/8] Initial wallpaper sync${RESET}"
info "Running: /usr/local/bin/update-gdm-wallpaper"
/usr/local/bin/update-gdm-wallpaper || {
    warn "Wallpaper sync failed. This is normal if no graphical session is active yet."
    warn "Run manually after logging in: sudo update-gdm-wallpaper"
}

# ---- Done -------------------------------------------------------------------
echo ""
echo -e "${BOLD}=============================================${RESET}"
echo -e "${BOLD}  Installation complete!${RESET}"
echo -e "${BOLD}=============================================${RESET}"
echo ""
info "Theme         : $THEME_NAME"
info "Gresource     : $INSTALL_THEME_DIR/gnome-shell-theme.gresource"
info "Wallpaper tool: /usr/local/bin/update-gdm-wallpaper"
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
