# Targets shared by every devkit consumer; the interface is docs/contract.md.
# `help` lists every rule line that carries a `## description` comment.

# Recipes run under bash on every machine, not whatever /bin/sh is (dash on
# Debian and Ubuntu). A project that needs another shell sets SHELL directly
# after the includes.
SHELL := /bin/bash

# An inherited PROJECT_ROOT must not aim the targets at another repository,
# not even under `make -e`; a command-line PROJECT_ROOT=... still does, and so
# does a project's own line after the include (the override applies only to
# the inherited value).
PROJECT_ROOT := $(CURDIR)
ifeq ($(origin PROJECT_ROOT),environment override)
override PROJECT_ROOT := $(CURDIR)
endif
# Likewise an inherited MODULES never counts, so a project that omits it is not
# steered by the caller's shell; a command-line value, and `make -e`, still do.
# The language files do the same for their own variables.
ifeq ($(origin MODULES),environment)
MODULES :=
endif
# A trailing "# comment" on a profile line leaves trailing blanks in the value.
MODULES := $(strip $(MODULES))
export PROJECT_ROOT PROJECT JAVA_VERSION MODULES FRONTEND_DIR COVERAGE_FLOOR ONLY DEVKIT

MAKEFLAGS += --no-print-directory

.PHONY: help check check-devkit check-hooks hooks gate lint lint-repo lint-devkitw \
	lint-pins lint-decisions lint-secrets lint-md format format-md branch rebase tag untag

help: ## list the available targets
	@echo "$(PROJECT) - Available commands:"
	@awk -F':.*## ' '/^[A-Za-z0-9_.-]+:[^=].*## /{printf "  make %-16s - %s\n", $$1, $$2}' \
		$(MAKEFILE_LIST) | LC_ALL=C sort

check: check-devkit check-hooks ## verify the local environment

check-devkit: ## verify .devkit links to the pin
	@[ "$$(cd "$(PROJECT_ROOT)/.devkit" && pwd -P)" = "$$(cd "$(DEVKIT)" && pwd -P)" ] \
		|| { echo "check-devkit: .devkit does not resolve to $(DEVKIT)" >&2; exit 1; }

# Advisory: says when a hook is missing or differs from what `make hooks`
# installs from the pinned devkit, and never fails.
check-hooks:
	@"$(DEVKIT)/scripts/hooks.sh" status

hooks: ## install the git hooks (pre-commit: lint-repo; pre-push: lint-repo and test)
	@"$(DEVKIT)/scripts/hooks.sh" install

gate: ## run the push gate (lint-repo, test) and record a passing clean HEAD, which pre-push then skips
	@"$(DEVKIT)/scripts/gate.sh"

# No `##` here: the language profile's `lint` and `format` rules carry the
# descriptions and the recipes, which run after these prerequisites.
lint: lint-repo
format: format-md

lint-repo: lint-devkitw lint-pins lint-decisions lint-secrets lint-md ## run the repository-wide gates (ONLY does not narrow them)

lint-devkitw: ## check that ./devkitw is not older than the pinned devkit's
	@"$(DEVKIT)/scripts/devkitw.sh"

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

tag: ## sign and push a new release tag at the default branch tip (suggests the next version)
	@"$(DEVKIT)/scripts/tag.sh"

untag: ## delete a local and remote git tag (prompts for tag to delete)
	@"$(DEVKIT)/scripts/untag.sh"
