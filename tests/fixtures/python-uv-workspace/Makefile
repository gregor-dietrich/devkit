PROJECT        := python-uv-workspace
MODULES        := packages/core packages/app   # uv workspace members
COVERAGE_FLOOR := 100
DEVKIT := $(shell ./devkitw path)
ifeq ($(DEVKIT),)
$(error devkitw failed; see its message above)
endif
include .devkit/make/common.mk
include .devkit/make/python-uv.mk
# project-only targets follow

.PHONY: hello
hello: ## a project-only target, which make help must list too
	@echo "hello from $(PROJECT)"
