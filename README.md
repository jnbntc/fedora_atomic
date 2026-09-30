# 📦 Fedora Atomic — OCI-native workstation lab

[![Build & Security Gate](https://github.com/jnbntc/fedora_atomic/actions/workflows/build.yml/badge.svg?branch=main)](https://github.com/jnbntc/fedora_atomic/actions/workflows/build.yml)
[![Promote Stable](https://github.com/jnbntc/fedora_atomic/actions/workflows/promote-stable.yml/badge.svg?branch=main)](https://github.com/jnbntc/fedora_atomic/actions/workflows/promote-stable.yml)
[![Repository Validation](https://github.com/jnbntc/fedora_atomic/actions/workflows/validate.yml/badge.svg?branch=main)](https://github.com/jnbntc/fedora_atomic/actions/workflows/validate.yml)
[![Recovery Drill](https://github.com/jnbntc/fedora_atomic/actions/workflows/recovery-drill.yml/badge.svg?branch=main)](https://github.com/jnbntc/fedora_atomic/actions/workflows/recovery-drill.yml)
[![Base](https://img.shields.io/badge/Base-Fedora_Silverblue_44-blue.svg)](https://fedoraproject.org/silverblue/)

Workstation personal basada en **Fedora Silverblue 44**, construida como imagen OCI y usada también como laboratorio de infraestructura inmutable, CI/CD y supply-chain security.

El objetivo original era simple: dejar de depender de cambios manuales difíciles de recordar y poder reconstruir el sistema desde código. Con el tiempo el flujo incorporó smoke tests sobre el artefacto real, SBOMs, un security gate basado en metadata nativa de Fedora, identidades OCI inmutables, firma keyless con Cosign, provenance SLSA, promoción `candidate → stable`, actualización local verificada por digest y ejercicios periódicos de recovery.

> **Alcance:** este repositorio describe mi workstation y mi hardware. No pretende ser una distribución genérica ni una receta para aplicar a ciegas en otros equipos.

## ⚡ El flujo en 20 segundos

```text
main
  ↓
build OCI
  ↓
smoke tests + SBOM + Fedora security gate
  ↓
identidad inmutable + Cosign + SLSA + attestation
  ↓
candidate
  ↓
segunda validación del artefacto publicado
  ↓
stable
  ↓
updater local verifica supply chain
  ↓
rpm-ostree rebase @sha256
  ↓
staged → reboot manual
```

La idea central es que cada etapa produzca **evidencia verificable** y que un fallo deje el sistema en el último estado conocido como bueno. El host no confía directamente en el tag `stable`: primero lo resuelve a un digest, verifica firma, provenance y SBOM, y recién entonces prepara el deployment.

## 🗺️ Mapa rápido del repositorio

| Ruta | Para qué sirve |
| --- | --- |
| `Containerfile` | definición de la imagen Fedora Atomic |
| `.github/workflows/build.yml` | build, smoke, SBOM, security gate, firma y publicación |
| `.github/workflows/promote-stable.yml` | segunda validación y promoción a `stable` |
| `files/` | configuración declarativa incorporada al rootfs |
| `files/usr/libexec/fedora-atomic-verified-update` | updater local fail-closed |
| `scripts/smoke/` | validación funcional del artefacto |
| `scripts/security/` | gate Fedora y verificación de supply chain |
| `scripts/recovery/` | helpers de verificación y recuperación |
| `docs/OPERATIONS.md` | operación diaria y lectura de fallos |
| `docs/HOST-SETUP.md` | integración del host y timer local |
| `docs/DISASTER-RECOVERY.md` | rollback y recuperación |

Para entender el proyecto sin leer todo el historial, conviene empezar por este README y después seguir con **[OPERATIONS](docs/OPERATIONS.md)** y **[DISASTER RECOVERY](docs/DISASTER-RECOVERY.md)**.

## 🏗️ Arquitectura de Despliegue

### 1. Nivel CI: The Build Pipeline
El ciclo de vida de la imagen base está orquestado por GitHub Actions mediante:

* **Push controlado:** cambios en `main` que afecten al `Containerfile`, al workflow de build o a futuros archivos de configuración de la imagen disparan un nuevo build.
* **Nightly:** `cron: '17 19 * * *'` (19:17 UTC / 16:17 ART). Así el `stable` diario suele estar listo antes de la primera ventana local de actualización de las 18:30.
* **Ejecución manual:** `workflow_dispatch` permanece disponible para validaciones y recuperación. Las ejecuciones sobre ramas distintas de `main` construyen y validan la imagen, pero no publican identidades/tags OCI ni mueven `candidate`, `latest` o `stable`; tampoco escriben en el cache compartido de GHCR.

El workflow usa un **cache-buster diario UTC** (`YYYYMMDD`) para forzar como máximo una invalidación deliberada de la transacción principal por día, permitiendo reutilizar caché en reintentos o ejecuciones manuales posteriores del mismo día.

* **Motor OCI:** se utiliza `podman` nativo junto con `buildah` para construir la imagen basada en OSTree. El build funciona con los defaults de seguridad de Podman: no requiere `cap-add=ALL`, `seccomp=unconfined` ni `label=disable`.
* **Smoke tests del artefacto:** antes del análisis de seguridad se valida desde dentro de la imagen que Fedora 44, paquetes, comandos, Starship y unidades systemd esperadas estén presentes; además, todo `files/etc/` se compara byte a byte contra el rootfs exportado y Firefox debe permanecer ausente.
* **SBOM:** el rootfs final se exporta de forma *squashed* y Syft `v1.52.0` genera inventarios **SPDX 2.3 JSON** y **CycloneDX JSON**. La ejecución falla si no detecta el rpmdb o si el SBOM no contiene paquetes RPM.
* **Fedora Security Gate:** `dnf5 advisory` consulta la metadata nativa de Fedora contra el rpmdb exacto de la imagen recién construida. La política versionada en `security/vulnerability-policy.json` bloquea advisories `Critical` e `Important` disponibles; `Moderate` y `Low` son informativos.
* **Grype advisory:** Grype `v0.119.0` analiza el SBOM como capa complementaria para dependencias embebidas (Go, Python, CPE, etc.). No se usa como autoridad para CVE del SO porque los probes de Etapa 5 comprobaron que no asociaba los RPM OSTree con namespaces Fedora.
* **Evidencia:** cada build conserva por 30 días el resultado de smoke tests, los dos SBOM, el reporte Grype y el JSON de advisories Fedora como artifact de GitHub Actions.
* **Registro, identidad y firma:** cada publicación crea un tag inmutable `run-<run_id>-<attempt>` asociado al digest OCI exacto de esa ejecución. El commit queda registrado como revision OCI y en la provenance, pero no se usa como identidad binaria porque el build consume inputs upstream mutables y el mismo commit puede producir otro digest en un rebuild posterior. Antes de mover `candidate`/`latest`, el digest se firma con Cosign `v3.1.3` mediante identidad efímera GitHub OIDC y recibe provenance SLSA + SBOM attestation. `stable` solo se mueve después de una segunda validación que incluye firma, attestations, smoke tests y Fedora gate.

### 2. Política de seguridad del artefacto

La publicación a GHCR ocurre **después** de la evaluación de seguridad. El flujo es:

```text
podman build
    │
    ├── export rootfs
    │     ├── smoke tests → contrato funcional
    │     └── Syft → SPDX + CycloneDX
    │
    ├── Grype sobre SBOM → advisory de dependencias
    │
    └── dnf5 advisory sobre la imagen
          └── Fedora Critical/Important disponibles?
                  ├── sí → build FAIL / no push
                  └── no → identidad OCI inmutable
                              └── run-<id>-<attempt>
                                    │
                                    ├── Cosign keyless signature
                                    ├── SLSA provenance
                                    ├── SPDX 2.3 attestation
                                    └── verify all three
                                          │
                                          ├── candidate
                                          └── latest
                                                │
                                                └── promotion workflow
                                                      ├── verify firma + attestations
                                                      ├── smoke tests otra vez
                                                      ├── Fedora gate otra vez
                                                      └── stable
```

La fuente autoritativa para el gate del sistema operativo es la metadata de advisories de Fedora, consultada con `dnf5 --refresh advisory list --available --security --with-cve --json`. Esto evita interpretar como “0 CVE” un scanner genérico que reconoce Fedora pero no tiene cobertura de matching para los RPM del OSTree.

La política está separada del workflow en `security/vulnerability-policy.json` y su lógica se prueba con `scripts/tests/test-security-gate.sh`. Los cambios en `security/**` o `scripts/security/**` disparan un build de `main`, por lo que cambiar la política también vuelve a validar el artefacto.

### 3. Identidad e inmutabilidad OCI

La publicación usa `scripts/publish/publish-image.sh` y trata el digest OCI como identidad primaria. El orden es deliberado:

```text
run-<run_id>-<attempt>  ── push inicial ──► digest sha256:...
                                      │
                                      ├── source revision = commit
                                      ├── sign + attest
                                      ├── verify
                                      ├── candidate
                                      └── latest
```

El tag `run-<run_id>-<attempt>` es inmutable por construcción y se comprueba antes de publicar. El **digest OCI** sigue siendo la identidad primaria. `candidate` y `latest` quedan diferidos hasta que firma y attestations hayan sido creadas y verificadas.

Esta separación es deliberada: el build no es hermético. Usa `--pull=always` y repositorios upstream que evolucionan, por lo que dos ejecuciones del mismo commit pueden producir digests distintos sin que exista una contradicción. Lo que no puede cambiar es el artefacto asociado a una ejecución concreta.

Los tags históricos `sha-<commit40>` y `YYYYMMDD-<sha12>` permanecen reconocidos por la política de cleanup como formatos legacy, pero ya no participan del release.

Cada publicación exitosa genera `security-evidence/image-identity.json` con repositorio, digest, commit, run ID, attempt y tag de ejecución. Ese archivo se conserva como artifact durante 90 días.

### 4. Firma keyless, provenance y SBOM attestation

La Etapa 9 no almacena claves privadas. El job de firma recibe `id-token: write` y usa **GitHub Actions OIDC** para obtener una identidad efímera que Sigstore/Fulcio incorpora al certificado de Cosign. La firma queda asociada al **digest OCI**, no a un tag mutable.

Para cada digest publicado en `main` se generan y verifican:

1. **Cosign keyless signature** — identidad esperada: `.github/workflows/build.yml@refs/heads/main`, issuer `https://token.actions.githubusercontent.com`.
2. **SLSA provenance v1** — generada con `actions/attest-build-provenance` y ligada al commit fuente.
3. **SPDX 2.3 attestation** — se deriva del SBOM canónico una vista package-level compacta (<16 MiB) que conserva los 7.830 paquetes y sus purls, pero omite el inventario masivo de archivos/relaciones `CONTAINS`. El SBOM completo permanece intacto como evidencia de 30 días.

Las attestations se registran en GitHub y se publican además como OCI referrers en GHCR. GitHub impone un límite de 16 MiB al archivo SBOM usado como predicate; por eso la vista compacta se valida explícitamente antes de firmarla. El pipeline usa `gh attestation verify` y Cosign para comprobarlas antes de mover `candidate`/`latest`. La promoción a `stable` repite esas verificaciones sobre el digest descargado desde GHCR.

Ejemplo conceptual de verificación:

```bash
cosign verify \
  --certificate-identity "https://github.com/jnbntc/fedora_atomic/.github/workflows/build.yml@refs/heads/main" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  ghcr.io/jnbntc/fedora_atomic@sha256:...

gh attestation verify \
  oci://ghcr.io/jnbntc/fedora_atomic@sha256:... \
  --repo jnbntc/fedora_atomic \
  --signer-workflow jnbntc/fedora_atomic/.github/workflows/build.yml \
  --predicate-type https://slsa.dev/provenance/v1 \
  --bundle-from-oci
```

> **Límite importante:** firma y provenance prueban identidad, integridad y contexto de construcción; no convierten el build en hermético. La imagen sigue consumiendo una base Fedora y repositorios upstream que pueden cambiar. Por eso la identidad inmutable se asocia a la ejecución exacta y al digest, mientras el commit queda registrado como revision fuente.

### 5. Promoción candidate → stable

`candidate` representa el build de `main` más reciente que completó build, smoke tests y security gate. La promoción a `stable` se ejecuta automáticamente con `.github/workflows/promote-stable.yml` después de un build exitoso.

La promoción **no reconstruye** la imagen: descarga el tag inmutable `run-<run_id>-<attempt>` de la ejecución que disparó el workflow y vuelve a ejecutar sobre ese artefacto publicado:

1. verificación Cosign keyless;
2. verificación de provenance SLSA y SBOM attestation;
3. smoke tests funcionales;
4. consulta `dnf5 advisory` contra Fedora;
5. Fedora security gate.

`main` y la promoción comparten el lock `fedora-atomic-release`. Si un build nuevo se adelanta, el promotor viejo compara el digest de su identidad `run-...` con el `candidate` actual y termina sin tocar `stable`. Por eso una promoción atrasada no puede pisar un candidate más nuevo.

El canal recomendado para un host que prioriza estabilidad es **`stable`**. `candidate` es útil para pruebas anticipadas y `latest` conserva la semántica de “último build validado”.

Cada promoción conserva evidencia funcional y Fedora durante 30 días y un `stable-promotion.json` durante 90 días.

El cleanup de GHCR solo puede purgar tags de identidad gestionados (incluyendo el formato diario legado). Si una versión lleva un tag desconocido como `stable`, `candidate` o una futura versión semántica, queda protegida por defecto.

### 6. Mantenimiento de GHCR
La retención del registro está desacoplada del build y se gestiona mediante `.github/workflows/cleanup.yml` y `scripts/cleanup-ghcr.sh`.

* **Schedule:** domingo 04:37 UTC / 01:37 ART.
* **Manual:** `workflow_dispatch`, con `dry-run` como opción predeterminada.
* **Seguridad:** el script usa `set -Eeuo pipefail`, diferencia un `404` de otros errores de API y no oculta fallos de autenticación o del backend.
* **Retención:** para el paquete principal `fedora_atomic`, las versiones `untagged` se preservan deliberadamente porque GHCR puede materializar firmas/attestations OCI como referrers sin tags convencionales. Solo se consideran purgables versiones cuyos tags sean exclusivamente formatos gestionados (`YYYYMMDD`, `YYYYMMDD-SHA12` y `sha-SHA40` como formatos legacy, más `run-ID-ATTEMPT` como identidad actual); `latest`, `candidate`, `stable` y cualquier tag especial/desconocido quedan protegidos. El cache mantiene su política independiente y sí elimina `untagged`.
* **Validación:** cada PR que modifica esta lógica ejecuta `bash -n`, ShellCheck y pruebas unitarias con un `gh` simulado, sin tocar GHCR.

### 7. Configuración declarativa del rootfs
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

Los servicios base (`podman-auto-update.timer`, `tailscaled`, `thermald` y `libvirtd`) mantienen symlinks explícitos en el `Containerfile`. El updater verificado, en cambio, se habilita con `systemctl enable fedora-atomic-verified-update.timer`, por lo que su enlace queda bajo `/etc/systemd/system/timers.target.wants/`. Los smoke tests verifican explícitamente ese contrato.

Fedora 44 usa TuneD/tuned-ppd: los eventos AC/batería disparan `fedora-power-profile.service` para seleccionar `balanced` con alimentación externa o `powersave` sin ella. La conservación Lenovo usa `charge_types=Long_Life` mediante tmpfiles. La auditoría post-boot separa `systemctl --failed --no-pager` y `systemctl --user --failed --no-pager`; el snapshot también guarda el perfil TuneD activo.

La coherencia del árbol se valida con `scripts/tests/test-config-tree.sh` y el workflow `Config Tree Validation`.

### 8. Nivel CD: Host local
El host local (notebook) opera como un nodo pasivo de consumo. Para uso normal se recomienda seguir el canal `stable`; `candidate` queda reservado para validación anticipada.

La imagen incluye ahora un updater local verificado: resuelve `stable`, valida firma Cosign + provenance SLSA + SBOM SPDX y recién después prepara un rebase fijado por digest. Corre a las **18:30** y **02:30**, no hace catch-up al encender, trabaja con prioridad baja y **nunca reinicia automáticamente**.

El timer estándar `rpm-ostreed-automatic.timer` queda fuera de este flujo para evitar actualizaciones que no pasen por la verificación criptográfica local. Detalles en **[docs/HOST-SETUP.md](docs/HOST-SETUP.md)**.

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
Algunos paquetes pueden quedar deliberadamente fuera de la imagen OCI cuando su instalación requiere comportamiento host-local difícil de reproducir de forma segura durante el build. Esos paquetes se gestionan por separado y no forman parte de la garantía de reconstrucción del rootfs.

En el host principal, el caso actual es:

* `teamviewer`

El estado local se captura antes de cambios importantes con `scripts/recovery/capture-host-state.sh` para que estos componentes no queden implícitos.

---

## 🛠️ Operaciones & Disaster Recovery

La operación diaria y la recuperación quedan documentadas como runbooks versionados:

- **[docs/OPERATIONS.md](docs/OPERATIONS.md)** — canales, workflows, evidencia, fallos y checklist operativo.
- **[docs/HOST-SETUP.md](docs/HOST-SETUP.md)** — configuración host-local de rpm-ostreed/timer y verificación post-boot.
- **[docs/DISASTER-RECOVERY.md](docs/DISASTER-RECOVERY.md)** — verificación criptográfica de `stable`, rebase fijado por digest, rollback y recuperación desde cero.

Helpers:

```bash
# Verificar firma + provenance + SBOM de stable
export GH_TOKEN="$(gh auth token)"
bash scripts/recovery/verify-stable.sh

# Inventario no secreto del host
bash scripts/recovery/capture-host-state.sh

# Verificar y preparar recovery sin modificar el host
bash scripts/recovery/rebase-stable.sh
```

El workflow **Stable Disaster Recovery Drill** ejecuta mensualmente una restauración lógica no destructiva del artefacto `stable`: verifica supply chain, descarga el digest exacto, ejecuta smoke tests y Fedora security gate, y conserva evidencia durante 90 días.

> El repositorio reconstruye el sistema base; no sustituye un backup de `$HOME`, secretos, VMs, credenciales ni datos de aplicaciones.
