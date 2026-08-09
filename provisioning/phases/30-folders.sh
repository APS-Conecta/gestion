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

# Surface the organization conventions where staff will see them (FR-14). Shipped verbatim from
# docs/CONVENTIONS.md, which is the reviewable source: staff cannot open a private repository, so a
# summary pointing at that path was a dead end (#148). Keep that file staff-readable — no repo paths.
# ponytail: idempotent by existence, so an edited CONVENTIONS.md does not reach an instance that
# already has the file. Deliberate — staff may have annotated it, and overwriting is data loss.
# If it must propagate, diff first and write only when the file is byte-identical to the last ship.
ensure_gf_file "Transversal" "LÉEME — Convenciones.md" "$(cat docs/CONVENTIONS.md)"

phase_end
