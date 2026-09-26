# ADR-0014 — IntraVox is the default landing app

- **Status:** accepted (2026-09-24, with this plan's approval). The flip itself lands only in the
  promotion commit — never during the lab period. *(Landed 2026-09-26, one commit after the
  promotion: missed in `32c6090`, caught by the state-recovery audit. The browser-open proof
  preceded it as ordered — and earned its keep first: it exposed the lab-period demo `en`/`nl`
  trees hijacking the landing for default-language users (a clean `--skip-demo` clinic never
  has them), deleted from the lab box before the flip.)*
- **Affects:** `provisioning/phases/15-branding.sh` (`defaultapp`), `dev/lab-apps.sh`,
  `provisioning/phases/12-apps.sh` (`OWN_APPS`), `scripts/uninstall.sh`, every staff login.

## Context

The welcome screen program (design: APS Conecta welcome screen, 2026-09-24 —
`.rpiv/artifacts/designs/` in the gestion workspace) makes IntraVox the intranet surface of
APS Conecta. Nextcloud's `defaultapp` decides where a
login lands; today it is `"dashboard,files"`. Flipping it is a fleet-wide convergence (`make
install` applies it everywhere on the next pull), so a pre-promotion flip would ship every clinic
a dead pointer while the app itself is still lab-only (ADR-0005 lifecycle: a lab app is never
shipped).

During the lab period the app is declared in `dev/lab-apps.sh` only; clinics do not install it,
and `defaultapp=intravox` would fall through to nothing.

## Decision

`defaultapp=intravox` replaces `"dashboard,files"` at `15-branding.sh:81` **in the promotion
commit** — one atomic change alongside the OWN_APPS line, the vendored tarball + VENDOR file, the
LICENSING row, and the uninstall self-test extension. Browser-open proof precedes the flip
(farmacia lesson `2a32278`).

Resolution falls to the hardcoded tail while the app is absent or disabled, so the value is safe
under rollback: disable the app and landing falls back to `dashboard,files` — the pre-flip state
needs no counter-edit to be recoverable. `ADR-0014` is the record that the flip is deliberate and
where its safety comes from.
