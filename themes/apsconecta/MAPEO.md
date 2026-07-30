# MAPEO.md — qué posee `server.css`, y por qué tan poco

Documenta lo que el tema de servidor **entrega de verdad** sobre Nextcloud 34, junto al fichero que
describe (`core/css/server.css`). Reglas generales y estructura de ajustes en
[`docs/THEMING-MODEL.md`](../../docs/THEMING-MODEL.md); la decisión, en
[`docs/adr/0001-server-theme-for-branding.md`](../../docs/adr/0001-server-theme-for-branding.md).

> **Este fichero cambió de propósito el 2026-07-27.** Antes documentaba ~25 desviaciones entre
> `tokens/tokens.json` y las variables `--color-*` de Nextcloud. Ese mapa **no llegaba a la
> página**: medido en la instancia real, solo 7 de 30 variables coincidían, y esas 7 porque ya
> valían lo mismo que el valor propio de Nextcloud. El mapa se retiró; esto describe lo que queda.

---

## 1. Por qué se retiró el mapa de variables

Nextcloud declara sus variables de tema en **`body[data-theme-light]`**, y el `server.css` de un
tema de servidor carga **antes** que la hoja de la app Theming. Todo lo declarado en `:root` queda
anulado dentro de `<body>`.

Medición del 2026-07-27 (`getComputedStyle(document.body)`):

| Variable | Valor del tema | Valor real | |
|---|---|---|---|
| `--color-main-text` | `#101828` | `#222222` | ✗ |
| `--border-radius` | `6px` | `4px` | ✗ |
| `--border-radius-rounded` | `999px` | `28px` | ✗ |
| `--border-radius-pill` | `999px` | `100px` | ✗ |
| `--color-border` | `#e2e5e9` | `#ededed` | ✗ |
| `--color-text-maxcontrast` | `#485363` | `#6b6b6b` | ✗ |
| `--color-error` | `#ea003e` | `#FFE7E7` | ✗ ver §2 |
| `--color-success` | `#009764` | `#D8F3DA` | ✗ ver §2 |
| `--color-primary-element` | `#7f21fe` | `#7f21fe` | ✓ pero lo fija `primary_color`, no el CSS |
| `--color-main-background` | `#ffffff` | `#ffffff` | ✓ coincidía con el valor de NC |

**Regla permanente:** antes de añadir cualquier variable aquí, compruébala en `document.body` en
devtools. Si Nextcloud ya la declara, la tuya no llegará — salvo con `!important`, que sí gana a
`body[data-theme-light]` independientemente de especificidad y orden.

**Asimetría clave:** las *variables* pierden; los *selectores de elemento* ganan, porque
`server.css` carga después del CSS del core. Por eso la tipografía, la cabecera y el foco sí
funcionan.

## 2. Dos variables donde el mapa era incorrecto, no solo inútil

La referencia oficial define `--color-error` y `--color-success` así: *"Color to show error state,
this should not be used for text but for element backgrounds."* En NC34 son **tintes claros de
fondo**, no colores de primer plano.

Meter ahí el rosa/verde de marca era **incorrecto**, no solo inservible. Los huecos correctos para
primer plano son `--color-text-error` / `--color-text-success`, y para elementos
`--color-element-error` y familia. Hoy Nextcloud los resuelve a `#bf0000` / `#c90000`; el tema no
los toca.

## 3. Libro mayor de contraste (sigue vigente y sigue siendo útil)

El oro de marca `#e06f00` mide **3,07:1** sobre blanco → **no cumple AA para texto pequeño**. Uso
permitido: rellenos, iconos, insignias y texto grande (≥24px, o ≥19px en negrita). Para texto
pequeño sobre blanco usar el oro oscuro **`#9a4c00`** (≥4,5:1).

| Color | Hex | Ratio | Uso |
|---|---|---|---|
| Violeta primario | `#7f21fe` | 5,57:1 | AA texto/UI ✓ (`primary_color`) |
| Violeta oscuro | `#5315a8` | ~8:1 | Titulares, telón de fondo ✓ (`background_color`) |
| Rosa error | `#ea003e` | 4,33:1 | UI/borde/texto grande — **no** cuerpo de texto |
| Oro | `#e06f00` | 3,07:1 | Rellenos/iconos/texto grande |
| Oro oscuro | `#9a4c00` | ≥4,5:1 | Texto pequeño (Collabora) |
| Tinta | `#101828` | ~16:1 | Texto principal |
| Apagado | `#485363` | ~7:1 | Texto secundario |

Los dos violetas **no son intercambiables**: `background_color` debe seguir siendo el oscuro
(`#5315a8`), porque de él deriva Nextcloud el color del texto sobre el fondo y la inversión de los
iconos de cabecera. Ver regla 5 de `THEMING-MODEL.md`.

## 4. Tipografía — lo único que justifica el directorio del tema

- **Familias:** Fraunces (display: `h1`–`h3`, cabecera, menú) · Nunito Sans (todo lo demás).
- **Nunito Sans se entrega por `--font-face`**, la única variable tipográfica documentada, con
  `!important`. No es adorno: 6 reglas de Nextcloud la leen, y cuatro son de clase
  (`.tooltip`, `.mx-datepicker-main`, `.rich-contenteditable__input`, una etiqueta del selector de
  color) que ganan a cualquier regla `body` que pudiéramos escribir. Antes de fijarla, los tooltips
  y los selectores de fecha se pintaban en system-ui mientras el resto iba con la marca.
- **Fraunces va por selectores de elemento**, porque no existe variable documentada para una fuente
  display.
- `@font-face` con **rutas absolutas** `/themes/apsconecta/core/fonts/`. Fuera de NC dan 404;
  `sistema-diseno.html` las redeclara con rutas relativas.
- **Solo `.woff2`, sin fallback a `.ttf`** (desde ADR-0001). El fallback no protegía a ningún
  navegador que soporte NC34 y escondía 404s. `make test` verifica que cada `url()` existe en disco.
- Fuentes **no subseteadas ni renombradas** (subsetear = *Modified Version* bajo SIL OFL-1.1).
- Se conservan `--default-font-size` (15px) y `--default-line-height` (1.5) de Nextcloud, para no
  descuadrar la densidad de `@nextcloud/vue`.

## 5. Modo oscuro — no existe

`server.css` es claro único (`enforce_theme=light`, decisión del propietario 2026-07-12). No hay
bloque oscuro: sería inalcanzable y mentiría. Los tokens oscuros viven **solo** en el paquete de
marca del sitio web, nunca en el tema.

**Coste no obvio:** `enforce_theme` también elimina `HighContrastTheme` y `DyslexiaFont`. Por eso el
bloque `@media (prefers-contrast: more)` de `server.css` es la **única** vía de alto contraste de la
instancia, y va con `!important` sobre `body`. No lo borres.

## 6. Fondo (trampa medida)

Nunca poner un degradado en `--color-main-background`: NC lo consume como `<color>` sólido y como
`rgb(var(--color-main-background-rgb))` en decenas de reglas.

Y **no pintes encima del fondo.** Hasta el 2026-07-27 este tema pintaba `body, #content,
#content-vue` con un degradado claro que tapaba por completo `background.svg`: la imagen estaba
registrada, servida y no se vio jamás. El telón de marca es el fondo ahora.

La cabecera lleva degradado **solo** en `#header:not(.header-guest)` — en el login, un header
desnudo mostraría una tira fea.

## 7. Cabecera — la marca y la palabra INICIO (2026-07-30)

`#nextcloud` **siempre fue** el enlace al inicio (`layout.user.php:67`), pero solo lo decía a los
lectores de pantalla vía `aria-label`. El tema ahora lo dice a todo el mundo:

- `padding-inline-start: 224px` en `#nextcloud` y `width: 200px` en `.logo`. **El padding ES el
  ancho del elemento** (no hay contenido en flujo salvo el `::after`), así que los dos se mueven
  juntos o el logo desborda sobre el menú de apps: 12 px de inset + 200 px de arte = 212 < 224.
- `::after` con el texto `INICIO`, filete de 1 px a la izquierda, en `--color-background-plain-text`
  (blanco derivado de `background_color`, no escrito a mano).

Dos cosas que hacen que esto sea CSS y no JavaScript: `#nextcloud` es `display:flex`, así que su
`::after` **es un flex item dentro del ancla** — la palabra hereda el área clicable, y el objetivo
pasa de 86×46 a 299×46 px (medido en vivo el 2026-07-30). A dónde va lo decide `defaultapp` en
`provisioning/phases/15-branding.sh`, no el tema.

Espacio: con `side_menu` el menú de apps de arriba está vacío (`#app-menu-container` mide 0×0), así
que `.header-start` usaba 134 px de 1059. Esto gasta 138 de los ~925 libres.

### Puerta de ancho: todo lo anterior vive por encima de 600 px

El header **solo encoge por flex** — `core/css/header.scss` no tiene ni una media query — así que
cuando falta sitio nada se recoloca: se recorta en silencio. Medido el 2026-07-30 con el iframe de
360 px (`resize_window` es un no-op aquí, ver `docs/THEMING-MODEL.md`):

| Ancho | Qué pasaba sin puerta |
|---|---|
| 360 px | `#nextcloud` ofrecía 224 px para 299 px de contenido, y los 200 px de arte se metían **32 px por debajo** de `.header-end` |
| 490 px | seguía recortado (293 px disponibles) |
| 500 px | primer ancho donde entra entero |

Por eso el ensanche y la etiqueta van dentro de `@media (min-width: 601px)`: ~100 px de holgura
sobre el fallo medido. Por debajo, el header recupera la geometría de core **sin reglas de deshacer**
(nada que mantener sincronizado con 86/62 px), y una segunda media query cambia el arte a
`logo-mark.svg` — la figura sola —, porque el lockup registrado en `logoheader` contiene su texto a
~4 px en un hueco de 62×44. El arte estrecho **no** está registrado en theming: es un `background-image`
del tema y nada de provisioning lo conoce.

El único breakpoint de Nextcloud es `$breakpoint-mobile: 1024px` (`variables.scss:100`), una variable
SCSS ya compilada: inalcanzable desde un tema, y demasiado ancha — tiraría el lockup en tablets donde
entra de sobra.

### Lectores de pantalla: lo que se creía y lo que se midió

Esta sección **afirmaba** que la AT oye «INICIO» *y* el `aria-label`, y que no era arreglable desde
CSS. Medido el 2026-07-30 en el árbol de accesibilidad: el nombre accesible del enlace era ya
**«Ir a Dashboard» y nada más**, porque un `aria-label` explícito gana sobre *name-from-content*, así
que la palabra generada nunca entró en el nombre. La duplicación que se temía no existía.

Queda la otra mitad — los lectores que verbalizan contenido generado al navegar — y para eso el
`content` lleva **texto alternativo vacío**: `content: "INICIO" / ""`. Chrome 150 lo parsea
(`CSS.supports('content', '"x" / ""')` = `true`); un navegador que no lo soporte anuncia la palabra,
que es exactamente el comportamiento de antes. Degrada sin romper nada.

## 8. Qué NO toca el tema

Sin editar el core · sin forkear `@nextcloud/vue` · sin CSS por componente · sin SCSS (retirado por
NC) · sin modo oscuro · **sin iconos por app** (escaneadas todas las apps activas el 2026-07-27:
cero iconos multitinta, nada califica).
