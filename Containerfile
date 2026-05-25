FROM quay.io/fedora-ostree-desktops/silverblue:44

# Instalación de utilidades core nativas (Infraestructura pura)
RUN rpm-ostree install \
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
