# ADR-0011 — org-wide facts live in `gestion`; cross-repo references are absolute URLs

- **Status:** accepted (2026-08-08)
- **Affects:** `docs/adr/0007-proprietary-across-the-org.md`,
  `docs/adr/0010-agpl-across-the-org.md`, `docs/LICENSING.md`, `docs/index.md`, and the `README.md`
  of `epidemiologia`, `territorio` and `aps-conecta-web`; `repo-docs/SKILL.md` and
  `repo-docs/references/conventions.md`

## Context

The organisation's licence decision — one rule for all seven code repositories — lived in
`aps-conecta-web/docs/adr/`, the website's repository. Three repositories then reached for it with a
filesystem-relative path, and the results diverged for a reason that has nothing to do with
documentation:

- `gestion/docs/LICENSING.md` used `../../aps-conecta-web/docs/adr/0010-…` and **resolved**, because
  `gestion` and `aps-conecta-web` are siblings on this machine.
- `epidemiologia/README.md` and `territorio/README.md` used the same idiom and **did not resolve**,
  because both sit two levels deeper, at `gestion/apps/<id>`. The idiom was copied between repos;
  the depth was not.

Depth is machine-local. `repo-docs/config.json` records where the clones live *precisely because
that is not policy* — so any reference whose correctness depends on it is broken by construction, and
only accidentally right in the one case that happens to be a sibling. The `0010` link in
`epidemiologia` had already been updated once, from `0009`, when the ADR was renumbered: someone
chased the number and never the path, because the path had never worked.

Bare numbers fail the same way. `repo-docs/SKILL.md` cited "ADR 0007" and "ADR 0002" with no
repository named, while its own ADRs stop at 0003 — the 0007 it meant belonged to another repository
entirely. Numbers collide across the organisation: `gestion` 0000–0005, `aps-conecta-web` 0001–0010,
`repo-docs` 0001–0003, `epidemiologia` 0001–0013, `territorio` 0001–0013, and `common`,
`analizador-rem` and `.github` have none. An ADR number is unique inside a repository and meaningless
outside one.

`gestion` is already where the organisation's doctrine lives: `AGENTS.md` holds the canonical repo
rules, `CONTRIBUTING.md` owns the documentation doctrine that `repo-docs` explicitly inherits rather
than restates, and `ADR-0000` defines the `AD-1`…`AD-10` decisions cited across every phase script.
`repo-docs/profiles/aps-conecta.json` names it `exemplar`. The org-wide home was not missing; it was
just never used for org-wide ADRs.

## Decision

1. **An org-wide decision lives in `gestion/docs/adr/`.** A decision about one product stays in that
   product's repository. ADR 0007 and ADR 0010 move here and **keep their numbers**.
2. **Any reference crossing a repository boundary is an absolute
   `https://github.com/APS-Conecta/…` URL.** Never a relative path. A relative path may only address
   a file in its own repository.
3. **An ADR cited outside its own repository is named with that repository** — "gestion ADR-0010",
   never a bare "ADR 0010".
4. **Numbers are never reused and never renumbered.** 0007 and 0010 arrived keeping theirs, so
   **0006, 0008 and 0009 stay permanently unused** in this series. `docs/index.md` says so, because
   three missing files otherwise read as three deletions.

## Considered Options

**Leave the ADRs where they were and only ban relative cross-repo links.** The cheapest fix, and it
would have repaired every broken link. Rejected because it treats the form and not the cause: a
reader of `gestion` has no reason to go looking in the website's repository for the organisation's
licence, and the next org-wide decision would land wherever it was first written again.

**Put org-wide ADRs in the public `.github` repository.** It is the literal organisation repository
and where GitHub expects organisation-level material. Rejected: it is the only public repository of
the eight, and `repo-docs` forbids host paths and internal detail there — ADR 0007 names
`/srv/syncthing/apsconecta-web` in its second paragraph. Publishing governance would mean sanitising
it first, and mixing a public and a private governance surface is a boundary that has to be policed
on every commit.

**A new `governance` repository.** Rejected: a ninth repository, with its own licence, health files
and docs gate, to hold two documents.

## Consequences

- Links to the old paths break. Forwarding stubs stay at
  `aps-conecta-web/docs/adr/0007-…` and `0010-…` so anything already pointing there still arrives.
- Cross-repo references stop depending on where anyone cloned anything. They become checkable by a
  machine with network access and no sibling directory — which is what CI is.
- A cost, accepted: an absolute URL pins `main`. A reader on an old tag follows a link and gets
  today's document, where a relative path would have given them the contemporaneous one. Since a
  release is a tag of `gestion` alone and the other repositories are not tagged with it, there was no
  contemporaneous cross-repo path to preserve.
- `docs/LICENSING.md` is no longer reaching outside this repository for its own authority: the ADR it
  cites is now a sibling file.
