FROM quay.io/fedora-ostree-desktops/silverblue:44

# 1. Inyección de llaves GPG y repositorios (Solo dependencias Core/Infra)
RUN rpm --import https://pkgs.tailscale.com/stable/fedora/repo.gpg && \
    curl -sL https://pkgs.tailscale.com/stable/fedora/tailscale.repo -o /etc/yum.repos.d/tailscale.repo

# BARRERA DE CACHÉ: Invalida de aquí en adelante para transacciones diarias
ARG CACHE_BUSTER=0

# 2. Transacción core: Herramientas de sistema, hardware y terminal
RUN rpm-ostree override remove \
        firefox \
        firefox-langpacks && \
    rpm-ostree install \
        btop \
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
        zsh-autosuggestions \
        zsh-syntax-highlighting \
        steam-devices && \
    rpm-ostree cleanup -m

# 3. Inyección de Starship
RUN curl -sS https://starship.rs/install.sh | sh -s -- -y -b /usr/bin

# 4. Tuning de Hardware (ZRAM IA, Sysctl y Wi-Fi)
RUN mkdir -p /etc/systemd/zram-generator.conf.d /etc/modprobe.d /etc/sysctl.d && \
    echo -e "[zram0]\nzram-size = ram\ncompression-algorithm = zstd" > /etc/systemd/zram-generator.conf.d/ai-workload.conf && \
    echo -e "vm.swappiness = 180\nvm.page-cluster = 0\nvm.watermark_boost_factor = 0" > /etc/sysctl.d/99-ai-zram-tuning.conf && \
    echo "options iwlwifi power_save=1" > /etc/modprobe.d/iwlwifi.conf

# 5. Automatización ACPI y Batería
RUN mkdir -p /etc/udev/rules.d /etc/tmpfiles.d && \
    echo -e 'SUBSYSTEM=="power_supply", ATTR{online}=="0", RUN+="/usr/bin/systemd-run --no-block /usr/bin/powerprofilesctl set power-saver"\nSUBSYSTEM=="power_supply", ATTR{online}=="1", RUN+="/usr/bin/systemd-run --no-block /usr/bin/powerprofilesctl set balanced"' > /etc/udev/rules.d/99-battery.rules && \
    echo "w /sys/bus/platform/drivers/ideapad_acpi/VPC2004:00/conservation_mode - - - - 1" > /etc/tmpfiles.d/lenovo-conservation.conf

# 6. Activación de Servicios Base
RUN ln -sf /usr/lib/systemd/system/podman-auto-update.timer /usr/lib/systemd/system/multi-user.target.wants/ && \
    ln -sf /usr/lib/systemd/system/tailscaled.service /usr/lib/systemd/system/multi-user.target.wants/ && \
    ln -sf /usr/lib/systemd/system/thermald.service /usr/lib/systemd/system/multi-user.target.wants/

# 7. Sello del commit inmutable
RUN ostree container commit