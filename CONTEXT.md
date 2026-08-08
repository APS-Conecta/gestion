# APS Conecta Gestión

The white-label Nextcloud suite one Chilean CESFAM runs for its internal operations. This glossary
fixes the words the repo uses for branding, identity, the screens branding has to reach, and the
line between what we develop and what a clinic installs. It is a glossary only — the mechanism lives
in [`docs/THEMING-MODEL.md`](docs/THEMING-MODEL.md) and the decisions in [`docs/adr/`](docs/adr/).

## Language

### Identity

**Product identity**:
"APS Conecta Gestión" — the suite itself. Identical on every install and never names a clinic.
_Avoid_: brand, site name, tenant name

**Clinic identity**:
The CESFAM a given install serves. Appears on the login screen and in the header; deliberately
absent everywhere the product identity alone is correct.
_Avoid_: site, tenant, organization, customer

**Server theme**:
The one directory whose files Nextcloud serves in place of its own. The only branding layer that
reaches a screen drawn before the apps load.
_Avoid_: fork, skin, custom CSS

### Screens

**Screen**:
Anything a person sees rendered by this instance — including the ones that only appear when
something is wrong or in progress.
_Avoid_: page, view, template

**Legacy-rendered screen**:
A screen Nextcloud draws through its old template path, which never announces that it is rendering.
Nothing that listens for that announcement — no app, and not the Theming app — can decorate it, so
it arrives carrying Nextcloud's own logo, colours and backdrop unless the server theme supplies
them.
_Avoid_: pre-boot page, error page, maintenance page (each names one instance of the class, and
two of them are drawn long after boot)

**Framework-rendered screen**:
Every other screen. It announces itself as it renders, the Theming app decorates it, and it is
branded today without further work.
_Avoid_: normal page, app page

**Branded**:
A screen is branded when all four hold: it carries the brand lockup, backdrop, colours and fonts;
no visible text names the vendor; it offers no vendor marketing or outbound vendor links; and its
text meets AA contrast.
_Avoid_: themed, white-labeled, styled

**Product chrome**:
Everything that tells a person what suite they are using — names, logo, colours, typography,
footers. The completeness bar applies here in full.
_Avoid_: branding, skin

**Vendor reference**:
Text that names a real external system this instance talks to, in a place where naming it
accurately is what makes the text true. Exempt from the bar: renaming it would ship a lie, which
is a worse defect than the leak. Every exemption is listed, never assumed.
_Avoid_: leak, leftover string

### Environments and releases

**Production instance**:
The Nextcloud a clinic runs, installed from a release. None exists yet.
_Avoid_: PRD, prod, live, PROD environment

**Dev stack**:
The local Docker Compose stack a developer runs. Disposable: `make install` rebuilds it.
_Avoid_: dev environment, local, staging

**Release**:
A tagged commit of this repo that a clinic may install. `main` is the trunk, never the release.
_Avoid_: build, deploy, version

**Shipped app**:
An app a release installs, pinned by version and sha256. Two kinds, below.
_Avoid_: installed app, enabled app

**Vendored app**:
A shipped app someone else wrote; its tarball comes from upstream unchanged.
_Avoid_: third-party app, store app

**Own app**:
A shipped app we wrote; its tarball is built from a tag of its own repository (ADR-0003).
_Avoid_: custom app, internal app

**Lab app**:
An app of ours under development: a clone in `apps/`, declared in `dev/lab-apps.sh`, never in a
release.
_Avoid_: custom app, WIP app, experimental app
