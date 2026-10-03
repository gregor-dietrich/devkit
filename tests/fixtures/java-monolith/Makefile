PROJECT      := java-monolith
JAVA_VERSION := 25
MODULES      :=                       # empty for a monolith
FRONTEND_DIR :=                       # optional; empty when there is none
DEVKIT := $(shell ./devkitw path)
ifeq ($(DEVKIT),)
$(error devkitw failed; see its message above)
endif
include .devkit/make/common.mk
include .devkit/make/java-maven.mk
# project-only targets follow

.PHONY: hello
hello: ## a project-only target, which make help must list too
	@echo "hello from $(PROJECT)"
