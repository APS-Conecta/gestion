<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Diagnóstico de recursos de la suite

El plan [#175](https://github.com/APS-Conecta/gestion/issues/175) conserva las comprobaciones
funcionales y el registro de uso. El dimensionamiento automático y el ensayo de capacidad
quedaron retirados el 2026-11-01. La grabación permanece desactivada.

## Referencia oficial

Los [requisitos de Nextcloud 34](https://github.com/nextcloud/documentation/blob/655c01bf5cd7b71dca088b67f701b74c1aa74b0d/admin_manual/installation/system_requirements.rst#L66)
describen la memoria por proceso y su dependencia de las personas activas, las aplicaciones,
los archivos y la actividad. La administración dimensiona el servidor según su uso.
Los controles actuales del instalador conservan sus valores anteriores.

## Registro de uso

Clean boot conserva una serie por trabajo y la instantánea final del trabajo de ciclo de vida.
El colector lee contadores del anfitrión y métricas de los servicios. Cada muestra identifica
su fecha UTC, tiempo monotónico, arranque y unidades. El cierre registra PID, cantidad de
muestras y motivo de término. Las lecturas ausentes se registran como no disponibles.

Para recopilar un diagnóstico:

```bash
measurement_dir="$(mktemp -d /tmp/aps-measurement.XXXXXX)"
(umask 077
 exec python3 scripts/usage.py "$measurement_dir/usage.jsonl" --interval 5 --duration 7200 \
   > "$measurement_dir/collector.log" 2>&1 < /dev/null) &
printf '%s\n' "$!" > "$measurement_dir/collector.pid"
```

Para terminar la captura:

```bash
python3 scripts/usage.py "$measurement_dir/usage.jsonl" --stop "$measurement_dir/collector.pid"
```

Registre la versión, las imágenes, los recursos disponibles y las operaciones realizadas.
La captura acredita el consumo observado durante ese período. Su interpretación respeta el
alcance de cada contador; el presupuesto completo de la suite requiere evidencia propia.

Referencias: [contadores de Linux](https://www.kernel.org/doc/html/v6.12/filesystems/proc.html)
y [métricas de Docker](https://docs.docker.com/reference/cli/docker/container/stats/).
