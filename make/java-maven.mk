# devkit: Java/Maven targets. Include after common.mk (docs/contract.md).
#
# Profile, set by the project Makefile before the includes:
#   JAVA_VERSION  JDK major that `check` requires exactly
#   MODULES       Maven module directories, space-separated; empty = monolith
#   FRONTEND_DIR  directory holding the Vaadin frontend; empty = none
#
# Module selection: ONLY=<module>[,<module>...] limits install, lint,
# format, test, coverage and clean to those MODULES (passed to Maven as
# -pl). Each entry is a module directory as MODULES lists it, not an
# artifactId. Unset, the whole reactor runs. lint's repository gates
# (lint-repo) and format's format-md, from common.mk, always cover the whole
# repository.
# Example: make test ONLY=<module-dir>
#
# Environment: REVISION (default 1.0.0-SNAPSHOT) is passed as -Drevision;
# `audit` reads NVD_API_KEY from the environment, else from .env.build, and
# fails without one.

# A trailing "# comment" on a profile line leaves trailing blanks in the value.
MODULES := $(strip $(MODULES))
FRONTEND_DIR := $(strip $(FRONTEND_DIR))
export ONLY

.PHONY: check check-java install lint format test coverage audit clean kill

check: check-java

check-java: ## Verify the JDK, Maven >= 3.9.9, Python >= 3.11, checkstyle-project.xml, the devkit parent POM and the pom's version pins
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
