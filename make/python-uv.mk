# devkit: uv (Python) targets. Include after common.mk (docs/contract.md).
#
# Profile, set by the project Makefile before the includes:
#   MODULES         uv workspace member directories as uv.lock records them, space-separated;
#                   empty = a single package at the root
#   COVERAGE_FLOOR  percent (0-100) of combined statement and branch coverage (--cov-branch)
#                   each package's tests must reach; required
# The CPython version comes from .python-version, the uv version from the uv package in uv.lock.
#
# Copy-paste gate: lint runs jscpd over devkit.toml's [python.duplication] paths, failing on a
# duplicated file pair not accepted there and on an accepted pair no longer duplicated; it
# needs node and npm.
#
# Module selection: ONLY=<member>[,<member>...] limits lint's ruff passes, format and test to
# those MODULES. install, check, audit and clean always act on the whole project, and vulture
# and jscpd always scan it whole. lint's repository gates (lint-repo) and format's format-md,
# from common.mk, always cover the whole repository.
# Example: make test ONLY=<member-dir>
#
# Environment: JUNIT_DIR, when set, makes `test` write one JUnit XML report per package
# there. `audit` needs the network.

# A trailing "# comment" on a profile line leaves trailing blanks in the value.
COVERAGE_FLOOR := $(strip $(COVERAGE_FLOOR))

.PHONY: check check-python install lint format test audit clean

check: check-python

check-python: ## Verify python3, COVERAGE_FLOOR, .python-version, MODULES, [python.duplication], [tool.vulture] paths, the pinned uv and that .venv matches uv.lock
	@"$(DEVKIT)/scripts/python/check.sh"

install: ## Sync .venv from uv.lock (uv sync --locked), installing the pinned uv first when missing
	@"$(DEVKIT)/scripts/python/install.sh"

lint: ## Run lint-repo, then ruff check, ruff format --check, vulture and the jscpd copy-paste gate (needs node and npm)
	@"$(DEVKIT)/scripts/python/lint.sh"

format: ## Run format-md, then apply ruff's fixes and format with ruff
	@"$(DEVKIT)/scripts/python/format.sh"

test: ## Run each package's pytest suite and hold its statement and branch coverage to COVERAGE_FLOOR
	@"$(DEVKIT)/scripts/python/test.sh"

audit: ## Run pip-audit on the runtime dependencies uv.lock pins (needs the network)
	@"$(DEVKIT)/scripts/python/audit.sh"

clean: ## Remove Python caches, build output and coverage data
	@"$(DEVKIT)/scripts/python/clean.sh"
