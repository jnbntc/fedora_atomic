FROM quay.io/fedora-ostree-desktops/silverblue:44

# 1. Inyección de repositorios de infraestructura
RUN curl -sL https://pkgs.tailscale.com/stable/fedora/tailscale.repo -o /etc/yum.repos.d/tailscale.repo

# 2. Modificación de la imagen base (Purga de navegadores redundantes)
RUN rpm-ostree override remove \
    firefox \
    firefox-langpacks

# 3. Instalación de utilidades core, telemetría y virtualización
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
    libva-intel-media-driver \
    intel-gpu-tools \
    clinfo \
    restic \
    qemu-system-x86 \
    edk2-ovmf \
    evtest \
    thermald

# 4. Automatización de Energía (Inyección de Reglas Udev en el Anillo 0)
RUN mkdir -p /etc/udev/rules.d && \
    echo 'SUBSYSTEM=="power_supply", ATTR{online}=="0", RUN+="/usr/bin/powerprofilesctl set power-saver"' > /etc/udev/rules.d/99-battery.rules && \
    echo 'SUBSYSTEM=="power_supply", ATTR{online}=="1", RUN+="/usr/bin/powerprofilesctl set balanced"' >> /etc/udev/rules.d/99-battery.rules

# 5. Habilitación de servicios base (Auto-update, VPN y Control Térmico Intel)
RUN ln -s /usr/lib/systemd/system/podman-auto-update.timer \
    /usr/lib/systemd/system/multi-user.target.wants/podman-auto-update.timer && \
    ln -s /usr/lib/systemd/system/tailscaled.service \
    /usr/lib/systemd/system/multi-user.target.wants/tailscaled.service && \
    ln -s /usr/lib/systemd/system/thermald.service \
    /usr/lib/systemd/system/multi-user.target.wants/thermald.service

# Cierre del commit inmutable
RUN ostree container commit
