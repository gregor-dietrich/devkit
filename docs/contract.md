# devkit consumer contract (v0.2.0)

The interface between devkit and a project that uses it. Every file in
devkit is written against this page; change it here first.

## What a consumer commits

| File | Role |
| --- | --- |
| `devkitw` | Verbatim copy of devkit's `devkitw`; never edited in the project |
| `devkit.toml` | The pin (`[devkit]`) and the project values devkit's scripts read (below) |
| `Makefile` | Profile variables, the two includes, project-only targets |
| `pom.xml` | Maven: the root pom inherits devkit's parent POM, with a `<groupId>` of its own and `maven.compiler.release` (see Parent POM) |
| `.mvn/jvm.config` | Maven: the `jdk.compiler` exports and opens Error Prone needs |
| `checkstyle-project.xml` | Maven: the project's own Checkstyle rules, at the root (see Maven configuration) |
| `checkstyle-suppressions.xml` | Maven: the project's Checkstyle exemptions, in every module, the root included; required (`<suppressions/>` when none) |
| `spotbugs-exclude.xml` | Maven: the project's SpotBugs exclusions, in every module with classes; required (an empty `<FindBugsFilter/>` when none) |
| `dependency-check-suppression.xml` | Maven: the project's dependency-check suppressions, at the root, read by `make audit` |
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
`pmd-ruleset.xml`, `eclipse-formatter.xml`). devkit's [parent
POM](#parent-pom) reads them as
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
configuration (a `Checker` root). The parent runs it as the checkstyle
plugin's execution `project`, with its own `configLocation`, `cacheFile`
and `outputFile`, and the shared config at plugin level.

`make lint` runs `checkstyle:check` and `checkstyle:check@project`. The
execution's `check` goal binds to `verify` by default, so `make test`,
`make coverage` and `make install` run the project's rules too. The
execution inherits the plugin-level `propertyExpansion`, so a
`SuppressionFilter` on `${org.checkstyle.google.suppressionfilter.config}`
reuses the project's `checkstyle-suppressions.xml`. A project with no rules
of its own commits an empty `<module name="Checker"/>`; `make check` fails
when the file is missing.

## Parent POM

`java/parent/pom.xml` is `de.vptr.devkit:devkit-parent`, the shared gate
configuration as a Maven parent. Since v0.2.0 a consumer's root pom must
inherit it, and Maven reads it through the link:

```xml
<parent>
  <groupId>de.vptr.devkit</groupId>
  <artifactId>devkit-parent</artifactId>
  <version>0.2.0</version>
  <relativePath>.devkit/java/parent/pom.xml</relativePath>
</parent>
```

- Its version is the release tag without the `v` (`v0.2.0` → `0.2.0`),
  literal, never a property. A bump edits it together with `version` and
  `commit` in `devkit.toml`. The parent is published to no repository: the
  link is the only way to reach it.
- Every target that runs Maven (`check`, `install`, `lint`, `format`,
  `test`, `coverage`, `audit`, `clean`, and a consumer's own script that
  sources `scripts/lib/get_maven.sh`) first runs
  `scripts/java/parent_check.py`. It fails, with one `ERROR` line and exit
  status 14, when
  - the root pom's `<parent>` is not devkit's;
  - its `<relativePath>` is not exactly `.devkit/java/parent/pom.xml`;
  - its `<version>` is not `devkit.toml`'s `version` without the `v`, or
    the pinned checkout's parent POM declares another version (a defective
    release);
  - the root pom has no `<groupId>` of its own: it would inherit
    `de.vptr.devkit`, for its artifacts and for NullAway's default
    packages;
  - the root pom or any module pom (`<modules>`, recursively, profiles
    included) defines one of the parent's `*.version` properties: a
    partial migration. To try another tool version, pass it on the command
    line (`./mvnw -Dcheckstyle.version=… verify`) instead;
  - any of those poms sets `maven-compiler-plugin`'s `<compilerArgs>` or
    `<annotationProcessorPaths>` without `combine.children="append"`.
- It pins every gate tool's version as a property (`checkstyle.version`,
  `checkstyle-plugin.version`, `compiler-plugin.version`,
  `dependency-check-plugin.version`, `eclipse-formatter.version`,
  `error-prone.version`, `jacoco-plugin.version`, `license-plugin.version`,
  `nullaway.version`, `pmd-plugin.version`, `spotbugs-plugin.version`,
  `spotless-plugin.version`, `surefire-plugin.version`), and manages the
  `org.jacoco` artifacts at the JaCoCo plugin's version, so Quarkus' own
  JaCoCo matches the plugin's.
- It configures the compiler (`-Werror`, `-Xlint:all` minus `serial`,
  `this-escape` and `classfile`, Error Prone with NullAway), surefire and
  failsafe, and activates failsafe, license (`add-third-party`), SpotBugs,
  PMD (with CPD), Checkstyle (the shared config and the execution
  `project`), JaCoCo (agent, report and coverage check) and Spotless, whose
  checks run at `verify`. dependency-check is configured but not
  activated; `make audit` runs it by its coordinates.
- The consumer sets `maven.compiler.release`, which the compiler and PMD's
  `targetJdk` read, and overrides these properties in its own
  `<properties>`:

  | Property | Default |
  | --- | --- |
  | `jacoco.check.lineMinimum` | `0.90` |
  | `jacoco.check.branchMinimum` | `0.80` |
  | `jacoco.check.skip` | `false` |
  | `pmd-cpd.minTokens` | `65` |
  | `skipITs` | `true` |
  | `nullaway.annotated.packages` | `${project.groupId}` |
  | `error-prone.extra.args` | empty; appended to the Error Prone argument, e.g. `-XepExcludedPaths:.*/generated-sources/.*` |

- It commits the files the table above lists. `.mvn/jvm.config` carries
  the `jdk.compiler` `--add-exports` and `--add-opens` lines as devkit's
  `tests/fixtures/java-monolith/.mvn/jvm.config` lists them. The parent
  reads `checkstyle-suppressions.xml` and `spotbugs-exclude.xml` from
  `${project.basedir}`; a multi-module project that keeps one
  `checkstyle-suppressions.xml` at the root overrides the checkstyle
  plugin's `<propertyExpansion>` in its own `<pluginManagement>`, as
  `tests/fixtures/java-multimodule/pom.xml` does.
- Maven merges any list the parent sets with a consumer's redeclaration
  element by element, by position, unless the consumer's list carries
  `combine.children="append"`: a redeclared `<compilerArgs>` silently drops
  the inherited `-Werror`, Error Prone or NullAway, and the same holds for
  `<annotationProcessorPaths>`, JaCoCo's `<excludes>` and `<rules>`, PMD's
  `<rulesets>` and dependency-check's `<suppressionFiles>`. The parent
  check enforces it for the compiler's two lists only.
- Some settings live at execution level, where a plugin-level override
  does not reach them; override them inside the execution with the id
  below: license's `failOnMissing`, `failOnBlacklist` and
  `excludedLicenses` (`add-third-party`), JaCoCo's agent `<excludes>`
  (`prepare-agent`), and its `<rules>` and `<skip>` (`check`; prefer the
  properties).
- Excluding generated sources is the consumer's: checkstyle
  `<sourceDirectories>`, PMD `<excludeRoots>`, the SpotBugs filter and
  `error-prone.extra.args`.
- The property names above and the execution ids are contract: a renamed
  one silently ignores a consumer's override. The ids are `prepare-agent`,
  `report` and `check` (JaCoCo), `pmd-check` and `cpd-check` (PMD),
  `checkstyle` and `project` (Checkstyle), `spotless-check` (Spotless),
  `spotbugs-check` (SpotBugs), `add-third-party` (license) and `default`
  (failsafe).
- Never add a repository whose namespace ownership is unverified to the
  root pom or to Maven's settings. Maven must find the parent only through
  the link; a remote lookup of `de.vptr.devkit:devkit-parent` is the
  failure mode, and whatever serves it would configure the build.
- Known limit: installed poms reference the unpublished parent, so a build
  outside the reactor cannot resolve it, e.g. `-pl` of a module that
  depends on a sibling, or a downstream project depending on the
  consumer's artifacts. No current consumer is affected.
