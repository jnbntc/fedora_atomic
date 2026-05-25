# 📦 Fedora Atomic - OCI Native Desktop

[![Build Custom Fedora Atomic](https://github.com/jnbntc/fedora_atomic/actions/workflows/build.yml/badge.svg)](https://github.com/jnbntc/fedora_atomic/actions/workflows/build.yml)
[![Base](https://img.shields.io/badge/Base-Fedora_Silverblue_44-blue.svg)](https://fedoraproject.org/silverblue/)
[![Paradigm](https://img.shields.io/badge/Architecture-OCI_Native-green.svg)](#)

Este repositorio define la infraestructura como código (IaC) para mi entorno de trabajo principal. Transforma una instalación estándar de Fedora Silverblue en un **sistema operativo declarativo, inmutable y empaquetado nativamente como una imagen OCI** (Open Container Initiative).

En lugar de mutar el sistema host mediante la instalación local de paquetes (`rpm-ostree install`), el árbol del sistema se compila de manera centralizada en GitHub Actions y se despliega como una imagen de contenedor.

## 🏗️ Arquitectura y Componentes Core

La imagen hereda de `quay.io/fedora-ostree-desktops/silverblue:44` y consolida estrictamente herramientas de infraestructura y capa base. Los entornos de desarrollo y aplicaciones privativas se delegan al espacio de usuario.

**Inyecciones en el Árbol OCI:**
* **SysAdmin / Redes:** `nmap`, `btop`
* **Terminal / Multiplexing:** `zsh`, `tmux`
* **Servicios del Host:** Habilitación nativa de `podman-auto-update.timer` para el ciclo de vida automatizado de contenedores (Quadlets).

## ⚙️ Pipeline CI/CD

El ciclo de compilación está automatizado mediante GitHub Actions.
* **Compilador:** `buildah` (Rootless).
* **Frecuencia:** Semanal (Todos los domingos a las 04:00 UTC) para consolidar parches de seguridad del *upstream*, mitigando la saturación de deltas en el registro.
* **Optimización de I/O:** Se utiliza `jlumbroso/free-disk-space` para la purga pasiva de SDKs en el *runner* de Ubuntu, evitando la corrupción de volúmenes lógicos durante la generación de la imagen.
* **Registro:** Publicación automática en GitHub Container Registry (GHCR).

## 🚀 Despliegue (Rebase)

Para pivotar una instalación de Fedora Silverblue/Kinoite hacia esta imagen OCI:

```bash
# 1. Cambiar la procedencia del árbol de SO hacia el registro OCI
sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/jnbntc/fedora_atomic:latest

# 2. Reiniciar para cargar el nuevo kernel y despliegue
sudo systemctl reboot
