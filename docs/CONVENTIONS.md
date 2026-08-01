# Convenciones de organización — Document Home (APS Conecta Gestión)

Reglas mínimas para que el Document Home siga ordenado a medida que crece (FR-14). En v1 se **siguen a
mano** — no hay auto-clasificación ni IA (eso es capa de roadmap). También se surfacean dentro de la carpeta
`Transversal` (`LÉEME — Convenciones.md`).

## Dónde va cada documento (áreas)

El árbol tiene cuatro áreas, provisionadas como Group Folders (ver `docs/ARCHITECTURE.md` y la matriz de
acceso en el PRD §4.4):

- **Transversal** — conocimiento compartido de todo el personal (Protocolos, Flujogramas, Documentación,
  Registro de redes, Actas de reuniones). Pensada como lectura para todo el personal y gestión por
  Jefaturas.
- **Programas/«programa»** — una carpeta por programa, gestionada por su Jefatura y su equipo.
- **Unidades/«unidad»** — carpetas funcionales (SOME, Farmacia, Dental, OIRS, Estadística-REM, Dirección),
  gestionadas por el rol dueño.
- **Sectores/«sector»** — espacios de equipo por sector territorial del CESFAM (nombres propios de cada CESFAM).

Si dudas dónde archivar algo: si sirve a todo el personal → **Transversal**; si es de un programa/unidad/sector
específico → su carpeta.

> **Permisos.** Los niveles descritos arriba son los que el servidor aplica: en **Transversal** todo el
> personal lee y las Jefaturas gestionan; en cada **Unidad** gestiona el rol dueño y las Jefaturas leen;
> en **Programas** y **Sectores** gestionan el equipo y las Jefaturas. `Unidades/Dirección` no tiene rol
> dueño, así que ahí las Jefaturas gestionan.
>
> Entre el 2026-07-30 y el 2026-08-01 todo el personal pudo editar y eliminar en todas las carpetas
> — una decisión temporal para poder reorganizar el árbol, ya revertida. Cada Team Folder conserva su
> propia papelera, así que un borrado siempre se puede recuperar. La matriz real vive en
> `sites/<slug>/site.sh`, aplicada por
> [`provisioning/phases/40-acl.sh`](../provisioning/phases/40-acl.sh).

## Nombre de archivos

- Patrón: **`AAAA-MM-DD_area_tema_vN.ext`** — fecha ISO primero (ordena solo), `area`/`tema` en minúsculas y
  **sin acentos** en el nombre técnico, versión `vN` solo si hace falta un hito.
  Ej.: `2026-07-19_protocolos_triage-urgencias_v2.docx`.
- Sin espacios raros ni caracteres especiales; los títulos “bonitos” en español van en el contenido, no en el
  nombre del archivo.

## Una sola copia viva (versionado)

El problema que resolvemos es *“no hay una versión confiable”*. Por eso:

- **Edita el documento en su lugar** con Nextcloud Office (edición colaborativa en vivo) en vez de descargar,
  editar y volver a subir copias.
- **No dupliques** archivos (`_final`, `_final2`, `_ESTE_SI`). Si necesitas conservar un hito, usa el
  historial de versiones de Nextcloud o un sufijo `vN` explícito y borra los borradores.
- La copia viva vive en la carpeta del área que le corresponde; los enlaces se comparten, no los archivos.

## Alcance (v1)

- Cumplimiento **humano** — sin enforcement automático (NON-GOAL de v1; la auto-organización por IA es roadmap).
- La matriz de acceso y la lista de programas/sectores son un **primer corte** parametrizable por CESFAM; la
  matriz validada final llega después.
