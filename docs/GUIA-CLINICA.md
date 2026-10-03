# GUÍA CLÍNICA — Instalar y operar la suite APS Conecta Gestión AIO

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
4. `sudo aps-conecta abrir` — el instalador web (§4): imprime un enlace.
5. `sudo aps-conecta temporizadores` — activa la re-provisión semanal (domingo 03:00) y el
   refresco mensual del mapa (día 4, 05:00), en hora de Santiago. La instalación los activa sola
   al terminar («Listo»); tras construir el mapa o una actualización se vuelve a ejecutar. Si una
   ejecución encuentra deriva (algo en la instancia que no se declaró), cada administrador recibe
   un aviso al entrar, y `aps-conecta estado` — sin sudo — muestra cada elemento con su arreglo.

## 3. El asistente (:8080)

El asistente está en español. Lo importante:

- **La frase de contraseña del asistente** la muestra el paso 7 del instalador web, que también
  deja el asistente configurado; en el asistente solo queda pulsar «Iniciar».
- El **dominio** debe apuntar al servidor y el servidor debe poder alcanzarse a sí mismo por
  ese dominio (la prueba «hairpin»; `INSTALLER.md` §7 trae los arreglos de DNS si preflight
  la marca en rojo).
- **La oficina es Euro-Office**, la única de la suite: el asistente no ofrece cambiarla ni
  desactivarla. No hay tienda de aplicaciones ni contenedores comunitarios: las apps de la suite
  vienen incorporadas y el conjunto se actualiza junto, nunca por partes.
- Talk, Whiteboard e Imaginary parten apagados; el paso 7 activa Talk (y su grabación) si caben
  en el servidor.
- Tras «Iniciar», la tarjeta «Suite en marcha» remite a la pestaña del instalador web
  (`sudo aps-conecta abrir` si se cerró).
- **Reinstalar desde cero** (una instalación fallida, o una frase del asistente que no se vio):
  `INSTALLER.md` §12. Borra la instancia y todo su contenido.

## 4. El instalador web: el enlace y el flujo

```bash
sudo aps-conecta abrir
```

La consola imprime **un enlace** — `https://<ip-del-servidor>:<puerto>/login#acceso=…` — y la huella
del certificado propio del instalador. Ábralo **desde otro equipo de la red**:
- **El aviso del certificado.** El navegador advierte una vez; compare la huella con la de la consola.
- **El ingreso.** La sesión se inicia sola. Sin el enlace completo, la página pide el código de
  acceso (lo que sigue a «#acceso=»).

Esa NO es la dirección que usará el personal: el instalador es solo su herramienta y se cierra al
terminar.

Después de la bienvenida, el navegador recorre los pasos 6 a 9 de la instalación:

1. **Elegir el centro** — región, comuna y tipo de centro filtran el registro DEIS completo (todos
   los centros de atención primaria: CESFAM, PSR, CECOSF, SAPU…); la búsqueda acepta nombre,
   código DEIS, comuna o dirección, con o sin tildes. La ficha muestra lo que dirá el sitio, y
   «Confirmar centro» lo fija. Se puede cambiar hasta cargar los equipos; desde ahí la instalación
   sirve a ese establecimiento y a ningún otro.
2. **Iniciar la suite** — las cinco aplicaciones APS con su versión (se activan al ejecutar), y si
   Talk y su grabación caben en este servidor, con el motivo. «Preparar el asistente» deja el
   asistente listo con el dominio del servidor, la hora de Santiago, Euro-Office, Talk según quepa y
   el respaldo diario a las 04:00 hora de Santiago (el asistente la muestra en UTC: 07:00 en horario
   de verano, 08:00 en invierno; tras el cambio de hora corre a las 03:00 o a las 05:00). Marque «Omitir la validación del dominio» si el servidor no tiene
   acceso desde Internet. La pantalla muestra la frase de contraseña del asistente; ábralo con
   «Abrir el asistente e iniciar», ingrese con esa frase y pulse «Iniciar». El avance de cada
   contenedor se ve aquí; con la suite instalada aparece «Siguiente».
3. **Cargar equipos y personas** — en una sola pantalla:
   - los sectores y programas del establecimiento, uno por línea (nadie los conoce fuera del
     equipo local); debajo de cada lista aparece el código de grupo de cada uno, el que usa la
     planilla. «Guardar equipos» los fija; guardarlos de nuevo con cambios muestra lo nuevo y lo
     quitado: «Reemplazar» o «Conservar»;
   - la planilla de personas (§5), con su plantilla («Descargar plantilla») y la lista de
     «Grupos válidos».
4. **Revisar y ejecutar** — el plan en palabras del establecimiento: el centro, sus sectores y
   programas, cada persona de la planilla con sus grupos (la primera administración marcada), las
   cuentas de cargo, los componentes y la mantención automática. «Ejecutar» crea los grupos, las
   carpetas y las cuentas, y aplica la marca, en unos minutos; la pantalla muestra cada paso a
   medida que termina (y la consola del servidor, línea a línea). Recargar la página no lo
   interrumpe.
   - Con **«divergencia vacía»** (la instancia coincide con su declaración, usuarios incluidos)
     aparece **«Listo»**: el instalador se cierra solo, el enlace deja de servir y la consola activa
     los temporizadores.
   - Cualquier otro resultado es un hallazgo con nombre, nunca un error mudo: la pantalla muestra
     su encabezado, y el detalle y el arreglo están en la consola del servidor
     (`aps-conecta estado`). Corríjalo y vuelva a ejecutar.

## 5. La planilla de usuarios

Un archivo de texto con **seis columnas separadas por punto y coma**, una fila por persona:

```
usuario;nombre;apellidos;correo;grupos;primer_admin
```

- **Sin columna de contraseñas.** Las contraseñas las genera el sistema, cifradas al azar, y se
  entregan selladas (§6). La planilla que usted prepara no lleva ningún secreto.
- **`primer_admin`**: exactamente **un** `sí` en toda la planilla (la primera persona en entrar
  a arreglar algo); todas las demás filas llevan `no`.
- **`grupos`**: los códigos de sector, programa y cargo de este centro, separados por espacios —
  la pantalla los muestra en «Grupos válidos», y la plantilla («Descargar plantilla») trae dos
  filas de ejemplo con los suyos. «Todo el personal» y la categoría de cada cargo se agregan
  solos: no los escriba. Se espera a **todo el personal** — la planilla es el registro de
  personas, no una lista de invitados.
- **Los cargos no van en la planilla.** La dirección y las jefaturas (jefe de sector, jefe de
  SOME…) **se crean solas, con sus propias cuentas permanentes** — la planilla nombra
  **personas**; los cargos son la estructura, y confundirlos duplica cuentas.
- **El formato**: UTF-8, punto y coma. **Si viene de Excel**: «Guardar como» → CSV UTF-8. Un CSV
   de Excel en Windows sale por defecto en windows-1252 y los acentos llegan rotos — la
   pantalla de carga lo avisa si lo detecta y el arreglo es volver a guardar como «CSV UTF-8».

## 6. Las credenciales

Al cargar la planilla, el sistema sella `/opt/aps-conecta/credentials.txt` (permiso 0600 — solo
root): una fila por persona y una por cada cuenta de cargo (`Cargo director`, `Cargo jefe.norte`, …),
cada una con su propia contraseña de primer ingreso. Se entregan al final, cuando la consola muestra
«Listo» — la pantalla de la planilla lo dice. Si la instalación no llega a ejecutarse, el archivo
nombra cuentas que todavía no existen. **El ritual de entrega:**

1. Abra el archivo **como root** (`sudo cat /opt/aps-conecta/credentials.txt`).
2. Entregue a cada persona **su fila** — no el archivo completo. La fila de un cargo se entrega a
   quien lo ocupa.
3. Pida a cada persona que cambie su contraseña al entrar por primera vez: **Configuración
   personal → Seguridad**. El sistema no lo exige.
4. **Conserve el archivo.** La re-provisión semanal lo lee para crear las cuentas que falten;
   solo root puede abrirlo.

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
suite, vive en el servidor y **se refresca solo cada mes** (el temporizador del día 4, que activa `sudo aps-conecta
temporizadores`).

- **Territorio** se instala con la suite, en «Revisar y ejecutar».
- **Sus capas comunales**: `aps-conecta datos` trae y verifica los paquetes de la comuna e imprime
  cómo importarlos. Antes de la primera provisión no descarga nada.

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
- Un respaldo de un Nextcloud AIO estándar no se restaura en la suite: la única mudanza es la de
  esta herramienta.

## 10. Las revisiones manuales (después de instalar y de cada actualización mayor)

Ocho verificaciones que no tienen automatización — cinco minutos, con ojo:

1. **Ingreso automático**: cerrar sesión y volver a entrar; el ingreso persiste.
2. **Cambio de frase del asistente**: cambiar la frase de contraseña del asistente AIO y
   volver a ingresar con la nueva.
3. **Comportamiento del ingreso**: una frase incorrecta muestra el error correcto, sin quedar
   en blanco.
4. **Apps opcionales**: activar/desactivar una opcional desde el asistente y ver que el
   conjunto queda consistente.
5. **Oficina**: la tarjeta «Oficina» muestra Euro-Office y no ofrece cambiarla ni desactivarla.
6. **Variables de entorno**: cambiar una variable visible en el asistente y verla reflejada.
7. **Zona horaria**: cambiar la zona horaria desde el asistente y verificar la hora de los
   respaldos.
8. **Respaldo diario**: disparar el respaldo diario desde el asistente y verlo terminar con
   su resumen.

Cualquier cosa rara: anótela antes de tocar nada — el registro de bugs del repositorio
(`BUGS.md`) es donde termina viviendo.
