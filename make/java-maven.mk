# devkit: Java/Maven targets. Include after common.mk (docs/contract.md).
#
# Profile, set by the project Makefile before the includes, with `:=` and never reading the
# variable's earlier value (`?=`, `+=` and `X := $(X) y` take the environment's). The command
# line and `make -e` count too, except under `make gate` and pre-push, where only the Makefile
# does (docs/contract.md):
#   JAVA_VERSION  JDK major Maven must run on, exactly (the parent's enforcer)
#   MODULES       Maven module directories, space-separated; empty = monolith
#   FRONTEND_DIR  directory holding the Vaadin frontend: one of MODULES, or `.`
#                 in a monolith whose frontend is the root; empty = none
#
# Module selection: ONLY=<module>[,<module>...] limits install, lint,
# format, test, coverage and clean to those MODULES (passed to Maven as
# -pl). Each entry is a module directory as MODULES lists it, not an
# artifactId. A sibling ONLY leaves out comes from the local repository, as
# the last `make install` left it; one never installed resolves from the
# remote repositories, so `make install` first. Unset, the whole reactor
# runs. lint's repository gates (lint-repo) and format's format-md, from
# common.mk, always cover the whole repository.
# Example: make test ONLY=<module-dir>
#
# Environment: REVISION (default 1.0.0-SNAPSHOT) is passed as -Drevision;
# `audit` reads NVD_API_KEY from the environment, else from .env.build, and
# fails without one.

# An inherited FRONTEND_DIR or JAVA_VERSION never counts (see common.mk's
# PROJECT_ROOT); a command-line value, and `make -e`, still do. Only these
# scripts read them, so common.mk leaves them alone for a uv project.
ifeq ($(origin FRONTEND_DIR),environment)
FRONTEND_DIR :=
endif
ifeq ($(origin JAVA_VERSION),environment)
JAVA_VERSION :=
endif
# A trailing "# comment" on a profile line leaves trailing blanks in the value.
FRONTEND_DIR := $(strip $(FRONTEND_DIR))
JAVA_VERSION := $(strip $(JAVA_VERSION))

.PHONY: check check-java install lint format test coverage audit clean kill

check: check-java

check-java: ## Verify checkstyle-project.xml, FRONTEND_DIR, Python >= 3.11, the devkit parent POM, then (the first run downloads devkit's pinned Maven) the JDK and Maven versions and the pom's version pins
	@"$(DEVKIT)/scripts/java/check.sh"

install: check ## make check, then mvn clean install -DskipTests
	@"$(DEVKIT)/scripts/java/install.sh"

lint: ## Run lint-repo, then the quality-gate plugins and the frontend pin check
	@"$(DEVKIT)/scripts/java/lint.sh"

format: ## Run format-md, then format Java sources with spotless
	@"$(DEVKIT)/scripts/java/format.sh"

test: ## Run the Maven test suite (mvn verify)
	@"$(DEVKIT)/scripts/java/test.sh"

coverage: ## Run all tests incl. ITs with JaCoCo; write .coverage.md
	@"$(DEVKIT)/scripts/java/coverage.sh"

audit: ## Run OWASP dependency-check (NVD_API_KEY or .env.build)
	@"$(DEVKIT)/scripts/java/audit.sh"

clean: ## mvn clean, plus logs and frontend build output
	@"$(DEVKIT)/scripts/java/clean.sh"

kill: ## Stop this project's Quarkus/Maven JVMs and its docker compose services
	@"$(DEVKIT)/scripts/java/kill.sh"
