# Entry points for day-to-day work. The logic lives in scripts/; each target
# is a thin wrapper so `make help` doubles as the list of things you can do.

.DEFAULT_GOAL := help
.PHONY: help dev test check codegen import migrate migration db-up db-down db-psql db-destroy hooks frontend-check

help: ## List available commands
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  make %-15s %s\n", $$1, $$2}'

dev: ## Start everything: Postgres, migrations, API (:8080), frontend (:5173)
	@scripts/dev.sh

test: ## Run backend tests against the test database
	@scripts/test.sh

check: ## Run every check CI runs (do this before pushing)
	@scripts/check.sh

codegen: ## Regenerate frontend/src/api/generated.ts from the Haskell API types
	@scripts/codegen.sh

import: ## Import an RBC CSV export: make import file=private/export.csv
	@test -n "$(file)" || (echo "usage: make import file=private/export.csv" && exit 1)
	@scripts/import.sh "$(file)"

migrate: ## Apply pending migrations to the dev and test databases
	@scripts/migrate.sh

migration: ## Create a new migration file: make migration name=create_ledger_accounts
	@test -n "$(name)" || (echo "usage: make migration name=describe_the_change" && exit 1)
	@bash -c 'source scripts/lib.sh && load_env && docker compose run --rm dbmate new "$(name)"'

db-up: ## Start Postgres in the background
	@docker compose up -d --wait db

db-down: ## Stop Postgres (data is kept)
	@docker compose down

db-psql: ## Open a psql shell on the development database
	@docker compose exec db psql -U reckon -d reckon

db-destroy: ## Delete the Postgres volume, including all imported data (asks first)
	@read -p "This deletes every ledger entry in your local database. Type 'destroy' to continue: " answer && [ "$$answer" = destroy ]
	@docker compose down -v

hooks: ## Install the git pre-commit hook that blocks committing private data
	@bash -c 'source scripts/lib.sh && install_git_hooks'

frontend-check: ## Lint, typecheck and build the frontend
	@cd frontend && npm run lint && npm run typecheck && npm run build
