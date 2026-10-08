# devkit consumer contract (v0.4.0)

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
| `pyproject.toml` | uv: the package, or a virtual workspace root (no `[project]` table) whose members are the packages; its `dev` dependency group lists ruff, pytest, pytest-cov, vulture, pip-audit and uv, and `[tool.vulture]` sets `paths` (see uv projects) |
| `.python-version` | uv: the CPython version, `major.minor` or `major.minor.patch` |
| `uv.lock` | uv: committed; `make install` syncs `.venv` from it and never rewrites it |
| `.gitignore` entry `/.devkit` | The link `devkitw` creates; a uv project also ignores `/.venv` |
| `docs/decisions.md` | Optional: the project's decisions log, whose entry format `lint-decisions` checks (see Repository gates) |
| `.gitleaks.toml` | Optional: the project's gitleaks configuration, read by `lint-secrets` (see Repository gates) |
| `.gitleaksignore` | Optional: the fingerprints of gitleaks findings the project has triaged, read by `lint-secrets` |
| `.markdownlint.jsonc` | Optional: the project's markdownlint configuration, at the root (see Repository gates) |
| `.markdownlintignore` | Optional: the Markdown files `lint-md` skips, at the root |

```toml
[devkit]
url = "https://git.vptr.de/gregor/devkit.git"
# mirror = "https://github.com/<owner>/devkit.git"   # optional fallback
version = "v0.4.0"
commit = "<40-hex commit the tag resolves to>"

# Required when FRONTEND_DIR is set; an empty table declares none.
[frontend.min-pins]
"some-package" = "1.2.3"
# quote names containing @, / or .: "@scope/name" = "1.2.3"

# Optional: the image namespaces the project publishes (Repository gates).
[pins]
first-party = ["registry.example/my-team"]

# Required in a uv project: what make lint's copy-paste gate scans (uv projects).
[python.duplication]
paths = ["src", "tests"]          # the Python files git lists under these
# min-tokens = 50                 # optional, a positive integer
# ignore = ["**/migrations/**"]   # optional jscpd --ignore globs, no commas

# Optional, one per duplicated file pair the project accepts.
[[python.duplication.accepted]]
files = ["src/a.py", "src/b.py"]   # the same file twice for a clone within one file
reason = "why this duplication is deliberate"
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

A uv project's `Makefile` has the same shape as the Maven one under
[What a consumer commits](#what-a-consumer-commits):

```make
PROJECT        := my-tool
MODULES        := packages/core packages/app   # uv workspace members; empty for a single package
COVERAGE_FLOOR := 90                           # percent, required
DEVKIT := $(shell ./devkitw path)
ifeq ($(DEVKIT),)
$(error devkitw failed; see its message above)
endif
include .devkit/make/common.mk
include .devkit/make/python-uv.mk
# project-only targets follow
```

- The consumer includes `common.mk` and exactly one language file,
  `java-maven.mk` or `python-uv.mk`, through the link, `.devkit/make/...`,
  never as `$(DEVKIT)/make/...`: `include` splits on spaces, so a cache
  path containing one would break. The `ifeq ($(DEVKIT),)` guard stays,
  since it is what reports a failed `devkitw`.
- `make/common.mk` sets `PROJECT_ROOT := $(CURDIR)`, so an inherited
  environment value never wins (a command-line `PROJECT_ROOT=...` still
  does), strips `MODULES` of the blanks a trailing comment leaves, and
  exports `PROJECT_ROOT PROJECT JAVA_VERSION MODULES FRONTEND_DIR
  COVERAGE_FLOOR ONLY DEVKIT` to every recipe.
- Targets: `common.mk` owns `help`, `check`, `check-devkit`, `check-hooks`,
  `hooks`, `gate`, `lint-repo`, `lint-pins`, `lint-decisions`, `lint-secrets`,
  `lint-md`, `format-md`, `branch`, `rebase`, `tag`, `untag`.
  `java-maven.mk` owns `check-java`, `install`, `lint`, `format`, `test`,
  `coverage`, `audit`, `clean`, `kill`. `python-uv.mk` owns
  `check-python`, `install`, `lint`, `format`, `test`, `audit`, `clean`.
  None defines project-only targets.
- `check`, `lint` and `format` are composed by prerequisites, never by two
  recipes: `common.mk` declares `check: check-devkit check-hooks`,
  `lint: lint-repo` and `format: format-md`; the language file adds
  `check: check-java` or `check: check-python` and carries the `lint` and
  `format` recipes, which run after the prerequisites. Only one rule line
  per target carries a `## description`.
- `check-devkit` fails when `.devkit` does not resolve to `$(DEVKIT)` and
  only warns when `./devkitw self-check` fails.
- `help` lists every target that carries a `## description` comment on its
  rule line, the consumer's own targets included.
- Every target is `.PHONY`. Recipes call scripts as
  `"$(DEVKIT)/scripts/<name>.sh"` (language-neutral),
  `"$(DEVKIT)/scripts/java/<name>.sh"` or
  `"$(DEVKIT)/scripts/python/<name>.sh"`.

## Scripts

- Bash, `set -euo pipefail`, shellcheck-clean. Python helpers are
  stdlib-only and run under `python3` 3.11 or later; a script checks that
  floor with `python3_floor` from `scripts/lib/python.sh` before it runs one.
- They act on the project, never on devkit: `cd "$PROJECT_ROOT"` first, and
  resolve project files from `$PROJECT_ROOT`, devkit files from `$DEVKIT`.
- Shared helpers live in `scripts/lib/` and are sourced as
  `"$DEVKIT/scripts/lib/<name>.sh"`. `node_closure.sh` checks `node`
  against a devkit directory's `package.json` `engines.node` and installs
  that directory's `package-lock.json` closure once (see `lint-md`), for
  markdownlint-cli (`markdown/`) and jscpd (`jscpd/`).
- `MODULES` empty means a single module or package at the root (a Maven
  monolith, a single uv package); otherwise Maven module selection maps
  each listed module to `-pl` as the Java scripts document. For uv,
  `MODULES` lists the workspace member directories as `uv.lock` records
  them (e.g. `packages/core`), and `make check` fails when they differ.
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
  nothing. devkit itself names no package. It also checks every `@vaadin/*`
  version in `package.json` and `package-lock.json` against the Vaadin
  release's manifests (the core manifest, gaps filled from the dev bundle);
  for that it asks Maven (`MVN_CMD`, which `scripts/lib/get_maven.sh`
  exports) for the local repository and the frontend module's
  `vaadin.version` and resolves the dev bundle. It fails without `MVN_CMD`.

## Repository gates

`lint-repo` runs the language-neutral gates over the whole repository,
before the language gates of `make lint`; `ONLY` does not narrow it.
`lint-pins`, like every gate that reads a family of files, reads the files
git lists in `$PROJECT_ROOT` (tracked, plus untracked files that are not
ignored), fails when git cannot list them, and passes when none match.
`lint-decisions` reads `docs/decisions.md` directly; `lint-secrets` reads
git's history and changes instead.

- `lint-pins` reads four families of files; a file belongs to the first
  that matches:
  - workflows: `.yml`/`.yaml` files under `.gitea/workflows/` or
    `.github/workflows/`, at any depth;
  - actions: every `action.yml` and `action.yaml`;
  - compose files: a basename `compose*.y{a,}ml` or
    `docker-compose*.y{a,}ml`;
  - Dockerfiles: a basename, in any case, that is `Dockerfile` or
    `Containerfile`, alone or followed by `.`, `-` or `_` and a suffix,
    or that ends in `.dockerfile` or `.containerfile`; the
    `.dockerignore` and `.containerignore` files are not.

  It requires every action as
  `owner/repo[/path]@<40 lowercase hex> # vX.Y.Z`, and every container
  image (Dockerfile `FROM`, `COPY --from=` and `# syntax=`; YAML `image:`,
  `container:` and a service's scalar value; `docker://`) as
  `<repository>:<tag>@sha256:<64 hex>`. Exempt: build stages and
  `scratch`; a `./` action whose `action.y{a,}ml`, or the reusable
  workflow it names, git lists, since that file is read itself; an
  action's `image:` that is a relative path to a Dockerfile, read itself
  too; and images under a namespace listed in `devkit.toml`'s optional
  `[pins] first-party = ["<namespace>", ...]`.

  Files a file names must be ones it reads: an action's Dockerfile
  `image:`, resolved against the action's directory, must be a Dockerfile
  git lists; a compose `include:` path and an `extends:` `file:`,
  resolved against the compose file's directory, must be compose files
  git lists, so a remote `include:` fails; a compose `dockerfile:` must be
  named as a Dockerfile (never a `.y{a,}ml` name) and stay inside the
  repository. It resolves against the build context, which is not
  followed.

  A reference it cannot read fails:
  - in YAML, a key in a position or spelling it cannot place (`services`
    included, unless a plain `services:` line), a value continued on a
    deeper line, a quoted value that does not close on its own line, a
    flow collection over several lines that holds anything but scalars
    in sequences, and a backslash escape in a double-quoted value;
  - in compose, `dockerfile_inline:`, `BUILDKIT_SYNTAX`,
    `additional_contexts`, a build argument whose list-form name holds
    `${`, a flow or aliased `args:`, `include:` or `extends:`, and an
    `include:` or `extends:` entry other than a path, `path:`, `file:`
    or `service:`;
  - in a Dockerfile, a line that is not a plain instruction (a heredoc,
    another frontend's syntax, `# escape=`, a lone trailing `\`).
- A `first-party` entry is a lowercase image name without tag or digest,
  and a prefix: every image under `<entry>/` is exempt, so a registry
  host alone (`ghcr.io`) exempts every image on it. Name the images the
  project builds itself (compose `build:` beside `image:`) under a
  declared, host-qualified namespace, with `pull_policy: build`, so that
  name is never pulled from a registry.
- It stops with one `ERROR` line when `devkit.toml` is not valid TOML,
  `pins` is not a table, `[pins]` holds another key, `first-party` is not
  a list or holds an entry that is not such a name, and when git cannot
  list `$PROJECT_ROOT` (not a work tree, such as an unpacked source
  archive, or one git refuses for dubious ownership). A family file that
  is a symlink, or is not UTF-8, is a violation.
- An action with no exact `vX.Y.Z` release (only `v1`, `1.2.3`, a
  prerelease or a branch) cannot pass: vendor it as a `./` action, or tag
  a fork and pin that.
- Limits: the check is one level deep. Images pulled by `run:` steps,
  `RUN` commands or code, and the references inside a pinned action or
  reusable workflow, are not read. Remote build contexts are not read,
  nor are files named only through `COMPOSE_FILE` or `-f`. Submodule
  content, and anything above `$PROJECT_ROOT`, is not listed.
- `lint-decisions` checks `docs/decisions.md` when it exists. An entry is
  a `## ADR-<digits>` heading and the lines up to the next heading starting
  with `##` followed by a space
  (a `###` heading does not end it); entries below a `## Superseded`
  heading are retired. Any other `##`-or-deeper heading naming `ADR-<digit>`
  fails, so a malformed heading cannot hide an entry. Fenced code blocks
  are not read, and a fence that never closes fails. Each entry carries
  exactly one `**Status:**` marker followed by a space, whose value is
  `Accepted` or `Proposed` on an active entry. An entry with a line starting
  `**Premise:**` carries one line starting `**Guard:**` whose first word is
  `watcher`, `cascade` or `memory-only`; an entry has at most
  one of each, and a line leading with `-` followed by a space quotes
  either label without being read as one. A `cascade` guard names
  `trigger: tag:<tag>`, read
  from the guard's paragraph up to the next blank line (backticks around
  the value are dropped; one left inside it fails), and an active entry
  whose tag exists fails as spent. It reads the repository's tags, so a
  shallow clone fails when an active cascade names a trigger. It stops
  with one `ERROR` line when the log cannot be read or is not UTF-8, and
  when git fails. Limit: a full clone made with `--no-tags` is not
  shallow, so it reads every trigger as unfired.
- `lint-secrets` runs gitleaks, at the version and per-platform sha256
  `scripts/secrets.sh` pins (downloaded once into the tools cache, verified
  before it is unpacked), over the history reachable from HEAD and over
  staged and unstaged changes to tracked files; it never scans ignored
  files. A shallow clone fails: CI checks out with full history. gitleaks
  reads the project's `.gitleaks.toml` and `.gitleaksignore`.
  - All three scans run, and the gate fails at the end if any failed. A
    scan also fails when git fails or warns under it: gitleaks logs that
    at level `ERR` with `[git]`, then exits 0 having scanned only part of
    it, or none. A line-ending warning (`LF will be replaced by CRLF`) is
    one: normalize the file's line endings, or commit it.
  - It stops with one `ERROR` line, before any scan, when `$PROJECT_ROOT`
    is not a git work tree, on a shallow clone, on a platform devkit pins
    no gitleaks build for (Linux and macOS, x86-64 and arm64 are pinned),
    when the download fails and when its sha256 differs from the pin.
    Before the first commit it skips the history scan.
  - `GITLEAKS_CONFIG` and `GITLEAKS_CONFIG_TOML` are ignored. git runs
    with `log.showRoot=true`, `color.ui=never`, `color.diff=never`,
    `diff.noprefix=false` and `core.quotePath=true` over the user's and
    the repository's configuration, which could otherwise hide the root
    commit or every line from gitleaks; git before 2.31 ignores these
    overrides. The rest of the configuration, `safe.directory` included,
    applies.
  - It needs curl, tar, and `sha256sum` or `shasum`; the binary lands,
    read-only, in
    `${XDG_CACHE_HOME:-$HOME/.cache}/devkit/tools/gitleaks-<version>-<platform>/`.
  - Limits: every scan reads git's diffs (`git log -p`, `git diff`), so
    lines that only a merge commit introduces (a conflict resolution) are
    not scanned, nor is any file git treats as binary, including one
    `.gitattributes` marks `-diff` or `binary`. Untracked files are not
    scanned until they are staged.
  - A finding is either a secret, which is removed and rotated, or a false
    positive. History keeps a committed secret: once it is rotated, or for a
    false positive, copy the finding's `Fingerprint` from the gate's output
    into `.gitleaksignore`, one per line. A history finding's is
    `<commit>:<path>:<rule>:<line>`; a staged or unstaged one's has no
    commit, `<path>:<rule>:<line>`. A fingerprint matches that one finding
    only, and a rewritten commit no longer matches it, so the finding comes
    back for triage. Prefer it to a path allowlist in `.gitleaks.toml`,
    which applies to every commit in history as well.
- `lint-md` checks every listed `*.md` file that is not a symlink with
  markdownlint-cli at the closure `markdown/package-lock.json` pins,
  installed with `npm ci --ignore-scripts` into
  `${XDG_CACHE_HOME:-$HOME/.cache}/devkit/tools/` on first use (the only
  run that needs the network). `format-md`, part of `make format`, runs its
  `--fix` over the same files and rewrites without judging: it prints what
  markdownlint cannot fix with a `NOTE`, since `make lint` fails on those,
  and passes, so `make format` goes on to the language formatter (an error
  of markdownlint's own still fails it). Both need `node` at or above
  `engines.node` in `markdown/package.json` and `npm` on `PATH`. The
  configuration is the project's `.markdownlint.jsonc` when it has one,
  else `markdown/markdownlint.jsonc`; a project's file may start with
  `"extends": ".devkit/markdown/markdownlint.jsonc"`. `.markdownlintignore`
  excludes files. Each first runs markdownlint on devkit's control files and
  fails unless they pass and fail as expected.

  markdownlint runs without `markdownlint_*` variables and with an empty
  `HOME`, so the files it reads from `HOME` (`~/.markdownlintrc`,
  `~/.config/markdownlint`) do not apply. It still merges, beneath the
  configuration, the nearest `.markdownlintrc` in the project root or a
  directory above it (`~/.markdownlintrc` for a project under the home
  directory), `/etc/markdownlintrc` and `/etc/markdownlint/config`, and,
  when the project has no `.markdownlint.jsonc`, its `.markdownlint.json`,
  `.yaml` or `.yml`.

## Git hooks

`make hooks` installs, into the clone's own hooks directory, `pre-commit`
(`make lint-repo`), `pre-push` (`make lint-repo test`) and notices on
checkout, merge and rewrite (the devkit pin moved; the branch is behind its
base). Each hook is a self-contained copy of the pinned devkit's
`scripts/hooks/`, never a call into the work tree; `make check` warns when
one is missing or stale. A hook it did not write is never overwritten.

- The project must be the git top level: the hooks act only where
  `devkit.toml` and the `Makefile` sit there, so `make hooks` refuses a
  project in a subdirectory, and `make check` says so once.
- The hooks directory is `git rev-parse --git-path hooks`, so
  `core.hooksPath` is honoured, but only inside the clone's git directory:
  `make hooks` refuses one in a work tree, where a branch could supply the
  hooks, or outside the clone, where other repositories would run them, and
  prints the `git config core.hooksPath` that points the clone back. A
  symlinked hooks directory is judged by where it leads.
- Beside a hook of someone else's, the copy is written as `<hook>.devkit`
  and `make hooks` prints the line that runs it from that hook; it refuses
  a `<hook>.devkit` it did not write. A copy that a hook manager moved to
  `<hook>.legacy` or `<hook>.old` is refreshed there. A copy is always a
  regular file: a symlink in its place is replaced, never written through,
  and `make check` reports it as stale.
- The notices run no make target and nothing the work tree supplies: they
  read `devkit.toml` as data, and of `.devkit` only the link, so a
  checkout, merge or rewrite runs no code the branch brings. The gates run
  the work tree's make targets, as a `make` there would. `pre-push` gates
  the work tree at HEAD, not the pushed commits, and says so when they
  differ or the tree is dirty (unless `make gate` verified HEAD, below).
- `make gate` runs the push gate, `make lint-repo test` with `MAKEFLAGS`,
  `MFLAGS`, `MAKELEVEL` and `MAKEFILES` cleared, so an outer `make -i`,
  `-k`, `-n` or `-o` cannot reach a stage (a command-line `VAR=value`
  still reaches the stages' environment), and refuses `ONLY`. Before the
  stages it removes the old record. When they pass, it records HEAD in
  `git rev-parse --git-path devkit-verified-head` (per worktree), but only
  if the project is the git top level, HEAD has a commit, the tree was
  strictly clean at the start and at the end (no change, no untracked
  file, no dirty submodule, no assume-unchanged or skip-worktree entry;
  ignored files are fine), HEAD did not move during the run (detected
  through HEAD and its reflog, so a move away and back counts, and no
  reflog means no record), the ref backend is not reftable, and none of
  `MAVEN_ARGS`, `PYTEST_ADDOPTS` or a `-D` in `MAVEN_OPTS`,
  `JAVA_TOOL_OPTIONS` or `JDK_JAVA_OPTIONS` is set. Recording never
  changes the exit status, and a passing run that records nothing says
  why. `pre-push` skips its gate only while HEAD equals the record and
  the tree is still strictly clean.
- `check-hooks` never fails and is silent with `CI=true`. Every worktree of
  a clone shares one hooks directory, so worktrees pinned to different
  devkit versions report each other's copies as stale.
- `git commit --no-verify` and `git push --no-verify` skip the gates once;
  CI stays the backstop.

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
  <version>0.4.0</version>
  <relativePath>.devkit/java/parent/pom.xml</relativePath>
</parent>
```

- Its version is the release tag without the `v` (`v0.4.0` → `0.4.0`),
  literal, never a property. A bump edits it together with `version` and
  `commit` in `devkit.toml`. The parent is published to no repository: the
  link is the only way to reach it.
- Every target that runs Maven (`check`, `install`, `lint`, `format`,
  `test`, `coverage`, `audit`, `clean`, and a consumer's own script that
  sources `scripts/lib/get_maven.sh`) first runs `python3_floor`, which
  exits 13 below python3 3.11, and then `scripts/java/parent_check.py`.
  That fails, with one `ERROR` line and exit status 14, when
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

## uv projects

`python-uv.mk` drives a uv project: a single package at the root, or a
virtual workspace root whose members are the packages. The project owns its
tool versions, through its `dev` dependency group, hash-locked in `uv.lock`,
and its tool configuration (ruff, vulture, pytest and coverage) in
`pyproject.toml`; devkit ships none and never passes `--config`. Its scripts
run the tools from `.venv`.

- Pins and drift. `.python-version` pins CPython and the `uv` package in
  `uv.lock` pins uv; neither is a profile variable. `make check` fails, one
  `ERROR` line with its remedy each, when `python3` is older than 3.11,
  when `COVERAGE_FLOOR` is unset or not a percent from 0 to 100, when
  `.python-version` is missing or no `major.minor[.patch]`, when `MODULES`
  holds a glob character or differs from the members `uv.lock` records,
  when the root `pyproject.toml` sets no `[tool.vulture] paths`, when no uv
  of the pinned version is found, when `.venv` is missing, when its Python's
  version differs from the pin (`major.minor`, or the patch too when the
  pin names one), when
  `uv sync --check --frozen --offline` cannot confirm `.venv` matches
  `uv.lock` (drift: run `make install`), and when a dev tool is missing
  from `.venv`. Before uv, it validates `devkit.toml`'s
  `[python.duplication]` (`duplication.py check-config`, see the
  copy-paste gate below).
- uv. `scripts/lib/get_uv.sh` exports `UV_CMD`, the first of: `uv` on
  `PATH` when it reports the pinned version and is not the one inside
  `.venv` (each `uv` on `PATH` in turn; a link to that one, or any file
  under `.venv`'s resolved path, counts as it); devkit's per-user copy,
  `${XDG_CACHE_HOME:-$HOME/.cache}/devkit/uv/<version>/bin/uv`. Only
  `make install` creates that copy, read-only, when it is missing: pip, in
  a throwaway venv of `python3`, installs the uv wheel `uv.lock` pins,
  verified against the lock's hashes. devkit never runs the uv inside
  `.venv`, and its targets always use the project's `.venv`: `get_uv.sh`
  unsets `UV_PROJECT_ENVIRONMENT`.
- `make install` runs `uv sync --locked --all-packages --all-extras`: it
  creates or repairs `.venv`, with the pinned CPython, which uv provisions
  when it is missing. It fails when `uv.lock` is stale against
  `pyproject.toml` (run `uv lock`), and never rewrites `uv.lock`. It has no
  `check` prerequisite: a drifted `.venv` fails `check`, and `install` is
  the repair.
- `make lint` runs, stopping at the first failure, `ruff check`,
  `ruff format --check`, vulture over the root `pyproject.toml`'s
  `[tool.vulture] paths`, which must be set, then the copy-paste gate.
  `ONLY` narrows the two ruff passes to the selected members; vulture and
  the copy-paste gate always scan the whole project.
- `make format` runs `ruff check --fix --exit-zero`, then `ruff format`, on
  the project or the `ONLY` selection: it rewrites and never judges.
- `make test` runs one pytest session per member of the selection, in the
  member's directory, with branch coverage (`--cov-branch`). Each
  session's combined statement and branch coverage must reach
  `COVERAGE_FLOOR`: per package, never combined. The project's pytest
  configuration activates coverage (e.g. `addopts = "--cov=src"`); a
  session that writes no coverage report fails. With `JUNIT_DIR` set
  (relative to the project root), each session writes
  `JUNIT_DIR/<name>.xml`, `<name>` being the member directory's last path
  component (for a single package, the project directory's name); two
  members of one name fail. `make test` does not
  lint; the full gate is `make lint test`.
- `make audit` runs pip-audit on the third-party runtime dependencies
  `uv.lock` pins (`uv export --no-default-groups`, the project's own
  packages and its local path dependencies left out, what they depend on
  kept), and passes, saying so, when there are none. It needs the network
  and fails closed without it; neither `check` nor `test` runs it.
- `make clean` removes `__pycache__`, `.pytest_cache`, `.ruff_cache`,
  `*.egg-info`, `dist`, `.coverage` and `.coverage.*` below the project
  root, skipping the root's `.git` and `.devkit`, every `.venv` and
  `node_modules`, and any directory holding a `.git` (a nested checkout).
- `ONLY` narrows `lint`'s ruff passes, `format` and `test`; `install`,
  `check`, `audit` and `clean` act on the whole project.
- The copy-paste gate, the last step of `make lint`, runs jscpd at the
  closure `jscpd/package-lock.json` pins, installed like markdownlint-cli
  (see `lint-md`) on first use, so it needs `node` at or above
  `engines.node` in `jscpd/package.json` and `npm` on `PATH`. It scans the
  Python files git lists (tracked, plus untracked ones the project does
  not ignore; the user's global excludes do not apply) under
  `devkit.toml`'s required `[python.duplication] paths`, project-relative
  directories or files inside the project root, each file once and none
  through a symlink, minus the optional `ignore` globs, which match
  project-relative paths (`src/b.py`) as well as `**/` patterns; a clone
  is a run of at least `min-tokens` tokens (default 50). jscpd gets the
  files on its command line, so no `.ignore` file applies and a list
  beyond the system's argument limit fails; it runs from an empty
  directory with an empty `HOME` and every setting on its command line, so
  no `.jscpd.json` applies. The accepted duplication is a ratchet: each
  `[[python.duplication.accepted]]` entry names a file pair (`files`, in
  any order) and a non-empty `reason`, and the gate fails, naming the pair
  and the lines jscpd reported, on every pair it finds a clone of that no
  entry accepts, and on every accepted pair it no longer finds. It first
  runs jscpd, with the default `min-tokens` and no `ignore`, on devkit's
  `jscpd/controls/`, and fails unless exactly the one duplicated pair there
  is found, and fails when jscpd writes no report. `make check` fails, one
  `ERROR` line with its remedy each, when the table or `paths` is missing,
  a path is absolute, leaves the project root or does not exist, git lists
  no Python file under `paths`, `min-tokens` is not a positive integer,
  `ignore` is not a list of strings without commas (jscpd splits on them),
  an entry has not exactly two `files` or no `reason`, a pair is accepted
  twice, or the table or an entry holds another key.
