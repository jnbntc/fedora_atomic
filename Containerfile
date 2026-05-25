FROM quay.io/fedora-ostree-desktops/silverblue:44

# Inyección de repositorios (Sintaxis POSIX estricta para parser de Buildah)
RUN printf "[microsoft-edge]\nname=microsoft-edge\nbaseurl=https://packages.microsoft.com/yumrepos/edge/\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc\n" > /etc/yum.repos.d/microsoft-edge.repo

# Instalación de paquetes atómicos
RUN rpm-ostree install \
    microsoft-edge-stable \
    btop \
    nmap \
    tmux \
    zsh \
    && rpm-ostree cleanup -a

# Habilitación de servicios base (Auto-update de Podman)
RUN ln -s /usr/lib/systemd/system/podman-auto-update.timer \
    /usr/lib/systemd/system/multi-user.target.wants/podman-auto-update.timer

# Cierre del commit inmutable
RUN ostree container commit
