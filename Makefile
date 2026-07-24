# APS Conecta Gestión — dev lifecycle.
# `make up` starts the core services ONLY (no seeding/provisioning — AD-2).
# The office backend (Story 0.2) is Euro-Office (AD-5):
#   `make office-eurooffice` → Euro-Office (eurooffice/JWT)
# `make smoke` / `make test` = the local quality gate; `make seed` runs the provisioning pipeline.
.DEFAULT_GOAL := help
.PHONY: help up up-dev down seed smoke test credentials fix-mount-perms office-eurooffice office-smoke office-formats office-down

OCC = docker compose exec -T --user www-data nextcloud php occ
# Your host group, so the container can hand the bind mounts back to you (fix-mount-perms).
HOST_GID := $(shell id -g)
# Read settings from .env (empty when .env is absent — targets that need them precheck for it).
HTTP_PORT := $(shell [ -f .env ] && grep -E '^HTTP_PORT=' .env | cut -d= -f2)
OFFICE_PORT := $(shell [ -f .env ] && grep -E '^OFFICE_PORT=' .env | cut -d= -f2)
OFFICE_JWT_SECRET := $(shell [ -f .env ] && grep -E '^OFFICE_JWT_SECRET=' .env | cut -d= -f2)

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

up: ## Start the core stack (services only)
	@test -f .env || { echo "No .env found — run: cp .env.example .env  (then edit the passwords)"; exit 1; }
	docker compose up -d
	@$(MAKE) --no-print-directory fix-mount-perms

up-dev: ## Start the core stack with the Xdebug derived dev image (step-debugging on :9003)
	@test -f .env || { echo "No .env found — run: cp .env.example .env  (then edit the passwords)"; exit 1; }
	docker compose -f compose.yaml -f compose.dev.yaml up -d --build
	@$(MAKE) --no-print-directory fix-mount-perms

fix-mount-perms: ## Make the bind-mounted apps/ + themes/ writable by BOTH the container (uid 33) and you
	@# Linux bind mounts keep host ownership; Nextcloud (uid 33) must own custom_apps/themes to install
	@# apps (groupfolders, office connectors) there. Done in-container so no host sudo is needed.
	@# Owner www-data (container installs apps) + your host group with g+w (you edit them live — AD-9).
	@# `chown www-data:www-data` would leave the host side read-only, defeating the live-edit mount.
	@# Recursive: apps already installed have their own subtree. Re-applied on every `make up`.
	@docker compose exec -T -u root nextcloud chown -R www-data:$(HOST_GID) /var/www/html/custom_apps /var/www/html/themes 2>/dev/null || true
	@docker compose exec -T -u root nextcloud chmod -R g+w /var/www/html/custom_apps /var/www/html/themes 2>/dev/null || true

down: ## Stop the stack (keeps volumes)
	docker compose down

seed: ## Run the provisioning pipeline (services must be up)
	@test -f .env || { echo "No .env found — run: cp .env.example .env"; exit 1; }
	provisioning/seed.sh

credentials: ## Write CREDENTIALS.local.md (all stack secrets from .env — gitignored, mode 600)
	@bash scripts/dump-credentials.sh

smoke: ## Health-gate the running core stack (exit 0 healthy / non-0 broken)
	@HTTP_PORT=$(HTTP_PORT) bash scripts/smoke.sh

test: ## Local quality gate — static checks + smoke (the CI stand-in)
	@bash scripts/test.sh

office-eurooffice: ## Bring up the Euro-Office backend and wire the eurooffice connector
	@test -f .env || { echo "No .env found — run: cp .env.example .env"; exit 1; }
	docker compose --profile eurooffice up -d --wait eurooffice
	$(OCC) app:install eurooffice 2>/dev/null || $(OCC) app:enable eurooffice
	@# The doc server fetches documents from Nextcloud at the StorageUrl host (`nextcloud`); it must be a
	@# trusted domain or Nextcloud answers HTTP 400. Idempotent (install-time env doesn't retro-apply).
	$(OCC) config:system:get trusted_domains | grep -qx nextcloud || $(OCC) config:system:set trusted_domains $$($(OCC) config:system:get trusted_domains | grep -c .) --value=nextcloud
	$(OCC) config:app:set eurooffice DocumentServerUrl --value="http://localhost:$(OFFICE_PORT)/"
	$(OCC) config:app:set eurooffice DocumentServerInternalUrl --value="http://eurooffice/"
	$(OCC) config:app:set eurooffice StorageUrl --value="http://nextcloud/"
	@# `@` + silenced output: this is the only secret on the wire here, and neither make's command echo
	@# nor occ's "is now set to '…'" confirmation may leak it (NFR-2/AD-3 — cf. scripts/dump-credentials.sh,
	@# which writes secrets to a mode-600 file and never to stdout).
	@$(OCC) config:app:set eurooffice jwt_secret --value="$(OFFICE_JWT_SECRET)" >/dev/null
	@echo "Config value 'jwt_secret' for app 'eurooffice' is set (value not printed)."
	@OFFICE_PORT=$(OFFICE_PORT) bash scripts/office-smoke.sh

office-smoke: ## Smoke-check the Euro-Office backend
	@OFFICE_PORT=$(OFFICE_PORT) bash scripts/office-smoke.sh

office-formats: ## Audit the Euro-Office backend — OSS/no-paid-licence (Story 4.3)
	@OFFICE_PORT=$(OFFICE_PORT) bash scripts/office-formats.sh

office-down: ## Stop the office backend (core stack keeps running)
	docker compose stop eurooffice 2>/dev/null || true
