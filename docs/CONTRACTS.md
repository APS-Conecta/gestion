# Org contracts — what app A may consume from app B

_The ADR-0011 home for org-wide facts. Every cross-module surface with an
owner and a stability status; indexed so cross-app consumption is a design
decision, not a grep accident (review L0-06)._

## OCS APIs (the published RESTful surface — M2 doctrine)

| App | Surface | Spec | Stability |
|---|---|---|---|
| territorio | `/ocs/v2.php/apps/territorio/api/v1/` (counts, features/{id}, subcategories/{c}/{s}/features) | territorio/openapi.json (generated) | stable (territorio#ADR-0020) |
| farmacia | `/ocs/v2.php/apps/farmacia/api/v1/medicamentos` | farmacia/openapi.json | stable (typed payload; farmacia's ApiContractTest pins the schema) |
| epidemiologia | `/ocs/v2.php/apps/epidemiologia/api/v1/sources` | epidemiologia/openapi.json | stable (epidemiologia#ADR-0006) |

## Injection services (in-instance, transactional)

| App | Service | Stability |
|---|---|---|
| territorio | `OCA\Territorio\Service\RegistryService` (counts/find/inSubcategory) | stable (territorio#ADR-0014 as amended by territorio#ADR-0020) |

## Tarball / VENDOR pins

gestion `provisioning/apps/<id>/` — one tarball + VENDOR (version, url,
sha256) per app; `ensure_vendored_app` unpacks, `*.patch` files apply in
name order (gestion#ADR-0002).

## Data manifests

| Manifest | Owner | What it pins |
|---|---|---|
| provisioning/data/packages.json | gestion | seeded data packages |
| provisioning/data/aio-siblings.txt | gestion | AIO sibling refs |
| aps-conecta-web/vendored.json | aps-conecta-web | the ECICEP engine dual-SHA (upstream-first) |

## ADR directories

| Repo | Path | Range |
|---|---|---|
| territorio | docs/adr/ | 0001–0020 |
| epidemiologia | docs/adr/ | 0002–0014 |
| gestion | docs/adr/ | 0000–0013 |
| aps-conecta-web | docs/adr/ | 0001–0023 |

Cross-repo citations are `repo#ADR-NNNN` (org L0-08); in-repo citations
stay bare. farmacia owns no ADR directory — its citations are always
repo-qualified.
