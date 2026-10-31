<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Medición de recursos de la suite

Preparación de [#189](https://github.com/APS-Conecta/gestion/issues/189).
El mínimo de memoria, los núcleos requeridos y el umbral de grabación permanecen pendientes
de medición. Los valores actuales del instalador son anteriores a este trabajo.

## Entorno y procedencia

Use un entorno desechable con memoria y CPU ajustables: una VPS exclusiva o un contenedor
de sistema LXD sin privilegios. Mantenga los clientes de navegador en otros equipos.
Registre el hipervisor o gestor de contenedores, la asignación efectiva, el sistema, el núcleo,
Docker, el almacenamiento, la red y la actividad concurrente del servidor físico.
La carga de los clientes y la sobreasignación del hipervisor afectan la interpretación.

Los contenedores LXD comparten el núcleo del anfitrión. Conserve los contadores del cgroup
(`memory.max`, `memory.current`, `memory.peak`, `memory.events`, `cpu.stat` y CPU disponibles)
junto con las mediciones simultáneas del anfitrión. Los valores virtualizados de `/proc`
describen el contenedor; el mínimo del servidor debe incluir el consumo y margen del anfitrión.

La prueba de compatibilidad en Hostinger utiliza LXD 5.21.8 y Ubuntu 24.04, con dos CPU y
2 GiB de memoria limitada. Verifica Docker, la incorporación de un filtro seccomp adicional
como usuario sin privilegios y el montaje de un archivo Borg mediante FUSE. Estos límites
pertenecen a la prueba de compatibilidad y preceden al ensayo de la suite completa.
El perfil permite anidamiento e intercepta `mknod` y `setxattr`; incorpora `/dev/fuse`.
La prueba de Borg reproduce las capacidades, el dispositivo FUSE y las opciones `--security-opt`
definidos por la suite. El ensayo completo verifica el resto de la configuración publicada.
La API LXD permanece local y el entorno utiliza una red privada sin ocupar los puertos públicos.

Referencias: [límites de Hostinger](https://www.hostinger.com/support/10429687-is-nested-virtualization-supported-in-hostinger/),
[Docker dentro de LXD](https://canonical.com/lxd/docs/v5.21/faq/#how-can-i-run-docker-inside-a-lxd-container).

Conserve el SHA completo del código del instalador, el estado de su árbol, la etiqueta
y los identificadores de las imágenes, el SHA de su compilación y el enlace de Clean boot.
El código del instalador y el código de las imágenes pueden tener revisiones distintas.
La etiqueta reutilizada `v0.0.0-ci.1870` corresponde a las imágenes verificadas de
`7b9a335c191fe417b486718ba6a330952fda314f`.

## Registro de uso

Clean boot conserva una serie por trabajo y la instantánea final del trabajo de ciclo de vida.
El colector lee contadores del anfitrión y métricas de contenedores de la suite; conserva
los campos anteriores `memoria_gib`, `contenedores` y `disco`.

Para cada repetición en el entorno preparado, ejecute desde la revisión que se medirá:

```bash
umask 077
measurement_dir="$(mktemp -d /tmp/aps-measurement.XXXXXX)"
python3 scripts/usage.py "$measurement_dir/usage.jsonl" --interval 5 --duration 7200 \
  > "$measurement_dir/collector.log" 2>&1 < /dev/null &
printf '%s\n' "$!" > "$measurement_dir/collector.pid"
```

Registre en UTC el inicio y el término de instalación, arranque, calentamiento,
carga estable y grabación. Al finalizar la sesión:

```bash
python3 scripts/usage.py "$measurement_dir/usage.jsonl" --stop "$measurement_dir/collector.pid"
```

Cada muestra tiene fecha UTC, tiempo monotónico e identidad del arranque. El cierre incluye
cantidad de muestras, PID del colector y motivo: duración cumplida o detención solicitada. Un cierre correcto
del colector acredita la captura; el cumplimiento del ensayo requiere además sus operaciones
y períodos completos. Un archivo existente se conserva y la nueva ejecución lo rechaza.

`containers_status: unavailable` identifica una lectura fallida, por ejemplo durante un
reinicio de Docker. En ese caso `contenedores` es `null`, nunca un consumo supuesto de cero.
Una interrupción durante la carga estable invalida esa repetición para decidir capacidad.

## Carga y perfil acordados

La carga acordada comprende diez cuentas ficticias simultáneas: dos sesiones activas de
Office, cuatro participantes con audio y video en Talk y cuatro cuentas para cargas,
antivirus, indexación y búsqueda. Las cuentas y los documentos pertenecen al entorno de ensayo.
Verifique ediciones guardadas, resultados por texto del documento y recepción real de medios.
Las comprobaciones de conexión, conversión y chat son requisitos previos de esas operaciones.

El perfil inicial acordado usa video de 720p a 30 cuadros por segundo, quince minutos de
calentamiento y treinta minutos de carga estable, con tres repeticiones por configuración.
Antes de ejecutarlo, fije tamaños, cadencias, corpus, objetivos de latencia y margen requerido.
Registre fallos y tiempos de las operaciones junto con las muestras. La variante de grabación
requiere una llamada real y un archivo reproducible con los medios previstos.

Repita la misma carga al reducir memoria y núcleos. Conserve resultados por debajo, en el
límite candidato y por encima. Fundamente el margen con las observaciones y los objetivos
operativos. El veredicto compartido se implementa después de obtener estos resultados;
#190 y #191 deben verificar nuevamente grabación y concurrencia con sus cambios.

## Interpretación

`MemAvailable` estima memoria utilizable sin intercambio; su mínimo muestreado puede omitir
picos breves. Los campos de memoria del anfitrión se expresan en KiB. Las diferencias de
`pswpin` y `pswpout` se expresan en páginas del tamaño registrado. Compare contadores dentro
del mismo arranque. Un aumento de `oom_kill` requiere investigar el proceso afectado.
Un contador nulo de OOM no acredita latencia ni ausencia de otros fallos.

Los contadores de CPU son acumulativos. Evite sumar nuevamente `guest` y `guest_nice`,
ya incluidos en otros campos. Separe espera de E/S y tiempo sustraído por el hipervisor;
las diferencias inválidas permanecen desconocidas. La memoria presentada por `docker stats`
descuenta caché y su suma no representa el consumo completo del anfitrión.

Referencias: [contadores de Linux](https://www.kernel.org/doc/html/v6.12/filesystems/proc.html),
[métricas de Docker](https://docs.docker.com/reference/cli/docker/container/stats/).
