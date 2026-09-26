FROM quay.io/fedora-ostree-desktops/silverblue:44

# 1. Repositorios externos y llaves GPG
# vscode.repo se versiona como IaC porque es configuración propia.
COPY files/etc/yum.repos.d/vscode.repo /etc/yum.repos.d/vscode.repo

RUN rpm --import https://packages.microsoft.com/keys/microsoft.asc && \
    rpm --import https://pkgs.tailscale.com/stable/fedora/repo.gpg && \
    curl -sL https://pkgs.tailscale.com/stable/fedora/tailscale.repo -o /etc/yum.repos.d/tailscale.repo

# BARRERA DE CACHÉ: invalida como máximo una vez por día la transacción principal.
ARG CACHE_BUSTER=0

# 2. Transacción core: herramientas de sistema, terminal, VS Code y KVM
RUN rpm-ostree override remove \
        firefox \
        firefox-langpacks && \
    rpm-ostree install \
        code \
        virt-manager \
        libvirt-daemon-kvm \
        libvirt-client \
        swtpm \
        btop \
        tmux \
        zsh \
        cockpit \
        cockpit-podman \
        cockpit-machines \
        cockpit-system \
        distrobox \
        fira-code-fonts \
        jetbrains-mono-fonts \
        tailscale \
        intel-compute-runtime \
        libva-intel-media-driver \
        oneapi-level-zero \
        oneapi-level-zero-devel \
        intel-gpu-tools \
        clinfo \
        vulkan-tools \
        restic \
        qemu-system-x86 \
        edk2-ovmf \
        evtest \
        thermald \
        zsh-autosuggestions \
        zsh-syntax-highlighting \
        steam-devices && \
    rpm-ostree cleanup -m

# 3. Starship pinneado y verificado
ARG STARSHIP_VERSION=1.26.0
ARG STARSHIP_SHA256=321f0dd7af8340a5f2e6a8fec6538a04f617486f9ec70d878f91c09cd8deef22

RUN set -eux; \
    archive="/tmp/starship.tar.gz"; \
    curl --fail --location --retry 3 --retry-delay 2 \
      "https://github.com/starship/starship/releases/download/v${STARSHIP_VERSION}/starship-x86_64-unknown-linux-gnu.tar.gz" \
      -o "${archive}"; \
    printf '%s  %s\n' "${STARSHIP_SHA256}" "${archive}" | sha256sum -c -; \
    tar -xzf "${archive}" -C /usr/bin starship; \
    chmod 0755 /usr/bin/starship; \
    /usr/bin/starship --version; \
    rm -f "${archive}"

# 4. Configuración declarativa del sistema
# Copia /etc/profile.d, /etc/skel, zram, sysctl, modprobe, udev y tmpfiles
# desde el árbol versionado files/etc/.
COPY files/etc/ /etc/


# 5. Activación de Servicios Base
RUN ln -sf /usr/lib/systemd/system/podman-auto-update.timer /usr/lib/systemd/system/multi-user.target.wants/ && \
    ln -sf /usr/lib/systemd/system/tailscaled.service /usr/lib/systemd/system/multi-user.target.wants/ && \
    ln -sf /usr/lib/systemd/system/thermald.service /usr/lib/systemd/system/multi-user.target.wants/ && \
    ln -sf /usr/lib/systemd/system/libvirtd.service /usr/lib/systemd/system/multi-user.target.wants/

# 6. Sello del commit inmutable
RUN ostree container commit
