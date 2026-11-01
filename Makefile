# devkit gates itself with the targets it ships: GATES=tree (the default) runs
# the working tree's scripts, GATES=release those of the release devkit.toml
# pins (README, "Gating devkit itself"). The tree branch is devkit's own: a
# consumer's Makefile has the shape docs/contract.md shows. `make check` or
# `make check-devkit` on its own defaults to GATES=release, the only mode they
# apply to; a bare `make` counts as its default goal, help, so stays in tree.
PROJECT := devkit
GATES   ?= $(if $(filter-out check check-devkit,$(or $(MAKECMDGOALS),help)),tree,release)
ifeq ($(GATES),release)
DEVKIT := $(shell ./devkitw path)
ifeq ($(DEVKIT),)
$(error devkitw failed; see its message above)
endif
include .devkit/make/common.mk
else ifeq ($(GATES),tree)
# check-devkit needs .devkit to resolve to DEVKIT, which here is the working
# tree, never the pin the hooks' notice asks to fetch and link.
ifneq ($(filter check check-devkit,$(MAKECMDGOALS)),)
$(error make check applies to GATES=release only: run 'make GATES=release check')
endif
DEVKIT := $(CURDIR)
include make/common.mk
else
$(error GATES must be tree or release, not '$(GATES)')
endif

.PHONY: audit check-versions maven-checksums test
# The working tree's script over its parent POMs, whichever GATES: the report is advisory, so it
# gates nothing a release's copy should, and the pins are this change's.
check: check-versions
check-versions: ## report newer releases of every parent POM's version pins (advisory, needs the network)
	@. scripts/lib/python.sh && python3_floor || exit; rc=0; for pom in java/*/pom.xml; do \
		echo "== $${pom%/pom.xml}"; PROJECT_ROOT=$${pom%/pom.xml} python3 -I scripts/java/version_check.py || rc=1; done; exit $$rc

# The working tree's closures, whichever GATES: their lockfiles are this change's.
audit: ## audit the markdown and jscpd closures with npm audit (needs the network)
	@scripts/closure_audit.sh markdown jscpd

maven-checksums: ## regenerate java/checksums/checksums.sha256 from a fresh build of the java fixtures (needs the network)
	@scripts/maven_checksums.sh

# Cleared, an outer make's flags, and its VAR=value as an override, cannot reach a fixture's make.
test: ## run devkit's tests (tests/run.sh), the push gate's second stage
	@env -u MAKEFLAGS -u MFLAGS -u GNUMAKEFLAGS -u MAKELEVEL -u MAKEFILES tests/run.sh
