# INSTALLER — standing up a clinic (APS Conecta)

The runbook for the person standing a clinic up: from a bare Ubuntu/Debian host to a
provisioned establishment with sealed credentials and a backup taken. The Spanish walkthrough
of the same steps is [`GUIA-CLINICA.md`](GUIA-CLINICA.md). One establishment per install (D13);
the suite's version is a signed release package (D12).

## 1. The shape of an install

- **One host** — Ubuntu or Debian, x86-64, Docker with API ≥ 1.44 (AIO's own floor).
- **The wizard** — one container (`nextcloud-aio-mastercontainer`) serving `:8080`; it owns the
  other containers as a lockstep set of 18 images under `ghcr.io/aps-conecta/*`.
- **The Provisionador** — the unpacked package at `/opt/aps-conecta/instalador`, driving the
  provisioning phases (`provisioning/` 05→60) over `docker exec` against the running instance.
- **One address** — a domain the host is reachable at from the LAN and from itself (§7), or, without
  one, this server's IP (§13).

## 2. Install the suite

A clinic installs a **signed release package**, never `main` (ADR-0005):

    curl -fsSL https://github.com/APS-Conecta/gestion/releases/latest/download/apsconecta-install.sh | sudo bash

The URL is stable — it always resolves to the newest published Release — and the version pin
travels inside the asset itself: the script carries the tag it installs and the package's
sha256, so a Release cut after this change serves itself with no URL editing. (For a
tag-pinned install or an audit, the same asset ships under its versioned name,
`apsconecta-vX.Y.Z-install.sh`; aps/RELEASING.md §6 owns that ceremony.)

On an institutional proxy network, enter its URL privately and preserve only its variables
through sudo for the initial download:

```bash
read -r -s -p 'Dirección del proxy: ' HTTPS_PROXY; echo
export HTTPS_PROXY HTTP_PROXY="$HTTPS_PROXY" https_proxy="$HTTPS_PROXY" http_proxy="$HTTPS_PROXY"
curl -fsSL https://github.com/APS-Conecta/gestion/releases/latest/download/apsconecta-install.sh \
  | sudo --preserve-env=HTTPS_PROXY,HTTP_PROXY,NO_PROXY,https_proxy,http_proxy,no_proxy bash
```

Use an HTTP(S) endpoint reachable from both the host and containers. Encode special
characters in Basic credentials. The verified bootstrap saves the profile privately in
`/opt/aps-conecta/proxy.env`; subsequent commands load it automatically. Preparation applies
Docker's systemd drop-in and restarts Docker when its configuration needs application.
Localhost, the suite address, service names and the inspected network bypass the proxy.
Keep the profile in the encrypted backup of `/opt/aps-conecta`.

The one-liner's anchor is the stable `releases/latest` URL plus TLS, and the tag pin rides
inside the delivered bytes: the installer asset itself embeds the package's sha256 and the
project's public key. The download is verified **before
anything unpacks** (a host that already carries `signify` verifies the signature too — the
install refuses on a bad one), the unpack is atomic, and the suite lands at
`/opt/aps-conecta/instalador` with the package kept — tarball, `SHA256SUMS`, `SHA256SUMS.minisig`
— at `/opt/aps-conecta/paquete/`, so `aps-conecta preflight` re-verifies the whole chain offline
from the next run on. Continue with:

    sudo bash /opt/aps-conecta/instalador/host/aps-conecta install

which links `aps-conecta` into `/usr/local/bin` and walks the steps below. The bundle is
`aps-conecta`: `install`, `preflight`, `run-command`, `provision`, `asistente-aio`,
`temporizadores`, `revalidate`, `actualizar`, `datos`, `red` — thin glue; every heavy
thing lives where its own gate is.

- **Verifying by hand** — an auditor, or anyone who wants to see it themselves — needs only the
  Release page and `signify-openbsd` (`sudo apt-get install signify-openbsd`): download
  `apsconecta-vX.Y.Z.tar.gz`, `SHA256SUMS`, `SHA256SUMS.minisig` and the committed
  [`installer.pub`](https://github.com/APS-Conecta/gestion/blob/main/installer.pub), then

  ```bash
  sudo apt-get install signify-openbsd
  sudo ln -sf /usr/bin/signify-openbsd /usr/local/bin/signify
  signify -V -p installer.pub -m SHA256SUMS -x SHA256SUMS.minisig && sha256sum -c SHA256SUMS
  ```

  The bootstrap, host checks and app resolver prefer `signify-openbsd`; the generic name is
  retained for compatible installations.

  The signature covers `SHA256SUMS`, which names the tag's tarball: a signature that verifies
  is a signature for that tag's package. The key story — keygen, secrets, rotation — is
  [`RELEASING.md`](RELEASING.md).
- **What the installer refuses**: the repository copy of `install.sh` (its embedded sha ships
  empty on purpose — only the Release asset runs), bytes that do not match the embedded sha, a
  `SHA256SUMS` that disagrees with it, and an existing `/opt/aps-conecta/instalador` of a
  different version — an update is a deliberate act (§10).
- **A clinic installed from the old gestion clones** keeps working untouched; this installer
  serves clean installs only — the migration path was removed with the v0.5.0 doctrine and none
  exists.

## 3. Preflight

```bash
aps-conecta preflight
```

Checks docker (API ≥ 1.44), the ports (80/443/8080/8443), DNS, x86-64 — each red
comes with its fix hint. It also re-verifies the kept release package when one is there — the
sum and the signature, offline, against the suite's own `installer.pub`. On green it prints the `docker run` command. **Never re-type it** —
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

`NEXTCLOUD_STARTUP_APPS` is deliberately **empty**: no image carries an app (D4, ADR-0018) — the
theme is the one suite thing aboard, the apps arrive from their own signed releases and the
scoped store — so boot-time installs would be noise. By IP (§13) the command carries two more
lines. If preflight reds on the domain probe, do
§7 before continuing — the wizard will not pass the check either.

## 4. The wizard (:8080)

1. Ejecute el comando de arranque. El asistente «APS Conecta Gestión AIO» se presenta en español de Chile.
2. El paso 6 invoca `aps-conecta asistente-aio --preparar`, inicia el contenedor maestro y guarda
   la contraseña inicial en `/opt/aps-conecta/aio/master.pw`, con permisos 0600. Configura el
   dominio o la IP (§13), la zona horaria, los servicios incluidos, las aplicaciones opcionales
   elegidas y el respaldo diario (§11). Farmacia, Estadística y Tótem se instalan desde sus
   publicaciones firmadas cuando se seleccionan. La grabación permanece desactivada.
3. Ingrese con esa contraseña y pulse «Iniciar». El paso 6 sigue el arranque hasta confirmar la
   instalación de Nextcloud. Los respaldos programados reinician las versiones actuales de la suite.

El primer recorrido completado del asistente define la configuración inicial. Con la suite
en marcha, las invocaciones posteriores conservan esos valores y el seed reconcilia el
aprovisionamiento. Antes del inicio o con la suite detenida, el controlador puede aplicar
la configuración; `--preparar` completa la preparación previa al arranque.

- El banco de pruebas `scripts/aio-testbed.sh up` completa ese primer recorrido. Una instalación
  silenciosa posterior utiliza la configuración que dejó el banco.
- Con la suite en marcha, repetir `install --respaldo R` conserva la ubicación de respaldo
  configurada inicialmente. Ajuste esa ubicación desde la sección de respaldos del asistente.

Para omitir la validación del dominio en la configuración inicial de una instalación silenciosa,
añada `--sin-validar-dominio`. El comando comparte el controlador del asistente:

```bash
sudo aps-conecta install --sitio site.sh --planilla usuarios.csv \
  --respaldo /srv/aps-conecta/respaldos --sin-validar-dominio
```

La consola confirma el resultado final del asistente antes de informar que inició la suite.
La espera continúa mientras avance la descarga o aparezcan estados nuevos de los contenedores;
se detiene tras 20 minutos sin avances. Una sesión vencida se recupera una vez. Si se interrumpe
la conexión, revise el asistente antes de iniciar otra vez: la operación puede continuar.

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
  certificate hangs from it, §13). The leaf is re-signed for the link's address on every start.
- **One installer at a time.** A second `abrir` while one is open is refused, naming the port.

The browser flow — the centre (Región › Comuna › Tipo, or a search, and the map that opens on the
establishment's official register point: confirm it or move it — a click, a drag or the arrow
keys — and the chosen point rides «Confirmar centro» into the site file's `SITE_LON`/`SITE_LAT`),
the suite's containers, the teams and the users CSV (one screen, with the centre's own template),
review, execute — is walked step by step in [`GUIA-CLINICA.md`](GUIA-CLINICA.md) §4–6. The pages
follow the registry's steps 5–8 (`aps-conecta pasos`).

Command-line site and roster imports resolve relative paths against the calling directory;
an unreadable input reports its absolute path. A reserved-account collision lists all reserved
uids for the establishment once, including its sector and role-derived positions.

When «Revisar y ejecutar» comes back green, the installer closes itself: the port closes and the
link stops working. The console then wires the timers (§6) and prints «Listo». Ctrl+C before that
leaves the instance as it is, and `sudo aps-conecta abrir` reopens with a new link. The two outcomes
that matter:

- **Divergencia vacía** — the handoff gate: the instance matches its declaration, users included.
- **`/opt/aps-conecta/credentials.txt`** — the sealed sheet, mode 0600: one row per person and one per
  cargo account. Hand it out row by row and keep it — the weekly re-provision reads it to create the
  accounts still missing (the GUIA's ritual, §6; B-034).

### Antivirus uploads

Phase 12 installs the store antivirus app; phase 14 and boot share its configuration.
`NEXTCLOUD_UPLOAD_LIMIT` supplies one whole-file scan budget (default `1G`, binary units),
capped at 2,147,483,645 bytes for ClamAV. Chunked uploads retain that complete-file limit.
ClamAV reports exceeded analysis limits and encrypted archives as rejections. An unavailable
scanner keeps the app enabled and refuses uploads; restore the scanner and retry the upload.
The Spanish rejection directs staff to review the file or contact administration.

## 6. Wire the timers

The silent install (`install --sitio --planilla`) and the browser install (at «Listo») install and
enable them themselves. After building the map (§9), and after every update (a changed unit lands
this way):

```bash
sudo aps-conecta temporizadores
```

It copies the two units from the bundle into `/etc/systemd/system`, reloads systemd and enables the
weekly timer; a re-run finds them in place. It first
checks that `/usr/local/bin/aps-conecta` is this bundle's: the units run it under a Condition, and a
missing link would skip them without a word. It fires on Santiago time (the zone rides
`OnCalendar`, not the host's clock): the weekly timer re-runs the provision headlessly on Sundays at
03:00 (idempotent; a drifted host shows as a FAILED unit in `systemctl --failed`).

When an execution finds drift, or does not finish, every member of the `admin` group gets a
notification at their next login (one, replaced each week), and `aps-conecta estado` — no sudo —
prints the last verdict with each item and its fix, in Spanish (`/opt/aps-conecta/estado.txt`,
written by every execution: the installer's and the weekly one).

## 7. DNS: the host must reach its own domain (D10)

The wizard and the gates curl the public domain **from the host itself** — the hairpin leg.
If preflight reds there, the installer can fix it itself — with your consent. The wizard's
step 6 offers the fix as a card («Sí, corregir la red») when the refused leg is this one; by
hand it is one command:

    sudo aps-conecta red --dominio <su-dominio> --arreglar

dnsmasq answers the domain from this server (the host's own resolution and the containers' DNS
ride along; the docker service restarts once, before the suite starts). The command proves the
leg before it returns, and re-running it changes nothing. The manual alternatives, if you would
rather not:

- **NAT reflection**: `ufw route allow proto tcp from 172.18.0.0/16 to any port 443`
  (the recorded upstream workaround), or the router's own hairpin setting.
- **Split-DNS via dnsmasq**: a local A record for the domain pointing at the host's LAN IP —
  LAN clients resolve the clinic locally.
- **Docker's own resolver**: `/etc/docker/daemon.json` with `"dns": ["<host-LAN-IP>"]`, then
  `sudo systemctl restart docker`.

Never `SKIP_DOMAIN_VALIDATION` — it silences the wizard's check without fixing the leg the
browsers and the gates actually use. An install by IP skips the check by design (§13): there is no
domain to check.

## 8. The .env the gates ride

The clinic `.env` (in the package root) is minimal by design — the wizard owns the stack. What
the gates read:

- **The suite's address, from apache itself** — the gates resolve `https://<su-dominio>/…` or
  `https://<ip>/…` from apache. `smoke` and `office-smoke` request it from the host with the
  installer's CA; `appapi-smoke` verifies it from HaRP with the running agent's trust.
  `revalidate` runs every gate as root. No `.env` key sets the address.
- **The office keys are absent on purpose**: under AIO the wizard's entrypoint owns the public
  document-server URL and the JWT secret on every boot; by IP, `14-office.sh` adds the two internal
  URLs (§13). There is nothing office-shaped to configure on a clinic — and nothing map-shaped
  either: the basemap needs no key at all (§9).

## 9. The map (OpenStreetMap)

The map is OpenStreetMap's own tile service, loaded directly by each person's browser under the
[Tile Usage Policy](https://operations.osmfoundation.org/policies/tiles/) — Territorio's basemap
and the installer's Centro pane alike (ADR-0021 in territorio). The suite builds, stores and serves
**no** map: there is no map step in the install, no archive, no map timer, no `tiles` subcommand, and
the mastercontainer is created without a map folder. Provisioning phase 16 writes the comuna
(`comuna_cut`, `comuna_name`) from which Territorio derives where the map opens, and no `tile_url`.

- **Every device that shows the map needs internet** (OpenStreetMap's servers, `tile.openstreetmap.org`),
  and so does the machine whose browser walks the web installer: its Centro pane loads the same
  tiles. If the first tile fails the pane says so and the step stays completable — the official
  point, the arrow-key nudge and «Confirmar centro» work on a plain background. The wizard does not
  check the point against any coverage.
- **What the installer's pane sends**: the bare tile URL, the wizard's origin as `Referer` (the
  policy asks for one; a LAN address like `https://192.168.1.10:8443/` is a valid origin), zoom 4
  to 18, tiles only once the view settles, and a linked **© OpenStreetMap contributors**. The wizard
  token rides the URL fragment, which no `Referer` carries.
- **A blocked client looks like a map**: OpenStreetMap answers a client it has blocked with an
  ordinary image, so no error is raised — the basemap shows a «blocked» tile. A block is lifted by a
  code release, not a setting; the repository's issue tracker is the contact the policy asks for.
- **Attribution**: the map must keep showing **© OpenStreetMap contributors**, linked to its copyright
  page — Territorio's map and the installer's pane both do; do not remove it.
- **Territorio's data packages**: `aps-conecta datos` fetches the comuna's packages
  (sha256-verified), stages them and prints the import commands; `aps-conecta datos --importar`
  loads them (the silent install already did — a re-run prints «0 creados» per file). Before
  the first provisioning installs territorio it downloads nothing.

## 10. Updates

The suite updates **as one lockstep set** — never a component alone. When a new suite tag is
published (the instalador Release), and **before it is announced**: install it on a fresh
rehearsal box exactly as a clinic does (§2), then `aps-conecta revalidate` — that rehearsal is
the acceptance record. When updating a clinic:

```bash
aps-conecta revalidate
```

right after the update lands — smoke, office, AppAPI, Talk and divergence, aggregated; a red
names its failed gate. Phase 12 configures Talk immediately after its signed release installs,
using the same owner as boot. Talk checks native TURN/STUN/signaling settings, the public
CA-verified welcome route and Nextcloud's native signaling diagnostic. It preserves wiring;
native diagnostics may initialize signing keys and record backend capabilities.
The supported server's exact optional `changed-users` warning remains visible and additionally
requires native Redis cache verification (ADR-0024). Every other signaling warning or error fails.
An install from v0.3.0 or earlier runs the suite under upstream's container
names; the suite now names them `aps-conecta-*` and does not migrate them: reinstall it. Three
honest notes:

- On image-bump boots an **offline clinic sits at the app-store probe** (upstream behavior:
an unbounded wait on `apps.nextcloud.com` while the store is off — documented upstream behavior,
not patched; the wait ends when the probe times out or the network returns).
- The wizard's automatic self-update paths are suppressed (040); the suite's releases are the source.

### The applications update: `aps-conecta actualizar` (#46)

The suite's images move with a suite tag (above); the **applications** move only when the
administrator says so, with `sudo aps-conecta actualizar` (ADR-0017). It refuses to run unless the
suite is up, the lock exists and the backup is configured — then it prints the plan (current and
candidate version per application), takes a **full backup first** and stops if it fails, fetches
and verifies the newest compatible releases into a new lock, applies them one application at a
time (store applications with one scoped `occ app:update` each, the store closed to everything
else), uninstalls last every release application whose row left the manifest (`occ app:remove`,
its lock row dropped), moves the lock only when everything succeeded, and revalidates.

`sudo aps-conecta actualizar --revisar` prints the plan and **writes nothing** — the way to see
what would move before moving anything. On any failure the lock is unchanged, the failing
application is named, and the restore command (the wizard's «Restaurar la copia de seguridad
seleccionada») is printed. A Nextcloud major bump is refused while a default application has no
compatible release.

## 11. Backups

The wizard's Borg backup covers the instance. Step 6 configures the daily backup at 04:00
Santiago time and includes the selected installation directory (`APS_HOME`, default
`/opt/aps-conecta`) through the wizard request. Keep a copy of the archive off the server.
Restore additional host directories manually with `borg extract` (the recipe: upstream's
[backup docs](https://github.com/nextcloud/all-in-one#pro-tip-backup-archives-access)).

The wizard runs in UTC, so step 6 posts the UTC hour — 07:00 in summer time, 08:00 in winter —
and the wizard shows that hour. After the next DST change the backup runs at 03:00 or 05:00
Santiago time. To move it, the wizard's backup section takes a new time, in UTC.

## 12. Troubleshooting

- **Data and log paths**: the running suite configures `/mnt/ncdata` as the data root and
  `/var/www/html/data/nextcloud.log` as the Nextcloud log. Read the configured values with:

  ```bash
  sudo docker exec --user www-data aps-conecta-nextcloud php /var/www/html/occ config:system:get datadirectory
  sudo docker exec --user www-data aps-conecta-nextcloud php /var/www/html/occ config:system:get logfile
  ```

  After an administrative out-of-band file transfer, update the file index. Replace `USER`
  and `FOLDER` with the account and folder:

  ```bash
  sudo docker exec --user www-data aps-conecta-nextcloud php /var/www/html/occ files:scan --path='USER/files/FOLDER'
  ```

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

  The old backups stay in the renamed folder (step 6's; move a folder named by hand the same way): a
  new wizard cannot reuse their repository. The rest
  of `/opt/aps-conecta` (the site record, `credentials.txt`) stays. Then `sudo aps-conecta abrir`:
  step 6 prepares a new wizard.

Nextcloud and Caddy derive forwarded-header trust from the suite's actual IPv4 interface prefix.
Startup refuses missing or ambiguous network discovery. LAN clients outside that network retain
their own address in access protection and logs, even when they send forwarding headers.

## 13. Without a domain: this server's IP

A clinic without a domain installs by one of this server's IPv4 addresses, written where the domain
goes: step 6, or `SITE_DOMINIO` in the site file of the silent install. The suite then answers at
`https://<ip>/` with a certificate signed by the installer's own CA, the one that signs its link (§5).

- **The address** is one of this server's own (`ip -4 addr`); any other is refused. The wizard's
  domain check is skipped: there is no DNS to check.
- **The certificate** is signed for the address before the wizard starts, into
  `/opt/aps-conecta/certificados/suite` (apache's, read-only). The weekly run signs it again 30 days
  before it expires and restarts apache. The CA that signs it is never made again: if it goes missing,
  the run stops until `/opt/aps-conecta/certificados` is restored from the daily backup (§11).
- **The run command** carries two more lines, `--env APS_TLS_DIR=/opt/aps-conecta/certificados/suite`
  and `--env NEXTCLOUD_TRUSTED_CACERTS_DIR=/opt/aps-conecta/certificados/ca`; step 6 and the silent
  install sign the certificate before they run it. A suite started for a domain does not switch to an
  address, nor the reverse: it is reinstalled (§12).
- **Nextcloud** trusts the CA (phase 07); **the office** reaches Nextcloud inside the suite's network
  (phase 14 writes the two internal URLs). Nothing to configure.
- **Internal IP access**: the AIO controller routes Nextcloud, Talk and HaRP requests to the
  suite IP's HTTPS port directly to Apache inside the suite network. The public URL and TLS
  verification stay unchanged. Short-lived helpers apply only this route inside each client's
  network namespace; they do not alter the host firewall or grant applications additional
  capabilities. The controller reapplies routes after restarts, recreation or a changed Apache
  address. A failed application is logged and retried; native readiness still has to pass.
- **HaRP** receives the public CA certificate read-only and combines it with system certificates
  before starting its AppAPI agent.

Every device that opens the suite imports the CA once. Step 6 offers it («Descargar el
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

## 14. Provisionar como usuario de desarrollo

Utilice una cuenta con acceso a Docker y una copia propia del repositorio. El servidor debe
contar con las dependencias del instalador, OpenSSL 3, el paquete `acl` y los puertos de la
suite disponibles. La preparación del sistema corresponde al administrador (§3).

`APS_HOME` selecciona una ruta absoluta para el estado de la instalación. Al omitirla,
los componentes conservan `/opt/aps-conecta` como ruta predeterminada.

| Estado | Ruta dentro de `APS_HOME` |
|---|---|
| Contraseñas selladas | `credentials.txt` |
| Resultado de ejecución | `estado.txt` |
| Estado y opciones del asistente | `aio/`, `aio/opciones` |
| Autoridad y certificados | `certificados/` |
| Versiones instaladas | `apps.lock.json` |
| Paquetes verificados | `apps/` |

`AIO_STATE` tiene prioridad para el estado del asistente. `APS_APPS_LOCK`, `APS_APPS_STORE`
y `APS_APPS_OPCIONES` tienen prioridad para sus respectivas rutas. `SUITE_CA` permite
seleccionar explícitamente el certificado público usado por las verificaciones HTTPS.
El banco de pruebas conserva `/tmp/aio-testbed` cuando se omiten `APS_HOME` y `AIO_STATE`.

Clone el repositorio y configure la misma sesión para todos los pasos:

```bash
git clone https://github.com/APS-Conecta/gestion.git "$HOME/aps-conecta/gestion"
cd "$HOME/aps-conecta/gestion"
export APS_HOME="$HOME/.local/share/aps-conecta"
export PATH="$HOME/.local/bin:$PATH"
```

Instale el verificador OpenBSD en su directorio de usuario desde el paquete de la distribución:

```bash
mkdir -p "$HOME/.local/bin"
signer_dir="$(mktemp -d)"
(
  cd "$signer_dir" || exit 1
  apt-get download signify-openbsd &&
    dpkg-deb --extract ./signify-openbsd_*.deb unpacked || exit 1
  binary=unpacked/usr/bin/signify-openbsd
  [ -f "$binary" ] || binary=unpacked/bin/signify-openbsd
  install -m 0755 "$binary" "$HOME/.local/bin/signify"
)
rm -rf "$signer_dir"
command -v signify
```

Inicie la suite mediante el banco de pruebas existente:

```bash
bash scripts/aio-testbed.sh up
```

El banco usa la versión fijada en el script; `AIO_TEST_IMAGE` permite seleccionar otra versión
de ensayo aprobada. Una versión publicada más antigua no necesariamente es compatible con
el instalador de este árbol. Antes de configurar el asistente o aprovisionar, el instalador
comprueba las capacidades requeridas de la imagen: el resultado de inicio del asistente y
la configuración de aplicaciones de Nextcloud. Una incompatibilidad nombra ambas versiones;
un problema de acceso a Docker se informa por separado.

Si aparece una incompatibilidad:

1. Conserve los datos, volúmenes, certificados y archivos del establecimiento.
2. Use el instalador correspondiente a las imágenes instaladas; para un ensayo nuevo, quite
   `AIO_TEST_IMAGE` y use la versión fijada por el árbol.
3. Vuelva a ejecutar el paso que falló después de corregir la combinación. Cambiar
   `AIO_TEST_IMAGE` no reemplaza por sí solo los contenedores existentes; no use `down` para
   recuperar una instalación con datos que deba conservar.

El estado queda en `$APS_HOME/aio`. El usuario conserva la propiedad
del certificado para renovarlo; una ACL autoriza su lectura al servicio Apache. Las claves de
la autoridad permanecen privadas. Configure la confianza de los equipos según §13.

Prepare el archivo del establecimiento y la planilla de usuarios según §5. En la misma sesión,
indique sus rutas y el código DEIS del establecimiento:

```bash
read -r -p 'Archivo site.sh: ' site_file
read -r -p 'Planilla de usuarios: ' roster_file
read -r -p 'Código DEIS: ' center_code
python3 scripts/provisionador.py --paso sitio --archivo "$site_file"
python3 scripts/provisionador.py --paso usuarios --codigo "$center_code" --planilla "$roster_file"
python3 scripts/provisionador.py --paso generar --codigo "$center_code" --resumen
bash scripts/divergence.sh --gate
```

La ejecución verifica los paquetes firmados, provisiona el establecimiento y exige divergencia
vacía. Consulte `$APS_HOME/estado.txt` y `.install.log` para revisar el resultado. Ejecute
`bash scripts/aio-testbed.sh down` para retirar los datos y servicios del banco de pruebas.

### Acceso Office

El menú de la suite incluye **Office**, el espacio de documentos de Nextcloud.
Abra sus documentos desde ese icono para editarlos con Euro-Office. Las opciones
Todos y Compartidos permiten encontrar documentos de otras personas y carpetas
compartidas; se conservan sus permisos de acceso. El inicio de los servicios y
la fase 14 de aprovisionamiento habilitan este acceso también en instalaciones
que lo tenían deshabilitado. Las preferencias personales del menú se conservan.
La verificación final debe incluir crear, editar, guardar y volver a abrir un
documento desde Office con una cuenta del personal.
