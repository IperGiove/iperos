# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /

# Base Image (Universal Blue, Nvidia variant)
# Minimal image: no desktop to tear down, open NVIDIA drivers (kmod-nvidia,
# Dual MIT/GPL) managed by rpm, rebuilt daily on Fedora 44.
# Replaces registry.gitlab.com/origami-linux/images/origami-nvidia:latest,
# which was stuck at 2026-06-02, shipped the COSMIC desktop, and had a
# proprietary driver installed outside rpm.
# Its /etc/os-release already has ID=fedora, so there's no need to fix it
# anymore.
FROM ghcr.io/ublue-os/base-nvidia:latest

### MODIFICATIONS
## Customizations and package installation happen in build.sh

# Homebrew (user package manager, at runtime, on the immutable system)
COPY --from=ghcr.io/ublue-os/brew:latest /system_files /
RUN --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /usr/bin/systemctl preset brew-setup.service && \
    /usr/bin/systemctl preset brew-update.timer && \
    /usr/bin/systemctl preset brew-upgrade.timer

# Runs build.sh (installs Niri, DMS, greetd, apps, removes COSMIC, etc.)
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build.sh

### LINTING
## Verify the final image is a valid bootc image.
RUN bootc container lint
