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

> **Regla de oro:** nunca edites el core de Nextcloud ni las apps de terceros. Solo capas blandas: el panel Theming, comandos `occ`, un tema de servidor propio (`themes/apsconecta/`) y CSS/l10n propios. Así no se dispara la obligación AGPL §13 ni se rompe la vía de actualización.

---

## 2. No hay vía por el panel de administración

Esta guía traía antes un apartado «vía rápida» para fijar nombre, colores y enlaces desde
**Ajustes → Administración → Theming**. Se ha eliminado: contradice **AD-2** (lo único que muta el
estado de la instancia es `make seed`) y contradecía al propio apartado 3, que ya se titulaba «la
única». Un ajuste hecho a mano no sobrevive a un despliegue limpio y no queda en git.

Todo — texto, colores, imágenes, tema y apps — se aplica desde `15-branding.sh`. Ver apartado 3.

---

## 3. Vía reproducible — `make seed` (la única)

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

**Sí sube imágenes**, con `occ theming:config <clave> <ruta-absoluta>` (§4). La afirmación
anterior — que el `occ` de NC34 solo fija texto y color — era **falsa**; solo exige ruta absoluta.
Lo que sigue prohibido es subirlas por el panel: sería el "hand-click" que AD-2 veta.

> **Revertir cualquier clave:** `occ theming:config <clave> --reset`.

---

## 4. Las imágenes de marca (sin subir nada)

Los ficheros viven en el tema y la fase los **registra** con `occ theming:config <clave>
<ruta-absoluta>` apuntando al bind-mount. No se sube nada por el panel, no hace falta la API ni
credenciales de admin, y el registro es lo que hace funcionar la rasterización del favicon, el
webmanifest y los correos con marca:

```
gestion/themes/apsconecta/core/img/
├── logo/logo.svg          ← clave `logo`: tarjeta de login (lockup completo)
├── logo/logo-header.svg   ← clave `logoheader`: cabecera, hueco de 62x44 px (SOLO la marca;
│                            el lockup completo ahí deja el texto en ~4 px, ilegible)
├── favicon.svg            ← clave `favicon`
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

## 5. El tema de servidor

Ya está instalado: vive en **`gestion/themes/apsconecta/`**, que `compose.yaml` monta en `/var/www/html/themes`. Lo que está en git *es* lo que corre — no hay paso de copia.

```
gestion/themes/apsconecta/
├── MAPEO.md                    ← qué entrega server.css de verdad, y por qué tan poco
└── core/
    ├── css/server.css          ← fuentes, display, cabecera, foco, alto contraste
    ├── fonts/*.woff2           ← Fraunces + Nunito Sans (zero-egress). La ÚNICA razón
    │                             de que este directorio exista
    └── img/                    ← logo, logo-header, favicon, fondo (§4)
```

Ya **no** hay `defaults.php` (§7) ni `apps/<appid>/img/` (§6: cero iconos en conflicto).

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

## 6. Iconos por app (una sola cara)

Nextcloud busca **primero** las imágenes dentro del tema. Poniendo un SVG en
`themes/apsconecta/apps/<appid>/img/<icono>.svg` **reemplazas el icono de navegación de cualquier app sin tocar la app** (cero modificación ⇒ AGPL §13 no se dispara).

**Solo se sobrescribe un icono que choque.** Criterio objetivo, no de gusto:

> Un icono **choca** si el SVG que trae la app usa **más de una tinta**.

*(Criterio corregido el 2026-07-27. Decía también «carece de `currentColor`»; eso era falso: más de
30 apps de serie no lo llevan porque la app Theming las recolorea ella misma desde `img/app.svg`.)*

Los iconos Material de serie (`files`, `calendar`, `contacts`, `tables`, `forms`…) **se conservan**: nuestros dibujos usan lenguaje Material justamente para *desaparecer dentro del anfitrión*, así que sustituir un Material de serie por el nuestro no se nota y añade un fichero a re-verificar en cada upgrade. (Esa regla se citaba como «ADR-iconos», documento que nunca existió; vive ahora en ADR-0001 § *Per-app icons*.)

**Estado medido el 2026-07-27: cero.** Escaneadas todas las apps activas, ninguna trae un icono
multitinta, así que `themes/apsconecta/apps/` no existe y no hace falta.

Cómo decidir, con el stack arriba:

```bash
occ app:list                      # qué hay realmente instalado
# ¿choca? Cuenta tintas distintas en el app.svg; más de una → sí.
grep -oE '#[0-9a-fA-F]{3,8}' <app>/img/app.svg | sort -u
```

- El **nombre del fichero** sale de `<navigations><icon>` en el `info.xml` de cada app. Verificado: `calendar` → `calendar.svg`, `forms` → `forms.svg`; el resto usa `app.svg`. Compruébalo app por app.
- **Restricción de dibujo:** el icono de la barra superior se pinta **monocromo sobre el header violeta**. Usa SVG de **una sola tinta, fondo transparente, `currentColor`, rejilla ~20px** — nunca la teja violeta (se vería morado sobre morado).
- Los dibujos viven en el sprite de `sistema-diseno.html` § Iconografía. Es una **galería**, no un manifiesto: la verdad sobre qué se envía es `ls gestion/themes/apsconecta/apps/*/img/`.

---

## 7. Trampas conocidas (ya verificadas — no las redescubras)

- **Nombre del producto:** `productName` es una clave aparte (`config:app:set theming productName`). Sin ella "Nextcloud" se filtra.
- **Banner iOS "Nextcloud — Abrir":** por defecto el id es `1125420102`. Se neutraliza con
  `occ config:system:set customclient_ios_appid ""` — `OC_Defaults.php:44` lee esa clave de sistema
  y las plantillas `layout.*.php` solo emiten el meta si el id no es `''`. Ojo: el leak es un
  número, `grep Nextcloud` no lo ve. Comprueba con
  `curl -s localhost:8180/login | grep -c apple-itunes-app` → debe dar `0`.
- **Fondo azul de Nextcloud:** el fondo por defecto es un **wallpaper**, no un color.
  `background_color` no lo quita. Para fondo plano: `theming:config background backgroundColor`.
  Aquí usamos una **imagen** (`background.svg`), así que no aplica; si quitas la imagen, recuerda
  esto — y recuerda ajustar `background_color` con ella (trampa siguiente).
- **`background_color` decide el color del TEXTO sobre el fondo**, no solo el color de relleno.
  `CommonThemeTrait.php:82` deriva `--color-background-plain-text` de él, y `:83` la inversión de
  los iconos. Blanco con una imagen violeta = texto negro e iconos invertidos sobre violeta.
- **Las variables del tema en `:root` no llegan.** Nextcloud las declara en
  `body[data-theme-light]` y el `server.css` del tema carga antes. Mide siempre sobre
  `document.body`, nunca sobre `document.documentElement` (con el SO en oscuro da una falsa alarma).
- **Un SVG que no parsea se sirve con un 200 y no pinta nada.** Los SVG de marca se leen como XML;
  un doble guion dentro de un comentario XML es error de sintaxis. `make test` los parsea todos.
- **`enforce_theme=light` también quita el alto contraste** y la fuente para dislexia:
  `ThemesService::getThemes()` solo devuelve `default`, `dark` y el forzado. Por eso el bloque
  `@media (prefers-contrast: more)` de `server.css` es la única vía de alto contraste que queda.
- **Idioma:** no existe una traducción `es_CL`. El repo ya lo resuelve en `provisioning/phases/10-locale.sh`: `default_language=es_419` (la traducción que Nextcloud sí trae), `default_locale=es_CL` (formato chileno de fechas/números) y `default_phone_region=CL`. No uses `es` a secas.
- **Reinicio:** ya no hace falta ninguno; era solo por el opcache de `defaults.php`, eliminado.
- **Acceso clientless:** si tu instancia bloquea `status.php` a red externa (`Require local`), las apps de escritorio/móvil oficiales no conectan a propósito — la vía móvil es la **PWA**.

---

## 8. PWA y apps móviles

- Nextcloud **genera el webmanifest** desde el theming. Verifícalo: `curl https://TU-HOST/apps/theming/manifest`.
  Mapeo: `name ← productName` · `short_name ← name` · `theme_color ← primary_color` · `background_color` · iconos ← `favicon`/`img/app.svg` por app · `display ← theming.standalone_window.enabled`.
- Las **apps oficiales de Android e iOS sincronizan el tema del servidor** automáticamente (color, logo, fondo): al tematizar el servidor quedan coherentes web, PWA, Android e iOS.
- La PWA debe verse bien en **360px** de ancho (el tema es responsive y está verificado a ese ancho).

---

## 9. Verificación final

1. **Refresca fuerte:** Ctrl/Cmd + Shift + R.
2. Comprueba: login (degradado + logo), header (marca oficial flotante), correos, favicon, PWA (`/apps/theming/manifest`), y que **no** aparezca "Nextcloud" ni el número `1125420102`.
3. Confirma que **no existe** el selector de tema y que el modo oscuro es inalcanzable (`enforce_theme=light`).
4. **Comprueba el tema realmente cargado.** Pega el fragmento de consola de
   [`THEMING-MODEL.md` §5](THEMING-MODEL.md) en las devtools **sobre una página de Nextcloud**,
   leyendo `document.body`. (El panel «Deriva» del brandbook hacía esto entre ficheros y se
   eliminó el 2026-07-27: no podía ver una instancia en marcha, que es justo por lo que nunca
   detectó que el mapa entero era inerte.)
5. **Puertas automáticas:** `make test` (los SVG parsean, cada `url()` de `server.css` existe) y
   `make smoke` (`/status.php` responde 200 y **no** contiene "Nextcloud").

## 10. Cómo ver el brandbook

Desde la carpeta del kit (`../APS Conecta Nextcloud/`, hermana de este repo):

```bash
cd "../APS Conecta Nextcloud" && python3 -m http.server 8080
# abre http://localhost:8080/sistema-diseno.html
```

(Con `file://` las fuentes y algunos assets no cargan; usa el servidor local.)

## 11. Licencias

Tokens y logos **MIT** (los consume también el sitio apsconecta.cl) · fuentes Fraunces y Nunito Sans **SIL OFL 1.1** (no subsetear ni renombrar) · iconografía en idioma Material (**Apache-2.0 / MIT**).

El **tema y las apps propias son propietarios**: viven en el repo `gestion/`, cubierto por su `LICENSE` (propietario, todos los derechos reservados) y detallado en `gestion/docs/LICENSING.md` §1. La marca AGPL-3.0 que este documento declaraba antes se retira: era una elección libre, no una obligación — al ser solo capas blandas, el §13 de la AGPL nunca se dispara.
