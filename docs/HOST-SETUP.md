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
       rpm-ostree rebase por digest
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

Validación real pendiente después de adoptar la imagen: suspender antes de 18:30 y retomar a las 20:00; confirmar un catch-up o un diferimiento por éxito reciente, ningún reboot, y el digest esperado si aparece un nuevo `stable`. Retomar en jornada con éxito reciente debe diferir sin consultar GHCR. Una recuperación laboral atrasada requiere AC; no se recomienda alterar timestamps reales para forzarla. Los tests simulan esas edades y eventos, no suspenden hardware.

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

Una ejecución normal sin novedades termina indicando que el digest booted ya coincide con `stable`.

Cuando existe una versión nueva, queda `Staged: yes`; el usuario reinicia cuando le resulte conveniente.

## Ejecución manual

El horario, la edad, la energía y los intervalos de espera se pueden saltear explícitamente para una ejecución administrativa (se mantienen el lock, la verificación y el registro de éxito):

```bash
sudo env FEDORA_ATOMIC_ALLOW_ANY_TIME=1 \
  /usr/libexec/fedora-atomic-verified-update
```

Esto **tampoco reinicia**.

## Paquetes host-locales

Pueden existir paquetes locales, por ejemplo TeamViewer. El updater usa `rpm-ostree rebase`, por lo que ese estado se conserva igual que en un rebase manual.

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
