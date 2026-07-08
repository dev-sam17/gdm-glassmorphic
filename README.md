# GDM Glassmorphic Customization Theme

Apply a modern, premium **glassmorphic** aesthetic to the GNOME Display Manager (GDM) login and lock screens. This toolkit extracts your system's default GDM theme, injects custom semi-transparent styling overrides, and automatically synchronizes a blurred version of your desktop wallpaper as the lock screen background.

---

## Features

- **Dynamic Wallpaper Sync**: Seamlessly detects and syncs your active desktop wallpaper to the GDM background.
- **Glassmorphic UI**: Transforms GDM elements (login/auth cards, buttons, text inputs, user list items, and notifications) into modern translucent glass controls.
- **Auto-Sync on Login**: Installs a post-session login hook to automatically update GDM's background whenever you sign in.
- **Clean Fallback**: Gracefully falls back to system wallpapers if user wallpapers aren't found, and uses unblurred copies if ImageMagick is missing.
- **Safe Install & Restorative Uninstall**: Backs up the original system theme and registers the new one using `update-alternatives` for native OS-level theme management.

---

## Supported Distributions

This toolkit is designed for systems running **Ubuntu** or **Debian-based** Linux distributions using **GDM3** and the default **Yaru** shell theme.

### Officially Supported
* **Ubuntu** (20.04 LTS, 22.04 LTS, 24.04 LTS, and newer releases)
* **Debian** (when using the `gdm3` display manager and with the `yaru-theme-gnome-shell` package installed)

### Technical Dependencies
The scripts rely on the following Debian/Ubuntu-specific features:
1. **GDM3 Directories**: `/etc/gdm3/PostLogin/Default` (for post-login wallpaper updates) and `/etc/gdm3/greeter.dconf-defaults`.
2. **`update-alternatives`**: Used to safely register and manage the active GDM gresource file.
3. **Yaru Theme Assets**: Backs up and appends to the Yaru theme configuration.

> [!WARNING]
> **Fedora, Arch Linux, openSUSE, and other non-Debian distributions are not supported out-of-the-box**. These distributions typically use `/etc/gdm/` configurations instead of `/etc/gdm3/`, do not use the `update-alternatives` system for managing GNOME Shell themes, and do not default to the Yaru theme.

---

## Script Overview

### 1. `install.sh`
The primary setup script. It must be run as root (`sudo`).
* **What it does**:
  1. Backs up the original GDM theme resource file (`gnome-shell-theme.gresource`).
  2. Extracts the theme contents (CSS/SVG assets) to a temporary directory.
  3. Appends the glassmorphic CSS rules from `glassmorphic-overrides.css` to all theme stylesheets (including `gdm.css`).
  4. Compiles the modified theme back into a new gresource binary (`Yaru-Glassmorphic`).
  5. Registers `Yaru-Glassmorphic` as a system theme option using `update-alternatives` and sets it active.
  6. Configures the GDM `dconf` profile to enable system-level background overrides.
  7. Installs the wallpaper sync script to `/usr/local/bin/update-gdm-wallpaper`.
  8. Appends a sync hook to the GDM post-login script (`/etc/gdm3/PostLogin/Default`) so the background stays updated.

### 2. `update-gdm-wallpaper.sh`
A background utility script that handles matching your desktop wallpaper to GDM.
* **What it does**:
  1. Identifies the active user and retrieves their active wallpaper by checking (in order):
     * Active Wayland wallpaper managers (`swww query`, `awww query`).
     * `hyprpaper` configurations.
     * Rofi wallpaper configurations and Hyprland effects files.
     * GNOME/GSettings database keys (`picture-uri`, `picture-uri-dark`).
     * Fallbacks: User Pictures folders and `/usr/share/backgrounds/`.
  2. Copies the original wallpaper to `/usr/share/backgrounds/gdm/current-wallpaper.jpg`.
  3. If **ImageMagick** is installed, it runs a Gaussian blur filters and brightness/contrast correction on the wallpaper to generate a beautiful, non-distracting blurred background (`current-wallpaper-blurred.jpg`).
  4. Updates GDM configuration files and applies changes instantly via `dconf update`.

### 3. `uninstall.sh`
The clean-up script. It must be run as root (`sudo`).
* **What it does**:
  1. Reverts `update-alternatives` to point to the system's original GDM theme.
  2. Deletes the custom compiled theme, the `/usr/local/bin/update-gdm-wallpaper` script, and its post-login hooks.
  3. Restores your default `/etc/gdm3/greeter.dconf-defaults` file.
  4. Updates the `dconf` database to immediately clear any cached backgrounds.

---

## Installation

### Prerequisites

Ensure you have **ImageMagick** installed to get the blurred background effect:

```bash
# On Debian/Ubuntu systems:
sudo apt update
sudo apt install imagemagick
```

### Setup Theme

1. Clone or navigate into this directory.
2. Run the installer:
   ```bash
   sudo ./install.sh
   ```
3. Restart GDM to see the changes:
   ```bash
   sudo systemctl restart gdm3
   ```
   *(Note: This will close your current session. Save your work first!)*

---

## Troubleshooting & Debug Mode

If the install fails, re-run with the `DEBUG=1` flag for verbose, per-step output that logs every file extracted, every command executed, and every intermediate state:

```bash
sudo DEBUG=1 ./install.sh 2>&1 | tee /tmp/gdm-install-debug.log
```

The log file at `/tmp/gdm-install-debug.log` captures full output including warnings and errors, and is useful to share when reporting issues.

### What the debug logs include
* **System diagnostics**: Hostname, kernel version, distribution name, GDM version, and GNOME Shell version — printed at the start of every run.
* **Dependency check**: Verifies `gresource`, `glib-compile-resources`, `update-alternatives`, `dconf`, and `imagemagick` are installed *before* doing any work. Missing packages are reported with the exact `apt install` command.
* **ERR trap**: If any command fails, the script prints the exact **line number** and the **failed command** before exiting, making it easy to locate failures without manually tracing through the script.
* **Per-file extraction logs**: Every file extracted from the Yaru gresource is logged, along with its destination path and byte size.
* **Manifest generation trace**: Lists every `<file>` entry written into the XML manifest before compilation.
* **Symlink verification**: After registering with `update-alternatives`, confirms the active symlink points to the newly installed file.
* **dconf profile trace**: Prints the contents of the written dconf profile to confirm Debian-specific paths are correct.

### Common Failures on Debian

| Symptom | Cause | Fix |
|---|---|---|
| `Cannot locate the original Yaru gresource` | Yaru theme not installed | `sudo apt install yaru-theme-gnome-shell` |
| `gresource: command not found` | Missing GLib tools | `sudo apt install libglib2.0-bin` |
| `glib-compile-resources: command not found` | Missing GLib dev tools | `sudo apt install libglib2.0-dev-bin` |
| `gdm.css NOT found in extracted resources` | GDM version uses different structure | Use `DEBUG=1` to inspect extracted files and report the output |
| `/etc/gdm3/PostLogin/` does not exist | GDM3 not installed or non-standard setup | `sudo apt install gdm3` |
| `dconf update` fails | dconf-cli missing | `sudo apt install dconf-cli` |
| Wallpaper sync fails on step 8 | No active graphical session when run over SSH | Run `sudo update-gdm-wallpaper` after logging into the desktop |

---

## Configuration & Manual Wallpaper Sync

### Triggering Wallpaper Sync Manually

The wallpaper sync script runs automatically on login. However, if you change your wallpaper and want GDM to update immediately, run:

```bash
sudo update-gdm-wallpaper
```

### Customizing Blur & Brightness

You can adjust the blur density and brightness of the login background by passing environment variables to the sync script:

* **`GDM_BLUR_RADIUS`**: Controls the density of the Gaussian blur (default is `8`). Higher values yield smoother glass styles.
* **`GDM_BRIGHTNESS`**: Controls the brightness offset (default is `-10`). Negative values make the wallpaper darker.

**Example**:
```bash
sudo GDM_BLUR_RADIUS=15 GDM_BRIGHTNESS=-20 update-gdm-wallpaper
```

---

## Uninstallation

To completely remove the theme and restore GDM to its stock configuration:

1. Run the uninstaller:
   ```bash
   sudo ./uninstall.sh
   ```
2. Restart GDM to apply:
   ```bash
   sudo systemctl restart gdm3
   ```
