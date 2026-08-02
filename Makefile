# APS Conecta Gestión — dev lifecycle.
# `make up` starts every service, Euro-Office included (AD-5, promoted by #81) — but seeds nothing
# (AD-2). `make office-down` stops just the document server when 2.5 GB is not worth a CSS edit.
# `make smoke` / `make test` = the local quality gate; `make seed` runs the provisioning pipeline.
.DEFAULT_GOAL := help
.PHONY: help setup install up up-dev down seed seed-idempotent smoke test divergence images images-check apps-check fix-mount-perms office-smoke office-down

# Your host group, so the container can hand the bind mounts back to you (fix-mount-perms).
HOST_GID := $(shell id -g)
# No .env reading here: every script sources scripts/env.sh itself, so `make smoke` and
# `bash scripts/smoke.sh` behave identically. Nothing in a recipe below needs a value from .env.

# One guard for every target that needs .env. One message, one place to change it. It names
# `make setup` rather than the copy it replaced: hand-copying leaves four placeholder passwords in a
# file nothing checks.
REQUIRE_ENV = test -f .env || { echo "No .env found — run: make setup"; exit 1; }

setup: ## Create .env with four generated secrets, mode 600 (run once, before install)
	@bash scripts/env-init.sh

install: ## Stand this clinic up, or converge it after editing site.sh / git pull (the one command)
	@bash scripts/install.sh

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

up: ## Start every service (Euro-Office included) and wait until Nextcloud is installed
	@$(REQUIRE_ENV)
	@# --wait, because Euro-Office joined the stack in #81 and `make test` now smokes it: without
	@# this, `up` returned while the document server was still inside its 120s start_period and the
	@# gate raced it. Every service here has a healthcheck, so this waits on all five. It is free on
	@# a warm box (already healthy) and costs the office boot on a cold one — which is the cost #81
	@# accepted. The timeout turns a service that never goes healthy into a failure rather than a hang.
	@docker compose up -d --wait --wait-timeout 420
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

divergence: ## List what is live on the instance that the repo no longer declares (#85)
	@bash scripts/divergence.sh

images: ## Refresh the pinned image digests to what each tag points at today (#109)
	@bash scripts/image-digests.sh

images-check: ## Report whether any tag has moved past its pin (changes nothing)
	@bash scripts/image-digests.sh --check

apps-check: ## Report whether any vendored app has a newer release (changes nothing)
	@bash scripts/app-versions.sh

# `office-eurooffice` was DELETED here by #81 — a second entry point for what `make install` already
# does, which is what ADR-0001 deleted occ-theming.sh for. `make office-smoke` checks the backend alone.

office-smoke: ## Smoke-check the Euro-Office backend
	@bash scripts/office-smoke.sh

office-down: ## Stop the office backend (core stack keeps running)
	docker compose stop eurooffice 2>/dev/null || true
