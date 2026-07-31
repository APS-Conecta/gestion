# Phase 30 — group folders.  OWNER: Epic 3 (only Epic 3 edits this file).
# Provisions the first-cut four-area tree (PRD §4.4) as Group Folders (AD-4 mount model: Transversal =
# one folder; each program/unit/sector = its own folder). Group Folders can't nest, so slash mount points
# (Programas/…, Unidades/…, Sectores/…) give the tree look. Idempotent via ensure_groupfolder
# (groupfolders:create is NOT idempotent by name — always query first). Grants are phase 40-acl.
phase_begin "30-folders" "Hybrid four-area Group Folders tree (Epic 3)"

# Group folders (mount points) — the tree is this clinic's, so it comes from sites/$SITE/site.sh.
for f in "${SITE_FOLDERS[@]}"; do ensure_groupfolder "$f"; done

# Transversal's shared-knowledge subfolders (regular folders inside the one Transversal group folder).
# Per-subfolder ACL refinement (e.g. Registro de redes, Actas) is deferred to the validated matrix.
for sub in "${SITE_SUBFOLDERS[@]}"; do
  ensure_gf_subfolder "Transversal" "$sub"
done

# Surface the organization conventions where staff will see them (FR-14). The text is product; only
# the clinic's name is per-site.
ensure_gf_file "Transversal" "LÉEME — Convenciones.md" \
"# Convenciones de organización — $SITE_NOMBRE_CORTO

Cómo mantener ordenada esta carpeta. Detalle completo: docs/CONVENTIONS.md en el repositorio.

- **Nombre de archivo:** \`AAAA-MM-DD_area_tema_vN.ext\` (fecha ISO, sin acentos en el nombre técnico).
- **Dónde va cada documento:** Transversal = conocimiento compartido; Programas = por programa;
  Unidades = por unidad funcional; Sectores = por sector territorial.
- **Una sola copia viva:** edita el documento en su lugar (Nextcloud Office) en vez de duplicar archivos.
"

phase_end
