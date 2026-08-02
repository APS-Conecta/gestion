# MAPEO.md — la ficha de marca del tema

Lo que hace falta para trabajar sobre `core/css/server.css`: la paleta con sus ratios de contraste,
las decisiones tipográficas y la geometría de la cabecera.

**El mecanismo no está aquí.** Por qué `:root` es inerte, por qué `background_color` decide el color
del texto, qué puede y qué no puede alcanzar una hoja de tema — todo eso vive una sola vez, en
[`docs/THEMING-MODEL.md`](../../docs/THEMING-MODEL.md). La decisión de tener un tema, en
[`ADR-0001`](../../docs/adr/0001-server-theme-for-branding.md). Este fichero enlaza; no los repite.

## 1. Libro mayor de contraste

El oro de marca `#e06f00` mide **3,07:1** sobre blanco → **no cumple AA para texto pequeño**. Uso
permitido: rellenos, iconos, insignias y texto grande (≥24 px, o ≥19 px en negrita). Para texto
pequeño sobre blanco usar el oro oscuro **`#9a4c00`** (≥4,5:1).

| Color | Hex | Ratio | Uso |
|---|---|---|---|
| Violeta primario | `#7f21fe` | 5,57:1 | AA texto/UI ✓ (`primary_color`) |
| Violeta oscuro | `#5315a8` | ~8:1 | Titulares, telón de fondo ✓ (`background_color`) |
| Rosa error | `#ea003e` | 4,33:1 | UI/borde/texto grande — **no** cuerpo de texto |
| Oro | `#e06f00` | 3,07:1 | Rellenos/iconos/texto grande |
| Oro oscuro | `#9a4c00` | ≥4,5:1 | Texto pequeño |
| Tinta | `#101828` | ~16:1 | Texto principal |
| Apagado | `#485363` | ~7:1 | Texto secundario |

Los dos violetas **no son intercambiables**: `background_color` debe seguir siendo el oscuro
(`#5315a8`), porque de él deriva Nextcloud el color del texto sobre el fondo y la inversión de los
iconos de cabecera (regla 5 de THEMING-MODEL).

## 2. Tipografía

- **Familias:** Fraunces (display: `h1`–`h3`, cabecera) · Nunito Sans (todo lo demás).
- **Nunito Sans se entrega por `--font-face`**, la única variable tipográfica documentada, con
  `!important`. **Fraunces va por selectores de elemento**, porque no existe variable documentada
  para una fuente display.
- `@font-face` con **rutas absolutas** `/themes/apsconecta/core/fonts/`. Fuera de Nextcloud dan 404;
  `sistema-diseno.html` las redeclara con rutas relativas.
- **Solo `.woff2`**, sin fallback a `.ttf` (ADR-0001).
- Los `.woff2` servidos **no están subseteados**; los lockups SVG **sí** incrustan un subconjunto.
  Ambas cosas son compatibles con SIL OFL-1.1 — el detalle está en
  [`docs/LICENSING.md`](../../docs/LICENSING.md) §3.2, fuente única en materia de licencias.
- Se conservan `--default-font-size` (15 px) y `--default-line-height` (1.5) de Nextcloud, para no
  descuadrar la densidad de `@nextcloud/vue`.

## 3. Geometría de la cabecera

La ranura de `#nextcloud` reserva **68 px de padding** para la marca, que core posiciona en
absoluto (`inset-inline-start:12px`, con ancho propio de 62); `server.css` la estrecha a 46, así
que termina en 58. 68 y no 52 (#102): a 52 la fila flex empezaba 6 px dentro de la marca. Se sirve `logo-mark.svg` a 34×30 dentro de esos 46. Las tres ranuras — marca,
casa (19 px dentro de 36) y nombre de la clínica (12 px de padding) — miden 36 px de alto y radio
8, para que el resalte de hover caiga igual en cada una. Solo por encima de **601 px**; por debajo
se retiran las dos ranuras generadas (`content: none`) y vuelve la ranura 62×44 de core, con la
misma marca.

Las reglas se acotan a `a#nextcloud`, no a `#nextcloud`: la cabecera de **enlace público** usa ese
mismo id sobre un `<div>` con contenido propio, y sin acotar se le aplicaba el padding de la
cabecera. Lo verifica `scripts/test.sh` sobre las dos plantillas.

## 4. Qué NO toca el tema

Sin modo oscuro (`enforce_theme=light`), sin iconos por app (se midieron: cero iconos multitinta) y
sin regla de lienzo — pintar `body`/`#content` tapaba por completo la imagen de fondo de marca.
