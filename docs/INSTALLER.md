# INSTALLER — standing up a clinic (APS Conecta Gestión AIO)

The runbook for the person standing a clinic up: from a bare Ubuntu/Debian host to a
provisioned establishment with sealed credentials and a backup taken. The Spanish walkthrough
of the same steps is [`GUIA-CLINICA.md`](GUIA-CLINICA.md). One establishment per install (D13);
the suite's version is this repo's release tag (D12).

## 1. The shape of an install

- **One host** — Ubuntu or Debian, x86-64, Docker with API ≥ 1.44 (AIO's own floor).
- **The wizard** — one container (`nextcloud-aio-mastercontainer`) serving `:8080`; it owns the
  other containers as a lockstep set of 20 images under `ghcr.io/aps-conecta/*`.
- **The Provisionador** — this repo's checkout on the host, driving the provisioning phases
  (`provisioning/` 05→60) over `docker exec` against the running instance.
- **One address** — a domain the host is reachable at from the LAN and from itself (§7), or, without
  one, this server's IP (§14).

## 2. Get the host bundle

A clinic installs a **release tag**, never `main` (ADR-0005):

```bash
git clone --branch vX.Y.Z --depth 1 https://github.com/APS-Conecta/gestion.git /opt/aps-conecta/gestion
cd /opt/aps-conecta/gestion
git rev-parse HEAD    # equals the tag's SHA on the Release page — the channel's integrity anchor
sudo ln -s "$PWD/host/aps-conecta" /usr/local/bin/aps-conecta
```

The clone at the tag is the acquisition channel and the tag SHA is its checksum — the same
anchor the image bake records as the channel's provenance. The release manifest on the Release
page also names the tag and (as the tarball fallback) carries `host_bundle.sha256` — the tag
archive's number; verify a tarball-form download against it before extracting.

The bundle is `aps-conecta`: `install`, `preflight`, `run-command`, `provision`, `asistente-aio`,
`temporizadores`, `revalidate`, `respaldo`, `tiles`, `datos` — thin glue; every heavy thing lives
where its own gate is.

## 3. Preflight

```bash
aps-conecta preflight
```

Checks docker (API ≥ 1.44), compose v2, the ports (80/443/8080/8443), DNS, x86-64 — each red
comes with its fix hint. On green it prints the `docker run` command. **Never re-type it** —
it is generated from one source:

```bash
docker run --init --sig-proxy=false --name nextcloud-aio-mastercontainer \
  --restart always \
  --publish 8080:8080 \
  --env APACHE_PORT=443 \
  --env NEXTCLOUD_STARTUP_APPS="" \
  --volume nextcloud_aio_mastercontainer:/mnt/docker-aio-config \
  --volume /var/run/docker.sock:/var/run/docker.sock:ro \
  ghcr.io/aps-conecta/all-in-one:<suite-tag>
```

`NEXTCLOUD_STARTUP_APPS` is deliberately **empty**: the apps and the theme are baked into the
image (D4), so boot-time installs would be noise. By IP (§14) the command carries two more lines. If preflight reds on the domain probe, do
§7 before continuing — the wizard will not pass the check either.

## 4. The wizard (:8080)

1. Paste the run command. The wizard, «APS Conecta Gestión AIO», comes up in Spanish (es-CL formal).
2. The web installer's step 7 fills it: `aps-conecta asistente-aio --preparar` starts the
   mastercontainer, captures the initial password (`GET /setup` shows it once; the installer keeps
   it in `/opt/aps-conecta/aio/master.pw`, 0600, and shows it on step 7), and posts the domain (or this
   server's IP, §14), the timezone, the options (Euro-Office, the suite's only office; Talk and its recording as the
   server's memory and cores allow, port 3478 free; Whiteboard and Imaginary off) and the daily
   backup (§11).
3. Log in to the wizard with that password and press Start, leaving the options as step 7 set them:
   the installer's review lists Talk from step 7's choice. Step 7 follows the containers until
   Nextcloud is installed. The wizard has no app store, no community containers and no other
   office: a request to switch or disable the office is refused. The daily-backup screen's
   automatic-update box ships **unchecked** — leave it: the suite updates as one set.

## 5. Provision

```bash
sudo aps-conecta abrir
```

`aps-conecta provision` is the same step. The console prints **one link** —
`https://<LAN-IP>:<port>/login#acceso=<code>` — and the SHA-256 fingerprint of the installer's own
certificate, which it signs with OpenSSL 3 (Ubuntu 22.04+, Debian 12+; an older OpenSSL stops
`abrir` saying so). Open it from another machine on the LAN:
- **The certificate warning.** The browser warns once; compare the fingerprint with the console's.
- **Sign-in.** The session starts by itself. The code rides the URL fragment, which no request
  carries, and leaves the address bar at once; without it the page asks for the code. The cookie
  is `Secure`, so nothing crosses the LAN in clear.
- **The CA.** It lives in `/opt/aps-conecta/certificados` (made once and kept; by IP, the suite's own
  certificate hangs from it, §14). The leaf is re-signed for the link's address on every start.
- **One installer at a time.** A second `abrir` while one is open is refused, naming the port.

The browser flow — the centre (Región › Comuna › Tipo, or a search), the suite's containers, the
teams and the users CSV (one screen, with the centre's own template), review, execute — is walked
step by step in [`GUIA-CLINICA.md`](GUIA-CLINICA.md) §4–6. The pages follow the registry's steps
6–9 (`aps-conecta pasos`).

When «Revisar y ejecutar» comes back green, the installer closes itself: the port closes and the
link stops working. The console then wires the timers (§6) and prints «Listo». Ctrl+C before that
leaves the instance as it is, and `sudo aps-conecta abrir` reopens with a new link. The two outcomes
that matter:

- **Divergencia vacía** — the handoff gate: the instance matches its declaration, users included.
- **`/opt/aps-conecta/credentials.txt`** — the sealed sheet, mode 0600: one row per person and one per
  cargo account. Hand it out row by row and keep it — the weekly re-provision reads it to create the
  accounts still missing (the GUIA's ritual, §6; B-034).

## 6. Wire the timers

The silent install (`install --sitio --planilla`) and the browser install (at «Listo») install and
enable them themselves. After building the map (§9), and after every update (a changed unit lands
this way):

```bash
sudo aps-conecta temporizadores
```

It copies the four units from the bundle into `/etc/systemd/system`, reloads systemd and enables the
weekly timer — and the monthly one once the map exists; a re-run finds them in place. It first
checks that `/usr/local/bin/aps-conecta` is this bundle's: the units run it under a Condition, and a
missing link would skip them without a word. Both fire on Santiago time (the zone rides
`OnCalendar`, not the host's clock). The weekly timer re-runs the provision headlessly on Sundays at
03:00 (idempotent; a drifted host shows as a FAILED unit in `systemctl --failed`). The tiles timer
re-extracts the basemap monthly (the 4th at 05:00, spread off borg's nightly window).

When an execution finds drift, or does not finish, every member of the `admin` group gets a
notification at their next login (one, replaced each week), and `aps-conecta estado` — no sudo —
prints the last verdict with each item and its fix, in Spanish (`/opt/aps-conecta/estado.txt`,
written by every execution: the installer's and the weekly one).

## 7. DNS: the host must reach its own domain (D10)

The wizard and the gates curl the public domain **from the host itself** — the hairpin leg.
If preflight reds there, one of these fixes it (pick one):

- **NAT reflection**: `ufw route allow proto tcp from 172.18.0.0/16 to any port 443`
  (the recorded upstream workaround), or the router's own hairpin setting.
- **Split-DNS via dnsmasq**: a local A record for the domain pointing at the host's LAN IP —
  LAN clients resolve the clinic locally.
- **Docker's own resolver**: `/etc/docker/daemon.json` with `"dns": ["<host-LAN-IP>"]`, then
  `sudo systemctl restart docker`.

Never `SKIP_DOMAIN_VALIDATION` — it silences the wizard's check without fixing the leg the
browsers and the gates actually use. An install by IP skips the check by design (§14): there is no
domain to check.

## 8. The .env the gates ride

The clinic `.env` (in the gestion checkout) is minimal by design — the wizard owns the stack, so
the compose-era keys do not exist under AIO. The keys that matter to the gates:

- `HTTP_PORT=443` — the public apache port; `smoke` and `revalidate` curl it
  (`http://localhost:${HTTP_PORT}/…`). Set it once; the gates read it every run.
- **The office keys are absent on purpose**: under AIO the wizard's entrypoint owns the public
  document-server URL and the JWT secret on every boot; by IP, `14-office.sh` adds the two internal
  URLs (§14). There is nothing office-shaped to configure on a clinic — and nothing map-shaped
  either: the basemap needs no key at all (§9).

## 9. The map (tiles)

Territorio's basemap is the suite's own same-origin route: apache serves the archive at
`https://<your-host>/tiles/chile.pmtiles`. There is no separate container, no port to publish and
no proxy to configure — provisioning phase 16 writes territorio's `tile_url` from the address the
instance is already reached by (`overwrite.cli.url`), so the map works by domain and by IP the
moment the archive exists.

- **Where the archive lives**: `/srv/aps-conecta/tiles/chile.pmtiles` — outside borg's backup
  scope **on purpose**: it is a 1.04 GB **regenerable** artifact (the monthly timer rebuilds it
  from Protomaps' published build), and a regenerable gigabyte must not ride every backup.
  `/opt/aps-conecta` — the credentials and the site record — is what `respaldo` wires in.
- **The bind is read once, at the wizard's first start**: the mastercontainer is created with
  `APS_TILES_DIR=/srv/aps-conecta/tiles`, and apache mounts that directory read-only at
  `/aps-tiles`. The setting is sticky in the suite's `configuration.json` once seen. A
  mastercontainer created **without** it serves `/tiles/` as a 404 while everything else works —
  `sudo bash host/tiles.sh check` says exactly that. The remedy is to re-create it (a minute,
  nothing is lost): stop the containers in the wizard, `sudo docker rm -f
  nextcloud-aio-mastercontainer` (its volume keeps the configuration), re-create it with
  `sudo aps-conecta asistente-aio --preparar --dominio <dominio>` (by IP: the address of §14),
  and start the containers in the wizard again.
- **Until the first build, `/tiles/` is a 404** — the suite never depends on the archive. Step 4
  of the install builds it; `sudo aps-conecta mapa` re-runs it, and the monthly timer refreshes
  it (`sudo aps-conecta temporizadores` re-checks both timers).
- **Attribution**: the basemap is an Open Database License (ODbL) Produced Work built from
  OpenStreetMap data. The map must keep showing **© OpenStreetMap contributors** — territorio's
  own `tile_attribution` default does this; do not remove it.
- **Territorio's data packages**: `aps-conecta datos` fetches the comuna's packages
  (sha256-verified), stages them and prints the import commands. Before the first provisioning
  installs territorio it downloads nothing.

## 10. Updates

The suite updates **as one lockstep set** — never a component alone. When a new suite tag is
published, and **before it is announced**: install it on a fresh rehearsal box exactly as a clinic
does (§2), then `aps-conecta revalidate` — that rehearsal is the acceptance record. When updating a
clinic:

```bash
aps-conecta revalidate
```

right after the update lands — smoke, office-smoke and the divergence gate, aggregated; a red
names its failed gate. An install from v0.3.0 or earlier runs the suite under upstream's container
names; the suite now names them `aps-conecta-*` and does not migrate them: reinstall it (§12). Two
honest notes:

- On image-bump boots an **offline clinic sits at the app-store probe** (upstream behavior:
an unbounded wait on `apps.nextcloud.com` while the store is off — documented upstream behavior,
not patched; the wait ends when the probe times out or the network returns).
- The wizard's update notifications are suppressed (040); the suite's releases are the source.

## 11. Backups

The wizard's own borg backup is the instance backup. Step 7 sets it daily at 04:00 Santiago time
in `/srv/aps-conecta/respaldos`, with `/opt/aps-conecta` (the credentials and the site record) in its
scope — the same folder on the same disk, so copy it off the server (an external disk, another
machine). `aps-conecta respaldo` adds `/opt/aps-conecta` to an existing backup — idempotent, and it
prints the **honest cost every time**: additional directories back up but never restore with the
instance. `/opt/aps-conecta`'s restore is a manual `borg extract` (the recipe: upstream's
[backup docs](https://github.com/nextcloud/all-in-one#pro-tip-backup-archives-access)).

The wizard runs in UTC, so step 7 posts the UTC hour — 07:00 in summer time, 08:00 in winter —
and the wizard shows that hour. After the next DST change the backup runs at 03:00 or 05:00
Santiago time. To move it, the wizard's backup section takes a new time, in UTC.

## 12. Troubleshooting

- **The log panel looks unstyled after a suite upgrade**: hard-refresh once. The overlay-log
  iframe pins its stylesheet URL in PHP the fork never touches (zero-PHP); a warm cache serves
  the pre-reskin palette until revalidation.
- **A remote user cannot open a document** while everything looks green: that is B-019's class
  — check `DocumentServerUrl` is the public form and open one from another machine yourself
  (the gate cannot do that leg for you).
- **Reinstall from scratch** (a failed install, or a wizard password that was not seen). It deletes
  the instance — the wizard and every container it created, under either generation's names
  (upstream's up to v0.3.0, `aps-conecta-…` since), all carrying the label
  `com.docker.compose.project=nextcloud-aio`, and every `nextcloud_aio_*` volume on the host — and
  everything in it: users, files, settings. The label and the name together keep any other project
  on the host out. Stop the containers in the wizard, then:

  ```bash
  sudo docker stop nextcloud-aio-mastercontainer
  sudo docker ps -a --filter label=com.docker.compose.project=nextcloud-aio --format '{{.Names}}' \
    | grep -E '^(nextcloud-aio|aps-conecta)-' | xargs -r sudo docker rm -f
  sudo docker network rm nextcloud-aio
  sudo docker volume ls --format '{{.Name}}' | grep '^nextcloud_aio_' | xargs -r sudo docker volume rm
  sudo rm -rf /opt/aps-conecta/aio
  [ ! -d /srv/aps-conecta/respaldos ] || sudo mv /srv/aps-conecta/respaldos "/srv/aps-conecta/respaldos.$(date +%F)"
  ```

  The old backups stay in the renamed folder (step 7's; move a folder named by hand the same way): a
  new wizard cannot reuse their repository. The rest
  of `/opt/aps-conecta` (the site record, `credentials.txt`) stays. Then `sudo aps-conecta abrir`:
  step 7 prepares a new wizard.

## 13. Migrating an existing (compose) clinic

[`MIGRATION.md`](MIGRATION.md) §2½ — the tool for any clinic: `migrate-to-aio.sh prepare` /
`verify`, the rehearsal window (run the whole flow against a throwaway first), and the
rollback story. Do not skip the rehearsal.

A backup made by a stock Nextcloud AIO is not restored into the suite: an existing clinic moves only
through this tool.

## 14. Without a domain: this server's IP

A clinic without a domain installs by one of this server's IPv4 addresses, written where the domain
goes: step 7, or `SITE_DOMINIO` in the site file of the silent install. The suite then answers at
`https://<ip>/` with a certificate signed by the installer's own CA, the one that signs its link (§5).

- **The address** is one of this server's own (`ip -4 addr`); any other is refused. The wizard's
  domain check is skipped: there is no DNS to check.
- **The certificate** is signed for the address before the wizard starts, into
  `/opt/aps-conecta/certificados/suite` (apache's, read-only). The weekly run signs it again 30 days
  before it expires and restarts apache. The CA that signs it is never made again: if it goes missing,
  the run stops until `/opt/aps-conecta/certificados` is restored from the daily backup (§11).
- **The run command** carries two more lines, `--env APS_TLS_DIR=/opt/aps-conecta/certificados/suite`
  and `--env NEXTCLOUD_TRUSTED_CACERTS_DIR=/opt/aps-conecta/certificados/ca`; step 7 and the silent
  install sign the certificate before they run it. A suite started for a domain does not switch to an
  address, nor the reverse: it is reinstalled (§12).
- **Nextcloud** trusts the CA (phase 07); **the office** reaches Nextcloud inside the suite's network
  (phase 14 writes the two internal URLs). Nothing to configure.

Every device that opens the suite imports the CA once. Step 7 offers it («Descargar el
certificado») with its SHA-256 fingerprint, and the console prints both at the end of the install;
on the server, the operator's own copy:

```bash
sudo install -m 0644 -o "$USER" /opt/aps-conecta/certificados/ca/aps-conecta-ca.crt .
```

The fingerprint is compared before importing — on Linux and macOS:

```bash
openssl x509 -in aps-conecta-ca.crt -noout -fingerprint -sha256
```

On Windows, the same hex digits without colons:

```
certutil -decode aps-conecta-ca.crt aps-conecta-ca.der
certutil -hashfile aps-conecta-ca.der SHA256
```

- **Windows** (Edge, Chrome, Firefox 120+), in a prompt run as administrator:

  ```
  certutil -addstore -f Root aps-conecta-ca.crt
  ```

- **macOS** (Safari, Chrome, Firefox 120+):

  ```bash
  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain aps-conecta-ca.crt
  ```

- **Ubuntu**: the system store, then Chrome's own (Chrome reads `$HOME/.pki/nssdb` when it exists):

  ```bash
  sudo cp aps-conecta-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates
  sudo apt-get install -y libnss3-tools
  mkdir -p $HOME/.pki/nssdb
  [ -f $HOME/.pki/nssdb/cert9.db ] || certutil -d sql:$HOME/.pki/nssdb -N --empty-password
  certutil -d sql:$HOME/.pki/nssdb -A -t "C,," -n aps-conecta -i aps-conecta-ca.crt
  ```

  Firefox: Settings → Privacy & Security → Certificates → View Certificates → Authorities → Import,
  with «Trust this CA to identify websites».
- **Android**: Settings → Security → Encryption & credentials → Install a certificate → CA
  certificate (the names vary by maker; a screen lock is required). The Nextcloud app trusts it.
