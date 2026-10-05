# devkit

devkit is the build and quality-gate tooling that projects would otherwise
copy between each other: shared Make targets (`make/`), the scripts behind
them (`scripts/`), the shared Maven gate configurations (`java/config/`) and
a parent POM that applies them (`java/parent/`).
A project consumes one pinned release of it through a small committed
wrapper, `devkitw`, on the pattern of the Maven wrapper: the wrapper fetches
the pinned commit once per machine into a cache and links it into the
project as `.devkit`. devkit was extracted from a Maven monolith and a Maven
multi-module project that had kept the same tooling byte-identical by hand.

## Why it looks like this

**Three repositories, one job each.** devkit holds build and gate tooling,
and is pinned per project. Agent tooling (a Claude Code plugin) and personal
configuration (a private repository) are per machine and live elsewhere.
Only devkit decides whether a build passes, so only devkit is pinned.

**Why a wrapper.** A consumer commits `devkitw` and a text pin,
`devkit.toml`. Nothing is installed globally, a bump is usually a
three-line text diff, `version` and `commit` in `devkit.toml` and the root
pom's `<parent><version>` (a release whose contract changes lists its
upgrade steps under [Releasing](#releasing)), and a cached checkout works
offline. The cache is
read-only: a change to shared tooling is made and released in devkit, never
edited inside a project. The wrapper fails closed: it never falls back to
another version and refuses a fetched commit that differs from the pin.

**Why a parent POM.** The Maven gate configuration lives in one place,
`java/parent/pom.xml`, which a consumer's root pom inherits through the
link. It activates the gate plugins, not just manages them, so a consumer
cannot drop a gate without noticing. It also carries the gate tools'
versions, because the shared configs depend on them: the formatter
version decides the formatting, the PMD and Checkstyle versions decide
which rules exist. Error Prone with NullAway is always on, not an opt-in
profile, so the fixtures test what consumers run. Its version is literal,
the release tag without the `v`, so a consumer's `-Drevision` never
touches it. Once consumers adopt it, some things are hard to change: its
coordinates, its path, the tag-to-version mapping, and the property names
and execution ids consumers override, since a renamed one silently
ignores the override.

**Rejected options:**

- _Keep the Makefile and scripts in each project._ The two source projects
  drifted under a written by-hand sync policy; the same Quarkus/JaCoCo
  change had to land twice in one day.
- _git submodule._ Needs `git submodule update` after every checkout and
  rebase, recursive clones, and a dedicated submodule manager in dependency
  bots instead of a text edit. (The per-bump commit in the consumer is common
  to every pinned option and did not decide.)
- _A project template (Copier)._ It allows local edits, which is the drift
  path, and turns scripts into templates tested only through rendered
  samples.
- _An installed CLI._ `uv tool` is Python tooling and an odd prerequisite for
  a Java build; a custom CLI is a product with a publish step per change.
- _A Claude Code plugin for everything._ Plugins update themselves per
  machine, but gates must be pinned per project for reproducible CI. A
  plugin carries agent tooling only.

## Adopting devkit

The interface is [docs/contract.md](docs/contract.md); every file here is
written against it. In short, a project:

1. copies `devkitw` from the release tag into its root, verbatim and
   executable, and never edits it;
2. adds `devkit.toml` with the pin (`url`, optional `mirror`, `version`,
   `commit`); when it has a frontend, its npm minimums in
   `[frontend.min-pins]`, which a project with a frontend requires (an
   empty table when it has no minimums); and, optionally, the image
   namespaces it publishes itself in `[pins] first-party`;
3. adds `/.devkit` to `.gitignore`;
4. shapes its `Makefile` as the contract shows: profile variables,
   `DEVKIT := $(shell ./devkitw path)` and its empty-result guard,
   `include .devkit/make/common.mk` and `.devkit/make/java-maven.mk`, then
   its own targets; a rule line ending in `## description` is listed by
   `make help`;
5. inherits devkit's parent POM in its root pom, as
   [the contract](docs/contract.md#parent-pom) shows, with a `<groupId>` of
   its own, and keeps only its own values there: overrides of the parent's
   properties, exclusions and its own plugins. The parent runs every gate,
   with the project's `checkstyle-project.xml` as checkstyle execution
   `project`.

Then run `make hooks` once per clone: it installs the
[git hooks](docs/contract.md#git-hooks) that run `make lint-repo` before a
commit and `make lint-repo test` before a push.

`make check` then fails when `.devkit` does not resolve to the pinned
checkout, warns when the committed `devkitw` is stale or a git hook is
missing or stale, and runs the language checks; every target that runs
Maven fails while the root pom does not inherit the parent as the contract
requires. `make lint` runs the
[repository gates](docs/contract.md#repository-gates) first, over the
whole repository, then the language gates. Requirements: git, GNU make,
bash and python3 (3.11 or later); `make lint` and `make format` also need
node (22.22.2 or later) with npm. `make lint` also needs curl, tar and
`sha256sum` or `shasum`, which fetch and verify the pinned gitleaks once.
Windows is not targeted.

On a fresh clone, run any `make` target once: a bare `./mvnw` or an IDE's
Maven import fails until the wrapper has created `.devkit`.
"Non-resolvable parent POM … devkit-parent" means `.devkit` is missing or
points at another pin: run `make check`.

## Releasing

A release is an annotated tag on `main`. The release commit sets the
version in `java/parent/pom.xml`, the `<parent>` versions of the fixtures in
`tests/fixtures/`, and in `docs/contract.md` the header, the TOML example's
`version` and the `<parent>` snippet's version; the tag is `v` + that
version, and `tests/run.sh` tags the tree under test under the same name.
Before
tagging, review the parent's pins against Maven Central (advisory, needs the
network):

```sh
PROJECT_ROOT=java/parent python3 scripts/java/version_check.py
```

Then tag:

```sh
tag=v$(python3 -c 'import sys, xml.etree.ElementTree as ET
version = ET.parse("java/parent/pom.xml").getroot().findtext("{http://maven.apache.org/POM/4.0.0}version")
print((version or "").strip() or sys.exit("java/parent/pom.xml declares no <version>"))') &&
  git tag -a "$tag" -m "devkit $tag" &&
  git push origin "$tag"
```

Tags are never moved or reused. Were one moved, the wrapper would refuse the
fetched commit rather than build with it.

A consumer bumps by editing `version` and `commit` in `devkit.toml` and
the root pom's `<parent><version>` (the version without the `v`), which is
usually the whole diff; a release whose contract changes lists its upgrade
steps below. The commit is the one the tag points at, which for an
annotated tag is the peeled `^{}` entry:

```sh
git ls-remote <url> 'refs/tags/vX.Y.Z^{}'
```

If the release changed `devkitw`, the consumer also copies the new wrapper;
`make check` warns until it does.

### Upgrading from v0.2.x

The next release adds the repository gates `lint-pins`, `lint-decisions`,
`lint-secrets` and `lint-md` to `make lint`, and `format-md` to `make format`
(see [Repository gates](docs/contract.md#repository-gates)). Besides the
version bump, make `make lint` pass them:

1. Add a digest to every container image the project names, as
   `<repository>:<tag>@sha256:<64 hex>`. To find one, run
   `docker buildx imagetools inspect <image>:<tag>`, or `docker pull
   <image>:<tag>` and then
   `docker inspect --format '{{index .RepoDigests 0}}' <image>:<tag>`.
2. Pin every workflow action to its full commit SHA with the release as a
   comment: `uses: owner/repo[/path]@<40 lowercase hex> # vX.Y.Z`. An
   action with no `vX.Y.Z` release is vendored as a `./` action or
   pinned through a tagged fork.
3. Declare the namespaces of the images the project publishes itself in
   `devkit.toml`, as `[pins] first-party = ["<namespace>", ...]`; their
   tags may stay unpinned.
4. A project that keeps `docs/decisions.md` now has to follow its entry
   format: `## ADR-<digits>` headings, one `**Status:** Accepted` or
   `Proposed` per active entry, retired entries under `## Superseded`, and
   a `**Guard:**` for every `**Premise:**`. Once an active `cascade` guard
   names a `trigger: tag:<tag>`, CI checks out the full history with its
   tags (`fetch-depth: 0`), since a shallow clone fails.
5. Check out with full history in every CI job that runs `make lint`
   (`actions/checkout` with `fetch-depth: 0`): `lint-secrets` fails on a
   shallow clone.
6. Run `make lint-secrets` and triage what it finds in the history: remove
   and rotate a real secret, then record its fingerprint, like a false
   positive's, in `.gitleaksignore`.
7. Make `make lint-md` pass: `make format-md` fixes what markdownlint can;
   wrap long lines by hand, exclude files in `.markdownlintignore`, or add
   a `.markdownlint.jsonc` that extends devkit's profile.
8. Provide Node.js 22.22.2 or later with npm in CI, e.g.
   `actions/setup-node` with `node-version: "22"` and `check-latest: true`
   (without it, an older cached 22.x can win), pinned like every other
   action.

It also adds the [git hooks](docs/contract.md#git-hooks): run `make hooks`
once per clone; `make check` notes it until then.

### Upgrading from v0.1.x

v0.2.0 moves the values v0.1.x hardcoded for its first consumers into the
project, and the Maven gate configuration into devkit's parent POM.
Following only the error messages can turn CI green with those values
silently dropped, so take every step:

1. Bump `version` and `commit` in `devkit.toml`; the root pom's
   `<parent><version>` follows in step 4.
2. A project with a frontend adds `[frontend.min-pins]` to `devkit.toml`.
   v0.1.x enforced `react-router = "7.15.0"` and `dompurify = "3.4.16"`
   itself; carry those over unless the project has decided otherwise. An
   empty table declares none.
3. Add `checkstyle-project.xml` at the project root. v0.1.x's shared config
   carried the rules `IllegalImport.UlidCreator`, `IllegalImport.RestAssured`
   and `RegexpSinglelineJava.JoinFetchCollection`. A project that relied on
   them copies them in from the v0.1.x tag's `java/config/checkstyle.xml`
   with their ids unchanged, so its existing suppressions keep applying, and
   trims JoinFetchCollection's field list to its own entities. For those
   suppressions to apply, the file carries the `SuppressionFilter` on
   `${org.checkstyle.google.suppressionfilter.config}`, as
   `tests/fixtures/java-monolith/checkstyle-project.xml` does. A project
   without such rules commits an empty `<module name="Checker"/>`.
4. Adopt the [parent POM](docs/contract.md#parent-pom); v0.2.0 requires
   it, and every target that runs Maven fails until the root pom inherits
   it as the contract shows.
   - Root pom: add the `<parent>` block and keep the pom's own `<groupId>`.
     Delete the gate plugins' configuration and activation (compiler,
     surefire, failsafe, license, dependency-check, SpotBugs, PMD,
     Checkstyle, JaCoCo, Spotless), their tool-version properties (the
     parent check fails while any remain), `pmd-cpd.minTokens` if it is
     65, and the four `org.jacoco` entries in `<dependencyManagement>`.
     Keep the project's own plugins, BOMs, profiles and dependencies.
   - Modules: JaCoCo keeps only its `<excludes>`; its executions come from
     the parent, and coverage minima other than the defaults become
     `jacoco.check.lineMinimum` and `jacoco.check.branchMinimum`. Keep
     `nullaway.annotated.packages`.
   - An Error Prone exclusion inside the old `<compilerArgs>` (e.g.
     `-XepExcludedPaths:.*/generated-sources/.*`) moves to
     `<error-prone.extra.args>`; checkstyle `<sourceDirectories>` and PMD
     `<excludeRoots>` stay as they are.
   - Keep `checkstyle-suppressions.xml` in every module, the root included,
     and `spotbugs-exclude.xml` in every module with classes; or, for one
     suppressions file at the root, override checkstyle's
     `<propertyExpansion>` as `tests/fixtures/java-multimodule/pom.xml`
     does.
   - Add the `jdk.compiler` lines to `.mvn/jvm.config` if they are missing.

   The parent runs `checkstyle-project.xml` as execution `project`, so the
   pom declares none. Checkstyle's `failsOnError` is gone, so `make lint`
   now prints the violation itself.
5. Diff `mvn help:effective-pom` before and after, with `NVD_API_KEY` not
   exported: the effective pom would print it. Besides path spellings,
   expect only these differences: the `<parent>`; the parent's new
   properties; the checkstyle execution `project`; SpotBugs' execution id
   `default` → `spotbugs-check` (both present means a partial migration);
   no `failsOnError`; dependency-check no longer under `<build><plugins>`;
   the JaCoCo executions also on a pom-packaged root; and surefire's
   `<includes>` gone, so its defaults (`Test*`, `*Test`, `*Tests`,
   `*TestCase`) apply.
6. Make sure `python3` is 3.11 or later.

To roll back, restore the previous `version` and `commit`, and the poms'
previous build configuration, since v0.1.x has no parent POM for Maven to
read: the cached old checkout is relinked offline, and v0.1.x ignores the
extra TOML table.
