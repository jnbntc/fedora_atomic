FROM quay.io/fedora-ostree-desktops/silverblue:44

# 1. Inyección de repositorios de infraestructura
RUN curl -sL https://pkgs.tailscale.com/stable/fedora/tailscale.repo -o /etc/yum.repos.d/tailscale.repo

# 2. Modificación de la imagen base (Purga de navegadores redundantes)
RUN rpm-ostree override remove \
    firefox \
    firefox-langpacks

# 3. Instalación de utilidades core y telemetría
# Instalación de utilidades core y telemetría de silicio
RUN rpm-ostree install \
    btop \
    nmap \
    tmux \
    zsh \
    cockpit \
    cockpit-podman \
    cockpit-system \
    distrobox \
    fira-code-fonts \
    jetbrains-mono-fonts \
    tailscale \
    intel-compute-runtime \
    intel-media-driver \
    clinfo

# 4. Habilitación de servicios base (Auto-update y VPN)
RUN ln -s /usr/lib/systemd/system/podman-auto-update.timer \
    /usr/lib/systemd/system/multi-user.target.wants/podman-auto-update.timer && \
    ln -s /usr/lib/systemd/system/tailscaled.service \
    /usr/lib/systemd/system/multi-user.target.wants/tailscaled.service

# Cierre del commit inmutable
RUN ostree container commit
