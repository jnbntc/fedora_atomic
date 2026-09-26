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

* **Push controlado:** cambios en `main` que afecten al `Containerfile`, al workflow de build o a futuros archivos de configuración de la imagen disparan un nuevo build.
* **Nightly:** `cron: '17 22 * * *'` (22:17 UTC / 19:17 ART). El minuto 17 evita concentrar la ejecución exactamente al comienzo de la hora.
* **Ejecución manual:** `workflow_dispatch` permanece disponible para validaciones y recuperación. Las ejecuciones manuales sobre ramas distintas de `main` construyen y validan la imagen, pero no publican `latest`/`YYYYMMDD` ni escriben en el cache compartido de GHCR; solo pueden reutilizarlo como fuente. En Etapa 4, las ejecuciones manuales pueden elegir un `privilege_profile` para probar de forma controlada qué relajaciones de Podman son realmente necesarias.

El workflow usa un **cache-buster diario UTC** (`YYYYMMDD`) para forzar como máximo una invalidación deliberada de la transacción principal por día, permitiendo reutilizar caché en reintentos o ejecuciones manuales posteriores del mismo día.

* **Motor OCI:** se utiliza `podman` nativo junto con `buildah` para construir la imagen basada en OSTree. El perfil estable conserva temporalmente `seccomp=unconfined`, `label=disable` y `cap-add=ALL`; los perfiles manuales de sondeo permiten retirar cada relajación por separado antes de cambiar el valor de producción.
* **SecScan advisory (Trivy):** la imagen compilada se exporta temporalmente a `.tar` y Trivy intenta inspeccionar vulnerabilidades de sistema operativo. Actualmente este resultado no bloquea el pipeline y no debe interpretarse como garantía de ausencia de CVE en Fedora/OSTree.
* **Registro:** tras completar el build, la imagen se publica en **GHCR** bajo las etiquetas `latest` y `YYYYMMDD`. La firma criptográfica del artefacto todavía no está implementada y se incorporará en una etapa posterior.

### 2. Mantenimiento de GHCR
La retención del registro está desacoplada del build y se gestiona mediante `.github/workflows/cleanup.yml` y `scripts/cleanup-ghcr.sh`.

* **Schedule:** domingo 04:37 UTC / 01:37 ART.
* **Manual:** `workflow_dispatch`, con `dry-run` como opción predeterminada.
* **Seguridad:** el script usa `set -Eeuo pipefail`, diferencia un `404` de otros errores de API y no oculta fallos de autenticación o del backend.
* **Retención:** elimina versiones `untagged`; para `fedora_atomic` conserva `latest`, todos los builds etiquetados de los últimos 14 días y además los 5 builds antiguos más recientes. Para `fedora_atomic/cache`, conserva todas las versiones etiquetadas de los últimos 14 días y garantiza un piso de 100 versiones etiquetadas recientes; las versiones de cache más antiguas que ambos límites se purgan.
* **Validación:** cada PR que modifica esta lógica ejecuta `bash -n`, ShellCheck y pruebas unitarias con un `gh` simulado, sin tocar GHCR.

### 3. Configuración declarativa del rootfs
La configuración propia del sistema ya no se genera mediante `echo` dentro del `Containerfile`. Se versiona directamente bajo `files/etc/` y se incorpora a la imagen mediante `COPY`.

Actualmente el árbol incluye:

```text
files/etc/
├── modprobe.d/iwlwifi.conf
├── profile.d/vscode-tune.sh
├── skel/.config/Code/User/settings.json
├── sysctl.d/99-ai-zram-tuning.conf
├── systemd/zram-generator.conf.d/ai-workload.conf
├── tmpfiles.d/lenovo-conservation.conf
├── udev/rules.d/99-battery.rules
└── yum.repos.d/vscode.repo
```

`vscode.repo` se copia antes de la transacción `rpm-ostree` porque es necesario para instalar VS Code; el árbol completo `files/etc/` se copia después de instalar paquetes para que cambios de configuración no invaliden innecesariamente la capa pesada de paquetes.

Los symlinks de servicios habilitados permanecen por ahora explícitos en el `Containerfile`: son estado de activación de systemd, no archivos regulares, y se migrarán solo si podemos conservar exactamente su semántica.

La coherencia del árbol se valida con `scripts/tests/test-config-tree.sh` y el workflow `Config Tree Validation`.

### 4. Nivel CD: Local Staging
El host local (notebook) opera como un nodo pasivo de consumo.
* **Staging Asíncrono:** a través de un *drop-in* de Systemd (`rpm-ostreed-automatic.timer`), el host descarga los deltas diariamente a la 01:00 AM (o al encenderse vía `Persistent=true`) y pre-ensambla el árbol en disco (`AutomaticUpdatePolicy=stage`).
* **RAM Optimization:** `rpm-ostreed.conf` forzado a `IdleExitTimeout=60` para evicción estricta de memoria, liberando recursos para cargas locales (LLMs y telemetría).

---

## 📦 Composición del Árbol (OSTree)

### Anillo 0 (Cloud-Baked OCI Image)
Paquetes y servicios inyectados nativamente en la compilación remota. El host no gasta ciclos de CPU en resolver este stack:
* **Infraestructura y Redes:** `tailscale` (VPN + nodo de salida).
* **Telemetría y Gestión:** suite `cockpit` (system/podman/machines), `btop`.
* **Desarrollo y Contenedores:** `distrobox`, `tmux`, `zsh`, `code`, `starship` (binario upstream pinneado y verificado por SHA-256), `fira-code-fonts`, `jetbrains-mono-fonts`.
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
