# Migrating the pilot to the AIO stack

The doctrine is REHEARSAL-FIRST: every step that can be proven before the irreversible one is
proven before it, and the live stack is the rollback until the moment of `down -v`. Nothing in
this document deletes anything until §3, and §3 refuses to run without a dump that has already
been restored once somewhere else.

The checkup is BOTH passes (locked): this VPS with the external reverse proxy, and one fresh VM
in the default topology — the FRD's acceptance shape. The VPS pass is the noisy-timing pass
(ollama shares its RAM); the fresh-VM pass is the clean timing run.

## 0. Preconditions

- v0.2.0 merged and tagged; `ghcr.io/aps-conecta/all-in-one:v0.2.0` published. The suite tag is
  IMMUTABLE once published — a new lockstep set ships under a new tag, never by re-emitting this
  one (that immutability is also what makes an accidentally-enabled autoupdate a no-op).
- The comuna package is importable: `provisioning/data/packages.json` + `scripts/comuna-package.sh`.
- DNS: the clinic's `$NC_DOMAIN` record exists (it is NXDOMAIN today — the pilot is tailnet-only).
- Staff know the window; the clinic's staff know the stack is going down once, briefly, at §3.

## 1. The dump, verified twice

```bash
bash scripts/db-dump.sh        # plain SQL — AIO greps the owner line, custom-format never fires
```

It verifies itself into a scratch postgres:18. Then the two copies that outlive this host's
rotation:

```bash
cp database-dump.sql /srv/backups/apsconecta/apsconecta-$(date +%F)-database-dump.sql
restic backup /srv/backups/apsconecta/
```

`/srv/backups/apsconecta/` keeps only top-level FILES — the rotation deletes directories — and a
dump that lives nowhere else is not a backup.

The data dir (2.7 MB) — the DATA dir, not the codetree volume that contains it — with the one
dotfile that matters:

```bash
mkdir -p preserved-data
docker run --rm -v apsconecta-gestion_nextcloud_data:/src:ro -v "$PWD/preserved-data":/dst alpine \
  cp -a /src/data/. /dst/          # the volume is /var/www/html; the data dir is data/ inside it
ls -a preserved-data/ | grep -q '^.ncdata$'   # .ncdata, NOT .ocdata — and a dotfile: never
                                               # "filter hidden files" in any later copy step
```

## 2. The throwaway restore (optional, and do it once even though it is optional)

A throwaway AIO on this VPS, beside the live stack, with the dump and the data dir in place
BEFORE first start — the restore only fires when `PG_VERSION` is absent in the database volume
and the dump is present, so the dump must land in the `nextcloud_aio_database_dump` volume
before the database container's first start.

The codetree half — `config.php` and `version.php` must be in the nextcloud volume before the
first start too. AIO's entrypoint decides fresh-vs-existing from `/var/www/html/version.php`
(entrypoint.sh:131-140): the file ABSENT is the Fresh-Install branch (:343-347), which runs
`maintenance:install` INTO the restored database — and the first boot dies `install.failed`. The
hand-built volumes must replicate both files, copied from the live stack's codetree volume
(the same `apsconecta-gestion_nextcloud_data` volume the data-dir copy above reads — the volume
is the codetree, `data/` lives inside it):

```bash
mkdir -p preserved-codetree
docker run --rm -v apsconecta-gestion_nextcloud_data:/src:ro -v "$PWD/preserved-codetree":/dst alpine \
  cp -a /src/config /src/version.php /dst/
```

— `config/` keeps its directory (the target wants `config/config.php` beside the `version.php`
at the volume root); both halves land in the target's nextcloud volume before its first start.

The markers, or the entrypoint's update pass can spin against a store that cannot answer (the
store is off in this suite — patch 020): `skip.update` and `fingerprint.update` in the data dir
are the supported escape — AIO's own backuprestore writes exactly these.

The wizard publishes on an alternate port (8080 is open-webui on this host; 8443 is free).

After first boot, assert the two survivals:

```bash
docker exec nextcloud-aio-nextcloud php occ app:list \
  | awk '/^Enabled/{e=1} /^Disabled/{e=0} e && /eurooffice/'   # EMPTY OUTPUT = RED — the JWT
     # rewrite hazard (entrypoint.sh:885-908) silently disables apps that came from outside AIO
     # unless the bake ordered it; this assert is the check. app:list prints BOTH an Enabled and
     # a Disabled section, so a plain grep matches a disabled eurooffice too — the section-aware
     # read is what can go red on the exact hazard.
docker exec nextcloud-aio-database psql -U oc_nextcloud -d nextcloud_database -Atc \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'"   # 185-ish
```

Then tear the throwaway down completely (its volumes too) before §3 — same VPS, one stack.

## 3. The uninstall (the irreversible step)

```bash
make uninstall
```

It preserves the site record (`<SITE>-preserved-<ts>/` — move it off this host), runs the
verified dump again, asks for the site slug, `down -v`s, removes the generated artifacts,
disables the basemap timer, and prints the clean-slate report. `.env` is LEFT by design: rotate
anything that used its secrets, then `rm .env`.

## 4. The AIO reinstall — external-RP topology (this VPS)

```bash
docker run -d --name nextcloud-aio-mastercontainer --restart always \
  -v nextcloud_aio_mastercontainer:/mnt/docker-aio-config \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -p 8443:8080 \
  ghcr.io/aps-conecta/all-in-one:v0.2.0
```

The shape is AIO's own recommended run, adapted for this host: no `--network` (the
mastercontainer creates and joins `nextcloud-aio` itself), no port 80 (the host Caddy owns it —
this is the external-reverse-proxy mode of AIO's reverse-proxy.md), and the wizard's interface
published on host 8443 → container 8080, because host 8080 is open-webui on this VPS.

The tag IS the channel — every sibling image resolves `%AIO_CHANNEL%` from it (19 images, zero
fork logic). NEVER a raw digest: `image@sha256:…` parses as exactly one colon and the digest hex
is silently accepted as the channel, propagating bogus `<hex>` tags to every sibling.

In the wizard, when you enable the daily backup (do), UNCHECK "Automatically update all
containers, the mastercontainer and on saturdays your Nextcloud apps" — the box ships
PRE-CHECKED. The suite is a lockstep set; any component moving alone breaks the pairing. Verify
after first boot:

```bash
docker exec nextcloud-aio-mastercontainer sed -n '2p' /mnt/docker-aio-config/data/daily_backup_time
# must print: automaticUpdatesAreNotEnabled
```

The host Caddy stays the reverse proxy on 80/443 (jomy.cl and apsconecta.cl routes untouched);
tailscale serve re-points 10001/10008/10009 at the new stack's published ports.

Provisioning converges the suite (the AIO-baked equivalents of phases 05→60), then the comuna
package — BEFORE the first monthly basemap run (`*-*-04`): the REF anchor queries the `deis:`
row, and without the import the timer fails loudly (by design — the serving archive survives):

```bash
scripts/comuna-package.sh 13110     # prints the exact territorio:import commands; run them
```

## 5. The gates (the same-VPS half of the checkup)

- `make test` (or the AIO equivalent smoke set) green
- `scripts/office-smoke.sh` green — timings noisy on this VPS (ollama); the fresh-VM pass is the
  clean timing run
- `make divergence` adds no note — INCLUDING the territorio comuna keys
- `scripts/refresh-basemap.sh` green with the derived anchor (the establishment's own DEIS point)
- `occ app:list` shows eurooffice under **Enabled** (the §2 section-aware assert — under "Disabled:" is the JWT rewrite having won: red); the DS reports 9.3.4 (office-smoke asserts it)
- the daily-backup flag line says `automaticUpdatesAreNotEnabled`

## 6. The fresh-VM pass (the other half)

Default topology, no external reverse proxy, the wizard's own ports. Same suite tag, same
provisioning sequence, same gates — this is the FRD's acceptance shape and the pass whose
timings mean something. Do it after the VPS pass is green, from the same release artifacts.

## 7. The pilot-host residue (the repo never installed these)

- [ ] tailscale serve: unsets or re-points for 10001/10008/10009
- [ ] `/root/backups` `.bak` files: rotated (what they back up is gone), then deleted
- [ ] transcript JSONLs (the 2026-09-18 session files): DELETED — they hold operator input from
      the live instance, including things typed at prompts
- [ ] the preservation copy moved off this host and recorded in the preservation doc
- [ ] `.env` rotated-then-removed (the uninstall's report nags until it is)

## 8. The preservation doc (template)

```
Establishment:  <SITE_NOMBRE> (DEIS <SITE_DEIS>, <SITE_COMUNA> CUT <SITE_COMUNA_CUT>)
Migrated:       <date> — gestion <gestion tag> → AIO <suite tag> (external-RP, this VPS)
Data:           dump <path> (sha256 <hash>, <N> tables) · data dir <path> · restic snapshot <id>
Site record:    <SITE>-preserved-<ts>/site.sh — <T> teams, <F> folders, <A> ACL rows
Accounts:       the four .env secrets rotated on <date>; standing accounts per site.sh jefaturas
Rollback:       until down -v: the live stack (abort = do nothing). After: the dump + the site
                record regenerate the clinic through either stack (gestion make install, or AIO
                with the dump-in-volume + markers procedure of §2).
```

## Rollback

Before §3: aborting costs nothing — the live stack never noticed. After §3: the verified dump
plus the preserved site record are the clinic; §2's procedure (adapted to the real install, not
a throwaway) is the restore path. This is why §1 verifies the dump twice and §2 once more.
