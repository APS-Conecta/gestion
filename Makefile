# APS Conecta Gestión — dev lifecycle.
# `make up` starts the core services ONLY (no seeding/provisioning — AD-2).
# The office backend (Story 0.2) is Euro-Office (AD-5):
#   `make office-eurooffice` → Euro-Office (eurooffice/JWT)
# `make smoke` / `make test` = the local quality gate; `make seed` runs the provisioning pipeline.
.DEFAULT_GOAL := help
.PHONY: help install up up-dev down seed seed-idempotent smoke test fix-mount-perms office-eurooffice office-smoke office-down

OCC = docker compose exec -T --user www-data nextcloud php occ
# Your host group, so the container can hand the bind mounts back to you (fix-mount-perms).
HOST_GID := $(shell id -g)
# No .env reading here: every script sources scripts/env.sh itself, so `make smoke` and
# `bash scripts/smoke.sh` behave identically. Nothing in a recipe below needs a value from .env.

# Same guard, four targets. One message, one place to change it.
REQUIRE_ENV = test -f .env || { echo "No .env found — run: cp .env.example .env  (then edit the passwords)"; exit 1; }

install: ## Stand this clinic up, or converge it after editing site.sh / git pull (the one command)
	@bash scripts/install.sh

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

up: ## Start the core stack (services only) and wait until Nextcloud is installed
	@$(REQUIRE_ENV)
	@docker compose up -d
	@$(MAKE) --no-print-directory fix-mount-perms
	@bash scripts/wait-ready.sh

up-dev: ## Start the core stack with the Xdebug derived dev image (step-debugging on :9003)
	@$(REQUIRE_ENV)
	@docker compose -f compose.yaml -f compose.dev.yaml up -d --build
	@$(MAKE) --no-print-directory fix-mount-perms
	@bash scripts/wait-ready.sh

fix-mount-perms: ## Make the bind-mounted apps/ + themes/ writable by BOTH the container (uid 33) and you
	@# Linux bind mounts keep host ownership, but uid 33 must own custom_apps/themes to install apps
	@# there. Owner www-data + your host group with g+w, so both sides can write (AD-9) — plain
	@# `chown www-data:www-data` would leave the host read-only and defeat the live-edit mount.
	@# Done in-container so no host sudo is needed; recursive, and re-applied on every `make up`.
	@docker compose exec -T -u root nextcloud chown -R www-data:$(HOST_GID) /var/www/html/custom_apps /var/www/html/themes 2>/dev/null || true
	@docker compose exec -T -u root nextcloud chmod -R g+w /var/www/html/custom_apps /var/www/html/themes 2>/dev/null || true

down: ## Stop the stack (keeps volumes)
	docker compose down

seed: ## Run the provisioning pipeline verbosely (make install wraps this)
	@$(REQUIRE_ENV)
	provisioning/seed.sh

seed-idempotent: ## Assert a SECOND seed writes nothing (run right after `make seed`)
	@bash scripts/seed-idempotent.sh

smoke: ## Health-gate the running core stack (exit 0 healthy / non-0 broken)
	@bash scripts/smoke.sh

test: ## Local quality gate — static checks + smoke (same script CI runs)
	@bash scripts/test.sh

office-eurooffice: ## Bring up the Euro-Office backend and wire the eurooffice connector
	@$(REQUIRE_ENV)
	docker compose --profile eurooffice up -d --wait eurooffice
	@# This target owns the BACKEND: the container above, the trusted_domains repair below, and the
	@# smoke. The CONNECTOR's config is phase 14-office.sh; the app and its patches are 12-apps.
	@# The doc server fetches from Nextcloud at the StorageUrl host (`nextcloud`), which must be a
	@# trusted domain or Nextcloud answers HTTP 400. It stays here because it repairs an INSTALL-time
	@# value and indexes into an array, which the config guards do not model. Idempotent.
	$(OCC) config:system:get trusted_domains | grep -qx nextcloud || $(OCC) config:system:set trusted_domains $$($(OCC) config:system:get trusted_domains | grep -c .) --value=nextcloud
	@# Then the connector config, through the pipeline that owns it. The WHOLE seed runs — phases are
	@# sourced by seed.sh, not independently runnable — which is affordable because it is idempotent.
	@# Output is not silenced: a target that reprovisions should say so. SEED_FIXTURES=0 because
	@# bringing up an office backend is no reason to create sample users.
	SEED_FIXTURES=0 provisioning/seed.sh
	@bash scripts/office-smoke.sh

office-smoke: ## Smoke-check the Euro-Office backend
	@bash scripts/office-smoke.sh

office-down: ## Stop the office backend (core stack keeps running)
	docker compose stop eurooffice 2>/dev/null || true
