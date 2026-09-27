# Setup host-local

La imagen OCI y el estado local del host son capas distintas. Este repo controla la imagen base; algunos ajustes operativos del notebook siguen siendo intencionalmente host-local.

## Canal recomendado

El host principal debe consumir:

```text
ghcr.io/jnbntc/fedora_atomic:stable
```

Para recuperación o rebase se resuelve primero `stable` a un digest y se verifica criptográficamente. El helper de recuperación genera un target fijado por digest.

## AutomaticUpdatePolicy

`rpm-ostreed` soporta la política `stage`, que descarga y prepara el update para el siguiente boot sin reiniciar por sí sola.

Archivo host-local:

```ini
# /etc/rpm-ostreed.conf
[Daemon]
AutomaticUpdatePolicy=stage
IdleExitTimeout=60
```

Aplicar/releer:

```bash
sudo rpm-ostree reload
sudo systemctl enable rpm-ostreed-automatic.timer --now
rpm-ostree status
```

`IdleExitTimeout=60` coincide actualmente con el default upstream, pero se documenta aquí porque forma parte de la intención operativa del host.

## Horario local del timer

Si se quiere mantener el staging diario alrededor de la 01:00:

```ini
# /etc/systemd/system/rpm-ostreed-automatic.timer.d/override.conf
[Timer]
OnCalendar=
OnCalendar=*-*-* 01:00:00
Persistent=true
```

Después:

```bash
sudo systemctl daemon-reload
sudo systemctl restart rpm-ostreed-automatic.timer
systemctl list-timers rpm-ostreed-automatic.timer --all
```

El `OnCalendar=` vacío limpia el calendario heredado del timer antes de definir el nuevo.

## Estado local que no está en la imagen

Actualmente pueden existir paquetes layered/locales —por ejemplo software de terceros que no conviene hornear en la imagen—. Antes de cambios grandes:

```bash
bash scripts/recovery/capture-host-state.sh
rpm-ostree status -v
```

El snapshot registra inventario pero evita copiar secretos, authfiles y contenido de `$HOME`.

## Verificación después del reboot

```bash
rpm-ostree status -v
systemctl is-enabled rpm-ostreed-automatic.timer
systemctl list-timers rpm-ostreed-automatic.timer --all
tailscale status
systemctl --failed
```

Si el deployment nuevo no funciona, seguir `docs/DISASTER-RECOVERY.md`.
