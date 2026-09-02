# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /

# Base Image (Universal Blue, variante Nvidia)
# Immagine minimale: nessun desktop da smontare, driver NVIDIA open (kmod-nvidia,
# Dual MIT/GPL) gestiti da rpm, ricostruita ogni giorno su Fedora 44.
# Sostituisce registry.gitlab.com/origami-linux/images/origami-nvidia:latest, che
# era ferma al 2026-06-02, portava il desktop COSMIC e un driver proprietario
# installato fuori da rpm.
# Il suo /etc/os-release ha gia' ID=fedora, quindi non serve piu' correggerlo.
FROM ghcr.io/ublue-os/base-nvidia:latest

### MODIFICATIONS
## Le personalizzazioni e l'installazione dei pacchetti avvengono in build.sh

# Homebrew (gestore pacchetti utente, a runtime, sul sistema immutabile)
COPY --from=ghcr.io/ublue-os/brew:latest /system_files /
RUN --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /usr/bin/systemctl preset brew-setup.service && \
    /usr/bin/systemctl preset brew-update.timer && \
    /usr/bin/systemctl preset brew-upgrade.timer

# Esegue build.sh (installa Niri, DMS, greetd, app, rimuove COSMIC, ecc.)
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build.sh

### LINTING
## Verifica che l'immagine finale sia un'immagine bootc valida.
RUN bootc container lint
