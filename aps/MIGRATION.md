# MIGRATION — moving a clinic, and retiring the old homes

The compose-era manual moved here from gestion (§0–§9; its tool,
`scripts/migrate-to-aio.sh`, moved with the installer — this file is its choreography).
§10 is the move an operator meets next: an existing clinic, installed from a gestion clone,
into the instalador package era. §11 is the maintainer's: freezing and archiving AIO once
instalador carries the fork.

The doctrine is REHEARSAL-FIRST: every step that can be proven before the irreversible one
is proven before it, and the live stack is the rollback until the moment of the teardown.

## 0. Preconditions

- A suite tag published and IMMUTABLE (a new lockstep set ships under a new tag, never by
  re-emitting one — that immutability is also what makes an accidentally-enabled autoupdate
  a no-op).
- The comuna package importable: `provisioning/data/packages.json` + the comuna tool.
- DNS: the clinic's domain record exists.
- Staff know the window; the clinic's staff know the stack is going down once, briefly, at §3.

## 1. The dump, verified twice

    bash scripts/db-dump.sh        # plain SQL — AIO greps the owner line, custom-format never fires

It verifies itself into a scratch postgres. Then the two copies that outlive this host's
rotation (the stash keeps only top-level FILES — a dump that lives nowhere else is not a
backup), and the data dir with the one dotfile that matters (`.ncdata`, NOT `.ocdata` — and
a dotfile: never "filter hidden files" in any later copy step).

## 2. The throwaway restore (do it once even though it is optional)

A throwaway AIO beside the live stack, with the dump and the data dir in place BEFORE first
start — the restore only fires when `PG_VERSION` is absent in the database volume and the
dump is present. The codetree half — `config.php` and `version.php` must be in the
nextcloud volume before the first start too: AIO's entrypoint decides fresh-vs-existing from
`/var/www/html/version.php`; the file ABSENT is the fresh-install branch, which runs
`maintenance:install` INTO the restored database — and the first boot dies. The markers
(`skip.update`, `fingerprint.update`) ride the datadir so the update pass cannot spin
against a store that cannot answer. `migrate-to-aio.sh prepare` does all of this; after
the first boot settles, assert the two survivals (eurooffice under **Enabled** — section-aware:
a plain grep matches a disabled one too; the restored table count), then tear the throwaway
down completely before §3.

## 2½. The tool for any clinic

The §1–§2 mechanics are `migrate-to-aio.sh`; the window and the rollback story remain this
document's:

- `prepare --domain <dominio>` — the reversible half: the verified dump into
  `nextcloud_aio_database_dump`, the datadir (`cp -a`, dotfiles, `.ncdata`) with the two
  markers into `nextcloud_aio_nextcloud_data`, config.php rewritten (dbhost/dbuser/dbname/
  datadirectory/trusted_domains/overwriteprotocol/overwrite.cli.url; the redis password
  dies — AIO's redis is passwordless) and version.php from the suite image, both into
  `nextcloud_aio_nextcloud`. Re-run is safe until the first start; every stage refuses
  loudly — a dump without the owner line AIO greps, an owner equal to `oc_nextcloud`, an
  already-initialized `nextcloud_aio_database` (`PG_VERSION` present: the restore would
  never fire).
- After the first boot settles: `verify --domain <dominio>` — the three survivals
  (eurooffice enabled, the restored table count, the datadir marker), the B-019 leg, and —
  once `aps-conecta provision` has converged the site — the revalidate sweep plus the
  seed's idempotence.

The rehearsal window: run the whole flow against a THROWAWAY first (the same suite tag, a
scratch domain), tear it down, and only then run it for the window.

## 3. The uninstall (the irreversible step)

`make uninstall` on the compose stack — it preserves the site record (move it off this
host), runs the verified dump again, asks for the site slug, tears the volumes down, removes
the generated artifacts, disables the basemap timer, and prints the clean-slate report.
`.env` is LEFT by design: rotate anything that used its secrets, then `rm .env`.

## 4. The AIO reinstall

The mastercontainer run shape is AIO's own recommended run (no `--network` — it creates and
joins `nextcloud-aio` itself; the wizard's interface published on a free host port; with an
external reverse proxy, no port 80 — that host's proxy owns it). The tag IS the channel —
every sibling image resolves its channel from it. NEVER a raw digest. In the wizard, when
you enable the daily backup (do), UNCHECK "Automatically update all containers…" — the box
ships PRE-CHECKED; the suite is a lockstep set, any component moving alone breaks the
pairing. Verify after first boot: the daily-backup flag line reads
`automaticUpdatesAreNotEnabled`. Provisioning converges the suite, then the comuna data
(`aps-conecta datos`).

## 5. The gates

- gestion's local gate green (the compose era) / `aps-conecta revalidate` (the suite era);
- office green — **and open a document from ANOTHER machine**: the one check no automation
  can do for you (B-019);
- the divergence report adds no note — including the territorio comuna keys;
- `occ app:list` shows eurooffice under **Enabled**;
- the daily-backup flag line says `automaticUpdatesAreNotEnabled`;
- `migrate-to-aio.sh verify` asserts the config shape (`DocumentServerUrl` in the public
  form, `overwriteprotocol` https).

## 6. The fresh-machine pass

Default topology, no external reverse proxy, the wizard's own ports. Same suite tag, same
provisioning sequence, same gates — the acceptance pass whose timings mean something. Do it
after the primary pass is green, from the same release artifacts.

## 7. The host residue (the repo never installed these)

- [ ] reverse-proxy routes and tunnels pointing at the old stack's published ports:
      unset or re-pointed
- [ ] stray `.bak`/transcript files that outlived the old stack: rotated, then deleted
      (transcripts hold operator input from the live instance)
- [ ] the preservation copy moved off the host and recorded in the preservation doc
- [ ] `.env` rotated-then-removed (the uninstall's report nags until it is)

## 8. The preservation doc (template)

    Establishment:  <SITE_NOMBRE> (DEIS <SITE_DEIS>, <SITE_COMUNA> CUT <SITE_COMUNA_CUT>)
    Migrated:       <date> — gestion <gestion tag> → AIO <suite tag>
    Data:           dump <path> (sha256 <hash>, <N> tables) · data dir <path>
    Site record:    <SITE>-preserved-<ts>/site.sh — <T> teams, <F> folders, <A> ACL rows
    Accounts:       the four .env secrets rotated on <date>
    Rollback:       until the teardown: the live stack (abort = do nothing). After: the dump
                    + the site record regenerate the clinic through §2's procedure.

## 9. The permanent traps (running index)

- §1: the datadir copy must keep EVERY dotfile — `.ncdata` is the marker;
- §2: the dump must land BEFORE the database container's first start (`PG_VERSION` present
  = the restore never fires); the `skip.update` + `fingerprint.update` markers must ride
  the datadir;
- §2½: the first-boot DS wait disables the connector if the document server is slow — one
  restart re-enables it; `verify` catches it;
- §4: the wizard's daily-backup screen ships the autoupdate box PRE-CHECKED — uncheck it.

## 10. A gestion-clone clinic → the instalador package era

The durable layer of an install is **`/opt/aps-conecta` itself** — `credentials.txt`,
`aio/` (the mastercontainer's state), `certificados/` (the suite TLS and the staff CA),
`estado.txt`, and the site record. The clone was only ever code. The package era unpacks
its code beside it, at `/opt/aps-conecta/instalador`, and touches nothing else.

**When**: your next deliberate update (INSTALLER §10) — no clinic needs to move a running
suite the day instalador publishes.

1. Take your backup as always.
2. Run the new bootstrap for the version you want:

       curl -fsSL https://github.com/APS-Conecta/instalador/releases/download/vX.Y.Z/apsconecta-vX.Y.Z-install.sh | sudo bash

   It verifies the package (the embedded sha256, and the signature when the host already
   carries `signify`), unpacks atomically to `/opt/aps-conecta/instalador`, and refuses to
   touch an existing install of another version.
3. The site record is data, not code: your generated `sites/<su-DEIS>/` tree lives inside
   the old clone. Copy it beside the register in the new home —

       sudo cp -a /opt/aps-conecta/gestion/sites/<su-DEIS> /opt/aps-conecta/instalador/sites/

   — or point `install --sitio` at the old copy once. The register
   (`sites/establecimientos-deis-*.csv`) ships inside the package.
4. `sudo bash /opt/aps-conecta/instalador/host/aps-conecta install` — the same nine steps;
   the running suite converges and `aps-conecta` re-links to the new home.
5. `sudo aps-conecta temporizadores` — the weekly re-provision and the monthly map timer
   re-point at the new home (their units name it).
6. Green (`aps-conecta revalidate`)? The old clone is inert now — nothing reads it — and
   removable: `sudo rm -rf /opt/aps-conecta/gestion`.

**Rollback**: until step 6, the old clone keeps working — nothing about it was mutated.
`sudo bash /opt/aps-conecta/gestion/host/aps-conecta …` is still the CLI it always was, and
re-running its `temporizadores` points the timers back. After step 6 the clone is gone, but
nothing ever depended on it: `/opt/aps-conecta` is the clinic.

**What does NOT change**: the containers, the volumes, the credentials, the certificates,
the domain, the timers' schedules. Old gestion tags and Releases stay intact and auditable;
an install pinned at an old tag keeps verifying against them exactly as it always did.

## 11. The AIO retirement checklist (the maintainer's)

instalador absorbed the fork; AIO freezes, then archives. In order — each line records a
hand-off that has no workflow of its own:

- [x] instalador's Replay schedule enabled, and one SCHEDULED run green — done in the queue
      era; the schedule, its liveness canary and the Replay workflow itself then retired
      with the hard fork (Stage 3, 2026-10: this fork runs no schedules).
- [ ] AIO's Replay schedule DISABLED, the same day instalador's goes live — no
      double-publish window. Record the date beside this line.
- [ ] instalador's first Release cut end-to-end: gates → the 20 images at the tag → the
      signed composite package, all five assets on the Release.
- [ ] N green instalador releases since the absorption (the org picks N; three is the
      floor) — each through the full chain, none repaired by hand.
- [ ] One real gestion-clone clinic walked §10 green (the recorded rehearsal).
- [ ] AIO archived (read-only) — the upstream mirror, the patch queue and the fork
      declaration stay readable forever; the readme gains the archived badge pointing at
      instalador.
- [ ] gestion's frozen install half deleted — or left frozen forever, the org's call: the
      movers under `host/`, `provisioning/`'s executor, and the 16 scripts. When they go,
      gestion's gate and Makefile shed their last install-half references with them.

Channel continuity, once more because it is the whole safety of the move: a published tag's
digests never move. `ghcr.io/aps-conecta/*:<old gestion tag>` sets remain valid channels
forever; instalador's tags are the new ones, never overwrites of the old.
