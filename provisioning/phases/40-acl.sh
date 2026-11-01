# Phase 40 — ACLs.  OWNER: Epic 3 (only Epic 3 edits this file).
# Applies the first-cut access matrix (PRD §4.4) as base group grants on the phase-30 folders —
# ALLOW-REFINEMENT, NO DENY (AD-4). Read = no perms; read/share = "read share";
# manage = "read write delete share". Grants target GROUP
# IDs only (FR-10). Category granularity ("Dirección/Jefaturas" = cat-jefaturas); per-role refinement is
# deferred to the CESFAM-validated matrix. Idempotent (gf_grant re-applies the same grant).
#
# Manage includes DELETE (owner decision 2026-07-30). "read write" alone is READ|UPDATE|CREATE,
# which makes a folder append-only — a wrong upload can never be removed and files cannot be moved,
# since a move needs delete on the source. Group folders keep their own trash, so it stays recoverable.
#
# THREE LEVELS (#116, #144):
#   Transversal              all-staff      read     staff read the shared area, Jefaturas curate it
#   Unidades/<owned>         cat-jefaturas  read/share
#   Unidades/Dirección       cat-jefaturas  manage   no owning role, so the Jefaturas are it
#   everything else                         manage
# Empty permissions mean read (1); read/share is 17, and manage/share is 31.
# The third field is passed unquoted so each permission word reaches gf_grant separately.
# Narrowing works: gf_grant compares the live bitmask and re-issues when it differs, so a row goes
# 15 -> 1 as well as widening. Verified on the running instance 2026-08-01.
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
