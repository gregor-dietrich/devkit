# devkit consumer contract (v0.8.0)

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
| `mvnw`, `.mvn/wrapper/maven-wrapper.properties` | Maven, optional: the Maven wrapper, of any distribution type, for an IDE or a bare build; no devkit target runs it (see Parent POM) |
| `checkstyle-project.xml` | Maven: the project's own Checkstyle rules, at the root (see Maven configuration) |
| `checkstyle-suppressions.xml` | Maven: the project's Checkstyle exemptions, in every module, the root included; required (`<suppressions/>` when none) |
| `spotbugs-exclude.xml` | Maven: the project's SpotBugs exclusions, in every module with classes; required (an empty `<FindBugsFilter/>` when none) |
| `pmd-ruleset.xml` | Maven, optional: a module's own PMD ruleset that drops a rule of devkit's, beside the module's pom (see Parent POM) |
| `checkstyle-xpath-suppressions.xml` | Maven, optional: the project's Checkstyle XPath exemptions, in any module, read from that module's directory (see Parent POM) |
| `dependency-check-suppression.xml` | Maven: the project's dependency-check suppressions, at the root, read by `make audit` |
| `pyproject.toml` | uv: the package, or a virtual workspace root (no `[project]` table) whose members are the packages; its `dev` dependency group lists ruff, pytest, pytest-cov, vulture, pip-audit and uv, and `[tool.vulture]` sets `paths` (see uv projects) |
| `.python-version` | uv: the CPython version, `major.minor` or `major.minor.patch`, 3.11 or later |
| `uv.lock` | uv: committed; `make install` syncs `.venv` from it and never rewrites it |
| `.gitignore` entry `/.devkit` | The link `devkitw` creates; a uv project also ignores `/.venv` |
| `docs/decisions.md` | Optional: the project's decisions log, whose entry format `lint-decisions` checks (see Repository gates) |
| `.gitleaks.toml` | Optional: the project's gitleaks configuration, read by `lint-secrets` (see Repository gates) |
| `.gitleaksignore` | Optional: the fingerprints of gitleaks findings the project has triaged, read by `lint-secrets` |
| `.markdownlint.jsonc` | Optional: the project's markdownlint configuration, at the root; a `[markdown.profiles]` entry names another one per subtree (see Repository gates) |
| `.markdownlintignore` | Optional: the Markdown files `lint-md` skips, at the root |

```toml
[devkit]
url = "https://git.vptr.de/gregor/devkit.git"
# mirror = "https://github.com/<owner>/devkit.git"   # optional, when url is unreachable
version = "v0.8.0"
commit = "<40-hex commit the tag resolves to>"

# Required when FRONTEND_DIR is set; an empty table declares none.
[frontend.min-pins]
"some-package" = "1.2.3"
# quote names containing @, / or .: "@scope/name" = "1.2.3"

# Optional: the image namespaces the project publishes, and further YAML
# files lint-pins reads as workflows (Repository gates).
[pins]
first-party = ["registry.example/my-team"]
# extra = ["docs/probes/*.yml"]

# Optional: subtrees lint-md checks with a markdownlint configuration of
# their own instead of the project's (Repository gates).
[markdown.profiles]
".claude" = ".claude/.markdownlint.jsonc"
".agents" = ".claude/.markdownlint.jsonc"

# Required in a uv project: what make lint's copy-paste gate scans (uv projects).
[python.duplication]
paths = ["src", "tests"]          # the Python files git lists under these
# min-tokens = 50                 # optional, a positive integer
# ignore = ["**/migrations/**"]   # optional jscpd --ignore globs, no commas

# Optional, one per duplicated file pair the project accepts.
[[python.duplication.accepted]]
files = ["src/a.py", "src/b.py"]   # the same file twice for a clone within one file
max-tokens = 120                   # ceiling on the pair's clone tokens (make lint)
reason = "why this duplication is deliberate"

# Optional, one per function the project accepts an anchored regex match in.
[[python.anchored-match.accepted]]
file = "src/a.py"                  # project-relative
function = "parse_line"            # as the error line names it, or "<module>"
reason = "why the input cannot carry a newline"

# Optional, one per Python file the gate neither parses nor scans.
[[python.anchored-match.excluded]]
file = "src/fixtures/py2.py"       # project-relative, one file
reason = "why the file is not scanned"

# Optional, one per pip-audit advisory the project accepts (make audit).
[[python.audit.accepted]]
package = "some-package"           # as pip-audit reports it (uv.lock names it), any PEP 503 spelling
id = "GHSA-xxxx-xxxx-xxxx"         # the advisory's id or one of its aliases
reason = "why the advisory does not apply, or has no fix"
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
- `devkitw` carries a `# devkitw revision N` line; devkit raises N, once
  per release, whenever the file changes, and `lint-devkitw` fails while a
  project's copy is older than the pinned commit's.
- It fails closed, with one line naming the cause, on: missing or malformed
  `devkit.toml`, fetched commit ≠ `commit`, a `commit` that is not an
  ancestor of the same remote's `main`, a tag that is not an annotated tag
  of `commit`, named `version` and signed by devkit's release key, a cache
  hit whose recorded version ≠ `version`, a reachable `url` that serves no
  tag `version` or no `main` (it does not fall back to the mirror then),
  every remote unreachable or without them, no `ssh-keygen` of OpenSSH 8.1
  or later, and a `.devkit` that exists and is not a symlink. It never falls
  back to another version. Where `ssh-keygen` fails for another reason than a
  bad signature, the line is "ssh-keygen failed verifying tag …" with its
  first message.
- A cache miss verifies the tag with `ssh-keygen -Y verify` (principal
  `devkit-release`, namespace `git`) against the allowed-signers line
  `devkitw` carries. It reads no git signing configuration and needs no gpg.
  A cache miss needs the running UID to have a passwd entry, which
  `ssh-keygen` requires (a container run with an arbitrary `-u` UID); a hit
  does not.
- It never prompts, and runs no credential helper or askpass program: an
  HTTPS remote's credentials come from git configuration such as
  `http.<url>.extraHeader`, or from `~/.netrc`, and a remote that rejects
  them counts as unreachable. ssh runs in batch mode unless the
  environment sets `GIT_SSH_COMMAND`, which then brings its own prompting
  and timeouts.
- A dead connection does not hang a fetch: HTTPS aborts below 1000
  bytes/s for 20 seconds, and the default ssh command gives up on a connect
  after 10 seconds and on a server that stops answering its keepalives
  within about half a minute. A server that keeps answering while git
  stalls is not bounded.
- Two things are trusted. The release key decides which tags are releases;
  `main` on the remote that answers (`url`, or `mirror` when `url` is
  unreachable) decides which commits may be. A pinned commit needs both. The
  release key signs devkit's release tags and nothing else: a signature binds
  commit, type, tag name and namespace, not the repository. Past the first
  copy at adoption, which is trusted on first copy, a new release key reaches
  a project only in a `devkitw` that a release signed by the previous key
  delivered; a rotation release carries both keys' lines, every existing
  `v*` tag is re-signed with the new key at its same commit (so pinning back
  keeps working), and a consumer bumps through that release: a wrapper that
  knows only the old key refuses a tag signed only by the new one. Limits: a
  checkout cached by an older `devkitw` is not re-checked; a project's copy
  of `devkitw` predating the signature check accepts any tag on `main`, and
  one predating the `main` check accepts any tagged commit; a signature does
  not stop a tag's deletion; the tools `devkitw` runs (`git`, `ssh-keygen`,
  `sed`, `grep`, `head`, `tail`, `cut`, …) come from `PATH`; and a pin chosen
  to evade `lint-devkitw` brings its own gates, so only the wrapper's own
  checks hold against it.
- Every cache devkit fills under `${XDG_CACHE_HOME:-$HOME/.cache}/devkit/`
  (the checkout, and the tools below) is read-only, its directories
  included, so that an edit through `.devkit` or the cache fails instead of
  changing every project's gates. To remove one, as a message may ask, make
  it writable first: `chmod -R u+w '<dir>'; rm -rf '<dir>'`. Limits: this stops
  an accident, not a process of the same user, which can make an entry writable
  again, nor root (a root container, say), which a mode does not stop, and a
  cache hit is not re-verified. On a CI runner whose `HOME` persists between
  jobs (on the host rather than in a fresh container per job), any job can
  change what a later job's gates run, through these caches as through `~/.m2`
  or the user's git configuration; give each job its own `HOME`, and `chmod -R
  u+w` it before removing it. An entry cached by an older devkit keeps writable
  directories until it is removed. Nothing removes an entry a bump supersedes,
  nor the `.tmp.*` stage a fetch leaves when it is killed outright (SIGKILL, an
  OOM kill, a power loss). To reclaim the space, remove the whole cache with
  the recipe above, applied to `${XDG_CACHE_HOME:-$HOME/.cache}/devkit`, while
  no devkit run on the machine is in progress; each project's next run fetches
  what it pins again, the checkout needing the network and `ssh-keygen`.
  Removing a single entry is safe on the same terms, but "not pinned here" is
  not "unused": another project on the machine may pin it.
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
- `make/common.mk` sets `PROJECT_ROOT` to `$(CURDIR)`, so an inherited
  environment value never wins, not even under `make -e` (a command-line
  `PROJECT_ROOT=...` still does, and so does a project's own line after the
  include). Likewise a `MODULES`, `FRONTEND_DIR` or
  `JAVA_VERSION` inherited from the environment does not count as such
  (`python-uv.mk` does the same for `COVERAGE_FLOOR`, `java-maven.mk` for
  `FRONTEND_DIR` and `JAVA_VERSION`, so a uv project's recipes still see an
  inherited `JAVA_VERSION`): a project that omits one gets it empty, while a
  command-line value and `make -e` still count (not under `make gate`,
  below). A `MAKEFLAGS` or `GNUMAKEFLAGS` in the environment that carries
  `MODULES=x` counts as a command-line value, and a `MAKEFILES` file's
  assignment as a makefile one; `make gate` clears all three. Write the
  profile lines with `:=`, as the skeletons do, and never read the variable's
  earlier value: `?=` leaves the value empty when the environment sets the
  variable, and `+=` or `MODULES := $(MODULES) x` take the environment's
  value (`MODULES += a` with `MODULES=b` inherited yields `b a`). An empty
  `COVERAGE_FLOOR` fails `check` and `test`; an empty `JAVA_VERSION` fails
  every Maven target (`scripts/lib/mvn_checked.sh`); an empty `FRONTEND_DIR`
  means no frontend, so the frontend pin check is skipped silently: set it in
  the Makefile with `:=`; a `MODULES` left empty in a workspace is caught by
  `make check` only. `common.mk` strips `MODULES` of the
  blanks a trailing comment leaves (`java-maven.mk` strips `FRONTEND_DIR` and
  `JAVA_VERSION`), and exports `PROJECT_ROOT PROJECT JAVA_VERSION MODULES
  FRONTEND_DIR COVERAGE_FLOOR ONLY DEVKIT` to every recipe. In a Maven project
  `JAVA_VERSION` is the JDK major Maven must run on, exactly, a plain number
  (`25`): `check` and every lifecycle build enforce it (see Parent POM).
- `make/common.mk` sets `SHELL := /bin/bash`, so recipes (devkit's and the
  project's) and every `$(shell ...)` expanded after the includes run under
  non-interactive bash on every machine: bash 3.2 on macOS, and it sources
  `$BASH_ENV` first. A plain `SHELL` assignment before the includes is
  replaced; a project that needs another shell sets it directly after the
  includes, before any `$(shell ...)` it affects, or on the command line. A
  sub-make whose `Makefile` does not include `common.mk` keeps `/bin/sh`.
  `.SHELLFLAGS` stays make's default. `make gate` and every installed git
  hook remove every shell function they inherit before they run anything, so
  an exported one reaches none of the recipes they run (see
  [Git hooks](#git-hooks)).
- Targets: `common.mk` owns `help`, `check`, `check-devkit`, `check-hooks`,
  `hooks`, `gate`, `lint-repo`, `lint-devkitw`, `lint-pins`, `lint-decisions`,
  `lint-secrets`, `lint-md`, `format-md`, `branch`, `rebase`, `tag`,
  `untag`.
  `java-maven.mk` owns `check-java`, `install`, `lint`, `format`, `test`,
  `coverage`, `audit`, `clean`, `kill`. `python-uv.mk` owns
  `check-python`, `install`, `lint`, `format`, `test`, `audit`, `clean`.
  None defines project-only targets.
- `tag` signs and pushes a release tag at the tip of origin's default branch.
  A tag is `X.Y.Z`, optionally prefixed `v` and followed by `rcN` or `-rcN`
  (no leading zeros); anything else, `REVISION` included, is refused.
  `REVISION`, when set, is the tag, and there is no prompt. The suggestion
  is the highest such tag with its rc number, or else its patch,
  incremented, and none without one. Tags are ordered by git's version sort
  of the whole name, so a `v`-prefixed tag ranks above any bare one: a
  project keeps to one prefix. Before the prompt, and under `REVISION` too,
  it refuses unless HEAD is the tip as the remote reports it now and the
  working tree is clean, untracked files included. `untag` offers the
  highest such tag, an rc before its final, and no default without one.
- `branch` prompts for a target and a source (default `origin/main`), fetches,
  and creates the target at the source, or resets an existing one (local or
  only on origin) to it. It refuses first while tracked files have uncommitted
  changes and, through `git reset --keep`, where an untracked file is in the
  way. It then pushes the target, with `--force-with-lease` when origin has it.
  `rebase` prompts for a target (default `origin/main`), fetches, rebases the
  current branch onto it, and pushes nothing.
- `check`, `lint` and `format` are composed by prerequisites, never by two
  recipes: `common.mk` declares `check: check-devkit check-hooks`,
  `lint: lint-repo` and `format: format-md`; the language file adds
  `check: check-java` or `check: check-python` and carries the `lint` and
  `format` recipes, which run after the prerequisites. Only one rule line
  per target carries a `## description`.
- A project may add prerequisites to devkit's targets on a rule line of its
  own after the includes, without a `## description`:
  `install: frontend-manifest`, `test: test-scripts`, each declared
  `.PHONY` (a file of the same name would otherwise satisfy it without its
  recipe). Make runs them before the target's recipe, and a
  failing one fails the target before devkit's recipe runs. They are
  unordered relative to devkit's own prerequisites (`install: check` in
  `java-maven.mk`), which `make -j` may run alongside them. A project never
  gives a devkit target a recipe: make keeps the last recipe with only a
  warning, so it would silently replace devkit's gate.
- `check-devkit` fails when `.devkit` does not resolve to `$(DEVKIT)`.
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
  `make lint` runs the anchored-match gate's scan under `.venv`'s Python
  instead (see uv projects). Every helper runs with `python3 -I`; one that
  imports a sibling module puts its own directory first on `sys.path`, so
  `-I` or `PYTHONSAFEPATH` does not break it.
- They act on the project, never on devkit: `cd "$PROJECT_ROOT"` first, and
  resolve project files from `$PROJECT_ROOT`, devkit files from `$DEVKIT`.
- Shared helpers live in `scripts/lib/` and are sourced as
  `"$DEVKIT/scripts/lib/<name>.sh"`; the exception is `fetch.sh` and
  `pinned_maven.sh`, which source their siblings relative to themselves,
  because they also run without `DEVKIT` (`maven_checksums.sh`, the tests).
  `node_closure.sh` checks `node` against a devkit directory's `package.json`
  `engines.node` and installs that directory's `package-lock.json` closure
  once (see `lint-md`), for markdownlint-cli (`markdown/`) and jscpd
  (`jscpd/`).
- `MODULES` empty means a single module or package at the root (a Maven
  monolith, a single uv package); otherwise Maven module selection maps
  each listed module to `-pl` as the Java scripts document. For uv,
  `MODULES` lists the workspace member directories as `uv.lock` records
  them (e.g. `packages/core`), and `make check` fails when they differ.
  For Maven, `FRONTEND_DIR` is the directory holding the Vaadin frontend
  (its `pom.xml`, `package.json` and, when committed, `package-lock.json`):
  one of `MODULES`, or
  `.` in a monolith whose frontend is the project root; empty when there is
  none. `make check` fails on any other value.
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
  exports, with the keys of [Plugin checksums](#plugin-checksums)) for the
  local repository and the frontend module's `vaadin.version` and resolves
  the dev bundle. It fails without `MVN_CMD`.
- A Maven project's `make clean` runs `mvn clean` on the selection, then
  removes each selected module's `logs` and, when the frontend is selected,
  `FRONTEND_DIR`'s `node_modules` and `src/main/frontend/generated`. devkit
  never removes `package.json` or `package-lock.json`; what a clean goal
  bound in the project's own POM removes is the project's.

## Repository gates

`lint-repo` runs the language-neutral gates over the whole repository,
before the language gates of `make lint`; `ONLY` does not narrow it.
`lint-pins`, like every gate that reads a family of files, reads the files
git lists in `$PROJECT_ROOT` (tracked, plus untracked files that are not
ignored), fails when git cannot list them, and passes when none match.
`lint-devkitw` reads `devkitw` and `lint-decisions` reads
`docs/decisions.md` directly; `lint-secrets` reads git's history and
changes instead.

- `lint-devkitw` passes when the project's `devkitw` is byte-identical to
  `$DEVKIT/devkitw`, or its `# devkitw revision` line names a greater
  number (a project pinned back to an older release keeps its newer
  wrapper). Otherwise it fails with one `ERROR` line whose remedy is
  `cp .devkit/devkitw devkitw`, the wrapper the project's own has just
  verified. A copy without the line is revision 0. It reads both files as
  data and runs neither. Like every gate it is the pinned commit's own: it
  makes an honest bump deliver the wrapper, and cannot hold against a pin
  chosen to evade it; only the wrapper's own checks do.
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

  A file in none of them that a `devkit.toml` `[pins] extra` pattern
  matches is read as a workflow. A pattern is a git glob pathspec
  relative to `$PROJECT_ROOT` (`*` stops at `/`, `**/` crosses
  directories) ending in `.yml` or `.yaml`, and matches the `.yml` and
  `.yaml` files among those git lists.

  It requires every action as
  `owner/repo[/path]@<40 lowercase hex> # vX.Y.Z`, and every container
  image (Dockerfile `FROM`, `COPY --from=` and `# syntax=`; YAML `image:`,
  `container:` and a service's scalar value; `docker://`) as
  `<repository>:<tag>@sha256:<64 hex>`. Exempt: build stages and
  `scratch`; a `./` action whose `action.y{a,}ml`, or the reusable
  workflow it names, is a file it reads itself (a workflow outside the
  workflow directories is declared in `[pins] extra`); an action's
  `image:` that is a relative path to a Dockerfile, read itself too; and
  images under a namespace listed in `devkit.toml`'s optional
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
  a list or holds an entry that is not such a name, `extra` is not a list
  or holds an entry that is not such a pattern, and when git cannot list
  `$PROJECT_ROOT` (not a work tree, such as an unpacked source archive,
  or one git refuses for dubious ownership). An `extra` entry that is not
  a string, is absolute, has a `..` component, holds a NUL or does not
  end in `.yml` or `.yaml` is not such a pattern; one that matches no
  file stops it too, so a typo cannot drop the files it meant. A file it
  reads that is a symlink, or is not UTF-8, is a violation.
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
    scan also fails when gitleaks logs git's stderr at level `ERR` with
    `[git]`, then exits 0 having scanned part of it, or none; the few git
    warnings it logs through its own warning path without `[git]` (rename
    limit, automatic packing; from a reading of v8.30.1's sources) do not fail
    it. A git that ends without writing to stderr, killed by a signal for one,
    is not detected (#186), and the scan passes over the part it read. A
    line-ending warning (`LF will be replaced by CRLF`) is one: normalize the
    file's line endings, or commit it.
  - It stops with one `ERROR` line, before any scan, when `$PROJECT_ROOT`
    is not a git work tree, on a shallow clone, on a platform devkit pins
    no gitleaks build for (Linux and macOS, x86-64 and arm64 are pinned),
    when the download fails and when its sha256 differs from the pin.
    Before the first commit it skips the history scan.
  - `GITLEAKS_CONFIG` and `GITLEAKS_CONFIG_TOML` are ignored. git runs with
    `log.showRoot=true`, `color.ui=never`, `color.diff=never`,
    `diff.noprefix=false` and `core.quotePath=true` over the user's and the
    repository's configuration, which could otherwise hide the root commit or
    every line from gitleaks; git before 2.31 ignores these overrides, which
    matters only before the first commit. The rest of the configuration,
    `safe.directory` included, applies.
  - It needs curl (7.52 or later, which added `--retry-connrefused`), tar,
    `sha256sum` or `shasum`, and git 2.36 or later for the history scan; a
    failed download is retried up to three times, none decided later than 300
    seconds after the first attempt (the pause before it and the attempt
    itself come on top; with curl before 7.71 only a timeout, a refused
    connect or a transient HTTP error, not a dropped connection); the
    download is capped at 100M on any curl, like the pinned Maven's; the
    binary lands, read-only, in
    `${XDG_CACHE_HOME:-$HOME/.cache}/devkit/tools/gitleaks-<version>-<platform>/`.
  - The history scan runs `git log` with `--text` (a file `.gitattributes` marks
    `-diff` or `binary` is read as text), `--diff-merges=remerge` (it reads what
    a merge commit changes against git's own re-merge of its parents: a conflict
    resolution, or a change a clean merge adds) and `--no-textconv` (a textconv
    driver in any configuration does not rewrite what it reads); it needs git
    2.36 or later, and older git fails it, as does a read-only
    `.git/objects` once the history holds a merge (git writes the re-merge's
    objects to a temporary directory there; a merge-free history needs no write
    access). With gitleaks' default configuration a path its default allowlist
    names is skipped whatever its content, binary-marked or not (8.30.1 skips
    `*.png`, `*.pdf` and a path through `gitleaks.toml`, though not `*.zip`).
    Limits: staged and unstaged changes are read as `git diff` shows them, so
    a change to a file git treats as binary, or one a textconv driver
    rewrites, is scanned only once committed; gitleaks may still skip content
    it detects as binary (a NUL byte alone does not make it); untracked files
    are not scanned until they are staged; an octopus merge's (three or more parents)
    own lines are not read, as git skips it with a warning on stdout that the
    gate does not see; commit messages are not scanned, only the changes (#187).
  - A finding is either a secret, which is removed and rotated, or a false
    positive. History keeps a committed secret: once it is rotated, or for a
    false positive, copy the finding's `Fingerprint` from the gate's output into
    `.gitleaksignore`, one per line. A history finding's is
    `<commit>:<path>:<rule>:<line>`, except that the finding of a file that
    conflicted in a merge carries `b/` before its path,
    `<merge>:b/<path>:<rule>:<line>`, while any other change in a merge has the
    usual form, with one exception (#189): once a line of the merge's re-merge
    output contains the text `commit` (a conflicted path such as `commit.cfg`,
    or a parent subject a modify/delete conflict message quotes), gitleaks
    drops the commit from that finding and every later one in that merge's
    diff, which print `b/<path>:<rule>:<line>`, or `<path>:<rule>:<line>` for a
    file the merge adds after it; earlier findings keep the merge's form.
    Record either exactly as printed. gitleaks matches path rules and
    allowlist paths (`[allowlist]` and `[[allowlists]]` alike) in
    `.gitleaks.toml` against that same `b/<path>`, so anchor a path pattern
    with `^(b/)?`, e.g. `^(b/)?fixtures/`, not `^`; it also admits a real
    top-level `b/fixtures/`, and `(^|/)` would widen it to any depth
    (`(^|/)fixtures/` also suppresses `src/deep/fixtures/x`). A pattern that
    needs a directory before the name (`.+/fixtures/`) also matches a
    top-level conflicted file, and a real top-level `b/` directory makes the
    prefix ambiguous: a conflicted `f` and a change to `b/f` in one merge print
    the same fingerprint. A staged or unstaged finding's has no commit,
    `<path>:<rule>:<line>`. A fingerprint with a commit matches that one
    finding only, and a rewritten commit no longer matches it, so the finding
    comes back for triage; one without a commit (the staged and unstaged form,
    and #189's) matches that path, rule and line in every commit of history,
    later ones included. Prefer a fingerprint with a commit to a path allowlist
    in `.gitleaks.toml`, which applies to every commit in history as well.
- `lint-md` checks every listed `*.md` file that is not a symlink with
  markdownlint, from the closure `markdown/package-lock.json` pins (that of
  markdownlint-cli, which brings the library), installed with
  `npm ci --ignore-scripts` into
  `${XDG_CACHE_HOME:-$HOME/.cache}/devkit/tools/` on first use (the only
  run that needs the network). devkit runs `npm audit` over that lockfile
  weekly and before each release, so a project need not audit the closure
  itself. `format-md`, part of `make format`, runs its `--fix` over the
  same files and rewrites without judging: it prints what
  markdownlint cannot fix with a `NOTE`, since `make lint` fails on those,
  and passes, so `make format` goes on to the language formatter (an error
  of markdownlint's own still fails it). Both need `node` at or above
  `engines.node` in `markdown/package.json` and `npm` on `PATH`. The
  configuration is per file: its subtree's profile from
  `[markdown.profiles]` in `devkit.toml` (the longest subtree that holds the
  file wins), else the project's `.markdownlint.jsonc`, else
  `markdown/markdownlint.jsonc`. Each is JSONC, and its `extends` chain is
  followed, each path relative to the file that names it: the project's
  file may start with `"extends": ".devkit/markdown/markdownlint.jsonc"`, a
  profile at `.claude/.markdownlint.jsonc` with
  `"extends": "../.devkit/markdown/markdownlint.jsonc"`. A subtree and a
  profile are relative, normalized paths without `..`, a profile an existing
  `.jsonc` file; `lint-md` stops with one `ERROR` line when `devkit.toml` is
  not valid TOML, `[markdown]` holds a key other than `profiles`,
  `profiles` is not a table, a path is not valid or a profile is missing, or
  a subtree holds no Markdown file `lint-md` checks, so a typo cannot send its
  files to the default profile. `.markdownlintignore` excludes files. Each
  first runs markdownlint on devkit's control files and fails unless they
  pass and fail as expected.

  `lint-md` lints with markdownlint's library through `markdown/lint.mjs`,
  which reads exactly that one configuration file and its `extends` chain: no
  `.markdownlintrc`, `/etc` file, `HOME` file, `markdownlint_*` variable or
  other `.markdownlint.*` file applies.

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
- `pre-commit` runs `make lint-repo` with `MAKEFLAGS`, `MFLAGS`,
  `GNUMAKEFLAGS`, `MAKELEVEL` and `MAKEFILES` cleared, so a commit from inside
  a make recipe cannot let a failing stage pass.
- Neither `ONLY` nor an outer make's flags narrow `pre-push`'s gate: it runs
  `make lint-repo test` with `ONLY` unset (it says so) and `MAKEFLAGS`,
  `MFLAGS`, `GNUMAKEFLAGS`, `MAKELEVEL` and `MAKEFILES` cleared, as
  `make gate` does. It warns on, but still runs under, `MAVEN_ARGS`,
  `MAVEN_BASEDIR` (Maven's project directory, where `.mvn/` and the
  parent's gate configurations are read from), `MAVEN_DEBUG_OPTS` (any
  value counts: it is for mvnDebug's debugger, and the launcher hands it
  to java), `PYTEST_ADDOPTS`, `PYTEST_PLUGINS`, `PYTHONOPTIMIZE`,
  `COVERAGE_RCFILE`, `COVERAGE_FORCE_CONFIG`, `BASH_ENV`, a JVM option that
  can skip tests (see below) in `MAVEN_OPTS`,
  `JAVA_TOOL_OPTIONS`, `JDK_JAVA_OPTIONS`, `_JAVA_OPTIONS`,
  `OPENJ9_JAVA_OPTIONS` or `IBM_JAVA_OPTIONS`, a mavenrc file Maven runs
  (`/usr/local/etc/mavenrc`, `/etc/mavenrc` or `~/.mavenrc`, unless
  `MAVEN_SKIP_RC` is set), a
  `~/.m2/settings.xml` that defines profile properties (`<properties>`
  outside XML comments) or an `<activeProfile>` naming no profile that
  file defines (Maven activates a profile of that id from the project's
  POM; every `<id>` in its `<profiles>` section counts as defined, and
  without one every `<activeProfile>` counts), a `~/.m2/extensions.xml`
  (any regular file, not a directory: Maven loads its core extensions, code
  in its JVM, whatever `MAVEN_SKIP_RC` says) and
  an ignored `.mvn/maven.config`, `.mvn/extensions.xml` or `.mvn/jvm.config`
  (Maven reads them whether git tracks them or not; `.mvn/wrapper/` does
  not count), a file pytest reads that git ignores (see below), and a
  committed POM profile that depends on ambient state (see
  below), which are often set on purpose.
  A JVM option that can skip tests is a word of the variable, found after
  every `"` and `'` is removed, at its start or after whitespace. Java strips
  quotes inside the JVM's own variables (`JDK_JAVA_OPTIONS`,
  `JAVA_TOOL_OPTIONS` ...); in `MAVEN_OPTS`, which the launcher word-splits,
  a quote stays literal, so removing every quote first can only over-count.
  The launcher of devkit's Maven or its JVM reads these variables. A word
  counts when it:
  - starts with `-D` or `@` (an `@argfile`), `-XX:VMOptionsFile=` or
    `-Xoptionsfile=` (OpenJ9) (an options file, which can set a `-D`),
    `-XX:Flags=` (a flags file), or `-javaagent:`, `-agentpath:`,
    `-agentlib:` or `-Xrun` (they load code into Maven's JVM, like the
    user-level core extensions);
  - is one of the options that end java without running its main class
    (the stage then exits 0 with no test run) or run another one instead,
    alone or followed by `=` (as `--module=x` is): `-version`, `--version`,
    `-fullversion`, `--full-version`, `-Xinternalversion`, `-help`,
    `--help`, `-h`, `-?`, `-X`, `--help-extra`, `--dry-run`,
    `--list-modules`, `-d`, `--describe-module`, `--validate-modules`,
    `-Xshare:dump`, `-XX:AOTMode=create`, `-XX:+PrintFlagsInitial`,
    `-XX:+PrintSharedArchiveAndExit`, `-XX:+JVMCIPrintProperties`, `-jar`,
    `-m` and `--module` (checked against JDK 25);
  - or, when it is none of those, has the form `-...:help` or `-...=help`
    (`-Xlog:help`, `-XX:StartFlightRecording:help`), which prints help and
    exits. A `-D...=help` is reported as `-D`.

  The message names the option without a trailing `:` or `=`, never the
  value; a help word is named whole, as its value is the literal `help`.
  `-showversion`, `-Xmx`, `-Xshare:auto`, `-XX:AOTMode=auto`,
  `-XX:+PrintFlagsFinal`, `-XshowSettings`, `-Xlog:gc`, `-verbose:gc`,
  `--add-opens`, `-ea` and a `-D` inside a word (`-XX:-DisableExplicitGC`)
  do not count. The match runs under `LC_ALL=C` (the stages keep their
  locale), and a bash that cannot compile the patterns is detected before
  the check: `pre-push` says so and `make gate` records nothing.

  The POMs in scope are the root `pom.xml`, every POM a `<module>` names
  (in a profile, too) and every parent a `<parent>` reaches through its
  `<relativePath>` (default `../pom.xml`) inside the project, each followed
  transitively; a parent outside the project is not read. They depend on
  ambient state when:
  - a POM in scope is not tracked by git (untracked or ignored);
  - a `<module>` uses a property (`${...}`), or names an existing directory
    outside the project;
  - `.mvn/maven.config` selects another root POM (`-f`, `--file`);
  - a POM holds a processing instruction other than its XML declaration;
  - an `<activation>` names an environment variable (`env.X` or `!env.X`)
    that is set and not empty (Maven reads an empty one as unset here), a
    name that is not a shell identifier, or a property `<name>` or `<value>`
    that uses a property (Maven interpolates both);
  - or an `<activation>` has an `<exists>` or `<missing>` path that uses
    `${env.X}` while X is set, even empty (Maven substitutes an empty value
    in a path); that uses a property other than `${env.X}`, `${basedir}`,
    `${project.basedir}`, `${project.rootDirectory}` and `${user.home}`;
    that holds a `\`, a `..` part or a trailing `/` (Maven normalises
    them); or that exists and git does not track (outside the project, or
    untracked or ignored inside it, but never the work tree's `.git`; `*`
    and `?` are literal, as they are to Maven). Maven resolves a relative
    path, `${basedir}` and `${project.rootDirectory}` per project it
    evaluates the profile for, which for a parent's profile is each module,
    so the path is tried against the directory of every POM in scope.

  Whitespace and attributes in the tags are read as Maven reads them. The
  scan is a static reading, not Maven's model builder: forms only a
  deliberate setup reaches are accepted misses (#150): a symlink, XML
  entities and CDATA, an attribute value holding `>`, a POM reached only
  through a parent outside the project, a variable whose value is only
  newlines, a crafted `CDPATH`, a non-UTF-8 POM naming a non-ASCII path and
  a path with an internal newline. A scan that cannot read a POM or ask git
  fails closed: `make gate` records nothing and `pre-push` warns.

  The message names the POM and the variable, module or path as written,
  never a value. The JDK, the operating system and the JVM's own system
  properties are the machine's, which `pre-push` runs on too, not ambient: a
  profile they activate does not count, and a `-D` one is a JVM option
  above.

  The files pytest reads whether git tracks them or not count only in a project
  with a tracked root `pyproject.toml`. A pyproject directory is the nearest
  directory holding a tracked `pyproject.toml`. In every pyproject directory and
  each directory above it up to the top level (`make test` starts a session in
  each member's directory, and pytest searches upward) these count: the
  configuration files `pytest.toml`, `.pytest.toml`, `pytest.ini`,
  `.pytest.ini`, `pyproject.toml`, `tox.ini` and `setup.cfg`, and coverage's
  `.coveragerc` and `.coveragerc.toml`; and a `conftest.py`, whatever its path
  components are, because pytest loads every ancestor `conftest.py` of the
  session directory at startup. Below a pyproject directory, every `conftest.py`
  and every test module matching pytest's default `python_files` (`test_*.py`,
  `*_test.py`) counts, except one below a directory pytest does not enter: one
  its default `norecursedirs` skips (`.*`, `venv`, `build`, `dist`,
  `node_modules`, `*.egg`, `_darcs`, `CVS`, `{arch}`), `__pycache__`, or a
  virtual environment (a directory holding a regular file `pyvenv.cfg` or
  `conda-meta/history`). A pyproject directory's `test*/conftest.py` always
  counts, as pytest loads it at startup; a test module has no ancestor or
  `test*/` rule, since pytest collects it (an ignored one can patch the code
  under test by its import, and its tests lift coverage). A `pyvenv.cfg` or
  `conda-meta/history` counts too when the directory it makes a virtual
  environment is not the top level, is not below a directory pytest does not
  enter (nor named like one) and holds a tracked file, which a real environment
  never does: pytest skips any directory holding either file, so an ignored one
  deselects the tracked tests inside it. The project's own `norecursedirs`,
  `testpaths`, `python_files` and `collect_ignore` are not read, so a
  `conftest.py` they skip still counts. Accepted misses (#157): a `conftest.py`
  in a directory only a project setting makes pytest collect, a committed
  setting that names an ignored file (`--cov-config`, `-p`, `pythonpath` or a
  data path in `addopts`), which the screen does not parse, a test module
  matching only the project's own `python_files`, configuration above the top
  level, a path through a symlink or inside a nested repository (an ignored
  nested repository does not count), an ignored module that tests, a
  `conftest.py` or a plugin imports, a `sitecustomize.py` in a `PYTHONPATH`
  entry, a crafted `.pyc` whose recorded source mtime and size match, or one
  under `PYTHONPYCACHEPREFIX`, a pytest older than 8.3.2 (before 8.3.0 its
  virtual-environment test looks for `bin/activate*`, and 8.3.0 and 8.3.1 read
  only `pyvenv.cfg`, so it enters a directory holding only a marker it does not
  read, whose `conftest.py` the screen drops), and, on a case-insensitive
  filesystem or under `core.ignoreCase`, a name that differs from a screened one
  only in case. A screen that cannot ask git, or meets a tracked
  `pyproject.toml` path holding a newline, fails closed: `make gate` records
  nothing and `pre-push` stays silent (the `.mvn/` screen above fails the same
  way when git cannot list its files). Both screens neutralise the four
  `GIT_*_PATHSPECS` variables for the git calls that rely on pathspec magic, and
  an exported `BASHOPTS=nocasematch` does not fold their matches.

- `make gate` and every installed hook remove every shell function they
  inherit before they run anything: one exported into the environment
  (`export -f`, which bash passes on as a `BASH_FUNC_<name>%%` variable that
  every bash it starts imports) and one `$BASH_ENV` defined. No function then
  replaces git or another command in their screens, nor, since none is
  exported any more, a command in a recipe they run: a recipe that calls an
  exported function fails under `make gate`, `pre-commit` and `pre-push` where
  a plain `make` finds it. Every installed hook asks git for the top level
  past any function (`command git`), so no function can let `pre-push` pass
  without a gate. `$BASH_ENV` itself still applies to every recipe, and it ran before
  the removal, so `make gate` records nothing while it is set (any value
  counts: bash expands it before sourcing it) and `pre-push` warns on it when
  it runs its gate; a function that cannot be removed (a `readonly -f` one)
  counts the same way, and `pre-push` then runs its gate on a recorded HEAD
  too.

- `make gate` runs the push gate, `make lint-repo test` with `MAKEFLAGS`,
  `MFLAGS`, `GNUMAKEFLAGS`, `MAKELEVEL` and `MAKEFILES` cleared, so an outer
  `make -i`, `-k`, `-n` or `-o` cannot reach a stage (a command-line
  `VAR=value` still reaches the stages' environment, except that a profile
  variable (`MODULES`, `FRONTEND_DIR`, `JAVA_VERSION`, `COVERAGE_FLOOR`)
  counts under `make gate` only from the Makefile: with `MAKEFLAGS` cleared,
  a command-line `make gate MODULES=x` or `make -e gate` reaches the inner
  make as inherited and is ignored), and refuses `ONLY`.
  Before the stages it removes the old record. When they pass, it records HEAD
  in `git rev-parse --git-path devkit-verified-head` (per worktree), but only
  if the project is the git top level, HEAD has a commit, the tree was
  strictly clean at the start and at the end (no change, no untracked file, no
  dirty submodule, no assume-unchanged or skip-worktree entry; ignored files
  are fine; `git status` runs with `core.fsmonitor` and `core.untrackedCache`
  off, without the optional index lock and with replace refs
  (`refs/replace/`, in a submodule too) off, and a second time against a
  throwaway index read from HEAD (kept in the git directory, and read without
  hooks), so git hashes every tracked file anew and a stat that a
  since-removed clean filter validated hides no edit; a submodule's own index
  is not re-read that way; `make gate` unsets git's local environment
  variables, as `pre-push` does, so neither an fsmonitor hook nor injected
  `GIT_CONFIG_PARAMETERS` can hide a change; the unset reaches the stages too,
  so a `safe.directory` or other setting supplied only through
  `GIT_CONFIG_COUNT`, `GIT_CONFIG_KEY_<n>` and `GIT_CONFIG_VALUE_<n>` is lost
  to them, and a stage such as `lint-secrets` can fail on dubious ownership
  under `make gate` where `make lint-repo` passes: set it in the global or
  system git config), no tracked file's `filter` attribute names a driver with
  `filter.<driver>.clean` or `.process` configured and none has the `ident`
  attribute set (git reads such a file through the filter, or collapses
  `$Id: ... $` to `$Id$`, which can make an edit read as clean, in an
  initialized submodule against its own configuration too; a project that
  tracks files through git-lfs therefore gets no record, and `pre-push` runs
  its gate; checked at both ends too), no gitlink lacks a `.gitmodules` entry
  (`git submodule` cannot list its filters, so an embedded repository added
  with `git add` gets no record until it has an entry or `git rm --cached
  <path>` removes it), HEAD did not move during the run (detected through HEAD
  and its reflog, so a move away and back counts, and no reflog means no
  record), the
  ref backend is not reftable, and none of `MAVEN_ARGS`, `MAVEN_BASEDIR`,
  `MAVEN_DEBUG_OPTS` (any value counts), `PYTEST_ADDOPTS`,
  `PYTEST_PLUGINS`, `PYTHONOPTIMIZE`, `COVERAGE_RCFILE`,
  `COVERAGE_FORCE_CONFIG`, `BASH_ENV`, a JVM option `pre-push` warns on above in
  `MAVEN_OPTS`, `JAVA_TOOL_OPTIONS`, `JDK_JAVA_OPTIONS`, `_JAVA_OPTIONS`,
  `OPENJ9_JAVA_OPTIONS` or `IBM_JAVA_OPTIONS`, a mavenrc file Maven runs
  (`/usr/local/etc/mavenrc`, `/etc/mavenrc` or `~/.mavenrc`, unless
  `MAVEN_SKIP_RC` is set) and a `~/.m2/settings.xml` that defines profile
  properties or activates a profile it does not define, or a regular file
  `~/.m2/extensions.xml`, is present, git ignores none of `.mvn/maven.config`,
  `.mvn/extensions.xml` and `.mvn/jvm.config`, none of the pytest files above is
  one git ignores, no POM in scope depends on ambient state, as above (all
  three checked at the start and again at the end of the run, as the tree state
  is), and it removed every shell function it inherited. Recording never
  changes the exit status, and a passing run that records nothing says why.
  `pre-push` skips its gate only while HEAD equals the record, it removed
  every shell function it inherited, the tree is still strictly clean (read as
  above) and no clean filter or `ident` attribute applies to a tracked file.
- `check-hooks` never fails and is silent with `CI=true`. Every worktree of
  a clone shares one hooks directory, so worktrees pinned to different
  devkit versions report each other's copies as stale.
- `git commit --no-verify` and `git push --no-verify` skip the gates once;
  CI stays the backstop. The screens in the hooks and in `make gate` guard
  against state set for another reason or by accident, not against a
  developer who evades them on purpose: `git push --no-verify` bypasses
  `pre-push`, and a hook can be edited or removed.

## Maven configuration

Shared gate configs live in `java/config/` (`checkstyle.xml`, `pmd-ruleset.xml`,
`eclipse-formatter.xml`, `spotbugs-baseline.xml`,
`findsecbugs-crlf-jboss-logging.txt`). devkit's [parent POM](#parent-pom) reads
them as `${maven.multiModuleProjectDirectory}/.devkit/java/config/<file>`; PMD
reads a filtered copy of `pmd-ruleset.xml` (see [Parent POM](#parent-pom)).
Project-specific files (`dependency-check-suppression.xml`,
`spotbugs-exclude.xml`, `checkstyle-suppressions.xml`, `checkstyle-project.xml`,
and a module's own optional PMD ruleset) stay in the project.

SpotBugs runs at threshold `Low` with find-sec-bugs' security detectors
(`com.h3xstream.findsecbugs:findsecbugs-plugin` at `findsecbugs.version`) beside
its own, and reads devkit's `spotbugs-baseline.xml` and then the module's own
`spotbugs-exclude.xml`. devkit's excludes only
`THROWS_METHOD_THROWS_RUNTIMEEXCEPTION`, which reports every rethrow of a caught
`RuntimeException` (PMD's `AvoidThrowingRawExceptionTypes` still rejects a
`throw new RuntimeException(…)`), and find-sec-bugs' `JAXRS_ENDPOINT`, which
marks every JAX-RS method annotated `@Path` for a security review rather than
reporting a defect. The baseline admits a find-sec-bugs pattern only if it
reports a construct rather than a defect and fires at threshold `Low` on a
construct the stack assumes. Every other finding, find-sec-bugs' included, is
fixed, or excluded as narrowly as it stands: in the module's
`spotbugs-exclude.xml` by pattern and class or method, or with
`@SuppressFBWarnings`. A project that sets `excludeFilterFile` itself replaces
both files, devkit's exclusions included. SpotBugs keeps the plugin's heap and
time limits (`maxHeap`, 512 MB, and `timeout`, 10 minutes); a project that needs
more sets `<maxHeap>` or `<timeout>`.

find-sec-bugs ships no log-injection sinks for JBoss Logging, the facade
devkit's Checkstyle prescribes, or for Quarkus' `io.quarkus.logging.Log`, so the
parent hands it `findsecbugs-crlf-jboss-logging.txt` through SpotBugs'
`<systemPropertyVariables>`, as the property
`findsecbugs.injection.customconfigfile.CrlfLogInjectionDetector`: a call on
`org.jboss.logging.Logger`, `org.jboss.logging.BasicLogger` or
`io.quarkus.logging.Log` that logs a value the analysis cannot trace to a
constant is a `CRLF_INJECTION_LOGS` finding. find-sec-bugs matches the type the
call names, so a call through any other type, a `@MessageLogger` interface for
one, is not covered. A project that adds sinks of its own sets that property to
the parent's value and its own entries, joined with `:`; the parent check
refuses a value without the parent's entry, a
`<systemPropertyVariables combine.self="override">` without it, and a
`<jvmArgs>` that sets the property, since each drops the sinks. SpotBugs splits
its plugin list, and find-sec-bugs its sink files, on `:`, so in a project path
containing one find-sec-bugs would silently not load: the parent check refuses
such a path.

An analysis error, a detector failing on a class, is written to
`target/spotbugsXml.xml` but does not fail the check; devkit accepts that risk:
find-sec-bugs builds against an older SpotBugs plugin API than the analyzer
devkit pins, and devkit's own tests fail on an analysis error only for the code
shapes its two fixtures hold.

A rule that names a class, helper or field the project writes belongs to
the project, not to the shared configs: PMD's UnitTestShouldIncludeAssert runs
with its defaults, and a project names its own assertion helpers in the
`pmd.extraAssertMethodNames` property ([Parent POM](#parent-pom)). The shared
configs do keep the stack's conventions: JBoss Logging as the facade, a
static `LOG` logger field, `jakarta.annotation.Nullable`, and failsafe's `*IT`
names for integration tests, which Checkstyle's `AbbreviationAsWordInName`
accepts. A project's own
Checkstyle rules live in `checkstyle-project.xml` at the project root, a
complete Checkstyle configuration (a `Checker` root). The parent runs it as
the checkstyle plugin's execution `project`, with its own `configLocation`,
`cacheFile` and `outputFile`, and the shared config at plugin level.

`make lint` runs `checkstyle:check` and `checkstyle:check@project`. The
execution's `check` goal binds to `verify` by default, so `make test`,
`make coverage` and `make install` run the project's rules too. The
execution inherits the plugin-level `propertyExpansion`, so a
`SuppressionFilter` on `${org.checkstyle.google.suppressionfilter.config}`
reuses the project's `checkstyle-suppressions.xml`; the shared config's
optional `SuppressionXpathFilter` likewise reads
`checkstyle-xpath-suppressions.xml` from each module's directory, when the
file exists. A project with no rules
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
  <version>0.8.0</version>
  <relativePath>.devkit/java/parent/pom.xml</relativePath>
</parent>
```

- Its version is the release tag without the `v` (`v0.8.0` → `0.8.0`),
  literal, never a property. A bump edits it together with `version` and
  `commit` in `devkit.toml`. The parent is published to no repository: the
  link is the only way to reach it.
- Every target that runs Maven (`check`, `install`, `lint`, `format`, `test`,
  `coverage`, `audit`, `clean`, and a consumer's own script that sources
  `scripts/lib/get_maven.sh`) runs the Maven that `scripts/lib/pinned_maven.sh`
  pins (the version and the SHA-256 of its distribution tarball live there),
  never `mvn` on `PATH` and never `./mvnw`. The first such target on a machine
  downloads it from the first entry of `DEVKIT_MAVEN_MIRROR` that serves it,
  which needs curl, tar, and `sha256sum` or `shasum`, refuses it unless the
  SHA-256 matches, and keeps it, read-only, in
  `${XDG_CACHE_HOME:-$HOME/.cache}/devkit/tools/maven-<version>/`; later runs
  need no network for it. `DEVKIT_MAVEN_MIRROR`, an environment variable, is an
  ordered list of Maven repository base URLs separated by spaces, tabs or line
  breaks. Unset, empty or blank, it is devkit's default list:
  `https://maven.vptr.de/central` (devkit's own),
  `https://maven-central.storage-download.googleapis.com/maven2` (Google's
  mirror of Central), `https://repo.maven.apache.org/maven2` (Central). A value
  replaces that list whole; `https://repo.maven.apache.org/maven2` alone asks
  Central only. Every Java target validates the value, not only a download: no
  `@` anywhere, and each entry `https://`, a non-empty host and an optional
  path, with no `?`, `#`, whitespace or control character, and it is refused
  otherwise without being printed. devkit prints the URLs on a download and in
  `make check`'s report, so they must hold no secret anywhere, a path token
  included. The download tries the entries in turn: any failed download moves to
  the next entry, a 404 included, since the SHA-256 decides whichever entry
  serves it, and a SHA-256 mismatch fails at once without trying the next. Only
  the last entry's download is retried, up to three times as for gitleaks
  (Repository gates); an earlier entry gets one attempt, which costs up to about
  10 seconds when it never answers, and up to 300 when it accepts and stalls.
  `make check`'s report of outdated version pins
  (`scripts/java/version_check.py`) reads each artifact's `maven-metadata.xml`
  from the same list, names it in its header, and validates the value at least
  as strictly (it splits on the same three separators, and its `\s` also refuses
  non-ASCII whitespace and U+001C to U+001F within an entry). A lookup moves to
  the next entry when one gives no answer, times out, breaks off its answer, or
  answers with a 5xx status or 429; any other answer, a 404 included, is final
  for that artifact, so an artifact one entry lacks is never fetched from the
  next. An entry that gave no answer, timed out or broke off its answer is
  skipped for the rest of the run, with a line naming it; with one entry, the
  remaining pins land under "Could not check" at once. A 5xx or 429 does not
  skip the entry, so one that answers slowly costs that time on every lookup.
  Each lookup gives up on an entry after 60 seconds of wall clock, or once its
  metadata passes 1 MiB, and a pin with an artifact no entry serves lands under
  "Could not check". One run's answers can come from several entries, and a
  mirror that caches metadata can delay an outdated line, or print a false
  "ahead" line, by its cache lifetime. By default, a download and every
  `make check` ask devkit's host first, Google's mirror only when that fails as
  above, and Central last. `DEVKIT_MAVEN_MIRROR` steers only these two: Maven's
  own resolution of plugins and dependencies follows Maven's settings
  (`~/.m2/settings.xml`, `-s` or `-gs` in `.mvn/maven.config`). Authenticated
  mirrors and air-gapped seeding are unsupported (#134). The pinned-Maven
  download is capped at 100M per download on any curl; a larger one fails like
  any failed download. The pin and the cache path stay. A cache entry without a
  launcher fails with the command that removes it, for a retry. A project's
  `mvnw` is optional, of any distribution type, for an IDE or
  a bare build. `get_maven.sh` first adjusts `MAVEN_OPTS` for the JDK Maven runs
  on (`$JAVA_HOME/bin/java`, else `java` on `PATH`; the probe follows the
  caller's `JAVA_HOME`, so one set in `/etc/mavenrc` or `~/.mavenrc` is not
  seen), then runs `python3_floor`, which exits 13 below python3 3.11, then
  `scripts/java/parent_check.py`, and only then the download, so a bad python3
  or parent fails offline. That fails, with one `ERROR` line and exit status 14,
  when
  - the project's path contains `:`, on which SpotBugs splits its plugin list,
    so find-sec-bugs would silently not load;
  - the root pom's `<parent>` is not devkit's;
  - the `<relativePath>` of the root pom, or of any module pom
    (`<modules>`, recursively, profiles included) whose `<parent>` is
    devkit's, is not exactly the path from that pom's directory to
    `.devkit/java/parent/pom.xml`: `.devkit/java/parent/pom.xml` for the
    root pom, `../.devkit/java/parent/pom.xml` for `app-api/pom.xml`;
  - the `<version>` of any of those poms is not `devkit.toml`'s `version`
    without the `v`, or the pinned checkout's parent POM declares another
    version (a defective release);
  - any of those poms has no `<groupId>` of its own: it would inherit
    `de.vptr.devkit`, for its artifacts and for NullAway's default
    packages;
  - the root pom or any module pom (`<modules>`, recursively, profiles
    included) defines one of the parent's `*.version` properties: a
    partial migration. To try another tool version, pass it on the command
    line (`mvn -Dcheckstyle.version=… verify`) instead, which is
    unchecked as a bare build is; through `MAVEN_ARGS` or
    `.mvn/maven.config` the targets run it too, but the version is
    unrecorded and so unchecked ([Plugin checksums](#plugin-checksums));
  - any of those poms sets `maven-compiler-plugin`'s `<compilerArgs>` or
    `<annotationProcessorPaths>`, or spotbugs-maven-plugin's `<plugins>`,
    without `combine.children="append"` or with `combine.self="override"`, or
    sets `combine.self="override"` on spotbugs-maven-plugin's `<configuration>`;
  - any of those poms sets spotbugs-maven-plugin's `<systemPropertyVariables>`
    property `findsecbugs.injection.customconfigfile.CrlfLogInjectionDetector`
    to a value that does not keep the parent's entry among its `:`-separated
    parts, overrides `<systemPropertyVariables>` without keeping it, or sets
    that property in `<jvmArgs>`.
- maven-enforcer-plugin (execution `environment`, goal `enforce`, at `validate`)
  checks the environment with two rules. `requireJavaVersion` holds the JDK
  Maven runs on to `devkit.jdk.range`, default `[0,)`, any JDK; make passes
  `-Ddevkit.jdk.range=[N,N+1)` for the project's `JAVA_VERSION` N, so under make
  that JDK is required exactly, and the message names `JAVA_VERSION` and
  `JAVA_HOME`. `requireMavenVersion` holds Maven to `devkit.maven.range`,
  default `[3.9.9,)`, the floor of a bare or IDE build. The default goes no
  lower because Maven 3.9.8 built Quarkus projects that passed the build and
  failed at runtime. An override is the project's call, and lowering it is at
  its own risk; it must still admit the pinned Maven, which passes at the
  default. `make check` runs the execution directly (`enforce@environment`),
  which resolves the enforcer's closure: on a cold `~/.m2` it needs Central or
  the project's mirror, and a resolution failure shows as exit 11 too, as does
  a failed rule.
  `install`, `lint`, `test` and `coverage` enforce it at `validate`; `clean`,
  `format`, `audit` and a bare goal do not. `devkit.jdk.range` is no override
  point: the command line beats the POM. Nor do `enforcer.skip`, `enforcer.fail`,
  `enforcer.skipRules` or `enforcer.rules` reach the execution, whatever a
  project set them to for its own executions. A project that declares the
  plugin itself keeps its own executions beside this one, which merges by id.
- It pins every gate tool's version, and flatten-maven-plugin's,
  maven-enforcer-plugin's and maven-resources-plugin's, as a property
  (`checkstyle.version`, `checkstyle-plugin.version`,
  `compiler-plugin.version`, `dependency-check-plugin.version`,
  `eclipse-formatter.version`, `enforcer-plugin.version`,
  `error-prone.version`, `findsecbugs.version`, `flatten-plugin.version`,
  `jacoco-plugin.version`, `license-plugin.version`, `nullaway.version`,
  `pmd-plugin.version`, `resources-plugin.version`,
  `spotbugs-plugin.version`, `spotbugs.version`, `spotless-plugin.version`,
  `surefire-plugin.version`), and manages the
  `org.jacoco` artifacts at the JaCoCo plugin's version, so Quarkus' own
  JaCoCo matches the plugin's. `spotbugs.version` is the analyzer
  `spotbugs-plugin.version` runs, which SpotBugs is told to use as a plugin
  dependency; the parent manages `com.github.spotbugs:spotbugs-annotations`
  at it, in scope `provided`, so a project that uses `@SuppressFBWarnings`
  (with a `justification`, a convention the gates do not check), the
  in-source alternative to `spotbugs-exclude.xml`, declares that artifact
  without a `<version>` or `<scope>`; a literal version or scope, or one
  behind a property of another name, overrides the parent's (a project
  property named `spotbugs.version` fails `parent_check`, as every parent
  version property does). The managed version and scope also apply to a declaration
  that keeps its `<version>` but has no `<scope>`, and where another
  dependency brings the annotations in. The annotations and their `jsr305`
  leave the runtime classpath and the packaged artifacts with no edit, but
  `provided` is not transitive: a module (or a downstream user) that got the
  annotations through another module stops compiling ("package
  edu.umd.cs.findbugs.annotations does not exist"). Each module that uses
  them declares the artifact itself (no version, no scope), or the root pom
  declares it once in its `<dependencies>` so every module inherits it.
- It sets `project.build.sourceEncoding` and `project.reporting.outputEncoding`
  to `UTF-8`, the encoding the shared configs read; a project's own
  `<properties>` override them.
- Surefire and failsafe set `quarkus.jacoco.report=false` in the test JVM:
  jacoco-maven-plugin writes the coverage report, and quarkus-jacoco's own
  would show 0%. A project that wants it back sets the property to `true` in
  its own `<systemPropertyVariables>`.
- It configures the compiler (`-Werror`, `-Xlint:all` minus `classfile`,
  Error Prone with NullAway; `@SuppressWarnings("serial")` or
  `("this-escape")` silences one site, and a module where the construct is
  pervasive (a framework such as Vaadin) or cannot be annotated (generated
  sources) appends `-Xlint:-serial` or `-Xlint:-this-escape` to its
  `<compilerArgs combine.children="append">`), surefire and
  failsafe, and activates failsafe, license (`add-third-party`), SpotBugs,
  PMD (with CPD; `printFailingErrors` logs each failing violation), Checkstyle
  (the shared config and the execution `project`), JaCoCo (agent, report and
  coverage check) and Spotless (the Eclipse formatter, with static imports
  first, then java, javax, jakarta, org, com, then the rest), whose checks
  run at `verify`, and resources, whose execution `pmd-ruleset` (the copy PMD
  reads) runs at `initialize`.
  dependency-check is configured but not activated; `make audit` runs it by its
  coordinates.
  License skips every artifact whose groupId is exactly the module's own: a
  sibling under it is not third party, and neither is any other artifact
  published under that groupId; a sibling under another groupId is. License
  allows only the names the parent lists in `includedLicenses`, compared
  exactly: a dependency under any other fails the build, and one passes when any
  one of its licenses is listed, since Maven reads a pom's licenses as
  alternatives. Two things are never checked: with `failOnMissing` off, a
  dependency with no license passes (the plugin keys it "Unknown license",
  which is listed), and so does a system-scope dependency. The
  "Unknown license" entry lets `failOnMissing` report a dependency with no
  license; a project that replaces the list keeps it, or such a dependency
  fails as forbidden instead. The parent sets no `excludedLicenses`: every name
  the allowlist omits already fails, and one a project appends is allowed,
  whatever it is. A project's own `excludedLicenses` therefore applies at any
  level, in the execution, at plugin level or as the `license.excludedLicenses`
  property; its names are separated by `|` and compared exactly, so none may
  wrap over a line. Beside the allowlist, plugin 2.7.1 then throws a
  `ConcurrentModificationException`, not a license message, when two or more
  dependencies declare an allowed license and the same excluded name. The
  project deletes that `excludedLicenses` and appends to the allowlist any name
  it let through instead. A dependency whose pom names licenses that all apply,
  or misstates its license, is declared in the override file below, whose line
  replaces every license of that artifact; the check then reads the declared
  name, so it must be a listed one. A dependency whose pom declares no license
  gets one in the module's `src/license/override-THIRD-PARTY.properties`, one
  `groupId--artifactId--version=License name` line each, which the plugin
  reads by default and never writes. Its error message names
  `THIRD-PARTY.properties` instead, which it reads only under
  `license.useMissingFile`; there, `force` has it rewrite that file, with a
  fresh timestamp, on every build.
- NullAway also checks test sources. It treats a field a test framework
  injects as initialized (`ExcludedFieldAnnotations`: NullAway's own list,
  which covers Mockito's `@Mock`, `@Spy`, `@Captor` and `@InjectMocks`,
  JUnit's `@TempDir` and `jakarta.inject.Inject`, plus the property
  `nullaway.excluded.field.annotations`, which adds Quarkus' `@InjectMock`
  and `@InjectSpy`), and an AssertJ, Truth or Hamcrest assertion such as
  `assertThat(x).isNotNull()` as a null check
  (`HandleTestAssertionLibraries`; NullAway reads JUnit's `assertNotNull` as
  one anyway). A test that passes `null` on purpose still suppresses
  NullAway on that method: the shared Checkstyle config bans
  `@SuppressWarnings("NullAway")` in main sources and allows it under
  `src/test`, so no project suppression line is needed for it.
- flatten-maven-plugin (execution `flatten`, at `verify`, after the tests
  and Quarkus' build) writes the pom a lifecycle `install` or `deploy`
  publishes (to `target/.flattened-pom.xml`), in its `ossrh` mode. It
  holds the project's coordinates; the `<name>`, `<description>`, `<url>`,
  `<licenses>`, `<developers>` and `<scm>` Maven Central requires; its
  dependencies, test-scoped ones dropped; its own
  `<dependencyManagement>`; and its `<profiles>`, not activated. Values
  are resolved at build time, `${revision}` and those in profiles
  included. It has no `<parent>`, `<build>`, `<modules>`, `<properties>`,
  `<repositories>` or other project metadata. With devkit's flatten
  configuration, an installed or published artifact never refers to
  devkit's parent, so a build outside the reactor resolves it without
  devkit: a downstream project, or `ONLY` on a module that depends on a
  sibling. That sibling comes from the local repository as the last
  `make install` left it; one never installed resolves like any other
  dependency, from the remote repositories, so `make install` comes
  first. Its configuration is not an override point: a project's own
  flatten configuration merges into devkit's and can fail the build.
  devkit sets the modes, so no `-D` property changes them, but the skip
  properties `-Dflatten.skip=true` and `-Dflatten.flatten.skip=true`
  publish the unflattened poms again.
- The consumer sets `maven.compiler.release`, which the compiler and PMD's
  `targetJdk` read, and overrides these properties in its own
  `<properties>`:

  | Property | Default |
  | --- | --- |
  | `jacoco.check.lineMinimum` | `0.90` |
  | `jacoco.check.branchMinimum` | `0.80` |
  | `jacoco.check.skip` | `false` |
  | `pmd-cpd.minTokens` | `65` |
  | `pmd.extraAssertMethodNames` | empty; comma-separated names, without spaces, of the project's own assertion helpers, which UnitTestShouldIncludeAssert accepts besides PMD's defaults (`assert*`, `verify*`, ...), e.g. `statusCode,greetingIs` |
  | `skipITs` | `true` |
  | `devkit.maven.range` | `[3.9.9,)`; the enforcer's Maven range for a bare or IDE build, which the pinned Maven under make meets at the default; an override is the project's call, lowering it at its own risk (Maven 3.9.8 built Quarkus projects that failed at runtime), and must still admit the pinned Maven |
  | `nullaway.annotated.packages` | `${project.groupId}`; comma-separated, without spaces |
  | `nullaway.excluded.field.annotations` | `io.quarkus.test.InjectMock,io.quarkus.test.junit.mockito.InjectSpy`; comma-separated, without spaces, added to NullAway's own `ExcludedFieldAnnotations`, which an override keeps; an override replaces this whole value, these two included, so a project adding a name repeats them |
  | `error-prone.extra.args` | empty; appended to the Error Prone argument, e.g. `-XepExcludedPaths:.*/generated-sources/.*` |

- PMD does not read `pmd.extraAssertMethodNames` itself: at `initialize` the
  parent's maven-resources-plugin execution `pmd-ruleset` copies
  `pmd-ruleset.xml` to `target/devkit/` in each module, filling in
  `${pmd.extraAssertMethodNames}` (the only placeholder the file carries; any
  `${…}` added to it is expanded too), and PMD reads that copy. Every target
  that runs PMD runs `initialize` first; a bare `mvn pmd:check` reads the
  previous build's copy, or fails after a `clean`. The CPD goals read no
  ruleset, so a bare `mvn pmd:cpd-check` needs no `initialize`. A project's
  plugin-level maven-resources-plugin configuration and its build filters do
  not reach the copy, and `maven.resources.skip` does not skip it; a project
  that redeclares the execution `pmd-ruleset` itself does reach it.

- A module drops one rule of devkit's PMD ruleset, keeping every other rule and
  the filled-in `pmd.extraAssertMethodNames`, without copying the file. It
  redeclares PMD's `<rulesets>` with one entry, a `pmd-ruleset.xml` of its own,
  and that file references the filtered
  copy, `target/devkit/pmd-ruleset.xml`, and excludes the rule. A Vaadin module,
  whose constructors call setters while building the UI, drops
  `ConstructorCallsOverridableMethod` this way. The module's pom:

  ```xml
  <plugin>
    <artifactId>maven-pmd-plugin</artifactId>
    <configuration>
      <rulesets>
        <ruleset>${project.basedir}/pmd-ruleset.xml</ruleset>
      </rulesets>
    </configuration>
  </plugin>
  ```

  The plugin goes in the `<build>` of the module's pom. The `pmd-ruleset.xml`
  beside that pom:

  ```xml
  <?xml version="1.0" encoding="UTF-8"?>
  <ruleset name="Module PMD Rules"
      xmlns="http://pmd.sourceforge.net/ruleset/2.0.0"
      xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
      xsi:schemaLocation="http://pmd.sourceforge.net/ruleset/2.0.0 https://pmd.sourceforge.io/ruleset_2_0_0.xsd">
    <description>devkit's rules without ConstructorCallsOverridableMethod.</description>
    <rule ref="target/devkit/pmd-ruleset.xml">
      <exclude name="ConstructorCallsOverridableMethod" />
    </rule>
  </ruleset>
  ```

  PMD expands no `${…}` in the reference, and resolves a relative path against
  the directory Maven runs from, the project root under make, not against the
  file that holds it. In a module of a multi-module project the reference is
  the module's directory as `MODULES` lists it, then `/target/devkit/`:
  `app/target/devkit/pmd-ruleset.xml` for the `MODULES` entry `app`. The bare
  `target/devkit/pmd-ruleset.xml` there reads the root's copy, if the last build
  left one, which holds the root's `pmd.extraAssertMethodNames`, not the
  module's. From another directory
  PMD fails where no file is at that path and reads whatever file is there
  otherwise: run a module from the root (`mvn -pl <module dir>`), not from
  inside it. The `<rulesets>` list carries no `combine.children="append"`: it
  replaces the parent's entry, where an appended one would keep the rule. One
  place is silenced with `@SuppressWarnings("PMD.<RuleName>")`.

- `MAVEN_ARGS` reaches every Maven call of the targets above:
  `MAVEN_ARGS=-Pproduction make install` applies a profile, and
  `MAVEN_ARGS=-DskipITs=false make test` runs the integration tests once.
  The resolver keys of [Plugin checksums](#plugin-checksums) override its
  own.

- It commits the files the table above lists. `.mvn/jvm.config` carries
  the `jdk.compiler` `--add-exports` and `--add-opens` lines as devkit's
  `tests/fixtures/java-monolith/.mvn/jvm.config` lists them. The parent
  reads `checkstyle-suppressions.xml`, `checkstyle-xpath-suppressions.xml`
  (optional) and `spotbugs-exclude.xml` from `${project.basedir}`; a
  multi-module project that keeps one `checkstyle-suppressions.xml` at the
  root overrides the checkstyle plugin's `<propertyExpansion>` in its own
  `<pluginManagement>`, which replaces both properties, as
  `tests/fixtures/java-multimodule/pom.xml` does; a project that also keeps
  one `checkstyle-xpath-suppressions.xml` at the root sets
  `org.checkstyle.google.suppressionxpathfilter.config=${maven.multiModuleProjectDirectory}/checkstyle-xpath-suppressions.xml`
  beside it, and an override that leaves that key out has the filter read
  `checkstyle-xpath-suppressions.xml` from Maven's working directory, the
  project root under make.
- Maven merges any list the parent sets with a consumer's redeclaration element
  by element, by position, unless the consumer's list carries
  `combine.children="append"`: a redeclared `<compilerArgs>` silently drops the
  inherited `-Werror`, Error Prone or NullAway, and the same holds for
  `<annotationProcessorPaths>`, JaCoCo's `<excludes>` and `<rules>`, PMD's
  `<rulesets>`, dependency-check's `<suppressionFiles>` and SpotBugs'
  `<plugins>`, where a project's own detector would take find-sec-bugs' place;
  license's `<includedLicenses>` is replaced whole by the project's names, not
  merged by position. The parent check enforces it for the compiler's two lists
  and SpotBugs' `<plugins>` only.
- Some settings live at execution level, where a plugin-level override does not
  reach them; override them inside the execution with the id below: license's
  `force` (`true`, so that every build runs the license checks, not only the
  first after a clean), `failOnMissing`, `failOnBlacklist`, `excludedGroups` and
  `includedLicenses` (`add-third-party`; a project adds names to the allowlist
  as `<includedLicenses combine.children="append">` with one `<includedLicense>`
  per name, which replaces the parent's list without the attribute and belongs
  in the execution, as a plugin-level or `license.includedLicenses` value is
  ignored; `failOnBlacklist` governs the allowlist as well as any
  `excludedLicenses`, so turning it off disables both; an `excludedGroups` of
  the project's own replaces the one that skips its groupId, so it keeps
  `^\Q${project.groupId}\E(?=:)|` before its own groups: the plugin embeds the
  pattern in a regular expression over `groupId:artifactId`, so
  `^\Qcom.example\E(?=:)` matches exactly that groupId, where a bare
  `com\.example` matches any that contains it), JaCoCo's agent `<excludes>`
  (`prepare-agent`), and its `<rules>` and `<skip>` (`check`; prefer the
  properties).
- Excluding generated sources is the consumer's: checkstyle
  `<sourceDirectories>`, PMD `<excludeRoots>`, the SpotBugs filter and
  `error-prone.extra.args`.
- The property names above and the execution ids are contract: a renamed
  one silently ignores a consumer's override. The ids are `prepare-agent`,
  `report` and `check` (JaCoCo), `pmd-check` and `cpd-check` (PMD),
  `checkstyle` and `project` (Checkstyle), `environment` (enforcer),
  `spotless-check` (Spotless), `spotbugs-check` (SpotBugs),
  `add-third-party` (license), `default` (failsafe) and `pmd-ruleset`
  (resources).
- Never add a repository whose namespace ownership is unverified to the
  root pom or to Maven's settings. Maven must find the parent only through
  the link; a remote lookup of `de.vptr.devkit:devkit-parent` is the
  failure mode, and whatever serves it would configure the build.

### Plugin checksums

`java/checksums/checksums.sha256` holds the SHA-256 of every artifact that
building devkit's `java-*` test fixtures through `make lint`, `test`,
`coverage`, `install` and `format` resolves: the parent's plugins and their
dependencies, the annotation processors (Error Prone, NullAway), find-sec-bugs'
jar, which SpotBugs resolves through Maven's resolver, and the fixtures'
dependencies, plus the closure of dependency-check's goals (recorded without an
NVD key through the plugin's `help` goal; the closure its analysis downloads at
run time, not through Maven, is not) and of the help and dependency plugins that
`check_frontend_deps.py` runs. Each line is `<sha256>  <repository path>`.
Maven's resolver checks every artifact it resolves against the file, from a
download or from the local repository, and fails the build on a mismatch, so a
repository or mirror that serves other bytes for a listed coordinate, or a jar
altered in the local repository, fails the build with
`Checksum validation failed … (Trusted Checksums Source: summaryFile)`.

- The scripts behind `check`, `install`, `lint`, `format`, `test`, `coverage`,
  `audit` and `clean` run Maven through `scripts/lib/mvn_checked.sh`, which
  `scripts/lib/get_maven.sh` exports as `MVN_CMD` (the pinned launcher stays
  `MVN_LAUNCHER`). It requires `JAVA_VERSION` to be a plain JDK major number,
  exiting 1 with an `ERROR` otherwise (`check`, which maps every failure of
  its enforcer run to 11, exits 11), and passes the enforcer its JDK range;
  make exports `JAVA_VERSION` from the project `Makefile`, and a consumer script
  that calls `MVN_CMD` outside make exports it. The wrapper puts the resolver's
  `trustedChecksumsSource.summaryFile` and `trustedChecksums` post-processor
  keys (SHA-256, basedir `$DEVKIT/java/checksums`, `originAware=false` so that a
  mirror cannot bypass the file, `scope=all` so that it covers every artifact)
  on Maven's command line, and pins the post-processor's `record` to `false`, so
  that a project cannot switch verification off through these keys (unlisted
  code inside Maven still can, below). A command-line key beats
  `MAVEN_ARGS` and `.mvn/maven.config`, so for these keys those calls ignore a
  project's own setting. The wrapper fails closed when the file is missing or
  empty. It also puts
  `org.slf4j.simpleLogger.log.org.apache.maven.plugin.compiler` and
  `org.slf4j.simpleLogger.log.org.apache.maven.plugins.pmd` at `warn` on the
  command line: `-q` alone keeps ERROR only, so a failing build would name
  neither the javac warning `-Werror` fails on nor the PMD and CPD violations,
  and only per-logger keys survive `-q`. These two keys go on every call
  except one asking for debug output (`-X` or `--debug` as a whole word of
  `MAVEN_ARGS` or of the call's arguments; one in `.mvn/maven.config` does not
  count), where they are left out so that the debug output is complete. A
  non-quiet call therefore also sees those two loggers at `warn`, and a
  project's own setting of these keys in `MAVEN_ARGS` or `.mvn/maven.config`
  is overridden.
- `failIfMissing` is off: an artifact the file does not list passes
  unchecked. That is:
  - a project's own artifact, unless it shares a recorded coordinate;
  - a gate plugin a project switches to another version through a
    `-D<tool>.version` in `MAVEN_ARGS` or `.mvn/maven.config` (the file
    records the pinned versions);
  - the Eclipse formatter, when a project overrides the formatter or
    Spotless version (a `-D` in `MAVEN_ARGS` or `.mvn/maven.config`, its own
    `<eclipse><version>` or `<p2Mirrors>`, a plugin dependency on another
    spotless-lib-extra): Spotless can then provision the formatter from P2,
    outside Maven;
  - a version resolved through repository metadata (a version range,
    `LATEST`, `RELEASE`); none is in devkit's closure.

  The file protects devkit's gate tooling at its pinned versions, not the
  project's dependency graph, and only while no unlisted code runs inside
  Maven: code in Maven's JVM can replace the resolver components that do
  the checking, so an unlisted core extension (`.mvn/extensions.xml`), a jar
  on `maven.ext.class.path` (set through any `-D`), a Java agent
  (`-javaagent:` in a JVM options variable or `.mvn/jvm.config`), a build
  extension or plugin the project adds, or a plugin the parent manages whose
  version the project overrides with a literal `<version>` can defeat
  verification of the listed tools too.
- The hashes are trust on first use: whatever Maven Central served over
  https when `make maven-checksums` ran. They detect a later substitution by
  a mirror, a proxy or the local repository, not an artifact that was
  already malicious on Central. A re-record refuses to change the hash of a
  path already in the file.
- A plain `mvn` outside the targets is not checked, and neither is anything
  downloaded outside Maven (dependency-check's vulnerability data). At the
  parent's `eclipse-formatter.version` and `spotless-plugin.version`, once
  `make maven-checksums` has recorded them (devkit's java tests fail when it
  has not), the Eclipse formatter's artifacts come through Maven and are
  checked, the spotless-lib-extra Spotless runs embedding a lockfile for that
  formatter version. `make maven-checksums` refuses a version without an
  embedded lockfile, whose formatter Spotless would provision from P2,
  outside Maven and so outside the trusted checksums.
- Under `-q`, which `check`, `install`, `lint`, `format`, `test`, `coverage`
  and `clean` pass (`audit` does not, and prints the error whichever way it
  names its plugin), a mismatch on an artifact of a lifecycle plugin, a plugin
  dependency or an annotation processor shows as that error. devkit invokes its
  gate plugins by `groupId:artifactId:goal`, without a version, so that the
  parent's pin applies and a mismatch shows as that error: invoked by prefix
  (`spotless:check`), a mismatch would show only as `No plugin found for
  prefix`. A consumer's own script that does the latter sees that message.
- The file also lists the pinned Maven's distribution
  (`org/apache/maven/apache-maven/<version>/apache-maven-<version>-bin.tar.gz`)
  and is recorded under that Maven, so the default lifecycle plugins it
  binds are checked.
- The file is devkit's, regenerated by `make maven-checksums` in devkit
  when a plugin version or `eclipse-formatter.version` in the parent, or the
  pinned Maven, changes; devkit's
  shell tests fail otherwise, but only for the top-level jar of every
  plugin, plugin dependency and annotation processor the parent pins, for
  the two plugins of `check_frontend_deps.py` and for the pinned Maven. It
  is no consumer's to edit.

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
  when `COVERAGE_FLOOR` is unset (an inherited environment value never
  counts) or not a percent from 0 to 100, when
  `.python-version` is missing, no `major.minor[.patch]` or older than 3.11
  (`make lint`'s anchored-match gate runs under `.venv`'s Python, so `make
  lint` fails as well when that Python is older than 3.11), when
  `MODULES` holds a glob character or differs from the members `uv.lock`
  records, when the root `pyproject.toml` sets no `[tool.vulture] paths`,
  when `uv.lock` pins no single usable uv version, lists a uv wheel
  without a sha256 hash, or records no wheel for uv at all (an sdist, git
  or path source), when that uv is older than devkit's minimum, 0.12.23
  (a pre-release of it counts as older; it is the oldest uv devkit tests
  its `uv sync` and `uv export` flags with), when devkit's copy of the uv
  `uv.lock` pins is not installed, when `.venv` is
  missing, when its Python's version differs from the pin (`major.minor`,
  or the patch too when the pin names one), when `uv sync --check --frozen
  --offline` cannot confirm `.venv` matches `uv.lock` (drift: run `make
  install`), and when a dev tool is missing from `.venv`. Before uv, it
  validates `devkit.toml`'s `[python.duplication]` (`duplication.py
  check-config`, see the copy-paste gate below) and `[python.anchored-match]`
  (`anchored_match.py check-config`, see the anchored-match gate below), and
  `[[python.audit.accepted]]` (`audit.py check-config`, see `make audit`).
- uv. `scripts/lib/get_uv.sh` exports `UV_CMD`, devkit's per-user copy of
  the uv `uv.lock` pins, `uv-<version>-<platform>-<key>/bin/uv` in
  `${XDG_CACHE_HOME:-$HOME/.cache}/devkit/tools`; `<platform>` is `uname -s`
  and `uname -m`, then the libc (`glibc`, `musl` or `other`) and pointer
  width (`32` or `64`) of the `python3` pip runs under, as in
  `Linux-x86_64-glibc64`, so a cache that machines of another platform,
  libc or word size share keeps a copy each, and `<key>` comes from the
  sha256 of every uv wheel the lock records (hashed with `sha256sum` or
  `shasum`), so projects
  that lock the same uv by the same hashes share one copy and a lock with
  other hashes gets its own. devkit never runs a `uv` on `PATH`, nor the
  one inside `.venv`. Every target that sources it (`check`, `install`,
  `test`, `audit`) fails first on a uv older than devkit's minimum (see
  `make check`). Only `make install` creates the copy, read-only, when
  it is missing, and
  `check`, `test` and `audit` fail until then: pip, in a throwaway venv of
  `python3`, installs the machine's uv wheel from the index pip's own
  configuration names (PyPI unless `pip.conf` or a `PIP_*` variable such as
  `PIP_INDEX_URL` names another), and only a wheel whose sha256 `uv.lock`
  lists. A copy that does not report the pinned version fails with the
  command that removes it. devkit's targets always use the project's
  `.venv`, in the project at `$PWD`: `get_uv.sh` unsets
  `UV_PROJECT_ENVIRONMENT`, `UV_PROJECT` and `UV_WORKING_DIR`.
- `make install` runs `uv sync --locked --all-packages --all-extras`: it
  creates or repairs `.venv`, with the pinned CPython, which uv provisions
  when it is missing. It fails when `uv.lock` is stale against
  `pyproject.toml` (run `uv lock`), and never rewrites `uv.lock`. It has no
  `check` prerequisite: a drifted `.venv` fails `check`, and `install` is
  the repair.
- `make lint` runs, stopping at the first failure, `ruff check`,
  `ruff format --check`, vulture over the root `pyproject.toml`'s
  `[tool.vulture] paths`, which must be set, then the anchored-match gate,
  then the copy-paste gate. `ONLY` narrows the two ruff passes to the
  selected members; vulture, the anchored-match gate (every `*.py` git
  lists) and the copy-paste gate always scan the whole project.
- `make format` runs `ruff check --fix --exit-zero`, then `ruff format`, on
  the project or the `ONLY` selection: it rewrites and never judges.
- `make test` first asks the pinned uv whether `.venv` matches `uv.lock`
  (`uv sync --check --frozen --offline --all-packages --all-extras`, as
  `make check` does) and fails with uv's report otherwise: run `make
  install`. That catches a package installed or removed behind uv's back and
  a `uv.lock` changed since the install, and touching a workspace member's
  (or a packaged root's) `pyproject.toml`, which makes uv rebuild the
  editable member, whose entry points or pytest plugins may have changed
  (as `make check` already did); any other file in `.venv` uv does not
  hash it does not (a stray `.pth` file, `sitecustomize.py`, an edited file
  in site-packages, an entry script such as `.venv/bin/pytest`,
  `pyvenv.cfg`), and `rm -rf .venv && make install` is the remedy for those.
  It judges `.venv` against `uv.lock`, not `uv.lock` against
  `pyproject.toml`: `make install`'s `--locked` does, and CI's install step
  catches a stale lock. A project whose `[tool.uv] cache-keys` name a git
  commit or a source-file glob makes uv treat it as needing a rebuild after
  every new commit or matching edit, so `make test`, `make gate` (which
  runs on the commit) and CI's test step fail until `make install`: run it
  after each commit or edit, or drop the cache key. It then runs one
  pytest session per member of the selection, in the member's directory,
  with branch coverage (`--cov-branch`), `--cache-clear` (it empties
  everything the suite keeps in pytest's cache, `config.cache` values and
  `.pytest_cache/d/` too, so a stale `.pytest_cache` steers no session
  through `--lf` or `--sw`; a project that sets `-p no:cacheprovider` in its
  `addopts` keeps no cache, and the option is still accepted) and a
  temporary `COVERAGE_FILE` (a stale `.coverage` or a `data_file` setting
  never reaches the floor, even under `--cov-append`; `make test` leaves no
  `.coverage`, so a project that wants a report adds `--cov-report=html` or
  `xml` to its `addopts`). Each
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
  `uv.lock` pins (`uv export --no-default-groups --all-packages
  --all-extras --format pylock.toml`: every member's and every extra's,
  the project's own packages and its local path dependencies left out,
  what they depend on kept), every one of them on every machine: pip-audit
  reads the export with `--locked`, which ignores environment markers, so
  a dependency only another platform or Python installs
  (`sys_platform == "win32"`) is audited too, and one `devkit.toml` is
  judged alike everywhere. Before pip-audit runs, an export that is not a
  pylock 1.x file naming each package and its version fails, and so does
  a package it pins from a git, URL or local file or directory source,
  which pip-audit cannot audit against an index (a git or URL one it
  would audit as the PyPI release of its name and version). When
  `uv.lock` pins none, `make audit` passes without running pip-audit,
  saying so, only when no entry is accepted (below; every entry is then
  stale). It runs pip-audit twice over that export, against PyPI and then
  against OSV, both with `--strict`, always both, and judges the two
  reports as the next paragraph says (an exit status 1 whose findings are
  all accepted passes): PyPI's advisory data omits advisories OSV carries,
  and OSV cannot tell an unknown package from a clean one, so only PyPI's
  `--strict` fails closed on a dependency that cannot be audited. It needs
  the network, both pypi.org's JSON API and api.osv.dev, and fails closed
  without either; the export also downloads any artifact whose hash
  `uv.lock` lacks, from its index, to compute it. Neither `check` nor
  `test` runs it.

  An advisory is accepted in `devkit.toml`, one
  `[[python.audit.accepted]]` entry each, with `package`, `id` and a
  non-blank `reason`, and no other key; `make check` and `make audit`
  (before any network call) fail on a malformed entry, on a package that
  is no Python package name, and on a repeat of one package (names
  compared as PEP 503 normalizes them) and id. pip-audit writes JSON
  reports (`--aliases on`), which `scripts/python/audit.py` judges. An
  entry accepts a finding of either service when the package is the
  same and `id` is the finding's id or one of its aliases, compared
  case-insensitively (PyPI lists a PYSEC id and OSV a GHSA id of one
  advisory; the aliases tie them, so one entry covers both rows). A row
  both services report under one id is listed once, with the aliases and
  fix versions of both. Every dependency of a report carries a version,
  and every advisory its `aliases` and `fix_versions`, as pip-audit
  writes them; a report without them fails. Any
  version of the package matches. A finding that more than one entry
  accepts fails, so that each entry stands for one finding: keep one. The
  run fails on every finding no entry accepts, naming its package,
  version, ids, fix versions and service, and on every stale entry, one
  that neither service reports, which is judged only when both reports
  were read. It also fails when a service exits with a status other than
  0 and 1, or 1 with no advisory, leaves no readable report, or reports
  a dependency it skipped, and then says that staleness was not judged.
  A report that leaves out a package the export pins fails too (a name
  `uv.lock` forks into two versions counts twice), and staleness is then
  not judged. `make audit` needs a pip-audit in the dev group with
  `--locked`, `--format json` and `--aliases`; a project pinning one
  without one of them fails both runs with exit status 2 and upgrades it
  (the fixtures pin 2.10.1), and a uv whose `uv export` has
  `--format pylock.toml`, as devkit's minimum uv, 0.12.23, does. An entry
  has no expiry, and keeps passing when a fixed release appears: a passing
  run lists each accepted finding with its fix versions and reason, so a
  fix does not go unseen.
- `make clean` removes `__pycache__`, `.pytest_cache`, `.ruff_cache`,
  `*.egg-info`, `dist`, `.coverage` and `.coverage.*` below the project
  root, skipping the root's `.git` and `.devkit`, every `.venv` and
  `node_modules`, and any directory holding a `.git` (a nested checkout).
- `ONLY` narrows `lint`'s ruff passes, `format` and `test`; `install`,
  `check`, `audit` and `clean` act on the whole project.
- The anchored-match gate, after vulture in `make lint`, fails on a regex
  that lets a trailing newline through: Python's `$` also matches before
  one, so `re.match(r"^[a-z]+$", "admin\n")` passes. It parses every `*.py`
  git lists (tracked, plus untracked ones the project does not ignore),
  none through a symlink, and flags `re.match`, and `re.search` whose
  pattern starts with `^` or `\A`, when the pattern holds a `$`; the
  fix is `re.fullmatch` on an unanchored pattern, or `\A…\Z`. The start
  anchor may follow whitespace, global inline flags such as `(?i)`, and
  group openers (`(`, `(?:`, `(?P<name>`, `(?i:`). It
  resolves `re.match` and `re.search` (also through import aliases),
  `re.compile(…).match` and `.search` called inline, and
  `NAME.match` and `.search` where `NAME` is bound once, in module scope or
  the enclosing function, to `re.compile(…)`. The pattern must be a `str`
  or `bytes` literal, also through a module-level constant bound once, or
  the literal parts of an f-string; flags are ignored, and a `$` counts
  unless escaped or inside `[…]`. Each optional
  `[[python.anchored-match.accepted]]` entry names a `file`, a `function`
  (the enclosing class and function names joined by `.`, as the error line
  prints it: no `<locals>`, `<lambda>` for a lambda, `<module>` at top
  level) and a non-empty `reason` saying why that input cannot carry a
  newline. One entry accepts every definition of that name in the file (a
  property's getter and setter, every lambda in one scope). The gate fails,
  naming the call, on every anchored call no entry accepts, and on every
  accepted entry that matches none any more. Each optional
  `[[python.anchored-match.excluded]]` entry names one `file` the gate neither
  parses nor scans (a fixture that is not meant to parse, vendored code) and a
  non-empty `reason`; single files only, no directories or globs, so a file
  added later is always scanned. The gate fails on an excluded entry naming a
  file git no longer lists. It is a ratchet, not a proof: it skips every call it
  cannot resolve, among them a parameter, an attribute such as `self._RE`, a
  class-level constant, a return value, a name bound twice, a bound method kept
  in a name (`v = re.compile(…).match`), a name imported from another module
  (each file is read on its own, so a pattern compiled in one module and used in
  another is not checked), the `regex` module and `PurePath.match`. A `$` in a
  `(?x)` or `(?#…)` comment is a known false positive: accept it; an unbalanced
  `[` inside such a comment can also hide a later `$`. It runs under `.venv`'s
  Python with `-I -S`, so no `PYTHON*` variable, user site or site-packages
  reaches it, and parses with the grammar of the CPython `.python-version`
  pins: a file that Python does not parse, or that cannot be read, fails the
  run, naming the file, and for a parse failure the version and the
  interpreter. `make check`
  validates the table with the `python3` on `PATH`. The table is optional; a
  project without one accepts nothing. `make check` fails, one `ERROR` line with
  its remedy each, when `[python.anchored-match]` is not a table or holds a key
  other than `accepted` or `excluded`, when either is not an array of tables,
  when an entry sets an unknown key, when `file`, `function` or `reason` is
  missing or blank, when two entries accept the same pair or exclude the same
  file (`./src/a.py` counts as `src/a.py`), and when an accepted entry's `file`
  is an excluded file (remove the accepted entry).
- The copy-paste gate, the last step of `make lint`, runs jscpd at the
  closure `jscpd/package-lock.json` pins, installed and audited like
  markdownlint-cli (see `lint-md`); installed on first use, it needs `node`
  at or above `engines.node` in `jscpd/package.json` and `npm` on `PATH`.
  It scans the Python files git lists (tracked, plus untracked ones the
  project does not ignore; the user's global excludes do not apply) under
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
  any order), a non-empty `reason` and a `max-tokens` ceiling, the sum of
  the `tokens` jscpd reports for every clone of the pair, and the gate
  fails, naming the pair and the lines jscpd reported, on every pair it
  finds a clone of that no entry accepts, on every accepted pair it no
  longer finds, and on every accepted pair whose clones sum to more than
  its `max-tokens` (extract the duplication, or raise the ceiling and
  revise the reason). A pair below its ceiling passes, with a hint naming
  the lower figure; an entry without `max-tokens` fails, naming the
  figure to copy in. The figures are jscpd's own count, so a devkit release
  that bumps its jscpd can move them; its upgrade steps say so. It first
  runs jscpd, with the default `min-tokens` and no `ignore`, on devkit's
  `jscpd/controls/`, and fails unless exactly the one duplicated pair there
  is found, and fails when jscpd writes no report. `make check` fails, one
  `ERROR` line with its remedy each, when the table or `paths` is missing,
  a path is absolute, leaves the project root or does not exist, git lists
  no Python file under `paths`, `min-tokens` is not a positive integer,
  `ignore` is not a list of strings without commas (jscpd splits on them),
  an entry has not exactly two `files`, no `reason` or no `max-tokens`
  (a positive integer; `make lint` names the figure), a pair is accepted
  twice, or the table or an entry holds another key.
