# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /

# Base Image (Origami, variante Nvidia)
FROM registry.gitlab.com/origami-linux/images/origami-nvidia:latest

# Origami imposta un proprio ID in /etc/os-release; lo riportiamo a "fedora"
# perche' alcuni repo/strumenti a valle si aspettano di girare su Fedora.
RUN sed -i 's/^ID=.*/ID=fedora/' /etc/os-release

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
