#!/bin/bash

set -ouex pipefail

## DNF5 Speedup
sed -i '/^\[main\]/a max_parallel_downloads=10' /etc/dnf/dnf.conf

# --- Si spoglia la base PRIMA di installare. -------------------------------
# Ordine non casuale: "dnf install" su un pacchetto gia' presente nella base
# non lo rimarca come richiesto dall'utente, quindi una "dnf remove" successiva
# se lo porta via come dipendenza inutilizzata. Con waybar succedeva proprio
# questo a playerctl, lasciando morti i bind XF86Audio* di config.kdl.
# Rimuove COSMIC per intero (usiamo Niri + DMS) e waybar.
# La base Origami e' la variante "COSMIC Atomic": elencare a mano i pacchetti ne
# lasciava indietro 31 per ~735 MB, inclusi xdg-desktop-portal-cosmic e
# cutecosmic-qt6 che non hanno il prefisso "cosmic-". Si filtra per pattern.
# NB: fedora-release-cosmic-atomic NON va toccato, fornisce system-release.
# Si rimuovono anche:
#   nvtop            monitor GPU da terminale, non richiesto
#   firefox          la stabile della base: il browser e' Firefox Nightly (sotto)
#   nvidia-settings  pannello X11, inutile su Wayland (non tocca il driver:
#                    e' un pacchetto a se' da 1.6 MiB, nessuno dipende da lui)
mapfile -t TO_REMOVE < <(rpm -qa --qf '%{NAME}\n' \
    | grep -E '^(cosmic-|cutecosmic|xdg-desktop-portal-cosmic|waybar|nvtop|firefox|nvidia-settings)' \
    | sort)
if [ ${#TO_REMOVE[@]} -gt 0 ]; then
    echo "Rimozione COSMIC: ${#TO_REMOVE[@]} pacchetti"
    dnf -y remove "${TO_REMOVE[@]}"
fi

# Origami e' deprecato e inietta in autostart un "RakuOS Migration Assistant"
# (non appartiene ad alcun pacchetto) che ogni giorno propone all'utente un
# "rpm-ostree rebase" verso quay.io/rakuos/rakuos-cosmic-nvidia, cioe' via da
# iperos. Il sed su ID= nel Containerfile non basta: la guardia dello script
# controlla anche NAME e PRETTY_NAME.
rm -f /etc/xdg/autostart/origami-migrate.desktop

## System apps
# SCELTA: virtualizzazione rimossa (libvirt virt-manager qemu-kvm).
#         Se ti serve, riaggiungili in fondo a questa riga.
dnf -y install flatpak-builder wlr-randr iotop sysstat lxqt-openssh-askpass lxpolkit parallel

# User apps  (rimossi: kitty, mpv)
# Set GTK/GNOME che rimpiazza le app COSMIC: DMS ha template matugen per gtk3/gtk4
# e qt5ct/qt6ct, ma nessuno per libcosmic, quindi le app COSMIC resterebbero fuori tema.
#   gnome-text-editor <- cosmic-edit      papers          <- cosmic-reader
#   gnome-calculator  <- cosmic-ext-calculator            celluloid <- cosmic-player
#   snapshot          <- cosmic-ext-camera
#   loupe / file-roller: prima mancavano del tutto
dnf -y install nautilus gnome-terminal gnome-system-monitor \
  gnome-text-editor papers gnome-calculator loupe file-roller celluloid snapshot

# SCELTA: ffmpeg + codec RPM Fusion mantenuti (per riproduzione/decodifica video),
#         ma SENZA OBS. Se non ti servono i codec, elimina queste 2 righe.
dnf -y install https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
dnf -y install ffmpeg x264-libs --allowerasing

# Nautilus "open any terminal" -> punta a gnome-terminal (prima era kitty)
curl -Lo /etc/yum.repos.d/nautilus-open-any-terminal.repo \
  https://copr.fedorainfracloud.org/coprs/monkeygold/nautilus-open-any-terminal/repo/fedora-$(rpm -E %fedora)/monkeygold-nautilus-open-any-terminal-fedora-$(rpm -E %fedora).repo
dnf install -y nautilus-open-any-terminal
# NB: "gsettings set" in fase di build scriverebbe nel dconf di root dentro il
#     container, non nei default di sistema. Si usa un override di schema.
cat > /usr/share/glib-2.0/schemas/zz-iperos-open-any-terminal.gschema.override << 'EOF'
[com.github.stunkymonkey.nautilus-open-any-terminal]
terminal='gnome-terminal'
EOF
glib-compile-schemas /usr/share/glib-2.0/schemas

# Install Niri
# niri "Recommends: waybar,alacritty", che rientrerebbero dopo la rimozione
# sopra (si usa gnome-terminal e la barra di DMS). Le altre weak deps servono:
# gnome-keyring (portal Secret), wireplumber (wpctl), xdg-desktop-portal-gnome
# (e' il backend che niri-portals.conf usa per lo screencast).
dnf -y install niri --exclude=waybar,alacritty

# Install Dank Linux shell (DMS)
curl --output-dir "/etc/yum.repos.d/" \
  --remote-name "https://copr.fedorainfracloud.org/coprs/avengemedia/dms/repo/fedora-$(rpm -E %fedora)/avengemedia-dms-fedora-$(rpm -E %fedora).repo"
dnf -y install quickshell dms greetd dms-greeter --allowerasing

# Desktop extras Wayland:
#  - swaylock/swayidle           : blocco schermo (bind Super+Alt+L) e blocco automatico su inattivita'/sospensione
#  - xdg-desktop-portal-gtk/-wlr : screen sharing (Discord/Zoom/Meet), file picker e screenshot dalle app
#  - grim/slurp                  : screenshot e selezione area da riga di comando
#  - brightnessctl / playerctl    : richiesti dai bind XF86MonBrightness* e XF86Audio*
#    di config.kdl. Vanno installati esplicitamente: su alcune basi arrivavano solo
#    come dipendenza transitiva di waybar, che qui viene rimosso.
dnf -y install swaylock swayidle xdg-desktop-portal-gtk xdg-desktop-portal-wlr grim slurp brightnessctl playerctl

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

# Firefox Nightly: non e' nei repo Fedora e non esiste su Flathub (c'e' solo
# org.mozilla.firefox stabile), quindi si usa il tarball ufficiale Mozilla.
# Porta con se' il proprio NSS (richiede NSS_3.126, di sistema c'e' 3.123).
# /usr e' read-only a runtime: l'updater interno va disattivato via policies.json,
# l'aggiornamento avviene con la ricostruzione giornaliera dell'immagine.
FF_DIR=/usr/lib/firefox-nightly
curl -L --retry 3 --fail -o /tmp/firefox-nightly.tar.xz \
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

# Browser predefinito di sistema. Serve perche' la base registrava
# org.mozilla.firefox come handler di http/https; rimosso quello, senza questo
# file i link finirebbero al selettore di DMS (dms-open.desktop).
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
Comment=Naviga il web con Firefox Nightly
Exec=/usr/bin/firefox-nightly %u
Icon=$FF_DIR/browser/chrome/icons/default/default128.png
Terminal=false
Categories=Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;
StartupNotify=true
StartupWMClass=firefox-nightly
EOF

# DMS: dock in basso con le app. La barra e' gia' in alto (barConfigs default
# position 0 = Top) e dockPosition e' gia' Bottom: manca solo showDock, che di
# default e' false. Il file e' volutamente minimale, le chiavi non presenti
# restano ai default del codice.
mkdir -p /etc/skel/.config/DankMaterialShell
cat > /etc/skel/.config/DankMaterialShell/settings.json << 'EOF'
{
  "showDock": true
}
EOF

# Voci di menu superflue nel launcher. Si nascondono con NoDisplay invece di
# disinstallare: htop resta usabile da terminale, e gnome-system-monitor-kde e'
# lo stesso pacchetto della voce GNOME buona, quindi non e' rimovibile a parte.
# NB: /usr/local e' un symlink a /var/usrlocal su bootc, quindi non si possono
# usare override in /usr/local/share/applications: si modifica il file in posto.
for entry in htop gnome-system-monitor-kde; do
    desktop_file="/usr/share/applications/${entry}.desktop"
    if [ -f "$desktop_file" ]; then
        desktop-file-edit --set-key=NoDisplay --set-value=true "$desktop_file"
    fi
done

#### Enable podman
systemctl enable podman.socket

# Disabilita i tip/alias di Origami (il file puo' sparire in una futura base image)
if [ -f /etc/profile.d/origami-aliases.sh ]; then
    mv /etc/profile.d/origami-aliases.sh /etc/profile.d/origami-aliases.sh.bak
fi

## CLEAN UP
dnf -y clean all
rm -rf /run/dnf /run/selinux-policy
rm -rf /var/lib/dnf
