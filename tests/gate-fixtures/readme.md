<!--
  - SPDX-FileCopyrightText: 2026 APS Conecta
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Static-gate fixtures

Bytes the static gate (`scripts/test.sh`) reads and never runs. Issue #60's gate
(`env_sh_selfpath_gate`) polices self-location by `dirname` in scripts that source
`scripts/env.sh`: env.sh's first act is `cd` to the repo root, so a dirname-of-self
evaluated on any later line resolves against the wrong directory whenever the script was
started by a relative path.

- `violador.sh` — the injected violation (org L7-2): the `#30` shape and its `BASH_SOURCE`
  spelling. The gate must flag exactly these two rows; if it cannot, the gate is vacuous.
- `legal.sh` — every idiom that must stay green: the sourcing line itself, pre-source
  self-location (the `HERE` idiom, a script's own `cd`), post-source use of an
  already-absolute path, and dirname/basename of things that are not the script.
- `ajeno.sh` — a script that never sources env.sh: not the gate's subject.

These live as tracked files — not as heredocs inside `scripts/test.sh` — because the
fixture bytes themselves would be `test.sh`'s own post-source lines and red the gate on
itself. If a fixture's lines move, the assertions hold: they match the fixture's content,
not its line numbers.
