# INSTALLER — standing up a clinic (APS Conecta AIO)

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
- **One domain** — the host must be reachable at it from the LAN (and the host itself; §7).

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

The bundle is `aps-conecta`: `preflight`, `run-command`, `provision`, `revalidate`,
`respaldo`, `tiles`, `datos` — thin glue; every heavy thing lives where its own gate is.

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
image (D4), so boot-time installs would be noise. If preflight reds on the domain probe, do
§7 before continuing — the wizard will not pass the check either.

## 4. The wizard (:8080)

1. Paste the run command. The wizard comes up branded, in Spanish (es-CL formal).
2. **Capture the initial password on first load** — `GET /setup` shows it once (`id="initial-password"`);
   login is blocked once the apache sibling runs.
3. Log in, set the **domain** (DNS must point here), the **timezone**, and the options —
   **Euro-Office is the default office** (leave it); Talk/Whiteboard/Imaginary stay off unless
   the clinic asked. The app store is hidden (store off, 020); the Collabora/OnlyOffice cards do
   not exist (050). The territorio card reads «pendiente de empaquetado» until that app ships.
4. Start the containers from the wizard and wait for the green set. The daily-backup screen's
   automatic-update box ships **unchecked** (040) — leave it: the suite updates as one set.

## 5. Provision

```bash
aps-conecta provision
```

The banner prints the URL and the access token (the login screen's hint names where it came
from — the console — but the token itself never appears in any page; copy it from the terminal
where you ran this). The browser flow — DEIS cascade (región →
comuna → centro), sectors/programs, the all-on components, the users CSV, review, execute — is
walked step by step in [`GUIA-CLINICA.md`](GUIA-CLINICA.md) §4–6. The two outcomes that matter:

- **Divergencia vacía** — the handoff gate: the instance matches its declaration, users included.
- **`/opt/aps-conecta/credentials.txt`** — the sealed sheet, mode 0600. Hand it out row by row and
  delete it after distribution (the GUIA's ritual, §6).

## 6. Wire the timers

```bash
sudo cp host/aps-conecta.service host/aps-conecta.timer /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now aps-conecta.timer
# with the map installed (§9), also — tiles.sh's own printed wiring, byte-identical:
sudo cp host/aps-conecta-tiles.service host/aps-conecta-tiles.timer /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now aps-conecta-tiles.timer
```

The weekly timer re-runs the provision headlessly (idempotent; a drifted host shows as a FAILED
unit in `systemctl --failed`). The tiles timer re-extracts the basemap monthly (the 4th at 05:00,
spread off borg's nightly window).

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
browsers and the gates actually use.

## 8. The .env the gates ride

The clinic `.env` (in the gestion checkout) is minimal by design — the wizard owns the stack, so
the compose-era keys do not exist under AIO. The keys that matter to the gates:

- `HTTP_PORT=443` — the public apache port; `smoke` and `revalidate` curl it
  (`http://localhost:${HTTP_PORT}/…`). Set it once; the gates read it every run.
- `TILES_PORT` (default 8084) and `TILES_PUBLIC_URL` — §9.
- **The office keys are absent on purpose**: under AIO the wizard's entrypoint owns the
  document-server URLs and the JWT secret on every boot (the reason `14-office.sh`'s AIO arm
  skips them). There is nothing office-shaped to configure on a clinic.

## 9. The map (tiles)

Territorio's basemap is served from the host, outside AIO:

```bash
sudo aps-conecta tiles install --url https://tiles.<dominio>/chile.pmtiles
```

- **Loopback publish, always**: the nginx container binds `127.0.0.1:$TILES_PORT` only. The
  public answer is an **HTTPS terminator** you already have or choose — the map page is HTTPS
  and a plain-HTTP tiles URL is **mixed content the browser blocks regardless of CSP**. That is
  why `TILES_PUBLIC_URL` must name an https address:
  - the clinic's reverse proxy: a `location /chile.pmtiles` proxying to `127.0.0.1:8084`;
  - **caddy**: `tiles.<dominio> { reverse_proxy 127.0.0.1:8084 }`;
  - **tailscale serve**: `tailscale serve --bg https://127.0.0.1:8084`.
- **Where the archive lives**: `/srv/aps-conecta/tiles/chile.pmtiles` — outside borg's backup
  scope **on purpose**: it is a 1.04 GB **regenerable** artifact (the monthly timer rebuilds it
  from Protomaps' published build), and a regenerable gigabyte must not ride every backup.
  `/opt/aps-conecta` — the credentials and the site record — is what `respaldo` wires in.
- **Stale container after an image bump**: the nginx container is digest-pinned; if the digest
  is retired upstream, `tiles install` re-creates the container (idempotent) — re-run it.
- **Attribution**: the basemap is an Open Database License (ODbL) Produced Work built from
  OpenStreetMap data. The map must keep showing **© OpenStreetMap contributors** — territorio's
  own `tile_attribution` default does this; do not remove it.
- Until territorio ships («pendiente de empaquetado»), `aps-conecta datos` answers the pending
  posture and downloads nothing; the basemap is already serving and refreshing on its own.

## 10. Updates

The suite updates **as one lockstep set** — never a component alone. When a new suite tag is
published, and **before it is announced**: run the acceptance harness on a rehearsal VM —
`scripts/final-validation.sh run` — its FINDINGS file is the acceptance record (the release
ritual's owner; the harness IS this runbook, instrumented). When updating a clinic:

```bash
aps-conecta revalidate
```

right after the update lands — smoke, office-smoke and the divergence gate, aggregated; a red
names its failed gate. Two honest notes:

- On image-bump boots an **offline clinic sits at the app-store probe** (upstream behavior:
an unbounded wait on `apps.nextcloud.com` while the store is off — documented upstream behavior,
not patched; the wait ends when the probe times out or the network returns).
- The wizard's update notifications are suppressed (040); the suite's releases are the source.

## 11. Backups

The wizard's own borg backup (daily, from the AIO interface) is the instance backup.
`aps-conecta respaldo` wires `/opt/aps-conecta` into its scope — idempotent, and it prints the
**honest cost every time**: additional directories back up but never restore with the instance.
`/opt/aps-conecta`'s restore is a manual `borg extract` (the recipe: upstream's
[backup docs](https://github.com/nextcloud/all-in-one#pro-tip-backup-archives-access)).

## 12. Troubleshooting

- **The log panel looks unstyled after a suite upgrade**: hard-refresh once. The overlay-log
  iframe pins its stylesheet URL in PHP the fork never touches (zero-PHP); a warm cache serves
  the pre-reskin palette until revalidation.
- **A remote user cannot open a document** while everything looks green: that is B-019's class
  — check `DocumentServerUrl` is the public form and open one from another machine yourself
  (the gate cannot do that leg for you).

## 13. Migrating an existing (compose) clinic

[`MIGRATION.md`](MIGRATION.md) §2½ — the tool for any clinic: `migrate-to-aio.sh prepare` /
`verify`, the rehearsal window (run the whole flow against a throwaway first), and the
rollback story. Do not skip the rehearsal.
