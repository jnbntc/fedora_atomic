# 📦 Fedora Atomic - OCI Native Desktop

[![Build Custom Fedora Atomic](https://github.com/jnbntc/fedora_atomic/actions/workflows/build.yml/badge.svg)](https://github.com/jnbntc/fedora_atomic/actions/workflows/build.yml)
[![Base](https://img.shields.io/badge/Base-Fedora_Silverblue_44-blue.svg)](https://fedoraproject.org/silverblue/)
[![Paradigm](https://img.shields.io/badge/Architecture-OCI_Native-green.svg)](#)

Repositorio de Infraestructura como Código (IaC) para el aprovisionamiento y mantenimiento de una estación de trabajo basada en **Fedora Silverblue 44**.

La arquitectura implementa un modelo estricto de **Desacople CI/CD**, desplazando la carga de cálculo, resolución de dependencias y escaneo de vulnerabilidades hacia la nube (GitHub Actions), entregando un artefacto OCI final y pre-validado al *endpoint* local para su *staging* asíncrono.

---

## 🏗️ Arquitectura de Despliegue

### 1. Nivel CI: The Build Pipeline
El ciclo de vida de la imagen base está orquestado por GitHub Actions operando en un esquema *Nightly* (`cron: '0 3 * * *'`).
* **Motor OCI:** Se utiliza `podman` nativo junto con `buildah` para sortear el límite estructural de OverlayFS (`max depth exceeded`) al apilar los *chunks* de OSTree.
* **SecScan Gatekeeper (Trivy):** Integración de IPS en la cadena de suministro. La imagen compilada se exporta temporalmente a `.tar` y se escanea en busca de vulnerabilidades a nivel de sistema operativo (`vuln-type: 'os'`). Ignora deliberadamente secretos (dummy keys) y vulnerabilidades sin parche upstream (`ignore-unfixed: true`) para evitar el bloqueo del pipeline por falsos positivos.
* **Registro:** Si el artefacto aprueba la auditoría, se empuja criptográficamente firmado a **GHCR** bajo la etiqueta `latest`.

### 2. Nivel CD: Local Staging
El host local (notebook) opera como un nodo pasivo de consumo.
* **Staging Asíncrono:** A través de un *drop-in* de Systemd (`rpm-ostreed-automatic.timer`), el host descarga los deltas diariamente a la 01:00 AM (o al encenderse vía `Persistent=true`) y pre-ensambla el árbol en disco (`AutomaticUpdatePolicy=stage`).
* **RAM Optimization:** `rpm-ostreed.conf` forzado a `IdleExitTimeout=60` para evicción estricta de memoria, liberando recursos para cargas locales (LLMs y telemetría).

---

## 📦 Composición del Árbol (OSTree)

### Anillo 0 (Cloud-Baked OCI Image)
Paquetes y servicios inyectados nativamente en la compilación remota. El host no gasta ciclos de CPU en resolver este stack:
* **Infraestructura y Redes:** `tailscale` (VPN + nodo de salida), `nmap`.
* **Telemetría y Gestión:** Suite `cockpit` (system/podman), `btop`.
* **Desarrollo y Contenedores:** `distrobox`, `tmux`, `zsh`, `fira-code-fonts`, `jetbrains-mono-fonts`.
* **Aceleración Gráfica (OpenCL/VAAPI):** `intel-compute-runtime`, `libva-intel-media-driver`, `intel-gpu-tools`, `clinfo`.
* **Virtualización y QA:** `qemu-system-x86`, `edk2-ovmf`, `evtest`.
* **Backup:** `restic`.
* **Purgas:** Se extrae `firefox` y sus langpacks base para reducir superficie de ataque.

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
