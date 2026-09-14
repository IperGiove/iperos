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

# keyd: niri non supporta un bind sul solo tasto Super (serve una "release bind",
# non ancora implementata - vedi niri-wm/niri discussion #1492). Si intercetta il
# tasto a livello di input driver: un tap isolato di Super invia Mod+W (gia'
# legato a "toggle-overview" in config.kdl, l'Overview di niri con l'overlay di
# ricerca di DMS sopra - il piu vicino a "Activities" di GNOME che niri abbia).
# Tenuto premuto, Super continua a fare da modificatore per tutte le altre
# combinazioni (Mod+D, Mod+E, ecc.), grazie a overloadt2.
# keyd non e' nei repo Fedora/RPM Fusion: serve il repo Terra.
# NB: si scrive il repo a mano (come vscode.repo/nordvpn.repo sotto) invece di
# usare il pacchetto terra-release, che punta gpgkey a un file locale
# (file:///etc/pki/rpm-gpg/RPM-GPG-KEY-terra$releasever). Quel file esiste nel
# container durante la build, ma bootc-image-builder fa il suo depsolve per
# l'ISO/qcow2 in un sandbox separato dove non c'e': "just build-iso" falliva con
# "Could not read a file:// file for .../RPM-GPG-KEY-terra44". Con gpgkey su
# URL https (come da subatomic-repos di Terra, pensato apposta per Fedora
# Atomic) la chiave si puo' scaricare da qualunque contesto faccia il depsolve.
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

# ---------------------------------------------------------------------------
# Applicazioni richieste
# ---------------------------------------------------------------------------
# Dai repo gia' attivi (Fedora + negativo17 della base ublue).
# Signal arriva da negativo17, dove il pacchetto si chiama Signal-Desktop.
dnf -y install \
    blender \
    hexchat \
    transmission-gtk \
    chromium \
    openscad \
    libreoffice-calc \
    Signal-Desktop

# Visual Studio Code: non e' nei repo Fedora, si usa quello ufficiale Microsoft.
# Si preferisce l'RPM al Flatpak perche' non e' in sandbox e quindi vede podman,
# i toolchain e i file di sistema: su una macchina da sviluppo conta.
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

# NordVPN: repo ufficiale (non e' su Flathub, esiste solo come RPM/DEB).
# Solo la CLI: il pacchetto nordvpn fornisce /usr/bin/nordvpn e il demone
# nordvpnd. Serve --exclude perche' "nordvpn" ha Recommends: nordvpn-gui,
# che altrimenti rientrerebbe da solo (stesso caso di waybar e alacritty).
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

# Il pacchetto crea il gruppo "nordvpn" direttamente in /etc/group, ma su bootc
# /etc e' stato locale della macchina: un gruppo creato solo in fase di build
# non e' stabile fra un aggiornamento e l'altro (e "bootc container lint" lo
# segnala). Lo si dichiara a systemd, che lo ricrea al boot in modo affidabile.
# Il GID resta a scelta di systemd: nessun file appartiene a questo gruppo,
# serve solo a decidere chi puo' parlare col demone nordvpnd.
cat > /usr/lib/sysusers.d/nordvpn.conf << 'EOF'
#Type Name    ID
g     nordvpn -
EOF

# Antares SQL, MongoDB Compass e UltiMaker Cura esistono solo come Flatpak.
# I Flatpak si installano in /var/lib/flatpak, che e' stato locale della macchina
# e NON fa parte dell'immagine: vanno quindi installati al primo avvio.
# Il remote flathub e' gia' fornito dalla base in /etc/flatpak/remotes.d/.
cat > /usr/libexec/iperos-install-flatpaks << 'EOF'
#!/usr/bin/bash
set -euo pipefail

APPS=(
    it.fabiodistasio.AntaresSQL
    com.mongodb.Compass
    com.ultimaker.cura
)

for app in "${APPS[@]}"; do
    # Si installa solo cio' che manca: gli aggiornamenti li fa gia'
    # flatpak-system-update.timer, quindi niente traffico inutile a ogni boot.
    if ! flatpak info --system "$app" > /dev/null 2>&1; then
        flatpak install --system --noninteractive flathub "$app" || true
    fi
done
EOF
chmod +x /usr/libexec/iperos-install-flatpaks

cat > /usr/lib/systemd/system/iperos-flatpaks.service << 'EOF'
[Unit]
Description=Installa i Flatpak predefiniti di iperos
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
# default e' false.
#
# dockSmartAutoHide: "Intelligent Auto-hide" (verificato in
# Modules/Dock/DockBody.qml) - il dock resta sempre visibile e si nasconde solo
# quando una finestra si sovrappone alla sua area, riapparendo al passaggio del
# mouse. E' mutualmente esclusivo con dockAutoHide (nascosto sempre): non va
# impostato insieme.
#
# barConfigs: copia della "Main Bar" di default (Common/settings/SettingsSpec.js)
# con "launcherButton" tolto da leftWidgets - e' il pulsante che apre il menu/
# app-drawer agganciato alla barra. Al suo posto si usa l'Overview di niri
# (Super o Mod+W, vedi keyd sopra) o Mod+D per lo spotlight di DMS.
# ATTENZIONE: essendo una copia completa e non una chiave singola, un futuro
# aggiornamento di DMS che aggiunga nuovi campi di default a barConfigs non si
# propaga qui automaticamente: se la barra iniziasse a comportarsi in modo
# strano dopo un bump di DMS, confrontare con il nuovo default upstream.
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
