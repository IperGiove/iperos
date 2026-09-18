#!/bin/bash

set -ouex pipefail

## DNF5 Speedup
sed -i '/^\[main\]/a max_parallel_downloads=10' /etc/dnf/dnf.conf

# --- Strip the base BEFORE installing anything. -----------------------------
# The order is not arbitrary: "dnf install" on a package already present in
# the base does not mark it as user-requested, so a later "dnf remove" would
# take it away as an unused dependency. This happened with waybar taking
# playerctl down with it, leaving the XF86Audio* binds in config.kdl dead.
# Removes COSMIC entirely (we use Niri + DMS) and waybar.
# The Origami base is the "COSMIC Atomic" variant: listing the packages by
# hand left 31 behind for ~735 MB, including xdg-desktop-portal-cosmic and
# cutecosmic-qt6, which don't have the "cosmic-" prefix. We filter by pattern
# instead.
# NB: fedora-release-cosmic-atomic must NOT be touched, it provides
# system-release.
# Also removed:
#   nvtop            terminal GPU monitor, not needed
#   firefox           the base's stable build: the browser here is Firefox
#                     Nightly (see below)
#   nvidia-settings  X11 panel, useless on Wayland (doesn't touch the driver:
#                    it's a standalone 1.6 MiB package, nothing depends on it)
mapfile -t TO_REMOVE < <(rpm -qa --qf '%{NAME}\n' \
    | grep -E '^(cosmic-|cutecosmic|xdg-desktop-portal-cosmic|waybar|nvtop|firefox|nvidia-settings)' \
    | sort)
if [ ${#TO_REMOVE[@]} -gt 0 ]; then
    echo "Removing COSMIC: ${#TO_REMOVE[@]} packages"
    dnf -y remove "${TO_REMOVE[@]}"
fi

# Origami is deprecated and injects a "RakuOS Migration Assistant" into
# autostart (it doesn't belong to any package) that every day nags the user
# to do an "rpm-ostree rebase" to quay.io/rakuos/rakuos-cosmic-nvidia, i.e.
# away from iperos. The sed on ID= in the Containerfile isn't enough: the
# script's guard also checks NAME and PRETTY_NAME.
rm -f /etc/xdg/autostart/origami-migrate.desktop

## System apps
# CHOICE: virtualization removed (libvirt virt-manager qemu-kvm).
#         If you need it, add it back at the end of this line.
# btrfs-assistant: GUI for snapshots/subvolumes. Relevant here because the
# VM/ISO/raw images are built with --rootfs=btrfs (see Justfile's
# _build-bib and build-disk.yml), so the root filesystem on those images
# actually is btrfs.
dnf -y install flatpak-builder wlr-randr iotop sysstat lxqt-openssh-askpass lxpolkit parallel openssh-server btrfs-assistant

# sshd doesn't start on its own even though the package is already in the
# base: it has to be enabled explicitly. The user/password stay whatever the
# system has (no key or preconfigured access here) - if the firewall is
# active on the machine, port 22 has to be opened separately (not handled by
# this image).
systemctl enable sshd.service

# Nvidia + suspend: the machine has no S3 (only "s2idle" in
# /sys/power/mem_sleep, checked by hand), so there's no way to get the
# near-zero-power suspend of classic S3. Without these parameters the GPU
# doesn't cooperate with s2idle: it stays powered during suspend instead of
# turning off the VRAM, which is the typical cause of battery drain and fans
# running with the lid closed.
#   NVreg_EnableS0ixPowerManagement=1  if the VRAM in use is below the
#     threshold (default 256 MB, NVreg_S0ixPowerManagementVideoMemoryThreshold),
#     copies it to system RAM and powers off video memory during s2idle.
#   NVreg_UseKernelSuspendNotifiers=1  on the open modules (the ones this
#     image uses, see Containerfile) this is needed to automatically trigger
#     saving/restoring VRAM across the suspend/resume cycle; without it,
#     EnableS0ixPowerManagement alone isn't enough on the open modules.
# Not guaranteed to be clean on every GPU/driver version (there are reports
# of GSP firmware panics with aggressive power management + s2idle): if
# resume gets worse, roll back with "just rollback".
mkdir -p /etc/modprobe.d
cat > /etc/modprobe.d/nvidia-power.conf << 'EOF'
options nvidia NVreg_EnableS0ixPowerManagement=1 NVreg_UseKernelSuspendNotifiers=1
EOF

# User apps  (removed: kitty, mpv)
# GTK/GNOME set that replaces the COSMIC apps: DMS has matugen templates for
# gtk3/gtk4 and qt5ct/qt6ct, but none for libcosmic, so COSMIC apps would be
# left out of theme.
#   gnome-text-editor <- cosmic-edit      papers          <- cosmic-reader
#   gnome-calculator  <- cosmic-ext-calculator            celluloid <- cosmic-player
#   snapshot          <- cosmic-ext-camera
#   loupe / file-roller: were missing entirely before
dnf -y install nautilus gnome-terminal gnome-system-monitor \
  gnome-text-editor papers gnome-calculator loupe file-roller celluloid snapshot

# CHOICE: ffmpeg + RPM Fusion codecs kept (for video playback/decoding), but
#         WITHOUT OBS. If you don't need the codecs, remove these 2 lines.
# "dnf swap" instead of "install --allowerasing": the base already has
# ffmpeg-free, and swap explicitly declares "replace this with that" instead
# of leaving dnf free to erase whatever it considers conflicting.
dnf -y install https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
dnf -y swap ffmpeg-free ffmpeg --allowerasing
dnf -y install x264-libs

# Go and uv (Astral's Python package/project manager): both in the Fedora
# repos with up-to-date versions, so they stay current on their own with the
# daily rebuild instead of having to be downloaded by hand like Firefox
# Nightly below.
dnf -y install golang uv

# task (go-task/Taskfile.dev): not in the Fedora repos, official Cloudsmith
# repo. Only the main arch repo is needed to install the binary (the noarch
# and SRPMS repos from the upstream instructions are not needed here).
rpm --import "https://dl.cloudsmith.io/public/task/task/gpg.046FD1186CA342F0.key"
cat > /etc/yum.repos.d/task.repo << EOF
[task-task]
name=task-task
baseurl=https://dl.cloudsmith.io/public/task/task/rpm/fedora/$(rpm -E %fedora)/\$basearch
gpgcheck=1
gpgkey=https://dl.cloudsmith.io/public/task/task/gpg.046FD1186CA342F0.key
enabled=1
EOF
# task's RPM ships a zsh completion under /usr/local/share/zsh/site-functions/,
# which on this base is a dangling symlink to /var/usrlocal (nothing has
# created that directory yet at this point in the build). rpm's cpio fails
# to mkdir through a dangling symlink ("cpio: mkdir failed - File exists"
# followed by "No data available"), so the target has to be created by
# writing straight to /var/usrlocal instead of through the /usr/local
# symlink, which just fails the same way "mkdir -p /usr/local/..." would.
mkdir -p /var/usrlocal/share/zsh/site-functions
dnf -y install task

# Nautilus "open any terminal" -> points to gnome-terminal (used to be kitty)
curl -Lo /etc/yum.repos.d/nautilus-open-any-terminal.repo \
  https://copr.fedorainfracloud.org/coprs/monkeygold/nautilus-open-any-terminal/repo/fedora-$(rpm -E %fedora)/monkeygold-nautilus-open-any-terminal-fedora-$(rpm -E %fedora).repo
dnf install -y nautilus-open-any-terminal
# NB: "gsettings set" at build time would write to root's dconf inside the
#     container, not to the system defaults. A schema override is used
#     instead.
cat > /usr/share/glib-2.0/schemas/zz-iperos-open-any-terminal.gschema.override << 'EOF'
[com.github.stunkymonkey.nautilus-open-any-terminal]
terminal='gnome-terminal'
EOF
glib-compile-schemas /usr/share/glib-2.0/schemas

# Install Niri
# niri "Recommends: waybar,alacritty", which would come back after the
# removal above (gnome-terminal and DMS's bar are used instead). The other
# weak deps are needed: gnome-keyring (Secret portal), wireplumber (wpctl),
# xdg-desktop-portal-gnome (the backend niri-portals.conf uses for
# screencast).
dnf -y install niri --exclude=waybar,alacritty

# Install Dank Linux shell (DMS)
curl --output-dir "/etc/yum.repos.d/" \
  --remote-name "https://copr.fedorainfracloud.org/coprs/avengemedia/dms/repo/fedora-$(rpm -E %fedora)/avengemedia-dms-fedora-$(rpm -E %fedora).repo"
dnf -y install quickshell dms greetd dms-greeter --allowerasing

# Wayland desktop extras:
#  - swaylock/swayidle           : screen lock (Super+Alt+L bind) and automatic
#                                   lock on idle/suspend
#  - xdg-desktop-portal-gtk/-wlr : screen sharing (Discord/Zoom/Meet), file
#                                   picker and screenshots from apps
#  - grim/slurp                  : screenshot and area selection from the
#                                   command line
#  - brightnessctl / playerctl    : required by the XF86MonBrightness* and
#    XF86Audio* binds in config.kdl. Need to be installed explicitly: on some
#    bases they only arrived as a transitive dependency of waybar, which is
#    removed here.
dnf -y install swaylock swayidle xdg-desktop-portal-gtk xdg-desktop-portal-wlr grim slurp brightnessctl playerctl

# swaylock without a config has a default light-grey 0xA3A3A3 background
# (checked in main.c, set_default_colors): on screen it looks almost white
# and the indicator, even though it's on by default, is barely visible on
# top of it. /etc/swaylock/config is read by default by every invocation
# (SYSCONFDIR, confirmed in Fedora's swaylock.spec: %meson sets
# _sysconfdir=/etc) - this covers both the Super+Alt+L bind and swayidle in
# config.kdl, without having to repeat it in multiple places.
mkdir -p /etc/swaylock
cat > /etc/swaylock/config << 'EOF'
color=1a1a1a
indicator
show-failed-attempts
EOF

# keyd: niri doesn't support a bind on the bare Super key (it would need a
# "release bind", not implemented yet - see niri-wm/niri discussion #1492).
# The key is intercepted at the input driver level instead: an isolated tap
# of Super sends Mod+W (already bound to "toggle-overview" in config.kdl,
# niri's Overview with DMS's search overlay on top - the closest thing niri
# has to GNOME's "Activities"). Held down, Super keeps acting as a modifier
# for every other combination (Mod+D, Mod+E, etc.), thanks to overloadt2.
# keyd is not in the Fedora/RPM Fusion repos: the Terra repo is needed.
# NB: the repo is written by hand (like vscode.repo/nordvpn.repo below)
# instead of using the terra-release package, which points gpgkey at a local
# file (file:///etc/pki/rpm-gpg/RPM-GPG-KEY-terra$releasever). That file
# exists in the container during the build, but bootc-image-builder does its
# own depsolve for the ISO/qcow2 in a separate sandbox where it doesn't
# exist: "just build-iso" failed with "Could not read a file:// file for
# .../RPM-GPG-KEY-terra44". With gpgkey on an https URL (as in Terra's
# subatomic-repos, built specifically for Fedora Atomic) the key can be
# downloaded from whatever context runs the depsolve.
rpm --import "https://repos.fyralabs.com/terra$(rpm -E %fedora)/key.asc"
cat > /etc/yum.repos.d/terra.repo << 'EOF'
[terra]
name=Terra $releasever
baseurl=https://repos.fyralabs.com/terra$releasever
type=rpm
skip_if_unavailable=True
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://repos.fyralabs.com/terra$releasever/key.asc
enabled=1
enabled_metadata=1
metadata_expire=4h
EOF
dnf -y install keyd
mkdir -p /etc/keyd
cat > /etc/keyd/default.conf << 'EOF'
[ids]
*

[main]
leftmeta = overloadt2(meta, macro(M-w), 200)
EOF
systemctl enable keyd.service

# greetd: login manager that launches Niri through Dank's greeter
mkdir -p /etc/greetd/
cat > /etc/greetd/config.toml << EOF
[terminal]
vt = 1
[default_session]
user = "greeter"
command = "dms-greeter --command niri"
EOF
rm -f /etc/systemd/system/display-manager.service
ln -s /usr/lib/systemd/system/greetd.service /etc/systemd/system/display-manager.service
systemctl enable --force greetd.service

# Default dotfiles for every new user (Niri)
mkdir -p /etc/skel/.config/systemd/user/graphical-session.target.wants
ln -s /usr/lib/systemd/user/dms.service /etc/skel/.config/systemd/user/graphical-session.target.wants/
mkdir -p /etc/skel/.config/niri/
cp -rf /ctx/dot_config/niri/config.kdl /etc/skel/.config/niri/

# ---------------------------------------------------------------------------
# Requested applications
# ---------------------------------------------------------------------------
# From the repos already enabled (Fedora + negativo17 from the ublue base).
# Signal comes from negativo17, where the package is called Signal-Desktop.
dnf -y install \
    blender \
    hexchat \
    transmission-gtk \
    chromium \
    openscad \
    libreoffice-calc \
    Signal-Desktop

# Visual Studio Code: not in the Fedora repos, using the official Microsoft
# one. The RPM is preferred over the Flatpak because it isn't sandboxed and
# so it can see podman, toolchains and system files: matters on a dev
# machine.
rpm --import https://packages.microsoft.com/keys/microsoft.asc
cat > /etc/yum.repos.d/vscode.repo << 'EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
autorefresh=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
dnf -y install code

# NordVPN: official repo (not on Flathub, only exists as RPM/DEB).
# CLI only: the nordvpn package provides /usr/bin/nordvpn and the nordvpnd
# daemon. --exclude is needed because "nordvpn" has Recommends: nordvpn-gui,
# which would otherwise come back on its own (same case as waybar and
# alacritty).
rpm --import https://repo.nordvpn.com/gpg/nordvpn_public.asc
cat > /etc/yum.repos.d/nordvpn.repo << 'EOF'
[nordvpn]
name=NordVPN
baseurl=https://repo.nordvpn.com/yum/nordvpn/centos/$basearch
enabled=1
gpgcheck=1
gpgkey=https://repo.nordvpn.com/gpg/nordvpn_public.asc
EOF
dnf -y install nordvpn --exclude=nordvpn-gui

# The package creates the "nordvpn" group directly in /etc/group, but on
# bootc /etc is machine-local state: a group created only at build time
# isn't stable across updates ("bootc container lint" flags it). It's
# declared to systemd instead, which recreates it reliably at boot. The GID
# is left up to systemd: no file belongs to this group, it's only used to
# decide who can talk to the nordvpnd daemon.
cat > /usr/lib/sysusers.d/nordvpn.conf << 'EOF'
#Type Name    ID
g     nordvpn -
EOF

# Antares SQL, MongoDB Compass, UltiMaker Cura and Android Studio only exist
# as Flatpak (Android Studio isn't in the Fedora repos either).
# Flatpaks are installed into /var/lib/flatpak, which is machine-local state
# and is NOT part of the image: so they need to be installed on first boot.
# The flathub remote is already provided by the base in
# /etc/flatpak/remotes.d/.
cat > /usr/libexec/iperos-install-flatpaks << 'EOF'
#!/usr/bin/bash
set -euo pipefail

APPS=(
    it.fabiodistasio.AntaresSQL
    com.mongodb.Compass
    com.ultimaker.cura
    com.google.AndroidStudio
)

for app in "${APPS[@]}"; do
    # Only install what's missing: updates are already handled by
    # flatpak-system-update.timer, so no wasted traffic on every boot.
    if ! flatpak info --system "$app" > /dev/null 2>&1; then
        flatpak install --system --noninteractive flathub "$app" || true
    fi
done
EOF
chmod +x /usr/libexec/iperos-install-flatpaks

cat > /usr/lib/systemd/system/iperos-flatpaks.service << 'EOF'
[Unit]
Description=Install iperos' default Flatpaks
Wants=network-online.target
After=network-online.target flatpak-add-fedora-repos.service
ConditionPathExists=/etc/flatpak/remotes.d/flathub.flatpakrepo

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/libexec/iperos-install-flatpaks

[Install]
WantedBy=multi-user.target
EOF
systemctl enable iperos-flatpaks.service

# Firefox Nightly: not in the Fedora repos and not on Flathub either (only
# the stable org.mozilla.firefox is), so the official Mozilla tarball is
# used. It ships its own NSS (requires NSS_3.126, the system has 3.123).
# /usr is read-only at runtime: the internal updater has to be disabled via
# policies.json, updates happen through the daily image rebuild instead.
FF_DIR=/usr/lib/firefox-nightly
# --retry-all-errors: without it, "--retry" only retries a subset of curl's
# "transient" errors, which does NOT include HTTP/2 protocol-level errors
# (seen in a failed build: "HTTP/2 stream 1 was not closed cleanly:
# PROTOCOL_ERROR") - sporadic against Mozilla's CDN, and not covered by
# plain retry either.
curl -L --retry 3 --retry-all-errors --fail -o /tmp/firefox-nightly.tar.xz \
  "https://download.mozilla.org/?product=firefox-nightly-latest-ssl&os=linux64&lang=en-US"
rm -rf "$FF_DIR"
tar -xJf /tmp/firefox-nightly.tar.xz -C /usr/lib
mv /usr/lib/firefox "$FF_DIR"
rm -f /tmp/firefox-nightly.tar.xz
ln -sf "$FF_DIR/firefox" /usr/bin/firefox-nightly

mkdir -p "$FF_DIR/distribution"
cat > "$FF_DIR/distribution/policies.json" << 'EOF'
{
  "policies": {
    "DisableAppUpdate": true
  }
}
EOF

# System default browser. Needed because the base registered
# org.mozilla.firefox as the http/https handler; once that's removed,
# without this file links would end up at DMS's picker (dms-open.desktop).
cat > /etc/xdg/mimeapps.list << 'MIMEEOF'
[Default Applications]
text/html=firefox-nightly.desktop
x-scheme-handler/http=firefox-nightly.desktop
x-scheme-handler/https=firefox-nightly.desktop
x-scheme-handler/about=firefox-nightly.desktop
x-scheme-handler/unknown=firefox-nightly.desktop
MIMEEOF

cat > /usr/share/applications/firefox-nightly.desktop << EOF
[Desktop Entry]
Type=Application
Name=Firefox Nightly
GenericName=Web Browser
Comment=Browse the web with Firefox Nightly
Exec=/usr/bin/firefox-nightly %u
Icon=$FF_DIR/browser/chrome/icons/default/default128.png
Terminal=false
Categories=Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;
StartupNotify=true
StartupWMClass=firefox-nightly
EOF

# DMS: dock at the bottom with the apps. The bar is already at the top
# (barConfigs default position 0 = Top) and dockPosition is already Bottom:
# only showDock is missing, which defaults to false.
#
# dockSmartAutoHide: "Intelligent Auto-hide" (checked in
# Modules/Dock/DockBody.qml) - the dock stays always visible and only hides
# when a window overlaps its area, reappearing on mouse hover. It's mutually
# exclusive with dockAutoHide (always hidden): don't set both together.
#
# barConfigs: a copy of the default "Main Bar" (Common/settings/SettingsSpec.js)
# with "launcherButton" removed from leftWidgets - it's the button that opens
# the menu/app-drawer attached to the bar. Niri's Overview is used instead
# (Super or Mod+W, see keyd above) or Mod+D for DMS's spotlight.
# WARNING: since this is a full copy and not a single key, a future DMS
# update that adds new default fields to barConfigs won't propagate here
# automatically: if the bar starts behaving oddly after a DMS bump, compare
# it against the new upstream default.
mkdir -p /etc/skel/.config/DankMaterialShell
cat > /etc/skel/.config/DankMaterialShell/settings.json << 'EOF'
{
  "showDock": true,
  "dockSmartAutoHide": true,
  "barConfigs": [
    {
      "id": "default",
      "name": "Main Bar",
      "enabled": true,
      "position": 0,
      "screenPreferences": ["all"],
      "showOnLastDisplay": true,
      "leftWidgets": ["workspaceSwitcher", "focusedWindow"],
      "centerWidgets": ["music", "clock", "weather"],
      "rightWidgets": ["systemTray", "clipboard", "cpuUsage", "memUsage", "notificationButton", "battery", "controlCenterButton"],
      "spacing": 4,
      "innerPadding": 4,
      "barLengthPadding": 0,
      "bottomGap": 0,
      "attachToScreenEdge": false,
      "transparency": 1.0,
      "widgetTransparency": 1.0,
      "squareCorners": false,
      "noBackground": false,
      "maximizeWidgetIcons": false,
      "maximizeWidgetText": false,
      "removeWidgetPadding": false,
      "widgetPadding": 8,
      "batteryColorMode": "theme",
      "gothCornersEnabled": false,
      "gothCornerRadiusOverride": false,
      "gothCornerRadiusValue": 12,
      "borderEnabled": false,
      "borderColor": "surfaceText",
      "borderOpacity": 1.0,
      "borderThickness": 1,
      "widgetOutlineEnabled": false,
      "widgetOutlineColor": "primary",
      "widgetOutlineOpacity": 1.0,
      "widgetOutlineThickness": 1,
      "fontScale": 1.0,
      "iconScale": 1.0,
      "autoHide": false,
      "autoHideStrict": false,
      "autoHideDelay": 250,
      "showOnWindowsOpen": false,
      "openOnOverview": false,
      "visible": true,
      "popupGapsAuto": true,
      "popupGapsManual": 4,
      "maximizeDetection": true,
      "useOverlayLayer": false,
      "scrollEnabled": true,
      "scrollXBehavior": "column",
      "scrollYBehavior": "workspace",
      "shadowIntensity": 0,
      "shadowOpacity": 60,
      "shadowColorMode": "default",
      "shadowCustomColor": "#000000",
      "clickThrough": false,
      "hoverPopouts": false,
      "hoverPopoutDelay": 150
    }
  ]
}
EOF

# Superfluous menu entries in the launcher. Hidden with NoDisplay instead of
# uninstalled: htop stays usable from the terminal, and
# gnome-system-monitor-kde is the same package as the good GNOME entry, so it
# can't be removed on its own.
# NB: /usr/local is a symlink to /var/usrlocal on bootc, so overrides in
# /usr/local/share/applications can't be used: the file is edited in place
# instead.
for entry in htop gnome-system-monitor-kde; do
    desktop_file="/usr/share/applications/${entry}.desktop"
    if [ -f "$desktop_file" ]; then
        desktop-file-edit --set-key=NoDisplay --set-value=true "$desktop_file"
    fi
done

#### Enable podman
systemctl enable podman.socket

# Disable Origami's tips/aliases (the file may disappear in a future base image)
if [ -f /etc/profile.d/origami-aliases.sh ]; then
    mv /etc/profile.d/origami-aliases.sh /etc/profile.d/origami-aliases.sh.bak
fi

## CLEAN UP
dnf -y clean all
rm -rf /run/dnf /run/selinux-policy
rm -rf /var/lib/dnf
