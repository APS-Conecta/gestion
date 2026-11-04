<!-- aps-fork-declaration-start -->
> [!IMPORTANT]
> **This is APS Conecta Gestión, a fork of
> [Nextcloud All-in-One](https://github.com/nextcloud/all-in-one)** maintained by
> [APS Conecta](https://github.com/APS-Conecta) for Chilean primary-healthcare clinics
> (CESFAM and the APS network). It is **not** produced by, affiliated with, sponsored, or
> endorsed by Nextcloud GmbH. "Nextcloud" and the Nextcloud logo are trademarks of
> Nextcloud GmbH.

**What this fork changes.** The tree is Upstream — nextcloud/all-in-one v14.4.3 — plus the paths
[`aps/keep-list.txt`](aps/keep-list.txt) declares, each with its reason — chiefly our layer (the
Keep-list, the runbooks, the docs, the theme, our workflows and scripts, and our three images),
the official images' digest pins, and the upstream automation this repository switches off. Our
Nextcloud image is upstream's without the one-click-instance user cap (#176). The Keep-list check
in CI fails on any other difference from Upstream and on an entry that no longer differs. An
Upstream release arrives as a merge into `main`, merged with a merge commit so `main` records
Upstream as a parent.

**The old host layer.** Until #301 the Keep-list also carries the old host layer — the host CLI,
the old Provisionador and its provisioning phases, the site files, the old release, resolver and
smoke scripts, `install.sh` and its key. The install it drives does not work on this tree, and
nothing is released before the release gate (#303).

**Upstream's documentation.** Upstream's own guides in this root (the manual-install and Helm
chart walkthroughs, the migration and reverse-proxy notes) are carried as upstream ships them;
upstream's readme lives in [its repository](https://github.com/nextcloud/all-in-one#readme).

**License.** The upstream [LICENSE](LICENSE) (AGPL-3.0) is carried unchanged. The complete
corresponding source of every suite image is this repository at the matching suite tag: the
tag's tree — upstream's history and the fork's changes as committed bytes — is the whole of
it.

**Installing.** A clinic installs from the published suite tag, never from this branch — the
runbook (preflight, the provisionador, backups, the map, updates) lives in
[`aps/INSTALLER.md`](https://github.com/APS-Conecta/gestion/blob/main/aps/INSTALLER.md),
and its Spanish walkthrough for clinic IT in
[`aps/GUIA-CLINICA.md`](https://github.com/APS-Conecta/gestion/blob/main/aps/GUIA-CLINICA.md).

Bugs this fork's own tooling hit are ledgered in [BUGS.md](BUGS.md); upstream's own issues
belong to [nextcloud/all-in-one](https://github.com/nextcloud/all-in-one/issues).

<!-- aps-fork-declaration-end -->
