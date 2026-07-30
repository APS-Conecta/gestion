# APS Conecta Gestión — dev lifecycle.
# `make up` starts the core services ONLY (no seeding/provisioning — AD-2).
# The office backend (Story 0.2) is Euro-Office (AD-5):
#   `make office-eurooffice` → Euro-Office (eurooffice/JWT)
# `make smoke` / `make test` = the local quality gate; `make seed` runs the provisioning pipeline.
.DEFAULT_GOAL := help
.PHONY: help up up-dev down seed seed-idempotent smoke test fix-mount-perms office-eurooffice office-smoke office-down

OCC = docker compose exec -T --user www-data nextcloud php occ
# Your host group, so the container can hand the bind mounts back to you (fix-mount-perms).
HOST_GID := $(shell id -g)
# No .env reading here: every script sources scripts/env.sh itself, so `make smoke` and
# `bash scripts/smoke.sh` behave identically. Nothing in a recipe below needs a value from .env.

# Same guard, four targets. One message, one place to change it.
REQUIRE_ENV = test -f .env || { echo "No .env found — run: cp .env.example .env  (then edit the passwords)"; exit 1; }

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

up: ## Start the core stack (services only)
	@$(REQUIRE_ENV)
	docker compose up -d
	@$(MAKE) --no-print-directory fix-mount-perms

up-dev: ## Start the core stack with the Xdebug derived dev image (step-debugging on :9003)
	@$(REQUIRE_ENV)
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
	@# This target owns the BACKEND: the ~2 GB documentserver container above, the trusted_domains
	@# repair below, and the smoke. The CONNECTOR's configuration — server URLs, editor theme, ODF
	@# formats, the JWT secret — is provisioning/phases/14-office.sh, so it gets query-before-set and
	@# the idempotency gate. The connector app itself and its patches are phase 12-apps (ADR-0002).
	@# Run `make seed` first on a new instance; re-run it after this to wire the connector.
	@# The doc server fetches documents from Nextcloud at the StorageUrl host (`nextcloud`); it must be a
	@# trusted domain or Nextcloud answers HTTP 400. Stays here: it repairs an INSTALL-time value
	@# (NEXTCLOUD_TRUSTED_DOMAINS already covers a fresh instance) and indexes into an array, which the
	@# config guards do not model. Idempotent (install-time env doesn't retro-apply).
	$(OCC) config:system:get trusted_domains | grep -qx nextcloud || $(OCC) config:system:set trusted_domains $$($(OCC) config:system:get trusted_domains | grep -c .) --value=nextcloud
	@# Then apply the connector config through the pipeline that owns it. The whole seed runs, not
	@# just phase 14 — phases are sourced by seed.sh and are not independently runnable — which is
	@# affordable precisely because it is idempotent and now takes ~25s. Output is NOT silenced: a
	@# target that reprovisions should say so rather than surprise you.  SEED_FIXTURES=0: bringing up
	@# an office backend is no reason to create sample users.
	SEED_FIXTURES=0 provisioning/seed.sh
	@bash scripts/office-smoke.sh

office-smoke: ## Smoke-check the Euro-Office backend
	@bash scripts/office-smoke.sh

office-down: ## Stop the office backend (core stack keeps running)
	docker compose stop eurooffice 2>/dev/null || true
