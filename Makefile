# devkit gates itself with the targets it ships: GATES=tree (the default) runs
# the working tree's scripts, GATES=release those of the release devkit.toml
# pins (README, "Gating devkit itself"). The tree branch is devkit's own: a
# consumer's Makefile has the shape docs/contract.md shows.
PROJECT := devkit
GATES   ?= tree
ifeq ($(GATES),release)
DEVKIT := $(shell ./devkitw path)
ifeq ($(DEVKIT),)
$(error devkitw failed; see its message above)
endif
include .devkit/make/common.mk
else ifeq ($(GATES),tree)
DEVKIT := $(CURDIR)
include make/common.mk
else
$(error GATES must be tree or release, not '$(GATES)')
endif

.PHONY: test
# Cleared, an outer make's flags, and its VAR=value as an override, cannot reach a fixture's make.
test: ## run devkit's tests (tests/run.sh), the push gate's second stage
	@env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u MAKEFILES tests/run.sh
