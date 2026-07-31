# BRANDING.md — Instalación de la marca en Nextcloud

Guía paso a paso para vestir la instancia con la identidad de **APS Conecta Gestión**
(tema **claro único**) sobre **Nextcloud 34**.

> Cómo se comporta el theming de Nextcloud por dentro, y las reglas que no se pueden romper, están
> en [`THEMING-MODEL.md`](THEMING-MODEL.md). Esta guía es el *qué hacer*; aquella es el *por qué*.
> Este fichero se llamaba `INSTALACION-NEXTCLOUD.md` y vivía en el kit de marca; se mudó al repo el
> 2026-07-27 porque describe lo que corre en el servidor.

---

## 0. Qué contiene esta carpeta

Lo que **corre** está en este repo:

```
gestion/
├── docs/BRANDING.md              ← esta guía
├── docs/THEMING-MODEL.md         ← reglas, estructura de ajustes, verificación
├── provisioning/phases/15-branding.sh   ← el ÚNICO sitio que escribe la marca
└── themes/apsconecta/            ← una sola copia; compose.yaml la monta
    ├── MAPEO.md
    └── core/{css,fonts,img}/
```

Lo que **alimenta a diseño** está en el kit hermano `../APS Conecta Nextcloud/` (MIT, fuera de git):
`tokens/`, `logo/`, `css/apsconecta.css`, `sistema-diseno.html` (brandbook vivo),
`brandbook-agnostico.html`, `README-MARCA.md`.

> **Regla:** *corre en el servidor → `gestion/`; alimenta a un diseñador o al sitio web → el kit.*

## 1. Requisitos

- Nextcloud **34** con la app **Theming** activada (viene por defecto).
- Acceso a **`occ`** como el usuario web:
  - Instalación normal: `sudo -u www-data php occ …`
  - Docker: `docker exec -u www-data <contenedor> php occ …`
- Para que Nextcloud **genere favicons e iconos de pantalla de inicio** a partir del logo hace falta **PHP imagick con soporte SVG** (p. ej. `libmagickcore-*-extra`). Si no lo tienes, sube tú el favicon en las opciones avanzadas de Theming.

> **Regla de oro:** nunca edites el core de Nextcloud. Prefiere capas blandas: el panel Theming,
> comandos `occ`, un tema de servidor propio (`themes/apsconecta/`) y CSS/l10n propios.
>
> *Matizado por [ADR-0002](adr/0002-app-patches.md) el 2026-07-29:* las apps de terceros **sí** se
> parchan, en tiempo de ejecución y desde `.patch` versionados, cuando no hay otra vía. Qué implica
> eso para la AGPL §13 lo resuelve [`LICENSING.md`](LICENSING.md) §4, que es su dueño.

---

## 2. Vía reproducible — `make seed` (la única)

No hay script suelto que ejecutar. La capa de identidad es una **fase de provisioning**,
`gestion/provisioning/phases/15-branding.sh`, y se aplica con el resto:

```bash
cd gestion
make up      # levanta el stack (bind-monta ./themes)
make seed    # aplica locale, marca, grupos, carpetas, ACL…
```

Es idempotente: cada clave se lee antes de escribirse, así que re-ejecutar no hace nada.
La fase hace, en orden:
1. **Identidad:** `name`, `slogan`, `url`, `imprintUrl`, `privacyUrl`.
2. **`productName`** (clave separada — **imprescindible**): sin ella, "Nextcloud" se filtra por `status.php`, `OC.theme`, las capabilities OCS y el botón de shares públicos.
3. **Colores:** `primary_color #7f21fe`, `background_color #5315a8`.
   `background_color` **no es decorativo**: de él deriva Nextcloud el color del texto sobre el
   fondo y la inversión de los iconos de cabecera. Tiene que coincidir con el tono dominante de
   `background.svg`. Ponerlo en blanco pintaba texto negro e iconos invertidos sobre violeta
   (corregido el 2026-07-27). Ver regla 5 de `THEMING-MODEL.md`.
4. **Tema claro forzado:** `enforce_theme = light` + `disable-user-theming = yes`. Son claves **complementarias**: la primera elimina la elección de tema/apariencia, la segunda impide que cada usuario cambie fondo y color por su cuenta.
5. **Banner iOS:** `config:system:set customclient_ios_appid ""` — mata el meta
   `apple-itunes-app`. Sustituye al antiguo `defaults.php`, eliminado el 2026-07-27.
6. **Navegación:** `ensure_app side_menu` (app de terceros, soportada en NC34).
7. **Activación del tema:** `config:system:set theme --value apsconecta`.

**Sí sube imágenes**, con `occ theming:config <clave> <ruta-absoluta>` (§3). La afirmación
anterior — que el `occ` de NC34 solo fija texto y color — era **falsa**; solo exige ruta absoluta.
Lo que sigue prohibido es subirlas por el panel: sería el "hand-click" que AD-2 veta.

> **Revertir cualquier clave:** `occ theming:config <clave> --reset`.

---

## 3. Las imágenes de marca (sin subir nada)

Los ficheros viven en el tema y la fase los **registra** con `occ theming:config <clave>
<ruta-absoluta>` apuntando al bind-mount. No se sube nada por el panel, no hace falta la API ni
credenciales de admin, y el registro es lo que hace funcionar la rasterización del favicon, el
webmanifest y los correos con marca:

```
gestion/themes/apsconecta/core/img/
├── logo/logo.svg          ← clave `logo`: tarjeta de login (lockup completo)
├── logo/logo-header.svg   ← clave `logoheader`: cabecera (lockup completo, con teja). El hueco
│                            nativo dejaba el texto en ~4 px; server.css lo ensancha y añade
│                            INICIO — las medidas las manda MAPEO.md §3
│                            AMBOS lockups llevan su propia subset de Fraunces/Nunito Sans
│                            embebida: un SVG servido como imagen no ve el @font-face de
│                            server.css (B-011). Regenerar con tools/embed-fonts.py
├── logo/logo-mark.svg     ← la figura sola: cabecera por debajo del corte (§ cabecera)
├── favicon.svg            ← clave `favicon`
├── manifest.json          ← el webmanifest que verifica `smoke.sh` (control 7)
└── background.svg         ← clave `background`: telón de TODA la UI, no solo del login
```

> **No pintes encima del fondo.** `server.css` tenía un degradado claro sobre `body`/`#content`
> que tapaba `background.svg` por completo: estaba registrado, servido y no se vio nunca. Se
> eliminó el 2026-07-27.
>
> **Resuelto el 2026-07-27** (ADR-0001 § Pending). La pregunta original —«¿ganan las imágenes del
> tema a los valores que la app Theming guarda en BD?»— quedó **sin objeto**: no dependemos de esa
> búsqueda, las registramos nosotros. Verificado en vivo: las cuatro claves registradas, favicon
> rasterizado y webmanifest tematizado. El plan B por API OCS (que habría metido credenciales de
> admin en el runner del seed) no hizo falta.

---

## 4. El tema de servidor

Ya está instalado: vive en **`gestion/themes/apsconecta/`**, que `compose.yaml` monta en `/var/www/html/themes`. Lo que está en git *es* lo que corre — no hay paso de copia.

```
gestion/themes/apsconecta/
├── MAPEO.md                    ← qué entrega server.css de verdad, y por qué tan poco
└── core/
    ├── css/server.css          ← fuentes, display, cabecera, foco, alto contraste
    ├── fonts/*.woff2           ← Fraunces + Nunito Sans (zero-egress). La ÚNICA razón
    │                             de que este directorio exista
    └── img/                    ← el listado completo vive en §3, no se repite aquí
```

Ya **no** hay `defaults.php` — su único trabajo lo hace `customclient_ios_appid` — ni
`apps/<appid>/img/` (§5: cero iconos en conflicto).

> **Lo que el CSS del tema puede cambiar es poco.** Nextcloud declara sus variables en
> `body[data-theme-light]` y el tema carga *antes*, así que lo que pongas en `:root` **no llega**.
> Medido: 7 de 30 variables coincidían, y solo porque ya valían lo mismo. Los selectores de
> elemento sí ganan. Lee `THEMING-MODEL.md` antes de tocar `server.css`.

1. **Activa el tema:** lo hace la fase `15-branding` (`config:system:set theme --value apsconecta`).
2. **Reinicio:** ninguno. Hacía falta solo por el opcache de `defaults.php`, que ya no existe.
3. **Fuentes:** Fraunces y Nunito Sans en **woff2 variable** (un fichero por familia cubre pesos 400–800, más las itálicas), en `core/fonts/`, declaradas por `@font-face` con rutas absolutas `/themes/apsconecta/core/fonts/` — **zero-egress, sin Google Fonts**. **Solo woff2, sin fallback a TTF**: ningún navegador que soporte Nextcloud 34 carece de woff2, y el fallback escondía errores (un woff2 ausente caía al TTF en silencio). `make test` verifica que cada `url()` de `server.css` existe en disco. Regenerar tras actualizar una fuente:
   ```bash
   python3 -c "from fontTools.ttLib.woff2 import compress; compress('X.ttf','X.woff2')"
   ```

   Convertir de formato no es subsetear ni renombrar, así que la SIL OFL se cumple.

*(La app **Custom CSS** queda descartada como alternativa: no puede auto-hospedar fuentes, así que perdería la tipografía de marca.)*

---

## 5. Iconos por app — no hay ninguno

Nextcloud busca las imágenes primero dentro del tema, así que un SVG en
`themes/apsconecta/apps/<appid>/img/` reemplazaría el icono de una app sin tocarla. **No se usa:**
se escanearon todas las apps activas el 2026-07-27 y ninguna trae un icono multitinta, que es el
único criterio que justificaría sustituirlo. `themes/apsconecta/apps/` no existe.

El criterio y el porqué de conservar los iconos Material de serie están en
[`ADR-0001`](adr/0001-server-theme-for-branding.md) § *Per-app icons*.

---

## 6. Trampas conocidas

Las trampas del **mecanismo** de theming (`:root` inerte, `background_color` decidiendo el color del
texto, `enforce_theme` quitando el alto contraste, un SVG que no parsea) están en
[`THEMING-MODEL.md`](THEMING-MODEL.md) §3, una sola vez. Aquí quedan las específicas de marca:

- **Nombre del producto:** `productName` es una clave aparte (`config:app:set theming productName`).
  Sin ella «Nextcloud» se filtra por `status.php`, `OC.theme` y el botón de compartir.
- **Banner iOS «Nextcloud — Abrir»:** el leak es un **número**, así que `grep Nextcloud` no lo ve.
  Se neutraliza con `customclient_ios_appid ""`. Comprueba:
  `curl -s localhost:8180/login | grep -c apple-itunes-app` → `0`.
- **El fondo azul de Nextcloud es un *wallpaper*, no un color:** `background_color` no lo quita.
  Aquí se sustituye por `background.svg`; si algún día se retira la imagen, el fondo plano se pone
  con `theming:config background backgroundColor` — y hay que reajustar `background_color` con él.
- **Idioma:** no existe traducción `es_CL`. Se usa `default_language=es` + `force_language=es`, con
  `default_locale=es_CL` para el formato chileno. **No uses `es_419`** (B-009).
- **Acceso clientless:** si la instancia bloquea `status.php` a red externa, las apps oficiales de
  escritorio y móvil no conectan a propósito — la vía móvil es la **PWA**.

---

## 7. PWA y apps móviles

- Nextcloud **genera el webmanifest** desde el theming. Verifícalo: `curl https://TU-HOST/apps/theming/manifest`.
  Mapeo: `name ← productName` · `short_name ← name` · `theme_color ← primary_color` · `background_color` · iconos ← `favicon`/`img/app.svg` por app · `display ← theming.standalone_window.enabled`.
- Las **apps oficiales de Android e iOS sincronizan el tema del servidor** automáticamente (color, logo, fondo): al tematizar el servidor quedan coherentes web, PWA, Android e iOS.
- **360 px, medido el 2026-07-30 (no es lo mismo que «la PWA»** — son dos comprobaciones distintas,
  ver [`THEMING-MODEL.md`](THEMING-MODEL.md) §*«PWA a 360px» eran dos comprobaciones*). A ese ancho el
  header **no cabe**: el lockup y la etiqueta INICIO necesitan 299 px y solo hay 224, y el arte se
  metía 32 px por debajo de los iconos de la derecha. Por eso `server.css` los limita a
  `@media (min-width: 601px)` y por debajo sirve `logo-mark.svg`, la figura sola, con la geometría
  de core. Verificado en un iframe de 360 px, que es el sustituto válido porque `resize_window` es
  un no-op bajo este gestor de ventanas: sin recorte, sin solape y sin scroll horizontal.

---

## 8. Verificación final

1. **Refresca fuerte:** Ctrl/Cmd + Shift + R.
2. Comprueba: login (degradado + logo), header (lockup + INICIO por encima de 601 px, marca sola por
   debajo), favicon, PWA (`/apps/theming/manifest`), y que **no** aparezca "Nextcloud" ni el número
   `1125420102`.
   **Los correos no se pueden comprobar todavía:** no hay SMTP configurado en ninguna parte del repo,
   así que la instancia no puede enviar nada. Este paso queda bloqueado por la decisión de correo
   aplazada (ver la sección *Future* de `ROADMAP.md`); el tema sí llega a las plantillas de correo,
   pero eso no se ha visto en un mensaje real.
3. Confirma que **no existe** el selector de tema y que el modo oscuro es inalcanzable (`enforce_theme=light`).
4. **Comprueba el tema realmente cargado.** Pega el fragmento de consola de
   [`THEMING-MODEL.md` §5](THEMING-MODEL.md) en las devtools **sobre una página de Nextcloud**,
   leyendo `document.body`. (El panel «Deriva» del brandbook hacía esto entre ficheros y se
   eliminó el 2026-07-27: no podía ver una instancia en marcha, que es justo por lo que nunca
   detectó que el mapa entero era inerte.)
5. **Puertas automáticas:** `make test` (los SVG parsean, cada `url()` de `server.css` existe) y
   `make smoke` (`/status.php` responde 200 y **no** contiene "Nextcloud").

## 9. Cómo ver el brandbook

Desde la carpeta del kit (`../APS Conecta Nextcloud/`, hermana de este repo):

```bash
cd "../APS Conecta Nextcloud" && python3 -m http.server 8080
# abre http://localhost:8080/sistema-diseno.html
```

(Con `file://` las fuentes y algunos assets no cargan; usa el servidor local.)

## 10. Licencias

Tokens y logos **MIT** (los consume también el sitio apsconecta.cl) · fuentes Fraunces y Nunito Sans **SIL OFL 1.1** (ver [`LICENSING.md`](LICENSING.md) §3.2: los
lockups SVG sí llevan subset, lo permite la licencia; lo que no se hace es renombrarlas) · iconografía en idioma Material (**Apache-2.0 / MIT**).

El **tema y las apps propias son propietarios**: viven en el repo `gestion/`, cubierto por su `LICENSE` (propietario, todos los derechos reservados) y detallado en `gestion/docs/LICENSING.md` §1. La marca AGPL-3.0 que este documento declaraba antes se retira: era una elección libre, no una obligación — el análisis del §13 lo
resuelve [`LICENSING.md`](LICENSING.md) §4, incluidos los parches de ADR-0002.
