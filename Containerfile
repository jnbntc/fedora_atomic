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

# 3. Configuración declarativa del sistema
# Copia /etc/profile.d, /etc/skel, zram, sysctl, modprobe, udev y tmpfiles
# desde el árbol versionado files/etc/.
COPY files/etc/ /etc/

# 4. Inyección de Starship
RUN curl -sS https://starship.rs/install.sh | sh -s -- -y -b /usr/bin

# 5. Activación de Servicios Base
RUN ln -sf /usr/lib/systemd/system/podman-auto-update.timer /usr/lib/systemd/system/multi-user.target.wants/ && \
    ln -sf /usr/lib/systemd/system/tailscaled.service /usr/lib/systemd/system/multi-user.target.wants/ && \
    ln -sf /usr/lib/systemd/system/thermald.service /usr/lib/systemd/system/multi-user.target.wants/ && \
    ln -sf /usr/lib/systemd/system/libvirtd.service /usr/lib/systemd/system/multi-user.target.wants/

# 6. Sello del commit inmutable
RUN ostree container commit
