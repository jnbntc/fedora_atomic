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

La imagen instala y habilita:

```text
fedora-atomic-verified-update.timer
fedora-atomic-verified-update.service
/usr/libexec/fedora-atomic-verified-update
```

Horario local:

```ini
OnCalendar=*-*-* 18:30:00
OnCalendar=*-*-* 02:30:00
Persistent=false
WakeSystem=false
```

Además, el script solo actúa dentro de ventanas acotadas alrededor de esos horarios. Si systemd intenta ejecutarlo tarde por un resume/suspend, sale sin tocar el sistema. Esto evita que una ejecución perdida durante la noche aparezca al encender la notebook a las 08:00.

El servicio usa prioridad baja de CPU/I/O y no contiene tokens ni credenciales.

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

El horario se puede saltear explícitamente para pruebas administrativas:

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

## Verificación después de reboot

```bash
rpm-ostree status -v
sudo bootc status
systemctl is-active tailscaled
systemctl status fedora-atomic-verified-update.timer --no-pager
systemctl list-timers fedora-atomic-verified-update.timer --all
systemctl --failed --no-pager
```

Si el deployment nuevo no funciona, seguir `docs/DISASTER-RECOVERY.md`.
