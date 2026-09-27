# Operaciones

Este documento describe cómo operar el pipeline y cómo interpretar su estado sin tener que reconstruir mentalmente la historia del repositorio.

## Canales OCI

| Canal | Semántica | Uso recomendado |
| --- | --- | --- |
| `sha-<commit40>` | identidad inmutable por commit | auditoría y recuperación exacta |
| `YYYYMMDD-<sha12>` | identidad legible e inmutable | navegación humana |
| `run-<run_id>-<attempt>` | identidad forense de ejecución | correlación con GitHub Actions |
| `candidate` | último build de `main` firmado y attestated | pruebas anticipadas |
| `latest` | alias del último build validado | inspección / compatibilidad |
| `stable` | candidate revalidado desde GHCR | **canal normal del host** |

La identidad primaria siempre es el digest `sha256:...`. Los tags son referencias hacia ese digest.

## Flujo normal de release

```text
main
 │
 ▼
build
 ├── smoke tests
 ├── SBOM SPDX/CycloneDX
 ├── Grype advisory
 └── Fedora security gate
 │
 ▼
tags inmutables
 │
 ▼
Cosign keyless + SLSA provenance + SPDX attestation
 │
 ▼
verificación criptográfica
 │
 ├── candidate
 └── latest
      │
      ▼
promotion workflow
 ├── verifica supply chain otra vez
 ├── pull del artefacto publicado
 ├── smoke tests otra vez
 └── Fedora gate otra vez
      │
      ▼
stable
```

## Workflows que deben existir

- `build.yml`: build, seguridad, firma y publicación.
- `promote-stable.yml`: promoción automática `candidate → stable`.
- `cleanup.yml`: retención GHCR.
- `recovery-drill.yml`: prueba mensual de recuperabilidad de `stable`.
- `validate.yml`: validación unificada de PRs; adentro separa configuración, hardening/smoke, seguridad/release y recovery.

## Qué significa cada tipo de fallo

### Falla durante build/smoke/Fedora gate

No se publica una nueva identidad OCI. `candidate`, `latest` y `stable` permanecen en la versión anterior.

Acción: revisar el artifact `fedora-atomic-security-...`.

### Falla después de publicar la identidad inmutable, durante firma/attestation

El digest puede existir bajo tags inmutables, pero **candidate/latest no se mueven**.

Acción: revisar `fedora-atomic-supply-chain-...`. No forzar tags manualmente.

### Falla de promoción

`candidate/latest` pueden estar en el build nuevo, pero `stable` permanece en el último artefacto que pasó la segunda validación.

Acción: revisar los artifacts `fedora-atomic-promotion-validation-...` y `fedora-atomic-stable-promotion-...`.

### Conflicto de inmutabilidad

El mismo commit intentó producir un digest diferente.

Acción: tratarlo como deriva de inputs upstream. No sobrescribir `sha-<commit>`; inspeccionar base Fedora, repos externos y cambios de paquetes antes de decidir qué hacer.

## Evidencia y retención

| Evidencia | Retención |
| --- | ---: |
| smoke/security/SBOM/Grype/Fedora gate | 30 días |
| image identity | 90 días |
| firma/provenance/SBOM attestation verification | 90 días |
| stable promotion | 90 días |
| recovery drill | 90 días |

Las attestations y firmas también viven asociadas al digest OCI/GitHub, independientemente del artifact ZIP de Actions.

## Operaciones manuales útiles

Verificar el canal estable desde un checkout confiable:

```bash
export GH_TOKEN="$(gh auth token)"
bash scripts/recovery/verify-stable.sh
```

Capturar el estado local del host antes de mantenimiento:

```bash
bash scripts/recovery/capture-host-state.sh
```

Preparar una recuperación/rebase sin modificar el host:

```bash
bash scripts/recovery/rebase-stable.sh
```

Forzar un build manual debe hacerse desde **Actions → Fedora Atomic Core - Build & Security Gate → Run workflow**, sobre `main`.

## Qué no hacer

- No mover manualmente `stable` para “arreglar” un workflow rojo.
- No reutilizar un tag `sha-<commit>` con otro digest.
- No borrar a mano versiones `untagged` del paquete principal: pueden ser referrers de firma/attestation.
- No hacer rebase a `candidate` en el host principal salvo que sea una prueba deliberada.
- No considerar el repo como backup de `$HOME`, secretos o datos de usuario.

## Checklist rápido después de un cambio

1. Checks del PR verdes.
2. Build de `main` verde.
3. Job `Sign, attest, verify & publish channels` verde.
4. `Promote Candidate to Stable` verde.
5. `stable` resuelve al digest esperado.
6. `verify-stable.sh` verifica firma, provenance y SBOM.
