FROM quay.io/fedora-ostree-desktops/silverblue:44

# 1. Inyección de repositorios de infraestructura (Tailscale y Microsoft)
RUN curl -sL https://pkgs.tailscale.com/stable/fedora/tailscale.repo -o /etc/yum.repos.d/tailscale.repo && \
    echo -e "[code]\nname=Visual Studio Code\nbaseurl=https://packages.microsoft.com/yumrepos/vscode\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc" > /etc/yum.repos.d/vscode.repo

# 2. Purga de entropía upstream
RUN rpm-ostree override remove \
    firefox \
    firefox-langpacks

# 3. Stack Core, Virtualización, IDE Nativo y Controladores de Hardware (XPU)
# NOTA: oneapi e intel-compute son drivers del kernel base, estrictamente 
# necesarios para el passthrough de /dev/dri hacia los contenedores Podman.
# Se inyecta 'code' para evitar los problemas de sockets de la versión Flatpak.
RUN rpm-ostree install \
    code \
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
    alacritty \
    zsh-autosuggestions \
    zsh-syntax-highlighting

# 3.5. Inyección nativa de Starship (Binario Estático Rust)
RUN curl -sS https://starship.rs/install.sh | sh -s -- -y -b /usr/bin

# 4. Tuning de Hardware (ZRAM IA & Wi-Fi ASPM)
RUN mkdir -p /etc/systemd/zram-generator.conf.d && \
    echo -e "[zram0]\nzram-size = ram\ncompression-algorithm = zstd" > /etc/systemd/zram-generator.conf.d/ai-workload.conf && \
    mkdir -p /etc/modprobe.d && \
    echo "options iwlwifi power_save=1" > /etc/modprobe.d/iwlwifi.conf

# 5. Automatización ACPI y Batería (Udev & Lenovo Conservation)
RUN mkdir -p /etc/udev/rules.d && \
    echo 'SUBSYSTEM=="power_supply", ATTR{online}=="0", RUN+="/usr/bin/powerprofilesctl set power-saver"' > /etc/udev/rules.d/99-battery.rules && \
    echo 'SUBSYSTEM=="power_supply", ATTR{online}=="1", RUN+="/usr/bin/powerprofilesctl set balanced"' >> /etc/udev/rules.d/99-battery.rules && \
    echo -e "[Unit]\nDescription=Lenovo Conservation Mode\nAfter=multi-user.target\n\n[Service]\nType=oneshot\nExecStart=/bin/bash -c 'CONSERVATION_PATH=\$(find /sys -type f -name conservation_mode | head -n 1); if [ -n \"\$CONSERVATION_PATH\" ]; then echo 1 > \"\$CONSERVATION_PATH\"; fi'\n\n[Install]\nWantedBy=multi-user.target" > /etc/systemd/system/lenovo-conservation.service

# 6. Activación del Árbol de Servicios Base
RUN ln -s /usr/lib/systemd/system/podman-auto-update.timer \
    /usr/lib/systemd/system/multi-user.target.wants/podman-auto-update.timer && \
    ln -s /usr/lib/systemd/system/tailscaled.service \
    /usr/lib/systemd/system/multi-user.target.wants/tailscaled.service && \
    ln -s /usr/lib/systemd/system/thermald.service \
    /usr/lib/systemd/system/multi-user.target.wants/thermald.service && \
    ln -s /etc/systemd/system/lenovo-conservation.service \
    /usr/lib/systemd/system/multi-user.target.wants/lenovo-conservation.service

# 7. Sello del commit inmutable
RUN ostree container commit
