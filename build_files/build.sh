#!/bin/bash

set -ouex pipefail

## DNF5 Speedup
sed -i '/^\[main\]/a max_parallel_downloads=10' /etc/dnf/dnf.conf

## System apps
# SCELTA: virtualizzazione rimossa (libvirt virt-manager qemu-kvm).
#         Se ti serve, riaggiungili in fondo a questa riga.
dnf -y install flatpak-builder wlr-randr iotop sysstat lxqt-openssh-askpass lxpolkit parallel

# User apps  (rimossi: kitty, mpv)
dnf -y install nautilus gnome-terminal gnome-system-monitor

# SCELTA: ffmpeg + codec RPM Fusion mantenuti (per riproduzione/decodifica video),
#         ma SENZA OBS. Se non ti servono i codec, elimina queste 2 righe.
dnf -y install https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
dnf -y install ffmpeg x264-libs --allowerasing

# Nautilus "open any terminal" -> punta a gnome-terminal (prima era kitty)
curl -Lo /etc/yum.repos.d/nautilus-open-any-terminal.repo \
  https://copr.fedorainfracloud.org/coprs/monkeygold/nautilus-open-any-terminal/repo/fedora-$(rpm -E %fedora)/monkeygold-nautilus-open-any-terminal-fedora-$(rpm -E %fedora).repo
dnf install -y nautilus-open-any-terminal
glib-compile-schemas /usr/share/glib-2.0/schemas
gsettings set com.github.stunkymonkey.nautilus-open-any-terminal terminal gnome-terminal

# Install Niri
dnf -y install niri

# Install Dank Linux shell (DMS)
curl --output-dir "/etc/yum.repos.d/" \
  --remote-name "https://copr.fedorainfracloud.org/coprs/avengemedia/dms/repo/fedora-$(rpm -E %fedora)/avengemedia-dms-fedora-$(rpm -E %fedora).repo"
dnf -y install quickshell dms greetd dms-greeter --allowerasing

# Desktop extras Wayland:
#  - swaylock/swayidle           : blocco schermo (bind Super+Alt+L) e blocco automatico su inattivita'/sospensione
#  - xdg-desktop-portal-gtk/-wlr : screen sharing (Discord/Zoom/Meet), file picker e screenshot dalle app
#  - grim/slurp                  : screenshot e selezione area da riga di comando
dnf -y install swaylock swayidle xdg-desktop-portal-gtk xdg-desktop-portal-wlr grim slurp

# greetd: login manager che lancia Niri tramite il greeter di Dank
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

# Dotfile di default per ogni nuovo utente (Niri)
mkdir -p /etc/skel/.config/systemd/user/graphical-session.target.wants
ln -s /usr/lib/systemd/user/dms.service /etc/skel/.config/systemd/user/graphical-session.target.wants/
mkdir -p /etc/skel/.config/niri/
cp -rf /ctx/dot_config/niri/config.kdl /etc/skel/.config/niri/

#### Enable podman
systemctl enable podman.socket

# Disabilita i tip/alias di Origami
mv /etc/profile.d/origami-aliases.sh /etc/profile.d/origami-aliases.sh.bak

# Rimuove il desktop COSMIC e waybar (usiamo Niri + DMS)
dnf -y remove cosmic-comp cosmic-initial-setup cosmic-settings cosmic-settings-daemon cosmic-store waybar

## CLEAN UP
dnf5 -y clean all
rm -rf /run/dnf /run/selinux-policy
rm -rf /var/lib/dnf
