# Targets shared by every devkit consumer; the interface is docs/contract.md.
# `help` lists every rule line that carries a `## description` comment.

# `:=`, not `?=`: an inherited PROJECT_ROOT must not aim the git targets at
# another repository. A command-line PROJECT_ROOT=... still overrides it.
PROJECT_ROOT := $(CURDIR)
export PROJECT_ROOT PROJECT JAVA_VERSION MODULES FRONTEND_DIR DEVKIT

MAKEFLAGS += --no-print-directory

.PHONY: help check check-devkit lint lint-repo lint-pins lint-decisions branch rebase tag untag

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

# No `##` here: the language profile's `lint` rule carries the description
# and the recipe, which runs after this prerequisite.
lint: lint-repo

lint-repo: lint-pins lint-decisions ## run the repository-wide gates (ONLY does not narrow them)

lint-pins: ## check that workflow actions and container images are pinned
	@"$(DEVKIT)/scripts/pins.sh"

lint-decisions: ## check docs/decisions.md's entry format, when the project keeps one
	@"$(DEVKIT)/scripts/decisions.sh"

branch: ## create or reset a git branch from a source (prompts for names and pushes)
	@"$(DEVKIT)/scripts/branch.sh"

rebase: ## interactive git rebase against a target (defaults to origin/main)
	@"$(DEVKIT)/scripts/rebase.sh"

tag: ## create, sign and push a new git tag (auto-increments latest tag suggestion)
	@"$(DEVKIT)/scripts/tag.sh"

untag: ## delete a local and remote git tag (prompts for tag to delete)
	@"$(DEVKIT)/scripts/untag.sh"
