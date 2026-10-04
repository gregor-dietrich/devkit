# devkit consumer contract (v0.2.0)

The interface between devkit and a project that uses it. Every file in
devkit is written against this page; change it here first.

## What a consumer commits

| File | Role |
| --- | --- |
| `devkitw` | Verbatim copy of devkit's `devkitw`; never edited in the project |
| `devkit.toml` | The pin (`[devkit]`) and the project values devkit's scripts read (below) |
| `Makefile` | Profile variables, the two includes, project-only targets |
| `checkstyle-project.xml` | Maven: the project's own Checkstyle rules (see Maven configuration) |
| `checkstyle-suppressions.xml` | Maven: the project's Checkstyle exemptions; required (`<suppressions/>` when none) |
| `.gitignore` entry `/.devkit` | The link `devkitw` creates |

```toml
[devkit]
url = "https://git.vptr.de/gregor/devkit.git"
# mirror = "https://github.com/<owner>/devkit.git"   # optional fallback
version = "v0.2.0"
commit = "<40-hex commit the tag resolves to>"

# Required when FRONTEND_DIR is set; an empty table declares none.
[frontend.min-pins]
"some-package" = "1.2.3"
# quote names containing @, / or .: "@scope/name" = "1.2.3"
```

```make
PROJECT      := my-app
JAVA_VERSION := 25
MODULES      := app-api app-gui       # empty for a monolith
FRONTEND_DIR := app-gui               # optional; empty when there is none
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
- It reads only the `[devkit]` table, one `key = "value"` per line; every
  other table in `devkit.toml` belongs to devkit's scripts.

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
  stdlib-only and run under `python3` 3.11 or later.
- They act on the project, never on devkit: `cd "$PROJECT_ROOT"` first, and
  resolve project files from `$PROJECT_ROOT`, devkit files from `$DEVKIT`.
- Shared helpers live in `scripts/lib/` and are sourced as
  `"$DEVKIT/scripts/lib/<name>.sh"`.
- `MODULES` empty means a single-module (monolith) build; otherwise Maven
  module selection maps each listed module to `-pl` as the Java scripts
  document.
- `ONLY` is read through `scripts/lib/select_modules.sh`, never parsed by
  hand. It normalizes each entry to its `MODULES` spelling (`./<dir>`,
  `<dir>/` and `:<dir>` as Maven's `-pl` accepts them) and keeps each module
  once, fails on an entry that names no module and on whitespace anywhere in
  `ONLY` (entries are separated by commas only), and exports the normalized
  `ONLY`, `SELECTED` and `FRONTEND_SELECTED`. A consumer's own scripts that
  act on `ONLY` source it the same way.
- `check_frontend_deps.py` reads the project's npm minimums from
  `[frontend.min-pins]` in `$PROJECT_ROOT/devkit.toml`: each
  `"<package>" = "<x.y.z>"` requires a stable version at or above it in
  `package.json` and, when the project commits one, in `package-lock.json`.
  It fails when the table is absent, when a minimum is not a stable
  `x.y.z`, and on any other key under `[frontend]`; an empty table checks
  nothing. devkit itself names no package.

## Maven configuration

Shared gate configs live in `java/config/` (`checkstyle.xml`,
`pmd-ruleset.xml`, `eclipse-formatter.xml`). A consumer's pom reads them as
`${maven.multiModuleProjectDirectory}/.devkit/java/config/<file>`.
Project-specific files (`dependency-check-suppression.xml`,
`spotbugs-exclude.xml`, `checkstyle-suppressions.xml`,
`checkstyle-project.xml`) stay in the project.

A rule that names a class, helper or field the project writes belongs to
the project, not to the shared configs. The known exception is
`pmd-ruleset.xml`'s `extraAssertMethodNames` for UnitTestShouldIncludeAssert,
which a project cannot extend yet. The shared configs do keep the stack's
conventions: JBoss Logging as the facade, a static `LOG` logger field and
`jakarta.annotation.Nullable`. A project's own Checkstyle rules live in
`checkstyle-project.xml` at the project root, a complete Checkstyle
configuration (a `Checker` root), which the pom runs as the checkstyle
plugin's execution `project`, with the shared config left at plugin level:

```xml
<executions>
  <execution>
    <id>project</id>
    <goals>
      <goal>check</goal>
    </goals>
    <configuration>
      <configLocation>${maven.multiModuleProjectDirectory}/checkstyle-project.xml</configLocation>
      <cacheFile>${project.build.directory}/checkstyle-project-cachefile</cacheFile>
      <outputFile>${project.build.directory}/checkstyle-project-result.xml</outputFile>
    </configuration>
  </execution>
</executions>
```

`make lint` runs `checkstyle:check` and `checkstyle:check@project`. The
execution's `check` goal binds to `verify` by default, so `make test`,
`make coverage` and `make install` run the project's rules too. The
execution inherits the plugin-level `propertyExpansion`, so a
`SuppressionFilter` on `${org.checkstyle.google.suppressionfilter.config}`
reuses the project's `checkstyle-suppressions.xml`. A project with no rules
of its own commits an empty `<module name="Checker"/>`; `make check` fails
when the file is missing. Without the execution, Maven still runs
`checkstyle:check@project`, with the plugin-level configuration, that is the
shared config again, and the project's rules never run.
