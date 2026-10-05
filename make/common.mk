# Targets shared by every devkit consumer; the interface is docs/contract.md.
# `help` lists every rule line that carries a `## description` comment.

# `:=`, not `?=`: an inherited PROJECT_ROOT must not aim the git targets at
# another repository. A command-line PROJECT_ROOT=... still overrides it.
PROJECT_ROOT := $(CURDIR)
export PROJECT_ROOT PROJECT JAVA_VERSION MODULES FRONTEND_DIR DEVKIT

MAKEFLAGS += --no-print-directory

.PHONY: help check check-devkit lint lint-repo lint-pins lint-decisions \
	lint-secrets lint-md format format-md branch rebase tag untag

help: ## list the available targets
	@echo "$(PROJECT) - Available commands:"
	@awk -F':.*## ' '/^[A-Za-z0-9_.-]+:[^=].*## /{printf "  make %-16s - %s\n", $$1, $$2}' \
		$(MAKEFILE_LIST) | LC_ALL=C sort

check: check-devkit ## verify the local environment

check-devkit: ## verify .devkit links to the pin (warns on a stale devkitw)
	@cd "$(PROJECT_ROOT)" && ./devkitw self-check \
		|| echo "check-devkit: warning: ./devkitw differs from .devkit/devkitw" >&2
	@[ "$$(cd "$(PROJECT_ROOT)/.devkit" && pwd -P)" = "$$(cd "$(DEVKIT)" && pwd -P)" ] \
		|| { echo "check-devkit: .devkit does not resolve to $(DEVKIT)" >&2; exit 1; }

# No `##` here: the language profile's `lint` and `format` rules carry the
# descriptions and the recipes, which run after these prerequisites.
lint: lint-repo
format: format-md

lint-repo: lint-pins lint-decisions lint-secrets lint-md ## run the repository-wide gates (ONLY does not narrow them)

lint-pins: ## check that workflow actions and container images are pinned
	@"$(DEVKIT)/scripts/pins.sh"

lint-decisions: ## check docs/decisions.md's entry format, when the project keeps one
	@"$(DEVKIT)/scripts/decisions.sh"

lint-secrets: ## scan git history and uncommitted changes for secrets (gitleaks)
	@"$(DEVKIT)/scripts/secrets.sh"

lint-md: ## check Markdown with markdownlint (needs node and npm)
	@"$(DEVKIT)/scripts/markdown.sh"

format-md: ## fix what markdownlint can fix in Markdown
	@"$(DEVKIT)/scripts/markdown.sh" --fix

branch: ## create or reset a git branch from a source (prompts for names and pushes)
	@"$(DEVKIT)/scripts/branch.sh"

rebase: ## interactive git rebase against a target (defaults to origin/main)
	@"$(DEVKIT)/scripts/rebase.sh"

tag: ## create, sign and push a new git tag (auto-increments latest tag suggestion)
	@"$(DEVKIT)/scripts/tag.sh"

untag: ## delete a local and remote git tag (prompts for tag to delete)
	@"$(DEVKIT)/scripts/untag.sh"
