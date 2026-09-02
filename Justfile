export image_name := env("IMAGE_NAME", "iperos") # output image name, usually same as repo name, change as needed
export default_tag := env("DEFAULT_TAG", "latest")
export bib_image := env("BIB_IMAGE", "quay.io/centos-bootc/bootc-image-builder:latest")

alias build-vm := build-qcow2
alias rebuild-vm := rebuild-qcow2
alias run-vm := run-vm-qcow2

[private]
default:
    @just --list

# Check Just Syntax
[group('Just')]
check:
    #!/usr/bin/bash
    find . -type f -name "*.just" | while read -r file; do
    	echo "Checking syntax: $file"
    	just --unstable --fmt --check -f $file
    done
    echo "Checking syntax: Justfile"
    just --unstable --fmt --check -f Justfile

# Fix Just Syntax
[group('Just')]
fix:
    #!/usr/bin/bash
    find . -type f -name "*.just" | while read -r file; do
    	echo "Checking syntax: $file"
    	just --unstable --fmt -f $file
    done
    echo "Checking syntax: Justfile"
    just --unstable --fmt -f Justfile || { exit 1; }

# Clean Repo
[group('Utility')]
clean:
    #!/usr/bin/bash
    set -eoux pipefail
    touch _build
    find *_build* -exec rm -rf {} \;
    rm -f previous.manifest.json
    rm -f changelog.md
    rm -f output.env
    rm -rf output/

# Sudo Clean Repo
[group('Utility')]
[private]
sudo-clean:
    just sudoif just clean

# sudoif bash function
[group('Utility')]
[private]
sudoif command *args:
    #!/usr/bin/bash
    function sudoif(){
        if [[ "${UID}" -eq 0 ]]; then
            "$@"
        elif [[ "$(command -v sudo)" && -n "${SSH_ASKPASS:-}" ]] && [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
            # sudo --askpass legge SUDO_ASKPASS, non SSH_ASKPASS: senza questa riga
            # fallisce con "no askpass program specified" su ogni desktop che imposta
            # solo SSH_ASKPASS (GNOME/Fedora Workstation lo fa di default).
            SUDO_ASKPASS="${SUDO_ASKPASS:-$SSH_ASKPASS}" /usr/bin/sudo --askpass "$@" || exit 1
        elif [[ "$(command -v sudo)" ]]; then
            /usr/bin/sudo "$@" || exit 1
        else
            exit 1
        fi
    }
    sudoif {{ command }} {{ args }}

# This Justfile recipe builds a container image using Podman.
#
# Arguments:
#   $target_image - The tag you want to apply to the image (default: $image_name).
#   $tag - The tag for the image (default: $default_tag).
#
# The script constructs the version string using the tag and the current date.
# If the git working directory is clean, it also includes the short SHA of the current HEAD.
#
# just build $target_image $tag
#
# Example usage:
#   just build aurora lts
#
# This will build an image 'aurora:lts' with DX and GDX enabled.
#

# Build the image using the specified parameters
build $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash

    BUILD_ARGS=()
    if [[ -z "$(git status -s)" ]]; then
        BUILD_ARGS+=("--build-arg" "SHA_HEAD_SHORT=$(git rev-parse --short HEAD)")
    fi

    podman build \
        "${BUILD_ARGS[@]}" \
        --pull=newer \
        --tag "${target_image}:${tag}" \
        .

# Command: _rootful_load_image
# Description: This script checks if the current user is root or running under sudo. If not, it attempts to resolve the image tag using podman inspect.
#              If the image is found, it loads it into rootful podman. If the image is not found, it pulls it from the repository.
#
# Parameters:
#   $target_image - The name of the target image to be loaded or pulled.
#   $tag - The tag of the target image to be loaded or pulled. Default is 'default_tag'.
#
# Example usage:
#   _rootful_load_image my_image latest
#
# Steps:
# 1. Check if the script is already running as root or under sudo.
# 2. Check if target image is in the non-root podman container storage)
# 3. If the image is found, load it into rootful podman using podman scp.
# 4. If the image is not found, pull it from the remote repository into reootful podman.

_rootful_load_image $target_image=image_name $tag=default_tag:
    #!/usr/bin/bash
    set -eoux pipefail

    # Check if already running as root or under sudo
    if [[ -n "${SUDO_USER:-}" || "${UID}" -eq "0" ]]; then
        echo "Already root or running under sudo, no need to load image from user podman."
        exit 0
    fi

    # Try to resolve the image tag using podman inspect
    set +e
    resolved_tag=$(podman inspect -t image "${target_image}:${tag}" | jq -r '.[].RepoTags.[0]')
    return_code=$?
    set -e

    USER_IMG_ID=$(podman images --filter reference="${target_image}:${tag}" --format "'{{ '{{.ID}}' }}'")

    if [[ $return_code -eq 0 ]]; then
        # If the image is found, load it into rootful podman
        ID=$(just sudoif podman images --filter reference="${target_image}:${tag}" --format "'{{ '{{.ID}}' }}'")
        if [[ "$ID" != "$USER_IMG_ID" ]]; then
            # "podman image scp" scrive un tar temporaneo di diversi GB e poi lo
            # ricarica. Su immagini grandi (qui ~10 GB) va in crash con SIGABRT
            # dentro il progress bar (mpb), lasciando il tar sul disco.
            # save|load in pipe fa lo stesso lavoro senza file intermedi.
            podman save "${target_image}:${tag}" | just sudoif podman load
        fi
    else
        # If the image is not found, pull it from the repository
        just sudoif podman pull "${target_image}:${tag}"
    fi

# Build a bootc bootable image using Bootc Image Builder (BIB)
# Converts a container image to a bootable image
# Parameters:
#   target_image: The name of the image to build (ex. localhost/fedora)
#   tag: The tag of the image to build (ex. latest)
#   type: The type of image to build (ex. qcow2, raw, iso)
#   config: The configuration file to use for the build (default: disk_config/disk.toml)

# Example: just _rebuild-bib localhost/fedora latest qcow2 disk_config/disk.toml
_build-bib $target_image $tag $type $config: (_rootful_load_image target_image tag)
    #!/usr/bin/env bash
    set -euo pipefail

    args="--type ${type} "
    args+="--use-librepo=True "
    args+="--rootfs=btrfs"

    BUILDTMP=$(mktemp -p "${PWD}" -d -t _build-bib.XXXXXXXXXX)

    sudo podman run \
      --rm \
      -it \
      --privileged \
      --pull=newer \
      --net=host \
      --security-opt label=type:unconfined_t \
      -v $(pwd)/${config}:/config.toml:ro \
      -v $BUILDTMP:/output \
      -v /var/lib/containers/storage:/var/lib/containers/storage \
      "${bib_image}" \
      ${args} \
      "${target_image}:${tag}"

    mkdir -p output
    sudo mv -f $BUILDTMP/* output/
    sudo rmdir $BUILDTMP
    sudo chown -R $USER:$USER output/

# Podman builds the image from the Containerfile and creates a bootable image
# Parameters:
#   target_image: The name of the image to build (ex. localhost/fedora)
#   tag: The tag of the image to build (ex. latest)
#   type: The type of image to build (ex. qcow2, raw, iso)
#   config: The configuration file to use for the build (deafult: disk_config/disk.toml)

# Example: just _rebuild-bib localhost/fedora latest qcow2 disk_config/disk.toml
_rebuild-bib $target_image $tag $type $config: (build target_image tag) && (_build-bib target_image tag type config)

# Build a QCOW2 virtual machine image
[group('Build Virtal Machine Image')]
build-qcow2 $target_image=("localhost/" + image_name) $tag=default_tag: && (_build-bib target_image tag "qcow2" "disk_config/disk.toml")

# Build a QCOW2 for VM testing, WITH a login user.
# disk.toml non definisce nessun utente e root e' bloccato: una VM costruita con
# "build-qcow2" si ferma a "login:" senza credenziali possibili. Questa ricetta usa
# disk_config/disk-test.toml, che e' in .gitignore perche' contiene una password in
# chiaro e non deve finire nell'immagine reale.
[group('Build Virtal Machine Image')]
build-qcow2-test $target_image=("localhost/" + image_name) $tag=default_tag: && (_build-bib target_image tag "qcow2" "disk_config/disk-test.toml")
    #!/usr/bin/bash
    if [[ ! -f disk_config/disk-test.toml ]]; then
        echo "Manca disk_config/disk-test.toml. Crealo cosi':" >&2
        echo "" >&2
        echo '  [[customizations.filesystem]]' >&2
        echo '  mountpoint = "/"' >&2
        echo '  minsize = "20 GiB"' >&2
        echo "" >&2
        echo '  [[customizations.user]]' >&2
        echo '  name = "tuonome"' >&2
        echo '  password = "unapassword"' >&2
        echo '  groups = ["wheel"]' >&2
        exit 1
    fi

# Build a RAW virtual machine image
[group('Build Virtal Machine Image')]
build-raw $target_image=("localhost/" + image_name) $tag=default_tag: && (_build-bib target_image tag "raw" "disk_config/disk.toml")

# Build a RAW image for testing on real hardware from an external USB disk.
# Stesso disk-test.toml della VM: include un utente per il login.
[group('Build Virtal Machine Image')]
build-raw-test $target_image=("localhost/" + image_name) $tag=default_tag: && (_build-bib target_image tag "raw" "disk_config/disk-test.toml")
    #!/usr/bin/bash
    if [[ ! -f disk_config/disk-test.toml ]]; then
        echo "Manca disk_config/disk-test.toml (vedi build-qcow2-test)." >&2
        exit 1
    fi

# Build an ISO virtual machine image
[group('Build Virtal Machine Image')]
build-iso $target_image=("localhost/" + image_name) $tag=default_tag: && (_build-bib target_image tag "iso" "disk_config/iso.toml")

# Rebuild a QCOW2 virtual machine image
[group('Build Virtal Machine Image')]
rebuild-qcow2 $target_image=("localhost/" + image_name) $tag=default_tag: && (_rebuild-bib target_image tag "qcow2" "disk_config/disk.toml")

# Rebuild a RAW virtual machine image
[group('Build Virtal Machine Image')]
rebuild-raw $target_image=("localhost/" + image_name) $tag=default_tag: && (_rebuild-bib target_image tag "raw" "disk_config/disk.toml")

# Rebuild an ISO virtual machine image
[group('Build Virtal Machine Image')]
rebuild-iso $target_image=("localhost/" + image_name) $tag=default_tag: && (_rebuild-bib target_image tag "iso" "disk_config/iso.toml")

# Run a virtual machine with the specified image type and configuration
_run-vm $target_image $tag $type $config:
    #!/usr/bin/bash
    set -eoux pipefail

    # Determine the image file based on the type
    image_file="output/${type}/disk.${type}"
    if [[ $type == iso ]]; then
        image_file="output/bootiso/install.iso"
    fi

    # Se l'immagine manca ci si ferma invece di ricostruirla di nascosto: la
    # ricostruzione automatica usava disk.toml, che NON crea nessun utente, e
    # produceva dopo un'ora una VM in cui era impossibile fare login.
    if [[ ! -f "${image_file}" ]]; then
        echo "Immagine non trovata: ${image_file}" >&2
        echo "" >&2
        echo "  per una VM di TEST (con utente admin/admin):  just build-${type}-test" >&2
        echo "  per l'immagine REALE (senza utente):          just build-${type}" >&2
        exit 1
    fi

    # Determine an available port to use
    port=8006
    while grep -q :${port} <<< $(ss -tunalp); do
        port=$(( port + 1 ))
    done
    echo "Using Port: ${port}"
    echo "Connect to http://localhost:${port}"

    # Set up the arguments for running the VM
    run_args=()
    # -it: senza stdin collegato la console seriale e' di sola lettura e non si
    # riesce a fare login ne' a diagnosticare nulla dal terminale.
    run_args+=(--rm --privileged -it)
    run_args+=(--pull=newer)
    run_args+=(--publish "127.0.0.1:${port}:8006")
    run_args+=(--env "CPU_CORES=4")
    run_args+=(--env "RAM_SIZE=8G")
    run_args+=(--env "DISK_SIZE=64G")
    run_args+=(--env "TPM=Y")
    # GPU=Y fa passare a qemux/qemu l'opzione virtio-vga-gl,host3d_blob_limit=...,
    # proprieta' che QEMU 11.1 (quello incluso nell'immagine) non ha piu': la VM
    # muore con "Property 'virtio-vga-gl.host3d_blob_limit' not found".
    # Default disattivato; per riattivarlo quando l'upstream avra' corretto:
    #   VM_GPU=Y just run-vm-qcow2
    run_args+=(--env "GPU=${VM_GPU:-N}")
    run_args+=(--device=/dev/kvm)
    run_args+=(--volume "${PWD}/${image_file}":"/boot.${type}")
    run_args+=(docker.io/qemux/qemu)

    # Run the VM and open the browser to connect
    (sleep 30 && xdg-open http://localhost:"$port") &
    podman run "${run_args[@]}"

# Run a virtual machine from a QCOW2 image
[group('Run Virtal Machine')]
run-vm-qcow2 $target_image=("localhost/" + image_name) $tag=default_tag: && (_run-vm target_image tag "qcow2" "disk_config/disk.toml")

# Run a virtual machine from a RAW image
[group('Run Virtal Machine')]
run-vm-raw $target_image=("localhost/" + image_name) $tag=default_tag: && (_run-vm target_image tag "raw" "disk_config/disk.toml")

# Run a virtual machine from an ISO
[group('Run Virtal Machine')]
run-vm-iso $target_image=("localhost/" + image_name) $tag=default_tag: && (_run-vm target_image tag "iso" "disk_config/iso.toml")

# Run the VM with the HOST's qemu instead of the qemux container.
# Serve per avere accelerazione 3D vera (virtio-vga-gl + virgl). Senza di essa
# niri non trova un allocatore GBM ("no allocator available for device"), non
# espone nessun output, e il greeter resta su uno schermo nero.
# Il container qemux non puo' farlo: con GPU=Y passa a QEMU l'opzione
# virtio-vga-gl,host3d_blob_limit=... che le QEMU recenti non hanno piu'.
[group('Run Virtal Machine')]
run-vm-native type="qcow2" ram="8G" cpus="4":
    #!/usr/bin/env bash
    set -euo pipefail

    image_file="output/{{ type }}/disk.{{ type }}"
    if [[ ! -f "$image_file" ]]; then
        echo "Manca $image_file" >&2
        echo "  costruiscilo con:  just build-{{ type }}-test" >&2
        exit 1
    fi

    OVMF_CODE=/usr/share/edk2/ovmf/OVMF_CODE.fd
    OVMF_VARS=/usr/share/edk2/ovmf/OVMF_VARS.fd
    for f in "$OVMF_CODE" "$OVMF_VARS"; do
        [[ -f "$f" ]] || { echo "Manca $f: dnf install edk2-ovmf" >&2; exit 1; }
    done

    # OVMF_VARS deve essere scrivibile: se ne usa una copia usa e getta
    VARS=$(mktemp -t ovmf-vars-XXXXXXXX.fd)
    cp "$OVMF_VARS" "$VARS"
    trap 'rm -f "$VARS"' EXIT

    exec qemu-system-x86_64 \
      -machine q35,accel=kvm -cpu host \
      -smp {{ cpus }} -m {{ ram }} \
      -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
      -drive if=pflash,format=raw,file="$VARS" \
      -drive file="$image_file",if=virtio,format={{ type }} \
      -device virtio-vga-gl -display gtk,gl=on,show-cursor=on \
      -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
      -device virtio-tablet-pci -device virtio-keyboard-pci

# Run a virtual machine using systemd-vmspawn
[group('Run Virtal Machine')]
spawn-vm rebuild="0" type="qcow2" ram="6G":
    #!/usr/bin/env bash

    set -euo pipefail

    [ "{{ rebuild }}" -eq 1 ] && echo "Rebuilding the ISO" && just build-vm {{ rebuild }} {{ type }}

    systemd-vmspawn \
      -M "bootc-image" \
      --console=gui \
      --cpus=2 \
      --ram=$(echo {{ ram }}| /usr/bin/numfmt --from=iec) \
      --network-user-mode \
      --vsock=false --pass-ssh-key=false \
      -i ./output/**/*.{{ type }}


# Runs shell check on all Bash scripts
lint:
    #!/usr/bin/env bash
    set -eoux pipefail
    # Check if shellcheck is installed
    if ! command -v shellcheck &> /dev/null; then
        echo "shellcheck could not be found. Please install it."
        exit 1
    fi
    # Run shellcheck on all Bash scripts
    /usr/bin/find . -iname "*.sh" -type f -exec shellcheck "{}" ';'

# Runs shfmt on all Bash scripts
format:
    #!/usr/bin/env bash
    set -eoux pipefail
    # Check if shfmt is installed
    if ! command -v shfmt &> /dev/null; then
        echo "shfmt could not be found. Please install it."
        exit 1
    fi
    # Run shfmt on all Bash scripts
    /usr/bin/find . -iname "*.sh" -type f -exec shfmt --write "{}" ';'
