# 📦 Fedora Atomic - OCI Native Desktop

[![Build Custom Fedora Atomic](https://github.com/jnbntc/fedora_atomic/actions/workflows/build.yml/badge.svg)](https://github.com/jnbntc/fedora_atomic/actions/workflows/build.yml)
[![Base](https://img.shields.io/badge/Base-Fedora_Silverblue_44-blue.svg)](https://fedoraproject.org/silverblue/)
[![Paradigm](https://img.shields.io/badge/Architecture-OCI_Native-green.svg)](#)

Repositorio de Infraestructura como Código (IaC) para el aprovisionamiento y mantenimiento de una estación de trabajo basada en **Fedora Silverblue 44**.

La arquitectura implementa un modelo estricto de **Desacople CI/CD**, desplazando la carga de cálculo y resolución de dependencias hacia GitHub Actions, entregando un artefacto OCI final al *endpoint* local para su *staging* asíncrono.

> **Estado de seguridad del pipeline:** el escaneo Trivy actual es **advisory** y no constituye todavía un gate de vulnerabilidades para Fedora/OSTree. La validación de seguridad compatible con este formato, junto con SBOM y políticas de bloqueo explícitas, se incorporará en una etapa posterior.

---

## 🏗️ Arquitectura de Despliegue

### 1. Nivel CI: The Build Pipeline
El ciclo de vida de la imagen base está orquestado por GitHub Actions mediante:

* **Push controlado:** cambios en `main` que afecten al `Containerfile`, al workflow o a futuros archivos de configuración/scripts disparan un nuevo build.
* **Nightly:** `cron: '17 22 * * *'` (22:17 UTC / 19:17 ART). El minuto 17 evita concentrar la ejecución exactamente al comienzo de la hora.
* **Ejecución manual:** `workflow_dispatch` permanece disponible para validaciones y recuperación. Las ejecuciones manuales sobre ramas distintas de `main` construyen y validan la imagen, pero no publican `latest`/`YYYYMMDD` ni ejecutan la purga del registro.

El workflow usa un **cache-buster diario UTC** (`YYYYMMDD`) para forzar como máximo una invalidación deliberada de la transacción principal por día, permitiendo reutilizar caché en reintentos o ejecuciones manuales posteriores del mismo día.

* **Motor OCI:** se utiliza `podman` nativo junto con `buildah` para construir la imagen basada en OSTree.
* **SecScan advisory (Trivy):** la imagen compilada se exporta temporalmente a `.tar` y Trivy intenta inspeccionar vulnerabilidades de sistema operativo. Actualmente este resultado no bloquea el pipeline y no debe interpretarse como garantía de ausencia de CVE en Fedora/OSTree.
* **Registro:** tras completar el build, la imagen se publica en **GHCR** bajo las etiquetas `latest` y `YYYYMMDD`. La firma criptográfica del artefacto todavía no está implementada y se incorporará en una etapa posterior.

### 2. Nivel CD: Local Staging
El host local (notebook) opera como un nodo pasivo de consumo.
* **Staging Asíncrono:** a través de un *drop-in* de Systemd (`rpm-ostreed-automatic.timer`), el host descarga los deltas diariamente a la 01:00 AM (o al encenderse vía `Persistent=true`) y pre-ensambla el árbol en disco (`AutomaticUpdatePolicy=stage`).
* **RAM Optimization:** `rpm-ostreed.conf` forzado a `IdleExitTimeout=60` para evicción estricta de memoria, liberando recursos para cargas locales (LLMs y telemetría).

---

## 📦 Composición del Árbol (OSTree)

### Anillo 0 (Cloud-Baked OCI Image)
Paquetes y servicios inyectados nativamente en la compilación remota. El host no gasta ciclos de CPU en resolver este stack:
* **Infraestructura y Redes:** `tailscale` (VPN + nodo de salida).
* **Telemetría y Gestión:** suite `cockpit` (system/podman/machines), `btop`.
* **Desarrollo y Contenedores:** `distrobox`, `tmux`, `zsh`, `code`, `fira-code-fonts`, `jetbrains-mono-fonts`.
* **Aceleración Gráfica (OpenCL/VAAPI):** `intel-compute-runtime`, `libva-intel-media-driver`, `oneapi-level-zero`, `intel-gpu-tools`, `clinfo`, `vulkan-tools`.
* **Virtualización y QA:** `virt-manager`, `libvirt-daemon-kvm`, `libvirt-client`, `swtpm`, `qemu-system-x86`, `edk2-ovmf`, `evtest`.
* **Backup:** `restic`.
* **Purgas:** se extrae `firefox` y sus langpacks base para reducir superficie de ataque.

### Layering Dinámico (LocalPackages)
Paquetes excluidos intencionalmente de la imagen OCI debido a la ejecución de scripts `%post` agresivos que rompen el *sandbox* del compilador. Se superponen localmente sobre el host conectándolos a sus repositorios oficiales para su auto-actualización:
* `microsoft-edge-stable`
* `teamviewer`

---

## 🛠️ Disaster Recovery & Mantenimiento Local

### Forzar actualización (Bypass de Systemd)
```bash
rpm-ostree upgrade
sudo systemctl reboot
```
