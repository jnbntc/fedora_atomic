# Disaster Recovery

Este runbook cubre la recuperación del **sistema base Fedora Atomic**. No reemplaza un backup de datos de usuario.

## Qué protege este repo

Sí cubre:

- definición de la imagen base;
- configuración declarativa bajo `files/etc/`;
- identidad por digest/commit;
- firma Cosign keyless;
- provenance SLSA;
- SBOM attestation;
- canal `stable`;
- procedimientos de validación y rebase.

No cubre:

- `$HOME`;
- claves SSH;
- tokens/API keys;
- credenciales Tailscale;
- authfiles de registries;
- secretos de aplicaciones;
- datos de VMs/containers;
- backups Restic si no fueron configurados fuera de este repo.

## Regla principal

**Nunca recuperar usando solamente un tag mutable.**

El procedimiento correcto es:

```text
stable
  ↓ resolver
digest sha256:...
  ↓ verificar Cosign + provenance + SBOM
digest verificado
  ↓
rpm-ostree rebase por digest
```

Aunque el target de rpm-ostree se llame `ostree-unverified-registry:`, la verificación de supply chain ocurre explícitamente **antes** con Cosign/GitHub Attestations. El término `unverified` describe el transporte rpm-ostree, no el procedimiento completo de este repo.

## Prerrequisitos del entorno de administración

Para verificar `stable` se requieren:

- `skopeo`;
- `jq`;
- `cosign` (misma versión pinneada en CI);
- GitHub CLI `gh` con soporte de attestations;
- autenticación GitHub disponible como `GH_TOKEN` o mediante `gh auth login`.

No se descargan binarios automáticamente durante una recuperación: eso evita introducir una nueva cadena de confianza en pleno incidente.

## 1. Verificar stable

Desde un checkout confiable de este repo:

```bash
export GH_TOKEN="$(gh auth token)"

bash scripts/recovery/verify-stable.sh
```

El script:

1. resuelve `stable` a digest;
2. obtiene la revision OCI;
3. verifica Cosign contra el workflow de `main`;
4. verifica provenance SLSA ligada al commit;
5. verifica la attestation SPDX;
6. guarda evidencia bajo `recovery-evidence/`;
7. imprime un target rpm-ostree fijado por digest.

Un resultado válido termina con variables similares a:

```text
STABLE_REPOSITORY=ghcr.io/jnbntc/fedora_atomic
STABLE_DIGEST=sha256:...
STABLE_REVISION=<commit40>
RPM_OSTREE_TARGET=ostree-unverified-registry:ghcr.io/jnbntc/fedora_atomic@sha256:...
```

## 2. Capturar el estado del host

Antes de un rebase/reparación, si el host todavía inicia:

```bash
bash scripts/recovery/capture-host-state.sh
```

Mover el directorio generado fuera del host junto con el backup normal.

## 3. Dry-run del rebase

```bash
bash scripts/recovery/rebase-stable.sh
```

El default **no modifica nada**. Captura `rpm-ostree status`, verifica `stable` y muestra el target por digest.

Si detecta paquetes layered/locales/overrides, se niega a aplicar automáticamente hasta que se revise el snapshot.

## 4. Aplicar rebase

Después de revisar el estado local:

```bash
bash scripts/recovery/rebase-stable.sh --apply --allow-layered
```

El helper ejecuta conceptualmente:

```bash
sudo rpm-ostree rebase   ostree-unverified-registry:ghcr.io/jnbntc/fedora_atomic@sha256:<digest-verificado>
```

Luego:

```bash
rpm-ostree status -v
```

No se reinicia salvo que se use explícitamente `--reboot`. Para incidentes reales es preferible revisar el deployment staged antes del reboot.

## Escenario A — update staged pero todavía no reinicié

Si el deployment pendiente es incorrecto y querés descartarlo antes de bootearlo:

```bash
rpm-ostree status
sudo rpm-ostree cleanup --pending
rpm-ostree status
```

Después se puede volver a resolver/verificar `stable` y preparar otro rebase.

## Escenario B — el deployment nuevo inicia pero está roto

La recuperación normal de rpm-ostree es volver al deployment anterior:

```bash
sudo rpm-ostree rollback
sudo systemctl reboot
```

`rpm-ostree rollback` cambia cuál deployment será el default; no restaura datos de usuario.

## Escenario C — el deployment nuevo no llega a iniciar

En el bootloader seleccionar el deployment anterior de Fedora/OSTree.

Una vez dentro del sistema funcional:

1. capturar `rpm-ostree status -v`;
2. no destruir inmediatamente el deployment roto si se necesita diagnóstico;
3. resolver y verificar `stable`;
4. preparar un rebase fijado por digest.

## Escenario D — instalación desde cero

1. instalar la misma generación compatible de Fedora Silverblue;
2. restaurar conectividad;
3. clonar este repo desde una fuente confiable;
4. preparar un entorno administrativo con `skopeo`, `cosign`, `gh` y `jq`;
5. ejecutar `verify-stable.sh`;
6. ejecutar `rebase-stable.sh` primero en dry-run y después con `--apply`;
7. reiniciar;
8. aplicar `docs/HOST-SETUP.md`;
9. restaurar paquetes host-locales a partir del último recovery snapshot;
10. restaurar `$HOME`/datos/secrets desde el sistema de backup externo.

## Escenario E — GHCR o GitHub no disponibles

No degradar automáticamente a una imagen no verificada.

Opciones seguras:

- seguir usando el deployment booted actual;
- bootear el rollback deployment local;
- esperar recuperación del registry/attestation service;
- usar un digest previamente verificado y conservado **solo si también se conserva la evidencia y el contenido sigue accesible localmente**.

## Escenario F — stable apunta a algo inesperado

Si `verify-stable.sh` falla o la revision no coincide con la evidencia esperada:

1. no hacer rebase;
2. no mover tags manualmente;
3. inspeccionar los runs de build/promoción;
4. revisar firma, provenance e identity artifacts;
5. si hay duda, mantener el deployment local conocido.

## Drill periódico

`.github/workflows/recovery-drill.yml` ejecuta mensualmente un ejercicio no destructivo:

- resuelve `stable`;
- verifica firma/provenance/SBOM;
- descarga el digest exacto;
- exporta rootfs;
- ejecuta smoke tests;
- consulta advisories Fedora;
- aplica el security gate;
- conserva evidencia.

El drill prueba recuperabilidad del artefacto, **no rebasea ningún host**.

## Referencias upstream

- rpm-ostree container images: https://coreos.github.io/rpm-ostree/container/
- rpm-ostree administration/rollback: https://coreos.github.io/rpm-ostree/administrator-handbook/
- rpm-ostreed automatic updates: https://github.com/coreos/rpm-ostree/blob/main/man/rpm-ostreed-automatic.xml
