# APS Conecta Gestión — dev lifecycle.
# `make up` starts the core services ONLY (no seeding/provisioning — AD-2).
# `make seed` / `smoke` / `test` arrive in later Epic-0 stories (0.4, 0.5).
.DEFAULT_GOAL := help
.PHONY: help up down

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-8s\033[0m %s\n", $$1, $$2}'

up: ## Start the core stack (services only)
	@test -f .env || { echo "No .env found — run: cp .env.example .env  (then edit the passwords)"; exit 1; }
	docker compose up -d

down: ## Stop the stack (keeps volumes)
	docker compose down
