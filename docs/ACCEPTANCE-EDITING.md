# Aceptación — Edición colaborativa en vivo (Épica 4)

> **Estado de este runbook:** los pasos de este documento **aún no se han ejecutado en un navegador**
> por una persona. Describen el procedimiento de aceptación a seguir; cada paso indica su resultado
> esperado y qué hacer si falla. Lo que **sí** está verificado por máquina se marca abajo.

Esta guía valida que el personal puede **abrir, crear y co-editar** documentos de oficina en el navegador
contra el backend de oficina activo (Collabora **o** Euro-Office). El backend se elige antes de empezar y
**solo uno está activo a la vez** (AD-11).

## Qué está verificado por máquina (no requiere navegador)

Estas partes de la Épica 4 las comprueba el gate y **pasan en verde**; no hace falta repetirlas a mano:

- **`make office-smoke`** — el backend activo sirve el editor y responde en la ruta WOPI (host + servidor).
- **`make office-formats`** — el backend activo declara los **6 formatos editables** (odt/docx, ods/xlsx,
  odp/pptx) leídos de su propio `/hosting/discovery`, y es una compilación **OSS sin licencia de pago**
  (Historia 4.3, segundo criterio: *el stack es OSS y self-hosted, sin licencia de pago*).

## Qué requiere una persona con navegador (este runbook)

El **renderizado en el navegador**, la **convergencia en vivo** entre editores, la **presencia/cursores**
y la **fidelidad al abrir/guardar** no las puede comprobar ningún script headless. Eso es lo que valida
esta guía.

---

## Requisitos previos

1. Levantar el stack. **Dónde:** host, raíz del repo.
   ```bash
   make up
   ```
   **Esperado:** los contenedores `nextcloud`, `db`, `redis` quedan *healthy*.
   **Si falla:** revisar `docker compose ps` y `make smoke`.

2. Activar un backend de oficina (elegir **uno**). **Dónde:** host.
   ```bash
   make office-collabora     # Collabora CODE
   # — o —
   make office-eurooffice    # Euro-Office (≈8 GB RAM; verificar antes con `free -h`)
   ```
   **Esperado:** termina con `PASS: … smoke …`.
   **Si falla:** ver la sección *Office* del `README.md` y los logs `docker compose logs collabora`
   (o `eurooffice`).

3. Confirmar formatos + OSS por máquina antes de la prueba manual. **Dónde:** host.
   ```bash
   make office-formats
   ```
   **Esperado:** `PASS: … 6/6 formats editable + OSS build, no paid licence`.
   **Si falla:** no continuar — el backend no está declarando algún formato; revisar el backend activo.

4. Iniciar sesión. **Dónde:** navegador, en `http://localhost:<HTTP_PORT>` (ver `HTTP_PORT` en `.env`).
   Usar `admin`, o un usuario de fixtures tras `make seed` (p. ej. `dev.medico`).
   **Esperado:** carga la interfaz de Nextcloud (tema por defecto; el branding no se aplica en v1) en es-CL.

---

## Historia 4.1 — Edición de oficina en el navegador

5. Abrir un documento existente. **Dónde:** navegador → app **Archivos** → una carpeta de grupo (p. ej.
   *Transversal*) → clic en el `.md`/documento de ejemplo, o subir un `.odt` de prueba y abrirlo.
   **Esperado:** el documento abre **dentro del editor del backend activo** en el navegador (no se descarga).
   **Si falla:** confirmar `make office-smoke` en verde; revisar `public_wopi_url`
   (`occ config:app:get richdocuments public_wopi_url` debe apuntar a `https://localhost:<OFFICE_PORT>`).

6. Crear un documento nuevo de cada tipo. **Dónde:** navegador → **Archivos** → botón **+ Nuevo** →
   *Nuevo documento* / *Nueva hoja de cálculo* / *Nueva presentación*.
   **Esperado:** cada uno abre en el editor; se puede escribir texto, una celda y una diapositiva, y el
   cambio persiste al recargar la página.
   **Si falla:** anotar qué tipo falló y el mensaje del editor; adjuntar a la evidencia de aceptación.

## Historia 4.2 — Co-edición concurrente

7. Abrir el **mismo** documento en dos sesiones. **Dónde:** navegador. Sesión A = usuario 1; sesión B =
   otro usuario (ventana de incógnito o segundo navegador) con el documento **compartido** entre ambos.
   **Esperado:** ambas sesiones muestran el documento abierto simultáneamente.

8. Editar a la vez desde A y B. **Dónde:** navegador, ambas ventanas.
   **Esperado:** los cambios de cada quien aparecen en la otra ventana **en segundos, sin sobrescribirse**
   (convergencia, sin *lost update*).
   **Si falla:** documentar la secuencia exacta que causó pérdida de cambios (es un fallo del criterio 4.2).

9. Verificar presencia/cursores. **Dónde:** navegador, ambas ventanas.
   **Esperado:** cada editor ve el **cursor/avatar** del otro y quién está editando.
   **Si falla:** anotar si falta presencia pero sí converge (parcial), o ninguna de las dos.

## Historia 4.3 — Soporte de formatos OSS (fidelidad, mitad humana)

> El *conjunto* de formatos editables y la ausencia de licencia de pago ya están verificados por
> `make office-formats`. Este paso valida solo la **fidelidad de apertura/guardado** en el navegador.

10. Para **cada** formato — `odt`, `docx`, `ods`, `xlsx`, `odp`, `pptx` — subir un archivo de ejemplo,
    abrirlo, hacer una edición pequeña y guardar. **Dónde:** navegador → **Archivos**.
    **Esperado:** cada archivo **abre y guarda** en el navegador conservando su contenido; al descargarlo y
    reabrirlo, la edición está presente y el formato se mantiene.
    **Si falla:** registrar el formato y el síntoma (no abre / abre pero no guarda / pierde formato).

---

## Registro de la ejecución

Al correr esta aceptación por primera vez en un navegador, anotar aquí la fecha, el backend probado
(Collabora / Euro-Office) y el resultado por historia (4.1 / 4.2 / 4.3), para que este runbook deje de
"abrir admitiendo que no se ha ejecutado" y pase a ser evidencia.

| Fecha | Backend | 4.1 | 4.2 | 4.3 | Notas |
|-------|---------|-----|-----|-----|-------|
| _pendiente_ | | | | | |
