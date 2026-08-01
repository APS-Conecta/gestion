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
# TWO LEVELS AGAIN (#116). Between 2026-07-30 and 2026-08-01 EVERY grant was "read write delete",
# including the six that were read-only — a deliberate widening so the tree could be reorganised,
# since moving a file needs delete on the SOURCE. That work is done and the rows are back:
#
#   Transversal              all-staff      read     staff read the shared area, Jefaturas curate it
#   Unidades/<owned>         cat-jefaturas  read     a Jefatura reads a unit the owning role manages
#   Unidades/Dirección       cat-jefaturas  manage   no owning role, so the Jefaturas are it
#   everything else                         manage
#
# Read-only is spelled as an EMPTY third field in the site file, which reaches gf_grant as no
# permission words at all — the bare form, bitmask 1. That is why the third field is passed
# unquoted below, and why the site file's own comment says "three fields ALWAYS".
#
# Narrowing works: gf_grant compares the live bitmask to the wanted one and re-issues when they
# differ, so this downgrades 15 -> 1 on an instance that already ran the wide version. Verified on
# the running instance 2026-08-01, not assumed — the alternative reading, that a grant helper only
# ever adds, would have made the fix cosmetic.
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
