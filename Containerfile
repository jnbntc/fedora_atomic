FROM quay.io/fedora-ostree-desktops/silverblue:44

# Inyección de repositorios
RUN cat <<REPOS > /etc/yum.repos.d/microsoft-edge.repo
[microsoft-edge]
name=microsoft-edge
baseurl=https://packages.microsoft.com/yumrepos/edge/
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
REPOS

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
