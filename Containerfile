FROM quay.io/fedora-ostree-desktops/silverblue:44

# Inyección de repositorios
RUN printf "[microsoft-edge]\nname=microsoft-edge\nbaseurl=https://packages.microsoft.com/yumrepos/edge/\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc\n" > /etc/yum.repos.d/microsoft-edge.repo

# Instalación atómica
RUN rpm-ostree install \
    microsoft-edge-stable \
    btop \
    nmap \
    tmux \
    zsh \
    && rpm-ostree cleanup -a

# Hack de ingeniería: Mudar binarios de /opt (volátil) a /usr (persistente) y parchear rutas
RUN mkdir -p /usr/lib/opt/microsoft && \
    mv /opt/microsoft/edge /usr/lib/opt/microsoft/ && \
    sed -i 's|/opt/microsoft/edge|/usr/lib/opt/microsoft/edge|g' /usr/bin/microsoft-edge-stable && \
    sed -i 's|/opt/microsoft/edge|/usr/lib/opt/microsoft/edge|g' /usr/share/applications/microsoft-edge.desktop

# Habilitación de servicios
RUN ln -s /usr/lib/systemd/system/podman-auto-update.timer \
    /usr/lib/systemd/system/multi-user.target.wants/podman-auto-update.timer

# Commit final de la capa
RUN ostree container commit
