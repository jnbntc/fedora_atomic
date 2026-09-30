Host recovery snapshot: 20260927T201650Z UTC

Este snapshot es inventario, NO backup de datos de usuario.

Incluye:
- rpm-ostree status y JSON
- inventario RPM
- Flatpaks (si existen)
- estado del timer rpm-ostreed
- rpm-ostreed.conf
- nombres de repos YUM (no su contenido)

No recopila:
- claves SSH
- tokens
- contraseñas
- /etc/shadow
- authfiles de registries
- contenido de /var/home/juanb
