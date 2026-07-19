# APS Conecta Gestión — dev lifecycle.
# `make up` starts the core services ONLY (no seeding/provisioning — AD-2).
# Office backends (Story 0.2) are switchable one-at-a-time (AD-11):
#   `make office-collabora`  → Collabora CODE   (richdocuments/WOPI)
#   `make office-eurooffice` → Euro-Office      (eurooffice/JWT)
# `make seed` / `smoke` / `test` arrive in later Epic-0 stories (0.4, 0.5).
.DEFAULT_GOAL := help
.PHONY: help up up-dev down office-collabora office-eurooffice office-smoke office-down

OCC = docker compose exec -T --user www-data nextcloud php occ
NET = apsconecta-gestion_default
# Read office settings from .env (empty when .env is absent — office targets precheck for it).
OFFICE_PORT := $(shell [ -f .env ] && grep -E '^OFFICE_PORT=' .env | cut -d= -f2)
OFFICE_JWT_SECRET := $(shell [ -f .env ] && grep -E '^OFFICE_JWT_SECRET=' .env | cut -d= -f2)

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

up: ## Start the core stack (services only)
	@test -f .env || { echo "No .env found — run: cp .env.example .env  (then edit the passwords)"; exit 1; }
	docker compose up -d

up-dev: ## Start the core stack with the Xdebug derived dev image (step-debugging on :9003)
	@test -f .env || { echo "No .env found — run: cp .env.example .env  (then edit the passwords)"; exit 1; }
	docker compose -f compose.yaml -f compose.dev.yaml up -d --build

down: ## Stop the stack (keeps volumes)
	docker compose down

office-collabora: ## Switch office backend → Collabora CODE (enable richdocuments, disable eurooffice)
	@test -f .env || { echo "No .env found — run: cp .env.example .env"; exit 1; }
	docker compose stop eurooffice 2>/dev/null || true
	docker compose --profile collabora up -d collabora
	@echo "Waiting for Collabora discovery on :$(OFFICE_PORT) (https, self-signed) ..."
	@for i in $$(seq 1 45); do curl -skf https://localhost:$(OFFICE_PORT)/hosting/discovery >/dev/null 2>&1 && break; sleep 2; done
	$(OCC) app:install richdocuments 2>/dev/null || $(OCC) app:enable richdocuments
	$(OCC) config:app:set richdocuments wopi_url --value="https://collabora:9980"
	$(OCC) config:app:set richdocuments wopi_allowlist --value="$$(docker network inspect $(NET) -f '{{(index .IPAM.Config 0).Subnet}}')"
	$(OCC) config:app:set richdocuments disable_certificate_verification --value="yes"
	$(OCC) richdocuments:activate-config || true
	# activate-config resets public_wopi_url to wopi_url; set the BROWSER-facing URL AFTER it so the
	# host browser loads the editor from localhost (it cannot resolve the `collabora` service name).
	$(OCC) config:app:set richdocuments public_wopi_url --value="https://localhost:$(OFFICE_PORT)"
	$(OCC) app:disable eurooffice 2>/dev/null || true
	@OFFICE_PORT=$(OFFICE_PORT) bash scripts/office-smoke.sh

office-eurooffice: ## Switch office backend → Euro-Office (enable eurooffice, disable richdocuments)
	@test -f .env || { echo "No .env found — run: cp .env.example .env"; exit 1; }
	docker compose stop collabora 2>/dev/null || true
	docker compose --profile eurooffice up -d eurooffice
	@echo "Waiting for Euro-Office healthcheck on :$(OFFICE_PORT) ..."
	@for i in $$(seq 1 90); do curl -sf http://localhost:$(OFFICE_PORT)/healthcheck >/dev/null 2>&1 && break; sleep 2; done
	$(OCC) app:install eurooffice 2>/dev/null || $(OCC) app:enable eurooffice
	# The doc server fetches documents from Nextcloud at the StorageUrl host (`nextcloud`); it must be a
	# trusted domain or Nextcloud answers HTTP 400. Idempotent (install-time env doesn't retro-apply).
	$(OCC) config:system:get trusted_domains | grep -qx nextcloud || $(OCC) config:system:set trusted_domains $$($(OCC) config:system:get trusted_domains | grep -c .) --value=nextcloud
	$(OCC) config:app:set eurooffice DocumentServerUrl --value="http://localhost:$(OFFICE_PORT)/"
	$(OCC) config:app:set eurooffice DocumentServerInternalUrl --value="http://eurooffice/"
	$(OCC) config:app:set eurooffice StorageUrl --value="http://nextcloud/"
	$(OCC) config:app:set eurooffice jwt_secret --value="$(OFFICE_JWT_SECRET)"
	$(OCC) app:disable richdocuments 2>/dev/null || true
	@OFFICE_PORT=$(OFFICE_PORT) bash scripts/office-smoke.sh

office-smoke: ## Smoke-check the active office backend (auto-detects which is enabled)
	@OFFICE_PORT=$(OFFICE_PORT) bash scripts/office-smoke.sh

office-down: ## Stop both office backends (core stack keeps running)
	docker compose stop collabora eurooffice 2>/dev/null || true
