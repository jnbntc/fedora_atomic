# 📦 Fedora Atomic - OCI Native Desktop

[![Build Custom Fedora Atomic](https://github.com/jnbntc/fedora_atomic/actions/workflows/build.yml/badge.svg)](https://github.com/jnbntc/fedora_atomic/actions/workflows/build.yml)
[![Base](https://img.shields.io/badge/Base-Fedora_Silverblue_44-blue.svg)](https://fedoraproject.org/silverblue/)
[![Paradigm](https://img.shields.io/badge/Architecture-OCI_Native-green.svg)](#)

Repositorio de Infraestructura como Código (IaC) para el aprovisionamiento y mantenimiento de una estación de trabajo basada en **Fedora Silverblue 44**.

La arquitectura implementa un modelo estricto de **Desacople CI/CD**, desplazando la carga de cálculo y resolución de dependencias hacia GitHub Actions, entregando un artefacto OCI final al *endpoint* local para su *staging* asíncrono.

> **Estado de seguridad del pipeline:** el pipeline genera SBOMs SPDX y CycloneDX desde el rootfs real, aplica un gate Fedora-native y publica primero una identidad OCI inmutable. Ese digest se firma de forma **keyless** con Sigstore/Cosign usando GitHub OIDC, recibe provenance SLSA y una attestation SPDX 2.3, y solo después de verificar las tres evidencias se mueven `candidate` y `latest`. Advisories Fedora **Critical** o **Important** con actualización disponible bloquean la publicación.

---

## 🏗️ Arquitectura de Despliegue

### 1. Nivel CI: The Build Pipeline
El ciclo de vida de la imagen base está orquestado por GitHub Actions mediante:

* **Push controlado:** cambios en `main` que afecten al `Containerfile`, al workflow de build o a futuros archivos de configuración de la imagen disparan un nuevo build.
* **Nightly:** `cron: '17 22 * * *'` (22:17 UTC / 19:17 ART). El minuto 17 evita concentrar la ejecución exactamente al comienzo de la hora.
* **Ejecución manual:** `workflow_dispatch` permanece disponible para validaciones y recuperación. Las ejecuciones manuales sobre ramas distintas de `main` construyen y validan la imagen, pero no publican `latest`/`YYYYMMDD` ni escriben en el cache compartido de GHCR; solo pueden reutilizarlo como fuente.

El workflow usa un **cache-buster diario UTC** (`YYYYMMDD`) para forzar como máximo una invalidación deliberada de la transacción principal por día, permitiendo reutilizar caché en reintentos o ejecuciones manuales posteriores del mismo día.

* **Motor OCI:** se utiliza `podman` nativo junto con `buildah` para construir la imagen basada en OSTree. El build funciona con los defaults de seguridad de Podman: no requiere `cap-add=ALL`, `seccomp=unconfined` ni `label=disable`.
* **Smoke tests del artefacto:** antes del análisis de seguridad se valida desde dentro de la imagen que Fedora 44, paquetes, comandos, Starship y unidades systemd esperadas estén presentes; además, todo `files/etc/` se compara byte a byte contra el rootfs exportado y Firefox debe permanecer ausente.
* **SBOM:** el rootfs final se exporta de forma *squashed* y Syft `v1.52.0` genera inventarios **SPDX 2.3 JSON** y **CycloneDX JSON**. La ejecución falla si no detecta el rpmdb o si el SBOM no contiene paquetes RPM.
* **Fedora Security Gate:** `dnf5 advisory` consulta la metadata nativa de Fedora contra el rpmdb exacto de la imagen recién construida. La política versionada en `security/vulnerability-policy.json` bloquea advisories `Critical` e `Important` disponibles; `Moderate` y `Low` son informativos.
* **Grype advisory:** Grype `v0.119.0` analiza el SBOM como capa complementaria para dependencias embebidas (Go, Python, CPE, etc.). No se usa como autoridad para CVE del SO porque los probes de Etapa 5 comprobaron que no asociaba los RPM OSTree con namespaces Fedora.
* **Evidencia:** cada build conserva por 30 días el resultado de smoke tests, los dos SBOM, el reporte Grype y el JSON de advisories Fedora como artifact de GitHub Actions.
* **Registro, identidad y firma:** cada publicación crea `sha-<commit40>`, `YYYYMMDD-<sha12>` y `run-<run_id>-<attempt>`, todos asociados al mismo digest OCI. Antes de mover `candidate`/`latest`, ese digest se firma con Cosign `v3.1.3` mediante identidad efímera GitHub OIDC y se generan provenance SLSA + SBOM attestation. `stable` solo se mueve después de una segunda validación que incluye firma, attestations, smoke tests y Fedora gate.

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
                              ├── sha-<commit40>
                              ├── YYYYMMDD-<sha12>
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
                                      ├── sha-<commit40>
                                      └── YYYYMMDD-<sha12>
                                              │
                                              ├── sign + attest
                                              ├── verify
                                              ├── candidate
                                              └── latest
```

Los tres tags de identidad son gestionados como **inmutables por política**. Antes de crear `sha-...` o el tag fecha+commit, el pipeline consulta GHCR con Skopeo. Si el tag ya existe con el mismo digest se reutiliza; si apunta a otro digest, el workflow falla. `candidate` y `latest` quedan diferidos hasta que la firma y las attestations hayan sido creadas y verificadas. Esto también detecta el caso importante de un mismo commit que intenta producir un artefacto diferente en una ejecución posterior.

Cada publicación exitosa genera `security-evidence/image-identity.json` con repositorio, digest, commit, run ID, attempt y tags. Ese archivo se conserva como artifact durante 90 días.

### 4. Firma keyless, provenance y SBOM attestation

La Etapa 9 no almacena claves privadas. El job de firma recibe `id-token: write` y usa **GitHub Actions OIDC** para obtener una identidad efímera que Sigstore/Fulcio incorpora al certificado de Cosign. La firma queda asociada al **digest OCI**, no a un tag mutable.

Para cada digest publicado en `main` se generan y verifican:

1. **Cosign keyless signature** — identidad esperada: `.github/workflows/build.yml@refs/heads/main`, issuer `https://token.actions.githubusercontent.com`.
2. **SLSA provenance v1** — generada con `actions/attest-build-provenance` y ligada al commit fuente.
3. **SPDX 2.3 attestation** — el SBOM canónico de Syft se firma como predicate `https://spdx.dev/Document/v2.3`.

Las attestations se registran en GitHub y se publican además como OCI referrers en GHCR. El pipeline usa `gh attestation verify` y Cosign para comprobarlas antes de mover `candidate`/`latest`. La promoción a `stable` repite esas verificaciones sobre el digest descargado desde GHCR.

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

> **Límite importante:** firma y provenance prueban identidad, integridad y contexto de construcción; no convierten el build en hermético. La imagen sigue consumiendo una base Fedora y repositorios upstream que pueden cambiar. Si el mismo commit reconstruye un digest distinto, la política de identidad de Etapa 7 lo detecta y bloquea los canales mutables.

### 5. Promoción candidate → stable

`candidate` representa el build de `main` más reciente que completó build, smoke tests y security gate. La promoción a `stable` se ejecuta automáticamente con `.github/workflows/promote-stable.yml` después de un build exitoso.

La promoción **no reconstruye** la imagen: descarga `sha-<commit40>` desde GHCR y vuelve a ejecutar sobre ese artefacto publicado:

1. verificación Cosign keyless;
2. verificación de provenance SLSA y SBOM attestation;
3. smoke tests funcionales;
4. consulta `dnf5 advisory` contra Fedora;
5. Fedora security gate.

`main` y la promoción comparten el lock `fedora-atomic-release`. Si un build nuevo se adelanta, el promotor viejo compara el digest de su `sha-<commit>` con el `candidate` actual y termina sin tocar `stable`. Por eso una promoción atrasada no puede pisar un candidate más nuevo.

El canal recomendado para un host que prioriza estabilidad es **`stable`**. `candidate` es útil para pruebas anticipadas y `latest` conserva la semántica de “último build validado”.

Cada promoción conserva evidencia funcional y Fedora durante 30 días y un `stable-promotion.json` durante 90 días.

El cleanup de GHCR solo puede purgar tags de identidad gestionados (incluyendo el formato diario legado). Si una versión lleva un tag desconocido como `stable`, `candidate` o una futura versión semántica, queda protegida por defecto.

### 6. Mantenimiento de GHCR
La retención del registro está desacoplada del build y se gestiona mediante `.github/workflows/cleanup.yml` y `scripts/cleanup-ghcr.sh`.

* **Schedule:** domingo 04:37 UTC / 01:37 ART.
* **Manual:** `workflow_dispatch`, con `dry-run` como opción predeterminada.
* **Seguridad:** el script usa `set -Eeuo pipefail`, diferencia un `404` de otros errores de API y no oculta fallos de autenticación o del backend.
* **Retención:** para el paquete principal `fedora_atomic`, las versiones `untagged` se preservan deliberadamente porque GHCR puede materializar firmas/attestations OCI como referrers sin tags convencionales. Solo se consideran purgables versiones cuyos tags sean exclusivamente formatos gestionados (`YYYYMMDD` legado, `YYYYMMDD-SHA12`, `sha-SHA40`, `run-ID-ATTEMPT`); `latest`, `candidate`, `stable` y cualquier tag especial/desconocido quedan protegidos. El cache mantiene su política independiente y sí elimina `untagged`.
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

Los symlinks de servicios habilitados permanecen por ahora explícitos en el `Containerfile`: son estado de activación de systemd, no archivos regulares, y se migrarán solo si podemos conservar exactamente su semántica.

La coherencia del árbol se valida con `scripts/tests/test-config-tree.sh` y el workflow `Config Tree Validation`.

### 8. Nivel CD: Local Staging
El host local (notebook) opera como un nodo pasivo de consumo. Para uso normal se recomienda seguir el canal `stable`; `candidate` queda reservado para validación anticipada.
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
