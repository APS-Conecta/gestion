# Phase 40 — ACLs.  OWNER: Epic 3 (only Epic 3 edits this file).
# Applies the first-cut access matrix (PRD §4.4) as base group grants on the phase-30 folders —
# ALLOW-REFINEMENT, NO DENY (AD-4). Read = no perms; Manage = "read write delete". Grants target GROUP
# IDs only (FR-10). Category granularity ("Dirección/Jefaturas" = cat-jefaturas); per-role refinement is
# deferred to the CESFAM-validated matrix. Idempotent (gf_grant re-applies the same grant).
#
# Manage includes DELETE (owner decision 2026-07-30). "read write" alone is READ|UPDATE|CREATE,
# which makes a folder append-only — a wrong upload can never be removed and files cannot be moved,
# since a move needs delete on the source. Group folders keep their own trash, so it stays recoverable.
#
# TEMPORARY — EVERY grant in the site file is "read write delete", including rows that were read-only
# (all-staff on Transversal, cat-jefaturas on the five Unidades). Owner decision 2026-07-30: the
# tree is about to be reorganised, and moving anything needs delete on the source.
#
# COST WHILE IT LASTS: any staff account can delete anything in any Team Folder, including the
# shared protocols in Transversal. This file still records WHO has access to WHAT, but no longer at
# what level — which is what FR-10 exists to express. docs/CONVENTIONS.md describes the INTENDED
# levels, not these.
#
# Restore before real staff use: put the read-only rows back to a bare `gf_grant "Mount" group`
# (bitmask 1) once the tree is settled. One edit, and the seed is idempotent.
phase_begin "40-acl" "First-cut access matrix — allow-refinement ACLs (Epic 3)"

# The matrix is this clinic's — sites/$SITE/site.sh, rows of mount|group|perms. Unquoted "$perms"
# on purpose: gf_grant takes the permission words as separate arguments.
for row in "${SITE_ACL[@]}"; do
  mount="${row%%|*}"; rest="${row#*|}"; group="${rest%%|*}"; perms="${rest#*|}"
  # shellcheck disable=SC2086
  gf_grant "$mount" "$group" $perms
done

# Anything granted on these folders that is NOT declared in the site file is revoked, so deleting a
# row there actually removes the access. Until this existed, gf_grant could only add.
gf_prune

phase_end
