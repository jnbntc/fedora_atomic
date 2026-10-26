# Setup host-local

La workstation consume únicamente imágenes del canal `stable`, pero no confía ciegamente en el tag. La imagen incluye un updater que resuelve el tag a un digest, verifica su supply chain y recién después prepara el siguiente deployment.

## Flujo normal

```text
16:17  GitHub construye la imagen del día
          ↓
       candidate
          ↓
       segunda validación
          ↓
        stable

18:30  notebook comprueba stable
02:30  segundo intento
boot/resume + cada 30 min: catch-up con guardas de horario/edad/energía
          ↓
       Cosign signature
       SLSA provenance
       SPDX attestation
          ↓
       rebase por digest + capas RPM
       o upgrade de capas sobre el mismo digest
          ↓
       staged para el próximo reboot
```

No hay reboot automático.

## Timer verificado

La imagen instala el updater y su service, y habilita específicamente el timer:

```text
/usr/libexec/fedora-atomic-verified-update
fedora-atomic-verified-update.service   # static / Type=oneshot
fedora-atomic-verified-update.timer     # enabled
```

Horario local de la máquina (el script y systemd usan la misma zona):

```ini
OnCalendar=*-*-* 18:30:00
OnCalendar=*-*-* 02:30:00
OnCalendar=*-*-* *:00,30:00
OnBootSec=10min
AccuracySec=1min
RandomizedDelaySec=0
Persistent=true
WakeSystem=false
```

`Persistent=true` recupera una activación de calendario perdida mientras el timer estuvo detenido, por ejemplo al apagar la notebook. Los timers de calendario también se procesan al volver de suspend/hibernación; no se despierta la máquina. `OnBootSec=10min` agrega una oportunidad al arrancar; **no impone una espera mínima**: el catch-up persistente puede disparar antes. La semántica está documentada en [systemd.timer](https://github.com/systemd/systemd/blob/main/man/systemd.timer.xml).

Activar el servicio no implica descargar una imagen. El script aplica esta política antes de consultar GHCR:

| Momento | Regla |
| --- | --- |
| Ventanas originales 02:20–03:10 / 18:20–19:10, inclusive | Verificar y preparar como antes. |
| Fuera de jornada: L–V antes de 08:00 o desde 18:20; sábados y domingos completos | Catch-up si no hubo éxito en las últimas 6 h. Tras un fallo, reintentar desde los 30 min. |
| Jornada: L–V desde 08:00 hasta antes de 18:20 | Diferir sin red, salvo **72 h o más sin una comprobación exitosa y alimentación externa confirmada** (Mains/USB online). Recuperación limitada a un intento cada 6 h, incluso si falla. |

La edad mide la última comprobación criptográfica que confirmó el digest `stable` ya booted/staged, o terminó de preparar ese digest. **No es la antigüedad del kernel ni garantiza que GitHub haya publicado una imagen nueva.** Un fallo de red/firma/provenance/SBOM o un stage diferido no reinicia esa edad.

El servicio mantiene `first-seen`, `last-success`, `last-attempt` y un lock bajo `/var/lib/fedora-atomic-verified-update/` (0700; archivos privados). Las escrituras de timestamps usan reemplazo atómico. En una primera instalación sin historial, el período de gracia de 72 h comienza en la primera invocación; no se infiere una edad desde el deployment y no se fuerza una descarga en el primer arranque laboral. El historial sobrevive reinicios y rebases. Timestamps corruptos/futuros reinician el plazo afectado conservadoramente; un `last-success` inválido se descarta y reinicia la gracia, sin inventar un éxito.

La alimentación desconocida, ausente o inválida no habilita la excepción laboral. Se vuelve a evaluar horario/energía después de la verificación y antes de limpiar/preparar deployments. Si se cruza el inicio de jornada sin cumplir la excepción, se difiere el stage; una transacción de rpm-ostree ya iniciada no se interrumpe al cambiar de hora o energía.

El intervalo de 30 min evita depender de un único boot/resume con red disponible. No se agregan hooks de suspensión ni procesos dormidos: si se difiere o falla, el timer vuelve a evaluar. Durante una ejecución, systemd no inicia otra instancia del mismo servicio y el lock también excluye invocaciones manuales simultáneas. Las ventanas originales y el override administrativo omiten los intervalos de espera, pero conservan el lock y la verificación.

El servicio usa prioridad baja de CPU/I/O y no contiene tokens ni credenciales. `StateDirectory=` crea el directorio incluso si `/var` no proviene de la imagen; la ejecución manual usa la misma ruta. `FEDORA_ATOMIC_STATE_DIR` y `POWER_SUPPLY_ROOT` permiten fixtures aislados en tests; no hace falta configurarlos en el host.

### Adopción y comprobación del cambio

El cambio se entrega en la siguiente imagen que lo incorpore; no modifica los servicios del host desde el checkout. Después de instalarla y reiniciar, comprobar:

```bash
systemctl cat fedora-atomic-verified-update.timer
systemctl cat fedora-atomic-verified-update.service
systemctl list-timers fedora-atomic-verified-update.timer --all
journalctl -u fedora-atomic-verified-update.service -b --no-pager
sudo ls -l /var/lib/fedora-atomic-verified-update/
```

Verificar que la unidad efectiva muestre `Persistent=true`, `OnBootSec=10min` y el calendario de 30 min. Revisar cualquier override bajo `/etc/systemd/system/` que oculte las unidades de `/usr/lib`; no borrarlo a ciegas. Para un host encendido en horario laboral sin historial, esperar el mensaje de diferimiento y `first-seen`, sin `last-success` hasta una comprobación permitida.

La **validación física de suspend/resume + catch-up sigue pendiente**, con seguimiento en el [issue #24](https://github.com/jnbntc/fedora_atomic/issues/24). Incluye reanudar después de las 20:00 tras suspender antes de las 18:30 y reanudar en jornada con éxito reciente, respetando diferimientos y sin reboot automático. La recuperación laboral atrasada queda como escenario futuro seguro: requiere 72 h sin éxito, AC y reintentos cada 6 h, sin modificar timestamps para forzarla.

Para volver al comportamiento anterior, revertir este cambio en el repo y consumir la imagen correspondiente. El estado de `/var/lib` puede conservarse; el script anterior no lo usa.

## Verificación criptográfica

Antes de cada stage se exige:

- firma Cosign válida;
- certificado emitido para `.github/workflows/build.yml@refs/heads/main`;
- issuer GitHub Actions OIDC;
- repository/ref/SHA coincidentes con la revision OCI;
- provenance `https://slsa.dev/provenance/v1`;
- SBOM attestation `https://spdx.dev/Document/v2.3`.

Si cualquiera falla, no se ejecuta `rpm-ostree rebase`.

## Timer estándar de rpm-ostree

El updater anterior debe quedar deshabilitado:

```bash
sudo systemctl disable --now rpm-ostreed-automatic.timer
```

El nuevo flujo no usa `AutomaticUpdatePolicy=stage` como mecanismo de scheduling. Puede seguir figurando configurado en `/etc/rpm-ostreed.conf`, pero el timer estándar permanece deshabilitado.

## Comprobar el estado

```bash
systemctl is-enabled fedora-atomic-verified-update.timer
systemctl is-active fedora-atomic-verified-update.timer
systemctl status fedora-atomic-verified-update.timer --no-pager
systemctl list-timers fedora-atomic-verified-update.timer --all
journalctl -u fedora-atomic-verified-update.service --no-pager
rpm-ostree status -v
```

El timer debe reportar `enabled` y `active`. El servicio es `Type=oneshot`, por lo que fuera de una ejecución normal permanece `inactive (dead)`.

Una ejecución normal sin novedades indica que el digest booted coincide con `stable`; si hay paquetes host-locales gestionados, también comprueba las capas RPM y termina con `Stable y paquetes de repositorio sin novedades.`

Cuando existe una versión nueva, queda `Staged: yes`; el usuario reinicia cuando le resulte conveniente.

## Ejecución manual

El horario, la edad, la energía y los intervalos de espera se pueden saltear explícitamente para una ejecución administrativa (se mantienen el lock, la verificación y el registro de éxito):

```bash
sudo env FEDORA_ATOMIC_ALLOW_ANY_TIME=1 \
  /usr/libexec/fedora-atomic-verified-update
```

Esto **tampoco reinicia**.

## Paquetes host-locales

`LocalPackages` representa RPM instalados desde un archivo/URL, conservados en una versión concreta. `LayeredPackages` representa solicitudes de repositorio que rpm-ostree vuelve a resolver al actualizar. El updater gestiona la migración de **ChatGPT y TeamViewer ya instalados**, con la política de `/etc/fedora-atomic/host-packages.json`:

```json
{
  "schema_version": 1,
  "packages": ["chatgpt", "teamviewer"]
}
```

La lista autoriza migrar sólo esas solicitudes locales y comprobar las capas si ya son solicitudes por nombre. No instala apps ausentes, no convierte otros RPM locales ni overrides y no elimina capas personales. Una política ausente/inválida bloquea el intento para evitar cambios ambiguos; `packages: []` desactiva esta gestión explícitamente y mantiene el flujo de imagen.

### Cómo se actualizan

1. Se aplican las guardas de horario/edad/energía y el lock existentes.
2. Se resuelve y verifica `stable` con Cosign, SLSA y SBOM antes de operar sobre RPM.
3. Si ya hay un deployment pendiente del mismo digest, se conserva y se espera el reboot; la comprobación de paquetes continúa después. Un pendiente ajeno/no fijado por digest se rechaza incluso cuando la imagen booted coincide con `stable`.
4. Para un nuevo digest, un único `rpm-ostree rebase` combina el cambio de imagen y la migración: `--uninstall=<NEVRA-local>` + `--install=<nombre>`. No hay desinstalación intermedia ni `cleanup --pending`; se parte de las solicitudes del deployment predeterminado para conservar cambios pendientes.
5. Si `stable` no cambió y hay apps gestionadas, se exige que la referencia booted sea exactamente el origen inmutable verificado. Se refrescan metadatos y se ejecuta `rpm-ostree upgrade --unchanged-exit-77`, con los mismos argumentos de migración si hacen falta. Así las actualizaciones RPM no dependen de que se publique otra imagen. `77` significa sin novedades sólo si no había una migración que aplicar.
6. Antes de transaccionar se reevalúan horario/energía y que los deployments no hayan cambiado durante las comprobaciones. Después se exige el mismo digest verificado y las solicitudes migradas esperadas antes de registrar éxito.

Las capas de repositorio y sus dependencias se resuelven juntas: otras capas de repositorio pueden actualizarse también, según rpm-ostree; otros **RPM locales fijos** se conservan. No se usa `dnf upgrade` sobre el sistema ni se sigue un tag mutable con `rpm-ostree upgrade`. Ningún camino reinicia o aplica cambios en vivo.

Si falla la resolución, un repositorio o la validación RPM, falla la transacción y el deployment anterior permanece disponible; no se registra éxito. El timer reintenta con los límites habituales. No se continúa con una desinstalación aislada ni se desactiva GPG para sortear errores.

### Requisitos y límites de confianza

Los repositorios del proveedor y sus claves deben estar configurados en el **host**; la imagen no contiene las aplicaciones ni descarga sus instaladores. En la notebook actual están configurados `openai-chatgpt` y `teamviewer`. Comprobar que estén habilitados y con `gpgcheck=1` (ChatGPT también configura `repo_gpgcheck=1`). rpm-ostree usa la configuración y las comprobaciones de firmas RPM del host.

La firma/SLSA/SBOM OCI cubren la imagen base; **no certifican las versiones host-locales** resueltas después desde los proveedores. La migración tampoco garantiza una versión que el proveedor aún no haya publicado o que no pueda resolverse con las dependencias del host.

### Adopción del cambio

El checkout no modifica el host. Después del merge, esperar que build y promoción publiquen un `stable` con este cambio. Usar el updater verificado existente para preparar esa imagen y reiniciar cuando convenga. El script anterior conservará las versiones locales durante ese primer rebase.

Al arrancar la imagen nueva, el updater nuevo podrá migrar los RPM en la siguiente ejecución permitida, incluso si `stable` no cambió. Puede requerir **un segundo reboot** para arrancar las apps actualizadas. Una vez preparados los paquetes no se reconstruye continuamente ese pendiente: se espera el reboot elegido por el usuario.

Comprobar el resultado:

```bash
journalctl -u fedora-atomic-verified-update.service -b -n 100 --no-pager
rpm-ostree status -v
rpm -q chatgpt teamviewer
```

`rpm -q` muestra las versiones del deployment **en uso**, no las del pendiente. Tras arrancar la migración, `chatgpt`/`teamviewer` deben aparecer en `LayeredPackages`, sin sus NEVRA antiguos en `LocalPackages`. Un `rpm-ostree status --json` permite comparar `requested-packages` y `requested-local-packages` de ambos deployments. Para comparar con lo publicado sin instalar:

```bash
dnf5 --refresh --repo=openai-chatgpt,teamviewer \
  repoquery --available --latest-limit=1 chatgpt teamviewer
```

### Validación física confirmada (2026-10-26)

Tras el merge del [PR #23](https://github.com/jnbntc/fedora_atomic/pull/23), build y promoción a `stable` finalizaron correctamente. La notebook arrancó con `44.20261025.0`, digest `sha256:dcd661013c1123744624682ad81d8835d662d0b9048a7b4c63888db9bfb148cc` y revisión OCI `d21f4213ca9a8c2bc9defb9dae90f037fc60a5b0`, sin deployment staged y con el anterior disponible para rollback. `chatgpt` y `teamviewer` permanecen como `LayeredPackages` en el deployment activo.

La ejecución manual del updater verificó Cosign, provenance SLSA y SBOM SPDX 2.3, refrescó metadata RPM y comprobó las capas sobre el mismo digest verificado. Terminó con `Stable y paquetes de repositorio sin novedades.`, sin `Argument list too long` ni falso error de postvalidación; `last-success` se actualizó a `2026-10-26 11:29:54 -03`.

Con esta evidencia en hardware quedan validados el flujo de paquetes host-locales y la adopción del fix del PR #23; el incidente **ARG_MAX queda cerrado**. Esta validación no incluye suspend/resume: ese pendiente continúa en el [issue #24](https://github.com/jnbntc/fedora_atomic/issues/24).

### Control y recuperación

Para conservar una aplicación como RPM fijo, quitar su nombre de la política **antes de la migración**. Para agregar otra, revisar primero su repositorio, firmas y compatibilidad, y añadir el nombre exacto; no se aceptan globs u opciones de comandos.

Quitar un nombre de la lista después de migrar no vuelve a fijar la versión: la solicitud de repositorio persistirá. Volver a una versión local requiere una operación administrativa explícita o arrancar el deployment anterior. El rollback conserva una ruta de recuperación, pero no revierte los datos de las aplicaciones bajo `/var`.

Los tests usan fixtures del solver y del estado de rpm-ostree para cubrir migración, reintentos, fallos y preservación del pendiente. Complementan la validación física del flujo de paquetes host-locales registrada arriba.

Antes de cambios grandes:

```bash
bash scripts/recovery/capture-host-state.sh
rpm-ostree status -v
```

## Energía y batería

Fedora 44 usa TuneD/tuned-ppd. Los eventos AC/batería de udev disparan `fedora-power-profile.service`, sin habilitarlo en boot: selecciona `balanced` con alguna fuente Mains/USB online y `powersave` con todas offline. Si el estado es indeterminado, conserva el perfil; si ya está activo, no lo reaplica.

La conservación Lenovo se configura mediante tmpfiles con `charge_types=Long_Life` en `/sys/class/power_supply/BAT*/charge_types`.

## Verificación después de reboot

```bash
rpm-ostree status -v
sudo bootc status
systemctl is-active tailscaled
systemctl status fedora-atomic-verified-update.timer --no-pager
systemctl list-timers fedora-atomic-verified-update.timer --all
systemctl --failed --no-pager
systemctl --user --failed --no-pager
tuned-adm active
```

Si el deployment nuevo no funciona, seguir `docs/DISASTER-RECOVERY.md`.
