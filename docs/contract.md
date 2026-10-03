# devkit consumer contract (v0.1.0)

The interface between devkit and a project that uses it. Every file in
devkit is written against this page; change it here first.

## What a consumer commits

| File | Role |
| --- | --- |
| `devkitw` | Verbatim copy of devkit's `devkitw`; never edited in the project |
| `devkit.toml` | The pin (below) |
| `Makefile` | Profile variables, the two includes, project-only targets |
| `.gitignore` entry `/.devkit` | The link `devkitw` creates |

```toml
[devkit]
url = "https://git.vptr.de/gregor/devkit.git"
# mirror = "https://github.com/<owner>/devkit.git"   # optional fallback
version = "v0.1.0"
commit = "<40-hex commit the tag resolves to>"
```

```make
PROJECT      := midas2
JAVA_VERSION := 25
MODULES      := midas-api midas-gui   # empty for a monolith
FRONTEND_DIR := midas-gui             # optional; empty when there is none
DEVKIT := $(shell ./devkitw path)
ifeq ($(DEVKIT),)
$(error devkitw failed; see its message above)
endif
include .devkit/make/common.mk
include .devkit/make/java-maven.mk
# project-only targets follow (dev, build, release, password, ...)
```

## `devkitw`

- `./devkitw path` (also the default with no argument) prints the absolute
  path of the pinned devkit checkout, fetching it on first use into
  `${XDG_CACHE_HOME:-$HOME/.cache}/devkit/<commit>/`, and points the
  project's `./.devkit` symlink at it. No network when cached. The cached
  checkout is read-only, and the pinned `version` is recorded with it.
- `./devkitw self-check` exits non-zero when the project's `devkitw` differs
  from the pinned commit's copy. It is advisory: `make check` warns on it
  and does not fail.
- It fails closed, with one line naming the cause, on: missing or malformed
  `devkit.toml`, fetched commit ≠ `commit`, a cache hit whose recorded
  version ≠ `version`, every remote unreachable, and a `.devkit` that
  exists and is not a symlink. It never falls back to another version.

## Make

- The consumer includes both files through the link, `.devkit/make/...`,
  never as `$(DEVKIT)/make/...`: `include` splits on spaces, so a cache
  path containing one would break. The `ifeq ($(DEVKIT),)` guard stays,
  since it is what reports a failed `devkitw`.
- `make/common.mk` sets `PROJECT_ROOT := $(CURDIR)`, so an inherited
  environment value never wins (a command-line `PROJECT_ROOT=...` still
  does), and exports `PROJECT_ROOT PROJECT JAVA_VERSION MODULES
  FRONTEND_DIR DEVKIT` to every recipe.
- Targets: `common.mk` owns `help`, `check`, `check-devkit`, `branch`,
  `rebase`, `tag`, `untag`. `java-maven.mk` owns `check-java`, `install`,
  `lint`, `format`, `test`, `coverage`, `audit`, `clean`, `kill`. Neither
  defines project-only targets.
- `check` is composed by prerequisites, never by two recipes:
  `common.mk` declares `check: check-devkit`, `java-maven.mk` adds
  `check: check-java`.
- `check-devkit` fails when `.devkit` does not resolve to `$(DEVKIT)` and
  only warns when `./devkitw self-check` fails.
- `help` lists every target that carries a `## description` comment on its
  rule line, the consumer's own targets included.
- Every target is `.PHONY`. Recipes call scripts as
  `"$(DEVKIT)/scripts/<name>.sh"` (language-neutral) or
  `"$(DEVKIT)/scripts/java/<name>.sh"`.

## Scripts

- Bash, `set -euo pipefail`, shellcheck-clean. Python helpers are
  stdlib-only and run under `python3`.
- They act on the project, never on devkit: `cd "$PROJECT_ROOT"` first, and
  resolve project files from `$PROJECT_ROOT`, devkit files from `$DEVKIT`.
- Shared helpers live in `scripts/lib/` and are sourced as
  `"$DEVKIT/scripts/lib/<name>.sh"`.
- `MODULES` empty means a single-module (monolith) build; otherwise Maven
  module selection maps each listed module to `-pl` as the Java scripts
  document.

## Maven configuration

Shared gate configs live in `java/config/` (`checkstyle.xml`,
`pmd-ruleset.xml`, `eclipse-formatter.xml`). A consumer's pom reads them as
`${maven.multiModuleProjectDirectory}/.devkit/java/config/<file>`.
Project-specific files (`dependency-check-suppression.xml`,
`spotbugs-exclude.xml`, `checkstyle-suppressions.xml`) stay in the project.
