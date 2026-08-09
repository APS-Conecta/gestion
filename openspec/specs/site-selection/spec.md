## Purpose

Defines how an install names the primary-care establishment it serves: what a fresh clone contains,
what happens when no establishment has been chosen, how one is chosen from the DEIS register, and
what tracked files may say about a real establishment. The product serves any Chilean APS
establishment and names none of them.

## Requirements

### Requirement: No establishment ships with the product

A clone, and a release tag installed from it, SHALL NOT contain configuration for any real
establishment. No `sites/<slug>/site.sh` is tracked in git, and no tracked file names a real
establishment as a value the software reads.

The DEIS register (`sites/establecimientos-deis-<date>.csv`) is exempt: it is the public MINSAL
catalogue an operator picks *from*, not configuration for any one establishment.

#### Scenario: Fresh clone carries no establishment configuration

- **WHEN** the repository is cloned and `sites/` is listed
- **THEN** it contains the DEIS register CSV and no `<slug>/site.sh`

#### Scenario: No tracked file carries a real establishment's name as a value

- **WHEN** tracked files are searched for the name of a real establishment used as configuration
- **THEN** the only matches are rows of the DEIS register, and no assignment, default or example
  elsewhere resolves to one

#### Scenario: The theme names nobody at rest

- **WHEN** `themes/` is inspected on a checkout that has never been provisioned
- **THEN** no tracked file carries an establishment's name, the per-install `site.css` being absent
  rather than committed with a placeholder value

#### Scenario: The interface is agnostic before an establishment is chosen

- **WHEN** the interface is rendered from a checkout whose per-install theme CSS has not been
  generated yet
- **THEN** the establishment name shows the product's own name from the fallback `server.css`
  declares, and no stylesheet fails in a way that affects any other rule
- **AND** provisioning writes the file on install, after which the chosen establishment's short name
  is what renders

### Requirement: An install refuses to proceed without a chosen establishment

`make install` SHALL stop before starting or changing anything when `SITE` is unset, or when it
names a directory that has no `site.sh`. It SHALL name, in the failure, the commands that choose an
establishment.

#### Scenario: SITE is unset

- **WHEN** `make install` runs with no `SITE` in `.env`
- **THEN** it stops before provisioning, states that `.env` must name the establishment this stack
  serves, and prints the command that searches the register

#### Scenario: SITE names an establishment that has no site file

- **WHEN** `make install` runs with `SITE=mi-establecimiento` and `sites/mi-establecimiento/site.sh`
  does not exist
- **THEN** it stops before provisioning and prints the `scripts/deis.py <codigo> --new
  mi-establecimiento` command that would write it

#### Scenario: The failure offers no shipped establishment as a shortcut

- **WHEN** either refusal above is printed
- **THEN** its remedy is to choose from the register, and it names no establishment the operator
  could adopt instead

### Requirement: The register covers every APS establishment type, and says so

The establishment picker SHALL accept and present every primary-care establishment type the register
carries — CESFAM, PSR, CECOSF, CGR, CGU, COSAM, SAPU, SAR and SUR — and its user-facing text SHALL
NOT describe the product, the register or the search as CESFAM-only.

#### Scenario: Searching for a non-CESFAM establishment

- **WHEN** an operator searches the register for a SAPU, PSR or COSAM by type and comuna
- **THEN** matching establishments of that type are listed and can be written to a site file

#### Scenario: Documented examples do not imply a CESFAM-only tool

- **WHEN** the quickstart, the picker's own help and the provisioning documentation are read
- **THEN** they describe choosing a primary-care establishment, and any type shown is an example
  rather than the only accepted value

### Requirement: Per-install artifacts are never tracked

Anything whose content is a function of *which* establishment is installed SHALL be install-local, in
the same class as `.env`: written on the install host, never committed. This covers the site file
`sites/<slug>/site.sh` and the generated theme stylesheet that carries the establishment's name, and
it holds for every establishment — our own pilot included, and any clinic that adopts the product
later.

One consequence is normative, not incidental: **provisioning an establishment SHALL leave no tracked
file modified.** A repository that goes dirty on every install is one routine commit away from
republishing the establishment it was supposed to stop naming.

#### Scenario: A newly written site file is not offered for commit

- **WHEN** an operator runs the picker to write `sites/<slug>/site.sh` and then inspects git status
- **THEN** the new file is ignored, and no commit can add it without a deliberate override

#### Scenario: Installing leaves the working tree clean

- **WHEN** a full install runs to completion against any chosen establishment
- **THEN** git reports no modified tracked file, the artifacts provisioning wrote being ignored ones

#### Scenario: The pilot install keeps working

- **WHEN** an operator whose `.env` sets `SITE` to a locally-held establishment runs `make install`
- **THEN** it provisions that establishment exactly as before, the file's location and format being
  unchanged

#### Scenario: Upgrading a working copy does not silently destroy its configuration

- **WHEN** a working copy that holds a previously-tracked site file takes this change
- **THEN** the release notes state that the file must be preserved before updating, and the file's
  removal from git is announced rather than discovered
