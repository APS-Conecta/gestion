# GUÍA CLÍNICA — Instalar y operar la suite APS Conecta AIO

Esta guía es para la persona de informática del establecimiento: instalar la suite, entregar
las credenciales, actualizarla y cuidarla. El detalle técnico de cada comando está en
[`INSTALLER.md`](INSTALLER.md) (en inglés, el canon del repositorio); aquí va el recorrido
completo, en español.

## 1. Lo que va a instalar

Una suite completa para un establecimiento: documentos, coordinación, oficina y chat del
personal, sobre **un solo servidor** del recinto. La instalación tiene tres piezas: el
**asistente** (una página web que crea y cuida los contenedores), el **Provisionador** (la
herramienta que configura el establecimiento: carpetas, grupos, usuarios) y los
**temporizadores** (el mantenimiento semanal y mensual, automáticos). Un establecimiento por
instalación; la versión de la suite es la etiqueta del repositorio gestión.

## 2. La instalación (resumen)

El recorrido completo, paso a paso con los comandos, está en `INSTALLER.md` §2–6. En resumen:

1. `aps-conecta preflight` — revisa el servidor (docker, puertos, DNS). Todo lo rojo viene
   con su arreglo sugerido.
2. El comando `docker run` que preflight imprime — se pega tal cual; nunca se re-escribe a mano.
3. El asistente en `http://<ip-del-servidor>:8080`.
4. `aps-conecta provision` — el Provisionador (§4).
5. Los temporizadores (§7).

## 3. El asistente (:8080)

El asistente está en español. Lo importante:

- **La frase de contraseña inicial se muestra una sola vez**, en la primera carga de `/setup`:
   cópiela en ese momento (una vez que apache corre, el ingreso queda bloqueado sin ella).
- El **dominio** debe apuntar al servidor y el servidor debe poder alcanzarse a sí mismo por
  ese dominio (la prueba «hairpin»; `INSTALLER.md` §7 trae los arreglos de DNS si preflight
  la marca en rojo).
- **Euro-Office queda por defecto** — no lo cambie. La tienda de aplicaciones está oculta:
  las apps de la suite vienen incorporadas y el conjunto se actualiza junto, nunca por partes.
- La tarjeta de territorio dice «pendiente de empaquetado»: el mapa ya funciona (§8); esa
  tarjeta es la aplicación territorio, que llega más adelante.

## 4. El Provisionador: el ingreso y el flujo

```bash
aps-conecta provision
```

La consola imprime la **dirección** y el **token de acceso** — cópielos en ese momento; el
token no vuelve a mostrarse (la pantalla de ingreso se lo pide). Ábralo en el navegador **desde
otro equipo de la red** cuando pueda, y tome nota: esa NO es la dirección que usará el personal
— el Provisionador es solo su herramienta; la suite misma vive en el dominio del establecimiento.

El flujo son ocho pantallas:

1. **Ingreso** — el token de la consola.
2. **Contenedores** — confirma que la suite está en marcha (consulta el estado real de los
   contenedores AIO; una lista vacía significa que algo no partió).
3. **Cascada DEIS** — Región → Comuna → Centro de Salud. El registro DEIS completo viene
   incluido; cualquier centro de atención primaria sirve (CESFAM, PSR, CECOSF, SAPU…).
4. **Sectores y programas** — los del establecimiento, uno por línea (nadie los conoce fuera
   del equipo local).
5. **Componentes** — todo activado, sin opciones: la distribución es una sola (documentos,
   oficina, epidemiología, farmacia…). Es la pantalla honesta: no hay nada que decidir.
6. **Planilla** — la lista de usuarios (§5).
7. **Revisión** — el plan completo antes de ejecutar: fases, usuarios, primer administrador.
   Ejecutar es un botón; la consola donde corre `aps-conecta provision` muestra el avance línea
   a línea (esa consola ES el progreso — no hay otra barra).
8. **Divergencia** — el veredicto: **«divergencia vacía»** significa que la instancia coincide
   con su declaración, usuarios incluidos. Cualquier otra cosa es un hallazgo con nombre,
   nunca un error mudo.

## 5. La planilla de usuarios

Un archivo de texto con **seis columnas separadas por punto y coma**, una fila por persona:

```
usuario;nombre;apellidos;correo;grupos;primer_admin
```

- **Sin columna de contraseñas.** Las contraseñas las genera el sistema, cifradas al azar, y se
  entregan selladas (§6). La planilla que usted prepara no lleva ningún secreto.
- **`primer_admin`**: exactamente **un** `sí` en toda la planilla (la primera persona en entrar
  a arreglar algo); todas las demás filas llevan `no`.
- **`grupos`**: los grupos del establecimiento (sectores, programas, roles), separados por
  espacios. (Plan-local fix, Step 5: la API separa grupos por espacios.) Se espera a **todo el personal** — la planilla es el registro de personas, no una
  lista de invitados.
- **Los cargos no van en la planilla.** Jefaturas y roles técnicos (jefe de sector, cat-jefaturas,
  role-*) **se siembran solos, con sus propias cuentas permanentes** — la planilla nombra **personas**;
  los cargos son la estructura, y confundirlos duplica cuentas.
- **El formato**: UTF-8, punto y coma. **Si viene de Excel**: «Guardar como» → CSV UTF-8. Un CSV
   de Excel en Windows sale por defecto en windows-1252 y los acentos llegan rotos — la
   pantalla de carga lo avisa si lo detecta y el arreglo es volver a guardar como «CSV UTF-8».

## 6. Las credenciales

Al ejecutar, el sistema sella `/opt/aps-conecta/credentials.txt` (permiso 0600 — solo root):
una fila por persona con su contraseña de primer ingreso. **El ritual de entrega:**

1. Imprima o abra el archivo **como root** (`sudo cat /opt/aps-conecta/credentials.txt`).
2. Entregue a cada persona **su fila** — no el archivo completo.
3. Cada persona cambia su contraseña en el primer ingreso (el sistema se lo exige).
4. **Borre el archivo cuando esté entregado.** Una hoja con contraseñas de primer ingreso no
   se guarda: cumplió su función.

Las cuentas de los cargos (las que se siembran solas) comparten una contraseña de
`FIXTURE_USER_PASSWORD`, generada en la instalación. Se entrega una vez a jefatura o
informática, igual que el resto:

```bash
grep '^FIXTURE_USER_PASSWORD=' /opt/aps-conecta/gestion/.env
```

No hay claves de oficina que configurar: bajo AIO el asistente es dueño de esa conexión y la
repara solo en cada arranque — no busque claves que no existen (`.env` mínimo por diseño).

## 7. Tras actualizar

Cuando salga una nueva versión de la suite (la etiqueta nueva), después de actualizar:

```bash
aps-conecta revalidate
```

corre las tres verificaciones (humo, oficina, divergencia) y las reporta **todas**, aunque
una falle — el éxito es el conjunto. Si el panel de registros del asistente se ve sin estilo
después de una actualización, un refresco fuerte del navegador (Ctrl+Shift+R) lo arregla: es un
archivo en caché que PHP fija y el fork no toca.

## 8. ¿Y el mapa?

El fondo de mapa ya se sirve solo — no hay que hacer nada para tenerlo: se instaló con la
suite, vive en el servidor y **se refresca solo cada mes** (el temporizador del día 4). Lo que
ve en territorio hasta que esa aplicación se empaquete:

- **La tarjeta «pendiente de empaquetado»** — la aplicación territorio completa (capas
  comunales, paquetes de datos) llega en una versión posterior; `aps-conecta datos` responde
  con esa misma postura y **no descarga nada** mientras tanto.
- El fondo de mapa (Chile completo) ya funciona en las apps que lo usan.

Si el mapa no carga desde otros equipos: la dirección pública del fondo debe ser **https**
(la página del mapa es https y el navegador bloquea fondos http sin importar la
configuración). El arreglo — el «terminador https» — está en `INSTALLER.md` §9, con las tres
recetas (proxy, caddy, tailscale).

## 9. La mudanza (desde la suite anterior)

Si el establecimiento ya tenía la suite anterior (docker compose), la mudanza es una
herramienta con su propio manual: [`MIGRATION.md`](MIGRATION.md) §2½. Lo que debe saber del
lado clínico:

- **El ensayo primero**: la mudanza completa se prueba contra un servidor desechable antes de
  tocar la instalación viva — nunca al revés.
- La ventana de mudanza se coordina (la instancia vieja sigue siendo el respaldo hasta el
  momento del cambio).
- **Después de la mudanza, abra un documento desde OTRO equipo.** Es la prueba que ninguna
  verificación automática puede hacer por usted: si un documento abre bien desde otra máquina,
  la oficina quedó bien migrada; si no, es el síntoma conocido (B-019) con su diagnóstico en el
  manual.

## 10. Las revisiones manuales (después de instalar y de cada actualización mayor)

Ocho verificaciones que no tienen automatización — cinco minutos, con ojo:

1. **Ingreso automático**: cerrar sesión y volver a entrar; el ingreso persiste.
2. **Cambio de frase del asistente**: cambiar la frase de contraseña del asistente AIO y
   volver a ingresar con la nueva.
3. **Comportamiento del ingreso**: una frase incorrecta muestra el error correcto, sin quedar
   en blanco.
4. **Apps opcionales**: activar/desactivar una opcional desde el asistente y ver que el
   conjunto queda consistente.
5. **Contenedores comunitarios**: la sección existe, se expande y no rompe la página.
6. **Variables de entorno**: cambiar una variable visible en el asistente y verla reflejada.
7. **Zona horaria**: cambiar la zona horaria desde el asistente y verificar la hora de los
   respaldos.
8. **Respaldo diario**: disparar el respaldo diario desde el asistente y verlo terminar con
   su resumen.

Cualquier cosa rara: anótela antes de tocar nada — el registro de bugs del repositorio
(`BUGS.md`) es donde termina viviendo.
