# devkit: Java/Maven targets. Include after common.mk (docs/contract.md).
#
# Profile, set by the project Makefile before the includes:
#   JAVA_VERSION  JDK major that `check` requires exactly
#   MODULES       Maven module directories, space-separated; empty = monolith
#   FRONTEND_DIR  directory holding the Vaadin frontend; empty = none
#
# Module selection: ONLY=<module>[,<module>...] limits install, lint,
# format, test, coverage and clean to those MODULES (passed to Maven as
# -pl). Unset, the whole reactor runs. Example: make test ONLY=api
#
# Environment: REVISION (default 1.0.0-SNAPSHOT) is passed as -Drevision;
# `audit` reads NVD_API_KEY from the environment, else from .env.build.

# A trailing "# comment" on a profile line leaves trailing blanks in the value.
MODULES := $(strip $(MODULES))
FRONTEND_DIR := $(strip $(FRONTEND_DIR))
export ONLY

.PHONY: check check-java install lint format test coverage audit clean kill

check: check-java

check-java: ## Verify the JDK, Maven >= 3.9.9 and the pom's version pins
	@"$(DEVKIT)/scripts/java/check.sh"

install: check ## make check, then mvn clean install -DskipTests
	@"$(DEVKIT)/scripts/java/install.sh"

lint: ## Run the quality-gate plugins and the frontend pin check
	@"$(DEVKIT)/scripts/java/lint.sh"

format: ## Format Java sources with spotless
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
